//  Theme.swift — the palette the principal ratified over thirteen rounds of
//  the browser demo, and the three that were added beside it.
//
//  Numbers for `black` and `warm` come from demo/styles.css; the contrast
//  ratios beside them were measured on the rendered page, not estimated. The
//  two added on 22/08 were measured the same way before they were written
//  down (Scripts/bench-f5.sh prints the ratios back).
//
//  A theme reaches the WHOLE window — the chrome and the terminal grid both.
//  The grid's ground, ink, cursor and selection are the theme's; the sixteen
//  ANSI colours stay the engine's xterm cube unless a theme names its own,
//  which only a light theme needs to do (`ESC[97m`, bright white, is
//  invisible on paper).

import AppKit
import TerminalCore

enum Theme {
    struct Palette {
        let name: String
        /// What a person sees in the settings and the palette. The key stays
        /// the short name, so `config.toml` keeps reading like a config file.
        let title: String
        let ground: NSColor        // the page
        let pane: NSColor
        let panel: NSColor         // panels sit one step above the page
        let panelEdge: NSColor
        let raised: NSColor
        let hairline: NSColor
        let hairlineSoft: NSColor
        let ink: NSColor
        let muted: NSColor
        let whisper: NSColor
        /// The family blue, used as a FILL: 3.02:1 on black alone, 6.96:1
        /// against the white that sits on it.
        let accent: NSColor
        /// The same hue and saturation lightened until it clears 4.5:1 on
        /// both grounds (5.20:1 on #000, 4.64:1 on #121212). Every mark drawn
        /// as text or a hairline uses this one.
        let accentText: NSColor
        let accentDim: NSColor
        let failed: NSColor
        let failedSoft: NSColor
        /// What a selection in the terminal grid is filled with. It is not
        /// `accent`, because on a light ground a dark blue fill under dark
        /// ink is unreadable, and the selection is the one colour the user
        /// puts text on without being asked.
        let selection: NSColor
        /// A light theme needs the system controls (text fields, the caret in
        /// them, the scroller) to know they are on a light ground.
        var isLight: Bool = false
        /// The sixteen base colours, when the theme insists. `nil` is the
        /// engine's own, which is what every dark theme wants.
        var ansi: [NSColor]? = nil
    }

    static let black = Palette(
        name: "black", title: "full black",
        ground: .hex(0x000000), pane: .hex(0x060606),
        panel: .hex(0x0E0E0E), panelEdge: .hex(0x232323),
        raised: .hex(0x121212),
        hairline: .hex(0x242424), hairlineSoft: .hex(0x1A1A1A),
        ink: .hex(0xEDECEC), muted: .hex(0x8F8F8F), whisper: .hex(0x5E5E5E),
        accent: .hex(0x2F5C8A), accentText: .hex(0x4582BF),
        accentDim: NSColor(srgbRed: 69/255, green: 130/255, blue: 191/255, alpha: 0.16),
        failed: .hex(0xD4574A), failedSoft: .hex(0xA8635B),
        selection: .hex(0x2F5C8A))

    /// The warm dark measured on cursor.com, 2026-08-19. Ink and accent do
    /// not move between themes: only the ground does.
    static let warm = Palette(
        name: "warm", title: "warm dark",
        ground: .hex(0x14120B), pane: .hex(0x1A1710),
        panel: .hex(0x1D1A12), panelEdge: .hex(0x2B2719),
        raised: .hex(0x221E15),
        hairline: .hex(0x2B2719), hairlineSoft: .hex(0x221F15),
        ink: .hex(0xEDECEC), muted: .hex(0x918B7C), whisper: .hex(0x625D51),
        accent: .hex(0x2F5C8A), accentText: .hex(0x4582BF),
        accentDim: NSColor(srgbRed: 69/255, green: 130/255, blue: 191/255, alpha: 0.16),
        failed: .hex(0xD4574A), failedSoft: .hex(0xA8635B),
        selection: .hex(0x2F5C8A))

    /// The T3.chat side of the reference: the same structure, a violet ground
    /// and a violet accent. This is the one theme where the accent moves, and
    /// it moves on purpose — a theme whose accent is somebody else's blue is
    /// a background change wearing a theme's name. Measured on the ground:
    /// ink 16.29:1, accentText 6.88:1, white on the accent fill 7.99:1.
    static let violet = Palette(
        name: "violet", title: "violet dark",
        ground: .hex(0x0E0B14), pane: .hex(0x130F1B),
        panel: .hex(0x191322), panelEdge: .hex(0x2A2135),
        raised: .hex(0x1D1729),
        hairline: .hex(0x2A2135), hairlineSoft: .hex(0x211A2D),
        ink: .hex(0xEDE9F2), muted: .hex(0x948CA3), whisper: .hex(0x635C70),
        accent: .hex(0x5B3E9E), accentText: .hex(0xA78BE0),
        accentDim: NSColor(srgbRed: 167/255, green: 139/255, blue: 224/255, alpha: 0.16),
        failed: .hex(0xE0736A), failedSoft: .hex(0xB0655F),
        selection: .hex(0x5B3E9E))

    /// The light one, and the reason `ansi` exists.
    ///
    /// Every role is inverted rather than lightened: the ground is a bright
    /// off-white, the panels are one step LIGHTER than it (raised means
    /// raised, whichever way the light comes from), and the sixteen ANSI
    /// colours are darkened so a program that prints bright white is still
    /// readable. Measured on the ground: ink 15.28:1, accentText 7.30:1, and
    /// the worst of the sixteen is bright black at 2.79:1, which is the dim
    /// grey it is meant to be — the other fifteen all clear 4:1.
    ///
    /// It was called `paper` until 22/08 and is called `light` now, because
    /// «il bianco è troppo bianco»: what it is, is the light theme, and the
    /// name paper belongs to the one below that actually looks like paper.
    static let light = Palette(
        name: "light", title: "light",
        ground: .hex(0xF2F0EC), pane: .hex(0xF7F6F3),
        panel: .hex(0xFBFAF8), panelEdge: .hex(0xDCD8D0),
        raised: .hex(0xFFFFFF),
        hairline: .hex(0xDCD8D0), hairlineSoft: .hex(0xE7E3DC),
        ink: .hex(0x1B1A18), muted: .hex(0x6B6862), whisper: .hex(0x94908A),
        accent: .hex(0x2F5C8A), accentText: .hex(0x205081),
        accentDim: NSColor(srgbRed: 32/255, green: 80/255, blue: 129/255, alpha: 0.12),
        failed: .hex(0xB03A2E), failedSoft: .hex(0x8E4C43),
        selection: .hex(0xC9DCF0),
        isLight: true,
        ansi: [
            .hex(0x1B1A18), .hex(0xB03A2E), .hex(0x3F6E22), .hex(0x7A5C0E),
            .hex(0x205081), .hex(0x8A3A80), .hex(0x1B6468), .hex(0x6B6862),
            .hex(0x94908A), .hex(0xC4483A), .hex(0x4E8129), .hex(0x8F6C12),
            .hex(0x2A63A0), .hex(0xA4479A), .hex(0x22757A), .hex(0x1B1A18),
        ])

    /// Warm paper, added 22/08 (ISC-125). His words: «il bianco è troppo
    /// bianco… un tema in più» — so this is an ADDITION and not a correction,
    /// and `light` above stays exactly as it was.
    ///
    /// The ground is the measured reference of his taste from DESIGN_TASTE
    /// § app-02, and nothing in the theme is pure white: the depth between
    /// the page, the terminal, the rail and the bubble is four tones of the
    /// SAME paper, each a step lighter than the last, so the light comes from
    /// above without anything having to glow. There is one accent, the family
    /// blue, darkened until it carries on paper.
    ///
    /// Measured on the ground, with Scripts/contrast (the ratios are computed,
    /// not estimated): ink 12.59:1, accentText 6.23:1, muted 4.76:1, white on
    /// the accent fill 6.96:1. Of the sixteen, fifteen clear 4:1 — the worst
    /// is bright yellow at 4.13:1 — and the sixteenth is bright black at
    /// 2.55:1, DECLARED: it is the dim grey a program asks for when it wants
    /// something to recede, and lifting it to 4:1 would be answering a
    /// different question than the one the escape code asked.
    static let paper = Palette(
        name: "paper", title: "warm paper",
        ground: .hex(0xDBD8D3), pane: .hex(0xE0DDD8),
        panel: .hex(0xE5E2DD), panelEdge: .hex(0xC3BFB7),
        raised: .hex(0xEAE7E2),
        hairline: .hex(0xC3BFB7), hairlineSoft: .hex(0xCFCBC4),
        ink: .hex(0x181717), muted: .hex(0x5E5B55), whisper: .hex(0x8A867F),
        accent: .hex(0x2F5C8A), accentText: .hex(0x1E4C7A),
        accentDim: NSColor(srgbRed: 30/255, green: 76/255, blue: 122/255, alpha: 0.12),
        failed: .hex(0xA8352A), failedSoft: .hex(0x8A4A42),
        selection: .hex(0xBFD2E4),
        isLight: true,
        ansi: [
            .hex(0x181717), .hex(0xA8352A), .hex(0x3A6420), .hex(0x715408),
            .hex(0x1E4C7A), .hex(0x7E3475), .hex(0x185B5F), .hex(0x5E5B55),
            .hex(0x8A867F), .hex(0xB23C2E), .hex(0x41701F), .hex(0x7D5B0C),
            .hex(0x275C96), .hex(0x963F8C), .hex(0x1D6B70), .hex(0x181717),
        ])

    static let all: [Palette] = [black, warm, violet, light, paper]

    static func palette(named name: String) -> Palette {
        all.first { $0.name == name } ?? black
    }

    /// The live palette. Every draw happens on the main thread, and so
    /// does every theme change, so the isolation is the truth rather than a
    /// lock bolted on.
    @MainActor private(set) static var current: Palette = black

    /// Why the last theme change did not give you the theme you asked for,
    /// or nil when it did. It is a stored fact and not a log line because a
    /// person has to be told: a theme that silently is not the one you named
    /// looks like the app ignoring you.
    @MainActor private(set) static var problem: String?

    @MainActor static func use(_ name: String) {
        current = palette(named: name)
        problem = nil
    }

    // MARK: - A theme of your own, from a file

    /// Where a user theme lives: `themes/<name>.toml` beside `config.toml`.
    ///
    /// There is no `theme-file` key, because a second key would let the two
    /// disagree. `theme` names a built-in OR a file, resolved in that order,
    /// so dropping `themes/mine.toml` next to the configuration and writing
    /// `theme = "mine"` is the whole of it.
    static func themesDirectory(besides config: URL) -> URL {
        config.deletingLastPathComponent().appendingPathComponent("themes")
    }

    static func userThemeNames(in directory: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".toml") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    /// Resolves a name to a palette, and says what went wrong when it cannot.
    ///
    /// A user theme that is missing a key or carries a colour nobody can read
    /// falls back to the default — never to a half-built palette, which would
    /// be a window with two themes in it.
    static func resolve(_ name: String, themes directory: URL) -> (Palette, String?) {
        if let built = all.first(where: { $0.name == name }) { return (built, nil) }
        let file = directory.appendingPathComponent("\(name).toml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return (black, "no theme called “\(name)”: neither built in nor "
                + "\(file.lastPathComponent) in \(directory.path)")
        }
        do {
            return (try parse(text, name: name), nil)
        } catch let error as ThemeError {
            return (black, "\(name).toml: \(error.message)")
        } catch {
            return (black, "\(name).toml: \(error.localizedDescription)")
        }
    }

    struct ThemeError: Error { let message: String }

    private static func parse(_ text: String, name: String) throws -> Palette {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }

        func colour(_ key: String) throws -> NSColor {
            guard let raw = values[key] else {
                throw ThemeError(message: "no “\(key)”. A theme file needs all "
                    + "fifteen colours; copy one of the built-in themes to start from.")
            }
            guard let parsed = NSColor.hex(string: raw) else {
                throw ThemeError(message: "“\(key) = \(raw)” is not a colour "
                    + "(it should read like #1B1A18).")
            }
            return parsed
        }

        var ansi: [NSColor]? = nil
        if values.keys.contains(where: { $0.hasPrefix("ansi-") }) {
            var colours: [NSColor] = []
            for index in 0..<16 { colours.append(try colour("ansi-\(index)")) }
            ansi = colours
        }
        // A fraction, and it has to BE one (ISC-134). `Double(_:)` happily
        // returns nan for "nan" and -1 for "-1", and NSColor takes either
        // without complaint: the first paints nothing at all and the second is
        // undefined. A theme file that asks for one falls back to the default
        // and says so, the same way a colour that is not a colour does — a
        // silent return to the default reads as the app ignoring you.
        let alpha: Double
        let rawAlpha = values["accent-dim-alpha"]
        if let rawAlpha, let parsed = Double(rawAlpha), parsed.isFinite, (0...1).contains(parsed) {
            alpha = parsed
        } else {
            if let rawAlpha {
                throw ThemeError(message: "“accent-dim-alpha = \(rawAlpha)” is not a "
                    + "fraction between 0 and 1.")
            }
            alpha = 0.16
        }
        let accent = try colour("accent-text")
        return Palette(
            name: name, title: values["title"] ?? name,
            ground: try colour("ground"), pane: try colour("pane"),
            panel: try colour("panel"), panelEdge: try colour("panel-edge"),
            raised: try colour("raised"),
            hairline: try colour("hairline"), hairlineSoft: try colour("hairline-soft"),
            ink: try colour("ink"), muted: try colour("muted"),
            whisper: try colour("whisper"),
            accent: try colour("accent"), accentText: accent,
            accentDim: accent.withAlphaComponent(CGFloat(alpha)),
            failed: try colour("failed"), failedSoft: try colour("failed-soft"),
            selection: try colour("selection"),
            isLight: (values["light"] ?? "false") == "true",
            ansi: ansi)
    }

    /// Puts a resolved palette in force, problem and all.
    @MainActor static func use(resolved: (Palette, String?)) {
        current = resolved.0
        problem = resolved.1
        if let message = resolved.1 { NSLog("T4A: %@", message) }
    }

    // MARK: - Metrics, from design/MISURE.md and the ratified demo.

    enum Metric {
        /// The band is taller than the demo's 56 on purpose.
        ///
        /// In a browser the demo's band has the browser's own chrome above it;
        /// in the app the window's top edge IS the top of the band, and the
        /// traffic lights live inside it. Drawn at 56 the count and the title
        /// sat level with those buttons, hard against the edge of the screen —
        /// the thing the collaudo of 20/08 called out (ISC-105). The extra
        /// height is not decoration: `bandTopInset` is the strip the titlebar
        /// occupies, and the line is centred in what is left.
        static let bandHeight: CGFloat = 78
        static let bandTopInset: CGFloat = 26
        static let dashHeight: CGFloat = 66
        static let railWidth: CGFloat = 232
        static let inspectorWidth: CGFloat = 300
        static let panelInset: CGFloat = 7     // the left panel floats (MacAppRules §8)
        static let panelRadius: CGFloat = 10
        static let cardRadius: CGFloat = 6
        static let textInset: CGFloat = 18
    }

    static func uiFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func monoFont(_ size: CGFloat) -> NSFont {
        // Berkeley Mono is the family reference; SF Mono is the fallback that
        // is always present on the machine.
        NSFont(name: "Berkeley Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func labelFont(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension Theme.Palette {
    /// What the terminal grid draws with. The chrome and the grid take their
    /// colours from ONE palette, so a theme cannot half-arrive.
    var terminal: TerminalTheme {
        TerminalTheme(background: ground, foreground: ink, cursor: ink,
                      selection: selection, link: accentText,
                      linkHighlight: accentDim, ansi: ansi)
    }
}

/// A view that keeps a colour somewhere other than in `draw`.
///
/// Most of the chrome reads `Theme.current` while it paints, so a redisplay
/// is the whole of a theme change. The few that cache — a label's textColor,
/// a layer's background — say so by conforming, and get asked.
@MainActor
protocol ThemeAware {
    func applyTheme()
}

extension Theme {
    /// Pushes the live palette through every window that is open.
    ///
    /// The walk is the mechanism and not a convenience: a theme change that
    /// only repaints the views somebody remembered to list is a theme change
    /// that decays every time a view is added.
    @MainActor static func reapplyEverywhere() {
        for window in NSApp.windows {
            window.appearance = NSAppearance(named: current.isLight ? .aqua : .darkAqua)
            (window.windowController as? ThemeAware)?.applyTheme()
            guard let content = window.contentView else { continue }
            walk(content)
        }
    }

    @MainActor private static func walk(_ view: NSView) {
        (view as? ThemeAware)?.applyTheme()
        view.needsDisplay = true
        view.subviews.forEach(walk)
    }
}

extension NSColor {
    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }

    /// `#RRGGBB`, the way a person writes a colour in a text file.
    static func hex(string: String) -> NSColor? {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return .hex(value)
    }
}
