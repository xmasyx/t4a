//  Palette.swift — the colours a terminal resolves its cells to.
//
//  The grid speaks in palette indices and direct RGB (`GridColor`); somebody
//  has to turn an index into a colour, and it must be the SAME somebody for
//  every renderer. Two independent colour tables is how a GPU renderer ends up
//  drawing a slightly different blue from the CPU one it is supposed to be
//  replacing, which is exactly the difference the fidelity check of F3 hunts
//  for.

import AppKit

public struct TerminalPalette {
    /// The default foreground and background — what a cell means by
    /// `.defaultForeground` / `.defaultBackground`.
    public var foreground: NSColor
    public var background: NSColor
    public var cursor: NSColor
    /// The colour of the character sitting under a block cursor.
    public var cursorText: NSColor
    public var selection: NSColor
    /// A Command-hovered terminal link: its stroke and its quiet cell fill.
    public var link: NSColor
    public var linkHighlight: NSColor
    /// Search hits, and the one the find bar is sitting on.
    public var highlight: NSColor
    public var currentHighlight: NSColor
    /// 256 entries: 16 named, 216 cube, 24 greys.
    public var ansi: [NSColor]

    public init(foreground: NSColor, background: NSColor, cursor: NSColor,
                cursorText: NSColor, selection: NSColor,
                link: NSColor, linkHighlight: NSColor,
                highlight: NSColor, currentHighlight: NSColor, ansi: [NSColor]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.cursorText = cursorText
        self.selection = selection
        self.link = link
        self.linkHighlight = linkHighlight
        self.highlight = highlight
        self.currentHighlight = currentHighlight
        self.ansi = ansi
    }

    /// Fills indices 16…255 from the sixteen the engine named.
    ///
    /// The cube and the grey ramp are the xterm formula, which every terminal
    /// agrees on: 16 + 36r + 6g + b over the levels 0, 95, 135, 175, 215, 255,
    /// then 24 greys from 8 to 238 in steps of ten.
    public static func complete(base sixteen: [NSColor]) -> [NSColor] {
        var colours = sixteen
        let levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
        for red in 0..<6 {
            for green in 0..<6 {
                for blue in 0..<6 {
                    colours.append(NSColor(srgbRed: levels[red] / 255,
                                           green: levels[green] / 255,
                                           blue: levels[blue] / 255, alpha: 1))
                }
            }
        }
        for step in 0..<24 {
            let value = CGFloat(8 + step * 10) / 255
            colours.append(NSColor(srgbRed: value, green: value, blue: value, alpha: 1))
        }
        return colours
    }
}

/// What the APP's theme says the grid should look like.
///
/// It is a separate, smaller type from `TerminalPalette` on purpose: the
/// palette is what the ENGINE resolves cells to, 256 colours deep and read
/// from the engine; this is the handful of colours a theme has an opinion
/// about, handed the other way. `ansi` is nil for every theme that is happy
/// with the xterm cube, which is every dark one (ISC-33).
public struct TerminalTheme {
    public var background: NSColor
    public var foreground: NSColor
    public var cursor: NSColor
    public var selection: NSColor
    public var link: NSColor
    public var linkHighlight: NSColor
    public var ansi: [NSColor]?

    public init(background: NSColor, foreground: NSColor, cursor: NSColor,
                selection: NSColor, link: NSColor, linkHighlight: NSColor,
                ansi: [NSColor]? = nil) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.link = link
        self.linkHighlight = linkHighlight
        self.ansi = ansi
    }
}
