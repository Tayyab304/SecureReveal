//
//  SecureRevealApp.swift
//  SecureReveal
//
//  Created by Tayyab on 08/09/2026.
//

import SwiftUI
import SecureRevealCore

@main
struct SecureRevealApp: App {
    @State private var model = SecureRevealModel(
            storage: KeychainNoteStore(
                service: "com.example.SecureReveal.private-note"
            )
        )
    
    var body: some Scene {
        WindowGroup {
            SecureRevealView(model: model)
        }
    }
}
