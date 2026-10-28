import SecureRevealCore
import XCTest

private let syntheticNote = "Synthetic test note"

final class SecureRevealModelTests: XCTestCase {
    @MainActor
    func testLoadingAnEmptyStoreEntersSetup() async {
        let storage = ControlledNoteStore(note: nil)
        let model = SecureRevealModel(storage: storage)

        XCTAssertEqual(model.state, .checking)
        await model.load()

        XCTAssertEqual(model.state, .setup)
        XCTAssertTrue(model.canSave)
        XCTAssertFalse(model.canReveal)
        XCTAssertEqual(storage.readCount, 0)
    }

    @MainActor
    func testSuccessfulSaveLeavesTheNoteLocked() async {
        let (model, storage) = await makeLoadedModel(note: nil)

        await model.save(syntheticNote)

        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(storage.note, syntheticNote)
        XCTAssertTrue(model.canReveal)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testInvalidNotesNeverReachStorage() async {
        let (model, storage) = await makeLoadedModel(note: nil)
        let tooLong = String(repeating: "x", count: SecureRevealModel.maximumNoteLength + 1)

        for invalidNote in ["", " \n\t", tooLong] {
            await model.save(invalidNote)
            XCTAssertEqual(model.state, .setup)
            XCTAssertEqual(model.error, .invalidNote)
        }

        XCTAssertEqual(storage.saveCount, 0)
    }

    @MainActor
    func testSaveFailureKeepsSetupAvailable() async {
        let (model, storage) = await makeLoadedModel(note: nil)
        storage.saveError = SecureRevealError.storageFailure

        await model.save(syntheticNote)

        XCTAssertEqual(model.state, .setup)
        XCTAssertEqual(model.error, .storageFailure)
        XCTAssertNil(storage.note)
        XCTAssertTrue(model.canSave)
    }

    @MainActor
    func testSuccessfulRetrievalRevealsTheNote() async {
        let (model, storage) = await makeLoadedModel()
        let attempt = Task { await model.reveal() }
        await storage.waitForReadStart()

        XCTAssertEqual(model.state, .unlocking)
        storage.finishRead()
        await attempt.value

        XCTAssertEqual(model.state, .unlocked(note: syntheticNote))
        XCTAssertNil(model.error)
    }

    @MainActor
    func testCancellationAndRetrievalFailuresLeaveItLocked() async {
        let failures: [SecureRevealError] = [
            .cancelled,
            .authenticationUnavailable,
            .authenticationFailed,
            .storageFailure
        ]

        for failure in failures {
            let (model, storage) = await makeLoadedModel()
            let attempt = Task { await model.reveal() }
            await storage.waitForReadStart()

            storage.finishRead(with: .failure(failure))
            await attempt.value

            XCTAssertEqual(model.state, .locked)
            XCTAssertEqual(model.error, failure)
            XCTAssertTrue(model.canReveal)
        }
    }

    @MainActor
    func testSwiftCancellationErrorMapsToSafeCancellationFeedback() async {
        let (model, storage) = await makeLoadedModel()
        let attempt = Task { await model.reveal() }
        await storage.waitForReadStart()

        storage.finishRead(with: .failure(CancellationError()))
        await attempt.value

        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(model.error, .cancelled)
    }

    @MainActor
    func testRepeatedRevealActionsStartOnlyOneRead() async {
        let (model, storage) = await makeLoadedModel()
        let attempt = Task { await model.reveal() }
        await storage.waitForReadStart()

        await model.reveal()
        await model.reveal()
        XCTAssertEqual(storage.readCount, 1)

        storage.finishRead()
        await attempt.value
        XCTAssertEqual(model.state, .unlocked(note: syntheticNote))
    }

    @MainActor
    func testManualLockClearsRevealedState() async {
        let (model, storage) = await makeLoadedModel()
        await revealSuccessfully(model, storage: storage)

        model.lock()

        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(storage.note, syntheticNote)
        XCTAssertTrue(model.canReveal)
    }

    @MainActor
    func testBackgroundingClearsRevealedStateAndBlocksReveal() async {
        let (model, storage) = await makeLoadedModel()
        await revealSuccessfully(model, storage: storage)

        model.sceneEnteredBackground()
        await model.reveal()

        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.canReveal)
        XCTAssertEqual(storage.readCount, 1)

        model.sceneBecameActive()
        XCTAssertTrue(model.canReveal)
    }

    @MainActor
    func testLateSuccessAfterManualLockCannotUnlock() async {
        let (model, storage) = await makeLoadedModel()
        let attempt = Task { await model.reveal() }
        await storage.waitForReadStart()

        model.lock()
        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(storage.cancellationCount, 1)

        storage.finishRead()
        await attempt.value

        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testLateSuccessAfterBackgroundAndReturnCannotUnlock() async {
        let (model, storage) = await makeLoadedModel()
        let oldAttempt = Task { await model.reveal() }
        await storage.waitForReadStart()

        model.sceneEnteredBackground()
        model.sceneBecameActive()

        // The old operation is still running, even though its result is invalid.
        XCTAssertEqual(model.state, .locked)
        XCTAssertFalse(model.canReveal)
        XCTAssertFalse(model.canReset)
        await model.reveal()
        await model.reset()
        XCTAssertEqual(storage.readCount, 1)
        XCTAssertEqual(storage.deleteCount, 0)
        XCTAssertEqual(storage.cancellationCount, 1)

        // Cancellation did not stop the fake. It returns plaintext afterward.
        storage.finishRead()
        await oldAttempt.value

        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.canReveal)

        // A fresh, explicit attempt is now allowed.
        await revealSuccessfully(model, storage: storage)
        XCTAssertEqual(storage.readCount, 2)
        XCTAssertEqual(model.state, .unlocked(note: syntheticNote))
    }

    @MainActor
    func testTemporaryInactivityDoesNotCancelTheCurrentAttempt() async {
        let (model, storage) = await makeLoadedModel()
        model.sceneBecameInactive()
        await model.reveal()
        XCTAssertEqual(storage.readCount, 0)

        model.sceneBecameActive()
        let attempt = Task { await model.reveal() }
        await storage.waitForReadStart()
        model.sceneBecameInactive()

        XCTAssertEqual(model.state, .unlocking)
        XCTAssertEqual(storage.cancellationCount, 0)

        storage.finishRead()
        await attempt.value
        model.sceneBecameActive()

        XCTAssertEqual(model.state, .unlocked(note: syntheticNote))
    }

    @MainActor
    func testAnItemDisappearingBeforeReadReturnsToSetup() async throws {
        let (model, storage) = await makeLoadedModel()
        try await storage.deleteNote()

        let attempt = Task { await model.reveal() }
        await storage.waitForReadStart()
        storage.finishRead()
        await attempt.value

        XCTAssertEqual(model.state, .setup)
        XCTAssertEqual(model.error, .missingItem)
        XCTAssertTrue(model.canSave)
    }

    @MainActor
    func testUnknownInspectionErrorBecomesSafeStorageFeedback() async {
        enum UnexpectedFailure: Error { case testOnly }
        let storage = ControlledNoteStore(note: syntheticNote)
        storage.inspectionError = UnexpectedFailure.testOnly
        let model = SecureRevealModel(storage: storage)

        await model.load()

        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(model.error, .storageFailure)
        XCTAssertEqual(storage.readCount, 0)
    }

    @MainActor
    func testResetClearsRevealedStateAndDeletesTheNote() async {
        let (model, storage) = await makeLoadedModel()
        await revealSuccessfully(model, storage: storage)

        await model.reset()

        XCTAssertEqual(model.state, .setup)
        XCTAssertNil(storage.note)
        XCTAssertNil(model.error)
        XCTAssertEqual(storage.deleteCount, 1)
    }

    @MainActor
    func testResetFailureLeavesTheNoteHiddenAndReportsFailure() async {
        let (model, storage) = await makeLoadedModel()
        await revealSuccessfully(model, storage: storage)
        storage.deleteError = SecureRevealError.storageFailure

        await model.reset()

        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(model.error, .storageFailure)
        XCTAssertEqual(storage.note, syntheticNote)
        XCTAssertTrue(model.canReset)
    }

    @MainActor
    func testCallerCancellationInvalidatesTheAttemptAndRejectsLateSuccess() async {
        let (model, storage) = await makeLoadedModel()
        let attempt = Task { await model.reveal() }
        await storage.waitForReadStart()

        attempt.cancel()
        await storage.waitForCancellation()
        XCTAssertEqual(model.state, .locked)

        storage.finishRead()
        await attempt.value

        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(model.error, .cancelled)
        XCTAssertEqual(storage.cancellationCount, 1)
    }

    @MainActor
    private func makeLoadedModel(
        note: String? = syntheticNote
    ) async -> (SecureRevealModel, ControlledNoteStore) {
        let storage = ControlledNoteStore(note: note)
        let model = SecureRevealModel(storage: storage)
        await model.load()
        return (model, storage)
    }

    @MainActor
    private func revealSuccessfully(
        _ model: SecureRevealModel,
        storage: ControlledNoteStore
    ) async {
        let attempt = Task { await model.reveal() }
        await storage.waitForReadStart()
        storage.finishRead()
        await attempt.value
    }
    
    @MainActor
    func testNoninteractiveInspectionLeavesAppQuietlyLocked() async {
        let storage = ControlledNoteStore(note: "Test note")
        storage.inspectionError = SecureRevealError.interactionNotAllowed

        let model = SecureRevealModel(storage: storage)

        await model.load()

        XCTAssertEqual(model.state, .locked)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.canReveal)
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(storage.readCount, 0)
    }

    @MainActor
    func testInteractionErrorDuringRevealIsStillReported() async {
        let storage = ControlledNoteStore(note: "Test note")
        let model = SecureRevealModel(storage: storage)

        await model.load()

        let attempt = Task {
            await model.reveal()
        }

        await storage.waitForReadStart()

        storage.finishRead(
            with: .failure(SecureRevealError.interactionNotAllowed)
        )

        await attempt.value

        XCTAssertEqual(model.state, .locked)
        XCTAssertEqual(model.error, .interactionNotAllowed)
        XCTAssertTrue(model.canReveal)
    }
}
