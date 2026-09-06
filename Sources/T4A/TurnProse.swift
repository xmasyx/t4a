//  TurnProse.swift — un turno messo in pagina, una volta sola.
//
//  Due superfici mostrano gli stessi turni: la pagina della chat, che sta
//  dentro il pannello, e il lettore che si apre da un turno della colonna di
//  destra quando la pagina è spenta. Se ognuna si disegnasse la sua, il
//  giorno che cambia un'etichetta ne cambierebbe una sola, e la differenza
//  non la vedrebbe nessun test: la si vedrebbe lui, in un posto e non
//  nell'altro. Quindi la forma di un turno vive qui.
//
//  La regola che questo file mette in pratica, ed è sua: la RISPOSTA si vede
//  sempre intera; il lavoro (il ragionamento, il testo scritto per arrivarci,
//  il codice degli strumenti) sta in blocchi che si aprono a richiesta.

import AppKit
import TerminalCore

@MainActor
enum TurnProse {
    /// Dove sta la riga cliccabile di un blocco, nel testo appena composto.
    struct Riga {
        let range: NSRange
        let stepID: String
        let turnID: Int
    }

    /// Il nome di un file scritto dall'agente, dentro la riga di un blocco
    /// (ISC-175). È un bersaglio DENTRO un altro bersaglio: la riga apre il
    /// blocco, queste lettere aprono l'anteprima.
    struct Collegamento {
        let range: NSRange
        let stepID: String
        let path: String
    }

    /// A transcript field beside the range where that field was rendered.
    /// Search ranges are relative to the original field, while Markdown and
    /// step furniture can change the length on the page; keeping both sides is
    /// what lets the reader reveal the word the search actually found.
    struct Campo {
        let place: TranscriptHit.Place
        let stepID: String?
        let source: String
        let sourceRange: NSRange
        let renderedRange: NSRange
    }

    /// Il risultato di una composizione: cosa si disegna, cosa si legge in
    /// chiaro (per i banchi), e dove si clicca.
    struct Pagina {
        var testo = NSMutableAttributedString()
        var chiaro = ""
        var righe: [Riga] = []
        var collegamenti: [Collegamento] = []
        var campi: [Campo] = []
        /// Dove comincia ogni turno, per portarcisi sopra da fuori.
        var inizioTurno: [Int: Int] = [:]
    }

    /// Quali blocchi di un turno sono già aperti quando ci arrivi sopra.
    ///
    /// «Apri quello per cui saresti venuto»: se un passo è fallito, quello,
    /// perché è la ragione per cui si guarda un turno andato storto; se ce
    /// n'è uno solo con qualcosa dentro, quello, perché chiedere un click per
    /// scegliere fra una cosa sola è cerimonia. Altrimenti tutto chiuso, e la
    /// scelta è tua: è il motivo per cui questa vista esiste.
    static func daAprireSubito(_ turn: AgentTurn) -> Set<String> {
        let pieni = turn.steps.filter { !$0.detail.isEmpty }
        if let rotto = pieni.first(where: { $0.isError }) { return [rotto.id] }
        if pieni.count == 1, let solo = pieni.first { return [solo.id] }
        return []
    }

    /// L'identità della riga che riassume il lavoro di un turno. Non è un
    /// passo vero, ed è apposta: vive nello stesso insieme degli aperti, così
    /// il click che apre un blocco e quello che apre il gruppo sono lo stesso
    /// meccanismo, e non ne nasce un secondo da tenere allineato.
    static func idGruppo(_ turn: AgentTurn) -> String { "gruppo-\(turn.id)" }

    /// I passi che si disegnano davvero.
    ///
    /// Mentre il turno è aperto, il testo che sta scrivendo è già «la
    /// risposta» in fondo: mostrarlo anche come blocco lo scrive due volte.
    /// Alla chiusura del turno l'adattatore lo toglie da sé.
    static func mostrati(_ turn: AgentTurn) -> [AgentStep] {
        turn.steps.filter { passo in
            !(passo.kind == .note
              && (passo.detail == turn.answer
                  || turn.followUps.contains(where: { $0.answer == passo.detail })))
        }
    }

    /// Mette in pagina uno o più turni, in ordine.
    ///
    /// `attesa` arriva dalla riga viva di `claude`: mentre una risposta è
    /// ancora vuota si mostra la sua frase esatta, non una nostra imitazione.
    /// Il ripiego `…` serve ai fornitori e alle fixture che non disegnano una
    /// riga animata; una risposta chiusa continua invece a dire esplicitamente
    /// che non è stata scritta (ISC-229).
    static func componi(turns: [AgentTurn], aperti: Set<String>,
                        attesa: String? = nil, conCapo: Bool = true) -> Pagina {
        var pagina = Pagina()
        for (indice, turn) in turns.enumerated() {
            if indice > 0 { aggiungi(&pagina, "\n", .separatore) }
            pagina.inizioTurno[turn.id] = pagina.testo.length
            componi(turn, in: &pagina, aperti: aperti, attesa: attesa,
                    conCapo: conCapo)
        }
        return pagina
    }

    private static func componi(_ turn: AgentTurn, in pagina: inout Pagina,
                                aperti: Set<String>, attesa: String?, conCapo: Bool) {
        if conCapo {
            let fallito = turn.failed ? S.turnFailed : ""
            aggiungi(&pagina, S.turnNumber(id: turn.id) + fallito + durata(turn) + "\n",
                     .etichetta)
            aggiungi(&pagina, "\n", .etichetta)
        }

        aggiungi(&pagina, S.turnYouAsked + "\n", .etichetta)
        let domanda = turn.prompt.isEmpty ? S.turnWithoutQuestion : turn.prompt
        let inizioDomanda = pagina.testo.length
        aggiungi(&pagina, domanda + "\n\n", .domanda)
        if !turn.prompt.isEmpty {
            pagina.campi.append(Campo(
                place: .prompt, stepID: nil, source: turn.prompt,
                sourceRange: NSRange(location: 0, length: turn.prompt.utf16.count),
                renderedRange: NSRange(location: inizioDomanda,
                                       length: turn.prompt.utf16.count)))
        }

        let passi = mostrati(turn)
        if !passi.isEmpty {
            // Il lavoro di un turno è UNA riga finché non la apri.
            //
            // Prima erano tutti i blocchi in fila sotto un'etichetta, e con
            // venticinque comandi la risposta finiva sotto un muro di titoli.
            // La forma è quella dell'app di Claude sul telefono, che lui ha
            // indicato il 26/08: una riga tenue che dice quanti comandi sono
            // stati eseguiti, un segno che si apre, e il triangolo rosso
            // quando uno è fallito — così il fallimento si vede da chiuso,
            // che è l'unica ragione per cui vale la pena guardare lì.
            let idGruppo = Self.idGruppo(turn)
            let apertoGruppo = aperti.contains(idGruppo)
            let rotti = passi.contains(where: \.isError)
            let testa = S.turnWorkSummary(commandCount: passi.count, isOpen: turn.isOpen)
            let inizioGruppo = pagina.testo.length
            let rigaGruppo = "\(rotti ? "⚠ " : "")\(testa) \(apertoGruppo ? "⌄" : "›")\n"
            aggiungi(&pagina, rigaGruppo, rotti ? .bloccoRotto : .blocco)
            pagina.righe.append(Riga(
                range: NSRange(location: inizioGruppo,
                               length: pagina.testo.length - inizioGruppo),
                stepID: idGruppo, turnID: turn.id))
            // I FILE SCRITTI restano fuori dalla piega, sempre.
            //
            // Comprimere il lavoro in una riga aveva un prezzo che lui ha
            // visto subito: i nomi dei file che l'agente ha appena scritto
            // sono la cosa che si clicca per vederli nell'anteprima, e finivano
            // dentro il gruppo chiuso, cioè a due click di distanza da una
            // cosa che serve a ogni turno (sua regola, 26/08). Stanno su una
            // riga loro, sotto il gruppo, e ognuno è un link.
            if !apertoGruppo {
                var scritti: [(nome: String, passo: AgentStep)] = []
                for passo in passi where passo.filePath != nil {
                    guard let nome = passo.fileName, !nome.isEmpty,
                          !scritti.contains(where: { $0.nome == nome }) else { continue }
                    scritti.append((nome, passo))
                }
                if !scritti.isEmpty {
                    aggiungi(&pagina, "  ", .blocco)
                    for (indice, voce) in scritti.enumerated() {
                        if indice > 0 { aggiungi(&pagina, " · ", .blocco) }
                        let da = pagina.testo.length
                        aggiungi(&pagina, voce.nome, .blocco)
                        guard let path = voce.passo.filePath else { continue }
                        let range = NSRange(location: da,
                                            length: pagina.testo.length - da)
                        pagina.collegamenti.append(Collegamento(
                            range: range, stepID: voce.passo.id, path: path))
                        pagina.testo.addAttribute(.foregroundColor,
                                                  value: Theme.current.ink, range: range)
                    }
                    aggiungi(&pagina, "\n", .blocco)
                }
            }
            for passo in apertoGruppo ? passi : [] {
                let aperto = aperti.contains(passo.id)
                // Il segno dice due cose in un carattere: se c'è dentro
                // qualcosa da vedere, e se è aperto adesso.
                let segno = passo.detail.isEmpty ? "·" : (aperto ? "▾" : "▸")
                let taglia = passo.size.isEmpty ? "" : " · \(passo.size)"
                let inizio = pagina.testo.length
                let intestazione =
                    "\(segno) \(passo.isError ? "✕ " : "")\(passo.title)\(taglia)\n"
                aggiungi(&pagina, intestazione,
                         passo.isError ? .bloccoRotto : (aperto ? .bloccoAperto : .blocco))
                let titolo = (intestazione as NSString).range(of: passo.title)
                if titolo.location != NSNotFound, titolo.length > 0 {
                    pagina.campi.append(Campo(
                        place: .step, stepID: passo.id, source: passo.title,
                        sourceRange: NSRange(location: 0, length: passo.title.utf16.count),
                        renderedRange: NSRange(location: inizio + titolo.location,
                                               length: titolo.length)))
                }
                collega(&pagina, passo: passo, riga: intestazione, da: inizio)
                if !passo.detail.isEmpty {
                    pagina.righe.append(Riga(
                        range: NSRange(location: inizio, length: pagina.testo.length - inizio),
                        stepID: passo.id, turnID: turn.id))
                }
                guard aperto, !passo.detail.isEmpty else { continue }
                let inizioDettaglio = pagina.testo.length
                aggiungi(&pagina, passo.detail + "\n\n", .corpo)
                pagina.campi.append(Campo(
                    place: .step, stepID: passo.id, source: passo.detail,
                    sourceRange: NSRange(location: passo.title.utf16.count + 1,
                                         length: passo.detail.utf16.count),
                    renderedRange: NSRange(location: inizioDettaglio,
                                           length: passo.detail.utf16.count)))
            }
            aggiungi(&pagina, "\n", .etichetta)
        }

        aggiungi(&pagina, S.turnAnswer + "\n", .etichetta)
        // La risposta si VESTE: gli asterischi, gli apici e le tabelle a barre
        // sono il modo in cui un agente scrive per un terminale, e questa non
        // è un terminale (suo, 26/08). La domanda no: quella l'hai scritta tu
        // e va riletta com'era.
        let risposta = turn.answer.isEmpty
            ? (turn.isOpen ? (attesa ?? "…") : S.turnNoAnswerWritten)
            : turn.answer
        let inizioRisposta = pagina.testo.length
        let rispostaVestita = Markdown.vesti(risposta, base: attributi(.risposta))
        pagina.testo.append(rispostaVestita)
        if !turn.answer.isEmpty {
            pagina.campi.append(Campo(
                place: .answer, stepID: nil, source: turn.answer,
                sourceRange: NSRange(location: 0, length: turn.answer.utf16.count),
                renderedRange: NSRange(location: inizioRisposta,
                                       length: rispostaVestita.length)))
        }
        pagina.chiaro += risposta
        aggiungi(&pagina, "\n\n", .risposta)

        for seguito in turn.followUps {
            let fonte = seguito.source.isEmpty ? "" : " · \(seguito.source)"
            aggiungi(&pagina, S.turnAfterStopHook(source: fonte) + "\n", .seguito)
            aggiungi(&pagina, seguito.reason + "\n", .blocco)
            let risposta = seguito.answer.isEmpty
                ? (turn.isOpen ? (attesa ?? "…") : S.turnNoAnswerWritten)
                : seguito.answer
            pagina.testo.append(Markdown.vesti(risposta, base: attributi(.risposta)))
            pagina.chiaro += risposta
            aggiungi(&pagina, "\n\n", .risposta)
        }
    }

    /// Il nome del file, dentro la riga già composta, vestito da link.
    ///
    /// Il nome si CERCA nella riga invece di comporre la riga a pezzi, e il
    /// motivo è che il titolo arriva già assemblato dall'adattatore — è lui
    /// che sa come si chiama uno strumento di quel fornitore. Si prende
    /// l'ULTIMA occorrenza perché il nome del file sta in coda al titolo
    /// (`Write · NOTE.md`) mentre in testa può esserci qualunque cosa.
    ///
    /// Se il nome non si trova, non nasce nessun link. È il caso del titolo
    /// tagliato a 72 caratteri da `oneLine`: meglio una riga senza link che un
    /// link su lettere che non sono il nome di quel file. La sottolineatura la
    /// disegna `ReaderText`, non un attributo: `.underlineStyle` sa fare
    /// `single`, `thick` e `double`, e la misura decisa da lui è 1,5 punti.
    private static func collega(_ pagina: inout Pagina, passo: AgentStep,
                                riga: String, da inizio: Int) {
        guard let path = passo.filePath, let nome = passo.fileName,
              !nome.isEmpty else { return }
        guard let trovato = riga.range(of: nome, options: .backwards) else { return }
        let prefisso = riga.distance(from: riga.startIndex, to: trovato.lowerBound)
        let utf16Prima = String(riga.prefix(prefisso)).utf16.count
        let range = NSRange(location: inizio + utf16Prima, length: nome.utf16.count)
        pagina.collegamenti.append(
            Collegamento(range: range, stepID: passo.id, path: path))
        // Il testo del link resta INCHIOSTRO anche in un blocco chiuso, dove
        // il resto della riga è tenue: è la scelta sua del 26/08, «il testo
        // non prende mai il blu, solo la riga sotto». Un link si riconosce
        // perché è più acceso di ciò che lo circonda, non perché è colorato.
        pagina.testo.addAttribute(.foregroundColor, value: Theme.current.ink,
                                  range: range)
    }

    // MARK: - I vestiti

    enum Stile {
        case etichetta, domanda, risposta, seguito, blocco, bloccoAperto, bloccoRotto
        case corpo, separatore
    }

    private static func aggiungi(_ pagina: inout Pagina, _ testo: String, _ stile: Stile) {
        pagina.testo.append(NSAttributedString(string: testo, attributes: attributi(stile)))
        pagina.chiaro += testo
    }

    /// La misura del corpo, che è quella del terminale.
    ///
    /// Le otto misure qui sotto erano scritte a mano (9, 11, 12, 13) e non
    /// sapevano niente di ⌘+ e ⌘−: quei due tasti chiamano `applyFont`, che
    /// tocca solo la griglia, quindi con la pagina della chat davanti lo zoom
    /// sembrava rotto — cambiava un testo che nessuno stava guardando (suo,
    /// 27/08). Adesso è un numero solo, scritto da `applyFont`, e le misure
    /// sono scarti da lui: il 13 della sua configurazione ridà esattamente i
    /// numeri di prima.
    static var misura: CGFloat = 13

    static func attributi(_ stile: Stile) -> [NSAttributedString.Key: Any] {
        let palette = Theme.current
        let base = max(8, min(48, misura))
        switch stile {
        case .etichetta:
            return [.font: Theme.labelFont(base - 4), .foregroundColor: palette.whisper, .kern: 1.2]
        case .domanda:
            return [.font: Theme.monoFont(base - 1), .foregroundColor: palette.ink]
        case .risposta:
            return [.font: Theme.uiFont(base), .foregroundColor: palette.ink]
        case .seguito:
            return [.font: Theme.uiFont(base - 1), .foregroundColor: palette.muted]
        case .blocco:
            return [.font: Theme.uiFont(base - 1), .foregroundColor: palette.muted]
        case .bloccoAperto:
            return [.font: Theme.uiFont(base - 1), .foregroundColor: palette.ink]
        case .bloccoRotto:
            return [.font: Theme.uiFont(base - 1), .foregroundColor: palette.failed]
        case .corpo:
            return [.font: Theme.monoFont(base - 2), .foregroundColor: palette.ink]
        case .separatore:
            return [.font: Theme.labelFont(base - 4), .foregroundColor: palette.hairline]
        }
    }

    /// Quanto è durato, detto come lo dice la mappa dei turni.
    static func durata(_ turn: AgentTurn) -> String {
        guard let duration = turn.duration else { return "" }
        if duration < 1 { return " · \(Int(duration * 1000))ms" }
        return " · " + String(format: "%.1fs", duration)
    }
}
