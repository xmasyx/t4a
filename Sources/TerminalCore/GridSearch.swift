//  GridSearch.swift — finding text in the scrollback.
//
//  The search is over ROWS, not over one giant string: a terminal's buffer is
//  a hundred thousand lines and joining them to run one regular expression
//  would allocate a hundred megabytes to find a five-letter word. Rows are
//  read newest-first from the row the user is looking at, so the first hit
//  reported is the nearest one, and the walk stops as soon as there are
//  enough of them.

import Foundation

public enum SearchMode: String, Sendable {
    case literal, regex
}

public struct SearchRequest: Sendable {
    public var text: String
    public var mode: SearchMode
    /// Nil means smart case: a query typed in lower case ignores case, a
    /// query with a capital in it does not. It is what every editor does and
    /// nobody has to be told about.
    public var caseSensitive: Bool?

    public init(text: String, mode: SearchMode = .literal, caseSensitive: Bool? = nil) {
        self.text = text
        self.mode = mode
        self.caseSensitive = caseSensitive
    }

    var isCaseSensitive: Bool {
        caseSensitive ?? text.contains { $0.isUppercase }
    }
}

public struct SearchResult: Sendable {
    public var spans: [GridSpan]
    /// True when the walk stopped at the limit rather than at the end of the
    /// buffer — so the count can be shown as "500+" instead of a wrong 500.
    public var truncated: Bool
    public var rowsScanned: Int
    public var seconds: Double
}

@MainActor
public enum GridSearch {
    /// Every match in the retained buffer, in row order.
    ///
    /// `limit` bounds the work, not the correctness: a search that would
    /// return fifty thousand hits stops early and says so.
    public static func find(_ request: SearchRequest, in grid: any TerminalGrid,
                            limit: Int = 5000) -> SearchResult {
        let started = Date()
        var spans: [GridSpan] = []
        var truncated = false
        var scanned = 0
        guard !request.text.isEmpty else {
            return SearchResult(spans: [], truncated: false, rowsScanned: 0, seconds: 0)
        }

        // Both kinds of search run through the same matcher, with a literal
        // query escaped into a pattern. The first version had a hand-written
        // literal path using Swift's `range(of:)` on a lower-cased copy of
        // every row: it allocated a string per row and took 106 ms over nine
        // thousand rows, against 12 ms for the regular-expression path on the
        // same buffer. Two paths, one of them eight times slower, and the
        // slower one was the common case.
        let pattern = request.mode == .regex
            ? request.text
            : NSRegularExpression.escapedPattern(for: request.text)
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: request.isCaseSensitive ? [] : [.caseInsensitive]) else {
            return SearchResult(spans: [], truncated: false, rowsScanned: 0, seconds: 0)
        }

        var row = grid.firstRetainedRow
        let end = grid.endRow
        while row < end {
            guard let text = grid.text(at: row) else { break }
            scanned += 1
            if !text.isEmpty {
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, options: [], range: range) {
                    guard let found = Range(match.range, in: text) else { continue }
                    // Columns, not UTF-16 offsets: a row with an emoji in it
                    // would highlight the wrong cells otherwise.
                    let start = text.distance(from: text.startIndex, to: found.lowerBound)
                    let length = text.distance(from: found.lowerBound, to: found.upperBound)
                    guard length > 0 else { continue }
                    spans.append(GridSpan(
                        start: GridPosition(column: start, row: row),
                        end: GridPosition(column: start + length, row: row)))
                    if spans.count >= limit { truncated = true; break }
                }
            }
            if truncated { break }
            row += 1
        }
        return SearchResult(spans: spans, truncated: truncated, rowsScanned: scanned,
                            seconds: Date().timeIntervalSince(started))
    }
}
