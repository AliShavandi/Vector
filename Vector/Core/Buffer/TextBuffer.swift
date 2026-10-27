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
        }
        return edit
    }

    /// Runs `body` as one undo step. Nested calls fold into the outermost transaction.
    mutating func transact(_ body: (inout TextBuffer) -> Void) {
        guard openTransaction == nil else {
            body(&self)
            return
        }
        openTransaction = Transaction(before: text, after: text, edits: [])
        body(&self)
        guard var transaction = openTransaction.take(), !transaction.edits.isEmpty else { return }
        transaction.after = text
        undoStack.append(transaction)
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
