//  KernelTranscriptTests.swift — quale file aperto dal processo è il suo transcript.
//
//  Fino al 28/08 il ramo «dal kernel» accettava solo path con `/projects/`,
//  cioè l'albero di Claude Code: un rollout di codex (`~/.codex/sessions/…`)
//  non passava mai, e il pannello agganciato al processo giusto non seguiva
//  niente (misurato sulla prima tappa della porta). La regola ora è: un
//  `.jsonl` dentro una delle cartelle di transcript dell'adattatore.

@testable import AgentAdapters
import Foundation
import Testing

private let home = URL(fileURLWithPath: "/tmp/x")
private let cwd = URL(fileURLWithPath: "/tmp/x/work/app")

@MainActor @Test func unRolloutDiCodexNellaSuaCartellaEIlSuoTranscript() {
    let dirs = CodexAdapter.transcriptDirectories(home: home, cwd: cwd)
    let today = dirs[0].path
    #expect(AgentObserver.isTranscript(path: "\(today)/rollout-2026-08-28T01-14-51-abc.jsonl", under: dirs))
}

@MainActor @Test func unTranscriptDiClaudeNellaSuaCartellaEIlSuoTranscript() {
    let dirs = ClaudeCodeAdapter.transcriptDirectories(home: home, cwd: cwd)
    #expect(!dirs.isEmpty)
    #expect(AgentObserver.isTranscript(path: "\(dirs[0].path)/7f56ac08.jsonl", under: dirs))
}

@MainActor @Test func unFileFuoriDalleCartelleNonLoE() {
    let dirs = CodexAdapter.transcriptDirectories(home: home, cwd: cwd)
    #expect(!AgentObserver.isTranscript(path: "/tmp/x/.codex/log/codex.jsonl", under: dirs))
    #expect(!AgentObserver.isTranscript(path: "/tmp/x/.codex/thread-writer-locks/abc.lock", under: dirs))
    #expect(!AgentObserver.isTranscript(path: "\(dirs[0].path)/note.txt", under: dirs))
    #expect(!AgentObserver.isTranscript(path: "\(dirs[0].path)/sub/deep.jsonl", under: dirs))
}
