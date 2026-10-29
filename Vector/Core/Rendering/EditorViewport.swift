//
//  EditorViewport.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-25.
//
//  NSTextView-based editor viewport over a TextBuffer. AppKit only — not SwiftUI.
//
//  The text view renders from its own NSTextStorage (a UTF-16 copy); every change is mirrored into the
//  TextBuffer, which stays the source of truth for parsing, LSP, and undo. A rope-backed NSTextStorage that
//  avoids the copy is a later optimization.
//

import AppKit

final class EditorViewport: NSView, NSTextViewDelegate {
    /// Owned here rather than in an observable model, so keystrokes never invalidate SwiftUI and the rope keeps
    /// its in-place edit path.
    private(set) var buffer = TextBuffer()
    private(set) var fileURL: URL?
    /// The text as last opened or saved. Undo restores exact Rope versions, so identity tells us if we're back.
    private var savedText = Rope()

    private let scrollView = NSScrollView()
    private let textView = EditorTextView(usingTextLayoutManager: false)

    private let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor.textColor,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTextView()
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureTextView() {
        textView.viewport = self
        textView.delegate = self
        textView.layoutManager?.allowsNonContiguousLayout = true

        // Code editor behavior: plain text, no wrapping, none of the prose "smart" features.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false  // undo goes through TextBuffer
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.font = textAttributes[.font] as? NSFont
        textView.typingAttributes = textAttributes
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 4)

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(textView)
        updateWindow()
    }

    // MARK: Mirroring edits into the buffer

    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        guard let replacementStrings else { return true }  // attribute-only change
        // Apply back to front so earlier ranges stay valid.
        let edits = zip(affectedRanges.map(\.rangeValue), replacementStrings).sorted { $0.0.location > $1.0.location }

        // The buffer normalizes CRLF to LF; if the storage took the raw text, their offsets would drift apart.
        // Reject the change and reinsert normalized text instead (it comes back through here without CRLFs).
        if replacementStrings.contains(where: { $0.contains("\r\n") }) {
            let normalized = edits.map { ($0.0, $0.1.replacingOccurrences(of: "\r\n", with: "\n")) }
            Task { @MainActor [weak textView] in
                for (range, text) in normalized {
                    textView?.insertText(text, replacementRange: range)
                }
            }
            return false
        }

        let apply = { (buffer: inout TextBuffer) in
            for (range, text) in edits {
                buffer.edit(Self.byteRange(of: range, in: buffer.text), with: text)
            }
        }
        if edits.count == 1 {
            apply(&buffer)
        } else {
            buffer.transact(apply)
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        assert(textView.textStorage?.length == buffer.text.utf16Count, "text storage and buffer diverged")
        updateWindow()
    }

    private static func byteRange(of range: NSRange, in text: Rope) -> Range<Int> {
        text.offset(atUTF16: range.location)..<text.offset(atUTF16: NSMaxRange(range))
    }

    // MARK: Undo

    var canUndo: Bool { buffer.canUndo }
    var canRedo: Bool { buffer.canRedo }

    func undo() { applyHistoryStep { $0.undo() } }
    func redo() { applyHistoryStep { $0.redo() } }

    /// Runs an undo/redo on the buffer, then brings the text storage in line with the edits it returns.
    private func applyHistoryStep(_ step: (inout TextBuffer) -> [BufferEdit]?) {
        if textView.hasMarkedText() { textView.unmarkText() }
        let previous = buffer.text
        guard let edits = step(&buffer), let storage = textView.textStorage else { return }

        if edits.count == 1, let edit = edits.first {
            let lower = previous.utf16Offset(at: edit.oldRange.lowerBound)
            let upper = previous.utf16Offset(at: edit.oldRange.upperBound)
            let text = buffer.text.string(in: edit.newRange)
            storage.replaceCharacters(in: NSRange(location: lower, length: upper - lower),
                                      with: NSAttributedString(string: text, attributes: textAttributes))
            let caret = NSRange(location: lower + text.utf16.count, length: 0)
            textView.setSelectedRange(caret)
            textView.scrollRangeToVisible(caret)
        } else {
            // Edits within a multi-edit transaction can overlap, so their inserted text isn't recoverable from the
            // final rope alone. The view doesn't produce these yet; replace everything.
            storage.setAttributedString(NSAttributedString(string: buffer.text.description, attributes: textAttributes))
        }
        textView.didChangeText()
    }

    // MARK: Open / Save
    // Stopgap: file handling moves to a document/workspace layer once there are tabs.

    @objc func openDocument(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            open(url)
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let fileURL {
            write(to: fileURL)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.txt"
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            write(to: url)
        }
    }

    func open(_ url: URL) {
        do {
            buffer = try TextBuffer(contentsOf: Data(contentsOf: url))
        } catch TextBufferError.invalidUTF8 {
            showAlert("“\(url.lastPathComponent)” isn’t valid UTF-8 text.")
            return
        } catch {
            showAlert(error.localizedDescription)
            return
        }
        fileURL = url
        savedText = buffer.text
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: buffer.text.description, attributes: textAttributes))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        updateWindow()
    }

    private func write(to url: URL) {
        do {
            // Not .atomic: the sandbox grants access to the chosen file only, not a temp file beside it.
            try buffer.encoded().write(to: url)
        } catch {
            showAlert(error.localizedDescription)
            return
        }
        fileURL = url
        savedText = buffer.text
        updateWindow()
    }

    private func updateWindow() {
        guard let window else { return }
        window.title = fileURL?.lastPathComponent ?? "Untitled"
        window.representedURL = fileURL
        window.isDocumentEdited = !buffer.text.isIdentical(to: savedText)
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Routes Edit ▸ Undo/Redo to the viewport's TextBuffer instead of an NSUndoManager.
private final class EditorTextView: NSTextView {
    weak var viewport: EditorViewport?

    @objc func undo(_ sender: Any?) { viewport?.undo() }
    @objc func redo(_ sender: Any?) { viewport?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): viewport?.canUndo ?? false
        case #selector(redo(_:)): viewport?.canRedo ?? false
        default: super.validateUserInterfaceItem(item)
        }
    }
}
