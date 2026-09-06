//  PaneView.swift — a terminal with a gutter beside it.
//
//  The gutter is where a shell command stops being a stream of text and
//  becomes an object: a red tick against the prompt of a command that failed,
//  and the time it took at the end of its line. Both are drawn from the block
//  log, which is fed by OSC 133 — so this works in a shell with no agent in
//  sight, and disappears entirely in a shell without integration.

import AppKit
import TerminalCore

@MainActor
protocol PaneViewDelegate: AnyObject {
    func paneDidRequestFocus(_ pane: PaneView)
}

@MainActor
final class PaneView: NSView, ThemeAware {
    func applyTheme() {
        layer?.backgroundColor = Theme.current.ground.cgColor
    }

    static let gutterWidth: CGFloat = 16

    let session: Session
    weak var delegate: PaneViewDelegate?
    private let overlay: BlockOverlayView
    private(set) var isActive = false
    var foldTargets: [[String: Any]] { overlay.testFoldTargets }
    var durationLabels: [[String: Any]] { overlay.durationLabels }
    var durationLabelsDropped: Int { overlay.durationLabelsDropped }

    init(session: Session) {
        self.session = session
        overlay = BlockOverlayView(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.current.ground.cgColor

        let surface = session.backend.surface
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor,
                                             constant: Self.gutterWidth),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        session.observe { [weak self] in self?.overlay.needsDisplay = true }
        // The cover of ISC-114 moves with the rows under it, not only when it
        // appears and goes, so it redraws on the scan itself. The session only
        // calls this while the experiment is armed.
        session.onScreenScanned = { [weak self] in self?.overlay.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        overlay.isActivePane = active
        overlay.needsDisplay = true
        if active { session.backend.focus(); session.markSeen() }
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.paneDidRequestFocus(self)
        super.mouseDown(with: event)
    }

    /// Called on a cadence only while a command is running, so a still
    /// terminal draws nothing at all (ISC-38).
    func tickRunningDuration() {
        guard session.blocks.openBlock != nil else { return }
        overlay.needsDisplay = true
    }
}

/// Transparent layer over the terminal: ticks in the gutter, durations at the
/// end of command lines. Every click falls through except one on a tick.
@MainActor
final class BlockOverlayView: NSView {
    private let session: Session
    var isActivePane = false
    /// Screen rects of failure ticks, rebuilt on each draw, so a click can
    /// find the block it belongs to without a second derivation of the layout.
    private var tickTargets: [(rect: NSRect, id: Int)] = []
    /// Screen rects of the folded-work strips, rebuilt on each draw, so a
    /// click opens the turn it belongs to (ISC-94).
    private var foldTargets: [(rect: NSRect, range: ClosedRange<Int>)] = []
    /// The renderer's scroll-offset callback is attached on the first draw
    /// that finds a renderer, because the GPU view is created after this
    /// overlay is (ISC-242).
    private var scrollWired = false

    /// The duration labels the last draw actually printed, row and text. Two
    /// entries with the same row would be two labels on top of each other,
    /// which is a thing a bench can assert and eyes cannot (ISC-137).
    private(set) var durationLabels: [[String: Any]] = []
    /// How many the last draw REFUSED because their row was already taken.
    /// It is the number that says the guard had something to do: without it,
    /// "no two labels share a row" is also true of a screen where no two
    /// labels ever wanted to (ISC-137).
    private(set) var durationLabelsDropped = 0

    /// The click targets the last draw put on screen. A claim that a strip is
    /// clickable is a claim about these rectangles, and a bench that cannot
    /// see them can only report that a click did nothing.
    var testFoldTargets: [[String: Any]] {
        foldTargets.map { ["y": Double($0.rect.minY), "height": Double($0.rect.height),
                           "from": $0.range.lowerBound, "to": $0.range.upperBound] }
    }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if tickTargets.contains(where: { $0.rect.contains(local) }) { return self }
        if foldTargets.contains(where: { $0.rect.contains(local) }) { return self }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        tickTargets.removeAll(keepingCapacity: true)
        foldTargets.removeAll(keepingCapacity: true)
        let palette = Theme.current
        let grid = session.backend.grid
        let rowHeight = session.backend.cellHeight
        guard rowHeight > 1 else { return }
        // The rows are drawn `scrollOffset` points higher than their integral
        // row while a precise scroll is in flight (ISC-235), and every
        // annotation here is placed by row number: without the same
        // translation the pills lag the text by up to a row and land on the
        // line below (ISC-242). Redrawn on every change of the offset, gesture
        // and settle alike, so the pills move in the same frame as the text.
        if !scrollWired, let renderer = session.backend.renderer {
            renderer.onScrollOffsetChanged = { [weak self] in self?.needsDisplay = true }
            scrollWired = true
        }
        let scrollOffset = session.backend.renderer?.scrollOffset ?? 0

        // Pure chat, and it is drawn BEFORE the alternate-screen guard below
        // on purpose (ISC-114). Every other annotation here steps back when a
        // program takes the alternate screen, because that screen is the
        // program's. This one is the opposite case, for the same reason the
        // permission scanner reads that screen: the agent whose prompt is
        // being covered runs its whole interface there (measured 2026-08-21,
        // `claude` 2.1.239 — `alternate_on: 1` at its resting prompt), so a
        // cover that stepped back would never cover anything at all.
        if let prompt = session.hostedPrompt {
            let offset = prompt.topRule - grid.topVisibleRow
            let y = OverlayRowGeometry.y(offset: offset, rowHeight: rowHeight,
                                         scrollOffset: scrollOffset)
            let height = CGFloat(prompt.rowCount) * rowHeight
            // Scrolled out of sight is not covered: the box keeps its
            // scroll-invariant rows, and the patch has to leave with them.
            if y + height > 0, y < bounds.height {
                let rect = NSRect(x: PaneView.gutterWidth, y: y,
                                  width: bounds.width - PaneView.gutterWidth,
                                  height: height)
                // GROUND, and deliberately nothing else. The first build of
                // this drew the composer's own card here, on the reading that
                // T4A should put "its bubble" where the program's prompt was.
                // Photographed (2026-08-21, `f5-114-pure-chat-covered.png`)
                // that produced TWO bubbles on one screen: the real composer
                // at the foot of the window, and up here a rounded box that
                // looks exactly like a text field and accepts nothing. The
                // claim this feature exists to satisfy is one input line on
                // screen, so the cover has to be the absence of an input line
                // and not the picture of one.
                palette.ground.setFill()
                rect.fill()
            }
        }

        // The alternate screen belongs entirely to the program drawing it —
        // vim gets no annotations from us.
        guard !grid.isAlternateScreenActive else { return }

        let top = grid.topVisibleRow
        // One more than the whole rows that fit: with a sub-row offset the
        // row after the last whole one is partly on screen too.
        let visibleRows = Int(bounds.height / rowHeight) + 2
        var durations: [(offset: Int, y: CGFloat, label: String,
                         attributes: [NSAttributedString.Key: Any])] = []
        // The folds the RENDERER is using, asked of the backend rather than
        // rebuilt here: a label drawn from a second derivation of the same
        // ranges is how an overlay ends up a row off its own strip.
        let folds = session.backend.folds

        if !folds.isEmpty {
            for (offset, entry) in folds.rows(from: top, count: visibleRows).enumerated() {
                guard case .fold(let range) = entry else { continue }
                let y = OverlayRowGeometry.y(offset: offset, rowHeight: rowHeight,
                                             scrollOffset: scrollOffset)
                let label = "▸ " + session.foldLabel(for: range)
                let text = NSAttributedString(string: label, attributes: [
                    .font: Theme.labelFont(10),
                    .foregroundColor: palette.whisper,
                ])
                let size = text.size()
                let x = PaneView.gutterWidth + 6
                // A patch of ground behind the words, so the rule the renderer
                // drew passes on either side of them instead of through them.
                palette.ground.setFill()
                NSRect(x: x - 5, y: y, width: size.width + 12, height: rowHeight).fill()
                text.draw(at: NSPoint(x: x, y: y + (rowHeight - size.height) / 2))
                foldTargets.append((NSRect(x: 0, y: y, width: bounds.width,
                                           height: rowHeight), range))
            }
        }

        for block in session.blocks.blocks {
            // The prompt row is the row the command was typed on. `outputRow`
            // is the row after it, which is the next command's line: a tick
            // there accuses the wrong command.
            guard let offset = folds.isEmpty
                ? (block.promptRow >= top - 1 ? block.promptRow - top : nil)
                : folds.visualOffset(of: block.promptRow, from: top),
                offset >= -1, offset <= visibleRows else { continue }
            let y = OverlayRowGeometry.y(offset: offset, rowHeight: rowHeight,
                                         scrollOffset: scrollOffset)

            if block.showsFailureMark {
                let tick = NSRect(x: 5, y: y + 2, width: 3, height: max(4, rowHeight - 4))
                palette.failed.setFill()
                NSBezierPath(roundedRect: tick, xRadius: 1.5, yRadius: 1.5).fill()
                tickTargets.append((tick.insetBy(dx: -4, dy: -2), block.id))
            }

            if let duration = block.duration, block.finishedAt != nil {
                let label = Self.format(duration)
                // Collected rather than drawn, because two blocks can land on
                // ONE visual row and the second would print on top of the
                // first: `7ms` and `12ms` stacked into an unreadable smudge in
                // the light-theme photographs of 22/08 (ISC-137). A fold
                // collapses several source rows onto one, and the clamp at the
                // top of the view puts anything above the viewport on the same
                // row too. Which one wins is decided after the loop.
                // The label sits at the right edge, so it must not land on the
                // command it describes. The clearance is counted in CELLS,
                // where both the text and the label have an exact length —
                // measuring it in pixels would need a cell width this view
                // does not have, and a nearly-right one puts the label on top
                // of the text in a narrow split.
                let textCells = grid.line(at: block.promptRow)?.text.count ?? 0
                guard textCells + 2 + label.count <= grid.columns else { continue }
                let colour = block.didFail ? palette.failedSoft : palette.whisper
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: Theme.labelFont(10),
                    .foregroundColor: colour,
                ]
                durations.append((offset: offset, y: y, label: label,
                                  attributes: attributes))
            }
        }

        // One duration a row, and the LAST block wins.
        //
        // Precedence rather than stacking: there is nowhere to stack to — the
        // row is one row high and the column to the left belongs to the text —
        // and the last block is the one whose command is actually drawn there,
        // an older one having been folded or clamped onto the same line. The
        // ones that lose are dropped rather than nudged, because a duration in
        // the wrong place is worse than no duration: it accuses the wrong
        // command.
        var taken = Set<Int>()
        durationLabels.removeAll(keepingCapacity: true)
        durationLabelsDropped = 0
        for entry in durations.reversed() {
            guard taken.insert(entry.offset).inserted else {
                durationLabelsDropped += 1
                continue
            }
            let text = NSAttributedString(string: entry.label, attributes: entry.attributes)
            let size = text.size()
            let x = bounds.width - size.width - 10
            // A duration sits on the row the command started on, at the far
            // right, where no shell writes.
            text.draw(at: NSPoint(x: x, y: entry.y + (rowHeight - size.height) / 2))
            durationLabels.append(["row": entry.offset, "label": entry.label])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = tickTargets.first(where: { $0.rect.contains(point) }) {
            session.blocks.acknowledgeFailure(id: hit.id)
            return
        }
        guard let fold = foldTargets.first(where: { $0.rect.contains(point) }),
              let turn = session.turn(foldedAs: fold.range) else { return }
        session.toggleFold(turn: turn)
    }

    static func format(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        if minutes < 60 { return "\(minutes)m\(String(format: "%02d", rest))s" }
        return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))m"
    }
}
