//  TerminalLink.swift — links inferred from terminal text while Command is held.
//
//  A terminal cell carries colour and style, not meaning. This detector is the
//  deliberately small bridge from cells to meaning: it joins soft-wrapped
//  rows, extracts the token under one cell, and classifies only web URLs and
//  absolute paths that a caller confirms exist. The filesystem question is an
//  injected closure so every boundary and classification rule stays pure.

import Foundation

public enum TerminalLinkKind: String, Equatable, Sendable {
    case file
    case directory
    case url
}

public struct TerminalLink: Equatable, Sendable {
    /// The characters as printed by the terminal, without surrounding quotes.
    public let text: String
    /// The value to open: escaped spaces and `~` have already been resolved.
    public let target: String
    public let kind: TerminalLinkKind
    /// The `:line` claude and compilers print after a path (`file.swift:123:7`).
    /// Part of the printed text and the underline, never of `target`.
    public let line: Int?

    public init(text: String, target: String, kind: TerminalLinkKind, line: Int? = nil) {
        self.text = text
        self.target = target
        self.kind = kind
        self.line = line
    }
}

public struct TerminalLinkMatch: Equatable, Sendable {
    public let link: TerminalLink
    /// Cell coordinates relative to the `lines` passed to `detect`.
    public let span: GridSpan

    public init(link: TerminalLink, span: GridSpan) {
        self.link = link
        self.span = span
    }
}

public enum TerminalLinkDetector {
    /// Finds and classifies the token under `hovered`.
    ///
    /// `lines` are adjacent grid rows. `isWrapped` has SwiftTerm semantics:
    /// true means this row continues the preceding one. Only the logical line
    /// containing `hovered` is joined. `inspectPath` is the sole impure edge;
    /// production supplies a stat-backed answer and tests supply a fixture.
    ///
    /// `workingDirectory` is what makes claude's own output clickable: it
    /// prints `Sources/T4A/PaneView.swift:123`, relative to the process, with
    /// a line suffix and often inside `Update(...)` or before a comma. Without
    /// it only absolute and `~` paths resolve (3/09: his «non funziona ancora»
    /// after the echo-based bench had passed on absolute paths).
    public static func detect(
        in lines: [GridLine],
        hovered: GridPosition,
        homeDirectory: String,
        workingDirectory: String? = nil,
        inspectPath: (String) -> TerminalLinkKind?
    ) -> TerminalLinkMatch? {
        guard lines.indices.contains(hovered.row), hovered.column >= 0 else { return nil }

        var first = hovered.row
        while first > lines.startIndex, lines[first].isWrapped { first -= 1 }
        var last = hovered.row
        while last + 1 < lines.endIndex, lines[last + 1].isWrapped { last += 1 }

        struct CellRef {
            let character: Character
            let position: GridPosition
            let width: Int
        }
        var cells: [CellRef] = []
        for row in first...last {
            for (column, cell) in lines[row].cells.enumerated() where cell.width > 0 {
                cells.append(CellRef(character: cell.text,
                                     position: GridPosition(column: column, row: row),
                                     width: cell.width))
            }
        }
        // Only the final visual row owns padding. Blanks at the end of an
        // intermediate wrapped row are real cells in the logical line.
        while cells.last?.character == " " { cells.removeLast() }
        guard let hoveredOffset = cells.firstIndex(where: {
            $0.position.row == hovered.row
                && hovered.column >= $0.position.column
                && hovered.column < $0.position.column + max(1, $0.width)
        }) else { return nil }

        let characters = cells.map(\.character)
        guard var token = tokenRange(in: characters, containing: hoveredOffset) else { return nil }

        // A URL may sit directly after prose punctuation. Its scheme is a
        // stronger left boundary than the surrounding terminal token.
        if let scheme = urlStart(in: characters, range: token) {
            token = scheme..<trimmedURLEnd(in: characters, start: scheme,
                                           proposedEnd: token.upperBound)
        }
        guard token.contains(hoveredOffset), !token.isEmpty else { return nil }

        let raw = String(characters[token])
        let link: TerminalLink
        if isWebURL(raw) {
            link = TerminalLink(text: raw, target: raw, kind: .url)
        } else {
            guard let hit = resolvePath(in: characters, token: token, hovered: hoveredOffset,
                                        homeDirectory: homeDirectory,
                                        workingDirectory: workingDirectory,
                                        inspectPath: inspectPath) else { return nil }
            token = hit.range
            link = hit.link
        }

        let start = cells[token.lowerBound].position
        let final = cells[token.upperBound - 1]
        let end = GridPosition(column: final.position.column + max(1, final.width),
                               row: final.position.row)
        return TerminalLinkMatch(link: link, span: GridSpan(start: start, end: end))
    }

    /// Characters prose or a tool call wraps around a path. A candidate may
    /// start after any of the openers and end before any of the closers.
    private static let openers: Set<Character> = ["(", "[", "<", "{", "'", "`", "\""]
    private static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]",
                                                   "}", ">", "'", "`", "\""]

    /// Tries the printed token, then progressively narrower pieces of it, in
    /// order of fidelity: whole token first, then without a `:line[:col]`
    /// suffix, then without trailing punctuation, then from inside an opener.
    /// The first piece the filesystem confirms wins. Bounded: at most a few
    /// stats per hover, and none at all without Command held (the caller).
    private static func resolvePath(
        in characters: [Character], token: Range<Int>, hovered: Int,
        homeDirectory: String, workingDirectory: String?,
        inspectPath: (String) -> TerminalLinkKind?
    ) -> (link: TerminalLink, range: Range<Int>)? {
        var starts = [token.lowerBound]
        for index in token where index > token.lowerBound && index <= hovered
            && openers.contains(characters[index - 1]) {
            starts.append(index)
        }
        for start in starts {
            for candidate in candidateEnds(in: characters, start: start,
                                           upper: token.upperBound, hovered: hovered) {
                let path = String(characters[start..<candidate.pathEnd])
                guard let target = expand(path, homeDirectory: homeDirectory,
                                          workingDirectory: workingDirectory) else { continue }
                guard let kind = inspectPath(target), kind != .url else { continue }
                let text = String(characters[start..<candidate.textEnd])
                return (TerminalLink(text: text, target: target, kind: kind,
                                     line: candidate.line),
                        start..<candidate.textEnd)
            }
        }
        return nil
    }

    private struct EndCandidate {
        /// Where the printed link (and its underline) ends.
        let textEnd: Int
        /// Where the filesystem path ends: before a `:line[:col]` suffix.
        let pathEnd: Int
        let line: Int?
    }

    /// Ends to try, widest first. A `:line[:col]` suffix leaves the text and
    /// the underline whole and shortens only the path; trailing punctuation
    /// shortens both. Every candidate still covers the hovered cell.
    private static func candidateEnds(in characters: [Character], start: Int,
                                      upper: Int, hovered: Int) -> [EndCandidate] {
        var out: [EndCandidate] = []
        var end = upper
        var steps = 0
        while end > hovered, end > start, steps < 8 {
            steps += 1
            if let (cut, number) = lineSuffix(in: characters, start: start, end: end) {
                out.append(EndCandidate(textEnd: end, pathEnd: cut, line: number))
                end = cut
                continue
            }
            out.append(EndCandidate(textEnd: end, pathEnd: end, line: nil))
            guard closers.contains(characters[end - 1]) else { break }
            end -= 1
        }
        return out
    }

    /// `:123` or `:123:7` at the end of `characters[start..<end]`.
    private static func lineSuffix(in characters: [Character], start: Int,
                                   end: Int) -> (Int, Int)? {
        func digits(before index: Int) -> (Int, Int)? {
            var cursor = index
            while cursor > start, characters[cursor - 1].isNumber { cursor -= 1 }
            guard cursor < index, cursor > start, characters[cursor - 1] == ":" else { return nil }
            guard let value = Int(String(characters[cursor..<index])) else { return nil }
            return (cursor - 1, value)
        }
        guard let (colon, last) = digits(before: end) else { return nil }
        if let (earlier, first) = digits(before: colon) {
            return (earlier, first)
        }
        return (colon, last)
    }

    /// The printed form to an absolute, standardized path, or nil when the
    /// text cannot name a file: empty, only dots, or relative with no
    /// directory to be relative to.
    private static func expand(_ text: String, homeDirectory: String,
                               workingDirectory: String?) -> String? {
        let unescaped = text.replacingOccurrences(of: "\\ ", with: " ")
        guard !unescaped.isEmpty else { return nil }
        let expanded: String
        if unescaped == "~" {
            expanded = homeDirectory
        } else if unescaped.hasPrefix("~/") {
            expanded = homeDirectory + String(unescaped.dropFirst())
        } else if unescaped.hasPrefix("/") {
            expanded = unescaped
        } else {
            guard let workingDirectory,
                  unescaped.count >= 2,
                  unescaped.contains(where: { $0 != "." }),
                  !unescaped.split(separator: "/", omittingEmptySubsequences: false)
                      .allSatisfy({ $0.isEmpty || $0.allSatisfy { $0 == "." } })
            else { return nil }
            expanded = workingDirectory + "/" + unescaped
        }
        return (expanded as NSString).standardizingPath
    }

    /// Shell-like token boundaries needed by the claim: quotes own the spaces
    /// inside them, and a backslash owns the next character.
    private static func tokenRange(in characters: [Character],
                                   containing hovered: Int) -> Range<Int>? {
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
                continue
            }
            if characters[index] == "\"" {
                let start = index + 1
                index = start
                while index < characters.count {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 2
                    } else if characters[index] == "\"" {
                        break
                    } else {
                        index += 1
                    }
                }
                let range = start..<index
                if range.contains(hovered) { return range }
                index += index < characters.count ? 1 : 0
                continue
            }

            let start = index
            while index < characters.count {
                if characters[index] == "\\", index + 1 < characters.count {
                    index += 2
                } else if characters[index].isWhitespace || characters[index] == "\"" {
                    break
                } else {
                    index += 1
                }
            }
            let range = start..<index
            if range.contains(hovered) { return range }
        }
        return nil
    }

    private static func urlStart(in characters: [Character], range: Range<Int>) -> Int? {
        let lower = range.lowerBound
        let token = String(characters[range])
        let offsets = [token.range(of: "https://"), token.range(of: "http://")]
            .compactMap { $0 }
            .map { token.distance(from: token.startIndex, to: $0.lowerBound) }
        return offsets.min().map { lower + $0 }
    }

    /// Markdown-style prose often surrounds a URL with parentheses. A closing
    /// parenthesis belongs to the link only when the link contains its mate.
    private static func trimmedURLEnd(in characters: [Character], start: Int,
                                      proposedEnd: Int) -> Int {
        var end = proposedEnd
        while end > start, characters[end - 1] == ")" {
            let body = characters[start..<end]
            let opens = body.filter { $0 == "(" }.count
            let closes = body.filter { $0 == ")" }.count
            guard closes > opens else { break }
            end -= 1
        }
        return end
    }

    private static func isWebURL(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text),
              parts.scheme == "http" || parts.scheme == "https",
              let host = parts.host, !host.isEmpty else { return false }
        return true
    }
}
