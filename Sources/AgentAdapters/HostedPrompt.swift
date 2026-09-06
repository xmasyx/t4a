//  HostedPrompt.swift — the input box the hosted program drew for itself, so
//  T4A can put its own bubble over it (ISC-114, EXPERIMENTAL).
//
//  This is the opposite job to SelectorPrompt.swift next door, and it borrows
//  that file's two shape tests rather than restating them: a probe that
//  rewrites the logic it depends on ends up measuring itself.
//
//  The rule that makes this safe is not a list of menus to look out for. It
//  is the other way round: NOTHING is covered unless a box is positively
//  recognised — two full-width rules, nothing but a prompt marker between
//  them, and the terminal's own cursor sitting inside it. Every departure
//  from that shape, whatever caused it, leaves the screen alone. A menu that
//  nobody thought of therefore reveals by default, which is the only failure
//  direction worth having: hiding a question a person is being asked is the
//  worst thing this feature could do.

import Foundation
import TerminalCore

/// The box a hosted TUI drew for its own input, in scroll-invariant rows.
public struct HostedPrompt: Equatable, Sendable {
    /// The rules that close the box, inclusive: what gets covered.
    public var topRule: Int
    public var bottomRule: Int
    /// The row carrying the prompt marker — where the cursor was.
    public var markerRow: Int
    public var marker: String
    public var rowCount: Int { bottomRule - topRule + 1 }
}

/// Cover, or the reason the screen was left alone. The reason is carried
/// rather than dropped because "nothing is covered" and "nothing was looked
/// at" are the same shape from outside, and only one of them is a defect.
public enum HostedPromptVerdict: Equatable, Sendable {
    case cover(HostedPrompt)
    case reveal(String)
}

@MainActor
public enum HostedPromptScanner {
    /// The marks a terminal UI puts at the head of its input line.
    static let markers: [Character] = [">", "❯", "›", "▶", "»"]

    /// How far above and below the cursor a rule may sit and still be this
    /// box's own. A prompt that has grown past this is a prompt with content
    /// in it, and content is a reason to reveal anyway.
    static let boxReach = 8

    private struct Box {
        var top: Int
        var bottom: Int
    }

    private enum BoxSearch {
        case found(Box)
        case reveal(String)
    }

    /// Whether the hosted program's own input line is drawn around the live
    /// cursor. Text after the marker is allowed: this answers whether the box
    /// may be hidden, not whether it is empty enough for `scan` to cover.
    ///
    /// This deliberately does not run the selector scan. The page already
    /// reveals selectors through its cached asking state, and a third selector
    /// pass per screen scan would pay again for a question already answered.
    public static func inputLine(_ grid: any TerminalGrid) -> Bool {
        guard case .found(let box) = box(aroundCursorIn: grid) else { return false }
        let firstInner = (grid.text(at: box.top + 1) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard let first = firstInner.first else { return false }
        return markers.contains(first)
    }

    public static func scan(_ grid: any TerminalGrid) -> HostedPromptVerdict {
        // 1. Anything the permission scanner recognises wins outright. It is
        //    the same code that raises the card in F4, so the two can never
        //    disagree about what a question looks like.
        //
        //    WITHOUT the caret test, deliberately. The card requires the caret
        //    inside the box because a card that answers the wrong prompt types
        //    into somebody's terminal (ISC-127); the cover has the opposite
        //    failure direction — hiding a question asked of a person is the
        //    worst thing this feature could do — so here any numbered question
        //    anywhere on the live screen uncovers, caret or no caret. One
        //    recogniser, two questions asked of it, and the two questions are
        //    allowed to be strict in opposite directions.
        if SelectorScanner.scan(grid, requireCursorInside: false) != nil {
            return .reveal("a selector is on screen")
        }

        let foundBox: Box
        switch box(aroundCursorIn: grid) {
        case .found(let found): foundBox = found
        case .reveal(let why): return .reveal(why)
        }

        // 4. What is between them is a marker and nothing else. This one test
        //    carries the whole slash-command case: `/` opens a list ABOVE the
        //    box and puts what you typed INSIDE it, and a box with anything in
        //    it is a box being used, so it is never covered. It also catches
        //    the completions, the recalled history, and the placeholder some
        //    versions draw — all of them, without knowing any of them.
        var marker = ""
        for row in (foundBox.top + 1)..<foundBox.bottom {
            var text = (grid.text(at: row) ?? "").trimmingCharacters(in: .whitespaces)
            if row == foundBox.top + 1, let first = text.first, markers.contains(first) {
                marker = String(first)
                text = String(text.dropFirst())
            }
            guard text.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .reveal("the prompt has text in it")
            }
        }
        guard !marker.isEmpty else { return .reveal("no prompt marker in the box") }

        // 5. Last, a line that names a key to press. It is checked HERE, in
        //    the few rows around the box, and deliberately not over the whole
        //    screen: the test is positional by design (SelectorPrompt uses it
        //    directly under a numbered run), and a coding agent's output says
        //    "select ... from table" often enough that a screen-wide search
        //    would be a reveal-always machine wearing a safety check's coat.
        let from = max(grid.liveScreenTopRow, foundBox.top - 3)
        for row in from..<grid.endRow where row < foundBox.top || row > foundBox.bottom {
            let text = grid.text(at: row) ?? ""
            if SelectorScanner.isFooter(text) {
                return .reveal("a line names a key: "
                    + text.trimmingCharacters(in: .whitespaces).prefix(60))
            }
        }

        return .cover(HostedPrompt(topRule: foundBox.top, bottomRule: foundBox.bottom,
                                   markerRow: foundBox.top + 1, marker: marker))
    }

    /// The one positional box finder shared by covering and page safety. Its
    /// result stops at geometry: the two callers intentionally disagree about
    /// whether text in the box and a nearby footer disqualify it.
    private static func box(aroundCursorIn grid: any TerminalGrid) -> BoxSearch {
        let end = grid.endRow
        let live = grid.liveScreenTopRow
        let cursorRow = grid.cursor.row
        guard end > live else { return .reveal("nothing on the live screen") }
        guard cursorRow >= live, cursorRow < end else {
            return .reveal("the cursor is not on the live screen")
        }

        // The cursor is where the next keystroke lands, so an older box
        // elsewhere on screen can never qualify as the live input line.
        func rule(_ row: Int) -> Bool {
            SelectorScanner.isRule(grid.text(at: row) ?? "")
        }
        var bottom = cursorRow
        while bottom < end, bottom - cursorRow <= boxReach, !rule(bottom) { bottom += 1 }
        guard bottom < end, bottom - cursorRow <= boxReach, rule(bottom) else {
            return .reveal("no rule under the cursor")
        }
        var top = cursorRow
        while top >= live, cursorRow - top <= boxReach, !rule(top) { top -= 1 }
        guard top >= live, cursorRow - top <= boxReach, rule(top) else {
            return .reveal("no rule over the cursor")
        }
        guard bottom - top >= 2 else { return .reveal("the cursor is on a rule") }

        let wide = max(20, grid.columns / 2)
        for row in [top, bottom] {
            let drawn = (grid.text(at: row) ?? "").trimmingCharacters(in: .whitespaces)
            guard drawn.count >= wide else { return .reveal("the rules are too short") }
        }
        return .found(Box(top: top, bottom: bottom))
    }
}
