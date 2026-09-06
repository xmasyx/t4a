//  WaitingLine.swift — claude's own live waiting line, read from the grid.

import Foundation
import TerminalCore

/// The last row on the live grid carrying claude's spinner: one glyph among
/// ✻ ✳ ✶ ✽ · followed by a word and `…`. Returned verbatim, with the leading
/// glyph left unnormalised: this is ITS line, and the animation is the point.
/// `✢` is included too because it is a real frame in claude's spinner cycle,
/// even though it was absent from the shorter list in the original contract.
public enum WaitingLine {
    @MainActor public static func read(_ grid: any TerminalGrid) -> String? {
        let end = grid.endRow
        let first = max(grid.liveScreenTopRow, end - 60)
        guard end > first else { return nil }

        let glyphs: Set<Character> = ["✻", "✳", "✶", "✽", "·", "✢"]
        for row in stride(from: end - 1, through: first, by: -1) {
            let line = (grid.text(at: row) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard let glyph = line.first, glyphs.contains(glyph), line.contains("…")
            else { continue }
            let rest = line.dropFirst()
            guard rest.first?.isWhitespace == true,
                  rest.contains(where: { !$0.isWhitespace }) else { continue }
            return line
        }
        return nil
    }
}
