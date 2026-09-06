//  PreviewSurface.swift — il file che l'agente ha appena scritto, dentro
//  l'app (ISC-176).
//
//  QuickLook e non un visualizzatore nostro: è il motore che il Mac usa già
//  per la barra spaziatrice nel Finder, quindi conosce markdown, PDF,
//  immagini, codice e testo senza che noi si scriva un renderer per ognuno, e
//  soprattutto **non ha rete e non ha sessioni** — legge un file dal disco e
//  lo disegna. È la preferenza sua del 20/08: anteprime locali con i motori
//  nativi del sistema, mai una webview con una sessione dentro l'app.
//
//  DAL DISCO, AL MOMENTO DEL CLICK. Il transcript contiene quello che l'agente
//  ha scritto in quel momento; questa superficie mostra il file com'è ADESSO,
//  che è una cosa diversa e più utile — nel frattempo può averlo cambiato un
//  altro turno, un altro agente, o la persona che sta guardando. Se il file
//  non c'è più lo dice in una riga e non ricostruisce niente.
//
//  UNA SOLA, IN DUE POSTI. La stessa vista sta nel pannello destro o al centro
//  come carta: cambia il contenitore, non l'oggetto, e il file non si rilegge
//  nel passaggio. Il contatore `reads` esiste proprio per poterlo dimostrare.
//
//  SOLA LETTURA, PER SEMPRE. Niente qui dentro scrive un file, da nessuna
//  parte: si passa un URL a QuickLook e si guarda.

import AppKit
import Quartz
import TerminalCore

@MainActor
final class PreviewSurface: FlushPanel, NSViewToolTipOwner, LanguageAware {
    /// Dove sta l'anteprima adesso. Il default è il pannello e non esiste una
    /// preferenza che lo cambi: portarla davanti è un gesto, non
    /// un'impostazione (sua decisione, 26/08 01:00).
    enum Placement: String { case panel, front }

    /// La vista di QuickLook, che NASCE A OGNI FILE e muore quando si chiude.
    ///
    /// Non è un'ottimizzazione mancata, è l'unica forma che regge, e l'ha
    /// insegnata un crash vero: `QLPreviewView.close()` non «svuota» la vista,
    /// la ritira, e assegnarle un `previewItem` dopo fa alzare a QuickLook un
    /// assert che ABORTISCE il processo — il banco del 26/08 ha chiuso
    /// l'anteprima al polo 11 e riaperta al 12, e il terminale è morto con
    /// `_QLRaiseAssert` in cima allo stack, portandosi via la sessione.
    ///
    /// È anche la regola di casa scritta a caro prezzo altrove (MacAppRules
    /// §0.3): una risorsa condivisa col sistema si tiene aperta per la durata
    /// dell'USO, non per la durata del processo. Fra un file e l'altro qui non
    /// c'è niente che un assert di qualcun altro possa colpire.
    ///
    /// Quello che NON cambia: ridurre, riaprire e portare davanti non toccano
    /// questa vista, quindi il file non si rilegge nel passaggio — che è la
    /// promessa della claim, e il contatore `reads` la misura.
    private var preview: QLPreviewView?
    private let missingNote = NSTextField(labelWithString: "")

    private(set) var path: String?
    private(set) var placement: Placement = .panel
    private(set) var collapsed = false
    private(set) var missing = false
    /// Quante volte un file è stato consegnato a QuickLook da quando l'app è
    /// partita. Ridurre, riaprire e portare davanti NON lo muovono, ed è così
    /// che «non si rilegge nel passaggio» diventa un numero invece di una
    /// promessa (ISC-176).
    private(set) var reads = 0

    var onToggleCollapse: (() -> Void)?
    var onFront: (() -> Void)?
    var onBack: (() -> Void)?
    var onClose: (() -> Void)?

    /// L'altezza della testa. È la stessa fascia che l'ispettore lascia
    /// libera per il suo titolo, così da ridotta questa testa si mette
    /// esattamente al posto di quello e sotto ricomincia la mappa dei turni
    /// (mockup `mock-176-D-ridotta.png`).
    static let headHeight: CGFloat = 36

    // MARK: - I comandi della testa

    /// Un glifo della testa: la lettera che disegna, dove sta, e cosa fa.
    /// Il rettangolo è più grande della lettera perché un comando si clicca
    /// tutto (MacAppRules §3), e il banco ci mira dentro.
    private struct Comando {
        let nome: String
        let glifo: String
        let tooltip: String
        var rect: NSRect = .zero
        let azione: () -> Void
    }

    private var comandi: [Comando] = []
    private var sorvegliato: String? { didSet { needsDisplay = true } }
    private var areaTesta: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        missingNote.font = Theme.uiFont(12)
        missingNote.textColor = Theme.current.whisper
        missingNote.isHidden = true
        missingNote.translatesAutoresizingMaskIntoConstraints = false
        addSubview(missingNote)
        NSLayoutConstraint.activate([
            missingNote.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            missingNote.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            missingNote.topAnchor.constraint(equalTo: topAnchor,
                                             constant: Self.headHeight + 10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Aprire, ridurre, chiudere

    /// Mostra un file, letto dal disco ADESSO.
    ///
    /// Riaprire lo stesso percorso rilegge davvero: `refreshPreviewItem` è lì
    /// perché QuickLook, ricevendo l'URL che ha già, si terrebbe il disegno di
    /// prima — e un'anteprima che mostra il file di dieci minuti fa è
    /// esattamente ciò che questa claim esiste per non fare.
    func show(path nuovo: String) {
        path = nuovo
        collapsed = false
        missing = !FileManager.default.fileExists(atPath: nuovo)
        reads += 1
        ritira()
        if missing {
            missingNote.isHidden = false
            updateMissingNote()
        } else {
            missingNote.isHidden = true
            monta(URL(fileURLWithPath: nuovo))
        }
        needsDisplay = true
    }

    private func updateMissingNote() {
        let name = path.map { ($0 as NSString).lastPathComponent } ?? ""
        missingNote.stringValue = name.isEmpty ? "" : name + S.fileNoLongerOnDisk
    }

    func applyLanguage() {
        guard missing else { return }
        updateMissingNote()
    }

    /// Una vista nuova per questo file, agganciata sotto la testa.
    private func monta(_ url: URL) {
        let vista = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        vista.autostarts = true
        vista.shouldCloseWithWindow = false
        vista.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vista)
        NSLayoutConstraint.activate([
            vista.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            vista.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            vista.topAnchor.constraint(equalTo: topAnchor,
                                       constant: Self.headHeight + 6),
            vista.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        // L'ordine conta: prima in vista, poi il file. E il file si assegna a
        // una vista APPENA NATA, mai a una che ha già visto un `close()`.
        vista.previewItem = url as NSURL
        preview = vista
    }

    /// Spegne e toglie la vista di QuickLook, se ce n'è una.
    private func ritira() {
        guard let vecchia = preview else { return }
        preview = nil
        // `close()` PRIMA di toglierla dalla finestra: senza, resta un
        // processo di anteprima appeso a niente.
        vecchia.close()
        vecchia.removeFromSuperview()
    }

    /// Ridotta: il file resta caricato, la testa resta, il corpo sparisce.
    func setCollapsed(_ chiuso: Bool) {
        guard collapsed != chiuso else { return }
        collapsed = chiuso
        // Nascosta, non ritirata: il file resta caricato, e riaprire non
        // rilegge niente. È la differenza che `reads` misura.
        preview?.isHidden = chiuso
        missingNote.isHidden = chiuso || !missing
        needsDisplay = true
    }

    func setPlacement(_ dove: Placement) {
        guard placement != dove else { return }
        placement = dove
        needsDisplay = true
    }

    /// Chiude davvero: QuickLook va spento con `close()` prima di togliere la
    /// vista, altrimenti resta un processo di anteprima appeso.
    func clear() {
        ritira()
        missingNote.isHidden = true
        path = nil
        missing = false
        collapsed = false
        placement = .panel
        needsDisplay = true
    }

    var isLoaded: Bool { path != nil }

    /// Il nome del file, che è quello che la testa scrive grande.
    var fileName: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }

    // MARK: - La testa

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let palette = Theme.current
        comandi = []

        let nome = NSAttributedString(string: fileName, attributes: [
            .font: Theme.uiFont(12), .foregroundColor: palette.ink,
        ])
        nome.draw(at: NSPoint(x: 14, y: 12))

        // I comandi si dispongono da destra, così aggiungerne uno non sposta
        // gli altri: quello più a destra è sempre lo stesso comando.
        var destra = bounds.width - 8
        func comando(_ nomeComando: String, _ glifo: String, _ tooltip: String,
                     _ azione: @escaping () -> Void) {
            let lato: CGFloat = 24
            let box = NSRect(x: destra - lato, y: 4, width: lato, height: lato)
            destra -= lato
            var voce = Comando(nome: nomeComando, glifo: glifo, tooltip: tooltip,
                               azione: azione)
            voce.rect = box
            comandi.append(voce)
        }

        switch (placement, collapsed) {
        case (.front, _):
            // Due glifi distinti, e la × è l'ultima a destra: in ogni app del
            // Mac la × chiude, quindi il ritorno al lato è un glifo suo
            // (deciso con lui il 26/08 01:15, mockup `mock-176-C-carta.png`).
            comando("close", "✕", "Close") { [weak self] in self?.onClose?() }
            comando("back", "⇥", "Send back to the panel") { [weak self] in
                self?.onBack?()
            }
        case (.panel, false):
            comando("close", "✕", "Close") { [weak self] in self?.onClose?() }
            comando("front", "⤢", "Preview in Front  ⇧⌥⌘P") { [weak self] in
                self?.onFront?()
            }
            comando("collapse", "‹", "Collapse the preview  ⌥⌘P") { [weak self] in
                self?.onToggleCollapse?()
            }
        case (.panel, true):
            comando("collapse", "›", "Reopen the preview  ⌥⌘P") { [weak self] in
                self?.onToggleCollapse?()
            }
        }

        // Il percorso, fra il nome e i comandi, e solo se ci sta: da ridotta
        // la colonna è larga 300 punti e un percorso lì dentro spingerebbe
        // fuori il nome, che è la sola cosa che serve leggere.
        let ultimo = comandi.map(\.rect.minX).min() ?? bounds.width
        let inizioPercorso = 14 + nome.size().width + 8
        if !collapsed, let path {
            let breve = NSAttributedString(string: Self.shorten(path), attributes: [
                .font: Theme.labelFont(10), .foregroundColor: palette.whisper,
            ])
            let spazio = ultimo - 8 - inizioPercorso
            if spazio > 40 {
                breve.draw(in: NSRect(x: inizioPercorso, y: 14,
                                      width: spazio, height: 14))
            }
        }

        for voce in comandi {
            let acceso = sorvegliato == voce.nome
            let glifo = NSAttributedString(string: voce.glifo, attributes: [
                .font: Theme.uiFont(13),
                .foregroundColor: acceso ? palette.ink : palette.muted,
            ])
            let size = glifo.size()
            glifo.draw(at: NSPoint(x: voce.rect.midX - size.width / 2,
                                   y: voce.rect.midY - size.height / 2))
        }

        // La cucitura sotto la testa: il corpo dell'anteprima è quasi sempre
        // carta bianca, e senza un filo la testa ci galleggia sopra.
        palette.hairline.setFill()
        NSRect(x: 12, y: Self.headHeight - 1, width: bounds.width - 24, height: 1).fill()

        rifaiTooltip()
    }

    /// Il percorso come lo dice la banda: casa diventa `~`.
    static func shorten(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Il puntatore

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let areaTesta { removeTrackingArea(areaTesta) }
        let area = NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: bounds.width, height: Self.headHeight),
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self)
        addTrackingArea(area)
        areaTesta = area
    }

    override func mouseMoved(with event: NSEvent) {
        let punto = convert(event.locationInWindow, from: nil)
        sorvegliato = comandi.first { $0.rect.contains(punto) }?.nome
    }

    override func mouseExited(with event: NSEvent) { sorvegliato = nil }

    override func mouseDown(with event: NSEvent) {
        let punto = convert(event.locationInWindow, from: nil)
        if let voce = comandi.first(where: { $0.rect.contains(punto) }) {
            voce.azione()
            return
        }
        // Un click sulla testa fuori dai comandi non fa niente e non passa
        // sotto: la testa è una superficie, non un buco.
        guard punto.y > Self.headHeight else { return }
        super.mouseDown(with: event)
    }

    private func rifaiTooltip() {
        // L'owner è `self`, mai la stringa. `addToolTip` NON trattiene l'owner
        // (sonda del 26/08: riferimento debole a un owner passato lì dentro
        // torna nil a fine scope), e una String Swift lunga o non-ASCII
        // ponteggiata a ObjC è un `__SharedStringStorage` TEMPORANEO che muore
        // subito: il tooltip parlava a memoria liberata. `"Close"` non era mai
        // esploso solo perché è corta e ASCII, quindi diventa un tagged
        // pointer che non si libera. Stessa famiglia del crash di DashView.
        //
        // E si ricostruisce solo quando la serie cambia, per non liberare i
        // tag di AppKit sotto un timer già armato.
        let firma = comandi.map {
            "\($0.nome)|\(Int($0.rect.minX))|\(Int($0.rect.minY))"
                + "|\(Int($0.rect.width))|\(Int($0.rect.height))"
        }
        guard firma != firmaTooltip else { return }
        firmaTooltip = firma
        removeAllToolTips()
        for voce in comandi { addToolTip(voce.rect, owner: self, userData: nil) }
    }

    /// La serie di tooltip registrata adesso, per non rifarla identica.
    private var firmaTooltip: [String] = []

    /// La frase sotto il puntatore, chiesta ad AppKit quando serve invece di
    /// consegnargliela in anticipo: così la stringa vive quanto vive questa
    /// vista.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        comandi.first { $0.rect.contains(point) }?.tooltip ?? ""
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for voce in comandi { addCursorRect(voce.rect, cursor: .pointingHand) }
    }

    // MARK: - Il banco

    var testState: [String: Any] {
        var stato: [String: Any] = [
            "showing": isLoaded && !isHidden,
            "collapsed": collapsed,
            "placement": placement.rawValue,
            "missing": missing,
            "reads": reads,
            "name": fileName,
            "note": missingNote.isHidden ? "" : missingNote.stringValue,
        ]
        if let path { stato["path"] = path }
        // I comandi della testa, col rettangolo sullo SCHERMO: il banco ci
        // clicca davvero sopra, e un comando che non ha disegnato non compare
        // qui — «la × c'è» si legge dall'inchiostro, mai dal fatto che una
        // vista esista.
        stato["controls"] = comandi.reduce(into: [String: Any]()) { out, voce in
            let inFinestra = convert(voce.rect, to: nil)
            let suSchermo = window?.convertToScreen(inFinestra) ?? inFinestra
            out[voce.nome] = ["x": Double(suSchermo.midX), "y": Double(suSchermo.midY),
                              "w": Double(suSchermo.width), "h": Double(suSchermo.height),
                              "glyph": voce.glifo, "tooltip": voce.tooltip]
        }
        return stato
    }
}

/// Il velo e la carta, quando l'anteprima sta davanti (ISC-176).
///
/// Stessa forma del lettore del turno, che è il modello dichiarato nella
/// claim: velo scuro sopra la pagina, carta centrata, e la superficie vera
/// dentro. Non disegna niente dell'anteprima — la ospita e basta, così
/// l'anteprima resta UNA e il file non si rilegge nel passaggio.
@MainActor
final class PreviewFrontView: NSView, ThemeAware {
    /// Un click FUORI dalla carta la rimanda a destra, non la chiude: è la
    /// stessa cosa che fa Esc, e un gesto che chiude per sbaglio un'anteprima
    /// che stavi leggendo è un gesto che costa più di quanto vale.
    var onBack: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyTheme() { needsDisplay = true }

    /// Proporzionale alla finestra, con un tetto: 960×640 è la misura scritta
    /// nella claim, e sotto quella taglia decide la finestra.
    var cardRect: NSRect {
        let width = min(960, max(360, bounds.width - 160))
        let height = min(640, max(240, bounds.height - 120))
        return NSRect(x: ((bounds.width - width) / 2).rounded(),
                      y: ((bounds.height - height) / 2).rounded(),
                      width: width, height: height)
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = cardRect
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
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
    }

    override func mouseDown(with event: NSEvent) {
        let punto = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(punto) else { onBack?(); return }
        super.mouseDown(with: event)
    }
}
