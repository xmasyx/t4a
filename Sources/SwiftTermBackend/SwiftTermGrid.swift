//  SwiftTermGrid.swift — SwiftTerm's buffer, read through T4A's cell model.

import Foundation
import SwiftTerm
import TerminalCore

@MainActor
final class SwiftTermGrid: TerminalGrid {
    private let terminal: Terminal
    /// Filled by the session: the engine keeps selection and cursor
    /// visibility on the view, not on the buffer.
    var selectionProvider: (() -> GridSpan?)?
    var cursorVisibleProvider: (() -> Bool)?

    init(terminal: Terminal) { self.terminal = terminal }

    var selection: GridSpan? { selectionProvider?() }
    var isCursorVisible: Bool { cursorVisibleProvider?() ?? true }

    var columns: Int { terminal.cols }
    var rows: Int { terminal.rows }
    var isAlternateScreenActive: Bool { terminal.isCurrentBufferAlternate }

    var firstRetainedRow: Int { terminal.buffer.totalLinesTrimmed }

    /// One past the last row the buffer holds, in scroll-invariant numbers.
    ///
    /// SwiftTerm publishes the count of lines trimmed but not the length of
    /// the line list, so the end is found by asking for rows until one comes
    /// back nil: a doubling reach followed by a bisection, about fourteen
    /// calls on a ten-thousand-line buffer.
    var endRow: Int {
        let base = firstRetainedRow
        guard terminal.getScrollInvariantLine(row: base) != nil else { return base }
        var span = 1
        while terminal.getScrollInvariantLine(row: base + span) != nil {
            span *= 2
            if span > 1 << 24 { break }
        }
        var low = span / 2          // known present
        var high = span             // known absent (or the ceiling)
        while high - low > 1 {
            let middle = low + (high - low) / 2
            if terminal.getScrollInvariantLine(row: base + middle) != nil {
                low = middle
            } else {
                high = middle
            }
        }
        return base + low + 1
    }

    var topVisibleRow: Int { firstRetainedRow + terminal.getTopVisibleRow() }

    /// The screen's first row. The line list always ends with the screen, so
    /// the screen starts `rows` before the end.
    private var screenTopRow: Int { max(firstRetainedRow, endRow - rows) }

    /// Same number, published: a renderer needs it to know which rows are
    /// history and therefore safe to remember.
    ///
    /// The alternate screen is never history — an application redraws all of
    /// it whenever it likes — so while it is up, nothing is cacheable.
    var liveScreenTopRow: Int {
        isAlternateScreenActive ? firstRetainedRow : screenTopRow
    }

    var cursor: GridPosition {
        let location = terminal.getCursorLocation()
        return GridPosition(column: location.x, row: screenTopRow + location.y)
    }

    /// The engine's own text extraction, which is what its selection uses:
    /// no cells are built, no colours are mapped, and a search over the whole
    /// buffer stops costing a hundred milliseconds.
    func text(at row: Int) -> String? {
        guard let bufferLine = terminal.getScrollInvariantLine(row: row) else { return nil }
        let raw = bufferLine.translateToString(trimRight: true, startCol: 0,
                                               endCol: terminal.cols)
        // A cell nothing has written to comes back as NUL, and the engine's
        // own string builder passes it straight through. The cell path already
        // turns it into a blank, so the two readers of the same buffer
        // disagreed: `line(at:)` gave "   1. Yes" and `text(at:)` gave
        // "\0\0\01. Yes".
        //
        // It cost an evening. The permission scanner reads rows through THIS
        // method, its trim left the NULs in place, and "\0\0\01" is not a
        // number — so a permission box that was plainly on the screen, and
        // that the scanner parsed correctly in a test built from the very same
        // screen text, was invisible to the running app. Two paths to one fact
        // must agree, and the fix belongs where the fact is read, not in every
        // reader.
        return raw.contains("\0") ? raw.replacingOccurrences(of: "\0", with: " ") : raw
    }

    func line(at row: Int) -> GridLine? {
        guard let bufferLine = terminal.getScrollInvariantLine(row: row) else { return nil }
        var cells: [GridCell] = []
        cells.reserveCapacity(terminal.cols)
        // A shrunk terminal keeps longer lines in its buffer than it shows.
        // Reporting them would make this grid claim a width the screen does
        // not have, so the row stops at the column count.
        for column in 0..<min(bufferLine.count, terminal.cols) {
            let data = bufferLine[column]
            // An untouched cell comes back as NUL, which is not a character a
            // reader ever wants to see: it is a blank.
            let character = terminal.getCharacter(for: data)
            cells.append(GridCell(
                text: character == "\0" ? " " : character,
                width: Int(data.width),
                foreground: Self.map(data.attribute.fg),
                background: Self.map(data.attribute.bg, isBackground: true),
                attributes: Self.map(data.attribute.style)))
        }
        return GridLine(cells: cells, isWrapped: bufferLine.isWrapped)
    }

    private static func map(_ color: Attribute.Color, isBackground: Bool = false) -> GridColor {
        switch color {
        case .ansi256(let code): return .palette(code)
        case .trueColor(let r, let g, let b): return .rgb(r: r, g: g, b: b)
        case .defaultColor: return isBackground ? .defaultBackground : .defaultForeground
        case .defaultInvertedColor: return isBackground ? .defaultBackground : .defaultForeground
        }
    }

    private static func map(_ style: CharacterStyle) -> GridAttributes {
        var result: GridAttributes = []
        if style.contains(.bold) { result.insert(.bold) }
        if style.contains(.dim) { result.insert(.dim) }
        if style.contains(.italic) { result.insert(.italic) }
        if style.contains(.underline) { result.insert(.underline) }
        if style.contains(.blink) { result.insert(.blink) }
        if style.contains(.inverse) { result.insert(.inverse) }
        if style.contains(.invisible) { result.insert(.invisible) }
        if style.contains(.crossedOut) { result.insert(.strikethrough) }
        return result
    }
}
