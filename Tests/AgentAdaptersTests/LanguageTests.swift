import Foundation
import TerminalCore
import Testing

@Test func englishSettingPinsEnglish() {
    #expect(Lang.resolve(setting: "en", environment: ["LANG": "it_IT.UTF-8"],
                         preferredLanguages: ["it-IT"]) == .en)
}

@Test func italianSettingPinsItalian() {
    #expect(Lang.resolve(setting: "it", environment: ["LANG": "en_US.UTF-8"],
                         preferredLanguages: ["en-US"]) == .it)
}

@Test func systemSettingTakesItalianFromTheInjectedEnvironment() {
    #expect(Lang.resolve(setting: "system", environment: ["LANG": "it_IT.UTF-8"],
                         preferredLanguages: ["en-US"]) == .it)
}

@Test func appleLanguagesTakesPrecedenceInsideTheInjectedEnvironment() {
    #expect(Lang.resolve(
        setting: "system",
        environment: ["AppleLanguages": "(it-IT, en-US)", "LANG": "en_US.UTF-8"],
        preferredLanguages: ["en-US"]
    ) == .it)
}

@Test func localePrecedenceIsAllThenMessagesThenLang() {
    #expect(Lang.resolve(
        setting: "system",
        environment: ["LC_ALL": "en_US.UTF-8", "LC_MESSAGES": "it_IT.UTF-8",
                      "LANG": "it_IT.UTF-8"],
        preferredLanguages: ["it-IT"]
    ) == .en)
}

@Test func unreadablePosixLocaleFallsThroughToTheNextInjectedSignal() {
    #expect(Lang.resolve(
        setting: "system",
        environment: ["LC_ALL": "C", "LC_MESSAGES": "it_IT.UTF-8"],
        preferredLanguages: ["en-US"]
    ) == .it)
}

@Test func systemSettingTakesItalianFromInjectedPreferredLanguages() {
    #expect(Lang.resolve(setting: "system", environment: [:],
                         preferredLanguages: ["it-IT", "en-US"]) == .it)
}

@Test func systemSettingMapsANonItalianSystemToEnglish() {
    #expect(Lang.resolve(setting: "system", environment: [:],
                         preferredLanguages: ["de-DE"]) == .en)
}

@Test func unreadableSettingFallsBackToTheSystemDefault() {
    #expect(Lang.resolve(setting: "italain", environment: [:],
                         preferredLanguages: ["it-IT"]) == .it)
    #expect(Lang.normalizedSetting("italain") == "system")
}

@Test func anEmptySystemFallsBackToEnglish() {
    #expect(Lang.resolve(setting: "system", environment: ["LANG": "C"],
                         preferredLanguages: []) == .en)
}

@Test func languageStorePublishesAnInMemoryChange() {
    let store = LanguageStore(.en)
    #expect(store.value == .en)
    store.value = .it
    #expect(store.value == .it)
}

@Test func taskOverrideSelectsTextWithoutChangingSharedState() {
    let before = LanguageStore.shared.value
    defer { LanguageStore.shared.value = before }
    LanguageStore.shared.value = .it
    #expect(L.current == .it)
    let translated: String = L.$override.withValue(.it) {
        L.t(en: "English", it: "Italiano")
    }
    let source: String = L.$override.withValue(.en) {
        L.t(en: "English", it: "Italiano")
    }
    #expect(translated == "Italiano")
    #expect(source == "English")
    #expect(LanguageStore.shared.value == .it)
}

@Test func configurationDefaultsLanguageAndAnnouncesAnInMemorySet() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("t4a-language-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: url) }
    let config = Configuration(url: url)
    #expect(config.languageSetting() == "system")

    var changed: ConfigKey?
    config.onChange = { changed = $0 }
    config.set(.language, "it")

    #expect(changed == .language)
    #expect(config.languageSetting() == "it")
}

@Test func garbageConfigurationLanguageReportsAndUsesItsDefault() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("t4a-language-garbage-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: url) }
    try "language = italain\n".write(to: url, atomically: true, encoding: .utf8)
    let config = Configuration(url: url)

    #expect(config.languageSetting() == "system")
    #expect(config.problems == [
        "language = italain is not system, en, or it; using the default, system"
    ])
}

@Test func emptyConfigurationLanguageReportsAndUsesItsDefault() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("t4a-language-empty-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: url) }
    try "language = \"\"\n".write(to: url, atomically: true, encoding: .utf8)
    let config = Configuration(url: url)

    #expect(config.languageSetting() == "system")
    #expect(config.problems == [
        "language = (empty) is not system, en, or it; using the default, system"
    ])
}
