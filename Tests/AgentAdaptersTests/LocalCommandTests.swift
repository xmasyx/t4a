//  LocalCommandTests.swift — un comando locale non è una frase detta
//  all'agente, e la sua uscita non è una domanda nuova.
//
//  Il caso vero, visto da lui il 26/08 cambiando modello: la pagina della chat
//  mostrava `<command-name>/model</command-name>` come domanda, poi
//  `<local-command-stdout>Set model to [1mFable 5[22m…` come SECONDA domanda,
//  coi codici di colore del terminale in mezzo, e la sessione si ribattezzava
//  «Set model to…». Erano due turni dove ce n'è uno.
//
//  Il polo negativo è l'ultimo: una frase normale non deve diventare un
//  comando. Senza, «riconosce i comandi» sarebbe una frase vera anche per un
//  lettore che chiama comando qualunque cosa.

import Foundation
import Testing
import TerminalCore
@testable import AgentAdapters

@MainActor
private func ingest(_ records: [[String: Any]]) -> ClaudeCodeAdapter {
    let adapter = ClaudeCodeAdapter()
    adapter.ingest(lines: records.map {
        String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    })
    return adapter
}

private let bustaModel = """
<command-name>/model</command-name>
            <command-message>model</command-message>
            <command-args></command-args>
"""

@MainActor
@Test func ilCommandoLocaleSiLeggeComeLaRigaCheHaiScritto() {
    #expect(ClaudeCodeAdapter.comandoLocale(bustaModel) == .comando("/model"))

    let conArgomenti = """
    <command-name>/model</command-name>
                <command-message>model</command-message>
                <command-args>opus</command-args>
    """
    #expect(ClaudeCodeAdapter.comandoLocale(conArgomenti) == .comando("/model opus"))
}

@MainActor
@Test func lUscitaDiUnComandoPerdeICodiciDiColore() {
    let uscita = "<local-command-stdout>Set model to \u{1B}[1mFable 5\u{1B}[22m"
        + " and saved as your default for new sessions</local-command-stdout>"
    #expect(ClaudeCodeAdapter.comandoLocale(uscita)
            == .uscita("Set model to Fable 5 and saved as your default for new sessions"))
    // Il pulitore da solo, sui due casi che il terminale produce davvero.
    #expect(ClaudeCodeAdapter.senzaCodici("\u{1B}[1mgrassetto\u{1B}[22m") == "grassetto")
    #expect(ClaudeCodeAdapter.senzaCodici("niente da togliere") == "niente da togliere")
}

@MainActor
@Test func lAvvertenzaDiClaudeCodeNonSiMostra() {
    let caveat = "<local-command-caveat>Caveat: The messages below were generated"
        + " by the user while running local commands.</local-command-caveat>"
    #expect(ClaudeCodeAdapter.comandoLocale(caveat) == .rumore)
    #expect(ClaudeCodeAdapter.comandoLocale("<local-command-stdout></local-command-stdout>")
            == .rumore)
}

@MainActor
@Test func unaFraseNormaleNonDiventaUnComando() {
    #expect(ClaudeCodeAdapter.comandoLocale("ripara il notch") == .nessuno)
    // Una frase che PARLA di un comando resta una frase: il riconoscimento sta
    // nella busta, non nella barra.
    #expect(ClaudeCodeAdapter.comandoLocale("usa /model per cambiare modello") == .nessuno)
}

@MainActor
@Test func ilComandoELaSuaUscitaSonoUnTurnoSolo() {
    let adapter = ingest([
        ["type": "user", "timestamp": "2026-08-26T14:41:00.000Z",
         "message": ["content": bustaModel]],
        ["type": "user", "timestamp": "2026-08-26T14:41:00.156Z",
         "message": ["content": "<local-command-stdout>Set model to \u{1B}[1mFable 5\u{1B}[22m"
                     + " and saved as your default for new sessions</local-command-stdout>"]],
    ])

    #expect(adapter.turns.count == 1)
    let turn = adapter.turns[0]
    #expect(turn.prompt == "/model")
    #expect(turn.answer == "Set model to Fable 5 and saved as your default for new sessions")
    #expect(turn.isLocalCommand)
    // E il turno è CHIUSO: senza, la pagina scriveva «sta ancora lavorando»
    // sotto un comando che aveva già risposto.
    #expect(!turn.isOpen)
    // Niente markup e niente codici di colore in quello che si legge.
    #expect(!turn.prompt.contains("<"))
    #expect(!turn.answer.contains("\u{1B}"))
    #expect(!turn.answer.contains("[1m"))
}

@MainActor
@Test func unaDomandaVeraDopoUnComandoRestaUnTurnoSuo() {
    let adapter = ingest([
        ["type": "user", "timestamp": "2026-08-26T14:41:00.000Z",
         "message": ["content": bustaModel]],
        ["type": "user", "timestamp": "2026-08-26T14:41:00.156Z",
         "message": ["content": "<local-command-stdout>Set model to Fable 5</local-command-stdout>"]],
        ["type": "user", "timestamp": "2026-08-26T14:42:00.000Z",
         "message": ["content": "adesso ripara il notch"]],
    ])

    #expect(adapter.turns.count == 2)
    #expect(adapter.turns[1].prompt == "adesso ripara il notch")
    #expect(!adapter.turns[1].isLocalCommand)
}
