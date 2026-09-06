//  ComposeLogTests.swift — l'anello degli invii (ISC-195).
//
//  Il polo che conta è `unaSolaRigaSopravviveAlTettoPiuStretto`: un anello che
//  taglia troppo è la prova che non avrai il giorno in cui il difetto ricapita,
//  e il messaggio lungo è proprio quello che quel giorno vorrai leggere.

import Foundation
import TerminalCore
import Testing

@Test func lAnelloTieneLeUltimeVenti() {
    let righe = (1...25).map { "riga \($0)" }
    let tenute = ComposeLog.trim(righe)
    #expect(tenute.count == 20)
    #expect(tenute.first == "riga 6")
    #expect(tenute.last == "riga 25")
}

@Test func sottoIlCapNonSiButtaNiente() {
    let righe = ["a", "b", "c"]
    #expect(ComposeLog.trim(righe) == righe)
}

@Test func ilTettoInByteScartaLePiuVecchie() {
    let righe = (1...3).map { _ in String(repeating: "x", count: 100) }
    #expect(ComposeLog.trim(righe, cap: 20, byteCap: 250).count == 2)
}

@Test func unaSolaRigaSopravviveAlTettoPiuStretto() {
    let righe = [String(repeating: "y", count: 5000)]
    #expect(ComposeLog.trim(righe, cap: 20, byteCap: 100).count == 1)
}

@Test func laRigaScrittaPortaTestoEByte() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t4a-compose-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("compose.jsonl")
    defer { try? FileManager.default.removeItem(at: dir) }

    ComposeLog.record(text: "ciao mondo", bytes: 22, bracketed: true, written: true,
                      to: file)
    let riga = try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n").map(String.init).last ?? ""
    let json = try JSONSerialization.jsonObject(with: Data(riga.utf8)) as? [String: Any]
    #expect(json?["text"] as? String == "ciao mondo")
    #expect(json?["bytes"] as? Int == 22)
    #expect(json?["bracketed"] as? Bool == true)
    #expect(json?["chars"] as? Int == 10)
}

@Test func venticinqueScrittureLascianoVentiRighe() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t4a-compose-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("compose.jsonl")
    defer { try? FileManager.default.removeItem(at: dir) }

    for i in 1...25 {
        ComposeLog.record(text: "messaggio \(i)", bytes: 10, bracketed: false,
                          written: true, to: file)
    }
    let righe = try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n").map(String.init)
    #expect(righe.count == 20)
    #expect(righe.first?.contains("messaggio 6") == true)
    #expect(righe.last?.contains("messaggio 25") == true)
}
