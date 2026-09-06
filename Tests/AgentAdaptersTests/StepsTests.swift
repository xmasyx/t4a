//  StepsTests.swift — il lavoro di un turno diventa blocchi richiudibili.
//
//  La regola che questi poli difendono è una sola, ed è sua: la RISPOSTA si
//  vede sempre per intero, tutto il resto (il ragionamento, quello che scrive
//  per arrivarci, il codice degli strumenti) sta dentro blocchi che si aprono
//  a richiesta. Un polo negativo tiene il confine: un testo intermedio non
//  deve finire nella risposta, e la risposta non deve finire fra i blocchi.

import Foundation
import Testing
import TerminalCore
@testable import AgentAdapters

@MainActor
private func ingest(_ records: [[String: Any]]) -> ClaudeCodeAdapter {
    let adapter = ClaudeCodeAdapter()
    let lines = records.map { record -> String in
        let data = try! JSONSerialization.data(withJSONObject: record)
        return String(decoding: data, as: UTF8.self)
    }
    adapter.ingest(lines: lines)
    return adapter
}

private func assistant(_ blocks: [[String: Any]], stop: String = "tool_use") -> [String: Any] {
    ["type": "assistant", "timestamp": "2026-08-25T10:00:00.000Z",
     "message": ["model": "claude-sonnet-5", "stop_reason": stop, "content": blocks]]
}

@MainActor
@Test func ilLavoroDiventaBlocchiELaRispostaResta() {
    let adapter = ingest([
        ["type": "user", "timestamp": "2026-08-25T10:00:00.000Z",
         "message": ["content": "ripara il notch"]],
        assistant([["type": "thinking", "thinking": "prima guardo\ndove sta il difetto"],
                   ["type": "text", "text": "Guardo il file."],
                   ["type": "tool_use", "id": "t1", "name": "Bash",
                    "input": ["command": "swift build\n&& swift test"]]]),
        assistant([["type": "text", "text": "Fatto: era lo scrub delle variabili."]],
                  stop: "end_turn"),
    ])

    let turn = adapter.turns.last!
    #expect(turn.answer == "Fatto: era lo scrub delle variabili.")
    #expect(turn.steps.map(\.kind) == [.thinking, .note, .tool])
    // Il ragionamento e il testo intermedio NON sono la risposta.
    #expect(!turn.answer.contains("Guardo il file"))
    #expect(turn.steps[1].detail == "Guardo il file.")
    // Il blocco dello strumento porta dentro il comando INTERO, non la sintesi.
    #expect(turn.steps[2].title == "Bash · swift build && swift test")
    #expect(turn.steps[2].detail == "swift build\n&& swift test")
    // La riga chiusa dice quanto c'è dentro.
    #expect(turn.steps[0].size == "2 righe")
}

@MainActor
@Test func unoStrumentoAndatoStortoSiVedeDalBlocco() {
    let adapter = ingest([
        ["type": "user", "timestamp": "2026-08-25T10:00:00.000Z",
         "message": ["content": "compila"]],
        assistant([["type": "tool_use", "id": "t9", "name": "Bash",
                    "input": ["command": "swift build"]]]),
        ["type": "user", "timestamp": "2026-08-25T10:00:02.000Z",
         "message": ["content": [["type": "tool_result", "tool_use_id": "t9",
                                  "is_error": true]]]],
    ])
    let turn = adapter.turns.last!
    #expect(turn.steps.first?.isError == true)
    #expect(turn.failed)
}

@MainActor
@Test func unAttrezzoSconosciutoMostraComunqueISuoiIngressi() {
    let detail = ClaudeCodeAdapter.detail(tool: "Attrezzo",
                                          input: ["alfa": "uno", "beta": "due"])
    #expect(detail == "alfa: uno\nbeta: due")
    // Con una chiave sola l'etichetta è rumore: il valore parla da sé.
    #expect(ClaudeCodeAdapter.detail(tool: "Bash", input: ["command": "ls -la"]) == "ls -la")
}

@MainActor
@Test func unTurnoSenzaLavoroNonHaBlocchi() {
    let adapter = ingest([
        ["type": "user", "timestamp": "2026-08-25T10:00:00.000Z",
         "message": ["content": "ciao"]],
        assistant([["type": "text", "text": "Ciao."]], stop: "end_turn"),
    ])
    #expect(adapter.turns.last!.steps.isEmpty)
    #expect(adapter.turns.last!.answer == "Ciao.")
}
