/// A single owner's protected storage for one note.
/// Implementations must move blocking work off the main actor.
@MainActor
public protocol ProtectedNoteStore: AnyObject {
    /// Checks for an item without requesting its plaintext or displaying authentication.
    func containsNote() async throws -> Bool

    /// Saves a new note. Callers use reset before setting up a replacement note.
    func saveNote(_ note: String) async throws

    /// Retrieves plaintext only after the real backend's access control is satisfied.
    func readNote() async throws -> String

    /// Deleting an already missing item must succeed.
    func deleteNote() async throws

    /// Requests cancellation without blocking. The pending read may still complete.
    func cancelRead()
}
