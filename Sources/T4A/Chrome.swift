//  Chrome.swift — the frame around the terminal, carried over from the demo
//  the principal ratified: a band on top with the waiting count and the
//  title, a floating sessions rail on the left, an inspector flush to the
//  right edge, a dashboard strip along the bottom.
//
//  Numbers are from design/MISURE.md and demo/styles.css. Nothing here is
//  re-designed: Phase 1 settled the layout, Phase 2 moves it onto real
//  processes.

import AppKit

/// Stable names spoken by the band benches. The retired address
/// "sessions panel" remains documented because its absence is itself probed.
enum BenchBand {
    static let turnMap = "turn map panel"
    static let preview = "preview panel"
    static let dashboard = "dashboard bar"
    static let sessionsLayout = "sessions layout"
}

/// A button whose whole rectangle is clickable, not just its text
/// (MacAppRules §3).
@MainActor
final class ChromeButton: NSButton, ThemeAware {
    func applyTheme() { contentTintColor = Theme.current.muted }

    private var hovering = false
    var isSelected = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    /// What the click does. A `var` and not a stored closure passed once:
    /// the approval card rebinds its two buttons every time the question
    /// changes, and a rebuilt button would take the focus with it.
    var onClick: () -> Void

    init(title: String, action: @escaping () -> Void = {}) {
        onClick = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = Theme.Metric.cardRadius
        contentTintColor = Theme.current.muted
        font = Theme.uiFont(12)
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { onClick() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        if isSelected || hovering {
            (isSelected ? palette.raised : palette.pane).setFill()
            NSBezierPath(roundedRect: bounds,
                         xRadius: Theme.Metric.cardRadius,
                         yRadius: Theme.Metric.cardRadius).fill()
        }
        palette.hairline.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: Theme.Metric.cardRadius,
                                  yRadius: Theme.Metric.cardRadius)
        border.lineWidth = 1
        border.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.uiFont(12),
            .foregroundColor: isSelected ? palette.ink : palette.muted,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))
    }
}

/// The top band: the count that shouts, the title on the terminal's own
/// column, and the panel toggles.
@MainActor
final class BandView: NSView, LanguageAware {
    var onWaitingClick: (() -> Void)?
    var waitingCount = 0 {
        didSet {
            guard waitingCount != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    /// The count block exists only while an agent lives somewhere: a person
    /// using T4A as a plain terminal was carrying «0 waiting» in the corner
    /// for nothing (his call, 25/08). Automatic, from the sessions.
    var showsWaiting = true {
        didSet {
            guard showsWaiting != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var title = "" { didSet { needsDisplay = true } }
    var path = "" { didSet { needsDisplay = true } }
    /// In full screen the system titlebar is gone. The band becomes the
    /// transparent header of the middle column instead of reserving another
    /// row above all three columns. The controller changes this in the
    /// system's WillEnter/WillExit animation context (ISC-238).
    private(set) var isFullScreenCompact = false
    static let compactHeight: CGFloat = 38
    /// Distance from the left edge to the terminal's first character, so the
    /// title sits on the terminal's column (ISC-81).
    var titleX: CGFloat = Theme.Metric.textInset { didSet { needsDisplay = true } }

    /// Where the band's own content may start. The window buttons sit in this
    /// band because the titlebar is transparent, so the inset is read from the
    /// buttons themselves rather than typed in — a hand-set constant is right
    /// until macOS moves them.
    private var contentInset: CGFloat {
        guard let button = window?.standardWindowButton(.zoomButton) else { return 78 }
        let frame = button.convert(button.bounds, to: nil)
        return frame.maxX + 14
    }

    override var isFlipped: Bool { true }

    /// Doppio click sulla banda: la finestra fa quello che il Mac dice di fare
    /// (suo, 26/08).
    ///
    /// La banda occupa la fascia della barra del titolo, che è trasparente e
    /// a tutta altezza: il doppio click che in ogni app ingrandisce la
    /// finestra qui moriva su questa vista. La risposta non è cablata a
    /// «ingrandisci» perché quel gesto è una PREFERENZA di sistema
    /// (`AppleActionOnDoubleClick`, Impostazioni → Scrivania e Dock), e
    /// un'app che la ignora è un'app che si comporta diversamente dalle altre
    /// sullo stesso Mac.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, waitingCount > 0, waitingHitRect.contains(point) {
            onWaitingClick?()
            return
        }
        guard event.clickCount == 2 else { super.mouseDown(with: event); return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.miniaturize(nil)
        case "None": break
        default: window?.zoom(nil)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if waitingCount > 0, waitingHitRect != .zero {
            addCursorRect(waitingHitRect, cursor: .pointingHand)
        }
    }

    func testPressWaiting() {
        guard waitingCount > 0 else { return }
        onWaitingClick?()
    }

    /// Where each piece of text ended up, in the band's own coordinates.
    /// A claim about air is a claim about numbers, and these are the numbers
    /// the drawing actually used (ISC-105).
    private(set) var inkRects: [String: NSRect] = [:]

    /// Number and word are one target. Insets make the target honest even
    /// around the thin 28-point numeral zero/one.
    var waitingHitRect: NSRect {
        guard showsWaiting, let count = inkRects["count"], let word = inkRects["waiting"]
        else { return .zero }
        return count.union(word).insetBy(dx: -5, dy: -4)
    }

    // MARK: - The switches on the right (ISC-104.5)

    let inspectorToggle = PanelToggleButton(edge: .right, label: BenchBand.turnMap,
                                            displayLabel: S.turnMapPanel)
    /// Il quarto, e c'è solo quando un'anteprima è caricata (ISC-176).
    ///
    /// Stessa famiglia degli altri — stessa cornice, stessa taglia, stesso
    /// posto — e un disegno suo: gli altri portano una barra su un bordo,
    /// perchè rispondono a «da che parte sta quel pannello»; questo porta un
    /// foglio in mezzo, perchè risponde a «c'è un file aperto». Un glifo
    /// identico a un altro accanto a lui è il difetto che ISC-156 ha gia`
    /// pagato una volta.
    let previewToggle = PanelToggleButton(edge: .right, label: BenchBand.preview,
                                          displayLabel: S.previewPanel)
    let dashToggle = PanelToggleButton(edge: .bottom, label: BenchBand.dashboard,
                                       displayLabel: S.dashboardBar)
    /// Where the sessions live: down the left, or across the top (ISC-147).
    ///
    /// No longer built here: the button itself lives in the sessions panel, at
    /// the corner opposite these switches. What follows is why it looks the
    /// way it does, kept because the reasoning is about the glyph.
    ///
    /// The odd one out among the four, and deliberately so. The other three
    /// answer "is this panel there?" and their fill says yes or no. This one
    /// answers "WHERE are they?", which has two answers and no off — so the
    /// bar moves instead of the fill: on the left edge for the rail, on the
    /// top edge for tabs, which is the same promise the other three make, that
    /// the glyph draws the edge it commands. The fill keeps the meaning it has
    /// beside them: your sessions are on the screen somewhere.
    private(set) lazy var settingsButton = ChromeButton(title: S.settingsButton)
    private lazy var actions: NSStackView = {
        let stack = NSStackView(views: toggleButtons + [settingsButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    private var actionsCenterY: NSLayoutConstraint!

    /// The three glyphs of the band, in the order they are drawn, for a bench
    /// that wants to press one by the name a person reads for it.
    ///
    /// Two, since 2026-08-25. The sessions cannot be hidden at all any more —
    /// they are down the left or across the top, never nowhere — so a switch
    /// that turned the rail off was offering a state the app no longer has.
    /// The arrow at the other corner is the whole of that control now.
    /// The layout glyph moved to the opposite corner, where the sessions are
    /// named, because it commands the sessions and not a panel; it lives in
    /// `RailView` and in `TabStripView`, whichever of the two is on screen.
    var toggleButtons: [PanelToggleButton] {
        [dashToggle, inspectorToggle, previewToggle]   // inverted at his word, 25/08
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewToggle.showsDocument = true
        previewToggle.isHidden = true
        addSubview(actions)
        settingsButton.font = Theme.uiFont(11)
        actionsCenterY = actions.centerYAnchor.constraint(
            equalTo: topAnchor,
            constant: Theme.Metric.bandTopInset
                + (Theme.Metric.bandHeight - Theme.Metric.bandTopInset) / 2)
        NSLayoutConstraint.activate([
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            // Below the titlebar strip, on the same line the count sits on:
            // the window buttons live in this band and the switches must not
            // share their row.
            actionsCenterY,
            settingsButton.heightAnchor.constraint(equalToConstant: 20),
            settingsButtonWidth,
        ])
        fitSettingsButton()
    }

    /// Sized to the word, not to a number: «impostazioni» is twice as long
    /// as «settings», and a fixed 62 showed «mpostazion» (6/09, foto).
    private lazy var settingsButtonWidth = settingsButton.widthAnchor.constraint(equalToConstant: 62)

    private func fitSettingsButton() {
        let width = settingsButton.title.size(withAttributes: [.font: Theme.uiFont(11)]).width
        settingsButtonWidth.constant = max(62, ceil(width) + 16)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyLanguage() {
        inspectorToggle.displayLabel = S.turnMapPanel
        previewToggle.displayLabel = S.previewPanel
        dashToggle.displayLabel = S.dashboardBar
        settingsButton.title = S.settingsButton
        fitSettingsButton()
        needsDisplay = true
    }

    /// Changes only model targets through animator proxies. The surrounding
    /// full-screen NSAnimationContext supplies the clock; this view never
    /// invents a duration of its own (ISC-238 / Reduce Motion).
    func setFullScreenCompact(_ compact: Bool, animated: Bool) {
        isFullScreenCompact = compact
        actions.isHidden = false
        let center = compact
            ? Self.compactHeight / 2
            : Theme.Metric.bandTopInset
                + (Theme.Metric.bandHeight - Theme.Metric.bandTopInset) / 2
        if animated {
            actionsCenterY.animator().constant = center
            actions.animator().alphaValue = compact ? 0 : 1
        } else {
            actionsCenterY.constant = center
            actions.alphaValue = compact ? 0 : 1
        }
        inkRects.removeAll(keepingCapacity: true)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Hiding a zero-alpha stack and fixing its model values changes no pixel;
    /// it merely takes dead controls out of AppKit's view walk after DidEnter.
    func finishFullScreenAppearance(_ compact: Bool) {
        isFullScreenCompact = compact
        actionsCenterY.constant = compact
            ? Self.compactHeight / 2
            : Theme.Metric.bandTopInset
                + (Theme.Metric.bandHeight - Theme.Metric.bandTopInset) / 2
        actions.alphaValue = compact ? 0 : 1
        actions.isHidden = compact
        needsDisplay = true
    }

    /// The compact header lies over the stage. Only its real controls may
    /// take the mouse; its transparent air belongs to the pane underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isFullScreenCompact else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        if waitingCount > 0, waitingHitRect.contains(local) { return self }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        // Constraint animation changes the actual bounds every frame. This
        // fraction therefore uses the system transition itself as its clock:
        // 78 pt is the untouched windowed band, 38 pt the compact header.
        let compactFraction = min(1, max(0,
            (Theme.Metric.bandHeight - bounds.height)
                / (Theme.Metric.bandHeight - Self.compactHeight)))
        // Windowed geometry is deliberately unchanged. In full screen the
        // middle header shares the stage's first row, so painting an opaque
        // full-width band here would cover the rail and inspector headers.
        if compactFraction < 1 {
            palette.ground.withAlphaComponent(1 - compactFraction).setFill()
            bounds.fill()
        }
        inkRects.removeAll(keepingCapacity: true)

        // The line is centred in the band BELOW the titlebar strip, not in the
        // whole band: centring in the whole thing is what put the count level
        // with the window buttons.
        let topInset = Theme.Metric.bandTopInset * (1 - compactFraction)
        let line = NSRect(x: 0, y: topInset,
                          width: bounds.width,
                          height: bounds.height - topInset)
        let baseline = line.midY

        // The count is the one accented thing on the screen, and only when it
        // is not zero (Principles: the accent marks one thing).
        let countColour = waitingCount > 0 ? palette.accentText : palette.whisper
        let number = NSAttributedString(string: "\(waitingCount)", attributes: [
            .font: Theme.uiFont(28, weight: .light), .foregroundColor: countColour,
        ])
        let numberSize = number.size()
        // The count no longer has to dodge the window buttons, so it starts on
        // the same left margin as everything else in the band.
        // In the overlay header the left column belongs to SESSIONS. Keep the
        // working waiting target in the middle column, before its title.
        let leftEdge = Theme.Metric.textInset
            + (self.titleX - Theme.Metric.textInset) * compactFraction
        let countFont = Theme.uiFont(28, weight: .light)
        let titleFont = Theme.uiFont(15, weight: .medium)
        // y=14 is the actual ink origin used by both side headings. Giving
        // the title that same origin is the visual invariant F0 measures.
        let regularBaseline = baseline - numberSize.height / 2 + countFont.ascender
        let compactBaseline = 14 + titleFont.ascender
        let sharedBaseline = regularBaseline
            + (compactBaseline - regularBaseline) * compactFraction
        let numberOrigin = NSPoint(x: leftEdge, y: sharedBaseline - countFont.ascender)
        if showsWaiting {
            number.draw(at: numberOrigin)
            inkRects["count"] = NSRect(origin: numberOrigin, size: numberSize)
        }

        // One baseline for the whole line, as in the demo: four pieces of text
        // at four sizes, each centred on its own middle, is four slightly
        // different heights pretending to be a row.
        func drawText(_ string: String, font: NSFont, colour: NSColor,
                      x: CGFloat, key: String) -> NSRect {
            let text = NSAttributedString(string: string,
                                          attributes: [.font: font, .foregroundColor: colour])
            let size = text.size()
            let origin = NSPoint(x: x, y: sharedBaseline - font.ascender)
            text.draw(at: origin)
            let rect = NSRect(origin: origin, size: size)
            inkRects[key] = rect
            return rect
        }

        if showsWaiting {
            _ = drawText(S.waiting, font: Theme.uiFont(11), colour: palette.whisper,
                         x: leftEdge + numberSize.width + 7, key: "waiting")
        }

        // Title and path share that same baseline (ISC-96) and start on the
        // terminal's own column. With the count away, the title owns the left.
        let titleX = showsWaiting ? max(self.titleX, leftEdge + numberSize.width + 70)
                                  : max(self.titleX, leftEdge)
        let titleRect = drawText(title, font: titleFont,
                                 colour: palette.ink, x: titleX, key: "title")
        if !path.isEmpty {
            _ = drawText(path, font: Theme.uiFont(12), colour: palette.whisper,
                         x: titleRect.maxX + 10, key: "path")
        }
    }
}

/// A panel at the edge of the window, with ONE rounded corner: the top one
/// facing the terminal.
///
/// The two extreme panels used to disagree — the rail floated, rounded on
/// four corners and inset from the window, while the inspector sat flush and
/// square — and the disagreement showed up as two top edges at two different
/// heights (his screenshot, 20/08 21:38). One shape, mirrored, fixes both:
/// each panel keeps its straight sides against the window frame and turns
/// only the corner that faces the middle (ISC-111).
@MainActor
class EdgePanel: NSView {
    /// Which side of this panel looks at the terminal.
    enum Facing: String { case leading, trailing }

    var facing: Facing = .trailing { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = Theme.Metric.panelRadius { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// The radius each corner was drawn with, by name, in the panel's own
    /// top-left coordinates. A claim about a corner shape is checked against
    /// the numbers the drawing used, never read off a screenshot by eye.
    var drawnCorners: [String: CGFloat] {
        let r = cornerRadius
        return facing == .trailing
            ? ["topLeft": 0, "topRight": r, "bottomRight": 0, "bottomLeft": 0]
            : ["topLeft": r, "topRight": 0, "bottomRight": 0, "bottomLeft": 0]
    }

    /// The panel's outline: three square corners and one round one.
    ///
    /// Built from lines and cubic curves rather than `appendArc`, because the
    /// view is flipped and an arc's sweep direction flips with it — geometry
    /// written out by hand looks the same in either coordinate system.
    private func outline(in rect: NSRect) -> NSBezierPath {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        // The circle-to-bezier constant: a corner drawn with control points
        // this far along each edge is within a quarter of a percent of a real
        // quarter circle.
        let k = r * 0.5523
        let path = NSBezierPath()
        let left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if facing == .leading {
            // Top-left is the round one.
            path.move(to: NSPoint(x: left + r, y: top))
            path.line(to: NSPoint(x: right, y: top))
            path.line(to: NSPoint(x: right, y: bottom))
            path.line(to: NSPoint(x: left, y: bottom))
            path.line(to: NSPoint(x: left, y: top + r))
            path.curve(to: NSPoint(x: left + r, y: top),
                       controlPoint1: NSPoint(x: left, y: top + r - k),
                       controlPoint2: NSPoint(x: left + r - k, y: top))
        } else {
            // Top-right is the round one.
            path.move(to: NSPoint(x: left, y: top))
            path.line(to: NSPoint(x: right - r, y: top))
            path.curve(to: NSPoint(x: right, y: top + r),
                       controlPoint1: NSPoint(x: right - r + k, y: top),
                       controlPoint2: NSPoint(x: right, y: top + r - k))
            path.line(to: NSPoint(x: right, y: bottom))
            path.line(to: NSPoint(x: left, y: bottom))
        }
        path.close()
        return path
    }

    /// The top of the panel and its one round corner — the short run that
    /// gives the panel its shape where it meets the band. Solid.
    ///
    /// It used to carry on down the whole facing side, and that continuation
    /// was one of the two vertical monochrome lines the principal objected to
    /// on 22/08 (ISC-124). The side is now `flank`, and it fades.
    private func crown(in rect: NSRect) -> NSBezierPath {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let k = r * 0.5523
        let path = NSBezierPath()
        let left = rect.minX, right = rect.maxX, top = rect.minY
        if facing == .leading {
            path.move(to: NSPoint(x: right, y: top))
            path.line(to: NSPoint(x: left + r, y: top))
            path.curve(to: NSPoint(x: left, y: top + r),
                       controlPoint1: NSPoint(x: left + r - k, y: top),
                       controlPoint2: NSPoint(x: left, y: top + r - k))
        } else {
            path.move(to: NSPoint(x: left, y: top))
            path.line(to: NSPoint(x: right - r, y: top))
            path.curve(to: NSPoint(x: right, y: top + r),
                       controlPoint1: NSPoint(x: right - r + k, y: top),
                       controlPoint2: NSPoint(x: right, y: top + r - k))
        }
        return path
    }

    /// The long side that looks at the terminal, from where the corner lets go
    /// down to the bottom of the window. Drawn with a fade rather than as a
    /// line: a one-pixel hairline held at one tone for eight hundred points is
    /// a rule, whatever palette it is drawn in.
    private func flank(in rect: NSRect) -> NSBezierPath {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let path = NSBezierPath()
        let x = facing == .leading ? rect.minX : rect.maxX
        path.move(to: NSPoint(x: x, y: rect.minY + r))
        path.line(to: NSPoint(x: x, y: rect.maxY))
        return path
    }

    /// How far down the corner's line is still there at all. A share of the
    /// height rather than a constant, so a short window does not get a stub
    /// and a tall one a bar.
    private func fadeLength(in rect: NSRect) -> CGFloat {
        min(rect.height * 0.30, 180)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        palette.ground.setFill()
        bounds.fill()
        let card = bounds
        let fill = outline(in: card)
        palette.panel.setFill()
        fill.fill()
        // Half a pixel in, so a stroke lands ON the boundary instead of
        // straddling it and coming out two pixels wide and soft.
        let edge = card.insetBy(dx: 0.5, dy: 0.5)
        palette.panelEdge.setStroke()
        let top = crown(in: edge)
        top.lineWidth = 1
        top.stroke()

        // The flank, stroked into a clip and filled with a gradient: AppKit
        // will not stroke a path in a gradient, and painting a fading
        // rectangle over the boundary by hand would put the fade half on the
        // panel and half on the page.
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(flank(in: edge).cgPath)
        context.setLineWidth(1)
        context.replacePathWithStrokedPath()
        context.clip()
        let start = edge.minY + min(cornerRadius, edge.height / 2)
        let gradient = NSGradient(
            colors: [palette.panelEdge, palette.panelEdge.withAlphaComponent(0)],
            atLocations: [0, 1], colorSpace: .sRGB)
        gradient?.draw(from: NSPoint(x: edge.midX, y: start),
                       to: NSPoint(x: edge.midX, y: start + fadeLength(in: edge)),
                       options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        context.restoreGState()
    }
}

/// The left panel: it faces the terminal with its right side.
@MainActor
class FloatingPanel: EdgePanel {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        facing = .trailing
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The right panel: it faces the terminal with its left side.
@MainActor
class FlushPanel: EdgePanel {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        facing = .leading
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One of the band's panel switches: a little window with a bar drawn on the
/// edge the panel it commands actually lives on (ISC-104.5).
///
/// Drawn rather than lettered on purpose. An icon that names its edge is the
/// difference between a switch you read and a switch you learn: the glyph for
/// the sessions panel has its bar on the LEFT because that is where the panel
/// is, and its filled state says whether the panel is there right now.
@MainActor
final class PanelToggleButton: NSView {
    enum Edge: String { case left, right, bottom, top }

    /// A `var` since ISC-147: the layout glyph draws the edge the sessions are
    /// on RIGHT NOW, so its bar moves from the left to the top and back. The
    /// other three are built with an edge and keep it for life.
    var edge: Edge { didSet { needsDisplay = true } }
    /// Where pressing this would SEND the thing it commands, or nil for the
    /// three switches that only turn a panel on and off (ISC-156).
    ///
    /// The glyph without it says where the sessions are, which is a fact and
    /// not an instruction — and in rail layout that fact is drawn as a box
    /// with a bar down the left, which is pixel for pixel the sessions-panel
    /// switch standing next to it. Two identical glyphs side by side is why
    /// he pressed this one looking for that one and read the result as the
    /// side panel moving his sessions up by itself. An arrow towards the
    /// destination is the difference between a label and a button.
    var destination: Edge? { didSet { needsDisplay = true } }
    /// Disegna un foglio in mezzo alla cornice invece di una barra su un
    /// bordo: è il glifo dell'anteprima (ISC-176). Un `var` e non una
    /// sottoclasse perchè cambia solo cosa c'è dentro la stessa cornice, e
    /// la cornice è tutto quello che rende questi quattro una famiglia.
    var showsDocument = false { didSet { needsDisplay = true } }
    /// The invariant English address used by the benches.
    let label: String
    /// What a person reads in the tooltip and through accessibility.
    var displayLabel: String? { didSet { updateDisplayedText() } }
    /// The sentence under the pointer. It starts as the label and the layout
    /// glyph rewrites it every time the sessions move, because a tooltip that
    /// says «sessions layout» tells you what the control is about and not what
    /// pressing it will do.
    var hint: String = "" {
        didSet { updateDisplayedText() }
    }
    var isOn = false { didSet { needsDisplay = true } }
    var onClick: () -> Void = {}

    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    static let size = NSSize(width: 27, height: 20)

    init(edge: Edge, label: String, displayLabel: String? = nil) {
        self.edge = edge
        self.label = label
        self.displayLabel = displayLabel
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        updateDisplayedText()
    }

    private func updateDisplayedText() {
        let text = hint.isEmpty ? (displayLabel ?? label) : hint
        toolTip = text
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

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
    /// The whole rectangle is the button, not just the glyph (MacAppRules §3).
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        let ink = isOn ? palette.ink : (hovering ? palette.ink : palette.muted)
        if isOn {
            palette.raised.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        (isOn || hovering ? palette.muted : palette.hairline).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()

        // The layout button draws ONE thing: the arrow. His call, 2026-08-25 —
        // «solo la freccia era comprensibile, così è brutto». The panel box
        // around it was a diagram of what would happen, and next to the three
        // switches that really are little panels it read as a fourth panel
        // rather than as a direction. Alone, at twice the size, it says «the
        // sessions go this way» and nothing else. Scale 1.3 and not 2: at
        // double it was «troppo grande ed invasiva» (25/08), which is fair —
        // this is a switch in a header, not a play button.
        if let destination {
            drawChevron(towards: destination, in: bounds, ink: ink)
            return
        }

        // The glyph: 15×12 with a 1pt border and a 3pt bar hugging one edge,
        // exactly the demo's numbers.
        let glyph = NSRect(x: (bounds.width - 15) / 2, y: (bounds.height - 12) / 2,
                           width: 15, height: 12)
        ink.setStroke()
        let box = NSBezierPath(roundedRect: glyph.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: 2, yRadius: 2)
        box.lineWidth = 1
        box.stroke()
        ink.setFill()
        let inner = glyph.insetBy(dx: 1, dy: 1)
        if showsDocument {
            // Un foglio al centro, con l'aria intorno: dice «qui dentro c'è
            // un documento», che è esattamente cosa mostra il pannello.
            NSRect(x: inner.midX - 3.5, y: inner.midY - 2.5,
                   width: 7, height: 5).fill()
            return
        }
        var free = inner
        switch edge {
        case .left:
            NSRect(x: inner.minX, y: inner.minY, width: 3, height: inner.height).fill()
            free.origin.x += 3; free.size.width -= 3
        case .right:
            NSRect(x: inner.maxX - 3, y: inner.minY, width: 3, height: inner.height).fill()
            free.size.width -= 3
        case .bottom:
            NSRect(x: inner.minX, y: inner.maxY - 3, width: inner.width, height: 3).fill()
            free.size.height -= 3
        case .top:
            // The view is flipped, so the top of the glyph is its minY. Said
            // here rather than remembered: a bar drawn on the wrong edge is a
            // glyph that lies about what it commands.
            NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: 3).fill()
            free.origin.y += 3; free.size.height -= 3
        }
        if let destination { drawArrow(towards: destination, in: free, ink: ink) }
    }

    /// The layout glyph: a chevron, two strokes and no fill. Picked by him on
    /// 2026-08-25 out of six drawn side by side («scelgo la due»): lighter
    /// than a solid triangle, and it reads as «that way» rather than «play».
    /// The view is flipped, so «towards the top» means towards minY.
    /// Option 1 of the six he was shown (25/08): the DESTINATION drawn as a
    /// bar on its edge, and the chevron moving toward it. The bare chevron
    /// read as «back»; the bar is what gives the arrow something to be going
    /// to.
    private func drawChevron(towards destination: Edge, in room: NSRect, ink: NSColor) {
        ink.setFill()
        ink.setStroke()
        let c = NSPoint(x: room.midX, y: room.midY)
        let half: CGFloat = 3.6, rise: CGFloat = 2.0
        let barLong: CGFloat = 10, barThin: CGFloat = 1.8, barOff: CGFloat = 5.5
        let path = NSBezierPath()
        switch destination {
        case .top:
            NSRect(x: c.x - barLong / 2, y: c.y - barOff - barThin / 2,
                   width: barLong, height: barThin).fill()
            path.move(to: NSPoint(x: c.x - half, y: c.y + 2.4 + rise))
            path.line(to: NSPoint(x: c.x, y: c.y + 2.4 - rise))
            path.line(to: NSPoint(x: c.x + half, y: c.y + 2.4 + rise))
        case .bottom:
            NSRect(x: c.x - barLong / 2, y: c.y + barOff - barThin / 2,
                   width: barLong, height: barThin).fill()
            path.move(to: NSPoint(x: c.x - half, y: c.y - 2.4 - rise))
            path.line(to: NSPoint(x: c.x, y: c.y - 2.4 + rise))
            path.line(to: NSPoint(x: c.x + half, y: c.y - 2.4 - rise))
        case .left:
            NSRect(x: c.x - barOff - barThin / 2, y: c.y - barLong / 2,
                   width: barThin, height: barLong).fill()
            path.move(to: NSPoint(x: c.x + 2.4 + rise, y: c.y - half))
            path.line(to: NSPoint(x: c.x + 2.4 - rise, y: c.y))
            path.line(to: NSPoint(x: c.x + 2.4 + rise, y: c.y + half))
        case .right:
            NSRect(x: c.x + barOff - barThin / 2, y: c.y - barLong / 2,
                   width: barThin, height: barLong).fill()
            path.move(to: NSPoint(x: c.x - 2.4 - rise, y: c.y - half))
            path.line(to: NSPoint(x: c.x - 2.4 + rise, y: c.y))
            path.line(to: NSPoint(x: c.x - 2.4 - rise, y: c.y + half))
        }
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// The little arrow in the room the bar left over (ISC-156). Filled, not
    /// stroked: at five points across, a stroked chevron is two grey smudges
    /// and a solid triangle is a direction.
    private func drawArrow(towards destination: Edge, in room: NSRect, ink: NSColor,
                           scale: CGFloat = 1) {
        ink.setFill()
        let centre = NSPoint(x: room.midX, y: room.midY)
        let long: CGFloat = 3.5 * scale, wide: CGFloat = 5 * scale
        let path = NSBezierPath()
        // The view is flipped: minY is the top of the glyph, so «up» is minus.
        switch destination {
        case .top:
            path.move(to: NSPoint(x: centre.x, y: centre.y - long))
            path.line(to: NSPoint(x: centre.x - wide / 2, y: centre.y + long))
            path.line(to: NSPoint(x: centre.x + wide / 2, y: centre.y + long))
        case .bottom:
            path.move(to: NSPoint(x: centre.x, y: centre.y + long))
            path.line(to: NSPoint(x: centre.x - wide / 2, y: centre.y - long))
            path.line(to: NSPoint(x: centre.x + wide / 2, y: centre.y - long))
        case .left:
            path.move(to: NSPoint(x: centre.x - long, y: centre.y))
            path.line(to: NSPoint(x: centre.x + long, y: centre.y - wide / 2))
            path.line(to: NSPoint(x: centre.x + long, y: centre.y + wide / 2))
        case .right:
            path.move(to: NSPoint(x: centre.x + long, y: centre.y))
            path.line(to: NSPoint(x: centre.x - long, y: centre.y - wide / 2))
            path.line(to: NSPoint(x: centre.x - long, y: centre.y + wide / 2))
        }
        path.close()
        path.fill()
    }
}
