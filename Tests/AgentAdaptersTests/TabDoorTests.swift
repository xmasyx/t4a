//  TabDoorTests.swift — la porta: una scheda che si apre da fuori (ISC-211/213).
//
//  Questo file fissa la FIRMA di `TabDoor` prima che il corpo esista: il
//  parser è puro (nessun disco, nessuna finestra) così le regole di
//  accettazione si provano senza aprire una scheda. Il polo che conta è
//  quello che RIFIUTA: una richiesta malformata non deve mai diventare una
//  scheda con un comando dentro.
//
//  Il contratto sul disco, che il banco vivo (`Scripts/bench-door.sh`) misura:
//
//    <cartella della porta>/<nome>.open.json   {"cwd": "...", "command": "...", "label": "..."}
//      → l'app apre una scheda in `cwd`, scrive `command` nella shell e lo
//        esegue, poi risponde con <nome>.opened.json {"session": "<uuid>"}
//        e cancella la richiesta. Malformata → <nome>.rejected.json
//        {"reason": "..."} e nessuna scheda.
//    <cartella della porta>/<nome>.close.json  {"session": "<uuid>"}
//      → l'app chiude quel pannello SOLO se non interromperebbe niente e
//        risponde con <nome>.closed.json {"closed": true} oppure
//        {"closed": false, "reason": "working" | "unknown"}. Mai un foglio
//        di conferma: la richiesta viene da un programma.
//
//  La cartella: `$T4A_DOOR` se c'è, altrimenti `~/.cache/t4a/door`. È un
//  file e non un link `t4a://` perché un link lo apre anche una pagina web.

import Foundation
import TerminalCore
import Testing

private func directoryExists(_ path: String) -> Bool {
    path == "/tmp/door-cwd" || path == "/"
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - I nomi dei file

@Test func unaRichiestaDiAperturaSiRiconosceDalNome() {
    let f = TabDoor.kind(ofFile: "tappa-uno.open.json")
    #expect(f?.name == "tappa-uno")
    #expect(f?.kind == .open)
}

@Test func unaRichiestaDiChiusuraSiRiconosceDalNome() {
    let f = TabDoor.kind(ofFile: "tappa-uno.close.json")
    #expect(f?.name == "tappa-uno")
    #expect(f?.kind == .close)
}

@Test func leRisposteEGliAltriFileNonSonoRichieste() {
    #expect(TabDoor.kind(ofFile: "tappa-uno.opened.json") == nil)
    #expect(TabDoor.kind(ofFile: "tappa-uno.rejected.json") == nil)
    #expect(TabDoor.kind(ofFile: "tappa-uno.closed.json") == nil)
    #expect(TabDoor.kind(ofFile: ".DS_Store") == nil)
    #expect(TabDoor.kind(ofFile: "note.txt") == nil)
}

@Test func unNomeFuoriDalCharsetNonEUnaRichiesta() {
    #expect(TabDoor.isValidName("tappa-uno") == true)
    #expect(TabDoor.isValidName("20260828.door_1") == true)
    #expect(TabDoor.isValidName("") == false)
    #expect(TabDoor.isValidName(".") == false)
    #expect(TabDoor.isValidName("..") == false)
    #expect(TabDoor.isValidName("con spazio") == false)
    #expect(TabDoor.isValidName("su/cartella") == false)
    #expect(TabDoor.kind(ofFile: "con spazio.open.json") == nil)
    #expect(TabDoor.kind(ofFile: "../fuori.open.json") == nil)
}

// MARK: - L'apertura

@Test func unaRichiestaValidaDiventaUnaTabRequest() {
    let data = json(["cwd": "/tmp/door-cwd", "command": "echo ciao", "label": "Tappa uno"])
    let result = TabDoor.parseOpen(name: "tappa-uno", data: data, isDirectory: directoryExists)
    #expect(result == .success(TabRequest(name: "tappa-uno", cwd: "/tmp/door-cwd",
                                          command: "echo ciao", label: "Tappa uno")))
}

@Test func lEtichettaEFacoltativa() {
    let data = json(["cwd": "/tmp/door-cwd", "command": "echo ciao"])
    let result = TabDoor.parseOpen(name: "tappa-uno", data: data, isDirectory: directoryExists)
    #expect(result == .success(TabRequest(name: "tappa-uno", cwd: "/tmp/door-cwd",
                                          command: "echo ciao", label: nil)))
}

@Test func unaCartellaCheNonEsisteVieneRifiutata() {
    let data = json(["cwd": "/nessuna/cartella", "command": "echo ciao"])
    let result = TabDoor.parseOpen(name: "tappa-uno", data: data, isDirectory: directoryExists)
    #expect(result == .failure(.noSuchDirectory))
}

@Test func unaCartellaRelativaVieneRifiutata() {
    let data = json(["cwd": "tmp/door-cwd", "command": "echo ciao"])
    let result = TabDoor.parseOpen(name: "tappa-uno", data: data, isDirectory: { _ in true })
    #expect(result == .failure(.noSuchDirectory))
}

@Test func unCampoMancanteVieneNominato() {
    let senzaComando = json(["cwd": "/tmp/door-cwd"])
    #expect(TabDoor.parseOpen(name: "t", data: senzaComando, isDirectory: directoryExists)
            == .failure(.missing("command")))
    let senzaCartella = json(["command": "echo ciao"])
    #expect(TabDoor.parseOpen(name: "t", data: senzaCartella, isDirectory: directoryExists)
            == .failure(.missing("cwd")))
}

@Test func unComandoVuotoVieneRifiutato() {
    let data = json(["cwd": "/tmp/door-cwd", "command": "   \n"])
    #expect(TabDoor.parseOpen(name: "t", data: data, isDirectory: directoryExists)
            == .failure(.emptyCommand))
}

@Test func unComandoSuPiuRigheVieneRifiutato() {
    // Una riga sola: un secondo a-capo sarebbe un secondo Invio, cioè un
    // secondo comando che nessuno ha chiesto.
    let data = json(["cwd": "/tmp/door-cwd", "command": "echo uno\necho due"])
    #expect(TabDoor.parseOpen(name: "t", data: data, isDirectory: directoryExists)
            == .failure(.multilineCommand))
}

@Test func unComandoOltreIlTettoVieneRifiutato() {
    let lungo = String(repeating: "x", count: TabDoor.commandByteCap + 1)
    let data = json(["cwd": "/tmp/door-cwd", "command": lungo])
    #expect(TabDoor.parseOpen(name: "t", data: data, isDirectory: directoryExists)
            == .failure(.commandTooLong))
    let alTetto = String(repeating: "x", count: TabDoor.commandByteCap)
    let ok = TabDoor.parseOpen(name: "t", data: json(["cwd": "/tmp/door-cwd", "command": alTetto]),
                               isDirectory: directoryExists)
    #expect(ok == .success(TabRequest(name: "t", cwd: "/tmp/door-cwd", command: alTetto, label: nil)))
}

@Test func unEtichettaOltreIlTettoVieneRifiutata() {
    let lunga = String(repeating: "e", count: TabDoor.labelCap + 1)
    let data = json(["cwd": "/tmp/door-cwd", "command": "echo ciao", "label": lunga])
    #expect(TabDoor.parseOpen(name: "t", data: data, isDirectory: directoryExists)
            == .failure(.labelTooLong))
}

@Test func unEtichettaVuotaValeComeAssente() {
    let data = json(["cwd": "/tmp/door-cwd", "command": "echo ciao", "label": "  "])
    #expect(TabDoor.parseOpen(name: "t", data: data, isDirectory: directoryExists)
            == .success(TabRequest(name: "t", cwd: "/tmp/door-cwd", command: "echo ciao", label: nil)))
}

@Test func unFileCheNonEJsonVieneRifiutato() {
    #expect(TabDoor.parseOpen(name: "t", data: Data("non json".utf8), isDirectory: directoryExists)
            == .failure(.notJSON))
    #expect(TabDoor.parseOpen(name: "t", data: Data("[1,2]".utf8), isDirectory: directoryExists)
            == .failure(.notJSON))
}

@Test func unNomeFuoriDalCharsetVieneRifiutatoAncheDalParser() {
    let data = json(["cwd": "/tmp/door-cwd", "command": "echo ciao"])
    #expect(TabDoor.parseOpen(name: "con spazio", data: data, isDirectory: directoryExists)
            == .failure(.badName))
}

// MARK: - La chiusura

@Test func unaChiusuraPortaLaSessione() {
    let id = UUID()
    let data = json(["session": id.uuidString])
    #expect(TabDoor.parseClose(data: data) == id)
}

@Test func unaChiusuraSenzaSessioneValidaENulla() {
    #expect(TabDoor.parseClose(data: json(["session": "non-un-uuid"])) == nil)
    #expect(TabDoor.parseClose(data: json(["altro": 1])) == nil)
    #expect(TabDoor.parseClose(data: Data("x".utf8)) == nil)
}

// MARK: - La cartella

@Test func laCartellaDellaPortaSiDirottaDallAmbiente() {
    let dirottata = TabDoor.directory(environment: ["T4A_DOOR": "/tmp/porta-di-prova"], home: "/Users/example")
    #expect(dirottata.path == "/tmp/porta-di-prova")
    let normale = TabDoor.directory(environment: [:], home: "/Users/example")
    #expect(normale.path == "/Users/example/.cache/t4a/door")
    let vuota = TabDoor.directory(environment: ["T4A_DOOR": ""], home: "/Users/example")
    #expect(vuota.path == "/Users/example/.cache/t4a/door")
}

// MARK: - Le risposte

@Test func leRisposteHannoIlNomeDellaRichiesta() {
    #expect(TabDoor.replyFileName(for: "tappa-uno", reply: .opened) == "tappa-uno.opened.json")
    #expect(TabDoor.replyFileName(for: "tappa-uno", reply: .rejected) == "tappa-uno.rejected.json")
    #expect(TabDoor.replyFileName(for: "tappa-uno", reply: .closed) == "tappa-uno.closed.json")
}
