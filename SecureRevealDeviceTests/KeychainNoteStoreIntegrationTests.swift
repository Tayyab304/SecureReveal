//
//  KeychainNoteStoreIntegrationTests.swift
//  SecureRevealCore
//
//  Created by Tayyab on 09/09/2026.
//

import Foundation
import LocalAuthentication
import Security
import SecureRevealCore
import XCTest

final class KeychainNoteStoreIntegrationTests: XCTestCase {
    @MainActor
    func testProtectedItemRejectsUnauthenticatedReadAndCanBeDeleted() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip(
            "Run this Keychain protection check on a physical iPhone."
        )
        #else
        // A unique identity prevents collisions with the app and other tests.
        let service = "SecureReveal.integration.\(UUID().uuidString)"
        let account = "test-note"

        let storage = KeychainNoteStore(
            service: service,
            account: account
        )

        // Register cleanup before attempting to create the item.
        // XCTest also runs this if the test throws or an assertion fails.
        addTeardownBlock {
            try await storage.deleteNote()
        }

        let initiallyExists = try await storage.containsNote()
        XCTAssertFalse(initiallyExists)

        // Synthetic test data only.
        try await storage.saveNote("Integration test note")

        // Bypass the model and read directly through Apple's API.
        // The fresh context has not authenticated.
        let readStatus = await Task.detached(
            priority: .userInitiated
        ) {
            let context = LAContext()

            defer {
                context.invalidate()
            }

            context.interactionNotAllowed = true

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context
            ]

            var result: CFTypeRef?

            return SecItemCopyMatching(
                query as CFDictionary,
                &result
            )
        }.value

        XCTAssertEqual(
            readStatus,
            errSecInteractionNotAllowed,
            "A fresh unauthenticated context must not read the protected item."
        )

        try await storage.deleteNote()

        let existsAfterDeletion = try await storage.containsNote()
        XCTAssertFalse(existsAfterDeletion)

        // Teardown repeats deletion, also exercising missing-item cleanup.
        #endif
    }
}
