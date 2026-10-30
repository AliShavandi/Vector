//
//  EditingTests.swift
//  VectorTests
//
//  Created by Ali Shavandi on 2026-10-30.
//

import AppKit
import Testing
@testable import Vector

private func state(_ text: String, carets: [Int]) -> EditorState {
    EditorState(buffer: TextBuffer(text),
                selections: SelectionSet(carets.map(Selection.caret), primaryIndex: carets.count - 1))
}

private func pairs(_ selections: SelectionSet) -> [[Int]] {
    selections.items.map { [$0.anchor, $0.head] }
}

// MARK: - Selections

struct SelectionSetTests {
    @Test func normalizeSortsAndMergesOverlaps() {
        var set = SelectionSet(.caret(9))
        set.add(Selection(anchor: 2, head: 5))
        set.add(.caret(9))  // coincides with the first caret
        set.add(Selection(anchor: 6, head: 4))  // overlaps 2..<5; the earlier one's direction wins
        #expect(pairs(set) == [[2, 6], [9, 9]])
        #expect(set.primaryIndex == 0)

        set.add(Selection(anchor: 6, head: 8))  // only touches: stays separate
        #expect(pairs(set) == [[2, 6], [6, 8], [9, 9]])
        #expect(set.primary == Selection(anchor: 6, head: 8))
    }

    @Test func toggleCaretAddsAndRemoves() {
        var set = SelectionSet(.caret(3))
        set.toggleCaret(at: 3)  // the only selection is never removed
        #expect(pairs(set) == [[3, 3]])
        set.toggleCaret(at: 7)
        set.toggleCaret(at: 1)
        #expect(pairs(set) == [[1, 1], [3, 3], [7, 7]])
        #expect(set.primary == .caret(1))
        set.toggleCaret(at: 1)
        #expect(pairs(set) == [[3, 3], [7, 7]])
        #expect(set.primary == .caret(7))
        set.collapseToPrimary()
        #expect(pairs(set) == [[7, 7]])
    }
}

// MARK: - Editing

struct EditorStateTests {
    @Test func typingAtEveryCaretShiftsLaterOnes() {
        var editor = state("aé\nb😀\nc", carets: [1, 9, 11])
        let edits = editor.insert("中")
        #expect(editor.buffer.text.description == "a中é\nb😀中\nc中")
        #expect(pairs(editor.selections) == [[4, 4], [15, 15], [20, 20]])
        #expect(edits.map(\.oldRange) == [1..<1, 12..<12, 17..<17])

        editor.undo()
        #expect(editor.buffer.text.description == "aé\nb😀\nc")
        #expect(pairs(editor.selections) == [[1, 1], [9, 9], [11, 11]])  // every caret comes back
    }

    @Test func deleteBackwardRemovesWholeClusters() {
        let text = "xe\u{301}👩‍💻\ny"  // e+combining acute is 3 bytes, the ZWJ sequence 11
        var editor = state(text, carets: [4, 15, 16])  // after é, after 👩‍💻, at the start of line 2
        editor.delete(.backward)
        #expect(editor.buffer.text.description == "xy")
        #expect(pairs(editor.selections) == [[1, 1]])

        // A caret inside a cluster deletes back to the cluster's start, forward to its end.
        var inside = state("👩‍💻", carets: [4])
        inside.delete(.forward)
        #expect(inside.buffer.text.description == "👩")
        inside = state("👩‍💻", carets: [4])
        inside.delete(.backward)
        #expect(inside.buffer.text.description == "\u{200D}💻")
    }

    @Test func overlappingDeletionsMerge() {
        var editor = EditorState(buffer: TextBuffer("abcdef"),
                                 selections: SelectionSet([Selection(anchor: 1, head: 3), .caret(4)], primaryIndex: 1))
        editor.delete(.wordBackward)  // the caret's word reaches back over the selection
        #expect(editor.buffer.text.description == "ef")
        #expect(pairs(editor.selections) == [[0, 0]])
        #expect(editor.buffer.canUndo)
        editor.undo()
        #expect(editor.buffer.text.description == "abcdef")
        #expect(!editor.buffer.canUndo)  // one step
    }

    @Test func noOpDeletesMakeNoUndoStep() {
        var editor = state("ab", carets: [0])
        #expect(editor.delete(.backward).isEmpty)
        #expect(!editor.buffer.canUndo)
    }

    @Test func pasteDistributesLinesWhenCountsMatch() {
        var editor = state("a\nb\nc", carets: [1, 3, 5])
        editor.paste("1\r\n2\n3\n")
        #expect(editor.buffer.text.description == "a1\nb2\nc3")

        editor = state("a\nb", carets: [1, 3])
        editor.paste("x\ny\nz")
        #expect(editor.buffer.text.description == "ax\ny\nz\nbx\ny\nz")
    }

    @Test func selectedTextJoinsSelections() {
        let editor = EditorState(buffer: TextBuffer("one two three"), selections: SelectionSet(
            [Selection(anchor: 0, head: 3), .caret(5), Selection(anchor: 13, head: 8)], primaryIndex: 0))
        #expect(editor.selectedText == "one\nthree")
    }

    @Test func wordMovement() {
        let text = Rope("  foo.bar(baz_1)  \nnext")
        var offset = 0
        var stops: [Int] = []
        while offset < text.utf8Count {
            offset = text.wordBoundary(after: offset)
            stops.append(offset)
        }
        #expect(stops == [5, 6, 9, 10, 15, 16, 18, 19, 23])
        #expect(text.wordBoundary(before: 15) == 10)
        #expect(text.wordBoundary(before: 18) == 15)
        #expect(text.wordBoundary(before: 19) == 18)
        #expect(text.wordBoundary(before: 2) == 0)
    }

    @Test func verticalMovementKeepsGoalColumn() {
        var editor = state("abcdef\nab\n中文中文中文", carets: [5])
        editor.move(.down, extending: false)
        #expect(pairs(editor.selections) == [[9, 9]])  // clamped to the short line's end
        editor.move(.down, extending: false)
        #expect(pairs(editor.selections) == [[25, 25]])  // back to column 5, in 3-byte characters
        editor.move(.up, extending: true)
        #expect(pairs(editor.selections) == [[25, 9]])
        editor.move(.down, extending: true)
        editor.move(.down, extending: false)  // past the last line: to the end
        #expect(pairs(editor.selections) == [[28, 28]])
        editor.move(.left, extending: false)
        #expect(editor.selections.primary.goalColumn == nil)
    }

    @Test func selectNextOccurrenceStartsWithTheWordThenMatchesWholeWords() {
        var editor = state("foo food foo.bar\nfoo", carets: [1])
        var found: Bool
        found = editor.selectNextOccurrence()
        #expect(found)
        #expect(pairs(editor.selections) == [[0, 3]])  // the word under the caret, no new cursor
        found = editor.selectNextOccurrence()
        #expect(found)
        #expect(pairs(editor.selections) == [[0, 3], [9, 12]])  // skips "food": whole words only
        found = editor.selectNextOccurrence()
        #expect(found)
        #expect(pairs(editor.selections) == [[0, 3], [9, 12], [17, 20]])
        found = editor.selectNextOccurrence()  // wrapped around; all taken
        #expect(!found)
        #expect(editor.selections.primary == Selection(anchor: 17, head: 20))

        editor.insert("x")
        #expect(editor.buffer.text.description == "x food x.bar\nx")
        editor.undo()  // selecting made no undo steps; the edit is one
        #expect(editor.buffer.text.description == "foo food foo.bar\nfoo")
        #expect(!editor.buffer.canUndo)
    }

    @Test func selectNextOccurrenceOfASelectionMatchesSubstringsAndWraps() {
        var found: Bool
        var editor = EditorState(buffer: TextBuffer("aXa aXa"), selections: SelectionSet(Selection(anchor: 4, head: 6)))
        found = editor.selectNextOccurrence()  // "aX" from a hand-made selection: substrings count, search wraps
        #expect(found)
        #expect(pairs(editor.selections) == [[0, 2], [4, 6]])
        #expect(editor.selections.primary == Selection(anchor: 0, head: 2))

        var adjacent = EditorState(buffer: TextBuffer("aaaa"), selections: SelectionSet(Selection(anchor: 0, head: 2)))
        found = adjacent.selectNextOccurrence()
        #expect(found)
        #expect(pairs(adjacent.selections) == [[0, 2], [2, 4]])  // touching matches stay separate
        found = adjacent.selectNextOccurrence()
        #expect(!found)

        var blank = state("a  b", carets: [2])
        found = blank.selectNextOccurrence()  // no word at the caret
        #expect(!found)
    }

    @Test func movingWithoutShiftCollapsesToTheSideMovedToward() {
        var editor = EditorState(buffer: TextBuffer("hello world"),
                                 selections: SelectionSet(Selection(anchor: 8, head: 2)))
        editor.move(.left, extending: false)
        #expect(pairs(editor.selections) == [[2, 2]])
        editor.selections = SelectionSet(Selection(anchor: 8, head: 2))
        editor.move(.right, extending: false)
        #expect(pairs(editor.selections) == [[8, 8]])
    }
}

// MARK: - Line commands

struct LineCommandTests {
    @Test func moveLinesAcrossTheLastLine() {
        var editor = state("one\ntwo\nthree", carets: [9])  // in "three", which has no trailing newline
        editor.moveLines(up: true)
        #expect(editor.buffer.text.description == "one\nthree\ntwo")
        #expect(pairs(editor.selections) == [[5, 5]])  // same column, one line up
        editor.moveLines(up: false)
        #expect(editor.buffer.text.description == "one\ntwo\nthree")
        #expect(pairs(editor.selections) == [[9, 9]])
        let edits = editor.moveLines(up: false)  // already last: nothing happens
        #expect(edits.isEmpty)
        editor.undo()
        #expect(editor.buffer.text.description == "one\nthree\ntwo")
    }

    @Test func blocksMoveTogetherAndSelectionsEndingAtColumnZeroLeaveThatLineOut() {
        // "b\nc\n" selected up to the start of "d", plus a caret on "d": touching blocks merge, so b–d move as one.
        var editor = EditorState(buffer: TextBuffer("a\nb\nc\nd\ne"),
                                 selections: SelectionSet([Selection(anchor: 2, head: 6), .caret(6)], primaryIndex: 0))
        editor.moveLines(up: false)
        #expect(editor.buffer.text.description == "a\ne\nb\nc\nd")

        editor = EditorState(buffer: TextBuffer("a\nb\nc\nd"), selections: SelectionSet(Selection(anchor: 2, head: 6)))
        editor.moveLines(up: true)  // just "b\nc"; "d" (where the selection ends) stays
        #expect(editor.buffer.text.description == "b\nc\na\nd")
        #expect(pairs(editor.selections) == [[0, 4]])
    }

    @Test func movingDownOntoTheLastLineKeepsSelectionsInBounds() {
        // "b\n" selected: it ends at the start of the last line, which then moves above it.
        var editor = EditorState(buffer: TextBuffer("a\nb\nc"), selections: SelectionSet(Selection(anchor: 2, head: 4)))
        editor.moveLines(up: false)
        #expect(editor.buffer.text.description == "a\nc\nb")
        #expect(pairs(editor.selections) == [[4, 5]])
    }

    @Test func duplicateAndDeleteLines() {
        var editor = state("ab\ncd", carets: [1])
        editor.duplicateLines(down: true)
        #expect(editor.buffer.text.description == "ab\nab\ncd")
        #expect(pairs(editor.selections) == [[4, 4]])  // on the copy
        editor.duplicateLines(down: false)
        #expect(editor.buffer.text.description == "ab\nab\nab\ncd")
        #expect(pairs(editor.selections) == [[4, 4]])  // stays on the upper of the two

        editor = state("ab\ncd\nef", carets: [7])
        editor.deleteLines()  // the last line takes the break before it
        #expect(editor.buffer.text.description == "ab\ncd")
        #expect(pairs(editor.selections) == [[5, 5]])
        editor = state("ab\ncd\nef", carets: [1, 4])
        editor.deleteLines()
        #expect(editor.buffer.text.description == "ef")
        #expect(pairs(editor.selections) == [[0, 0]])
        editor.deleteLines()
        #expect(editor.buffer.text.description == "")
    }

    @Test func toggleLineCommentAlignsAndRoundTrips() {
        let original = "    if x {\n        y()\n\n    }"
        var editor = EditorState(buffer: TextBuffer(original),
                                 selections: SelectionSet(Selection(anchor: 0, head: original.utf8.count)))
        editor.toggleLineComment("//")
        #expect(editor.buffer.text.description == "    // if x {\n    //     y()\n\n    // }")
        editor.toggleLineComment("//")
        #expect(editor.buffer.text.description == original)

        // Mixed: one line not commented, so the block gets commented (again).
        editor = state("// a\nb", carets: [0, 5])
        editor.toggleLineComment("//")
        #expect(editor.buffer.text.description == "// // a\n// b")
    }

    @Test func indentAndOutdent() {
        var editor = state("a\n\n\tb\n  c", carets: [1, 2, 4, 8])
        editor.indentLines()
        #expect(editor.buffer.text.description == "    a\n\n    \tb\n      c")  // the empty line stays empty
        #expect(pairs(editor.selections) == [[5, 5], [6, 6], [12, 12], [20, 20]])
        editor.outdentLines()
        editor.outdentLines()
        #expect(editor.buffer.text.description == "a\n\nb\nc")
    }

    @Test func addCursorsAboveAndBelowKeepTheColumn() {
        var editor = state("abcdef\nab\nabcdef", carets: [5])
        editor.addCursors(above: false)
        #expect(pairs(editor.selections) == [[5, 5], [9, 9]])
        editor.addCursors(above: false)
        #expect(pairs(editor.selections) == [[5, 5], [9, 9], [15, 15]])  // the short line didn't lose the column
        #expect(editor.selections.primary == Selection(anchor: 15, head: 15, goalColumn: 5))
        let added = editor.addCursors(above: true)
        #expect(added)
        // From 15 (goal 5) onto the existing caret at 9; from 9, which lost its goal merging, column 2 of line 1.
        #expect(pairs(editor.selections) == [[2, 2], [5, 5], [9, 9], [15, 15]])
    }
}

struct KeymapTests {
    @Test func chordsParse() {
        #expect(KeyChord("cmd+shift+k") == KeyChord(key: "k", modifiers: [.command, .shift]))
        #expect(KeyChord("Alt+Up") == KeyChord(key: "up", modifiers: .option))
        #expect(KeyChord("cmd+/") == KeyChord(key: "/", modifiers: .command))
        #expect(KeyChord("cmd++") == KeyChord(key: "+", modifiers: .command))
        #expect(KeyChord("hyper+k") == nil)
        #expect(KeyChord("cmd+") == nil)
    }

    @Test func eventsMatchBindings() throws {
        let keymap = Keymap(DefaultKeymap.bindings)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        // Arrow events carry function-key and numeric-pad flags too; only the four modifiers count.
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .function, .numericPad], timestamp: 0,
            windowNumber: 0, context: nil, characters: up, charactersIgnoringModifiers: up, isARepeat: false,
            keyCode: 126))
        #expect(keymap.command(for: event) == "editor.moveLineUp")
        #expect(keymap.command(for: KeyChord(key: "up", modifiers: [.option, .shift])) == "editor.duplicateLineUp")
        #expect(keymap.command(for: KeyChord(key: "up", modifiers: [])) == nil)
    }
}

// MARK: - Randomized comparison

/// A naive model of the same editor: a byte array and plain selections, edited back to front with expected carets
/// counted afterwards (where the engine goes front to back with a running shift), and grapheme boundaries taken
/// from segmenting the whole document.
private struct ReferenceEditor {
    struct Sel: Equatable {
        var anchor: Int
        var head: Int
        var goal: Int?
        var lower: Int { min(anchor, head) }
        var upper: Int { max(anchor, head) }
    }

    var bytes: [UInt8]
    var selections: [Sel]

    var string: String { String(decoding: bytes, as: UTF8.self) }

    var graphemeBoundaries: [Int] {
        var result = [0]
        var offset = 0
        for character in string {
            offset += character.utf8.count
            result.append(offset)
        }
        return result
    }

    func lineStart(_ offset: Int) -> Int {
        (bytes[..<offset].lastIndex(of: 0x0A)).map { $0 + 1 } ?? 0
    }

    func lineEnd(_ offset: Int) -> Int {
        bytes[offset...].firstIndex(of: 0x0A) ?? bytes.count
    }

    static func normalized(_ selections: [Sel]) -> [Sel] {
        var items = selections.sorted { ($0.lower, $0.upper, $0.head < $0.anchor ? 1 : 0) < ($1.lower, $1.upper, $1.head < $1.anchor ? 1 : 0) }
        var i = 0
        while i + 1 < items.count {
            let a = items[i], b = items[i + 1]
            let overlaps = (a.lower, a.upper) == (b.lower, b.upper) || (a.lower < b.upper && b.lower < a.upper)
            if overlaps {
                let lower = min(a.lower, b.lower), upper = max(a.upper, b.upper)
                items[i] = a.head < a.anchor ? Sel(anchor: upper, head: lower) : Sel(anchor: lower, head: upper)
                items.remove(at: i + 1)
            } else {
                i += 1
            }
        }
        return items
    }

    /// Replaces `ranges` (sorted, disjoint) back to front; returns whether anything changed.
    mutating func replace(_ ranges: [Range<Int>], with texts: [String]) -> Bool {
        var changed = false
        for (range, text) in zip(ranges, texts).reversed() where !(range.isEmpty && text.isEmpty) {
            bytes.replaceSubrange(range, with: Array(text.utf8))
            changed = true
        }
        var carets: [Sel] = []
        var growth = 0
        for (range, text) in zip(ranges, texts) {
            let caret = range.lowerBound + growth + text.utf8.count
            carets.append(Sel(anchor: caret, head: caret))
            growth += text.utf8.count - range.count
        }
        selections = Self.normalized(carets)
        return changed
    }

    mutating func insert(_ text: String) -> Bool {
        replace(selections.map { $0.lower..<$0.upper }, with: Array(repeating: text, count: selections.count))
    }

    mutating func paste(_ text: String) -> Bool {
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        let texts = selections.count > 1 && lines.count == selections.count ? lines : Array(repeating: text, count: selections.count)
        return replace(selections.map { $0.lower..<$0.upper }, with: texts)
    }

    mutating func delete(forward: Bool) -> Bool {
        let boundaries = graphemeBoundaries
        var ranges = selections.map { sel -> Range<Int> in
            guard sel.anchor == sel.head else { return sel.lower..<sel.upper }
            return forward
                ? sel.head..<(boundaries.first { $0 > sel.head } ?? sel.head)
                : (boundaries.last { $0 < sel.head } ?? sel.head)..<sel.head
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var i = 0
        while i + 1 < ranges.count {
            if ranges[i].upperBound > ranges[i + 1].lowerBound || ranges[i] == ranges[i + 1] {
                ranges[i] = ranges[i].lowerBound..<max(ranges[i].upperBound, ranges[i + 1].upperBound)
                ranges.remove(at: i + 1)
            } else {
                i += 1
            }
        }
        return replace(ranges, with: Array(repeating: "", count: ranges.count))
    }

    func row(_ offset: Int) -> Int { bytes[..<offset].count(where: { $0 == 0x0A }) }

    func column(_ offset: Int) -> Int {
        String(decoding: bytes[lineStart(offset)..<offset], as: UTF8.self).count
    }

    mutating func move(_ movement: EditorState.Movement, extending: Bool) {
        let boundaries = graphemeBoundaries
        let lineStarts = [0] + bytes.indices.filter { bytes[$0] == 0x0A }.map { $0 + 1 }
        selections = Self.normalized(selections.map { sel in
            var from = sel.head
            if !extending && sel.anchor != sel.head {
                switch movement {
                case .left: return Sel(anchor: sel.lower, head: sel.lower)
                case .right: return Sel(anchor: sel.upper, head: sel.upper)
                case .up: from = sel.lower
                case .down: from = sel.upper
                default: break
                }
            }
            var goal: Int?
            let head: Int
            switch movement {
            case .left: head = boundaries.last { $0 < from } ?? 0
            case .right: head = boundaries.first { $0 > from } ?? bytes.count
            case .lineStart: head = lineStart(from)
            case .lineEnd: head = lineEnd(from)
            case .documentStart: head = 0
            case .documentEnd: head = bytes.count
            case .up, .down:
                goal = sel.goal ?? column(from)
                let target = row(from) + (movement == .up ? -1 : 1)
                if target < 0 {
                    head = 0
                } else if target >= lineStarts.count {
                    head = bytes.count
                } else {
                    let start = lineStarts[target]
                    let line = String(decoding: bytes[start..<lineEnd(start)], as: UTF8.self)
                    head = start + line.prefix(goal!).utf8.count
                }
            case .wordLeft, .wordRight:
                fatalError("word movement isn't modeled")
            }
            return Sel(anchor: extending ? sel.anchor : head, head: head, goal: goal)
        })
    }

    // MARK: Line commands, modeled on an array of lines with (row, byte column) positions

    struct Position {
        var row: Int
        var column: Int
    }

    enum LineCommand: CaseIterable {
        case moveUp, moveDown, duplicateDown, duplicateUp, delete, indent, outdent, comment
    }

    func position(_ offset: Int) -> Position {
        Position(row: row(offset), column: offset - lineStart(offset))
    }

    /// Applies `command` block by block, front to back, tracking how many rows earlier blocks added or removed.
    mutating func perform(_ command: LineCommand) -> Bool {
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        var anchors = selections.map { position($0.anchor) }
        var heads = selections.map { position($0.head) }

        // Blocks: rows per selection (a selection ending at column 0 of a later row leaves that row out), merged
        // when they share or touch rows.
        var blocks: [(first: Int, last: Int, members: [Int])] = []
        for (i, sel) in selections.enumerated() {
            let first = position(sel.lower).row
            let end = position(sel.upper)
            let last = sel.lower != sel.upper && end.column == 0 && end.row > first ? end.row - 1 : end.row
            if let previous = blocks.last, first <= previous.last + 1 {
                blocks[blocks.count - 1].last = max(previous.last, last)
                blocks[blocks.count - 1].members.append(i)
            } else {
                blocks.append((first, last, [i]))
            }
        }

        var rowShift = 0
        for block in blocks {
            let a = block.first + rowShift, b = block.last + rowShift, count = b - a + 1
            var map: (Position) -> Position = { $0 }
            for i in block.members {
                anchors[i].row += rowShift
                heads[i].row += rowShift
            }
            switch command {
            case .moveUp where a > 0:
                lines.insert(lines.remove(at: a - 1), at: b)
                map = { Position(row: $0.row - 1, column: $0.column) }
            case .moveDown where b + 1 < lines.count:
                lines.insert(lines.remove(at: b + 1), at: a)
                let lastRow = lines.count - 1, lastLength = lines[lastRow].count
                map = { $0.row + 1 > lastRow ? Position(row: lastRow, column: lastLength) : Position(row: $0.row + 1, column: $0.column) }
            case .duplicateDown:
                lines.insert(contentsOf: lines[a...b], at: b + 1)
                map = { Position(row: $0.row + count, column: $0.column) }
                rowShift += count
            case .duplicateUp:
                lines.insert(contentsOf: lines[a...b], at: a)
                rowShift += count
            case .delete:
                lines.removeSubrange(a...b)
                let caret: Position
                if a < lines.count {
                    caret = Position(row: a, column: 0)
                } else if a > 0 {
                    caret = Position(row: a - 1, column: lines[a - 1].count)
                } else {
                    lines = [[]]
                    caret = Position(row: 0, column: 0)
                }
                map = { _ in caret }
                rowShift -= count
            case .indent, .outdent, .comment:
                var columnMaps: [Int: (Int) -> Int] = [:]
                let indents = (a...b).map { r in lines[r].prefix { $0 == 0x20 || $0 == 0x09 }.count }
                let nonBlank = (a...b).filter { indents[$0 - a] < lines[$0].count }
                let token = Array("//".utf8)
                let uncomment = !nonBlank.isEmpty && nonBlank.allSatisfy { lines[$0][indents[$0 - a]...].starts(with: token) }
                let commentColumn = nonBlank.map { indents[$0 - a] }.min() ?? 0
                for r in a...b {
                    let line = lines[r]
                    switch command {
                    case .indent where !line.isEmpty:
                        lines[r] = Array("    ".utf8) + line
                        columnMaps[r] = { $0 + 4 }
                    case .outdent:
                        let k = line.first == 0x09 ? 1 : line.prefix(4).prefix { $0 == 0x20 }.count
                        lines[r] = Array(line.dropFirst(k))
                        columnMaps[r] = { max($0 - k, 0) }
                    case .comment where nonBlank.contains(r):
                        if uncomment {
                            let start = indents[r - a]
                            let k = token.count + (line.count > start + token.count && line[start + token.count] == 0x20 ? 1 : 0)
                            lines[r] = Array(line[..<start] + line[(start + k)...])
                            columnMaps[r] = { $0 <= start ? $0 : max($0 - k, start) }
                        } else {
                            lines[r] = Array(line[..<commentColumn] + token + [0x20] + line[commentColumn...])
                            columnMaps[r] = { $0 < commentColumn ? $0 : $0 + 3 }
                        }
                    default:
                        break
                    }
                }
                map = { p in Position(row: p.row, column: columnMaps[p.row].map { $0(p.column) } ?? p.column) }
            default:
                break
            }
            for i in block.members {
                anchors[i] = map(anchors[i])
                heads[i] = map(heads[i])
            }
        }

        let old = bytes
        bytes = Array(lines.joined(separator: [0x0A]))
        func offset(_ p: Position) -> Int { lines[..<p.row].reduce(0) { $0 + $1.count + 1 } + p.column }
        selections = Self.normalized(selections.indices.map {
            Sel(anchor: offset(anchors[$0]), head: offset(heads[$0]), goal: selections[$0].goal)
        })
        return bytes != old
    }

    /// A caret on the line above or below each head, at its goal column (or current column).
    mutating func addCursors(above: Bool) {
        let lineStarts = [0] + bytes.indices.filter { bytes[$0] == 0x0A }.map { $0 + 1 }
        var added = selections
        for sel in selections {
            let target = row(sel.head) + (above ? -1 : 1)
            guard target >= 0 && target < lineStarts.count else { continue }
            let goal = sel.goal ?? column(sel.head)
            let start = lineStarts[target]
            let caret = start + String(decoding: bytes[start..<lineEnd(start)], as: UTF8.self).prefix(goal).utf8.count
            added.append(Sel(anchor: caret, head: caret, goal: goal))
        }
        selections = Self.normalized(added)
    }
}

private func expectInvariants(_ editor: EditorState, label: String = "",
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
    let items = editor.selections.items
    let text = editor.buffer.text
    try text.checkInvariants()
    #expect(editor.selections.primaryIndex < items.count, sourceLocation: sourceLocation)
    for selection in items {
        try #require(selection.anchor <= text.utf8Count && selection.head <= text.utf8Count, "\(label): selection past the end",
                     sourceLocation: sourceLocation)
        #expect(text.isScalarBoundary(selection.anchor) && text.isScalarBoundary(selection.head), sourceLocation: sourceLocation)
    }
    for (a, b) in zip(items, items.dropFirst()) {
        #expect(a.range.lowerBound <= b.range.lowerBound && !SelectionSet.overlap(a, b), sourceLocation: sourceLocation)
    }
}

/// Replays `edits` the way the viewport mirrors them into NSTextStorage: UTF-16 replacements on the old string.
private func expectStorageMirror(_ edits: [BufferEdit], from previous: Rope, to current: Rope,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
    let storage = NSMutableString(string: previous.description)
    for (old, new) in BufferEdit.replacements(for: edits, resultLength: current.utf8Count).reversed() {
        let lower = previous.utf16Offset(at: old.lowerBound)
        let upper = previous.utf16Offset(at: old.upperBound)
        storage.replaceCharacters(in: NSRange(location: lower, length: upper - lower), with: current.string(in: new))
    }
    #expect(storage as String == current.description, sourceLocation: sourceLocation)
}

/// Text with clusters that span several scalars, so cluster-aware deletion and movement get exercised.
private let editingSnippets = ["a", "b", " ", "\n", "é", "中", "😀", "e\u{301}", "👩‍💻", "x\ny", "_9", "."]

struct EditingRandomizedTests {
    @Test(arguments: [30, 31, 32, 33] as [UInt64])
    func multiCursorEditsMatchReference(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        let initial = (0..<60).map { _ in editingSnippets.randomElement(using: &rng)! }.joined()
        var editor = EditorState(buffer: TextBuffer(initial))
        var reference = ReferenceEditor(bytes: Array(initial.utf8), selections: [.init(anchor: 0, head: 0)])
        var undoSnapshots: [[UInt8]] = []
        var redoSnapshots: [[UInt8]] = []

        for step in 0..<1_500 {
            let previous = editor.buffer.text
            let before = reference.bytes
            let roll = Int.random(in: 0..<120, using: &rng)
            var edits: [BufferEdit]?
            var changed = false
            var label = "roll \(roll)"

            switch roll {
            case 0..<12:  // add a caret somewhere
                let offset = previous.clipOffset(Int.random(in: 0...previous.utf8Count, using: &rng), bias: .backward)
                editor.selections.add(.caret(offset))
                reference.selections = ReferenceEditor.normalized(reference.selections + [.init(anchor: offset, head: offset)])
            case 12..<16:  // add a selection
                let a = previous.clipOffset(Int.random(in: 0...previous.utf8Count, using: &rng), bias: .backward)
                let b = previous.clipOffset(Int.random(in: 0...previous.utf8Count, using: &rng), bias: .backward)
                editor.selections.add(Selection(anchor: a, head: b))
                reference.selections = ReferenceEditor.normalized(reference.selections + [.init(anchor: a, head: b)])
            case 16..<40:
                let snippet = editingSnippets.randomElement(using: &rng)!
                edits = editor.insert(snippet)
                changed = reference.insert(snippet)
            case 40..<52:
                edits = editor.delete(.backward)
                changed = reference.delete(forward: false)
            case 52..<58:
                edits = editor.delete(.forward)
                changed = reference.delete(forward: true)
            case 58..<62:
                let count = Int.random(in: 0..<2, using: &rng) == 0 ? editor.selections.count : 2
                let clip = (0..<count).map { _ in editingSnippets.randomElement(using: &rng)!.replacingOccurrences(of: "\n", with: "") }
                    .joined(separator: "\n")
                edits = editor.paste(clip)
                changed = reference.paste(clip)
            case 62..<80:
                let movements: [EditorState.Movement] = [.left, .right, .lineStart, .lineEnd, .up, .down, .documentStart, .documentEnd]
                let movement = movements.randomElement(using: &rng)!
                let extending = Bool.random(using: &rng)
                editor.move(movement, extending: extending)
                reference.move(movement, extending: extending)
            case 80..<84:  // word movement isn't modeled; check direction and take the engine's result
                let left = Bool.random(using: &rng)
                let heads = editor.selections.items.map(\.head)
                editor.move(left ? .wordLeft : .wordRight, extending: false)
                for selection in editor.selections.items {
                    #expect(heads.contains { left ? $0 >= selection.head : $0 <= selection.head })
                }
                reference.selections = editor.selections.items.map { .init(anchor: $0.anchor, head: $0.head, goal: $0.goalColumn) }
            case 84..<87:
                editor.selections.collapseToPrimary()
                let primary = editor.selections.primary
                reference.selections = [.init(anchor: primary.anchor, head: primary.head, goal: primary.goalColumn)]
            case 87..<103:
                let command = ReferenceEditor.LineCommand.allCases.randomElement(using: &rng)!
                edits = switch command {
                case .moveUp: editor.moveLines(up: true)
                case .moveDown: editor.moveLines(up: false)
                case .duplicateDown: editor.duplicateLines(down: true)
                case .duplicateUp: editor.duplicateLines(down: false)
                case .delete: editor.deleteLines()
                case .indent: editor.indentLines()
                case .outdent: editor.outdentLines()
                case .comment: editor.toggleLineComment("//")
                }
                changed = reference.perform(command)
                label = "\(command)"
            case 103..<107:
                let above = Bool.random(using: &rng)
                editor.addCursors(above: above)
                reference.addCursors(above: above)
            case 107..<116:  // undo and redo place carets themselves; check they're sane and take them
                let snapshot = undoSnapshots.popLast()
                edits = editor.undo()
                #expect((edits != nil) == (snapshot != nil))
                if let snapshot {
                    redoSnapshots.append(reference.bytes)
                    reference.bytes = snapshot
                }
                reference.selections = editor.selections.items.map { .init(anchor: $0.anchor, head: $0.head, goal: $0.goalColumn) }
            default:
                let snapshot = redoSnapshots.popLast()
                edits = editor.redo()
                #expect((edits != nil) == (snapshot != nil))
                if let snapshot {
                    undoSnapshots.append(reference.bytes)
                    reference.bytes = snapshot
                }
                reference.selections = editor.selections.items.map { .init(anchor: $0.anchor, head: $0.head, goal: $0.goalColumn) }
            }

            if roll < 107, edits != nil {
                // A new edit step: undoable as one step, and it clears redo.
                #expect(edits!.isEmpty == !changed, "step \(step): edit/no-op mismatch")
                if changed {
                    undoSnapshots.append(before)
                    redoSnapshots.removeAll()
                }
            }

            try #require(Array(editor.buffer.text.description.utf8) == reference.bytes, "step \(step) (\(label)): text diverged")
            let actual = editor.selections.items.map { ReferenceEditor.Sel(anchor: $0.anchor, head: $0.head, goal: $0.goalColumn) }
            try #require(actual == reference.selections, "step \(step) (\(label)): selections diverged")
            try expectInvariants(editor, label: "step \(step) (\(label))")
            if let edits {
                expectStorageMirror(edits, from: previous, to: editor.buffer.text)
            }
            #expect(editor.buffer.canUndo == !undoSnapshots.isEmpty)
            #expect(editor.buffer.canRedo == !redoSnapshots.isEmpty)
        }
    }
}
