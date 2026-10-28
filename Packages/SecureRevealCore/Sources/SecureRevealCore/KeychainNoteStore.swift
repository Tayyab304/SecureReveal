//
//  KeychainNoteStore.swift
//  SecureRevealCore
//
//  Created by Tayyab on 09/09/2026.
//

import Dispatch
import Foundation
import LocalAuthentication
import Security

/// One owner, one note.
/// The model owns cancellation through cancelRead().
@MainActor
public final class KeychainNoteStore: ProtectedNoteStore {
    private let worker: KeychainWorker
    private var readID: UUID?

    public init(
        service: String,
        account: String = "private-note"
    ) {
        worker = KeychainWorker(
            service: service,
            account: account
        )
    }

    public func containsNote() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            worker.containsNote(continuation)
        }
    }

    public func saveNote(_ note: String) async throws {
        guard !note.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              note.count <= SecureRevealModel.maximumNoteLength else {
            throw SecureRevealError.invalidNote
        }

        try await withCheckedThrowingContinuation { continuation in
            worker.saveNote(
                note,
                continuation: continuation
            )
        }
    }

    public func readNote() async throws -> String {
        try Task.checkCancellation()

        guard readID == nil else {
            throw SecureRevealError.storageFailure
        }

        let id = UUID()
        readID = id

        defer {
            readID = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Enqueue before the main actor can run cancelRead().
            worker.beginRead(
                id: id,
                continuation: continuation
            )
        }
    }

    public func deleteNote() async throws {
        try await withCheckedThrowingContinuation { continuation in
            worker.deleteNote(continuation)
        }
    }

    public func cancelRead() {
        guard let id = readID else { return }

        worker.cancelRead(id: id)
    }
}

// Safety invariant:
// All mutable worker state and every LAContext access stay on queue.
// Methods called from outside this class only enqueue work.
//
// @unchecked Sendable means we enforce this invariant ourselves.
// It does not automatically make shared mutable objects safe.
private final class KeychainWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "SecureReveal.keychain",
        qos: .userInitiated
    )

    private let service: String
    private let account: String

    private var pendingRead: PendingRead?

    private struct PendingRead {
        let id: UUID
        let context: LAContext
        let continuation: CheckedContinuation<String, any Error>
    }

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    func containsNote(
        _ continuation: CheckedContinuation<Bool, any Error>
    ) {
        queue.async {
            do {
                let exists = try self.itemExists()
                continuation.resume(returning: exists)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func saveNote(
        _ note: String,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        queue.async {
            do {
                let context = LAContext()

                defer {
                    context.invalidate()
                }

                var policyError: NSError?

                guard context.canEvaluatePolicy(
                    .deviceOwnerAuthentication,
                    error: &policyError
                ) else {
                    throw SecureRevealError.authenticationUnavailable
                }

                // The authentication requirement belongs to the ITEM.
                guard let access = SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                    .userPresence,
                    nil
                ) else {
                    throw SecureRevealError.storageFailure
                }

                context.interactionNotAllowed = true

                var query = self.identityQuery()
                query[kSecAttrAccessControl as String] = access
                query[kSecValueData as String] = Data(note.utf8)
                query[kSecUseAuthenticationContext as String] = context

                let status = SecItemAdd(
                    query as CFDictionary,
                    nil
                )

                guard status == errSecSuccess else {
                    throw Self.failure(for: status)
                }

                continuation.resume(returning: ())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func deleteNote(
        _ continuation: CheckedContinuation<Void, any Error>
    ) {
        queue.async {
            let context = LAContext()

            defer {
                context.invalidate()
            }

            context.interactionNotAllowed = true

            var query = self.identityQuery()
            query[kSecUseAuthenticationContext as String] = context

            let status = SecItemDelete(query as CFDictionary)

            if status == errSecSuccess || status == errSecItemNotFound {
                continuation.resume(returning: ())
            } else {
                continuation.resume(
                    throwing: Self.failure(for: status)
                )
            }
        }
    }

    func beginRead(
        id: UUID,
        continuation: CheckedContinuation<String, any Error>
    ) {
        queue.async {
            guard self.pendingRead == nil else {
                continuation.resume(
                    throwing: SecureRevealError.storageFailure
                )
                return
            }

            // Fresh context for every Reveal attempt.
            let context = LAContext()
            context.touchIDAuthenticationAllowableReuseDuration = 0

            var policyError: NSError?

            guard context.canEvaluatePolicy(
                .deviceOwnerAuthentication,
                error: &policyError
            ) else {
                    #if DEBUG
                print(
                    "SecureReveal: authentication preflight failed; code =",
                    policyError?.code ?? 0
                )
                #endif
                context.invalidate()
                continuation.resume(
                    throwing: SecureRevealError.authenticationUnavailable
                )
                return
            }

            self.pendingRead = PendingRead(
                id: id,
                context: context,
                continuation: continuation
            )

            // Asynchronous authentication leaves our queue free
            // to process cancellation while the prompt is open.
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Authenticate to reveal your private note."
            ) { success, error in
                let failure = Self.authenticationFailure(error)

                // Apple's callback can arrive on a different queue.
                self.queue.async {
                    self.authenticationFinished(
                        id: id,
                        success: success,
                        failure: failure
                    )
                }
            }
        }
    }

    func cancelRead(id: UUID) {
        queue.async {
            self.finishRead(
                id: id,
                result: .failure(SecureRevealError.cancelled)
            )
        }
    }

    private func authenticationFinished(
        id: UUID,
        success: Bool,
        failure: SecureRevealError
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let request = pendingRead,
              request.id == id else {
            return
        }

        guard success else {
            finishRead(
                id: id,
                result: .failure(failure)
            )
            return
        }

        // Authentication success is not yet a successful note read.
        // Keychain must authorize access against the item's ACL.
        request.context.interactionNotAllowed = true

        var query = identityQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = request.context

        var result: CFTypeRef?

        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )

        #if DEBUG
            print("SecureReveal: protected read status =", status)
        #endif
        
        guard status == errSecSuccess else {
            finishRead(
                id: id,
                result: .failure(Self.failure(for: status))
            )
            return
        }

        guard let data = result as? Data,
              let note = String(data: data, encoding: .utf8) else {
            finishRead(
                id: id,
                result: .failure(SecureRevealError.storageFailure)
            )
            return
        }

        finishRead(
            id: id,
            result: .success(note)
        )
    }

    private func finishRead(
        id: UUID,
        result: Result<String, any Error>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let request = pendingRead,
              request.id == id else {
            return
        }

        // Remove first. Invalidation may produce a later callback.
        pendingRead = nil

        request.context.invalidate()
        request.continuation.resume(with: result)
    }

    private func itemExists() throws -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))

        let context = LAContext()

        defer {
            context.invalidate()
        }

        context.interactionNotAllowed = true

        var query = identityQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        // Metadata only: never request note data during initial loading.
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context

        var attributes: CFTypeRef?

        let status = SecItemCopyMatching(
            query as CFDictionary,
            &attributes
        )
        
        #if DEBUG
            print("SecureReveal: itemExists status =", status)
        #endif
        
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw Self.failure(for: status)
        }
    }

    private func identityQuery() -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(queue))

        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private static func failure(
        for status: OSStatus
    ) -> SecureRevealError {
        #if DEBUG
        print("SecureReveal: Keychain status =", status)
        #endif

        return switch status {
        case errSecItemNotFound:
                .missingItem
            
        case errSecUserCanceled:
                .cancelled
            
        case errSecAuthFailed:
                .authenticationFailed
            
        case errSecInteractionNotAllowed:
                .interactionNotAllowed
            
        case errSecNotAvailable:
                .authenticationUnavailable
            
        default:
                .storageFailure
        }
    }

    private static func authenticationFailure(
        _ error: (any Error)?
    ) -> SecureRevealError {
        guard let error = error as? LAError else {
            return .authenticationFailed
        }
        
        #if DEBUG
        print(
            "SecureReveal: authentication callback error =",
            error.code.rawValue
        )
        #endif
        
        
        return switch error.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            .cancelled
        case .passcodeNotSet, .biometryNotAvailable,
             .biometryNotEnrolled, .biometryLockout,
             .notInteractive:
            .authenticationUnavailable
        default:
            .authenticationFailed
        }
    }
}
