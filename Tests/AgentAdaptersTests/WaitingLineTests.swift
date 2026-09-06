//  WaitingLineTests.swift — claude's live spinner line, from photographed grids.
//
//  These 184-column, 41-row fixtures were captured from claude 2.1.250 on
//  2026-08-28. The author's four provider status rows are scrubbed and
//  replaced with generic rows, as in HostedPromptTests.swift; they do not
//  participate in recognising the spinner line. The rules retain their
//  measured width and are built rather than pasted.

import Testing
@testable import AgentAdapters

private let waitingRule = String(repeating: "─", count: 184)
private let effortLine = String(repeating: " ", count: 166) + "● high · /effort"

private func waitingScreen(_ line: String) -> [String] {
    Array(repeating: "", count: 30) + [
        line,
        effortLine,
        waitingRule,
        "❯ ",
        waitingRule,
        "  a status line the principal chose",
        "  a second row of it",
        "  a third row of it",
        "  a fourth row of it",
        "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents",
        "",
    ]
}

@MainActor
private func photographedGrid(_ lines: [String]) -> FakeGrid {
    let grid = FakeGrid(lines, alternate: true)
    grid.cursorRow = 33
    return grid
}

@MainActor
@Suite("WaitingLineTests")
struct WaitingLineTests {
    @Test func readsTheOpenTurnLineVerbatim() {
        let screen = waitingScreen("· Glanding-bliss…")
        #expect(screen.count == 41)
        #expect(screen[30] == "· Glanding-bliss…")
        let grid = photographedGrid(screen)
        #expect(grid.cursor.row == 33)
        #expect(WaitingLine.read(grid)
                == "· Glanding-bliss…")
    }

    @Test func ignoresTheClosedTurnLine() {
        let screen = waitingScreen("✻ Cooked for 7s · done 12:54")
        #expect(screen.count == 41)
        #expect(WaitingLine.read(photographedGrid(screen)) == nil)
    }

    @Test func findsNothingWithoutAWaitingLine() {
        #expect(WaitingLine.read(FakeGrid(
            ["an answer", waitingRule, "❯ ", waitingRule], alternate: true)) == nil)
    }

    @Test func requiresTheEllipsisShapeGate() {
        #expect(WaitingLine.read(photographedGrid(waitingScreen("✳ Thinking"))) == nil)
    }

    @Test func keepsTheLaterTimingSuffix() {
        let line = "✻ Thinking… (12s · esc to interrupt)"
        #expect(WaitingLine.read(photographedGrid(waitingScreen(line))) == line)
    }
}
