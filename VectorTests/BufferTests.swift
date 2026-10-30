//
//  BufferTests.swift
//  VectorTests
//
//  Created by Ali Shavandi on 2026-10-25.
//

import Foundation
import Testing
@testable import Vector

// MARK: - Reference model

private let alphabet = ["a", "b", "c", " ", "\n", "é", "中", "😀"]

private func randomText(length: Int, using rng: inout SplitMix64) -> String {
    String((0..<length).map { _ in alphabet.randomElement(using: &rng)! }.joined())
}

/// Scalar-boundary byte offsets of `bytes`, including the end.
private func boundaries(_ bytes: [UInt8]) -> [Int] {
    bytes.indices.filter { !bytes[$0].isUTF8Continuation } + [bytes.count]
}

private func referenceSummary(_ bytes: some Collection<UInt8>) -> (point: Point, pointUTF16: PointUTF16, utf16: Int) {
    let string = String(decoding: bytes, as: UTF8.self)
    let lastLine = string.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
    let rows = bytes.filter { $0 == 0x0A }.count
    return (Point(row: rows, column: lastLine.utf8.count),
            PointUTF16(row: rows, column: lastLine.utf16.count),
            string.utf16.count)
}

private func expectMatches(_ rope: Rope, _ reference: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws {
    try rope.checkInvariants()
    #expect(Array(rope.description.utf8) == reference, sourceLocation: sourceLocation)
    let string = String(decoding: reference, as: UTF8.self)
    #expect(rope.utf8Count == reference.count, sourceLocation: sourceLocation)
    #expect(rope.utf16Count == string.utf16.count, sourceLocation: sourceLocation)
    #expect(rope.lineCount == reference.filter { $0 == 0x0A }.count + 1, sourceLocation: sourceLocation)
}

// MARK: - Rope

struct RopeTests {
    @Test func emptyRope() throws {
        let rope = Rope()
        try rope.checkInvariants()
        #expect(rope.isEmpty)
        #expect(rope.lineCount == 1)
        #expect(rope.description == "")
        #expect(rope.point(at: 0) == .zero)
        #expect(rope.lineRange(0) == 0..<0)
        #expect(Array(rope.chunks(in: 0..<0)).isEmpty)
    }

    @Test func multibyteCounts() throws {
        let text = "héllo\n😀 wörld"
        let rope = Rope(text)
        try expectMatches(rope, Array(text.utf8))
        #expect(rope.lineCount == 2)
        #expect(rope.point(at: rope.utf8Count) == Point(row: 1, column: "😀 wörld".utf8.count))
        #expect(rope.pointUTF16(at: rope.utf8Count) == PointUTF16(row: 1, column: "😀 wörld".utf16.count))
    }

    @Test func largeTextBuildsBalancedTree() throws {
        var rng = SplitMix64(state: 1)
        let text = randomText(length: 100_000, using: &rng)
        let rope = Rope(text)
        try expectMatches(rope, Array(text.utf8))
        #expect(rope.root.height >= 2)
    }

    @Test func conversionsMatchReferenceAtEveryBoundary() throws {
        var rng = SplitMix64(state: 2)
        let bytes = Array(randomText(length: 3_000, using: &rng).utf8)
        let rope = Rope(String(decoding: bytes, as: UTF8.self))
        for offset in boundaries(bytes) {
            let expected = referenceSummary(bytes[..<offset])
            #expect(rope.point(at: offset) == expected.point)
            #expect(rope.pointUTF16(at: offset) == expected.pointUTF16)
            #expect(rope.utf16Offset(at: offset) == expected.utf16)
            #expect(rope.offset(of: expected.point) == offset)
            #expect(rope.offset(of: expected.pointUTF16) == offset)
            #expect(rope.offset(atUTF16: expected.utf16) == offset)
            #expect(rope.isScalarBoundary(offset))
        }
    }

    @Test func linesMatchReference() {
        var rng = SplitMix64(state: 3)
        let text = randomText(length: 5_000, using: &rng)
        let rope = Rope(text)
        let expected = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(rope.lines(in: 0..<rope.lineCount)) == expected)
        #expect(Array(rope.lines(in: 2..<5)) == Array(expected[2..<5]))
        #expect(Array(rope.lines(in: (rope.lineCount - 1)..<(rope.lineCount + 10))) == [expected.last!])
    }

    @Test func clipping() {
        let rope = Rope("a😀b\ncd")  // 😀 is bytes 1..<5, UTF-16 1..<3
        #expect(rope.offset(atUTF16: 2) == 1)  // inside the surrogate pair rounds down
        #expect(rope.offset(atUTF16: 3) == 5)
        #expect(rope.offset(atUTF16: 999) == rope.utf8Count)
        #expect(rope.clipOffset(3, bias: .backward) == 1)
        #expect(rope.clipOffset(3, bias: .forward) == 5)
        #expect(rope.clipOffset(-4, bias: .forward) == 0)
        #expect(!rope.isScalarBoundary(2))
        #expect(rope.offset(of: Point(row: 0, column: 3)) == 1)  // inside 😀 rounds down
        #expect(rope.offset(of: Point(row: 0, column: 99)) == 6)  // clamps to line end, before \n
        #expect(rope.offset(of: PointUTF16(row: 0, column: 99)) == 6)
        #expect(rope.offset(of: Point(row: 9, column: 0)) == rope.utf8Count)
        #expect(rope.lineRange(0) == 0..<6)
        #expect(rope.lineRange(1) == 7..<9)
    }

    @Test func snapshotIsUnaffectedByLaterEdits() throws {
        var rng = SplitMix64(state: 4)
        let text = randomText(length: 20_000, using: &rng)
        var rope = Rope(text)
        let snapshot = rope
        rope.insert("inserted", at: rope.clipOffset(5_000, bias: .backward))
        rope.delete(0..<rope.clipOffset(100, bias: .backward))
        #expect(snapshot.description == text)
        try snapshot.checkInvariants()
        try rope.checkInvariants()
    }

    @Test func sliceSharesAndMatches() throws {
        var rng = SplitMix64(state: 5)
        let bytes = Array(randomText(length: 20_000, using: &rng).utf8)
        let rope = Rope(String(decoding: bytes, as: UTF8.self))
        let cuts = boundaries(bytes)
        for _ in 0..<50 {
            let a = cuts.randomElement(using: &rng)!, b = cuts.randomElement(using: &rng)!
            let range = min(a, b)..<max(a, b)
            let slice = rope.slice(range)
            try expectMatches(slice, Array(bytes[range]))
            #expect(rope.string(in: range) == slice.description)
        }
    }

    @Test func searchMatchesReference() {
        var rng = SplitMix64(state: 6)
        // Several leaves, with "/*" straddling the first leaf boundary (1 KB).
        let bytes = Array((String(repeating: "ab", count: 511) + "c/" + "*d" + randomText(length: 3_000, using: &rng)).utf8)
        let rope = Rope(String(decoding: bytes, as: UTF8.self))
        func reference(_ needle: [UInt8], _ range: Range<Int>) -> Range<Int>? {
            guard !needle.isEmpty, needle.count <= range.count else { return nil }
            return (range.lowerBound...(range.upperBound - needle.count))
                .first { bytes[$0..<($0 + needle.count)].elementsEqual(needle) }
                .map { $0..<($0 + needle.count) }
        }

        #expect(rope.firstRange(of: Array("/*".utf8), in: 0..<bytes.count) == 1023..<1025)
        #expect(rope.firstRange(of: Array("/*".utf8), in: 0..<1024) == nil)  // must lie wholly inside the range
        let cuts = boundaries(bytes)
        for _ in 0..<300 {
            let a = cuts.randomElement(using: &rng)!, b = cuts.randomElement(using: &rng)!
            let start = cuts.randomElement(using: &rng)!
            let needle = Array(bytes[start..<(cuts.first { $0 >= start + Int.random(in: 1...6, using: &rng) } ?? bytes.count)])
            let range = min(a, b)..<max(a, b)
            #expect(rope.firstRange(of: needle, in: range) == reference(needle, range))
        }
    }

    @Test(arguments: [10, 11, 12, 13])
    func randomEditsMatchReference(seed: UInt64) throws {
        var rng = SplitMix64(state: seed)
        var reference = Array(randomText(length: 4_000, using: &rng).utf8)
        var rope = Rope(String(decoding: reference, as: UTF8.self))
        var snapshots: [(Rope, [UInt8])] = []

        for step in 0..<1_500 {
            let cuts = boundaries(reference)
            let a = cuts.randomElement(using: &rng)!, b = cuts.randomElement(using: &rng)!
            var range = min(a, b)..<max(a, b)
            // Mostly small, keystroke-like edits; occasionally big deletes and pastes to force restructuring.
            if Int.random(in: 0..<10, using: &rng) < 8, range.count > 8 {
                range = range.lowerBound..<(cuts.first { $0 >= range.lowerBound + Int.random(in: 0...8, using: &rng) } ?? range.upperBound)
            }
            let insertLength = Int.random(in: 0..<20, using: &rng) == 0 ? Int.random(in: 0...3_000, using: &rng) : Int.random(in: 0...3, using: &rng)
            let inserted = randomText(length: insertLength, using: &rng)

            rope.replace(range, with: inserted)
            reference.replaceSubrange(range, with: Array(inserted.utf8))
            try expectMatches(rope, reference)

            if step % 100 == 0 { snapshots.append((rope, reference)) }
            if step % 25 == 0 {
                for offset in boundaries(reference).shuffled(using: &rng).prefix(10) {
                    let expected = referenceSummary(reference[..<offset])
                    #expect(rope.point(at: offset) == expected.point)
                    #expect(rope.offset(of: expected.pointUTF16) == offset)
                    #expect(rope.offset(atUTF16: expected.utf16) == offset)
                }
            }
        }
        for (snapshot, expected) in snapshots {
            try expectMatches(snapshot, expected)
        }
    }
}

// MARK: - TextBuffer

struct TextBufferTests {
    @Test func crlfRoundTrips() throws {
        let data = Data("one\r\ntwo\r\n\r\nthree".utf8)
        let buffer = try TextBuffer(contentsOf: data)
        #expect(buffer.lineEnding == .crlf)
        #expect(buffer.text.description == "one\ntwo\n\nthree")
        #expect(buffer.encoded() == data)
    }

    @Test func lfFileStaysLF() throws {
        let data = Data("a\nb\n".utf8)
        let buffer = try TextBuffer(contentsOf: data)
        #expect(buffer.lineEnding == .lf)
        #expect(buffer.encoded() == data)
    }

    @Test func invalidUTF8Throws() {
        #expect(throws: TextBufferError.invalidUTF8) {
            try TextBuffer(contentsOf: Data([0x61, 0xFF, 0x62]))
        }
    }

    @Test func pastedCRLFIsNormalized() {
        var buffer = TextBuffer("x")
        buffer.edit(1..<1, with: "\r\ny\r\n")
        #expect(buffer.text.description == "x\ny\n")
    }

    @Test func editDescribesAllCoordinates() {
        var buffer = TextBuffer("hello\nwörld")
        let ö = 7..<9
        let edit = buffer.edit(ö, with: "o\n😀")
        #expect(buffer.text.description == "hello\nwo\n😀rld")
        #expect(edit.oldRange == ö)
        #expect(edit.newRange == 7..<13)
        #expect(edit.startPoint == Point(row: 1, column: 1))
        #expect(edit.oldEndPoint == Point(row: 1, column: 3))
        #expect(edit.newEndPoint == Point(row: 2, column: 4))
        #expect(edit.oldRangeUTF16 == PointUTF16(row: 1, column: 1)..<PointUTF16(row: 1, column: 2))
        #expect(edit.newEndPointUTF16 == PointUTF16(row: 2, column: 2))
        #expect(buffer.version == 1)
    }

    @Test func undoRedoWithTransactions() {
        var buffer = TextBuffer("abc")
        buffer.edit(3..<3, with: "d")
        buffer.transact { buffer in
            buffer.edit(0..<1, with: "X")
            buffer.transact { $0.edit(4..<4, with: "!") }  // nested: folds into the outer step
        }
        #expect(buffer.text.description == "Xbcd!")

        let undone = buffer.undo()
        #expect(buffer.text.description == "abcd")
        #expect(undone?.map(\.oldRange) == [4..<5, 0..<1])
        #expect(undone?.first?.newRange == 4..<4)

        buffer.undo()
        #expect(buffer.text.description == "abc")
        #expect(!buffer.canUndo)
        #expect(buffer.undo() == nil)

        buffer.redo()
        #expect(buffer.text.description == "abcd")

        buffer.edit(0..<0, with: ">")
        #expect(!buffer.canRedo)
        #expect(buffer.text.description == ">abcd")
        #expect(buffer.version == 7)
    }

    @Test func emptyTransactionAddsNoUndoStep() {
        var buffer = TextBuffer("a")
        buffer.transact { _ in }
        #expect(!buffer.canUndo)
    }

    @Test func coalescedEditsUndoAsOneStep() {
        var buffer = TextBuffer("")
        for (i, character) in "abc".enumerated() {
            buffer.transact(coalesce: true) { $0.edit(i..<i, with: String(character)) }
        }
        #expect(buffer.text.description == "abc")

        let undone = buffer.undo()
        #expect(buffer.text.description == "")
        #expect(undone?.map(\.oldRange) == [2..<3, 1..<2, 0..<1])
        #expect(!buffer.canUndo)

        buffer.redo()
        #expect(buffer.text.description == "abc")
    }

    @Test func coalescingStopsAtBreaksEditsAndHistory() {
        var buffer = TextBuffer("")
        buffer.transact(coalesce: true) { $0.edit(0..<0, with: "a") }
        buffer.breakUndoCoalescing()
        buffer.transact(coalesce: true) { $0.edit(1..<1, with: "b") }
        buffer.transact(coalesce: true) { $0.edit(2..<2, with: "c") }
        buffer.edit(3..<3, with: "-")
        buffer.transact(coalesce: true) { $0.edit(4..<4, with: "d") }  // can't join the plain edit
        buffer.transact { $0.edit(5..<5, with: "e") }
        buffer.transact(coalesce: true) { $0.edit(6..<6, with: "f") }  // nor a plain transaction

        var states: [String] = []
        while buffer.undo() != nil { states.append(buffer.text.description) }
        #expect(states == ["abc-de", "abc-d", "abc-", "abc", "a", ""])

        // Undo and redo end the run too.
        buffer.redo()
        buffer.transact(coalesce: true) { $0.edit(1..<1, with: "x") }
        buffer.undo()
        #expect(buffer.text.description == "a")
        buffer.transact(coalesce: true) { $0.edit(1..<1, with: "y") }
        #expect(!buffer.canRedo)
        buffer.undo()
        #expect(buffer.text.description == "a")
    }

    @Test func touchingEditsMergeIntoOneReplacement() {
        var buffer = TextBuffer("abcdef")
        var edits: [BufferEdit] = []
        buffer.transact { buffer in
            edits.append(buffer.edit(4..<5, with: ""))  // backspacing from after "e"
            edits.append(buffer.edit(3..<4, with: ""))
            edits.append(buffer.edit(2..<3, with: ""))
        }
        #expect(BufferEdit.replacements(for: edits, resultLength: 3).map(\.old) == [2..<5])
        #expect(BufferEdit.replacements(for: edits, resultLength: 3).map(\.new) == [2..<2])
    }

    /// Mirroring a step into the text storage replays `BufferEdit.replacements`; they must rebuild the result exactly,
    /// forward and on undo, and be precise (no wider than the edits) whenever the edits are monotonic.
    @Test(arguments: [20, 21, 22, 23] as [UInt64])
    func replacementsReproduceEdits(seed: UInt64) {
        var rng = SplitMix64(state: seed)
        for step in 0..<400 {
            var buffer = TextBuffer(randomText(length: Int.random(in: 0...200, using: &rng), using: &rng))
            let before = Array(buffer.text.description.utf8)
            let isMonotonic = step % 3 != 2
            var edits: [BufferEdit] = []
            buffer.transact { buffer in
                guard isMonotonic else {
                    // Anywhere, including over earlier edits.
                    for _ in 0..<Int.random(in: 1...6, using: &rng) {
                        let cuts = boundaries(Array(buffer.text.description.utf8))
                        let a = cuts.randomElement(using: &rng)!, b = cuts.randomElement(using: &rng)!
                        let inserted = randomText(length: Int.random(in: 0...3, using: &rng), using: &rng)
                        edits.append(buffer.edit(min(a, b)..<max(a, b), with: inserted))
                    }
                    return
                }
                // Disjoint (possibly touching) ranges of the original text, front to back or back to front.
                let cuts = (0..<2 * Int.random(in: 1...5, using: &rng))
                    .map { _ in boundaries(before).randomElement(using: &rng)! }
                    .sorted()
                var ranges = stride(from: 0, to: cuts.count, by: 2).map { cuts[$0]..<cuts[$0 + 1] }
                if step % 3 == 1 { ranges.reverse() }
                var shift = 0
                for range in ranges {
                    let start = step % 3 == 0 ? range.lowerBound + shift : range.lowerBound
                    let inserted = randomText(length: Int.random(in: 0...3, using: &rng), using: &rng)
                    let edit = buffer.edit(start..<start + range.count, with: inserted)
                    shift += edit.newRange.count - edit.oldRange.count
                    edits.append(edit)
                }
            }
            let after = Array(buffer.text.description.utf8)
            expectReplacements(edits, rebuild: after, from: before, precise: isMonotonic)

            let undone = buffer.undo()!
            expectReplacements(undone, rebuild: before, from: after, precise: isMonotonic)
        }
    }

    private func expectReplacements(_ edits: [BufferEdit], rebuild result: [UInt8], from original: [UInt8],
                                    precise: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let replacements = BufferEdit.replacements(for: edits, resultLength: result.count)
        #expect(zip(replacements, replacements.dropFirst()).allSatisfy { $0.old.upperBound < $1.old.lowerBound },
                sourceLocation: sourceLocation)
        var rebuilt = original
        for (old, new) in replacements.reversed() {
            rebuilt.replaceSubrange(old, with: result[new])
        }
        #expect(rebuilt == result, sourceLocation: sourceLocation)
        if precise {
            #expect(replacements.map(\.old.count).reduce(0, +) == edits.map(\.oldRange.count).reduce(0, +),
                    sourceLocation: sourceLocation)
        }
    }
}
