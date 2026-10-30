//
//  EditorState.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-30.
//
//  The buffer plus its selections, and the edits and movements that act on every selection at once. Pure Swift,
//  no AppKit: the viewport feeds it input and mirrors the returned edits into its text storage.
//

import Foundation

nonisolated struct EditorState: Sendable {
    var buffer: TextBuffer
    var selections: SelectionSet
    /// The word "select next occurrence" started from a caret with, which it matches only as a whole word.
    private var wholeWordSearch: String?

    init(buffer: TextBuffer = TextBuffer(), selections: SelectionSet = SelectionSet()) {
        self.buffer = buffer
        self.selections = selections
    }

    enum Deletion: Sendable {
        case backward
        case forward
        case wordBackward
        case wordForward
        case toLineStart
    }

    enum Movement: Sendable {
        case left
        case right
        case wordLeft
        case wordRight
        case lineStart
        case lineEnd
        case up
        case down
        case documentStart
        case documentEnd
    }

    // MARK: Editing
    // Each returns the edits it made, in order (none if nothing changed). The whole call is one undo step.

    /// Types `text` at every selection.
    @discardableResult
    mutating func insert(_ text: String, coalesce: Bool = false) -> [BufferEdit] {
        replace(selections.items.map(\.range), with: Array(repeating: text, count: selections.count),
                primaryIndex: selections.primaryIndex, coalesce: coalesce)
    }

    /// Pastes `text` at every selection, or one line per selection when its line count matches theirs.
    @discardableResult
    mutating func paste(_ text: String) -> [BufferEdit] {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        let texts = selections.count > 1 && lines.count == selections.count
            ? lines
            : Array(repeating: text, count: selections.count)
        return replace(selections.items.map(\.range), with: texts, primaryIndex: selections.primaryIndex, coalesce: false)
    }

    /// Deletes every non-empty selection, and from each caret by `deletion`.
    @discardableResult
    mutating func delete(_ deletion: Deletion, coalesce: Bool = false) -> [BufferEdit] {
        let text = buffer.text
        let ranges = selections.items.map { selection -> Range<Int> in
            guard selection.isEmpty else { return selection.range }
            let offset = selection.head
            return switch deletion {
            case .backward: text.graphemeBoundaries(around: offset).before..<offset
            case .forward: offset..<text.graphemeBoundaries(around: offset).after
            case .wordBackward: text.wordBoundary(before: offset)..<offset
            case .wordForward: offset..<text.wordBoundary(after: offset)
            case .toLineStart:
                text.lineStart(of: offset) < offset
                    ? text.lineStart(of: offset)..<offset
                    : text.graphemeBoundaries(around: offset).before..<offset
            }
        }

        // Grown ranges can reach over their neighbors; merge them so each byte is deleted once.
        var merged: [Range<Int>] = []
        var primaryIndex = 0
        for (index, range) in ranges.enumerated().sorted(by: { $0.element.lowerBound < $1.element.lowerBound }) {
            if let last = merged.last, last.upperBound > range.lowerBound || last == range {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
            if index == selections.primaryIndex { primaryIndex = merged.count - 1 }
        }
        return replace(merged, with: Array(repeating: "", count: merged.count), primaryIndex: primaryIndex,
                       coalesce: coalesce)
    }

    /// The selected text, one selection per line. Empty selections contribute nothing.
    var selectedText: String {
        selections.items.filter { !$0.isEmpty }.map { buffer.text.string(in: $0.range) }.joined(separator: "\n")
    }

    /// Replaces `ranges` (sorted, non-overlapping) with `texts` front to back, shifting each range by what the edits
    /// before it added or removed, and leaves a caret after each replacement.
    private mutating func replace(_ ranges: [Range<Int>], with texts: [String], primaryIndex: Int,
                                  coalesce: Bool) -> [BufferEdit] {
        var edits: [BufferEdit] = []
        var carets: [Selection] = []
        buffer.transact(coalesce: coalesce) { buffer in
            var shift = 0
            for (range, text) in zip(ranges, texts) {
                let range = range.shifted(by: shift)
                guard !range.isEmpty || !text.isEmpty else {
                    carets.append(.caret(range.lowerBound))
                    continue
                }
                let edit = buffer.edit(range, with: text)
                shift += edit.newRange.count - edit.oldRange.count
                edits.append(edit)
                carets.append(.caret(edit.newRange.upperBound))
            }
        }
        selections = SelectionSet(carets, primaryIndex: primaryIndex)
        return edits
    }

    // MARK: Undo

    /// Undoes the last step and puts a caret at the end of each range it changed.
    @discardableResult
    mutating func undo() -> [BufferEdit]? { applyHistoryStep { $0.undo() } }

    @discardableResult
    mutating func redo() -> [BufferEdit]? { applyHistoryStep { $0.redo() } }

    private mutating func applyHistoryStep(_ step: (inout TextBuffer) -> [BufferEdit]?) -> [BufferEdit]? {
        guard let edits = step(&buffer) else { return nil }
        let changed = BufferEdit.replacements(for: edits, resultLength: buffer.text.utf8Count)
        selections = SelectionSet(changed.map { .caret($0.new.upperBound) }, primaryIndex: 0)
        return edits
    }

    // MARK: Line commands
    // Each acts on the whole lines any selection touches. Selections on the same or adjacent lines form one block,
    // which gets one edit; the selections move with their text.

    /// Swaps each block with the line above (or below). Blocks already at the edge stay put.
    @discardableResult
    mutating func moveLines(up: Bool) -> [BufferEdit] {
        editLineBlocks { rows, text in
            let lines = Self.span(of: rows, in: text)
            if up {
                guard rows.lowerBound > 0 else { return nil }
                let above = text.lineRange(rows.lowerBound - 1)
                return LineEdit(range: above.lowerBound..<lines.upperBound,
                                text: text.string(in: lines) + "\n" + text.string(in: above),
                                map: { $0 - (above.count + 1) })
            } else {
                guard rows.upperBound + 1 < text.lineCount else { return nil }
                let below = text.lineRange(rows.upperBound + 1)
                return LineEdit(range: lines.lowerBound..<below.upperBound,
                                text: text.string(in: below) + "\n" + text.string(in: lines),
                                // A selection ending at the start of the line below ends after the block, if anything.
                                map: { min($0 + below.count + 1, text.utf8Count) })
            }
        }
    }

    /// Copies each block below itself (selections move to the copy) or above itself (selections stay on the upper one).
    @discardableResult
    mutating func duplicateLines(down: Bool) -> [BufferEdit] {
        editLineBlocks { rows, text in
            let lines = Self.span(of: rows, in: text)
            let copy = text.string(in: lines)
            return down
                ? LineEdit(range: lines.upperBound..<lines.upperBound, text: "\n" + copy, map: { $0 + lines.count + 1 })
                : LineEdit(range: lines.lowerBound..<lines.lowerBound, text: copy + "\n", map: { $0 })
        }
    }

    /// Deletes each block's lines, leaving a caret where they were.
    @discardableResult
    mutating func deleteLines() -> [BufferEdit] {
        editLineBlocks { rows, text in
            let lines = Self.span(of: rows, in: text)
            let range = if rows.upperBound + 1 < text.lineCount {
                lines.lowerBound..<text.lineRange(rows.upperBound + 1).lowerBound  // with the line break after
            } else if rows.lowerBound > 0 {
                text.lineRange(rows.lowerBound - 1).upperBound..<lines.upperBound  // the last line: the break before
            } else {
                lines
            }
            return LineEdit(range: range, text: "", map: { _ in range.lowerBound })
        }
    }

    /// Adds `unit` before every non-empty line.
    @discardableResult
    mutating func indentLines(by unit: String = Self.indentUnit) -> [BufferEdit] {
        editLineBlocks { rows, text in
            Self.rewriteLines(rows, in: text) { lines in
                lines.map { $0.isEmpty ? ($0, { $0 }) : (Array(unit.utf8) + $0, Self.inserting(unit.utf8.count, at: 0)) }
            }
        }
    }

    /// Removes one tab, or up to one indent unit's width of spaces, from the start of every line.
    @discardableResult
    mutating func outdentLines(by unit: String = Self.indentUnit) -> [BufferEdit] {
        editLineBlocks { rows, text in
            Self.rewriteLines(rows, in: text) { lines in
                lines.map { line in
                    let count = line.first == 0x09 ? 1 : line.prefix(unit.utf8.count).prefix { $0 == 0x20 }.count
                    return (Array(line.dropFirst(count)), Self.removing(0..<count))
                }
            }
        }
    }

    /// Comments out each block with `token`, or uncomments it if every non-blank line already starts with it.
    /// Blank lines are left alone; new tokens line up at the block's smallest indentation.
    @discardableResult
    mutating func toggleLineComment(_ token: String) -> [BufferEdit] {
        let token = Array(token.utf8)
        return editLineBlocks { rows, text in
            Self.rewriteLines(rows, in: text) { lines in
                let indents = lines.map { line in line.prefix { $0 == 0x20 || $0 == 0x09 }.count }
                let nonBlank = lines.indices.filter { indents[$0] < lines[$0].count }
                guard !nonBlank.isEmpty else { return lines.map { ($0, { $0 }) } }

                if nonBlank.allSatisfy({ lines[$0][indents[$0]...].starts(with: token) }) {
                    return lines.indices.map { i in
                        guard nonBlank.contains(i) else { return (lines[i], { $0 }) }
                        let start = indents[i]
                        var end = start + token.count
                        if end < lines[i].count && lines[i][end] == 0x20 { end += 1 }
                        return (Array(lines[i][..<start] + lines[i][end...]), Self.removing(start..<end))
                    }
                }
                let column = nonBlank.map { indents[$0] }.min()!
                let inserted = token + [0x20]
                return lines.indices.map { i in
                    guard nonBlank.contains(i) else { return (lines[i], { $0 }) }
                    return (Array(lines[i][..<column] + inserted + lines[i][column...]), Self.inserting(inserted.count, at: column))
                }
            }
        }
    }

    /// Hardcoded until there are settings.
    static let indentUnit = "    "

    /// Adds a caret on the line above (or below) each selection's head, at its goal column. The one added for the
    /// primary selection becomes primary. Returns false if every selection was already on the first (last) line.
    @discardableResult
    mutating func addCursors(above: Bool) -> Bool {
        let text = buffer.text
        let carets = selections.items.indices.compactMap { index -> (Selection, isPrimary: Bool)? in
            let head = selections.items[index].head
            let row = text.point(at: head).row + (above ? -1 : 1)
            guard row >= 0 && row < text.lineCount else { return nil }
            let goal = selections.items[index].goalColumn ?? text.graphemeColumn(of: head)
            let offset = text.offset(row: row, graphemeColumn: goal)
            return (Selection(anchor: offset, head: offset, goalColumn: goal), index == selections.primaryIndex)
        }
        for (caret, isPrimary) in carets where !isPrimary { selections.add(caret) }
        for (caret, isPrimary) in carets where isPrimary { selections.add(caret) }
        return !carets.isEmpty
    }

    /// One block's replacement, and where an offset in or just after the block ends up, counting only this edit.
    private struct LineEdit {
        var range: Range<Int>
        var text: String
        var map: (Int) -> Int
    }

    /// Groups the selections into blocks of lines, then makes `plan`'s edit for each block front to back as one undo
    /// step, shifting later blocks by what earlier ones added or removed.
    private mutating func editLineBlocks(_ plan: (ClosedRange<Int>, Rope) -> LineEdit?) -> [BufferEdit] {
        let text = buffer.text
        let blocks = lineBlocks(in: text)
        let lineEdits = blocks.map { plan($0.rows, text) }
        var moved = selections.items
        var edits: [BufferEdit] = []
        buffer.transact { buffer in
            var shift = 0
            for (block, lineEdit) in zip(blocks, lineEdits) {
                let map = lineEdit?.map ?? { $0 }
                for index in block.selections {
                    let selection = moved[index]
                    moved[index] = Selection(anchor: map(selection.anchor) + shift, head: map(selection.head) + shift,
                                             goalColumn: selection.goalColumn)
                }
                // Skip blocks that wouldn't change, like a line moving past an identical one.
                guard let lineEdit, text.string(in: lineEdit.range) != lineEdit.text else { continue }
                let edit = buffer.edit(lineEdit.range.shifted(by: shift), with: lineEdit.text)
                shift += edit.newRange.count - edit.oldRange.count
                edits.append(edit)
            }
        }
        selections = SelectionSet(moved, primaryIndex: selections.primaryIndex)
        return edits
    }

    /// The rows each selection covers, merged where they share or touch lines. A non-empty selection ending at the
    /// start of a line doesn't cover that line.
    private func lineBlocks(in text: Rope) -> [(rows: ClosedRange<Int>, selections: [Int])] {
        var blocks: [(rows: ClosedRange<Int>, selections: [Int])] = []
        for (index, selection) in selections.items.enumerated() {
            let first = text.point(at: selection.range.lowerBound).row
            let end = text.point(at: selection.range.upperBound)
            let last = !selection.isEmpty && end.column == 0 && end.row > first ? end.row - 1 : end.row
            if let previous = blocks.last, first <= previous.rows.upperBound + 1 {
                blocks[blocks.count - 1].rows = previous.rows.lowerBound...max(previous.rows.upperBound, last)
                blocks[blocks.count - 1].selections.append(index)
            } else {
                blocks.append((first...last, [index]))
            }
        }
        return blocks
    }

    /// The bytes of `rows`, without the final line break.
    private static func span(of rows: ClosedRange<Int>, in text: Rope) -> Range<Int> {
        text.lineRange(rows.lowerBound).lowerBound..<text.lineRange(rows.upperBound).upperBound
    }

    /// An edit replacing `rows` line by line. `rewrite` returns each new line with a map from byte columns in the old
    /// line to the new one. Nil if nothing changes.
    private static func rewriteLines(_ rows: ClosedRange<Int>, in text: Rope,
                                     _ rewrite: ([[UInt8]]) -> [(line: [UInt8], column: (Int) -> Int)]) -> LineEdit? {
        let range = span(of: rows, in: text)
        let old = rows.map { Array(text.string(in: text.lineRange($0)).utf8) }
        let new = rewrite(old)
        guard new.map(\.line) != old else { return nil }

        var starts: [Int] = []  // where each new line starts, relative to the block
        var position = 0
        for line in new.map(\.line) {
            starts.append(position)
            position += line.count + 1
        }
        let replacement = String(decoding: Array(new.map(\.line).joined(separator: [0x0A])), as: UTF8.self)
        let growth = replacement.utf8.count - range.count
        return LineEdit(range: range, text: replacement) { offset in
            guard offset <= range.upperBound else { return offset + growth }  // just past the block
            let point = text.point(at: offset)
            let line = point.row - rows.lowerBound
            return range.lowerBound + starts[line] + new[line].column(point.column)
        }
    }

    /// A column map for inserting `count` bytes at `column`: positions at or after it move along.
    private static func inserting(_ count: Int, at column: Int) -> (Int) -> Int {
        { $0 < column ? $0 : $0 + count }
    }

    /// A column map for removing the bytes in `removed`: positions inside it go to its start.
    private static func removing(_ removed: Range<Int>) -> (Int) -> Int {
        { $0 <= removed.lowerBound ? $0 : $0 >= removed.upperBound ? $0 - removed.count : removed.lowerBound }
    }

    // MARK: Select next occurrence

    /// ⌘D. With an empty primary selection, selects the word around it. Otherwise adds the next occurrence of the
    /// primary's text after it as the new primary, wrapping around and skipping any that overlap a selection.
    /// Case-sensitive. Returns false if there was nothing to select.
    @discardableResult
    mutating func selectNextOccurrence() -> Bool {
        let text = buffer.text
        let primary = selections.primary
        guard !primary.isEmpty else {
            guard let word = text.wordRange(around: primary.head) else { return false }
            selections.replacePrimary(with: Selection(anchor: word.lowerBound, head: word.upperBound))
            wholeWordSearch = text.string(in: word)
            return true
        }

        let needle = text.string(in: primary.range)
        let wholeWord = needle == wholeWordSearch
        let bytes = Array(needle.utf8)
        for searchRange in [primary.range.upperBound..<text.utf8Count, 0..<primary.range.upperBound] {
            var start = searchRange.lowerBound
            while let match = text.firstRange(of: bytes, in: start..<searchRange.upperBound) {
                let candidate = Selection(anchor: match.lowerBound, head: match.upperBound)
                if (!wholeWord || text.isWholeWord(match))
                    && !selections.items.contains(where: { SelectionSet.overlap($0, candidate) }) {
                    selections.add(candidate)
                    return true
                }
                start = match.lowerBound + 1
            }
        }
        return false
    }

    // MARK: Movement

    /// Moves every selection's head, or collapses them to carets there unless `extending`.
    mutating func move(_ movement: Movement, extending: Bool) {
        let text = buffer.text
        selections.update { selection in
            var from = selection.head
            if !extending && !selection.isEmpty {
                // Without shift, a selection first collapses to the side being moved toward.
                switch movement {
                case .left: return .caret(selection.range.lowerBound)
                case .right: return .caret(selection.range.upperBound)
                case .up: from = selection.range.lowerBound
                case .down: from = selection.range.upperBound
                default: break
                }
            }
            let (head, goalColumn) = Self.target(of: movement, from: from, goalColumn: selection.goalColumn, in: text)
            return Selection(anchor: extending ? selection.anchor : head, head: head, goalColumn: goalColumn)
        }
    }

    /// Where `movement` takes a head at `offset`, and the goal column to keep (only vertical moves keep one).
    private static func target(of movement: Movement, from offset: Int, goalColumn: Int?,
                               in text: Rope) -> (offset: Int, goalColumn: Int?) {
        switch movement {
        case .left: return (text.graphemeBoundaries(around: offset).before, nil)
        case .right: return (text.graphemeBoundaries(around: offset).after, nil)
        case .wordLeft: return (text.wordBoundary(before: offset), nil)
        case .wordRight: return (text.wordBoundary(after: offset), nil)
        case .lineStart: return (text.lineStart(of: offset), nil)
        case .lineEnd: return (text.lineEnd(of: offset), nil)
        case .documentStart: return (0, nil)
        case .documentEnd: return (text.utf8Count, nil)
        case .up, .down:
            let goal = goalColumn ?? text.graphemeColumn(of: offset)
            let row = text.point(at: offset).row + (movement == .up ? -1 : 1)
            // Past the first or last line, go to the very start or end, like NSTextView.
            guard row >= 0 else { return (0, goal) }
            guard row < text.lineCount else { return (text.utf8Count, goal) }
            return (text.offset(row: row, graphemeColumn: goal), goal)
        }
    }
}

// MARK: - Text navigation

/// Line, grapheme, and word positions for editing. Only ever look at the line around an offset, so they stay cheap
/// in big files; very long lines cost proportionally.
nonisolated extension Rope {
    func lineStart(of offset: Int) -> Int {
        offset - point(at: offset).column
    }

    func lineEnd(of offset: Int) -> Int {
        lineRange(point(at: offset).row).upperBound
    }

    /// The nearest grapheme cluster boundaries strictly before and after `offset` (which may be inside a cluster),
    /// clamped to the text. A line break is a cluster of its own.
    func graphemeBoundaries(around offset: Int) -> (before: Int, after: Int) {
        let lineStart = lineStart(of: offset)
        let lineEnd = lineEnd(of: offset)
        // Context on both sides, so an offset inside a cluster still sees the whole cluster.
        let start = clipOffset(max(lineStart, offset - Self.graphemeContext), bias: .backward)
        let end = clipOffset(min(lineEnd, offset + Self.graphemeContext), bias: .forward)
        var before = offset > lineStart ? start : max(offset - 1, 0)
        var after = offset < lineEnd ? end : min(offset + 1, utf8Count)
        var position = start
        for character in string(in: start..<end) {
            let next = position + character.utf8.count
            if next < offset {
                before = next
            } else if next > offset {
                after = next
                break
            }
            position = next
        }
        return (before, after)
    }

    /// Bytes of context `graphemeBoundaries(around:)` reads each way; far longer than any real cluster.
    private static let graphemeContext = 128

    /// Grapheme clusters between the start of `offset`'s line and `offset`.
    func graphemeColumn(of offset: Int) -> Int {
        string(in: lineStart(of: offset)..<offset).count
    }

    /// The offset `column` grapheme clusters into line `row`, clamped to the line's end.
    func offset(row: Int, graphemeColumn column: Int) -> Int {
        let line = lineRange(row)
        var offset = line.lowerBound
        for character in string(in: line).prefix(column) {
            offset += character.utf8.count
        }
        return offset
    }

    /// The word (letters, digits, `_`) containing or touching `offset`, if any.
    func wordRange(around offset: Int) -> Range<Int>? {
        var lower = offset
        for character in string(in: lineStart(of: offset)..<offset).reversed() {
            guard WordClass(character) == .word else { break }
            lower -= character.utf8.count
        }
        var upper = offset
        for character in string(in: offset..<lineEnd(of: offset)) {
            guard WordClass(character) == .word else { break }
            upper += character.utf8.count
        }
        return lower < upper ? lower..<upper : nil
    }

    /// Whether `range` has no word character directly on either side.
    func isWholeWord(_ range: Range<Int>) -> Bool {
        let before = string(in: graphemeBoundaries(around: range.lowerBound).before..<range.lowerBound).last
        let after = string(in: range.upperBound..<graphemeBoundaries(around: range.upperBound).after).first
        return (before.map { WordClass($0) != .word } ?? true) && (after.map { WordClass($0) != .word } ?? true)
    }

    /// The start of the word (or run of punctuation) before `offset`, skipping whitespace. At a line's start, the
    /// end of the previous line.
    func wordBoundary(before offset: Int) -> Int {
        let lineStart = lineStart(of: offset)
        guard offset > lineStart else { return max(offset - 1, 0) }
        let characters = Array(string(in: lineStart..<offset))
        var end = characters.endIndex
        while end > 0, WordClass(characters[end - 1]) == .whitespace { end -= 1 }
        if end > 0 {
            let kind = WordClass(characters[end - 1])
            while end > 0, WordClass(characters[end - 1]) == kind { end -= 1 }
        }
        return lineStart + characters[..<end].reduce(0) { $0 + $1.utf8.count }
    }

    /// The end of the word (or run of punctuation) after `offset`, skipping whitespace. At a line's end, the start
    /// of the next line.
    func wordBoundary(after offset: Int) -> Int {
        let lineEnd = lineEnd(of: offset)
        guard offset < lineEnd else { return min(offset + 1, utf8Count) }
        let characters = Array(string(in: offset..<lineEnd))
        var start = 0
        while start < characters.count, WordClass(characters[start]) == .whitespace { start += 1 }
        if start < characters.count {
            let kind = WordClass(characters[start])
            while start < characters.count, WordClass(characters[start]) == kind { start += 1 }
        }
        return offset + characters[..<start].reduce(0) { $0 + $1.utf8.count }
    }
}

/// What word movement treats as one run. Language-agnostic for now.
nonisolated enum WordClass: Sendable {
    case whitespace
    case word
    case punctuation

    init(_ character: Character) {
        if character.isWhitespace {
            self = .whitespace
        } else if character.isLetter || character.isNumber || character == "_" {
            self = .word
        } else {
            self = .punctuation
        }
    }
}
