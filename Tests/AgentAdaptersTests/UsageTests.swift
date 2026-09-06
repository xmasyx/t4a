//  UsageTests.swift — i tre numeri che un terminale legge da sé (ISC-172).
//
//  Contesto, uscita ed effort esistono già nel file che l'adattatore apre da
//  settimane: `ingestAssistant` leggeva `message.model` e buttava via
//  `message.usage`. Chi apre `claude` nudo, senza un fornitore di fatti, non li vedeva da
//  nessuna parte — non perché mancassero, ma perché nessuno li raccoglieva.
//
//  Le righe qui sotto sono VERE: i tre blocchi `usage` e il campo `effort`
//  sono copiati da un transcript sul disco il 25/08/2026, numeri compresi.
//  Quello che è stato tolto è il testo dei messaggi, che non serve a questi
//  poli e non ha ragione di stare in un repo. Contano tre cose che un
//  fixture inventato non avrebbe dimostrato: che `effort` sta IN CIMA al
//  record e non dentro `message`, che `usage` sta invece dentro `message`, e
//  che i tre ingressi del contesto arrivano davvero in campi separati.
//
//  Il polo che tiene il confine è l'ultimo: Codex non ha questi numeri e
//  risponde nil. Senza di lui «l'adattatore espone i token» sarebbe una frase
//  su Claude Code travestita da frase sul protocollo.

import Foundation
import Testing
import TerminalCore
@testable import AgentAdapters

@MainActor
private func mangia(_ records: [[String: Any]]) -> ClaudeCodeAdapter {
    let adapter = ClaudeCodeAdapter()
    adapter.ingest(lines: records.map { record in
        String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    })
    return adapter
}

/// Un record `assistant` come lo scrive Claude Code: `effort` in cima,
/// `usage` dentro `message`.
private func assistente(input: Int, creation: Int, read: Int, output: Int,
                        effort: String = "high") -> [String: Any] {
    ["type": "assistant", "effort": effort,
     "timestamp": "2026-08-25T20:00:00.000Z",
     "message": ["model": "claude-fable-5", "stop_reason": "tool_use",
                 "content": [[String: Any]](),
                 "usage": ["input_tokens": input,
                           "cache_creation_input_tokens": creation,
                           "cache_read_input_tokens": read,
                           "output_tokens": output,
                           // La ripartizione dei token di ragionamento è
                           // DENTRO `output_tokens`, non accanto: sommarla
                           // conterebbe due volte la stessa cosa. Sta qui
                           // proprio perché il polo la veda e la ignori.
                           "output_tokens_details": ["thinking_tokens": 57]]]]
}

@MainActor
@Test func ilContestoEQuelloDellUltimoRecord() {
    let adapter = mangia([
        assistente(input: 2, creation: 89_329, read: 27_454, output: 280),
        assistente(input: 56, creation: 997, read: 249_720, output: 1_035),
        assistente(input: 101, creation: 1_028, read: 323_942, output: 344),
    ])
    // 101 + 1.028 + 323.942 — l'ULTIMO, non la somma: il contesto è uno
    // stato, e sommarlo sui turni conterebbe dieci volte lo stesso testo
    // riletto dalla cache (qui farebbe 728.629, cioè più del doppio del vero).
    #expect(adapter.contextTokens == 325_071)
}

@MainActor
@Test func lUscitaInveceSiSommaSuTuttaLaSessione() {
    let adapter = mangia([
        assistente(input: 2, creation: 89_329, read: 27_454, output: 280),
        assistente(input: 56, creation: 997, read: 249_720, output: 1_035),
        assistente(input: 101, creation: 1_028, read: 323_942, output: 344),
    ])
    // 280 + 1.035 + 344, e non 344: quello che l'agente ha scritto è una
    // spesa, e una spesa si accumula. E non 1.659 + 57: i token di
    // ragionamento sono già dentro `output_tokens`.
    #expect(adapter.outputTokens == 1_659)
}

@MainActor
@Test func lEffortSiLeggeInCimaAlRecordNonDentroIlMessaggio() {
    let adapter = mangia([assistente(input: 2, creation: 89_329, read: 27_454,
                                     output: 280, effort: "high")])
    #expect(adapter.effort == "high")
}

@MainActor
@Test func unRecordSenzaEffortNonNeInventaUno() {
    // Il polo negativo dell'effort: senza il campo la lettura non c'è, e
    // «non c'è» non è «basso». La barra ci mette un trattino.
    var record = assistente(input: 2, creation: 89_329, read: 27_454, output: 280)
    record.removeValue(forKey: "effort")
    let adapter = mangia([record])
    #expect(adapter.effort == nil)
    // Ma i token li ha letti lo stesso: i due campi sono indipendenti.
    #expect(adapter.contextTokens == 116_785)
}

@MainActor
@Test func unAdattatoreAppenaNatoNonHaLetture() {
    let adapter = ClaudeCodeAdapter()
    #expect(adapter.contextTokens == nil)
    #expect(adapter.outputTokens == nil)
    #expect(adapter.effort == nil)
}

@MainActor
@Test func rewindDimenticaAncheINumeri() {
    // `rewind` significa «sta per arrivare un altro file»: un contesto
    // rimasto dal file di prima sarebbe il numero di un'altra sessione
    // disegnato accanto al nome di questa.
    let adapter = mangia([assistente(input: 101, creation: 1_028, read: 323_942,
                                     output: 344)])
    #expect(adapter.contextTokens == 325_071)
    adapter.rewind()
    #expect(adapter.contextTokens == nil)
    #expect(adapter.outputTokens == nil)
    #expect(adapter.effort == nil)
}

@MainActor
@Test func unRecordDiSottoAgenteNonEntraNelConto() {
    // Un sidechain è un sotto-agente che parla con sé stesso: il suo
    // contesto è il suo, non quello della sessione che stai guardando.
    var sotto = assistente(input: 9, creation: 999_999, read: 999_999, output: 5_000)
    sotto["isSidechain"] = true
    let adapter = mangia([assistente(input: 101, creation: 1_028, read: 323_942,
                                     output: 344), sotto])
    #expect(adapter.contextTokens == 325_071)
    #expect(adapter.outputTokens == 344)
}

@MainActor
@Test func lAltroFornitoreQuestiNumeriNonCeLiHa() {
    // Il polo che rende le frasi qui sopra frasi sul PROTOCOLLO e non su un
    // fornitore: i rollout di Codex non portano né token né sforzo, e
    // l'adattatore lo dice invece di indovinare.
    let codex = CodexAdapter()
    #expect(codex.contextTokens == nil)
    #expect(codex.outputTokens == nil)
    #expect(codex.effort == nil)
}
