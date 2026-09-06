//  DashRows.swift — the nine lines of the bar, as a thing you can drag.
//
//  This is where the order of the dashboard is chosen (ISC-104.2). Both
//  groups are on screen at once, side by side: stacked, the far lines sit
//  below the fold and a single drag can never reach them. The three whole
//  lines (ISC-142) sit under them, full width, in the shape they have on the
//  bar — and they are destinations like any other, so a provider row drags
//  onto a half line and a built-in row drags onto a whole one.
//
//  The drag is a real mouse gesture on a real handle. A handle nothing can
//  address is a handle no keyboard, no screen reader and no bench can reach,
//  so the grip is its own view with its own name — and the geometry it
//  occupies is reported in screen coordinates, which is what lets a drag be
//  PERFORMED from outside rather than simulated inside.
//
//  Nothing is rebuilt while the mouse is down. Moving the views mid-gesture
//  destroys the very view that is receiving the events; the pane draws where
//  the row would land instead, and commits once, on release.

import AppKit

@MainActor
final class DashRowsPane: NSView {
    private(set) var layout: DashLayout
    private let onChange: (DashLayout) -> Void

    /// A switch changed: the same commit path a drag takes.
    func apply(_ next: DashLayout) {
        layout = next
        onChange(next)
    }
    private var lines: [DashSlot: DashLineView] = [:]
    private(set) var switches: [String: M6Switch] = [:]

    private var draggingKey: String?
    private var landing: (slot: DashSlot, before: String?)?
    /// Which row the pointer is over — ONE name, held here and not a flag on
    /// each row (ISC-144). A row that decides for itself whether it is hovered
    /// can only be wrong: it learns it is no longer hovered from an exit
    /// event, and an exit event is exactly what a rebuild, a window losing
    /// focus, or a drag never delivers. Five rows were lit at once in the live
    /// window, which reads as two different row styles rather than as one
    /// stuck highlight. With one name there is nothing to fall out of step
    /// with — at most one row can be lit, by construction.
    var hoveredKey: String? {
        didSet {
            guard hoveredKey != oldValue else { return }
            for line in lines.values { for row in line.rows { row.needsDisplay = true } }
        }
    }
    /// What the last gesture actually did, so a drag that lands nowhere says
    /// WHERE it went instead of failing silently.
    private(set) var trace: [String: Any] = [:]

    init(layout: DashLayout, onChange: @escaping (DashLayout) -> Void) {
        self.layout = layout
        self.onChange = onChange
        super.init(frame: .zero)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    private var resignToken: NSObjectProtocol?

    /// A window that stops being key stops delivering exit events, so a row
    /// the pointer was over when the user clicked away would stay lit until
    /// something else redrew it. The claim is at most one lit row, and this is
    /// the other way it can be broken.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignToken { NotificationCenter.default.removeObserver(resignToken) }
        resignToken = nil
        guard let window else { return }
        resignToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hoveredKey = nil }
        }
    }

    private func rebuild() {
        // Before the views go: a rebuild is the commonest way a highlight was
        // left behind, because the view that would have received the exit
        // event no longer exists to receive it.
        hoveredKey = nil
        subviews.forEach { $0.removeFromSuperview() }
        lines.removeAll()
        switches.removeAll()

        func column(_ slots: [DashSlot]) -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            for slot in slots {
                // ISC-192 — una nativa la cui gemella è arrivata dal fornitore
                // non ha una riga qui. La chiave resta nel layout, e quindi al
                // suo posto nel file: sparisce dall'elenco, non dalla barra di
                // chi un domani toglie il fornitore. La tabella delle coppie
                // sta in `DashCatalog`, che è anche la sola che la barra legge.
                let keys = layout.keys(in: slot).filter { !DashCatalog.isSuperseded($0) }
                let line = DashLineView(slot: slot, keys: keys,
                                        off: layout.off, pane: self)
                lines[slot] = line
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                for (name, control) in line.switches { switches[name] = control }
            }
            return stack
        }

        let left = column([.left1, .left2, .left3])
        let right = column([.right1, .right2, .right3])
        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fillEqually
        columns.spacing = 18

        // The whole lines go UNDER the two columns, one above the other and
        // the full width of the panel — which is where they are on the bar
        // (ISC-142). Putting them in a third column would draw the settings
        // as three groups when the bar has two groups and three wide lines.
        let wide = column(DashSlot.fulls)
        let sheet = NSStackView(views: [columns, wide])
        sheet.orientation = .vertical
        sheet.alignment = .leading
        sheet.spacing = 12
        sheet.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sheet)
        // The sheet sits at the TOP and takes the height it needs. It used to
        // be pinned top and bottom, and when the panel was taller than the
        // rows — which it is, at any ordinary window size — the slack was
        // handed to the stacks to share out: `left · line 3` came out 64 pt
        // tall against `right · line 3`'s 34, and a gap of seventy-odd points
        // opened above the whole lines. Nothing about the bar's arrangement
        // asked for either; they were leftover space with nowhere else to go.
        let floor = sheet.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        floor.priority = .init(1)
        NSLayoutConstraint.activate([
            sheet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sheet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sheet.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            sheet.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            floor,
            columns.widthAnchor.constraint(equalTo: sheet.widthAnchor),
            // The same width as a half column, and not the sheet's (ISC-144).
            // A whole line is full width on the BAR; in here it is a list of
            // names with a switch at the end of each, and stretching that list
            // across the panel put every switch five hundred points from the
            // name it belongs to while the six half lines kept theirs at the
            // end of the column. Same width, same row.
            wide.widthAnchor.constraint(equalTo: left.widthAnchor),
        ])
    }

    // MARK: - The gesture

    func beginDrag(key: String) {
        trace = ["began": key]
        draggingKey = key
        landing = nil
        lines.values.forEach { $0.draggingKey = key }
    }

    func updateDrag(windowPoint: NSPoint) {
        guard draggingKey != nil else { return }
        let local = convert(windowPoint, from: nil)
        landing = target(at: local)
        trace["moves"] = (trace["moves"] as? Int ?? 0) + 1
        trace["point"] = ["x": Double(local.x), "y": Double(local.y)]
        trace["landing"] = landing.map { "\($0.slot.rawValue)/\($0.before ?? "end")" } ?? "none"
        trace["boxes"] = lines.map { slot, line in
            let box = line.convert(line.rowsBounds, to: self)
            return "\(slot.rawValue) \(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))x\(Int(box.height))"
        }.sorted()
        for (slot, line) in lines {
            line.isLanding = landing?.slot == slot
            line.dropBefore = landing?.slot == slot ? landing?.before : nil
        }
    }

    func endDrag() {
        defer {
            draggingKey = nil
            landing = nil
            lines.values.forEach {
                $0.isLanding = false
                $0.dropBefore = nil
                $0.draggingKey = nil
            }
        }
        trace["ended"] = landing.map { "\($0.slot.rawValue)/\($0.before ?? "end")" } ?? "none"
        guard let key = draggingKey, let landing else { return }
        trace["committed"] = true
        var next = layout
        next.move(key, to: landing.slot, before: landing.before)
        layout = next
        rebuild()
        onChange(next)
    }

    /// Which line the point is over, and which row it would land before. An
    /// empty line is a target like any other — that is the whole reason it
    /// keeps a body when it holds nothing.
    private func target(at point: NSPoint) -> (DashSlot, String?)? {
        for (slot, line) in lines {
            let box = line.convert(line.rowsBounds, to: self)
            guard box.insetBy(dx: -6, dy: -6).contains(point) else { continue }
            let inLine = line.convert(point, from: self)
            for row in line.rows where row.key != draggingKey {
                let frame = row.convert(row.bounds, to: line)
                if inLine.y < frame.midY { return (slot, row.key) }
            }
            return (slot, nil)
        }
        return nil
    }

    /// Where every handle and every line sit ON SCREEN, so a drag can be
    /// performed from outside the app with real events.
    func geometry() -> [String: Any] {
        func screen(_ view: NSView) -> [String: Double] {
            let inWindow = view.convert(view.bounds, to: nil)
            let onScreen = view.window?.convertToScreen(inWindow) ?? inWindow
            return ["x": Double(onScreen.midX), "y": Double(onScreen.midY),
                    "w": Double(onScreen.width), "h": Double(onScreen.height)]
        }
        var rows: [[String: Any]] = []
        var boxes: [[String: Any]] = []
        for slot in DashSlot.allCases {
            guard let line = lines[slot] else { continue }
            boxes.append(["slot": slot.rawValue, "empty": line.rows.isEmpty,
                          "rect": screen(line.rowsHost)])
            for row in line.rows {
                rows.append(["key": row.key, "slot": slot.rawValue,
                             "handle": screen(row.handle), "switch": screen(row.control)])
            }
        }
        // The row that is lit, by name. A claim that says "at most one" is a
        // claim about this string, and reading it off the pane is the only way
        // a bench can tell one lit row from five.
        return ["rows": rows, "lines": boxes, "hovered": hoveredKey ?? ""]
    }
}

/// One line of the bar as a list you can drop into.
@MainActor
final class DashLineView: NSView {
    let slot: DashSlot
    private(set) var rows: [DashRowView] = []
    private(set) var switches: [String: M6Switch] = [:]
    let rowsHost = NSView()
    var isLanding = false { didSet { needsDisplay = true } }
    var dropBefore: String? { didSet { needsDisplay = true } }
    var draggingKey: String?

    init(slot: DashSlot, keys: [String], off: Set<String>, pane: DashRowsPane) {
        self.slot = slot
        super.init(frame: .zero)

        let title = NSTextField(labelWithString: slot.title.uppercased())
        title.font = Theme.labelFont(10)
        title.textColor = Theme.current.whisper
        title.translatesAutoresizingMaskIntoConstraints = false
        rowsHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        addSubview(rowsHost)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsHost.addSubview(stack)

        if keys.isEmpty {
            // An empty line still has a body: without one it has nothing to
            // hover and can never be a destination, which is exactly how it
            // came to refuse every drop.
            let hint = NSTextField(labelWithString: S.emptyDashboardLine)
            hint.font = NSFontManager.shared.convert(Theme.uiFont(11), toHaveTrait: .italicFontMask)
            hint.textColor = Theme.current.whisper
            stack.addArrangedSubview(hint)
            hint.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        for key in keys {
            let row = DashRowView(key: key, isOn: !off.contains(key), pane: pane)
            rows.append(row)
            switches[row.control.label] = row.control
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: topAnchor),
            rowsHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowsHost.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            rowsHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            // EXACTLY what its rows need, and 34 when it has none — not "at
            // least", which is an invitation to whatever stack is looking for
            // somewhere to put its leftover height. One row is 30 points on a
            // half line and on a whole line alike, which is the whole of
            // ISC-144's "same height" said as a number.
            rowsHost.heightAnchor.constraint(
                equalToConstant: CGFloat(max(1, keys.count)) * DashRowView.height),
            stack.leadingAnchor.constraint(equalTo: rowsHost.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rowsHost.trailingAnchor),
            stack.topAnchor.constraint(equalTo: rowsHost.topAnchor),
            stack.bottomAnchor.constraint(equalTo: rowsHost.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    var rowsBounds: NSRect { rowsHost.frame }

    override func draw(_ dirtyRect: NSRect) {
        guard isLanding else { return }
        let palette = Theme.current
        let box = rowsHost.frame
        palette.accentDim.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        palette.accentText.setStroke()
        let edge = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 6, yRadius: 6)
        edge.lineWidth = 1
        edge.stroke()
        // The line the row would land on, drawn where it would land.
        palette.accentText.setFill()
        let y: CGFloat
        if let before = dropBefore, let row = rows.first(where: { $0.key == before }) {
            y = convert(row.bounds, from: row).minY
        } else {
            y = box.maxY - 1
        }
        NSRect(x: box.minX + 4, y: y, width: box.width - 8, height: 1).fill()
    }
}

/// One row: the handle, the name, the switch.
@MainActor
final class DashRowView: NSView {
    /// One number for how tall a row is, read by the row and by the line that
    /// makes room for it — so the two cannot disagree.
    static let height: CGFloat = 30
    let key: String
    let handle: DragHandleView
    let control: M6Switch
    private weak var pane: DashRowsPane?
    private var trackingArea: NSTrackingArea?

    init(key: String, isOn: Bool, pane: DashRowsPane) {
        self.key = key
        self.pane = pane
        handle = DragHandleView(label: "Move \(DashCatalog.name(of: key))")
        control = M6Switch(label: DashCatalog.name(of: key), isOn: isOn)
        super.init(frame: .zero)

        handle.onBegin = { [weak pane] in pane?.beginDrag(key: key) }
        handle.onMove = { [weak pane] point in pane?.updateDrag(windowPoint: point) }
        handle.onEnd = { [weak pane] in pane?.endDrag() }
        control.onChange = { [weak pane] on in
            guard let pane else { return }
            var next = pane.layout
            if on { next.off.remove(key) } else { next.off.insert(key) }
            pane.apply(next)
        }

        // ONE human name per row, and this is it (ISC-104.6).
        let name = NSTextField(labelWithString: DashCatalog.name(of: key))
        name.font = Theme.uiFont(12.5)
        name.textColor = Theme.current.muted
        for view in [handle, name, control] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            handle.centerYAnchor.constraint(equalTo: centerYAnchor),
            handle.widthAnchor.constraint(equalToConstant: 16),
            handle.heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: handle.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.widthAnchor.constraint(equalToConstant: M6Switch.size.width),
            control.heightAnchor.constraint(equalToConstant: M6Switch.size.height),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.inVisibleRect`: the rectangle follows the row when the panel is
        // scrolled or relaid, instead of staying where the row used to be.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                            .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { pane?.hoveredKey = key }
    override func mouseExited(with event: NSEvent) {
        // Only ever give up a claim that is still mine: two rows exchanging
        // enter and exit out of order must not leave the pane with nothing
        // lit while the pointer is over a row.
        if pane?.hoveredKey == key { pane?.hoveredKey = nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard pane?.hoveredKey == key else { return }
        Theme.current.pane.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// The grip. Its own view with its own accessibility name, because a control
/// that nothing can address is a control nothing can test.
@MainActor
final class DragHandleView: NSView {
    var onBegin: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?
    private var dragging = false

    init(label: String) {
        super.init(frame: .zero)
        setAccessibilityLabel(label)
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        onBegin?()
        onMove?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onMove?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.current.whisper.setFill()
        let width: CGFloat = 10
        let x = (bounds.width - width) / 2
        for index in 0..<3 {
            NSRect(x: x, y: bounds.midY - 4 + CGFloat(index) * 3, width: width, height: 1).fill()
        }
    }
}
