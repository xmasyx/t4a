//  BoxDrawing.swift — the characters a terminal must draw itself.
//
//  Box drawing and block elements are the one place where using the font is
//  wrong. A `─` glyph is a stroke inside a cell with a hair of side bearing,
//  so a row of them comes out as a dotted line with a gap at every cell
//  boundary, and a TUI drawn with them looks broken — which is most TUIs,
//  `claude` included. Every serious terminal paints these ranges as
//  rectangles that reach the edges of the cell instead, and so does this one:
//  measured against the engine's own renderer, this file is the difference
//  between a continuous frame and a perforated one.

import CoreGraphics
import Foundation

enum BoxDrawing {
    /// A piece of a cell to fill, in fractions of the cell (0…1), plus an
    /// alpha for the shade characters.
    struct Piece {
        var x: Double, y: Double, width: Double, height: Double
        var alpha: Double = 1
    }

    /// Nil means "this is not one of ours — use the font".
    static func pieces(for character: Character, thickness: Double,
                       heavyThickness: Double) -> [Piece]? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return nil }
        let value = scalar.value
        guard (0x2500...0x259F).contains(value) else { return nil }

        let light = thickness
        let heavy = heavyThickness
        // The stroke is centred on the cell's middle line, and every arm runs
        // to the cell edge so the next cell continues it exactly.
        func horizontal(_ weight: Double, from: Double = 0, to: Double = 1) -> Piece {
            Piece(x: from, y: 0.5 - weight / 2, width: to - from, height: weight)
        }
        func vertical(_ weight: Double, from: Double = 0, to: Double = 1) -> Piece {
            Piece(x: 0.5 - weight / 2, y: from, width: weight, height: to - from)
        }

        switch value {
        // ── lines
        case 0x2500: return [horizontal(light)]
        case 0x2501: return [horizontal(heavy)]
        case 0x2502: return [vertical(light)]
        case 0x2503: return [vertical(heavy)]
        // ── corners, light
        case 0x250C: return [horizontal(light, from: 0.5), vertical(light, from: 0.5)]
        case 0x2510: return [horizontal(light, to: 0.5), vertical(light, from: 0.5)]
        case 0x2514: return [horizontal(light, from: 0.5), vertical(light, to: 0.5)]
        case 0x2518: return [horizontal(light, to: 0.5), vertical(light, to: 0.5)]
        // ── corners, heavy
        case 0x250F: return [horizontal(heavy, from: 0.5), vertical(heavy, from: 0.5)]
        case 0x2513: return [horizontal(heavy, to: 0.5), vertical(heavy, from: 0.5)]
        case 0x2517: return [horizontal(heavy, from: 0.5), vertical(heavy, to: 0.5)]
        case 0x251B: return [horizontal(heavy, to: 0.5), vertical(heavy, to: 0.5)]
        // ── rounded corners: a terminal draws them square; the radius is
        //    smaller than a pixel at any sane cell size.
        case 0x256D: return [horizontal(light, from: 0.5), vertical(light, from: 0.5)]
        case 0x256E: return [horizontal(light, to: 0.5), vertical(light, from: 0.5)]
        case 0x256F: return [horizontal(light, to: 0.5), vertical(light, to: 0.5)]
        case 0x2570: return [horizontal(light, from: 0.5), vertical(light, to: 0.5)]
        // ── tees and cross, light
        case 0x251C: return [vertical(light), horizontal(light, from: 0.5)]
        case 0x2524: return [vertical(light), horizontal(light, to: 0.5)]
        case 0x252C: return [horizontal(light), vertical(light, from: 0.5)]
        case 0x2534: return [horizontal(light), vertical(light, to: 0.5)]
        case 0x253C: return [horizontal(light), vertical(light)]
        // ── tees and cross, heavy
        case 0x2523: return [vertical(heavy), horizontal(heavy, from: 0.5)]
        case 0x252B: return [vertical(heavy), horizontal(heavy, to: 0.5)]
        case 0x2533: return [horizontal(heavy), vertical(heavy, from: 0.5)]
        case 0x253B: return [horizontal(heavy), vertical(heavy, to: 0.5)]
        case 0x254B: return [horizontal(heavy), vertical(heavy)]
        // ── double lines: two thin strokes a third of a cell apart.
        case 0x2550:
            return [Piece(x: 0, y: 0.5 - light * 1.5, width: 1, height: light),
                    Piece(x: 0, y: 0.5 + light * 0.5, width: 1, height: light)]
        case 0x2551:
            return [Piece(x: 0.5 - light * 1.5, y: 0, width: light, height: 1),
                    Piece(x: 0.5 + light * 0.5, y: 0, width: light, height: 1)]
        // ── blocks
        case 0x2580: return [Piece(x: 0, y: 0, width: 1, height: 0.5)]      // ▀
        case 0x2584: return [Piece(x: 0, y: 0.5, width: 1, height: 0.5)]    // ▄
        case 0x2588: return [Piece(x: 0, y: 0, width: 1, height: 1)]        // █
        case 0x258C: return [Piece(x: 0, y: 0, width: 0.5, height: 1)]      // ▌
        case 0x2590: return [Piece(x: 0.5, y: 0, width: 0.5, height: 1)]    // ▐
        case 0x2581...0x2587:                                               // ▁…▇
            let eighths = Double(value - 0x2580) / 8
            return [Piece(x: 0, y: 1 - eighths, width: 1, height: eighths)]
        case 0x2589...0x258B:                                               // ▉▊▋
            let eighths = Double(0x2590 - value) / 8
            return [Piece(x: 0, y: 0, width: eighths, height: 1)]
        case 0x258D...0x258F:                                               // ▍▎▏
            let eighths = Double(0x2590 - value) / 8
            return [Piece(x: 0, y: 0, width: eighths, height: 1)]
        // ── shades: a full block at a fraction of the ink, which is what the
        //    dither pattern in the font is trying to look like from a metre
        //    away, and is stable at every cell size.
        case 0x2591: return [Piece(x: 0, y: 0, width: 1, height: 1, alpha: 0.25)]
        case 0x2592: return [Piece(x: 0, y: 0, width: 1, height: 1, alpha: 0.5)]
        case 0x2593: return [Piece(x: 0, y: 0, width: 1, height: 1, alpha: 0.75)]
        case 0x2594: return [Piece(x: 0, y: 0, width: 1, height: 0.125)]    // ▔
        case 0x2595: return [Piece(x: 0.875, y: 0, width: 0.125, height: 1)] // ▕
        case 0x2596: return [Piece(x: 0, y: 0.5, width: 0.5, height: 0.5)]
        case 0x2597: return [Piece(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case 0x2598: return [Piece(x: 0, y: 0, width: 0.5, height: 0.5)]
        case 0x259D: return [Piece(x: 0.5, y: 0, width: 0.5, height: 0.5)]
        default:
            // Dashed, curved and the odder diagonals stay with the font: a
            // wrong rectangle is worse than a glyph with a seam.
            return nil
        }
    }
}
