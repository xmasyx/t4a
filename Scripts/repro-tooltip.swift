// Il crash dei tooltip del 26/08 09:33:34, riprodotto in piccolo.
//
//   swift Scripts/repro-tooltip.swift string-owner   # owner = String Swift, registrato UNA volta
//   swift Scripts/repro-tooltip.swift rebuild        # li rifà al ritmo della barra (1s)
//   swift Scripts/repro-tooltip.swift fixed          # owner = self, e li rifà solo se cambiano
//
// Apre una finestrina, ci porta sopra il puntatore VERO (e lo rimette dov'era),
// e resta fermo mentre il timer dei tooltip di AppKit scatta e riscatta.
//
// La sonda della sonda: se il tooltip non è mai COMPARSO (`NSToolTipPanel` fra
// le finestre dell'app) il verde non vale niente, e infatti la prima stesura
// di questo file rifaceva i tip ogni 200ms — cioè disarmava il timer prima di
// ogni scatto e «sopravviveva» senza aver mai misurato niente.
//
// Uscita: 0 sopravvissuto col tooltip visto, 3 non ha mai mostrato un tooltip,
// e il segnale del crash se il difetto c'è.
import AppKit

let mode = CommandLine.arguments.dropFirst().first ?? "fixed"
let durata = Double(CommandLine.arguments.dropFirst(2).first ?? "30") ?? 30

final class Prova: NSView, NSViewToolTipOwner {
    var firma: [String] = []
    override var isFlipped: Bool { true }
    let rect = NSRect(x: 0, y: 0, width: 200, height: 200)

    // La stessa frase del pannello dell'anteprima: lunga e non-ASCII, quindi
    // ponteggiata a ObjC diventa un oggetto vero e non un tagged pointer.
    let frase = "Preview in Front  ⇧⌥⌘P"

    func registra() {
        switch mode {
        case "string-owner":
            removeAllToolTips()
            addToolTip(rect, owner: frase, userData: nil)
        case "rebuild":
            removeAllToolTips()
            addToolTip(rect, owner: self, userData: nil)
        default:
            let f = ["\(rect)"]
            guard f != firma else { return }
            firma = f
            removeAllToolTips()
            addToolTip(rect, owner: self, userData: nil)
        }
        // Memoria che si riprende quello che AppKit ha appena liberato: è il
        // pezzo che trasforma un puntatore penzolante in un salto a zero.
        for _ in 0..<800 { _ = NSMutableArray(array: [NSObject(), NSObject(), NSObject()]) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData: UnsafeMutableRawPointer?) -> String { frase }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 200),
                   styleMask: [.titled], backing: .buffered, defer: false)
let prova = Prova(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
win.contentView = prova
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

let schermo = NSScreen.screens.first!.frame
let quartz = CGPoint(x: win.frame.midX, y: schermo.height - win.frame.midY)
let partenza = CGEvent(source: nil)?.location ?? .zero

func muovi(_ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

prova.registra()
var visto = 0
var giri = 0
// Un micro-movimento ogni tanto: il puntatore fermo per sempre non ri-arma il
// timer dopo che il tooltip si è già mostrato una volta.
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
    giri += 1
    muovi(CGPoint(x: quartz.x + CGFloat(giri % 3), y: quartz.y + CGFloat((giri / 3) % 3)))
    if NSApp.windows.contains(where: { "\(type(of: $0))".contains("ToolTip") }) { visto += 1 }
    if Double(giri) * 0.25 > durata {
        t.invalidate()
        muovi(partenza)
        print("SURVIVED mode=\(mode) tooltipsShown=\(visto) key=\(win.isKeyWindow)")
        exit(visto > 0 ? 0 : 3)
    }
}
// Una vista con `toolTip` che MUORE sotto il puntatore, che è quello che
// succede chiudendo una scheda: i pannelli se ne vanno e le loro viste con
// loro. Serve a sapere se il difetto è solo dell'owner-stringa o di ogni
// tooltip la cui vista sparisce mentre il timer è armato.
if mode == "dying-view" {
    Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { _ in
        prova.subviews.forEach { $0.removeFromSuperview() }
        let effimera = NSView(frame: prova.rect)
        effimera.toolTip = prova.frase
        prova.addSubview(effimera)
        for _ in 0..<800 { _ = NSMutableArray(array: [NSObject(), NSObject(), NSObject()]) }
    }
}

// Al ritmo della striscia in basso, che si ridisegna ogni secondo.
if mode == "rebuild" || mode == "fixed" {
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in prova.registra() }
}
app.run()
