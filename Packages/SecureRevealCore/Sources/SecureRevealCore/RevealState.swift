// The Swift Programming Language
// https://docs.swift.org/swift-book

public enum RevealState: Equatable, Sendable {
    case checking
    case setup
    case saving
    case locked
    case unlocking
    case unlocked(note: String)
    case deleting
}

