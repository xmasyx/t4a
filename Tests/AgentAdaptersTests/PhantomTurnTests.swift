//  PhantomTurnTests.swift — più record `assistant` possono essere blocchi
//  dello stesso messaggio API, non turni distinti.

import Foundation
import Testing
import TerminalCore
@testable import AgentAdapters

@MainActor
private func readPhantomTranscript(_ records: [[String: Any]]) -> ClaudeCodeAdapter {
    let adapter = ClaudeCodeAdapter()
    adapter.ingest(lines: records.map { record in
        String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    })
    return adapter
}

private func phantomUser(_ content: Any, at timestamp: String,
                         meta: Bool = false) -> [String: Any] {
    var record: [String: Any] = [
        "type": "user", "timestamp": timestamp,
        "message": ["role": "user", "content": content],
    ]
    if meta { record["isMeta"] = true }
    return record
}

private func phantomAssistant(id: String, _ content: [[String: Any]],
                              at timestamp: String, stop: String) -> [String: Any] {
    ["type": "assistant", "timestamp": timestamp,
     "message": ["id": id, "role": "assistant", "model": "claude-opus-5",
                 "content": content, "stop_reason": stop]]
}

private var splitAnswer: [[String: Any]] {
    [
        phantomUser("Domanda.", at: "2026-08-28T10:00:00.000Z"),
        phantomAssistant(id: "msg_A", [["type": "thinking", "thinking": "Penso."]],
                         at: "2026-08-28T10:00:01.000Z", stop: "end_turn"),
        phantomAssistant(id: "msg_A", [["type": "text", "text": "Risposta."]],
                         at: "2026-08-28T10:00:02.000Z", stop: "end_turn"),
    ]
}

@MainActor
@Test func iBlocchiDelloStessoMessaggioRestanoInUnTurno() {
    let adapter = readPhantomTranscript(splitAnswer)

    #expect(adapter.turns.count == 1)
    #expect(adapter.turns[0].answer == "Risposta.")
    #expect(!adapter.turns[0].isOpen)
    #expect(adapter.activity == .waiting)
}

@MainActor
@Test func unaDomandaVeraDopoIlMessaggioDivisoApreIlSecondoTurno() {
    let adapter = readPhantomTranscript(splitAnswer + [
        phantomUser("Altra domanda.", at: "2026-08-28T10:00:03.000Z"),
    ])

    #expect(adapter.turns.count == 2)
    #expect(adapter.turns[1].prompt == "Altra domanda.")
}

@MainActor
@Test func unIdDiversoSenzaDomandaRestaUnTurnoIniziatoDallAssistente() {
    let adapter = readPhantomTranscript(splitAnswer + [
        phantomAssistant(id: "msg_B", [["type": "text", "text": "Fuori turno."]],
                         at: "2026-08-28T10:00:03.000Z", stop: "end_turn"),
    ])

    #expect(adapter.turns.count == 2)
    #expect(adapter.turns[1].prompt.isEmpty)
    #expect(adapter.turns[1].answer == "Fuori turno.")
}

@MainActor
@Test func ancheIlSeguitoDivisoRestaNelTurnoOriginale() {
    let hook = "Stop hook feedback:\n[/tmp/RulesNudgeGate.hook.ts]: leggi prima le regole"
    let adapter = readPhantomTranscript(splitAnswer + [
        phantomUser(hook, at: "2026-08-28T10:00:03.000Z", meta: true),
        phantomAssistant(id: "msg_B", [["type": "tool_use", "id": "read-1",
                                        "name": "Read",
                                        "input": ["file_path": "/tmp/notes.md"]]],
                         at: "2026-08-28T10:00:04.000Z", stop: "tool_use"),
        phantomUser([["type": "tool_result", "tool_use_id": "read-1",
                      "content": "regole", "is_error": false]],
                    at: "2026-08-28T10:00:05.000Z"),
        phantomAssistant(id: "msg_C", [["type": "thinking", "thinking": "Rileggo."]],
                         at: "2026-08-28T10:00:06.000Z", stop: "end_turn"),
        phantomAssistant(id: "msg_C", [["type": "text", "text": "Seconda."]],
                         at: "2026-08-28T10:00:07.000Z", stop: "end_turn"),
    ])

    #expect(adapter.turns.count == 1)
    #expect(adapter.turns[0].answer == "Risposta.")
    #expect(adapter.turns[0].followUps.count == 1)
    #expect(adapter.turns[0].followUps[0].answer == "Seconda.")
    #expect(adapter.turns[0].tools.contains { $0.id == "read-1" && $0.name == "Read" })
    #expect(!adapter.turns[0].isOpen)
}
