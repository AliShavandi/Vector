//
//  DefaultKeymap.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-30.
//
//  The built-in key bindings. Plain data, so an extension's or the user's keymap can replace or extend it later.
//

enum DefaultKeymap {
    static let bindings: [String: String] = [
        "cmd+d": "editor.selectNextOccurrence",
        "alt+cmd+up": "editor.addCursorAbove",
        "alt+cmd+down": "editor.addCursorBelow",
        "alt+up": "editor.moveLineUp",
        "alt+down": "editor.moveLineDown",
        "shift+alt+up": "editor.duplicateLineUp",
        "shift+alt+down": "editor.duplicateLineDown",
        "shift+cmd+k": "editor.deleteLine",
        "cmd+/": "editor.toggleLineComment",
        "cmd+]": "editor.indent",
        "cmd+[": "editor.outdent",
    ]
}
