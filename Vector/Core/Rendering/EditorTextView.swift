//
//  EditorTextView.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-30.
//
//  The viewport's NSTextView. NSTextView can't hold several insertion points, so it only ever shows the primary
//  selection. With more than one selection, this view sends input to the viewport's editing engine instead of
//  NSTextView's own handling, and draws the other selections itself.
//

import AppKit

/// What produced the text change in progress, so typing can be grouped into one undo step.
enum InputKind {
    case insertion
    case deleteBackward
    case deleteForward
    /// Marked text from an input method, and the text that commits it.
    case composition
    /// Paste, drop, find and replace, and everything else; never grouped.
    case other
}

final class EditorTextView: NSTextView {
    weak var viewport: EditorViewport?
    /// Set only while a keystroke's change is being made.
    private(set) var inputKind = InputKind.other

    /// Every selection but the primary, as UTF-16 ranges. Update after any change that could move them.
    var secondarySelections: [NSRange] = [] {
        didSet {
            updateSecondaryCarets()
            setNeedsDisplay(visibleRect)
        }
    }
    /// One system caret per empty secondary selection; they blink on their own.
    private var secondaryCarets: [NSTextInsertionIndicator] = []

    private var hasMultipleSelections: Bool { viewport?.hasMultipleSelections ?? false }

    // MARK: Undo

    @objc func undo(_ sender: Any?) { viewport?.undo() }
    @objc func redo(_ sender: Any?) { viewport?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): viewport?.canUndo ?? false
        case #selector(redo(_:)): viewport?.canRedo ?? false
        case #selector(copy(_:)) where hasMultipleSelections: !(viewport?.selectedText.isEmpty ?? true)
        case #selector(cut(_:)) where hasMultipleSelections: !(viewport?.selectedText.isEmpty ?? true)
        default: super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Input

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let viewport, viewport.hasMultipleSelections {
            // A replacement range comes from an input method or service acting on one spot; let NSTextView have it.
            if !hasMarkedText(), replacementRange.location == NSNotFound,
               let text = (string as? String) ?? (string as? NSAttributedString)?.string {
                viewport.insertAtSelections(text)
                return
            }
            viewport.collapseSelections()
        }
        withInputKind(hasMarkedText() ? .composition : .insertion) {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Composing at several carets isn't supported yet; compose at the primary one.
        if hasMultipleSelections { viewport?.collapseSelections() }
        withInputKind(.composition) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
    }

    /// Key bindings arrive here (arrows, delete, return, ...). With several selections the engine handles the ones it
    /// supports; anything else collapses to the primary selection and goes to NSTextView as usual.
    override func doCommand(by selector: Selector) {
        guard let viewport, viewport.hasMultipleSelections else { return super.doCommand(by: selector) }
        if !viewport.performMultiCursorCommand(selector) {
            viewport.collapseSelections()
            super.doCommand(by: selector)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        withInputKind(.deleteBackward) { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        withInputKind(.deleteForward) { super.deleteForward(sender) }
    }

    /// Esc. Collapses multiple selections, or else closes the find bar; never NSTextView's default, which opens the
    /// completion popup.
    override func cancelOperation(_ sender: Any?) {
        if hasMultipleSelections {
            viewport?.collapseSelections()
        } else if enclosingScrollView?.isFindBarVisible == true {
            let hide = NSMenuItem()
            hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performTextFinderAction(hide)
        }
    }

    // Keymap bindings win over NSTextView's own: ⌘-chords arrive as key equivalents (before the main menu), the
    // rest as key-downs (before key binding interpretation).

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, performKeymapCommand(for: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if performKeymapCommand(for: event) { return }
        super.keyDown(with: event)
    }

    private func performKeymapCommand(for event: NSEvent) -> Bool {
        // Mid-composition, keys belong to the input method.
        guard !hasMarkedText(), let viewport, let command = viewport.keymap.command(for: event) else { return false }
        return viewport.perform(command: command)
    }

    private func withInputKind(_ kind: InputKind, _ body: () -> Void) {
        let outer = inputKind
        inputKind = kind
        defer { inputKind = outer }
        body()
    }

    // MARK: Pasteboard

    override func copy(_ sender: Any?) {
        guard let viewport, viewport.hasMultipleSelections else { return super.copy(sender) }
        writeToPasteboard(viewport.selectedText)
    }

    override func cut(_ sender: Any?) {
        guard let viewport, viewport.hasMultipleSelections else { return super.cut(sender) }
        writeToPasteboard(viewport.selectedText)
        viewport.deleteSelectedText()
    }

    override func paste(_ sender: Any?) {
        guard let viewport, viewport.hasMultipleSelections,
              let text = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        viewport.pasteAtSelections(text)
    }

    override func selectAll(_ sender: Any?) {
        viewport?.collapseSelections()
        super.selectAll(sender)
    }

    private func writeToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // Option+click adds a caret, or removes the selection there. This replaces NSTextView's Option-drag column
        // selection for now.
        if event.modifierFlags.intersection([.shift, .control, .option, .command]) == .option, event.clickCount == 1,
           let viewport {
            window?.makeFirstResponder(self)
            viewport.toggleCaret(atCharacterIndex: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Drawing secondary selections

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !secondarySelections.isEmpty, let layoutManager, let textContainer else { return }
        let isActive = window?.isKeyWindow == true && window?.firstResponder === self
        (isActive ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor).setFill()
        let origin = textContainerOrigin
        for range in secondarySelections where range.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                                  in: textContainer) { enclosing, _ in
                let enclosing = enclosing.offsetBy(dx: origin.x, dy: origin.y)
                if enclosing.intersects(rect) { enclosing.fill() }
            }
        }
    }

    private func updateSecondaryCarets() {
        let carets = secondarySelections.filter { $0.length == 0 }
        while secondaryCarets.count < carets.count {
            let indicator = NSTextInsertionIndicator(frame: .zero)
            addSubview(indicator)
            secondaryCarets.append(indicator)
        }
        while secondaryCarets.count > carets.count {
            secondaryCarets.removeLast().removeFromSuperview()
        }
        for (indicator, caret) in zip(secondaryCarets, carets) {
            indicator.frame = caretRect(at: caret.location)
        }
        updateCaretVisibility()
    }

    /// Where an insertion point at UTF-16 offset `index` is drawn, in view coordinates.
    private func caretRect(at index: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        var rect = NSRect.zero
        if index >= (textStorage?.length ?? 0), layoutManager.extraLineFragmentTextContainer != nil {
            // After a trailing newline: the empty last line has no glyphs.
            rect = layoutManager.extraLineFragmentRect
            rect.origin.x += textContainer.lineFragmentPadding
        } else {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 0),
                                                  actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                                  in: textContainer) { enclosing, stop in
                rect = enclosing
                stop.pointee = true
            }
        }
        rect.size.width = 1
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Secondary carets show only where the primary one would: in the key window's first responder.
    private func updateCaretVisibility() {
        let isActive = window?.isKeyWindow == true && window?.firstResponder === self
        for indicator in secondaryCarets {
            indicator.displayMode = isActive ? .automatic : .hidden
        }
    }

    override func becomeFirstResponder() -> Bool {
        defer { updateCaretVisibility(); setNeedsDisplay(visibleRect) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { updateCaretVisibility(); setNeedsDisplay(visibleRect) }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateDidChange(_:)),
                                                   name: name, object: window)
        }
    }

    @objc private func windowKeyStateDidChange(_ notification: Notification) {
        updateCaretVisibility()
        setNeedsDisplay(visibleRect)
    }
}
