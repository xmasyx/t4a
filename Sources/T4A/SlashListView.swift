//  SlashListView.swift — the `/` commands the attached agent has, listed
//  above the bubble (ISC-187, second half).
//
//  Drawn by hand, and that is a rule and not a preference: MacAppRules §7 says
//  no system control goes in the page, and an `NSMenu`, an `NSPopover` or an
//  `NSTableView` would each bring somebody else's colours, corners and
//  scrollers into a window that paints every pixel of itself. The list is
//  therefore the same shape as the command palette next door — a panel, a
//  hairline edge, a veil under the chosen row — because §2's corollary is to
//  copy the form the app already uses rather than invent a second one.
//
//  It NEVER writes a byte to the pty. Everything on screen here comes from
//  `SlashCommandCatalog`, which reads files; nothing is asked of the agent.

import AgentAdapters
import AppKit

@MainActor
final class SlashListView: NSView, ThemeAware {
    /// Eight rows, from the brief. Past that the list stops being something
    /// you read at a glance and becomes a document, and the scroll below
    /// carries the rest.
    static let maxRows = 8
    /// Not private: the window has to work out how many rows fit between the
    /// bubble and the top of the frame before it asks for a height.
    static let rowHeight: CGFloat = 30
    private static let padding: CGFloat = 6
    /// Where the text of a row starts and where the little source label ends,
    /// both measured from the panel's own edge so they land in the SAME
    /// columns as the bubble underneath.
    ///
    /// The bubble insets its drawn card by 10 and its field by another 6, and
    /// this panel's edges are pinned to that card — so 6 here puts `/compact`
    /// exactly under what you are typing, and the `built-in` label exactly
    /// under the `→ zsh ⏎` caption. It was 16, which looked fine on its own
    /// and was ten points off in the photograph of the whole page
    /// (MacAppRules §2: si giudica sulla pagina intera).
    private static let textInset: CGFloat = 6
    /// The column every description starts in, so the rows read as a table
    /// instead of a ragged edge — the same shape claude's own menu has.
    /// Measured from the names once, not per visible row, or it would shift
    /// under the reader every time the list scrolled.
    private var descriptionColumn: CGFloat = 90
    /// Past this a name keeps its own room and its description is dropped:
    /// a column wide enough for `/code-review:code-review` would leave every
    /// ordinary row with a hole in the middle.
    private static let widestNameColumn: CGFloat = 190

    private(set) var items: [SlashCommand] = []
    private(set) var selection = 0
    /// The first row on screen. Only ever moved to keep the selection visible,
    /// so the list never scrolls under a still finger.
    private(set) var top = 0
    private var rowRects: [(rect: NSRect, index: Int)] = []

    /// A row was chosen with the mouse. Same effect as Tab, by the brief.
    var onChoose: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyTheme() { needsDisplay = true }

    // MARK: - What is in it

    var visibleRows: Int { min(Self.maxRows, items.count) }

    /// How tall the list wants to be. The window may give it less — see
    /// `fit(rows:)`.
    var preferredHeight: CGFloat {
        CGFloat(visibleRows) * Self.rowHeight + 2 * Self.padding
    }

    /// The height for a list allowed only `rows` rows, so the caller can cap
    /// it against the room above the bubble without this view knowing where
    /// it is in the window.
    func height(cappedAt rows: Int) -> CGFloat {
        CGFloat(max(0, min(visibleRows, rows))) * Self.rowHeight + 2 * Self.padding
    }

    var selected: SlashCommand? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    /// New contents. The selection goes back to the first row whenever the
    /// NAMES changed: with the list refiltered on every keystroke, a selection
    /// carried across a different set of commands is an index pointing at
    /// something the reader never chose.
    func show(_ next: [SlashCommand]) {
        if next.map(\.name) != items.map(\.name) {
            selection = 0
            top = 0
        }
        items = next
        let font = Theme.monoFont(12)
        let widest = next.map {
            NSAttributedString(string: "/" + $0.name, attributes: [.font: font]).size().width
        }.max() ?? 0
        descriptionColumn = min(Self.widestNameColumn, max(90, widest + 14))
        clampScroll()
        needsDisplay = true
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
        clampScroll()
        needsDisplay = true
    }

    private func clampScroll() {
        let rows = visibleRows
        guard rows > 0 else { top = 0; return }
        top = min(top, max(0, items.count - rows))
        if selection < top { top = selection }
        if selection >= top + rows { top = selection - rows + 1 }
        top = max(0, top)
    }

    // MARK: - The mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The whole row, not the text in it (MacAppRules §3).
        for row in rowRects where row.rect.contains(point) {
            selection = row.index
            needsDisplay = true
            onChoose?(row.index)
            return
        }
    }

    // MARK: - Paint

    /// What the little label on the right of a row says. `builtin` is the
    /// enum's spelling, not a word; the reader gets the word.
    static func label(for source: SlashCommandSource) -> String {
        source == .builtin ? "built-in" : source.rawValue
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        let card = bounds
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Theme.Metric.panelRadius,
                                yRadius: Theme.Metric.panelRadius)
        palette.panel.setFill()
        path.fill()
        palette.panelEdge.setStroke()
        path.lineWidth = 1
        path.stroke()

        rowRects.removeAll(keepingCapacity: true)
        let rows = Int((card.height - 2 * Self.padding) / Self.rowHeight)
        guard rows > 0 else { return }
        let scrolls = items.count > rows
        // The thumb takes a sliver of the right edge, and only when there is
        // something off screen: a scroller that is always there over a list of
        // three is furniture.
        let rightEdge = card.maxX - (scrolls ? 14 : Self.textInset)
        let column = card.minX + Self.textInset + descriptionColumn

        var y = card.minY + Self.padding
        for index in top ..< min(items.count, top + rows) {
            let item = items[index]
            let row = NSRect(x: card.minX + 5, y: y, width: card.width - 10,
                             height: Self.rowHeight)
            rowRects.append((row, index))
            if index == selection {
                palette.accentDim.setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: 1),
                             xRadius: Theme.Metric.cardRadius,
                             yRadius: Theme.Metric.cardRadius).fill()
            }
            let name = NSAttributedString(string: "/" + item.name, attributes: [
                .font: Theme.monoFont(12),
                .foregroundColor: index == selection ? palette.ink : palette.muted,
            ])
            name.draw(at: NSPoint(x: card.minX + Self.textInset, y: y + 8))

            // The source label first, because it is the one thing that must
            // not be squeezed: it is what says a command is yours and not the
            // agent's. The description then gets what is left.
            let tag = NSAttributedString(string: Self.label(for: item.source), attributes: [
                .font: Theme.labelFont(9),
                .foregroundColor: palette.whisper,
            ])
            let tagWidth = tag.size().width
            tag.draw(at: NSPoint(x: rightEdge - tagWidth, y: y + 10))

            if !item.description.isEmpty {
                // Colonna fissa, tranne quando il nome è più lungo della
                // colonna: allora la descrizione lo segue invece di finirci
                // sopra.
                let left = max(column, card.minX + Self.textInset + name.size().width + 14)
                let room = rightEdge - tagWidth - 12 - left
                if room > 40 {
                    let style = NSMutableParagraphStyle()
                    style.lineBreakMode = .byTruncatingTail
                    NSAttributedString(string: item.description, attributes: [
                        .font: Theme.labelFont(10),
                        .foregroundColor: palette.whisper,
                        .paragraphStyle: style,
                    ]).draw(with: NSRect(x: left, y: y + 9, width: room, height: 14),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }
            y += Self.rowHeight
        }

        guard scrolls else { return }
        let track = NSRect(x: card.maxX - 8, y: card.minY + Self.padding, width: 3,
                           height: CGFloat(rows) * Self.rowHeight)
        let share = CGFloat(rows) / CGFloat(items.count)
        let thumb = NSRect(x: track.minX,
                           y: track.minY + track.height * CGFloat(top) / CGFloat(items.count),
                           width: track.width, height: max(24, track.height * share))
        // Binario in `hairlineSoft` e cursore in `whisper`: fra i due deve
        // esserci un salto che si vede, altrimenti sullo scuro il binario
        // pieno si legge come un cursore lungo tutto l'elenco — che è
        // esattamente il contrario di quello che dice (foto del 27/08).
        palette.hairlineSoft.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        palette.whisper.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// What the dump shows. The filter and the state come from the controller,
    /// which owns the catalog; this is only what is on screen.
    var testState: [String: Any] {
        [
            "shown": !isHidden,
            // Il rettangolo vero, non solo la bandiera: `shown` dice che la
            // vista non è nascosta, e una vista alta zero o fuori dalla
            // finestra non è nascosta — è invisibile, che è un'altra cosa e
            // dal dump si vedeva uguale (mio errore, 27/08).
            "frame": ["x": Double(frame.minX), "y": Double(frame.minY),
                      "w": Double(frame.width), "h": Double(frame.height)],
            "windowFrame": (superview?.convert(frame, to: nil)).map {
                ["x": Double($0.minX), "y": Double($0.minY),
                 "w": Double($0.width), "h": Double($0.height)]
            } ?? [:],
            "selected": selection,
            "top": top,
            "visibleRows": visibleRows,
            "items": items.map {
                ["name": $0.name, "description": $0.description,
                 "source": Self.label(for: $0.source)]
            },
        ]
    }
}
