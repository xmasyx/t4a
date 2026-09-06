//  QueueTests.swift — la coda di claude letta dai suoi record (ISC-194).
//
//  Le tre operazioni viste nei transcript veri del 27/08: `enqueue` col testo,
//  `remove` col testo e `reason: absorbed_mid_turn` (2.1.247: il messaggio
//  entra nel turno in corso, nessun turno nuovo), `dequeue` senza testo (il
//  più vecchio esce, su interruzione o a fine turno). E il polo negativo: una
//  notifica accodata dal harness, che comincia con `<`, non è un messaggio
//  di una persona e non fa ricevuta.

import Foundation
import Testing
@testable import AgentAdapters

private func lines(_ records: [[String: Any]]) -> [String] {
    records.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
}

private func op(_ operation: String, _ content: String? = nil) -> [String: Any] {
    var r: [String: Any] = ["type": "queue-operation", "operation": operation,
                            "timestamp": "2026-08-27T19:59:11.376Z"]
    if let content { r["content"] = content }
    return r
}

@MainActor @Test func unEnqueueEntraNellaCoda() {
    let a = ClaudeCodeAdapter()
    a.ingest(lines: lines([op("enqueue", "secondo messaggio in coda")]))
    #expect(a.queued == ["secondo messaggio in coda"])
    #expect(a.queueConsumed == 0)
}

@MainActor @Test func unRemoveAssorbitoNelTurnoLaSvuota() {
    let a = ClaudeCodeAdapter()
    var remove = op("remove", "secondo messaggio in coda")
    remove["reason"] = "absorbed_mid_turn"
    a.ingest(lines: lines([op("enqueue", "secondo messaggio in coda"), remove]))
    #expect(a.queued.isEmpty)
    #expect(a.queueConsumed == 1)
}

@MainActor @Test func unDequeueSenzaTestoToglieIlPiuVecchio() {
    let a = ClaudeCodeAdapter()
    a.ingest(lines: lines([op("enqueue", "primo"), op("enqueue", "secondo"), op("dequeue")]))
    #expect(a.queued == ["secondo"])
    #expect(a.queueConsumed == 1)
}

@MainActor @Test func unaNotificaDelHarnessNonFaRicevuta() {
    let a = ClaudeCodeAdapter()
    a.ingest(lines: lines([op("enqueue", "<task-notification>\n<task-id>x</task-id>")]))
    #expect(a.queued.isEmpty)
}

@MainActor @Test func unDequeueSuCodaVuotaNonContaNiente() {
    let a = ClaudeCodeAdapter()
    a.ingest(lines: lines([op("dequeue")]))
    #expect(a.queued.isEmpty)
    #expect(a.queueConsumed == 0)
}
