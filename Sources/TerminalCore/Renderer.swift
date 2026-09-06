//  Renderer.swift — what the app may ask of whatever is drawing the grid.
//
//  The app never says "Metal". It says "draw this", "highlight these", "the
//  cursor moves like this", and "tell me how you are doing" — and a renderer
//  answers. The GPU renderer of F3 and the engine's own CPU renderer both sit
//  behind this, which is what makes ISC-24 (the fallback is always alive)
//  something you can switch at runtime rather than a promise.

import Foundation

/// Geometry shared by the renderer and its pure tests. Cell height is already
/// in backing pixels; the scroll remainder is in AppKit points and therefore
/// crosses the backing scale exactly once.
public enum TerminalRowGeometry {
    public static func y(screenRow: Int, cellHeight: CGFloat,
                         scrollOffset: CGFloat, scale: CGFloat) -> CGFloat {
        CGFloat(screenRow) * cellHeight - scrollOffset * scale
    }
}

/// Where an AppKit overlay draws the annotation of the row at visual
/// `offset`, in points, flipped coordinates: the same translation the GPU
/// applies to the row itself, in the overlay's own unit. Two derivations of
/// one position is how the fold pills drifted a whole row off the text they
/// labelled while the text glided at the pixel (ISC-242, his video of 5/09).
public enum OverlayRowGeometry {
    public static func y(offset: Int, rowHeight: CGFloat, scrollOffset: CGFloat) -> CGFloat {
        CGFloat(offset) * rowHeight - scrollOffset
    }
}

/// Decomposes one precise wheel delta into an integral viewport move and the
/// non-negative draw offset required by `TerminalRowGeometry`. Positive wheel
/// deltas move towards history; because the draw offset itself always moves
/// rows upwards, that direction takes the preceding integral row first and
/// uses the complementary offset to keep the pixels continuous.
public enum PixelScrollGeometry {
    public static func step(offset: CGFloat, delta: CGFloat,
                            cellHeight: CGFloat) -> (lines: Int, offset: CGFloat) {
        guard cellHeight > 0 else { return (0, 0) }
        let rawOffset = offset - delta
        let lines: Int
        if rawOffset < 0 {
            lines = Int(ceil(-rawOffset / cellHeight))
        } else if rawOffset >= cellHeight {
            lines = -Int(floor(rawOffset / cellHeight))
        } else {
            lines = 0
        }
        let remainder = rawOffset + CGFloat(lines) * cellHeight
        return (lines, min(max(0, remainder), cellHeight.nextDown))
    }
}

/// The shapes a cursor can take. Names, not numbers: a configuration file
/// says `cursor-style = bar`, and a person reading it knows what they will get.
public enum CursorStyle: String, CaseIterable, Sendable {
    case block, bar, underline
}

/// How the cursor travels between two cells.
public enum CursorMotion: String, CaseIterable, Sendable {
    /// No travel at all: it is simply in the new place on the next frame.
    case instant
    /// Exponential ease, the metalterm feel — fast out of the old cell and
    /// gently into the new one.
    case glide
    /// A light spring, with a touch of overshoot.
    case spring
}

/// A renderer that can hand a frame to Xcode's GPU debugger. Separate from
/// `TerminalRenderer` because a renderer that cannot do this is still a
/// renderer — the CPU fallback, for instance.
@MainActor
public protocol MetalCaptureCapable: AnyObject {
    func captureFrame(to path: String) -> String
}

@MainActor
public protocol TerminalRenderer: AnyObject {
    /// True when this renderer is drawing. False means the engine's own
    /// CPU renderer has the pane (ISC-24).
    var isActive: Bool { get }

    /// The grid changed; draw when the display is ready for it.
    func markDirty()

    /// Run at the top of every frame, before the grid is read.
    ///
    /// It exists for the scroll bench: a scroll driven by a timer competes
    /// with the display link for the main thread and drops frames of its own,
    /// which the measurement would then blame on the renderer. Driven from
    /// here, the content changes exactly once per frame, which is also what
    /// "continuous scroll" means.
    var beforeFrame: (() -> Void)? { get set }

    /// The sub-row translation the rows are drawn at, in points. Zero at
    /// rest; between a trackpad's precise deltas the rows sit this much
    /// higher than their integral row, and anything placed by row number
    /// over the text subtracts the same amount or drifts off it (ISC-242).
    var scrollOffset: CGFloat { get }

    /// Fires whenever `scrollOffset` changes — gesture, settle or reset — so
    /// an overlay can redraw in step with the frame instead of one row late.
    var onScrollOffsetChanged: (() -> Void)? { get set }

    /// Search hits to paint under the text, and which one is current.
    var highlights: [GridSpan] { get set }
    var currentHighlight: Int? { get set }

    /// The token under a Command-hover. Nil is the resting state, so the
    /// renderer does no link work unless the modifier has armed it.
    var linkHighlight: GridSpan? { get set }

    /// Rows the viewport must skip, standing in for each run with a single
    /// strip. Empty is the normal state and costs nothing: with no folds the
    /// row walk is the same arithmetic it always was (ISC-94).
    var folds: RowFold { get set }

    var cursorStyle: CursorStyle { get set }
    var cursorMotion: CursorMotion { get set }

    /// The one switch that stops every animation the renderer does. It is
    /// forced off — motion off — whenever the system asks for reduced motion,
    /// and the renderer says which of the two silenced it (ISC-67).
    var motionEnabled: Bool { get set }

    /// Where the cursor was drawn on each of the last few frames: time in
    /// seconds since the trail began, then column and row in CELLS, with the
    /// fraction that makes the movement sub-cell. It exists so "the cursor
    /// interpolates" can be read as numbers rather than judged from a video.
    var cursorTrail: [SIMD3<Double>] { get }

    /// Numbers the bench prints. Free-form so a different renderer can report
    /// what it actually knows instead of faking the fields of this one.
    func statistics() -> [String: Double]
    func resetStatistics()
}
