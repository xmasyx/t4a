//  TabStripView.swift — tabs across the top, the second of the two session
//  layouts the principal asked for (side rail AND top tabs, iTerm2 style).
//  The choice lives in the config file and survives a restart.
//
//  Rewritten on 2026-08-25 for one reason: «la selezione risulta meccanica e
//  anche la chiusura con le X. Quasi laggano». There was no lag to find — the
//  strip drew and nothing else. No hover, no pressed state, and the selection
//  moved only after the model had answered, so a click had no acknowledgement
//  of its own. A control that reacts a frame late reads as slow even when the
//  frame is all it costs; a control that never reacts reads as broken. Three
//  answers, in the order they matter: paint the new selection at once, slide
//  the pill instead of teleporting it, and say under the pointer what is about
//  to be pressed.

import AgentAdapters
import AppKit

@MainActor
final class TabStripView: NSView, LanguageAware {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The «+» after the last tab, iTerm's way (his ask, 25/08).
    var onNewTab: (() -> Void)?
    private var plusRect = NSRect.zero

    /// The twin of the rail's: whichever of the two is on screen carries the
    /// button that moves the sessions to the other place. Without it, tab
    /// layout would be a one-way door — the rail is gone, and with it the only
    /// way back (2026-08-24).
    let layoutButton = PanelToggleButton(edge: .top, label: BenchBand.sessionsLayout,
                                         displayLabel: S.sessionsLayout)

    private var titles: [String] = []
    private var selected = 0
    private var hitBoxes: [(rect: NSRect, index: Int, isClose: Bool)] = []

    /// What the pointer is over, and what is being pressed. Nil means nothing.
    private var hoverTab: Int?
    private var hoverPoint: NSPoint?
    private var hoverClose: Int?
    private var pressedClose: Int?
    private var trackingArea: NSTrackingArea?

    /// The pill in flight: where it started, where it is going, and when it
    /// left. Drawn from these rather than from `selected`, so the selection can
    /// already be true in the model while the paint is still catching up.
    private var pillFrom: NSRect?
    private var pillTo: NSRect?
    private var pillStartedAt: TimeInterval = 0
    private var pillTimer: Timer?
    private static let pillDuration: TimeInterval = 0.16

    /// The working sign owns the only repeating clock in this view.  It is
    /// born only while at least one tab is working and motion is allowed, and
    /// is destroyed as soon as either half stops being true.
    private var workTimer: Timer?
    private var animationsEnabled = true
    private var reduceMotionOverride: Bool?
    private var reduceMotionCache = false
    private var reduceMotionCheckedAt: TimeInterval = 0
    private(set) var redrawCount = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layoutButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layoutButton)
        NSLayoutConstraint.activate([
            layoutButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            layoutButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyLanguage() {
        layoutButton.displayLabel = S.sessionsLayout
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWorkAnimation()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            pillTimer?.invalidate()
            pillTimer = nil
            workTimer?.invalidate()
            workTimer = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Where the first tab starts: past the button, never under it.
    private var firstTabX: CGFloat { 8 + PanelToggleButton.size.width + 10 }

    /// Il segno che una scheda porta a destra del nome (sua richiesta, 25/08).
    ///
    /// Tre stati, perché «lavora», «ha finito» e «aspetta una decisione» sono
    /// tre risposte diverse. La precedenza non vive nel disegno: è la regola
    /// pura condivisa con i test, decisione > finita > lavora.
    struct Segno: Equatable {
        var decisioni = 0
        var haFinito = false
        /// True only when every finished pane in this tab has been viewed.
        /// The painter receives the resolved kind; it never infers visibility.
        var finiViste = true
        var staLavorando = false
        var kind: ChatMarkKind {
            ChatMarkKind.resolve(decisions: decisioni, hasFinished: haFinito,
                                 finishedWasSeen: finiViste,
                                 hasWorking: staLavorando)
        }
        var isEmpty: Bool { kind == .none }
    }

    private var segni: [Segno] = []

    func reload(titles: [String], selected: Int, segni: [Segno] = [],
                animationsEnabled: Bool = true) {
        let moved = self.selected != selected || self.titles != titles
        let changed = self.titles != titles || self.selected != selected
            || self.segni != segni || self.animationsEnabled != animationsEnabled
        self.titles = titles
        self.selected = selected
        self.segni = segni
        self.animationsEnabled = animationsEnabled
        if moved { flyPill(to: box(of: selected)) }
        updateWorkAnimation()
        // A quiet refresh with the same answer does not redraw the strip.
        // This is what makes the five-second stillness pole meaningful: the
        // counter below records drawing, not calls to the controller.
        if changed { needsDisplay = true }
    }

    /// Il tondo di una decisione, e il pallino di una chat che ha finito.
    /// Stessa misura del mockup approvato: 16 punti di diametro.
    private static let tondo: CGFloat = 16
    private static let pallino: CGFloat = 7
    /// Nine points: visibly a ring rather than the approved seven-point dot,
    /// still quieter and smaller than the sixteen-point decision badge.
    private static let anello: CGFloat = 9

    private func disegna(_ segno: Segno, in box: NSRect, palette: Theme.Palette) {
        guard !segno.isEmpty else { return }
        let centroY = box.midY
        if segno.kind == .decision {
            let cerchio = NSRect(x: box.maxX - 10 - Self.tondo,
                                 y: centroY - Self.tondo / 2,
                                 width: Self.tondo, height: Self.tondo)
            palette.accent.setFill()
            NSBezierPath(ovalIn: cerchio).fill()
            let testo = NSAttributedString(string: String(segno.decisioni), attributes: [
                .font: Theme.uiFont(10, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
            let taglia = testo.size()
            // Centrato sulla scatola della riga, poi corretto di quel punto
            // che separa la scatola dall'inchiostro: una cifra si siede sulla
            // linea di base, non al centro del proprio rigo. La correzione è
            // MISURATA sui pixel del rendering, come nel mockup.
            testo.draw(at: NSPoint(x: cerchio.midX - taglia.width / 2,
                                   y: cerchio.midY - taglia.height / 2 + Self.correzioneCifra))
            return
        }
        if segno.kind == .working {
            let ring = NSRect(x: box.maxX - 10 - Self.anello,
                              y: centroY - Self.anello / 2,
                              width: Self.anello, height: Self.anello)
            let centre = NSPoint(x: ring.midX, y: ring.midY)
            let radius = (Self.anello - 1.5) / 2
            palette.hairline.setStroke()
            let track = NSBezierPath(ovalIn: ring.insetBy(dx: 0.75, dy: 0.75))
            track.lineWidth = 1
            track.stroke()

            // A broken ring says motion even in its reduced-motion pose; a
            // solid point cannot be mistaken for it.  With motion allowed the
            // gap makes one slow lap, twelve modest frames per second.
            let phase = workTimer == nil ? 35
                : CGFloat(ProcessInfo.processInfo.systemUptime
                    .truncatingRemainder(dividingBy: 1.2) / 1.2 * 360)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: radius,
                          startAngle: phase, endAngle: phase + 235)
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            palette.muted.setStroke()
            arc.stroke()
            return
        }
        let punto = NSRect(x: box.maxX - 10 - Self.pallino,
                           y: centroY - Self.pallino / 2,
                           width: Self.pallino, height: Self.pallino)
        palette.muted.setFill()
        NSBezierPath(ovalIn: punto).fill()
    }

    private var reducedMotion: Bool {
        if let reduceMotionOverride { return reduceMotionOverride }
        let now = ProcessInfo.processInfo.systemUptime
        if now - reduceMotionCheckedAt > 1 {
            reduceMotionCheckedAt = now
            CFPreferencesAppSynchronize("com.apple.universalaccess" as CFString)
            let stored = CFPreferencesCopyAppValue(
                "reduceMotion" as CFString,
                "com.apple.universalaccess" as CFString) as? Bool ?? false
            reduceMotionCache = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || stored
        }
        return reduceMotionCache
    }

    private func updateWorkAnimation() {
        let shouldRun = window != nil && !isHidden && animationsEnabled && !reducedMotion
            && segni.contains { $0.kind == .working }
        if shouldRun, workTimer == nil {
            workTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) {
                [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // A scripted preference change does not post AppKit's
                    // accessibility notification. Rechecking here also makes
                    // that route settle within a second.
                    guard self.window != nil, !self.isHidden,
                          self.animationsEnabled && !self.reducedMotion,
                          self.segni.contains(where: { $0.kind == .working }) else {
                        self.updateWorkAnimation()
                        return
                    }
                    self.setNeedsDisplay(self.workMarksRect)
                }
            }
        } else if !shouldRun, let timer = workTimer {
            timer.invalidate()
            workTimer = nil
            needsDisplay = true
        }
    }

    private var workMarksRect: NSRect {
        let all = boxes()
        return segni.indices.compactMap { index -> NSRect? in
            guard segni[index].kind == .working, all.indices.contains(index) else { return nil }
            let box = all[index]
            return NSRect(x: box.maxX - 22, y: box.midY - 8, width: 18, height: 16)
        }.reduce(.zero) { $0 == .zero ? $1 : $0.union($1) }
    }

    /// Quanto scostare la cifra dal centro della sua scatola perché il suo
    /// INCHIOSTRO stia al centro del tondo. Misurato, non stimato.
    static var correzioneCifra: CGFloat = 0

    // MARK: - Geometry, worked out in one place

    /// The rectangle of every tab, in drawing order. Shared by the drawing, the
    /// hit test and the animation: a pill that lands beside the tab it belongs
    /// to is what happens when the same numbers are worked out twice.
    private func boxes() -> [NSRect] {
        guard !titles.isEmpty else { return [] }
        // iTerm2's rule, his call (25/08): the tabs SHARE the strip. One tab
        // is the whole bar, two are half each, three a third — the width comes
        // from how many there are, never from what their titles happen to say.
        let gap: CGFloat = 6, rightEdge: CGFloat = 8 + 26   // room for the «+»
        let room = bounds.width - firstTabX - rightEdge - gap * CGFloat(titles.count - 1)
        let width = max(60, room / CGFloat(titles.count))
        var x = firstTabX
        var out: [NSRect] = []
        for _ in titles {
            out.append(NSRect(x: x, y: 4, width: width, height: bounds.height - 9))
            x += width + gap
        }
        return out
    }

    /// The geometry depends on the strip's own width now, so a resize is a
    /// re-layout of every tab, not just a stretch of the background.
    override func layout() {
        super.layout()
        needsDisplay = true
    }

    private func box(of index: Int) -> NSRect? {
        let all = boxes()
        return all.indices.contains(index) ? all[index] : nil
    }

    /// The × sits at the LEFT corner, beside the name (ISC-167, his call
    /// 25/08).
    /// It used to be at the far right, which on tabs that share the whole
    /// strip puts it a long way from the word it belongs to — on a wide
    /// window, half a screen from the name it closes.
    private func closeBox(in tab: NSRect) -> NSRect {
        NSRect(x: tab.minX + 8, y: tab.minY + 7, width: 12, height: 12)
    }

    /// Where the name starts, and it does not depend on the pointer.
    ///
    /// The × is only drawn on hover, so the honest-looking thing would be to
    /// let the title use that room while it is not there. It is the wrong
    /// thing: the title would slide right every time the pointer crossed the
    /// tab, and text that moves reads as text being rewritten. The room is
    /// reserved always and the × moves into it.
    private static let titleInset: CGFloat = 26

    // MARK: - The pill in flight

    private func flyPill(to destination: NSRect?) {
        guard let destination else { pillFrom = nil; pillTo = nil; return }
        // From wherever it is being drawn right now, which on a fast second
        // click is halfway through the previous flight and not the old tab.
        pillFrom = currentPill() ?? destination
        pillTo = destination
        pillStartedAt = ProcessInfo.processInfo.systemUptime
        pillTimer?.invalidate()
        pillTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.needsDisplay = true
                guard self.pillProgress() >= 1 else { return }
                self.pillTimer?.invalidate()
                self.pillTimer = nil
            }
        }
        needsDisplay = true
    }

    private func pillProgress() -> CGFloat {
        guard pillTo != nil else { return 1 }
        let elapsed = ProcessInfo.processInfo.systemUptime - pillStartedAt
        return min(1, max(0, CGFloat(elapsed / Self.pillDuration)))
    }

    /// Where the pill is at this instant, eased so it leaves quickly and
    /// settles slowly: the shape of something being put down, not of something
    /// jumping.
    private func currentPill() -> NSRect? {
        guard let from = pillFrom, let to = pillTo else { return box(of: selected) }
        let t = pillProgress()
        let e = 1 - pow(1 - t, 3)
        return NSRect(x: from.minX + (to.minX - from.minX) * e,
                      y: from.minY + (to.minY - from.minY) * e,
                      width: from.width + (to.width - from.width) * e,
                      height: from.height + (to.height - from.height) * e)
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if plusRect.contains(point) != plusRect.contains(hoverPoint ?? .zero) { needsDisplay = true }
        hoverPoint = point
        let tab = hitBoxes.first { !$0.isClose && $0.rect.contains(point) }?.index
        let close = hitBoxes.first { $0.isClose && $0.rect.contains(point) }?.index
        guard tab != hoverTab || close != hoverClose else { return }
        hoverTab = tab
        hoverClose = close
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
        guard hoverTab != nil || hoverClose != nil else { return }
        hoverTab = nil
        hoverClose = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        press(at: convert(event.locationInWindow, from: nil))
    }

    /// The click, without the event. Split so a bench can put a press exactly
    /// on a tab or on its ×, which is the only part of this that a person's
    /// hand does differently.
    func press(at point: NSPoint) {
        if plusRect.contains(point) { onNewTab?(); return }
        // Close boxes sit inside tab boxes, so they are tested first.
        if let hit = hitBoxes.first(where: { $0.isClose && $0.rect.contains(point) }) {
            pressedClose = hit.index
            display()   // drawn pressed BEFORE the model is told, or the press
            pressedClose = nil   // of an instant close is never seen at all
            onClose?(hit.index)
            return
        }
        if let hit = hitBoxes.first(where: { !$0.isClose && $0.rect.contains(point) }) {
            // Painted before the model is told. The controller comes back with
            // the same answer a moment later and `reload` finds nothing to
            // change; if it ever comes back with a different one, that answer
            // wins, because `reload` is what sets `selected`.
            if selected != hit.index {
                selected = hit.index
                flyPill(to: box(of: hit.index))
            }
            onSelect?(hit.index)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        redrawCount += 1
        hitBoxes.removeAll(keepingCapacity: true)
        let palette = Theme.current
        palette.ground.setFill()
        bounds.fill()
        palette.hairlineSoft.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        // The pill first, under everything: the selection is a surface the
        // selected tab sits on, not a box drawn around its text.
        if let pill = currentPill() {
            palette.raised.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        }

        let all = boxes()
        for (index, title) in titles.enumerated() where all.indices.contains(index) {
            let box = all[index]
            let isSelected = index == selected
            // Under the pointer an unselected tab warms up: the cheapest way to
            // say «this one, and it can be clicked» before the click.
            if !isSelected, hoverTab == index {
                palette.raised.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            }
            let text = NSAttributedString(string: title, attributes: [
                .font: Theme.uiFont(12, weight: isSelected ? .medium : .regular),
                .foregroundColor: isSelected || hoverTab == index ? palette.ink : palette.whisper,
            ])
            // Il nome si ferma prima del segno, altrimenti un titolo lungo ci
            // finisce sotto e si legge una parola con un tondo in mezzo.
            let segno = segni.indices.contains(index) ? segni[index] : Segno()
            let spazioSegno: CGFloat
            switch segno.kind {
            case .none: spazioSegno = 0
            case .decision: spazioSegno = Self.tondo + 8
            case .finished: spazioSegno = Self.pallino + 8
            case .working: spazioSegno = Self.anello + 8
            }
            text.draw(in: NSRect(x: box.minX + Self.titleInset, y: box.minY + 5,
                                 width: max(10, box.width - Self.titleInset - 10 - spazioSegno),
                                 height: 16))
            disegna(segno, in: box, palette: palette)

            // The × only under the pointer (his call, 25/08, reversing the
            // always-visible choice of the 23rd): resting tabs show no
            // controls, the hovered one shows its way out. The hit box
            // follows the drawing — an invisible × must not be clickable, or
            // a click aimed at the TAB closes it.
            let hovered = hoverTab == index || hoverClose == index || pressedClose == index
            let close = closeBox(in: box)
            if hovered {
                if hoverClose == index || pressedClose == index {
                    (pressedClose == index ? palette.muted : palette.raised).setFill()
                    NSBezierPath(roundedRect: close.insetBy(dx: -3, dy: -3),
                                 xRadius: 4, yRadius: 4).fill()
                }
                let cross = NSAttributedString(string: "×", attributes: [
                    .font: Theme.uiFont(13),
                    .foregroundColor: (hoverClose == index || pressedClose == index)
                        ? palette.ink : palette.whisper,
                ])
                cross.draw(at: NSPoint(x: close.minX + 2, y: close.minY - 2))
            }

            hitBoxes.append((box, index, false))
            if hovered { hitBoxes.append((close.insetBy(dx: -3, dy: -3), index, true)) }
        }

        // The «+», right of the last tab. Drawn as a quiet cell: it earns its
        // ink on hover like everything else in the strip.
        let lastX = all.last.map(\.maxX) ?? firstTabX
        plusRect = NSRect(x: lastX + 6, y: 4, width: 24, height: bounds.height - 9)
        let plusHover = plusRect.contains(hoverPoint ?? .zero)
        if plusHover {
            palette.raised.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: plusRect, xRadius: 6, yRadius: 6).fill()
        }
        NSAttributedString(string: "+", attributes: [
            .font: Theme.uiFont(14),
            .foregroundColor: plusHover ? palette.ink : palette.whisper,
        ]).draw(at: NSPoint(x: plusRect.midX - 4, y: plusRect.minY + 2))
    }

    // MARK: - For the bench

    /// What the strip is drawing right now: where the pill is and whether it is
    /// still moving. A claim about movement is a claim about two numbers at two
    /// moments, and this is where both are read.
    var testState: [String: Any] {
        let pill = currentPill() ?? .zero
        return [
            "selected": selected,
            "pillX": Double(pill.minX),
            "pillWidth": Double(pill.width),
            // Where the selected tab actually is. The pill arriving is the pill
            // agreeing with THIS, not with a number written in a bench.
            "tabX": Double(box(of: selected)?.minX ?? -1),
            "flying": pillTimer != nil,
            "hoverTab": hoverTab ?? -1,
            "hoverClose": hoverClose ?? -1,
            "redrawCount": redrawCount,
            "workAnimationActive": workTimer != nil,
            "reducedMotion": reducedMotion,
            "marks": titles.indices.map { index -> [String: Any] in
                let sign = segni.indices.contains(index) ? segni[index] : Segno()
                let shape: String
                switch sign.kind {
                case .none: shape = "none"
                case .working: shape = "gap-ring"
                case .finished: shape = "solid-dot"
                case .decision: shape = "number-circle"
                }
                return ["index": index, "kind": sign.kind.rawValue,
                        "decisions": sign.decisioni, "shape": shape,
                        "animated": sign.kind == .working && workTimer != nil]
            },
            // Ogni scheda DOVE È SULLO SCHERMO, non solo quella scelta: un
            // banco che deve cliccare la scheda accanto non ha altro modo di
            // sapere dove sta, e dedurlo dalla larghezza di questa sarebbe
            // aritmetica che smette di valere il giorno in cui i titoli
            // cambiano lunghezza (ISC-188). Diagnostica: qui non si disegna.
            "boxes": titles.indices.compactMap { index -> [String: Double]? in
                guard let box = box(of: index),
                      let screen = window?.convertToScreen(convert(box, to: nil))
                else { return nil }
                return ["x": Double(screen.midX), "y": Double(screen.midY),
                        "w": Double(screen.width), "h": Double(screen.height)]
            },
        ]
    }

    /// Moves the pointer for a bench, without a mouse.
    func testHover(at point: NSPoint) {
        let tab = hitBoxes.first { !$0.isClose && $0.rect.contains(point) }?.index
        let close = hitBoxes.first { $0.isClose && $0.rect.contains(point) }?.index
        hoverTab = tab
        hoverClose = close
        needsDisplay = true
    }

    /// The centre of a tab and of its close box, so a bench can aim.
    func testPoints(of index: Int) -> (tab: NSPoint, close: NSPoint)? {
        guard let box = box(of: index) else { return nil }
        let close = closeBox(in: box)
        return (NSPoint(x: box.midX, y: box.midY), NSPoint(x: close.midX, y: close.midY))
    }

    /// The test channel forces the same branch the system preference feeds,
    /// without rewriting the user's global accessibility preference.
    func testSetReducedMotion(_ value: Bool?) {
        reduceMotionOverride = value
        updateWorkAnimation()
        needsDisplay = true
    }
}
