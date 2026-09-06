//  WrittenFileTests.swift — un passo che ha scritto un file porta il suo
//  percorso, e solo lui (ISC-175).
//
//  I poli sono quelli scritti nella claim, e il terzo è il polo negativo che
//  dà un senso ai primi due: se `filePath` fosse riempito da tutto, «il
//  percorso c'è» sarebbe una frase che produce anche un adattatore rotto.
//  `Read` è nel banco per la stessa ragione — porta lo stesso `file_path` dei
//  suoi fratelli, quindi è il caso in cui è facile sbagliare, ed è la
//  decisione di prodotto che questo file inchioda.
//
//  I record sono nella forma vera dei transcript, `cwd` in cima compreso: è da
//  lì che si risolve un percorso relativo, e ricostruirlo altrove sarebbe
//  misurare la mia ricostruzione invece del loro formato.

import Foundation
import Testing
import TerminalCore
@testable import AgentAdapters

@MainActor
private func ingest(_ records: [[String: Any]]) -> ClaudeCodeAdapter {
    let adapter = ClaudeCodeAdapter()
    adapter.ingest(lines: records.map { record in
        String(decoding: try! JSONSerialization.data(withJSONObject: record),
               as: UTF8.self)
    })
    return adapter
}

private func assistant(_ blocks: [[String: Any]],
                       cwd: String = "/tmp/t4a-unit") -> [String: Any] {
    ["type": "assistant", "timestamp": "2026-08-26T10:00:00.000Z", "cwd": cwd,
     "message": ["model": "claude-haiku-4-5-20251001", "stop_reason": "tool_use",
                 "content": blocks]]
}

private func tool(_ name: String, _ input: [String: Any],
                  id: String = "t1") -> [String: Any] {
    ["type": "tool_use", "id": id, "name": name, "input": input]
}

@MainActor
private func step(_ adapter: ClaudeCodeAdapter, _ id: String) -> AgentStep? {
    adapter.turns.flatMap(\.steps).first { $0.id == id }
}

@Test @MainActor func unWriteConPercorsoAssolutoPortaQuelPercorso() {
    let adapter = ingest([assistant([
        tool("Write", ["file_path": "/tmp/t4a-preview/nota.md", "content": "ciao"]),
    ])])
    #expect(step(adapter, "t1")?.filePath == "/tmp/t4a-preview/nota.md")
    #expect(step(adapter, "t1")?.fileName == "nota.md")
}

@Test @MainActor func unEditPortaIlSuoPercorso() {
    let adapter = ingest([assistant([
        tool("Edit", ["file_path": "/tmp/t4a-preview/README.md",
                      "old_string": "a", "new_string": "b"]),
    ])])
    #expect(step(adapter, "t1")?.filePath == "/tmp/t4a-preview/README.md")
}

@Test @MainActor func unBashNonPortaNessunPercorso() {
    let adapter = ingest([assistant([
        tool("Bash", ["command": "cupsfilter nota.md > nota.pdf"]),
    ])])
    #expect(step(adapter, "t1")?.filePath == nil)
}

/// Il polo che tiene il confine: `Read` porta lo stesso `file_path` di `Write`
/// e NON deve diventare un link. Senza di lui ogni riga della pagina sarebbe
/// un link, e un link su tutto non è più un link.
@Test @MainActor func unReadNonPortaNessunPercorso() {
    let adapter = ingest([assistant([
        tool("Read", ["file_path": "/tmp/t4a-preview/Package.swift"]),
    ])])
    #expect(step(adapter, "t1")?.filePath == nil)
}

@Test @MainActor func unPercorsoRelativoSiRisolveSulCwdDellaSessione() {
    let adapter = ingest([assistant([
        tool("Write", ["file_path": "docs/nota.md", "content": "ciao"]),
    ], cwd: "/tmp/t4a-unit/progetto")])
    #expect(step(adapter, "t1")?.filePath == "/tmp/t4a-unit/progetto/docs/nota.md")
}

/// Senza `cwd` un relativo NON diventa un percorso: mezzo percorso risolto
/// sulla cartella sbagliata apre il file di qualcun altro con lo stesso nome,
/// che è peggio di nessun link.
@Test @MainActor func unRelativoSenzaCwdNonDiventaUnPercorso() {
    #expect(WrittenFile.absolute("docs/nota.md", cwd: nil) == nil)
    #expect(WrittenFile.absolute("docs/nota.md", cwd: "") == nil)
}

@Test @MainActor func laTildeEcasa() {
    let risolto = WrittenFile.absolute("~/nota.md", cwd: "/altrove")
    #expect(risolto == NSHomeDirectory() + "/nota.md")
}

@Test @MainActor func notebookEditUsaIlSuoNomeDiCampo() {
    let adapter = ingest([assistant([
        tool("NotebookEdit", ["notebook_path": "/tmp/t4a-preview/a.ipynb",
                              "new_source": "1+1"]),
    ])])
    #expect(step(adapter, "t1")?.filePath == "/tmp/t4a-preview/a.ipynb")
}

// MARK: - Codex

@MainActor
private func codex(_ records: [[String: Any]]) -> CodexAdapter {
    let adapter = CodexAdapter()
    adapter.ingest(lines: records.map { record in
        String(decoding: try! JSONSerialization.data(withJSONObject: record),
               as: UTF8.self)
    })
    return adapter
}

private func meta(_ cwd: String) -> [String: Any] {
    ["type": "session_meta", "timestamp": "2026-08-26T10:00:00.000Z",
     "payload": ["cwd": cwd, "model": "gpt-5-codex"]]
}

private func chiamata(_ name: String, _ arguments: String,
                      id: String = "c1") -> [String: Any] {
    ["type": "response_item", "timestamp": "2026-08-26T10:00:01.000Z",
     "payload": ["type": "function_call", "name": name, "call_id": id,
                 "arguments": arguments]]
}

@Test @MainActor func codexApplyPatchPortaIlFileDellaPatch() {
    let patch = """
    *** Begin Patch
    *** Update File: Sources/T4A/Theme.swift
    @@
    -uno
    +due
    *** End Patch
    """
    let adapter = codex([meta("/tmp/t4a-unit/progetto"),
                         chiamata("apply_patch", patch)])
    let passo = adapter.turns.flatMap(\.steps).first { $0.id == "c1" }
    #expect(passo?.filePath == "/tmp/t4a-unit/progetto/Sources/T4A/Theme.swift")
}

/// `*** Move to:` vince, perché la destinazione è il file che dopo la patch
/// esiste davvero.
@Test @MainActor func codexPreferisceLaDestinazioneDiUnoSpostamento() {
    let patch = """
    *** Begin Patch
    *** Update File: vecchio.md
    *** Move to: nuovo.md
    *** End Patch
    """
    #expect(CodexAdapter.patchTarget(in: patch) == "nuovo.md")
}

/// Una cancellazione non produce un link: si aprirebbe solo per dire che il
/// file non c'è più.
@Test @MainActor func codexNonCollegaUnaCancellazione() {
    let patch = """
    *** Begin Patch
    *** Delete File: andato.md
    *** End Patch
    """
    #expect(CodexAdapter.patchTarget(in: patch) == nil)
}

@Test @MainActor func codexNonCollegaUnaLettura() {
    let adapter = codex([meta("/tmp/t4a-unit/progetto"),
                         chiamata("read_file", #"{"path":"nota.md"}"#)])
    #expect(adapter.turns.flatMap(\.steps).first { $0.id == "c1" }?.filePath == nil)
}

@Test @MainActor func codexCollegaUnoStrumentoCheScrive() {
    let adapter = codex([meta("/tmp/t4a-unit/progetto"),
                         chiamata("write_file", #"{"path":"nota.md"}"#)])
    #expect(adapter.turns.flatMap(\.steps).first { $0.id == "c1" }?.filePath
            == "/tmp/t4a-unit/progetto/nota.md")
}
