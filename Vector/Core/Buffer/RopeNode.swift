//
//  RopeNode.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-27.
//
//  B-tree node storage for `Rope`. Leaves hold UTF-8 chunks; internal nodes hold children plus a parallel
//  array of their summaries. All leaves sit at the same depth.
//

/// A node in the rope's B-tree.
///
/// `@unchecked Sendable` is sound because of how nodes are owned: a node is mutated only while its owner
/// holds the sole reference (checked with `isKnownUniquelyReferenced`). Once a second reference exists
/// (a snapshot, an undo entry, a slice), the node is never mutated again; edits copy it instead. Any node
/// another thread can observe is therefore immutable.
nonisolated final class RopeNode: @unchecked Sendable {
    static let maxLeafBytes = 1024
    /// Slightly under half of `maxLeafBytes`: splitting an overfull leaf at a scalar boundary can land up to
    /// 3 bytes short of the midpoint.
    static let minLeafBytes = maxLeafBytes / 2 - 4
    static let maxChildren = 16
    static let minChildren = maxChildren / 2

    /// 0 for leaves.
    let height: Int
    var summary: TextSummary
    /// Leaf storage. Always split on Unicode scalar boundaries. Empty for internal nodes.
    var bytes: ContiguousArray<UInt8>
    /// Internal storage. Empty for leaves.
    var children: ContiguousArray<RopeNode>
    /// `childSummaries[i] == children[i].summary`, kept alongside so a seek scans one contiguous array
    /// without touching (or retaining) each child.
    var childSummaries: ContiguousArray<TextSummary>

    init(leaf bytes: ContiguousArray<UInt8>) {
        height = 0
        self.bytes = bytes
        summary = bytes.withUnsafeBufferPointer { TextSummary($0) }
        children = []
        childSummaries = []
    }

    init(children: ContiguousArray<RopeNode>) {
        precondition(!children.isEmpty, "internal node needs children")
        height = children[0].height + 1
        self.children = children
        childSummaries = ContiguousArray(children.lazy.map(\.summary))
        summary = childSummaries.reduce(.zero, +)
        bytes = []
    }

    private init(copying other: RopeNode) {
        height = other.height
        summary = other.summary
        bytes = other.bytes
        children = other.children
        childSummaries = other.childSummaries
    }

    var isLeaf: Bool { height == 0 }

    /// Whether this node is full enough to sit under a parent without rebalancing.
    var isOkChild: Bool {
        isLeaf ? bytes.count >= Self.minLeafBytes : children.count >= Self.minChildren
    }

    /// Makes `node` safe to mutate in place, copying it (shallowly, since children stay shared) if anyone else holds it.
    @inline(__always) static func makeUnique(_ node: inout RopeNode) {
        if !isKnownUniquelyReferenced(&node) {
            node = RopeNode(copying: node)
        }
    }
}

// MARK: - Building

nonisolated extension RopeNode {
    /// Builds a balanced tree from valid UTF-8.
    static func build(utf8: UnsafeBufferPointer<UInt8>) -> RopeNode {
        let leaves = leaves(from: utf8)
        return leaves.isEmpty ? RopeNode(leaf: []) : build(from: leaves)
    }

    /// Chunks bytes into leaves of at most `maxLeafBytes`, every non-root leaf at least `minLeafBytes`.
    static func leaves(from utf8: UnsafeBufferPointer<UInt8>) -> ContiguousArray<RopeNode> {
        var result = ContiguousArray<RopeNode>()
        result.reserveCapacity(utf8.count / maxLeafBytes + 1)
        var start = 0
        while start < utf8.count {
            var end = min(start + maxLeafBytes, utf8.count)
            while end < utf8.count && utf8[end].isUTF8Continuation { end -= 1 }
            result.append(RopeNode(leaf: ContiguousArray(utf8[start..<end])))
            start = end
        }
        if result.count >= 2, result[result.count - 1].bytes.count < minLeafBytes {
            let last = result.removeLast()
            let previous = result.removeLast()
            result.append(contentsOf: splitEvenly(previous.bytes + last.bytes))
        }
        return result
    }

    /// Groups same-height nodes into parents level by level until one root remains.
    static func build(from nodes: ContiguousArray<RopeNode>) -> RopeNode {
        precondition(!nodes.isEmpty)
        var level = nodes
        while level.count > 1 {
            // Spread nodes evenly so every group has between minChildren and maxChildren.
            let groupCount = (level.count + maxChildren - 1) / maxChildren
            var next = ContiguousArray<RopeNode>()
            next.reserveCapacity(groupCount)
            var start = 0
            for group in 1...groupCount {
                let end = level.count * group / groupCount
                next.append(RopeNode(children: ContiguousArray(level[start..<end])))
                start = end
            }
            level = next
        }
        return level[0]
    }

    /// Splits bytes (more than `maxLeafBytes`, less than twice that) into two leaves at the scalar boundary at or
    /// before the midpoint.
    private static func splitEvenly(_ bytes: ContiguousArray<UInt8>) -> [RopeNode] {
        var mid = bytes.count / 2
        while mid > 0 && bytes[mid].isUTF8Continuation { mid -= 1 }
        return [RopeNode(leaf: ContiguousArray(bytes[..<mid])), RopeNode(leaf: ContiguousArray(bytes[mid...]))]
    }
}

// MARK: - Editing

nonisolated extension RopeNode {
    /// Fast path for an edit that stays inside one leaf and keeps it within size bounds: mutates in place,
    /// copying only nodes on the path that are shared. Returns false (leaving the content unchanged) if the
    /// edit needs restructuring.
    static func replaceInPlace(
        _ node: inout RopeNode, _ range: Range<Int>, with text: UnsafeBufferPointer<UInt8>, isRoot: Bool
    ) -> Bool {
        if node.isLeaf {
            let newCount = node.bytes.count - range.count + text.count
            guard newCount <= maxLeafBytes, isRoot || newCount >= minLeafBytes else { return false }
            makeUnique(&node)
            node.bytes.replaceSubrange(range, with: text)
            node.summary = node.bytes.withUnsafeBufferPointer { TextSummary($0) }
            return true
        }

        var start = 0
        for i in node.childSummaries.indices {
            let end = start + node.childSummaries[i].utf8
            if range.upperBound <= end {
                guard range.lowerBound >= start else { return false }  // spans children
                makeUnique(&node)
                let local = (range.lowerBound - start)..<(range.upperBound - start)
                guard replaceInPlace(&node.children[i], local, with: text, isRoot: false) else { return false }
                node.childSummaries[i] = node.children[i].summary
                node.summary = node.childSummaries.reduce(.zero, +)
                return true
            }
            start = end
        }
        return false
    }

    /// Joins two trees, keeping the result balanced. Never mutates its inputs. The result's height is
    /// `max(a.height, b.height)` or one more.
    static func concat(_ a: RopeNode, _ b: RopeNode) -> RopeNode {
        if a.height < b.height {
            if a.height == b.height - 1 && a.isOkChild {
                return merge(CollectionOfOne(a), b.children)
            }
            let joined = concat(a, b.children[0])
            return joined.height == b.height - 1
                ? merge(CollectionOfOne(joined), b.children.dropFirst())
                : merge(joined.children, b.children.dropFirst())
        } else if a.height > b.height {
            if b.height == a.height - 1 && b.isOkChild {
                return merge(a.children, CollectionOfOne(b))
            }
            let joined = concat(a.children[a.children.count - 1], b)
            return joined.height == a.height - 1
                ? merge(a.children.dropLast(), CollectionOfOne(joined))
                : merge(a.children.dropLast(), joined.children)
        } else {
            if a.isOkChild && b.isOkChild {
                return RopeNode(children: [a, b])
            }
            if a.isLeaf {
                let combined = a.bytes + b.bytes
                return combined.count <= maxLeafBytes
                    ? RopeNode(leaf: combined)
                    : RopeNode(children: ContiguousArray(splitEvenly(combined)))
            }
            return merge(a.children, b.children)
        }
    }

    /// Makes one parent from two runs of same-height siblings, or a two-level subtree if they don't fit in one.
    private static func merge(
        _ first: some Collection<RopeNode>, _ second: some Collection<RopeNode>
    ) -> RopeNode {
        var all = ContiguousArray<RopeNode>()
        all.reserveCapacity(first.count + second.count)
        all.append(contentsOf: first)
        all.append(contentsOf: second)
        if all.count <= maxChildren {
            return RopeNode(children: all)
        }
        let split = min(maxChildren, all.count - minChildren)
        return RopeNode(children: [
            RopeNode(children: ContiguousArray(all[..<split])),
            RopeNode(children: ContiguousArray(all[split...])),
        ])
    }
}

/// Assembles a tree left to right from whole subtrees and slices of existing trees.
nonisolated struct RopeBuilder {
    private var root: RopeNode?

    mutating func push(_ node: RopeNode) {
        guard node.summary.utf8 > 0 else { return }
        root = root.map { RopeNode.concat($0, node) } ?? node
    }

    /// Pushes `range` (relative to `node`), reusing every child the range covers entirely.
    mutating func push(slice range: Range<Int>, of node: RopeNode) {
        guard !range.isEmpty else { return }
        if range.lowerBound == 0 && range.upperBound == node.summary.utf8 {
            push(node)
        } else if node.isLeaf {
            push(RopeNode(leaf: ContiguousArray(node.bytes[range])))
        } else {
            var start = 0
            for i in node.childSummaries.indices {
                let end = start + node.childSummaries[i].utf8
                let lower = max(range.lowerBound, start)
                let upper = min(range.upperBound, end)
                if lower < upper {
                    push(slice: (lower - start)..<(upper - start), of: node.children[i])
                }
                if end >= range.upperBound { break }
                start = end
            }
        }
    }

    func finish() -> RopeNode {
        var node = root ?? RopeNode(leaf: [])
        while !node.isLeaf && node.children.count == 1 {
            node = node.children[0]
        }
        return node
    }
}
