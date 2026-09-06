//  FactsFeed.swift — what an outside program is allowed to put on the bar.
//
//  T4A knows what a terminal knows. Everything else a person might want down
//  there — how much of a budget is spent, which machine is warm, what a build
//  is doing — lives in programs T4A has never heard of, so the bar takes a
//  PATH and reads lines. No plugin, no protocol, no network: one executable
//  the user names, run every couple of seconds, and its standard output.
//
//  The line is `key<TAB>text[<TAB>tone]`. Repeating a key appends another
//  token to the same cell, each with its own tone, which is the whole reason
//  the format is not one line per cell: a ladder of model names, or a scale
//  of effort levels, is ONE reading whose words are coloured differently.
//  `#name<TAB>key<TAB>Label` gives the row the name a person reads IN THE
//  SETTINGS. It is not a caption: the bar draws the tokens and nothing else.
//
//  This file is the parser and nothing else — no process, no timer, no view —
//  so the contract can be tested without a window (and it is, in
//  `FactsFeedTests`). What it refuses matters as much as what it accepts: a
//  key is a name that ends up inside `dash-slots`, where `,` `|` and `:`
//  separate things, so a key carrying one of those would quietly corrupt the
//  saved layout of the whole bar. Those lines are refused and said out loud.

import Foundation

/// The eight words a provider may use to colour a token. They are names of
/// MEANINGS, not of colours: the theme decides what `critical` looks like, and
/// a theme that changes its reds does not change what a provider writes.
public enum FactTone: String, Sendable, CaseIterable {
    case ok, warn, critical, live, used, dim, accent, muted
}

/// One word of a cell, with the tone it asked for. `tone == nil` is a token
/// that did not ask, drawn in whatever the bar draws a calm value in.
public struct FactToken: Equatable, Sendable {
    public let text: String
    public let tone: FactTone?

    public init(text: String, tone: FactTone? = nil) {
        self.text = text
        self.tone = tone
    }
}

/// One row of the bar, as the provider described it.
public struct FactRow: Equatable, Sendable {
    public let key: String
    /// The name a person reads in the SETTINGS, from a `#name` line. It is
    /// never drawn on the bar: the readings a provider sends carry their own
    /// caption (`MEMORY`, `CONTEXT`, `5HR`), so printing the row's name beside
    /// them would say everything twice and charge the width to the rows that
    /// then do not fit — measured, it cost four of nine rows their place.
    /// `nil` or empty means the provider never named it, and the settings fall
    /// back to the key.
    public var label: String?
    public var tokens: [FactToken]

    public init(key: String, label: String? = nil, tokens: [FactToken] = []) {
        self.key = key
        self.label = label
        self.tokens = tokens
    }

    /// The whole reading as one string, which is what the bar measures and
    /// what a dump prints.
    public var text: String { tokens.map(\.text).joined(separator: " ") }
}

public enum FactsFeed {
    /// What a run of the provider produced: the rows in the order the keys
    /// first appeared, and every line that could not be read.
    public struct Reading: Equatable, Sendable {
        public var rows: [FactRow] = []
        public var problems: [String] = []
        public func row(_ key: String) -> FactRow? { rows.first { $0.key == key } }
    }

    /// A key becomes part of `dash-slots` on disk and part of the settings
    /// list on screen, so it is a NAME and not free text. Anything outside
    /// this is refused rather than escaped: escaping would make the config
    /// file unreadable, which is the one thing this app promised not to do.
    public static func isValidKey(_ key: String) -> Bool {
        guard (1...32).contains(key.count) else { return false }
        var first = true
        for character in key.unicodeScalars {
            let alphanumeric = (character >= "a" && character <= "z")
                || (character >= "A" && character <= "Z")
                || (character >= "0" && character <= "9")
            if first {
                guard alphanumeric else { return false }
                first = false
                continue
            }
            guard alphanumeric || character == "-" || character == "_" else { return false }
        }
        return true
    }

    public static func parse(_ output: String) -> Reading {
        var reading = Reading()
        var index: [String: Int] = [:]
        var labels: [String: String] = [:]

        func note(_ message: String) {
            guard !reading.problems.contains(message) else { return }
            reading.problems.append(message)
        }

        for rawLine in output.components(separatedBy: .newlines) {
            // Only the ends are trimmed of whitespace that is not a tab: a
            // token may legitimately be ` │ ` and the tab is the separator.
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \r\n"))
            if line.isEmpty { continue }
            let fields = line.components(separatedBy: "\t")

            if fields[0] == "#name" {
                guard fields.count >= 3 else {
                    note("#name needs a key and a label: \(shorten(line))")
                    continue
                }
                let key = fields[1]
                guard isValidKey(key) else {
                    note("not a usable key: \(shorten(key))")
                    continue
                }
                labels[key] = fields[2]
                if let at = index[key] { reading.rows[at].label = fields[2] }
                continue
            }
            // A line the provider meant as a comment, and any other directive
            // we do not know, is ignored rather than printed on the bar.
            if fields[0].hasPrefix("#") { continue }

            guard fields.count >= 2 else {
                note("a line with no tab is not a reading: \(shorten(line))")
                continue
            }
            let key = fields[0]
            guard isValidKey(key) else {
                note("not a usable key: \(shorten(key))")
                continue
            }
            var tone: FactTone?
            if fields.count >= 3, !fields[2].isEmpty {
                tone = FactTone(rawValue: fields[2].lowercased())
                if tone == nil { note("unknown tone \(shorten(fields[2])) on \(key)") }
            }
            let token = FactToken(text: fields[1], tone: tone)
            if let at = index[key] {
                reading.rows[at].tokens.append(token)
            } else {
                index[key] = reading.rows.count
                reading.rows.append(FactRow(key: key, label: labels[key], tokens: [token]))
            }
        }
        return reading
    }

    /// The tokens that fit in `characters`, with `…` marking what was cut.
    ///
    /// It cuts the TEXT and keeps the TONES, because a truncated ladder whose
    /// remaining words lost their colours would be worse than the truncation:
    /// the colour is the reading. A cut that would leave nothing keeps one
    /// character, so a cell never becomes an ellipsis on its own.
    public static func clip(_ tokens: [FactToken], to characters: Int) -> [FactToken] {
        let whole = tokens.map(\.text).joined(separator: " ")
        guard characters >= 1, whole.count > characters else { return tokens }
        let budget = max(1, characters - 1)   // one character for the ellipsis
        var out: [FactToken] = []
        var used = 0
        for token in tokens {
            let separator = out.isEmpty ? 0 : 1
            if used + separator + token.text.count <= budget {
                used += separator + token.text.count
                out.append(token)
                continue
            }
            let room = budget - used - separator
            if room > 0 {
                out.append(FactToken(text: String(token.text.prefix(room)) + "…",
                                     tone: token.tone))
            } else if out.isEmpty {
                out.append(FactToken(text: String(token.text.prefix(1)) + "…",
                                     tone: token.tone))
            } else {
                let last = out.removeLast()
                out.append(FactToken(text: last.text + "…", tone: last.tone))
            }
            return out
        }
        return out
    }

    private static func shorten(_ text: String) -> String {
        text.count <= 40 ? text : String(text.prefix(40)) + "…"
    }
}
