//  Configuration.swift — one readable text file, and nothing to fill in on
//  day one.
//
//  Two rules carry the whole design. Every setting has a working default, so
//  a first launch with no file at all is a complete terminal (ISC-3). And the
//  file is the only place settings live, so a change made in the window is
//  visible in the file a moment later, in text a person can read (ISC-4).

import Foundation

public struct ConfigKey: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }

    public static let theme = ConfigKey("theme")
    /// `system`, the default, follows the language exported by the launching
    /// environment and then macOS. `en` and `it` pin one language instead;
    /// anything else is unreadable and follows the default rather than
    /// becoming an accidental third choice.
    public static let language = ConfigKey("language")
    public static let fontFamily = ConfigKey("font-family")
    public static let fontSize = ConfigKey("font-size")
    public static let scrollbackLines = ConfigKey("scrollback-lines")
    public static let shellIntegration = ConfigKey("shell-integration")
    public static let notifications = ConfigKey("notifications")
    public static let layoutSessions = ConfigKey("layout-sessions")
    public static let showSessionsPanel = ConfigKey("show-sessions-panel")
    public static let showTurnMap = ConfigKey("show-turn-map")
    public static let showDashboard = ConfigKey("show-dashboard")
    public static let windowWidth = ConfigKey("window-width")
    public static let windowHeight = ConfigKey("window-height")
    /// Size AND position, in AppKit's own saved-frame form. It supersedes the
    /// two sizes above, which stay as the first-launch default for a machine
    /// that has never placed the window (ISC-109).
    public static let windowFrame = ConfigKey("window-frame")
    public static let commandBlocks = ConfigKey("command-blocks")
    /// `gpu` or `cpu`. The fallback is not a debug switch: it is the promise
    /// that the GPU renderer is an addition and never a dependency (ISC-24).
    public static let renderer = ConfigKey("renderer")
    public static let cursorStyle = ConfigKey("cursor-style")
    public static let cursorMotion = ConfigKey("cursor-motion")
    /// The one switch. `motion = false` and nothing in the window animates,
    /// whatever the styles above say.
    public static let motion = ConfigKey("motion")
    /// The agent adapter. Off and T4A is the terminal it was before F4:
    /// no transcript is opened, no directory is watched, no card can appear
    /// (ISC-30).
    public static let agentAdapter = ConfigKey("agent-adapter")
    /// The compact view of a turn: its work folded, its question and answer
    /// left standing (ISC-94).
    public static let compactTurns = ConfigKey("compact-turns")
    /// The line at the bottom that types into the selected session (ISC-42).
    public static let showComposer = ConfigKey("show-composer")
    /// When the composer is allowed on screen (ISC-113): `always`, the
    /// default, keeps the bubble there even inside `claude`; `contextual`
    /// hides it while the front program has an input line of its own
    /// (the ISC-112 behaviour, now a choice); `never` puts it away for good.
    public static let composerMode = ConfigKey("composer-mode")
    /// With ONE tab, the strip is a row that says nothing: `hide` keeps it
    /// away until a second tab exists, iTerm's way; `show`, the default,
    /// keeps it always (his ask, 25/08).
    public static let tabsWhenSingle = ConfigKey("tabs-when-single")
    /// «Pure chat», EXPERIMENTAL and off (ISC-114): with it on, T4A puts its
    /// own bubble over the input box the hosted program drew, so one text
    /// field is left on screen. A key of its own rather than a fourth
    /// `composer-mode`, because the two answer different questions — where
    /// MY line is, and whether I also cover THEIRS — and one switch that
    /// answered both would make `never` plus a cover representable, which is
    /// a terminal with no input line at all.
    public static let pureChat = ConfigKey("pure-chat")
    /// La conversazione disegnata da T4A dentro il pannello, al posto della
    /// schermata dell'agente (ISC-169).
    public static let chatPage = ConfigKey("chat-page")
    /// Selezionare del testo lo copia negli appunti, come fa iTerm (ISC-197).
    ///
    /// Un interruttore e non un comportamento fisso, perché il costo è reale
    /// nella direzione opposta: chi seleziona una riga solo per rileggerla si
    /// ritrova gli appunti sovrascritti senza averlo chiesto. Acceso di
    /// default perché è il gesto che lui ha chiesto (27/08) ed è quello che
    /// ogni terminale con cui lavora fa già.
    public static let copyOnSelect = ConfigKey("copy-on-select")
    /// The bar's order, as `left-1:a,b|left-2:c|right-1:d` (ISC-104.2).
    public static let dashSlots = ConfigKey("dash-slots")
    /// The bar's switched-off rows, comma separated (ISC-104.3).
    public static let dashOff = ConfigKey("dash-off")
    /// Where the settings window sits, as `dx dy width height` — the offset of
    /// its centre from the centre of the window that opened it, not a place on
    /// a screen (ISC-155).
    ///
    /// An offset and not a frame, because the two halves of the claim pull
    /// opposite ways: it has to open ON the window a person was working in,
    /// wherever that window is today, and it has to come back where they put
    /// it. A saved absolute position satisfies the second and breaks the
    /// first the moment the main window moves; an offset satisfies both, and
    /// is zero — dead centre — until somebody drags it.
    public static let settingsOffset = ConfigKey("settings-offset")
    /// Panel widths, chosen by dragging the seam and kept (ISC-104.4).
    public static let railWidth = ConfigKey("rail-width")
    public static let inspectorWidth = ConfigKey("inspector-width")
    /// Quanto è larga la colonna di destra QUANDO ci sta un'anteprima
    /// (ISC-176). Una seconda larghezza e non un riuso della prima: aprire un
    /// file vuole metà finestra, la mappa dei turni ne vuole trecento punti,
    /// e una sola chiave costringerebbe a riscegliere ogni volta.
    ///
    /// VUOTA finché nessuno ha trascinato la cucitura, e allora vale metà
    /// finestra. Stessa disciplina di `window-framè e `settings-offset`: un
    /// numero di default sarebbe una scelta fatta da noi al posto suo, e uno
    /// zero che significa «automatico» sarebbe un ramo nascosto dentro un
    /// intero.
    public static let previewWidth = ConfigKey("preview-width")

    /// A program of the user's own whose standard output becomes rows of the
    /// bar (ISC-139). EMPTY by default, and that is the whole safety of it:
    /// T4A runs nothing it was not pointed at, so a fresh install spawns no
    /// process and the bar is exactly the bar it was.
    public static let factsProvider = ConfigKey("facts-provider")
    /// How often it is asked, in seconds.
    public static let factsInterval = ConfigKey("facts-interval")

    /// Empty means the login shell, which is what almost everyone wants.
    /// Naming one is how you run T4A on a shell that is not your own.
    public static let shell = ConfigKey("shell")
}

public final class Configuration {
    public static let defaults: [String: String] = [
        ConfigKey.theme.name: "black",
        ConfigKey.language.name: "system",
        ConfigKey.fontFamily.name: "SF Mono",
        ConfigKey.fontSize.name: "13",
        ConfigKey.scrollbackLines.name: "10000",
        ConfigKey.shellIntegration.name: "true",
        ConfigKey.notifications.name: "true",
        ConfigKey.layoutSessions.name: "rail",
        ConfigKey.showSessionsPanel.name: "true",
        ConfigKey.showTurnMap.name: "true",
        ConfigKey.showDashboard.name: "true",
        ConfigKey.windowWidth.name: "1512",
        ConfigKey.windowHeight.name: "950",
        ConfigKey.commandBlocks.name: "true",
        ConfigKey.windowFrame.name: "",
        ConfigKey.renderer.name: "gpu",
        ConfigKey.cursorStyle.name: "block",
        ConfigKey.cursorMotion.name: "glide",
        ConfigKey.motion.name: "true",
        ConfigKey.shell.name: "",
        ConfigKey.agentAdapter.name: "true",
        ConfigKey.compactTurns.name: "false",
        ConfigKey.showComposer.name: "true",
        // `never` since 2026-09-06, his decision for the release («togliamo
        // la bolla … adesso utilizziamo solamente l'impalcatura originale dei
        // vari agent per l'inserimento del testo», 28/08 on his own config,
        // 6/09 for everyone): the agent's own input line is the input. The
        // bubble stays a choice (`agent`, `always`), not the default.
        ConfigKey.composerMode.name: "never",
        ConfigKey.tabsWhenSingle.name: "show",
        // ON since 2026-08-23 (ISC-150). It shipped off because ISC-114 called
        // it an experiment, and an experiment earns its default by surviving
        // the case it could do harm in. Three shapes of menu now uncover it on
        // the live agent — a completion list, a settings selector, and a REAL
        // permission — measured at 32.9 ms, 31.9 ms and immediately, against a
        // ceiling of 200. The third is the one that mattered: covering a
        // question put to a person is the only way this feature could hurt,
        // and two shapes were not three.
        // OFF since 2026-09-06, same decision as the composer above: the
        // terminal grid is the page, and the chat page («lo schermo nero»)
        // is an option a person turns on, never what a new install shows.
        ConfigKey.pureChat.name: "false",
        ConfigKey.chatPage.name: "false",
        ConfigKey.copyOnSelect.name: "true",
        ConfigKey.dashSlots.name: "",
        ConfigKey.dashOff.name: "",
        ConfigKey.settingsOffset.name: "",
        ConfigKey.railWidth.name: "232",
        ConfigKey.inspectorWidth.name: "300",
        ConfigKey.previewWidth.name: "",
        ConfigKey.factsProvider.name: "",
        ConfigKey.factsInterval.name: "2",
    ]

    public let url: URL
    private var values: [String: String] = [:]
    /// Lines of the file we did not write, kept so a hand-edited comment
    /// survives a write from the window.
    private var preamble: [String] = []
    public var onChange: ((ConfigKey) -> Void)?

    /// How many times this file has been written since launch.
    ///
    /// It exists because "the configuration is not rewritten while you drag
    /// the window" is a claim about disk writes, and a claim about writes is
    /// counted at the write, not sampled from outside and hoped to be
    /// complete (ISC-106).
    public private(set) var writeCount = 0

    public static func defaultURL() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("t4a/config.toml")
    }

    public init(url: URL = Configuration.defaultURL()) {
        self.url = url
        reload()
    }

    /// True when the file does not exist. A first launch is expected to be
    /// exactly this, and must still produce a whole terminal.
    public var isUnconfigured: Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }

    public func reload() {
        values.removeAll()
        preamble.removeAll()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { preamble.append(trimmed); continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
    }

    public func string(_ key: ConfigKey) -> String {
        values[key.name] ?? Configuration.defaults[key.name] ?? ""
    }

    /// The three spellings accepted for `language`, or its documented
    /// default. Like `bool`, this says when a hand-edited value cannot be
    /// understood: silently following the system after a typo looks exactly
    /// like the settings window ignored the user.
    public func languageSetting() -> String {
        let raw = string(.language).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["system", "en", "it"].contains(raw) { return raw }
        let fallback = Lang.normalizedSetting(Configuration.defaults[ConfigKey.language.name]
                                              ?? "system")
        note("language = \(raw.isEmpty ? "(empty)" : raw) is not system, en, or it; "
            + "using the default, \(fallback)")
        return fallback
    }

    public func int(_ key: ConfigKey) -> Int {
        Int(string(key)) ?? Int(Configuration.defaults[key.name] ?? "") ?? 0
    }

    /// The words that mean yes and no in a configuration file, in the forms a
    /// person actually writes them.
    private static let yesWords: Set<String> = ["true", "yes", "1", "on"]
    private static let noWords: Set<String> = ["false", "no", "0", "off"]

    /// A switch, and a value nobody can read falls back to the KEY'S default
    /// rather than to `false` (ISC-134).
    ///
    /// `agent-adapter = tru` used to turn the adapter off. Every reading of
    /// that line is wrong except the one the code took: it is not the user
    /// asking for the feature to be off, it is a typo, and the honest answer
    /// to a typo is the behaviour they would have had without the line at all.
    /// Silently choosing `false` also picks the direction that removes a
    /// feature, which is the reading a person is least likely to notice and
    /// most likely to blame on the app.
    public func bool(_ key: ConfigKey) -> Bool {
        let raw = string(key).lowercased()
        if Configuration.yesWords.contains(raw) { return true }
        if Configuration.noWords.contains(raw) { return false }
        let fallback = (Configuration.defaults[key.name] ?? "false").lowercased()
        note("\(key.name) = \(raw.isEmpty ? "(empty)" : raw) is not yes or no; "
            + "using the default, \(fallback)")
        return Configuration.yesWords.contains(fallback)
    }

    /// A number between two bounds, or the key's default. Same rule as
    /// `bool`, and it exists because NaN and −1 both pass `Double(_:)`.
    public func fraction(_ key: ConfigKey, in range: ClosedRange<Double>) -> Double {
        let fallback = Double(Configuration.defaults[key.name] ?? "") ?? range.lowerBound
        guard let value = Double(string(key)) else {
            note("\(key.name) is not a number; using the default, \(fallback)")
            return fallback
        }
        guard value.isFinite, range.contains(value) else {
            note("\(key.name) = \(value) is outside \(range.lowerBound)…\(range.upperBound); "
                + "using the default, \(fallback)")
            return fallback
        }
        return value
    }

    /// Every line this file could not make sense of, once each.
    ///
    /// A fallback that happens in silence is indistinguishable from the app
    /// ignoring you: the settings window reads this, and so does the dump a
    /// bench looks at.
    public private(set) var problems: [String] = []

    private func note(_ message: String) {
        guard !problems.contains(message) else { return }
        problems.append(message)
        NSLog("T4A config: \(message)")
    }

    public func set(_ key: ConfigKey, _ value: String) {
        guard values[key.name] != value else { return }
        values[key.name] = value
        write()
        onChange?(key)
    }

    public func set(_ key: ConfigKey, _ value: Bool) { set(key, value ? "true" : "false") }
    public func set(_ key: ConfigKey, _ value: Int) { set(key, String(value)) }

    /// The file as it stands on disk, for the read-back check.
    public func rawText() -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private func write() {
        var lines = preamble.isEmpty ? [
            "# T4A configuration. Delete this file and everything returns to",
            "# its default: the terminal works with no configuration at all.",
        ] : preamble
        lines.append("")
        for key in values.keys.sorted() {
            let value = values[key] ?? ""
            let needsQuotes = value.isEmpty || value.contains(" ")
            lines.append("\(key) = \(needsQuotes ? "\"\(value)\"" : value)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        writeCount += 1
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic: a crash mid-write must never leave a half file that the
            // next launch reads as "everything is default".
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("T4A: could not write \(url.path): \(error.localizedDescription)")
        }
    }
}
