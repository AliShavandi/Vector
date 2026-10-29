//
//  HighlightQuery.swift
//  Vector
//
//  Created by Ali Shavandi on 2026-10-29.
//
//  A compiled tree-sitter highlight query. The C API matches patterns but leaves predicates (#match?, #eq?) to
//  the caller; they're evaluated here against the rope.
//

import Foundation
import OSLog
import TreeSitter

nonisolated struct HighlightCapture: Equatable, Sendable {
    var byteRange: Range<Int>
    /// Index into `HighlightQuery.captureNames`.
    var captureIndex: Int
}

/// `@unchecked Sendable`: the `TSQuery` is never mutated after creation, and each `captures` call uses its own cursor.
nonisolated final class HighlightQuery: @unchecked Sendable {
    /// `TSQuery *`
    private let query: OpaquePointer
    let captureNames: [String]
    /// Predicates per pattern index.
    private let predicates: [[Predicate]]

    private enum Predicate {
        case match(capture: UInt32, regex: NSRegularExpression, negated: Bool)
        case equalsString(capture: UInt32, value: String, negated: Bool)
        case equalsCapture(UInt32, UInt32, negated: Bool)
    }

    init?(language: OpaquePointer, source: String) {
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let utf8 = Array(source.utf8)
        guard let query = utf8.withUnsafeBufferPointer({ buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                ts_query_new(language, $0.baseAddress, UInt32($0.count), &errorOffset, &errorType)
            }
        }) else {
            Logger.syntax.error("Highlight query error \(errorType.rawValue) at byte \(errorOffset)")
            return nil
        }
        self.query = query

        captureNames = (0..<ts_query_capture_count(query)).map { id in
            var length: UInt32 = 0
            let name = ts_query_capture_name_for_id(query, id, &length)!
            return String(decoding: UnsafeRawBufferPointer(start: name, count: Int(length)), as: UTF8.self)
        }
        predicates = (0..<ts_query_pattern_count(query)).map { Self.predicates(of: query, pattern: $0) }
    }

    deinit {
        ts_query_delete(query)
    }

    /// Captures for nodes intersecting `byteRange`, in document order. Later captures should take precedence over
    /// earlier ones that overlap them.
    func captures(in byteRange: Range<Int>, of tree: SyntaxTree, text: Rope) -> [HighlightCapture] {
        let cursor = ts_query_cursor_new()
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_set_byte_range(cursor, UInt32(byteRange.lowerBound), UInt32(byteRange.upperBound))
        ts_query_cursor_exec(cursor, query, ts_tree_root_node(tree.pointer))

        var result: [HighlightCapture] = []
        var match = TSQueryMatch()
        var index: UInt32 = 0
        while ts_query_cursor_next_capture(cursor, &match, &index) {
            guard satisfiesPredicates(match, text: text) else { continue }
            let capture = match.captures[Int(index)]
            let range = Int(ts_node_start_byte(capture.node))..<Int(ts_node_end_byte(capture.node))
            result.append(HighlightCapture(byteRange: range, captureIndex: Int(capture.index)))
        }
        return result
    }

    private func satisfiesPredicates(_ match: TSQueryMatch, text: Rope) -> Bool {
        func capturedText(_ id: UInt32) -> String? {
            let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            guard let node = captures.first(where: { $0.index == id })?.node else { return nil }
            return text.string(in: Int(ts_node_start_byte(node))..<Int(ts_node_end_byte(node)))
        }

        for predicate in predicates[Int(match.pattern_index)] {
            switch predicate {
            case let .match(capture, regex, negated):
                guard let value = capturedText(capture) else { continue }
                let found = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
                if found == negated { return false }
            case let .equalsString(capture, expected, negated):
                guard let value = capturedText(capture) else { continue }
                if (value == expected) == negated { return false }
            case let .equalsCapture(first, second, negated):
                if (capturedText(first) == capturedText(second)) == negated { return false }
            }
        }
        return true
    }

    private static func predicates(of query: OpaquePointer, pattern: UInt32) -> [Predicate] {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, pattern, &count) else { return [] }

        func string(_ id: UInt32) -> String {
            var length: UInt32 = 0
            let value = ts_query_string_value_for_id(query, id, &length)!
            return String(decoding: UnsafeRawBufferPointer(start: value, count: Int(length)), as: UTF8.self)
        }

        // Steps are flat: [name, args..., Done, name, args..., Done, ...].
        var result: [Predicate] = []
        var current: [TSQueryPredicateStep] = []
        for step in UnsafeBufferPointer(start: steps, count: Int(count)) {
            guard step.type == TSQueryPredicateStepTypeDone else {
                current.append(step)
                continue
            }
            defer { current = [] }
            guard let first = current.first, first.type == TSQueryPredicateStepTypeString else { continue }
            let name = string(first.value_id)
            let args = current.dropFirst()
            let negated = name.hasPrefix("not-")
            switch (name, args.first, args.dropFirst().first) {
            case ("match?", let capture?, let pattern?), ("not-match?", let capture?, let pattern?):
                guard capture.type == TSQueryPredicateStepTypeCapture,
                      pattern.type == TSQueryPredicateStepTypeString,
                      let regex = try? NSRegularExpression(pattern: string(pattern.value_id)) else { break }
                result.append(.match(capture: capture.value_id, regex: regex, negated: negated))
            case ("eq?", let capture?, let other?), ("not-eq?", let capture?, let other?):
                guard capture.type == TSQueryPredicateStepTypeCapture else { break }
                result.append(other.type == TSQueryPredicateStepTypeCapture
                              ? .equalsCapture(capture.value_id, other.value_id, negated: negated)
                              : .equalsString(capture: capture.value_id, value: string(other.value_id), negated: negated))
            default:
                // Unknown predicates (and directives like #set!) don't filter matches.
                Logger.syntax.debug("Ignoring query predicate #\(name, privacy: .public)")
            }
        }
        return result
    }
}
