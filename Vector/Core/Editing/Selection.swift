//
//  Selection.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-30.
//
//  Cursors and selections, kept beside the buffer rather than in it. Offsets are buffer byte offsets on scalar
//  boundaries, the same coordinates as `BufferEdit`; the view converts to UTF-16 only when it talks to AppKit.
//

/// A selected range, or a caret when `anchor == head`. The head is the end that moves.
nonisolated struct Selection: Hashable, Sendable {
    var anchor: Int
    var head: Int
    /// The column (in grapheme clusters) vertical movement aims for, kept while moving through shorter lines.
    var goalColumn: Int?

    init(anchor: Int, head: Int, goalColumn: Int? = nil) {
        self.anchor = anchor
        self.head = head
        self.goalColumn = goalColumn
    }

    static func caret(_ offset: Int) -> Selection {
        Selection(anchor: offset, head: offset)
    }

    var range: Range<Int> { min(anchor, head)..<max(anchor, head) }
    var isEmpty: Bool { anchor == head }
    var isReversed: Bool { head < anchor }

    /// Whether `offset` is on or inside this selection (including either end).
    func touches(_ offset: Int) -> Bool {
        range.lowerBound <= offset && offset <= range.upperBound
    }
}

/// One or more selections, sorted and non-overlapping. The primary selection is the newest; it's the one
/// NSTextView shows natively and the one "select next occurrence" extends from.
nonisolated struct SelectionSet: Sendable {
    private(set) var items: [Selection]
    private(set) var primaryIndex: Int

    init(_ selection: Selection = .caret(0)) {
        items = [selection]
        primaryIndex = 0
    }

    /// Sorts and merges `selections`; the one at `primaryIndex` (or whatever it merges into) stays primary.
    init(_ selections: [Selection], primaryIndex: Int) {
        precondition(!selections.isEmpty, "a selection set can't be empty")
        items = selections
        self.primaryIndex = primaryIndex
        normalize()
    }

    var primary: Selection { items[primaryIndex] }
    var count: Int { items.count }

    /// Adds `selection` as the new primary, merging it with any it overlaps.
    mutating func add(_ selection: Selection) {
        items.append(selection)
        primaryIndex = items.count - 1
        normalize()
    }

    /// Option+click: removes the selection at `offset` if there's another one left, otherwise adds a caret there.
    mutating func toggleCaret(at offset: Int) {
        if items.count > 1, let index = items.firstIndex(where: { $0.touches(offset) }) {
            items.remove(at: index)
            if primaryIndex == index {
                primaryIndex = items.count - 1
            } else if primaryIndex > index {
                primaryIndex -= 1
            }
        } else {
            add(.caret(offset))
        }
    }

    mutating func replacePrimary(with selection: Selection) {
        items[primaryIndex] = selection
        normalize()
    }

    mutating func collapseToPrimary() {
        items = [primary]
        primaryIndex = 0
    }

    /// Replaces every selection with `transform`'s result, merging any that now overlap.
    mutating func update(_ transform: (Selection) -> Selection) {
        items = items.map(transform)
        normalize()
    }

    /// Sorts by range and merges selections that overlap, or carets that coincide. Selections that only touch stay
    /// separate, so adjacent matches of "select next occurrence" remain distinct.
    private mutating func normalize() {
        var indexed = Array(items.enumerated())
        // Forward before reversed on equal ranges, so which direction a merge keeps doesn't depend on insertion order.
        indexed.sort { Self.sortKey($0.element) < Self.sortKey($1.element) }

        var merged: [Selection] = []
        var newPrimary = 0
        for (index, selection) in indexed {
            if let last = merged.last, Self.overlap(last, selection) {
                let range = min(last.range.lowerBound, selection.range.lowerBound)..<max(last.range.upperBound, selection.range.upperBound)
                // Keep the merged selection's direction from the earlier one.
                merged[merged.count - 1] = last.isReversed
                    ? Selection(anchor: range.upperBound, head: range.lowerBound)
                    : Selection(anchor: range.lowerBound, head: range.upperBound)
            } else {
                merged.append(selection)
            }
            if index == primaryIndex { newPrimary = merged.count - 1 }
        }
        items = merged
        primaryIndex = newPrimary
    }

    private static func sortKey(_ selection: Selection) -> (Int, Int, Int) {
        (selection.range.lowerBound, selection.range.upperBound, selection.isReversed ? 1 : 0)
    }

    static func overlap(_ a: Selection, _ b: Selection) -> Bool {
        a.range == b.range || (a.range.lowerBound < b.range.upperBound && b.range.lowerBound < a.range.upperBound)
    }
}
