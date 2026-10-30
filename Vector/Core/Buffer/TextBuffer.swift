//
//  TextBuffer.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-25.
//
//  The editing model the rest of the app talks to: a Rope plus versioning, undo/redo, and the edit records
//  tree-sitter and LSP need. Selections and cursors live in the view layer, not here.
//

import Foundation

nonisolated enum LineEnding: Sendable {
    case lf
    case crlf
}

nonisolated enum TextBufferError: Error {
    case invalidUTF8
}

/// One replacement, described in every coordinate system a consumer needs: byte ranges and points for
/// tree-sitter's `ts_tree_edit`, UTF-16 positions for an LSP incremental `didChange`. New text can be read from
/// the buffer at `newRange`.
nonisolated struct BufferEdit: Hashable, Sendable {
    var oldRange: Range<Int>
    var newRange: Range<Int>
    var startPoint: Point
    var oldEndPoint: Point
    var newEndPoint: Point
    var startPointUTF16: PointUTF16
    var oldEndPointUTF16: PointUTF16
    var newEndPointUTF16: PointUTF16

    var oldRangeUTF16: Range<PointUTF16> { startPointUTF16..<oldEndPointUTF16 }

    /// The edit that undoes this one.
    var inverted: BufferEdit {
        BufferEdit(
            oldRange: newRange, newRange: oldRange,
            startPoint: startPoint, oldEndPoint: newEndPoint, newEndPoint: oldEndPoint,
            startPointUTF16: startPointUTF16, oldEndPointUTF16: newEndPointUTF16, newEndPointUTF16: oldEndPointUTF16
        )
    }

    /// The net change made by `edits` (in application order) as disjoint replacements, ascending: byte ranges in the
    /// text before the first edit, each paired with the range holding its new text after the last edit.
    /// `resultLength` is the byte length after the last edit.
    ///
    /// Edits that move monotonically through the text, as multi-range changes do (ascending) and their undo does
    /// (descending), map to one replacement each, merged where they touch. Anything else, such as typing then
    /// deleting within one coalesced step, becomes a single replacement spanning everything the edits touched.
    static func replacements(for edits: [BufferEdit], resultLength: Int) -> [(old: Range<Int>, new: Range<Int>)] {
        guard !edits.isEmpty else { return [] }
        let deltas = edits.map { $0.newRange.count - $0.oldRange.count }
        let pairs: [(old: Range<Int>, new: Range<Int>)]
        if zip(edits, edits.dropFirst()).allSatisfy({ $1.oldRange.lowerBound >= $0.newRange.upperBound }) {
            // Ascending: earlier edits shifted each old range; nothing after an edit moves its new text.
            var shift = 0
            pairs = edits.indices.map { i in
                defer { shift += deltas[i] }
                return (edits[i].oldRange.shifted(by: -shift), edits[i].newRange)
            }
        } else if zip(edits, edits.dropFirst()).allSatisfy({ $1.oldRange.upperBound <= $0.oldRange.lowerBound }) {
            // Descending: old ranges are already in original coordinates; the later, lower edits shift the new text.
            var shift = 0
            pairs = edits.indices.reversed().map { i in
                defer { shift += deltas[i] }
                return (edits[i].oldRange, edits[i].newRange.shifted(by: shift))
            }
        } else {
            // Nothing before the lowest edit start changed, and neither did the shortest tail any edit left alone.
            let start = edits.map(\.oldRange.lowerBound).min()!
            var length = resultLength
            var suffix = Int.max
            for (edit, delta) in zip(edits, deltas).reversed() {
                suffix = min(suffix, length - edit.newRange.upperBound)
                length -= delta
            }
            suffix = min(suffix, length - start, resultLength - start)
            return [(start..<length - suffix, start..<resultLength - suffix)]
        }

        var merged = [pairs[0]]
        for pair in pairs.dropFirst() {
            let last = merged[merged.count - 1]
            if last.old.upperBound == pair.old.lowerBound {
                merged[merged.count - 1] = (last.old.lowerBound..<pair.old.upperBound, last.new.lowerBound..<pair.new.upperBound)
            } else {
                merged.append(pair)
            }
        }
        return merged
    }
}

nonisolated extension Range<Int> {
    func shifted(by offset: Int) -> Range<Int> {
        (lowerBound + offset)..<(upperBound + offset)
    }
}

nonisolated struct TextBuffer: Sendable {
    /// The current text. Copying it is an O(1) snapshot that later edits won't affect.
    private(set) var text: Rope
    /// Bumped by every edit, undo, and redo, so background work can tell when its snapshot is stale.
    private(set) var version: UInt64 = 0
    /// The file's original line ending; text is held with `\n` only and converted back by `encoded()`.
    var lineEnding: LineEnding

    private var undoStack: [Transaction] = []
    private var redoStack: [Transaction] = []
    /// Non-nil while inside `transact`.
    private var openTransaction: Transaction?
    /// True while the top undo step was made by `transact(coalesce: true)` and nothing has happened since.
    private var lastStepIsCoalescing = false

    /// Undo keeps whole Rope versions; they share every node an edit didn't touch, so each entry costs roughly
    /// the edited path, not the document.
    private struct Transaction: Sendable {
        var before: Rope
        var after: Rope
        var edits: [BufferEdit]
    }

    init(_ string: String = "") {
        let (normalized, lineEnding) = Self.normalizingLineEndings(string)
        text = Rope(normalized)
        self.lineEnding = lineEnding
    }

    init(contentsOf data: Data) throws {
        guard let string = String(validating: data, as: UTF8.self) else { throw TextBufferError.invalidUTF8 }
        self.init(string)
    }

    /// The text as file contents, with the original line endings restored.
    func encoded() -> Data {
        var data = Data()
        data.reserveCapacity(text.utf8Count + (lineEnding == .crlf ? text.summary.newlines : 0))
        for chunk in text.chunks(in: 0..<text.utf8Count) {
            switch lineEnding {
            case .lf:
                data.append(contentsOf: chunk)
            case .crlf:
                var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)[...]
                data.append(contentsOf: lines.removeFirst())
                for line in lines {
                    data.append(contentsOf: [0x0D, 0x0A])
                    data.append(contentsOf: line)
                }
            }
        }
        return data
    }

    // MARK: Editing

    /// Replaces the byte range with `newText` (whose line endings are normalized to `\n`).
    @discardableResult
    mutating func edit(_ range: Range<Int>, with newText: String) -> BufferEdit {
        let newText = newText.utf8.contains(0x0D) ? Self.normalizingLineEndings(newText).text : newText
        let start = text.summary(upTo: range.lowerBound)
        let oldEnd = text.summary(upTo: range.upperBound)
        let newEnd = start + TextSummary(newText)
        let edit = BufferEdit(
            oldRange: range, newRange: range.lowerBound..<newEnd.utf8,
            startPoint: start.point, oldEndPoint: oldEnd.point, newEndPoint: newEnd.point,
            startPointUTF16: start.pointUTF16, oldEndPointUTF16: oldEnd.pointUTF16, newEndPointUTF16: newEnd.pointUTF16
        )

        let before = text
        text.replace(range, with: newText)
        version &+= 1
        redoStack.removeAll()
        if openTransaction != nil {
            openTransaction!.edits.append(edit)
        } else {
            undoStack.append(Transaction(before: before, after: text, edits: [edit]))
            lastStepIsCoalescing = false
        }
        return edit
    }

    /// Runs `body` as one undo step. Nested calls fold into the outermost transaction, and their `coalesce` is ignored.
    ///
    /// With `coalesce: true`, the edits join the previous undo step if that step was also made with `coalesce: true`
    /// and nothing else (an edit, undo, or redo) has happened since. The caller decides which edits belong together,
    /// e.g. adjacent keystrokes; call `breakUndoCoalescing()` when the next one shouldn't join.
    mutating func transact(coalesce: Bool = false, _ body: (inout TextBuffer) -> Void) {
        guard openTransaction == nil else {
            body(&self)
            return
        }
        openTransaction = Transaction(before: text, after: text, edits: [])
        body(&self)
        guard var transaction = openTransaction.take(), !transaction.edits.isEmpty else { return }
        transaction.after = text
        if coalesce, lastStepIsCoalescing, var last = undoStack.popLast() {
            last.edits += transaction.edits
            last.after = text
            transaction = last
        }
        undoStack.append(transaction)
        lastStepIsCoalescing = coalesce
    }

    /// Makes the next `transact(coalesce: true)` start a new undo step.
    mutating func breakUndoCoalescing() {
        lastStepIsCoalescing = false
    }

    // MARK: Undo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Reverts the last transaction. Returns the edits that took the text back, in application order.
    @discardableResult
    mutating func undo() -> [BufferEdit]? {
        precondition(openTransaction == nil, "undo inside a transaction")
        guard let transaction = undoStack.popLast() else { return nil }
        text = transaction.before
        version &+= 1
        lastStepIsCoalescing = false
        redoStack.append(transaction)
        return transaction.edits.reversed().map(\.inverted)
    }

    /// Reapplies the last undone transaction. Returns its edits, in application order.
    @discardableResult
    mutating func redo() -> [BufferEdit]? {
        precondition(openTransaction == nil, "redo inside a transaction")
        guard let transaction = redoStack.popLast() else { return nil }
        text = transaction.after
        version &+= 1
        lastStepIsCoalescing = false
        undoStack.append(transaction)
        return transaction.edits
    }

    // MARK: Line endings

    /// Converts `\r\n` to `\n`. The style is taken from the first line break.
    private static func normalizingLineEndings(_ string: String) -> (text: String, lineEnding: LineEnding) {
        var contiguous = string
        return contiguous.withUTF8 { source in
            guard let firstBreak = source.firstIndex(of: 0x0A) else { return (string, .lf) }
            let lineEnding: LineEnding = firstBreak > 0 && source[firstBreak - 1] == 0x0D ? .crlf : .lf
            guard source.indices.dropLast().contains(where: { source[$0] == 0x0D && source[$0 + 1] == 0x0A }) else {
                return (string, lineEnding)
            }
            var bytes = ContiguousArray<UInt8>()
            bytes.reserveCapacity(source.count)
            for i in source.indices where !(source[i] == 0x0D && i + 1 < source.count && source[i + 1] == 0x0A) {
                bytes.append(source[i])
            }
            return (String(decoding: bytes, as: UTF8.self), lineEnding)
        }
    }
}
