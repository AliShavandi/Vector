//
//  VectorApp.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-25.
//

import AppKit
import SwiftUI

@main
struct VectorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Sent down the responder chain, so they reach the key window's EditorViewport.
            CommandGroup(after: .newItem) {
                Button("Open…") { send(#selector(EditorViewport.openDocument(_:))) }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { send(#selector(EditorViewport.saveDocument(_:))) }
                    .keyboardShortcut("s")
                Button("Save As…") { send(#selector(EditorViewport.saveDocumentAs(_:))) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
