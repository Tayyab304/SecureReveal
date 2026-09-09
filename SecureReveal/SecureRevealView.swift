//
//  ContentView.swift
//  SecureReveal
//
//  Created by Tayyab on 08/09/2026.
//

import SecureRevealCore
import SwiftUI

@MainActor
struct SecureRevealView: View {
    let model: SecureRevealModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @FocusState private var draftIsFocused: Bool

    var body: some View {
        ZStack {
            if scenePhase == .active {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label(
                            "SecureReveal",
                            systemImage: "lock.shield"
                        )
                        .font(.largeTitle.bold())

                        Text("One private note, protected on this device.")
                            .foregroundStyle(.secondary)

                        stateContent

                        if let error = model.error {
                            Text(message(for: error))
                                .foregroundStyle(.red)
                                .accessibilityLabel(
                                    "Notice: " + message(for: error)
                                )
                        }

                        Button("Lock", systemImage: "lock") {
                            clearDraft()
                            model.lock()
                        }
                        .buttonStyle(.bordered)

                        Button("Delete note", role: .destructive) {
                            clearDraft()

                            Task {
                                await model.reset()
                            }
                        }
                        .disabled(!model.canReset)
                    }
                    .padding(24)
                }
            } else {
                // Sensitive views are absent while inactive.
                // This does not guarantee screenshot prevention.
                Color(.systemBackground)
                    .ignoresSafeArea()

                Label(
                    "SecureReveal",
                    systemImage: "lock.shield"
                )
                .font(.title)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .task {
            // Metadata only. No authentication prompt.
            await model.load()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                model.sceneBecameActive()

            case .inactive:
                draftIsFocused = false
                model.sceneBecameInactive()

            case .background:
                clearDraft()
                model.sceneEnteredBackground()

            @unknown default:
                clearDraft()
                model.sceneEnteredBackground()
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .checking:
            ProgressView("Checking for a saved note…")

        case .setup:
            Text("No note saved")
                .font(.headline)

            TextField(
                "Enter a private note",
                text: $draft,
                axis: .vertical
            )
            .lineLimit(3...6)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .privacySensitive()
            .focused($draftIsFocused)

            Text(
                "\(draft.count)/\(SecureRevealModel.maximumNoteLength) characters"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Save note") {
                // Retain the submission only for the write.
                // Never restore it to the UI after backgrounding.
                let note = draft
                clearDraft()

                Task {
                    await model.save(note)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSave)

        case .saving:
            ProgressView("Saving…")

        case .locked:
            Text("Locked")
                .font(.headline)

            Button("Reveal note") {
                Task {
                    await model.reveal()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canReveal)

        case .unlocking:
            ProgressView("Authenticating…")

        case .unlocked(let note):
            Text("Unlocked")
                .font(.headline)

            Text(note)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .padding()
                .background(
                    .quaternary,
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .privacySensitive()
                .textSelection(.disabled)

        case .deleting:
            ProgressView("Deleting…")
        }
    }

    private func clearDraft() {
        draft = ""
        draftIsFocused = false
    }

    private func message(
        for error: SecureRevealError
    ) -> String {
        switch error {
        case .cancelled:
            "Authentication was cancelled. Your note remains locked."
            
        case .authenticationUnavailable:
            "Authentication is unavailable. Check that your device has a passcode, then try again."
            
        case .authenticationFailed:
            "Authentication did not succeed. Please try again."
            
        case .interactionNotAllowed:
            "The protected operation could not complete without further system interaction. Please try again."
            
        case .missingItem:
            "No saved note was found. You can create a new one."
            
        case .storageFailure:
            "Could not complete the storage operation. Please try again."
            
        case .invalidNote:
            "Enter a note containing 1–280 characters, not only spaces."
        }
    }
}
