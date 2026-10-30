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
            // SwiftUI's default Edit menu has no Find items, so the text view's find bar had no way to open.
            CommandGroup(after: .pasteboard) {
                Menu("Find") {
                    Button("Find…") { find(.showFindInterface) }
                        .keyboardShortcut("f")
                    Button("Find and Replace…") { find(.showReplaceInterface) }
                        .keyboardShortcut("f", modifiers: [.command, .option])
                    Button("Find Next") { find(.nextMatch) }
                        .keyboardShortcut("g")
                    Button("Find Previous") { find(.previousMatch) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    Button("Use Selection for Find") { find(.setSearchString) }
                        .keyboardShortcut("e")
                }
            }
        }
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    /// NSTextView reads which find action to run from the sender's tag, as it would from a menu item's.
    private func find(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: sender)
    }
}
