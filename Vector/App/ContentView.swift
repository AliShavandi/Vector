//
//  ContentView.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        EditorViewportRepresentable()
    }
}

/// Hosts the AppKit editor viewport. It owns its own state, so there's nothing to update from SwiftUI.
struct EditorViewportRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> EditorViewport {
        EditorViewport()
    }

    func updateNSView(_ nsView: EditorViewport, context: Context) {}
}

#Preview {
    ContentView()
}
