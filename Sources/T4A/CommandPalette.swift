//  CommandPalette.swift — ⌘K: every session, every theme, every action, one
//  list (ISC-32).
//
//  Two things make this file what it is.
//
//  The first is that the palette is the door to the rest of the app, so it
//  has to be there before the finger is off the key. <100 ms is the claim,
//  and a claim about latency is measured where the latency happens: the
//  keystroke's OWN timestamp — the one the window server stamped on the
//  event, not a clock read once the app is already awake — to the first
//  frame this view draws, and again to the moment that frame is on screen.
//  Both numbers are kept for every opening, so a distribution can be read
//  instead of a best case.
//
//  The second is that a palette that keeps the keyboard after it closes is
//  worse than no palette: the next thing typed is meant for the program in
//  the pane. The responder that had the keyboard is put back, always.

import AppKit

struct PaletteItem {
    /// `sessions`, `themes`, `actions` — the three families ISC-32 names.
    let family: String
    let displayFamily: String
    /// Stable English search and test address, independent of the title.
    let identifier: String
    let title: String
    let detail: String
    let run: () -> Void
}

/// One opening, as it was measured.
struct PaletteOpening {
    /// From the keystroke to the end of `open` — the app's own work, building
    /// the list and putting the view up. Everything after this number is
    /// AppKit and the window server.
    let toReadyMs: Double
    let toFirstDrawMs: Double
    let toPresentedMs: Double?
}

@MainActor
final class CommandPaletteView: NSView, ThemeAware, LanguageAware, NSTextFieldDelegate {
    static let cardWidth: CGFloat = 560
    private static let rowHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 22
    private static let fieldHeight: CGFloat = 44
    private static let maxRows = 9

    private let field = NSTextField()
    private var items: [PaletteItem] = []
    private(set) var visible: [PaletteItem] = []
    private(set) var selection = 0
    private var previousResponder: NSResponder?

    /// The keystroke's own timestamp, in the clock `CACurrentMediaTime`
    /// reads. Set before the view is ever added to the window.
    private var keystrokeAt: CFTimeInterval = 0
    private var measuredThisOpening = false
    private(set) var openings: [PaletteOpening] = []

    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.uiFont(15)
        field.placeholderString = S.commandPalettePlaceholder
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Opening and closing

    /// Everything that has to happen before the first frame. Kept small on
    /// purpose: the list is built here, so what the measurement covers is the
    /// real work of opening, not an empty box that fills in later.
    func open(items: [PaletteItem], at keystroke: CFTimeInterval,
              restoring responder: NSResponder?) {
        self.items = items
        self.keystrokeAt = keystroke
        self.previousResponder = responder
        measuredThisOpening = false
        field.stringValue = ""
        filter("")
        isHidden = false
        needsLayout = true
        needsDisplay = true
        readyMs = (CACurrentMediaTime() - keystroke) * 1000
    }

    /// Replace display text after a live language change without closing the
    /// palette or discarding what the person has typed.
    func replace(items: [PaletteItem]) {
        self.items = items
        filter(field.stringValue)
    }

    /// Set at the end of `open`, read by the first draw.
    private var readyMs: Double = 0

    func close() {
        guard !isHidden else { return }
        isHidden = true
        // The keyboard goes back where it came from. Without this the pane
        // keeps drawing a terminal that no longer receives anything typed.
        if let previousResponder, let window {
            window.makeFirstResponder(previousResponder)
        }
        onClose?()
    }

    func focusField() { window?.makeFirstResponder(field) }

    /// What the bench types into the field. It goes through the same
    /// notification a keystroke raises, so the filtering it triggers is the
    /// filtering a person triggers.
    func type(_ text: String) {
        field.stringValue = text
        selection = 0
        filter(text)
    }

    // MARK: - The list

    private func filter(_ text: String) {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        visible = needle.isEmpty ? items : items.filter {
            $0.title.lowercased().contains(needle)
                || $0.identifier.lowercased().contains(needle)
                || $0.detail.lowercased().contains(needle)
                || $0.family.contains(needle)
                || $0.displayFamily.lowercased().contains(needle)
        }
        selection = visible.isEmpty ? 0 : min(selection, visible.count - 1)
        needsDisplay = true
    }

    func move(_ step: Int) {
        guard !visible.isEmpty else { return }
        selection = (selection + step + visible.count) % visible.count
        needsDisplay = true
    }

    func runSelected() {
        guard visible.indices.contains(selection) else { return }
        let item = visible[selection]
        // Closed FIRST: an action that opens a window of its own must not
        // find the palette still sitting on top of it.
        close()
        item.run()
    }

    func controlTextDidChange(_ notification: Notification) {
        selection = 0
        filter(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    /// A click outside the card is a dismissal, the way every palette on this
    /// platform behaves.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(point) else { close(); return }
        guard let hit = rowRects.first(where: { $0.rect.contains(point) }) else { return }
        selection = hit.index
        runSelected()
    }

    // MARK: - Geometry

    var cardRect: NSRect {
        let rows = min(visible.count, Self.maxRows)
        let families = Set(visible.prefix(Self.maxRows).map(\.family)).count
        let height = Self.fieldHeight + CGFloat(rows) * Self.rowHeight
            + CGFloat(families) * Self.headerHeight + 8
        let width = min(Self.cardWidth, bounds.width - 80)
        return NSRect(x: (bounds.width - width) / 2, y: max(60, bounds.height * 0.16),
                      width: width, height: height)
    }

    /// Where each row was actually painted, filled in by `draw`.
    ///
    /// The click reads THIS rather than recomputing the layout, because a
    /// second derivation of a row's position is how a click ends up one row
    /// away from the thing it landed on — and headers are not the same height
    /// as rows, so the arithmetic has two cases to get wrong.
    private var rowRects: [(rect: NSRect, index: Int)] = []

    override func layout() {
        super.layout()
        let card = cardRect
        field.frame = NSRect(x: card.minX + 18, y: card.minY + 12,
                             width: card.width - 36, height: 22)
    }

    // MARK: - Paint

    func applyTheme() {
        field.textColor = Theme.current.ink
        needsDisplay = true
    }

    func applyLanguage() {
        field.placeholderString = S.commandPalettePlaceholder
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        // The page behind, dimmed. Not a blur: a blur on a terminal is a
        // frame's worth of work for a decoration.
        (palette.isLight ? NSColor(white: 0.35, alpha: 0.22)
                         : NSColor(white: 0, alpha: 0.38)).setFill()
        bounds.fill()

        let card = cardRect
        let path = NSBezierPath(roundedRect: card, xRadius: Theme.Metric.panelRadius,
                                yRadius: Theme.Metric.panelRadius)
        palette.panel.setFill()
        path.fill()
        palette.panelEdge.setStroke()
        path.lineWidth = 1
        path.stroke()

        // The hairline under the field.
        palette.hairlineSoft.setFill()
        NSRect(x: card.minX, y: card.minY + Self.fieldHeight - 1,
               width: card.width, height: 1).fill()

        var y = card.minY + Self.fieldHeight
        var family = ""
        rowRects.removeAll(keepingCapacity: true)
        for (index, item) in visible.prefix(Self.maxRows).enumerated() {
            if item.family != family {
                family = item.family
                NSAttributedString(string: item.displayFamily.uppercased(), attributes: [
                    .font: Theme.labelFont(9),
                    .foregroundColor: palette.whisper,
                    .kern: 1.2,
                ]).draw(at: NSPoint(x: card.minX + 18, y: y + 6))
                y += Self.headerHeight
            }
            let row = NSRect(x: card.minX + 6, y: y, width: card.width - 12,
                             height: Self.rowHeight)
            rowRects.append((row, index))
            if index == selection {
                palette.accentDim.setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: 2),
                             xRadius: Theme.Metric.cardRadius,
                             yRadius: Theme.Metric.cardRadius).fill()
            }
            let title = NSAttributedString(string: item.title, attributes: [
                .font: Theme.uiFont(13),
                .foregroundColor: index == selection ? palette.ink : palette.muted,
            ])
            title.draw(at: NSPoint(x: row.minX + 12, y: y + 9))
            if !item.detail.isEmpty {
                // The detail is whatever the session had to say about itself,
                // and a running command is as long as somebody typed. Drawn
                // at its natural width it went off the side of the card and
                // over the name — so it gets the room the title leaves and
                // not a pixel more.
                let room = row.width - 24 - title.size().width - 14
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingHead
                let detail = NSAttributedString(string: item.detail, attributes: [
                    .font: Theme.labelFont(10),
                    .foregroundColor: palette.whisper,
                    .paragraphStyle: style,
                ])
                if room > 40 {
                    let width = min(room, detail.size().width)
                    detail.draw(with: NSRect(x: row.maxX - 12 - width, y: y + 11,
                                             width: width, height: 14),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }
            y += Self.rowHeight
        }

        if visible.isEmpty {
            NSAttributedString(string: S.commandPaletteNoMatches, attributes: [
                .font: Theme.uiFont(12),
                .foregroundColor: palette.whisper,
            ]).draw(at: NSPoint(x: card.minX + 18, y: card.minY + Self.fieldHeight + 8))
        }

        recordFirstFrame()
    }

    /// The measurement, taken in the only place that can honestly take it.
    ///
    /// `toFirstDrawMs` closes at the end of the first paint. `toPresentedMs`
    /// closes when the transaction this paint belongs to has been rendered —
    /// the completion block is registered from INSIDE the draw, so it hangs
    /// on AppKit's own display transaction rather than on one of ours, which
    /// would fire before the frame existed.
    private func recordFirstFrame() {
        guard !measuredThisOpening, keystrokeAt > 0 else { return }
        measuredThisOpening = true
        let drawn = (CACurrentMediaTime() - keystrokeAt) * 1000
        let index = openings.count
        let ready = readyMs
        openings.append(PaletteOpening(toReadyMs: ready, toFirstDrawMs: drawn,
                                       toPresentedMs: nil))
        let start = keystrokeAt
        CATransaction.setCompletionBlock { [weak self] in
            let presented = (CACurrentMediaTime() - start) * 1000
            MainActor.assumeIsolated {
                guard let self, self.openings.indices.contains(index) else { return }
                self.openings[index] = PaletteOpening(toReadyMs: ready,
                                                      toFirstDrawMs: drawn,
                                                      toPresentedMs: presented)
            }
        }
    }

    /// What the bench reads.
    var testState: [String: Any] {
        [
            "open": !isHidden,
            "rows": visible.count,
            "families": Array(NSOrderedSet(array: visible.map(\.family))) as? [String] ?? [],
            "selected": visible.indices.contains(selection) ? visible[selection].identifier : "",
            "query": field.stringValue,
            "hasKeyboard": window?.firstResponder === field.currentEditor()
                || window?.firstResponder === field,
            "openings": openings.map {
                ["ready": $0.toReadyMs, "draw": $0.toFirstDrawMs,
                 "presented": $0.toPresentedMs ?? -1]
            },
        ]
    }
}
