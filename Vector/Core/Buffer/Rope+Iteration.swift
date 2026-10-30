//
//  Rope+Iteration.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-27.
//
//  Zero-copy chunk iteration (for tree-sitter's read callback, saving, search) and line iteration (for the viewport).
//

nonisolated extension Rope {
    /// The leaf chunks overlapping `range`, trimmed to it. Each chunk is a slice of a leaf's storage, not a copy.
    func chunks(in range: Range<Int>) -> ChunkSequence {
        precondition(range.lowerBound >= 0 && range.upperBound <= utf8Count, "range \(range) out of bounds")
        return ChunkSequence(root: root, range: range)
    }

    /// The first occurrence of `needle` lying wholly inside `range`. Streams the chunks rather than copying the text.
    func firstRange(of needle: [UInt8], in range: Range<Int>) -> Range<Int>? {
        guard let first = needle.first, needle.count <= range.count else { return nil }
        // Carries the last `needle.count - 1` bytes into the next chunk, so matches across chunk boundaries count.
        var window: [UInt8] = []
        var windowStart = range.lowerBound
        for chunk in chunks(in: range) {
            window.append(contentsOf: chunk)
            if window.count >= needle.count {
                for i in 0...(window.count - needle.count)
                where window[i] == first && window[i..<(i + needle.count)].elementsEqual(needle) {
                    return (windowStart + i)..<(windowStart + i + needle.count)
                }
            }
            let kept = min(needle.count - 1, window.count)
            windowStart += window.count - kept
            window.removeFirst(window.count - kept)
        }
        return nil
    }

    /// The text of each line in `rows` (clamped to the document), without trailing `\n`.
    func lines(in rows: Range<Int>) -> LazyMapSequence<Range<Int>, String> {
        rows.clamped(to: 0..<lineCount).lazy.map { string(in: lineRange($0)) }
    }
}

nonisolated struct ChunkSequence: Sequence, Sendable {
    fileprivate let root: RopeNode
    fileprivate let range: Range<Int>

    func makeIterator() -> Iterator {
        Iterator(stack: [(root, 0)], range: range)
    }

    nonisolated struct Iterator: IteratorProtocol {
        /// Nodes still to visit with their absolute start offsets; the next one is on top.
        fileprivate var stack: [(node: RopeNode, start: Int)]
        fileprivate let range: Range<Int>

        mutating func next() -> ArraySlice<UInt8>? {
            while let (node, start) = stack.popLast() {
                if node.isLeaf {
                    let lower = Swift.max(range.lowerBound - start, 0)
                    let upper = Swift.min(range.upperBound - start, node.bytes.count)
                    if lower < upper { return node.bytes[lower..<upper] }
                    continue
                }
                var childEnd = start + node.summary.utf8
                for i in node.children.indices.reversed() {
                    let childStart = childEnd - node.childSummaries[i].utf8
                    if childStart < range.upperBound && childEnd > range.lowerBound {
                        stack.append((node.children[i], childStart))
                    }
                    childEnd = childStart
                }
            }
            return nil
        }
    }
}
