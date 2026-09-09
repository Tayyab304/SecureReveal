# SecureReveal

A small SwiftUI app for storing one private note in Keychain and
revealing it through Face ID or device passcode authentication.

Built to explore item-level access control, Swift Concurrency,
and testable state management in a local Swift Package.

## Features

- Save a note of up to 280 characters.
- Authenticate to reveal it.
- Lock manually or automatically when entering the background.
- Hide sensitive content while inactive.
- Delete the note and return to setup.
- Handle cancellation, missing data, and storage errors.

Everything runs locally, without networking or third-party dependencies.

## Setup

Requires Xcode 26.2 and iOS 17 or later.

1. Open `SecureReveal.xcodeproj`.
2. Select your signing team for the app and device test target.
3. Select the `SecureReveal` scheme and run on an iPhone.

The app links the local package at `Packages/SecureRevealCore`.
The app target includes `NSFaceIDUsageDescription`.

A physical device with a configured passcode is required for
the authentication and Keychain device checks.

## Design

The app uses MVVM with constructor-based dependency injection.
Reusable state management and Keychain storage live in a local
Swift Package, `SecureRevealCore`.

`SecureRevealView` renders the interface. `SecureRevealModel` serves
as the ViewModel, owning observable state and handling user actions.
It receives a `ProtectedNoteStore` through its initializer, allowing
tests to substitute controlled fake storage.

Unlock behavior follows an explicit state machine. Attempt identities
prevent invalidated authentication results from changing the state.

## Tests

| Suite | How to run | Verified |
| --- | --- | --- |
| Model tests | `SecureRevealCoreTests` scheme, iPhone simulator, ⌘U | 20 passed |
| Keychain integration | `SecureReveal` scheme with `SecureRevealDeviceTests` enabled, physical iPhone, ⌘U | 1 passed |

Model tests cover state transitions, cancellation, repeated taps,
storage errors, and stale results using controlled continuations
rather than sleeps.

The app-hosted integration test creates isolated test data,
checks that an unauthenticated Keychain read is rejected,
and deletes the item with teardown cleanup.

Manual iPhone checks passed for Face ID, passcode fallback,
persistence, cancellation, background relocking, deletion,
the inactive cover, and draft clearing. Touch ID hardware
has not been tested.

## Limitations

This is a learning project, not an audited security product.

- The chosen Keychain class does not sync or back up.
  Removing or resetting the device passcode renders its items unusable.
- Clearing Swift state does not guarantee plaintext memory zeroization.
- The privacy cover does not guarantee screenshot or recording prevention.
- The app does not protect against a compromised process or operating system.

## Demo

Save a note → Reveal and authenticate → Lock → Reveal again →
background and return locked → Delete.

## References

- [Apple: Keychain data protection](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web)
- [Apple: Accessing Keychain items with Face ID or Touch ID](https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id)
