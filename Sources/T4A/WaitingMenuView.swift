//  WaitingMenuView.swift — the anchored chooser behind «N waiting» (ISC-237).

import AppKit

/// A small in-window menu, drawn with the same panel and row vocabulary as
/// the command palette and slash list. It never becomes first responder: the
/// composer keeps the keyboard while the menu is open, and a dismissal puts
/// back the responder captured at opening as an explicit guard against the
/// ISC-231 class of regressions.
@MainActor
final class WaitingMenuView: NSView, ThemeAware {
    struct Item: Equatable {
        let id: UUID
        let title: String
        let age: String
    }

    private static let rowHeight: CGFloat = 32
    private static let padding: CGFloat = 6
    private static let panelWidth: CGFloat = 330

    private(set) var items: [Item] = []
    private var anchor = NSPoint.zero
    private var previousResponder: NSResponder?
    private var rowRects: [(NSRect, Int)] = []
    private(set) var panelRect = NSRect.zero

    var onChoose: ((UUID) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyTheme() { needsDisplay = true }

    func open(items: [Item], below anchor: NSPoint, restoring responder: NSResponder?) {
        guard items.count > 1 else { return }
        self.items = items
        self.anchor = anchor
        previousResponder = responder
        isHidden = false
        needsDisplay = true
    }

    /// Refreshes ages/titles while preserving the responder captured when the
    /// menu opened. A count below two no longer needs a chooser.
    func update(items: [Item], below anchor: NSPoint) {
        guard !isHidden else { return }
        guard items.count > 1 else { dismiss(); return }
        self.items = items
        self.anchor = anchor
        needsDisplay = true
    }

    func dismiss(restoring: Bool = true) {
        guard !isHidden else { return }
        isHidden = true
        items = []
        rowRects = []
        if restoring, let previousResponder, let window {
            window.makeFirstResponder(previousResponder)
        }
        previousResponder = nil
    }

    override func mouseDown(with event: NSEvent) {
        press(at: convert(event.locationInWindow, from: nil))
    }

    private func press(at point: NSPoint) {
        guard let hit = rowRects.first(where: { $0.0.contains(point) }),
              items.indices.contains(hit.1) else {
            // A native menu consumes the outside click that closes it. This
            // full-window overlay does the same without taking the keyboard.
            dismiss()
            return
        }
        let id = items[hit.1].id
        dismiss(restoring: false)
        onChoose?(id)
    }

    override func draw(_ dirtyRect: NSRect) {
        rowRects.removeAll(keepingCapacity: true)
        guard !items.isEmpty else { return }
        let height = CGFloat(items.count) * Self.rowHeight + 2 * Self.padding
        let width = min(Self.panelWidth, bounds.width - 16)
        let x = min(max(8, anchor.x), max(8, bounds.width - width - 8))
        // Both the band and this overlay are flipped. `anchor` is the point
        // just below the count, so increasing y really is below it.
        panelRect = NSRect(x: x, y: anchor.y + 5, width: width, height: height)

        let palette = Theme.current
        let panel = NSBezierPath(roundedRect: panelRect.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: Theme.Metric.panelRadius,
                                 yRadius: Theme.Metric.panelRadius)
        palette.panel.setFill()
        panel.fill()
        palette.panelEdge.setStroke()
        panel.lineWidth = 1
        panel.stroke()

        var y = panelRect.minY + Self.padding
        for (index, item) in items.enumerated() {
            let row = NSRect(x: panelRect.minX + 5, y: y,
                             width: panelRect.width - 10, height: Self.rowHeight)
            rowRects.append((row, index))
            let age = NSAttributedString(string: "· " + item.age, attributes: [
                .font: Theme.labelFont(10),
                .foregroundColor: palette.whisper,
            ])
            let ageWidth = age.size().width
            age.draw(at: NSPoint(x: row.maxX - ageWidth - 7, y: row.minY + 10))
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: item.title, attributes: [
                .font: Theme.uiFont(12, weight: .medium),
                .foregroundColor: palette.ink,
                .paragraphStyle: style,
            ]).draw(with: NSRect(x: row.minX + 7, y: row.minY + 8,
                                 width: max(40, row.width - ageWidth - 28), height: 17),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += Self.rowHeight
        }
    }

    var testState: [String: Any] {
        [
            "shown": !isHidden,
            "rows": items.enumerated().map { index, item in
                ["index": index, "id": item.id.uuidString,
                 "title": item.title, "age": item.age,
                 "text": "\(item.title) · \(item.age)"]
            },
            "panel": ["x": Double(panelRect.minX), "y": Double(panelRect.minY),
                      "w": Double(panelRect.width), "h": Double(panelRect.height)],
            "firstResponder": window?.firstResponder
                .map { String(describing: type(of: $0)) } ?? "none",
        ]
    }

    func testChoose(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let id = items[index].id
        dismiss(restoring: false)
        onChoose?(id)
    }
}
