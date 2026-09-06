//  RowFold.swift — hiding rows of a terminal without losing them.
//
//  The compact view of a turn (ISC-94) needs the WORK of a turn to take one
//  line instead of two hundred, with the question and the answer still on
//  screen. That is a real fold, not a cover: a folded run occupies exactly one
//  visual row, and everything below moves up.
//
//  One invariant carries the whole design, and it is what makes the fold safe:
//  A FOLD MAY ONLY COVER HISTORY. The live screen belongs to the program
//  drawing it — it rewrites those rows whenever it likes, the cursor lives
//  there, and the pty's idea of how many rows it has is that screen. Fold a
//  live row and the terminal and the program disagree about what is where.
//  Every fold is clipped against `liveScreenTopRow` before it is used.

import Foundation

/// What occupies one visual row of the viewport.
public enum FoldedRow: Equatable, Sendable {
    /// An ordinary row, at this scroll-invariant number.
    case line(Int)
    /// A folded run, standing in for these rows.
    case fold(ClosedRange<Int>)
}

/// A set of folded runs, in scroll-invariant coordinates.
public struct RowFold: Equatable, Sendable {
    /// Sorted, disjoint, and never overlapping the live screen.
    public private(set) var ranges: [ClosedRange<Int>] = []

    public init() {}

    public init(_ ranges: [ClosedRange<Int>], liveScreenTopRow: Int) {
        // Clipped and merged here rather than trusted from the caller: a fold
        // that reached into the live screen would be a bug you only see as a
        // terminal drawing the wrong thing.
        var clipped = ranges.compactMap { range -> ClosedRange<Int>? in
            guard range.lowerBound < liveScreenTopRow else { return nil }
            let upper = min(range.upperBound, liveScreenTopRow - 1)
            guard upper >= range.lowerBound else { return nil }
            return range.lowerBound...upper
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for range in clipped {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        clipped = merged
        self.ranges = clipped
    }

    public var isEmpty: Bool { ranges.isEmpty }

    /// The fold covering a row, if any.
    public func fold(containing row: Int) -> ClosedRange<Int>? {
        ranges.first { $0.contains(row) }
    }

    /// The rows the viewport shows, starting at `top` and taking `count`
    /// visual rows. With no folds this is exactly `top..<top+count`, which is
    /// why a terminal with the compact view off is bit-for-bit the terminal it
    /// was before.
    public func rows(from top: Int, count: Int) -> [FoldedRow] {
        guard !ranges.isEmpty else {
            return (0..<max(0, count)).map { .line(top + $0) }
        }
        var out: [FoldedRow] = []
        out.reserveCapacity(max(0, count))
        var row = top
        while out.count < count {
            if let range = fold(containing: row) {
                out.append(.fold(range))
                row = range.upperBound + 1
            } else {
                out.append(.line(row))
                row += 1
            }
        }
        return out
    }

    /// Where the viewport should land after moving, so it never comes to rest
    /// in the middle of something that is folded.
    ///
    /// `direction` is +1 when scrolling towards history and -1 towards the
    /// live screen — the same sign the backend's `scroll(lines:)` uses.
    public func settle(_ row: Int, direction: Int) -> Int {
        guard let range = fold(containing: row) else { return row }
        return direction >= 0 ? range.lowerBound : range.upperBound + 1
    }

    /// How many visual rows a run of grid rows takes once folded. Used by the
    /// overlay to put a label on the same line the renderer drew a strip on.
    public func visualOffset(of row: Int, from top: Int) -> Int? {
        guard row >= top else { return nil }
        var offset = 0
        var current = top
        while current <= row {
            if let range = fold(containing: current) {
                if range.contains(row) { return offset }
                current = range.upperBound + 1
            } else {
                if current == row { return offset }
                current += 1
            }
            offset += 1
            if offset > 100_000 { return nil }
        }
        return nil
    }
}
