//  ScrollGeometryTests.swift — the grid stays integral; only drawing moves.

import Foundation
import TerminalCore
import Testing

@Test func rowGeometryTranslatesPointsOnceAtBackingScale() {
    #expect(TerminalRowGeometry.y(screenRow: 0, cellHeight: 32,
                                  scrollOffset: 3, scale: 2) == -6)
    #expect(TerminalRowGeometry.y(screenRow: 1, cellHeight: 32,
                                  scrollOffset: 3, scale: 2) == 26)
    #expect(TerminalRowGeometry.y(screenRow: 7, cellHeight: 32,
                                  scrollOffset: 0, scale: 2) == 224)
}

@Test func preciseDeltasKeepTheRequiredNonNegativeRemainder() {
    let towardsHistory = PixelScrollGeometry.step(offset: 0, delta: 3, cellHeight: 16)
    #expect(towardsHistory.lines == 1)
    #expect(towardsHistory.offset == 13)

    let nextHistoryPixel = PixelScrollGeometry.step(offset: towardsHistory.offset,
                                                    delta: 3, cellHeight: 16)
    #expect(nextHistoryPixel.lines == 0)
    #expect(nextHistoryPixel.offset == 10)

    let towardsLive = PixelScrollGeometry.step(offset: 0, delta: -3, cellHeight: 16)
    #expect(towardsLive.lines == 0)
    #expect(towardsLive.offset == 3)
}

@Test func overlayAnnotationsSubtractTheSameOffsetTheRowsAreDrawnAt() {
    // At rest the overlay is where it always was: whole rows, nothing moved.
    #expect(OverlayRowGeometry.y(offset: 3, rowHeight: 16, scrollOffset: 0) == 48)
    // Mid-gesture the rows sit 5 points higher, and so does the pill on them:
    // the same number the renderer uses, before its own backing-scale factor.
    #expect(OverlayRowGeometry.y(offset: 3, rowHeight: 16, scrollOffset: 5) == 43)
    #expect(OverlayRowGeometry.y(offset: 3, rowHeight: 16, scrollOffset: 5)
            == TerminalRowGeometry.y(screenRow: 3, cellHeight: 32, scrollOffset: 5, scale: 2) / 2)
    // The row above the viewport can be drawn partly on screen: negative is legal.
    #expect(OverlayRowGeometry.y(offset: 0, rowHeight: 16, scrollOffset: 15) == -15)
}
