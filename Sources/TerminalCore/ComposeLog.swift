//  ComposeLog.swift — l'anello degli ultimi messaggi spediti dalla bolla
//  (ISC-195).
//
//  Il caso che lo fa esistere, 27/08. Un messaggio suo è arrivato a `claude`
//  DOPPIO — «…tu termini il lavoro.Io me ne vado, tu termini il lavoro.» —
//  una volta sola in tutta la storia delle sue chat. Nel codice c'è UN solo
//  punto che invia (`MainWindowController.compose`) e UNA sola scrittura sul
//  pty (`SwiftTermSession.compose`), quindi il difetto non si legge nel
//  sorgente; e non essendo riproducibile non si può nemmeno riparare.
//
//  La lezione è già scritta, e viene da un'altra app della stessa mano: *un componente che butta il
//  proprio INGRESSO non è diagnosticabile, e nessuna bravura recupera il
//  dato*. Là erano quattro rimedi costruiti e bocciati senza mai poter
//  guardare il caso vero. Qui l'ingresso è il testo che è partito, e tenerne
//  gli ultimi venti costa qualche decina di kilobyte.
//
//  Non è un log dell'app: non passa da `NSLog`, non finisce in un referto e
//  non lascia la macchina. È un anello locale con un tetto, che si legge con
//  un `tail` il giorno in cui il difetto ricapita.

import Foundation

/// Gli ultimi messaggi composti, con i byte che sono davvero usciti.
public enum ComposeLog {
    /// Quante composizioni si tengono. Venti coprono una sessione di lavoro
    /// intera senza che il file diventi una cosa da gestire.
    public static let cap = 20
    /// Il tetto in byte, che è la seconda metà del cap: venti messaggi da
    /// mezzo mega sarebbero venti righe e dieci megabyte.
    public static let byteCap = 1_048_576

    /// Dove vive l'anello. `T4A_COMPOSE_LOG` lo dirotta, e non è una comodità:
    /// una sonda che scrive nel registro VERO è un registro inquinato dalle
    /// sue stesse prove — 118 sessioni su 119 di un altro registro di questa
    /// casa erano corse di banco. Una sonda riceve il suo path dall'ambiente.
    public static var file: URL {
        if let named = ProcessInfo.processInfo.environment["T4A_COMPOSE_LOG"],
           !named.isEmpty {
            return URL(fileURLWithPath: named)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/t4a/compose.jsonl")
    }

    /// Le righe da tenere: le ultime `cap`, e poi, se sfondano il tetto in
    /// byte, si scartano le più vecchie finché ci stanno.
    ///
    /// Pura di proposito — nessun disco, nessun orologio — così il taglio si
    /// prova senza scrivere niente da nessuna parte.
    public static func trim(_ lines: [String], cap: Int = cap,
                            byteCap: Int = byteCap) -> [String] {
        var kept = Array(lines.suffix(max(0, cap)))
        while kept.count > 1,
              kept.reduce(0, { $0 + $1.utf8.count + 1 }) > byteCap {
            kept.removeFirst()
        }
        return kept
    }

    /// Una riga di anello. `written` è l'esito della scrittura sul pty, non
    /// la nostra intenzione: una scrittura fallita a metà è esattamente il
    /// genere di cosa che questo file esiste per far vedere.
    ///
    /// Il path arriva come PARAMETRO e non solo dall'ambiente, ed è una
    /// riparazione pagata subito: due prove che si scambiavano `setenv` in
    /// parallelo hanno lasciato 2 righe su 25, perché l'ambiente è del
    /// processo e i test girano insieme. Un default che legge l'ambiente
    /// resta comodo per l'app; una prova passa il suo file e non condivide
    /// niente con nessuno.
    public static func record(text: String, bytes: Int, bracketed: Bool,
                              written: Bool, now: Date = Date(),
                              to destination: URL? = nil) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: now),
            "chars": text.count,
            "bytes": bytes,
            "bracketed": bracketed,
            "written": written,
            "text": text,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry,
                                                     options: [.withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = destination ?? file
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        let kept = trim(existing + [line])
        try? (kept.joined(separator: "\n") + "\n").write(to: url, atomically: true,
                                                         encoding: .utf8)
    }
}
