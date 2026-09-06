//  TestChannel.swift — a way to drive and read the real app.
//
//  Why it exists: a claim about a terminal has to be measured on the terminal
//  the user opens, not on a headless replica of it. Synthesising key events
//  into the real view and reading state back out of the real session is the
//  difference between proving the app works and proving a copy of it does.
//
//  IT IS NOT IN THE BINARY YOU DOWNLOAD (ISC-128). "Dormant unless an
//  environment variable is set" was the old guard, and it was not one: the
//  verb table below — `text`, `key`, `approve`, `copy`, `cells` — is a remote
//  control for the terminal, and a remote control that ships is a remote
//  control however politely it waits. The whole file compiles only into a
//  debug build, or into one that asked for it by name with `-DT4A_TESTABLE`
//  (the bench bundle, which needs release optimisation AND the door: frame
//  times measured on an unoptimised build are not the product's numbers).
//  `Scripts/build-app.sh release` passes neither, so the shipped executable
//  has no channel, no verb and no variable that opens anything.

import AppKit
import Foundation
import TerminalCore

#if DEBUG || T4A_TESTABLE

@MainActor
final class TestChannel {
    private let controller: MainWindowController
    private var source: DispatchSourceRead?
    private var descriptor: Int32 = -1
    private var pending = Data()

    init?(controller: MainWindowController) {
        guard let path = ProcessInfo.processInfo.environment["T4A_TEST_CHANNEL"]
        else { return nil }
        self.controller = controller
        // The channel opens ONLY a pipe it made itself.
        //
        // The old code created the fifo when the path was free and opened
        // whatever was there when it was not, which is the whole hole: another
        // local user leaves a 0666 fifo at the name a bench is about to use,
        // and the terminal reads their keystrokes and types them into whatever
        // the person here is running. `mkfifo` failing with EEXIST IS the
        // check — asking first and creating after is a race with the attacker.
        guard mkfifo(path, 0o600) == 0 else {
            NSLog("T4A: refusing the test channel at \(path): "
                + String(cString: strerror(errno)))
            return nil
        }
        // O_NOFOLLOW because the name could have become a symlink between the
        // mkfifo and this line, and then `fstat` on the DESCRIPTOR rather than
        // a second look at the path: what was checked and what was opened have
        // to be the same object. The channel belongs to T4A, so a pane must
        // lose it at exec.
        descriptor = open(path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            NSLog("T4A: could not open the test channel at \(path)")
            return nil
        }
        var info = stat()
        let isPrivateFifo = fstat(descriptor, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFIFO
            && info.st_uid == getuid()
            && (info.st_mode & 0o777) == 0o600
        guard isPrivateFifo else {
            NSLog("T4A: \(path) is not a private fifo of ours; channel closed")
            close(descriptor)
            descriptor = -1
            return nil
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                                   queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source
        NSLog("T4A: test channel open at \(path)")
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return }
        pending.append(contentsOf: buffer[0..<count])
        while let index = pending.firstIndex(of: 0x0a) {
            let line = pending[pending.startIndex..<index]
            pending.removeSubrange(pending.startIndex...index)
            let text = String(decoding: line, as: UTF8.self)
            if !text.isEmpty { run(text) }
        }
    }

    private func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "text": controller.testSendText(unescape(rest))
        case "key": controller.testSendKey(rest)
        case "newtab": controller.newTab()
        case "open-pane-cmd": controller.testOpenPaneCommand(base64: rest)
        case "splitv": controller.splitVertically()
        case "splith": controller.splitHorizontally()
        case "closepane": controller.closeCurrent()
        case "selectall": controller.selectAllText()
        case "copy": controller.copySelection()
        case "theme": controller.testSetTheme(rest)
        case "layout": controller.testSetLayout(rest)
        case "resize": controller.testResize(rest)
        case "drag": controller.testDrag(rest)
        case "clickpane": controller.testClickPane(rest)
        case "focus-pane": controller.testFocusPane()
        case "dblclick": controller.testDoubleClick(rest)
        case "delivered": controller.testDelivered(to: rest)
        case "notify-click": controller.testNotifyClick(rest)
        case "endliveresize": controller.testEndLiveResize()
        case "movewindow": controller.testMoveWindow(rest)
        case "fullscreen": controller.testFullScreen(rest)
        case "closepane-ask": controller.testCloseCurrent()
        case "closewindow": controller.testCloseWindow()
        case "selecttab": controller.testSelectTab(Int(rest) ?? 0)
        case "answer": controller.testAnswerClose(rest)
        case "fontsize": controller.setFontSize(Int(rest) ?? 13)
        case "clearbuffer": controller.clearBuffer()
        case "newwindow": NSApp.sendAction(Selector(("newWindow")), to: nil, from: nil)
        case "scrollbench": controller.testScrollBench(rest)
        case "renderstats": controller.testRenderStats(to: rest)
        case "renderreset": controller.testResetRenderStats()
        case "renderer": controller.testSetRenderer(rest)
        case "cursor": controller.testCursor(rest)
        case "scroll": controller.testScroll(rest)
        case "capture": controller.testCapture(rest)
        case "cells": controller.testCells(rest)
        case "find": controller.testFind(rest)
        case "findstep": controller.testFindStep(Int(rest) ?? 1)
        case "findopen": controller.testFindOpen()
        case "findclose": controller.closeFind()
        case "motion": controller.testMotion(rest)
        case "menu": controller.testDumpMenu(to: rest)
        case "fire": controller.testFireMenuItem(rest)
        // Paste fidelity is a product claim, not a responder-chain claim.
        // The channel already runs on the main actor/main queue, so this
        // reaches the exact @objc method behind the menu without requiring
        // the otherwise unrelated bench window to be key.
        case "paste-here": controller.pasteHere()
        case "approve": controller.testApprove(rest)
        case "stalecard": controller.testStaleCard(rest)
        case "compose": controller.testCompose(unescape(rest))
        case "fold": controller.testFold(rest)
        case "foldrows": controller.testFoldRows(rest)
        case "scan": controller.testScanScreen()
        case "facts": controller.testSetFactsProvider(rest)
        case "settings": controller.testSettingsCommand(rest)
        case "toggle": controller.testToggleSwitch(rest)
        case "choice": controller.testPressChoice(rest)
        case "composer-mode": controller.testSetComposerMode(rest)
        case "slash-catalog": controller.testSlashCatalog(rest)
        case "composer-paste": controller.testComposerPaste()
        case "bracketed-paste": controller.testBracketedPaste(unescape(rest))
        case "clipboard-file": controller.testClipboardFile(unescape(rest))
        case "clipboard-png": controller.testClipboardPNG(rest)
        case "clipboard-text64": controller.testClipboardText(base64: rest)
        case "drop-file": controller.testDropFile(unescape(rest))
        case "shot": controller.testShot(to: rest)
        case "press-switch": controller.testPressSettingsSwitch(unescape(rest))
        case "press-toggle": controller.testPressBandToggle(unescape(rest))
        case "tab-press": controller.testTabPress(rest)
        case "tab-hover": controller.testTabHover(rest)
        case "waiting-press": controller.testWaitingPress()
        case "waiting-choose": controller.testWaitingChoose(Int(rest) ?? 0)
        case "waiting-dismiss": controller.testWaitingDismiss()
        case "reduce-motion": controller.testReduceMotion(rest)
        case "composer-send": controller.testComposerSend()
        case "preview-open": controller.testPreviewOpen(rest)
        case "preview-path": controller.testPreviewPath(rest)
        case "preview-close": controller.closePreview()
        case "preview-collapse": controller.testPreviewCollapse(true)
        case "preview-expand": controller.testPreviewCollapse(false)
        case "preview-front": controller.previewToFront()
        case "preview-panel": controller.previewToPanel()
        case "turn-open": controller.testOpenTurn(Int(rest) ?? 0)
        case "turn-close": controller.closeTurnReader()
        case "chat-page": controller.testSetChatPage(rest)
        case "pure-chat": controller.testSetPureChat(rest)
        case "palette": controller.testPalette(rest)
        // An app can bring ITSELF to the front; on macOS 14 another process
        // asking on its behalf is refused. A real keystroke goes to whoever
        // holds the keyboard, so the bench asks the app first and only then
        // presses (ISC-32).
        case "activate": NSApp.activate(ignoringOtherApps: true)
        case "hittest": controller.testHitTest(rest)
        case "typekey": controller.testTypeThroughResponder(unescape(rest))
        case "dump": controller.testDump(to: rest)
        default: NSLog("T4A: unknown test verb \(verb)")
        }
    }

    /// `\n` and `\t` in a command line mean the characters, not the letters.
    private func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\e", with: "\u{1b}")
    }
}

extension MainWindowController {
    func testTerminalLinkHoverState() -> [String: Any]? {
        guard let (hover, surface) = testActiveLinkHover() else { return nil }
        let rectangles = hover.rects.map { local -> [String: Double] in
            let inWindow = surface.convert(local, to: nil)
            let screen = surface.window?.convertToScreen(inWindow) ?? inWindow
            return ["x": Double(screen.midX), "y": Double(screen.midY),
                    "w": Double(screen.width), "h": Double(screen.height)]
        }
        guard let first = hover.rects.first else { return nil }
        let union = hover.rects.dropFirst().reduce(first) { $0.union($1) }
        let inWindow = surface.convert(union, to: nil)
        let screen = surface.window?.convertToScreen(inWindow) ?? inWindow
        return [
            "text": hover.link.text,
            "path": hover.link.target,
            "type": hover.link.kind.rawValue,
            "rect": ["x": Double(screen.midX), "y": Double(screen.midY),
                     "w": Double(screen.width), "h": Double(screen.height)],
            "rects": rectangles,
            "span": ["startRow": hover.span.start.row,
                     "startColumn": hover.span.start.column,
                     "endRow": hover.span.end.row,
                     "endColumn": hover.span.end.column],
        ]
    }

    func testLinkOpenState() -> [String: String]? { testLinkOpenRecord }

    func testLinkCursorTraceState() -> [String: Any]? {
        guard let trace = testActiveLinkCursorTrace() else { return nil }
        var result: [String: Any] = [
            "pushes": trace.pushes,
            "pops": trace.pops,
            "pointingHandSets": trace.pointingHandSets,
            "cursorUpdatesConsumed": trace.cursorUpdatesConsumed,
        ]
        if let last = trace.lastTransition {
            result["lastTransition"] = [
                "kind": last.kind,
                "timestamp": last.timestamp,
            ]
        }
        return result
    }

    /// Types into the pane the keyboard is on, through the same key path a
    /// person's keystroke takes — not a shortcut into the pty.
    func testSendText(_ text: String) {
        guard let view = testActiveSurface() else { return }
        sendSyntheticText(text, to: view)
    }

    func testFocusPane() {
        guard let surface = testActiveSurface() else { return }
        window?.makeFirstResponder(surface)
    }

    func testSendKey(_ spec: String) {
        guard let view = testActiveSurface() else { return }
        sendSyntheticKey(spec, to: view)
    }

    /// The theme verb goes through the same door the settings and the palette
    /// use, so what the bench exercises is what a person exercises. A name
    /// nobody can resolve is not filtered out here: the app's own fallback is
    /// exactly what the negative pole is looking at.
    func testSetTheme(_ name: String) { setTheme(name) }

    func testSetLayout(_ name: String) {
        guard name == "rail" || name == "tabs" else { return }
        if testLayoutName() != name { toggleSessionLayout() }
    }

    /// The whole observable state of the app, as JSON. Anything a claim needs
    /// to assert is read from the live objects here, never re-derived by the
    /// test on the side.
    func testDump(to path: String) {
        var root: [String: Any] = [:]
        root["theme"] = Theme.current.name
        root["layout"] = testLayoutName()
        root["waiting"] = testWaitingCount()
        root["configPath"] = testConfigPath()
        root["tabs"] = testTabsDump()
        root["clipboard"] = NSPasteboard.general.string(forType: .string) ?? ""
        root["clipboardTypes"] = NSPasteboard.general.types?.map(\.rawValue) ?? []
        root["clipboardChangeCount"] = NSPasteboard.general.changeCount
        root["notifications"] = testNotificationLog()
        root["configWrites"] = testConfigWrites()
        root["fontSize"] = testFontSize()
        root["window"] = testWindowState()
        root["foreground"] = testForeignPrograms()
        root["presentations"] = Notifier.shared.presentationLog
        root["appActive"] = NSApp.isActive
        root["windows"] = NSApp.windows.filter { $0.contentView != nil && $0.isVisible }.count
        root["termProgramVersion"] = AppVersion.short
        root["band"] = testBandMetrics()
        root["fullScreenLayout"] = testFullScreenLayout()
        root["waitingMenu"] = testWaitingMenuState()
        root["rail"] = testRailState()
        root["panels"] = testPanelMetrics()
        root["panelWidths"] = testPanelWidths()
        root["dash"] = testDashState()
        root["composer"] = testComposerState()
        root["pureChat"] = testPureChatState()
        root["settings"] = testSettingsState()
        root["palette"] = testPaletteState()
        root["hitTest"] = lastHitTest
        root["themeState"] = testThemeState()
        root["firstResponder"] = window?.firstResponder
            .map { String(describing: type(of: $0)) } ?? "none"
        // The rows as the SCANNER sees them, through `text(at:)`, beside the
        // rows the rest of the dump shows through `line(at:)`. Two readers of
        // the same buffer that disagree is exactly the kind of thing a dump
        // has to be able to show.
        if let grid = testActiveGrid() {
            root["scannerText"] = (0..<min(grid.endRow, 30)).map {
                (grid.text(at: $0) ?? "").unicodeScalars.map { String(format: "%04X", $0.value) }
                    .prefix(12).joined(separator: " ")
            }
        }
        root["agents"] = testAgentDump()
        root["card"] = testCardState()
        root["selector"] = testSelectorState()
        root["foldTargets"] = testFoldTargets()
        root["inspectorMode"] = testInspectorMode()
        root["composerTarget"] = testComposerTarget()
        root["turnReader"] = testTurnReaderState()
        root["preview"] = testPreviewState()
        root["chatPage"] = testChatPageState()
        root["queued"] = testQueuedState()
        root["find"] = testFindState()
        if let hover = testTerminalLinkHoverState() { root["linkHover"] = hover }
        if let trace = testLinkCursorTraceState() { root["cursorTrace"] = trace }
        if let opened = testLinkOpenState() { root["linkOpen"] = opened }
        root["windowTitles"] = NSApp.windows.filter(\.isVisible).map {
            "\(type(of: $0)): \($0.title)"
        }
        // The class names of whatever the engine has put over the terminal.
        // Reflection, not an import: the app still cannot name a VT library,
        // and a find bar that appeared is a fact about the view tree.
        root["surfaceOverlays"] = (testActiveSurface()?.subviews ?? []).map {
            "\(type(of: $0))\($0.isHidden ? " (hidden)" : "")"
        }
        // No default path. `/tmp/t4a-dump.json` was one, and a predictable
        // name in a world-writable directory is where a dump of the whole
        // observable state — clipboard included — should never land on its
        // own. The caller names the file or there is no file (ISC-128).
        guard !path.isEmpty else {
            NSLog("T4A: dump needs a path; refusing to pick a predictable one")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

#endif
