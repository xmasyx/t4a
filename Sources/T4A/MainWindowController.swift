//  MainWindowController.swift — the window: tabs, splits, and the chrome
//  around them.

import AgentAdapters
import AppKit
import TerminalCore

@MainActor
final class Tab {
    let id = UUID()
    let tree: SplitTree
    var activePane: PaneView
    var container: NSView?

    init(pane: PaneView) {
        tree = SplitTree(root: pane)
        activePane = pane
    }

    var panes: [PaneView] { tree.panes }
    var sessions: [Session] { panes.map(\.session) }
}

enum DoorCloseResult {
    case closed
    case working
    case unknown
    case last
}

@MainActor
final class MainWindowController: NSWindowController, PaneViewDelegate {
    private enum BenchPalette {
        static let sessions = "sessions"
        static let themes = "themes"
        static let actions = "actions"
        static let newTab = "New Tab"
        static let splitRight = "Split Right"
        static let splitDown = "Split Down"
        static let closePane = "Close Pane"
        static let clearBuffer = "Clear Buffer"
        static let find = "Find…"
        static let settings = "Settings…"
        static let commandMap = "Command Map"
        static let dashboardBar = "Dashboard Bar"
        static let preview = "Preview"
        static let previewInFront = "Preview in Front"
        static let sessionsAsTabsOrRail = "Sessions as Tabs / Rail"
        static let bigger = "Bigger"
        static let smaller = "Smaller"
        static let actualSize = "Actual Size"
        static let openConfigurationFile = "Open configuration file"
    }

    private let config: Configuration
    private let integrationRoot: URL?

    private var tabs: [Tab] = []
    private var activeTabIndex = 0
    private var activeTab: Tab? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }
    /// Commands waiting for the first prompt of a pane opened by the door.
    /// The UUID is the target so switching tabs during startup cannot send a
    /// command to the pane the person moved to.
    private var pendingDoorCommands: [UUID: String] = [:]

    /// Meta motion, kept by hand now that Option is the compose layer.
    private var optionMotionMonitor: Any?
    private var escapeMonitor: Any?

    private let band = BandView()
    /// The chooser opened by «N waiting». It covers the window only while
    /// open so an outside click dismisses it like a menu, without ever taking
    /// the first responder from the composer or terminal.
    private let waitingMenu = WaitingMenuView()
    /// The layout button, in both of its homes. Only one is on screen at a
    /// time, and they are driven together so they can never disagree.
    private var layoutToggles: [PanelToggleButton] { [rail.layoutButton, tabStrip.layoutButton] }
    private let tabStrip = TabStripView()
    private let rail = RailView()
    private let stage = NSView()
    private let terminalHost = NSView()
    /// The «+» at the far right of every pane: a split without the shortcut
    /// (his ask, 25/08). One pane → at its right edge; more panes → at the
    /// right of the LAST one, because the host's trailing edge IS that.
    private(set) lazy var splitButton: ChromeButton = {
        let button = ChromeButton(title: "+") { [weak self] in self?.splitVertically() }
        button.toolTip = S.splitRightTooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let inspector = InspectorView()
    private let dash = DashView()
    /// The card that appears when the agent in the front pane asks for
    /// something (ISC-29), and the line that types into it (ISC-42).
    private let card = ApprovalCard()
    private let composer = ComposerView()
    /// L'elenco dei comandi `/` sopra la bolla, e il catalogo che lo riempie
    /// (ISC-187). Il catalogo è UNO per finestra e guarda il pannello attivo:
    /// cambiare pannello lo rifà, che con la cache della scansione costa mezzo
    /// millisecondo.
    private let slashList = SlashListView()
    private let queuedView = QueuedView()
    private var queuedHeight: NSLayoutConstraint!
    /// Il rifiuto occupa lo stesso posto della ricevuta ma resta una vista
    /// distinta: `queued.visible` deve continuare a significare solo coda.
    private let refusalView = QueuedView()
    private var refusalHeight: NSLayoutConstraint!
    /// Una sola sorgente per testo, dump e cancellazione automatica (ISC-228).
    private var rifiutoComposer = ""
    private let slashCatalog = SlashCommandCatalog()
    /// Chi il catalogo sta già seguendo — fornitore, binario, cartella. Senza
    /// questa firma `refresh()` lo rifarebbe a ogni giro della finestra.
    private var catalogoSeguito: [String]?
    /// Il catalogo è stato puntato a mano dal canale di prova, quindi non
    /// segue più l'agente. Esiste perché un banco possa misurare la BOLLA
    /// senza far girare claude.
    private var catalogoForzato = false
    /// L'elenco è stato chiuso da un tasto e non si riapre da solo. Serve a
    /// Esc, che chiude tenendo il testo: senza questo il primo `refresh()`
    /// successivo lo rimetterebbe su, perché il testo dice ancora `/c`.
    private var elencoScartato = false
    /// The seams between the terminal and the two panels. They are views, not
    /// gestures bolted to the panels, so a drag has something to hit even
    /// where the panel it resizes is one pixel away (ISC-104.4).
    private let railGrip = GripView()
    private let inspectorGrip = GripView()
    /// L'anteprima di un file scritto dall'agente (ISC-176). Una sola, e sta
    /// nel pannello destro oppure dentro il velo, mai due copie.
    private let previewSurface = PreviewSurface()
    private let previewFront = PreviewFrontView()
    /// ⌘K (ISC-32). It lives over the whole content view, not over the
    /// terminal: it lists sessions from every tab, so it is not a thing that
    /// belongs to one pane.
    private let commandPalette = CommandPaletteView()
    private let turnReader = TurnReaderView()
    /// La conversazione disegnata da noi, sopra il terminale (ISC-169).
    private let chatPage = ChatPageView()
    /// Una pagina che cambia visibilità di continuo sta seguendo i burst
    /// invece dello stato: ISC-227 rende quel difetto misurabile.
    private var pageFlips = 0
    /// When a synthesized press opened the palette, the moment that press was
    /// made. See `showCommandPalette` for why it cannot be read afterwards.
    private var pendingKeystrokeAt: CFTimeInterval?
    /// The last answer `testHitTest` produced, for the dump.
    var lastHitTest: [String] = []
    /// Which row of the bar sits where, and which are off (ISC-104.1/2/3).
    private(set) var dashLayout = DashLayout()
    /// The user's own program, if they named one (ISC-139). It owns its own
    /// clock and its own thread; this controller only hands it the pane the
    /// keyboard is on and paints what comes back.
    let facts = FactsProvider()
    private var settings: SettingsWindowController?

    private var railWidth: NSLayoutConstraint!
    private var inspectorWidth: NSLayoutConstraint!
    /// Quanto è alta l'anteprima nella colonna: tutta la colonna da aperta,
    /// la sola testa da ridotta — e da ridotta la testa si mette esattamente
    /// dove l'ispettore scrive il suo titolo, quindi sotto ricompare la mappa
    /// dei turni senza che nessuno la sposti (mockup `mock-176-D-ridotta`).
    private var previewHeight: NSLayoutConstraint!
    private var previewBottom: NSLayoutConstraint!
    private var dashHeight: NSLayoutConstraint!
    private var composerHeight: NSLayoutConstraint!
    private var slashListHeight: NSLayoutConstraint!
    private var bandTop: NSLayoutConstraint!
    private var bandHeight: NSLayoutConstraint!
    private var tabStripTop: NSLayoutConstraint!
    private var tabStripHeight: NSLayoutConstraint!
    private var terminalHostTop: NSLayoutConstraint!
    /// The requested state is explicit because `.fullScreen` changes at a
    /// system-owned point between WillEnter and DidEnter.
    private var fullScreenLayoutTarget = false
    private var fullScreenTransition = "windowed"
    private var fullScreenHookLog: [[String: Any]] = []
    private static let fullScreenTopMargin: CGFloat = 7
    private static let fullScreenHeaderHeight = BandView.compactHeight
    private var durationTimer: Timer?
    /// Every notification T4A posted, in order. It exists so ISC-65 can be
    /// checked against what the app DID, not against a banner that has already
    /// faded by the time anything looks.
    private var notificationLog: [[String: String]] = []
#if DEBUG || T4A_TESTABLE
    private var testChannel: TestChannel?
    var testLinkOpenRecord: [String: String]?
#endif

    /// Told when this window goes away, so the app can forget it (⌘N makes
    /// more than one).
    var onWindowClosed: ((MainWindowController) -> Void)?

    private var frameSaveTimer: Timer?
    private var frameSavePending = false
    /// How many times the window changed shape. Against `configWrites` it is
    /// the whole of ISC-106: many changes, one write.
    private var frameChangeCount = 0
    /// How long after the last frame change a window that is NOT being dragged
    /// waits before writing. A programmatic resize gets no mouse-up to hang a
    /// write on, so it settles instead.
    private static let frameSettleDelay: TimeInterval = 0.4

    /// The close confirmation, while it is on screen. Held so the test channel
    /// can answer the same sheet a person answers, rather than a copy of it.
    private var closeConfirmation: (
        alert: NSAlert,
        proceed: () -> Void,
        running: [String],
        subject: S.CloseSubject
    )?

    init(config: Configuration, integrationRoot: URL?) {
        self.config = config
        self.integrationRoot = integrationRoot

        let size = NSSize(width: CGFloat(config.int(.windowWidth)),
                          height: CGFloat(config.int(.windowHeight)))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 420)
        // The band colour is the window's, so the transparent titlebar takes
        // the page's ground rather than a system grey (MacAppRules §0.4).
        window.backgroundColor = Theme.current.ground
        super.init(window: window)

        dashLayout = DashLayout.load(from: config)
        // The ghost's memory, beside the config so it travels with it.
        composer.historyFile = config.url.deletingLastPathComponent()
            .appendingPathComponent("composer-history.txt")
        buildLayout()
        startFacts()
        window.delegate = self
        installOptionMotionMonitor()
        restoreFrame()
        newTab()
    }

    /// ⌥← ⌥→ ⌥⌫ still mean word-motion, now that Option is not Meta.
    ///
    /// `SwiftTermSession` turns `optionAsMetaKey` off so this layout can
    /// compose `@ # [ ] { }` on Option. That same flag was what turned these
    /// three into the Meta sequences a shell expects, and unlike a letter they
    /// carry no glyph on any layout — so they are the part of Meta worth
    /// keeping, and nothing is taken from composition by keeping them. A local
    /// monitor is the only seam there is: SwiftTerm declares `keyDown` public
    /// rather than open, so a subclass cannot take the key first.
    private func installOptionMotionMonitor() {
        optionMotionMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option,
                  // A text view composes on its own: the composer, the palette,
                  // the find field. Only a pane needs the bytes written for it.
                  !(window.firstResponder is NSTextView),
                  let session = self.activeTab?.activePane.session,
                  let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
            else { return event }
            switch Int(scalar.value) {
            case NSLeftArrowFunctionKey:  session.backend.send(bytes: [0x1b, 0x62]); return nil
            case NSRightArrowFunctionKey: session.backend.send(bytes: [0x1b, 0x66]); return nil
            case NSDeleteCharacter:       session.backend.send(bytes: [0x1b, 0x7f]); return nil
            default: return event
            }
        }
    }

    /// Opens the test channel, in a build that HAS one.
    ///
    /// Only the window the app started with gets one, and only when the
    /// environment names a fifo: a second window would read the same pipe and
    /// answer the same commands twice. In a shipped build the body is empty
    /// and the type it would name does not exist (ISC-128).
    func openTestChannel() {
#if DEBUG || T4A_TESTABLE
        testChannel = TestChannel(controller: self)
#endif
    }

    /// Size AND position, from the file, before the window is ever shown.
    ///
    /// `window-frame` is AppKit's own saved-frame string, so a window that was
    /// left on a display that is now unplugged comes back on screen rather
    /// than off the edge of the world. The two old size keys are the
    /// first-launch default and nothing else (ISC-109).
    private func restoreFrame() {
        guard let window else { return }
        let saved = config.string(.windowFrame)
        if !saved.isEmpty {
            window.setFrame(from: saved)
        } else if let half = Self.benchHalfFrame() {
            window.setFrame(half, display: false)
        } else {
            window.center()
        }
    }

    /// The right half of the main screen, for a window a bench opened.
    ///
    /// His request (2026-09-05): while a bench works, his terminal on the
    /// left and the bench's window on the right, so he keeps working. ISC-244
    /// put that inside each bench, and on 2026-09-06 a bench that had not
    /// been taught it opened over his iTerm — 2 of 60 called it. Now the
    /// window places ITSELF: a bench instance is one that carries the test
    /// channel, and only on a first launch (no saved frame, so ISC-109's
    /// memory still wins and `bench-window-memory` still measures it).
    /// `T4A_BENCH_FRAME=free` is the way out for a bench that wants the
    /// centre. Nil in a shipped build: the environment never moves it.
    private static func benchHalfFrame() -> NSRect? {
#if DEBUG || T4A_TESTABLE
        let env = ProcessInfo.processInfo.environment
        guard env["T4A_TEST_CHANNEL"] != nil, env["T4A_BENCH_FRAME"] != "free",
              let screen = NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let width = floor(visible.width / 2)
        return NSRect(x: visible.maxX - width, y: visible.minY,
                      width: width, height: visible.height)
#else
        return nil
#endif
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildLayout() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.current.ground.cgColor
        window.contentView = content
        // A light theme has to tell the system controls — the text fields and
        // their carets — which way the light comes from, or the composer draws
        // white text on paper.
        window.appearance = NSAppearance(named: Theme.current.isLight ? .aqua : .darkAqua)

        for view in [band, tabStrip, stage, dash] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for view in [rail, railGrip, terminalHost, composer, inspectorGrip, inspector] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(view)
        }
        // L'anteprima sta SOPRA l'ispettore e occupa la stessa colonna: da
        // aperta lo copre per intero, da ridotta gli lascia tutto tranne la
        // fascia del titolo. Cosi` la larghezza della colonna resta UNA —
        // quella dell'ispettore — e la cucitura e il terminale la seguono
        // senza sapere che esiste un'anteprima.
        previewSurface.translatesAutoresizingMaskIntoConstraints = false
        previewSurface.isHidden = true
        stage.addSubview(previewSurface, positioned: .above, relativeTo: inspector)
        card.isHidden = true
        terminalHost.addSubview(card)
        terminalHost.addSubview(splitButton)

        railWidth = rail.widthAnchor
            .constraint(equalToConstant: CGFloat(config.int(.railWidth)))
        inspectorWidth = inspector.widthAnchor
            .constraint(equalToConstant: CGFloat(config.int(.inspectorWidth)))
        previewHeight = previewSurface.heightAnchor
            .constraint(equalToConstant: PreviewSurface.headHeight)
        dashHeight = dash.heightAnchor.constraint(equalToConstant: Theme.Metric.dashHeight)
        composerHeight = composer.heightAnchor.constraint(equalToConstant: 0)
        tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        bandTop = band.topAnchor.constraint(equalTo: content.topAnchor)
        bandHeight = band.heightAnchor.constraint(equalToConstant: Theme.Metric.bandHeight)
        // Written separately from band.bottom on purpose: in full screen the
        // band overlays the stage while the tabs, if present, keep their own
        // honest row at the edge.
        tabStripTop = tabStrip.topAnchor.constraint(equalTo: content.topAnchor,
                                                    constant: Theme.Metric.bandHeight)
        terminalHostTop = terminalHost.topAnchor.constraint(equalTo: stage.topAnchor)

        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bandTop,
            bandHeight,

            tabStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabStripTop,
            tabStripHeight,

            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stage.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            stage.bottomAnchor.constraint(equalTo: dash.topAnchor),

            dash.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dash.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dash.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            dashHeight,

            rail.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            rail.topAnchor.constraint(equalTo: stage.topAnchor),
            rail.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            railWidth,

            railGrip.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            railGrip.topAnchor.constraint(equalTo: stage.topAnchor),
            railGrip.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            railGrip.widthAnchor.constraint(equalToConstant: GripView.thickness),

            inspectorGrip.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspectorGrip.topAnchor.constraint(equalTo: stage.topAnchor),
            inspectorGrip.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            inspectorGrip.widthAnchor.constraint(equalToConstant: GripView.thickness),

            terminalHost.leadingAnchor.constraint(equalTo: railGrip.trailingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: inspectorGrip.leadingAnchor),
            splitButton.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor, constant: -6),
            splitButton.centerYAnchor.constraint(equalTo: terminalHost.centerYAnchor),
            terminalHostTop,
            terminalHost.bottomAnchor.constraint(equalTo: composer.topAnchor),

            composer.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            composerHeight,

            // The card floats over the bottom of the terminal, where the
            // question it is about was drawn, and never over the rail or the
            // inspector: it belongs to one pane.
            card.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor, constant: 22),
            card.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor, constant: -22),
            card.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor, constant: -16),

            inspector.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: stage.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            inspectorWidth,

            previewSurface.leadingAnchor.constraint(equalTo: inspector.leadingAnchor),
            previewSurface.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            previewSurface.topAnchor.constraint(equalTo: stage.topAnchor),
        ])
        // Aperta arriva in fondo alla colonna, ridotta è alta quanto la sua
        // testa. Due vincoli e non un'altezza calcolata: così la colonna
        // resta giusta quando la finestra cambia taglia, senza che nessuno
        // ricalcoli niente (ISC-106 vale anche qui).
        previewBottom = previewSurface.bottomAnchor.constraint(equalTo: stage.bottomAnchor)
        previewBottom.isActive = true

        commandPalette.isHidden = true
        commandPalette.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(commandPalette, positioned: .above, relativeTo: nil)
        turnReader.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(turnReader, positioned: .below, relativeTo: commandPalette)
        previewFront.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(previewFront, positioned: .below, relativeTo: turnReader)
        // L'elenco dei comandi sta nel CONTENUTO e non nella scena, perché
        // deve passare sopra la pagina della chat e sopra il terminale
        // restando dentro la finestra — la stessa scelta di `card` e di
        // `turnReader`. Sotto l'anteprima e la palette: quelli sono veli che
        // prendono tutta la finestra, e un elenco di comandi sopra un velo
        // sarebbe un elenco che non appartiene più a niente.
        slashList.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(slashList, positioned: .below, relativeTo: previewFront)
        slashListHeight = slashList.heightAnchor.constraint(equalToConstant: 0)
        // La ricevuta sta dove sta l'elenco dei comandi e non accanto: le due
        // non convivono mai — l'elenco compare mentre SCRIVI, la ricevuta
        // mentre ASPETTI — e due pannelli impilati sopra la bolla la
        // spingerebbero giù per niente (ISC-194).
        queuedView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(queuedView, positioned: .below, relativeTo: previewFront)
        queuedHeight = queuedView.heightAnchor.constraint(equalToConstant: 0)
        refusalView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(refusalView, positioned: .below, relativeTo: previewFront)
        refusalHeight = refusalView.heightAnchor.constraint(equalToConstant: 0)
        waitingMenu.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(waitingMenu, positioned: .below, relativeTo: commandPalette)
        NSLayoutConstraint.activate([
            commandPalette.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            commandPalette.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            commandPalette.topAnchor.constraint(equalTo: content.topAnchor),
            commandPalette.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            turnReader.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            turnReader.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            turnReader.topAnchor.constraint(equalTo: content.topAnchor),
            turnReader.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            previewFront.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            previewFront.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewFront.topAnchor.constraint(equalTo: content.topAnchor),
            previewFront.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            waitingMenu.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            waitingMenu.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            waitingMenu.topAnchor.constraint(equalTo: content.topAnchor),
            waitingMenu.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            // Appoggiato sul bordo alto della bolla, e largo quanto la sua
            // carta: il testo di una riga cade così nella stessa colonna del
            // testo che stai scrivendo sotto, e i due bordi destri coincidono
            // (MacAppRules §2, «tutti i comandi finiscono sullo stesso bordo»).
            slashList.leadingAnchor.constraint(equalTo: composer.leadingAnchor,
                                               constant: ComposerView.cardInset),
            slashList.trailingAnchor.constraint(equalTo: composer.trailingAnchor,
                                                constant: -ComposerView.cardInset),
            slashList.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: 1),
            slashListHeight,

            queuedView.leadingAnchor.constraint(equalTo: composer.leadingAnchor,
                                                constant: ComposerView.cardInset),
            queuedView.trailingAnchor.constraint(equalTo: composer.trailingAnchor,
                                                 constant: -ComposerView.cardInset),
            queuedView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: 1),
            queuedHeight,

            refusalView.leadingAnchor.constraint(equalTo: composer.leadingAnchor,
                                                 constant: ComposerView.cardInset),
            refusalView.trailingAnchor.constraint(equalTo: composer.trailingAnchor,
                                                  constant: -ComposerView.cardInset),
            refusalView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: 1),
            refusalHeight,
        ])
        // In a window the two views never overlap, so this does not change a
        // pixel. In full screen the transparent compact band is the middle
        // header and must sit above the terminal stage it labels.
        content.addSubview(band, positioned: .above, relativeTo: stage)

        rail.onSelect = { [weak self] session in self?.focusSession(id: session.id) }
        rail.onClose = { [weak self] session in self?.closeSession(id: session.id) }
        inspector.onSelectTurn = { [weak self] turn in
            self?.openTurn(turn)
        }
        inspector.onToggleTurn = { [weak self] turn in
            self?.activeTab?.activePane.session.toggleFold(turn: turn)
            self?.refresh()
        }
        card.onAnswer = { [weak self] keys in self?.answerApproval(keys) }
        composer.onSend = { [weak self] submission in self?.compose(submission) ?? false }
        // Esc e Ctrl-C scritti nella bolla arrivano al processo del pannello
        // attivo, come se fossero stati battuti nella riga d'ingresso.
        composer.onRawKey = { [weak self] bytes in
            self?.activeTab?.activePane.session.backend.send(bytes: bytes)
        }
        // The bubble grew or shrank: give it the room, without going through
        // `applyComposerMode`, which would re-arm pure chat on every keystroke
        // and re-scan sixty rows of grid with it.
        // L'elenco dei comandi `/` (ISC-187). Quattro fili: il testo cambia,
        // un tasto arriva a elenco aperto, la bolla perde la tastiera, e il
        // catalogo ha finito di leggere (che succede DUE volte per ogni
        // aggancio — i dichiarati subito, i built-in a scansione finita).
        composer.onTextChange = { [weak self] _ in
            self?.elencoScartato = false
            self?.aggiornaElencoComandi()
        }
        composer.onSlashKey = { [weak self] event in self?.elencoTasti(event) ?? false }
        composer.onResign = { [weak self] in
            // Il primo responder cambia DENTRO `makeFirstResponder`, quindi
            // qui la bolla ce l'ha ancora: la chiusura va rimandata di un
            // giro, o `aggiornaElencoComandi` legge lo stato di prima e
            // lascia l'elenco aperto sotto una tastiera che non è più sua.
            DispatchQueue.main.async { self?.aggiornaElencoComandi() }
        }
        slashCatalog.onChange = { [weak self] in self?.aggiornaElencoComandi() }
        slashList.onChoose = { [weak self] index in self?.completaComando(at: index, andSend: false) }
        composer.onHeightChange = { [weak self] in
            guard let self, !self.composer.isHidden else { return }
            self.composerHeight.constant = self.composer.preferredHeight
        }
        tabStrip.onSelect = { [weak self] index in self?.selectTab(index) }
        tabStrip.onClose = { [weak self] index in self?.closeTab(index) }
        tabStrip.onNewTab = { [weak self] in self?.newTab() }
        band.onWaitingClick = { [weak self] in self?.apriAttese() }
        waitingMenu.onChoose = { [weak self] id in self?.focusSession(id: id) }
        railGrip.invert = false
        // Which side the panel is on, said out loud rather than read out of
        // `invert` — the shade of ISC-124 has to start at the panel's edge.
        railGrip.panelSide = .left
        railGrip.range = 150...460
        railGrip.currentWidth = { [weak self] in self?.railWidth.constant ?? 0 }
        railGrip.onDrag = { [weak self] width in self?.railWidth.constant = width }
        railGrip.onEnd = { [weak self] in
            guard let self else { return }
            self.config.set(.railWidth, Int(self.railWidth.constant.rounded()))
            self.applyPanelVisibility()
        }
        inspectorGrip.invert = true
        inspectorGrip.panelSide = .right
        inspectorGrip.range = 180...560
        inspectorGrip.currentWidth = { [weak self] in self?.inspectorWidth.constant ?? 0 }
        inspectorGrip.onDrag = { [weak self] width in self?.inspectorWidth.constant = width }
        inspectorGrip.onEnd = { [weak self] in
            guard let self else { return }
            // La stessa cucitura scrive in due chiavi diverse, e non è un
            // ramo nascosto: è la colonna che in questo momento ha
            // un'anteprima aperta dentro, quindi la larghezza scelta è la
            // larghezza DELL'ANTEPRIMA. Chiusa l'anteprima, la mappa dei
            // turni ritrova i suoi trecento punti invece di ereditare meta`
            // finestra (ISC-176).
            let quanto = Int(self.inspectorWidth.constant.rounded())
            if self.previewIsExpanded { self.config.set(.previewWidth, quanto) }
            else { self.config.set(.inspectorWidth, quanto) }
            self.applyPanelVisibility()
        }
        // Two buttons, one meaning: the one in the rail and the one in the tab
        // strip are the same command in the two places the sessions can be.
        for button in layoutToggles { button.onClick = { [weak self] in self?.toggleSessionLayout() } }
        band.inspectorToggle.onClick = { [weak self] in self?.toggleInspector() }
        band.previewToggle.onClick = { [weak self] in self?.togglePreviewCollapsed() }
        band.dashToggle.onClick = { [weak self] in self?.toggleDash() }
        band.settingsButton.onClick = { [weak self] in self?.openSettings() }
        // Il click sul nome di un file, da tutte e due le superfici che
        // mostrano un turno: la pagina della chat e il lettore. Una sola
        // destinazione, perchè sono lo stesso gesto sulla stessa cosa.
        chatPage.onOpenFile = { [weak self] link in self?.openPreview(link.path) }
        // La pagina della chat è l'altra superficie da cui si copia davvero:
        // la ragione per cui apri un blocco è quasi sempre riprenderne un
        // pezzo (ISC-197).
        chatPage.onSelection = { [weak self] testo in self?.copiaSelezione(testo) }
        chatPage.onDrop = { [weak self] paths in self?.consegnaDrop(paths) ?? false }
        chatPage.onPlainClick = { [weak self] in _ = self?.restituisciTastieraAllaBolla() }
        turnReader.onSelection = { [weak self] testo in self?.copiaSelezione(testo) }
        turnReader.onOpenFile = { [weak self] link in self?.openPreview(link.path) }
        previewSurface.onToggleCollapse = { [weak self] in self?.togglePreviewCollapsed() }
        previewSurface.onFront = { [weak self] in self?.previewToFront() }
        previewSurface.onBack = { [weak self] in self?.previewToPanel() }
        previewSurface.onClose = { [weak self] in self?.closePreview() }
        previewFront.onBack = { [weak self] in self?.previewToPanel() }
        installEscapeMonitor()
        dash.onHeightChange = { [weak self] in
            guard let self, self.config.bool(.showDashboard) else { return }
            self.dashHeight.constant = self.dash.preferredHeight
        }
        applyPanelVisibility()
    }

    private func applyPanelVisibility(animated: Bool = false) {
        guard animated else { applyPanelVisibilityNow(); return }
        // The panels SLIDE (his word, 25/08: the snap was «scattante») — but
        // through the CONSTRAINTS' own animator proxies, and nothing else.
        // `allowsImplicitAnimation` was the crash: it put every view of every
        // window into the transaction, and a settings pane rebuilt while that
        // transaction still meant to draw it died inside AppKit's drawRect
        // (bisected 25/08: with it, dead on the second turn-map toggle three
        // runs out of three; without it, three clean rounds).
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            applyPanelVisibilityNow(animator: true)
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// The strip is there when the tabs layout is on AND there is something
    /// to show: with one tab and `tabs-when-single = hide`, it waits for the
    /// second (iTerm's way, his ask 25/08). The «+» lives inside the strip,
    /// so it follows — ⌘T and the Shell menu remain the always-there way in.
    private func updateTabStripVisibility(showTabs: Bool? = nil, animator: Bool = false) {
        let tabsLayout = showTabs ?? (config.string(.layoutSessions) == "tabs")
        let visible = tabsLayout
            && (tabs.count > 1 || config.string(.tabsWhenSingle) != "hide")
        if animator, tabStripHeight.constant != (visible ? 34 : 0) {
            tabStripHeight.animator().constant = visible ? 34 : 0
        } else {
            tabStripHeight.constant = visible ? 34 : 0
        }
        tabStrip.isHidden = !visible
        // The compact middle header begins below a visible tab strip. Keep it
        // on the same top line as the stage while the tab strip animates.
        if fullScreenLayoutTarget {
            let value = Self.fullScreenTopMargin + (visible ? 34 : 0)
            if animator, bandTop.constant != value {
                bandTop.animator().constant = value
            } else {
                bandTop.constant = value
            }
        }
    }

    /// Moves the chrome to its full-screen target in the animation context
    /// AppKit already opened for the Space transition. There is deliberately
    /// no duration and no independent animation: Reduce Motion and the system
    /// transition remain the only clock (ISC-238).
    private func applyFullScreenLayout(_ fullScreen: Bool, animated: Bool) {
        guard let content = window?.contentView else { return }
        fullScreenLayoutTarget = fullScreen
        content.layoutSubtreeIfNeeded()

        let tabs = tabStrip.isHidden ? CGFloat(0) : tabStripHeight.constant
        let targets: [(NSLayoutConstraint, CGFloat)] = [
            (bandTop, fullScreen ? Self.fullScreenTopMargin + tabs : 0),
            (bandHeight, fullScreen ? Self.fullScreenHeaderHeight : Theme.Metric.bandHeight),
            (tabStripTop, fullScreen ? Self.fullScreenTopMargin : Theme.Metric.bandHeight),
            (terminalHostTop, fullScreen ? Self.fullScreenHeaderHeight : 0),
        ]
        band.setFullScreenCompact(fullScreen, animated: animated)
        for (constraint, value) in targets where constraint.constant != value {
            if animated { constraint.animator().constant = value }
            else { constraint.constant = value }
        }
        content.layoutSubtreeIfNeeded()
    }

    private func fullScreenLayoutIsAtTarget(_ fullScreen: Bool) -> Bool {
        let tabs = tabStrip.isHidden ? CGFloat(0) : tabStripHeight.constant
        let wanted: [(NSLayoutConstraint, CGFloat)] = [
            (bandTop, fullScreen ? Self.fullScreenTopMargin + tabs : 0),
            (bandHeight, fullScreen ? Self.fullScreenHeaderHeight : Theme.Metric.bandHeight),
            (tabStripTop, fullScreen ? Self.fullScreenTopMargin : Theme.Metric.bandHeight),
            (terminalHostTop, fullScreen ? Self.fullScreenHeaderHeight : 0),
        ]
        return wanted.allSatisfy { abs($0.0.constant - $0.1) < 0.01 }
    }

    private func recordFullScreenHook(_ event: String) {
        fullScreenHookLog.append([
            "event": event,
            // ScreenCaptureKit PTS and systemUptime share the host clock.
            "hostTimeMs": ProcessInfo.processInfo.systemUptime * 1_000,
            "bandTop": Double(bandTop.constant),
            "bandHeight": Double(bandHeight.constant),
            "tabStripTop": Double(tabStripTop.constant),
            "terminalTop": Double(terminalHostTop.constant),
        ])
        if fullScreenHookLog.count > 16 { fullScreenHookLog.removeFirst() }
    }

    /// AppKit owns the Space transition. Our animator proxies participate only
    /// when both the app and accessibility settings permit motion; otherwise
    /// the target is installed in the Will hook with no animation of our own.
    private var fullScreenLayoutShouldAnimate: Bool {
        config.bool(.motion) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func applyPanelVisibilityNow(animator: Bool = false) {
        // One door for every panel constant: the animated path slides it,
        // the plain path sets it. The hidden flags never animate.
        func set(_ constraint: NSLayoutConstraint, _ value: CGFloat) {
            if animator, constraint.constant != value {
                constraint.animator().constant = value
            } else {
                constraint.constant = value
            }
        }
        // The sessions are always somewhere: down the left, or across the top.
        // Hiding them was a third state nobody wanted and it made the arrow a
        // liar — «move them up» while they were not on screen at all (his call,
        // 2026-08-25). The rail follows the layout and nothing else.
        let showRail = config.string(.layoutSessions) == "rail"
        let showTabs = config.string(.layoutSessions) == "tabs"
        // A closed panel gives its width BACK to the terminal, grip included:
        // a zero-width panel that still holds a seam is a panel that is only
        // pretending to be gone (ISC-104.5).
        let railSize = CGFloat(config.int(.railWidth))
        set(railWidth, showRail ? railSize : 0)
        rail.isHidden = !showRail
        railGrip.isHidden = !showRail
        updateTabStripVisibility(showTabs: showTabs, animator: animator)
        // LA COLONNA DI DESTRA, che è una sola larghezza con due inquilini.
        //
        // Con un'anteprima aperta la colonna vale `preview-width` e la
        // riempie l'anteprima; ridotta o chiusa torna a `inspector-width` e la
        // riempie la mappa dei turni. Il conto sta in un posto solo perchè la
        // cucitura e il terminale leggono `inspectorWidth` e non devono sapere
        // che esiste un'anteprima (ISC-176).
        //
        // Con un'anteprima aperta la colonna c'è ANCHE se la mappa dei turni
        // è spenta: hai appena chiesto tu di vedere un file, e rispondere con
        // niente perchè un altro interruttore è giù sarebbe un click che si
        // perde.
        let showInspector = config.bool(.showTurnMap)
        let hasPreview = previewSurface.isLoaded && previewSurface.placement == .panel
        let inspectorSize = previewIsExpanded
            ? previewWidthWanted : CGFloat(config.int(.inspectorWidth))
        set(inspectorWidth, (showInspector || hasPreview) ? inspectorSize : 0)
        inspector.isHidden = !showInspector
        inspectorGrip.isHidden = !(showInspector || hasPreview)
        // Da aperta prende tutta la colonna, da ridotta la sola testa. Nella
        // carta l'altezza la decide il velo, quindi qui vale zero e non tocca
        // niente.
        // Visibile ogni volta che un file è caricato, ovunque stia: nascosta
        // solo quando non c'è niente da mostrare. Legarla a `hasPreview` la
        // faceva sparire nel momento in cui la portavi davanti, che è
        // esattamente quando la stai guardando (trovato dal banco, 26/08).
        previewSurface.isHidden = !previewSurface.isLoaded
        let nellaColonna = previewSurface.superview === stage
        previewBottom.isActive = nellaColonna && !previewSurface.collapsed
        previewHeight.isActive = nellaColonna && previewSurface.collapsed
        // Il quarto glifo esiste solo quando c'è un file caricato, ed è
        // acceso quando l'anteprima è aperta: spento vuol dire ridotta, non
        // assente (ISC-176).
        band.previewToggle.isHidden = !previewSurface.isLoaded
        band.previewToggle.isOn = previewSurface.isLoaded && !previewSurface.collapsed
        applyComposerMode()
        let showDash = config.bool(.showDashboard)
        dashHeight.constant = showDash ? dash.preferredHeight : 0
        dash.isHidden = !showDash
        band.inspectorToggle.isOn = showInspector
        band.dashToggle.isOn = showDash
        // The layout glyph says WHERE the sessions are, so its bar follows the
        // arrangement rather than a stored opinion (ISC-147). It is lit when
        // they are visible at all — which the tab strip always is, and the
        // rail is only while its own switch is on.
        for button in layoutToggles {
            button.edge = showTabs ? .top : .left
            button.isOn = showTabs || showRail
        }
        // The arrow points at where they would GO, which is the other place
        // (ISC-156), and the tooltip says it in words. Both are set here and
        // nowhere else, so the drawing and the sentence cannot disagree about
        // which way this button is pointing.
        for button in layoutToggles {
            button.destination = showTabs ? .left : .top
            button.hint = showTabs
                ? S.moveSessionsLeft
                : S.moveSessionsTop
        }
        // The sessions-panel switch commands the rail, and in tab layout there
        // is no rail to command: pressing it wrote a line in the file and
        // changed nothing on the screen, which is a control that lies. It goes
        // away while the sessions are tabs, and the arrow beside it is how you
        // get the rail back (ISC-162).
        band.titleX = (showRail ? railSize + GripView.thickness : 0)
            + PaneView.gutterWidth + Theme.Metric.textInset
        refresh()
    }

    // MARK: - The facts provider (ISC-139)

    /// Hand the provider its clock and its questions. Called at launch and
    /// again whenever the two keys change, so pointing the configuration at a
    /// different program takes effect without a restart.
    func startFacts() {
        facts.context = { [weak self] in
            guard let self, let session = self.activeTab?.activePane.session
            else { return FactsContext() }
            var context = FactsContext()
            context.cwd = session.workingDirectory.path
            context.pid = session.backend.foregroundProcesses().first {
                AgentRegistry.adapter(forProcess: $0.name,
                                      commandLine: $0.commandLine) != nil
            }?.pid
            if let agent = session.agent, agent.isAttached {
                context.agent = agent.kind
                context.session = agent.sessionIdentifier
            }
            return context
        }
        facts.onUpdate = { [weak self] catalogueChanged in
            guard let self else { return }
            self.placeDiscoveredRows()
            // The provider's name for the session in the pane, straight off the
            // facts (asked for, 25/08): the band's title is the one the
            // provider's own dashboard shows, and survives the dashboard being veiled —
            // the veil stops the DRAWING, the facts keep flowing.
            if let row = self.facts.rows["session"] {
                let name = row.tokens.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let session = self.activeTab?.activePane.session {
                    session.lifeosLabel = name
                }
            }
            // A key that appeared is a row the settings does not know about
            // yet, and rebuilding the panel is how it learns. Only when the
            // CATALOGUE changed, though, and the distinction is ISC-191.
            //
            // The line above used to say that rebuilding "only when something
            // changed" is why a tick is not a redraw of everything. It was
            // true of the sentence and false of the code: what `onUpdate`
            // reports is that a READING changed, which for a live provider is
            // every single tick — his `5HR 8%` moves, so the panel was thrown
            // away and rebuilt every two seconds. The settings shows no
            // readings at all. It shows the row NAMES and their switches, and
            // those change when a provider names a row for the first time or
            // renames one, which is what the flag now carries.
            //
            // What it cost: a real click on a switch takes about a tenth of a
            // second between press and release, and a rebuild landing in that
            // gap deletes the view holding the gesture. Six clicks in six
            // failed under a 0.3 s provider; under his 2 s one it is a click
            // in a handful, which is worse — it reads as a switch that is
            // moody rather than as a switch that is broken.
            if catalogueChanged, self.settings?.currentCategory == "Dashboard rows" {
                self.settings?.show(category: "Dashboard rows")
            }
            self.refresh()
        }
        facts.configure(path: config.string(.factsProvider),
                        interval: config.fraction(.factsInterval, in: 0.1...3600))
    }

    /// Point the bar at a different provider without relaunching. It goes
    /// through the configuration, exactly as editing the file and restarting
    /// would, so what a bench drives is what a person gets — including the one
    /// write that changing a setting costs.
    func testSetFactsProvider(_ path: String) {
        config.set(.factsProvider, path)
        startFacts()
    }

    /// A row the provider has just named has no line yet. It gets one of the
    /// three WHOLE lines — the ones that span the window and open only when
    /// something is on them — and it gets it IN MEMORY.
    ///
    /// Nothing is written. `dash-slots` records where the USER put a row, and
    /// a row nobody has touched has no business in the file; the day the user
    /// drags it, the drag saves it, prefix and all. This is also what keeps
    /// the promise that a tick is not a disk write (ISC-106): discovery
    /// happens on a tick, and if it saved, a provider naming rows would be a
    /// program writing the configuration file every couple of seconds.
    ///
    /// The arrangement is the provider's own order, four to a line, and it is
    /// arrived at without this app knowing one provider from another: rows one
    /// to four fill the first whole line, five to eight the second, and
    /// anything after that lands on the third SWITCHED OFF. The third line is
    /// left free on purpose, exactly as the third half line is (ISC-104.1) —
    /// a default that fills every line leaves a person nothing to drag into,
    /// and a bar showing twelve readings at once is a bar nobody reads.
    ///
    /// A row is defaulted off only while it has no line at all, which is the
    /// same guard the placement uses. Without that, switching one on would
    /// save a layout the next launch would quietly switch off again.
    private func placeDiscoveredRows() {
        let placed = Set(DashSlot.allCases.flatMap { dashLayout.keys(in: $0) })
        let missing = DashCatalog.placeable.filter { !placed.contains($0) }
        guard !missing.isEmpty else { return }
        var next = dashLayout
        for key in missing {
            let slot: DashSlot
            if next.keys(in: .facts1).count < DashCatalog.factsPerLine {
                slot = .facts1
            } else if next.keys(in: .facts2).count < DashCatalog.factsPerLine {
                slot = .facts2
            } else {
                slot = .facts3
                next.off.insert(key)
            }
            next.move(key, to: slot, before: nil)
        }
        dashLayout = next
    }

    // MARK: - The settings window (ISC-104.6)

    @objc func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(config: config, owner: self)
        }
        // Placed on every OPENING and not only on the first one (ISC-155).
        // The controller outlives its window being closed, so a panel put down
        // once would come back where the main window used to be — which is the
        // same complaint as the one that started this, arriving a day later.
        // Only when it is off screen: re-centring a panel that is already open
        // would move it under the hand of somebody who just clicked settings
        // to bring it forward.
        let wasOffScreen = settings?.window?.isVisible != true
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        // AFTER it is on screen, not before. Showing a window is allowed to
        // move it — the cascade above is one way, and it is switched off, but
        // the ordering also means the placement is the last word rather than
        // the first. Only when it was off screen: re-centring a panel that is
        // already open would move it under the hand of somebody who clicked
        // settings to bring it forward.
        if wasOffScreen { settings?.place() }
    }

    func setSessionLayout(_ name: String) {
        guard name == "rail" || name == "tabs" else { return }
        config.set(.layoutSessions, name)
        applyPanelVisibility()
    }

    /// The one door a theme change comes through, from the palette, the
    /// settings or the menu. The name is written to the file first and read
    /// back from it, so the window and the file cannot hold different
    /// opinions about which theme is on (ISC-33).
    func setTheme(_ name: String) {
        config.set(.theme, name)
        applyThemeFromConfig()
    }

    /// Resolves whatever `theme` names — a built-in, or a file in `themes/`
    /// beside the configuration — and puts it in force everywhere, without a
    /// relaunch. A name nobody can resolve falls back to the default and says
    /// why, in `Theme.problem`.
    func applyThemeFromConfig() {
        let directory = Theme.themesDirectory(besides: config.url)
        Theme.use(resolved: Theme.resolve(config.string(.theme), themes: directory))
        Theme.reapplyEverywhere()
    }

    /// Every theme that can be chosen right now: the four that ship, then
    /// whatever files are sitting in `themes/`.
    func availableThemeNames() -> [String] {
        Theme.all.map(\.name)
            + Theme.userThemeNames(in: Theme.themesDirectory(besides: config.url))
    }

    /// Every switch in the settings comes through here, so a change made in
    /// the window and a change made in the file are the same change.
    func setBool(_ key: ConfigKey, _ value: Bool) {
        config.set(key, value)
        if key == ConfigKey.notifications { Notifier.shared.isEnabled = value }
        if key == ConfigKey.pureChat { applyComposerMode() }
        applyPanelVisibility()
    }

    // MARK: - The composer, only when it is needed (ISC-112)

    /// Whether the front program already has a prompt of its own.
    ///
    /// Two independent readings, and either one is enough. The kernel says a
    /// program other than the shell owns the pty — `claude`, `codex`, `vim` —
    /// and the grid says the alternate screen is up, which is what a
    /// full-screen program takes when it draws its own input line. Neither is
    /// a guess about what the user typed.
    private var frontProgramOwnsInput: Bool {
        activeTab?.activePane.session.frontOwnsInput ?? false
    }

    /// The composer is there by default, `claude` or no `claude` (ISC-113):
    /// the bubble is T4A's own line and hiding it is a choice, not the rule.
    /// `contextual` is that choice — it takes the composer away while the
    /// front program has an input line of its own, and brings it back for a
    /// card waiting on an answer or a session asking for you (ISC-112).
    /// An unreadable value falls to the default rather than to hiding: a
    /// typo in the file must never cost you your input line.
    ///
    /// `agent` è il default da ISC-174, ed è la sua richiesta del 25/08: «la
    /// bolla con message this session la mettiamo solo quando viene aperto
    /// claude, un agente, codex». Vale «mostra la bolla se e solo se il pannello
    /// è connesso», con la STESSA funzione di ISC-173 e non una copia: se
    /// domani cambia cosa vuol dire connesso, la barra e la bolla cambiano
    /// insieme, che è l'unico modo perché non possano contraddirsi.
    ///
    /// E il default che assorbe un valore illeggibile è cambiato con lui, il
    /// che vuol dire che un refuso nel file adesso PUÒ togliere la bolla —
    /// sopra una shell nuda. Non toglie però la riga d'ingresso, che è la
    /// cosa che quella frase qui sopra difende: con una shell nuda la riga
    /// del terminale è lì, ed è proprio quella che si vuole vedere.
    var composerShouldShow: Bool {
        guard config.bool(.showComposer) else { return false }
        switch config.string(.composerMode) {
        case "never": return false
        case "always": return true
        case "contextual": break
        default:
            // `agent`, e qualunque cosa il file non sappia scrivere.
            guard let session = activeTab?.activePane.session else { return false }
            return paneIsConnected(session)
        }
        guard let session = activeTab?.activePane.session else { return false }
        if card.isShowing { return true }
        if session.isWaitingForYou || session.agent?.approval != nil { return true }
        return !frontProgramOwnsInput
    }

    func applyComposerMode() {
        let show = composerShouldShow
        // The bubble's own height, not a constant: it grows with the message
        // being written in it (ISC-159).
        composerHeight.constant = show ? composer.preferredHeight : 0
        composer.isHidden = !show
        armPureChat(composerIsShown: show)
    }

    /// Pure chat is armed here and nowhere else (ISC-114), because the two
    /// conditions it needs live here: the flag, and whether T4A's own line is
    /// actually on screen to take the covered one's place.
    ///
    /// The pane is re-scanned only when the arming CHANGED. A scan on every
    /// refresh would read sixty rows of grid every time anything in the window
    /// moved, and this method is on that path.
    private func armPureChat(composerIsShown show: Bool) {
        let on = config.bool(.pureChat) && show
        for session in tabs.flatMap(\.sessions) where session.pureChat != on {
            session.pureChat = on
            // A quiet pane sends no bytes, so nothing would scan: switching
            // the experiment on in front of a resting agent has to take
            // effect now or it looks broken.
            session.scanScreenNow()
        }
    }

    /// L'agente sta tenendo aperta una domanda sullo schermo del pannello?
    ///
    /// Due sorgenti, e la seconda è più larga della prima: una card di
    /// permesso, e qualunque domanda numerata che lo scanner riconosca. La
    /// seconda prende anche i menu (`/model`), che non sono permessi e che
    /// sarebbero invisibili sotto la pagina.
    private func staChiedendo(_ session: Session) -> Bool {
        // Il valore è già stato calcolato dalla scansione dello schermo, che
        // gira sui byte in arrivo. Ricalcolarlo qui significherebbe leggere la
        // griglia a ogni refresh, e `refresh` sta su ogni battito della
        // finestra: è così che questa riga ha fatto fallire `bench-card`.
        session.agent?.approval != nil || session.agenteStaChiedendo
    }

    /// ⌥⌘C — la via d'uscita che non dipende da noi.
    ///
    /// Lo scoprimento automatico prende le domande che sappiamo riconoscere;
    /// tutto il resto che `claude` può disegnare (una diff, la storia con
    /// ctrl-r, un pannello suo) non lo sappiamo. Una scorciatoia che riporta
    /// il terminale sotto gli occhi in un tasto è la differenza fra una vista
    /// che copre e una vista che imprigiona.
    @objc func toggleChatPage() {
        config.set(ConfigKey.chatPage, !config.bool(.chatPage))
        refresh()
    }

    /// Il segno che una scheda porta a destra del nome: quante decisioni
    /// aspettano una risposta, e se c'è un fine-turno non ancora guardato.
    ///
    /// La decisione resta finché non rispondi. Il pallino invece è attenzione,
    /// non stato: selezionare dopo la fine lo spegne anche quando poi lasci la
    /// scheda, e solo un nuovo fine-turno lo riaccende (decisione del 30/08).
    private func segnoDella(scheda tab: Tab) -> TabStripView.Segno {
        var segno = TabStripView.Segno()
        for session in tab.sessions {
            guard let agent = session.agent, agent.isAttached else { continue }
            if agent.approval != nil { segno.decisioni += 1 }
            else if agent.activity == .waiting {
                segno.haFinito = true
                segno.finiViste = segno.finiViste && session.vistaDopoLaFine
            }
            else if agent.activity == .working { segno.staLavorando = true }
        }
        return segno
    }

    /// The single source for the number, the direct jump and the menu rows.
    /// Focus exclusion and finished-turn visibility both remain Session's
    /// decision; the controller only consumes that exact answer.
    private var sessioniInAttesa: [Session] {
        tabs.flatMap(\.sessions).filter(\.isWaitingForYou)
    }

    private func vociAttese(_ sessions: [Session]) -> [WaitingMenuView.Item] {
        let now = Date()
        return sessions.map { session in
            let seconds = session.waitingForYouSince.map { now.timeIntervalSince($0) } ?? 0
            return WaitingMenuView.Item(id: session.id, title: session.displayName,
                                        age: WaitingAge.label(seconds: seconds))
        }
    }

    /// Point immediately below the complete «N waiting» target, converted
    /// into the full-window overlay's flipped coordinates.
    private func ancoraMenuAttese() -> NSPoint {
        band.displayIfNeeded()
        let rect = band.waitingHitRect
        return waitingMenu.convert(NSPoint(x: rect.minX, y: rect.maxY), from: band)
    }

    private func apriAttese() {
        let waiting = sessioniInAttesa
        switch WaitingRoute.forCount(waiting.count) {
        case .none:
            return
        case .direct:
            _ = focusSession(id: waiting[0].id)
        case .menu:
            waitingMenu.open(items: vociAttese(waiting), below: ancoraMenuAttese(),
                             restoring: window?.firstResponder)
        }
    }

    private func aggiornaMenuAtteseSeAperto() {
        guard !waitingMenu.isHidden else { return }
        let waiting = sessioniInAttesa
        waitingMenu.update(items: vociAttese(waiting), below: ancoraMenuAttese())
    }

    /// La pagina della chat si mostra quando c'è una conversazione da
    /// mostrare, e sparisce quando non c'è.
    ///
    /// Le tre condizioni sono tutte necessarie e nessuna è di gusto:
    /// l'interruttore, un agente davvero agganciato in QUESTO pannello, e
    /// almeno un turno. Senza la terza, aprire una scheda nuova coprirebbe un
    /// terminale funzionante con una pagina vuota, che è il modo più veloce di
    /// far sembrare rotta un'app.
    private func aggiornaPaginaChat(_ active: Session?) {
        // La pagina appartiene alla BOLLA, ed è sua regola del 25/08: «se non è
        // selezionata la bolla, la scelta del terminale viene mostrata come la
        // propone in modo classico Claude Code». Senza questa condizione la
        // pagina copriva il terminale anche con la bolla spenta, cioè copriva
        // proprio la riga d'ingresso che quella scelta esiste per mostrare
        // (misurato il 25/08: composer shown=False e chatPage showing=True).
        let acceso = config.bool(.chatPage) && composerShouldShow
        let turni = active?.agent?.isAttached == true ? (active?.turns ?? []) : []
        // La pagina si toglie di mezzo quando l'agente sta CHIEDENDO qualcosa
        // sul suo schermo: un permesso, il menu di `/model`, una lista
        // numerata. Coprirla sarebbe nascondere l'unica cosa che aspetta te,
        // ed è la stessa regola con cui la bolla scopre la riga d'ingresso
        // quando serve (ISC-114).
        let ingressoDisponibile = active.map { $0.rigaIngressoDisponibile } ?? false
        let mostra = acceso && !turni.isEmpty && ingressoDisponibile
            && !(active.map(staChiedendo) ?? false)
        if mostra { chatPage.mostra(turns: turni, attesa: active?.rigaDiAttesa) }
        guard chatPage.isHidden == mostra else { return }
        pageFlips += 1
        chatPage.isHidden = !mostra
        // Tornando al terminale la tastiera torna al terminale: una pagina
        // nascosta che tiene il primo responder è un pannello che non riceve
        // più niente (ISC-32). SOLO se la teneva la pagina (ISC-231): questa
        // riga prendeva la tastiera anche alla BOLLA, prima che
        // `aggiornaTastiera` potesse segnarla come prestata, e a domanda
        // finita nessuno la restituiva. Suo video del 28/08 22:50: dopo
        // `/model` dalla bolla la tastiera restava sul terminale, e i suoi Esc
        // aprivano il Rewind di claude. Riprodotto anche su `55c197e`, quindi
        // non è la fetta di ISC-227: è di sempre, e si vedeva solo scrivendo
        // `/model` nella bolla.
        if !mostra, let pane = activeTab?.activePane,
           let responder = window?.firstResponder as? NSView,
           responder === chatPage || responder.isDescendant(of: chatPage) {
            window?.makeFirstResponder(pane.session.backend.surface)
        }
    }

    /// La tastiera sta dove sta la domanda.
    ///
    /// Una regola sola, e due difetti che sembravano diversi (suoi, 26/08).
    /// Col menu di `/model` aperto la bolla teneva la tastiera, quindi le
    /// frecce muovevano il cursore dentro la scatola di testo invece della
    /// scelta: il menu si vedeva e non si poteva usare. E il suo gemello: con
    /// la bolla accesa, a chat appena aperta, la tastiera stava sul terminale,
    /// quindi il primo carattere finiva nella riga d'ingresso di `claude` e la
    /// bolla restava lì vuota a guardare.
    ///
    /// Non è un ladro di fuoco: agisce solo se la tastiera è già su uno dei
    /// due (la bolla o il terminale), quindi le impostazioni, la ricerca e il
    /// lettore di un turno la tengono. E la restituisce alla bolla SOLO se
    /// gliel'aveva tolta lei: se sei stato tu ad andare nel terminale, ci
    /// resti.
    private func aggiornaTastiera(_ active: Session?) {
        // Niente `isKeyWindow`: il primo responder è una cosa della FINESTRA,
        // non dello schermo, e legarlo al fuoco dell'app rendeva la regola
        // vera solo mentre T4A era davanti. Misurato il 26/08: col terminale
        // del banco davanti, la tastiera restava sulla bolla col menu aperto,
        // e la stessa sequenza a T4A davanti funzionava. Una regola che
        // dipende da chi è davanti è una regola che nei banchi non si vede.
        guard let window, window.attachedSheet == nil,
              let pane = activeTab?.activePane else { return }
        let responder = window.firstResponder
        let bolla = responder === composer.field
        // La tastiera su una vista NASCOSTA è una tastiera che non scrive da
        // nessuna parte: succedeva aprendo una scheda nuova, dove la bolla si
        // spegne perché non c'è ancora un agente e il primo responder restava
        // suo (suo, 26/08: «apro la scheda, non clicco niente, e non scrive»).
        if bolla, !composerShouldShow {
            tastieraPrestata = false
            bollaEraVisibile = false
            window.makeFirstResponder(pane.session.backend.surface)
            return
        }
        let terminale = (responder as? NSView).map { $0 === pane || $0.isDescendant(of: pane) }
            ?? false
        guard bolla || terminale else { return }
        if active.map(staChiedendo) ?? false {
            guard bolla else { return }
            tastieraPrestata = true
            // La SUPERFICIE del terminale, non il pannello che la contiene.
            //
            // `PaneView` accetta il primo responder e non passa i tasti a
            // nessuno: con lui la freccia non arrivava al menu, ed è il
            // difetto che lui ha filmato. Il mio polo precedente non se n'era
            // accorto perché consegnava il tasto DIRETTAMENTE alla superficie
            // (`testActiveSurface().keyDown`), cioè rispondeva a «il terminale
            // accetta le frecce» invece che a «una freccia vera ci arriva».
            window.makeFirstResponder(pane.session.backend.surface)
            return
        }
        // La bolla è APPENA comparsa: con `composer-mode = agent` compare
        // quando l'agente si aggancia, e quello è il momento in cui la riga
        // d'ingresso diventa lei. Senza questo, la chat si apriva con la
        // tastiera sul terminale e il primo carattere finiva nella riga di
        // `claude` (suo, 26/08).
        let comparsa = composerShouldShow && !bollaEraVisibile
        bollaEraVisibile = composerShouldShow
        guard composerShouldShow, terminale, tastieraPrestata || comparsa else {
            if !composerShouldShow { tastieraPrestata = false }
            return
        }
        tastieraPrestata = false
        composer.focus()
    }

    /// Torni a guardare questa finestra: la tastiera è nella bolla (ISC-188).
    ///
    /// Sua frase del 27/08: «non serve che io clicchi nella bolla, basta che
    /// clicchi sulla chat». `aggiornaTastiera` qui sopra risponde a un'altra
    /// domanda — «la bolla è APPENA comparsa» — e chi torna da un'altra app o
    /// sceglie una sessione trova la bolla lì da un pezzo: quella regola non
    /// scatta, la tastiera resta dov'era, e l'unica via era cliccarci dentro.
    ///
    /// Una funzione sola per i tre agganci (la finestra che torna chiave, la
    /// riga del pannello, la scheda), e non è un vezzo: `focusSession` fa
    /// `makeKeyAndOrderFront`, quindi passa anche dal primo. Scritta due
    /// volte sarebbero due regole che il giorno dopo divergono.
    ///
    /// **Non è un ladro di fuoco** (anti-claim dell'ISA): agisce solo se la
    /// tastiera è già nella bolla, nel terminale, o da nessuna parte. La
    /// ricerca, il lettore di un turno, la palette e l'anteprima se la
    /// tengono, e le impostazioni sono un'altra finestra — finché è chiave
    /// lei, questa non lo è e qui non arriva niente.
    ///
    /// Torna `true` quando ha deciso lei dove va la tastiera, così chi la
    /// chiama non decide una seconda volta.
    @discardableResult
    func restituisciTastieraAllaBolla() -> Bool {
        guard let window, window.attachedSheet == nil,
              let pane = activeTab?.activePane else { return false }
        let responder = window.firstResponder
        let bolla = responder === composer.field
        let terminale = (responder as? NSView).map { $0 === pane || $0.isDescendant(of: pane) }
            ?? false
        // «Nessuno» è la finestra stessa: AppKit non lascia mai il primo
        // responder vuoto, ci mette la finestra, ed è lo stato in cui si
        // trova una finestra che nessuno ha ancora toccato.
        let nessuno = responder === window || responder === window.contentView
        // E la PAGINA DELLA CHAT, che mancava: è selezionabile, quindi un
        // click per leggere le dà il primo responder, e da lì la regola non
        // si riprendeva più la tastiera. Sintomo suo, 27/08: torno su T4A da
        // un'altra app e non posso scrivere finché non clicco nella bolla.
        // Prenderla è sicuro perché la pagina non riceve testo: copre la riga
        // d'ingresso del programma, quindi lì la tastiera non scrive da
        // nessuna parte.
        let pagina = (responder as? NSView).map {
            $0 === chatPage || $0.isDescendant(of: chatPage)
        } ?? false
        guard bolla || terminale || nessuno || pagina else { return false }
        // La regola della domanda sta sopra a questa (ISC-182): con un
        // permesso o un menu numerato sullo schermo la tastiera va alla
        // SUPERFICIE del terminale, che è dove le frecce e i numeri arrivano.
        if staChiedendo(pane.session) {
            // Prestata, non tolta: finita la domanda `aggiornaTastiera` la
            // riporta nella bolla da sé, che è dove questa regola la voleva.
            tastieraPrestata = true
            window.makeFirstResponder(pane.session.backend.surface)
            return true
        }
        guard composerShouldShow else { return false }
        composer.focus()
        return true
    }

    /// La bolla era sullo schermo al giro precedente.
    private var bollaEraVisibile = false

    /// La bolla aveva la tastiera e gliel'abbiamo tolta noi per una domanda.
    private var tastieraPrestata = false

    func applyDashLayout(_ layout: DashLayout) {
        dashLayout = layout
        layout.save(to: config)
        refresh()
        dash.needsLayout = true
    }

    // MARK: - Tabs and panes

    private func makeSession(directory: URL, directCommand: [String]? = nil) -> Session {
        let size = CGFloat(config.int(.fontSize))
        let family = config.string(.fontFamily)
        let font = NSFont(name: family, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        // The environment variable wins over the file, because the bench that
        // compares the two renderers has to be able to ask for one without
        // editing the user's configuration underneath them.
        let wanted = ProcessInfo.processInfo.environment["T4A_RENDERER"]
            ?? config.string(.renderer)
        let session = Session(directory: directory,
                              integrationRoot: config.bool(.shellIntegration)
                                  ? integrationRoot : nil,
                              scrollback: config.int(.scrollbackLines),
                              font: font,
                              shell: config.string(.shell),
                              useGPU: wanted != "cpu",
                              agentAdapter: config.bool(.agentAdapter),
                              directCommand: directCommand)
        session.compactTurns = config.bool(.compactTurns)
        // A pane born after a theme change still gets the theme: the grid is
        // told at birth, not only when somebody switches (ISC-33).
        session.backend.applyTheme(Theme.current.terminal)
        if let renderer = session.backend.renderer {
            renderer.cursorStyle = CursorStyle(rawValue: config.string(.cursorStyle)) ?? .block
            renderer.cursorMotion = CursorMotion(rawValue: config.string(.cursorMotion)) ?? .glide
            renderer.motionEnabled = config.bool(.motion)
        }
        // Selezionare copia, come iTerm (ISC-197). L'interruttore si legge al
        // rilascio e non alla nascita del pannello, altrimenti spegnerlo non
        // varrebbe per le schede già aperte.
        session.backend.onSelectionFinished = { [weak self] testo in
            self?.copiaSelezione(testo)
        }
        // Un file trascinato sul pannello va nella riga d'ingresso che c'è
        // ADESSO, che con un agente agganciato è la bolla (ISC-201).
        session.backend.onDropPaths = { [weak self] paths in
            self?.consegnaDrop(paths) ?? false
        }
        session.backend.onOpenLink = { [weak self] link in
            self?.openTerminalLink(link)
        }
        session.observe { [weak self] in self?.refresh() }
        // A session that starts waiting for you while you are somewhere else
        // says so, once, through the same notifier OSC 9 uses — so a click
        // lands on the pane that is waiting (ISC-28).
        session.onWaitingForYou = { [weak self] what in
            guard let self, self.config.bool(.notifications) else { return }
            guard session.id != self.activeSessionID || !NSApp.isActive else { return }
            let title = session.displayName
            self.notificationLog.append([
                "title": title, "body": what, "session": session.id.uuidString,
                "reason": "waiting",
            ])
            Notifier.shared.post(title: title, body: what, sessionID: session.id)
        }
        session.onNotification = { [weak self] title, body in
            guard let self, self.config.bool(.notifications) else { return }
            self.notificationLog.append([
                "title": title, "body": body, "session": session.id.uuidString,
            ])
            Notifier.shared.post(title: title, body: body, sessionID: session.id)
        }
        return session
    }

    /// The workspace call lives above the terminal backend so a test-channel
    /// build can replace the external side effect with a durable receipt.
    private func openTerminalLink(_ link: TerminalLink) {
#if DEBUG || T4A_TESTABLE
        if testChannel != nil {
            testLinkOpenRecord = ["path": link.target, "type": link.kind.rawValue]
            return
        }
#endif
        switch link.kind {
        case .url:
            guard let url = URL(string: link.target) else { return }
            NSWorkspace.shared.open(url)
        case .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: link.target))
        case .directory:
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: link.target, isDirectory: true)])
        }
    }

    private func makePane(directory: URL, directCommand: [String]? = nil) -> PaneView {
        let pane = PaneView(session: makeSession(directory: directory,
                                                 directCommand: directCommand))
        pane.delegate = self
        return pane
    }

    @objc func newTab() {
        let directory = activeTab?.activePane.session.backend.currentWorkingDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let tab = Tab(pane: makePane(directory: directory))
        tabs.append(tab)
        selectTab(tabs.count - 1)
    }

#if DEBUG || T4A_TESTABLE
    /// Opens a tab whose pty leader is exactly argv[0], without putting a
    /// shell between the terminal and the program a bench is measuring.
    /// Base64(JSON) keeps argv boundaries intact on the channel's line
    /// protocol; accepting a shell command string here would recreate the
    /// quoting and prompt races this door exists to remove.
    func testOpenPaneCommand(base64: String) {
        guard let data = Data(base64Encoded: base64),
              let argv = try? JSONSerialization.jsonObject(with: data) as? [String],
              let executable = argv.first, executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable)
        else {
            NSLog("T4A: open-pane-cmd needs base64 JSON argv with an absolute executable")
            return
        }
        let directory = activeTab?.activePane.session.backend.currentWorkingDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let tab = Tab(pane: makePane(directory: directory, directCommand: argv))
        tabs.append(tab)
        selectTab(tabs.count - 1)
    }
#endif

    /// Opens and selects a door tab, then types on its first shell prompt. A
    /// shell without integration gets the same command after one short grace
    /// period rather than leaving the request stranded forever.
    func openDoorTab(directory: URL, command: String, label: String?) -> UUID {
        let pane = makePane(directory: directory)
        let session = pane.session
        let id = session.id
        session.doorLabel = label
        pendingDoorCommands[id] = command
        session.onPromptStarted = { [weak self] in
            self?.deliverDoorCommand(to: id)
        }
        let tab = Tab(pane: pane)
        tabs.append(tab)
        selectTab(tabs.count - 1)

        if session.hasStartedPrompt { deliverDoorCommand(to: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.deliverDoorCommand(to: id)
        }
        return id
    }

    private func deliverDoorCommand(to id: UUID) {
        guard let command = pendingDoorCommands.removeValue(forKey: id) else { return }
        guard let session = tabs.flatMap(\.sessions).first(where: { $0.id == id }) else {
            NSLog("T4A: door session %@ disappeared before its command", id.uuidString)
            return
        }
        session.onPromptStarted = nil
        sendSyntheticText(command, to: session.backend.surface)
        sendSyntheticKey("return", to: session.backend.surface)
    }

    var doorPaneCount: Int { tabs.reduce(0) { $0 + $1.panes.count } }

    /// Closes exactly the named pane and never enters the confirmation path.
    /// `allPaneCount` lets this window protect the final pane in the app.
    func closeDoorSession(id: UUID, allPaneCount: Int) -> DoorCloseResult {
        guard let tabIndex = tabs.firstIndex(where: { tab in
            tab.panes.contains(where: { $0.session.id == id })
        }), let pane = tabs[tabIndex].panes.first(where: { $0.session.id == id })
        else { return .unknown }
        guard pane.session.closingWouldInterrupt == nil else { return .working }
        guard allPaneCount > 1 else { return .last }

        pendingDoorCommands.removeValue(forKey: id)
        pane.session.onPromptStarted = nil
        let tab = tabs[tabIndex]
        if tab.panes.count > 1 {
            let wasActive = tab.activePane === pane
            pane.session.close()
            tab.tree.remove(pane)
            pane.removeFromSuperview()
            tab.container = nil
            if wasActive, let next = tab.panes.first { tab.activePane = next }
            if tabIndex == activeTabIndex { installActiveTabView() }
            else { refresh() }
            return .closed
        }

        tabs.remove(at: tabIndex)
        pane.session.close()
        pane.removeFromSuperview()
        if tabs.isEmpty {
            window?.close()
        } else {
            if tabIndex < activeTabIndex { activeTabIndex -= 1 }
            else if tabIndex == activeTabIndex {
                activeTabIndex = min(tabIndex, tabs.count - 1)
            }
            installActiveTabView()
        }
        return .closed
    }

    @objc func splitVertically() { split(vertical: true) }
    @objc func splitHorizontally() { split(vertical: false) }

    private func split(vertical: Bool) {
        guard let tab = activeTab else { return }
        let directory = tab.activePane.session.backend.currentWorkingDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser
        let pane = makePane(directory: directory)
        tab.tree.insert(pane, beside: tab.activePane, vertical: vertical)
        tab.container = nil
        setActivePane(pane, in: tab)
        installActiveTabView()
    }

    /// ⌘W. The reflex that closes a window is the same reflex that closes a
    /// pane, and a pane can hold three hours of an agent's work: the question
    /// is asked whenever the foreground program is not the bare shell
    /// (ISC-107).
    @objc func closeCurrent() {
        guard let tab = activeTab else { return }
        if tab.panes.count == 1, tabs.count == 1 {
            // The last pane of the last tab: closing it closes the window, so
            // the window's own question is the right one to ask.
            if let window, window.delegate === self,
               windowShouldClose(window) { window.close() }
            return
        }
        guard let running = tab.activePane.session.closingWouldInterrupt else {
            closeCurrentWithoutAsking()
            return
        }
        confirm(closing: [running], subject: .pane) { [weak self] in
            self?.closeCurrentWithoutAsking()
        }
    }

    /// The × on a row of the rail, or on a tab (ISC-148).
    ///
    /// It brings that pane forward and then closes it exactly as ⌘W does. Two
    /// closing paths would be two chances to disagree about when the question
    /// gets asked, and the question is the whole point: the one thing this
    /// must never do is kill three hours of an agent's work on one click. So
    /// there is one path, and the × is ⌘W aimed at a row.
    ///
    /// Bringing the pane forward first is not a side effect to apologise for:
    /// if the sheet comes up, what is behind it is the pane you are about to
    /// kill, which is the thing you need to see to answer.
    func closeSession(id: UUID) {
        guard focusSession(id: id) else { return }
        closeCurrent()
    }

    private func closeCurrentWithoutAsking() {
        guard let tab = activeTab else { return }
        let pane = tab.activePane
        if tab.panes.count > 1 {
            pane.session.close()
            tab.tree.remove(pane)
            pane.removeFromSuperview()
            tab.container = nil
            if let next = tab.panes.first { setActivePane(next, in: tab) }
            installActiveTabView()
        } else {
            // Without asking: the question has already been put, and asking
            // it again here made a confirmed ⌘W open a second sheet and close
            // nothing (measured 2026-08-20, found by the bench).
            closeTabWithoutAsking(activeTabIndex)
        }
    }

    private func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        // The LAST tab is the window, so the window's question is the right
        // one. Without this branch the × on the only tab killed a live agent
        // on one click and never asked — `tabs.count > 1` guarded the sheet,
        // and `closeTabWithoutAsking` then closed the window (found reading
        // the code for ISC-148, reproduced on 2026-08-23 with `claude` in the
        // only tab). ⌘W had this branch; the × did not, which is exactly the
        // second closing path this claim exists to remove.
        if tabs.count == 1 {
            if let window, window.delegate === self,
               windowShouldClose(window) { window.close() }
            return
        }
        let running = tabs[index].sessions.compactMap(\.closingWouldInterrupt)
        guard !running.isEmpty else {
            closeTabWithoutAsking(index)
            return
        }
        confirm(closing: running, subject: .tab) { [weak self] in
            self?.closeTabWithoutAsking(index)
        }
    }

    private func closeTabWithoutAsking(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.sessions.forEach { $0.close() }
        tab.panes.forEach { $0.removeFromSuperview() }
        if tabs.isEmpty {
            window?.close()
            return
        }
        selectTab(min(index, tabs.count - 1))
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabIndex = index
        installActiveTabView()
        // Con la bolla accesa la riga d'ingresso è LEI, quindi è lei a
        // ricevere il primo carattere: una scheda nuova che dà la tastiera al
        // terminale ti fa scrivere dentro la riga di `claude` mentre guardi la
        // bolla vuota (suo, 26/08). Se una domanda è già sullo schermo, la
        // regola della tastiera qui sotto la riporta al terminale da sé.
        //
        // E senza bolla la tastiera va alla SUPERFICIE del terminale, non al
        // pannello: il pannello accetta il primo responder e non passa i tasti
        // a nessuno, quindi una scheda nuova non scriveva niente finché non ci
        // cliccavi dentro (suo, 26/08).
        //
        // Dal 27/08 la scelta passa dalla regola sola (ISC-188) invece di
        // chiamare `composer.focus()` a mano: è la stessa cosa nel caso
        // normale, e in più rispetta la domanda sullo schermo al primo colpo
        // invece di dare la tastiera alla bolla e farsela togliere dal
        // refresh, e non porta via la tastiera alla ricerca.
        if composerShouldShow { restituisciTastieraAllaBolla() }
        else if let pane = activeTab?.activePane {
            window?.makeFirstResponder(pane.session.backend.surface)
        }
    }

    @objc func selectTabByMenu(_ sender: NSMenuItem) { selectTab(sender.tag) }

    /// ⌘1…⌘9: the tab by its number, counted the way a person counts, from one.
    /// A number nobody has open does nothing — better than jumping to the last
    /// tab, which is what "clamp it" would do and would move you somewhere you
    /// did not ask for (his request, 2026-08-25).
    @objc func goToSession(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        guard tabs.indices.contains(index) else { return }
        selectTab(index)
    }

    private func installActiveTabView() {
        // Everything EXCEPT the two views that live over the terminal rather
        // than in a tab. Removing them here is what made the approval card
        // invisible: it was created once, added once, and thrown away by the
        // first tab install — the dump said it was showing and the screenshot
        // said it was not, which is the exact shape of a view with no
        // superview (measured 2026-08-20).
        for view in terminalHost.subviews
        where view !== card && view !== findBar && view !== chatPage {
            view.removeFromSuperview()
        }
        guard let tab = activeTab else { return }
        let view = tab.container ?? tab.tree.makeView()
        tab.container = view
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
        // Reordered, not re-added: the constraints stay, and the card and the
        // find bar keep sitting over whatever tab is in front.
        // La pagina della chat sta SOPRA il terminale e SOTTO la card: una
        // domanda di permesso deve restare sopra tutto, anche mentre leggi.
        terminalHost.addSubview(chatPage, positioned: .above, relativeTo: view)
        if chatPage.translatesAutoresizingMaskIntoConstraints {
            chatPage.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                chatPage.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
                chatPage.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
                chatPage.topAnchor.constraint(equalTo: terminalHost.topAnchor),
                chatPage.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
            ])
        }
        terminalHost.addSubview(card, positioned: .above, relativeTo: chatPage)
        if let findBar { terminalHost.addSubview(findBar, positioned: .above, relativeTo: card) }
        setActivePane(tab.activePane, in: tab)
        refresh()
    }

    private func setActivePane(_ pane: PaneView, in tab: Tab) {
        tab.activePane = pane
        for candidate in tabs.flatMap(\.panes) {
            let active = candidate === pane
            candidate.setActive(active)
            candidate.session.isFocused = active
        }
        inspector.show(pane.session)
        refresh()
    }

    func paneDidRequestFocus(_ pane: PaneView) {
        guard let tab = tabs.first(where: { $0.panes.contains(where: { $0 === pane }) })
        else { return }
        if let index = tabs.firstIndex(where: { $0 === tab }), index != activeTabIndex {
            activeTabIndex = index
            installActiveTabView()
        }
        setActivePane(pane, in: tab)
    }

    /// True when this window held the session and brought it forward. The
    /// app asks every window in turn, so a click on a notification lands on
    /// the pane that sent it whichever window that is.
    @discardableResult
    func focusSession(id: UUID) -> Bool {
        for (index, tab) in tabs.enumerated() {
            if let pane = tab.panes.first(where: { $0.session.id == id }) {
                activeTabIndex = index
                tab.activePane = pane
                installActiveTabView()
                window?.makeKeyAndOrderFront(nil)
                // Scelta una sessione — dal pannello di sinistra o dal clic su
                // una notifica — la tastiera va dove si scrive (ISC-188). La
                // riga qui sopra può già aver fatto scattare
                // `windowDidBecomeKey`: la regola è idempotente, e chiamarla
                // qui è ciò che la rende vera anche a finestra già davanti.
                restituisciTastieraAllaBolla()
                return true
            }
        }
        return false
    }

    /// The pane the keyboard is talking to, for the notifier's question about
    /// what the user is already looking at.
    var activeSessionID: UUID? { activeTab?.activePane.session.id }

    // MARK: - Talking back to the session

    /// Synthesised input shared by the live test channel and the door. Both
    /// travel through the terminal view's key path, just like a real press.
    func sendSyntheticText(_ text: String, to view: NSView) {
        for character in text {
            let string = String(character)
            let code: UInt16 = character == "\n" ? 36 : 0
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: string, charactersIgnoringModifiers: string,
                isARepeat: false, keyCode: code) else { continue }
            view.keyDown(with: event)
        }
    }

    func sendSyntheticKey(_ spec: String, to view: NSView) {
        var flags: NSEvent.ModifierFlags = []
        var name = spec
        while let dash = name.firstIndex(of: "-") {
            let modifier = String(name[..<dash])
            switch modifier {
            case "ctrl": flags.insert(.control)
            case "alt", "opt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "cmd": flags.insert(.command)
            default: break
            }
            name = String(name[name.index(after: dash)...])
        }
        let table: [String: (UInt16, String)] = [
            "return": (36, "\r"), "escape": (53, "\u{1b}"), "tab": (48, "\t"),
            "space": (49, " "), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"),
            "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
            "backspace": (51, "\u{8}"), "q": (12, "q"), "c": (8, "c"), "d": (2, "d"),
        ]
        guard let (code, characters) = table[name] else {
            NSLog("T4A: unknown key %@", name)
            return
        }
        var sent = characters
        if flags.contains(.control), let scalar = characters.unicodeScalars.first,
           let control = UnicodeScalar(scalar.value & 0x1f) {
            sent = String(Character(control))
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: sent, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else { return }
        view.keyDown(with: event)
    }

    /// Answers the agent's own prompt, by typing at it.
    ///
    /// This is the whole of ISC-29 and the reason it is honest: T4A does not
    /// decide whether the tool may run, and it holds no permission state of
    /// its own. It puts the digit and the Return into the pty, the agent's
    /// prompt reads them exactly as it reads a person's fingers, and the
    /// agent decides. Nothing here can grant anything.
    func answerApproval(_ keystrokes: String) {
        guard let session = activeTab?.activePane.session else { return }
        // The card is a PICTURE of a question, taken when the scan ran; the
        // click arrives later (ISC-127). In between the agent may have
        // finished, scrolled the box away, or drawn a different question in
        // the same place — and any shell output shaped like a permission can
        // raise a card in the first place, so "the card is up" is not evidence
        // that anybody is waiting. A digit and a Return typed into a terminal
        // whose question has moved on go to whatever is reading the tty now.
        //
        // So the screen is read again, here, at the moment of the keystroke,
        // and the keys go down only if it is still asking the same thing.
        // Failing towards NOT SENDING is the only acceptable direction: a
        // permission nobody answered is still on the screen and can be
        // answered by typing at it, which is what every terminal does.
        if let shown = card.shownApproval {
            let now = session.agent?.approvalOnScreen(on: session.backend.grid)
            guard let now, now.asksTheSameAs(shown) else {
                session.agent?.withdrawApproval()
                card.withdraw(now == nil
                    ? "that question is no longer on the screen"
                    : "the screen is asking something else now: \(now!.title)")
                refresh()
                return
            }
        }
        session.backend.send(text: keystrokes)
        session.backend.focus()
        // The box is about to leave the screen; the scan that notices is the
        // one the next bytes trigger, and this one closes the card at once so
        // it does not sit over an answered question.
        card.show(nil, kind: "")
        refresh()
    }

    /// Types a message at the selected session (ISC-42).
    ///
    /// Same rule as the card: the text goes into the pty. There is no channel
    /// to the agent, no API call and no protocol of ours — the prompt that
    /// receives it is the real one, and a session whose terminal T4A closed
    /// mid-sentence would still have the words.
    @discardableResult
    func compose(_ text: String) -> Bool {
        compose(ComposerSubmission(written: text))
    }

    /// The composer may carry an attachment as a visible token. Its path is a
    /// paste object of its own, while `text` remains the fully expanded string
    /// used by the receipt and history.
    @discardableResult
    private func compose(_ submission: ComposerSubmission) -> Bool {
        let text = submission.text
        guard let session = activeTab?.activePane.session, !text.isEmpty else { return false }
        // Anche i comandi locali passano da questa porta: dentro una domanda
        // `/model` sarebbe testo destinato alla domanda, non un comando. La
        // decisione precede qualunque scrittura, ricevuta o cronologia.
        if let rifiuto = motivoRifiuto(per: session) {
            rifiutoComposer = rifiuto
            session.backend.focus()
            refresh()
            return false
        }
        rifiutoComposer = ""
        let comandoLocale = slashCatalog.isLocalCommand(text)
        // Read BEFORE a byte goes out, because sending is what changes it: the
        // text lands in the agent's input box, the box stops being empty, and
        // the cover correctly lets go — so a reading taken afterwards would
        // say the line was never covered at the exact moment it matters.
        let wasCovered = session.pureChat && session.hostedPrompt != nil
        // ONE object, and the Return only once its last byte has left
        // (ISC-166). It used to be `send(text:)` plus a Return on an 80 ms
        // timer, and both halves were wrong for a long message. The text went
        // down the pty as raw keystrokes, which the tty cuts into 1022-byte
        // reads: a TUI that keeps one read of a burst keeps the tail, and a
        // 5275-byte message of his arrived as its last 165 bytes, from the
        // middle of a word (measured 2026-08-25 — the surviving fragment began
        // at byte 5110, which is exactly where the sixth read began). And the
        // newlines in it were Returns, so a message written on several lines
        // was several messages. Bracketed paste answers both: the far side is
        // told this is one object to accumulate to the end marker, newlines
        // included. The 80 ms gap is kept — measured on 2026-08-20, and it is
        // the same move `claude` makes writing into another session's pty,
        // where the gap is 10 ms — but it now starts when the message is
        // actually out, not when we asked for it to go.
        session.backend.compose(payloads: submission.payloads, submitAfter: 0.08)
        // La ricevuta, subito: `annotaInvio` decide da sé se serve, cioè solo
        // a turno aperto (ISC-194).
        session.annotaInvio(text, comandoLocale: comandoLocale)

        // Where the keyboard goes afterwards, and it is the whole of ISC-158.
        //
        // It used to go back to the terminal, always. That is right while the
        // agent's own input line is on the screen — you sent one line through
        // the bubble and the place to type is the line you can see. It is
        // exactly wrong while «pure chat» is covering that line: the next
        // thing typed goes into an input box nobody can see, the box then has
        // text in it, and the cover correctly gets out of the way — so the
        // row he has been asking to be rid of for two days comes back, with
        // his own words in it, and nothing on screen says why (ISC-157).
        // Measured before it was changed: `compose` then five characters
        // through the responder chain left `❯ pippo` on the grid and the
        // cover reporting «the prompt has text in it».
        //
        // The rule, said once: the keyboard belongs to the only input line a
        // person can see.
        if wasCovered {
            composer.focus()
        } else {
            session.backend.focus()
        }
        session.markSeen()
        refresh()
        return true
    }

    /// Apre un turno e lo mette sotto gli occhi (ISC-168).
    ///
    /// Il turno arriva dalla mappa, che lo ha preso dalla sessione: la
    /// domanda e la risposta sono gia qui per intero, quindi non si va a
    /// cercarle da nessuna parte. Il responder da restituire alla chiusura e
    /// letto ADESSO, prima che il lettore prenda la tastiera.
    func openTurn(_ turn: AgentTurn) {
        // Con la pagina della chat accesa il turno è già sulla pagina: ci si
        // porta sopra e si aprono i blocchi che vale la pena vedere, invece di
        // coprire tutto con una seconda superficie che dice le stesse cose.
        if !chatPage.isHidden {
            chatPage.vai(a: turn.id)
            return
        }
        turnReader.onClose = { [weak self] in self?.refresh() }
        turnReader.open(turn, restoring: window?.firstResponder,
                        attesa: activeTab?.activePane.session.rigaDiAttesa)
    }

    /// Chiude il lettore, se e aperto. Chiamato anche da Esc di finestra.
    func closeTurnReader() { turnReader.close() }

    /// ⌘L — put the keyboard back in the bubble (ISC-158).
    ///
    /// Clicking it was the only way in, and a control a mouse alone can reach
    /// is a control you lose the moment your hands are on the keys. It also
    /// covers the case the rule above cannot: pure chat off, the bubble on
    /// screen, and a person who would rather type there than in the terminal.
    @objc func focusComposer() {
        guard composerShouldShow else { return }
        composer.focus()
    }

    // MARK: - I comandi `/` sopra la bolla (ISC-187)

    /// La cartella di configurazione che l'agente legge davvero.
    ///
    /// `$CLAUDE_CONFIG_DIR` dell'ambiente di T4A quando c'è: chi lo esporta ha
    /// spostato comandi, skill e plugin altrove, e un catalogo che legge
    /// comunque `~/.claude` gli offrirebbe i comandi di qualcun altro.
    private static var configuredAgentDirectory: URL {
        if let named = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !named.isEmpty {
            return URL(fileURLWithPath: (named as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
    }

    /// La fonte dell'elenco è l'agente agganciato, e nient'altro.
    ///
    /// Chiamata da `refresh()`, cioè spesso: la firma qui sotto è ciò che
    /// impedisce di rileggere il disco a ogni giro. Cambia quando cambia il
    /// fornitore, il binario o la cartella — e il binario cambia anche quando
    /// il pid arriva in ritardo, che è il passo 0 di questa fetta.
    private func aggiornaCatalogo(_ active: Session?) {
        guard !catalogoForzato else { return }
        guard let agent = active?.agent, agent.isAttached else {
            guard catalogoSeguito != nil else { return }
            catalogoSeguito = nil
            slashCatalog.clear()
            return
        }
        let firma = [agent.kind, agent.executable?.path ?? "", agent.cwd?.path ?? ""]
        guard firma != catalogoSeguito else { return }
        catalogoSeguito = firma
        slashCatalog.refresh(executable: agent.executable,
                             configDirectory: Self.configuredAgentDirectory,
                             projectDirectory: agent.cwd)
    }

    /// L'elenco si apre quando il testo della bolla è un comando a metà.
    ///
    /// `matches` risponde a tutte e tre le regole del brief in una riga sola —
    /// niente `/` iniziale, uno spazio dopo la parola, zero corrispondenze —
    /// perché la domanda «questo testo è ancora un nome da completare» è del
    /// catalogo e non della finestra. Qui restano le due condizioni che il
    /// catalogo non può conoscere: la tastiera è nella bolla, e nessun tasto
    /// ha appena chiuso l'elenco.
    private func aggiornaElencoComandi() {
        let hasKeyboard = window?.firstResponder === composer.field
        let voci = elencoScartato || !hasKeyboard || composer.isHidden
            ? [] : slashCatalog.matches(composer.text)
        slashList.show(voci)
        // Quante righe ci stanno DAVVERO fra la bolla e la cima della scena.
        // Il tetto è otto, ma una finestra bassa ne concede meno, e un elenco
        // che esce dalla finestra è un elenco che non si legge.
        //
        // `stage` NON è capovolta, quindi lo spazio sopra la bolla è
        // `altezza - bordo alto della bolla`, non `frame.minY`. Con la seconda
        // formula, che è quella che avevo scritto, veniva sempre ZERO — la
        // bolla è ancorata in fondo alla scena — e l'elenco usciva alto 12
        // punti, cioè la sola imbottitura: nessuna riga, e `shown` VERO lo
        // stesso. Se ne è accorta la foto, non il dump (27/08).
        let sopra = stage.bounds.height - composer.frame.maxY - 12
        let capienza = Int(max(0, sopra) / SlashListView.rowHeight)
        let righe = min(slashList.visibleRows, capienza)
        let mostra = !voci.isEmpty && righe > 0
        slashListHeight.constant = mostra ? slashList.height(cappedAt: righe) : 0
        slashList.isHidden = !mostra
        composer.listaAperta = mostra
        slashList.needsDisplay = true
    }

    /// Chiude l'elenco senza toccare il testo, e non lo riapre da solo.
    private func chiudiElenco() {
        elencoScartato = true
        aggiornaElencoComandi()
    }

    /// Mette il comando scelto nella bolla, e — con Invio — lo manda.
    ///
    /// Tab lascia `/nome ` con lo spazio, pronto per gli argomenti; Invio
    /// manda `/nome` per la via di sempre (`submit` → `fire` → `compose`), che
    /// è il solo modo perché il PTY riceva quello che riceve quando scrivi il
    /// comando a mano.
    private func completaComando(at index: Int, andSend send: Bool) {
        guard slashList.items.indices.contains(index) else { return }
        let name = slashList.items[index].name
        composer.text = "/" + name + (send ? "" : " ")
        // Dopo il testo, non prima: assegnarlo fa scattare `onTextChange`, che
        // azzera il latch. Chiuso qui, resta chiuso.
        chiudiElenco()
        if send {
            if composer.submit() { composer.focus() }
        } else {
            composer.focus()
        }
    }

    /// I tasti mentre l'elenco è aperto. `true` vuol dire «l'ho preso io».
    ///
    /// Chiamato dalla bolla PRIMA di tutto il resto, quindi qui si risponde
    /// `false` con scrupolo: ogni `true` di troppo è un tasto che non arriva
    /// né alla scatola di testo né al processo.
    private func elencoTasti(_ event: NSEvent) -> Bool {
        guard !slashList.isHidden, !slashList.items.isEmpty else { return false }
        // Niente ⌘: ⌘A, ⌘V e compagnia restano della scatola di testo.
        guard !event.modifierFlags.contains(.command) else { return false }
        switch event.keyCode {
        case 126: slashList.move(by: -1); return true            // ↑
        case 125: slashList.move(by: 1); return true             // ↓
        case 48:                                                  // Tab
            completaComando(at: slashList.selection, andSend: false)
            return true
        case 36, 76:                                              // Invio
            completaComando(at: slashList.selection, andSend: true)
            return true
        case 53:                                                  // Esc
            // Solo l'elenco. Il `^[` al processo è il SECONDO Esc, quando qui
            // non c'è più niente di aperto e questa funzione risponde `false`
            // (ISC-171, intatta).
            chiudiElenco()
            return true
        default: return false
        }
    }

    /// Il catalogo puntato a mano, per il banco. Solo nel bundle dei banchi.
    func testSlashCatalog(_ rest: String) {
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard let source = parts.first, !source.isEmpty else {
            catalogoForzato = false
            catalogoSeguito = nil
            slashCatalog.clear()
            aggiornaElencoComandi()
            return
        }
        catalogoForzato = true
        let fixture = URL(fileURLWithPath: source)
        // La cartella della fixture fa da cartella di configurazione: non ha
        // né `commands/` né `skills/` né plugin, quindi l'elenco che il banco
        // misura è ESATTAMENTE quello che sta dentro il file, senza i comandi
        // di questa macchina in mezzo.
        slashCatalog.refresh(executable: fixture,
                             configDirectory: fixture.deletingLastPathComponent(),
                             projectDirectory: parts.count > 1
                                 ? URL(fileURLWithPath: parts[1]) : nil)
    }

    /// Quello che il dump dice dell'elenco: cosa c'è, cosa è scelto, e in che
    /// stato è il catalogo che lo riempie.
    func testSuggestionsState() -> [String: Any] {
        var result = slashList.testState
        result["filter"] = composer.text
        switch slashCatalog.state {
        case .idle: result["state"] = "idle"
        case .scanning: result["state"] = "scanning"
        case .ready(let builtin, let declared):
            result["state"] = "ready"
            result["builtin"] = builtin
            result["declared"] = declared
        case .unavailable(let reason):
            result["state"] = "unavailable"
            // Separato dallo stato, così un polo può pretendere la parola
            // esatta senza dover leggere dentro una frase.
            result["reason"] = reason
        }
        return result
    }

    /// Da dove vengono i built-in dell'elenco, per il dump dell'agente.
    var slashSource: String {
        slashCatalog.commands.first { $0.source == .builtin }?.origin ?? ""
    }

    /// Who holds the keyboard, by the name of the class. A claim about focus
    /// is a claim about the first responder, and the honest place to read it
    /// is the window.
    func testFirstResponder() -> String {
        guard let responder = window?.firstResponder else { return "none" }
        // A text field hands editing to a shared field editor, so the first
        // responder is an NSTextView whose delegate is the field. Reported as
        // the field, because «the composer has the keyboard» is the question
        // and «NSTextView» is not an answer to it.
        if responder === composer.field { return "ComposerField" }
        return String(describing: type(of: responder))
    }

    /// The pane the composer is aimed at, by name.
    private var composerTarget: String {
        guard let session = activeTab?.activePane.session else { return "" }
        if let agent = session.agent, agent.isAttached { return agent.kind }
        return session.foreignProgramName ?? session.shellName
    }

    // MARK: - Refresh

    private func refresh() {
        let sessions = tabs.flatMap(\.sessions)
        let active = activeTab?.activePane.session
        // Una volta mostrato, il rifiuto segue lo stato già cacheato dalla
        // scansione: appena la domanda finisce, la scatola torna o l'agente
        // lavora, non serve un secondo Invio per farlo sparire (ISC-228).
        if !rifiutoComposer.isEmpty {
            rifiutoComposer = active.flatMap { motivoRifiuto(per: $0) } ?? ""
        }
        band.waitingCount = sessioniInAttesa.count
        // The count only while an agent lives in some pane (25/08): a plain
        // terminal carries no «0 waiting».
        band.showsWaiting = sessions.contains { $0.agent?.isAttached == true }
        updateTabStripVisibility()
        band.title = active?.displayName ?? ""
        band.path = active.map { Self.shorten($0.workingDirectory.path) } ?? ""
        rail.reload(sessions: sessions, selected: active)
        // The card belongs to the pane the keyboard is on: an approval waiting
        // in a pane you are not looking at is a NOTIFICATION, not a dialog
        // over the terminal you are typing in.
        // La card appartiene alla pagina (ISC-232, suo, 28/08 23:08: «questo
        // non serve più in questo modo»). Con la griglia classica la domanda
        // di claude è già lì, intera e rispondibile dalla tastiera: una card
        // sopra la copre con un doppione. Con la pagina accesa resta la
        // maniglia cliccabile che era. La rotaia e il conteggio «waiting»
        // continuano a leggere `approval`, quindi il segno non cambia.
        let cardVisibile = config.bool(.chatPage) ? active?.agent?.approval : nil
        card.show(cardVisibile, kind: active?.agent?.kind ?? "")
        inspector.foldedTurns = active?.foldedTurns ?? []
        aggiornaPaginaChat(active)
        turnReader.aggiorna(attesa: active?.rigaDiAttesa)
        aggiornaTastiera(active)
        composer.describe(target: composerTarget)
        applyComposerMode()
        // Dopo `applyComposerMode`, che decide se la bolla c'è e quanto è
        // alta: l'elenco si appoggia sul suo bordo e non esiste senza di lei.
        aggiornaCatalogo(active)
        aggiornaElencoComandi()
        // Dopo l'elenco, perché quando l'elenco è aperto la ricevuta si toglie
        // di mezzo (ISC-194).
        aggiornaCoda(active)
        tabStrip.reload(titles: tabs.map { $0.activePane.session.displayName },
                        selected: activeTabIndex,
                        segni: tabs.map { segnoDella(scheda: $0) },
                        animationsEnabled: config.bool(.motion))
        aggiornaMenuAtteseSeAperto()
        inspector.reload()
        refreshDash(active: active, sessions: sessions)
        updateDurationTimer()
    }

    /// La ricevuta di ciò che è già partito e non è ancora stato preso in
    /// mano (ISC-194).
    ///
    /// La potatura sta qui e non in un timer: la coda cambia solo quando
    /// cambia lo stato dell'agente, e `refresh` gira su ogni cambio di stato.
    private func aggiornaCoda(_ active: Session?) {
        active?.potaCoda()
        let messaggi = active?.messaggiInCoda ?? []
        queuedView.mostra(messaggi)
        refusalView.mostra(riga: rifiutoComposer)
        let mostraRifiuto = !rifiutoComposer.isEmpty && !composer.isHidden
            && slashList.isHidden
        let mostraCoda = !messaggi.isEmpty && !composer.isHidden && slashList.isHidden
            && !mostraRifiuto
        refusalHeight.constant = mostraRifiuto ? QueuedView.height : 0
        refusalView.isHidden = !mostraRifiuto
        queuedHeight.constant = mostraCoda ? QueuedView.height : 0
        queuedView.isHidden = !mostraCoda
    }

    /// Il motivo per cui la bolla non può consegnare testo a questo pannello.
    /// Senza agente non c'è rifiuto: in modalità `always` una shell nuda deve
    /// continuare a ricevere dalla bolla.
    private func motivoRifiuto(per session: Session) -> String? {
        guard let agent = session.agent, agent.isAttached else { return nil }
        if staChiedendo(session) {
            return "il terminale ti sta facendo una domanda: rispondi lì (↑ ↓, numeri, Invio, Esc)"
        }
        guard !session.rigaIngressoDisponibile else { return nil }
        return S.agentInputOffScreen
    }

    /// È connesso questo pannello?
    ///
    /// Due modi, e sono due perché la barra ha due sorgenti indipendenti.
    /// L'adattatore è agganciato — c'è un agente vero che scrive un file che
    /// stiamo leggendo — oppure il fornitore dei fatti ha emesso una riga che
    /// riguarda QUESTA sessione, che è l'unico segno che ha riconosciuto il
    /// pannello invece di rispondere a vuoto.
    ///
    /// Perché una riga per-sessione e non «il fornitore ha risposto»: un
    /// fornitore risponde sempre, anche quando la sessione non la conosce, e
    /// in quel caso le sue righe parlano della macchina e non di questo
    /// pannello. Erano esattamente i fatti che riempivano la barra sopra una
    /// shell nuda il 25/08 — `ACTIVE HAIKU SONNET OPUS FABLE`, `MEMORY OK`,
    /// `5HR 8%` — tutti veri, e nessuno di questa sessione.
    ///
    /// Le due chiavi guardate sono quelle del protocollo dei fatti, non di un
    /// fornitore preciso: `session` è il titolo che solo un riconoscimento
    /// esatto produce, `context` è la lettura per-sessione per eccellenza, e
    /// un fornitore che non ha riconosciuto la sessione la manda col
    /// trattino. Un trattino non è una lettura, quindi non connette niente.
    private func paneIsConnected(_ session: Session) -> Bool {
        if let agent = session.agent, agent.isAttached { return true }
        for key in ["session", "context"] {
            guard let row = facts.rows[key] else { continue }
            // Si guarda TOKEN per token, non il testo intero della riga. Il
            // fornitore dei fatti scrive la riga del contesto come due token,
            // la didascalia `CONTEXT` e poi il valore, e quando la sessione
            // non la conosce il valore è un trattino: il testo intero fa
            // `CONTEXT —`, che confrontato con `—` non è mai uguale, e la
            // shell nuda risultava connessa. Misurato il 26/08 01:04 sulla
            // sua configurazione (dieci celle dipinte, bolla alta 44 con
            // `composer-mode = agent`), dopo che il banco l'aveva provata
            // solo su una configurazione senza fornitore. Il polo A2 di
            // `bench-rows.sh` è quel caso, e resta rosso senza queste righe.
            for token in row.tokens {
                let text = token.text.trimmingCharacters(in: .whitespaces)
                if text.isEmpty || text == "—" || text == "-" { continue }
                // La didascalia della riga non è una lettura.
                if text.caseInsensitiveCompare(key) == .orderedSame { continue }
                return true
            }
        }
        return false
    }

    /// Un numero di token come lo scrive una barra: `197k`, `12.4k`, `842`.
    ///
    /// Mai in percentuale, e la ragione non è di gusto: la percentuale vuole
    /// il MASSIMO della finestra, che nel transcript non c'è. Dedurlo dal
    /// nome del modello sarebbe la stima che ISC-149 vieta, e sbaglierebbe di
    /// cinque volte il giorno che una sessione gira con una finestra più
    /// larga di quella solita della sua famiglia.
    static func compactTokens(_ count: Int) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 {
            let thousands = Double(count) / 1_000
            // Un decimale finché serve a distinguere, poi non serve più: fra
            // `197k` e `197.4k` la seconda cifra è rumore in una cella larga
            // quanto una parola.
            return thousands < 100
                ? String(format: "%.1fk", thousands)
                : "\(Int(thousands.rounded()))k"
        }
        return String(format: "%.1fM", Double(count) / 1_000_000)
    }

    private func refreshDash(active: Session?, sessions: [Session]) {
        // ISC-173 — finché il pannello non è connesso, la barra non dice
        // NIENTE: né le righe native, né quelle del fornitore, né `DIR`, e
        // nemmeno gli allarmi (sua decisione esplicita del 25/08, «gli
        // allarmi solo se claude o lifeos aperto»).
        //
        // È il rovescio di ISC-149, non la sua smentita, e la distinzione sta
        // nella domanda a cui rispondono. ISC-149 dice cosa fa una riga
        // ACCESA quando non ha una lettura: disegna un trattino, perché un
        // interruttore che hai messo su deve fare qualcosa. Questa dice
        // quando quella domanda ha senso: sopra una shell nuda non c'è
        // sessione di cui dire niente, e quattordici trattini in fila non
        // sono onestà, sono una barra che occupa lo schermo per dire che non
        // sa nulla. Appena il pannello si connette la barra torna intera e
        // ISC-149 ricomincia a valere, allarmi che bucano lo spento compresi.
        guard let active, paneIsConnected(active) else {
            dash.values = [:]
            dash.slotLayout = dashLayout
            dash.alarms = []
            return
        }
        var values: [String: DashCell] = [:]
        // Every row a person can switch ON is given a cell before anything is
        // read, so that a switch which is on is a row which is DRAWN (ISC-149).
        //
        // This reverses the rule the bar was built with — «a key with no
        // reading is absent rather than invented» — and the reversal is the
        // point. That rule is right about a VALUE and wrong about a ROW: with
        // a bare shell in the pane, `Agent turns`, `Session state`, `Agent` and
        // `Model` were switched on, sitting on their default lines, and drew
        // nothing at all (measured 2026-08-22, four of the fourteen). Nothing
        // is invented here: a dash says the app has no reading right now, which
        // is a fact, where an absent cell says a switch you set did nothing.
        //
        // The label comes from the catalogue and not from the code below,
        // because the code below only runs when there IS a reading.
        //
        // BUILT-IN rows only, and the exception is not tidiness. A provider's
        // row exists because the provider named it; a row it named once and
        // has stopped naming is a GHOST, and ISC-143 settled what happens to
        // one — it has no value, it is not painted, and a line holding nothing
        // but ghosts does not open at all, because a whole line costs the
        // window twenty-one points. Giving ghosts a dash undid all three at
        // once (caught by `bench-facts` the same night, three ghosts painted
        // and two lines opened for them). A terminal answers for its own rows;
        // it does not answer for a program it did not write.
        for entry in DashCatalog.entries where !entry.transient && !entry.discovered {
            values[entry.key] = DashCell(key: entry.key, label: entry.bar,
                                         value: "—", placeholder: true)
        }
        func put(_ key: String, _ label: String, _ value: String,
                 alarm: DashCell.Alarm = .none, live: Bool = false) {
            values[key] = DashCell(key: key, label: label, value: value,
                                   alarm: alarm, live: live)
        }
        let failed = active.blocks.failureCount
        put("blocks", "BLOCKS", "\(active.blocks.blocks.count)")
        put("failed", "FAILED", failed == 0 ? "0" : "\(failed) failed",
            alarm: failed == 0 ? .none : .critical)
        let grid = active.backend.grid
        put("scrollback", "SCROLLBACK",
            "\(grid.retainedLineCount) of \(config.int(.scrollbackLines))")
        put("grid", "GRID", "\(grid.columns)×\(grid.rows)")
        put("dir", "DIR", Self.shorten(active.workingDirectory.path))
        put("proc", "PROC", active.backend.foregroundProcessName() ?? "—")
        // The bar says what a terminal KNOWS. Before the adapter attached,
        // the model was absent rather than invented (the Phase 2 note);
        // now it is present because the session's own file says so.
        if let agent = active.agent, agent.isAttached {
            put("turns", "TURNS", "\(agent.turns.count)")
            put("state", "STATE", active.activity.rawValue,
                alarm: active.isWaitingForYou ? .warn : .none)
            put("agent", "AGENT", agent.kind)
            if !agent.model.isEmpty {
                // The file writes a long name; the bar reads two words
                // (ISC-104.3). The shortening belongs to the adapter, so
                // the core names no vendor (ISC-123).
                put("model", "MODEL", agent.shortModel)
            }
            // Le tre di ISC-172. Ognuna solo se l'adattatore ha davvero la
            // lettura: un fornitore che non la tiene risponde nil, e la
            // cella resta il segnaposto col trattino messo qui sopra.
            if let context = agent.contextTokens {
                put("context", "CONTEXT", Self.compactTokens(context))
            }
            if let output = agent.outputTokens {
                put("output", "OUTPUT", Self.compactTokens(output))
            }
            if let effort = agent.effort, !effort.isEmpty {
                put("effort", "EFFORT", effort)
            }
        }
        if let work = Self.runningWork(in: active) {
            if !dashLayout.off.contains("worker") {
                put("worker", "WORKER", work, live: true)
            }
        }
        for key in facts.order {
            guard let row = facts.rows[key] else { continue }
            // An alarm is read from the TONES, not from a switch and not from
            // the words: `critical` and `warn` are the two reds of ISC-103, so
            // a provider row that is complaining punches back through the off
            // list exactly like a built-in one (ISC-104.3).
            let tones = Set(row.tokens.compactMap(\.tone))
            var alarm: DashCell.Alarm = .none
            if tones.contains(.critical) { alarm = .critical }
            else if tones.contains(.warn) { alarm = .warn }
            if facts.isStale { alarm = .none }
            values[DashCatalog.factKey(key)] = DashCell(
                key: DashCatalog.factKey(key),
                // NO label, ever. `#name` is the name in the settings and
                // nothing else: a provider's reading already says what it is
                // (`MEMORY OK`, `CONTEXT 17%`, `5HR 7%`), and printing the
                // row's name in front of it prints the caption twice and
                // spends the width on it. Measured on nine real rows: with the
                // names drawn, five fit and four were dropped; without, all
                // nine fit.
                label: "",
                value: row.text, alarm: alarm, tokens: row.tokens, stale: facts.isStale)
        }
        let shellPath = config.string(.shell).isEmpty
            ? LoginShell.path() : config.string(.shell)
        put("shell", "SHELL", (shellPath as NSString).lastPathComponent)
        put("blocks-on", "OSC133", config.bool(.shellIntegration) ? "on" : "off")
        put("panes", "PANES", "\(sessions.count) in \(tabs.count)")
        put("theme", "THEME", config.string(.theme))
        // ISC-192 — la nativa cede alla gemella del fornitore, e cede QUI,
        // dopo che tutti l'hanno messa. Un posto solo, alla fine, invece di
        // una guardia dentro ognuno dei `put` che la scrivono: la cella nasce
        // in tre punti diversi (il segnaposto col trattino, la lettura
        // dell'adattatore, e il segnaposto di nuovo quando la lettura manca) e
        // una guardia per punto è una guardia che il quarto punto non avrà.
        for key in DashCatalog.superseded { values.removeValue(forKey: key) }
        dash.values = values
        dash.slotLayout = dashLayout
        dash.alarms = factsAlarms(values: values)
    }

    /// The cells the bar shows whatever the layout says, in the order they are
    /// drawn (ISC-145). A provider that will not start comes first, because a
    /// provider that is not running is the reason every other reading is
    /// missing, and reading the symptoms before the cause is backwards.
    private func factsAlarms(values: [String: DashCell]) -> [DashCell] {
        var out: [DashCell] = []
        if facts.lastFailure != nil {
            let text = Self.factsFailureText(facts)
            // Carried as a TOKEN as well as a value, so the colour it came out
            // is recorded by the drawing (ISC-139) and a bench can read the
            // warning's ink instead of taking the app's word for its tone.
            out.append(DashCell(key: "facts", label: DashView.alarmMark + " FACTS",
                                value: text,
                                alarm: .warn,
                                tokens: [FactToken(text: text, tone: .warn)],
                                pinned: true))
        }
        // Then every provider reading that is complaining and is NOT already
        // on the bar (ISC-146): switched off, or sitting on no line at all.
        // In the provider's own order, because that is the order it chose to
        // tell us about them, and once each — a reading that IS drawn where
        // the user put it does not get a second cell here.
        for key in facts.order {
            let dashKey = DashCatalog.factKey(key)
            guard let cell = values[dashKey], cell.alarm != .none else { continue }
            let drawn = dashLayout.slot(of: dashKey) != nil
                && !dashLayout.off.contains(dashKey)
            guard !drawn else { continue }
            var lane = cell
            lane.pinned = true
            // The mark goes in the LABEL and not into a drawing step of its
            // own (ISC-152). A provider row prints no caption, so its label is
            // empty and the mark is the whole of it; a row that has one gets
            // the mark in front of it. Either way it is measured, placed,
            // truncated and reported by exactly the code every other cell
            // goes through — and it comes out in the alarm's own colour,
            // because a label beside a complaining value is already painted
            // in the value's tone.
            lane.label = lane.label.isEmpty
                ? DashView.alarmMark : DashView.alarmMark + " " + lane.label
            out.append(lane)
        }
        return out
    }

    /// What that cell says. Short on purpose: the whole sentence — the exit
    /// status AND the line the program printed before dying — is in
    /// `problems`, where a person goes to read it. The bar's job is to say
    /// that the thing is broken and roughly how, in the width of a cell.
    private static func factsFailureText(_ facts: FactsProvider) -> String {
        let head: String
        if facts.lastTimedOut {
            head = "TIMED OUT"
        } else if facts.lastExit == 127 {
            head = "EXIT 127 · NOT ON PATH"
        } else if facts.lastExit != 0 {
            head = "EXIT \(facts.lastExit)"
        } else {
            head = "CANNOT RUN"
        }
        // Three misses in a row is the moment ISC-139 stops calling the
        // readings current, and the cell has to say the same thing the dimmed
        // rows are saying.
        return facts.isStale ? head + " · NOT REFRESHING" : head
    }

    /// The one row that is HAPPENING rather than being reported: the tool the
    /// agent is running, or the command the shell is running, with how long it
    /// has been going. It exists only while it runs and then leaves, which is
    /// why it is built here and never stored in a line (ISC-104.3).
    private static func runningWork(in session: Session) -> String? {
        func seconds(_ since: Date) -> Int { max(1, Int(Date().timeIntervalSince(since).rounded())) }
        if let agent = session.agent, agent.isAttached,
           let turn = agent.turns.last, turn.isOpen,
           let tool = turn.tools.last(where: { $0.finishedAt == nil }) {
            return "\(tool.name) · \(seconds(tool.startedAt))s"
        }
        // Il blocco di shell aperto vale come «lavoro» SOLO in un pannello che
        // non ospita un agente, e la ragione è la sua foto del 27/08 alle 20:36:
        // `WORKER lifeos · 13578s`, cioè esattamente da quando aveva aperto T4A.
        // In una scheda agente il blocco aperto È il comando che ha lanciato la
        // sessione (`lifeos`, `claude`, `codex`): resta aperto per tutta la vita
        // del pannello per costruzione, quindi la cella non si spegneva mai e
        // contava l'app invece del lavoro. Con un agente agganciato il lavoro
        // sono i suoi tool, che il ramo qui sopra legge già (ISC-196).
        if session.agent?.isAttached != true,
           let block = session.blocks.openBlock, let started = block.startedAt,
           !block.command.isEmpty {
            let name = block.command.split(separator: " ").first.map(String.init) ?? block.command
            return "\(name) · \(seconds(started))s"
        }
        return nil
    }

    /// A running command's clock only ticks while something is running: a
    /// still terminal schedules nothing at all, which is what ISC-38 measures.
    private func updateDurationTimer() {
        let running = tabs.flatMap(\.panes).contains { $0.session.blocks.openBlock != nil }
        if running, durationTimer == nil {
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                Task { @MainActor in
                    self.tabs.flatMap(\.panes).forEach { $0.tickRunningDuration() }
                    self.inspector.reload()
                }
            }
        } else if !running, let timer = durationTimer {
            timer.invalidate()
            durationTimer = nil
        }
    }

    // MARK: - Window frame

    /// The window moved or changed size. Nothing is written here.
    ///
    /// Dragging a window edge produces a `windowDidResize` every few
    /// milliseconds, and the old code wrote the configuration file on each one
    /// — measured on 2026-08-20, a two-second drag rewrote it dozens of times
    /// a second, every write a create-plus-rename of a file nobody had asked
    /// to change. A size mid-drag is not a size the user chose; only the one
    /// under their finger when they let go is (ISC-106).
    private func noteFrameChanged() {
        guard let window else { return }
        frameChangeCount += 1
        frameSavePending = true
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil
        // A live drag ends with `windowDidEndLiveResize`, which flushes. A
        // programmatic change never gets that call, so it settles on a timer.
        guard !window.inLiveResize else { return }
        frameSaveTimer = Timer.scheduledTimer(withTimeInterval: Self.frameSettleDelay,
                                              repeats: false) { _ in
            Task { @MainActor in self.saveFrameNow() }
        }
    }

    /// Writes the frame, once, if there is anything to write.
    func saveFrameNow(force: Bool = false) {
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil
        guard let window, frameSavePending || force else { return }
        // Full screen is a shape the system imposed, not one the user picked.
        // Saving it means the next launch opens at the size of a display and
        // the size they had chosen is gone for good (ISC-109).
        guard !window.styleMask.contains(.fullScreen) else { return }
        frameSavePending = false
        config.set(.windowFrame, window.frameDescriptor)
    }

    // MARK: - Closing, with a question when it matters

    /// Puts the question as a sheet and runs `proceed` only on a yes.
    ///
    /// A sheet, not a modal panel: a modal run loop would freeze the test
    /// channel and every other window, and the question is about this window.
    private func confirm(closing running: [String], subject: S.CloseSubject,
                         then proceed: @escaping () -> Void) {
        guard let window else { proceed(); return }
        if closeConfirmation != nil { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: S.closeAnyway)
        alert.addButton(withTitle: S.cancel)
        renderCloseConfirmation(alert, running: running, subject: subject)
        closeConfirmation = (alert, proceed, running, subject)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.closeConfirmation = nil
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    private func renderCloseConfirmation(_ alert: NSAlert, running: [String],
                                         subject: S.CloseSubject) {
        alert.messageText = S.closeQuestion(subject: subject)
        let list = Set(running).sorted().joined(separator: ", ")
        alert.informativeText = S.closeRunningProcesses(names: list, count: running.count)
        if alert.buttons.indices.contains(0) { alert.buttons[0].title = S.closeAnyway }
        if alert.buttons.indices.contains(1) { alert.buttons[1].title = S.cancel }
    }

    /// Answers the sheet the way a click on one of its buttons does.
    func answerCloseConfirmation(_ yes: Bool) {
        guard let confirmation = closeConfirmation, let window else {
            NSLog("T4A: no close confirmation to answer")
            return
        }
        window.endSheet(confirmation.alert.window,
                        returnCode: yes ? .alertFirstButtonReturn : .alertSecondButtonReturn)
    }

    var isAskingToClose: Bool { closeConfirmation != nil }

    /// Closes the window without asking. The question has already been put.
    private func forceCloseWindow() {
        tabs.flatMap(\.sessions).forEach { $0.close() }
        tabs.removeAll()
        window?.close()
    }

#if DEBUG || T4A_TESTABLE
    // Everything to the #endif is the surface the benches drive and read,
    // and it is compiled only into a build that asked for it (ISC-128).
    // Without the channel in TestChannel.swift nothing can reach these
    // methods, but a remote control for a terminal should not be sitting
    // in the shipped binary waiting for a caller either.
    // MARK: - State the test channel reads

    func testActiveSurface() -> NSView? { activeTab?.activePane.session.backend.surface }

    /// Resizes the window, which is how a terminal's size really changes:
    /// the view relays out, the engine recounts its grid, and the pty is told.
    func testResize(_ spec: String) {
        let parts = spec.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let window else { return }
        var frame = window.frame
        frame.origin.y += frame.height - parts[1]
        frame.size = NSSize(width: parts[0], height: parts[1])
        window.setFrame(frame, display: true)
        window.layoutIfNeeded()
    }
    /// Drags across the terminal with real mouse events, in cell
    /// coordinates: `drag col,row col,row`. A selection made any other way
    /// proves the selection service works, not that the terminal does.
    func testDrag(_ spec: String) {
        let points = spec.split(separator: " ").map {
            $0.split(separator: ",").compactMap { Int($0) }
        }
        guard points.count == 2, points[0].count == 2, points[1].count == 2,
              let pane = activeTab?.activePane, let window else { return }
        let surface = pane.session.backend.surface
        let cellHeight = pane.session.backend.cellHeight
        let cellWidth = surface.bounds.width / CGFloat(max(1, pane.session.backend.grid.columns))

        func windowPoint(column: Int, row: Int) -> NSPoint {
            let local = NSPoint(x: (CGFloat(column) + 0.5) * cellWidth,
                                y: surface.bounds.height - (CGFloat(row) + 0.5) * cellHeight)
            return surface.convert(local, to: nil)
        }

        let from = windowPoint(column: points[0][0], row: points[0][1])
        let to = windowPoint(column: points[1][0], row: points[1][1])
        let number = window.windowNumber

        func event(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: number, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }

        if let down = event(.leftMouseDown, from) { surface.mouseDown(with: down) }
        for step in 1...8 {
            let fraction = CGFloat(step) / 8
            let point = NSPoint(x: from.x + (to.x - from.x) * fraction,
                                y: from.y + (to.y - from.y) * fraction)
            if let drag = event(.leftMouseDragged, point) { surface.mouseDragged(with: drag) }
        }
        if let up = event(.leftMouseUp, to) { surface.mouseUp(with: up) }
    }

    func testDelivered(to path: String) {
        Task { @MainActor in
            let payload: [String: Any] = [
                "settings": await Notifier.shared.settingsSummary(),
                "delivered": await Notifier.shared.delivered(),
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted]) else { return }
            try? data.write(to: URL(fileURLWithPath:
                path.isEmpty ? "/tmp/t4a-delivered.json" : path))
        }
    }

    func testNotifyClick(_ raw: String) {
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else { return }
        Notifier.shared.simulateActivation(sessionID: id)
    }

    /// Un doppio click in coordinate di FINESTRA (origine in basso a
    /// sinistra), consegnato dalla finestra come fa un dito: `dblclick x,y`.
    ///
    /// Esiste perché un doppio click sintetico posato con CoreGraphics non
    /// arriva sempre come tale — AppKit ricostruisce il conteggio dei click
    /// da sé — e senza questo comando «il doppio click non ingrandisce» non
    /// si può distinguere da «il mio click non era doppio» (26/08).
    func testDoubleClick(_ spec: String) {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let window else { return }
        let point = NSPoint(x: parts[0], y: parts[1])
        for count in 1...2 {
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: kind, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: count, pressure: kind == .leftMouseDown ? 1 : 0)
                else { return }
                window.sendEvent(event)
            }
        }
    }

    /// Clicks a point in the active pane, in the pane's own top-left
    /// coordinates: `clickpane x,y`. The gutter lives there, so this is how a
    /// failure tick gets clicked the way a person clicks it.
    func testClickPane(_ spec: String) {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let pane = activeTab?.activePane, let window else { return }
        // The spec is top-left, like everything else the tests talk about;
        // the pane is an ordinary unflipped NSView, so the y is turned over
        // here rather than leaving each caller to remember.
        let local = NSPoint(x: parts[0],
                            y: pane.isFlipped ? parts[1] : pane.bounds.height - parts[1])
        let inWindow = pane.convert(local, to: nil)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        // Through the window, so the hit test decides which view receives it —
        // clicking the view directly would skip the very thing being tested.
        window.sendEvent(down)
        if let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) {
            window.sendEvent(up)
        }
    }

    // MARK: - The chrome, as the bench sees it (ISC-104)

    /// `settings open|close|<category>`.
    func testSettingsCommand(_ rest: String) {
        switch rest.trimmingCharacters(in: .whitespaces) {
        case "open", "": openSettings()
        case "close": testCloseSettings()
        case let name where name.hasPrefix("shot "):
            testCaptureSettings(to: String(name.dropFirst(5)))
        case let name where name.hasPrefix("place "):
            testPlaceSettings(String(name.dropFirst(6)))
        case let name: testSettingsCategory(name)
        }
    }

    /// Brings the settings window to the front of EVERYTHING and puts it
    /// where it was asked to sit. A drag performed with real events lands on
    /// whatever window is on top at that point, so a bench that does not
    /// place and raise the window first is measuring another app.
    func testPlaceSettings(_ spec: String) {
        openSettings()
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        NSApp.activate(ignoringOtherApps: true)
        if parts.count == 4, let window = settings?.window {
            window.setFrame(NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]),
                            display: true)
        }
        settings?.window?.level = .floating
        settings?.window?.makeKeyAndOrderFront(nil)
        settings?.window?.orderFrontRegardless()
    }

    /// Has the settings window draw ITSELF into a PNG. Not a screen capture:
    /// the view renders into a bitmap, so the picture is of the app's own
    /// drawing and cannot accidentally photograph anything else on screen.
    func testCaptureSettings(to path: String) {
        guard let view = settings?.window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// La finestra come immagine, disegnata dalle VISTE e non dallo schermo:
    /// un banco che usasse `screencapture` avrebbe bisogno della finestra
    /// davanti, e la finestra sta sulla scrivania di qualcuno che lavora
    /// (MacAppRules §7).
    ///
    /// **Quello che questa foto NON contiene: il terminale.** `cacheDisplay`
    /// chiede alle viste di ridisegnarsi in un bitmap, e il terminale non si
    /// disegna lì: è uno strato Metal, e la GPU non passa da questa strada.
    /// Nell'immagine quell'area esce bianca, a volte con residui capovolti.
    /// Scoperto il 26/08 confrontando questa foto con `screencapture -l` sulla
    /// stessa finestra: là il menu di `/model` si leggeva riga per riga, qui
    /// era una lastra bianca — e per mezz'ora ho creduto a un difetto del
    /// renderer che non esisteva.
    ///
    /// Quindi: per la banda, la bolla, la pagina della chat, le impostazioni e
    /// il pannello dell'anteprima questa foto è fedele. **Per il contenuto del
    /// terminale si usa `Scripts/shot.sh`**, che passa dal server delle
    /// finestre e vede lo strato Metal. Il file `.md` accanto alla foto lo
    /// dice, perché una lastra bianca non si annuncia da sé.
    func testShot(to path: String) {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let destinazione = path.isEmpty ? "/tmp/t4a-shot.png" : path
        try? data.write(to: URL(fileURLWithPath: destinazione))
        // L'avvertenza viaggia con la foto: una foto senza terminale che non
        // dice di non averlo è la cosa che mi ha fatto sbagliare diagnosi.
        // This travels beside a diagnostic image for developers, not into UI.
        let nota = "View-drawn image: the TERMINAL is absent (it is a Metal layer).\n"
            + "To capture the terminal: Scripts/shot.sh <pid> <file>\n"
        try? nota.write(to: URL(fileURLWithPath: destinazione + ".md"),
                        atomically: true, encoding: .utf8)
    }

    /// Presses a tab, or its ×, where a person's finger would land.
    func testTabPress(_ spec: String) {
        let parts = spec.split(separator: " ")
        guard let index = Int(parts.first ?? ""), let points = tabStrip.testPoints(of: index) else { return }
        tabStrip.press(at: parts.count > 1 && parts[1] == "close" ? points.close : points.tab)
    }

    /// Puts the pointer over a tab, or over its ×, with no mouse.
    func testTabHover(_ spec: String) {
        let parts = spec.split(separator: " ")
        guard let index = Int(parts.first ?? ""), let points = tabStrip.testPoints(of: index) else {
            tabStrip.testHover(at: NSPoint(x: -1, y: -1))
            return
        }
        tabStrip.testHover(at: parts.count > 1 && parts[1] == "close" ? points.close : points.tab)
    }

    /// The count's own action path, with no invented controller shortcut.
    func testWaitingPress() { band.testPressWaiting() }
    func testWaitingChoose(_ index: Int) { waitingMenu.testChoose(index) }
    func testWaitingDismiss() { waitingMenu.dismiss() }
    func testReduceMotion(_ spec: String) {
        switch spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "true", "reduce": tabStrip.testSetReducedMotion(true)
        case "off", "false": tabStrip.testSetReducedMotion(false)
        default: tabStrip.testSetReducedMotion(nil)
        }
    }

    /// Presses one settings switch by its invariant English address, through
    /// the same gesture path a click takes — for the live-window probe of the
    /// dashboard toggles (his instruction, 25/08).
    func testPressSettingsSwitch(_ name: String) {
        guard let control = settings?.switches[name] else {
            NSLog("T4A: no settings switch named \(name)")
            return
        }
        control.press()
    }

    /// Presses one of the BAND's toggle buttons by its invariant English
    /// label — the gesture a person makes. The menu route (`fire`) travels the key window's
    /// responder chain, and with the settings open THAT window is key, so the
    /// menu never reaches this controller: a bench that used it measured the
    /// bench (learned 25/08, three probes in a row).
    func testPressBandToggle(_ label: String) {
        guard let button = (band.toggleButtons + layoutToggles)
            .first(where: { $0.label == label }) else {
            NSLog("T4A: no band toggle labelled \(label)")
            return
        }
        button.onClick()
    }

    func testOpenSettings() { openSettings() }
    func testCloseSettings() { settings?.close(); settings = nil }
    func testSettingsCategory(_ name: String) {
        openSettings()
        settings?.show(category: name)
    }

    /// Presses a named switch, through the same gesture a person makes.
    func testToggleSwitch(_ label: String) {
        settings?.switches[label]?.press()
    }

    /// Presses a one-of-several button by its English address, through the
    /// same closure the pointer fires. The pointer route stays the proof of
    /// the click; this is the door for the state change it causes.
    func testPressChoice(_ label: String) {
        settings?.choices[label]?.onClick()
    }

    /// Everything about the settings window a claim needs: which category is
    /// open, the names of the switches on screen (there is exactly one per
    /// row), the milliseconds the last gesture took, and where the handles
    /// and lines sit on screen so a drag can be performed with real events.
    func testSettingsState() -> [String: Any] {
        guard let settings, settings.window?.isVisible == true else { return ["open": false] }
        var out: [String: Any] = ["open": true, "category": settings.currentCategory]
        out["switches"] = settings.switches.keys.sorted()
        // Where each one-of-several button IS on the display, so the bench can
        // put a real click on it (ISC-33: the theme changes from the settings,
        // not only from the palette).
        out["choices"] = settings.choices.mapValues { screenRect(of: $0) }
        // And where each SWITCH is, for the same reason. The rows pane already
        // reported the rectangles of the switches inside it; the ones above it
        // — `Running work` is the only one today — had none, so a bench could
        // press them by name through the channel and could not put a REAL
        // click on one. That gap is how ISC-191 sat unmeasured: the named
        // press worked, and nothing was asking the question a finger asks.
        out["switchRects"] = settings.switches.mapValues { screenRect(of: $0) }
        out["choiceSelected"] = settings.choices.mapValues(\.isSelected)
        out["gestureMs"] = settings.switches.mapValues { $0.lastGestureMs }
            .filter { $0.value > 0 }
        out["on"] = settings.switches.mapValues { $0.isOn }
        out["categories"] = SettingsWindowController.categories
        // Where the panel sits against the window that owns it (ISC-155).
        for (key, value) in settings.testPlacement() { out[key] = value }
        let geometry = settings.rowsGeometry()
        out["trace"] = settings.rowsTrace()
        out["rows"] = geometry["rows"] ?? []
        out["lines"] = geometry["lines"] ?? []
        out["hovered"] = geometry["hovered"] ?? ""
        if let frame = settings.window?.frame {
            out["frame"] = ["x": Double(frame.minX), "y": Double(frame.minY),
                            "w": Double(frame.width), "h": Double(frame.height)]
        }
        return out
    }

    /// The bar: what is drawn, where, and how it is arranged.
    func testDashState() -> [String: Any] {
        var out: [String: Any] = [:]
        out["rows"] = dash.rowCount
        out["height"] = Double(dashHeight.constant)
        out["slots"] = dashLayout.encoded
        out["off"] = dashLayout.off.sorted()
        out["left"] = dash.lines(left: true).map { $0.map(\.key) }
        out["right"] = dash.lines(left: false).map { $0.map(\.key) }
        // The whole lines, and how many of them opened. Read separately from
        // `rows`, which counts the two groups: a bar with no provider must
        // have none of these and be exactly the height it always was.
        out["full"] = dash.fullLines().map { $0.map(\.key) }
        out["fullRows"] = dash.fullRowCount
        out["values"] = dash.values.mapValues { $0.label + " " + $0.value }
        // What was PAINTED, after truncation, and in which tones. A claim
        // about what the bar shows is read from the drawing.
        out["painted"] = dash.inkText
        // The label separately from the value: a provider may ask for NO
        // label, and "the label is empty" cannot be read off a string that
        // glues the two together.
        out["labels"] = dash.values.mapValues(\.label)
        out["tones"] = dash.inkTones
        out["inks"] = dash.inkColours
        out["hidden"] = dash.hiddenKeys
        // Quali celle si stanno LAMENTANDO, per chiave. Serve a un banco per
        // dire ISC-104.3 invece di inciamparci: «spenta implica non
        // disegnata» ha un'eccezione dichiarata — una riga che si lamenta
        // torna da sola — e senza questo campo l'eccezione è indistinguibile
        // da un guasto. È una diagnostica, non un comportamento: niente qui
        // cambia cosa viene dipinto.
        out["alarmed"] = dash.values.filter { $0.value.alarm != .none }.keys.sorted()
        // The lane the bar keeps for what it may not hide (ISC-145, ISC-146).
        out["alarms"] = dash.alarms.map(\.key)
        // The lane's labels, so "the warning is marked as one" is read off the
        // cell instead of off a photograph (ISC-152).
        out["alarmLabels"] = dash.alarms.map(\.label)
        out["catalog"] = DashCatalog.entries.map { ["key": $0.key, "name": $0.name,
                                                    "discovered": $0.discovered] }
        out["facts"] = facts.diagnostics
        let context = facts.context()
        // JSON needs one object whose pid can be either a number or null.
        var factsContext: [String: Any] = [
            "session": context.session,
            "cwd": context.cwd,
            "agent": context.agent,
        ]
        if let pid = context.pid {
            factsContext["pid"] = Int(pid)
        } else {
            factsContext["pid"] = NSNull()
        }
        out["factsContext"] = factsContext
        out["ink"] = dash.inkRects.mapValues {
            ["x": Double($0.minX), "y": Double($0.minY), "w": Double($0.width)]
        }
        return out
    }

    func testComposerState() -> [String: Any] {
        [
            "mode": config.string(.composerMode),
            "shown": !composer.isHidden && composerHeight.constant > 0,
            "height": Double(composerHeight.constant),
            "frontOwnsInput": frontProgramOwnsInput,
            "target": composerTarget,
            "refusal": rifiutoComposer,
            // What is IN the bubble, and who has the keyboard (ISC-158,
            // ISC-159). Both are the difference between "he typed in the
            // bubble" and "he typed into the terminal believing he was in
            // the bubble", which from outside are the same gesture.
            "dropTypes": activeTab?.activePane.session.backend.registeredDropTypes ?? [],
            "text": composer.text,
            "lines": composer.text.components(separatedBy: "\n").count,
            "firstResponder": testFirstResponder(),
            // L'elenco dei comandi `/` (ISC-187). Sta qui e non in cima al
            // dump perché è una cosa DELLA bolla: senza bolla non esiste.
            "suggestions": testSuggestionsState(),
        ]
    }

    /// Everything ISC-114 claims, read off the live objects: whether the
    /// experiment is on, whether it is armed, what is covered RIGHT NOW in
    /// rows and in points, the text of the rows under the cover, and — when
    /// nothing is covered — the reason.
    func testPureChatState() -> [String: Any] {
        var result: [String: Any] = ["enabled": config.bool(.pureChat)]
        guard let session = activeTab?.activePane.session else {
            result["armed"] = false
            result["covering"] = false
            result["reason"] = "no session"
            return result
        }
        result["armed"] = session.pureChat
        result["covering"] = session.hostedPrompt != nil
        result["reason"] = session.hostedPromptReason
        result["flips"] = session.coverFlips
        result["cursorRow"] = session.backend.grid.cursor.row
        result["alternateScreen"] = session.backend.grid.isAlternateScreenActive
        if let millis = session.lastRevealMillis { result["lastRevealMillis"] = millis }
        if let prompt = session.hostedPrompt {
            let grid = session.backend.grid
            result["topRule"] = prompt.topRule
            result["bottomRule"] = prompt.bottomRule
            result["markerRow"] = prompt.markerRow
            result["marker"] = prompt.marker
            result["rows"] = prompt.rowCount
            result["heightPoints"] =
                Double(CGFloat(prompt.rowCount) * session.backend.cellHeight)
            // The rows the patch is over, so what is covered can be read and
            // not taken on trust.
            result["coveredText"] = (prompt.topRule...prompt.bottomRule).map {
                String((grid.text(at: $0) ?? "").prefix(40))
            }
        }
        return result
    }

    /// `pure-chat on|off`, and a scan straight afterwards: a resting agent
    /// sends no bytes, and a switch that only takes effect on the next
    /// keystroke cannot be measured.
    func testSetPureChat(_ value: String) {
        config.set(.pureChat, value == "on" || value == "true")
        applyComposerMode()
        for session in tabs.flatMap(\.sessions) { session.scanScreenNow() }
    }

    func testSetComposerMode(_ mode: String) {
        guard ["agent", "contextual", "always", "never"].contains(mode) else { return }
        config.set(.composerMode, mode)
        applyComposerMode()
    }

    func testLayoutName() -> String { config.string(.layoutSessions) }
    func testConfigPath() -> String { config.url.path }
    func testConfigWrites() -> Int { config.writeCount }
    func testFontSize() -> Int { config.int(.fontSize) }
    func testSavedFrame() -> String { config.string(.windowFrame) }

    /// Everything about the window's shape, for ISC-106 and ISC-109.
    func testWindowState() -> [String: Any] {
        guard let window else { return [:] }
        let current = NSCursor.current
        let cursor: String
        if current === NSCursor.arrow { cursor = "arrow" }
        else if current === NSCursor.iBeam { cursor = "ibeam" }
        else if current === NSCursor.pointingHand { cursor = "pointingHand" }
        else {
            // `currentSystem` crea un wrapper nuovo a ogni lettura, quindi la
            // sua identità non può riconoscere i singleton installati da
            // `set()`. Misurato il 28/08: tre `other:NSCursor` col puntatore
            // su un link, su una parola e nel vuoto. Prima si legge
            // `current`, che conserva quell'identità; l'immagine resta il
            // ripiego per un cursore consegnato dal sistema tramite wrapper.
            let shown = (NSCursor.currentSystem ?? current).image.tiffRepresentation
            if let shown, shown == NSCursor.arrow.image.tiffRepresentation {
                cursor = "arrow"
            } else if let shown, shown == NSCursor.iBeam.image.tiffRepresentation {
                cursor = "ibeam"
            } else if let shown, shown == NSCursor.pointingHand.image.tiffRepresentation {
                cursor = "pointingHand"
            } else {
                cursor = "other:\(String(describing: type(of: current)))"
            }
        }
        return [
            "frame": NSStringFromRect(window.frame),
            "x": Int(window.frame.origin.x),
            "y": Int(window.frame.origin.y),
            "width": Int(window.frame.width),
            "height": Int(window.frame.height),
            // A responder-chain paste is meaningful only in the key window.
            // Exposing the precondition keeps a background bench from passing
            // because another window happened to lend it a responder.
            "key": window.isKeyWindow,
            "inLiveResize": window.inLiveResize,
            "fullScreen": window.styleMask.contains(.fullScreen),
            "savedFrame": config.string(.windowFrame),
            "frameChanges": frameChangeCount,
            "framePending": frameSavePending,
            "askingToClose": isAskingToClose,
            // Un tooltip COMPARSO, non un tooltip registrato. AppKit lo mette
            // in una finestra sua, e questa è la sola cosa che distingue «il
            // suggerimento funziona» da «nessuno l'ha mai visto»: rifare i
            // tooltip a ogni disegno non fa crashare niente, disarma il timer
            // e basta, e il suggerimento non appare mai (misurato il 26/08 in
            // `Scripts/repro-tooltip.swift`, modo `rebuild`: zero apparizioni
            // in venticinque secondi contro settantacinque del modo `fixed`).
            // Il cursore che il Mac sta mostrando ADESSO. Una claim sul
            // puntatore è una claim su questo, e non si vede in una foto.
            "cursor": cursor,
            "toolTipShowing": NSApp.windows.contains {
                "\(type(of: $0))".contains("ToolTip")
            },
        ]
    }

    /// The end of a drag, through the delegate method AppKit itself calls
    /// when the mouse comes up.
    func testEndLiveResize() {
        windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    }

    func testMoveWindow(_ spec: String) {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let window else { return }
        window.setFrameOrigin(NSPoint(x: parts[0], y: parts[1]))
    }

    func testFullScreen(_ spec: String) {
        guard let window else { return }
        let wanted = spec.hasPrefix("on")
        guard wanted != window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    /// ⌘W through the same method the menu item fires.
    func testCloseCurrent() { closeCurrent() }

    /// The red button's path: `performClose` asks the delegate first, which
    /// is the whole point of ISC-107.
    func testCloseWindow() { window?.performClose(nil) }

    func testSelectTab(_ index: Int) { selectTab(index) }
    func testAnswerClose(_ spec: String) { answerCloseConfirmation(spec.hasPrefix("y")) }
    func testActiveLinkHover() -> (TerminalLinkHover, NSView)? {
        guard let backend = activeTab?.activePane.session.backend,
              let hover = backend.linkHover else { return nil }
        return (hover, backend.surface)
    }
    func testActiveLinkCursorTrace() -> TerminalLinkCursorTrace? {
        activeTab?.activePane.session.backend.linkCursorTrace
    }
#endif

    // MARK: - Find (ISC-66)

    private var findBar: FindBar?
    private var findMatches: [GridSpan] = []
    private var findTranscriptHits: [TranscriptHit] = []
    private var findSource: FindSource = .grid
    private var findIndex: Int?
    private(set) var lastSearch: (seconds: Double, rows: Int, truncated: Bool) = (0, 0, false)

    /// ⌘F. The bar is created once and lives at the top right of the
    /// terminal, over the text it is searching.
    @objc func showFind() {
        if findBar == nil {
            let bar = FindBar()
            bar.translatesAutoresizingMaskIntoConstraints = false
            terminalHost.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor,
                                              constant: -12),
                bar.topAnchor.constraint(equalTo: terminalHost.topAnchor, constant: 8),
            ])
            bar.onChange = { [weak self] request in self?.runSearch(request) }
            bar.onStep = { [weak self] step in self?.stepFind(step) }
            bar.onSelect = { [weak self] index in self?.selectFind(index) }
            bar.onOpen = { [weak self] hit in self?.openFindHit(hit) }
            bar.onClose = { [weak self] in self?.closeFind() }
            findBar = bar
        }
        findBar?.isHidden = false
        findBar?.focus()
        if let request = findBar?.request, !request.text.isEmpty { runSearch(request) }
    }

    @objc func findNext() { stepFind(1) }
    @objc func findPrevious() { stepFind(-1) }

    func closeFind() {
        findBar?.isHidden = true
        findMatches = []
        findTranscriptHits = []
        findSource = .grid
        findIndex = nil
        for pane in tabs.flatMap(\.panes) {
            pane.session.backend.renderer?.highlights = []
            pane.session.backend.renderer?.currentHighlight = nil
        }
        activeTab?.activePane.session.backend.focus()
    }

    func runSearch(_ request: SearchRequest) {
        guard let session = activeTab?.activePane.session else { return }
        let backend = session.backend
        let turns = session.turns
        if !turns.isEmpty {
            let started = Date()
            let result = TranscriptSearch.find(request, in: turns)
            findSource = .transcript
            findMatches = []
            findTranscriptHits = result.hits
            findIndex = findTranscriptHits.isEmpty ? nil : 0
            lastSearch = (Date().timeIntervalSince(started), turns.count, result.truncated)
            backend.renderer?.highlights = []
            backend.renderer?.currentHighlight = nil
            backend.renderer?.markDirty()
            findBar?.show(count: findTranscriptHits.count, current: findIndex,
                          truncated: result.truncated, seconds: lastSearch.seconds,
                          source: findSource, hits: findTranscriptHits, request: request)
            return
        }

        let result = GridSearch.find(request, in: backend.grid)
        findSource = .grid
        findTranscriptHits = []
        findMatches = result.spans
        lastSearch = (result.seconds, result.rowsScanned, result.truncated)
        // The match nearest the top of what is on screen, so the first hit is
        // the one the eye is already near.
        let top = backend.grid.topVisibleRow
        findIndex = findMatches.isEmpty ? nil
            : (findMatches.firstIndex { $0.start.row >= top } ?? findMatches.count - 1)
        applyHighlights(reveal: true)
        findBar?.show(count: findMatches.count, current: findIndex,
                      truncated: result.truncated, seconds: result.seconds,
                      source: findSource, hits: [], request: request)
    }

    func stepFind(_ step: Int) {
        if findSource == .transcript {
            guard !findTranscriptHits.isEmpty else { return }
            let current = findIndex ?? 0
            findIndex = (current + step + findTranscriptHits.count) % findTranscriptHits.count
            if let request = findBar?.request {
                findBar?.show(count: findTranscriptHits.count, current: findIndex,
                              truncated: lastSearch.truncated, seconds: lastSearch.seconds,
                              source: findSource, hits: findTranscriptHits, request: request)
            }
            return
        }
        guard !findMatches.isEmpty else { return }
        let current = findIndex ?? 0
        findIndex = (current + step + findMatches.count) % findMatches.count
        applyHighlights(reveal: true)
        findBar?.show(count: findMatches.count, current: findIndex,
                      truncated: lastSearch.truncated, seconds: lastSearch.seconds,
                      source: findSource, hits: [], request: findBar?.request
                          ?? SearchRequest(text: ""))
    }

    private func selectFind(_ index: Int) {
        guard findSource == .transcript,
              findTranscriptHits.indices.contains(index) else { return }
        findIndex = index
        guard let request = findBar?.request else { return }
        findBar?.show(count: findTranscriptHits.count, current: findIndex,
                      truncated: lastSearch.truncated, seconds: lastSearch.seconds,
                      source: findSource, hits: findTranscriptHits, request: request)
    }

    private func openFindHit(_ hit: TranscriptHit) {
        guard findSource == .transcript,
              let session = activeTab?.activePane.session,
              let turn = session.turns.first(where: { $0.id == hit.turnID }) else { return }
        // Il lettore restituisce la tastiera al responder che aveva preso, ma
        // quello è il field editor del campo di ricerca, che AppKit stacca
        // quando l'editing finisce: restituirlo dà la finestra, non il campo
        // (misurato dal banco 233b, 30/08: `responder=NSWindow`). La barra è
        // ancora lì con l'elenco, quindi la tastiera torna nel campo.
        turnReader.onClose = { [weak self] in
            self?.refresh()
            if let bar = self?.findBar, !bar.isHidden { bar.focus() }
        }
        turnReader.open(turn, restoring: nil,
                        attesa: session.rigaDiAttesa, highlight: hit)
    }

    private func applyHighlights(reveal: Bool) {
        guard let backend = activeTab?.activePane.session.backend else { return }
        backend.renderer?.highlights = findMatches
        backend.renderer?.currentHighlight = findIndex
        if reveal, let index = findIndex, findMatches.indices.contains(index) {
            let row = findMatches[index].start.row
            let top = backend.grid.topVisibleRow
            if row < top || row >= top + backend.grid.rows {
                backend.reveal(row: max(0, row - backend.grid.rows / 2))
            }
        }
        backend.renderer?.markDirty()
    }

#if DEBUG || T4A_TESTABLE
    // Everything to the #endif is the surface the benches drive and read,
    // and it is compiled only into a build that asked for it (ISC-128).
    // Without the channel in TestChannel.swift nothing can reach these
    // methods, but a remote control for a terminal should not be sitting
    // in the shipped binary waiting for a caller either.
    // MARK: - The render bench

    private var scrollBenchEnds: Date?
    private var scrollBenchResetsAt: Date?
    private var scrollBenchDirection = -1
    private var scrollBenchTravelled = 0
    private var scrollBenchReversal = 2000
    /// Frames on which the scroll asked to move and nothing moved.
    private(set) var scrollBenchStalls = 0

    /// Scrolls the viewport continuously for a while, so every frame the
    /// renderer draws has content it has never drawn before.
    ///
    /// This is the shape of ISC-20: a full buffer, scrolled without pause. It
    /// runs from the app rather than from the test script because a scroll
    /// driven by one shell command per line measures the pipe, not the
    /// renderer — and because the frames have to keep coming faster than a
    /// process can be spawned.
    func testScrollBench(_ spec: String) {
        let parts = spec.split(separator: " ").map(String.init)
        let seconds = Double(parts.first ?? "30") ?? 30
        // An optional warm-up: the first frames of a cold renderer rasterise
        // every glyph on screen and allocate the instance buffer, and a
        // benchmark that includes them is measuring the first second of the
        // app's life rather than the thing it claims to measure. The default
        // is none, so the plain form of the verb has no warm-up to explain.
        let warmUp = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
        scrollBenchReversal = parts.count > 2 ? (Int(parts[2]) ?? 2000) : 2000
        guard let renderer = activeTab?.activePane.session.backend.renderer else { return }
        scrollBenchEnds = Date().addingTimeInterval(seconds + warmUp)
        scrollBenchResetsAt = warmUp > 0 ? Date().addingTimeInterval(warmUp) : nil
        // INTO the scrollback, and starting a little way in.
        //
        // The first version of this went the other way and measured nothing:
        // the viewport was already at the bottom, `scroll(lines: -1)` had
        // nowhere to go, and the bench redrew one motionless screen at 120 Hz
        // for thirty seconds while reporting it as a continuous scroll. The
        // dead giveaway was in the dump — `topVisibleRow` equal to the live
        // screen's first row for the whole run. A bench whose subject never
        // moves still produces numbers, which is what makes this class of
        // mistake dangerous.
        scrollBenchDirection = 1
        scrollBenchTravelled = 0
        scrollBenchStalls = 0
        activeTab?.activePane.session.backend.scroll(lines: 300)
        renderer.resetStatistics()
        // Driven from inside the frame: one line per frame, every frame, with
        // no timer of our own to fight the display link for the main thread.
        renderer.beforeFrame = { [weak self] in self?.stepScrollBench() }
        renderer.markDirty()
    }

    private func stepScrollBench() {
        guard let ends = scrollBenchEnds, Date() < ends,
              let backend = activeTab?.activePane.session.backend else {
            activeTab?.activePane.session.backend.renderer?.beforeFrame = nil
            scrollBenchEnds = nil
            return
        }
        if let resets = scrollBenchResetsAt, Date() >= resets {
            scrollBenchResetsAt = nil
            backend.renderer?.resetStatistics()
        }
        // If the viewport did not actually move, the bench is not measuring a
        // scroll and says so instead of quietly drawing the same screen.
        let before = backend.grid.topVisibleRow
        backend.scroll(lines: scrollBenchDirection)
        if backend.grid.topVisibleRow == before { scrollBenchStalls += 1 }
        scrollBenchTravelled += 1
        // Ping-pong through the buffer instead of running out of it: a scroll
        // that hits the end stops changing the screen, and a still screen
        // would let the renderer sleep in the middle of the measurement.
        if scrollBenchTravelled >= scrollBenchReversal {
            scrollBenchTravelled = 0
            scrollBenchDirection = -scrollBenchDirection
        }
    }

    /// Captures one frame of the active pane to a `.gputrace`.
    func testCapture(_ spec: String) {
        let path = spec.isEmpty ? "/tmp/t4a-frame.gputrace" : spec
        let result = (activeTab?.activePane.session.backend.renderer
            as? MetalCaptureCapable)?.captureFrame(to: path) ?? "no GPU renderer on this pane"
        try? result.write(to: URL(fileURLWithPath: "/tmp/t4a-capture-result.txt"),
                          atomically: true, encoding: .utf8)
    }

    /// Writes one row of the grid, cell by cell: the character, how many
    /// columns it claims, and its colours. It is how a claim about a grapheme
    /// cluster living in ONE cell is checked against the cells rather than
    /// against a screenshot (ISC-23).
    func testCells(_ spec: String) {
        let parts = spec.split(separator: " ").map(String.init)
        guard let grid = activeTab?.activePane.session.backend.grid else { return }
        let row = Int(parts.first ?? "") ?? grid.cursor.row
        let path = parts.count > 1 ? parts[1] : "/tmp/t4a-cells.json"
        guard let line = grid.line(at: row) else { return }
        let cells: [[String: Any]] = line.cells.enumerated().map { column, cell in
            [
                "column": column,
                "text": String(cell.text),
                "scalars": cell.text.unicodeScalars.map { String(format: "U+%04X", $0.value) },
                "width": cell.width,
                "bold": cell.attributes.contains(.bold),
            ]
        }
        let root: [String: Any] = ["row": row, "columns": grid.columns, "cells": cells,
                                   "wrapped": line.isWrapped]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Types into the find bar the way a person does — through the field, so
    /// the same code path runs — and reports how long the search took.
    func testFind(_ spec: String) {
        showFind()
        guard let bar = findBar else { return }
        let parts = spec.split(separator: " ", maxSplits: 1).map(String.init)
        let mode: SearchMode = parts.first == "regex" ? .regex : .literal
        let text = parts.count > 1 && mode == .regex ? parts[1] : spec
        bar.setQuery(text, regex: mode == .regex)
        runSearch(bar.request)
    }

    func testFindStep(_ step: Int) { stepFind(step) }
    func testFindOpen() {
        guard findSource == .transcript, let index = findIndex,
              findTranscriptHits.indices.contains(index) else { return }
        openFindHit(findTranscriptHits[index])
    }

    func testFindState() -> [String: Any] {
        let matchCount = findSource == .transcript ? findTranscriptHits.count : findMatches.count
        return [
            "open": findBar != nil && findBar?.isHidden == false,
            "query": findBar?.query ?? "",
            "source": findSource.rawValue,
            "matches": matchCount,
            "current": findIndex ?? -1,
            "seconds": lastSearch.seconds,
            "rowsScanned": lastSearch.rows,
            "truncated": lastSearch.truncated,
            "hits": findTranscriptHits.prefix(50).map { hit in
                ["turn": hit.turnID, "place": hit.place.rawValue,
                 "stepID": hit.stepID ?? "", "excerpt": hit.excerpt] as [String: Any]
            },
            "currentRow": findIndex.flatMap { findMatches.indices.contains($0)
                ? findMatches[$0].start.row : nil } ?? -1,
        ]
    }

    /// The one switch that stops every animation the renderer does (ISC-67).
    func testMotion(_ spec: String) {
        let on = !(spec.hasPrefix("off") || spec.hasPrefix("false") || spec.hasPrefix("no"))
        for pane in tabs.flatMap(\.panes) {
            pane.session.backend.renderer?.motionEnabled = on
        }
        config.set(.motion, on)
        refresh()
    }

    func testScroll(_ spec: String) {
        activeTab?.activePane.session.backend.scroll(lines: Int(spec) ?? 1)
    }

    func testRenderStats(to path: String) {
        var stats = activeTab?.activePane.session.backend.renderer?.statistics() ?? [:]
        stats["scrollStalls"] = Double(scrollBenchStalls)
        // The cursor's trail goes in as its own list rather than being
        // flattened into the numbers: a claim about interpolation is a claim
        // about a sequence.
        let trail = (activeTab?.activePane.session.backend.renderer?.cursorTrail ?? [])
            .map { [$0.x, $0.y, $0.z] }
        stats["topVisibleRow"] = Double(activeTab?.activePane.session.backend.grid.topVisibleRow ?? 0)
        var payload: [String: Any] = stats
        payload["cursorTrail"] = trail
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath:
            path.isEmpty ? "/tmp/t4a-render.json" : path))
    }

    func testResetRenderStats() {
        activeTab?.activePane.session.backend.renderer?.resetStatistics()
    }

    /// Turns the GPU renderer off and on again on a live pane (ISC-24).
    func testSetRenderer(_ spec: String) {
        for pane in tabs.flatMap(\.panes) {
            BackendFactory.setGPURenderer(spec.hasPrefix("gpu"), on: pane.session.backend)
        }
    }

    func testCursor(_ spec: String) {
        let parts = spec.split(separator: " ").map(String.init)
        guard let renderer = activeTab?.activePane.session.backend.renderer else { return }
        for part in parts {
            if let style = CursorStyle(rawValue: part) {
                renderer.cursorStyle = style
                config.set(.cursorStyle, part)
            }
            if let motion = CursorMotion(rawValue: part) {
                renderer.cursorMotion = motion
                config.set(.cursorMotion, part)
            }
        }
    }

    /// Where the band's text sits and where the window buttons sit, in window
    /// coordinates. ISC-105 is a claim about the space between those two
    /// things, so both are measured, not one asserted.
    func testBandMetrics() -> [String: Any] {
        band.needsDisplay = true
        band.displayIfNeeded()
        var result: [String: Any] = ["bandHeight": band.bounds.height,
                                     "topInset": Theme.Metric.bandTopInset]
        for (key, rect) in band.inkRects {
            let inWindow = band.convert(rect, to: nil)
            // The band is flipped and the window is not: what a reader wants
            // is the distance from the TOP of the window, so it is given
            // directly rather than left as an arithmetic exercise.
            let topOfWindow = (window?.contentView?.bounds.height ?? 0)
            result[key] = [
                "x": Double(rect.origin.x),
                "topFromWindow": Double(topOfWindow - inWindow.maxY),
                "height": Double(rect.height),
            ]
        }
        // The glyphs in the band, by invariant English address, with the edge
        // each one is drawing and where it is ON SCREEN — so a bench puts
        // a real click on the button instead of calling the method behind it
        // (ISC-147). The whole rectangle is the target, which is why the width
        // and height come along.
        result["strip"] = tabStrip.testState
        let waiting = band.waitingHitRect
        result["waitingTarget"] = ["x": Double(waiting.minX),
                                   "y": Double(waiting.minY),
                                   "w": Double(waiting.width),
                                   "h": Double(waiting.height)]
        // The words on the band, for the pole that says the title is the
        // provider's one and not the folder's.
        result["titleText"] = band.title
        result["buttons"] = (band.toggleButtons + layoutToggles).map { button -> [String: Any] in
            var entry: [String: Any] = ["label": button.label,
                                        "edge": button.edge.rawValue,
                                        "on": button.isOn,
                                        // Where it would send them, and the
                                        // sentence under the pointer (ISC-156).
                                        "arrow": button.destination?.rawValue ?? "",
                                        "tip": button.toolTip ?? "",
                                        "hidden": button.isHidden,
                                        // `hidden` is the button's own flag,
                                        // and the layout glyph is never
                                        // hidden by it: there are two of them,
                                        // one in the rail and one in the tab
                                        // strip, and the one that is not on
                                        // screen is out of sight because its
                                        // PANEL is. A bench choosing where to
                                        // put a real click needs the question
                                        // a hand answers — can I see it? — so
                                        // it is reported and not left to be
                                        // re-derived from coordinates
                                        // (ISC-189).
                                        "onScreen": !button.isHiddenOrHasHiddenAncestor]
            for (key, value) in screenRect(of: button) { entry[key] = value }
            return entry
        }
        if let button = window?.standardWindowButton(.closeButton) {
            let frame = button.convert(button.bounds, to: nil)
            let topOfWindow = (window?.contentView?.bounds.height ?? 0)
            result["closeButton"] = [
                "x": Double(frame.origin.x),
                "topFromWindow": Double(topOfWindow - frame.maxY),
                "height": Double(frame.height),
            ]
        }
        return result
    }

    /// The three visible starts named by ISC-238, all measured from the top
    /// of the same content view. The side panels publish the rectangles they
    /// actually drew; the middle title already does the same in `BandView`.
    func testFullScreenLayout() -> [String: Any] {
        guard let content = window?.contentView else { return [:] }
        for view in [band, rail, inspector] { view.needsDisplay = true; view.displayIfNeeded() }

        func top(_ view: NSView, _ rect: NSRect) -> Double {
            let inWindow = view.convert(rect, to: nil)
            return Double(content.bounds.height - inWindow.maxY)
        }
        let railY = top(rail, rail.headingRect)
        let contentY = band.inkRects["title"].map { top(band, $0) } ?? -1
        let inspectorY = top(inspector, inspector.headingRect)
        let ys = [railY, contentY, inspectorY]
        return [
            "railY": railY,
            "contentY": contentY,
            "inspectorY": inspectorY,
            "spread": (ys.max() ?? 0) - (ys.min() ?? 0),
            "targetFullScreen": fullScreenLayoutTarget,
            "transition": fullScreenTransition,
            "compactBand": band.isFullScreenCompact,
            "bandTop": Double(bandTop.constant),
            "bandHeight": Double(bandHeight.constant),
            "tabStripTop": Double(tabStripTop.constant),
            "terminalTopInset": Double(terminalHostTop.constant),
            "systemReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "hooks": fullScreenHookLog,
        ]
    }

    /// The whole menu bar as JSON — titles, shortcuts, and whether AppKit
    /// would let you press them.
    ///
    /// `menu.update()` first, because an item's enabled state is decided by
    /// the responder chain at the moment the menu opens: reading it without
    /// that says what the item was born as, not what a person would find.
    func testDumpMenu(to path: String) {
        func describe(_ menu: NSMenu) -> [[String: Any]] {
            menu.update()
            return menu.items.map { item in
                var entry: [String: Any] = [
                    "title": item.title,
                    "key": item.keyEquivalent,
                    "modifiers": Self.describe(item.keyEquivalentModifierMask),
                    "hasAction": item.action != nil,
                    "enabled": item.isEnabled,
                    "separator": item.isSeparatorItem,
                ]
                if let submenu = item.submenu { entry["items"] = describe(submenu) }
                return entry
            }
        }
        let root: [String: Any] = ["menus": NSApp.mainMenu.map(describe) ?? []]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted]) else { return }
        try? data.write(to: URL(fileURLWithPath: path.isEmpty ? "/tmp/t4a-menu.json" : path))
    }

    private static func describe(_ modifiers: NSEvent.ModifierFlags) -> String {
        var out = ""
        if modifiers.contains(.control) { out += "ctrl+" }
        if modifiers.contains(.option) { out += "alt+" }
        if modifiers.contains(.shift) { out += "shift+" }
        if modifiers.contains(.command) { out += "cmd+" }
        return out
    }

    /// Presses a menu item by title, through the responder chain the click
    /// uses. A menu item that exists and does nothing is the failure this is
    /// looking for.
    func testFireMenuItem(_ title: String) {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.identifier?.rawValue == title || item.title == title { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        guard let menu = NSApp.mainMenu, let item = find(menu), let action = item.action else {
            NSLog("T4A: no menu item titled \(title)")
            return
        }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    /// The two extreme panels, as geometry: where each one sits in the
    /// window and which of its corners was drawn round. ISC-111 is a claim
    /// about a shape and about two top edges agreeing, so both are read from
    /// the views that drew them.
    func testPanelWidths() -> [String: Any] {
        [
            "rail": Double(railWidth.constant),
            "inspector": Double(inspectorWidth.constant),
            "railSaved": config.int(.railWidth),
            "inspectorSaved": config.int(.inspectorWidth),
            "railGripHidden": railGrip.isHidden,
            "inspectorGripHidden": inspectorGrip.isHidden,
            "gripThickness": Double(GripView.thickness),
            "railGrip": screenRect(of: railGrip),
            "inspectorGrip": screenRect(of: inspectorGrip),
            "railFloats": !rail.isHidden && rail.frame.minX >= 0,
            "toggles": [
                "turn map panel": band.inspectorToggle.isOn,
                "dashboard bar": band.dashToggle.isOn,
            ],
            "toggleRects": [
                "turn map panel": screenRect(of: band.inspectorToggle),
                "dashboard bar": screenRect(of: band.dashToggle),
                "settings": screenRect(of: band.settingsButton),
            ],
        ]
    }

    /// A view's rectangle on the DISPLAY, which is the only coordinate space a
    /// mouse event posted from outside the app can be aimed at.
    private func screenRect(of view: NSView) -> [String: Double] {
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = view.window?.convertToScreen(inWindow) ?? inWindow
        return ["x": Double(onScreen.midX), "y": Double(onScreen.midY),
                "w": Double(onScreen.width), "h": Double(onScreen.height)]
    }

    /// The rail's rows, with the × where it actually is on screen (ISC-148).
    ///
    /// `close` is present only when the row DREW one, so "the × is there" is
    /// read from the ink and never from the fact that a row exists. The bench
    /// puts the pointer on `row` with a real move and then a real click on
    /// `close`, which is the only way to measure a control that appears on
    /// hover.
    func testRailState() -> [String: Any] {
        ["hidden": rail.isHidden,
         "rows": rail.rows.map { row -> [String: Any] in
            var entry: [String: Any] = ["title": row.session.displayName,
                                        "selected": row.isSelected,
                                        "showingClose": row.isShowingClose,
                                        "id": row.session.id.uuidString]
            for (key, value) in screenRect(of: row) { entry["row_" + key] = value }
            if let box = row.closeRect {
                let inWindow = row.convert(box, to: nil)
                let onScreen = row.window?.convertToScreen(inWindow) ?? inWindow
                entry["close"] = ["x": Double(onScreen.midX), "y": Double(onScreen.midY),
                                  "w": Double(onScreen.width), "h": Double(onScreen.height)]
                // In the ROW's own coordinates as well, because "the count
                // never lands on the ×" is two rectangles compared, and two
                // screen rectangles from two different rows would compare
                // fine while overlapping on the glass (ISC-154).
                entry["closeLocal"] = ["x": Double(box.minX), "w": Double(box.width)]
            }
            if let box = row.countRect {
                entry["countLocal"] = ["x": Double(box.minX), "w": Double(box.width)]
            }
            return entry
         }]
    }

    func testPanelMetrics() -> [String: Any] {
        func describe(_ panel: EdgePanel) -> [String: Any] {
            let inWindow = panel.convert(panel.bounds, to: nil)
            let topOfWindow = window?.contentView?.bounds.height ?? 0
            return [
                "facing": panel.facing.rawValue,
                "hidden": panel.isHidden,
                "x": Double(inWindow.origin.x),
                "width": Double(inWindow.width),
                "topFromWindow": Double(topOfWindow - inWindow.maxY),
                "corners": panel.drawnCorners.mapValues(Double.init),
            ]
        }
        return ["rail": describe(rail), "inspector": describe(inspector)]
    }

    // MARK: - The agent adapter, as the bench sees it

    /// Presses the card's own button.
    /// Puts a question on the card that the screen is NOT asking, so the check
    /// at click time has something to catch (ISC-127).
    ///
    /// Scaffolding, and it earns its place: the real race is between the scan
    /// and the click, a window of at most one coalesced scan, and a bench that
    /// waited for it to happen would be a bench that goes green by never
    /// reproducing anything. This freezes the time-of-check instead. With a
    /// real question on the screen it keeps that question's OPTIONS and
    /// changes only its title, so what the check catches is a difference in
    /// the question and not the absence of one.
    func testStaleCard(_ spec: String) {
        guard let session = activeTab?.activePane.session else { return }
        let live = session.agent?.approval
        let title = spec.isEmpty ? S.stagedQuestion : spec
        let options = live?.options ?? [
            AgentApprovalOption(label: S.yes, keystrokes: "1\r", isApproval: true),
            AgentApprovalOption(label: S.no, keystrokes: "2\r", isApproval: false),
        ]
        card.show(AgentApproval(title: title, detail: [S.stagedDetail],
                                options: options, firstRow: live?.firstRow ?? 0),
                  kind: S.stagedKind)
    }

    func testApprove(_ spec: String) {
        let yes = !(spec.hasPrefix("n") || spec.hasPrefix("d"))
        if !card.press(approve: yes) { NSLog("T4A: no approval card on screen") }
    }

    /// Pastes into the bubble through the very method ⌘V reaches.
    ///
    /// The key event is the one thing skipped: AppKit routes ⌘V to
    /// `paste(_:)` on the focused text view, and that method is what a bench
    /// can call without owning the keyboard of a machine somebody is using.
    func testComposerPaste() {
        composer.focus()
        composer.field.paste(nil)
    }

    /// Sends whatever is in the bubble, without writing it first.
    func testComposerSend() { composer.submit() }

    /// Puts text in the hosted program's input line through the same framed
    /// write as the composer, but leaves Return out. The form bench has to
    /// inspect what Claude made of the paste before a submitted turn can erase
    /// the input line; this door exists only in testable builds.
    func testBracketedPaste(_ text: String) {
        activeTab?.activePane.session.backend.compose(text: text, submitAfter: nil)
    }

    /// A Finder-shaped clipboard: the file URL and a deliberately misleading
    /// display name coexist. The production decision still reads the real
    /// pasteboard; only construction of the otherwise awkward fixture lives
    /// in the test channel.
    func testClipboardFile(_ spec: String) {
        let fields = spec.split(separator: "\t", maxSplits: 1,
                                omittingEmptySubsequences: false).map(String.init)
        guard let path = fields.first, !path.isEmpty else { return }
        let display = fields.count > 1 ? fields[1] : URL(fileURLWithPath: path).lastPathComponent
        let board = NSPasteboard.general
        board.clearContents()
        guard board.writeObjects([URL(fileURLWithPath: path) as NSURL]) else { return }
        board.setString(display, forType: .string)
    }

    /// A real PNG representation, not a filename pretending to be one.
    func testClipboardPNG(_ path: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: .png)
    }

    /// Base64 keeps every byte representable on the channel's one-line
    /// protocol; decoding as UTF-8 gives the same string AppKit will paste.
    func testClipboardText(base64: String) {
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Drops a file where the caret is, through the same code a real drag
    /// runs. Only AppKit's carrying of the mouse is left out.
    /// `drop-file <path>` cade dove sta il cursore; `drop-file pane <path>` e
    /// `drop-file page <path>` entrano dalle altre due porte, che sono quelle
    /// che ISC-201 ha aperto: il pannello del terminale e la pagina della
    /// chat. Senza un bersaglio esplicito il banco misurerebbe sempre la
    /// bolla, cioè l'unica strada che funzionava già.
    func testDropFile(_ rest: String) {
        var path = rest
        var bersaglio = "caret"
        for nome in ["pane", "page"] where rest.hasPrefix(nome + " ") {
            bersaglio = nome
            path = String(rest.dropFirst(nome.count + 1))
        }
        let board = NSPasteboard(name: NSPasteboard.Name("dev.t4a.bench.drop"))
        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: path) as NSURL])
        if bersaglio == "pane" {
            activeTab?.activePane.session.backend.acceptDrop(from: board)
            return
        }
        if bersaglio == "page" {
            chatPage.accettaDrop(board)
            return
        }
        if let editor = window?.firstResponder as? NSTextView {
            // Through the same door the real drop uses, or the bench measures
            // a road nobody travels: the field turns a picture into its token.
            if let field = editor as? ComposerField {
                for path in DroppedItems.paths(from: board) { field.insertAttachment(path: path) }
                return
            }
            let paths = DroppedItems.paths(from: board)
            editor.insertText(paths.joined(separator: " "), replacementRange: editor.selectedRange())
            return
        }
        activeTab?.activePane.session.backend.acceptDrop(from: board)
    }

    /// Types into the composer and presses Return through the field itself.
    func testCompose(_ text: String) {
        composer.text = text
        composer.submit()
    }

    /// Folds or unfolds one turn by its number, or every finished one.
    /// Folds an arbitrary run of rows, so a bench can build the case where two
    /// commands land on ONE visual line (ISC-137). Real folds come from agent
    /// turns and cost an agent; the collision they cause does not.
    func testFoldRows(_ spec: String) {
        guard let session = activeTab?.activePane.session else { return }
        let parts = spec.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, parts[0] <= parts[1] else {
            session.backend.setFolds([])
            refresh()
            return
        }
        session.backend.setFolds([parts[0]...parts[1]])
        refresh()
    }

    func testFold(_ spec: String) {
        guard let session = activeTab?.activePane.session else { return }
        let parts = spec.split(separator: " ").map(String.init)
        if parts.first == "compact" {
            let on = !(parts.count > 1 && (parts[1].hasPrefix("off") || parts[1] == "false"))
            session.compactTurns = on
            config.set(.compactTurns, on)
        } else if let id = Int(parts.first ?? ""),
                  let turn = session.turns.first(where: { $0.id == id }) {
            session.toggleFold(turn: turn)
        }
        refresh()
    }

    /// One screen scan, now, through the same method the arriving bytes reach.
    func testScanScreen() {
        activeTab?.activePane.session.scanScreenNow()
        refresh()
    }

    /// Everything the adapter knows about every pane.
    func testAgentDump() -> [[String: Any]] {
        tabs.flatMap(\.panes).map { pane -> [String: Any] in
            let session = pane.session
            var entry: [String: Any] = [
                "session": session.id.uuidString,
                "active": pane.isActive,
                "activity": session.activity.rawValue,
                "waitingForYou": session.isWaitingForYou,
                "compact": session.compactTurns,
                "foldedTurns": session.foldedTurns.sorted(),
                "folds": session.backend.folds.ranges.map { [$0.lowerBound, $0.upperBound] },
            ]
            entry["adapter"] = session.agent?.diagnostics ?? ["attached": false]
            // Da quale binario vengono i built-in dell'elenco `/`. Solo per il
            // pannello attivo: il catalogo è uno per finestra e guarda quello.
            if pane.isActive { entry["slashSource"] = slashSource }
            // Where the question's text is in the buffer RIGHT NOW, found the
            // same way the anchor is found. Two numbers that should agree, so
            // a disagreement says which half is wrong.
            let grid = session.backend.grid
            entry["needleProbe"] = session.turns.map { turn -> [String: Any] in
                let needle = Session.needle(turn.prompt)
                var hit = -1
                if !needle.isEmpty {
                    var row = grid.firstRetainedRow
                    while row < grid.endRow {
                        if grid.text(at: row)?.contains(needle) == true { hit = row; break }
                        row += 1
                    }
                }
                return ["id": turn.id, "needle": needle, "row": hit]
            }
            entry["turnList"] = session.turns.map { turn -> [String: Any] in
                [
                    "id": turn.id,
                    "prompt": String(turn.prompt.prefix(120)),
                    "answer": String(turn.answer.prefix(120)),
                    "tools": turn.tools.map { ["name": $0.name, "summary": $0.summary,
                                               "error": $0.isError] },
                    "failed": turn.failed,
                    "open": turn.isOpen,
                    "durationMs": turn.duration.map { Int($0 * 1000) } ?? -1,
                    "promptRow": turn.promptRow ?? -1,
                    "workRows": turn.workRows.map { [$0.lowerBound, $0.upperBound] } ?? [],
                ]
            }
            return entry
        }
    }

    /// What the card is showing, if anything, and what its buttons would send.
    func testCardState() -> [String: Any] {
        guard let approval = card.shownApproval else {
            // "No card" and "a card that refused to send and said so" are two
            // different facts, and only the bench can tell them apart from
            // outside (ISC-127).
            return ["showing": false, "withdrawn": card.withdrawnReason]
        }
        return [
            "showing": true,
            "title": approval.title,
            "detail": approval.detail,
            "options": approval.options.map { option -> [String: Any] in
                ["label": option.label, "approval": option.isApproval,
                 "keys": option.keystrokes
                     .replacingOccurrences(of: "\r", with: "\\r")
                     .replacingOccurrences(of: "\u{1b}", with: "\\e")]
            },
        ]
    }

    /// What the recogniser makes of the live screen right now, whether or not
    /// a card came of it (ISC-122).
    ///
    /// Without this, "no card" and "there was nothing to see" are the same
    /// answer from outside, and a bench built on the card alone would go green
    /// on a claude that never opened the menu — the same green for the wrong
    /// reason.
    func testSelectorState() -> [String: Any] {
        guard let grid = testActiveGrid() else { return ["kind": "no grid"] }
        guard let agent = activeTab?.activePane.session.agent else {
            return ["kind": "no observer"]
        }
        return agent.reading(on: grid)
    }

    func testActiveGrid() -> (any TerminalGrid)? { activeTab?.activePane.session.backend.grid }
    func testFoldTargets() -> [[String: Any]] {
        activeTab?.activePane.foldTargets ?? []
    }
    /// Che cosa mostra la colonna di destra ADESSO.
    ///
    /// Una risposta sola per una colonna sola: con un'anteprima aperta dentro
    /// vale `preview`, altrimenti quello che dice l'ispettore. Da RIDOTTA
    /// torna `turns`, ed è la cosa giusta — sotto la testa dell'anteprima
    /// c'è di nuovo la mappa dei turni, che è quello che si vede.
    func testInspectorMode() -> String {
        previewIsExpanded ? "preview" : inspector.mode
    }
    func testComposerTarget() -> String { composerTarget }

    /// Apre il turno numero `id` della sessione attiva, come farebbe un
    /// click sulla sua riga nella mappa. Il numero e quello che la mappa
    /// stessa espone, non un indice di lista.
    func testOpenTurn(_ id: Int) {
        guard let turn = activeTab?.activePane.session.turns.first(where: { $0.id == id })
        else { NSLog("T4A: nessun turno \(id)"); return }
        openTurn(turn)
    }

    func testTurnReaderState() -> [String: Any] { turnReader.testState }
    func testChatPageState() -> [String: Any] {
        var stato = chatPage.testState
        stato["inputBoxSeen"] = activeTab?.activePane.session.rigaIngressoVista ?? false
        stato["pageFlips"] = pageFlips
        return stato
    }

    /// La ricevuta dei messaggi in coda, per il banco (ISC-194). Si legge dal
    /// pannello disegnato, non dalla sessione: la domanda è «lo VEDE», e la
    /// sessione risponderebbe a «lo sa».
    func testQueuedState() -> [String: Any] {
        let agent = activeTab?.activePane.session.agent
        return ["visible": !queuedView.isHidden,
                "line": queuedView.riga,
                "count": queuedView.messaggi.count,
                // Cosa dice l'agente, separato da cosa disegniamo noi: la
                // ricevuta sparita per un suo `remove` e quella mai comparsa
                // hanno lo stesso `visible`, e si distinguono solo qui.
                "fromAgent": agent?.queued ?? [],
                "consumed": agent?.queueConsumed ?? 0]
    }

    /// L'anteprima come la vede il banco, più la larghezza vera della colonna
    /// e quella salvata: la claim parla di due larghezze che si alternano,
    /// quindi il dump le mostra tutte e due accanto a quella misurata adesso.
    func testPreviewState() -> [String: Any] {
        var stato = previewSurface.testState
        stato["columnWidth"] = Double(inspectorWidth.constant)
        stato["previewSaved"] = config.string(.previewWidth)
        stato["inspectorSaved"] = config.int(.inspectorWidth)
        stato["mode"] = testInspectorMode()
        stato["panelMode"] = inspector.mode
        stato["frontShowing"] = !previewFront.isHidden
        // Dove sta la CARTA sullo schermo, quando è davanti. Serve al polo
        // che clicca fuori da lei: senza questo rettangolo il banco deve
        // indovinare un punto, e un punto indovinato finisce fuori dalla
        // FINESTRA invece che fuori dalla carta — che è un gesto diverso, e
        // che infatti non fa tornare l'anteprima al lato (26/08).
        if !previewFront.isHidden {
            let box = previewFront.convert(previewFront.cardRect, to: nil)
            let onScreen = window?.convertToScreen(box) ?? box
            stato["card"] = ["x": Double(onScreen.midX), "y": Double(onScreen.midY),
                             "minX": Double(onScreen.minX), "maxX": Double(onScreen.maxX),
                             "w": Double(onScreen.width), "h": Double(onScreen.height)]
            let velo = previewFront.convert(previewFront.bounds, to: nil)
            let veloOnScreen = window?.convertToScreen(velo) ?? velo
            stato["veil"] = ["minX": Double(veloOnScreen.minX),
                             "maxX": Double(veloOnScreen.maxX),
                             "y": Double(veloOnScreen.midY)]
        }
        stato["bandGlyph"] = ["hidden": band.previewToggle.isHidden,
                              "on": band.previewToggle.isOn]
        return stato
    }

    /// `preview-open <stepID>`: apre il file di QUEL passo, che è la stessa
    /// strada del click sul link — il percorso viene dal passo, non dalla riga
    /// di comando, così il banco non può provare un percorso che l'app non
    /// avrebbe mai aperto.
    func testPreviewOpen(_ stepID: String) {
        let voluto = stepID.trimmingCharacters(in: .whitespaces)
        for pane in tabs.flatMap(\.panes) {
            for turn in pane.session.turns {
                guard let passo = turn.steps.first(where: { $0.id == voluto }),
                      let path = passo.filePath else { continue }
                openPreview(path)
                return
            }
        }
        NSLog("T4A: no step \(voluto) with a file to preview")
    }

    /// `preview-path <percorso>`: apre un file per percorso.
    ///
    /// Esiste per UNA cosa sola, ed è meglio dirla che lasciarla scoprire:
    /// fotografare un tipo di file che l'agente non può produrre con `Write`,
    /// cioè un PDF, che è binario. La strada vera resta `preview-open
    /// <stepID>` — il percorso viene dal passo — e i poli sul `.md` passano
    /// tutti di lì. Un verbo che apre un percorso qualunque non prova niente
    /// sul link, e infatti non è usato per provarlo.
    func testPreviewPath(_ path: String) {
        let voluto = path.trimmingCharacters(in: .whitespaces)
        guard !voluto.isEmpty else { return }
        openPreview(voluto)
    }

    func testPreviewCollapse(_ chiuso: Bool) {
        guard previewSurface.isLoaded else { return }
        if previewSurface.placement == .front { previewToPanel() }
        previewSurface.setCollapsed(chiuso)
        applyPanelVisibility(animated: false)
    }

    /// Accende o spegne la pagina della chat dal canale di prova, passando
    /// dalla stessa strada dell'interruttore: si scrive nella configurazione e
    /// si ridisegna, così il banco misura il comportamento vero e non una
    /// scorciatoia che esiste solo per lui.
    func testSetChatPage(_ raw: String) {
        let acceso = ["1", "on", "true", "yes"].contains(raw.trimmingCharacters(in: .whitespaces))
        config.set(ConfigKey.chatPage, acceso)
        refresh()
    }

    func testForeignPrograms() -> [String] {
        tabs.flatMap(\.sessions).compactMap(\.foreignProgramName)
    }
    /// Quello che la domanda di chiusura conta davvero: un agente che LAVORA,
    /// o un programma che non è un agente. Una chat ferma non c'è.
    func testClosingInterrupts() -> [String] {
        tabs.flatMap(\.sessions).compactMap(\.closingWouldInterrupt)
    }
    func testWaitingCount() -> Int { tabs.flatMap(\.sessions).filter(\.isWaitingForYou).count }
    func testWaitingMenuState() -> [String: Any] { waitingMenu.testState }
    func testNotificationLog() -> [[String: String]] { notificationLog }

    func testTabsDump() -> [[String: Any]] {
        tabs.enumerated().map { index, tab in
            var entry: [String: Any] = [:]
            entry["index"] = index
            entry["active"] = index == activeTabIndex
            entry["panes"] = tab.panes.map { pane -> [String: Any] in
                let session = pane.session
                let grid = session.backend.grid
                var value: [String: Any] = [:]
                value["id"] = session.id.uuidString
                value["title"] = session.displayName
                value["cwd"] = session.backend.currentWorkingDirectory()?.path ?? ""
                value["process"] = session.backend.foregroundProcessName() ?? ""
                value["pid"] = Int(session.backend.foregroundProcessID ?? -1)
                if let agentPid = session.agent?.processIdentifier {
                    value["agentPid"] = Int(agentPid)
                } else {
                    value["agentPid"] = NSNull()
                }
                value["active"] = pane.isActive
                value["exited"] = session.hasExited
                value["columns"] = grid.columns
                value["rows"] = grid.rows
                value["retainedLines"] = grid.retainedLineCount
                value["firstRetainedRow"] = grid.firstRetainedRow
                value["endRow"] = grid.endRow
                value["alternateScreen"] = grid.isAlternateScreenActive
                // Cosa risponderebbe la domanda di chiusura per QUESTO
                // pannello, e perché: il banco deve poter distinguere «non
                // chiede perché l'agente è fermo» da «non chiede perché non
                // si è agganciato niente».
                value["activity"] = session.activity.rawValue
                value["waitingForYou"] = session.isWaitingForYou
                value["finishedTurnSeen"] = session.vistaDopoLaFine
                if let since = session.waitingForYouSince {
                    value["waitingAgeSeconds"] = Date().timeIntervalSince(since)
                } else {
                    value["waitingAgeSeconds"] = NSNull()
                }
                // Perché la pagina copre o non copre: il valore in cache che
                // decide, e la lettura dello schermo rifatta ADESSO. Se i due
                // divergono, il difetto è nell'aggiornamento e non nello
                // scanner, ed è esattamente la domanda che il 26/08 non si
                // poteva fare al dump.
                value["asking"] = session.agenteStaChiedendo
                value["inputBoxSeen"] = session.rigaIngressoVista
                if let waitingLine = session.rigaDiAttesa {
                    value["waitingLine"] = waitingLine
                } else {
                    value["waitingLine"] = NSNull()
                }
                if let lettura = session.agent?.reading(on: grid) {
                    value["reading"] = ["kind": lettura["kind"] ?? "", "reason": lettura["reason"] ?? ""]
                }
                value["attached"] = session.agent?.isAttached ?? false
                value["interrupts"] = session.closingWouldInterrupt ?? ""
                value["cursorRow"] = grid.cursor.row
                value["cellHeight"] = session.backend.cellHeight
                value["topVisibleRow"] = grid.topVisibleRow
                let rendererStats = session.backend.renderer?.statistics() ?? [:]
                value["scrollOffset"] = rendererStats["scrollOffset"] ?? 0
                value["renderer"] = rendererStats
                value["selection"] = session.backend.selectedText ?? ""
                value["bracketedPaste"] = session.backend.acceptsBracketedPaste
                // Dove sta la superficie del terminale SULLO SCHERMO, per un
                // banco che deve trascinarci sopra un mouse vero (ISC-197):
                // senza questo il banco indovina un punto, e un punto
                // indovinato è la prima cosa che si rompe quando cambia la
                // larghezza della rotaia.
                value["surfaceRect"] = screenRect(of: session.backend.surface)
                value["screen"] = Self.screenText(grid)
                value["diagnostics"] = session.backend.diagnostics
                // What the gutter PRINTED, not what it could have printed:
                // two labels on one row is the defect ISC-137 names, and it is
                // invisible in the block list.
                value["durationLabels"] = pane.durationLabels
                value["durationLabelsDropped"] = pane.durationLabelsDropped
                value["blocks"] = session.blocks.blocks.map { block -> [String: Any] in
                    var item: [String: Any] = [:]
                    item["id"] = block.id
                    item["command"] = block.command
                    item["promptRow"] = block.promptRow
                    item["outputRow"] = block.outputRow ?? -1
                    item["endRow"] = block.endRow ?? -1
                    item["exitCode"] = block.exitCode.map(Int.init) ?? -9999
                    item["durationMs"] = block.duration.map { Int($0 * 1000) } ?? -1
                    item["failureMark"] = block.showsFailureMark
                    return item
                }
                return value
            }
            return entry
        }
    }

    /// The visible screen as text, so a test can assert what a person sees
    /// instead of asserting that bytes were written somewhere.
    private static func screenText(_ grid: TerminalGrid) -> [String] {
        let top = grid.topVisibleRow
        return (0..<grid.rows).compactMap { grid.line(at: top + $0)?.text }
    }
#endif

    /// Prints the frame of every piece of chrome. A layout claim is measured
    /// on the real window, never read off a screenshot by eye.
    @objc func dumpLayout() {
        guard let content = window?.contentView else { return }
        var lines = ["window \(window?.frame ?? .zero)", "content \(content.frame)"]
        let named: [(String, NSView)] = [
            ("band", band), ("tabStrip", tabStrip), ("stage", stage), ("dash", dash),
            ("rail", rail), ("terminalHost", terminalHost), ("inspector", inspector),
        ]
        for (name, view) in named {
            let inWindow = view.convert(view.bounds, to: nil)
            lines.append("\(name) frame=\(view.frame) inWindow=\(inWindow) hidden=\(view.isHidden)")
        }
        if let pane = activeTab?.activePane {
            let surface = pane.session.backend.surface
            lines.append("pane inWindow=\(pane.convert(pane.bounds, to: nil))")
            lines.append("surface inWindow=\(surface.convert(surface.bounds, to: nil))")
            lines.append("grid \(pane.session.backend.grid.columns)x\(pane.session.backend.grid.rows) cellHeight=\(pane.session.backend.cellHeight)")
        }
        let text = lines.joined(separator: "\n")
        try? text.write(to: URL(fileURLWithPath: "/tmp/t4a-layout.txt"),
                        atomically: true, encoding: .utf8)
        NSLog("T4A layout:\n\(text)")
    }

    /// Ends every child process this window started.
    ///
    /// A terminal that dies without doing this leaves login shells with no
    /// parent and no terminal, and they do not quietly exit: measured on
    /// 2026-08-20, eight orphaned zsh processes sat at full CPU inside
    /// `lockhistfile`, fighting each other for the history lock, and the next
    /// shell T4A opened never reached a prompt because of them. Killing the
    /// app is a thing that happens — a crash, a Force Quit, a test harness —
    /// so the cleanup cannot live only on the tidy path.
    private var isTearingDown = false

    func closeEverything() {
        isTearingDown = true
        // A sheet still up would keep the window alive and the app with it.
        if let confirmation = closeConfirmation, let window {
            window.endSheet(confirmation.alert.window, returnCode: .alertSecondButtonReturn)
            closeConfirmation = nil
        }
        // A size chosen a tenth of a second before the app was killed is
        // still a size the user chose: the pending write is flushed here
        // rather than lost with the process.
        saveFrameNow()
        durationTimer?.invalidate()
        durationTimer = nil
        tabs.flatMap(\.sessions).forEach { $0.close() }
    }

    static func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - L'anteprima di un file (ISC-176)

    /// Aperta e non ridotta e nel pannello: è lo stato in cui l'anteprima si
    /// prende la colonna, ed è la sola domanda che la larghezza deve fare.
    var previewIsExpanded: Bool {
        previewSurface.isLoaded && !previewSurface.collapsed
            && previewSurface.placement == .panel
    }

    /// Quanto è larga la colonna quando ci sta un'anteprima aperta.
    ///
    /// Meta` finestra finchè nessuno ha trascinato la cucitura, poi quello
    /// che ha scelto lui. I limiti sono quelli della claim: mai sotto 180
    /// punti, e mai così larga da lasciare al terminale meno di 400.
    private var previewWidthWanted: CGFloat {
        let finestra = window?.contentView?.bounds.width ?? 1200
        let scelto = config.string(.previewWidth)
        let voluto = Int(scelto).map(CGFloat.init) ?? (finestra / 2)
        return min(max(voluto, 180), max(180, finestra - 400))
    }

    /// Apre un file: dal DISCO, adesso.
    ///
    /// Cliccare un altro link sostituisce il contenuto invece di aprire una
    /// seconda anteprima, ed è scritto nella claim: l'anteprima è una, e
    /// due anteprime sarebbero due posti dove cercare la stessa cosa.
    func openPreview(_ path: String) {
        previewSurface.show(path: path)
        previewSurface.isHidden = false
        // Un file nuovo torna nel pannello: la carta è un gesto che si
        // rifà, non uno stato che si eredita.
        previewSurface.setPlacement(.panel)
        movePreview(to: .panel)
        applyPanelVisibility(animated: false)
    }

    /// Chiude davvero. La colonna torna alla mappa dei turni e alla sua
    /// larghezza, e QuickLook viene spento.
    func closePreview() {
        guard previewSurface.isLoaded else { return }
        movePreview(to: .panel)
        previewSurface.clear()
        previewSurface.isHidden = true
        applyPanelVisibility(animated: false)
    }

    /// Riduce e riapre. Il file resta caricato: riaprire non rilegge niente.
    @objc func togglePreviewCollapsed() {
        guard previewSurface.isLoaded else { return }
        // Da davanti il tasto la rimanda prima al lato: ridurre una carta che
        // sta al centro dello schermo non vuol dire niente.
        if previewSurface.placement == .front { previewToPanel(); return }
        previewSurface.setCollapsed(!previewSurface.collapsed)
        applyPanelVisibility(animated: false)
    }

    /// La porta davanti come carta. La stessa anteprima, un altro contenitore.
    @objc func previewToFront() {
        guard previewSurface.isLoaded else { return }
        previewSurface.setCollapsed(false)
        previewSurface.setPlacement(.front)
        movePreview(to: .front)
        applyPanelVisibility(animated: false)
    }

    /// La rimanda a destra. È quello che fanno Esc e un click fuori dalla
    /// carta: nessuno dei due chiude, perchè chiudere ha il suo comando.
    @objc func previewToPanel() {
        guard previewSurface.placement == .front else { return }
        previewSurface.setPlacement(.panel)
        movePreview(to: .panel)
        applyPanelVisibility(animated: false)
    }

    /// Sposta la VISTA da un contenitore all'altro.
    ///
    /// La `QLPreviewView` sta dentro `previewSurface` e non viene toccata:
    /// cambia il padre della superficie, non l'oggetto che ha letto il file.
    /// È così che «il file non si rilegge nel passaggio» è vero per
    /// costruzione e non per attenzione, e il contatore `reads` nel dump lo
    /// dimostra da fuori.
    private func movePreview(to dove: PreviewSurface.Placement) {
        guard let stage = inspector.superview else { return }
        switch dove {
        case .front:
            guard previewSurface.superview !== previewFront else { break }
            previewSurface.removeFromSuperview()
            previewSurface.translatesAutoresizingMaskIntoConstraints = true
            previewFront.addSubview(previewSurface)
            previewFront.isHidden = false
            previewFront.needsLayout = true
            previewFront.needsDisplay = true
        case .panel:
            previewFront.isHidden = true
            guard previewSurface.superview !== stage else { break }
            previewSurface.removeFromSuperview()
            previewSurface.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(previewSurface, positioned: .above, relativeTo: inspector)
            NSLayoutConstraint.activate([
                previewSurface.leadingAnchor.constraint(equalTo: inspector.leadingAnchor),
                previewSurface.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                previewSurface.topAnchor.constraint(equalTo: stage.topAnchor),
            ])
            previewBottom = previewSurface.bottomAnchor
                .constraint(equalTo: stage.bottomAnchor)
            previewHeight = previewSurface.heightAnchor
                .constraint(equalToConstant: PreviewSurface.headHeight)
        }
    }

    /// Esc, per tutta la finestra, in un posto solo.
    ///
    /// Un monitor locale e non un `keyDown`, per la stessa ragione per cui
    /// esiste quello di ⌥←: SwiftTerm dichiara `keyDown` `public` e non
    /// `open`, quindi nessuna sottoclasse può prendere il tasto prima del
    /// terminale.
    ///
    /// La precedenza sta scritta QUI e in nessun altro posto (ISC-162, allargata
    /// da ISC-198). Nell'ordine: le superfici che si aprono sopra la finestra —
    /// elenco `/`, palette, lettore del turno, barra di ricerca — se lo tengono;
    /// poi l'anteprima, che dal davanti torna al lato e dal lato si chiude; e
    /// **in fondo, sempre, il processo del pannello attivo**.
    ///
    /// L'ultimo ramo è la riparazione del 27/08 (suo referto: «voglio che quando
    /// premo ESC su T4A, anche se non sono all'interno della bolla, funzioni
    /// ugualmente»). Prima esistevano due sole strade per fermare un agente: la
    /// bolla, che converte Esc in `^[`, e il terminale a fuoco, dove ci pensa
    /// SwiftTerm. Ma la pagina della chat è SELEZIONABILE, quindi un click per
    /// leggere le dà il primo responder, e da lì Esc moriva dentro una
    /// `NSTextView` che non sa cosa farsene: l'agente non si poteva più fermare
    /// senza prima rimettere la tastiera da qualche parte.
    ///
    /// Il byte lo scrive SEMPRE questo ramo, anche quando il terminale o la
    /// bolla hanno la tastiera, e l'evento viene ingoiato: così ne parte uno
    /// solo per pressione, invece di uno nostro più uno loro.
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  event.window === window, event.keyCode == 53,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            else { return event }
            // 1. Chi si è aperto sopra la finestra se lo tiene.
            guard self.slashList.isHidden, self.commandPalette.isHidden,
                  self.turnReader.isHidden, self.findBar?.isHidden != false
            else { return event }
            // 2. L'anteprima: dal davanti torna al lato, dal lato si chiude.
            if self.previewSurface.isLoaded {
                if self.previewSurface.placement == .front { self.previewToPanel() }
                else { self.closePreview() }
                return nil
            }
            // 3. In fondo c'è sempre il processo.
            guard let session = self.activeTab?.activePane.session else { return event }
            session.backend.send(bytes: [0x1b])
            return nil
        }
    }

    // MARK: - Menu actions

    @objc func toggleInspector() {
        config.set(.showTurnMap, !config.bool(.showTurnMap))
        // animated: false, DELIBERATELY, and the numbers are the reason.
        // Two animations were built and bisected on 25/08 with a live claude
        // in the pane and the settings open: `allowsImplicitAnimation` died
        // in AppKit's drawRect on the second turn-map toggle (3 runs out of
        // 3), and the constraint-only animator died the same way (1 of 1) —
        // some view drawn at the intermediate widths throws, and the thrower
        // never appears in the stack. Without animation: six clean rounds.
        // The slide comes back the day it runs over FROZEN content (hide the
        // panel's subviews, slide the empty width, reveal at the end).
        applyPanelVisibility(animated: false)
        refreshLayoutSettingsPane()
    }

    @objc func toggleDash() {
        config.set(.showDashboard, !config.bool(.showDashboard))
        applyPanelVisibility(animated: false)
        refreshLayoutSettingsPane()
    }

    /// The band's buttons and the settings' switches are two views of ONE
    /// fact: a press on either repaints the other (his report, 25/08 — the
    /// dashboard came back from the band while its switch stayed off).
    private func refreshLayoutSettingsPane() {
        // Whatever pane is showing, not just Layout: the settings window is a
        // VIEW of the config, and any press elsewhere (band, menu, ⌥⌘3) must
        // repaint it wherever it is open.
        //
        // On the NEXT runloop turn, deliberately. The press that gets here
        // may have just opened an animation group; rebuilding the settings
        // pane tears its views out while the same Core Animation transaction
        // is still going to draw them, and AppKit answers a drawing pass on a
        // dead backing layer by throwing — the pane crashed on the second
        // turn-map toggle, reproduced three times (25/08). One hop later the
        // transaction has committed and the rebuild is ordinary.
        DispatchQueue.main.async { [weak self] in
            guard let self, let settings = self.settings,
                  settings.window?.isVisible == true else { return }
            settings.show(category: settings.currentCategory)
        }
    }

    /// The one-tab strip choice, from the settings.
    func setTabsWhenSingle(_ value: String) {
        config.set(.tabsWhenSingle, value)
        updateTabStripVisibility()
    }

    /// The transient WORKER cell, from the settings.
    func dashRowIsOff(_ key: String) -> Bool { dashLayout.off.contains(key) }
    func setDashRowOff(_ key: String, off: Bool) {
        if off { dashLayout.off.insert(key) } else { dashLayout.off.remove(key) }
        dashLayout.save(to: config)
        refresh()
    }

    @objc func toggleSessionLayout() {
        config.set(.layoutSessions, config.string(.layoutSessions) == "rail" ? "tabs" : "rail")
        applyPanelVisibility()
    }

    @objc func cycleTheme() {
        let names = availableThemeNames()
        guard !names.isEmpty else { return }
        let current = names.firstIndex(of: config.string(.theme)) ?? names.count - 1
        setTheme(names[(current + 1) % names.count])
    }

    /// ⌘+ / ⌘- / ⌘0. The size lives in the configuration file, so the choice
    /// survives a restart like every other one (ISC-110).
    @objc func fontBigger() { changeFontSize(by: 1) }
    @objc func fontSmaller() { changeFontSize(by: -1) }
    @objc func fontActualSize() {
        setFontSize(Int(Configuration.defaults[ConfigKey.fontSize.name] ?? "13") ?? 13)
    }

    private func changeFontSize(by delta: Int) {
        setFontSize(config.int(.fontSize) + delta)
    }

    func setFontSize(_ size: Int) {
        let clamped = max(8, min(48, size))
        guard clamped != config.int(.fontSize) else { return }
        config.set(.fontSize, clamped)
        applyFont()
    }

    private func applyFont() {
        let size = CGFloat(config.int(.fontSize))
        // ⌘+ e ⌘− valgono anche per la pagina della chat e per il lettore.
        // Prima toccavano solo la griglia, quindi con la pagina davanti lo
        // zoom cambiava un testo che nessuno stava guardando (suo, 27/08).
        TurnProse.misura = size
        chatPage.ridisegna()
        turnReader.ridisegna()
        let family = config.string(.fontFamily)
        let font = NSFont(name: family, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        for pane in tabs.flatMap(\.panes) {
            pane.session.backend.font = font
            pane.needsLayout = true
        }
        refresh()
    }

    /// ⇧⌘K since 22/08, as ⌘K went to the palette (ISC-32, and the decision
    /// of 20/08 15:40 that said to confirm this when the palette arrived).
    /// The buffer goes, the program stays. Nothing is written down the pty,
    /// so a shell keeps its history and a running program never notices.
    @objc func clearBuffer() {
        activeTab?.activePane.session.backend.clearBuffer()
        // The blocks are anchored to rows that no longer exist, so they go
        // with the rows: a tick in the gutter pointing at nothing is worse
        // than no tick.
        activeTab?.activePane.session.blocks.reset()
        refresh()
    }

    /// Una selezione col mouse finisce negli appunti, se l'interruttore è
    /// acceso (ISC-197). Un posto solo per le tre superfici che selezionano.
    private func copiaSelezione(_ testo: String) {
        guard config.bool(.copyOnSelect), !testo.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(testo, forType: .string)
    }

    /// ⌘C chiede a chi ha davvero la selezione, non sempre al terminale.
    ///
    /// Il difetto, suo, 27/08: con la pagina della chat accesa quello che si
    /// vede NON è la griglia del terminale, è una `NSTextView` posata sopra.
    /// Selezionavi una frase lì, premevi ⌘C, e questo metodo chiedeva la
    /// selezione al terminale, che sotto non ne ha nessuna: gli appunti
    /// restavano quelli di prima, e il tasto sembrava morto.
    ///
    /// L'ordine è quello di chi sta davanti: il lettore di un turno copre la
    /// pagina, la pagina copre il terminale. In fondo c'è sempre la griglia,
    /// che è il caso di una shell senza agente.
    @objc func copySelection() {
        let sorgenti: [String?] = [
            turnReader.isHidden ? nil : turnReader.selezione,
            chatPage.isHidden ? nil : chatPage.selezione,
            activeTab?.activePane.session.backend.selectedText,
        ]
        guard let text = sorgenti.compactMap({ $0 }).first(where: { !$0.isEmpty })
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// ⌘V, decided by what is on the clipboard and by who is listening.
    ///
    /// Text keeps the old road, the responder chain, and nothing about it
    /// changes. A picture had no road at all: a terminal asks the clipboard
    /// for a string, is given nothing, and pastes nothing, so ⌘V on a
    /// screenshot read as a dead key (his report, 2026-08-24).
    ///
    /// Three destinations, in the order they are asked. A text view takes the
    /// path, because the bubble sends words and a path is a word. An agent
    /// takes ctrl+V, the key `claude` binds to reading the clipboard itself —
    /// better than a path, because the picture arrives as a picture. A pane
    /// with no agent gets the path: it is the only thing a shell could use,
    /// and a control byte there would sit in the line as literal-next.
    /// Un file o un'immagine lasciati cadere finiscono nella riga d'ingresso.
    ///
    /// Suo, 27/08: «trascinata nella bolla o sullo schermo del terminale, non
    /// importa, deve essere incollata nella riga di testo». È la stessa
    /// dottrina di ⌘V con un'immagine negli appunti: chi ha la riga
    /// d'ingresso se la prende. Torna `false` quando la bolla non c'è, e
    /// allora il pannello scrive i percorsi nel pty come ha sempre fatto,
    /// che è il caso giusto per una shell senza agente.
    private func consegnaDrop(_ paths: [String]) -> Bool {
        guard composerShouldShow, !paths.isEmpty else { return false }
        for path in paths { composer.field.insertAttachment(path: path) }
        composer.focus()
        return true
    }

    @objc func pasteHere() {
        let board = NSPasteboard.general
        // Finder may put both a file URL and a display name on the same
        // pasteboard. The file type wins before the string is even inspected:
        // deciding from `nome.mov` is what lost the directory. In the bubble
        // the path becomes an attachment; in the pane it travels through the
        // same bracketed-paste writer as a real terminal paste, with no Return.
        let filePaths = ClipboardImage.filePaths(on: board)
        if !filePaths.isEmpty {
            if let field = window?.firstResponder as? ComposerField {
                for path in filePaths { field.insertAttachment(path: path) }
            } else {
                activeTab?.activePane.session.backend.compose(
                    text: filePaths.joined(separator: " "), submitAfter: nil)
            }
            return
        }
        let text = board.string(forType: .string)
        // Text into the pane goes through OUR bracketed writer, not the
        // engine's: the engine frames a paste but does not strip a paste-end
        // sequence out of it, and a clipboard that carries `ESC[201~` would
        // otherwise type the rest of itself (Gemini audit 2026-09-06). A text
        // view keeps the system paste.
        if let text, !(window?.firstResponder is NSTextView) {
            activeTab?.activePane.session.backend.compose(text: text, submitAfter: nil)
            return
        }
        guard text == nil, ClipboardImage.isOnClipboard(board) else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            return
        }
        if let editor = window?.firstResponder as? NSTextView {
            guard let path = ClipboardImage.writeToDisk(board) else { return }
            if let field = editor as? ComposerField { field.insertAttachment(path: path) }
            else { editor.insertText(path, replacementRange: editor.selectedRange()) }
            return
        }
        guard let session = activeTab?.activePane.session else { return }
        // `agent` is not the question: every pane has an observer, attached or
        // not, so asking whether it exists says yes above a bare shell too
        // (measured with the dump on 2026-08-24 — `attached: false`, kind
        // empty, and ctrl+V went to `cat`). What matters is whether something
        // is actually there to read a clipboard.
        if session.agent?.isAttached == true {
            session.backend.send(bytes: [0x16])
            return
        }
        guard let path = ClipboardImage.writeToDisk(board) else { return }
        session.backend.compose(text: path, submitAfter: nil)
    }

    /// ⌘A selects what the caret is in, not always the buffer.
    ///
    /// Until now this always selected the whole terminal, wherever the caret
    /// was: a ⌘A meant to select the line being typed in the composer silently
    /// selected the entire pane instead (his report, 2026-08-24). The composer
    /// is an `NSTextView`, and so is the field editor behind every text field,
    /// so asking the first responder is the whole rule.
    @objc func selectAllText() {
        if let text = window?.firstResponder as? NSTextView {
            text.selectAll(nil)
            return
        }
        activeTab?.activePane.session.backend.selectAll()
    }

    @objc func revealConfig() {
        // Writing a value the file already carries is a no-op, so the reveal
        // makes the file exist without changing the settings behind it.
        config.set(.theme, config.string(.theme) == "black" ? "black" : config.string(.theme))
        if config.isUnconfigured { config.set(.fontSize, config.int(.fontSize)) }
        NSWorkspace.shared.selectFile(config.url.path,
                                      inFileViewerRootedAtPath: config.url
                                          .deletingLastPathComponent().path)
    }
}

extension MainWindowController: @preconcurrency NSWindowDelegate {
    /// Sei tornato a guardare questa finestra — da un'altra app, da un'altra
    /// finestra, da un clic sulla barra del titolo — e la tastiera torna nella
    /// bolla (ISC-188). Chi tiene la tastiera lo decide la regola sola.
    ///
    /// Qui, e non su `applicationDidBecomeActive`, perché il primo responder è
    /// una cosa della FINESTRA: con le impostazioni aperte è la loro finestra a
    /// tornare chiave, questa non lo diventa, e la tastiera resta lì dov'era.
    func windowDidBecomeKey(_ notification: Notification) {
        restituisciTastieraAllaBolla()
    }

    func windowDidResize(_ notification: Notification) { noteFrameChanged() }
    func windowDidMove(_ notification: Notification) { noteFrameChanged() }

    /// The end of a drag. AppKit calls this once, when the mouse comes up,
    /// which is the only moment the size is a size the user chose.
    func windowDidEndLiveResize(_ notification: Notification) { saveFrameNow() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        // Whatever was pending belongs to the window's real shape, and the
        // window is about to stop having one; it was already saved on the way
        // in, so the pending flag is dropped rather than flushed.
        frameSaveTimer?.invalidate()
        frameSaveTimer = nil
        frameSavePending = false
        fullScreenTransition = "entering"
        recordFullScreenHook("willEnter")
        applyFullScreenLayout(true, animated: fullScreenLayoutShouldAnimate)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        // Model constants already carry the final values. The guard makes the
        // Did hook a verifier, not a second visible layout step.
        if !fullScreenLayoutIsAtTarget(true) {
            applyFullScreenLayout(true, animated: false)
        }
        band.finishFullScreenAppearance(true)
        fullScreenTransition = "fullScreen"
        recordFullScreenHook("didEnter")
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullScreenTransition = "exiting"
        recordFullScreenHook("willExit")
        applyFullScreenLayout(false, animated: fullScreenLayoutShouldAnimate)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if !fullScreenLayoutIsAtTarget(false) {
            applyFullScreenLayout(false, animated: false)
        }
        band.finishFullScreenAppearance(false)
        fullScreenTransition = "windowed"
        recordFullScreenHook("didExit")
        saveFrameNow(force: true)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        applyFullScreenLayout(false, animated: false)
        band.finishFullScreenAppearance(false)
        fullScreenTransition = "windowed"
        recordFullScreenHook("failedEnter")
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        applyFullScreenLayout(true, animated: false)
        band.finishFullScreenAppearance(true)
        fullScreenTransition = "fullScreen"
        recordFullScreenHook("failedExit")
    }

    /// ⌘W on the last pane, the red button, and Quit all arrive here.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Once the app is on its way out, the question is over.
        //
        // Without this, a SIGTERM to a window with `claude` in it put a sheet
        // on screen that nobody would ever answer and the process never died:
        // three orphaned T4A instances were found sitting on the screen on
        // 2026-08-20, each waiting for an answer to a question asked of a
        // machine. A guard against a reflex must never become a guard against
        // the operating system.
        guard !isTearingDown else { return true }
        let running = tabs.flatMap(\.sessions).compactMap(\.closingWouldInterrupt)
        guard !running.isEmpty else { return true }
        confirm(closing: running,
                subject: tabs.count == 1 && tabs[0].panes.count == 1
                    ? .pane : .window) { [weak self] in
            self?.forceCloseWindow()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Le impostazioni sono una finestra DI questa finestra, e se ne vanno
        // con lei (ISC-193, parole sue: «i settings devono essere sempre
        // legati all'app»). Il controller sopravviveva alla principale, e
        // `applicationShouldTerminateAfterLastWindowClosed` conta le finestre:
        // chiusa la principale, l'app restava viva con il solo pannello sullo
        // schermo, cioè un terminale senza terminale.
        //
        // Qui e non in un `windowWillClose` dentro `SettingsWindowController`:
        // là ce n'è deliberatamente nessuno, perché ricordare la posizione
        // alla chiusura scrive uno scostamento che nessuno ha scelto (il
        // commento in `SettingsWindow.swift` lo racconta per intero). Questa
        // riga non ricorda niente, chiude e basta.
        //
        // E chiude LE SUE: con due finestre principali (⌘N) ognuna ha il suo
        // pannello, e chi resta aperto tiene il proprio.
        settings?.close()
        settings = nil
        saveFrameNow()
        closeEverything()
        onWindowClosed?(self)
    }
}

// MARK: - ⌘K, the command palette (ISC-32)

extension MainWindowController {
    /// ⌘K. Everything the palette needs is built here, inside the measured
    /// window: what the bench times is the real work of opening, not an empty
    /// box that fills itself in a frame later.
    @objc func showCommandPalette() {
        guard let window else { return }
        // The KEYSTROKE's timestamp, not a clock read now. `NSEvent.timestamp`
        // and `CACurrentMediaTime()` are both seconds of system uptime, so the
        // subtraction is honest; the dump carries the difference between the
        // two clocks as its own control, so a day where that stops being true
        // shows up as a number rather than as a good result.
        //
        // The `type == .keyDown` is not a formality, and it cost a wrong
        // number to learn. `NSApp.currentEvent` is the event the RUN LOOP is
        // dispatching, and a `sendEvent` called from anywhere else — a test
        // channel, a script — leaves it holding whatever came through the
        // queue last. The first measurement taken here read 3067 ms, which
        // was the age of the mouse move that activated the window at launch.
        // A latency that is quietly measured from the wrong start is worse
        // than no latency at all, so the start is either a key-down the
        // application is really dispatching or one the caller stamped itself.
        let keystroke = pendingKeystrokeAt
            ?? NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0.timestamp : nil }
            ?? CACurrentMediaTime()
        pendingKeystrokeAt = nil
        guard commandPalette.isHidden else { commandPalette.close(); return }
        commandPalette.onClose = { [weak self] in self?.refresh() }
        commandPalette.open(items: paletteItems(), at: keystroke,
                            restoring: window.firstResponder)
        commandPalette.focusField()
    }

    /// Three families, in the order ISC-32 names them.
    private func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []

        for tab in tabs {
            for session in tab.sessions {
                let id = session.id
                items.append(PaletteItem(
                    family: BenchPalette.sessions,
                    displayFamily: S.commandPaletteSessions,
                    identifier: session.displayName,
                    title: session.displayName,
                    detail: session.isWaitingForYou
                        ? S.commandPaletteWaitingForYou : session.statusLine,
                    run: { [weak self] in _ = self?.focusSession(id: id) }))
            }
        }

        let currentTheme = config.string(.theme)
        for name in availableThemeNames() {
            let built = Theme.all.first { $0.name == name }
            let englishTitle = built?.title ?? name
            items.append(PaletteItem(
                family: BenchPalette.themes,
                displayFamily: S.commandPaletteThemes,
                identifier: englishTitle,
                title: S.settingsThemeTitle(name: name, fallback: englishTitle),
                detail: name == currentTheme
                    ? S.commandPaletteCurrent : (built == nil ? S.commandPaletteYours : ""),
                run: { [weak self] in self?.setTheme(name) }))
        }

        func action(_ identifier: String, displayedTitle: String, _ shortcut: String,
                    _ run: @escaping () -> Void) {
            items.append(PaletteItem(family: BenchPalette.actions,
                                     displayFamily: S.commandPaletteActions,
                                     identifier: identifier, title: displayedTitle,
                                     detail: shortcut, run: run))
        }
        action(BenchPalette.newTab, displayedTitle: S.newTab, "⌘T") {
            [weak self] in self?.newTab()
        }
        action(BenchPalette.splitRight, displayedTitle: S.splitRight, "⌘D") {
            [weak self] in self?.splitVertically()
        }
        action(BenchPalette.splitDown, displayedTitle: S.splitDown, "⇧⌘D") {
            [weak self] in self?.splitHorizontally()
        }
        action(BenchPalette.closePane, displayedTitle: S.closePane, "⌘W") {
            [weak self] in self?.closeCurrent()
        }
        action(BenchPalette.clearBuffer, displayedTitle: S.clearBuffer, "⇧⌘K") {
            [weak self] in self?.clearBuffer()
        }
        action(BenchPalette.find, displayedTitle: S.find, "⌘F") {
            [weak self] in self?.showFind()
        }
        action(BenchPalette.settings, displayedTitle: S.settingsEllipsis, "") {
            [weak self] in self?.openSettings()
        }
        action(BenchPalette.commandMap, displayedTitle: S.commandMap, "⌥⌘2") {
            [weak self] in self?.toggleInspector()
        }
        action(BenchPalette.dashboardBar, displayedTitle: S.dashboardBarAction, "⌥⌘3") {
            [weak self] in self?.toggleDash()
        }
        action(BenchPalette.preview, displayedTitle: S.preview, "⌥⌘P") {
            [weak self] in self?.togglePreviewCollapsed()
        }
        action(BenchPalette.previewInFront, displayedTitle: S.previewInFront, "⇧⌥⌘P") {
            [weak self] in self?.previewToFront()
        }
        action(BenchPalette.sessionsAsTabsOrRail, displayedTitle: S.sessionsAsTabsOrRail, "⌥⌘L") {
            [weak self] in self?.toggleSessionLayout()
        }
        action(BenchPalette.bigger, displayedTitle: S.bigger, "⌘+") {
            [weak self] in self?.fontBigger()
        }
        action(BenchPalette.smaller, displayedTitle: S.smaller, "⌘-") {
            [weak self] in self?.fontSmaller()
        }
        action(BenchPalette.actualSize, displayedTitle: S.actualSize, "⌘0") {
            [weak self] in self?.fontActualSize()
        }
        action(BenchPalette.openConfigurationFile, displayedTitle: S.openConfigurationFile, "") {
            [weak self] in self?.revealConfig()
        }
        return items
    }

#if DEBUG || T4A_TESTABLE
    // Everything to the #endif is the surface the benches drive and read,
    // and it is compiled only into a build that asked for it (ISC-128).
    // Without the channel in TestChannel.swift nothing can reach these
    // methods, but a remote control for a terminal should not be sitting
    // in the shipped binary waiting for a caller either.
    // MARK: - What the bench drives and reads

    /// `palette open` presses ⌘K for real: a key-down event handed to
    /// `NSApp.sendEvent`, which is where a menu key equivalent is matched. It
    /// is the same road a finger takes, which is the only road worth timing.
    func testPalette(_ rest: String) {
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "open":
            pendingKeystrokeAt = ProcessInfo.processInfo.systemUptime
            // Handed to the MENU, which is the object that owns ⌘K, rather
            // than to `NSApp.sendEvent`: `sendEvent` only reaches the menu
            // while the application is the front one, and a bench that has to
            // hold the front of the screen for a hundred presses is a bench
            // that goes red when somebody clicks somewhere else. The one
            // press that proves the whole road end to end — window server,
            // front app, menu, action — is the real one the bench posts with
            // `keypress`, which is not this.
            guard let window, let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: pendingKeystrokeAt ?? ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "k", charactersIgnoringModifiers: "k",
                isARepeat: false, keyCode: 40) else { return }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) != true {
                NSLog("T4A: ⌘K matched no menu item")
                pendingKeystrokeAt = nil
            }
        case "esc": sendKeyToApp("\u{1b}", keyCode: 53, flags: [])
        case "close": commandPalette.close()
        case "down": commandPalette.move(1)
        case "up": commandPalette.move(-1)
        case "enter": commandPalette.runSelected()
        case "type":
            let text = parts.count > 1 ? parts[1] : ""
            commandPalette.type(text)
        default: NSLog("T4A: unknown palette command \(rest)")
        }
    }

    /// A key event put into the application, not into a view: it goes to the
    /// menu and then to whoever holds the keyboard, which is what makes it a
    /// probe of focus and not just of a method.
    func sendKeyToApp(_ characters: String, keyCode: UInt16,
                      flags: NSEvent.ModifierFlags) {
        guard let window, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode) else { return }
        NSApp.sendEvent(event)
    }

    /// Types through the responder chain rather than into a chosen view.
    ///
    /// `text` aims at the terminal surface directly, which proves the pty is
    /// alive but says nothing about who holds the keyboard. This one asks the
    /// window, so after the palette closes it answers the question the claim
    /// is really about: does what I type still reach the program?
    func testTypeThroughResponder(_ text: String) {
        for character in text {
            let string = String(character)
            sendKeyToApp(string, keyCode: character == "\n" ? 36 : 0, flags: [])
        }
    }

    /// What view is actually under a point on the DISPLAY.
    ///
    /// It exists because "the click did nothing" has two very different
    /// causes — the button never got the event, or it got it and did nothing —
    /// and no amount of clicking from outside can tell them apart. The answer
    /// is a hit test, asked of the same window server coordinate the mouse
    /// was posted at.
    func testHitTest(_ spec: String) {
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        let onScreen = NSPoint(x: parts[0], y: parts[1])
        var found: [String] = []
        for window in NSApp.windows where window.isVisible {
            let inWindow = window.convertPoint(fromScreen: onScreen)
            guard window.contentView?.bounds
                .contains(window.contentView!.convert(inWindow, from: nil)) == true else { continue }
            var view = window.contentView?.hitTest(inWindow)
            var chain: [String] = []
            while let current = view {
                chain.append(String(describing: type(of: current)))
                view = current.superview
            }
            found.append("\(window.title.isEmpty ? "main" : window.title): "
                + (chain.isEmpty ? "nothing" : chain.joined(separator: " < ")))
        }
        lastHitTest = found
    }

    func testPaletteState() -> [String: Any] {
        var state = commandPalette.testState
        // The control for the measurement: the two clocks the timing
        // subtracts, read one after the other. A number near zero is what
        // makes the openings above mean anything.
        state["clockSkewMs"] = (CACurrentMediaTime()
            - ProcessInfo.processInfo.systemUptime) * 1000
        return state
    }

    func testThemeState() -> [String: Any] {
        func hex(_ colour: NSColor) -> String {
            let srgb = colour.usingColorSpace(.sRGB) ?? colour
            return String(format: "#%02X%02X%02X",
                          Int((srgb.redComponent * 255).rounded()),
                          Int((srgb.greenComponent * 255).rounded()),
                          Int((srgb.blueComponent * 255).rounded()))
        }
        var state: [String: Any] = [
            "name": Theme.current.name,
            "title": Theme.current.title,
            "configured": config.string(.theme),
            "problem": Theme.problem ?? "",
            "available": availableThemeNames(),
            "light": Theme.current.isLight,
            "chrome": [
                "ground": hex(Theme.current.ground),
                "panel": hex(Theme.current.panel),
                "ink": hex(Theme.current.ink),
                "accent": hex(Theme.current.accent),
            ],
        ]
        // What the GRID resolves its cells to, read from the backend rather
        // than from the theme: this is the half a theme used not to reach.
        if let backend = activeTab?.activePane.session.backend {
            let grid = backend.palette
            state["grid"] = [
                "background": hex(grid.background),
                "foreground": hex(grid.foreground),
                "cursor": hex(grid.cursor),
                "selection": hex(grid.selection),
                "ansi1": hex(grid.ansi[1]),
                "ansi15": hex(grid.ansi[15]),
            ]
        }
        return state
    }
#endif
}

extension MainWindowController: ThemeAware {
    /// A theme change, everywhere this window owns something that holds a
    /// colour: the window itself, the grid of every pane, and the settings
    /// sheet if it happens to be open.
    func applyTheme() {
        window?.backgroundColor = Theme.current.ground
        window?.contentView?.layer?.backgroundColor = Theme.current.ground.cgColor
        for session in tabs.flatMap(\.sessions) {
            session.backend.applyTheme(Theme.current.terminal)
        }
        refresh()
    }
}

extension MainWindowController: LanguageAware {
    /// Recompose every piece of controller-owned text. Descendant views that
    /// cache their own prose are reached by the sibling language walk.
    func applyLanguage() {
        refresh()
        splitButton.toolTip = S.splitRightTooltip
        applyPanelVisibilityNow()
        if let confirmation = closeConfirmation {
            renderCloseConfirmation(confirmation.alert, running: confirmation.running,
                                    subject: confirmation.subject)
        }
        if !commandPalette.isHidden {
            commandPalette.replace(items: paletteItems())
        }
    }
}
