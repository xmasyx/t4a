//  Markdown.swift — il testo di un agente si legge, non si decodifica.
//
//  La pagina della chat mostrava quello che l'agente scrive esattamente come
//  lo scrive, cioè `**così**`, `` `così` ``, `[nome](https://…)` e le tabelle
//  in righe di barre verticali. In un terminale quei segni sono il prezzo da
//  pagare; in una pagina disegnata da noi sono solo rumore fra gli occhi e la
//  frase (suo, 26/08).
//
//  Il perimetro è deciso, e piccolo: grassetto, corsivo, codice in linea,
//  link, titoli, elenchi puntati e numerati, righe di citazione, tabelle e
//  righe orizzontali. Tutto il resto passa alla lettera. Un renderer completo
//  qui sarebbe una libreria, e una libreria per sei segni è la dipendenza che
//  questo progetto non prende.
//
//  Una regola sopra le altre: NON SI PERDE TESTO. Ogni carattere che non è un
//  segno riconosciuto arriva a destinazione. È il polo negativo dei test, e la
//  ragione per cui la tabella si allinea invece di sparire.

import AppKit

@MainActor
enum Markdown {
    /// Il testo vestito, pronto per la pagina.
    ///
    /// `base` sono gli attributi del corpo: da lì nascono il grassetto (stesso
    /// carattere, peso `.bold`), il corsivo e il codice, così un cambio di
    /// tema o di misura resta in un posto solo.
    static func vesti(_ testo: String, base: [NSAttributedString.Key: Any])
        -> NSAttributedString {
        let fuori = NSMutableAttributedString()
        let righe = testo.components(separatedBy: "\n")
        var i = 0
        while i < righe.count {
            let riga = righe[i]
            // Una tabella si riconosce dalla sua SECONDA riga, quella dei
            // trattini: senza quel controllo una riga qualunque con due barre
            // dentro diventerebbe una tabella di una riga sola.
            if riga.hasPrefix("|"), i + 1 < righe.count, separatoreTabella(righe[i + 1]) {
                var blocco: [String] = []
                while i < righe.count, righe[i].hasPrefix("|") {
                    blocco.append(righe[i]); i += 1
                }
                fuori.append(tabella(blocco, base: base))
                continue
            }
            fuori.append(rigaVestita(riga, base: base))
            if i + 1 < righe.count { fuori.append(NSAttributedString(string: "\n", attributes: base)) }
            i += 1
        }
        return fuori
    }

    // MARK: - Le righe

    private static func rigaVestita(_ riga: String, base: [NSAttributedString.Key: Any])
        -> NSAttributedString {
        let senzaSpazi = riga.trimmingCharacters(in: .whitespaces)

        // Una riga orizzontale diventa una riga orizzontale, non tre trattini.
        if senzaSpazi.count >= 3,
           senzaSpazi.allSatisfy({ $0 == "-" }) || senzaSpazi.allSatisfy({ $0 == "*" })
            || senzaSpazi.allSatisfy({ $0 == "_" }) {
            var attributi = base
            attributi[.foregroundColor] = Theme.current.hairline
            return NSAttributedString(string: String(repeating: "─", count: 24),
                                      attributes: attributi)
        }

        // Titolo: i cancelletti se ne vanno e resta il peso.
        if let cancelletti = prefissoRipetuto(senzaSpazi, "#"), cancelletti <= 6,
           senzaSpazi.dropFirst(cancelletti).first == " " {
            let testo = String(senzaSpazi.dropFirst(cancelletti + 1))
            var attributi = base
            let misura = (base[.font] as? NSFont)?.pointSize ?? 13
            attributi[.font] = Theme.uiFont(misura + (cancelletti == 1 ? 3 : 1), weight: .bold)
            return inLinea(testo, base: attributi)
        }

        // Citazione: la barra verticale al posto del maggiore.
        if senzaSpazi.hasPrefix("> ") {
            var attributi = base
            attributi[.foregroundColor] = Theme.current.muted
            let dentro = inLinea(String(senzaSpazi.dropFirst(2)), base: attributi)
            let fuori = NSMutableAttributedString(string: "│ ", attributes: attributi)
            fuori.append(dentro)
            return fuori
        }

        // Elenco puntato: il segno diventa un punto, e il rientro resta.
        let rientro = riga.prefix { $0 == " " || $0 == "\t" }
        let corpo = String(riga.dropFirst(rientro.count))
        if corpo.hasPrefix("- ") || corpo.hasPrefix("* ") || corpo.hasPrefix("+ ") {
            let fuori = NSMutableAttributedString(
                string: String(rientro) + "• ", attributes: base)
            fuori.append(inLinea(String(corpo.dropFirst(2)), base: base))
            return fuori
        }

        return inLinea(riga, base: base)
    }

    private static func prefissoRipetuto(_ testo: String, _ carattere: Character) -> Int? {
        let quanti = testo.prefix { $0 == carattere }.count
        return quanti > 0 ? quanti : nil
    }

    // MARK: - I segni dentro una riga

    /// Grassetto, corsivo, codice e link, in una passata sola.
    ///
    /// A mano e non con una regex per due ragioni misurate: `**` e `*` si
    /// distinguono guardando il carattere dopo, cosa che una regex fa male; e
    /// un segno che non si chiude deve restare testo, mentre una regex avida
    /// se lo mangia insieme a mezza frase.
    static func inLinea(_ riga: String, base: [NSAttributedString.Key: Any])
        -> NSAttributedString {
        let fuori = NSMutableAttributedString()
        var normale = ""
        var i = riga.startIndex

        func scarica() {
            guard !normale.isEmpty else { return }
            fuori.append(NSAttributedString(string: normale, attributes: base))
            normale = ""
        }

        while i < riga.endIndex {
            let c = riga[i]
            // `codice`
            if c == "`", let fine = riga[riga.index(after: i)...].firstIndex(of: "`") {
                scarica()
                let dentro = String(riga[riga.index(after: i)..<fine])
                var attributi = base
                let misura = (base[.font] as? NSFont)?.pointSize ?? 13
                attributi[.font] = Theme.monoFont(misura - 1)
                attributi[.foregroundColor] = Theme.current.muted
                fuori.append(NSAttributedString(string: dentro, attributes: attributi))
                i = riga.index(after: fine)
                continue
            }
            // **grassetto**
            if c == "*", riga.index(after: i) < riga.endIndex,
               riga[riga.index(after: i)] == "*",
               let fine = chiusura(riga, da: riga.index(i, offsetBy: 2), segno: "**") {
                scarica()
                let dentro = String(riga[riga.index(i, offsetBy: 2)..<fine])
                var attributi = base
                let misura = (base[.font] as? NSFont)?.pointSize ?? 13
                attributi[.font] = Theme.uiFont(misura, weight: .bold)
                fuori.append(inLinea(dentro, base: attributi))
                i = riga.index(fine, offsetBy: 2)
                continue
            }
            // *corsivo* e _corsivo_
            if c == "*" || c == "_",
               let fine = chiusura(riga, da: riga.index(after: i), segno: String(c)),
               fine > riga.index(after: i) {
                scarica()
                let dentro = String(riga[riga.index(after: i)..<fine])
                var attributi = base
                let misura = (base[.font] as? NSFont)?.pointSize ?? 13
                let corsivo = NSFontManager.shared.convert(Theme.uiFont(misura), toHaveTrait: .italicFontMask)
                attributi[.font] = corsivo
                fuori.append(inLinea(dentro, base: attributi))
                i = riga.index(after: fine)
                continue
            }
            // [nome](indirizzo) → resta il nome, acceso. L'indirizzo non si
            // stampa: era la metà più lunga della riga e la meno leggibile.
            if c == "[", let chiusa = riga[i...].firstIndex(of: "]"),
               riga.index(after: chiusa) < riga.endIndex,
               riga[riga.index(after: chiusa)] == "(",
               let tonda = riga[chiusa...].firstIndex(of: ")") {
                scarica()
                let nome = String(riga[riga.index(after: i)..<chiusa])
                var attributi = base
                attributi[.foregroundColor] = Theme.current.ink
                attributi[.underlineStyle] = NSUnderlineStyle.single.rawValue
                fuori.append(inLinea(nome, base: attributi))
                i = riga.index(after: tonda)
                continue
            }
            normale.append(c)
            i = riga.index(after: i)
        }
        scarica()
        return fuori
    }

    /// Dove si chiude un segno, o nil se non si chiude: un asterisco solo in
    /// mezzo a una frase resta un asterisco.
    private static func chiusura(_ riga: String, da: String.Index, segno: String)
        -> String.Index? {
        guard da < riga.endIndex else { return nil }
        var i = da
        while i < riga.endIndex {
            if riga[i...].hasPrefix(segno) {
                // Un segno attaccato a uno spazio a sinistra non chiude niente
                // («2 * 3 * 4» non è corsivo).
                guard i > da else { return nil }
                return i
            }
            i = riga.index(after: i)
        }
        return nil
    }

    // MARK: - Le tabelle

    private static func separatoreTabella(_ riga: String) -> Bool {
        let dentro = riga.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
        guard !dentro.isEmpty else { return false }
        return dentro.allSatisfy { "-:| ".contains($0) } && dentro.contains("-")
    }

    /// Celle vere, non spazi: una tabella si impagina, non si allinea.
    ///
    /// La versione di prima riempiva ogni cella di spazi in carattere fisso e
    /// non sapeva quanto fosse larga la finestra: una cella che contiene una
    /// frase produceva una riga più larga della colonna, `NSTextView` la
    /// mandava a capo dove capitava, e le colonne collassavano (sua foto,
    /// 27/08: «Stato» finiva sotto «# Candidato»).
    ///
    /// `NSTextTable` è la risposta di AppKit, e la ragione per cui vince non è
    /// il pareggio delle colonne: è che il contenitore segue la finestra
    /// (`widthTracksTextView`), quindi una tabella impaginata a mano sarebbe
    /// da rifare a ogni ridimensionamento, mentre queste celle si
    /// ri-impaginano da sole. Vive in TextKit 1, ed è dove siamo: toccare
    /// `textStorage` tiene la vista nella modalità vecchia.
    ///
    /// Il carattere fisso se ne va con gli spazi. Serviva solo a far quadrare
    /// il riempimento; adesso le colonne le tiene la tabella, e il corpo si
    /// legge nel carattere del corpo.
    private static func tabella(_ righe: [String], base: [NSAttributedString.Key: Any])
        -> NSAttributedString {
        let celle: [[String]] = righe.compactMap { riga in
            guard !separatoreTabella(riga) else { return nil }
            var parti = riga.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parti.first == "" { parti.removeFirst() }
            if parti.last == "" { parti.removeLast() }
            return parti
        }
        guard !celle.isEmpty else { return NSAttributedString(string: "", attributes: base) }
        let colonne = celle.map(\.count).max() ?? 0
        guard colonne > 0 else { return NSAttributedString(string: "", attributes: base) }

        let tavola = NSTextTable()
        tavola.numberOfColumns = colonne
        // Fissa e non automatica: l'automatica misura il contenuto e torna a
        // sbordare fuori dal contenitore, che è il difetto di partenza.
        tavola.layoutAlgorithm = .fixedLayoutAlgorithm
        tavola.hidesEmptyCells = false
        tavola.setContentWidth(100, type: .percentageValueType)

        let quote = quoteColonne(celle, colonne: colonne)
        let fuori = NSMutableAttributedString()
        for (numero, riga) in celle.enumerated() {
            for colonna in 0..<colonne {
                let blocco = NSTextTableBlock(table: tavola, startingRow: numero, rowSpan: 1,
                                              startingColumn: colonna, columnSpan: 1)
                blocco.setContentWidth(quote[colonna], type: .percentageValueType)
                blocco.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
                blocco.setWidth(5, type: .absoluteValueType, for: .padding, edge: .maxY)
                blocco.setWidth(0, type: .absoluteValueType, for: .padding, edge: .minX)
                blocco.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
                // Un filo sotto l'intestazione e niente altro: una griglia
                // intera è più segno che tabella, e questa app disegna sottile.
                if numero == 0 {
                    blocco.setBorderColor(Theme.current.hairline, for: .maxY)
                    blocco.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                }
                let paragrafo = NSMutableParagraphStyle()
                paragrafo.textBlocks = [blocco]
                paragrafo.lineBreakMode = .byWordWrapping
                var attributi = numero == 0 ? grassetto(base) : base
                attributi[.paragraphStyle] = paragrafo
                let testo = colonna < riga.count ? riga[colonna] : ""
                fuori.append(inLinea(testo, base: attributi))
                // Ogni cella è un paragrafo suo: senza questo a capo AppKit
                // non sa dove finisce, e le celle si fondono in una sola.
                fuori.append(NSAttributedString(string: "\n", attributes: attributi))
            }
        }
        return fuori
    }

    /// Quanto spazio prende ogni colonna, in percentuale.
    ///
    /// La misura è la cella più lunga della colonna, che è una stima e non una
    /// verità: serve solo a non dare a «#» la stessa larghezza di una frase.
    /// I due limiti contano più della formula — sotto il 7% una colonna non
    /// contiene nemmeno una parola, sopra il 50% mangia tutte le altre.
    static func quoteColonne(_ celle: [[String]], colonne: Int) -> [CGFloat] {
        guard colonne > 0 else { return [] }
        var misure = [CGFloat](repeating: 1, count: colonne)
        for riga in celle {
            for (indice, cella) in riga.enumerated() where indice < colonne {
                misure[indice] = max(misure[indice], CGFloat(senzaSegni(cella).count))
            }
        }
        let totale = max(1, misure.reduce(0, +))
        var quote = misure.map { min(50, max(7, $0 / totale * 100)) }
        // I limiti rompono il totale: si rinormalizza, altrimenti la somma
        // supera il 100% e l'ultima colonna esce dal contenitore.
        let somma = quote.reduce(0, +)
        if somma > 0 { quote = quote.map { $0 / somma * 100 } }
        return quote
    }

    private static func grassetto(_ attributi: [NSAttributedString.Key: Any])
        -> [NSAttributedString.Key: Any] {
        var fuori = attributi
        let misura = (attributi[.font] as? NSFont)?.pointSize ?? 13
        fuori[.font] = Theme.uiFont(misura, weight: .bold)
        fuori[.foregroundColor] = Theme.current.ink
        return fuori
    }

    /// Il testo come si vedrà, cioè senza i segni: serve a misurare la
    /// larghezza di una colonna, e misurarla sui segni la sballa di due
    /// caratteri per ogni grassetto.
    static func senzaSegni(_ testo: String) -> String {
        var fuori = ""
        var i = testo.startIndex
        while i < testo.endIndex {
            let c = testo[i]
            if c == "`" { i = testo.index(after: i); continue }
            if c == "*", testo.index(after: i) < testo.endIndex,
               testo[testo.index(after: i)] == "*" {
                i = testo.index(i, offsetBy: 2); continue
            }
            if c == "*" { i = testo.index(after: i); continue }
            if c == "[", let chiusa = testo[i...].firstIndex(of: "]"),
               testo.index(after: chiusa) < testo.endIndex,
               testo[testo.index(after: chiusa)] == "(",
               let tonda = testo[chiusa...].firstIndex(of: ")") {
                fuori += testo[testo.index(after: i)..<chiusa]
                i = testo.index(after: tonda)
                continue
            }
            fuori.append(c)
            i = testo.index(after: i)
        }
        return fuori
    }
}
