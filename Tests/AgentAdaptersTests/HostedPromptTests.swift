//  HostedPromptTests.swift — the box scanner of ISC-114, against the screen
//  `claude` really draws.
//
//  The fixture below was read off a live `claude` 2.1.239 at its resting
//  prompt on 2026-08-21 (a 120x40 terminal): a full-width rule, the marker
//  line, another rule, and the lines the agent prints underneath. Two things
//  were changed for this public repo, both named here because a fixture you
//  have edited in silence is not a photograph any more:
//
//    * the four rows of the principal's own status line, which sit between
//      the box and the hint, are replaced by four generic ones. What this
//      scanner asks of those rows is only that none of them names a key to
//      press, and the REAL ones are exercised by `Scripts/bench-pure-chat.sh`
//      against a live agent, which is the honest place for them.
//    * the usage figures on the line above the box are dropped.
//
//  The rules are 120 columns wide in the original and are built here rather
//  than pasted, so the width test is exercised on the real width.

import Testing
import TerminalCore
@testable import AgentAdapters

private let rule = String(repeating: "─", count: 120)

/// `claude` at rest: the box is empty and nobody is being asked anything.
private func restingScreen(typed: String = "") -> [String] {
    [
        "> what is 2 + 2",
        "",
        "  4",
        "",
        "                                            You've used some of your weekly limit",
        rule,
        "❯\u{00A0}\(typed)",
        rule,
        "  a status line the principal chose",
        "  a second row of it",
        "  a third row of it",
        "  a fourth row of it",
        "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents",
    ]
}

/// The marker row of `restingScreen`, where the terminal really put the
/// cursor (measured: `cursor_y` 32 on a 40-row screen whose box sat at 32-34).
private let restingCursorRow = 6

@MainActor
private func grid(_ lines: [String], cursor: Int) -> FakeGrid {
    let grid = FakeGrid(lines, alternate: true)
    grid.cursorRow = cursor
    return grid
}

@MainActor
@Test func coversTheRestingPrompt() {
    let verdict = HostedPromptScanner.scan(grid(restingScreen(), cursor: restingCursorRow))
    guard case .cover(let prompt) = verdict else {
        Issue.record("nothing covered: \(verdict)")
        return
    }
    #expect(prompt.topRule == 5)
    #expect(prompt.bottomRule == 7)
    #expect(prompt.markerRow == restingCursorRow)
    #expect(prompt.rowCount == 3)
    #expect(prompt.marker == "❯")
}

@MainActor
@Test func seesTheInputLineAtRest() {
    #expect(HostedPromptScanner.inputLine(
        grid(restingScreen(), cursor: restingCursorRow)))
}

@MainActor
@Test func seesTheInputLineWithTypedText() {
    #expect(HostedPromptScanner.inputLine(
        grid(restingScreen(typed: "a message"), cursor: restingCursorRow)))
}

@MainActor
@Test func seesNoInputLineOnTheSwitchModelConfirmation() {
    let screen = asked(switchModelScreen, alternate: true)
    #expect(screen.cursor.row == 38)
    #expect(!HostedPromptScanner.inputLine(screen))
}

@MainActor
@Test func seesNoInputLineWithoutRules() {
    #expect(!HostedPromptScanner.inputLine(
        grid(["a note", "❯ a message", "another note"], cursor: 1)))
}

@MainActor
@Test func revealsWhileTheSlashListIsOpen() {
    // The list itself is drawn ABOVE the box and carries no numbers, no
    // marker and no footer — nothing the F4 scanner would see. What gives it
    // away is the box: what you typed is in it.
    let verdict = HostedPromptScanner.scan(
        grid(restingScreen(typed: "/rel"), cursor: restingCursorRow))
    #expect(verdict == .reveal("the prompt has text in it"))
}

@MainActor
@Test func revealsWhenALineNamesAKey() {
    var lines = restingScreen()
    lines.append("  Press enter to continue")
    let verdict = HostedPromptScanner.scan(grid(lines, cursor: restingCursorRow))
    guard case .reveal(let why) = verdict else {
        Issue.record("covered something it should not have: \(verdict)")
        return
    }
    #expect(why.hasPrefix("a line names a key"))
}

@MainActor
@Test func theRestingHintIsNotAFooter() {
    // The anti-pole of the test above, and the one that decides whether this
    // feature can ever cover anything: the hint `claude` leaves under its box
    // says "shift+tab", so a looser key test would reveal for ever.
    #expect(!SelectorScanner.isFooter("  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"))
}

@MainActor
@Test func revealsOnTheWorkspaceTrustQuestion() {
    #expect(HostedPromptScanner.scan(FakeGrid(trustScreen)) == .reveal("a selector is on screen"))
}

@MainActor
@Test func revealsOnAPermissionOnTheAlternateScreen() {
    #expect(HostedPromptScanner.scan(FakeGrid(permissionScreen, alternate: true))
        == .reveal("a selector is on screen"))
}

@MainActor
@Test func revealsOnTheOtherVendorsApproval() {
    #expect(HostedPromptScanner.scan(FakeGrid(codexEditApprovalScreen))
        == .reveal("a selector is on screen"))
}

@MainActor
@Test func coversNothingAtAnOrdinaryShellPrompt() {
    #expect(HostedPromptScanner.scan(FakeGrid(innocentScreen))
        == .reveal("no rule under the cursor"))
}

@MainActor
@Test func coversNothingWhenTheCursorIsElsewhere() {
    // The box is on screen and the cursor is up in the conversation: the
    // program is not waiting for a line, and nothing may be covered. The
    // cursor sits on a line of the answer rather than at the very top of the
    // screen, so what stops the cover is the shape and not the screen edge.
    #expect(HostedPromptScanner.scan(grid(restingScreen(), cursor: 2))
        == .reveal("no rule over the cursor"))
}

@MainActor
@Test func refusesABoxDrawnOutOfShortRules() {
    // A short rule is the corner of some other drawing, not an input line.
    let short = String(repeating: "─", count: 12)
    let lines = ["  a note", short, "❯ ", short, "  and the rest"]
    #expect(HostedPromptScanner.scan(grid(lines, cursor: 2))
        == .reveal("the rules are too short"))
}

@MainActor
@Test func refusesABoxWithNoMarkerInIt() {
    let lines = ["  a note", rule, "", rule, "  and the rest"]
    #expect(HostedPromptScanner.scan(grid(lines, cursor: 2))
        == .reveal("no prompt marker in the box"))
}

@MainActor
@Test func keepsTheCoverWhileTheAgentIsWorking() {
    // The pole that decides whether this feature is worth having at all. An
    // agent at work prints `esc to interrupt` under its box, and `esc` is one
    // of the three key words the footer test looks for. If that alone counted,
    // the cover would leave for the whole of every turn — which is most of the
    // time anyone is watching. It does not count, because `isFooter` also
    // wants a verb of choosing, and interrupting is not choosing.
    var lines = restingScreen()
    lines.append("  ✻ Thinking… (12s · esc to interrupt)")
    guard case .cover = HostedPromptScanner.scan(grid(lines, cursor: restingCursorRow)) else {
        Issue.record("the cover left while the agent was merely working")
        return
    }
}
