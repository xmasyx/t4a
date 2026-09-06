//  QueuedView.swift — la ricevuta di ciò che hai spedito mentre l'agente
//  lavorava (ISC-194).
//
//  Il difetto che la fa esistere, dal suo referto del 27/08: un messaggio
//  scritto nella bolla a turno aperto PARTE — `claude` lo mette in coda e lo
//  disegna sulla propria riga d'ingresso — ma quella riga è esattamente
//  quella che la copertura di chat pura nasconde. Dal suo lato non restava
//  nessun segno: «non viene registrato nel testo, quindi non so se è comparso
//  o meno». T4A ha coperto la ricevuta di sotto, quindi T4A ne mette una sua.
//
//  Disegnata a mano e con la stessa forma dell'elenco dei comandi — pannello,
//  filo di bordo, insetti della carta della bolla — per la ragione di
//  MacAppRules §2: si copia la forma che l'app ha già, non se ne inventa una
//  seconda. Non è un posto dove si scrive e non ritrasmette niente: è un
//  cartellino, e un click non ci fa nulla.

import AppKit

@MainActor
final class QueuedView: NSView, ThemeAware, LanguageAware {
    /// Una riga sola. Se la coda ne tiene più d'una si mostra l'ULTIMA con il
    /// conteggio davanti: la ricevuta serve a sapere che è partito, non a
    /// rileggere la conversazione.
    static let height: CGFloat = 26
    private static let textInset: CGFloat = 6

    private(set) var messaggi: [String] = []
    /// Quello che c'è scritto, per il banco: la stessa stringa che finisce
    /// sullo schermo, non una ricostruzione.
    private(set) var riga = ""

    override var isFlipped: Bool { true }

    func mostra(_ messaggi: [String]) {
        guard messaggi != self.messaggi else { return }
        self.messaggi = messaggi
        rebuildRow()
    }

    private func rebuildRow() {
        guard let ultimo = messaggi.last else {
            riga = ""
            needsDisplay = true
            return
        }
        riga = S.queuedPrefix(count: messaggi.count)
            + ultimo.replacingOccurrences(of: "\n", with: " ")
        needsDisplay = true
    }

    /// La stessa carta può portare una riga che non è una ricevuta. ISC-228
    /// la riusa in una seconda istanza, così il rifiuto e la coda non possono
    /// divergere nello stile pur restando due stati osservabili distinti.
    func mostra(riga: String) {
        guard riga != self.riga else { return }
        messaggi = []
        self.riga = riga
        needsDisplay = true
    }

    func applyTheme() { needsDisplay = true }

    func applyLanguage() { rebuildRow() }

    override func draw(_ dirtyRect: NSRect) {
        guard !riga.isEmpty else { return }
        let palette = Theme.current
        let card = bounds
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Theme.Metric.panelRadius,
                                yRadius: Theme.Metric.panelRadius)
        palette.panel.setFill()
        path.fill()
        palette.panelEdge.setStroke()
        path.lineWidth = 1
        path.stroke()

        let font = Theme.monoFont(11)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: palette.whisper,
        ]
        let testo = NSAttributedString(string: riga, attributes: attributes)
        let larghezza = card.width - 2 * Self.textInset
        let y = card.minY + (card.height - font.boundingRectForFont.height) / 2
        // Tagliato con i puntini invece che mandato a capo: la ricevuta è alta
        // una riga per definizione, e un testo lungo che sfonda il rettangolo
        // sarebbe peggio di un testo accorciato.
        let box = NSRect(x: card.minX + Self.textInset, y: y,
                         width: larghezza, height: font.boundingRectForFont.height)
        let stile = NSMutableParagraphStyle()
        stile.lineBreakMode = .byTruncatingTail
        var tagliato = attributes
        tagliato[.paragraphStyle] = stile
        NSAttributedString(string: testo.string, attributes: tagliato).draw(in: box)
    }
}
