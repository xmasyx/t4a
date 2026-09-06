//  TranscriptSearchTests.swift — finding words the alternate screen forgot.

import Foundation
import TerminalCore
import Testing

private func turn(_ id: Int, prompt: String = "", answer: String = "",
                  steps: [AgentStep] = []) -> AgentTurn {
    AgentTurn(id: id, prompt: prompt, answer: answer, steps: steps,
              startedAt: Date(timeIntervalSince1970: Double(id)))
}

@Test func trovaDomandaRispostaEDettaglioDelPasso() {
    let step = AgentStep(id: "tool-7", kind: .tool, title: "Bash · echo",
                         detail: "printed tantalio to the terminal")
    let turns = [turn(1, prompt: "cerca zirconio"),
                 turn(2, answer: "qui c’è zirconio"),
                 turn(3, steps: [step])]

    let result = TranscriptSearch.find(SearchRequest(text: "zirconio"), in: turns)
    #expect(result.hits.map(\.place) == [.prompt, .answer])
    #expect(result.hits.map(\.turnID) == [1, 2])

    let stepResult = TranscriptSearch.find(SearchRequest(text: "tantalio"), in: turns)
    #expect(stepResult.hits.count == 1)
    #expect(stepResult.hits.first?.place == .step)
    #expect(stepResult.hits.first?.stepID == "tool-7")
    let field = step.title + "\n" + step.detail
    #expect(stepResult.hits.first.map { (field as NSString).substring(with: $0.range) } == "tantalio")
}

@Test func smartCaseSegueLeMaiuscoleDellaRichiesta() {
    let turns = [turn(1, prompt: "Harbour harbour")]
    #expect(TranscriptSearch.find(SearchRequest(text: "Harbour"), in: turns).hits.count == 1)
    #expect(TranscriptSearch.find(SearchRequest(text: "harbour"), in: turns).hits.count == 2)
}

@Test func accettaUnaEspressioneRegolare() {
    let request = SearchRequest(text: "zircon(?:io|ium)", mode: .regex)
    let result = TranscriptSearch.find(request,
                                       in: [turn(1, answer: "zirconio e zirconium")])
    #expect(result.hits.count == 2)
}

@Test func unaParolaAssenteNonProduceColpi() {
    let result = TranscriptSearch.find(SearchRequest(text: "zirconio"),
                                       in: [turn(1, prompt: "rame")])
    #expect(result.hits.isEmpty)
    #expect(!result.truncated)
}

@Test func ilLimiteDichiaraIlRisultatoTroncato() {
    let result = TranscriptSearch.find(SearchRequest(text: "x"),
                                       in: [turn(1, prompt: "x x x")], limit: 2)
    #expect(result.hits.count == 2)
    #expect(result.truncated)
}

@Test func ilFrammentoContieneIlColpoSuUnaRigaSola() {
    let prompt = String(repeating: "a", count: 80) + "\nzirconio\n"
        + String(repeating: "b", count: 80)
    let result = TranscriptSearch.find(SearchRequest(text: "zirconio"),
                                       in: [turn(1, prompt: prompt)])
    #expect(result.hits.count == 1)
    #expect(result.hits[0].excerpt.contains("zirconio"))
    #expect(!result.hits[0].excerpt.contains("\n"))
    #expect(result.hits[0].excerpt.count <= 70)
}

@Test func conservaOrdineDeiTurniEPosizioneNelCampo() {
    let turns = [turn(9, prompt: "zirconio poi zirconio"),
                 turn(3, prompt: "zirconio")]
    let hits = TranscriptSearch.find(SearchRequest(text: "zirconio"), in: turns).hits
    #expect(hits.map(\.turnID) == [9, 9, 3])
    #expect(hits[0].range.location < hits[1].range.location)
}
