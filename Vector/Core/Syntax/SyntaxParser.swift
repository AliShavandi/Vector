//
//  SyntaxParser.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-25.
//
//  tree-sitter bindings: incremental parsing of Rope snapshots off the main thread. Each parse applies the
//  buffer's edits to the previous tree (ts_tree_edit) so tree-sitter reuses every unchanged subtree.
//

import Foundation
import OSLog
import TreeSitter

/// One owned `TSTree`. tree-sitter trees aren't safe to share across threads, but copies (`ts_tree_copy`, cheap and
/// reference-counted inside) are; so each thread gets its own instance. `@unchecked Sendable` on that basis: an
/// instance is handed off, never used from two threads at once.
nonisolated final class SyntaxTree: @unchecked Sendable {
    /// `TSTree *`
    let pointer: OpaquePointer
    /// Byte offset of a block comment opener that's never closed, when the grammar didn't make it a comment.
    /// Everything from here to the end of the text is comment. Set by `SyntaxParser` before the tree is handed off.
    fileprivate(set) var unterminatedBlockCommentStart: Int?

    init(taking pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        ts_tree_delete(pointer)
    }

    func copy() -> SyntaxTree {
        let copy = SyntaxTree(taking: ts_tree_copy(pointer))
        copy.unterminatedBlockCommentStart = unterminatedBlockCommentStart
        return copy
    }

    /// The tree as an S-expression, for tests and debugging.
    var sExpression: String {
        let string = ts_node_string(ts_tree_root_node(pointer))!
        defer { free(string) }
        return String(cString: string)
    }
}

/// Owns a `TSParser` and the latest tree for one document.
actor SyntaxParser {
    /// `TSParser *`
    private let parser: OpaquePointer
    private var tree: SyntaxTree?
    private let blockComment: (open: [UInt8], close: String)?
    /// Tells which text is inside strings and comments, where a comment opener means nothing.
    private let highlightQuery: HighlightQuery?
    /// Whether the most recent parse started from a previous tree.
    private(set) var lastParseReusedTree = false

    init(language: SyntaxLanguage) {
        parser = ts_parser_new()
        ts_parser_set_language(parser, language.tsLanguage)
        blockComment = language.blockComment.map { (Array($0.open.utf8), $0.close) }
        highlightQuery = language.highlightQuery
    }

    deinit {
        ts_parser_delete(parser)
    }

    /// Parses `text`, reusing the previous tree. `edits` must be every edit since the previous parse's snapshot, in
    /// the order they were made. Returns a copy of the new tree for the caller's thread.
    func parse(_ text: Rope, edits: [BufferEdit]) -> SyntaxTree {
        let start = ContinuousClock.now
        lastParseReusedTree = tree != nil
        if let tree {
            for edit in edits {
                var inputEdit = TSInputEdit(edit)
                ts_tree_edit(tree.pointer, &inputEdit)
            }
        }
        let input = RopeInput(text)
        let newTree = withExtendedLifetime(input) {
            ts_parser_parse(parser, tree?.pointer, input.tsInput)
        }
        // Only nil with a timeout or cancellation flag set, and we set neither.
        let parsed = SyntaxTree(taking: newTree!)
        parsed.unterminatedBlockCommentStart = unterminatedBlockCommentStart(in: text, tree: parsed)
        tree = parsed
        Logger.syntax.debug("""
            Parsed \(text.utf8Count) bytes (\(edits.count) edits, \(self.lastParseReusedTree ? "incremental" : "full", privacy: .public)) \
            in \(ContinuousClock.now - start, privacy: .public)
            """)
        return parsed.copy()
    }

    /// Finds the first block comment opener that the grammar lexed as a token of its own rather than as the start of
    /// a comment node, which is how an unclosed block comment comes out of some grammars. One pass over the bytes;
    /// each opener found is checked against the tree, and openers inside comments or strings are skipped.
    private func unterminatedBlockCommentStart(in text: Rope, tree: SyntaxTree) -> Int? {
        guard let (open, close) = blockComment else { return nil }
        let root = ts_tree_root_node(tree.pointer)
        var searchFrom = 0
        while let candidate = Self.firstOccurrence(of: open, in: text, from: searchFrom) {
            let node = ts_node_descendant_for_byte_range(root, UInt32(candidate), UInt32(candidate + open.count))
            var skipTo = Int(ts_node_end_byte(node))
            if Int(ts_node_start_byte(node)) == candidate && ts_node_child_count(node) == 0 {
                if let literalEnd = endOfStringOrComment(covering: candidate, tree: tree, text: text) {
                    skipTo = literalEnd
                } else {
                    let token = text.string(in: candidate..<skipTo)
                    let isClosedComment = token.utf8.count >= open.count + close.utf8.count && token.hasSuffix(close)
                    if !isClosedComment { return candidate }
                }
            }
            searchFrom = max(skipTo, candidate + 1)
        }
        return nil
    }

    /// If the highlight query puts `offset` inside a string or comment, the end of that capture. Uses capture names
    /// rather than node types, so it works for any grammar whose query follows the usual naming.
    private func endOfStringOrComment(covering offset: Int, tree: SyntaxTree, text: Rope) -> Int? {
        guard let query = highlightQuery else { return nil }
        return query.captures(in: offset..<offset + 1, of: tree, text: text)
            .filter { capture in
                let name = query.captureNames[capture.captureIndex]
                return capture.byteRange.contains(offset) && (name.hasPrefix("string") || name.hasPrefix("comment"))
            }
            .map(\.byteRange.upperBound)
            .max()
    }

    /// Byte offset of the first occurrence of `pattern` at or after `offset`. Jumps between candidate first bytes with
    /// `memchr`, since this runs on every parse. A match may straddle two chunks.
    private static func firstOccurrence(of pattern: [UInt8], in text: Rope, from offset: Int) -> Int? {
        guard offset < text.utf8Count else { return nil }
        var chunkStart = offset
        /// Bytes of `pattern` matched at the end of the previous chunk.
        var carried = 0
        for chunk in text.chunks(in: offset..<text.utf8Count) {
            let found = chunk.withUnsafeBufferPointer { bytes -> Int? in
                let base = bytes.baseAddress!
                var index = 0
                if carried > 0 {
                    while carried < pattern.count && index < bytes.count && bytes[index] == pattern[carried] {
                        carried += 1
                        index += 1
                    }
                    if carried == pattern.count { return chunkStart + index - pattern.count }
                    if index == bytes.count { return nil }  // still a partial match; keep carrying
                    carried = 0
                }
                while index < bytes.count, let hit = memchr(base + index, Int32(pattern[0]), bytes.count - index) {
                    let start = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    var length = 1
                    while length < pattern.count && start + length < bytes.count && bytes[start + length] == pattern[length] {
                        length += 1
                    }
                    if length == pattern.count { return chunkStart + start }
                    if start + length == bytes.count {
                        carried = length  // runs off the end of the chunk
                        return nil
                    }
                    index = start + 1
                }
                return nil
            }
            if let found { return found }
            chunkStart += chunk.count
        }
        return nil
    }
}

/// Feeds a Rope to tree-sitter. Each read copies one leaf chunk (at most `RopeNode.maxLeafBytes`) into a scratch
/// buffer, so tree-sitter never holds a pointer into rope storage.
private nonisolated final class RopeInput {
    private let text: Rope
    private let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: RopeNode.maxLeafBytes)

    init(_ text: Rope) {
        self.text = text
    }

    deinit {
        scratch.deallocate()
    }

    /// Valid while `self` is alive.
    var tsInput: TSInput {
        TSInput(
            payload: Unmanaged.passUnretained(self).toOpaque(),
            read: { payload, byteIndex, _, bytesRead in
                let input = Unmanaged<RopeInput>.fromOpaque(payload!).takeUnretainedValue()
                bytesRead!.pointee = UInt32(input.read(at: Int(byteIndex)))
                return UnsafeRawPointer(input.scratch).assumingMemoryBound(to: CChar.self)
            },
            encoding: TSInputEncodingUTF8,
            decode: nil
        )
    }

    /// Copies the chunk starting at `offset` into scratch; 0 at the end of the text.
    private func read(at offset: Int) -> Int {
        guard offset < text.utf8Count else { return 0 }
        var chunks = text.chunks(in: offset..<text.utf8Count).makeIterator()
        guard let chunk = chunks.next() else { return 0 }
        chunk.withUnsafeBufferPointer { scratch.update(from: $0.baseAddress!, count: $0.count) }
        return chunk.count
    }
}

private nonisolated extension TSInputEdit {
    init(_ edit: BufferEdit) {
        self.init(
            start_byte: UInt32(edit.oldRange.lowerBound),
            old_end_byte: UInt32(edit.oldRange.upperBound),
            new_end_byte: UInt32(edit.newRange.upperBound),
            start_point: TSPoint(edit.startPoint),
            old_end_point: TSPoint(edit.oldEndPoint),
            new_end_point: TSPoint(edit.newEndPoint)
        )
    }
}

private nonisolated extension TSPoint {
    init(_ point: Point) {
        self.init(row: UInt32(point.row), column: UInt32(point.column))
    }
}
