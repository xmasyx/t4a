//  ModelNameTests.swift — the bar's two words, and the families that make them
//  (ISC-123).
//
//  The point of these is not the formatting. It is that the family names come
//  from the ADAPTER: the last test is the one that would go red if somebody
//  moved the table back into the core, because it asks each adapter for its
//  own answer and expects the other vendor's names to mean nothing to it.

import Testing
import TerminalCore
@testable import AgentAdapters

@MainActor
@Test func shortensAModelToTheFamilyAndItsNumber() {
    let families = ClaudeCodeAdapter.modelFamilies
    #expect(ModelName.short("claude-opus-5", families: families) == "Opus 5")
    #expect(ModelName.short("claude-sonnet-4-5-20250929", families: families) == "Sonnet 4.5")
    #expect(ModelName.short("claude-haiku-4-5", families: families) == "Haiku 4.5")
    #expect(ModelName.short("fable", families: families) == "Fable")
}

@MainActor
@Test func leavesAModelItCannotReadAlone() {
    // Never a guess and never a truncation: half a model name is worse than
    // a long one.
    let families = ClaudeCodeAdapter.modelFamilies
    #expect(ModelName.short("llama-3-70b", families: families) == "llama-3-70b")
    #expect(ModelName.short("", families: families) == "")
    #expect(ModelName.short("opus-5", families: []) == "opus-5")
}

@MainActor
@Test func eachAdapterOnlyKnowsItsOwnVendorsFamilies() {
    // The falsifier for ISC-123: with one shared table in the core, both of
    // these would answer the same, and both halves of this test would pass by
    // accident.
    #expect(ModelName.short("gpt-5.6-sol", families: CodexAdapter.modelFamilies) == "Gpt 5.6")
    #expect(ModelName.short("gpt-5.6-sol", families: ClaudeCodeAdapter.modelFamilies)
        == "gpt-5.6-sol")
    #expect(ModelName.short("claude-opus-5", families: CodexAdapter.modelFamilies)
        == "claude-opus-5")
}

@MainActor
@Test func theAdapterAnswersForItself() {
    // Through the protocol extension, which is the path the bar actually uses.
    let claude = ClaudeCodeAdapter()
    claude.ingest(lines: [#"{"type":"assistant","message":{"model":"claude-opus-5","content":[]}}"#])
    #expect(claude.model == "claude-opus-5")
    #expect(claude.shortModel == "Opus 5")
}

// MARK: - Values nobody can read (ISC-134)

import Foundation

@Test func anUnreadableSwitchFallsBackToTheKeyDefault() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t4a-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")

    // The exact line from the audit: a typo, not a decision.
    try "agent-adapter = tru\n".write(to: file, atomically: true, encoding: .utf8)
    let typo = Configuration(url: file)
    #expect(typo.bool(.agentAdapter) == true, "a typo turned the adapter off")
    #expect(typo.problems.contains { $0.contains("agent-adapter") })

    // A value that IS readable still wins, in both directions — without this
    // the test above would pass on a `bool` that had stopped reading the file.
    try "agent-adapter = false\n".write(to: file, atomically: true, encoding: .utf8)
    let off = Configuration(url: file)
    #expect(off.bool(.agentAdapter) == false)
    #expect(off.problems.isEmpty)

    try "agent-adapter = on\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(Configuration(url: file).bool(.agentAdapter) == true)

    // And a key whose default is FALSE stays false when it is misspelled.
    // This half is the one with teeth: without a key that defaults the other
    // way, "falls back to the key's own default" and "falls back to true" are
    // the same green. It used to be `pure-chat`, and `pure-chat` shipped ON on
    // 2026-08-23 (ISC-150) — at which point this test went red and said so,
    // which is exactly what it is for. `compact-turns` is a key that defaults
    // false today.
    try "compact-turns = perhaps\n".write(to: file, atomically: true, encoding: .utf8)
    let compact = Configuration(url: file)
    #expect(compact.bool(.compactTurns) == false)
    #expect(compact.problems.contains { $0.contains("compact-turns") })

    // And the key that changed twice, asserted in its CURRENT direction (off
    // since 6/09, his decision for the release: the agent's own input line is
    // the input), so a default that quietly flipped would not pass unnoticed.
    try "pure-chat = perhaps\n".write(to: file, atomically: true, encoding: .utf8)
    let pure = Configuration(url: file)
    #expect(pure.bool(.pureChat) == false)
    #expect(pure.problems.contains { $0.contains("pure-chat") })
}

@Test func aFractionOutsideItsRangeFallsBackToTheDefault() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t4a-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    try "font-size = nan\n".write(to: file, atomically: true, encoding: .utf8)
    let broken = Configuration(url: file)
    #expect(broken.fraction(.fontSize, in: 1...200) == 13)
    try "font-size = 14\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(Configuration(url: file).fraction(.fontSize, in: 1...200) == 14)
    try "font-size = -3\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(Configuration(url: file).fraction(.fontSize, in: 1...200) == 13)
}

@Test func aTranscriptRewrittenShorterIsReadAgainFromTheStart() throws {
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t4a-tail-\(UUID().uuidString).jsonl")
    try #"{"a":1}"#.appending("\n{\"a\":2}\n{\"a\":3}\n")
        .write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    var seen: [String] = []
    var rewinds = 0
    let tail = try #require(TranscriptTail(url: file,
                                           onLines: { seen.append(contentsOf: $0) },
                                           onVanished: {}))
    tail.onTruncated = { rewinds += 1; seen.removeAll() }
    tail.drain()
    #expect(seen.count == 3)

    // Rewritten IN PLACE and shorter: the same inode, so nothing is deleted or
    // renamed and the kqueue has nothing to report.
    //
    // `write(to:atomically: true)` would NOT do this — it writes a temporary
    // file and renames it over, which makes a new inode and leaves the old one
    // intact behind our descriptor, so the first version of this test measured
    // a case that cannot happen and would have passed on the unfixed code.
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(#"{"b":1}"#.appending("\n").utf8))
    try handle.close()
    tail.drain()
    // At least once, not exactly once: the tail also has a live kqueue on this
    // file, so the write can be drained by the event handler as well as by the
    // call above, and pinning the count would be pinning a race. What has to
    // be exact is what came out — the old three lines must be gone and the new
    // one read, which is the whole claim.
    #expect(rewinds >= 1, "the truncation went unnoticed")
    #expect(seen == [#"{"b":1}"#], "read \(seen)")
    tail.stop()
}
