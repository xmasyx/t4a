//  GripView.swift — the seam between the terminal and a panel.
//
//  A real view rather than a gesture bolted onto the panel's edge: the thing
//  you drag has to be hit-testable, or the drag is only reachable from code
//  and the claim about resizing is a claim about a function call (ISC-104.4).
//
//  It writes nothing while it moves. The width lands in the file when the
//  mouse comes up, which is the same discipline the window frame learned in
//  ISC-106 — dozens of writes a second is how a config file gets shredded.
//
//  WHAT IT DRAWS, since 22/08 (ISC-124). It used to fill its whole rectangle
//  with the hairline colour, which is a three-point bar of one flat tone
//  running from the top of the stage to the bottom — «quelle linee verticali
//  monocolore brutte», said looking at the running app. It now draws the PAGE,
//  and over it the shade a raised panel casts on the ground beside it: a
//  falloff that starts at the panel's edge and is gone a few points later.
//  The grab zone is untouched — the rectangle is the same rectangle, and what
//  changed is only what gets painted inside it.

import AppKit

@MainActor
final class GripView: NSView {
    /// Wide enough to grab, narrow enough to read as a seam. The demo's is
    /// 3px and this matches it.
    static let thickness: CGFloat = 3

    /// Which side of this seam the panel is on, and therefore where the shade
    /// starts. It is set by the layout, not inferred from `invert`: `invert`
    /// answers "which way does a drag grow the panel", and a drawing that
    /// reads a fact out of a field kept for something else is a drawing that
    /// breaks the day the two stop agreeing.
    enum PanelSide { case left, right }
    var panelSide: PanelSide = .left

    /// Called with the width the panel should have, while the mouse moves.
    var onDrag: ((CGFloat) -> Void)?
    /// Called once, when the mouse comes up: the moment to write.
    var onEnd: (() -> Void)?
    /// The panel's width right now, asked at mouse-down so the drag is
    /// measured from where it started rather than accumulated.
    var currentWidth: (() -> CGFloat)?
    /// Which way the panel grows relative to the drag: the left panel grows
    /// with +x, the right one against it.
    var invert = false
    var range: ClosedRange<CGFloat> = 150...460

    private var startWidth: CGFloat = 0
    private var startX: CGFloat = 0
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        startWidth = currentWidth?() ?? 0
        // In WINDOW coordinates, because the grip itself moves with the panel
        // it resizes: measuring the drag in the grip's own space measures it
        // against a ruler that is sliding under the mouse.
        startX = event.locationInWindow.x
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let delta = event.locationInWindow.x - startX
        let wanted = startWidth + (invert ? -delta : delta)
        onDrag?(min(max(wanted, range.lowerBound), range.upperBound))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        // The seam IS the page. Anything else here is a line.
        palette.ground.setFill()
        bounds.fill()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // The shade. `hairlineSoft` is one soft step off the ground in every
        // palette, and the step goes the right way on its own: lighter than
        // the ground on a dark theme, darker than it on a light one, which is
        // what a shadow has to do to read as one on paper.
        //
        // Under the pointer it deepens and takes the colour of a control, so
        // the thing you are about to drag answers you. It is still a falloff
        // and never a fill: a bar that appears on hover is the same bar.
        let shade = dragging || hovering ? palette.muted : palette.hairlineSoft
        let strength: CGFloat = dragging ? 0.85 : (hovering ? 0.65 : 0.5)
        let gradient = NSGradient(
            colors: [shade.withAlphaComponent(strength),
                     shade.withAlphaComponent(strength * 0.30),
                     shade.withAlphaComponent(0)],
            atLocations: [0, 0.45, 1], colorSpace: .sRGB)
        let start = panelSide == .left ? bounds.minX : bounds.maxX
        let end = panelSide == .left ? bounds.maxX : bounds.minX
        gradient?.draw(from: NSPoint(x: start, y: bounds.midY),
                       to: NSPoint(x: end, y: bounds.midY), options: [])
    }
}
