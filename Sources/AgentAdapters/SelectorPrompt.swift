//  SelectorPrompt.swift — reading a terminal UI's numbered question off the
//  grid, without pretending to be it.
//
//  A CLI agent asks for permission by DRAWING a box and waiting for a
//  keystroke. There is no file to read: measured across the whole transcript
//  estate on 2026-08-20, a permission that has not been answered yet leaves no
//  record of any kind — the tool call is written, and the next line does not
//  appear until a human has decided. So the only place a pending permission
//  exists is on the screen.
//
//  That is why T4A can do this and a wrapper cannot: it already owns the grid.
//  What follows reads the box; it never re-implements the decision. The answer
//  travels back as the keystroke a person would have typed.

import Foundation
import TerminalCore

/// One numbered choice as it was drawn.
struct SelectorOption {
    var number: Int
    var label: String
    /// True for the line carrying the selection marker.
    var isCurrent: Bool
}

/// What kind of numbered question this is (ISC-122).
enum SelectorKind {
    /// "May I do X?" — one thing is being asked, and the answers are the two
    /// halves of a decision. This is the only kind that gets a card.
    case permission
    /// "Which of these?" — a list of choices that stand beside each other,
    /// like `/model`. Nothing is being approved, so nothing is offered.
    case selector
}

/// What the recogniser made of a numbered question, and the two halves it
/// found while deciding. Carrying them is the whole of ISC-130: the card's
/// buttons and the classification must be one answer, not two agreeing ones.
struct SelectorDecision {
    var kind: SelectorKind
    var reason: String
    /// The option that means "go ahead", if the drawing offers one.
    var yes: SelectorOption?
    /// The option that means "no", if the drawing offers one.
    var no: SelectorOption?
}

/// A numbered question found on the live screen.
struct SelectorPrompt {
    /// The first non-empty line of the box: "Bash command", "Edit file".
    var title: String
    /// Everything between the title and the options, blanks dropped.
    var detail: [String]
    var options: [SelectorOption]
    /// Scroll-invariant row where the box's first line sits.
    var firstRow: Int
    /// Scroll-invariant row of the footer, or of the last option when a yes/no
    /// pair proves the question without one. With `firstRow` it is the box's
    /// extent, which is what "the cursor is inside the box" is measured
    /// against (ISC-127).
    var lastRow: Int
    /// The footer that proved this is an interactive question, or empty when
    /// the yes/no pair itself supplied that proof.
    var footer: String

    /// Permission or menu, and WHY — the reason is carried rather than
    /// dropped, because "no card" and "nothing was looked at" are the same
    /// thing from outside and only one of them is a defect (the discipline
    /// `HostedPromptVerdict` next door already keeps).
    @MainActor var decision: SelectorDecision { SelectorScanner.classify(options) }
    @MainActor var kind: SelectorKind { decision.kind }
    @MainActor var kindReason: String { decision.reason }
}

@MainActor
enum SelectorScanner {
    /// Lines that mark the top or bottom of a drawn box, in any of the shapes
    /// the agents use. Shared with `HostedPrompt` rather than restated there:
    /// two copies of a shape test drift apart in silence (ISC-114).
    static func isRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 8 else { return false }
        // `▔` (U+2594, upper one eighth block) is how claude 2.1.239 draws the
        // top of a menu frame. Without it the walk up from the options ran
        // straight through the frame and titled the card with the banner line
        // above it (ISC-126). It is added HERE and so it reaches the pure-chat
        // cover too, which is the point of the two sharing one alphabet.
        return trimmed.allSatisfy { "─╌━▔╭╮╰╯│┌┐└┘.·-=".contains($0) }
    }

    /// `❯ 1. Yes` or `   2. No` → the option, or nil.
    private static func option(_ line: String) -> SelectorOption? {
        let marked = line.contains("❯") || line.contains("›") || line.contains("▶")
        var text = line
        for marker in ["❯", "›", "▶"] {
            text = text.replacingOccurrences(of: marker, with: " ")
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let dot = trimmed.firstIndex(of: "."), dot > trimmed.startIndex else { return nil }
        let digits = trimmed[trimmed.startIndex..<dot]
        guard digits.count <= 2, let number = Int(digits) else { return nil }
        let label = trimmed[trimmed.index(after: dot)...]
            .trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return SelectorOption(number: number, label: label, isCurrent: marked)
    }

    /// The line that proves a human is being waited for. Without it a numbered
    /// list in ordinary output — a README being `cat`ed, a numbered log — would
    /// raise a card over a terminal nobody is asking anything of.
    static func isFooter(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard lower.contains("esc") || lower.contains("enter") || lower.contains("tab")
        else { return false }
        // The verbs each vendor puts under its question. Codex says
        // "Press enter to continue" where Claude Code says "Enter to confirm ·
        // Esc to cancel", and a list that named only one vendor's words would
        // be a vendor check wearing a shape check's clothes.
        return lower.contains("cancel") || lower.contains("confirm")
            || lower.contains("amend") || lower.contains("select")
            || lower.contains("continue") || lower.contains("choose")
    }

    // MARK: - Permission, or a menu? (ISC-122)

    /// The words that answer a yes/no question, whichever vendor drew it.
    ///
    /// They are matched on the FIRST WORD of the label and nowhere else. The
    /// four real permissions this repo holds photographs of read `Yes`,
    /// `Yes, and don't ask again for: sw_vers *`, `No, exit` and `No, and
    /// tell Codex what to do differently (esc)`: the decision is always the
    /// first word, and everything after it is the small print.
    static let affirmatives: Set<String> = [
        "yes", "y", "approve", "allow", "accept", "proceed", "ok", "okay",
        "trust", "confirm",
    ]
    static let negatives: Set<String> = [
        "no", "n", "cancel", "deny", "decline", "reject", "quit", "abort",
        "stop", "exit", "don", "dont", "never",
    ]

    private static func firstWord(_ label: String) -> String {
        String(label.lowercased().drop { !$0.isLetter }.prefix { $0.isLetter })
    }

    /// The trait that separates the two classes, and it is ONE trait: a
    /// permission offers both halves of a decision — a way to say yes and a
    /// way to say no — while a menu offers choices that stand beside each
    /// other, none of them the refusal of the others.
    ///
    /// Measured against every real screen this repo holds. The four
    /// permissions — both vendors, a trust question and a tool approval each
    /// — all carry the pair. `/model` on claude 2.1.239 carries neither: its
    /// five options read `Default (recommended)`, `Opus (1M context)`,
    /// `Fable`, `Sonnet`, `Haiku`, and its footer says `Esc to cancel`. The
    /// word cancel is in the FOOTER, which is exactly why the pair is looked
    /// for in the options and nowhere else.
    ///
    /// It fails towards NO CARD, on purpose. A card over a menu covers the
    /// menu with something that cannot answer it, which is what the
    /// screenshot of 22/08 showed; a permission with no card is still on the
    /// screen, drawn by the agent, and is answered by typing the digit — what
    /// every terminal in the world does. Only the first of those takes
    /// something away from the person sitting here.
    static func classify(_ options: [SelectorOption]) -> SelectorDecision {
        let list = options.map(\.label).joined(separator: " | ")
        let yes = options.first { affirmatives.contains(firstWord($0.label)) }
        let no = options.first { negatives.contains(firstWord($0.label)) }
        switch (yes, no) {
        case let (yes?, no?):
            return SelectorDecision(
                kind: .permission,
                reason: "yes is \(yes.number). \(yes.label) · no is \(no.number). \(no.label)",
                yes: yes, no: no)
        case (nil, _?):
            return SelectorDecision(kind: .selector,
                                    reason: "no option says yes: " + list, yes: nil, no: no)
        case let (yes?, nil):
            return SelectorDecision(kind: .selector,
                                    reason: "no option says no: " + list, yes: yes, no: nil)
        default:
            return SelectorDecision(kind: .selector,
                                    reason: "choices, none of them a yes or a no: " + list,
                                    yes: nil, no: nil)
        }
    }

    /// The scan, narrowed to the questions a card may answer.
    ///
    /// A SECOND door rather than a change to `scan`, because the two callers
    /// want different things and the difference is the whole of ISC-122: the
    /// card wants permissions only, while «pure chat» (ISC-114) wants any
    /// numbered question at all, so a menu nobody predicted uncovers the
    /// input box instead of staying hidden under it. One recogniser, two
    /// questions asked of it.
    static func permission(on grid: any TerminalGrid) -> SelectorPrompt? {
        guard let prompt = scan(grid), prompt.kind == .permission else { return nil }
        return prompt
    }

    /// Finds the question on the LIVE screen, or returns nil.
    ///
    /// Four independent conditions have to hold together, because each one on
    /// its own has a plausible innocent cause: the block is on the live screen
    /// (history cannot be waiting for anything), the options are numbered from
    /// one and consecutive, exactly one of them carries the selection marker,
    /// and either a footer naming a key follows within a few rows or the
    /// choices themselves form a yes/no pair. The latter is necessary because
    /// claude 2.1.250's «Switch model?» confirmation has no footer at all
    /// (measured 2026-08-28); a marked menu without that pair still fails shut.
    /// The alternate screen is NOT excluded here, and that is the whole point.
    ///
    /// Every other overlay in T4A steps back when a program takes the
    /// alternate screen, because that screen belongs to the program drawing
    /// it. This one is the opposite case: Claude Code runs its conversation on
    /// the primary screen and switches to the alternate screen exactly to ask
    /// a question (measured 2026-08-20 — the scan came back empty on a box
    /// that was plainly there, and the dump said `alternateScreen: true`).
    /// Refusing to look at the alternate screen means refusing to see the only
    /// thing this scanner exists for.
    /// `requireCursorInside: false` reports the box WITHOUT the cursor test,
    /// and exists for the same reason `reading` next door does: from outside,
    /// "there is no question on screen" and "there is one but the cursor is
    /// somewhere else" are the same silence, and only one of them is a defect.
    /// Nothing that answers a prompt is allowed to pass false.
    static func scan(_ grid: any TerminalGrid, maximumRows: Int = 60,
                     requireCursorInside: Bool = true) -> SelectorPrompt? {
        let end = grid.endRow
        let first = max(grid.liveScreenTopRow, end - maximumRows)
        guard end > first else { return nil }
        var lines: [(row: Int, text: String)] = []
        for row in first..<end {
            lines.append((row, grid.text(at: row) ?? ""))
        }

        // Work backwards: the question a person is being asked is always the
        // LAST one drawn, and an older one further up the screen is a question
        // that has already been answered.
        var index = lines.count - 1
        while index >= 0 {
            guard option(lines[index].text) != nil else { index -= 1; continue }
            // Walk up through the consecutive option lines.
            var top = index
            while top > 0, option(lines[top - 1].text) != nil { top -= 1 }
            var options: [SelectorOption] = []
            var bottom = top
            while bottom < lines.count, let parsed = option(lines[bottom].text) {
                options.append(parsed)
                bottom += 1
            }
            let numbersRunFromOne = options.first?.number == 1
                && options.enumerated().allSatisfy { $0.element.number == $0.offset + 1 }
            let markedCount = options.filter(\.isCurrent).count
            // The footer, within a few rows of the options — and the few rows
            // are counted in LINES THAT SAY SOMETHING, not in rows.
            //
            // Four rows flat was the first rule and it lost a real menu:
            // `/model` on claude 2.1.239 at 117 columns wraps one price line,
            // leaving an orphan fragment under option 4, and with the blank
            // rows either side of the effort line the footer lands five rows
            // below the last option. The scanner came back empty on a menu
            // that was plainly on the screen (measured 2026-08-22, the screen
            // is in the tests). A blank row is layout; it is not distance.
            var footer = ""
            var footerIndex = bottom - 1
            var meaningfulRows = 0
            var probe = bottom
            while probe < lines.count, meaningfulRows < 4 {
                let text = lines[probe].text
                if isFooter(text) {
                    footer = text.trimmingCharacters(in: .whitespaces)
                    footerIndex = probe
                    break
                }
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { meaningfulRows += 1 }
                probe += 1
            }
            guard options.count >= 2, numbersRunFromOne, markedCount == 1,
                  !footer.isEmpty || classify(options).kind == .permission
            else { index = top - 1; continue }

            // Everything above the options, back to the rule that opened the
            // box or to a run of blank lines, is the question itself.
            // Up from the options to the top of the box.
            //
            // Three things end it, and the second two were learned from the
            // second vendor: a drawn rule, the echo of your own question (a
            // line beginning with the prompt marker), and a run of two blank
            // lines, which is how a terminal UI separates one block from the
            // next. Without them the walk ran past the question, out of the
            // box entirely, and titled the card with the tip of the day
            // (measured 2026-08-20 on a real Codex edit approval).
            var boxTop = top - 1
            var body: [String] = []
            var blanks = 0
            var sawText = false
            while boxTop >= 0 {
                let text = lines[boxTop].text
                if isRule(text) { break }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    blanks += 1
                    // Blank lines directly under the box's last words are the
                    // gap before the options, not the end of anything.
                    if sawText, blanks >= 2 { break }
                } else {
                    if trimmed.hasPrefix("›") || trimmed.hasPrefix("❯") { break }
                    blanks = 0
                    sawText = true
                }
                body.append(text)
                boxTop -= 1
                if body.count > 24 { break }
            }
            body.reverse()
            let meaningful = body.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let title = meaningful.first ?? "Permission"
            let detail = Array(meaningful.dropFirst())
            let firstRow = lines[max(0, boxTop + 1)].row
            let lastRow = lines[min(footerIndex, lines.count - 1)].row
            // The cursor has to be IN the question (ISC-127).
            //
            // A box is a drawing, and anything can draw one: `printf` a rule,
            // a line of prose, `❯ 1. Yes`, `  2. No` and a line naming Enter,
            // and every shape test above is satisfied by output that nobody is
            // waiting behind. What a drawing cannot fake is where the terminal
            // will put the next keystroke — after a `printf` the shell takes
            // the cursor back and it lands under the box, while an agent
            // holding the screen open for an answer keeps it inside.
            //
            // Measured before it was believed, on live permissions from both
            // vendors; the value it read is in Decisions, and the fixtures put
            // their cursor where the live screens put theirs.
            let caret = grid.cursor.row
            if requireCursorInside, caret < firstRow || caret > lastRow {
                index = top - 1
                continue
            }
            return SelectorPrompt(title: title, detail: detail, options: options,
                                  firstRow: firstRow, lastRow: lastRow,
                                  footer: footer)
        }
        return nil
    }

    /// Turns the drawn choices into the two answers a card offers.
    ///
    /// The keystrokes are the ones a person would type — a digit and Return —
    /// and never a private channel: the prompt that decides is the agent's own
    /// (ISC-29).
    ///
    /// Both buttons come from the SAME classification that decided this was a
    /// permission at all (ISC-130). The old rule picked "yes" as the first
    /// label not beginning with "no", which is a different question with a
    /// different answer: `1. Cancel  2. Approve` gave an Approve button that
    /// sent `1`, and `1. Deny  2. Allow` gave one that sent Deny. The card
    /// named one thing and the pty received another — and the direction of the
    /// mistake happened to be mostly safe, which is exactly why nobody saw it.
    /// One recogniser decides what the halves ARE; nothing downstream guesses.
    static func answers(for prompt: SelectorPrompt)
        -> (approve: AgentApprovalOption, deny: AgentApprovalOption) {
        let decision = classify(prompt.options)
        // A prompt with no affirmative is not a permission and never reaches
        // here through `permission(on:)`; the fallback keeps the function
        // total rather than trapping, and stays on the first option because
        // that is what a caller who ignored the classification would get.
        let yes = decision.yes ?? prompt.options[0]
        let no = decision.no
        return (
            AgentApprovalOption(label: yes.label, keystrokes: "\(yes.number)\r",
                                isApproval: true),
            // Escape is the fallback for a permission that offers no written
            // refusal: every one of these selectors treats it as cancel.
            AgentApprovalOption(label: no?.label ?? "Cancel",
                                keystrokes: no.map { "\($0.number)\r" } ?? "\u{1b}",
                                isApproval: false)
        )
    }
}
