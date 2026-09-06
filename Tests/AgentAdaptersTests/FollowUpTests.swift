//  FollowUpTests.swift — uno Stop hook rimanda il modello dentro lo stesso
//  turno, senza inventare una seconda domanda.
//
//  Il confine importante è il messaggio meta: quello col prefisso misurato è
//  una continuazione; ogni altro meta resta rumore del harness. E quando il
//  modello finisce davvero, la frase umana successiva torna a essere un turno
//  nuovo come prima.

import Foundation
import Testing
import TerminalCore
@testable import AgentAdapters

private let hookReale = """
Stop hook feedback:
[$HOME/.claude/hooks/RulesNudgeGate.hook.ts]: 📖 RULES-NUDGE GATE: il turno ha ricevuto l'innesco e il file non è stato letto. Prima di chiudere, Read:
- docs/PROJECT_RULES.md
"""

@MainActor
private func leggi(_ records: [[String: Any]]) -> ClaudeCodeAdapter {
    let adapter = ClaudeCodeAdapter()
    adapter.ingest(lines: records.map { record in
        String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    })
    return adapter
}

private func user(_ content: Any, at timestamp: String,
                  isMeta: Bool = false) -> [String: Any] {
    var record: [String: Any] = [
        "type": "user", "timestamp": timestamp,
        "message": ["role": "user", "content": content],
    ]
    if isMeta { record["isMeta"] = true }
    return record
}

private func assistant(_ content: [[String: Any]], at timestamp: String,
                       stop: String) -> [String: Any] {
    ["type": "assistant", "timestamp": timestamp,
     "message": ["role": "assistant", "model": "claude-opus-5",
                 "content": content, "stop_reason": stop]]
}

private func transcriptConSeguito() -> [[String: Any]] {
    [
        user("Leggi le regole e poi rispondi.", at: "2026-08-26T23:10:00.000Z"),
        assistant([["type": "text", "text": "Prima risposta."]],
                  at: "2026-08-26T23:11:16.000Z", stop: "end_turn"),
        user(hookReale, at: "2026-08-26T23:11:17.232Z", isMeta: true),
        assistant([["type": "tool_use", "id": "read-1", "name": "Read",
                    "input": ["file_path": "/tmp/notes.md"]]],
                  at: "2026-08-26T23:11:18.000Z", stop: "tool_use"),
        user([["type": "tool_result", "tool_use_id": "read-1",
               "content": "regole", "is_error": false]],
             at: "2026-08-26T23:11:18.500Z"),
        assistant([["type": "thinking", "thinking": "Ora applico le regole."],
                   ["type": "text", "text": "Seconda risposta dopo la lettura."]],
                  at: "2026-08-26T23:11:19.000Z", stop: "end_turn"),
    ]
}

@MainActor
@Test func loStopHookAggiungeUnaRispostaAlloStessoTurno() {
    let adapter = leggi(transcriptConSeguito())

    #expect(adapter.turns.count == 1)
    let turn = adapter.turns[0]
    #expect(turn.followUps.count == 1)
    #expect(turn.followUps[0].source == "RulesNudgeGate")
    #expect(turn.followUps[0].reason.hasPrefix("📖 RULES-NUDGE GATE"))
    #expect(turn.followUps[0].answer == "Seconda risposta dopo la lettura.")
    #expect(turn.answer == "Prima risposta.")
    #expect(!turn.isOpen)
    #expect(turn.tools.contains { $0.id == "read-1" && $0.name == "Read" })
    #expect(adapter.activity == .waiting)
}

@MainActor
@Test func unaFraseUmanaDopoIlSeguitoApreUnTurnoNuovo() {
    let adapter = leggi(transcriptConSeguito() + [
        user("Adesso fai un'altra cosa.", at: "2026-08-26T23:12:00.000Z"),
    ])

    #expect(adapter.turns.count == 2)
    #expect(adapter.turns[1].prompt == "Adesso fai un'altra cosa.")
    #expect(adapter.turns[1].followUps.isEmpty)
}

@MainActor
@Test func iMessaggiMetaSenzaPrefissoRestanoInvisibili() {
    let adapter = leggi([
        user("Prima domanda.", at: "2026-08-26T23:00:00.000Z"),
        assistant([["type": "text", "text": "Prima risposta."]],
                  at: "2026-08-26T23:00:01.000Z", stop: "end_turn"),
        user("<local-command-caveat>messaggio del harness</local-command-caveat>",
             at: "2026-08-26T23:00:02.000Z", isMeta: true),
        user("[Image: original 3024x1750, displayed at 2000x1157.]",
             at: "2026-08-26T23:00:03.000Z", isMeta: true),
    ])

    #expect(adapter.turns.count == 1)
    #expect(adapter.turns[0].followUps.isEmpty)

    adapter.ingest(lines: [String(decoding: try! JSONSerialization.data(
        withJSONObject: assistant([["type": "text", "text": "Testo tardivo."]],
                                  at: "2026-08-26T23:00:04.000Z", stop: "end_turn")),
        as: UTF8.self)])
    #expect(adapter.turns.count == 2)
    #expect(adapter.turns[1].prompt.isEmpty)
    #expect(adapter.turns[1].followUps.isEmpty)
    #expect(adapter.turns[1].answer == "Testo tardivo.")
}

@MainActor
@Test func ilFeedbackDelloStopHookHaUnConfineEUnaFonte() {
    let parsed = ClaudeCodeAdapter.hookFeedback(hookReale)
    #expect(parsed?.source == "RulesNudgeGate")
    #expect(parsed?.reason == """
    📖 RULES-NUDGE GATE: il turno ha ricevuto l'innesco e il file non è stato letto. Prima di chiudere, Read:
    - docs/PROJECT_RULES.md
    """)

    let senzaFonte = ClaudeCodeAdapter.hookFeedback(
        "Stop hook feedback:\nsomething without a bracket")
    #expect(senzaFonte?.source == "")
    #expect(senzaFonte?.reason == "something without a bracket")
    #expect(ClaudeCodeAdapter.hookFeedback("not a hook") == nil)
}

@MainActor
@Test func unFeedbackSenzaTurniONelTurnoApertoRestaLeggibile() {
    let senzaPrima = leggi([
        user("Stop hook feedback:\nsolo richiamo", at: "2026-08-26T22:00:00.000Z",
             isMeta: true),
    ])
    #expect(senzaPrima.turns.count == 1)
    #expect(senzaPrima.turns[0].prompt.isEmpty)
    #expect(senzaPrima.turns[0].followUps.first?.reason == "solo richiamo")

    let aperto = leggi([
        user("Domanda ancora aperta.", at: "2026-08-26T22:01:00.000Z"),
        user("Stop hook feedback:\nrichiamo in corsa", at: "2026-08-26T22:01:01.000Z",
             isMeta: true),
    ])
    #expect(aperto.turns.count == 1)
    #expect(aperto.turns[0].prompt == "Domanda ancora aperta.")
    #expect(aperto.turns[0].followUps.first?.reason == "richiamo in corsa")
}
