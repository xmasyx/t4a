//  TranscriptAttributionTests.swift — a pane follows only process-owned facts.

import Foundation
import Testing
@testable import AgentAdapters

private let attributionRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("t4a-transcript-attribution", isDirectory: true)

private func transcriptURL(_ name: String) -> URL {
    attributionRoot.appendingPathComponent(name)
}

private func processStartString(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    formatter.isLenient = false
    return formatter.string(from: date)
}

private func utcProcessStart(_ date: Date) -> String {
    processStartString(date, timeZone: TimeZone(identifier: "UTC")!)
}

private func localProcessStart(_ date: Date) -> String {
    processStartString(date, timeZone: .current)
}

private func sessionRecord(pid: Any, sessionID: String = "session-123",
                           processStart: String? = nil) -> [String: Any] {
    var record: [String: Any] = ["pid": pid, "sessionId": sessionID]
    if let processStart { record["procStart"] = processStart }
    return record
}

private func temporaryHome(_ name: String) throws -> URL {
    let home = attributionRoot
        .appendingPathComponent("\(name)-\(getpid())-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func storeRecord(_ record: [String: Any], at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: record)
    try data.write(to: url)
}

// MARK: - Pure candidate choice

@Test func chooseTranscriptKeepsCurrentCandidate() {
    let current = transcriptURL("current.jsonl")
    let decision = AgentObserver.chooseTranscript(
        candidates: [(current, "vendor-record")], current: current,
        isFree: { _ in false })
    #expect(decision.url == current)
    #expect(decision.source == "vendor-record")
    #expect(decision.reason.isEmpty)
}

@Test func chooseTranscriptPicksFirstFreeCandidate() {
    let held = transcriptURL("held.jsonl")
    let free = transcriptURL("free.jsonl")
    let decision = AgentObserver.chooseTranscript(
        candidates: [(held, "kernel"), (free, "vendor-record")], current: nil,
        isFree: { $0 == free })
    #expect(decision.url == free)
    #expect(decision.source == "vendor-record")
    #expect(decision.reason.isEmpty)
}

@Test func chooseTranscriptPrefersKernelOrder() {
    let kernel = transcriptURL("kernel.jsonl")
    let vendor = transcriptURL("vendor.jsonl")
    let decision = AgentObserver.chooseTranscript(
        candidates: [(kernel, "kernel"), (vendor, "vendor-record")], current: nil,
        isFree: { _ in true })
    #expect(decision.url == kernel)
    #expect(decision.source == "kernel")
}

@Test func chooseTranscriptReportsWhenEveryCandidateIsHeld() {
    let first = transcriptURL("first.jsonl")
    let second = transcriptURL("second.jsonl")
    let decision = AgentObserver.chooseTranscript(
        candidates: [(first, "kernel"), (second, "vendor-record")], current: nil,
        isFree: { _ in false })
    #expect(decision.url == nil)
    #expect(decision.source.isEmpty)
    #expect(decision.reason == "transcript first.jsonl is held by another pane")
}

@Test func chooseTranscriptReturnsNothingForNoCandidates() {
    let decision = AgentObserver.chooseTranscript(
        candidates: [], current: nil, isFree: { _ in true })
    #expect(decision.url == nil)
    #expect(decision.source.isEmpty)
    #expect(decision.reason.isEmpty)
}

@Test func chooseTranscriptSwitchesFromAFormerCandidate() {
    let current = transcriptURL("former.jsonl")
    let replacement = transcriptURL("replacement.jsonl")
    let decision = AgentObserver.chooseTranscript(
        candidates: [(replacement, "vendor-record")], current: current,
        isFree: { _ in true })
    #expect(decision.url == replacement)
    #expect(decision.source == "vendor-record")
    #expect(decision.reason.isEmpty)
}

@Test func chooseTranscriptKeepsProvenCurrentDuringAnEmptyRead() {
    let current = transcriptURL("proven.jsonl")
    let decision = AgentObserver.chooseTranscript(
        candidates: [], current: current, isFree: { _ in false })
    #expect(decision.url == current)
    #expect(decision.source.isEmpty)
    #expect(decision.reason.isEmpty)
}

// MARK: - Claude's pure session-record match

@Test func sessionRecordRejectsPidMismatch() {
    let record = sessionRecord(pid: 701)
    #expect(!ClaudeCodeAdapter.sessionRecordMatches(
        record, pid: 702, processStart: nil))
}

@Test func sessionRecordAcceptsProcessStartWithinTwoSeconds() {
    let started = Date(timeIntervalSince1970: 1_787_954_610)
    let record = sessionRecord(pid: 703, processStart: utcProcessStart(started))
    #expect(ClaudeCodeAdapter.sessionRecordMatches(
        record, pid: 703, processStart: started.addingTimeInterval(2)))
}

@Test func sessionRecordAcceptsLocalProcessStartWithinTwoSeconds() {
    let started = Date(timeIntervalSince1970: 1_787_954_610)
    let record = sessionRecord(pid: 704, processStart: localProcessStart(started))
    #expect(ClaudeCodeAdapter.sessionRecordMatches(
        record, pid: 704, processStart: started.addingTimeInterval(2)))
}

@Test func sessionRecordRejectsStaleReusedPidInUTCAndLocalConventions() {
    let started = Date(timeIntervalSince1970: 1_787_954_610)
    let stale = started.addingTimeInterval(-90)
    for recordedStart in [utcProcessStart(stale), localProcessStart(stale)] {
        let record = sessionRecord(pid: 705, processStart: recordedStart)
        #expect(!ClaudeCodeAdapter.sessionRecordMatches(
            record, pid: 705, processStart: started))
    }
}

@Test func sessionRecordAcceptsMissingProcessStart() {
    let record = sessionRecord(pid: 706)
    #expect(ClaudeCodeAdapter.sessionRecordMatches(
        record, pid: 706, processStart: Date()))
}

@Test func sessionRecordAcceptsWhenKernelStartIsUnreadable() {
    let record = sessionRecord(
        pid: 707, processStart: utcProcessStart(Date(timeIntervalSince1970: 1_000)))
    #expect(ClaudeCodeAdapter.sessionRecordMatches(
        record, pid: 707, processStart: nil))
}

@Test func sessionRecordAcceptsUnparseableProcessStart() {
    let record = sessionRecord(pid: 708, processStart: "a future vendor format")
    #expect(ClaudeCodeAdapter.sessionRecordMatches(
        record, pid: 708, processStart: Date()))
}

@Test func sessionRecordRejectsUnsafeSessionIDs() {
    #expect(!ClaudeCodeAdapter.sessionRecordMatches(
        sessionRecord(pid: 709, sessionID: "parent/child"),
        pid: 709, processStart: nil))
    #expect(!ClaudeCodeAdapter.sessionRecordMatches(
        sessionRecord(pid: 709, sessionID: ".."),
        pid: 709, processStart: nil))
    #expect(!ClaudeCodeAdapter.sessionRecordMatches(
        sessionRecord(pid: 709, sessionID: ""),
        pid: 709, processStart: nil))
}

@Test func sessionRecordAcceptsIntegralDoublePid() {
    let record = sessionRecord(pid: Double(710))
    #expect(ClaudeCodeAdapter.sessionRecordMatches(
        record, pid: 710, processStart: nil))
}

// MARK: - Record reading and kernel time

@MainActor
@Test func claudeRecordAttributesItsExpectedTranscript() throws {
    let home = try temporaryHome("matching-record")
    let cwd = home.appendingPathComponent("work/project", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    let pid = getpid()
    let started = try #require(AgentObserver.processStart(of: pid))
    let recordURL = ClaudeCodeAdapter.sessionRecordURL(pid: pid, home: home)
    defer { try? FileManager.default.removeItem(at: recordURL) }

    var record = sessionRecord(pid: Int(pid), processStart: utcProcessStart(started))
    record["cwd"] = cwd.path
    try storeRecord(record, at: recordURL)

    let attributed = ClaudeCodeAdapter.transcripts(
        attributedTo: pid, home: home,
        cwd: home.appendingPathComponent("different-caller-cwd"),
        processStart: started)
    let sessionID = "session-123"
    let expected = ClaudeCodeAdapter.transcriptDirectories(home: home, cwd: cwd).map {
        $0.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
    }
    #expect(attributed == expected)
    let configuredExpected = ClaudeCodeAdapter.configurationRoot(home: home)
        .appendingPathComponent("projects")
        .appendingPathComponent(ClaudeCodeAdapter.flatten(cwd.path))
        .appendingPathComponent("\(sessionID).jsonl")
    #expect(attributed.contains(configuredExpected))

    record["procStart"] = utcProcessStart(started.addingTimeInterval(-90))
    try storeRecord(record, at: recordURL)
    #expect(ClaudeCodeAdapter.transcripts(
        attributedTo: pid, home: home, cwd: cwd, processStart: started).isEmpty)
}

@MainActor
@Test func claudeRecordReaderDefinesMissingMalformedAndFallbackCwd() throws {
    let home = try temporaryHome("record-errors")
    let pid = Int32.max - 41
    let recordURL = ClaudeCodeAdapter.sessionRecordURL(pid: pid, home: home)
    defer { try? FileManager.default.removeItem(at: recordURL) }
    let cwd = home.appendingPathComponent("fallback-cwd")

    #expect(ClaudeCodeAdapter.transcripts(
        attributedTo: pid, home: home, cwd: cwd, processStart: nil).isEmpty)

    try FileManager.default.createDirectory(
        at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: recordURL)
    #expect(ClaudeCodeAdapter.transcripts(
        attributedTo: pid, home: home, cwd: cwd, processStart: nil).isEmpty)

    try storeRecord(sessionRecord(pid: Int(pid)), at: recordURL)
    let attributed = ClaudeCodeAdapter.transcripts(
        attributedTo: pid, home: home, cwd: cwd, processStart: nil)
    let expected = ClaudeCodeAdapter.transcriptDirectories(home: home, cwd: cwd).map {
        $0.appendingPathComponent("session-123.jsonl")
    }
    #expect(attributed == expected)

    var emptyCwdRecord = sessionRecord(pid: Int(pid))
    emptyCwdRecord["cwd"] = ""
    try storeRecord(emptyCwdRecord, at: recordURL)
    #expect(ClaudeCodeAdapter.transcripts(
        attributedTo: pid, home: home, cwd: cwd, processStart: nil) == expected)
}

@Test func processStartReadsCurrentProcessAndRejectsImpossiblePids() throws {
    let started = try #require(AgentObserver.processStart(of: getpid()))
    let age = Date().timeIntervalSince(started)
    #expect(age >= -2)
    #expect(age < 24 * 60 * 60)
    #expect(AgentObserver.processStart(of: 0) == nil)
    #expect(AgentObserver.processStart(of: 99_999_999) == nil)
}
