import Foundation
import Observation

@MainActor
@Observable
public final class SecureRevealModel {
    public static let maximumNoteLength = 280

    public private(set) var state: RevealState = .checking
    public private(set) var error: SecureRevealError?

    private let storage: any ProtectedNoteStore
    private var isActive = true

    // Tracks unfinished work, not unlock status. It can remain true after locking.
    private var operationInFlight = false

    @ObservationIgnored private var activeAttemptID: UUID?
    @ObservationIgnored private var readTask: Task<String, any Error>?

    public init(storage: any ProtectedNoteStore) {
        self.storage = storage
    }

    public var canSave: Bool {
        isActive && !operationInFlight && state == .setup
    }

    public var canReveal: Bool {
        isActive && !operationInFlight && state == .locked
    }

    public var canReset: Bool {
        guard isActive && !operationInFlight else { return false }
        switch state {
        case .locked, .unlocked:
            return true
        default:
            return false
        }
    }

    /// Establishes initial setup state. It never starts an authentication prompt.
    public func load() async {
        guard state == .checking && !operationInFlight else { return }
        operationInFlight = true
        error = nil
        defer { operationInFlight = false }

        do {
            let exists = try await storage.containsNote()
            state = exists ? .locked : .setup
        } catch {
            let failure = classify(error)
            
            state = .locked
            if failure == .interactionNotAllowed {
                // Startup must not prompt.
                // Leave Reveal available for an explicit authenticated read.
                self.error = nil
            } else {
                self.error = failure
            }
        }
    }

    public func save(_ note: String) async {
        guard canSave && !Task.isCancelled else { return }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.count <= Self.maximumNoteLength else {
            error = .invalidNote
            return
        }

        operationInFlight = true
        state = .saving
        error = nil
        defer { operationInFlight = false }

        do {
            try await storage.saveNote(note)
            state = .locked
        } catch {
            state = .setup
            self.error = classify(error)
        }
    }

    public func reveal() async {
        guard canReveal && !Task.isCancelled else { return }

        // All of these changes happen before the first suspension point.
        operationInFlight = true
        state = .unlocking
        error = nil
        let attemptID = UUID()
        activeAttemptID = attemptID

        let task = Task { [storage] in
            try await storage.readNote()
        }
        readTask = task

        defer {
            readTask = nil
            operationInFlight = false
            if activeAttemptID == attemptID {
                activeAttemptID = nil
            }
        }

        do {
            let note = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                // The cancellation handler can run outside the main actor.
                Task { @MainActor [weak self] in
                    self?.cancelAttempt(attemptID, reportCancellation: true)
                }
            }

            // This check independently rejects a result after lock/background.
            guard activeAttemptID == attemptID else { return }

            // Handles caller cancellation before its actor cleanup has run.
            guard !Task.isCancelled else {
                cancelAttempt(attemptID, reportCancellation: true)
                return
            }

            state = .unlocked(note: note)
        } catch {
            guard activeAttemptID == attemptID else { return }
            guard !Task.isCancelled else {
                cancelAttempt(attemptID, reportCancellation: true)
                return
            }

            let failure = classify(error)
            state = failure == .missingItem ? .setup : .locked
            self.error = failure
        }
    }

    public func lock() {
        if let attemptID = activeAttemptID {
            cancelAttempt(attemptID, reportCancellation: false)
        }

        if case .unlocked = state {
            state = .locked
        }
        error = nil
    }

    public func reset() async {
        guard canReset && !Task.isCancelled else { return }
        operationInFlight = true
        state = .deleting
        error = nil
        defer { operationInFlight = false }

        do {
            try await storage.deleteNote()
            state = .setup
        } catch {
            state = .locked
            self.error = classify(error)
        }
    }

    public func sceneBecameInactive() {
        // Authentication can temporarily make the scene inactive.
        isActive = false
    }

    public func sceneBecameActive() {
        isActive = true
    }

    public func sceneEnteredBackground() {
        isActive = false
        lock()
    }

    private func cancelAttempt(_ attemptID: UUID, reportCancellation: Bool) {
        guard activeAttemptID == attemptID else { return }

        // Invalidate before requesting cancellation from either dependency.
        activeAttemptID = nil
        state = .locked
        error = reportCancellation ? .cancelled : nil
        readTask?.cancel()
        storage.cancelRead()
    }

    private func classify(_ error: any Error) -> SecureRevealError {
        if error is CancellationError {
            return .cancelled
        }
        return error as? SecureRevealError ?? .storageFailure
    }
}
