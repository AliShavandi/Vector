//
//  SyntaxLanguage.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-29.
//
//  Registry of tree-sitter grammars. Adding a language is one entry here (grammar + where its queries live);
//  nothing else in core knows about specific languages.
//

import Foundation
import OSLog
import TreeSitter
import TreeSitterSwift

/// A tree-sitter grammar plus its highlight query. `@unchecked Sendable`: the `TSLanguage` is immutable static
/// data from the grammar, and `HighlightQuery` is read-only after creation.
nonisolated final class SyntaxLanguage: @unchecked Sendable {
    let name: String
    let fileExtensions: Set<String>
    /// `const TSLanguage *`
    let tsLanguage: OpaquePointer
    /// Nil if the grammar's query couldn't be loaded; the file still parses, just without colors.
    let highlightQuery: HighlightQuery?
    /// Block comment delimiters, if the language has them. Some grammars (tree-sitter-swift among them) emit no
    /// comment node for a block comment that's never closed, lexing the opener as an ordinary token instead;
    /// `SyntaxParser` uses these to find that case so the rest of the file can still be shown as a comment.
    let blockComment: (open: String, close: String)?

    /// - Parameter queriesBundle: the grammar package's SwiftPM resource bundle, which holds `queries/highlights.scm`.
    init(name: String, fileExtensions: Set<String>, tsLanguage: OpaquePointer, queriesBundle: String,
         blockComment: (open: String, close: String)? = nil) {
        self.name = name
        self.fileExtensions = fileExtensions
        self.tsLanguage = tsLanguage
        self.blockComment = blockComment
        let source = Bundle.main.url(forResource: queriesBundle, withExtension: "bundle")
            .flatMap(Bundle.init(url:))?
            .url(forResource: "highlights", withExtension: "scm", subdirectory: "queries")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if let source {
            highlightQuery = HighlightQuery(language: tsLanguage, source: source)
        } else {
            Logger.syntax.error("No highlights.scm for \(name, privacy: .public) in \(queriesBundle, privacy: .public)")
            highlightQuery = nil
        }
    }

    static let swift = SyntaxLanguage(
        name: "Swift", fileExtensions: ["swift"],
        tsLanguage: tree_sitter_swift(), queriesBundle: "TreeSitterSwift_TreeSitterSwift",
        blockComment: ("/*", "*/")
    )

    static let all: [SyntaxLanguage] = [swift]

    static func forFile(_ url: URL) -> SyntaxLanguage? {
        let fileExtension = url.pathExtension.lowercased()
        return all.first { $0.fileExtensions.contains(fileExtension) }
    }
}

nonisolated extension Logger {
    static let syntax = Logger(subsystem: "com.alishavandi.Vector", category: "Syntax")
}
