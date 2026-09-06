//  DashView.swift — the strip along the bottom.
//
//  It is a statusline, not a panel: full width, height taken from the bottom,
//  never a column stolen from the terminal (ISC-51). Cells are laid in two
//  groups anchored to the outer edges, on rows of a fixed height so the left
//  and right halves sit on the same baselines (ISC-82).
//
//  Which cell sits where is not decided here: `DashLayout` holds the nine
//  lines and this view draws them (ISC-104.1). What IS decided here is how
//  many rows the strip needs — measured from what actually fits, never
//  guessed — and a line with nothing on it draws nothing and reserves no
//  height, because the third line exists to be chosen, not to hold space.
//
//  Under the six half lines sit three WHOLE ones (ISC-142). They are the same
//  cells drawn by the same code, with one difference that is the entire point:
//  the room they are measured against is the window, not half of it. A reading
//  a person is meant to READ — `MEMORY OK · REVIEWED 2M AGO · NEXT IN 8 TURNS`
//  — does not survive being squeezed into half a window, and the bar that did
//  it printed «MEMORY OK · RE…» beside «LIFEOS 7.40…» and «EFFORT LOW MEDI…».
//  So a whole line never compresses a cell while it still has room, and when
//  it runs out only its LAST cell gives up characters.
//
//  Every value here is something a terminal actually knows.

import AppKit
import TerminalCore

struct DashCell {
    let key: String
    /// A `var` since ISC-152: the transient warning lane puts its mark in
    /// front of the caption, and a cell that is only ever built once cannot
    /// be told apart from the calm one beside it.
    var label: String
    var value: String
    /// warn/critical raise the colour of the whole cell. Read from the VALUE,
    /// never from a switch of its own (ISC-90/103).
    var alarm: Alarm = .none
    /// Drawn in the accent while it lasts: the one row that is happening
    /// rather than being reported (ISC-104.3).
    var live = false
    /// The value word by word, when the words are not all the same colour
    /// (ISC-139). Empty for everything a terminal says about itself, which is
    /// why the built-in rows draw through exactly the code they always did.
    /// When it is not empty, `value` is these tokens joined by a space: the
    /// bar measures and truncates the string, and paints the tokens.
    var tokens: [FactToken] = []
    /// A row whose provider has stopped answering (ISC-139). The reading is
    /// the last one that arrived, and it is drawn dim so that a number nobody
    /// is refreshing does not look like a number somebody is.
    var stale = false
    /// A cell that may not be shortened and may not be dropped (ISC-145,
    /// ISC-146). It is the exact inverse of the rule ISC-142 wrote for a
    /// crowded line, and the inversion is the point: a warning is on the bar
    /// BECAUSE something is wrong, so trading its letters for a calm cell's
    /// letters is trading the message for the wallpaper. Calm cells give way
    /// first, and if there is still no room the warning stays whole.
    var pinned = false
    /// A row that is switched on and has no reading right now, standing in for
    /// itself with a dash (ISC-149). It is the first thing a crowded line gives
    /// up: it is the only cell on the bar that carries no information, so
    /// spending width on it while a real reading is being cut would be the
    /// squeeze rule pointed the wrong way round.
    var placeholder = false

    enum Alarm { case none, warn, critical }

    /// The same cell with its value cut to `characters`, ellipsis included.
    /// Tones survive the cut, because in a coloured reading the colour IS the
    /// reading (ISC-139).
    func clipped(to characters: Int) -> DashCell {
        guard value.count > characters, characters >= 1 else { return self }
        var copy = self
        if tokens.isEmpty {
            copy.value = String(value.prefix(max(1, characters - 1))) + "…"
        } else {
            copy.tokens = FactsFeed.clip(tokens, to: characters)
            copy.value = copy.tokens.map(\.text).joined(separator: " ")
        }
        return copy
    }

    static func alarm(for value: String) -> Alarm {
        let lowered = value.lowercased()
        for word in ["critical", "error", "failed", "down", "exceeded", "full"]
        where lowered.contains(word) { return .critical }
        for word in ["warn", "degraded", "stale", "blocked", "backlog"]
        where lowered.contains(word) { return .warn }
        if let percent = lowered.firstMatchPercent() {
            if percent >= 100 { return .critical }
            if percent >= 90 { return .warn }
        }
        return .none
    }
}

/// Tone to colour, in ONE place (the rule ISC-103 set for the reds, kept for
/// the six other words a provider may use).
///
/// `ok` is the calm colour and not a green: no theme here has one, and
/// inventing a colour that only appears for provider rows would make the bar
/// look like two bars. `live` and `accent` are the same blue on purpose —
/// every mark drawn as TEXT uses `accentText`, because `accent` is a fill and
/// does not clear contrast as type (see the palette).
///
/// `used` is a GREY since ISC-153, and it used to be `ink`. The three tones a
/// ladder sends — `live`, `used`, `dim` — are a rung that is running, one that
/// ran earlier, and one that never ran; `ink` is the brightest text this bar
/// draws, so the middle state came out louder than the live one and a rung
/// nobody had switched on read as switched on. The statusline this bar stands
/// beside keeps one hue per rung and varies its brightness, which T4A cannot
/// copy with one accent — so the accent is spent on the only state that means
/// ON, and the other two are the two greys, in the order a person reads them.
extension Theme.Palette {
    func colour(for tone: FactTone) -> NSColor {
        switch tone {
        case .critical: return failed
        case .warn: return failedSoft
        case .ok, .muted, .used: return muted
        case .live, .accent: return accentText
        case .dim: return whisper
        }
    }
}

private extension String {
    func firstMatchPercent() -> Int? {
        guard let range = range(of: #"\d+(?=%)"#, options: .regularExpression) else { return nil }
        return Int(self[range])
    }
}

@MainActor
final class DashView: NSView, NSViewToolTipOwner {
    /// What a warning wears in front of its caption (ISC-152).
    ///
    /// One character, because the lane it lives in is at the end of a line
    /// that is already full and the rule of ISC-146 is that the warning may
    /// not be shortened — so anything it wears is width taken from a reading
    /// that could otherwise be there. A word would be a second caption; a
    /// pictogram is a picture, and this bar prints words (ISC-139).
    static let alarmMark = "!"

    static let rowHeight: CGFloat = 21
    /// The strip's own left/right padding and the gap between two cells,
    /// measured on the ratified demo in a real browser: `.dash-items` pads
    /// 14px, `.dash-group` puts 20px between columns (ISC-104.7).
    static let sideInset: CGFloat = 14
    static let cellGap: CGFloat = 20

    /// Every reading the app has right now, by key. What is DRAWN is the
    /// intersection of this and the layout: a key with no reading (no agent
    /// attached, say) is absent rather than invented.
    var values: [String: DashCell] = [:] { didSet { invalidateLayout() } }
    var slotLayout = DashLayout() { didSet { invalidateLayout() } }
    /// The cells the bar shows WHATEVER the layout says (ISC-145, ISC-146):
    /// a provider that will not start, and a reading that is complaining while
    /// its row is switched off or has no line. They ride the end of `left-2`,
    /// which is one predictable place a person can learn to look — a warning
    /// that appears wherever its row happens to sit is a warning you have to
    /// hunt for. They are transient exactly like the worker cell (ISC-104.3):
    /// never in `dash-slots`, never draggable, and gone by themselves the
    /// moment the thing they are about is calm again.
    var alarms: [DashCell] = [] { didSet { invalidateLayout() } }
    /// Rows discovered by measuring, never a number written by hand. The two
    /// counts are separate because they answer different questions: how tall
    /// the two groups had to grow, and how many whole lines have anything on
    /// them at all.
    private(set) var rowCount = 2
    private(set) var fullRowCount = 0

    override var isFlipped: Bool { true }

    var preferredHeight: CGFloat {
        let rows = rowCount + fullRowCount
        // Niente da dire, niente barra: zero punti, non una striscia vuota
        // alta una riga (ISC-173). È lo stesso comportamento che una linea
        // intera senza righe accese ha già da ISC-104.1 — una linea che non
        // ha niente sopra non è una riga vuota, non esiste — portato dalla
        // singola linea alla barra intera. Il `+ 12` è il respiro sopra e
        // sotto le righe: senza righe non c'è niente attorno a cui respirare.
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * Self.rowHeight + 12
    }
    var onHeightChange: (() -> Void)?

    private func invalidateLayout() {
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - What each half is asked to draw

    /// A row is shown when it is switched on, OR when it is switched off and
    /// its value is complaining: an alarm punches back through the off list
    /// (ISC-104.3). A bar that can hide trouble is worse than no bar.
    private func shown(_ slot: DashSlot) -> [DashCell] {
        slotLayout.keys(in: slot).compactMap { key in
            guard let cell = values[key] else { return nil }
            guard slotLayout.off.contains(key) else { return cell }
            // A row that is switched off and complaining comes back — that is
            // ISC-104.3 and it stands for everything a terminal knows about
            // itself. A PROVIDER's row comes back somewhere else (ISC-146):
            // in the lane at the end of `left-2`, which is one place a person
            // can learn to look, instead of wherever that row happens to have
            // been dragged. Here it stays hidden, so it cannot be drawn twice.
            if DashCatalog.isFact(key) { return nil }
            return cell.alarm == .none ? nil : cell
        }
    }

    /// The non-empty lines of one half, in order. The transient work cell
    /// rides the END of the left group's last populated line: on the right the
    /// group hugs the window edge, so anything appearing there shoves
    /// everything sideways; on the left it just grows.
    func lines(left: Bool) -> [[DashCell]] {
        var built: [(slot: DashSlot, cells: [DashCell])] = []
        for slot in DashSlot.halves where slot.isLeft == left {
            built.append((slot, shown(slot)))
        }
        if left {
            if let worker = values["worker"] {
                let last = built.lastIndex { !$0.cells.isEmpty } ?? 0
                built[last].cells.append(worker)
            }
            // After the worker, because the claim says "to the right of the
            // last cell there is" and the worker is a cell like any other. A
            // warning is the last thing on that line, always, so its place on
            // the bar does not move about with what else is running.
            if !alarms.isEmpty, let index = built.firstIndex(where: { $0.slot == .left2 }) {
                built[index].cells.append(contentsOf: alarms)
            }
        }
        return built.filter { !$0.cells.isEmpty }.map(\.cells)
    }

    /// The whole lines that have something on them, in order. A line with
    /// nothing switched on is not an empty row: it does not exist, which is
    /// what lets the bar be exactly as tall as it was before a provider was
    /// ever configured (ISC-142).
    func fullLines() -> [[DashCell]] {
        DashSlot.fulls.compactMap { slot in
            let cells = shown(slot)
            return cells.isEmpty ? nil : cells
        }
    }

    /// What one group is allowed to be wide. Measured the same way in the
    /// pass that decides how many rows to open and in the pass that draws
    /// them, so a row can never be planned against one width and painted
    /// against another.
    var halfWidth: CGFloat { max(120, bounds.width / 2 - 24) }

    /// What each group may ACTUALLY use on a shared row (ISC-245, 6/09). Half
    /// the bar each was the rule until the Codex row arrived with a model
    /// ladder, an effort ladder and a context cell on the left and one cell
    /// on the right: the left overflowed its half and opened a second row
    /// while half the bar sat empty beside it. His words: «a sinistra context
    /// model effort, senza alcun limite a metà, perché occupiamo tutta la
    /// linea». So a group is allowed the whole line minus what the OTHER
    /// group needs, and never less than its half: two wide groups still split
    /// the bar exactly as before, one wide group next to a narrow one takes
    /// the room the narrow one leaves. The natural width is measured off the
    /// same `plan` the drawing uses, one row per line, widest line counts.
    func groupBudgets() -> (left: CGFloat, right: CGFloat) {
        let half = halfWidth
        let full = fullWidth
        let natural = { (lines: [[DashCell]]) -> CGFloat in
            lines.isEmpty ? 0 : (Self.plan(lines, rows: lines.count).widths.max() ?? 0)
        }
        let leftNatural = natural(lines(left: true))
        let rightNatural = natural(lines(left: false))
        let leftBudget = max(half, full - min(rightNatural, half) - Self.cellGap)
        let rightBudget = max(half, full - min(leftNatural, half) - Self.cellGap)
        return (leftBudget, rightBudget)
    }
    /// And what a whole line is allowed to be wide: everything between the
    /// two insets. This is the number the claim is about.
    var fullWidth: CGFloat { max(120, bounds.width - 2 * Self.sideInset) }

    override func layout() {
        super.layout()
        guard bounds.width > 1 else { return }
        let budgets = groupBudgets()
        let left = lines(left: true)
        let right = lines(left: false)
        // `rowsNeeded` risponde «almeno una» per costruzione, ed è giusto per
        // un GRUPPO vuoto accanto a uno pieno: le due metà sono affiancate e
        // hanno la stessa altezza. Ma quando non c'è niente da nessuna delle
        // due parti quella riga minima è una barra alta trenta punti che non
        // dice niente, ed è esattamente la cosa che ISC-173 toglie.
        let discovered = left.isEmpty && right.isEmpty && fullLines().isEmpty
            ? 0
            : max(Self.rowsNeeded(left, width: budgets.left),
                  Self.rowsNeeded(right, width: budgets.right))
        // A whole line is one row and never two: a line that overflows gives
        // up characters, it does not grow downwards. Opening a second row for
        // it is the move that produced a nine-row bar (ISC-139).
        let fulls = fullLines().count
        guard discovered != rowCount || fulls != fullRowCount else { return }
        rowCount = discovered
        fullRowCount = fulls
        needsDisplay = true
        onHeightChange?()
    }

    /// Three, and never four: a group is three half lines (ISC-104.1), and it
    /// cannot be taller than the lines it holds. Counted off the half lines
    /// and not off every case, or the day the model grew three whole lines
    /// this quietly became four.
    static let maxRows = DashSlot.halves.count / 2

    /// One row per non-empty line to begin with; a line that overflows is
    /// given another row until it fits, up to the three the model allows.
    ///
    /// The cap is not a tidiness rule, it is the difference between two
    /// failure modes. Without it, a single reading too long to fit on any
    /// width — and a facts provider can send one (ISC-139) — makes the bar
    /// open a row per cell looking for room it will never find: measured at
    /// NINE rows and 201 pt, a third of the window eaten to show one row that
    /// still did not fit. Past three rows the answer is not more bar, it is
    /// `squeeze`: the long cell gives up characters and everything else stays
    /// where it is.
    private static func rowsNeeded(_ lines: [[DashCell]], width: CGFloat) -> Int {
        guard !lines.isEmpty else { return 1 }
        let ceiling = min(maxRows, max(lines.count, lines.reduce(0) { $0 + $1.count }))
        var rows = lines.count
        while rows < ceiling, !fits(lines, rows: rows, width: width) { rows += 1 }
        return max(1, min(maxRows, rows))
    }

    private static func fits(_ lines: [[DashCell]], rows: Int, width: CGFloat) -> Bool {
        plan(lines, rows: rows).widths.allSatisfy { $0 <= width }
    }

    /// Where every cell goes, and how wide each drawn row came out. The rows
    /// beyond the number of lines go to whichever line is most crowded —
    /// handing them all to the first one left the second as long as ever, so
    /// the bar kept overflowing however many rows it opened.
    private static func plan(_ lines: [[DashCell]], rows: Int)
        -> (rows: [[DashCell]], widths: [CGFloat]) {
        guard !lines.isEmpty else { return ([], []) }
        var spans = [Int](repeating: 1, count: lines.count)
        var extra = rows - lines.count
        while extra > 0 {
            var worst = 0
            for index in 1..<spans.count where
                ceilDiv(lines[index].count, spans[index]) > ceilDiv(lines[worst].count, spans[worst]) {
                worst = index
            }
            spans[worst] += 1
            extra -= 1
        }
        var drawn: [[DashCell]] = []
        for (index, cells) in lines.enumerated() {
            let span = max(1, spans[index])
            let perRow = max(1, ceilDiv(cells.count, span))
            for start in stride(from: 0, to: max(cells.count, 1), by: perRow) {
                drawn.append(Array(cells[start..<min(start + perRow, cells.count)]))
            }
        }
        let widths = drawn.map { row in row.reduce(CGFloat(0)) { $0 + measure($1) + cellGap } }
        return (drawn, widths)
    }

    private static func ceilDiv(_ a: Int, _ b: Int) -> Int { b <= 0 ? a : (a + b - 1) / b }

    private static func measure(_ cell: DashCell) -> CGFloat {
        let label = NSAttributedString(string: cell.label,
                                       attributes: [.font: Theme.labelFont(10)])
        let value = NSAttributedString(string: cell.value,
                                       attributes: [.font: Theme.labelFont(11)])
        return label.size().width + value.size().width + 6
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        palette.ground.setFill()
        bounds.fill()
        palette.hairlineSoft.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        // Cleared every draw: a rectangle left over from the last frame is a
        // probe that reports a cell which is no longer on the bar.
        inkRects.removeAll(keepingCapacity: true)
        inkText.removeAll(keepingCapacity: true)
        inkTones.removeAll(keepingCapacity: true)
        inkColours.removeAll(keepingCapacity: true)
        hiddenKeys.removeAll(keepingCapacity: true)

        let budgets = groupBudgets()
        drawGroup(lines(left: true), originX: Self.sideInset, alignRight: false, budget: budgets.left)
        drawGroup(lines(left: false), originX: bounds.width - Self.sideInset,
                  alignRight: true, budget: budgets.right)
        drawFullLines(below: rowCount)
        refreshAlarmTips()
    }

    /// A sentence over the warning, because the mark in front of it says THAT
    /// something is a warning and not WHY it is on a bar the row was taken
    /// off (ISC-152). Registered from the rectangles the drawing just used,
    /// so the tip cannot end up over a cell that is no longer there.
    private func refreshAlarmTips() {
        // Solo quando la SERIE cambia davvero, e la firma è chiave più
        // rettangolo. `removeAllToolTips()` libera gli oggetti-tag di AppKit,
        // e il gestore dei tooltip ne tiene un riferimento NON trattenuto
        // mentre il suo timer è armato sotto il puntatore: questa striscia si
        // ridisegna ogni secondo (il contatore del worker), quindi ricostruire
        // a ogni disegno voleva dire liberare, una volta al secondo, l'oggetto
        // su cui il timer stava per parlare. Crash vero del 26/08 09:33:34,
        // `toolTipTimerFired -> displayToolTip: -> -[NSArray
        // descriptionWithLocale:]` e salto a zero, nessun frame nostro nello
        // stack perché la memoria liberata era già stata riusata da un array.
        let firma = alarms.compactMap { cell -> String? in
            guard let rect = inkRects[cell.key] else { return nil }
            return "\(cell.key)|\(Int(rect.minX))|\(Int(rect.minY))"
                + "|\(Int(rect.width))|\(Int(rect.height))"
        }
        guard firma != alarmTipSignature else { return }
        alarmTipSignature = firma
        removeAllToolTips()
        for cell in alarms {
            guard let rect = inkRects[cell.key] else { continue }
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    /// La serie di tooltip registrata adesso, per non rifarla identica.
    private var alarmTipSignature: [String] = []

    /// The text of that tip. One sentence, and it names the two things a
    /// person cannot see: that the row is switched off, and that the cell
    /// will go by itself.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let key = alarms.first { inkRects[$0.key]?.contains(point) == true }?.key
        let name = key.map { DashCatalog.name(of: $0) } ?? "This row"
        return "\(name) is switched off, and this is a warning: a row that is "
            + "complaining comes back on its own and leaves again when it is calm."
    }

    /// Where each drawn cell ended up, by key, in the strip's own coordinates.
    /// A claim about paired rows is a claim about y values, and these are the
    /// ones the drawing used (ISC-104.1).
    private(set) var inkRects: [String: NSRect] = [:]
    /// The value each cell was PAINTED with — after truncation, not before.
    /// A claim about what the bar shows is a claim about this, and the only
    /// honest place to record it is the drawing itself.
    private(set) var inkText: [String: String] = [:]
    /// And the tone each word was painted in — the EFFECTIVE one, after a
    /// stale row has overridden what the provider asked for — beside the
    /// colour that tone resolved to in the theme on screen. Two readings of
    /// the same paint: the meaning, and the ink.
    private(set) var inkTones: [String: [[String]]] = [:]

    private func drawGroup(_ lines: [[DashCell]], originX: CGFloat, alignRight: Bool, budget: CGFloat) {
        let laid = Self.plan(lines, rows: rowCount)
        for (index, planned) in laid.rows.enumerated() where index < rowCount {
            let y = 6 + CGFloat(index) * Self.rowHeight
            let squeezed = Self.squeeze(planned, into: budget)
            var row = squeezed.cells
            if !squeezed.dropped.isEmpty {
                // The marker is a cell of the row, so it is measured, placed
                // and reported like every other one. Its key names the row it
                // belongs to, because both groups can have one.
                row.append(DashCell(key: "more-\(alignRight ? "right" : "left")-\(index)",
                                    label: "", value: "+\(squeezed.dropped.count)"))
                for key in squeezed.dropped { hiddenKeys.append(key) }
            }
            let width = row.reduce(CGFloat(0)) { $0 + Self.measure($1) + Self.cellGap }
            // Every row starts at column one of its own GROUP; the group is
            // what is anchored to the edge, not each row (ISC-98).
            lay(row, from: alignRight ? originX - width + Self.cellGap : originX, y: y)
        }
    }

    /// The whole lines, under the two groups (ISC-142). One row each, the
    /// window's width to fill, and the left inset to start from — the same
    /// column the left group starts at, so the bar reads as one thing.
    ///
    /// The `+N` marker names the LINE it belongs to and not the group, because
    /// down here a line is not half of anything.
    private func drawFullLines(below rows: Int) {
        for (index, cells) in fullLines().enumerated() {
            let y = 6 + CGFloat(rows + index) * Self.rowHeight
            let squeezed = Self.squeezeLast(cells, into: fullWidth)
            var row = squeezed.cells
            if !squeezed.dropped.isEmpty {
                row.append(DashCell(key: "more-full-\(index)", label: "",
                                    value: "+\(squeezed.dropped.count)"))
                for key in squeezed.dropped { hiddenKeys.append(key) }
            }
            lay(row, from: Self.sideInset, y: y)
        }
    }

    /// Put a row of cells down, left to right, and record where each one
    /// landed and what it was painted with. Every cell on the bar goes
    /// through here, half line and whole line alike, so a probe cannot be
    /// reading one kind of row through code the other kind never runs.
    private func lay(_ row: [DashCell], from startX: CGFloat, y: CGFloat) {
        var x = startX
        for cell in row {
            let cellWidth = Self.measure(cell)
            draw(cell, at: NSPoint(x: x, y: y))
            inkRects[cell.key] = NSRect(x: x, y: y, width: cellWidth, height: Self.rowHeight)
            inkText[cell.key] = cell.value
            // Recorded in `draw`, not here: what a token was painted in is
            // the drawing's answer, and a stale row overrides every tone
            // it was given.
            x += cellWidth + Self.cellGap
        }
    }

    /// A row that still does not fit after the bar has opened every row it
    /// can. Two things happen, in this order, and the order is the design.
    ///
    /// First the longest cells give up characters, down to twelve. Twelve and
    /// not six: `ACTIV…` is not a shorter reading, it is a stump that costs
    /// width and says nothing, and the first run against nine real provider
    /// rows produced exactly that — every cell on the bar cut to five letters.
    ///
    /// Then, if it STILL does not fit, cells are dropped from the end and a
    /// `+N` says how many went. This is the part that matters: a bar that
    /// silently shows eight of your nine rows has told you nothing is wrong.
    /// A cell carrying an alarm is never the one dropped — a calm one goes
    /// instead — because the whole rule of this bar is that it may not hide
    /// trouble (ISC-104.3).
    static let floorCharacters = 12

    struct Squeezed {
        var cells: [DashCell]
        var dropped: [String] = []
    }

    static func squeeze(_ row: [DashCell], into width: CGFloat) -> Squeezed {
        func total(_ cells: [DashCell]) -> CGFloat {
            cells.reduce(CGFloat(0)) { $0 + measure($1) + cellGap }
        }
        guard width > 0, total(row) > width else { return Squeezed(cells: row) }
        let markerRoom = measure(DashCell(key: "", label: "", value: "+99")) + cellGap

        /// The row with its longest cells cut back, as far as the floor.
        func trimmed(_ cells: [DashCell], into room: CGFloat) -> [DashCell] {
            var out = cells
            // Bounded: every pass shortens the longest value by at least one
            // character, and stops when nothing is longer than the floor.
            // A pinned cell is never one of them (ISC-145, ISC-146): the
            // letters come out of the calm readings, never out of the warning.
            for _ in 0..<400 {
                guard total(out) > room else { break }
                var widest: Int?
                for (index, cell) in out.enumerated() where !cell.pinned {
                    if widest == nil || cell.value.count > out[widest!].value.count {
                        widest = index
                    }
                }
                guard let at = widest else { break }
                let length = out[at].value.count
                guard length > floorCharacters else { break }
                out[at] = out[at].clipped(
                    to: max(floorCharacters, length - max(1, length / 8)))
            }
            return out
        }

        var kept = row
        var dropped: [String] = []
        while true {
            let room = dropped.isEmpty ? width : width - markerRoom
            let trial = trimmed(kept, into: room)
            if total(trial) <= room || kept.count <= 1 {
                return Squeezed(cells: trial, dropped: dropped)
            }
            // A row standing in for itself with a dash goes before a row that
            // is actually saying something (ISC-149); then a calm reading;
            // then, only if nothing else is left, a loud one.
            guard let victim = kept.lastIndex(where: { $0.placeholder && !$0.pinned })
                ?? kept.lastIndex(where: { $0.alarm == .none && !$0.pinned })
                ?? kept.lastIndex(where: { !$0.pinned })
            else { return Squeezed(cells: trial, dropped: dropped) }
            dropped.append(kept.remove(at: victim).key)
        }
    }

    /// The same job for a whole line, under a rule the claim states as one
    /// sentence: a cell is never compressed below its natural width while the
    /// line still has room, and when the line runs out the compression starts
    /// at the LAST cell (ISC-142).
    ///
    /// It is a different rule from `squeeze` above, not a tidier version of
    /// it, and the difference is what the two kinds of line are FOR. A half
    /// line is a column of short readings a terminal knows about itself, so
    /// shortening the widest of them spreads the loss and everything stays
    /// readable. A whole line carries a provider's sentences, where the widest
    /// cell is usually the one worth the most — clipping it first is how
    /// `MEMORY OK · REVIEWED 2M AGO · NEXT IN 8 TURNS · 76% FULL` became
    /// `MEMORY OK · RE…` while `CONTEXT 12%` sat beside it untouched.
    ///
    /// Only when every cell is down at the floor do cells start to go, from
    /// the end, with a `+N` saying how many — and the one that goes is never a
    /// cell carrying an alarm (ISC-104.3).
    static func squeezeLast(_ row: [DashCell], into width: CGFloat) -> Squeezed {
        func total(_ cells: [DashCell]) -> CGFloat {
            cells.reduce(CGFloat(0)) { $0 + measure($1) + cellGap }
        }
        guard width > 0, total(row) > width else { return Squeezed(cells: row) }
        let markerRoom = measure(DashCell(key: "", label: "", value: "+99")) + cellGap

        /// The row cut back from its LAST cell, walking backwards, each cell
        /// as far as the floor and no further. Clipped from the original every
        /// pass, so a cell can never collect a second ellipsis on the first.
        ///
        /// Backwards, and not the last cell alone, for a reason that showed up
        /// the first time this ran on a real line: `CONTEXT 12%` at the end of
        /// a line is already shorter than the floor, so a last-cell-only rule
        /// has nothing to give and goes straight to dropping — it would throw
        /// away eleven characters while a fifty-six character reading beside
        /// it stayed whole. Walking backwards spends the width where there is
        /// width to spend, and keeps the FRONT of the line, which is the part
        /// a person reads first.
        func trimmedTail(_ cells: [DashCell], into room: CGFloat) -> [DashCell] {
            var out = cells
            var index = cells.count - 1
            while index >= 0, total(out) > room {
                guard !cells[index].pinned else { index -= 1; continue }
                var length = cells[index].value.count
                // Bounded: every pass takes at least one character off, and
                // stops at the floor.
                for _ in 0..<400 {
                    guard total(out) > room, length > floorCharacters else { break }
                    length = max(floorCharacters, length - max(1, length / 8))
                    out[index] = cells[index].clipped(to: length)
                }
                index -= 1
            }
            return out
        }

        var kept = row
        var dropped: [String] = []
        while true {
            let room = dropped.isEmpty ? width : width - markerRoom
            let trial = trimmedTail(kept, into: room)
            if total(trial) <= room || kept.count <= 1 {
                return Squeezed(cells: trial, dropped: dropped)
            }
            // A row standing in for itself with a dash goes before a row that
            // is actually saying something (ISC-149); then a calm reading;
            // then, only if nothing else is left, a loud one.
            guard let victim = kept.lastIndex(where: { $0.placeholder && !$0.pinned })
                ?? kept.lastIndex(where: { $0.alarm == .none && !$0.pinned })
                ?? kept.lastIndex(where: { !$0.pinned })
            else { return Squeezed(cells: trial, dropped: dropped) }
            dropped.append(kept.remove(at: victim).key)
        }
    }

    /// The colour a token came out, as a person would read it off a picture.
    /// It is here so the tone-to-colour map can be checked against the theme
    /// on screen rather than against a table somebody typed twice.
    private(set) var inkColours: [String: [String]] = [:]
    /// The rows there was no room for. They are not on the bar and they are
    /// not a secret: a `+N` sits where they would have been, and this is the
    /// list behind that number.
    private(set) var hiddenKeys: [String] = []

    static func hex(_ colour: NSColor) -> String {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }

    private func draw(_ cell: DashCell, at point: NSPoint) {
        let palette = Theme.current
        var valueColour: NSColor
        switch cell.alarm {
        case .none: valueColour = palette.muted
        case .warn: valueColour = palette.failedSoft
        case .critical: valueColour = palette.failed
        }
        var labelColour = cell.alarm == .none ? palette.whisper : valueColour
        if cell.live, cell.alarm == .none {
            labelColour = palette.accentText
            valueColour = palette.ink
        }

        let label = NSAttributedString(string: cell.label, attributes: [
            .font: Theme.labelFont(10), .foregroundColor: labelColour, .kern: 0.5,
        ])
        label.draw(at: NSPoint(x: point.x, y: point.y + 4))
        var x = point.x + label.size().width + (cell.label.isEmpty ? 0 : 6)
        guard !cell.tokens.isEmpty else {
            let value = NSAttributedString(string: cell.value, attributes: [
                .font: Theme.labelFont(11), .foregroundColor: valueColour,
            ])
            value.draw(at: NSPoint(x: x, y: point.y + 3))
            return
        }
        // Word by word: this is the only reason the format lets a key repeat.
        // A cell whose provider went quiet is drawn dim whatever its tones
        // said, because the tones describe a reading that is no longer being
        // taken.
        var tones: [[String]] = []
        var inks: [String] = []
        for (index, token) in cell.tokens.enumerated() {
            let text = (index == 0 ? "" : " ") + token.text
            let tone: FactTone? = cell.stale ? .dim : token.tone
            let colour: NSColor = tone.map { palette.colour(for: $0) } ?? valueColour
            let piece = NSAttributedString(string: text, attributes: [
                .font: Theme.labelFont(11), .foregroundColor: colour,
            ])
            piece.draw(at: NSPoint(x: x, y: point.y + 3))
            x += piece.size().width
            tones.append([token.text, tone?.rawValue ?? ""])
            inks.append(Self.hex(colour))
        }
        inkTones[cell.key] = tones
        inkColours[cell.key] = inks
    }
}
