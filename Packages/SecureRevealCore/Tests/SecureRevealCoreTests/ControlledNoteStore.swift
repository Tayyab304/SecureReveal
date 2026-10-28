import SecureRevealCore

/// Test data only: this fake stores plaintext in memory and performs no authentication.
@MainActor
final class ControlledNoteStore: ProtectedNoteStore {
    private(set) var note: String?
    private(set) var readCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private(set) var cancellationCount = 0

    var inspectionError: (any Error)?
    var saveError: (any Error)?
    var deleteError: (any Error)?

    private var readContinuation: CheckedContinuation<String, any Error>?
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(note: String?) {
        self.note = note
    }

    func containsNote() async throws -> Bool {
        if let inspectionError { throw inspectionError }
        return note != nil
    }

    func saveNote(_ note: String) async throws {
        saveCount += 1
        if let saveError { throw saveError }
        self.note = note
    }

    func readNote() async throws -> String {
        readCount += 1
        guard readContinuation == nil else {
            throw SecureRevealError.storageFailure
        }

        // The test controls completion, even if this task has been cancelled.
        return try await withCheckedThrowingContinuation { continuation in
            readContinuation = continuation
            let waiters = readStartWaiters
            readStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    func deleteNote() async throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        note = nil
    }

    func cancelRead() {
        cancellationCount += 1
        // Deliberately do not finish the read: cancellation may not stop a backend.
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForReadStart() async {
        if readContinuation != nil { return }
        await withCheckedContinuation { continuation in
            readStartWaiters.append(continuation)
        }
    }

    func waitForCancellation() async {
        if cancellationCount > 0 { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func finishRead() {
        if let note {
            finishRead(with: .success(note))
        } else {
            finishRead(with: .failure(SecureRevealError.missingItem))
        }
    }

    func finishRead(with result: Result<String, any Error>) {
        guard let continuation = readContinuation else {
            preconditionFailure("The test must start a read before completing it.")
        }
        readContinuation = nil
        continuation.resume(with: result)
    }
}
