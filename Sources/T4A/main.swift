//  main.swift — T4A starts here.

import AppKit
import TerminalCore

@MainActor
final class AppDelegate: NSObject, @preconcurrency NSApplicationDelegate {
    /// Menu titles spoken by TestChannel are identifiers, not display text.
    private enum BenchMenu {
        static let aboutT4A = "About T4A"
        static let openConfigurationFile = "Open configuration file"
        static let hideT4A = "Hide T4A"
        static let hideOthers = "Hide Others"
        static let quitT4A = "Quit T4A"
        static let shell = "Shell"
        static let newWindow = "New Window"
        static let goToSession = "Go to Session"
        static func session(_ number: Int) -> String { "Session \(number)" }
        static let newTab = "New Tab"
        static let splitRight = "Split Right"
        static let splitDown = "Split Down"
        static let closePane = "Close Pane"
        static let edit = "Edit"
        static let undo = "Undo"
        static let redo = "Redo"
        static let copy = "Copy"
        static let paste = "Paste"
        static let selectAll = "Select All"
        static let messageThisSession = "Message This Session"
        static let find = "Find…"
        static let findNext = "Find Next"
        static let findPrevious = "Find Previous"
        static let view = "View"
        static let bigger = "Bigger"
        static let smaller = "Smaller"
        static let actualSize = "Actual Size"
        static let commandPalette = "Command Palette"
        static let clearBuffer = "Clear Buffer"
        static let chatPage = "Chat Page"
        static let commandMap = "Command Map"
        static let dashboard = "Dashboard"
        static let preview = "Preview"
        static let previewInFront = "Preview in Front"
        static let sessionsAsTabsOrRail = "Sessions as Tabs / Rail"
        static let nextTheme = "Next Theme"
        static let dumpLayout = "Dump Layout"
        static let window = "Window"
        static let minimize = "Minimize"
        static let zoom = "Zoom"
        static let bringAllToFront = "Bring All to Front"
    }

    /// Every window T4A has open. ⌘N makes another; each one owns its own
    /// tabs, splits and child processes, and the last one to close ends the
    /// app.
    private var controllers: [MainWindowController] = []
    private let config = Configuration()
    private var integrationRoot: URL?
    private var tabDoor: TabDoorWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A drawing exception dies inside AppKit's own catch, which crashes
        // without ever printing WHAT was thrown: the stack is all AppKit and
        // the reason is nowhere (paid 25/08 — three reproductions to learn
        // nothing). This handler is the missing sentence in the crash log.
        NSSetUncaughtExceptionHandler { exception in
            NSLog("T4A UNCAUGHT: %@ — %@", exception.name.rawValue,
                  exception.reason ?? "no reason")
            for line in exception.callStackSymbols.prefix(16) { NSLog("T4A STACK: %@", line) }
        }
        installSignalCleanup()
        LanguageStore.shared.value = Lang.resolve(
            setting: config.languageSetting(),
            environment: ProcessInfo.processInfo.environment,
            preferredLanguages: Locale.preferredLanguages
        )
        // Configuration is rewritten by `set`, then announces the changed
        // key. Language follows that in-memory event; re-reading config.toml
        // here would make the file a second, racy notification mechanism.
        config.onChange = { [weak self] key in
            guard key == .language else { return }
            self?.applyLanguageFromConfig()
        }
        // `theme` may name one of the four built in or a file in `themes/`
        // beside the configuration; either way it is resolved once here and
        // again on every change, through the same function (ISC-33).
        Theme.use(resolved: Theme.resolve(config.string(.theme),
                                          themes: Theme.themesDirectory(besides: config.url)))
        Notifier.shared.isEnabled = config.bool(.notifications)
        Notifier.shared.onActivate = { [weak self] id in
            for controller in self?.controllers ?? [] where controller.focusSession(id: id) {
                return
            }
        }
        // Which pane the user is looking at, asked at the moment a banner
        // would appear rather than remembered from when it was posted.
        Notifier.shared.activePaneProvider = { [weak self] in
            guard let self else { return nil }
            let key = self.controllers.first { $0.window?.isKeyWindow == true }
            return (key ?? self.controllers.first)?.activeSessionID
        }
        Notifier.shared.start()

        integrationRoot = Bundle.main.url(forResource: "Integration", withExtension: nil)
        if integrationRoot == nil {
            // Running from a bare build rather than the bundle: the terminal
            // works, the command blocks do not, and the strip says so rather
            // than pretending.
            NSLog("T4A: no Integration resources found; OSC 133 blocks are off")
        }
        let window = makeWindow()
        // Only the first window carries the test channel: a second reader on
        // the same pipe would swallow half the commands.
        window.openTestChannel()
        startTabDoor()
        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["T4A_DUMP_LAYOUT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { window.dumpLayout() }
        }
    }

    /// `t4a://focus?session=<uuid>` — the door that goes with the badge in
    /// `T4A_SESSION_ID`. iTerm's equivalent is its AppleScript dictionary;
    /// a URL does the same job without asking the user for Automation
    /// permission, and it lands on the same code path as a clicked
    /// notification, so there is one way to reveal a pane, not two.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { focus(url: url) }
    }

    private func focus(url: URL) {
        guard url.scheme?.lowercased() == "t4a" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        guard let raw = query?.first(where: { $0.name == "session" })?.value,
              let id = UUID(uuidString: raw) else {
            NSLog("T4A: %@ names no session", url.absoluteString)
            return
        }
        // A pane that has gone stays gone: saying so in the log beats
        // activating the app on whatever pane happens to be in front, which
        // is the failure the notch's jump had against iTerm.
        guard controllers.contains(where: { $0.focusSession(id: id) }) else {
            NSLog("T4A: no pane holds session %@", id.uuidString)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A local program gets the front T4A window, but never activates the app
    /// on the program's behalf. If no window remains, a new one is made.
    private func openDoorRequest(_ request: TabRequest) -> UUID {
        if let front = controllers.first(where: { $0.window?.isKeyWindow == true })
            ?? controllers.first {
            return front.openDoorTab(directory: URL(fileURLWithPath: request.cwd),
                                     command: request.command, label: request.label)
        }

        let controller = makeWindow()
        let initial = controller.activeSessionID
        let id = controller.openDoorTab(directory: URL(fileURLWithPath: request.cwd),
                                        command: request.command, label: request.label)
        // `MainWindowController` is born with one ordinary tab. Once the
        // requested tab exists it is safe to discard that bootstrap pane, so
        // creating a window for the door still produces exactly one tab.
        if let initial { _ = controller.closeDoorSession(id: initial, allPaneCount: 2) }
        return id
    }

    private func closeDoorRequest(_ id: UUID) -> DoorCloseResult {
        let allPaneCount = controllers.reduce(0) { $0 + $1.doorPaneCount }
        for controller in controllers {
            let result = controller.closeDoorSession(id: id, allPaneCount: allPaneCount)
            if case .unknown = result { continue }
            return result
        }
        return .unknown
    }

    private func startTabDoor() {
        let directory = TabDoor.directory(environment: ProcessInfo.processInfo.environment,
                                          home: NSHomeDirectory())
        tabDoor = TabDoorWatcher(
            directory: directory,
            openRequest: { [unowned self] in self.openDoorRequest($0) },
            closeRequest: { [unowned self] in self.closeDoorRequest($0) })
    }

    @discardableResult
    private func makeWindow() -> MainWindowController {
        let controller = MainWindowController(config: config, integrationRoot: integrationRoot)
        controller.onWindowClosed = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// ⌘N. A second window, not a second app: same configuration, same
    /// integration, its own processes.
    @objc func newWindow() { makeWindow() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.closeEverything() }
    }

    /// SIGTERM and SIGINT never reach `applicationWillTerminate`, so the tidy
    /// path alone leaves orphaned shells behind whenever anything kills the
    /// app from outside. These handlers run on the main queue, close the
    /// children, and then let the default disposition finish the job.
    private func installSignalCleanup() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.controllers.forEach { $0.closeEverything() }
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    /// The menus a Mac terminal is expected to have.
    ///
    /// Nothing here targets a particular window: every item goes down the
    /// responder chain, so a command lands on the window the user is actually
    /// in — which is the only way ⌘N can exist at all (ISC-110).
    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu(title: "T4A")
        add(appMenu, BenchMenu.aboutT4A, "", #selector(showAbout),
            displayedTitle: S.aboutT4A)
        appMenu.addItem(.separator())
        add(appMenu, BenchMenu.openConfigurationFile, "",
            #selector(MainWindowController.revealConfig),
            displayedTitle: S.openConfigurationFile)
        appMenu.addItem(.separator())
        add(appMenu, BenchMenu.hideT4A, "h", #selector(NSApplication.hide(_:)),
            displayedTitle: S.hideT4A)
        add(appMenu, BenchMenu.hideOthers, "h",
            #selector(NSApplication.hideOtherApplications(_:)),
            modifiers: [.command, .option], displayedTitle: S.hideOthers)
        appMenu.addItem(.separator())
        add(appMenu, BenchMenu.quitT4A, "q", #selector(NSApplication.terminate(_:)),
            displayedTitle: S.quitT4A)
        main.addItem(submenu: appMenu)

        let shellMenu = NSMenu(title: S.shellMenu)
        add(shellMenu, BenchMenu.newWindow, "n", #selector(newWindow),
            displayedTitle: S.newWindow)
        // ⌘1…⌘9 straight to a session. In a submenu rather than nine lines in
        // the Shell menu: the shortcut is what gets used, the list is only
        // there so it can be found once.
        let sessionsItem = add(shellMenu, BenchMenu.goToSession, "", nil,
                               displayedTitle: S.goToSession)
        let sessionsMenu = NSMenu(title: S.goToSession)
        for n in 1...9 {
            let item = add(sessionsMenu, BenchMenu.session(n), String(n),
                           #selector(MainWindowController.goToSession(_:)),
                           displayedTitle: S.session(number: n))
            item.tag = n
        }
        sessionsItem.submenu = sessionsMenu
        add(shellMenu, BenchMenu.newTab, "t", #selector(MainWindowController.newTab),
            displayedTitle: S.newTab)
        shellMenu.addItem(.separator())
        add(shellMenu, BenchMenu.splitRight, "d",
            #selector(MainWindowController.splitVertically), displayedTitle: S.splitRight)
        add(shellMenu, BenchMenu.splitDown, "D",
            #selector(MainWindowController.splitHorizontally),
            modifiers: [.command, .shift], displayedTitle: S.splitDown)
        shellMenu.addItem(.separator())
        add(shellMenu, BenchMenu.closePane, "w", #selector(MainWindowController.closeCurrent),
            displayedTitle: S.closePane)
        main.addItem(submenu: shellMenu)

        let editMenu = NSMenu(title: S.editMenu)
        // Undo and Redo go to whoever holds the keyboard, which is why they
        // carry no target: the bubble keeps an undo manager, a terminal pane
        // does not, so AppKit greys them out there by itself. Without these
        // two items ⌘Z did nothing anywhere in the app, bubble included (his
        // report, 2026-08-24) — a text view answers the menu, not the key.
        add(editMenu, BenchMenu.undo, "z", Selector(("undo:")), displayedTitle: S.undo)
        add(editMenu, BenchMenu.redo, "z", Selector(("redo:")),
            modifiers: [.command, .shift], displayedTitle: S.redo)
        editMenu.addItem(.separator())
        add(editMenu, BenchMenu.copy, "c", #selector(MainWindowController.copySelection),
            displayedTitle: S.copy)
        // Paste goes through the controller now, because ⌘V with a PICTURE on
        // the clipboard used to do nothing at all: a terminal pastes strings,
        // and an image is not one (his report, 2026-08-24). The controller
        // looks at what is on the clipboard first and only then decides who
        // gets it; plain text still travels the responder chain as before.
        add(editMenu, BenchMenu.paste, "v", #selector(MainWindowController.pasteHere),
            displayedTitle: S.paste)
        add(editMenu, BenchMenu.selectAll, "a", #selector(MainWindowController.selectAllText),
            displayedTitle: S.selectAll)
        editMenu.addItem(.separator())
        // ⌘L puts the keyboard in the bubble (ISC-158). Clicking it was the
        // only way in, and after a line was sent the keyboard went back to the
        // terminal — so the next thing typed landed in the agent's own input
        // box, under the cover, where nobody could see it.
        add(editMenu, BenchMenu.messageThisSession, "l",
            #selector(MainWindowController.focusComposer), displayedTitle: S.messageThisSession)
        editMenu.addItem(.separator())
        // Our own find, not the engine's: the matches are painted by the
        // renderer with the cells (ISC-66), which the engine's find bar
        // cannot do because it does not know a GPU renderer exists.
        add(editMenu, BenchMenu.find, "f", #selector(MainWindowController.showFind),
            displayedTitle: S.find)
        add(editMenu, BenchMenu.findNext, "g", #selector(MainWindowController.findNext),
            displayedTitle: S.findNext)
        add(editMenu, BenchMenu.findPrevious, "G", #selector(MainWindowController.findPrevious),
            modifiers: [.command, .shift], displayedTitle: S.findPrevious)
        main.addItem(submenu: editMenu)

        let viewMenu = NSMenu(title: S.viewMenu)
        add(viewMenu, BenchMenu.bigger, "+", #selector(MainWindowController.fontBigger),
            displayedTitle: S.bigger)
        // ⌘= is the key people actually press for ⌘+, because + needs shift.
        let equals = add(viewMenu, BenchMenu.bigger, "=",
                         #selector(MainWindowController.fontBigger), displayedTitle: S.bigger)
        equals.isHidden = true
        equals.isAlternate = false
        add(viewMenu, BenchMenu.smaller, "-", #selector(MainWindowController.fontSmaller),
            displayedTitle: S.smaller)
        add(viewMenu, BenchMenu.actualSize, "0", #selector(MainWindowController.fontActualSize),
            displayedTitle: S.actualSize)
        viewMenu.addItem(.separator())
        // ⌘K is the palette, as it is in T3 and Cursor; clearing the buffer —
        // the ⌘K of every other Mac terminal — moves one modifier over. The
        // door to everything goes under the fingers; the rare gesture does
        // not (ISC-32, and the decision of 20/08 that deferred this).
        add(viewMenu, BenchMenu.commandPalette, "k",
            #selector(MainWindowController.showCommandPalette), displayedTitle: S.commandPalette)
        add(viewMenu, BenchMenu.clearBuffer, "K", #selector(MainWindowController.clearBuffer),
            modifiers: [.command, .shift], displayedTitle: S.clearBuffer)
        viewMenu.addItem(.separator())
        // La pagina della chat sta accanto agli altri due pannelli, con lo
        // stesso modificatore: sono la stessa famiglia di gesti, «mostrami
        // un'altra faccia di questa finestra».
        add(viewMenu, BenchMenu.chatPage, "1", #selector(MainWindowController.toggleChatPage),
            modifiers: [.command, .option], displayedTitle: S.chatPage)
        add(viewMenu, BenchMenu.commandMap, "2", #selector(MainWindowController.toggleInspector),
            modifiers: [.command, .option], displayedTitle: S.commandMap)
        add(viewMenu, BenchMenu.dashboard, "3", #selector(MainWindowController.toggleDash),
            modifiers: [.command, .option], displayedTitle: S.dashboard)
        // L'anteprima sta nella stessa famiglia: stesso modificatore, e una
        // lettera invece di un numero perchè non è un quarto pannello fisso
        // — esiste solo quando hai cliccato il nome di un file (ISC-176).
        add(viewMenu, BenchMenu.preview, "p",
            #selector(MainWindowController.togglePreviewCollapsed),
            modifiers: [.command, .option], displayedTitle: S.preview)
        add(viewMenu, BenchMenu.previewInFront, "P",
            #selector(MainWindowController.previewToFront),
            modifiers: [.command, .option, .shift], displayedTitle: S.previewInFront)
        viewMenu.addItem(.separator())
        add(viewMenu, BenchMenu.sessionsAsTabsOrRail, "l",
            #selector(MainWindowController.toggleSessionLayout),
            modifiers: [.command, .option], displayedTitle: S.sessionsAsTabsOrRail)
        add(viewMenu, BenchMenu.nextTheme, "y", #selector(MainWindowController.cycleTheme),
            displayedTitle: S.nextTheme)
        add(viewMenu, BenchMenu.dumpLayout, "0", #selector(MainWindowController.dumpLayout),
            modifiers: [.command, .control], displayedTitle: S.dumpLayout)
        main.addItem(submenu: viewMenu)

        let windowMenu = NSMenu(title: S.windowMenu)
        add(windowMenu, BenchMenu.minimize, "m", #selector(NSWindow.performMiniaturize(_:)),
            displayedTitle: S.minimize)
        add(windowMenu, BenchMenu.zoom, "", #selector(NSWindow.performZoom(_:)),
            displayedTitle: S.zoom)
        windowMenu.addItem(.separator())
        add(windowMenu, BenchMenu.bringAllToFront, "",
            #selector(NSApplication.arrangeInFront(_:)), displayedTitle: S.bringAllToFront)
        main.addItem(submenu: windowMenu)

        NSApp.mainMenu = main
        // AppKit fills this one with the open windows and keeps the tick on
        // the front one; it is the reason the menu is called Window.
        NSApp.windowsMenu = windowMenu
    }

    /// Resolve the value already held by Configuration, publish it once, and
    /// then re-set every open piece of text. Menus are outside every window's
    /// view tree, so they are rebuilt as the second half of the same change.
    private func applyLanguageFromConfig() {
        LanguageStore.shared.value = Lang.resolve(
            setting: config.languageSetting(),
            environment: ProcessInfo.processInfo.environment,
            preferredLanguages: Locale.preferredLanguages
        )
        LanguageUI.reapplyEverywhere()
        buildMenu()
    }

    /// The standard About panel, with the version the app really is.
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppVersion.name,
            .applicationVersion: AppVersion.short,
            .credits: NSAttributedString(
                string: S.aboutCredits,
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ englishTitle: String, _ key: String, _ action: Selector?,
                     modifiers: NSEvent.ModifierFlags = [.command],
                     displayedTitle: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: displayedTitle ?? englishTitle,
                              action: action, keyEquivalent: key)
        // The title is display text; the identifier is the English address
        // spoken by the shell benches. Localizing one must never rename the
        // other, or a missed menu action only leaves an NSLog behind.
        item.identifier = NSUserInterfaceItemIdentifier(englishTitle)
        // An item with no key has no shortcut, and a modifier mask hanging off
        // one is a shortcut of ⌘ alone waiting to be believed.
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = nil
        menu.addItem(item)
        return item
    }

    private func addFind(_ menu: NSMenu, _ title: String, _ key: String,
                         _ action: NSTextFinder.Action,
                         modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title,
                              action: #selector(NSResponder.performTextFinderAction(_:)),
                              keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = action.rawValue
        item.target = nil
        menu.addItem(item)
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        // The item carries the submenu's title too: AppKit shows the item's,
        // and anything reading the menu bar back finds a name instead of an
        // empty string where a menu should be.
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
