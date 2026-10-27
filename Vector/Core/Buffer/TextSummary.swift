//
//  TextSummary.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-27.
//
//  Coordinate types and the per-node text summary the rope caches at every level.
//

/// A position as (row, column) with the column in UTF-8 bytes. Matches tree-sitter's `TSPoint`.
nonisolated struct Point: Hashable, Comparable, Sendable {
    var row: Int
    var column: Int

    static let zero = Point(row: 0, column: 0)

    static func < (lhs: Point, rhs: Point) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// A position as (row, column) with the column in UTF-16 code units. Matches LSP's default `Position` encoding.
nonisolated struct PointUTF16: Hashable, Comparable, Sendable {
    var row: Int
    var column: Int

    static let zero = PointUTF16(row: 0, column: 0)

    static func < (lhs: PointUTF16, rhs: PointUTF16) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// Which way to snap an offset that falls inside a multi-byte scalar.
nonisolated enum Bias: Sendable {
    case backward
    case forward
}

/// Aggregate measurements of a run of UTF-8 text. Summaries add like a monoid, so a node's summary is the
/// sum of its children's, and any coordinate conversion is "seek by one field, read the others".
nonisolated struct TextSummary: Hashable, Sendable {
    var utf8 = 0
    var utf16 = 0
    var newlines = 0
    /// Bytes after the last `\n` (or from the start, if there is none).
    var lastLineUTF8 = 0
    /// UTF-16 code units after the last `\n`.
    var lastLineUTF16 = 0

    static let zero = TextSummary()

    init() {}

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        for byte in bytes {
            if byte == 0x0A {
                utf16 += 1
                newlines += 1
                lastLineUTF8 = 0
                lastLineUTF16 = 0
            } else {
                let width = byte.utf16Width
                utf16 += width
                lastLineUTF8 += 1
                lastLineUTF16 += width
            }
        }
        utf8 = bytes.count
    }

    init(_ text: some StringProtocol) {
        var string = String(text)
        self = string.withUTF8 { TextSummary($0) }
    }

    var point: Point { Point(row: newlines, column: lastLineUTF8) }
    var pointUTF16: PointUTF16 { PointUTF16(row: newlines, column: lastLineUTF16) }

    static func + (lhs: TextSummary, rhs: TextSummary) -> TextSummary {
        var result = TextSummary()
        result.utf8 = lhs.utf8 + rhs.utf8
        result.utf16 = lhs.utf16 + rhs.utf16
        result.newlines = lhs.newlines + rhs.newlines
        if rhs.newlines > 0 {
            result.lastLineUTF8 = rhs.lastLineUTF8
            result.lastLineUTF16 = rhs.lastLineUTF16
        } else {
            result.lastLineUTF8 = lhs.lastLineUTF8 + rhs.lastLineUTF8
            result.lastLineUTF16 = lhs.lastLineUTF16 + rhs.lastLineUTF16
        }
        return result
    }

    static func += (lhs: inout TextSummary, rhs: TextSummary) {
        lhs = lhs + rhs
    }
}

nonisolated extension UInt8 {
    @inline(__always) var isUTF8Continuation: Bool { self & 0xC0 == 0x80 }

    /// Byte length of the scalar this leading byte starts.
    @inline(__always) var utf8ScalarLength: Int {
        self < 0x80 ? 1 : self < 0xE0 ? 2 : self < 0xF0 ? 3 : 4
    }

    /// UTF-16 code units this byte contributes: 0 for a continuation byte, 2 for the lead of a 4-byte scalar.
    @inline(__always) var utf16Width: Int {
        isUTF8Continuation ? 0 : (self >= 0xF0 ? 2 : 1)
    }
}
