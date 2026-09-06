//  DashModel.swift — what the bottom bar is allowed to say, and where each
//  row sits.
//
//  The bar is six half LINES, three per group, plus three whole ones under
//  them, and every row lives in exactly one of the nine (ISC-104.1, ISC-142).
//  That is the whole model: the layout is the assignment of keys to lines, the
//  order inside a line is the order they are drawn, and dragging a row in the
//  settings is how both are chosen (ISC-104.2). Nothing here knows which rows
//  came from a provider and which the terminal knows by itself — a whole line
//  takes any row, and a provider row drags onto a half line like any other.
//
//  Two rules keep it honest. A key the app no longer ships is dropped when the
//  file is read, and a key the file never mentioned is put back in its default
//  line — so a saved layout can never strand a row outside the six lines, and
//  a new release cannot make one disappear. And a row that is switched off is
//  hidden only while it is calm: a value carrying an alarm comes back on its
//  own (ISC-104.3), because a bar that can hide trouble is worse than no bar.

import Foundation
import TerminalCore

enum DashSlot: String, CaseIterable {
    case left1 = "left-1", left2 = "left-2", left3 = "left-3"
    case right1 = "right-1", right2 = "right-2", right3 = "right-3"
    case facts1 = "facts-1", facts2 = "facts-2", facts3 = "facts-3"

    /// A line is anchored to one edge, or it spans the whole strip. The third
    /// kind is what ISC-142 added, and it exists because a half line is at
    /// most half a window wide: nine real provider rows came out of it as
    /// «LIFEOS 7.40…» and «MEMORY OK · RE…», which is a bar you guess at
    /// rather than read.
    enum Kind { case left, right, full }

    var kind: Kind {
        switch self {
        case .left1, .left2, .left3: return .left
        case .right1, .right2, .right3: return .right
        case .facts1, .facts2, .facts3: return .full
        }
    }

    var isLeft: Bool { kind == .left }

    /// The six half lines, and the three whole ones under them. Written out
    /// rather than counted off `allCases`: how tall a group may grow is the
    /// number of half lines in it, and deriving that from the total is what
    /// would quietly turn a three-row group into a four-row one the day this
    /// enum grew a case.
    static let halves: [DashSlot] = [.left1, .left2, .left3, .right1, .right2, .right3]
    static let fulls: [DashSlot] = [.facts1, .facts2, .facts3]

    /// What the settings calls this line. A person never reads `left-2`.
    var title: String {
        switch self {
        case .left1: return "left · line 1"
        case .left2: return "left · line 2"
        case .left3: return "left · line 3"
        case .right1: return "right · line 1"
        case .right2: return "right · line 2"
        case .right3: return "right · line 3"
        case .facts1: return "whole width · line 1"
        case .facts2: return "whole width · line 2"
        case .facts3: return "whole width · line 3"
        }
    }
}

/// Every row the bar can show, with the ONE name a person reads for it.
/// Nothing outside this table may appear on the bar or in the settings, which
/// is what makes "one human label per row" checkable rather than intended.
///
/// The table has two halves. The built-in rows below are what a terminal
/// knows. The other half is DISCOVERED: a facts provider (ISC-139) names its
/// own rows, and each one becomes an entry here the moment it is seen, so it
/// is switchable and draggable by exactly the same code as `Grid size`. Their
/// keys carry a prefix nobody else may use, which is not decoration: the
/// provider's key space is the user's, and `model` from a provider must not
/// silently take over the row that says which model the agent is running.
@MainActor
enum DashCatalog {
    struct Entry {
        let key: String
        let name: String
        /// The short caps label the STRIP prints, as against `name`, which is
        /// the sentence the SETTINGS shows. Both belong here since ISC-149:
        /// the bar now has to draw a row whose reading does not exist yet, and
        /// a label it can only get from the code that had the reading is a
        /// label it cannot get at all. Empty for a provider row, which prints
        /// no caption ever (ISC-139).
        var bar = ""
        /// A row built on the fly while something runs, never stored in a
        /// line: the worker of the demo (ISC-104.3).
        var transient = false
        /// Named by a provider rather than by this table (ISC-139).
        var discovered = false
        /// Named by a provider that ANSWERED, as against a key read back out
        /// of `dash-slots` when the file was loaded. The two are the same row
        /// as far as the layout is concerned — that is the whole point of
        /// putting the file's keys back in the table before the layout is
        /// repaired — and they are NOT the same for ISC-192: a key still in
        /// the file of somebody who has since removed their provider would
        /// otherwise hide the native row for good, and hide it behind a ghost
        /// that draws nothing (ISC-143). A native gives way to a reading, not
        /// to a memory of one.
        var live = false
    }

    /// `fact-` and not `fact:` or `fact.`: this key is written into
    /// `dash-slots`, where `:` separates a line from its rows and `,` and `|`
    /// separate the rows and the lines. A prefix that collides with the file's
    /// own punctuation would corrupt the saved layout of the WHOLE bar the
    /// first time a provider appeared, which is the kind of defect that shows
    /// up as "my bar reset itself" three days later.
    static let factPrefix = "fact-"
    static func factKey(_ raw: String) -> String { factPrefix + raw }
    static func isFact(_ key: String) -> Bool { key.hasPrefix(factPrefix) }
    /// The provider's own key, back out of ours.
    static func rawFactKey(_ key: String) -> String {
        isFact(key) ? String(key.dropFirst(factPrefix.count)) : key
    }

    static let builtins: [Entry] = [
        Entry(key: "blocks", name: "Command blocks", bar: "BLOCKS"),
        Entry(key: "failed", name: "Failed commands", bar: "FAILED"),
        Entry(key: "turns", name: "Agent turns", bar: "TURNS"),
        Entry(key: "state", name: "Session state", bar: "STATE"),
        Entry(key: "scrollback", name: "Scrollback", bar: "SCROLLBACK"),
        Entry(key: "grid", name: "Grid size", bar: "GRID"),
        Entry(key: "dir", name: "Directory", bar: "DIR"),
        Entry(key: "proc", name: "Foreground process", bar: "PROC"),
        Entry(key: "agent", name: "Agent", bar: "AGENT"),
        Entry(key: "model", name: "Model", bar: "MODEL"),
        // Le tre righe che un terminale sa da sé leggendo il file della
        // sessione, senza nessun fornitore configurato (ISC-172). Si chiama
        // «Context» e basta: se un fornitore ne nomina un'altra con lo stesso
        // nome, `uniqueName` marca la SUA come «Context (provider)», che è il
        // verso giusto — la riga nativa esiste per chiunque, quella del
        // fornitore solo per chi l'ha installato.
        Entry(key: "context", name: "Context", bar: "CONTEXT"),
        Entry(key: "output", name: "Output tokens", bar: "OUTPUT"),
        Entry(key: "effort", name: "Effort", bar: "EFFORT"),
        Entry(key: "shell", name: "Shell", bar: "SHELL"),
        Entry(key: "blocks-on", name: "Shell integration", bar: "OSC133"),
        Entry(key: "panes", name: "Panes and tabs", bar: "PANES"),
        Entry(key: "theme", name: "Theme", bar: "THEME"),
        Entry(key: "worker", name: "Running work", bar: "WORKER", transient: true),
    ]

    /// What a row is called ON THE BAR. The one place that knows, so a reading
    /// and the dash that stands in for it cannot come out under two different
    /// captions (ISC-149).
    static func bar(of key: String) -> String {
        entries.first { $0.key == key }?.bar ?? ""
    }

    /// The rows a provider named, in the order they were first seen.
    private(set) static var discovered: [Entry] = []

    static var entries: [Entry] { builtins + discovered }

    static func name(of key: String) -> String {
        entries.first { $0.key == key }?.name ?? key
    }

    static var placeable: [String] { entries.filter { !$0.transient }.map(\.key) }

    /// Le tre righe native che un fornitore dichiara una seconda volta, e la
    /// riga del fornitore che le rimpiazza. La tabella sta QUI, in un posto
    /// solo, perché la coppia è un fatto sul catalogo: chi disegna la barra e
    /// chi disegna le impostazioni devono nascondere la stessa riga, e due
    /// elenchi scritti in due file divergono il giorno che ne nasce una terza.
    ///
    /// Il verso è quello di ISC-172 letto al contrario, e i due non si
    /// contraddicono. Le native esistono per chi NON ha un fornitore: senza,
    /// restano tutte. Quando il fornitore le dichiara, la sua è la lettura
    /// vera — sa la scala dei modelli, la finestra di contesto e lo sforzo —
    /// e la nativa diventa un doppione con lo stesso nome («Context» accanto a
    /// «Context (provider)»), cioè due righe che nessuno sa distinguere.
    /// Parole sue, 27/08: «togli la voce model, teniamo solo active model».
    ///
    /// La riga nativa NON esce dal layout: resta dov'è in `dash-slots`, solo
    /// non viene mostrata. Toglierla dal file la farebbe tornare al suo posto
    /// di default il giorno che il fornitore sparisce, e sarebbe l'app che
    /// riordina la barra di qualcun altro senza che nessuno l'abbia chiesto.
    static let twins: [String: String] = [
        "model": "active",
        "context": "context",
        "effort": "effort",
    ]

    /// La gemella di questa riga nativa ha parlato, adesso, in questa corsa.
    static func isSuperseded(_ key: String) -> Bool {
        guard let raw = twins[key] else { return false }
        let twin = factKey(raw)
        return discovered.contains { $0.key == twin && $0.live }
    }

    /// Le native da nascondere adesso, per chi deve toglierle in blocco.
    static var superseded: [String] { twins.keys.filter { isSuperseded($0) } }

    /// Take note of a row a provider named. Returns true when the table
    /// changed, which is what tells the settings window it has a row to draw
    /// that was not there a second ago.
    ///
    /// A label is a name a PERSON reads, and two rows with the same name are
    /// two rows nobody can tell apart — in the settings, and in the bench that
    /// presses switches by name. So a label that is already taken is marked as
    /// coming from the provider instead of being allowed to shadow the row
    /// that had it.
    ///
    /// `live` is the caller saying whether this came from a provider that
    /// answered or from the configuration file. It only ever goes up: a row
    /// that has spoken once has spoken, and a later read of the file must not
    /// take that back. A row that goes live is a CHANGE even when its name is
    /// the one it already had — the settings has a native row to stop drawing.
    @discardableResult
    static func discover(_ rawKey: String, label: String? = nil, live: Bool = false) -> Bool {
        guard FactsFeed.isValidKey(rawKey) else { return false }
        let key = factKey(rawKey)
        let wanted = uniqueName(for: label?.isEmpty == false ? label! : rawKey.capitalized,
                                excluding: key)
        if let at = discovered.firstIndex(where: { $0.key == key }) {
            let wasLive = discovered[at].live
            guard discovered[at].name != wanted || (live && !wasLive) else { return false }
            discovered[at] = Entry(key: key, name: wanted, discovered: true, live: wasLive || live)
            return true
        }
        discovered.append(Entry(key: key, name: wanted, discovered: true, live: live))
        return true
    }

    private static func uniqueName(for wanted: String, excluding key: String) -> String {
        let taken = entries.filter { $0.key != key }.map(\.name)
        guard taken.contains(wanted) else { return wanted }
        let marked = "\(wanted) (provider)"
        guard taken.contains(marked) else { return marked }
        var index = 2
        while taken.contains("\(marked) \(index)") { index += 1 }
        return "\(marked) \(index)"
    }

    /// Only for a bench that wants the table it started with.
    static func forgetDiscovered() { discovered.removeAll() }

    static let defaults: [DashSlot: [String]] = [
        .left1: ["blocks", "failed", "turns", "state"],
        .left2: ["scrollback", "grid"],
        .left3: [],
        .right1: ["dir", "proc", "agent", "model"],
        // Le tre di ISC-172 stanno in coda a questa linea, non su `right-3`
        // che è vuota, e la scelta è stata MISURATA sul bundle vero a quattro
        // larghezze (25/08, `dash-slots` diversi, stesso binario):
        //
        //     larghezza   in coda a right-2      su right-3
        //      1512 px    2 righe, 0 tagli       3 righe, 0 tagli
        //      1180 px    3 righe, 1 taglio      3 righe, 1 taglio
        //      1000 px    3 righe, 1 taglio      3 righe, 1 taglio
        //       900 px    3 righe, `model` fuori 3 righe, `model` fuori
        //
        // Identiche ovunque tranne che a finestra larga, dove una linea nuova
        // costa una riga di finestra e questa no. Sotto, la barra apre la
        // terza riga da sé perché la linea è piena, che è il comportamento
        // normale e non una scelta: la differenza è che qui la paga solo chi
        // ha la finestra stretta, e su `right-3` la pagherebbero tutti.
        .right2: ["shell", "blocks-on", "panes", "theme",
                  "context", "output", "effort"],
        // Resta vuota, ed è dove trascinarle chi le vuole su una riga loro.
        // `DashLayout.repaired` rimette al suo posto di default ogni chiave
        // che un layout salvato non conosce, quindi le tre nuove compaiono da
        // sole anche in una configurazione scritta prima che esistessero,
        // senza che nessuno tocchi il proprio file.
        .right3: [],
        // The three whole lines start empty, and they are empty in a way the
        // half lines are not: nothing a TERMINAL knows lives here. They are
        // where a provider's readings land (ISC-142), and with no provider
        // configured they hold nothing, draw nothing, and cost the bar not one
        // point of height.
        .facts1: [],
        .facts2: [],
        .facts3: [],
    ]

    /// How many provider rows a whole line is given before the next one is
    /// started. Four is not a round number picked for tidiness: it is the
    /// density this app already chose for itself, since `left-1`, `right-1`
    /// and `right-2` each hold exactly four built-in rows.
    static let factsPerLine = 4
}

/// The bar's layout: which line each row is on, and which rows are off.
@MainActor
struct DashLayout {
    private(set) var slots: [DashSlot: [String]]
    var off: Set<String>

    init(slots: [DashSlot: [String]] = DashCatalog.defaults, off: Set<String> = []) {
        self.slots = DashLayout.repaired(slots)
        // OFF accetta anche le voci transitorie (worker): non stanno su
        // nessuna riga, ma «non mostrarla» è una scelta legittima quanto per
        // le altre (25/08, sua segnalazione: worker non era rimovibile).
        self.off = off.filter { key in DashCatalog.entries.contains { $0.key == key } }
    }

    func keys(in slot: DashSlot) -> [String] { slots[slot] ?? [] }

    func slot(of key: String) -> DashSlot? {
        DashSlot.allCases.first { keys(in: $0).contains(key) }
    }

    /// Moves a row to `slot`, landing it before `before` or at the end.
    /// A move is always a REMOVE then an INSERT, so a row cannot end up on two
    /// lines however the drag was made.
    mutating func move(_ key: String, to slot: DashSlot, before: String?) {
        guard DashCatalog.placeable.contains(key) else { return }
        for candidate in DashSlot.allCases {
            slots[candidate]?.removeAll { $0 == key }
        }
        var line = slots[slot] ?? []
        if let before, let index = line.firstIndex(of: before) {
            line.insert(key, at: index)
        } else {
            line.append(key)
        }
        slots[slot] = line
    }

    /// Every placeable key sits on exactly one line, always: unknown keys go,
    /// duplicates go, and anything the file forgot comes back where it began.
    private static func repaired(_ saved: [DashSlot: [String]]) -> [DashSlot: [String]] {
        var out: [DashSlot: [String]] = [:]
        var placed = Set<String>()
        for slot in DashSlot.allCases {
            out[slot] = (saved[slot] ?? []).filter { key in
                guard DashCatalog.placeable.contains(key), !placed.contains(key) else { return false }
                placed.insert(key)
                return true
            }
        }
        for slot in DashSlot.allCases {
            for key in DashCatalog.defaults[slot] ?? [] where !placed.contains(key) {
                out[slot]?.append(key)
                placed.insert(key)
            }
        }
        return out
    }

    // MARK: - The file

    /// `left-1:blocks,failed|right-1:dir` — one line of TOML, readable by a
    /// person, which is the only kind of configuration this app has.
    var encoded: String {
        DashSlot.allCases
            .map { "\($0.rawValue):\(keys(in: $0).joined(separator: ","))" }
            .joined(separator: "|")
    }

    static func decode(_ text: String, off offText: String) -> DashLayout {
        var slots: [DashSlot: [String]] = [:]
        for chunk in text.split(separator: "|") {
            let parts = chunk.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let slot = DashSlot(rawValue: String(parts[0])) else { continue }
            let keys = parts.count > 1
                ? parts[1].split(separator: ",").map(String.init).filter { !$0.isEmpty }
                : []
            slots[slot] = keys
        }
        // An empty or unreadable line is not a layout: fall back to the
        // defaults rather than to six empty lines, which would read as "the
        // user turned the whole bar off".
        let resolved = slots.values.contains { !$0.isEmpty } ? slots : DashCatalog.defaults
        let off = Set(offText.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        // A provider row the file remembers is put back in the table BEFORE
        // the layout is repaired. Without this the first launch of the day
        // drops every provider row — the file is read seconds before the
        // provider is first run, so at that moment the key is unknown, and an
        // unknown key is exactly what `repaired` throws away. The user would
        // see their arrangement quietly reset itself, once, at every launch.
        for key in resolved.values.flatMap({ $0 }) + Array(off)
        where DashCatalog.isFact(key) {
            DashCatalog.discover(DashCatalog.rawFactKey(key))
        }
        return DashLayout(slots: resolved, off: off)
    }

    static func load(from config: Configuration) -> DashLayout {
        decode(config.string(.dashSlots), off: config.string(.dashOff))
    }

    func save(to config: Configuration) {
        config.set(.dashSlots, encoded)
        config.set(.dashOff, off.sorted().joined(separator: ","))
    }
}

