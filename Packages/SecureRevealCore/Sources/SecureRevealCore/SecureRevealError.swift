public enum SecureRevealError: Error, Equatable, Sendable {
    case cancelled
    case authenticationUnavailable
    case authenticationFailed
    case interactionNotAllowed
    case missingItem
    case storageFailure
    case invalidNote
}
