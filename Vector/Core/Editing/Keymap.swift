//
//  Keymap.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-30.
//
//  Key chords to command IDs. Bindings are plain strings on both sides ("alt+up" → "editor.moveLineUp"), so a
//  keymap can come from data — today the built-in table, later an extension or user config — without new Swift API.
//

import AppKit

/// A key plus modifiers, written like `cmd+shift+k`, `alt+up`, or `cmd+/`. Modifiers: `cmd`, `alt`, `ctrl`, `shift`.
/// Named keys: `up`, `down`, `left`, `right`, `escape`, `tab`, `enter`, `backspace`, `delete`; anything else is the
/// unshifted character the key types.
struct KeyChord: Hashable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private static let modifierNames: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "alt": .option, "ctrl": .control, "shift": .shift,
    ]

    private static let namedKeys: [Character: String] = [
        Character(UnicodeScalar(NSUpArrowFunctionKey)!): "up",
        Character(UnicodeScalar(NSDownArrowFunctionKey)!): "down",
        Character(UnicodeScalar(NSLeftArrowFunctionKey)!): "left",
        Character(UnicodeScalar(NSRightArrowFunctionKey)!): "right",
        Character(UnicodeScalar(NSDeleteFunctionKey)!): "delete",
        "\u{1B}": "escape",
        "\t": "tab",
        "\r": "enter",
        "\u{7F}": "backspace",
    ]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
    }

    /// Parses `cmd+shift+k`. Nil for an unknown modifier or an empty key.
    init?(_ description: String) {
        var parts = description.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // A trailing empty part means the key itself is "+", as in "cmd++".
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("+") }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for name in parts {
            guard let modifier = Self.modifierNames[name] else { return nil }
            modifiers.insert(modifier)
        }
        self.init(key: key, modifiers: modifiers)
    }

    /// The chord a key-down event types. Uses the unshifted character, so `cmd+shift+/` matches ⇧⌘/ rather than ⌘?.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        // Named keys from the plain characters: re-translating an arrow key through the layout gives a control
        // character instead of its function-key code.
        if let character = event.charactersIgnoringModifiers?.first, let name = Self.namedKeys[character] {
            self.init(key: name, modifiers: event.modifierFlags)
            return
        }
        guard let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
              characters.count == 1 else { return nil }
        self.init(key: characters.lowercased(), modifiers: event.modifierFlags)
    }
}

// NSEvent.ModifierFlags isn't Hashable on its own.
extension KeyChord {
    static func == (a: KeyChord, b: KeyChord) -> Bool {
        a.key == b.key && a.modifiers.rawValue == b.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}

struct Keymap {
    private var bindings: [KeyChord: String] = [:]

    /// `bindings` maps chord descriptions to command IDs. Unparseable chords are skipped (and assert in debug).
    init(_ bindings: [String: String]) {
        for (description, command) in bindings {
            guard let chord = KeyChord(description) else {
                assertionFailure("unparseable key chord “\(description)”")
                continue
            }
            self.bindings[chord] = command
        }
    }

    func command(for chord: KeyChord) -> String? {
        bindings[chord]
    }

    func command(for event: NSEvent) -> String? {
        KeyChord(event: event).flatMap { bindings[$0] }
    }
}
