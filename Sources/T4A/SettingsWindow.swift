//  SettingsWindow.swift — the settings, as the demo settled them: a column of
//  categories on the left, the chosen category's panel on the right
//  (ISC-104.6).
//
//  Two rules do the work. Every row carries ONE human name — the internal key
//  is ours, not the reader's — and every switch is the same M6 gesture, so a
//  toggle here and a toggle there cannot behave differently. And every change
//  lands in `config.toml` the moment it is made: this window is a view onto
//  the file, never a second place where settings live.

import AppKit
import TerminalCore

@MainActor
final class SettingsWindowController: NSWindowController, ThemeAware, LanguageAware,
                                      @preconcurrency NSWindowDelegate {
    static let categories = ["Sessions", "Layout", "Appearance", "Dashboard rows", "Terminal"]

    /// Test-channel names are identifiers, even while the same English words
    /// happen to be displayed. Keeping them out of the catalog prevents a
    /// translation from renaming the control a bench addresses.
    private enum BenchName {
        static let sideRail = "side rail"
        static let tabsOnTop = "tabs on top"
        static let showTheBar = "show the bar"
        static let hideUntilSecond = "hide until a second"
        static let t4aBubble = "the T4A bubble"
        static let agentLine = "the agent's own line"
        static let sessionsPanel = "Sessions panel"
        static let turnMap = "Turn map"
        static let dashboardBar = "Dashboard bar"
        static let withAgent = "with an agent"
        static let whenNeeded = "when it is needed"
        static let always = "always"
        static let never = "never"
        static let chatPage = "Chat page"
        static let pureChat = "Pure chat"
        static let languageSystem = "Follow the system"
        static let languageEnglish = "English"
        static let languageItalian = "Italian"
        static let motion = "Motion"
        static let shellIntegration = "Shell integration"
        static let agentAdapter = "Agent adapter"
        static let compactTurns = "Compact turns"
        static let notifications = "Notifications"
        static let copyOnSelect = "Copy on select"
        static let runningWork = "Running work"
        static let checkForUpdates = "Check for updates"
    }

    private let config: Configuration
    private unowned let host: MainWindowController
    private var category = "Dashboard rows"

    private let nav = NSStackView()
    private let paneHost = NSView()
    private let paneStack = NSStackView()
    private var rowsPane: DashRowsPane?
    /// Built once and idle until the button is pressed: constructing it makes
    /// no request, so the panel opening is still zero network (ISC-248).
    private lazy var updater = Updater()
    private weak var updateStatus: NSTextField?
    private weak var updateButton: ChromeButton?
    private var updateButtonWidth: NSLayoutConstraint?
    /// Every switch on screen right now, by its invariant English bench
    /// address. The control itself carries the independently localized text.
    private(set) var switches: [String: M6Switch] = [:]
    /// The one-of-several buttons — the theme is chosen with these, not with a
    /// switch — by invariant English address. Registered so a bench can press
    /// the real button instead of calling the method behind it.
    private(set) var choices: [String: ChromeButton] = [:]

    init(config: Configuration, owner: MainWindowController) {
        self.config = config
        self.host = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = S.settingsWindowTitle
        window.backgroundColor = Theme.current.raised
        // The same three lines the main window uses (ISC-155). Without them
        // the panel wore a system titlebar in system grey above a panel in the
        // app's own colour, which is two materials meeting on one window and
        // reads as somebody else's dialog — his word for it was «separata».
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: Theme.current.isLight ? .aqua : .darkAqua)
        window.minSize = NSSize(width: 640, height: 420)
        super.init(window: window)
        // OFF, and this is the whole of why the panel came up in the corner.
        //
        // `NSWindowController` cascades its window on `showWindow` by default
        // — it nudges it down and right from wherever the last one was, and
        // with nothing before it that is the bottom left of the screen. It
        // does this AFTER the frame is set, so a window placed in `init` is
        // placed and then moved, silently. Measured: `place` reported
        // «owner 260 mid 1016 -> 476,137» and the window was photographed at
        // 386,201, which is the cascade's answer and not ours.
        shouldCascadeWindows = false
        window.delegate = self
        build()
        show(category: category)
        place()
    }

    // MARK: - Where it opens (ISC-155)

    /// The offset the file remembers, as `dx dy width height`, or nil.
    private var savedOffset: (dx: CGFloat, dy: CGFloat, size: NSSize)? {
        let parts = config.string(.settingsOffset)
            .split(separator: " ").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return (CGFloat(parts[0]), CGFloat(parts[1]),
                NSSize(width: parts[2], height: parts[3]))
    }

    /// Centre it on the window that opened it, plus whatever offset the user
    /// dragged it to last time. Then push it back onto a screen: an offset
    /// saved beside a window that has since moved to the corner of a display
    /// would otherwise open half off the world.
    private(set) var lastPlace = "never"

    func place() {
        guard let window else { lastPlace = "no window"; return }
        guard let owner = host.window else { lastPlace = "no owner"; return }
        let saved = savedOffset
        var size = saved?.size ?? window.frame.size
        let ownerFrame = owner.frame
        // Never taller or wider than the window it belongs to, minus a margin:
        // a panel bigger than its parent is the other way to look detached.
        size.width = min(size.width, max(window.minSize.width, ownerFrame.width - 40))
        size.height = min(size.height, max(window.minSize.height, ownerFrame.height - 40))
        let centre = NSPoint(x: ownerFrame.midX + (saved?.dx ?? 0),
                             y: ownerFrame.midY + (saved?.dy ?? 0))
        var frame = NSRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                           width: size.width, height: size.height)
        if let visible = (owner.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
        lastPlace = "owner \(Int(ownerFrame.minX)) mid \(Int(ownerFrame.midX)) "
            + "-> \(Int(frame.minX)),\(Int(frame.minY)) saved \(config.string(.settingsOffset))"
    }

    /// What the user chose, written down as an offset from the owner's centre.
    private(set) var lastRemember = "never"

    private func rememberPlacement() {
        guard let window else { lastRemember = "no window"; return }
        guard let owner = host.window else { lastRemember = "no owner"; return }
        guard window.isVisible else { lastRemember = "not visible"; return }
        let dx = window.frame.midX - owner.frame.midX
        let dy = window.frame.midY - owner.frame.midY
        let value = "\(Int(dx.rounded())) \(Int(dy.rounded())) "
            + "\(Int(window.frame.width.rounded())) "
            + "\(Int(window.frame.height.rounded()))"
        lastRemember = "wrote " + value
        config.set(.settingsOffset, value)
    }

    private(set) var moveCount = 0

    func windowDidMove(_ notification: Notification) {
        moveCount += 1
        rememberPlacement()
    }
    func windowDidEndLiveResize(_ notification: Notification) { rememberPlacement() }
    // There is deliberately NO `windowWillClose` here, and the reason is the
    // one thing this feature can get wrong twice.
    //
    // Remembering the placement when the panel closes sounds like the safe
    // extra net, and it is the opposite: the position at close is wherever
    // `place` put it, measured against a main window that may have moved
    // since — so closing a panel nobody touched writes an offset nobody
    // chose, and the next opening honours it. Measured on the bench: the main
    // window moved to x=560, the untouched panel was still centred on x=40,
    // and the close recorded an offset of −520 which then followed the panel
    // around for the rest of the run. Only a real move is a choice.

    /// Where this window is, and where the one that owns it is, for a probe
    /// that has to say whether one centre falls inside the other.
    func testPlacement() -> [String: Any] {
        let mine = window?.frame ?? .zero
        let theirs = host.window?.frame ?? .zero
        return [
            "settings": ["x": Double(mine.minX), "y": Double(mine.minY),
                         "w": Double(mine.width), "h": Double(mine.height),
                         "cx": Double(mine.midX), "cy": Double(mine.midY)],
            "owner": ["x": Double(theirs.minX), "y": Double(theirs.minY),
                      "w": Double(theirs.width), "h": Double(theirs.height),
                      "cx": Double(theirs.midX), "cy": Double(theirs.midY)],
            "centreInsideOwner": theirs.contains(NSPoint(x: mine.midX, y: mine.midY)),
            "savedOffset": config.string(.settingsOffset),
            "titlebarTransparent": window?.titlebarAppearsTransparent ?? false,
            "moves": moveCount,
            "lastRemember": lastRemember,
            "lastPlace": lastPlace,
            "delegateIsController": (window?.delegate as AnyObject?) === self,
        ]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Rebuilt rather than repainted. Every label in here had its colour set
    /// when the row was made, so the honest way to change theme is to make
    /// the rows again — which is cheap, and cannot leave one row behind.
    func applyTheme() {
        window?.backgroundColor = Theme.current.raised
        window?.contentView?.layer?.backgroundColor = Theme.current.raised.cgColor
        window?.appearance = NSAppearance(named: Theme.current.isLight ? .aqua : .darkAqua)
        show(category: category)
    }

    func applyLanguage() {
        window?.title = S.settingsWindowTitle
        for case let button as CategoryButton in nav.arrangedSubviews {
            button.setTitle(Self.displayTitle(for: button.name))
        }
        show(category: category)
    }

    private static func displayTitle(for category: String) -> String {
        switch category {
        case "Sessions": return S.settingsCategorySessions
        case "Layout": return S.settingsCategoryLayout
        case "Appearance": return S.settingsCategoryAppearance
        case "Dashboard rows": return S.settingsCategoryDashboardRows
        case "Terminal": return S.settingsCategoryTerminal
        default: return category
        }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.current.raised.cgColor

        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        nav.edgeInsets = NSEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        nav.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        paneStack.orientation = .vertical
        paneStack.alignment = .leading
        paneStack.spacing = 0
        paneStack.translatesAutoresizingMaskIntoConstraints = false
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(paneStack)
        scroll.documentView = paneHost

        content.addSubview(nav)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            nav.topAnchor.constraint(equalTo: content.topAnchor),
            nav.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            nav.widthAnchor.constraint(equalToConstant: 152),

            scroll.leadingAnchor.constraint(equalTo: nav.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            paneHost.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            paneStack.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor, constant: 12),
            paneStack.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor, constant: -12),
            paneStack.topAnchor.constraint(equalTo: paneHost.topAnchor, constant: 10),
            paneStack.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor, constant: -14),
        ])

        for name in Self.categories {
            let button = CategoryButton(name: name, title: Self.displayTitle(for: name)) {
                [weak self] in self?.show(category: name)
            }
            nav.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: nav.widthAnchor, constant: -12).isActive = true
        }
    }

    // MARK: - The panels

    func show(category name: String) {
        category = name
        for case let button as CategoryButton in nav.arrangedSubviews {
            button.isSelected = button.name == name
        }
        paneStack.arrangedSubviews.forEach {
            paneStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        switches.removeAll()
        choices.removeAll()
        rowsPane = nil

        switch name {
        case "Sessions":
            add(SettingRow(label: S.settingsWhereTheyLive, note: "", controls: [
                choice(BenchName.sideRail, displayLabel: S.settingsSideRail,
                       on: config.string(.layoutSessions) == "rail") {
                    [weak self] in self?.host.setSessionLayout("rail")
                },
                choice(BenchName.tabsOnTop, displayLabel: S.settingsTabsOnTop,
                       on: config.string(.layoutSessions) == "tabs") {
                    [weak self] in self?.host.setSessionLayout("tabs")
                },
            ]))
            add(SettingRow(label: S.settingsOneTab,
                           note: S.settingsOneTabNote,
                           controls: [
                choice(BenchName.showTheBar, displayLabel: S.settingsShowTheBar,
                       on: config.string(.tabsWhenSingle) != "hide") {
                    [weak self] in self?.host.setTabsWhenSingle("show")
                    self?.show(category: "Sessions")
                },
                choice(BenchName.hideUntilSecond, displayLabel: S.settingsHideUntilSecond,
                       on: config.string(.tabsWhenSingle) == "hide") {
                    [weak self] in self?.host.setTabsWhenSingle("hide")
                    self?.show(category: "Sessions")
                },
            ]))
        case "Layout":
            // ONE choice for the two halves of the input story (his ask,
            // 25/08): the bubble wants the composer on AND the agent's line
            // covered; the agent's own line wants the cover off and the
            // bubble away. Set apart they leave half-states — a bubble over
            // an uncovered line says everything twice.
            add(SettingRow(label: S.settingsInput, note: S.settingsInputNote,
                           controls: [
                choice(BenchName.t4aBubble, displayLabel: S.settingsT4ABubble,
                       on: config.string(.composerMode) != "never" && config.bool(.pureChat)) {
                    [weak self] in self?.setInputMethod(bubble: true)
                },
                choice(BenchName.agentLine, displayLabel: S.settingsAgentLine,
                       on: config.string(.composerMode) == "never" || !config.bool(.pureChat)) {
                    [weak self] in self?.setInputMethod(bubble: false)
                },
            ]))
            add(switchRow(BenchName.sessionsPanel, displayLabel: S.settingsSessionsPanel,
                          note: S.settingsSessionsPanelNote,
                          key: .showSessionsPanel))
            add(switchRow(BenchName.turnMap, displayLabel: S.settingsTurnMap,
                          note: S.settingsTurnMapNote, key: .showTurnMap))
            add(switchRow(BenchName.dashboardBar, displayLabel: S.settingsDashboardBar,
                          note: S.settingsDashboardBarNote,
                          key: .showDashboard))
            add(SettingRow(label: S.settingsComposer,
                           note: S.settingsComposerNote,
                           controls: [
                // Per prima perché è il default (ISC-174): la bolla dove c'è
                // un agente, e con un terminale normale niente bolla. Le voci
                // di una fila si leggono da sinistra, e la prima è quella che
                // dice come si comporta l'app se non tocchi niente.
                choice(BenchName.withAgent, displayLabel: S.settingsWithAgent,
                       on: !["contextual", "always", "never"]
                           .contains(config.string(.composerMode))) {
                    [weak self] in self?.setComposer("agent")
                },
                choice(BenchName.whenNeeded, displayLabel: S.settingsWhenNeeded,
                       on: config.string(.composerMode) == "contextual") {
                    [weak self] in self?.setComposer("contextual")
                },
                choice(BenchName.always, displayLabel: S.settingsAlways,
                       on: config.string(.composerMode) == "always") {
                    [weak self] in self?.setComposer("always")
                },
                choice(BenchName.never, displayLabel: S.settingsNever,
                       on: config.string(.composerMode) == "never") {
                    [weak self] in self?.setComposer("never")
                },
            ]))
            add(switchRow(BenchName.chatPage, displayLabel: S.settingsChatPage,
                          note: S.settingsChatPageNote,
                          key: .chatPage))
            add(switchRow(BenchName.pureChat, displayLabel: S.settingsPureChat,
                          note: S.settingsPureChatNote,
                          key: .pureChat))
        case "Appearance":
            let names = host.availableThemeNames()
            add(SettingRow(label: S.settingsTheme,
                           note: S.settingsThemeNote,
                           controls: names.map { name in
                // A custom title such as the bench fixture "lagoon" is both
                // its address and its user-owned display fallback.
                let englishTitle = Theme.all.first { $0.name == name }?.title ?? name
                return choice(englishTitle,
                       displayLabel: S.settingsThemeTitle(name: name, fallback: englishTitle),
                       on: config.string(.theme) == name) { [weak self] in
                    self?.host.setTheme(name)
                }
            }))
            // A theme that could not be read must SAY so where it was chosen.
            // Falling back to the default without a word is the app appearing
            // to ignore you (ISC-33).
            if let problem = Theme.problem {
                let warning = NSTextField(wrappingLabelWithString:
                    S.settingsThemeFallback(current: Theme.current.title, problem: problem))
                warning.font = Theme.uiFont(11)
                warning.textColor = Theme.current.failed
                add(warning)
            }
            let language = config.languageSetting()
            add(SettingRow(label: S.language, note: S.languageNote, controls: [
                choice(BenchName.languageSystem, displayLabel: S.languageSystem,
                       on: language == "system") { [weak self] in
                    self?.config.set(.language, "system")
                },
                choice(BenchName.languageEnglish, displayLabel: S.languageEnglish,
                       on: language == "en") { [weak self] in
                    self?.config.set(.language, "en")
                },
                choice(BenchName.languageItalian, displayLabel: S.languageItalian,
                       on: language == "it") { [weak self] in
                    self?.config.set(.language, "it")
                },
            ]))
            add(switchRow(BenchName.motion, displayLabel: S.settingsMotion,
                          note: S.settingsMotionNote,
                          key: .motion))
        case "Terminal":
            add(switchRow(BenchName.shellIntegration, displayLabel: S.settingsShellIntegration,
                          note: S.settingsShellIntegrationNote,
                          key: .shellIntegration))
            add(switchRow(BenchName.agentAdapter, displayLabel: S.settingsAgentAdapter,
                          note: S.settingsAgentAdapterNote,
                          key: .agentAdapter))
            add(switchRow(BenchName.compactTurns, displayLabel: S.settingsCompactTurns,
                          note: S.settingsCompactTurnsNote,
                          key: .compactTurns))
            add(switchRow(BenchName.notifications, displayLabel: S.settingsNotifications,
                          note: S.settingsNotificationsNote,
                          key: .notifications))
            add(switchRow(BenchName.copyOnSelect, displayLabel: S.settingsCopyOnSelect,
                          note: S.settingsCopyOnSelectNote,
                          key: .copyOnSelect))
            add(updatesRow())
        default:
            let hint = NSTextField(labelWithString:
                S.settingsReorderDashboardRows)
            hint.font = Theme.uiFont(11)
            hint.textColor = Theme.current.whisper
            add(hint)
            // The transient WORKER cell has no line in the pane below, so its
            // switch lives here, above it (25/08: worker was not removable).
            let workerSwitch = M6Switch(label: S.settingsRunningWork,
                                        isOn: !host.dashRowIsOff("worker"))
            workerSwitch.onChange = { [weak self] on in
                self?.host.setDashRowOff("worker", off: !on)
            }
            switches[BenchName.runningWork] = workerSwitch
            add(SettingRow(label: S.settingsRunningWork,
                           note: S.settingsRunningWorkNote,
                           controls: [workerSwitch]))
            let pane = DashRowsPane(layout: host.dashLayout) { [weak self] layout in
                self?.host.applyDashLayout(layout)
            }
            rowsPane = pane
            add(pane)
            // Provider-owned addresses arrive at runtime and pass through
            // unchanged; bench fixtures include "Weather", "Model ladder",
            // and "Long reading".
            for (name, control) in pane.switches { switches[name] = control }
        }
    }

    private func add(_ view: NSView) {
        paneStack.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: paneStack.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: paneStack.trailingAnchor).isActive = true
    }

    private func switchRow(_ englishLabel: String, displayLabel: String? = nil,
                           note: String, key: ConfigKey) -> NSView {
        let label = displayLabel ?? englishLabel
        let control = M6Switch(label: label, isOn: config.bool(key))
        control.onChange = { [weak self] on in self?.host.setBool(key, on) }
        switches[englishLabel] = control
        return SettingRow(label: label, note: note, controls: [control])
    }

    private func choice(_ englishLabel: String, displayLabel: String? = nil,
                        on: Bool, run: @escaping () -> Void) -> NSView {
        let label = displayLabel ?? englishLabel
        let button = ChromeButton(title: label) { [weak self] in
            run()
            self?.show(category: self?.category ?? "Layout")
        }
        button.isSelected = on
        choices[englishLabel] = button
        button.widthAnchor.constraint(equalToConstant:
            max(72, label.size(withAttributes: [.font: Theme.uiFont(12)]).width + 22)).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    // MARK: - Updates (ISC-248)

    /// One row: the state in words on the left of the button, the button on
    /// the right. The button is registered under its English name so the
    /// bench presses the same control a person presses.
    private func updatesRow() -> NSView {
        let status = NSTextField(labelWithString: "")
        status.font = Theme.uiFont(11)
        status.textColor = Theme.current.whisper
        let button = ChromeButton(title: S.checkForUpdates) { [weak self] in
            self?.updater.checkNow()
        }
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        choices[BenchName.checkForUpdates] = button
        updateStatus = status
        updateButton = button
        updater.onStateChange = { [weak self] state in self?.render(update: state) }
        render(update: updater.state)
        return SettingRow(label: S.updates, note: S.updatesNote, controls: [status, button])
    }

    private func render(update state: Updater.State) {
        guard let status = updateStatus, let button = updateButton else { return }
        var title = S.checkForUpdates
        var run: () -> Void = { [weak self] in self?.updater.checkNow() }
        switch state {
        case .idle:
            status.stringValue = ""
        case .checking:
            status.stringValue = S.updateChecking
        case .upToDate(let current):
            status.stringValue = S.updateUpToDate(current: current)
        case .available(let version, let action):
            status.stringValue = S.updateAvailable(version: version)
            switch action {
            case .upgradeAndRelaunch: title = S.installUpdate(version: version)
            case .openReleasePage: title = S.openReleasePage
            }
            run = { [weak self] in self?.updater.perform(action) }
        case .upgrading(let line):
            status.stringValue = line.isEmpty ? S.updateInstalling : line
        case .failed(let message):
            status.stringValue = message
        }
        button.title = title
        button.onClick = run
        // One width constraint, re-tuned as the title changes: a fresh one per
        // render would leave the old ones behind and AppKit would pick one.
        let width = max(72, title.size(withAttributes: [.font: Theme.uiFont(12)]).width + 22)
        if let constraint = updateButtonWidth, constraint.firstItem === button {
            constraint.constant = width
        } else {
            let constraint = button.widthAnchor.constraint(equalToConstant: width)
            constraint.isActive = true
            updateButtonWidth = constraint
        }
    }

    private func setComposer(_ mode: String) {
        config.set(.composerMode, mode)
        host.applyComposerMode()
    }

    private func setInputMethod(bubble: Bool) {
        // `agent` e non più `always`: questa fila sceglie DOVE si scrive, non
        // QUANDO la bolla compare. Scegliere «la bolla di T4A» significa
        // volere la bolla, e il modo che la dà è quello di default; scrivere
        // `always` qui rimetterebbe la bolla anche sopra una shell nuda, che
        // è la cosa che ISC-174 toglie, e lo farebbe senza che nessuno abbia
        // chiesto «sempre».
        setComposer(bubble ? "agent" : "never")
        host.setBool(.pureChat, bubble)
        show(category: "Layout")   // repaint the two choices' filled states
    }

    /// Where the handles and the lines are ON SCREEN, so the bench can drag
    /// them with real events instead of asking the app to move them.
    func rowsGeometry() -> [String: Any] { rowsPane?.geometry() ?? [:] }

    func rowsTrace() -> [String: Any] { rowsPane?.trace ?? [:] }
    var currentCategory: String { category }
}

/// A category in the left column.
@MainActor
final class CategoryButton: NSView {
    /// The bench address is an invariant English key; `title` is what is
    /// drawn, and Stage 2 may translate it without changing that address.
    let name: String
    private(set) var title: String
    var isSelected = false { didSet { needsDisplay = true } }
    private let onClick: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(name: String, title: String, onClick: @escaping () -> Void) {
        self.name = name
        self.title = title
        self.onClick = onClick
        super.init(frame: .zero)
        setAccessibilityLabel(title)
    }

    func setTitle(_ title: String) {
        self.title = title
        setAccessibilityLabel(title)
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 32) }

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
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        if isSelected || hovering {
            palette.pane.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: Theme.uiFont(12.5, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected || hovering ? palette.ink : palette.muted,
        ])
        text.draw(at: NSPoint(x: 10, y: (bounds.height - text.size().height) / 2))
    }
}

/// One line of the panel: a name, a note under it, and its controls at the
/// far right.
///
/// A row with ONE switch IS that switch, all of it (ISC-191). The switch is
/// 34×18 in a row 46 tall and as wide as the panel, so all of the row but a
/// fiftieth of it did nothing at all — measured 27/08 on his own
/// configuration: in the middle of the switch it toggles, nine points above
/// the centre it does not, and neither does the name, the note, nor the empty
/// space between them. That is the house rule about a button being clickable
/// on its whole rectangle, in the one place where the rectangle is a line of
/// text with a control at the end of it.
///
/// A row with SEVERAL controls is untouched: with three one-of-N buttons on a
/// line there is no single answer to what a click on the line means.
@MainActor
final class SettingRow: NSView {
    /// The one switch this row speaks for, when it has exactly one.
    private let single: M6Switch?
    private var pressing = false

    init(label: String, note: String, controls: [NSView]) {
        single = controls.count == 1 ? controls.first as? M6Switch : nil
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: label)
        name.font = Theme.uiFont(12.5)
        name.textColor = Theme.current.muted
        let text = NSStackView(views: note.isEmpty ? [name] : [name, {
            let sub = NSTextField(labelWithString: note)
            sub.font = Theme.uiFont(10.5)
            sub.textColor = Theme.current.whisper
            return sub
        }()])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let group = NSStackView(views: controls)
        group.orientation = .horizontal
        group.spacing = 6
        for view in [text, group] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            group.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            group.centerYAnchor.constraint(equalTo: centerYAnchor),
            group.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 16),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    /// Everything that is not the switch answers as the ROW. A label is the
    /// reason this is a hit test and not two `mouseDown`s: `NSTextField` takes
    /// the click and drops it where it stands, so a row that only overrode
    /// `mouseDown` would still have two dead words in the middle of it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        guard let single, let found else { return found }
        if found === single || found.isDescendant(of: single) { return found }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard single != nil else { super.mouseDown(with: event); return }
        pressing = true
    }

    /// Released inside the row, the way a button behaves: a press that wanders
    /// off before it is let go is a mind changed, not a choice made.
    override func mouseUp(with event: NSEvent) {
        guard let single, pressing else { super.mouseUp(with: event); return }
        pressing = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        single.press()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.current.hairlineSoft.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
