//  Language.swift — the two languages T4A speaks, and the one place that
//  decides which of them a caller means.
//
//  The language state lives in TerminalCore rather than in the executable.
//  That is not layering for its own sake: the app target has top-level code
//  and cannot be imported by the test target, while language resolution is
//  exactly the kind of quiet precedence rule that must be driven with made-up
//  environments. The UI catalog stays in T4A; the mechanism it relies on is
//  small, process-independent, and testable here.

import Foundation

/// The languages remain deliberately finite. Adding a case means writing a
/// third version of every sentence; it is not a promise made by a config knob.
public enum Lang: String, CaseIterable, Sendable {
    case en
    case it

    /// Resolve the configuration value into the language T4A should use.
    ///
    /// `system`, which is also the documented configuration default, first
    /// honours the language exported by a launching shell and then macOS's
    /// preferred-language list. Both inputs are arguments so the resolver
    /// never changes its answer underneath a test or reaches into its process.
    /// An unreadable setting is a typo, not a third choice: it takes the same
    /// path as the default instead of silently selecting a language the user
    /// did not ask for.
    public static func resolve(
        setting: String,
        environment: [String: String],
        preferredLanguages: [String]
    ) -> Lang {
        switch normalizedSetting(setting) {
        case "en":
            return .en
        case "it":
            return .it
        default:
            // `normalizedSetting` maps both `system` and unreadable values to
            // the documented default, so the remaining branch is deliberate.
            return detect(environment: environment, preferredLanguages: preferredLanguages)
        }
    }

    /// The spelling written back into a choice control. Keeping this beside
    /// resolution means a bad value cannot make the app follow the system
    /// while its settings window claims that no choice is selected.
    public static func normalizedSetting(_ setting: String) -> String {
        let normalized = setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "en", "it", "system":
            return normalized
        default:
            return "system"
        }
    }

    private static func detect(
        environment: [String: String],
        preferredLanguages: [String]
    ) -> Lang {
        if let value = environment["AppleLanguages"],
           let language = language(for: firstAppleLanguage(in: value)) {
            return language
        }

        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let value = environment[key],
               let language = language(for: posixLanguage(in: value)) {
                return language
            }
        }

        if let preferred = preferredLanguages.first,
           let language = language(for: preferred) {
            return language
        }

        return .en
    }

    private static func firstAppleLanguage(in value: String) -> String {
        let first = String(value.prefix { $0 != "," })
        let decoration = CharacterSet(charactersIn: "()\"'")
            .union(.whitespacesAndNewlines)
        return first.trimmingCharacters(in: decoration)
    }

    private static func posixLanguage(in value: String) -> String {
        let end = value.firstIndex { character in
            character == "." || character == "_"
        } ?? value.endIndex
        return String(value[..<end])
    }

    private static func language(for tag: String) -> Lang? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != "c", normalized != "posix" else {
            return nil
        }
        return normalized.hasPrefix("it") ? .it : .en
    }
}

/// The app's live language, protected because `L.t` is also available to
/// non-UI code. The lock makes the unchecked conformance a stated invariant:
/// no access to `storedValue` exists without taking it.
public final class LanguageStore: @unchecked Sendable {
    public static let shared = LanguageStore()

    private let lock = NSLock()
    private var storedValue: Lang

    public init(_ value: Lang = .en) {
        storedValue = value
    }

    public var value: Lang {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

/// The short spelling used by the UI catalog.
public enum L {
    /// A test pins its own task without changing the live value another test
    /// or the app may be reading at the same time.
    @TaskLocal public static var override: Lang?

    public static var current: Lang {
        override ?? LanguageStore.shared.value
    }

    /// The labels make the source language impossible to confuse with its
    /// translation at a call site whose two arguments otherwise share a type.
    public static func t(en: String, it: String) -> String {
        switch current {
        case .en:
            return en
        case .it:
            return it
        }
    }
}
