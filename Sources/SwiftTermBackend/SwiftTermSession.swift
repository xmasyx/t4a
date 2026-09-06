//  SwiftTermSession.swift — the one place in T4A that knows a VT library
//  exists.
//
//  Everything the app does with a terminal goes through TerminalCore's
//  protocols; this file is the adapter that fills them from SwiftTerm. When
//  libghostty ships a Swift framework with a stable API, a sibling file
//  fills the same protocols and nothing above changes. The falsifier is one
//  grep: `import SwiftTerm` appears in this target and nowhere else.

import AppKit
import Foundation
import MetalRenderer
import SwiftTerm
import TerminalCore

/// The view SwiftTerm draws into, with the pty stream tapped on the way past.
@MainActor
final class TappedTerminalView: LocalProcessTerminalView {
    var onBytes: ((ArraySlice<UInt8>) -> Void)?
    var onSequence: ((OSCSequence) -> Void)?
    let tap = OSCTap()

    /// Precise scrolling belongs half to SwiftTerm's integral viewport and
    /// half to the renderer's sub-row translation. These closures keep the
    /// subclass from reaching through the backend into Metal state.
    var scrollCellHeight: (() -> CGFloat)?
    var canPixelScroll: ((CGFloat) -> Bool)?
    var onScrollLines: ((Int) -> Int)?
    var onScrollOffset: ((CGFloat) -> Void)?
    var onScrollSettle: (() -> Void)?
    var onScrollReset: (() -> Void)?
    var onWheelEvent: ((Double) -> Void)?
    private var preciseScrollRemainder: CGFloat = 0
    private var scrollEndWork: DispatchWorkItem?
    private var alternateWheelRemainder: CGFloat = 0
    private var alternateWheelSentFirst = false
    private var alternateWheelEndWork: DispatchWorkItem?
    private var scrollMonitor: Any?
    private var linkMonitor: Any?
    private var consumesLinkClick = false
    private var linkCursorState = TerminalLinkCursorState()

    /// The closure is never called by an ordinary mouse move. Command is the
    /// gate here, before any grid row is read or filesystem question is asked.
    var resolveLink: ((NSPoint) -> TerminalLinkHover?)?
    var onLinkHoverChanged: ((TerminalLinkHover?) -> Void)?
    var onOpenLink: ((TerminalLink) -> Void)?
    private(set) var linkHover: TerminalLinkHover?
    var linkCursorTrace: TerminalLinkCursorTrace { linkCursorState.trace }

    /// True while the GPU renderer is drawing this pane.
    ///
    /// The engine keeps doing everything else — parsing, layout, selection,
    /// keys — and only stops painting. That is what makes ISC-24 real rather
    /// than a promise: flip this back and CoreText has the pane again on the
    /// next redraw, with no restart and no reallocation.
    var gpuIsDrawing = false {
        didSet { needsDisplay = true }
    }

    /// Files dropped on the pane arrive as their paths.
    ///
    /// Split out from `performDragOperation` on purpose: a bench can hand this
    /// a pasteboard, and what it exercises is the whole decision — what the
    /// drag carried, what it becomes, what reaches the pty — with only
    /// AppKit's delivery of the drag left out, and that part is proved by the
    /// registered types instead.
    /// Chi ha la riga d'ingresso; `nil` o `false` e il testo va nel pty.
    var onDropPaths: (([String]) -> Bool)?

    @discardableResult
    func acceptDrop(from board: NSPasteboard) -> Bool {
        let paths = DroppedItems.paths(from: board)
        guard !paths.isEmpty else { return false }
        // Con la bolla accesa la riga d'ingresso non è più il pty: scriverci
        // dentro i percorsi li seppelliva sotto la copertura di chat pura.
        if onDropPaths?(paths) == true { return true }
        send(txt: paths.joined(separator: " "))
        return true
    }

    /// Fine del gesto di selezione (ISC-197).
    ///
    /// `mouseUp` e non `mouseDragged`: iTerm copia al rilascio, e copiare a
    /// ogni pixel di trascinamento riscriverebbe gli appunti decine di volte
    /// per una selezione sola. `open` in SwiftTerm, quindi qui una
    /// sottoclasse basta — a differenza di `keyDown`, che è solo `public` ed
    /// è il motivo per cui Esc vive in un monitor di finestra.
    var onSelection: ((String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            updateLink(at: convert(event.locationInWindow, from: nil), commandDown: true)
            if let link = linkHover?.link {
                consumesLinkClick = true
                onOpenLink?(link)
                return
            }
        }
        // SwiftTerm hit-tests integral rows. Aligning before it sees the press
        // makes the selected row be the row visibly under the pointer.
        resetPreciseScroll()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if consumesLinkClick {
            consumesLinkClick = false
            return
        }
        super.mouseUp(with: event)
        guard let text = getSelection(), !text.isEmpty else { return }
        onSelection?(text)
    }

    override func viewDidHide() {
        super.viewDidHide()
        clearLinkHover()
    }

    private func updateLink(at point: NSPoint, commandDown: Bool,
                            timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard commandDown, bounds.contains(point) else {
            clearLinkHover(timestamp: timestamp)
            return
        }
        setLinkHover(resolveLink?(point), timestamp: timestamp)
    }

    private func setLinkHover(_ hover: TerminalLinkHover?, timestamp: TimeInterval) {
        let changed = hover != linkHover
        if changed {
            linkHover = hover
            onLinkHoverChanged?(hover)
        }
        updateLinkCursor(for: hover, timestamp: timestamp)
    }

    private func updateLinkCursor(for hover: TerminalLinkHover?, timestamp: TimeInterval) {
        switch linkCursorState.setHover(active: hover != nil, at: timestamp) {
        case .push:
            // SwiftTerm's whole-surface I-beam cursor rect is applied after a
            // plain `set()`. Keeping the hand on AppKit's cursor stack makes
            // the link own the cursor until this exact state is cleared.
            NSCursor.pointingHand.push()
        case .pop:
            NSCursor.pop()
            // The pop restores whatever was current at the push, and that was
            // the arrow: the I-beam comes from cursor rects, which AppKit
            // re-applies only on the next mouse event. Releasing Command
            // without moving sends none, so the beam is put back here when
            // the pointer is still over this surface (bench-link L3).
            if let window, window.isKeyWindow,
               bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                NSCursor.iBeam.set()
            }
        case .none:
            break
        }
    }

    private func clearLinkHover(timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        setLinkHover(nil, timestamp: timestamp)
    }

    /// Reassert after link resolution, at the last point the local monitor
    /// owns. A mouse move still has SwiftTerm's sealed responder method ahead
    /// of it, so its set belongs on the next main-loop turn; a cursorUpdate is
    /// consumed here and can install the hand immediately.
    private func handleLinkCursorEvent(_ event: TerminalLinkCursorPointerEvent,
                                       timestamp: TimeInterval) -> Bool {
        let action = linkCursorState.handle(event, at: timestamp)
        if action.reassertPointingHand {
            switch event {
            case .mouseMoved:
                DispatchQueue.main.async { [weak self] in
                    guard self?.linkCursorState.stackHeld == true else { return }
                    NSCursor.pointingHand.set()
                }
            case .cursorUpdate:
                NSCursor.pointingHand.set()
            }
        }
        return action.consume
    }

    /// SwiftTerm seals its `scrollWheel` override outside its module. A local
    /// monitor is therefore the only AppKit door before that method: consume
    /// our precise scrollback events here, and return every program-owned or
    /// non-precise event unchanged so SwiftTerm receives its normal input.
    private func handlePreciseScroll(_ event: NSEvent) -> Bool {
        let started = CACurrentMediaTime()
        var handled = false
        defer {
            if handled { onWheelEvent?(CACurrentMediaTime() - started) }
        }
        let programOwnsWheel = terminal.isCurrentBufferAlternate || terminal.mouseMode != .off
        guard gpuIsDrawing, !programOwnsWheel, event.hasPreciseScrollingDeltas,
              let height = scrollCellHeight?(), height > 0,
              onScrollOffset != nil else {
            resetPreciseScroll()
            return false
        }
        handled = true

        scrollEndWork?.cancel()
        let delta = event.scrollingDeltaY
        if delta != 0 {
            guard canPixelScroll?(delta) ?? false else {
                resetPreciseScroll()
                return true
            }
            let step = PixelScrollGeometry.step(offset: preciseScrollRemainder,
                                                delta: delta, cellHeight: height)
            let requestedLines = step.lines
            if requestedLines != 0 {
                let movedLines = onScrollLines?(requestedLines) ?? 0
                if movedLines == requestedLines {
                    preciseScrollRemainder = step.offset
                    // Reaching either end consumes the fractional reveal too:
                    // there is no row beyond that edge to draw into the gap.
                    if preciseScrollRemainder > 0,
                       !(canPixelScroll?(delta) ?? false) {
                        preciseScrollRemainder = 0
                    }
                } else {
                    // At either end of scrollback there is no unseen row to
                    // reveal. A rubber band would be invented state, so stop.
                    preciseScrollRemainder = 0
                }
            } else {
                preciseScrollRemainder = step.offset
            }
            onScrollOffset?(preciseScrollRemainder)
        }

        if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
            finishPreciseScroll()
        } else {
            // Synthesised streams and ordinary precise wheels carry no phase.
            // Twenty-five milliseconds of silence plus the 100 ms ease keeps
            // final alignment inside the 150 ms bench bound.
            let work = DispatchWorkItem { [weak self] in self?.finishPreciseScroll() }
            scrollEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
        }
        return true
    }

    /// Schermo alternato SENZA mouse reporting: il programma riceve tasti freccia. Il primo tasto parte
    /// appena il gesto ha accumulato cellHeight/3 (non una riga intera), i successivi ogni riga; il resto
    /// si azzera a fine gesto. Con mouse reporting attivo non si tocca niente: gli eventi mouse sono già
    /// proprietà del programma.
    private func handleAlternateScreenWheel(_ event: NSEvent) -> Bool {
        let sendsArrowKeys = terminal.isCurrentBufferAlternate && terminal.mouseMode == .off
        guard sendsArrowKeys else {
            resetAlternateScreenWheel()
            return false
        }
        // A wheel notch already has line semantics. Only a precise trackpad
        // delta needs the early threshold; SwiftTerm keeps every other route.
        guard event.hasPreciseScrollingDeltas,
              let height = scrollCellHeight?(), height > 0 else {
            resetAlternateScreenWheel()
            return false
        }

        alternateWheelEndWork?.cancel()
        let delta = event.scrollingDeltaY
        if delta != 0 {
            alternateWheelRemainder += delta
            if !alternateWheelSentFirst {
                let firstThreshold = height / 3
                if abs(alternateWheelRemainder) >= firstThreshold {
                    sendAlternateArrow(scrollingUp: alternateWheelRemainder > 0,
                                       sourceEvent: event)
                    alternateWheelRemainder -= alternateWheelRemainder > 0
                        ? firstThreshold : -firstThreshold
                    alternateWheelSentFirst = true
                }
            }
            while alternateWheelSentFirst && abs(alternateWheelRemainder) >= height {
                let scrollingUp = alternateWheelRemainder > 0
                sendAlternateArrow(scrollingUp: scrollingUp, sourceEvent: event)
                alternateWheelRemainder -= scrollingUp ? height : -height
            }
        }

        if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
            resetAlternateScreenWheel()
        } else if event.phase.isEmpty && event.momentumPhase.isEmpty {
            // Synthetic and older precise streams have no phase. Silence is
            // their only end marker, so never carry a fraction into the next.
            let work = DispatchWorkItem { [weak self] in self?.resetAlternateScreenWheel() }
            alternateWheelEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: work)
        }
        return true
    }

    private func sendAlternateArrow(scrollingUp: Bool, sourceEvent: NSEvent) {
        let functionKey = scrollingUp ? NSUpArrowFunctionKey : NSDownArrowFunctionKey
        guard let scalar = UnicodeScalar(functionKey),
              let keyEvent = NSEvent.keyEvent(
                with: .keyDown, location: sourceEvent.locationInWindow,
                modifierFlags: [], timestamp: sourceEvent.timestamp,
                windowNumber: sourceEvent.windowNumber, context: nil,
                characters: String(scalar), charactersIgnoringModifiers: String(scalar),
                isARepeat: false, keyCode: scrollingUp ? 126 : 125) else { return }
        // Calling the engine's key path preserves application-cursor and
        // keyboard-protocol modes; spelling ESC sequences here would not.
        super.keyDown(with: keyEvent)
    }

    private func resetAlternateScreenWheel() {
        alternateWheelEndWork?.cancel()
        alternateWheelEndWork = nil
        alternateWheelRemainder = 0
        alternateWheelSentFirst = false
    }

    private func finishPreciseScroll() {
        scrollEndWork?.cancel()
        scrollEndWork = nil
        preciseScrollRemainder = 0
        onScrollSettle?()
    }

    func resetPreciseScroll() {
        scrollEndWork?.cancel()
        scrollEndWork = nil
        preciseScrollRemainder = 0
        resetAlternateScreenWheel()
        onScrollReset?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptDrop(from: sender.draggingPasteboard)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(DroppedItems.types)
        if window == nil {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            if let linkMonitor { NSEvent.removeMonitor(linkMonitor) }
            linkMonitor = nil
            clearLinkHover()
        } else if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self else { return event }
                let handled = MainActor.assumeIsolated {
                    guard !self.isHiddenOrHasHiddenAncestor,
                          event.window === self.window,
                          self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    else { return false }
                    if self.handleAlternateScreenWheel(event) { return true }
                    return self.handlePreciseScroll(event)
                }
                return handled ? nil : event
            }
        }
        if window != nil, linkMonitor == nil {
            // SwiftTerm implements these responder methods as `public` rather
            // than `open`, so a subclass cannot override them. A local monitor
            // observes the real events without consuming them; the engine
            // still receives every move and modifier change it owned before.
            linkMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .cursorUpdate, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                let consumeLinkEvent = MainActor.assumeIsolated {
                    guard !self.isHiddenOrHasHiddenAncestor else {
                        self.clearLinkHover()
                        return false
                    }
                    // A flagsChanged event can arrive without a window even
                    // though the key window owns it. Reading the window's live
                    // mouse location makes releasing Command clear a stationary
                    // hover in the same event, not on the next mouse move.
                    if event.type == .flagsChanged,
                       let window = self.window, window.isKeyWindow {
                        let point = self.convert(window.mouseLocationOutsideOfEventStream,
                                                 from: nil)
                        self.updateLink(
                            at: point,
                            commandDown: event.modifierFlags.contains(.command),
                            timestamp: event.timestamp)
                        return false
                    }
                    // Cursor-rect maintenance is an EFFECT of the current
                    // hover, not a new hit-test input. Re-resolving it here,
                    // or listening to the cursor rects' enter/exit traffic,
                    // made our own rect rebuild alternate hover on/off once
                    // per rendered frame (95 pushes for one two-event move).
                    if event.type == .cursorUpdate {
                        guard event.window === self.window else { return false }
                        return self.handleLinkCursorEvent(.cursorUpdate,
                                                          timestamp: event.timestamp)
                    }
                    guard event.window === self.window else {
                        self.clearLinkHover()
                        return false
                    }
                    let point = self.convert(event.locationInWindow, from: nil)
                    self.updateLink(at: point,
                                    commandDown: event.modifierFlags.contains(.command),
                                    timestamp: event.timestamp)
                    // AppKit still applies SwiftTerm's whole-view I-beam after
                    // the local monitor returns. The deferred hand above is
                    // deliberately last; every non-link and non-Command move
                    // keeps the old route.
                    if event.type == .mouseMoved {
                        return self.handleLinkCursorEvent(.mouseMoved,
                                                          timestamp: event.timestamp)
                    }
                    return false
                }
                return consumeLinkEvent ? nil : event
            }
        }
    }

    /// While the GPU has the pane, the engine is never asked to repaint.
    ///
    /// `draw(_:)` cannot be overridden here — SwiftTerm declares it `public`
    /// rather than `open`, so it is sealed outside its own module — but the
    /// request to redraw can be. Refusing it is better than intercepting the
    /// drawing anyway: CoreText is never entered at all, which is the CPU that
    /// ISC-37 is about, and the moment the flag goes back the very next
    /// invalidation paints the pane the old way (ISC-24).
    /// Called instead of repainting, whenever the engine wanted a repaint.
    /// Every reason the engine has to redraw — output, a scroll, a selection,
    /// a cursor move, a resize — arrives here, so the GPU renderer needs no
    /// list of events to subscribe to and cannot miss one that gets added
    /// later.
    var onNeedsRedraw: (() -> Void)?

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            guard gpuIsDrawing else {
                super.needsDisplay = newValue
                return
            }
            if newValue { onNeedsRedraw?() }
            super.needsDisplay = false
        }
    }

    /// The other door AppKit has for the same request, and the one the engine
    /// uses after a SCROLL (`scrollTo` ends in `setNeedsDisplay(frame)`, and
    /// `updateDisplay` invalidates a region the same way). Measured 30/08 with
    /// 120 trackpad events in a second: the grid moved 22 rows and the GPU
    /// drew zero frames, so the scroll only showed up with the next byte the
    /// program happened to write. Both doors now lead to the same place.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard gpuIsDrawing else {
            super.setNeedsDisplay(invalidRect)
            return
        }
        onNeedsRedraw?()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        onBytes?(slice)
        tap.consume(slice,
                    feed: { [weak self] bytes in self?.feed(byteArray: bytes) },
                    sequence: { [weak self] sequence in self?.onSequence?(sequence) })
    }
}

@MainActor
public final class SwiftTermSession: NSObject, TerminalBackend {
    private let view: TappedTerminalView
    private let gridAdapter: SwiftTermGrid
    /// Where a composed message and its Return are written, one after the
    /// other and in order. One per session, so a slow child cannot hold up
    /// another pane.
    private let composeQueue = DispatchQueue(label: "t4a.compose")

    public var surface: NSView { view }
    public var grid: TerminalGrid { gridAdapter }
    public var linkHover: TerminalLinkHover? { view.linkHover }
    public var linkCursorTrace: TerminalLinkCursorTrace { view.linkCursorTrace }
    public var onOpenLink: ((TerminalLink) -> Void)? {
        get { view.onOpenLink }
        set { view.onOpenLink = newValue }
    }

    public var cellHeight: CGFloat {
        let rows = max(1, view.terminal.rows)
        return view.getOptimalFrameSize().height / CGFloat(rows)
    }
    public var onEvent: ((TerminalEvent) -> Void)?
    public private(set) var exitCode: Int32?
    private var cloexecMarked = 0

    public var scrollbackLimit: Int {
        get { view.terminal.buffer.totalLinesTrimmed >= 0 ? storedScrollback : storedScrollback }
        set {
            storedScrollback = newValue
            view.terminal.buffer.changeHistorySize(newValue)
        }
    }
    private var storedScrollback: Int

    public init(columns: Int = 80, rows: Int = 25, scrollback: Int = 10_000,
                font: NSFont? = nil, useGPU: Bool = true) {
        var options = TerminalOptions.default
        options.cols = columns
        options.rows = rows
        options.scrollback = scrollback
        options.termName = "xterm-256color"
        // The 256-colour cube is xterm's, which is what every program that
        // prints `ESC[38;5;208m` means by 208. SwiftTerm's own default is a
        // Lab-harmonised palette derived from the sixteen base colours: a
        // defensible choice for a widget, wrong for a terminal that says
        // `xterm-256color` in TERM. Found by the fidelity bench on 2026-08-20
        // — the GPU renderer drew the standard cube, the engine drew its own,
        // and twenty-four colour blocks came out visibly different.
        options.ansi256PaletteStrategy = .xterm
        storedScrollback = scrollback
        view = TappedTerminalView(frame: .zero, font: font, options: options)
        // Option is this keyboard's compose layer, not Meta.
        //
        // SwiftTerm ships `optionAsMetaKey = true`, which turns Option into an
        // ESC prefix. On the Italian layout that makes `@ # [ ] { }` impossible
        // to type, because every one of them lives on Option: measured on
        // 2026-08-24, Option+ò sent `ESC ò` instead of `@`, and the same key
        // typed `@` fine in every other field of the app. The engine already
        // knows how to compose when the flag is off — it sends the composed
        // glyph straight through, the AltGr path — so this is one line, not a
        // special case. The cost is Meta word-motion, put back explicitly for
        // Option+arrows and Option+delete in `MainWindowController`.
        view.optionAsMetaKey = false
        gridAdapter = SwiftTermGrid(terminal: view.terminal)
        super.init()
        view.processDelegate = self
        view.onSequence = { [weak self] sequence in self?.handle(sequence) }
        view.onBytes = { [weak self] _ in
            self?.onEvent?(.outputArrived)
            self?.metalView?.markDirty()
        }
        // Selection and cursor visibility live on the view, not in the buffer,
        // so the grid asks for them rather than holding a stale copy.
        gridAdapter.selectionProvider = { [weak self] in self?.selectionSpan }
        gridAdapter.cursorVisibleProvider = { [weak self] in self?.isCursorVisible ?? true }
        view.resolveLink = { [weak self] point in self?.resolveLink(at: point) }
        view.onLinkHoverChanged = { [weak self] hover in
            self?.metalView?.linkHighlight = hover?.span
        }
        if useGPU { installMetalRenderer() }
        installClipboardPolicy()
    }

    /// Nobody reads the clipboard through the terminal. Ever.
    ///
    /// `OSC 52` has a query form: a program prints `ESC ] 52 ; c ; ? ST` and
    /// the terminal replies with the clipboard, base64, **as input** — as if
    /// the user had typed it. SwiftTerm's own default refuses, and its
    /// documentation says to prompt first, but the concrete Mac view T4A is
    /// built on answers it from `NSPasteboard` with no prompt at all.
    /// Measured inside the running app on 2026-08-20: one `printf` from an
    /// ordinary shell put 468 base64 characters of the real clipboard onto
    /// the command line.
    ///
    /// The attack needs no code execution, only text on the screen: a `cat`
    /// of a downloaded file, an SSH banner, the output of a `curl`, a build
    /// log. Clipboards hold passwords and tokens. xterm ships this read
    /// disabled and iTerm2 asks.
    ///
    /// The repair goes here and not in a delegate method, because the
    /// delegate that answers is the library's own concrete class and its
    /// method is `public`, not `open` — sealed outside its module. Taking
    /// the code over with a handler is the door the library does leave open,
    /// and it is the right one: the behaviour T4A wants for a read is no
    /// behaviour. Writing IS still allowed — a `yank` over ssh into your
    /// clipboard is the reason anyone implemented OSC 52 — and that choice
    /// is written down where it is made, so it can be changed.
    private func installClipboardPolicy() {
        view.terminal.registerOscHandler(code: 52) { [weak self] payload in
            guard let self else { return }
            let text = String(decoding: payload, as: UTF8.self)
            let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            let data = String(parts[1])
            guard data != "?" else {
                NSLog("T4A: refused an OSC 52 clipboard read")
                self.clipboardReadsRefused += 1
                return
            }
            guard let decoded = Data(base64Encoded: data),
                  let string = String(data: decoded, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }

    /// How many times a program asked for the clipboard and was told nothing.
    /// Counted so the refusal can be measured rather than assumed.
    public private(set) var clipboardReadsRefused = 0

    // MARK: - The GPU renderer

    private var metalView: TerminalMetalView?
    public var renderer: TerminalRenderer? { metalView }

    /// SwiftTerm's own caret, found by class name.
    ///
    /// Its colour is set to nothing so it never draws — the GPU cursor is the
    /// one on screen — but it is deliberately NOT hidden, because the engine
    /// hides it exactly when the program hides the cursor, and that flag is
    /// the only readable signal of DECTCEM from outside the library.
    private var caretView: NSView? {
        view.subviews.first {
            String(describing: type(of: $0)).contains("Caret")
        }
    }
    private var isCursorVisible: Bool { !(caretView?.isHidden ?? false) }

    private func installMetalRenderer() {
        guard let metal = TerminalMetalView(font: view.font, palette: palette) else {
            NSLog("T4A: no Metal device; the pane stays on the CPU renderer")
            return
        }
        metal.source = gridAdapter
        metal.translatesAutoresizingMaskIntoConstraints = false
        // Above the engine's own drawing, below the caret and the find bar:
        // the GPU paints the grid, AppKit keeps the furniture.
        view.addSubview(metal, positioned: .below, relativeTo: caretView)
        NSLayoutConstraint.activate([
            metal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metal.topAnchor.constraint(equalTo: view.topAnchor),
            metal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        metalView = metal
        view.onNeedsRedraw = { [weak metal] in metal?.markDirty() }
        view.scrollCellHeight = { [weak self] in self?.cellHeight ?? 0 }
        view.canPixelScroll = { [weak self] delta in self?.canPixelScroll(delta: delta) ?? false }
        view.onScrollLines = { [weak self] lines in self?.scrollFromWheel(lines: lines) ?? 0 }
        view.onScrollOffset = { [weak metal] offset in metal?.scrollOffset = offset }
        view.onScrollSettle = { [weak metal] in metal?.settleScrollOffset() }
        view.onScrollReset = { [weak metal] in metal?.resetScrollOffset() }
        view.onWheelEvent = { [weak metal] seconds in metal?.noteWheelEvent(seconds) }
        view.gpuIsDrawing = true
        view.caretColor = .clear
        view.caretTextColor = .clear
    }

    /// Maps the drawn cell under a Command-hover to one logical line. The
    /// detector receives only that soft-wrapped run, never the whole grid.
    private func resolveLink(at point: NSPoint) -> TerminalLinkHover? {
        let columns = gridAdapter.columns
        let rows = gridAdapter.rows
        guard columns > 0, rows > 0, view.bounds.contains(point) else { return nil }
        let width = metalView?.cellWidth ?? view.bounds.width / CGFloat(columns)
        let height = metalView?.cellHeight ?? cellHeight
        guard width > 0, height > 0 else { return nil }

        let scrollOffset = metalView?.scrollOffset ?? 0
        let screenRow = Int(floor((view.bounds.height - point.y + scrollOffset) / height))
        let column = Int(floor(point.x / width))
        guard screenRow >= 0, screenRow < rows, column >= 0, column < columns else { return nil }

        let top = gridAdapter.topVisibleRow
        let folds = self.folds
        let entry = folds.isEmpty
            ? FoldedRow.line(top + screenRow)
            : folds.rows(from: top, count: rows + 1)[screenRow]
        guard case .line(let hoveredRow) = entry,
              gridAdapter.line(at: hoveredRow) != nil else { return nil }

        var first = hoveredRow
        while first > gridAdapter.firstRetainedRow,
              gridAdapter.line(at: first)?.isWrapped == true {
            first -= 1
        }
        var last = hoveredRow
        while last + 1 < gridAdapter.endRow,
              gridAdapter.line(at: last + 1)?.isWrapped == true {
            last += 1
        }
        var logical: [GridLine] = []
        logical.reserveCapacity(last - first + 1)
        for row in first...last {
            guard let line = gridAdapter.line(at: row) else { return nil }
            logical.append(line)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // The foreground process is what printed the text (claude, a build),
        // so its directory is what its relative paths mean; the shell's is
        // the fallback. Read at hover time, under Command only.
        let cwd = (foregroundWorkingDirectory() ?? currentWorkingDirectory())?.path
        guard let relative = TerminalLinkDetector.detect(
            in: logical,
            hovered: GridPosition(column: column, row: hoveredRow - first),
            homeDirectory: home,
            workingDirectory: cwd,
            inspectPath: Self.inspectPath)
        else { return nil }

        let span = GridSpan(
            start: GridPosition(column: relative.span.start.column,
                                row: relative.span.start.row + first),
            end: GridPosition(column: relative.span.end.column,
                              row: relative.span.end.row + first))
        let walk = folds.isEmpty ? [] : folds.rows(from: top, count: rows + 1)
        var rects: [CGRect] = []
        for row in span.start.row...span.end.row {
            guard let range = span.columns(on: row, width: columns) else { continue }
            let visual: Int?
            if walk.isEmpty {
                visual = row - top
            } else {
                visual = walk.firstIndex(where: {
                    if case .line(let candidate) = $0 { return candidate == row }
                    return false
                })
            }
            guard let visual, visual >= 0, visual <= rows else { continue }
            let rect = CGRect(x: CGFloat(range.lowerBound) * width,
                              y: view.bounds.height - CGFloat(visual + 1) * height + scrollOffset,
                              width: CGFloat(range.count) * width, height: height)
                .intersection(view.bounds)
            if !rect.isNull, !rect.isEmpty { rects.append(rect) }
        }
        guard !rects.isEmpty else { return nil }
        return TerminalLinkHover(link: relative.link, span: span, rects: rects)
    }

    private static func inspectPath(_ path: String) -> TerminalLinkKind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? .directory : .file
    }

    /// Hands the pane back to the engine's CPU renderer, or takes it again.
    /// ISC-24 is this method being callable at any moment, including in the
    /// middle of a run.
    public func setGPURenderer(_ enabled: Bool) {
        if enabled {
            if metalView == nil { installMetalRenderer() }
            metalView?.isHidden = false
            metalView?.markDirty()
            view.gpuIsDrawing = metalView != nil
            view.caretColor = .clear
            view.caretTextColor = .clear
        } else {
            view.resetPreciseScroll()
            metalView?.isHidden = true
            view.gpuIsDrawing = false
            view.caretColor = NSColor.white
            view.caretTextColor = nil
        }
        view.needsDisplay = true
    }

    /// The theme in force, when the app has given the grid one (ISC-33).
    /// Nil is the engine's own colours, which is what a build with no window
    /// around it draws.
    private var theme: TerminalTheme?

    /// The engine's own colours, handed on so both renderers draw the same
    /// blue. The sixteen named colours are the ones SwiftTerm installs; the
    /// other 240 are the xterm cube, computed in one place. Where the app's
    /// theme has an opinion, the theme wins.
    public var palette: TerminalPalette {
        let base = (theme?.ansi ?? Color.terminalAppColors.map { colour -> NSColor in
            NSColor(srgbRed: CGFloat(colour.red) / 65535,
                    green: CGFloat(colour.green) / 65535,
                    blue: CGFloat(colour.blue) / 65535, alpha: 1)
        })
        let background = theme?.background ?? view.nativeBackgroundColor
        return TerminalPalette(
            foreground: theme?.foreground ?? view.nativeForegroundColor,
            background: background,
            cursor: theme?.cursor ?? NSColor(white: 0.85, alpha: 1),
            cursorText: background,
            selection: theme?.selection ?? view.selectedTextBackgroundColor,
            link: theme?.link ?? view.nativeForegroundColor,
            linkHighlight: theme?.linkHighlight ?? view.selectedTextBackgroundColor,
            highlight: NSColor(srgbRed: 0.42, green: 0.36, blue: 0.10, alpha: 1),
            currentHighlight: NSColor(srgbRed: 0.85, green: 0.66, blue: 0.16, alpha: 1),
            ansi: TerminalPalette.complete(base: base))
    }

    /// Takes the app's theme and repaints, without a relaunch (ISC-33).
    ///
    /// Both renderers are told, because either one can be the one on screen:
    /// the engine's own drawing reads `nativeBackgroundColor`, the GPU reads
    /// the palette, and a theme that only reached one of them would appear to
    /// work until somebody flipped the renderer.
    public func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        view.nativeBackgroundColor = theme.background
        view.nativeForegroundColor = theme.foreground
        view.installColors(theme.ansi.map { colours in
            colours.map { colour -> Color in
                let srgb = colour.usingColorSpace(.sRGB) ?? colour
                return Color(red: UInt16(srgb.redComponent * 65535),
                             green: UInt16(srgb.greenComponent * 65535),
                             blue: UInt16(srgb.blueComponent * 65535))
            }
        } ?? Color.terminalAppColors)
        metalView?.palette = palette
        view.needsDisplay = true
    }

    /// The selection, translated from the engine's buffer rows into the
    /// scroll-invariant rows everything above this file speaks.
    private var selectionSpan: GridSpan? {
        guard let selection = view.selection, selection.active else { return nil }
        let trimmed = view.terminal.buffer.totalLinesTrimmed
        return GridSpan(
            start: GridPosition(column: selection.start.col, row: selection.start.row + trimmed),
            end: GridPosition(column: selection.end.col, row: selection.end.row + trimmed))
    }

    public func scroll(lines: Int) {
        view.resetPreciseScroll()
        if lines > 0 { view.scrollUp(lines: lines) } else if lines < 0 {
            view.scrollDown(lines: -lines)
        }
        settleViewport(direction: lines >= 0 ? 1 : -1)
        metalView?.markDirty()
    }

    /// Moves only the integral part of a precise wheel event and reports how
    /// much SwiftTerm actually accepted, so the renderer never exposes a row
    /// beyond either end of scrollback.
    private func scrollFromWheel(lines: Int) -> Int {
        let before = gridAdapter.topVisibleRow
        let scrollStarted = CACurrentMediaTime()
        if lines > 0 { view.scrollUp(lines: lines) }
        else if lines < 0 { view.scrollDown(lines: -lines) }
        metalView?.noteWheelScrollTo(CACurrentMediaTime() - scrollStarted)
        let settleStarted = CACurrentMediaTime()
        settleViewport(direction: lines >= 0 ? 1 : -1)
        metalView?.noteWheelSettle(CACurrentMediaTime() - settleStarted)
        let change = before - gridAdapter.topVisibleRow
        metalView?.markDirty()
        if lines > 0 { return min(lines, max(0, change)) }
        if lines < 0 { return max(lines, min(0, change)) }
        return 0
    }

    private func canPixelScroll(delta: CGFloat) -> Bool {
        let top = gridAdapter.topVisibleRow
        if delta > 0 { return top > gridAdapter.firstRetainedRow }
        if delta < 0 { return top < gridAdapter.liveScreenTopRow }
        return false
    }

    /// The folds in force. Empty on the CPU fallback, which draws through
    /// SwiftTerm's own view and has no row walk of ours to bend — the compact
    /// view is a thing the GPU renderer can do and the fallback cannot, and it
    /// says so here rather than pretending.
    public var folds: RowFold { metalView?.folds ?? RowFold() }

    /// Folds runs of history away.
    ///
    /// The clipping against the live screen happens HERE, where the live
    /// screen is known exactly, rather than in the caller, where it would be
    /// a second derivation of a number this object already holds.
    public func setFolds(_ ranges: [ClosedRange<Int>]) {
        let fold = RowFold(ranges, liveScreenTopRow: gridAdapter.liveScreenTopRow)
        guard metalView?.folds != fold else { return }
        metalView?.folds = fold
        metalView?.invalidateRowCache()
        settleViewport(direction: 1)
        metalView?.markDirty()
    }

    /// Never leave the top of the viewport inside something that is folded:
    /// the screen would not change as you scrolled through it, and a scroll
    /// that does nothing looks exactly like a terminal that has stopped.
    private func settleViewport(direction: Int) {
        guard let fold = metalView?.folds, !fold.isEmpty else { return }
        let top = gridAdapter.topVisibleRow
        let settled = fold.settle(top, direction: direction)
        guard settled != top else { return }
        reveal(row: settled)
    }

    public func reveal(row: Int) {
        view.scrollTo(row: max(0, row - view.terminal.buffer.totalLinesTrimmed))
        metalView?.markDirty()
    }

    // MARK: - Lifecycle

    /// Sweeps immediately before the fork so descriptors opened by frameworks
    /// (Metal's shader cache was the measured example) cannot cross the exec.
    /// The returned pty master is marked immediately after too: `forkpty`
    /// closes this pane's own master in its child, while later panes would
    /// otherwise inherit it from T4A.
    public func start(_ launch: TerminalLaunch) {
        var environment = ProcessInfo.processInfo.environment
        Self.scrubInheritedSession(&environment)
        for (key, value) in launch.environment { environment[key] = value }
        // The child gets TERM from the terminal it is actually running in.
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        let flattened = environment.map { "\($0.key)=\($0.value)" }

        // argv[0] with a leading dash is the POSIX way to say "login shell",
        // and it is what makes the shell read the user's own profile.
        let name = (launch.executable as NSString).lastPathComponent
        cloexecMarked = DescriptorHygiene.markCloseOnExec()
        view.startProcess(executable: launch.executable,
                          args: launch.arguments,
                          environment: flattened,
                          execName: launch.argv0 ?? "-\(name)",
                          currentDirectory: launch.workingDirectory.path)
        let master = view.process.childfd
        if master >= 0 { DescriptorHygiene.markCloseOnExec(master) }
    }

    /// What the byte tap has seen. Diagnosis only: a claim about blocks is
    /// made on the blocks, and this says which half is at fault when there
    /// are none.
    public var diagnostics: [String: String] {
        var result = ["engine": "SwiftTerm",
                      "tapState": view.tap.stateName,
                      "bytes": String(view.tap.bytesSeen),
                      "cloexecMarked": String(cloexecMarked),
                      "mouseMode": String(describing: view.terminal.mouseMode)]
        for (code, count) in view.tap.sequencesSeen { result["osc\(code)"] = String(count) }
        return result
    }

    /// Removes the variables that describe the session of whatever launched
    /// T4A, rather than the user's own shell.
    ///
    /// A terminal opened from another program inherits that program's
    /// environment, and some of those variables mean "you are already inside
    /// me". Measured on 2026-08-20: T4A started from a Claude Code session
    /// handed `CLAUDECODE=1` to every shell it opened, so running `claude`
    /// inside T4A refused to start, reporting a nested session — a fault of
    /// the terminal, in a program the terminal exists to host.
    static func scrubInheritedSession(_ environment: inout [String: String]) {
        let exact = [
            "TERM_SESSION_ID", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
            "CLAUDECODE", "CLAUDE_PID", "CODEX_SANDBOX", "CURSOR_TRACE_ID",
        ]
        let prefixes = ["CLAUDE_CODE_", "ITERM_", "__CFBundleIdentifier"]
        for key in environment.keys where exact.contains(key)
            || prefixes.contains(where: { key.hasPrefix($0) }) {
            environment.removeValue(forKey: key)
        }
    }

    public var font: NSFont {
        get { view.font }
        set {
            view.font = newValue
            metalView?.font = newValue
        }
    }

    /// SwiftTerm's own reset drops the alternate buffer, the scrollback and
    /// the screen together, then the view is told to lay out again. The child
    /// keeps running: nothing is sent down the pty.
    public func clearBuffer() {
        view.resetPreciseScroll()
        // The row numbering starts again, so anything the renderer remembers
        // about a row number is about a different row now.
        metalView?.invalidateRowCache()
        view.terminal.resetToInitialState()
        view.terminal.updateFullScreen()
        view.needsDisplay = true
    }

    public func send(text: String) { inFondo(); view.send(txt: text) }

    /// Scrivere riporta in fondo, come ogni terminale.
    ///
    /// Suo, 27/08: «se sono in cima all'output e invio qualcosa, lo schermo
    /// deve tornare in basso». SwiftTerm mette in pausa lo scorrimento
    /// automatico appena l'utente sale (`userScrolling`), e quella pausa non
    /// finiva mai da sé: l'output nuovo arrivava in fondo, fuori dallo
    /// schermo, e sembrava che il comando non avesse fatto niente. Il momento
    /// giusto è la scrittura, non l'arrivo dell'output: è lì che hai deciso di
    /// tornare a lavorare invece che a leggere.
    private func inFondo() {
        guard view.canScroll else { return }
        view.resetPreciseScroll()
        view.scroll(toPosition: 1)
        metalView?.markDirty()
    }

    /// Whether the program on the other side asked for bracketed paste.
    public var acceptsBracketedPaste: Bool { view.terminal.bracketedPasteMode }

    /// One message, one ordered stream of bytes (ISC-166).
    ///
    /// Written straight to the pty on a serial queue of ours rather than
    /// through `LocalProcess.send`, for one reason: that path hands every call
    /// to a fresh `DispatchIO` channel on a concurrent queue, so a long
    /// message still being drained and a Return issued behind it are two
    /// writers on one descriptor. A 5 KB message does not fit the tty buffer,
    /// so it IS still being drained — the Return could land inside the text.
    /// Here the message and its Return are one serial queue, in order, and the
    /// Return waits for the last byte of the message to have left.
    public func compose(payloads texts: [String], submitAfter: TimeInterval?) {
        let bracketed = view.terminal.bracketedPasteMode
        let payloads = PasteFraming.payloads(for: texts, bracketed: bracketed)
        guard !payloads.isEmpty else { return }
        let fd = view.process.childfd
        guard fd >= 0 else { return }
        let queue = composeQueue
        queue.async {
            var written = true
            for payload in payloads where written {
                written = PtyWriter.writeAll(payload, to: fd)
            }
            // L'anello PRIMA dell'uscita anticipata: una scrittura fallita è
            // il caso che più merita di lasciare una traccia (ISC-195).
            ComposeLog.record(text: texts.joined(), bytes: payloads.reduce(0) { $0 + $1.count },
                              bracketed: bracketed, written: written)
            guard written else { return }
            guard let submitAfter else { return }
            if submitAfter > 0 { usleep(useconds_t(submitAfter * 1_000_000)) }
            _ = PtyWriter.writeAll(PasteFraming.submit, to: fd)
        }
    }


    @discardableResult
    public func acceptDrop(from board: NSPasteboard) -> Bool { view.acceptDrop(from: board) }
    public var registeredDropTypes: [String] { view.registeredDraggedTypes.map(\.rawValue) }
    public func send(bytes: [UInt8]) { inFondo(); view.send(data: bytes[...]) }

    public func terminate() { view.terminate() }
    public func focus() { view.window?.makeFirstResponder(view) }

    // MARK: - Reading the child

    public func currentWorkingDirectory() -> URL? {
        if let reported = reportedDirectory { return reported }
        let pid = view.process.shellPid
        guard pid > 0 else { return nil }
        return Self.kernelWorkingDirectory(of: pid)
    }

    public func foregroundWorkingDirectory() -> URL? {
        guard let pid = foregroundProcessID else { return nil }
        return Self.kernelWorkingDirectory(of: pid)
    }

    public func workingDirectory(ofProcess pid: Int32) -> URL? {
        Self.kernelWorkingDirectory(of: pid)
    }

    public func foregroundProcesses() -> [ForegroundProcess] {
        guard let leader = foregroundProcessID else { return [] }
        var out: [ForegroundProcess] = []
        var frontier = [leader]
        // Two hops cover every launcher seen so far (`bun → claude`,
        // `sh → bun → claude`); a cap keeps a fork bomb from becoming ours.
        for _ in 0..<3 where !frontier.isEmpty && out.count < 12 {
            var next: [Int32] = []
            for pid in frontier {
                guard let name = Self.processName(of: pid) else { continue }
                out.append(ForegroundProcess(pid: pid, name: name,
                                             commandLine: Self.commandLine(of: pid)))
                next.append(contentsOf: Self.children(of: pid))
            }
            frontier = next
        }
        return out
    }

    private static func processName(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard read == Int32(size) else { return nil }
        let name = withUnsafePointer(to: &info.pbi_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                      capacity: Int(MAXCOMLEN * 2)) { String(cString: $0) }
        }
        return name.isEmpty ? nil : name
    }

    /// The argv a process was started with, from the kernel, first words only.
    private static func commandLine(of pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        var arguments: [String] = []
        var current: [UInt8] = []
        while index < size, arguments.count < min(Int(argc), 6) {
            let byte = buffer[index]
            if byte == 0 {
                arguments.append(String(decoding: current, as: UTF8.self))
                current.removeAll()
            } else {
                current.append(byte)
            }
            index += 1
        }
        return String(arguments.joined(separator: " ").prefix(300))
    }

    private static func children(of pid: Int32) -> [Int32] {
        let capacity = 64
        var pids = [Int32](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid),
                          buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<Int32>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private static func kernelWorkingDirectory(of pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size) else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                      capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// The name of the process in the foreground of the child's terminal
    /// group — `vim` while vim is up, the shell otherwise.
    public func foregroundProcessName() -> String? {
        guard let pid = foregroundProcessID else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard read == Int32(size) else { return nil }
        let name = withUnsafePointer(to: &info.pbi_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                      capacity: Int(MAXCOMLEN * 2)) { String(cString: $0) }
        }
        return name.isEmpty ? nil : name
    }

    /// The leader of the terminal's foreground process group.
    public var foregroundProcessID: Int32? {
        let fd = view.process.childfd
        guard fd >= 0 else { return nil }
        let group = tcgetpgrp(fd)
        return group > 0 ? group : nil
    }

    private var reportedDirectory: URL?

    // MARK: - Selection

    public var selectedText: String? {
        let text = view.getSelection()
        return (text?.isEmpty == false) ? text : nil
    }

    public var onDropPaths: (([String]) -> Bool)? {
        get { view.onDropPaths }
        set { view.onDropPaths = newValue }
    }

    public var onSelectionFinished: ((String) -> Void)? {
        get { view.onSelection }
        set { view.onSelection = newValue }
    }

    public func selectAll() { view.selectAll(nil) }
    public func clearSelection() { view.selectNone() }

    // MARK: - OSC

    private func handle(_ sequence: OSCSequence) {
        switch sequence.code {
        case 133:
            handleSemanticPrompt(sequence.payload)
        case 633:
            // The command line, announced separately from the structure. Held
            // until the next `C` claims it.
            if let command = SemanticPromptWire.announcedCommand(sequence) {
                announcedCommand = command
                onEvent?(.commandLineAnnounced(command))
            }
        case 9:
            // OSC 9 carries two different things. `9;4;…` is a progress
            // report (ConEmu's), which is not a notification; anything else
            // is the growl-style message iTerm2 popularised.
            let fields = sequence.fields
            if fields.first == "4" { return }
            let body = sequence.payload
            guard !body.isEmpty else { return }
            onEvent?(.notification(title: "", body: body))
        case 777:
            // ESC ] 777 ; notify ; title ; body
            let fields = sequence.fields
            guard fields.count >= 3, fields[0] == "notify" else { return }
            onEvent?(.notification(title: fields[1],
                                   body: fields[2...].joined(separator: ";")))
        default:
            break
        }
    }

    private var announcedCommand: String?

    private func handleSemanticPrompt(_ payload: String) {
        guard let action = SemanticPromptWire.parse(payload) else { return }
        // The cursor is read AFTER the sequence has gone through the engine,
        // so the row is where the engine actually put it — including the
        // fresh-line an `A` performs.
        let row = gridAdapter.cursor.row
        switch action.letter {
        case "A", "N":
            announcedCommand = nil
            onEvent?(.promptStarted(row: row))
        case "C":
            let command = SemanticPromptWire.command(from: action.options)
                ?? announcedCommand ?? ""
            announcedCommand = nil
            onEvent?(.commandStarted(row: row, command: command))
        case "D":
            onEvent?(.commandFinished(row: row,
                                      exitCode: SemanticPromptWire.exitCode(from: action)))
        default:
            break
        }
    }
}

// MARK: - Process delegate

extension SwiftTermSession: @preconcurrency LocalProcessTerminalViewDelegate {

    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // A reflow rewrites history: the same row number holds different text.
        metalView?.invalidateRowCache()
        onEvent?(.sizeChanged(columns: newCols, rows: newRows))
    }

    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onEvent?(.title(title))
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory) ?? URL(string: "file://" + directory)
        else { return }
        reportedDirectory = URL(fileURLWithPath: url.path)
        onEvent?(.workingDirectory(URL(fileURLWithPath: url.path)))
    }

    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        self.exitCode = exitCode ?? 0
        onEvent?(.processExited(code: exitCode))
    }
}
