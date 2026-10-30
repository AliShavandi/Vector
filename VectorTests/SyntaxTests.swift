//
//  SyntaxTests.swift
//  VectorTests
//
//  Created by Ali Shavandi on 2026-10-29.
//

import Foundation
import Testing
@testable import Vector

private let sample = """
    import Foundation

    /// A point in 2D.
    struct Point: Equatable {
        var x: Double
        var y: Double

        func distance(to other: Point) -> Double {
            let dx = x - other.x, dy = y - other.y
            return (dx * dx + dy * dy).squareRoot()
        }
    }

    // Entry point
    let origin = Point(x: 0, y: 0)
    print("distance: \\(origin.distance(to: Point(x: 3, y: 4)))")

    enum Shape {
        case circle(radius: Double)
        case square(side: Double)

        var area: Double {
            switch self {
            case .circle(let r): return .pi * r * r
            case .square(let s): return s * s
            }
        }
    }
    """

/// Fragments that make edits syntactically interesting: they open and close strings, comments, and blocks.
private let snippets = ["x", " ", "\n", "func f() {", "}", "{", "\"", "/*", "*/", "// c\n", "let a = 1\n", "(", ")", "é", "😀", ".pi"]

struct SyntaxTests {
    @Test func swiftLanguageLoadsWithHighlightQuery() throws {
        let query = try #require(SyntaxLanguage.swift.highlightQuery)
        #expect(query.captureNames.contains("keyword"))
        #expect(SyntaxLanguage.forFile(URL(filePath: "/tmp/a.swift")) === SyntaxLanguage.swift)
        #expect(SyntaxLanguage.forFile(URL(filePath: "/tmp/a.txt")) == nil)
    }

    /// Incremental parsing only works if every TSInputEdit exactly matches the text change; a wrong byte or point
    /// silently corrupts the tree. So after each random edit, the incrementally updated tree must equal a parse of
    /// the same text from scratch.
    @Test(arguments: [1, 2, 3] as [UInt64])
    func incrementalParseMatchesFullParse(seed: UInt64) async throws {
        var rng = SplitMix64(state: seed)
        var buffer = TextBuffer(sample)
        let incremental = SyntaxParser(language: .swift)
        _ = await incremental.parse(buffer.text, edits: [])

        for step in 0..<150 {
            let text = buffer.text
            let count = text.utf8Count
            let start = text.clipOffset(Int.random(in: 0...count, using: &rng), bias: .backward)
            let length = Int.random(in: 0..<4, using: &rng) == 0 ? Int.random(in: 0...20, using: &rng) : 0
            let end = text.clipOffset(min(start + length, count), bias: .forward)
            let inserted = Int.random(in: 0..<5, using: &rng) == 0 ? "" : snippets.randomElement(using: &rng)!
            var edits = [buffer.edit(start..<end, with: inserted)]

            // Sometimes undo, which hands back inverted edits.
            if step % 17 == 16, let undone = buffer.undo() {
                edits += undone
            }

            let updated = await incremental.parse(buffer.text, edits: edits)
            #expect(await incremental.lastParseReusedTree)
            let fresh = await SyntaxParser(language: .swift).parse(buffer.text, edits: [])
            try #require(updated.sExpression == fresh.sExpression, "step \(step): trees diverged")
        }
    }

    /// Multi-cursor edits reach the parser as several edits per transaction (and undo hands back their inverses);
    /// the incremental tree must still match a fresh parse.
    @Test(arguments: [4, 5] as [UInt64])
    func multiCursorEditsParseIncrementally(seed: UInt64) async throws {
        var rng = SplitMix64(state: seed)
        var editor = EditorState(buffer: TextBuffer(sample))
        let incremental = SyntaxParser(language: .swift)
        _ = await incremental.parse(editor.buffer.text, edits: [])

        for step in 0..<120 {
            if editor.selections.count < 4 || Int.random(in: 0..<6, using: &rng) == 0 {
                let text = editor.buffer.text
                editor.selections.add(.caret(text.clipOffset(Int.random(in: 0...text.utf8Count, using: &rng), bias: .backward)))
            }
            let edits: [BufferEdit]
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<5: edits = editor.insert(snippets.randomElement(using: &rng)!)
            case 5..<8: edits = editor.delete(.backward)
            case 8: edits = editor.delete(.wordForward)
            default: edits = editor.undo() ?? []
            }
            if step % 10 == 9 { editor.selections.collapseToPrimary() }

            let updated = await incremental.parse(editor.buffer.text, edits: edits)
            let fresh = await SyntaxParser(language: .swift).parse(editor.buffer.text, edits: [])
            try #require(updated.sExpression == fresh.sExpression, "step \(step): trees diverged")
        }
    }

    @Test func highlightCaptures() async throws {
        let source = """
            /// Docs
            struct Foo {
                func bar() -> Int { return 42 }
            }
            let s = "hi" // note
            """
        let text = Rope(source)
        let tree = await SyntaxParser(language: .swift).parse(text, edits: [])
        let query = try #require(SyntaxLanguage.swift.highlightQuery)
        let captures = query.captures(in: 0..<text.utf8Count, of: tree, text: text).map {
            (text: text.string(in: $0.byteRange), name: query.captureNames[$0.captureIndex])
        }
        func names(of fragment: String) -> Set<String> {
            Set(captures.filter { $0.text == fragment }.map(\.name))
        }

        #expect(names(of: "struct").contains { $0.hasPrefix("keyword") })
        #expect(names(of: "func").contains("keyword.function"))
        #expect(names(of: "return").contains("keyword.return"))
        #expect(names(of: "Foo").contains("type"))
        #expect(names(of: "Int").contains("type"))
        #expect(names(of: "42").contains("number"))
        #expect(captures.contains { $0.text.contains("hi") && $0.name == "string" })
        #expect(names(of: "// note").contains("comment"))
        #expect(names(of: "/// Docs").contains("comment.documentation"))  // via #match?

        // A capture range limited to the last line shouldn't return captures from the first.
        let lastLine = text.lineRange(text.lineCount - 1)
        let limited = query.captures(in: lastLine, of: tree, text: text)
        #expect(!limited.isEmpty)
        #expect(limited.allSatisfy { $0.byteRange.upperBound > lastLine.lowerBound })
    }

    /// tree-sitter-swift lexes an unclosed `/*` as an operator, so the parser has to find it for the highlighter.
    @Test(arguments: [
        ("/* top\nstruct S {}\n", 0),
        ("let a = 1\n/* open\nlet x = 2\n", 10),
        ("/* closed */\nlet x = 1 /* open", 23),
        ("func f() {\n    /* open in a body\n}\n", 15),
        ("/* outer /* nested */ still open\nlet x = 1", 0),  // Swift block comments nest
        // `/` ends the first 1 KB rope leaf and `*` starts the second.
        (String(repeating: " ", count: 1023) + "/*" + String(repeating: " ", count: 2000) + "\nlet x = 1", 1023),
        ("let a = 1 /* c */ + 2\n", nil),
        ("let s = \"/* in a string\"\n", nil),
        ("// line /* comment\nlet x = 1\n", nil),
        ("let x = 4 / 2 * 3\n", nil),
    ] as [(String, Int?)])
    func unterminatedBlockComment(source: String, expected: Int?) async {
        let tree = await SyntaxParser(language: .swift).parse(Rope(source), edits: [])
        #expect(tree.unterminatedBlockCommentStart == expected)
        #expect(tree.copy().unterminatedBlockCommentStart == expected)
    }

    /// Typing the `*` of `/*` (and then the closing `*/`) must flip the result through incremental parses too.
    @Test func unterminatedBlockCommentTracksEdits() async {
        var buffer = TextBuffer("let a = 1\nlet b = 2\n")
        let parser = SyntaxParser(language: .swift)
        _ = await parser.parse(buffer.text, edits: [])

        let opened = [buffer.edit(0..<0, with: "/"), buffer.edit(1..<1, with: "*")]
        #expect(await parser.parse(buffer.text, edits: opened).unterminatedBlockCommentStart == 0)

        let closed = buffer.edit(buffer.text.utf8Count..<buffer.text.utf8Count, with: "*/")
        #expect(await parser.parse(buffer.text, edits: [closed]).unterminatedBlockCommentStart == nil)
    }
}
