//  ChatPageView.swift — la conversazione DENTRO il pannello (ISC-169).
//
//  Sua richiesta del 25/08: «non voglio che venga mostrato su una pagina a
//  parte il codice; voglio che si srotoli all'interno della finestra del
//  terminale quando clicco, e che venga richiuso quando clicco di nuovo su un
//  qualunque punto del blocco srotolato. Però deve permettermi di selezionare
//  il testo».
//
//  Perché non si piegano le righe del terminale, che sarebbe la strada
//  ovvia e che il terminale sa già fare (ISC-94). Misurato sull'app viva il
//  25/08: con `claude` davanti il pannello riporta `alternateScreen: true`,
//  cioè quel programma possiede TUTTO lo schermo e lo ridipinge quando gli
//  pare. Una piega può coprire solo la storia, quindi il backend la scarta
//  (il dump diceva `foldedTurns: [1]` e `folds: []`) e `PaneView` non annota
//  affatto lo schermo alternato. Non è una cosa che ci manca: è una cosa che
//  quel programma non permette.
//
//  Quindi la pagina la disegniamo noi, dal transcript che l'adattatore già
//  legge. Il terminale vero resta sotto, vivo, a un tasto di distanza: questa
//  vista non lo sostituisce, lo copre — come la bolla copre la riga
//  d'ingresso di `claude` da ISC-114.

import AppKit
import TerminalCore

@MainActor
final class ChatPageView: NSView, ThemeAware, LanguageAware {
    private let scroller = NSScrollView()
    private let text = ReaderText()
    private var areaVuoto: NSTrackingArea?

    /// I blocchi aperti in questo momento, per id di passo. Vive qui e non
    /// nel modello: è uno stato di lettura, e due pannelli che mostrano lo
    /// stesso turno possono averlo aperto in modi diversi.
    private var aperti: Set<String> = []
    /// I turni che hanno già ricevuto la loro apertura d'ufficio, così la
    /// regola «apri il blocco fallito» si applica una volta e non riapre
    /// quello che tu hai chiuso a mano.
    private var giaVisti: Set<Int> = []
    private var righe: [TurnProse.Riga] = []
    private var inizioTurno: [Int: Int] = [:]
    private var turns: [AgentTurn] = []
    /// La frase viva letta una volta dalla sessione; fa parte del confronto
    /// visibile perché l'animazione deve arrivare alla pagina (ISC-229).
    private var attesa: String?

    /// Il click sul nome di un file scritto dall'agente (ISC-175). Chi lo
    /// riceve apre l'anteprima; questa vista non sa che cosa sia
    /// un'anteprima, e non deve saperlo.
    var onOpenFile: ((TurnProse.Collegamento) -> Void)?

    /// Una selezione col mouse è finita (ISC-197). Questa vista non sa cosa
    /// siano gli appunti: passa il testo e basta.
    var onSelection: ((String) -> Void)? {
        get { text.onSelection }
        set { text.onSelection = newValue }
    }

    /// Un file lasciato cadere sulla pagina. Torna `true` se chi riceve se
    /// l'è preso: la pagina non sa cosa sia una riga d'ingresso.
    var onDrop: (([String]) -> Bool)?

    /// Un click che non ha aperto niente e non ha selezionato niente. La
    /// pagina copre la riga d'ingresso del programma, quindi un click qui
    /// sopra non deve lasciare la tastiera in un posto che non scrive (suo,
    /// 27/08: «devo per forza andare dentro la bolla»).
    var onPlainClick: (() -> Void)?

    /// La selezione viva, se c'è: ⌘C la chiede a questa vista invece che al
    /// terminale, che non sa niente di quello che è scritto qui (27/08).
    var selezione: String? {
        let scelta = text.selectedRange()
        guard scelta.length > 0 else { return nil }
        return (text.string as NSString).substring(with: scelta)
    }

    /// Il testo in chiaro, per i banchi: è la stessa stringa che finisce sullo
    /// schermo, non una ricostruzione.
    private(set) var body = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        text.isEditable = false
        // Selezionabile per scelta, ed è sua condizione esplicita: la ragione
        // per cui apri un blocco è quasi sempre riprenderne un pezzo.
        text.isSelectable = true
        text.drawsBackground = false
        text.isRichText = false
        text.textContainerInset = NSSize(width: Theme.Metric.textInset,
                                         height: Theme.Metric.textInset)
        text.textContainer?.lineFragmentPadding = 0
        // Il click su una riga di blocco va intercettato QUI e non sulla vista
        // che contiene il testo: AppKit consegna il click alla vista più
        // profonda, e un `mouseDown` sul contenitore vede solo i click FUORI
        // dal testo (misurato il 25/08 su due click veri che non aprivano
        // niente).
        text.onClick = { [weak self] punto in
            guard let self else { return false }
            if self.tocca(punto) { return true }
            // Un click nel vuoto della pagina: non apre niente, quindi
            // restituisce la tastiera a chi scrive davvero.
            self.onPlainClick?()
            return false
        }
        registerForDraggedTypes(DroppedItems.types)
        scroller.drawsBackground = false
        scroller.borderType = .noBorder
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        scroller.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroller)
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scroller.documentView = text
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    /// Un file lasciato sulla PAGINA. Senza questo il drop moriva qui: la
    /// pagina copre il pannello, e il terminale sotto non è un antenato di
    /// questa vista, quindi AppKit non gli consegnava niente (suo, 27/08).
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        accettaDrop(sender.draggingPasteboard)
    }

    /// La decisione, staccata da AppKit: un banco può porgere una lavagna e
    /// misurare cosa fa il drop, mentre cosa fa AppKit con un mouse non si
    /// misura.
    @discardableResult
    func accettaDrop(_ board: NSPasteboard) -> Bool {
        let paths = DroppedItems.paths(from: board)
        guard !paths.isEmpty else { return false }
        return onDrop?(paths) ?? false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyTheme() {
        scroller.scrollerKnobStyle = Theme.current.isLight ? .dark : .light
        disegna()
        needsDisplay = true
    }

    func applyLanguage() { disegna() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.current.pane.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let dentro = text.convert(event.locationInWindow, from: nil)
        // AppKit dovrebbe aver già consegnato questo caso alla vista più
        // profonda. La guardia evita che un futuro cambio della gerarchia
        // trasformi un click sulle parole in un click semplice della pagina.
        if text.bounds.contains(dentro) {
            super.mouseDown(with: event)
            return
        }
        if text.selectedRange().length > 0 {
            // Il vuoto congeda la selezione viva senza copiarla: il 28/08 lui
            // ha chiesto che quel click torni subito alla bolla, non che
            // ripeta il gesto di selezione.
            text.setSelectedRange(NSRange(location: 0, length: 0))
        }
        // Senza una selezione non c'è niente da togliere intenzionalmente.
        onPlainClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let areaVuoto {
            removeTrackingArea(areaVuoto)
        }
        // Al primo aggiornamento non c'è intenzionalmente un'area precedente.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                      .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        areaVuoto = area
    }

    override func cursorUpdate(with event: NSEvent) {
        aggiornaCursoreDelVuoto(event)
    }

    override func mouseMoved(with event: NSEvent) {
        aggiornaCursoreDelVuoto(event)
    }

    private func aggiornaCursoreDelVuoto(_ event: NSEvent) {
        let dentro = text.convert(event.locationInWindow, from: nil)
        // Le due tracking area si sovrappongono, quindi sopra ReaderText il
        // contenitore tace: mano, asta e freccia restano una sua decisione.
        guard !text.bounds.contains(dentro) else { return }
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let contenitore = text.superview else { return }
        let pagina = convert(text.frame, from: contenitore)
        guard bounds.intersects(pagina) else { return }
        let inizio = max(bounds.minY, pagina.maxY)
        let vuoto = NSRect(x: bounds.minX, y: inizio,
                           width: bounds.width, height: bounds.maxY - inizio)
        guard vuoto.height > 0 else { return }
        // `NSTextView` mette l'asta sul suo contenitore e ReaderText la
        // corregge sulla propria superficie. Sotto il documento non parlava
        // nessuno: misurato il 28/08 come `ibeam` 220 pt sotto l'ultima riga,
        // nel suo video delle 09:41, frame 3.
        addCursorRect(vuoto, cursor: .arrow)
    }

    override func layout() {
        super.layout()
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.autoresizingMask = [.width]
        // La colonna prende TUTTA la finestra e si adatta a lei.
        //
        // C'era una misura fissa di 720 punti, nata quando il testo stava
        // incollato a sinistra: su una finestra larga lasciava mezza app
        // vuota. Prima l'ho centrata, poi allargata fino a 1100, e la sua
        // risposta è stata la terza: nessun tetto, il testo occupa lo spazio
        // che c'è. Quando l'anteprima si prende la colonna di destra questo
        // spazio si stringe da solo, ed è per quello che qui non c'è nessuna
        // domanda sull'anteprima: la larghezza del contenitore è già la
        // risposta (sua decisione, 26/08).
        let base = Theme.Metric.textInset
        let contenuto = scroller.contentSize.width
        text.textContainerInset = NSSize(width: base, height: base)
        text.frame.origin.x = 0
        text.frame.size.width = contenuto
        text.textContainer?.containerSize = NSSize(width: max(0, contenuto - base * 2),
                                                   height: CGFloat.greatestFiniteMagnitude)
    }

    // MARK: - Il modello

    /// I turni da mostrare. Ricompone solo quando qualcosa è davvero cambiato:
    /// l'adattatore ri-legge il transcript a ogni scan, e ridisegnare a ogni
    /// giro farebbe saltare la selezione sotto le dita di chi sta copiando.
    func mostra(turns nuovi: [AgentTurn], attesa nuovaAttesa: String?) {
        guard cambiati(nuovi, attesa: nuovaAttesa) else { return }
        let inFondo = eraInFondo
        turns = nuovi
        attesa = nuovaAttesa
        for turn in nuovi where !giaVisti.contains(turn.id) && turn.finishedAt != nil {
            giaVisti.insert(turn.id)
            aperti.formUnion(TurnProse.daAprireSubito(turn))
        }
        disegna()
        if inFondo { vaiInFondo() }
    }

    /// Due liste di turni sono «le stesse» quando nessuna delle cose che si
    /// vedono è cambiata. Il confronto è sul disegnato, non sull'oggetto:
    /// `AgentTurn` non è `Equatable` e renderlo tale legherebbe il modello a
    /// questa vista.
    private func cambiati(_ nuovi: [AgentTurn], attesa nuovaAttesa: String?) -> Bool {
        guard nuovaAttesa == attesa else { return true }
        guard nuovi.count == turns.count else { return true }
        for (a, b) in zip(nuovi, turns) {
            if a.id != b.id || a.prompt != b.prompt || a.answer != b.answer
                || a.failed != b.failed || a.finishedAt != b.finishedAt
                || a.steps.count != b.steps.count || a.followUps != b.followUps { return true }
            for (p, q) in zip(a.steps, b.steps) where p.id != q.id || p.title != q.title
                || p.detail != q.detail || p.isError != q.isError { return true }
        }
        return false
    }

    /// Ridisegna la pagina con gli attributi di ADESSO.
    ///
    /// `mostra(turns:attesa:)` si ferma quando i turni non sono cambiati, ed è
    /// giusto: ridisegnare a ogni battito costa. Ma ⌘+ non cambia i turni,
    /// cambia le misure, quindi senza questa porta lo zoom non arrivava mai
    /// alla pagina (suo, 27/08).
    func ridisegna() { disegna() }

    private func disegna() {
        let pagina = TurnProse.componi(turns: turns, aperti: aperti, attesa: attesa)
        righe = pagina.righe
        inizioTurno = pagina.inizioTurno
        body = pagina.chiaro
        text.links = pagina.collegamenti
        let dove = scroller.contentView.bounds.origin
        text.textStorage?.setAttributedString(pagina.testo)
        // Aprire un blocco non deve riportarti in cima: quello che stavi
        // guardando è la ragione per cui hai cliccato.
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        scroller.contentView.scroll(to: dove)
    }

    // MARK: - Il tocco

    /// Torna `true` quando il click apparteneva a un blocco: la riga lo apre o
    /// lo chiude, e un click DENTRO un blocco aperto lo richiude, ma solo se
    /// non hai selezionato niente — altrimenti copiare il codice te lo
    /// chiuderebbe in faccia, ed è la condizione che ha posto lui.
    private func tocca(_ puntoNellaFinestra: NSPoint) -> Bool {
        let dentro = text.convert(puntoNellaFinestra, from: nil)
        // Il nome del file PRIMA della riga, perché sta dentro la riga: due
        // bersagli concentrici, e il più piccolo vince (ISC-175). Si guarda il
        // rettangolo delle lettere e non l'indice del carattere, così un click
        // nel vuoto a destra della riga non conta come click sul nome.
        if let link = text.links.first(where: {
            text.rect(of: $0)?.contains(dentro) == true
        }) {
            onOpenFile?(link)
            return true
        }
        guard !righe.isEmpty else { return false }
        let indice = text.characterIndexForInsertion(at: dentro)
        guard let colpita = riga(contenente: indice) else { return false }
        if aperti.contains(colpita.stepID) { aperti.remove(colpita.stepID) }
        else { aperti.insert(colpita.stepID) }
        disegna()
        return true
    }

    /// La riga di blocco a cui appartiene un carattere: la sua intestazione,
    /// oppure il corpo srotolato che le sta sotto, che arriva fino
    /// all'intestazione successiva.
    private func riga(contenente indice: Int) -> TurnProse.Riga? {
        var trovata: TurnProse.Riga?
        for riga in righe {
            if indice < riga.range.location { break }
            trovata = riga
        }
        guard let trovata else { return nil }
        // Un click sotto l'ultimo blocco, cioè dentro la risposta, non
        // appartiene a nessun blocco: si ferma al primo passo chiuso.
        if !aperti.contains(trovata.stepID),
           indice >= trovata.range.location + trovata.range.length { return nil }
        return trovata
    }

    // MARK: - Portarsi su un turno (dalla colonna di destra)

    /// Il click su un turno nella mappa: ci si porta sopra e si aprono i
    /// blocchi che vale la pena vedere. È la stessa regola del lettore, in una
    /// pagina che non copre niente.
    func vai(a turnID: Int) {
        if let turn = turns.first(where: { $0.id == turnID }) {
            aperti.formUnion(TurnProse.daAprireSubito(turn))
            disegna()
        }
        guard let inizio = inizioTurno[turnID], let layout = text.layoutManager,
              let container = text.textContainer else { return }
        let glifo = layout.glyphIndexForCharacter(at: inizio)
        let rect = layout.lineFragmentRect(forGlyphAt: glifo, effectiveRange: nil)
        let y = max(0, rect.minY - Theme.Metric.textInset)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroller.reflectScrolledClipView(scroller.contentView)
    }

    // MARK: - Lo scorrimento

    /// Sei in fondo, o hai scorso indietro a leggere? Serve a decidere se
    /// l'arrivo di nuovo testo deve trascinarti giù: se stavi leggendo un
    /// turno vecchio, no.
    private var eraInFondo: Bool {
        let clip = scroller.contentView.bounds
        guard let documento = scroller.documentView else { return true }
        return clip.maxY >= documento.bounds.height - 24
    }

    private func vaiInFondo() {
        guard let documento = scroller.documentView else { return }
        let y = max(0, documento.bounds.height - scroller.contentView.bounds.height)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroller.reflectScrolledClipView(scroller.contentView)
    }

    // MARK: - Il banco

    /// Un rettangolo del testo portato sul DISPLAY, che è l'unico sistema di
    /// coordinate a cui si può mirare un click posato da fuori dall'app.
    private func schermo(_ box: NSRect) -> [String: Double] {
        let inFinestra = text.convert(box, to: nil)
        let suSchermo = window?.convertToScreen(inFinestra) ?? inFinestra
        return ["x": Double(suSchermo.midX), "y": Double(suSchermo.midY),
                "w": Double(suSchermo.width), "h": Double(suSchermo.height)]
    }

    /// Il contenitore sul display: il banco deve provare che il punto del
    /// 28/08 è davvero sotto il documento ma ancora dentro la pagina.
    private func schermoDelContenitore(_ box: NSRect) -> [String: Double] {
        let inFinestra = convert(box, to: nil)
        let suSchermo = window?.convertToScreen(inFinestra) ?? inFinestra
        return ["x": Double(suSchermo.midX), "y": Double(suSchermo.midY),
                "w": Double(suSchermo.width), "h": Double(suSchermo.height)]
    }

    /// Il rettangolo dell'INTESTAZIONE del blocco a cui appartiene un link,
    /// meno le lettere del nome: è dove il banco clicca per provare che il
    /// resto della riga apre il blocco invece dell'anteprima. Si prende la
    /// parte a sinistra del nome, che è il nome dello strumento e c'è sempre.
    /// Il rettangolo di un intervallo di caratteri, chiesto all'impaginazione
    /// dopo averla pretesa: lo stesso rito di `rigaDiSchermo`, e per la stessa
    /// ragione, cioè che un rettangolo calcolato prima che il testo sia
    /// impaginato esce a origine zero.
    private func rettangolo(di range: NSRange) -> NSRect? {
        guard let layout = text.layoutManager, let container = text.textContainer,
              range.length > 0 else { return nil }
        layout.ensureLayout(for: container)
        let glifo = layout.glyphIndexForCharacter(at: range.location)
        var box = layout.lineFragmentRect(forGlyphAt: glifo, effectiveRange: nil)
        box.origin.x += text.textContainerInset.width
        box.origin.y += text.textContainerInset.height
        return box
    }

    private func rigaDiSchermo(_ link: TurnProse.Collegamento) -> NSRect? {
        // Dal FRAMMENTO di riga del primo glifo del nome, non da un intervallo
        // di caratteri. Il 26/08 alle 02:50 il rettangolo «della riga»
        // calcolato sull'intervallo (inizio riga → inizio nome) usciva a
        // origine zero dopo che l'anteprima aveva ristretto la colonna e
        // ri-impaginato il testo: convertito con lo scorrimento finiva SOPRA
        // la pagina, nella banda, e il banco cliccava lì (polo 4 rosso,
        // «sotto il puntatore: BandView»). Il frammento di riga si chiede a
        // un glifo solo, dopo aver preteso l'impaginazione, e sta sempre
        // dove sta il nome: la parte a sinistra del nome è il nome dello
        // strumento, che c'è sempre.
        guard let nome = text.rect(of: link), let layout = text.layoutManager,
              let container = text.textContainer else { return nil }
        layout.ensureLayout(for: container)
        let glifo = layout.glyphIndexForCharacter(at: link.range.location)
        var frammento = layout.lineFragmentUsedRect(forGlyphAt: glifo, effectiveRange: nil)
        frammento.origin.x += text.textContainerOrigin.x
        frammento.origin.y += text.textContainerOrigin.y
        let sinistra = NSRect(x: frammento.minX, y: frammento.minY,
                              width: nome.minX - 4 - frammento.minX,
                              height: frammento.height)
        // Su una riga andata a capo il nome può stare all'inizio del suo
        // frammento: allora non c'è un «resto della riga» a sinistra, e il
        // banco lo deve sapere invece di cliccare il nome credendo di
        // cliccare la riga.
        guard sinistra.width > 12 else { return nil }
        return sinistra
    }

    var testState: [String: Any] {
        ["showing": !isHidden,
         "turns": turns.count,
         "followUps": turns.reduce(0) { $0 + $1.followUps.count },
         "followUpTurns": turns.filter { !$0.followUps.isEmpty }.map(\.id),
         "emptyPrompts": turns.filter { $0.prompt.isEmpty && !$0.isLocalCommand }.count,
         "chars": body.count,
         // La geometria della colonna, che è l'unica cosa misurabile della
         // regola «il testo prende tutta la finestra»: dove comincia, quanto
         // è largo, e quanto spazio c'era da prendere.
         "columnX": Double(text.textContainerInset.width),
         "columnW": Double(text.textContainer?.containerSize.width ?? 0),
         "hostW": Double(scroller.contentSize.width),
         "openSteps": Array(aperti).sorted(),
         "steps": turns.flatMap { turn in
             TurnProse.mostrati(turn).map { passo in
                 var voce: [String: Any] = [
                     "turn": turn.id, "id": passo.id, "kind": passo.kind.rawValue,
                     "title": passo.title, "detailChars": passo.detail.count,
                     "open": aperti.contains(passo.id)]
                 // Solo quando ce l'ha: un `Optional` infilato in `Any` rompe
                 // la serializzazione di TUTTO il dump, non solo di sé stesso.
                 if let path = passo.filePath { voce["filePath"] = path }
                 return voce
             }
         },
         // I link, con le lettere del nome DOVE STANNO SULLO SCHERMO: è quello
         // che serve al banco per mettere il puntatore sul nome del file e
         // cliccarlo davvero, e accanto il rettangolo della riga intera, per
         // il polo gemello — un click sul resto della riga apre il blocco e
         // non l'anteprima.
         "links": text.links.compactMap { link -> [String: Any]? in
             guard let box = text.rect(of: link) else { return nil }
             return ["stepID": link.stepID, "path": link.path,
                     "name": (link.path as NSString).lastPathComponent,
                     "link": schermo(box),
                     "row": schermo(rigaDiSchermo(link) ?? box),
                     // Sta nella parte VISIBILE della pagina? Un link scorso
                     // via ha coordinate di schermo perfettamente calcolate e
                     // perfettamente inutili: sopra la pagina, nella banda, o
                     // fuori dalla finestra. Il 26/08 il banco ha cliccato lì
                     // per tre corse (la pagina scorre in fondo a ogni turno
                     // nuovo) e il dump non aveva modo di dirglielo.
                     "visible": scroller.documentVisibleRect.intersects(box)]
         },
         // La riga che riassume il lavoro di un turno, col rettangolo sullo
         // schermo: il banco ci clicca sopra davvero per aprirla, e senza
         // questo dovrebbe indovinare un punto.
         "groups": righe.filter { $0.stepID.hasPrefix("gruppo-") }
             .compactMap { riga -> [String: Any]? in
                 guard let box = rettangolo(di: riga.range) else { return nil }
                 return ["id": riga.stepID, "turn": riga.turnID,
                         "open": aperti.contains(riga.stepID),
                         "label": (text.string as NSString)
                             .substring(with: riga.range)
                             .trimmingCharacters(in: .newlines),
                         "row": schermo(box),
                         "visible": scroller.documentVisibleRect.intersects(box)]
             },
         // Il disegno: quante volte e quanta superficie. Il puntatore che
         // scorre sopra un link deve ridisegnare una riga, non la pagina.
         // La pagina intera sullo schermo: dove un banco può cliccare per
         // darle la tastiera senza toccare un link né una riga (ISC-198).
         "page": schermo(text.bounds),
         "host": schermoDelContenitore(bounds),
         "draws": text.disegni,
         "hovered": text.linkSorvegliato ?? -1,
         "cursorAsks": text.richiesteCursore,
         "lastDrawArea": Int(text.ultimaArea),
         "viewArea": Int(text.areaTotale),
         "scrollY": Int(scroller.contentView.bounds.origin.y),
         // Quanto testo è selezionato adesso. Serve al banco che prova la sua
         // condizione — «selezionare non deve chiudere» — perché senza questo
         // numero un click che non chiude e un click che non è mai arrivato
         // sono la stessa riga di risultato.
         "selectedChars": text.selectedRange().length,
         // Quanto è ALTO il testo impaginato, che è la sola cosa che cambia
         // quando cambia la misura del carattere: il rettangolo della vista
         // no, quello lo decide il layout della finestra, ed è per questo che
         // il primo polo dello zoom era verde su una pagina che non era
         // cambiata (27/08).
         "textHeight": Int((text.layoutManager?.usedRect(
             for: text.textContainer ?? NSTextContainer()).height ?? 0).rounded())]
    }
}
