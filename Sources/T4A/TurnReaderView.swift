//  TurnReaderView.swift — cliccare un turno APRE il messaggio (ISC-168).
//
//  Perché non è uno scorrimento, che è la cosa che sembrava ovvia. La mappa
//  dei turni portava al terminale, cioè alla riga su cui la domanda era stata
//  scritta, e con `claude` quella riga non esiste: misurato sull'app viva il
//  2026-08-25, `alternateScreen: true` e la sonda degli agganci che risponde
//  **riga −1 su tutti e quattro i turni**. Lo schermo alternato è una
//  schermata sola senza storia, e per giunta una domanda lunga `claude` la
//  mostra come `[Pasted text #1 +12 lines]`, quindi il testo non ci è mai
//  stato. L'aggancio ripiegava sull'ultima riga e il click portava in fondo:
//  un comando che risponde e non fa niente, che è peggio di un comando morto.
//
//  Il dato però ce l'abbiamo già intero — l'adattatore legge il transcript, e
//  lì domanda e risposta stanno per esteso. Quindi il click non va a cercare
//  il messaggio sullo schermo: lo **mostra**. Una cosa sola, sempre la stessa,
//  senza rami nascosti: la regola di ISC-162 vale anche qui, un controllo che
//  a volte fa una cosa e a volte un'altra è un controllo che mente.

import AppKit
import TerminalCore

/// Un turno, aperto e leggibile: la domanda per intero, la risposta, e gli
/// strumenti usati. Sta sopra la pagina come la palette (⌘K) e si chiude con
/// Esc o con un click fuori dalla carta.
@MainActor
final class TurnReaderView: NSView, ThemeAware, LanguageAware {
    private let scroller = NSScrollView()
    private let text = ReaderText()
    private(set) var turn: AgentTurn?
    private var previousResponder: NSResponder?
    /// La riga della sessione che ha composto il testo adesso. Il confronto
    /// evita di ridisegnare un turno a ogni `refresh` della finestra.
    private var attesa: String?
    private var highlight: TranscriptHit?
    private(set) var highlightRange: NSRange?

    var onClose: (() -> Void)?
    /// Il click sul nome di un file scritto dall'agente (ISC-175). Vale qui
    /// come nella pagina della chat: le due superfici mostrano lo stesso
    /// turno, quindi devono rispondere allo stesso gesto.
    var onOpenFile: ((TurnProse.Collegamento) -> Void)?
    /// Come nella pagina della chat: una selezione col mouse è finita (ISC-197).
    var onSelection: ((String) -> Void)? {
        get { text.onSelection }
        set { text.onSelection = newValue }
    }

    /// La selezione viva, se c'è: ⌘C la chiede a questa vista invece che al
    /// terminale, che non sa niente di quello che è scritto qui (27/08).
    var selezione: String? {
        let scelta = text.selectedRange()
        guard scelta.length > 0 else { return nil }
        return (text.string as NSString).substring(with: scelta)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        text.isEditable = false
        // Selezionabile per scelta: la ragione per cui apri un messaggio
        // vecchio è quasi sempre riprenderne un pezzo, e un lettore da cui
        // non si può copiare costringe a ridigitare quello che hai sotto gli
        // occhi.
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = false
        text.textContainerInset = NSSize(width: Theme.Metric.textInset,
                                         height: Theme.Metric.textInset)
        text.textContainer?.lineFragmentPadding = 0
        scroller.translatesAutoresizingMaskIntoConstraints = true
        scroller.drawsBackground = false
        scroller.borderType = .noBorder
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        text.onEscape = { [weak self] in self?.close() }
        // Il click su una riga di blocco va intercettato QUI e non nella
        // vista che contiene la carta: AppKit consegna il click alla vista
        // più profonda, cioè al testo, e un `mouseDown` sul contenitore vede
        // solo i click FUORI dal testo. Misurato il 25/08 su due click veri
        // che non aprivano niente.
        text.onClick = { [weak self] point in self?.toggleStep(at: point) ?? false }
        scroller.documentView = text
        addSubview(scroller)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyTheme() {
        scroller.scrollerKnobStyle = Theme.current.isLight ? .dark : .light
        if let turn { render(turn, attesa: attesa) }
        needsDisplay = true
    }

    func applyLanguage() {
        ridisegna()
        needsDisplay = true
    }

    // MARK: - La carta

    /// Larga abbastanza da non spezzare una frase ogni tre parole, e mai più
    /// alta della finestra: sotto una certa taglia è la finestra a decidere.
    /// La striscia in fondo alla carta. Il congedo vive qui e non in coda al
    /// testo: in coda si vede solo dopo aver scorso fino in fondo, cioe nel
    /// momento in cui non serve piu.
    static let footerHeight: CGFloat = 28

    var cardRect: NSRect {
        let width = min(760, max(320, bounds.width - 120))
        let height = min(560, max(200, bounds.height - 120))
        return NSRect(x: (bounds.width - width) / 2,
                      y: (bounds.height - height) / 2,
                      width: width, height: height)
    }

    override func layout() {
        super.layout()
        let card = cardRect
        // Il testo sta DENTRO la carta, con il bordo che resta visibile.
        scroller.frame = NSRect(x: card.minX + 1, y: card.minY + 1,
                                width: card.width - 2,
                                height: card.height - 2 - Self.footerHeight)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        text.frame.size.width = scroller.contentSize.width
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        // La pagina dietro, smorzata. Stessa scelta della palette: niente
        // sfocatura, che su un terminale è un fotogramma speso in decorazione.
        (palette.isLight ? NSColor(white: 0.35, alpha: 0.22)
                         : NSColor(white: 0, alpha: 0.38)).setFill()
        bounds.fill()

        let path = NSBezierPath(roundedRect: cardRect,
                                xRadius: Theme.Metric.panelRadius,
                                yRadius: Theme.Metric.panelRadius)
        palette.panel.setFill()
        path.fill()
        palette.panelEdge.setStroke()
        path.lineWidth = 1
        path.stroke()

        let card = cardRect
        // Un filo VISIBILE, non tenue: separa il piede dal testo che continua
        // sotto la piega, e una riga tagliata a meta senza niente sopra si
        // legge come un difetto invece che come un scorrimento.
        palette.hairline.setFill()
        NSRect(x: card.minX + 1, y: card.maxY - Self.footerHeight,
               width: card.width - 2, height: 1).fill()
        let hint = NSAttributedString(string: S.turnReaderCloseHint, attributes: [
            .font: Theme.labelFont(9),
            .foregroundColor: palette.whisper,
        ])
        hint.draw(at: NSPoint(x: card.minX + Theme.Metric.textInset,
                              y: card.maxY - Self.footerHeight + 9))
    }

    // MARK: - Aprire e chiudere

    func open(_ turn: AgentTurn, restoring responder: NSResponder?, attesa: String?,
              highlight: TranscriptHit? = nil) {
        self.turn = turn
        self.attesa = attesa
        self.highlight = highlight
        previousResponder = responder
        // Il lettore si apre APPOSTA per leggere quel turno, quindi il
        // gruppo dei comandi nasce aperto: nella pagina della chat sta chiuso
        // perché lì il lavoro è di passaggio, qui è la ragione per cui hai
        // cliccato (26/08).
        aperti = TurnProse.daAprireSubito(turn).union([TurnProse.idGruppo(turn)])
        if let stepID = highlight?.stepID { aperti.insert(stepID) }
        render(turn, attesa: attesa)
        isHidden = false
        needsLayout = true
        needsDisplay = true
        window?.makeFirstResponder(self)
        text.scroll(.zero)
    }

    func close() {
        guard !isHidden else { return }
        isHidden = true
        turn = nil
        attesa = nil
        highlight = nil
        highlightRange = nil
        // La tastiera torna da dove è venuta, altrimenti il pannello resta a
        // disegnare un terminale che non riceve più niente (ISC-32).
        if let previousResponder, let window {
            window.makeFirstResponder(previousResponder)
        }
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }   // Esc
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(point) else { close(); return }
        if toggleStep(at: event.locationInWindow) { return }
        super.mouseDown(with: event)
    }

    // MARK: - Il testo

    /// Quello che il lettore mostra, in chiaro, per il banco: è la stessa
    /// stringa che finisce sullo schermo, non una ricostruzione.
    private(set) var body = ""

    /// I passi aperti in questo momento, per id. Si ricalcola a ogni
    /// apertura: un turno si apre come lo aprirebbe la pagina della chat,
    /// perché due superfici che mostrano la stessa cosa in due modi diversi
    /// sono due cose da imparare invece di una.
    private var aperti: Set<String> = []

    /// Dove sta la riga cliccabile di ogni blocco, nel testo disegnato adesso.
    private var righe: [TurnProse.Riga] = []

    /// Ridisegna il turno aperto con gli attributi di adesso: ⌘+ cambia le
    /// misure e non il turno, quindi senza questa porta lo zoom non arriva.
    func ridisegna() { if let turn { render(turn, attesa: attesa) } }

    /// Aggiorna solo l'unica parte mobile di un turno aperto. `refresh()` è
    /// frequente; un confronto qui mantiene il costo a un solo render quando
    /// la frase di `claude` cambia davvero (ISC-229).
    func aggiorna(attesa nuovaAttesa: String?) {
        guard !isHidden, let turn, turn.isOpen, nuovaAttesa != attesa else { return }
        render(turn, attesa: nuovaAttesa)
    }

    private func render(_ turn: AgentTurn, attesa: String?) {
        self.attesa = attesa
        let pagina = TurnProse.componi(turns: [turn], aperti: aperti, attesa: attesa)
        righe = pagina.righe
        body = pagina.chiaro
        text.links = pagina.collegamenti
        let scorrimento = scroller.contentView.bounds.origin
        text.textStorage?.setAttributedString(pagina.testo)
        highlightRange = highlight.flatMap { locate($0, in: pagina) }
        if let range = highlightRange {
            text.textStorage?.addAttributes([
                .backgroundColor: Theme.current.selection,
                .foregroundColor: Theme.current.ink,
            ], range: range)
            text.setSelectedRange(range)
        }
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        // Aprire un blocco non deve riportarti in cima: quello che stavi
        // guardando è la ragione per cui hai cliccato.
        scroller.contentView.scroll(to: scorrimento)
        if let range = highlightRange { text.scrollRangeToVisible(range) }
    }

    /// Turns the field-relative UTF-16 range returned by TranscriptSearch into
    /// the range of the rendered reader. Prompt and step text map directly;
    /// answers can shed Markdown punctuation, so there the visible occurrence
    /// nearest the source position wins.
    private func locate(_ hit: TranscriptHit, in page: TurnProse.Pagina) -> NSRange? {
        for field in page.campi
        where field.place == hit.place && field.stepID == hit.stepID {
            let sourceEnd = NSMaxRange(field.sourceRange)
            guard hit.range.location >= field.sourceRange.location,
                  NSMaxRange(hit.range) <= sourceEnd else { continue }
            let local = NSRange(location: hit.range.location - field.sourceRange.location,
                                length: hit.range.length)
            guard NSMaxRange(local) <= field.source.utf16.count else { continue }
            let source = field.source as NSString
            let needle = source.substring(with: local)
            guard !needle.isEmpty else { continue }

            let rendered = (page.testo.string as NSString).substring(with: field.renderedRange)
            if rendered == field.source {
                return NSRange(location: field.renderedRange.location + local.location,
                               length: local.length)
            }
            let escaped = NSRegularExpression.escapedPattern(for: needle)
            guard let regex = try? NSRegularExpression(pattern: escaped) else { continue }
            let candidates = regex.matches(in: rendered,
                                            range: NSRange(location: 0,
                                                           length: rendered.utf16.count))
                .filter { $0.range.length > 0 }
            let sourceShare = Double(local.location) / Double(max(1, field.source.utf16.count))
            guard let closest = candidates.min(by: {
                abs(Double($0.range.location) / Double(max(1, rendered.utf16.count)) - sourceShare)
                    < abs(Double($1.range.location) / Double(max(1, rendered.utf16.count)) - sourceShare)
            }) else { continue }
            return NSRange(location: field.renderedRange.location + closest.range.location,
                           length: closest.range.length)
        }
        return nil
    }

    /// Il click su una riga di blocco lo apre o lo chiude. Fuori da quelle
    /// righe il click resta quello di prima: selezionare il testo.
    /// Torna `true` se il click apparteneva a un blocco.
    func toggleStep(at point: NSPoint) -> Bool {
        guard let turn, text.selectedRange().length == 0 else { return false }
        let dentro = text.convert(point, from: nil)
        // Il nome del file prima della riga che lo contiene (ISC-175).
        if let link = text.links.first(where: {
            text.rect(of: $0)?.contains(dentro) == true
        }) {
            onOpenFile?(link)
            return true
        }
        guard !righe.isEmpty else { return false }
        let indice = text.characterIndexForInsertion(at: dentro)
        guard let colpito = righe.first(where: {
            NSLocationInRange(indice, $0.range)
        }) else { return false }
        if aperti.contains(colpito.stepID) { aperti.remove(colpito.stepID) }
        else { aperti.insert(colpito.stepID) }
        render(turn, attesa: attesa)
        return true
    }

    /// Lo stato per il banco: aperto o no, e su quale turno.
    var testState: [String: Any] {
        var state: [String: Any] = ["open": !isHidden,
         "turn": turn?.id ?? -1,
         "chars": body.count,
         "text": String(body.prefix(4_000)),
         "tail": String(body.suffix(2_000)),
         "promptChars": turn?.prompt.count ?? 0,
         "answerChars": turn?.answer.count ?? 0,
         "attesa": attesa ?? "",
         "steps": (turn?.steps ?? []).map { passo in
             ["id": passo.id, "kind": passo.kind.rawValue, "title": passo.title,
              "detailChars": passo.detail.count,
              "open": aperti.contains(passo.id)] as [String: Any]
         },
         "openSteps": Array(aperti).sorted()]
        if let highlight {
            state["highlight"] = [
                "place": highlight.place.rawValue,
                "stepID": highlight.stepID ?? "",
                "location": highlight.range.location,
                "length": highlight.range.length,
                "renderedLocation": highlightRange?.location ?? -1,
                "renderedLength": highlightRange?.length ?? 0,
            ]
        } else {
            state["highlight"] = [:]
        }
        return state
    }
}

/// Il testo del lettore, che restituisce Esc.
///
/// Serve perche una `NSTextView` selezionabile diventa first responder al
/// primo click dentro il testo, e `cancelOperation` e roba SUA (la usa per
/// annullare un completamento): senza questa riga, Esc dopo aver selezionato
/// una frase non chiude piu niente, che e il caso normale di chi apre un
/// messaggio per copiarne un pezzo.
@MainActor
final class ReaderText: NSTextView {
    var onEscape: (() -> Void)?
    /// Torna `true` quando il click apparteneva alla riga di un blocco: in
    /// quel caso non deve anche iniziare una selezione.
    var onClick: ((NSPoint) -> Bool)?
    /// La selezione col mouse è finita, e non è vuota (ISC-197). Il testo
    /// viaggia già estratto: chi riceve decide se copiarlo, e questa vista non
    /// sa che esistano gli appunti.
    var onSelection: ((String) -> Void)?

    /// Il click apre o chiude un blocco, il TRASCINAMENTO seleziona.
    ///
    /// La distinzione si fa alla fine e non all'inizio, ed è la riparazione
    /// di un difetto misurato il 25/08: decidendo su `mouseDown` il gesto
    /// veniva sempre interpretato come un click, quindi `super` non riceveva
    /// niente, il testo non si poteva selezionare, e un trascinamento partito
    /// su una riga di blocco la richiudeva sotto il puntatore. Ora
    /// `super.mouseDown` gestisce il gesto per intero — il suo ciclo di
    /// tracciamento ritorna al rilascio — e solo dopo si guarda se è stato un
    /// click: niente selezione, e il puntatore fermo.
    override func mouseDown(with event: NSEvent) {
        let partenza = event.locationInWindow
        super.mouseDown(with: event)
        // Il ciclo di tracciamento di `super` è già tornato: qui il gesto è
        // finito, quindi questo È il rilascio del mouse, il momento in cui
        // iTerm copia (ISC-197).
        let scelta = selectedRange()
        let arrivo = window?.mouseLocationOutsideOfEventStream ?? partenza
        let click = abs(arrivo.x - partenza.x) < 3 && abs(arrivo.y - partenza.y) < 3
        if scelta.length > 0 {
            // Il 28/08, 203d misurava `ReaderText/21` due volte: in una vista
            // selezionabile ma non editabile AppKit non toglie la selezione
            // cliccando nel vuoto, perciò questo ritorno non restituiva mai la
            // tastiera alla bolla. Un click vero fuori dalle lettere la toglie
            // qui e segue la strada del click semplice, senza copiarla; sopra
            // il testo resta invece selezionata e quindi copiabile.
            let punto = convert(partenza, from: nil)
            if click, !sopraDelTesto(punto) {
                setSelectedRange(NSRange(location: 0, length: 0))
                _ = onClick?(partenza)
                return
            }
            onSelection?((string as NSString).substring(with: scelta))
            return
        }
        guard scelta.length == 0 else { return }
        guard click else { return }
        _ = onClick?(partenza)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }

    // MARK: - I link ai file scritti (ISC-175)

    /// I nomi di file disegnati adesso come link, con la loro posizione nel
    /// testo. Chi compone la pagina li consegna qui; questa vista li disegna,
    /// li illumina sotto il puntatore e cambia il cursore sopra di loro. Chi
    /// decide cosa fa il click resta il proprietario, che è lo stesso posto
    /// dove si decide cosa fa il click su una riga di blocco.
    var links: [TurnProse.Collegamento] = [] {
        didSet {
            rettangoli.removeAll()
            sorvegliato = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    /// Il link sotto il puntatore adesso, per indice.
    ///
    /// Ridisegna SOLO le due righe che cambiano, non la pagina: `needsDisplay`
    /// su una vista che tiene migliaia di caratteri la fa ridisegnare tutta, e
    /// qui succedeva a ogni movimento del mouse. È il ritardo che lui ha
    /// filmato il 26/08 alle 22:30 — non il calcolo dei rettangoli, che
    /// intanto era già in memoria, ma il disegno.
    private var sorvegliato: Int? {
        didSet {
            guard sorvegliato != oldValue else { return }
            // La mano si IMPILA, non si «imposta».
            //
            // `NSCursor.set()` perde contro la macchina dei rettangoli di
            // `NSTextView`, che rimette l'asta di testo subito dopo: misurato
            // il 26/08 con la vista che sapeva benissimo di avere un link
            // sotto il puntatore (`hovered=0`) e il cursore che restava
            // quello della selezione. Una pila si svuota solo quando la
            // svuoti tu, e questa si svuota all'uscita dal link.
            let dentro = sorvegliato != nil
            if dentro, !manoImpilata {
                NSCursor.pointingHand.push()
                manoImpilata = true
            } else if !dentro, manoImpilata {
                NSCursor.pop()
                manoImpilata = false
            }
            for indice in [oldValue, sorvegliato].compactMap({ $0 })
            where links.indices.contains(indice) {
                guard var box = rect(of: links[indice]) else { continue }
                // Un filo attorno: la riga sotto il nome sta sotto la linea di
                // base, cioè fuori dal rettangolo delle lettere.
                box = box.insetBy(dx: -2, dy: -4)
                setNeedsDisplay(box)
            }
        }
    }
    private var areaLink: NSTrackingArea?

    /// Il link sotto il puntatore come lo vede LA VISTA, e quante volte le
    /// hanno chiesto di decidere il cursore: se il primo è nullo mentre il
    /// puntatore è sopra un nome, il difetto non è nel cursore, è che i
    /// movimenti del mouse non arrivano fin qui.
    var linkSorvegliato: Int? { sorvegliato }
    private(set) var richiesteCursore = 0
    /// La mano è sulla pila adesso. Senza questa memoria una pila si
    /// sbilancia, e un cursore impilato due volte non torna più indietro.
    private var manoImpilata = false

    /// I numeri del disegno, per il banco.
    private(set) var disegni = 0
    private(set) var ultimaArea: Double = 0
    private(set) var areaTotale: Double = 0

    /// Lo spessore della riga sotto il nome, in punti. 1,5 è la misura che ha
    /// scelto lui il 26/08; sotto il puntatore ingrossa, che è l'unico segnale
    /// che il link dà prima del click — il testo non cambia mai colore.
    static let spessoreLink: CGFloat = 1.5
    static let spessoreLinkSorvegliato: CGFloat = 2.5

    /// Il link che contiene questo carattere, se ce n'è uno.
    func link(at indice: Int) -> TurnProse.Collegamento? {
        links.first { NSLocationInRange(indice, $0.range) }
    }

    /// Il rettangolo delle lettere di un link, nelle coordinate di questa
    /// vista. Nasce dal layout vero e non da una stima: è quello che il banco
    /// usa per mettere il puntatore sul nome del file e cliccarlo davvero.
    func rect(of link: TurnProse.Collegamento) -> NSRect? {
        if let memoria = rettangoli[link.range] { return memoria }
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let glifi = layout.glyphRange(forCharacterRange: link.range,
                                      actualCharacterRange: nil)
        guard glifi.length > 0 else { return nil }
        var box = layout.boundingRect(forGlyphRange: glifi, in: container)
        box.origin.x += textContainerOrigin.x
        box.origin.y += textContainerOrigin.y
        rettangoli[link.range] = box
        return box
    }

    /// I rettangoli dei link, calcolati una volta.
    ///
    /// Chiedere all'impaginazione dove sta un intervallo costa, e il puntatore
    /// lo chiedeva per OGNI link a OGNI movimento del mouse: il cursore a mano
    /// arrivava con un ritardo che si sente (suo, 26/08). La memoria si
    /// svuota quando cambia la serie dei link o quando il testo si ri-impagina,
    /// che sono i due soli momenti in cui quei rettangoli possono spostarsi.
    private var rettangoli: [NSRange: NSRect] = [:]

    override func layout() {
        super.layout()
        rettangoli.removeAll()
    }

    /// La larghezza cambia quando l'anteprima si prende metà finestra, e il
    /// testo si ri-manda a capo: i rettangoli di prima puntano a righe che non
    /// stanno più lì. Senza questa riga il banco ha cliccato nel vuoto tre
    /// poli di fila (26/08), che è esattamente il difetto che una memoria
    /// introduce quando non si svuota dove deve.
    override func setFrameSize(_ newSize: NSSize) {
        let cambiata = newSize.width != frame.width
        super.setFrameSize(newSize)
        if cambiata { rettangoli.removeAll() }
    }

    override func didChangeText() {
        super.didChangeText()
        rettangoli.removeAll()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let areaLink { removeTrackingArea(areaLink) }
        // `.mouseMoved` fa seguire il cursore al puntatore dentro l'area;
        // `.cursorUpdate` copre anche gli ingressi e i cambi della macchina
        // dei cursor rect. Senza quest'ultimo, `NSTextView` sovrascriveva la
        // mano con la sua asta di testo: compariva a tratti, e a volte solo
        // dopo un click (suo, 26/08).
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                      .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        areaLink = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        sorvegliato = indiceLink(sotto: event.locationInWindow)
        // Il 28/08, 204b misurava `cursorAsks` 2 → 2 e leggeva `arrow` sopra
        // una parola: dentro una sola tracking area AppKit non richiama
        // `cursorUpdate`. Si decide quindi anche a ogni movimento, dopo
        // `super`, senza ridisegnare se il link sorvegliato non è cambiato.
        aggiornaCursore(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        sorvegliato = nil
    }

    /// Uscendo dalla finestra o cambiando pagina la mano va tolta comunque:
    /// una pila lasciata piena è un cursore a mano sopra tutta l'app.
    override func viewDidHide() {
        super.viewDidHide()
        sorvegliato = nil
    }

    private func indiceLink(sotto puntoNellaFinestra: NSPoint) -> Int? {
        guard !links.isEmpty else { return nil }
        let dentro = convert(puntoNellaFinestra, from: nil)
        // Il rettangolo delle lettere, non l'indice del carattere: a fine riga
        // `characterIndexForInsertion` risponde con l'ultimo carattere anche
        // quando il puntatore è nel vuoto a destra, e il link si accenderebbe
        // con il puntatore fuori da sé.
        for (indice, link) in links.enumerated() {
            if rect(of: link)?.contains(dentro) == true { return indice }
        }
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Dopo `super`, così la mano vince sull'asta di testo che la vista
        // mette su tutto il contenitore: fra due rettangoli sovrapposti conta
        // l'ultimo aggiunto.
        for link in links {
            guard let box = rect(of: link) else { continue }
            addCursorRect(box, cursor: .pointingHand)
        }
    }

    /// Anche gli ingressi e i cambi di cursor rect passano dalla stessa
    /// decisione di `mouseMoved`: i rettangoli da soli non bastano, perché
    /// `NSTextView` può rimettere l'asta dopo che hanno parlato (suo, 26/08).
    override func cursorUpdate(with event: NSEvent) {
        richiesteCursore += 1
        sorvegliato = indiceLink(sotto: event.locationInWindow)
        aggiornaCursore(convert(event.locationInWindow, from: nil))
    }

    /// Mano sul link, freccia nel vuoto, asta sopra le lettere.
    private func aggiornaCursore(_ punto: NSPoint) {
        // `sorvegliato` è appena stato calcolato dal chiamante: riusarlo evita
        // un secondo giro dei rettangoli a ogni movimento del puntatore.
        if sorvegliato != nil {
            NSCursor.pointingHand.set()
            return
        }
        // La freccia dove non c'è testo, l'asta dove c'è (suo, 27/08: «il
        // cursore normale, a meno che non mi avvicini al testo»).
        //
        // `NSTextView` mette l'asta su TUTTO il contenitore, che in un
        // terminale è la cosa giusta — ogni cella può contenere testo, ed è
        // il motivo per cui iTerm si comporta così e per cui la griglia resta
        // com'è. Questa è una pagina, dove il testo occupa una frazione della
        // superficie: sotto l'ultima riga e a destra di una riga corta non
        // c'è niente da selezionare, e l'asta lì è una promessa falsa.
        //
        // La misura è la riga PIÙ CORTA possibile, cioè il rettangolo davvero
        // occupato dalle lettere di quella riga (`lineFragmentUsedRect`), non
        // il fragment intero, che arriva sempre al bordo destro.
        if !sopraDelTesto(punto) {
            NSCursor.arrow.set()
            return
        }
        NSCursor.iBeam.set()
    }

    /// Il punto sta sopra delle lettere davvero disegnate?
    private func sopraDelTesto(_ punto: NSPoint) -> Bool {
        guard let manager = layoutManager, let container = textContainer,
              manager.numberOfGlyphs > 0 else { return false }
        let origine = textContainerOrigin
        let dentro = NSPoint(x: punto.x - origine.x, y: punto.y - origine.y)
        let indice = manager.glyphIndex(for: dentro, in: container,
                                        fractionOfDistanceThroughGlyph: nil)
        let usata = manager.lineFragmentUsedRect(forGlyphAt: indice, effectiveRange: nil)
        // Due punti di margine: l'asta deve comparire quando ci sei sopra,
        // non quando ci sei esattamente dentro al pixel.
        return usata.insetBy(dx: -2, dy: -1).contains(dentro)
    }

    /// La riga sotto il nome del file: 1,5 punti nell'accento del tema, due
    /// punti sotto la linea di base.
    ///
    /// Disegnata a mano e non con `.underlineStyle`, che conosce solo
    /// `single`, `thick` e `double` — tre spessori decisi da AppKit, nessuno
    /// dei quali è 1,5 punti, e nessuno dei quali può ingrossare sotto il
    /// puntatore senza saltare da un gradino all'altro.
    override func draw(_ dirtyRect: NSRect) {
        // Quanto si ridisegna, e quante volte: una claim sul ritardo del
        // puntatore è una claim su questi due numeri, e senza di loro la sola
        // strada era guardare un filmato e credere agli occhi.
        disegni += 1
        ultimaArea = Double(dirtyRect.width * dirtyRect.height)
        areaTotale = Double(bounds.width * bounds.height)
        super.draw(dirtyRect)
        guard !links.isEmpty, let layout = layoutManager else { return }
        Theme.current.accentText.setFill()
        for (indice, link) in links.enumerated() {
            let glifi = layout.glyphRange(forCharacterRange: link.range,
                                          actualCharacterRange: nil)
            guard glifi.length > 0, let box = rect(of: link) else { continue }
            let fragment = layout.lineFragmentRect(forGlyphAt: glifi.location,
                                                   effectiveRange: nil)
            let base = fragment.minY + layout.location(forGlyphAt: glifi.location).y
                + textContainerOrigin.y
            let spessore = indice == sorvegliato
                ? Self.spessoreLinkSorvegliato : Self.spessoreLink
            let riga = NSRect(x: box.minX, y: base + 2,
                              width: box.width, height: spessore)
            riga.fill()
        }
    }
}
