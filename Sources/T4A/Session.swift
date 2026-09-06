//  Session.swift — one pane: a child process, its grid, its blocks, its name.
//
//  A tab holds a split tree of these; the rail lists them. Nothing here knows
//  which VT engine is underneath, which is the point of TerminalCore.

import AgentAdapters
import AppKit
import Foundation
import TerminalCore

@MainActor
final class Session: Identifiable, Hashable {
    let id = UUID()
    let backend: TerminalBackend
    let blocks = CommandBlockLog()

    /// The agent running in this pane, when one is and when the adapter is
    /// switched on. Nil is not a degraded state: it is a terminal, which is
    /// what every pane is before F4 has anything to say (ISC-30).
    let agent: AgentObserver?
    /// Turn rows, once they have been found on the grid. Kept beside the
    /// adapter's turns rather than inside them, because where a turn was
    /// DRAWN is a fact about this terminal and the transcript cannot know it.
    private(set) var turnAnchors: [Int: TurnAnchor] = [:]
    /// Raised when this pane starts waiting for you while you are elsewhere.
    var onWaitingForYou: ((String) -> Void)?
    /// Coalesces the screen scan. Created only when output arrives, so a still
    /// terminal schedules nothing at all (ISC-38).
    private var screenScan: Timer?
    /// A slow exception to ISC-38, alive only while an attached agent still
    /// lacks the pid that the process tree may publish after its last byte.
    private var processAdoptionRetryTimer: Timer?
    private var isAdoptingProcess = false
    private static let processAdoptionRetryInterval: TimeInterval = 2.5
    /// The last value of `isWaitingForYou`, so the notification fires on the
    /// TRANSITION and exactly once. Reading it fresh each time and posting
    /// whenever it was true would put a banner on screen for every byte that
    /// arrived while the session sat waiting.
    private var wasWaitingForYou = false
    /// When the session entered the exact state counted by the band. It is
    /// deliberately derived from `isWaitingForYou`, never from a second
    /// approximation, so the menu's age and the number cannot disagree.
    private(set) var waitingForYouSince: Date?

    /// This finished turn has already been selected with this pane focused.
    /// It survives a later working phase and is replaced only when a new
    /// finish arrives, so merely watching work cannot pre-read its result.
    private(set) var vistaDopoLaFine = false

    private struct FineTurno: Equatable {
        var transcript: URL?
        var id: Int
        var finitoAlle: Date
    }
    private var ultimaFineOsservata: FineTurno?

    private func aggiornaVistaDopoLaFine() {
        let corrente = agent?.isAttached == true ? (agent?.activity ?? .idle) : .idle
        let fineCorrente = agent?.turns.last(where: { $0.finishedAt != nil }).flatMap { turn in
            turn.finishedAt.map {
                FineTurno(transcript: agent?.transcript, id: turn.id, finitoAlle: $0)
            }
        }
        let nuovaFine = corrente == .waiting && fineCorrente != nil
            && fineCorrente != ultimaFineOsservata
        vistaDopoLaFine = FinishedTurnAttention.seenAfterUpdate(
            wasSeen: vistaDopoLaFine,
            activity: corrente,
            isNewFinish: nuovaFine,
            isFocused: isFocused)
        if corrente == .waiting, let fineCorrente {
            ultimaFineOsservata = fineCorrente
        } else if agent?.isAttached != true {
            ultimaFineOsservata = nil
        }
    }

    /// Where one agent turn's question was drawn on this terminal.
    ///
    /// Only the START is remembered. Where a turn ENDS is wherever the next
    /// turn begins, and that is not known when the turn closes — the first
    /// version stored both, the end of every turn was stamped as "the bottom
    /// of the buffer" before its successor existed, and every span overlapped
    /// every later one. A fact that is still moving does not get frozen.
    struct TurnAnchor {
        var promptRow: Int
        /// True when the question's own text was found on that row. A guessed
        /// row is kept so the list has an order, and is never folded on.
        var found: Bool
    }

    /// Turns whose WORK is folded away in the terminal right now (ISC-94).
    private(set) var foldedTurns: Set<Int> = []
    /// Fold every turn as it finishes, rather than one at a time.
    var compactTurns = false {
        didSet {
            guard compactTurns != oldValue else { return }
            if compactTurns { foldAllFinished() } else { foldedTurns.removeAll() }
            applyFolds()
        }
    }

    /// The title the program asked for, or the running program's name.
    private(set) var reportedTitle: String = ""
    private(set) var workingDirectory: URL
    private(set) var hasExited = false
    private(set) var exitCode: Int32?
    /// Rings when something happens the user is not looking at.
    private(set) var hasUnseenActivity = false

    /// Everyone who wants to know when this session moves. A single
    /// callback looked simpler and was wrong: the pane view assigned it after
    /// the window did, and the dashboard silently stopped updating.
    private var observers: [() -> Void] = []
    func observe(_ block: @escaping () -> Void) { observers.append(block) }
    private func notifyChanged() {
        announceWaitingIfNeeded()
        observers.forEach { $0() }
    }

    /// Fires once when this pane starts waiting for you.
    ///
    /// Every path that can change the answer goes through `notifyChanged`, so
    /// this sits there rather than in any one of them: the first version hung
    /// it off the permission scan alone and a turn that simply FINISHED —
    /// which is the ordinary way a session comes to want you — never said
    /// anything at all.
    private func announceWaitingIfNeeded() {
        let waiting = isWaitingForYou
        defer {
            if waiting, !wasWaitingForYou { waitingForYouSince = Date() }
            if !waiting { waitingForYouSince = nil }
            wasWaitingForYou = waiting
        }
        guard waiting, !wasWaitingForYou else { return }
        let reason = agent?.approval?.title ?? (agent?.turns.last?.answer ?? "")
        onWaitingForYou?(reason.isEmpty ? "waiting for you"
            : String(reason.replacingOccurrences(of: "\n", with: " ").prefix(90)))
    }
    var onNotification: ((String, String) -> Void)?
    var onBell: (() -> Void)?
    /// The door arms this while a newly launched shell is reaching its first
    /// prompt. It is cleared as soon as the waiting command is delivered.
    var onPromptStarted: (() -> Void)?
    private(set) var hasStartedPrompt = false

    /// The name shown in the rail and on the tab.
    ///
    /// Three sources, each used only where it is the freshest thing there is
    /// (ISC-151):
    ///
    /// 1. **The agent's own conversation.** With an agent attached and a turn
    ///    on the record, the pane is named by the NEWEST question. This is the
    ///    repair. `claude` writes the session's name into the terminal title
    ///    once — it is an `ai-title` record in the transcript, one per session,
    ///    computed from the first exchange and never rewritten (measured
    ///    2026-08-23: asked for a haiku, then for the water cycle; the title
    ///    stayed `✳ Lighthouse haiku` for the rest of the session, and the
    ///    rail said so too). Faithfully repeating a name that stopped being
    ///    true is still showing the wrong thing, and the app holds the thing
    ///    that IS true: it reads the turns.
    /// 2. **What the program reported**, for a pane with no agent in it: `vim`,
    ///    `top`, a shell that sets its own title. Live, and proven live —
    ///    OSC 0 and OSC 2 both land within a tick.
    /// 3. **The folder**, when nothing was reported at all.
    /// The name the facts provider gave this session, read off its
    /// `session` row. Highest precedence among the three: it is the one name
    /// the person also sees on the surfaces that provider feeds, so the two never
    /// disagree (25/08). Only the door's own label sits above it (ISC-212).
    var lifeosLabel = "" {
        didSet { if lifeosLabel != oldValue { notifyChanged() } }
    }

    /// A local program opening a pane may give it a durable name. It wins
    /// over facts, agents and terminal titles because it belongs to the
    /// request that created this particular pane.
    var doorLabel: String? {
        didSet { if doorLabel != oldValue { notifyChanged() } }
    }

    var displayName: String {
        if let doorLabel { return doorLabel }
        if !lifeosLabel.isEmpty { return lifeosLabel }
        if let name = agentTopic { return name }
        if !reportedTitle.isEmpty { return Self.withoutSpinner(reportedTitle) }
        return workingDirectory.lastPathComponent
    }

    /// What the attached agent is being asked about right now, or nil.
    ///
    /// nil rather than a fallback of its own, so `displayName` keeps every
    /// decision about precedence in one place. A blank question is nil too: a
    /// pane named with an empty string is a rail row with a hole in it.
    private var agentTopic: String? {
        guard let agent, agent.isAttached else { return nil }
        // L'ULTIMO turno che è una domanda vera. Un comando locale come
        // `/model` è un turno a tutti gli effetti, ma dargli il nome della
        // sessione la ribattezzava «Set model to…» e il nome del lavoro in
        // corso spariva (visto da lui il 26/08).
        guard let prompt = agent.turns.last(where: { !$0.isLocalCommand })?.prompt
        else { return nil }
        return Self.shortTopic(prompt)
    }

    /// One line, no runs of spaces, and short enough for a rail 232 points
    /// wide. Cut on a word where there is one to cut on, because a name that
    /// stops mid-word reads as a bug rather than as a name.
    static func shortTopic(_ prompt: String, limit: Int = 42) -> String? {
        let flat = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        guard flat.count > limit else { return flat }
        let head = String(flat.prefix(limit))
        guard let space = head.lastIndex(of: " "), head.distance(from: head.startIndex,
                                                                to: space) > limit / 2
        else { return head + "…" }
        return String(head[head.startIndex..<space]) + "…"
    }

    /// A reported title with the vendor's animation mark taken off the front.
    ///
    /// `claude` prefixes its title with a spinner — `◐ Lighthouse haiku` while
    /// it works, `✳ Lighthouse haiku` at rest — and the mark changes with the
    /// animation, so a rail that prints the title verbatim has a name that
    /// twitches. Only a LEADING run of non-alphanumeric characters goes, and
    /// only when something is left afterwards: a title that is nothing but
    /// marks is still that title.
    static func withoutSpinner(_ title: String) -> String {
        let trimmed = title.drop { !$0.isLetter && !$0.isNumber }
        let cleaned = trimmed.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    /// What the pane is doing, in the words the rail uses.
    var statusLine: String {
        if hasExited { return exitCode == 0 ? "finished" : "exited \(exitCode ?? -1)" }
        if let open = blocks.openBlock, !open.command.isEmpty { return open.command }
        return backend.foregroundProcessName() ?? "shell"
    }

    var isBusy: Bool {
        if let agent, agent.isAttached { return agent.activity == .working }
        return blocks.openBlock != nil
    }

    /// The turns the adapter read, each with the rows it was drawn on when
    /// those could be found.
    var turns: [AgentTurn] {
        let all = agent?.turns ?? []
        let bufferEnd = backend.grid.endRow
        return all.enumerated().map { index, turn in
            var copy = turn
            guard let anchor = turnAnchors[turn.id] else { return copy }
            copy.promptRow = anchor.promptRow
            // A row nobody could find is not a row to fold on: hiding the
            // wrong two hundred lines is worse than hiding none.
            guard anchor.found else { return copy }
            // A turn's work runs from the row after its question to the row
            // before the next question — computed here, every time, because
            // the next question may not have been asked yet.
            let successor = index + 1 < all.count
                ? turnAnchors[all[index + 1].id]?.promptRow : nil
            let end = successor ?? bufferEnd
            if turn.finishedAt != nil, end > anchor.promptRow + 1 {
                copy.workRows = (anchor.promptRow + 1)...(end - 1)
            }
            return copy
        }
    }

    /// The shell this pane was started with, by name — `zsh`, `bash`, `fish`.
    private(set) var shellName = ""

    /// The program in front of the shell, when it is not the shell itself.
    ///
    /// This is the whole question ISC-107 turns on: closing a pane whose
    /// foreground process is the login shell throws away a prompt, and closing
    /// one where `claude` has been working for three hours throws away the
    /// work. The fact comes from the kernel — the leader of the pty's
    /// foreground process group — not from a guess about what the user typed.
    var foreignProgramName: String? {
        guard !hasExited else { return nil }
        guard let name = backend.foregroundProcessName(), !name.isEmpty else { return nil }
        // `-zsh` is how a login shell names itself; the leading dash is the
        // login marker, not part of the program's name.
        let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
        guard bare != shellName else { return nil }
        // What the kernel calls the process is not always what the person
        // called it: `claude` runs as a versioned binary, and the foreground
        // process of a claude session came back named `2.1.237` (measured
        // 2026-08-20). When the shell told us the command line, that is the
        // name to say back to them.
        if let typed = blocks.openBlock?.command, !typed.isEmpty,
           let last = ShellCommandLine.programs(in: typed).last {
            return last
        }
        return bare
    }

    /// True while something other than the shell owns the input line: the
    /// alternate screen is up, or the pty's foreground process is not the
    /// shell. TRACKED rather than asked on demand, because the composer has
    /// to leave the moment `claude` starts and come back the moment `less`
    /// quits, and nothing else on the output path fires on that change
    /// (ISC-112).
    private(set) var frontOwnsInput = false
    private var frontScan: Timer?

    /// Coalesced the same way the screen scan is, and for the same reason:
    /// asking the kernel who owns the pty once per chunk of output would put
    /// a syscall in the renderer's budget, and a quiet pane must schedule
    /// nothing at all (ISC-38).
    private func scheduleFrontScan() {
        guard frontScan == nil else { return }
        frontScan = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { _ in
            Task { @MainActor in
                self.frontScan = nil
                self.refreshFrontOwnership()
            }
        }
    }

    func refreshFrontOwnership() {
        let now = backend.grid.isAlternateScreenActive || foreignProgramName != nil
        guard now != frontOwnsInput else { return }
        frontOwnsInput = now
        notifyChanged()
    }

    // MARK: - I messaggi in coda (ISC-197 → ISC-194)

    /// Un messaggio spedito mentre l'agente stava lavorando, e il numero di
    /// turni che c'erano nel momento in cui è partito.
    struct MessaggioInCoda {
        let testo: String
        let turniAllInvio: Int
    }

    /// Quello che hai spedito e che l'agente non ha ancora preso in mano.
    ///
    /// **Perché esiste (suo referto del 27/08).** Un messaggio scritto mentre
    /// l'agente lavora arriva davvero: `claude` lo mette in coda e lo disegna
    /// sulla PROPRIA riga d'ingresso — che è esattamente la riga che la
    /// copertura di chat pura nasconde. Il transcript di quel giorno lo prova
    /// (`queue-operation enqueue`, 17:08:09), ma lui non aveva modo di saperlo:
    /// «non viene registrato nel testo, quindi non so se è comparso o meno».
    /// Quindi non mancava l'invio, mancava la vista, e la vista la deve mettere
    /// T4A perché è T4A che ha coperto quella di sotto.
    ///
    /// Non è una coda nostra: non ritrasmette niente e non riordina niente. È
    /// la ricevuta di ciò che è già partito.
    private(set) var inCoda: [MessaggioInCoda] = []

    /// Registra un messaggio appena spedito, se l'agente stava lavorando.
    ///
    /// A sessione ferma non si registra niente: il messaggio diventa un turno
    /// entro un battito, e una ricevuta che compare e sparisce è rumore.
    func annotaInvio(_ testo: String, comandoLocale: Bool = false) {
        // Tre corse nude e dentro T4A, 28/08: `/model` apre il menu subito
        // durante un turno e non produce `queue-operation`. La ricevuta
        // «in coda» sarebbe quindi una nostra affermazione falsa.
        guard !comandoLocale else { return }
        guard let agent, agent.isAttached else { return }
        let turni = agent.turns
        guard turni.last?.isOpen == true else { return }
        inCoda.append(MessaggioInCoda(testo: testo, turniAllInvio: turni.count))
    }

    /// Toglie dalla ricevuta ciò che l'agente ha preso in mano.
    ///
    /// Due proprietari, in ordine di tempo. Nel secondo che passa fra l'invio
    /// e la riga scritta da `claude` nel transcript, la ricevuta è NOSTRA
    /// (`annotaInvio`). Appena il suo record `enqueue` arriva, il messaggio è
    /// nella coda dell'agente e la ricevuta è SUA: la nostra copia si toglie e
    /// `messaggiInCoda` legge la sua. Il segnale di consumo è quindi il suo
    /// `remove`/`dequeue`, e NON il conteggio dei turni: nella 2.1.247 il
    /// messaggio viene assorbito dentro il turno in corso e un turno nuovo non
    /// si apre mai (misurato il 27/08, `reason: absorbed_mid_turn`). La
    /// nostra copia cade anche se i turni crescono senza un `enqueue` — il
    /// messaggio è partito come turno, non come coda — e se l'agente sparisce.
    func potaCoda() {
        guard !inCoda.isEmpty else { return }
        guard let agent, agent.isAttached else { inCoda.removeAll(); return }
        let turni = agent.turns.count
        let sua = agent.queued
        inCoda.removeAll { turni > $0.turniAllInvio || sua.contains($0.testo) }
    }

    /// La ricevuta da disegnare: la coda dell'agente, più la nostra copia
    /// per i messaggi che lui non ha ancora scritto.
    var messaggiInCoda: [String] {
        let sua = agent?.isAttached == true ? (agent?.queued ?? []) : []
        return sua + inCoda.map(\.testo).filter { !sua.contains($0) }
    }

    // MARK: - Pure chat (ISC-114, experimental)

    /// Armed by the window when the experiment is on AND the composer is
    /// actually on screen. The second half is not decoration: covering the
    /// program's own prompt while offering nothing in its place would leave
    /// the pane with no input line at all, which is worse than either state
    /// on its own.
    var pureChat = false

    /// The box being covered right now, or nil. Derived ONCE here, on the
    /// screen scan, and read by the overlay that draws it and the dump that
    /// reports it — neither re-derives it.
    private(set) var hostedPrompt: HostedPrompt?
    /// Why nothing is covered. Kept because "covered nothing" and "never
    /// looked" are indistinguishable from outside, and only one is a defect.
    private(set) var hostedPromptReason = "the experiment is off"
    /// How many times the cover has appeared or gone since launch. A cover
    /// that flickers is a defect you can only see by counting it.
    private(set) var coverFlips = 0
    /// Milliseconds from the arrival of the output that changed the screen to
    /// the cover being gone. It is measured from the START of the burst that
    /// woke the scan, so a menu drawn by the second chunk of a burst is
    /// reported as SLOWER than it was: the number errs against the claim.
    private(set) var lastRevealMillis: Double?
    private var burstStartedAt: Date?
    /// Set by the pane: the cover moved, redraw. Only ever called while the
    /// experiment is armed, so a T4A with the flag off draws exactly what it
    /// drew before ISC-114 existed.
    var onScreenScanned: (() -> Void)?

    /// L'agente sta tenendo una domanda sullo schermo: un permesso, oppure un
    /// menu numerato come quello di `/model`.
    ///
    /// Si calcola DENTRO la scansione dello schermo, che gira sui byte in
    /// arrivo, e si legge da `refresh`. Rifarlo a ogni refresh vorrebbe dire
    /// leggere sessanta righe di griglia ogni volta che qualcosa nella
    /// finestra si muove: è la stessa ragione per cui `armPureChat` ri-scansa
    /// solo quando l'armamento cambia, ed è il difetto che ha fatto fallire
    /// `bench-card` il 25/08 (l'app non riusciva più a venire davanti in
    /// dodici secondi).
    private(set) var agenteStaChiedendo = false

    /// La riga d'ingresso dell'agente è stata riconosciuta nell'ultima
    /// scansione. È indipendente da `pureChat`: ISC-227 la usa per decidere se
    /// la pagina può coprire, anche quando la copertura sperimentale è spenta.
    private(set) var rigaIngressoVista = false

    /// La riga animata è quella che `claude` ha disegnato, non un verbo
    /// ricostruito da T4A. Si legge nello stesso passaggio di ISC-227: quel
    /// passaggio nasce dai byte in arrivo e gira al massimo ogni 120 ms, quindi
    /// un'altra camminata di non più di sessanta righe è tutto il costo e non
    /// esiste nessun timer nuovo (ISC-229).
    private(set) var rigaDiAttesa: String?

    /// Durante un turno lo schermo viene ridisegnato a scatti e la scatola può
    /// essere incompleta per un battito. `.working` tiene stabile la pagina in
    /// quei passaggi; senza, ISC-227 la farebbe lampeggiare a ogni ridisegno.
    var rigaIngressoDisponibile: Bool {
        rigaIngressoVista || activity == .working
    }

    private func aggiornaRigaIngressoVista() {
        let prima = rigaIngressoVista
        defer { if prima != rigaIngressoVista { notifyChanged() } }
        guard let agent, agent.isAttached else { rigaIngressoVista = false; return }
        rigaIngressoVista = HostedPromptScanner.inputLine(backend.grid)
    }

    private func aggiornaRigaDiAttesa() {
        let prima = rigaDiAttesa
        defer { if prima != rigaDiAttesa { notifyChanged() } }
        // Il turno chiuso non legge mai la griglia in cerca di un verbo: la
        // forma senza ellissi è già esclusa dallo scanner, e questo secondo
        // cancello lega la riga allo stato che le dà significato.
        guard let agent, agent.isAttached, agent.activity == .working else {
            rigaDiAttesa = nil
            return
        }
        rigaDiAttesa = WaitingLine.read(backend.grid)
    }

    private func aggiornaDomandaSuSchermo() {
        // Il valore cambia dentro una scansione dello schermo, e la finestra
        // ridisegna solo quando qualcuno gliela chiede: senza l'avviso qui
        // sotto il menu di `/model` restava sotto la pagina della chat FINCHÉ
        // non arrivava un altro evento qualsiasi, cioè per sempre se non
        // toccavi niente. Misurato il 26/08: `asking=True` e
        // `chatShowing=True` nello stesso dump per dieci secondi buoni.
        let prima = agenteStaChiedendo
        defer { if prima != agenteStaChiedendo { notifyChanged() } }
        guard let agent, agent.isAttached else { agenteStaChiedendo = false; return }
        if agent.approval != nil { agenteStaChiedendo = true; return }
        let lettura = agent.reading(on: backend.grid)
        agenteStaChiedendo = (lettura["kind"] as? String)
            .map { $0 == "permission" || $0 == "selector" } ?? false
    }

    /// Re-reads the box under the cursor. Called from the screen scan, so it
    /// runs on arriving bytes and never on a timer of its own.
    private func updateHostedPrompt() {
        let had = hostedPrompt != nil
        defer {
            if had != (hostedPrompt != nil) {
                coverFlips += 1
                if hostedPrompt == nil, let start = burstStartedAt {
                    lastRevealMillis = Date().timeIntervalSince(start) * 1000
                }
            }
            if pureChat { onScreenScanned?() }
        }
        guard pureChat else {
            hostedPrompt = nil
            hostedPromptReason = "the experiment is off"
            return
        }
        guard let agent, agent.isAttached else {
            hostedPrompt = nil
            hostedPromptReason = "no agent is attached to this pane"
            return
        }
        switch HostedPromptScanner.scan(backend.grid) {
        case .cover(let prompt):
            hostedPrompt = prompt
            hostedPromptReason = ""
        case .reveal(let why):
            hostedPrompt = nil
            hostedPromptReason = why
        }
    }

    /// The one thing the accent is allowed to mark. In a shell with no agent
    /// attached, "waiting for you" has an exact meaning: the pane produced
    /// something you have not looked at and is now back at a prompt with
    /// nothing to do. With no shell integration it is always false, and the
    /// count reads zero rather than guessing.
    var isWaitingForYou: Bool {
        guard !hasExited else { return false }
        // A permission with its card standing is a question addressed to you,
        // and it stays one WHILE YOU LOOK AT IT (ISC-136).
        //
        // The rule below — the pane you are on is never waiting, because you
        // are already there — is right for everything else and wrong for this.
        // A card is the one state where the pane in front of you is asking and
        // has stopped: the big number read `0 waiting` with a permission on the
        // screen, which is the accent Principles reserves for exactly this and
        // it was dark at the only moment it exists for. Seen in a photograph
        // taken for the README, not in a bench.
        if agent?.approval != nil { return true }
        guard !isFocused else { return false }
        // With an agent attached the question has an exact answer, derived
        // from the agent's own record and from the prompt on the screen; the
        // shell rule below is the one for a pane with no agent in it.
        if let agent, agent.isAttached {
            return FinishedTurnAttention.needsAttention(
                activity: agent.activity, wasSeen: vistaDopoLaFine)
        }
        return hasUnseenActivity && !isBusy
    }

    /// Il nome da mettere nella domanda di chiusura, o `nil` se chiudere qui
    /// non butta via niente.
    ///
    /// Non è `foreignProgramName`, ed è la differenza che ha chiesto lui il
    /// 26/08: una chat con l'agente FERMO, che ha appena finito di rispondere,
    /// non è lavoro in corso, e farsi chiedere «Close anyway» per chiuderla è
    /// una domanda a cui la risposta è sempre sì, cioè un click che insegna a
    /// non leggere le domande.
    ///
    /// Le due condizioni sono separate apposta. Un agente ATTACCATO risponde
    /// da sé se sta lavorando, e allora la domanda ha un contenuto. Un
    /// programma che non è un agente (`vim`, un build, un rsync) non ha modo
    /// di dirlo, e lì la domanda resta: chiudere ammazza il processo, e la
    /// perdita silenziosa è peggio della domanda di troppo.
    var closingWouldInterrupt: String? {
        guard let name = foreignProgramName else { return nil }
        if let agent, agent.isAttached { return agent.activity == .working ? name : nil }
        return name
    }

    /// The one word the rail puts on the pane.
    var activity: AgentActivity {
        if hasExited { return .idle }
        if let agent, agent.isAttached { return agent.activity }
        return isBusy ? .working : .idle
    }

    /// Set by the window: the pane the keyboard is talking to is never
    /// waiting for you, because you are already there.
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            // Arriving after the finish consumes its attention before anybody
            // redraws. Arriving while it works consumes nothing; a later end
            // reached elsewhere is therefore new and visible.
            aggiornaVistaDopoLaFine()
            notifyChanged()
        }
    }

    init(directory: URL, integrationRoot: URL?, scrollback: Int, font: NSFont,
         shell: String = "", useGPU: Bool = true, agentAdapter: Bool = true,
         directCommand: [String]? = nil) {
        workingDirectory = directory
        agent = agentAdapter ? AgentObserver() : nil
        backend = BackendFactory.make(columns: 80, rows: 25,
                                      scrollback: scrollback, font: font,
                                      useGPU: useGPU)

        // A non-nil command is reachable only from the test-channel method
        // compiled below T4A_TESTABLE. It execs the measured reader as the
        // pane leader: no shell prompt can arm or disarm terminal modes in
        // front of it. The ordinary nil path remains the user's login shell.
        let executable = directCommand?.first
            ?? (shell.isEmpty ? LoginShell.path() : shell)
        shellName = (executable as NSString).lastPathComponent
        // Who is hosting this shell, and which version of it. Both are set
        // here rather than inside the shell integration, because a program
        // asking what terminal it is in deserves an answer whether or not the
        // OSC 133 shims are switched on (ISC-110).
        var environment: [String: String] = [
            "TERM_PROGRAM": AppVersion.name,
            "TERM_PROGRAM_VERSION": AppVersion.short,
        ]
        var arguments = directCommand.map { Array($0.dropFirst()) } ?? []
        var argv0: String? = directCommand == nil ? nil : shellName
        if directCommand == nil, let integrationRoot {
            let integration = ShellIntegration(root: integrationRoot)
            let prepared = integration.prepare(executable: executable,
                                               arguments: arguments,
                                               environment: &environment)
            arguments = prepared.arguments
            argv0 = prepared.argv0
        }

        agent?.onChange = { [weak self] in
            guard let self else { return }
            // Settle the latch before notifying the controller. In particular,
            // a finish that arrives in the pane already in front is born seen:
            // there is no intermediate refresh carrying a finished dot.
            self.aggiornaVistaDopoLaFine()
            // Una lettura della griglia appartiene all'agente che l'ha
            // prodotta: dopo lo sgancio non può restare vera fino a un byte
            // futuro che potrebbe non arrivare mai.
            if self.agent?.isAttached != true {
                self.rigaIngressoVista = false
                self.rigaDiAttesa = nil
            } else if self.agent?.activity != .working {
                // Cancellare non legge la griglia: impedisce che l'ultimo
                // fotogramma del turno resti vivo quando il transcript lo ha
                // già chiuso e non arrivano altri byte.
                self.rigaDiAttesa = nil
            }
            self.updateProcessAdoptionRetry()
            self.anchorTurns()
            if self.compactTurns { self.foldAllFinished() }
            self.applyFolds()
            self.notifyChanged()
        }
        backend.onEvent = { [weak self] event in self?.handle(event) }
        blocks.onChange = { [weak self] in self?.notifyChanged() }
        // The pane's own badge, the way iTerm publishes ITERM_SESSION_ID: a
        // process inside this pane can say which pane it is in, and something
        // outside (a menu-bar app, a script) can ask T4A to come back to it.
        // Set here, after the scrub in the backend has removed the badges of
        // whatever terminal launched T4A, so ours survives.
        environment["T4A_SESSION_ID"] = id.uuidString
        backend.start(TerminalLaunch(executable: executable,
                                     arguments: arguments,
                                     workingDirectory: directory,
                                     environment: environment,
                                     argv0: argv0))
    }

    /// Asks the child where it is. The shell only announces a directory
    /// change if it was configured to (OSC 7), and most are not, so the fact
    /// is read from the process instead of waited for.
    func refreshWorkingDirectory() {
        guard let current = backend.currentWorkingDirectory(),
              current.path != workingDirectory.path else { return }
        workingDirectory = current
        notifyChanged()
    }

    /// Folds or unfolds one turn's work.
    func toggleFold(turn: AgentTurn) {
        if foldedTurns.contains(turn.id) { foldedTurns.remove(turn.id) }
        else { foldedTurns.insert(turn.id) }
        applyFolds()
        notifyChanged()
    }

    private func foldAllFinished() {
        for turn in turns where turn.finishedAt != nil && turn.workRows != nil {
            foldedTurns.insert(turn.id)
        }
    }

    /// Hands the folded runs to the backend, which clips them against the live
    /// screen and settles the viewport.
    private func applyFolds() {
        guard agent?.isAttached == true else {
            backend.setFolds([])
            return
        }
        let ranges = turns.filter { foldedTurns.contains($0.id) }
            .compactMap(\.workRows)
        backend.setFolds(ranges)
    }

    /// The one line that stands in for a folded turn.
    func foldLabel(for range: ClosedRange<Int>) -> String {
        guard let turn = turn(foldedAs: range) else {
            return S.linesFolded(count: range.count)
        }
        let tools = turn.tools.count
        let time = turn.duration.map { BlockOverlayView.format($0) } ?? ""
        var parts = [S.lines(count: range.count)]
        if tools > 0 { parts.append(S.tools(count: tools)) }
        if !time.isEmpty { parts.append(time) }
        return parts.joined(separator: " · ")
    }

    /// The turn a folded run belongs to, so a click on its strip opens it.
    /// Matched on where the run STARTS, not on the whole range.
    ///
    /// The backend clips a fold against its own live screen, so the range that
    /// comes back is a prefix of the one that went in — and an equality test
    /// silently stopped finding the turn as soon as any clipping happened,
    /// which showed up as a strip reading "55 lines folded" beside two that
    /// named their tools.
    func turn(foldedAs range: ClosedRange<Int>) -> AgentTurn? {
        turns.first { $0.workRows?.lowerBound == range.lowerBound }
    }

    func markSeen() {
        guard hasUnseenActivity else { return }
        hasUnseenActivity = false
        notifyChanged()
    }

    func acknowledgeFailures() { blocks.acknowledgeAllFailures() }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .title(let title):
            reportedTitle = title
            notifyChanged()
        case .workingDirectory(let url):
            workingDirectory = url
            notifyChanged()
        case .promptStarted(let row):
            blocks.promptStarted(row: row)
            hasStartedPrompt = true
            onPromptStarted?()
        case .commandStarted(let row, let command):
            blocks.commandStarted(row: row, command: command)
            // The shell just announced what it is about to run: this is the
            // event that says an agent may have started, and it is an event
            // rather than a tick, which is why watching an idle pane costs
            // nothing (ISC-25, ISC-38).
            refreshWorkingDirectory()
            probeForAgent(commandLine: command)
        case .commandLineAnnounced(let command):
            blocks.annotateCommand(command)
        case .commandFinished(let row, let exitCode):
            blocks.commandFinished(row: row, exitCode: exitCode)
            refreshWorkingDirectory()
            refreshFrontOwnership()
            // The agent exited. Everything it had open is closed with it: a
            // watch held past its meaning is a resource nobody is using.
            //
            // Its NAME goes with it (ISC-151). `claude` writes the session's
            // name into the terminal title and nothing takes it back down when
            // the session ends, so a pane that had a chat in it went on wearing
            // that chat's name — and the next chat started underneath it. A
            // shell whose prompt sets the title papers over this; one that does
            // not leaves a dead conversation's name on a live pane. What is
            // left is the pane's own name: the folder, or whatever the program
            // in front says about itself next.
            if agent?.isAttached == true { reportedTitle = "" }
            agent?.detach()
        case .notification(let title, let body):
            onNotification?(title.isEmpty ? displayName : title, body)
        case .bell:
            onBell?()
        case .processExited(let code):
            hasExited = true
            exitCode = code
            stopProcessAdoptionRetry()
            notifyChanged()
        case .sizeChanged:
            notifyChanged()
        case .outputArrived:
            // Deliberately does nothing but note that the pane moved. The
            // work of redrawing belongs to the view, and ISC-38 rests on this
            // path staying empty when the terminal is quiet.
            if !hasUnseenActivity { hasUnseenActivity = true; notifyChanged() }
            scheduleScreenScan()
            scheduleFrontScan()
        }
    }

    /// Looks at the live screen for a permission prompt, at most a few times a
    /// second while output is flowing.
    ///
    /// The coalescing is not an optimisation, it is the shape of the claim:
    /// during a build that prints thousands of lines a scan per chunk would
    /// put the terminal's own CPU into the renderer's budget, and a terminal
    /// with nothing arriving schedules no timer at all — the object is created
    /// by the arrival of bytes and invalidates itself.
    private func scheduleScreenScan() {
        guard agent != nil, screenScan == nil else { return }
        // The moment the pane started moving, kept so the reveal latency of
        // ISC-114 is measured against arriving bytes and not against a
        // keystroke a person is still finishing.
        burstStartedAt = Date()
        // A cover that is STANDING is the one state in which a late scan can
        // keep a question hidden, so it is the only state that pays for a
        // faster one (ISC-114). With nothing covered — which is every pane
        // that never switched the experiment on — the cadence is the ISC-38
        // one, untouched. Measured 2026-08-21: at 0.12 the reveal landed at
        // 188 ms of a 200 ms budget, a margin too thin to call a pass.
        let delay = hostedPrompt != nil ? 0.03 : 0.12
        screenScan = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in
                self.screenScan = nil
                self.scanScreenNow()
            }
        }
    }

    /// One scan, now. Also the path the test channel uses, so a bench measures
    /// the same code a person's keystroke reaches.
    /// Looks for an agent in the pane's foreground TREE, not just its leader.
    ///
    /// Two kernel facts fixed here at once (both his, 25/08). OSC 7 arrives at
    /// the next prompt, so on `cd dir && claude` the pane still says the OLD
    /// directory when the agent starts: the cwd comes from the agent process
    /// itself. And a launcher hides the agent one level down — `lifeos` is
    /// `bun lifeos.ts` and the leader is `bun` for the whole session, so an
    /// attach that reads only the leader never fires: the tree is walked and
    /// the first recognised process wins, with ITS directory.
    private func probeForAgent(commandLine: String) {
        guard let agent else { return }
        let tree = backend.foregroundProcesses()
        for process in tree {
            // The process's OWN argv beats the typed command: through a
            // launcher the typed line never names the agent, and the agent's
            // binary is versioned so its kernel name is `2.1.243` — argv[0]
            // is the only witness that says `claude` (25/08).
            let line = process.commandLine.isEmpty ? commandLine : process.commandLine
            if AgentRegistry.adapter(forProcess: process.name, commandLine: line) != nil {
                agent.programChanged(process: process.name, commandLine: line,
                                     cwd: backend.workingDirectory(ofProcess: process.pid)
                                          ?? workingDirectory,
                                     pid: process.pid)
                return
            }
        }
        // Nothing in the tree is an agent: let the observer detach if it was
        // attached, through the same door everything else goes through.
        agent.programChanged(process: tree.first?.name ?? "", commandLine: commandLine,
                             cwd: workingDirectory)
    }

    /// The last time this pane went looking for an agent it had already
    /// attached to. Without it the walk below runs on every screen scan — up
    /// to eight a second while output is flowing — for a pane whose agent
    /// genuinely has no findable process.
    private var ultimoTentativoPid = Date.distantPast

    /// State changes own this timer so a pane that cannot make progress never
    /// leaves a periodic kernel lookup behind.
    private func updateProcessAdoptionRetry() {
        let shouldRun = RetryAdoptionPolicy.shouldRun(
            sessionIsAlive: !hasExited,
            isAttached: agent?.isAttached ?? false,
            hasProcess: agent?.hasProcess ?? false)
        guard shouldRun else {
            stopProcessAdoptionRetry()
            return
        }
        guard processAdoptionRetryTimer == nil else { return }
        // Empty process trees are expected during launcher races, not errors.
        // Retrying remains intentionally unbounded only while the policy is
        // true; pid adoption, detach, process exit and close all invalidate it.
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.processAdoptionRetryInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.processAdoptionRetryFired() }
        }
        timer.tolerance = 0.5
        processAdoptionRetryTimer = timer
    }

    private func stopProcessAdoptionRetry() {
        processAdoptionRetryTimer?.invalidate()
        processAdoptionRetryTimer = nil
    }

    private func processAdoptionRetryFired() {
        let shouldRun = RetryAdoptionPolicy.shouldRun(
            sessionIsAlive: !hasExited,
            isAttached: agent?.isAttached ?? false,
            hasProcess: agent?.hasProcess ?? false)
        guard shouldRun else {
            stopProcessAdoptionRetry()
            return
        }
        adottaProcesso()
    }

    /// Attached, but nobody ever handed the observer a pid: go and find it.
    ///
    /// The fallback in `probeForAgent` attaches without one whenever the
    /// process tree is still empty at the moment the agent is recognised, and
    /// until 2026-08-27 that was permanent — `scanScreenNow` re-probed only
    /// while UNattached, so a pane that lost the race stayed pid-less for the
    /// whole session, with the command table (ISC-187) and the kernel reading
    /// of the transcript (25/08) both off. Measured that day: 5 attaches in 7
    /// came through the fallback.
    ///
    /// It does NOT go through `probeForAgent`, and the difference is the whole
    /// safety of this function. That one hands the observer the directory the
    /// KERNEL reports for the process, and hands the fallback an empty command
    /// line — either of which, on an already-attached pane, means detach: a
    /// different directory re-attaches (throwing away the turns read so far
    /// and the process attribution that selected this pane's transcript), and
    /// the fallback with nothing to match on detaches outright. Here the
    /// observer's OWN directory is passed back, so the only thing that can
    /// change is the pid.
    private func adottaProcesso() {
        guard let agent, agent.isAttached, !agent.hasProcess, let cwd = agent.cwd,
              Date().timeIntervalSince(ultimoTentativoPid) > 1,
              !isAdoptingProcess else { return }
        isAdoptingProcess = true
        defer { isAdoptingProcess = false }
        ultimoTentativoPid = Date()
        for process in backend.foregroundProcesses()
        where AgentRegistry.adapter(forProcess: process.name,
                                    commandLine: process.commandLine) != nil {
            agent.programChanged(process: process.name, commandLine: process.commandLine,
                                 cwd: cwd, pid: process.pid)
            return
        }
    }

    func scanScreenNow() {
        guard let agent else { return }
        // The launcher race: at the commandStarted event the agent's process
        // may not exist yet (bun has not spawned claude). Output keeps
        // arriving while it starts, and this scan rides that output — so an
        // unattached pane re-probes here, throttled by the scan's own timer,
        // and stops the moment it attaches.
        if !agent.isAttached { probeForAgent(commandLine: "") } else { adottaProcesso() }
        // Before the early return below: an unattached pane covers nothing,
        // and a cover left standing because the scan gave up early would be
        // exactly the failure this experiment must not have.
        updateHostedPrompt()
        aggiornaDomandaSuSchermo()
        aggiornaRigaIngressoVista()
        aggiornaRigaDiAttesa()
        if !agent.isAttached {
            // `cd /somewhere && claude` announces its command line BEFORE the
            // shell has changed directory, so the working directory read at
            // that moment is the old one and the watcher would sit on the
            // wrong project directory for ever. The retry costs a string match
            // on a command line nobody has to run, and it is only reached when
            // bytes arrived — an idle pane still schedules nothing.
            attemptAttach()
            return
        }
        if agent.transcript == nil { agent.retryFind() }
        if agent.refreshApproval(on: backend.grid) {
            // Approval changes AgentObserver.activity too, but deliberately do
            // not call its onChange callback. Feed that transition to the same
            // latch before publishing the screen scan.
            aggiornaVistaDopoLaFine()
            // `aggiornaDomandaSuSchermo` può aver visto l'approvazione
            // cacheata del giro precedente. Rifatta solo quando quella cache
            // cambia, libera il rifiuto di ISC-228 nello stesso scan che vede
            // la domanda sparire, senza aggiungere letture a ogni refresh.
            aggiornaDomandaSuSchermo()
            anchorTurns()
            notifyChanged()
        }
    }

    /// Tries to attach, using the directory the child is in NOW.
    private func attemptAttach() {
        guard let agent, !agent.isAttached,
              let command = blocks.openBlock?.command, !command.isEmpty else { return }
        // The cheap test first: a pure string match against the command line.
        // Only a line that names an agent is worth a trip to the kernel for
        // the process's real working directory.
        guard AgentRegistry.adapter(forProcess: backend.foregroundProcessName() ?? "",
                                    commandLine: command) != nil else { return }
        refreshWorkingDirectory()
        probeForAgent(commandLine: command)
    }

    /// Finds, once per turn, the row this terminal drew that turn's question
    /// on.
    ///
    /// The transcript knows WHAT happened and has no idea WHERE it went, so
    /// the row is found by looking for the question's own text in the buffer.
    /// When the text cannot be found — it scrolled out of the retained
    /// buffer, or the agent rewrote the line — the row where the terminal
    /// stood when the turn arrived is used instead, and the difference is
    /// visible in the dump rather than hidden behind a number that looks
    /// exact.
    private func anchorTurns() {
        guard let agent, agent.isAttached else { return }
        let grid = backend.grid
        let end = grid.endRow
        let liveTop = grid.liveScreenTopRow
        let all = agent.turns
        // Turns happened in order, so their rows are in order too, and each
        // search starts where the previous turn ended.
        //
        // Searching BACKWARDS from the bottom was the first version and it put
        // turn 1 at row 64 with turns 2 and 3 above it: an agent echoes your
        // question again in its input box and in its history, so the lowest
        // row containing the text is almost never the row it was asked on
        // (measured 2026-08-20 on Codex). Forwards from the previous anchor,
        // the first match is the right one by construction.
        var floor = max(grid.firstRetainedRow, end - 4000)
        for turn in all {
            // An anchor that has fallen into history can no longer move: the
            // program cannot write to those rows any more. One still on the
            // live screen is re-searched, because the agent repaints its own
            // area and a question shifts by a row as it does.
            // Frozen only when the row was FOUND and has fallen into history.
            //
            // A guessed row freezing was the bug: the transcript record is
            // written the instant you press Return and the agent echoes your
            // question a beat later, so the first look finds nothing, guesses
            // the bottom of the buffer, and — once the buffer grows past it —
            // never looks again. Three turns all claimed the last three rows
            // of the screen (measured 2026-08-20).
            if let anchor = turnAnchors[turn.id], anchor.found, anchor.promptRow < liveTop {
                floor = max(floor, anchor.promptRow + 1)
                continue
            }
            let needle = Self.needle(turn.prompt)
            var found: Int?
            if !needle.isEmpty {
                var row = floor
                while row < end {
                    if let text = grid.text(at: row), text.contains(needle) {
                        found = row
                        break
                    }
                    row += 1
                }
            }
            let anchor = found ?? max(floor, end - 1)
            turnAnchors[turn.id] = TurnAnchor(promptRow: anchor, found: found != nil)
            floor = max(floor, anchor + 1)
        }
    }

    /// The piece of a prompt worth searching a terminal for: its first line,
    /// short enough to survive the agent wrapping it.
    static func needle(_ prompt: String) -> String {
        let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return "" }
        return String(trimmed.prefix(38))
    }

    /// Frees the child. Called when the pane closes — a pty held past its use
    /// is a resource open longer than its meaning (MacAppRules §0.3).
    func close() {
        screenScan?.invalidate()
        screenScan = nil
        stopProcessAdoptionRetry()
        agent?.detach()
        backend.onEvent = nil
        backend.terminate()
    }

    nonisolated static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
