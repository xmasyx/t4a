//  WrittenFile.swift — da un percorso qualunque a un percorso che si apre.
//
//  Vive fuori dai due adattatori perché tutti e due ne hanno bisogno e la
//  regola è una sola: un percorso relativo si risolve sulla cartella in cui
//  l'agente stava lavorando, un percorso assoluto si lascia stare, e la tilde
//  è casa. Riscritta due volte sarebbe due funzioni che divergono in silenzio,
//  che è il difetto pagato il 2026-08-05 sugli elenchi del compendio.
//
//  QUELLO CHE NON FA, ed è deliberato: non guarda il disco. Se il file esiste
//  è una domanda che si fa al momento del click e non al momento della
//  lettura del transcript — un file scritto e poi cancellato deve restare un
//  link che dice «non è più sul disco», non un link che non è mai nato
//  (ISC-176).

import Foundation

enum WrittenFile {
    /// Il percorso assoluto di `raw`, risolto su `cwd` quando è relativo.
    ///
    /// Torna `nil` su una stringa vuota e su una che non è un percorso — e
    /// torna `nil` anche su un relativo senza `cwd`, perché mezzo percorso
    /// aperto sulla cartella sbagliata è peggio di nessun link: apre il file
    /// di qualcun altro con lo stesso nome.
    static func absolute(_ raw: String?, cwd: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return (raw as NSString).standardizingPath }
        if raw.hasPrefix("~") { return (raw as NSString).expandingTildeInPath }
        guard let cwd, !cwd.isEmpty else { return nil }
        return ((cwd as NSString).appendingPathComponent(raw) as NSString)
            .standardizingPath
    }
}
