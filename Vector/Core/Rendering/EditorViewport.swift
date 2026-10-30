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
//  With one selection, NSTextView handles input itself and the delegate mirrors its edits into the buffer. With
//  several, EditorTextView routes input to the EditorState engine, and edits flow the other way: buffer first, then
//  the storage.
//

import AppKit

final class EditorViewport: NSView, NSTextViewDelegate {
    /// Owned here rather than in an observable model, so keystrokes never invalidate SwiftUI and the rope keeps
    /// its in-place edit path.
    private(set) var state = EditorState()
    private(set) var fileURL: URL?
    /// The text as last opened or saved. Undo restores exact Rope versions, so identity tells us if we're back.
    private var savedText = Rope()
    /// Nil for files with no registered grammar (and untitled buffers).
    private var highlighter: SyntaxHighlighter?
    /// The typing the last undo step is still open to, if any.
    private var typingRun: TypingRun?
    /// True while the viewport sets the text view's selection (or edits its storage), so the change isn't taken
    /// for the user's.
    private var isDrivingSelection = false

    /// Consecutive keystrokes of one kind, which undo as a single step.
    private struct TypingRun {
        var kind: InputKind
        /// The buffer version right after the run's last edit; any other change ends the run.
        var version: UInt64
        /// Where each of the last edits left the caret, as byte offsets.
        var carets: [Int]
        var time: ContinuousClock.Instant
    }

    /// Typing pauses longer than this start a new undo step.
    private static let typingPause = Duration.seconds(1)

    private let scrollView = NSScrollView()
    private let textView = EditorTextView(usingTextLayoutManager: false)

    private var buffer: TextBuffer {
        get { state.buffer }
        set { state.buffer = newValue }
    }

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

        // Highlighting covers only what's on screen, so recheck whenever that changes.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(visibleRegionDidChange(_:)),
                                                   name: name, object: clipView)
        }
    }

    @objc private func visibleRegionDidChange(_ notification: Notification) {
        highlighter?.highlightVisibleText()
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
        let edits = zip(affectedRanges.map(\.rangeValue), replacementStrings).sorted { $0.0.location < $1.0.location }

        // The buffer normalizes CRLF to LF; if the storage took the raw text, their offsets would drift apart.
        // Reject the change and reinsert normalized text instead (it comes back through here without CRLFs).
        if replacementStrings.contains(where: { $0.contains("\r\n") }) {
            // Back to front, so earlier ranges stay valid.
            let normalized = edits.reversed().map { ($0.0, $0.1.replacingOccurrences(of: "\r\n", with: "\n")) }
            Task { @MainActor [weak textView] in
                for (range, text) in normalized {
                    textView?.insertText(text, replacementRange: range)
                }
            }
            return false
        }

        // Applied front to back with a running shift, so the edits move monotonically through the text and undo can
        // mirror them range by range.
        let text = buffer.text
        let byteEdits = edits.map { (range: Self.byteRange(of: $0.0, in: text), text: $0.1) }

        let kind = self.textView.inputKind
        let coalesce = kind != .other && !byteEdits.contains { $0.text.contains("\n") }
        if coalesce && !continuesTypingRun(kind, byteEdits) {
            buffer.breakUndoCoalescing()
        }
        var bufferEdits: [BufferEdit] = []
        buffer.transact(coalesce: coalesce) { buffer in
            var shift = 0
            for (range, text) in byteEdits {
                let edit = buffer.edit((range.lowerBound + shift)..<(range.upperBound + shift), with: text)
                shift += edit.newRange.count - edit.oldRange.count
                bufferEdits.append(edit)
            }
        }
        typingRun = coalesce
            ? TypingRun(kind: kind, version: buffer.version, carets: bufferEdits.map(\.newRange.upperBound), time: .now)
            : nil
        // The old selections may now point past the text. NSTextView reports its new selection right after this; until
        // then, a caret after the last edit keeps them valid.
        if let last = bufferEdits.last {
            state.selections = SelectionSet(.caret(last.newRange.upperBound))
            self.textView.secondarySelections = []
        }
        highlighter?.bufferDidChange(bufferEdits)
        return true
    }

    // MARK: Selections

    var hasMultipleSelections: Bool { state.selections.count > 1 }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isDrivingSelection else { return }
        // The user (a click, native movement, the find bar) changed the selection: NSTextView's is the one now.
        // Its own discontiguous selections (⌘-drag) stay native; the engine tracks the last range.
        let text = buffer.text
        let range = textView.selectedRange()
        let lower = text.offset(atUTF16: range.location)
        let upper = text.offset(atUTF16: NSMaxRange(range))
        let current = state.selections.primary
        let unchanged = state.selections.count == 1 && current.range == lower..<upper
        // NSTextView doesn't expose which end moves; keep ours (and the goal column) if the range is the same.
        state.selections = SelectionSet(unchanged ? current : Selection(anchor: lower, head: upper))
        textView.secondarySelections = []
    }

    /// Shows `state.selections` in the text view: the primary natively, the rest drawn by the text view.
    private func showSelections() {
        let text = buffer.text
        let primary = state.selections.primary
        let primaryRange = utf16Range(primary.range, in: text)
        driveSelection { textView.setSelectedRange(primaryRange) }
        textView.secondarySelections = state.selections.items.indices
            .filter { $0 != state.selections.primaryIndex }
            .map { utf16Range(state.selections.items[$0].range, in: text) }
        textView.scrollRangeToVisible(NSRange(location: text.utf16Offset(at: primary.head), length: 0))
    }

    private func driveSelection(_ body: () -> Void) {
        isDrivingSelection = true
        defer { isDrivingSelection = false }
        body()
    }

    private func utf16Range(_ range: Range<Int>, in text: Rope) -> NSRange {
        let lower = text.utf16Offset(at: range.lowerBound)
        return NSRange(location: lower, length: text.utf16Offset(at: range.upperBound) - lower)
    }

    func toggleCaret(atCharacterIndex index: Int) {
        if textView.hasMarkedText() { textView.unmarkText() }
        state.selections.toggleCaret(at: buffer.text.offset(atUTF16: index))
        showSelections()
    }

    func collapseSelections() {
        guard hasMultipleSelections else { return }
        state.selections.collapseToPrimary()
        showSelections()
    }

    func selectNextOccurrence() {
        if textView.hasMarkedText() { textView.unmarkText() }
        if state.selectNextOccurrence() {
            showSelections()
        } else {
            NSSound.beep()
        }
    }

    // MARK: Commands

    /// Resolved once; an extension-provided keymap will replace this.
    let keymap = Keymap(DefaultKeymap.bindings)

    /// Editor commands by ID, for the keymap (and later, extensions and the command palette).
    private static let commands: [String: (EditorViewport) -> Void] = [
        "editor.selectNextOccurrence": { $0.selectNextOccurrence() },
        "editor.addCursorAbove": { $0.addCursors(above: true) },
        "editor.addCursorBelow": { $0.addCursors(above: false) },
        "editor.collapseSelections": { $0.collapseSelections() },
        "editor.moveLineUp": { $0.performEdit(.other) { state, _ in state.moveLines(up: true) } },
        "editor.moveLineDown": { $0.performEdit(.other) { state, _ in state.moveLines(up: false) } },
        "editor.duplicateLineUp": { $0.performEdit(.other) { state, _ in state.duplicateLines(down: false) } },
        "editor.duplicateLineDown": { $0.performEdit(.other) { state, _ in state.duplicateLines(down: true) } },
        "editor.deleteLine": { $0.performEdit(.other) { state, _ in state.deleteLines() } },
        "editor.toggleLineComment": { $0.toggleLineComment() },
        "editor.indent": { $0.performEdit(.other) { state, _ in state.indentLines() } },
        "editor.outdent": { $0.performEdit(.other) { state, _ in state.outdentLines() } },
    ]

    /// Runs the command with this ID. Returns false if there's no such command.
    @discardableResult
    func perform(command id: String) -> Bool {
        guard let command = Self.commands[id] else { return false }
        command(self)
        return true
    }

    private func addCursors(above: Bool) {
        if textView.hasMarkedText() { textView.unmarkText() }
        if state.addCursors(above: above) {
            showSelections()
        } else {
            NSSound.beep()
        }
    }

    private func toggleLineComment() {
        guard let token = fileURL.flatMap(SyntaxLanguage.forFile)?.lineComment else {
            NSSound.beep()  // plain text, or a language without line comments
            return
        }
        performEdit(.other) { state, _ in state.toggleLineComment(token) }
    }

    // MARK: Multi-cursor editing

    var selectedText: String { state.selectedText }

    func insertAtSelections(_ text: String) {
        performEdit(.insertion, newline: text.contains("\n")) { $0.insert(text, coalesce: $1) }
    }

    func pasteAtSelections(_ text: String) {
        performEdit(.other) { state, _ in state.paste(text) }
    }

    func deleteSelectedText() {
        performEdit(.other) { state, _ in state.insert("") }
    }

    private static let movements: [Selector: (EditorState.Movement, extending: Bool)] = [
        #selector(NSResponder.moveLeft(_:)): (.left, false),
        #selector(NSResponder.moveBackward(_:)): (.left, false),
        #selector(NSResponder.moveRight(_:)): (.right, false),
        #selector(NSResponder.moveForward(_:)): (.right, false),
        #selector(NSResponder.moveUp(_:)): (.up, false),
        #selector(NSResponder.moveDown(_:)): (.down, false),
        #selector(NSResponder.moveWordLeft(_:)): (.wordLeft, false),
        #selector(NSResponder.moveWordBackward(_:)): (.wordLeft, false),
        #selector(NSResponder.moveWordRight(_:)): (.wordRight, false),
        #selector(NSResponder.moveWordForward(_:)): (.wordRight, false),
        #selector(NSResponder.moveToBeginningOfLine(_:)): (.lineStart, false),
        #selector(NSResponder.moveToLeftEndOfLine(_:)): (.lineStart, false),
        #selector(NSResponder.moveToEndOfLine(_:)): (.lineEnd, false),
        #selector(NSResponder.moveToRightEndOfLine(_:)): (.lineEnd, false),
        #selector(NSResponder.moveToBeginningOfDocument(_:)): (.documentStart, false),
        #selector(NSResponder.moveToEndOfDocument(_:)): (.documentEnd, false),
        #selector(NSResponder.moveLeftAndModifySelection(_:)): (.left, true),
        #selector(NSResponder.moveBackwardAndModifySelection(_:)): (.left, true),
        #selector(NSResponder.moveRightAndModifySelection(_:)): (.right, true),
        #selector(NSResponder.moveForwardAndModifySelection(_:)): (.right, true),
        #selector(NSResponder.moveUpAndModifySelection(_:)): (.up, true),
        #selector(NSResponder.moveDownAndModifySelection(_:)): (.down, true),
        #selector(NSResponder.moveWordLeftAndModifySelection(_:)): (.wordLeft, true),
        #selector(NSResponder.moveWordBackwardAndModifySelection(_:)): (.wordLeft, true),
        #selector(NSResponder.moveWordRightAndModifySelection(_:)): (.wordRight, true),
        #selector(NSResponder.moveWordForwardAndModifySelection(_:)): (.wordRight, true),
        #selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(NSResponder.moveToLeftEndOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(NSResponder.moveToEndOfLineAndModifySelection(_:)): (.lineEnd, true),
        #selector(NSResponder.moveToRightEndOfLineAndModifySelection(_:)): (.lineEnd, true),
        #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)): (.documentStart, true),
        #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)): (.documentEnd, true),
    ]

    private static let deletions: [Selector: (EditorState.Deletion, InputKind)] = [
        #selector(NSResponder.deleteBackward(_:)): (.backward, .deleteBackward),
        #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)): (.backward, .deleteBackward),
        #selector(NSResponder.deleteForward(_:)): (.forward, .deleteForward),
        #selector(NSResponder.deleteWordBackward(_:)): (.wordBackward, .other),
        #selector(NSResponder.deleteWordForward(_:)): (.wordForward, .other),
        #selector(NSResponder.deleteToBeginningOfLine(_:)): (.toLineStart, .other),
    ]

    /// Runs a key-binding command at every selection. Returns false for commands the engine doesn't support.
    func performMultiCursorCommand(_ selector: Selector) -> Bool {
        if let (movement, extending) = Self.movements[selector] {
            state.move(movement, extending: extending)
            showSelections()
        } else if let (deletion, kind) = Self.deletions[selector] {
            performEdit(kind) { $0.delete(deletion, coalesce: $1) }
        } else if selector == #selector(NSResponder.insertNewline(_:)) {
            insertAtSelections("\n")
        } else if selector == #selector(NSResponder.insertTab(_:)) {
            insertAtSelections("\t")
        } else {
            return false
        }
        return true
    }

    /// Runs an engine edit, then mirrors it into the storage and shows the resulting selections. The operation gets
    /// whether to coalesce with the previous undo step.
    private func performEdit(_ kind: InputKind, newline: Bool = false,
                             _ operation: (inout EditorState, Bool) -> [BufferEdit]) {
        if textView.hasMarkedText() { textView.unmarkText() }
        let coalesce = kind != .other && !newline
        let heads = state.selections.items.map(\.head)
        let continuesRun = typingRun.map {
            $0.kind == kind && $0.version == buffer.version && $0.carets == heads
                && state.selections.items.allSatisfy(\.isEmpty) && ContinuousClock.now - $0.time < Self.typingPause
        } ?? false
        if coalesce && !continuesRun { buffer.breakUndoCoalescing() }

        let previous = buffer.text
        let edits = operation(&state, coalesce)
        if !edits.isEmpty {
            typingRun = coalesce
                ? TypingRun(kind: kind, version: buffer.version, carets: state.selections.items.map(\.head), time: .now)
                : nil
        }
        applyEngineEdits(edits, from: previous)
    }

    /// Brings the storage and the highlighter in line with edits the engine already made to the buffer.
    private func applyEngineEdits(_ edits: [BufferEdit], from previous: Rope) {
        if !edits.isEmpty {
            driveSelection { mirrorIntoStorage(edits, from: previous) }
            highlighter?.bufferDidChange(edits)
            textView.didChangeText()
        }
        showSelections()
    }

    /// Whether these edits pick up where the current typing run left off, so they can share its undo step.
    private func continuesTypingRun(_ kind: InputKind, _ edits: [(range: Range<Int>, text: String)]) -> Bool {
        guard let run = typingRun, run.kind == kind, run.version == buffer.version, run.carets.count == edits.count else {
            return false
        }
        // An IME composition replaces its own marked text, and can sit on a candidate list for a while.
        if kind == .composition { return true }
        guard ContinuousClock.now - run.time < Self.typingPause else { return false }
        return zip(edits, run.carets).allSatisfy { edit, caret in
            switch kind {
            case .insertion: edit.range == caret..<caret
            case .deleteBackward: edit.text.isEmpty && edit.range.upperBound == caret
            case .deleteForward: edit.text.isEmpty && edit.range.lowerBound == caret
            case .composition, .other: false
            }
        }
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

    /// Runs an undo/redo, which leaves a caret at each changed range, then mirrors it like any engine edit.
    private func applyHistoryStep(_ step: (inout EditorState) -> [BufferEdit]?) {
        if textView.hasMarkedText() { textView.unmarkText() }
        let previous = buffer.text
        guard let edits = step(&state) else { return }
        typingRun = nil
        applyEngineEdits(edits, from: previous)
    }

    /// Brings the text storage from `previous` up to the buffer's text, given the edits between them, touching only
    /// what changed.
    private func mirrorIntoStorage(_ edits: [BufferEdit], from previous: Rope) {
        guard let storage = textView.textStorage else { return }
        let replacements = BufferEdit.replacements(for: edits, resultLength: buffer.text.utf8Count)
        storage.beginEditing()
        for (old, new) in replacements.reversed() {  // back to front, so earlier ranges stay valid
            let lower = previous.utf16Offset(at: old.lowerBound)
            let upper = previous.utf16Offset(at: old.upperBound)
            storage.replaceCharacters(in: NSRange(location: lower, length: upper - lower),
                                      with: NSAttributedString(string: buffer.text.string(in: new), attributes: textAttributes))
        }
        storage.endEditing()
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
            state = EditorState(buffer: try TextBuffer(contentsOf: Data(contentsOf: url)))
        } catch TextBufferError.invalidUTF8 {
            showAlert("“\(url.lastPathComponent)” isn’t valid UTF-8 text.")
            return
        } catch {
            showAlert(error.localizedDescription)
            return
        }
        fileURL = url
        savedText = buffer.text
        typingRun = nil
        driveSelection {
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: buffer.text.description, attributes: textAttributes))
        }
        showSelections()
        highlighter = nil  // new buffer: never reuse the old parse, even for the same language
        updateHighlighter()
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
        // Keep the saved state reachable by undo.
        buffer.breakUndoCoalescing()
        typingRun = nil
        updateHighlighter()  // Save As may have changed the extension
        updateWindow()
    }

    /// Starts, replaces, or stops highlighting to match the current file name's language. Keeps the running
    /// highlighter (and its parse) when the language is unchanged.
    private func updateHighlighter() {
        let language = fileURL.flatMap(SyntaxLanguage.forFile)
        guard highlighter == nil || language !== highlighter?.language else { return }
        textView.layoutManager?.removeTemporaryAttribute(
            .foregroundColor, forCharacterRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0))
        highlighter = language.map { language in
            SyntaxHighlighter(language: language, textView: textView) { [unowned self] in (buffer.text, buffer.version) }
        }
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
