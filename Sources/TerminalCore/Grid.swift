//  Grid.swift — the cell model T4A draws from.
//
//  Nothing here knows which VT engine filled the cells. That is the whole
//  point: the day libghostty ships a Swift framework, a new backend fills the
//  same structures and neither the views nor the Metal renderer of F3 change.

import Foundation

/// A colour as the VT engine resolved it: either a palette index or a direct
/// RGB triple. Themes map indices; direct colours are used verbatim.
public enum GridColor: Equatable, Sendable {
    case defaultForeground
    case defaultBackground
    case palette(UInt8)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

public struct GridAttributes: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = GridAttributes(rawValue: 1 << 0)
    public static let dim = GridAttributes(rawValue: 1 << 1)
    public static let italic = GridAttributes(rawValue: 1 << 2)
    public static let underline = GridAttributes(rawValue: 1 << 3)
    public static let blink = GridAttributes(rawValue: 1 << 4)
    public static let inverse = GridAttributes(rawValue: 1 << 5)
    public static let invisible = GridAttributes(rawValue: 1 << 6)
    public static let strikethrough = GridAttributes(rawValue: 1 << 7)
}

/// One cell. `text` is a whole grapheme cluster, so a family emoji or a
/// combining sequence stays one cell (ISC-23 lives on this contract).
public struct GridCell: Sendable {
    public var text: Character
    public var width: Int
    public var foreground: GridColor
    public var background: GridColor
    public var attributes: GridAttributes

    public init(text: Character, width: Int = 1,
                foreground: GridColor = .defaultForeground,
                background: GridColor = .defaultBackground,
                attributes: GridAttributes = []) {
        self.text = text
        self.width = width
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }
}

public struct GridPosition: Equatable, Sendable {
    public var column: Int
    public var row: Int
    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

/// A row addressed in scroll-invariant coordinates: row 0 is the first line
/// ever written, and a row's number never changes as the screen scrolls.
/// Everything durable — command blocks, search hits, gutter marks — is
/// anchored here, because screen-relative rows expire.
public struct GridLine: Sendable {
    public var cells: [GridCell]
    public var isWrapped: Bool

    public init(cells: [GridCell], isWrapped: Bool = false) {
        self.cells = cells
        self.isWrapped = isWrapped
    }

    /// The row as text, trailing blanks trimmed.
    public var text: String {
        var out = ""
        for cell in cells where cell.width > 0 { out.append(cell.text) }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}

/// A run of cells from one position to another, in scroll-invariant
/// coordinates. `end` is exclusive on its own row.
public struct GridSpan: Equatable, Sendable {
    public var start: GridPosition
    public var end: GridPosition

    public init(start: GridPosition, end: GridPosition) {
        self.start = start
        self.end = end
    }

    /// The columns of this span that fall on `row`, or nil if none do.
    public func columns(on row: Int, width: Int) -> Range<Int>? {
        let (first, last) = start.row <= end.row ? (start, end) : (end, start)
        guard row >= first.row, row <= last.row else { return nil }
        let from = row == first.row ? first.column : 0
        let to = row == last.row ? last.column : width
        guard to > from else { return nil }
        return max(0, from)..<min(width, to)
    }
}

/// The read side of a terminal: what is on screen, what is in scrollback, and
/// where the cursor is.
@MainActor
public protocol TerminalGrid: AnyObject {
    var columns: Int { get }
    var rows: Int { get }

    /// Scroll-invariant row of the first line still retained.
    var firstRetainedRow: Int { get }
    /// Scroll-invariant row one past the last written line.
    var endRow: Int { get }
    /// Scroll-invariant row of the top line currently on screen.
    var topVisibleRow: Int { get }

    /// Scroll-invariant row where the LIVE screen begins.
    ///
    /// Everything below this number is history: a row that has scrolled off
    /// the screen can never change again, because its number is fixed and the
    /// program can only write to the screen. A renderer can cache those rows;
    /// nothing above this line may be cached, because the program rewrites
    /// them whenever it likes.
    var liveScreenTopRow: Int { get }

    /// Cursor in scroll-invariant coordinates.
    var cursor: GridPosition { get }

    /// True while an application owns the alternate screen (vim, less, htop).
    var isAlternateScreenActive: Bool { get }

    func line(at row: Int) -> GridLine?

    /// The row as text, for the readers that only want the words — search,
    /// above all. A default implementation builds it from `line(at:)`, but a
    /// backend that can produce a string without materialising every cell
    /// should: measured on a search over nine thousand rows, going through
    /// the cells cost 135 ms and going straight to text cost a fraction of
    /// that (ISC-66).
    func text(at row: Int) -> String?

    /// What the user has selected, in scroll-invariant coordinates.
    /// A renderer that does not know this draws a terminal where dragging
    /// does nothing visible.
    var selection: GridSpan? { get }

    /// False while the program has hidden the cursor (DECTCEM).
    var isCursorVisible: Bool { get }
}

@MainActor
public extension TerminalGrid {
    /// Retained scrollback plus screen, in lines. The number ISC-17 is about.
    var retainedLineCount: Int { max(0, endRow - firstRetainedRow) }

    func text(at row: Int) -> String? { line(at: row)?.text }
}
