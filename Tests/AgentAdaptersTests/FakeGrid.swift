//  FakeGrid.swift — a grid made of strings, for the tests.
//
//  It exists so the selector scanner can be run against SCREENS CAPTURED FROM
//  THE REAL APP: every screen in these tests was dumped out of a live T4A pane
//  with `drive.sh dump`, so the fixture is a photograph and not an invention.

import AppKit
import Foundation
import TerminalCore

@MainActor
final class FakeGrid: TerminalGrid {
    private let lines: [String]
    let columns: Int
    let rows: Int
    let firstRetainedRow = 0
    var isAlternateScreenActive: Bool
    var selection: GridSpan? { nil }
    var isCursorVisible = true

    init(_ lines: [String], alternate: Bool = false) {
        self.lines = lines
        columns = lines.map(\.count).max() ?? 80
        rows = lines.count
        isAlternateScreenActive = alternate
    }

    var endRow: Int { lines.count }
    var topVisibleRow: Int { 0 }
    var liveScreenTopRow: Int { isAlternateScreenActive ? 0 : max(0, endRow - rows) }
    /// Where the cursor is. It defaults to the last line, which is where a
    /// shell leaves it, and is settable because the box scanner of ISC-114
    /// is anchored to the cursor: a fixture that could not move it could only
    /// test one half of that scanner.
    var cursorRow: Int?
    var cursorColumn = 0
    var cursor: GridPosition {
        GridPosition(column: cursorColumn, row: cursorRow ?? max(0, lines.count - 1))
    }

    func line(at row: Int) -> GridLine? {
        guard lines.indices.contains(row) else { return nil }
        return GridLine(cells: lines[row].map { GridCell(text: $0) })
    }

    func text(at row: Int) -> String? {
        lines.indices.contains(row) ? lines[row] : nil
    }
}
