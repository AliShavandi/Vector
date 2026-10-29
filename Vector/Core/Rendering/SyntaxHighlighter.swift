//
//  SyntaxHighlighter.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-29.
//
//  Keeps a SyntaxParser fed with buffer edits and colors the visible text from the latest tree. Colors are
//  TextKit 1 temporary attributes: they only invalidate drawing, never layout, and never touch the text storage.
//

import AppKit

final class SyntaxHighlighter {
    let language: SyntaxLanguage
    private let parser: SyntaxParser
    private let query: HighlightQuery?
    /// Color per capture index, resolved once from the theme.
    private let captureColors: [NSColor?]
    private weak var textView: NSTextView?
    /// The buffer's current text and version.
    private let currentText: () -> (text: Rope, version: UInt64)

    /// The newest tree that matches the buffer, and the buffer version it was parsed from.
    private var tree: SyntaxTree?
    private var treeVersion: UInt64?
    /// Edits made since the snapshot of the parse in flight (or the last parse).
    private var pendingEdits: [BufferEdit] = []
    private var isParsing = false
    /// UTF-16 ranges already colored from `tree`.
    private var colored = IndexSet()

    /// Lines colored beyond each edge of the viewport, so small scrolls don't need a query.
    private static let marginLines = 30

    init(language: SyntaxLanguage, textView: NSTextView, currentText: @escaping () -> (text: Rope, version: UInt64)) {
        self.language = language
        parser = SyntaxParser(language: language)
        query = language.highlightQuery
        captureColors = query?.captureNames.map(SyntaxTheme.color(forCapture:)) ?? []
        self.textView = textView
        self.currentText = currentText
        parseIfIdle()
    }

    /// Call with the edits from every buffer change (typing, undo, redo), in order.
    func bufferDidChange(_ edits: [BufferEdit]) {
        pendingEdits += edits
        parseIfIdle()
    }

    /// One parse at a time: edits that arrive meanwhile queue up and go into the next parse together, which keeps
    /// them ordered and coalesces fast typing.
    private func parseIfIdle() {
        guard !isParsing else { return }
        let (text, version) = currentText()
        let edits = pendingEdits
        pendingEdits = []
        isParsing = true
        Task { [weak self, parser] in
            let tree = await parser.parse(text, edits: edits)
            self?.didParse(tree, version: version)
        }
    }

    private func didParse(_ tree: SyntaxTree, version: UInt64) {
        isParsing = false
        guard pendingEdits.isEmpty else {
            parseIfIdle()  // already stale
            return
        }
        guard version == currentText().version else { return }
        self.tree = tree
        treeVersion = version
        colored = IndexSet()
        highlightVisibleText()
    }

    /// Colors whatever is on screen that hasn't been colored from the current tree. Call on scroll and resize too.
    func highlightVisibleText() {
        guard let tree, let query, let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let (text, version) = currentText()
        guard version == treeVersion else { return }  // a newer parse is on its way

        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let visible = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let firstRow = text.point(at: text.offset(atUTF16: visible.location)).row
        let lastRow = text.point(at: text.offset(atUTF16: NSMaxRange(visible))).row
        let bytes = text.lineRange(max(firstRow - Self.marginLines, 0)).lowerBound
            ..< text.lineRange(min(lastRow + Self.marginLines, text.lineCount - 1)).upperBound
        let utf16 = text.utf16Offset(at: bytes.lowerBound)..<text.utf16Offset(at: bytes.upperBound)
        guard !colored.contains(integersIn: utf16) else { return }

        let storageLength = textView.textStorage?.length ?? 0
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(utf16))
        for capture in query.captures(in: bytes, of: tree, text: text) {
            guard let color = captureColors[capture.captureIndex] else { continue }
            let lower = text.utf16Offset(at: capture.byteRange.lowerBound)
            let upper = min(text.utf16Offset(at: capture.byteRange.upperBound), storageLength)
            guard lower < upper else { continue }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color,
                                                forCharacterRange: NSRange(location: lower, length: upper - lower))
        }
        // An unclosed block comment runs to the end of the file, over whatever the grammar parsed after it.
        if let commentStart = tree.unterminatedBlockCommentStart, let color = SyntaxTheme.color(forCapture: "comment") {
            let lower = max(text.utf16Offset(at: commentStart), utf16.lowerBound)
            let upper = min(utf16.upperBound, storageLength)
            if lower < upper {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color,
                                                    forCharacterRange: NSRange(location: lower, length: upper - lower))
            }
        }
        colored.insert(integersIn: utf16)
    }
}

/// Capture name → color. Dynamic system colors, so light/dark switches need no re-highlight. Lookup falls back by
/// dropping dotted suffixes (`keyword.function` → `keyword`); captures with no entry keep the default text color.
enum SyntaxTheme {
    private static let colors: [String: NSColor] = [
        "keyword": .systemPink,
        "keyword.directive": .systemOrange,
        "boolean": .systemPink,
        "constant.builtin": .systemPink,
        "variable.builtin": .systemPink,
        "string": .systemRed,
        "string.escape": .systemOrange,
        "string.regexp": .systemOrange,
        "character.special": .systemOrange,
        "comment": .secondaryLabelColor,
        "type": .systemTeal,
        "constructor": .systemTeal,
        "function": .systemIndigo,
        "function.macro": .systemBrown,
        "number": .systemBlue,
        "attribute": .systemBrown,
        "label": .systemPurple,
    ]

    static func color(forCapture name: String) -> NSColor? {
        var key = Substring(name)
        while true {
            if let color = colors[String(key)] { return color }
            guard let dot = key.lastIndex(of: ".") else { return nil }
            key = key[..<dot]
        }
    }
}
