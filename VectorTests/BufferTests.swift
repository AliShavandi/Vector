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

/// Deterministic RNG so randomized failures reproduce.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

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
}
