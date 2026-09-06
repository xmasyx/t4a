//  RailView.swift — the sessions list, in the register of Mail's sidebar:
//  no boxes, `› name … count`, a sub-line with state and title, a small-caps
//  heading, and a soft rounded wash for the selection (ISC-80).

import AppKit
import TerminalCore

@MainActor
final class RailRow: NSView {
    let session: Session
    var isSelected = false { didSet { needsDisplay = true } }
    private let onSelect: (Session) -> Void
    private let onClose: (Session) -> Void

    /// Where the × was drawn, in the row's own coordinates, or nil when it was
    /// not drawn at all. The click reads this rather than working the box out a
    /// second time: a hit box computed twice is a hit box that can disagree
    /// with the ink.
    private(set) var closeRect: NSRect?
    /// Where the turn count was drawn, or nil when the session has no turns.
    /// Kept for the same reason as `closeRect`: "the count never lands on the
    /// ×" is a claim about two rectangles, and reading them off the drawing is
    /// the only way to check it without a photograph (ISC-154).
    private(set) var countRect: NSRect?
    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(session: Session, onSelect: @escaping (Session) -> Void,
         onClose: @escaping (Session) -> Void) {
        self.session = session
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

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

    /// The × is tested BEFORE the row, because it sits inside it: a close box
    /// that loses to the row it lives on is a close box that selects (ISC-148).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let closeRect, closeRect.contains(point) {
            onClose(session)
            return
        }
        onSelect(session)
    }

    /// Where the × sits: the top-right corner, always (ISC-154).
    ///
    /// It used to appear only under the pointer, taking the corner from the
    /// turn count while the mouse was there and giving it back after — the two
    /// took turns because a count and a cross drawn on top of one another is
    /// the gutter defect of ISC-137 in another costume. Taking turns was the
    /// wrong way to keep them apart: a button that is only there once you have
    /// found it is a button you have to know about first. They now sit side by
    /// side, the count to the LEFT of the cross, and the corner belongs to the
    /// cross for good. Wider than the mark on purpose: the whole little square
    /// is the button, not the three strokes (MacAppRules §3).
    private var closeBox: NSRect {
        NSRect(x: bounds.width - 27, y: 6, width: 19, height: 19)
    }

    /// True while the row is showing a close box a person could hit. Used by
    /// the bench, which must not have to photograph a hover to know.
    var isShowingClose: Bool { closeRect != nil }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        if isSelected {
            palette.raised.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1),
                         xRadius: 7, yRadius: 7).fill()
        }

        let waiting = session.isWaitingForYou
        // The icon of the selected row uses the accent FILL; the accent TEXT
        // colour stays reserved for the session that is waiting for you, so
        // the one-accent rule holds (ISC-80).
        let chevronColour = waiting ? palette.accentText
            : (isSelected ? palette.accent : palette.whisper)
        let chevron = NSAttributedString(string: "›", attributes: [
            .font: Theme.uiFont(13), .foregroundColor: chevronColour,
        ])
        chevron.draw(at: NSPoint(x: 14, y: 8))

        let name = NSAttributedString(string: session.displayName, attributes: [
            .font: Theme.uiFont(13, weight: isSelected ? .medium : .regular),
            .foregroundColor: isSelected ? palette.ink : palette.muted,
        ])
        name.draw(at: NSPoint(x: 30, y: 7))

        // The × owns the corner, mouse or no mouse (ISC-154), and the count
        // sits to its left. The hover is still worth something — it is what
        // says the mark is a button — so it lights the cross rather than
        // conjuring it.
        let box = closeBox
        closeRect = box
        let cross = NSAttributedString(string: "×", attributes: [
            .font: Theme.uiFont(15),
            .foregroundColor: hovering ? palette.ink : palette.whisper,
        ])
        let crossSize = cross.size()
        cross.draw(at: NSPoint(x: box.midX - crossSize.width / 2,
                               y: box.midY - crossSize.height / 2))
        let count = session.blocks.blocks.count
        if count > 0 {
            let countText = NSAttributedString(string: "\(count)", attributes: [
                .font: Theme.labelFont(11), .foregroundColor: palette.whisper,
            ])
            // Right-aligned against the × instead of against the row's edge,
            // which is what keeps the two from ever sharing a pixel however
            // many turns the session has run.
            countText.draw(at: NSPoint(x: box.minX - 6 - countText.size().width, y: 9))
            countRect = NSRect(x: box.minX - 6 - countText.size().width, y: 9,
                               width: countText.size().width, height: 14)
        } else {
            countRect = nil
        }

        let statusColour = session.hasExited ? palette.failedSoft
            : (waiting ? palette.accentText : palette.whisper)
        // With an agent attached the sub-line leads with the STATE — the one
        // thing you came to the rail to find out — and the title follows it
        // (ISC-27). Without one it is what a terminal knows, as before.
        var statusText = session.statusLine
        if let agent = session.agent, agent.isAttached {
            let word: String
            switch session.activity {
            case .working: word = S.sessionWorking
            case .waiting: word = waiting ? S.sessionWaitsForYou : S.sessionWaiting
            case .idle: word = S.sessionIdle
            }
            let turns = agent.turns.count
            statusText = "\(word) · \(S.sessionTurnCount(turns))"
        }
        let status = NSAttributedString(string: statusText, attributes: [
            .font: Theme.uiFont(11), .foregroundColor: statusColour,
        ])
        let available = bounds.width - 46
        status.draw(in: NSRect(x: 30, y: 25, width: available, height: 15))

        if session.blocks.failureCount > 0 {
            palette.failed.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 10, y: 27, width: 5, height: 5)).fill()
        }
    }
}

@MainActor
final class RailView: FloatingPanel, LanguageAware {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private(set) var rows: [RailRow] = []
    var onSelect: ((Session) -> Void)?
    /// The × on a row (ISC-148). It closes that pane and nothing else, and the
    /// question it may have to ask is the window's, not one of its own.
    var onClose: ((Session) -> Void)?
    var onToggle: (() -> Void)?

    /// Where the sessions live, commanded from where the sessions are named.
    ///
    /// It used to sit in the band with the three panel switches, and it does
    /// not belong there: those three answer «is this panel on screen?», this
    /// one answers «where are my sessions?». Moved to this corner on 2026-08-24
    /// at his word, with `demo/local.html` measured first — the demo's band
    /// carries exactly three glyphs and no fourth.
    let layoutButton = PanelToggleButton(edge: .left, label: BenchBand.sessionsLayout,
                                         displayLabel: S.sessionsLayout)
    /// The ink actually drawn for F0. A container edge is not a witness for
    /// the line a person sees (ISC-238).
    private(set) var headingRect = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = stack
        addSubview(scrollView)
        layoutButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layoutButton)

        // The panel is flush with the window now (ISC-111), so these are the
        // panel's own padding rather than the inset of a floating card — and
        // the top one matches the inspector's, which is what makes the two
        // headings sit on one line.
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
            // In the header strip, against the far edge: the heading is drawn
            // at x=14 and this closes the same line on the other side.
            layoutButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            layoutButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyLanguage() {
        layoutButton.displayLabel = S.sessionsLayout
        rows.forEach { $0.needsDisplay = true }
        needsDisplay = true
    }

    func reload(sessions: [Session], selected: Session?) {
        if rows.count != sessions.count || !zip(rows, sessions).allSatisfy({ $0.session === $1 }) {
            rows.forEach { $0.removeFromSuperview() }
            rows = sessions.map { session in
                let row = RailRow(session: session,
                                  onSelect: { [weak self] in self?.onSelect?($0) },
                                  onClose: { [weak self] in self?.onClose?($0) })
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 46).isActive = true
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                return row
            }
        }
        for row in rows {
            row.isSelected = (row.session === selected)
            row.needsDisplay = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let palette = Theme.current
        let heading = NSAttributedString(string: S.sessionsHeading, attributes: [
            .font: Theme.labelFont(10),
            .foregroundColor: palette.whisper,
            .kern: 1.2,
        ])
        let origin = NSPoint(x: 14, y: 14)
        heading.draw(at: origin)
        headingRect = NSRect(origin: origin, size: heading.size())
    }
}

/// NSClipView draws bottom-up by default; every list in this app reads
/// top-down.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
