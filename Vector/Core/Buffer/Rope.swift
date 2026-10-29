//
//  Rope.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-27.
//
//  Persistent, value-semantic text storage. Copying a Rope is an O(1) snapshot; edits are O(log n) and
//  mutate in place when nothing else shares the edited path.
//

/// UTF-8 text in a balanced B-tree of chunks.
///
/// Offsets are UTF-8 byte offsets and must fall on Unicode scalar boundaries. Only `\n` counts as a line
/// break; `TextBuffer` normalizes line endings before text gets here.
nonisolated struct Rope: Sendable {
    private(set) var root: RopeNode

    init() {
        root = RopeNode(leaf: [])
    }

    init(_ text: some StringProtocol) {
        var string = String(text)
        root = string.withUTF8 { RopeNode.build(utf8: $0) }
    }

    private init(root: RopeNode) {
        self.root = root
    }

    var summary: TextSummary { root.summary }
    var utf8Count: Int { root.summary.utf8 }
    var utf16Count: Int { root.summary.utf16 }
    var lineCount: Int { root.summary.newlines + 1 }
    var isEmpty: Bool { utf8Count == 0 }

    // MARK: Editing

    mutating func replace(_ range: Range<Int>, with text: some StringProtocol) {
        precondition(range.lowerBound >= 0 && range.upperBound <= utf8Count, "range \(range) out of bounds")
        precondition(isScalarBoundary(range.lowerBound) && isScalarBoundary(range.upperBound),
                     "range \(range) splits a Unicode scalar")
        var text = String(text)
        text.withUTF8 { utf8 in
            if RopeNode.replaceInPlace(&root, range, with: utf8, isRoot: true) { return }
            var builder = RopeBuilder()
            builder.push(slice: 0..<range.lowerBound, of: root)
            builder.push(RopeNode.build(utf8: utf8))
            builder.push(slice: range.upperBound..<utf8Count, of: root)
            root = builder.finish()
        }
    }

    mutating func insert(_ text: some StringProtocol, at offset: Int) {
        replace(offset..<offset, with: text)
    }

    mutating func delete(_ range: Range<Int>) {
        replace(range, with: "")
    }

    /// O(log n); the slice shares every node the range covers entirely.
    func slice(_ range: Range<Int>) -> Rope {
        precondition(range.lowerBound >= 0 && range.upperBound <= utf8Count, "range \(range) out of bounds")
        var builder = RopeBuilder()
        builder.push(slice: range, of: root)
        return Rope(root: builder.finish())
    }

    func string(in range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }
        return String(unsafeUninitializedCapacity: range.count) { buffer in
            var written = 0
            for chunk in chunks(in: range) {
                chunk.withUnsafeBufferPointer { source in
                    buffer.baseAddress!.advanced(by: written).initialize(from: source.baseAddress!, count: source.count)
                }
                written += chunk.count
            }
            return written
        }
    }

    // MARK: Coordinate conversion

    /// Summary of the text before `offset`: its byte, UTF-16, and row/column position in one O(log n) lookup.
    func summary(upTo offset: Int) -> TextSummary {
        precondition(offset >= 0 && offset <= utf8Count, "offset \(offset) out of bounds")
        let (leaf, prefix) = seek(offset, by: \.utf8)
        return prefix + leaf.bytes.withUnsafeBufferPointer {
            TextSummary(UnsafeBufferPointer(rebasing: $0[..<(offset - prefix.utf8)]))
        }
    }

    func point(at offset: Int) -> Point { summary(upTo: offset).point }
    func pointUTF16(at offset: Int) -> PointUTF16 { summary(upTo: offset).pointUTF16 }
    func utf16Offset(at offset: Int) -> Int { summary(upTo: offset).utf16 }

    /// Byte offset for a UTF-16 offset. Clamps to the text; an offset inside a surrogate pair rounds down.
    func offset(atUTF16 utf16: Int) -> Int {
        let target = min(max(utf16, 0), utf16Count)
        let (leaf, prefix) = seek(target, by: \.utf16)
        var units = prefix.utf16
        var index = 0
        let bytes = leaf.bytes
        while index < bytes.count && units < target {
            let lead = bytes[index]
            let width = lead.utf16Width
            if units + width > target { break }
            units += width
            index += lead.utf8ScalarLength
        }
        return prefix.utf8 + index
    }

    /// Byte offset for a point. A row past the end clamps to the end of the text; a column past the end of its
    /// line clamps to the line's end; a column inside a scalar rounds down.
    func offset(of point: Point) -> Int {
        offset(row: point.row, column: point.column, columnIsUTF16: false)
    }

    /// Byte offset for an LSP-style position. Clamps like `offset(of: Point)`.
    func offset(of point: PointUTF16) -> Int {
        offset(row: point.row, column: point.column, columnIsUTF16: true)
    }

    /// Byte range of line `row`, excluding its trailing `\n`.
    func lineRange(_ row: Int) -> Range<Int> {
        precondition(row >= 0 && row < lineCount, "row \(row) out of bounds")
        return offset(of: Point(row: row, column: 0))..<offset(of: Point(row: row, column: .max))
    }

    /// Snaps an offset to the nearest scalar boundary in the direction of `bias`, clamping to the text.
    func clipOffset(_ offset: Int, bias: Bias) -> Int {
        let offset = min(max(offset, 0), utf8Count)
        let (leaf, prefix) = seek(offset, by: \.utf8)
        let bytes = leaf.bytes
        var index = offset - prefix.utf8
        switch bias {
        case .backward:
            while index > 0 && index < bytes.count && bytes[index].isUTF8Continuation { index -= 1 }
        case .forward:
            while index < bytes.count && bytes[index].isUTF8Continuation { index += 1 }
        }
        return prefix.utf8 + index
    }

    func isScalarBoundary(_ offset: Int) -> Bool {
        guard offset > 0 && offset < utf8Count else { return offset == 0 || offset == utf8Count }
        let (leaf, prefix) = seek(offset, by: \.utf8)
        let index = offset - prefix.utf8
        return index == leaf.bytes.count || !leaf.bytes[index].isUTF8Continuation
    }

    // MARK: Internals

    /// Descends to the first leaf whose end, measured by `key`, reaches `target` (or the last leaf). Returns that
    /// leaf and the summary of everything before it.
    private func seek<Key: Comparable>(_ target: Key, by key: (TextSummary) -> Key) -> (leaf: RopeNode, prefix: TextSummary) {
        var node = root
        var prefix = TextSummary.zero
        while !node.isLeaf {
            let last = node.children.count - 1
            var i = 0
            while i < last {
                let next = prefix + node.childSummaries[i]
                if key(next) >= target { break }
                prefix = next
                i += 1
            }
            node = node.children[i]
        }
        return (node, prefix)
    }

    private func offset(row: Int, column: Int, columnIsUTF16: Bool) -> Int {
        guard row >= 0 else { return 0 }
        guard row <= root.summary.newlines else { return utf8Count }
        let target = Point(row: row, column: max(column, 0))
        let (leaf, prefix) = seek(target) {
            Point(row: $0.newlines, column: columnIsUTF16 ? $0.lastLineUTF16 : $0.lastLineUTF8)
        }

        let bytes = leaf.bytes
        var index = 0
        var currentRow = prefix.newlines
        var currentColumn = columnIsUTF16 ? prefix.lastLineUTF16 : prefix.lastLineUTF8
        while currentRow < target.row, index < bytes.count {
            if bytes[index] == 0x0A {
                currentRow += 1
                currentColumn = 0
            }
            index += 1
        }
        while index < bytes.count && currentColumn < target.column {
            let lead = bytes[index]
            if lead == 0x0A { break }
            let width = columnIsUTF16 ? lead.utf16Width : lead.utf8ScalarLength
            if currentColumn + width > target.column { break }
            currentColumn += width
            index += lead.utf8ScalarLength
        }
        return prefix.utf8 + index
    }
}

nonisolated extension Rope {
    /// True if both are the same version (one is an unmodified copy of the other). O(1); unlike `==`, it's false
    /// for equal text reached by different edits.
    func isIdentical(to other: Rope) -> Bool {
        root === other.root
    }
}

nonisolated extension Rope: Equatable {
    static func == (lhs: Rope, rhs: Rope) -> Bool {
        if lhs.root === rhs.root { return true }
        guard lhs.summary == rhs.summary else { return false }
        return lhs.chunks(in: 0..<lhs.utf8Count).joined()
            .elementsEqual(rhs.chunks(in: 0..<rhs.utf8Count).joined())
    }
}

nonisolated extension Rope: CustomStringConvertible {
    var description: String { string(in: 0..<utf8Count) }
}

#if DEBUG
nonisolated extension Rope {
    struct InvariantViolation: Error, CustomStringConvertible {
        var description: String
    }

    /// Verifies the tree's structural invariants. O(n); for tests.
    func checkInvariants() throws {
        try Self.check(root, isRoot: true)
    }

    private static func check(_ node: RopeNode, isRoot: Bool) throws {
        func fail(_ message: String) throws -> Never { throw InvariantViolation(description: message) }

        if node.isLeaf {
            let count = node.bytes.count
            if count > RopeNode.maxLeafBytes { try fail("leaf has \(count) bytes, over max") }
            if !isRoot && count < RopeNode.minLeafBytes { try fail("non-root leaf has \(count) bytes, under min") }
            if let first = node.bytes.first, first.isUTF8Continuation { try fail("leaf starts mid-scalar") }
            if node.summary != node.bytes.withUnsafeBufferPointer({ TextSummary($0) }) { try fail("stale leaf summary") }
            return
        }

        let count = node.children.count
        if count > RopeNode.maxChildren { try fail("node has \(count) children, over max") }
        if isRoot && count < 2 { try fail("internal root has \(count) child") }
        if !isRoot && count < RopeNode.minChildren { try fail("node has \(count) children, under min") }
        if node.childSummaries.count != count { try fail("childSummaries out of sync") }
        for (child, summary) in zip(node.children, node.childSummaries) {
            if child.height != node.height - 1 { try fail("uneven leaf depth") }
            if child.summary != summary { try fail("stale child summary") }
            try check(child, isRoot: false)
        }
        if node.summary != node.childSummaries.reduce(.zero, +) { try fail("stale node summary") }
    }
}
#endif
