//  ClaudeCodeAdapter.swift — reading a Claude Code session that is already
//  running in the pane.
//
//  It reads the JSONL transcript Claude Code writes for itself, in
//  `~/.claude/projects/<flattened cwd>/<session>.jsonl`. Nothing is asked of
//  the user and nothing is asked of Claude Code: the file exists whether or
//  not T4A is watching, and T4A opens it read-only.

import Foundation
import TerminalCore

@MainActor
final class ClaudeCodeAdapter: AgentAdapter {
    static let identifier = "claude-code"

    static func recognises(process: String, commandLine: String) -> Bool {
        let bare = (process as NSString).lastPathComponent
        if bare == "claude" { return true }
        // The kernel names the foreground process after the versioned binary
        // Claude Code actually execs — a live session came back called
        // `2.1.237` (measured 2026-08-20). So the command line the shell
        // announced is the second, and better, witness.
        return ShellCommandLine.programs(in: commandLine).contains("claude")
    }

    /// The directory Claude Code writes this pane's transcripts into.
    ///
    /// The name is the absolute path with every character that is not a letter,
    /// a digit or an underscore turned into a dash — verified against the
    /// directories on disk rather than assumed, because a path with a dot in it
    /// is flattened the same way as one with a slash.
    nonisolated static func transcriptDirectories(home: URL, cwd: URL) -> [URL] {
        let root = configurationRoot(home: home).appendingPathComponent("projects")
        // The pane may be in a subdirectory of the directory the agent was
        // started in, and it may follow a symlink; both the literal path and
        // its resolved form are watched.
        var names = Set<String>()
        for path in [cwd.path, cwd.resolvingSymlinksInPath().path] {
            names.insert(flatten(path))
        }
        return names.sorted().map { root.appendingPathComponent($0) }
    }

    /// `CLAUDE_CONFIG_DIR` when the user set one, `~/.claude` otherwise. A
    /// session started with a different configuration directory writes its
    /// transcript there, and a watcher looking in the default place would sit
    /// on an empty directory for ever without saying so.
    nonisolated static func configurationRoot(home: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent(".claude")
    }

    nonisolated static func flatten(_ path: String) -> String {
        String(path.map { character in
            character.isLetter || character.isNumber || character == "_"
                ? character : "-"
        })
    }

    /// Claude Code closes its transcript after every append, so its own
    /// process record is the durable fact that ties a session id to a pid.
    /// The record is born with the first message, not at process startup;
    /// before then this deliberately returns `[]`, and the observer's reason
    /// is the right state to show.
    static func transcripts(attributedTo pid: Int32, home: URL, cwd: URL,
                            processStart: Date?) -> [URL] {
        let recordURL = sessionRecordURL(pid: pid, home: home)
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              sessionRecordMatches(record, pid: pid, processStart: processStart),
              let sessionID = record["sessionId"] as? String else {
            return []
        }
        let recordedCwd = (record["cwd"] as? String).flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value)
        }
        return transcriptDirectories(home: home, cwd: recordedCwd ?? cwd).map {
            $0.appendingPathComponent(sessionID).appendingPathExtension("jsonl")
        }
    }

    /// The record path is exposed so tests can supply vendor-shaped input
    /// without making the adapter responsible for creating any file.
    nonisolated static func sessionRecordURL(pid: Int32, home: URL) -> URL {
        configurationRoot(home: home)
            .appendingPathComponent("sessions")
            .appendingPathComponent("\(pid).json")
    }

    /// Validates only facts inside one record and the supplied kernel time,
    /// keeping pid-reuse behavior testable without a live Claude process.
    nonisolated static func sessionRecordMatches(_ record: [String: Any], pid: Int32,
                                                 processStart: Date?) -> Bool {
        guard recordPID(record["pid"]) == pid,
              let sessionID = record["sessionId"] as? String,
              !sessionID.isEmpty,
              !sessionID.contains("/"),
              !sessionID.contains("..") else {
            return false
        }
        guard let rawStart = record["procStart"] as? String,
              let processStart else {
            // The pid remains the vendor's attribution when either side lacks
            // a comparable time; future record formats must not disable it.
            return true
        }
        let readings = [
            parseProcessStart(rawStart),
            parseProcessStart(rawStart, timeZone: .current),
        ].compactMap { $0 }
        guard !readings.isEmpty else {
            // The pid remains the vendor's attribution when either side lacks
            // a comparable time; future record formats must not disable it.
            return true
        }
        // The vendor does not document this zone. It is UTC today (measured
        // twice), while retaining a local reading means a convention change
        // broadens the match instead of leaving the pane following nothing.
        // The two windows cannot both be hit by a stale record unless that pid
        // was reused within the same two seconds of a day, which is the same
        // order of improbability as before.
        return readings.contains {
            abs($0.timeIntervalSince(processStart)) <= 2
        }
    }

    private nonisolated static func recordPID(_ value: Any?) -> Int32? {
        if let integer = value as? Int { return Int32(exactly: integer) }
        if let double = value as? Double { return Int32(exactly: double) }
        return nil
    }

    private nonisolated static func parseProcessStart(_ value: String) -> Date? {
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        return parseProcessStart(value, timeZone: utc)
    }

    private nonisolated static func parseProcessStart(
        _ value: String, timeZone: TimeZone
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Foundation.Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.isLenient = false
        return formatter.date(from: value)
    }

    /// Does this file belong to the INTERACTIVE session working in `cwd`?
    ///
    /// Two conditions, and the second one was learned the hard way. The file's
    /// own `cwd` field has to match, because the directory name is a
    /// flattening and a flattening is not reversible. And its `entrypoint` has
    /// to be `cli`: Claude Code runs a second, tiny session of its own to name
    /// the tab, and that session writes into the SAME project directory, with
    /// the same working directory and the user's own prompt inside it. It
    /// finishes first, so "the file written most recently" picks it every
    /// time — measured 2026-08-20, the inspector filled with one turn whose
    /// answer was `{"tab_title": …}` and whose model was not the model the
    /// session was running. The tell in the file is exact:
    /// `entrypoint: "sdk-cli"` and `promptSource: "sdk"` against `cli`/`typed`.
    static func file(_ url: URL, belongsTo cwd: URL) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 16), !head.isEmpty
        else { return false }
        let wanted = Set([cwd.path, cwd.resolvingSymlinksInPath().path])
        var directoryMatches = false
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            if let entrypoint = object["entrypoint"] as? String, entrypoint != "cli" {
                return false
            }
            guard !directoryMatches, let recorded = object["cwd"] as? String else { continue }
            let resolved = URL(fileURLWithPath: recorded).resolvingSymlinksInPath().path
            guard wanted.contains(recorded) || wanted.contains(resolved) else { return false }
            directoryMatches = true
        }
        return directoryMatches
    }

    // MARK: - The model

    private(set) var turns: [AgentTurn] = []
    private(set) var model = ""
    /// La taglia del contesto CORRENTE, in token: i tre ingressi dell'ultimo
    /// record `assistant` che ne porta uno — quello che è stato letto adesso,
    /// più quello che è stato scritto in cache, più quello che ne è stato
    /// riletto. È lo stesso numero che la statusline di Claude Code chiama
    /// `total_input_tokens`, e si prende dall'ULTIMO record perché il contesto
    /// è uno stato e non una spesa: sommarlo sui turni conterebbe dieci volte
    /// lo stesso testo riletto dalla cache.
    private(set) var contextTokens: Int?
    /// Quello che l'agente ha SCRITTO, sommato su tutta la sessione: questa
    /// invece è una spesa, e una spesa si accumula. `output_tokens` comprende
    /// già i token di ragionamento — `output_tokens_details.thinking_tokens`
    /// è una ripartizione di quel totale, non un addendo — quindi sommarlo a
    /// parte conterebbe due volte la stessa cosa.
    private(set) var outputTokens: Int?
    /// Il campo `effort` dei record, che sta in cima e non dentro `message`.
    private(set) var effort: String?
    /// I messaggi che `claude` tiene in coda ADESSO, letti dai suoi record
    /// `queue-operation` (ISC-194). È la sua ricevuta, non la nostra: la
    /// scrive quando accoda (`enqueue`, col testo), quando lo assorbe dentro
    /// il turno in corso (`remove`, col testo e `reason: absorbed_mid_turn` —
    /// 2.1.247, misurato il 27/08: il messaggio NON diventa un turno nuovo) e
    /// quando lo consuma a fine turno o su interruzione (`dequeue`, senza
    /// testo: esce il più vecchio). I messaggi che comincia lui stesso —
    /// notifiche di lavori in sfondo, promemoria di sistema, tutti aperti da
    /// `<` — non sono cose che una persona ha spedito e restano fuori.
    private(set) var queued: [String] = []
    /// Quante volte la coda si è svuotata di un elemento, per il banco: la
    /// ricevuta che sparisce e la ricevuta che non è mai esistita si
    /// distinguono solo contando.
    private(set) var queueConsumed = 0
    private(set) var latestRecordAt: Date?
    /// La cartella in cui questa sessione sta lavorando, letta dai record.
    ///
    /// Serve a una cosa sola: risolvere il percorso relativo di uno strumento
    /// che ha scritto un file (ISC-175). Si legge dal transcript e non si fa
    /// passare da fuori, perché il transcript ce l'ha già dentro — ogni record
    /// porta il suo `cwd` — ed è la cartella che l'agente aveva DAVVERO quando
    /// ha scritto, non quella che il pannello ha adesso, che nel frattempo un
    /// `cd` può avere cambiato.
    private(set) var sessionCwd: String?
    private var openTurn: Int?
    private var nextID = 1
    /// L'id del messaggio API che ha chiuso ciascun turno. Claude Code
    /// 2.1.246+ scrive un record `assistant` per blocco, ma ripete su tutti
    /// lo stesso id e lo stesso `stop_reason`: il record seguente con lo
    /// stesso id continua quindi quel turno, non ne comincia uno senza domanda.
    private var closingMessageID: [Int: String] = [:]
    /// Il passo che in questo momento contiene la risposta del turno, per id
    /// di turno: alla chiusura se ne va, perché la risposta si mostra sempre.
    private var answerStep: [Int: String] = [:]

    init() {}

    /// What this vendor calls its families, so the bar can print `Opus 5`
    /// where the session file says `claude-opus-5` (ISC-123).
    static let modelFamilies = ["fable", "opus", "sonnet", "haiku"]

    var activity: AgentActivity {
        guard !turns.isEmpty else { return .idle }
        return openTurn == nil ? .waiting : .working
    }

    func rewind() {
        turns.removeAll()
        model = ""
        contextTokens = nil
        outputTokens = nil
        effort = nil
        queued.removeAll()
        queueConsumed = 0
        latestRecordAt = nil
        sessionCwd = nil
        openTurn = nil
        nextID = 1
        closingMessageID.removeAll()
        answerStep.removeAll()
    }

    func approval(on grid: any TerminalGrid) -> AgentApproval? {
        // A card is offered on a PERMISSION and never on a menu: on
        // `/model` it used to sit on top of the five choices (ISC-122).
        guard let prompt = SelectorScanner.permission(on: grid) else { return nil }
        let answers = SelectorScanner.answers(for: prompt)
        // The question line itself says nothing a card needs to repeat, and
        // the "requires approval" line is the card's whole reason for being.
        let noise = ["do you want to proceed?", "this command requires approval"]
        let detail = prompt.detail.filter { !noise.contains($0.lowercased()) }
        return AgentApproval(title: prompt.title, detail: detail,
                             options: [answers.approve, answers.deny],
                             firstRow: prompt.firstRow)
    }

    func ingest(lines: [String]) {
        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any] else { continue }
            // A sidechain is a subagent talking to itself. In the main stream
            // the whole subagent shows up as ONE tool call, which is what the
            // person watching actually did; folding its inner turns in as well
            // would count the same work twice.
            if record["isSidechain"] as? Bool == true { continue }
            // In cima al record, accanto a `version` e `gitBranch`, e non
            // dentro `message`: verificato sui transcript veri il 25/08.
            if let level = record["effort"] as? String, !level.isEmpty {
                effort = level
            }
            // Anche `cwd` sta in cima al record, e serve a risolvere i
            // percorsi relativi degli strumenti che scrivono (ISC-175).
            if let where_ = record["cwd"] as? String, !where_.isEmpty {
                sessionCwd = where_
            }
            guard let type = record["type"] as? String else { continue }
            let when = Self.date(record["timestamp"] as? String)
            if let raw = record["timestamp"] as? String, !raw.isEmpty {
                if latestRecordAt == nil || when > latestRecordAt! { latestRecordAt = when }
            }
            switch type {
            case "user": ingestUser(record, at: when)
            case "assistant": ingestAssistant(record, at: when)
            case "queue-operation": ingestQueue(record)
            default: continue
            }
        }
    }

    private func ingestQueue(_ record: [String: Any]) {
        let content = (record["content"] as? String) ?? ""
        switch record["operation"] as? String {
        case "enqueue":
            guard !Self.isMachineMade(content) else { return }
            queued.append(content)
        case "remove":
            if let index = queued.firstIndex(of: content) {
                queued.remove(at: index)
                queueConsumed += 1
            }
        case "dequeue":
            if !queued.isEmpty {
                queued.removeFirst()
                queueConsumed += 1
            }
        default:
            return
        }
    }

    /// Un messaggio accodato dal harness e non da una persona: comincia con
    /// un tag. `<task-notification>` è quello visto il 27/08.
    static func isMachineMade(_ content: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    private func ingestUser(_ record: [String: Any], at when: Date) {
        guard let message = record["message"] as? [String: Any] else { return }
        // A prompt is text; a tool result is an array of result blocks. The
        // two arrive as the same record type and mean opposite things.
        if let text = message["content"] as? String {
            if record["isMeta"] as? Bool == true {
                if let feedback = Self.hookFeedback(text) {
                    openFollowUp(source: feedback.source, reason: feedback.reason, at: when)
                }
                return
            }
            // Un comando locale (`/model`, `/clear`, una skill) NON è una
            // frase che l'umano ha scritto all'agente: Claude Code lo mette
            // nel transcript come messaggio utente, ma imbustato, e la sua
            // uscita arriva come un SECONDO messaggio utente. Letti alla
            // lettera diventavano due turni, uno con dentro il markup e uno
            // con dentro i codici di colore del terminale, e il nome della
            // sessione lo prendeva da lì (visto da lui il 26/08 su `/model`).
            switch Self.comandoLocale(text) {
            case let .comando(riga):
                beginTurn(prompt: riga, at: when)
                if let index = openTurn, turns.indices.contains(index) {
                    turns[index].isLocalCommand = true
                }
            case let .uscita(testo):
                // L'uscita appartiene al turno del comando che l'ha prodotta.
                // Se non ce n'è uno aperto, uno lo apre: meglio un turno senza
                // domanda che una riga di risposta buttata via.
                if openTurn == nil { beginTurn(prompt: "", at: when) }
                if let index = openTurn, turns.indices.contains(index) {
                    turns[index].answer = testo
                    turns[index].finishedAt = when
                    turns[index].isLocalCommand = true
                    openTurn = nil
                }
            case .rumore:
                return
            case .nessuno:
                beginTurn(prompt: text, at: when)
            }
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        var prompt = ""
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { prompt += text }
            case "tool_result":
                closeTool(id: block["tool_use_id"] as? String,
                          failed: block["is_error"] as? Bool ?? false, at: when)
            default: continue
            }
        }
        if !prompt.isEmpty, record["isMeta"] as? Bool != true {
            beginTurn(prompt: prompt, at: when)
        }
    }


    // MARK: - I comandi locali

    /// Il prefisso è il confine: gli altri messaggi meta sono istruzioni del
    /// harness e restano invisibili, mentre questo solo rimanda il modello
    /// dentro il turno che aveva appena provato a chiudere.
    static func hookFeedback(_ text: String) -> (source: String, reason: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Stop hook feedback:"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let remainder = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard remainder.hasPrefix("["),
              let separator = remainder.range(of: "]:") else {
            return ("", remainder)
        }
        let pathStart = remainder.index(after: remainder.startIndex)
        let path = String(remainder[pathStart..<separator.lowerBound])
        let filename = (path as NSString).lastPathComponent
        let source = filename.firstIndex(of: ".").map { String(filename[..<$0]) }
            ?? filename
        let reason = String(remainder[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (source, reason)
    }

    /// Che cosa è, davvero, un messaggio utente imbustato da Claude Code.
    enum Locale: Equatable {
        /// `<command-name>/model</command-name>` più i suoi argomenti.
        case comando(String)
        /// `<local-command-stdout>…</local-command-stdout>`, cioè quello che
        /// il comando ha risposto, già senza codici di colore.
        case uscita(String)
        /// L'avvertenza che Claude Code infila per sé stesso, e la riga vuota
        /// che a volte accompagna un comando: niente da mostrare.
        case rumore
        /// Una frase scritta da una persona.
        case nessuno
    }

    static func comandoLocale(_ testo: String) -> Locale {
        let t = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nome = fra(t, "command-name") {
            let args = (fra(t, "command-args") ?? "")
                .trimmingCharacters(in: .whitespaces)
            let riga = nome.hasPrefix("/") ? nome : "/" + nome
            return .comando(args.isEmpty ? riga : "\(riga) \(args)")
        }
        if let fuori = fra(t, "local-command-stdout") {
            let pulito = senzaCodici(fuori).trimmingCharacters(in: .whitespacesAndNewlines)
            return pulito.isEmpty ? .rumore : .uscita(pulito)
        }
        if let errore = fra(t, "local-command-stderr") {
            let pulito = senzaCodici(errore).trimmingCharacters(in: .whitespacesAndNewlines)
            return pulito.isEmpty ? .rumore : .uscita(pulito)
        }
        if t.contains("<local-command-caveat>") { return .rumore }
        return .nessuno
    }

    /// Il contenuto di un tag, senza pretendere che il testo sia XML valido:
    /// quello che arriva qui dentro non lo è quasi mai (l'uscita di un comando
    /// può contenere qualunque carattere), e un parser vero fallirebbe proprio
    /// sui casi che contano.
    private static func fra(_ testo: String, _ tag: String) -> String? {
        guard let apre = testo.range(of: "<\(tag)>"),
              let chiude = testo.range(of: "</\(tag)>", range: apre.upperBound..<testo.endIndex)
        else { return nil }
        return String(testo[apre.upperBound..<chiude.lowerBound])
    }

    /// Via le sequenze di colore del terminale. `/model` risponde
    /// `Set model to \u{1B}[1mFable 5\u{1B}[22m`, e quei codici in una pagina
    /// che non è un terminale si leggono come `[1mFable 5[22m`.
    static func senzaCodici(_ testo: String) -> String {
        var fuori = ""
        var i = testo.startIndex
        while i < testo.endIndex {
            if testo[i] == "\u{1B}" {
                var j = testo.index(after: i)
                // CSI: `ESC [` … lettera finale. Le altre sequenze (OSC, e la
                // forma a due caratteri) si saltano con la stessa regola
                // grossolana, che qui basta perché il testo è breve.
                if j < testo.endIndex, testo[j] == "[" {
                    j = testo.index(after: j)
                    while j < testo.endIndex, !testo[j].isLetter { j = testo.index(after: j) }
                    if j < testo.endIndex { j = testo.index(after: j) }
                } else if j < testo.endIndex {
                    j = testo.index(after: j)
                }
                i = j
                continue
            }
            fuori.append(testo[i])
            i = testo.index(after: i)
        }
        return fuori
    }

    private func ingestAssistant(_ record: [String: Any], at when: Date) {
        guard let message = record["message"] as? [String: Any] else { return }
        if let named = message["model"] as? String, !named.isEmpty { model = named }
        // Letto PRIMA della guardia sul turno aperto: i numeri della sessione
        // non dipendono dal fatto che ci sia un turno in corso, e metterli
        // dopo li avrebbe persi in silenzio proprio sul primo record.
        if let usage = message["usage"] as? [String: Any] {
            func token(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            contextTokens = token("input_tokens")
                + token("cache_creation_input_tokens")
                + token("cache_read_input_tokens")
            outputTokens = (outputTokens ?? 0) + token("output_tokens")
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        if openTurn == nil,
           let last = turns.indices.last,
           let messageID = message["id"] as? String,
           closingMessageID[turns[last].id] == messageID {
            turns[last].finishedAt = nil
            openTurn = last
        } else if openTurn == nil {
            beginTurn(prompt: "", at: when)
        }
        guard let index = openTurn, turns.indices.contains(index) else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "thinking":
                let raw = (block["thinking"] as? String)
                    ?? (block["text"] as? String) ?? ""
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                turns[index].steps.append(AgentStep(
                    id: "thinking-\(turns[index].id)-\(turns[index].steps.count)",
                    kind: .thinking, title: "Ragionamento",
                    detail: Self.clamp(text)))
            case "text":
                if let text = block["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Ogni testo entra SUBITO come passo, al suo posto nella
                    // fila: rimandarlo a quando arriva il successivo lo faceva
                    // scivolare dopo gli strumenti che invece l'avevano
                    // seguito, e l'ordine è metà di quello che si legge.
                    // L'ultimo di questi testi è la risposta, e alla chiusura
                    // del turno esce dai passi: la risposta si vede sempre,
                    // quindi averla anche in un blocco sarebbe scriverla due
                    // volte.
                    let passo = "note-\(turns[index].id)-\(turns[index].steps.count)"
                    turns[index].steps.append(AgentStep(
                        id: passo, kind: .note, title: Self.headline(text),
                        detail: Self.clamp(text)))
                    // Un turno ha una storia sola: pensieri, note e strumenti
                    // restano nella sua fila. Solo la seconda risposta ha un
                    // posto proprio, perché nasce dopo che lo Stop hook ha
                    // rimesso il modello al lavoro.
                    if turns[index].followUps.isEmpty {
                        turns[index].answer = text
                    } else {
                        turns[index].followUps[turns[index].followUps.count - 1].answer = text
                    }
                    answerStep[turns[index].id] = passo
                }
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let summary = Self.summarise(tool: name, input: input)
                turns[index].tools.append(AgentToolUse(
                    id: id, name: name, summary: summary,
                    startedAt: when))
                turns[index].steps.append(AgentStep(
                    id: id, kind: .tool,
                    title: summary.isEmpty ? name : "\(name) · \(Self.oneLine(summary))",
                    detail: Self.detail(tool: name, input: input),
                    filePath: Self.writtenFile(tool: name, input: input,
                                               cwd: sessionCwd)))
            default: continue
            }
        }
        // `tool_use` means the assistant is going to keep going; anything else
        // is the end of its turn, and the next move is the human's.
        if let reason = message["stop_reason"] as? String, reason != "tool_use" {
            turns[index].finishedAt = when
            if let messageID = message["id"] as? String {
                closingMessageID[turns[index].id] = messageID
            }
            if let passo = answerStep.removeValue(forKey: turns[index].id) {
                turns[index].steps.removeAll { $0.id == passo }
            }
            // A tool still open at the end of a turn never got its result
            // written: the run was interrupted. Left open it would tick
            // upwards for ever in the inspector.
            for tool in turns[index].tools.indices
            where turns[index].tools[tool].finishedAt == nil {
                turns[index].tools[tool].finishedAt = when
            }
            openTurn = nil
        }
    }

    private func beginTurn(prompt: String, at when: Date) {
        if let index = openTurn, turns.indices.contains(index),
           turns[index].finishedAt == nil {
            turns[index].finishedAt = when
        }
        turns.append(AgentTurn(id: nextID, prompt: prompt, startedAt: when))
        nextID += 1
        openTurn = turns.count - 1
        if turns.count > 500 {
            turns.removeFirst(turns.count - 500)
            openTurn = turns.count - 1
        }
    }

    private func openFollowUp(source: String, reason: String, at when: Date) {
        let index: Int
        if let openTurn, turns.indices.contains(openTurn) {
            index = openTurn
        } else if turns.isEmpty {
            // Un transcript cominciato dal richiamo deve restare leggibile:
            // non c'è un turno precedente da riaprire, quindi ne nasce uno
            // senza domanda invece di perdere l'unico testo disponibile.
            beginTurn(prompt: "", at: when)
            guard let openTurn else { return }
            index = openTurn
        } else {
            index = turns.count - 1
            turns[index].finishedAt = nil
            openTurn = index
        }
        turns[index].followUps.append(AgentFollowUp(
            source: source, reason: reason, at: when))
    }

    private func closeTool(id: String?, failed: Bool, at when: Date) {
        guard let id else { return }
        for turn in turns.indices.reversed() {
            guard let tool = turns[turn].tools.firstIndex(where: { $0.id == id })
            else { continue }
            turns[turn].tools[tool].finishedAt = when
            turns[turn].tools[tool].isError = failed
            if let step = turns[turn].steps.firstIndex(where: { $0.id == id }) {
                turns[turn].steps[step].isError = failed
            }
            if failed { turns[turn].failed = true }
            return
        }
    }

    /// The one line worth showing for a tool call.
    ///
    /// Each vendor names its inputs differently, so this is the adapter's job
    /// and not the core's. The fallback is deliberately the first string in the
    /// input rather than the tool's name repeated: a new tool nobody has
    /// taught this function about still says something true.
    static func summarise(tool: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        switch tool {
        case "Bash", "BashOutput":
            return string("command") ?? string("description") ?? ""
        case "Read", "Write", "Edit", "NotebookEdit":
            return string("file_path").map { ($0 as NSString).lastPathComponent } ?? ""
        case "Grep":
            return string("pattern") ?? ""
        case "Glob":
            return string("pattern") ?? ""
        case "Agent", "Task":
            return string("description") ?? string("subagent_type") ?? ""
        case "WebFetch", "WebSearch":
            return string("url") ?? string("query") ?? ""
        case "Skill":
            return string("skill") ?? ""
        default:
            for key in input.keys.sorted() {
                if let value = string(key) { return value }
            }
            return ""
        }
    }

    /// Il file che questo strumento ha SCRITTO, assoluto, o `nil` (ISC-175).
    ///
    /// L'elenco è corto e chiuso per un motivo: sono gli strumenti di Claude
    /// Code che creano o cambiano un file. `Read` non c'è, ed è la decisione
    /// che vale la pena scrivere — porta anche lui `file_path`, quindi
    /// includerlo costava una riga, ma un'anteprima esiste per far vedere
    /// quello che l'agente ha appena FATTO, e un file letto lo aveva già fatto
    /// qualcun altro. Ogni riga del blocco diventerebbe un link, e un link su
    /// tutto non è più un link (ISC-175, e il brief lo chiede esplicito).
    ///
    /// `MultiEdit` è dentro anche se l'ISA nomina i tre fratelli: è la stessa
    /// forma (`file_path`) e scrive un file, quindi sta nella regola che l'ISA
    /// enuncia — «ogni strumento che scrive o modifica un file» — e lasciarlo
    /// fuori sarebbe un link che c'è o non c'è a seconda di come l'agente ha
    /// deciso di raggruppare le sue modifiche.
    static func writtenFile(tool: String, input: [String: Any],
                            cwd: String?) -> String? {
        let raw: String?
        switch tool {
        case "Write", "Edit", "MultiEdit":
            raw = input["file_path"] as? String
        case "NotebookEdit":
            raw = (input["notebook_path"] as? String) ?? (input["file_path"] as? String)
        default:
            return nil
        }
        return WrittenFile.absolute(raw, cwd: cwd)
    }

    /// Tutto quello che il passo contiene, per quando lo apri.
    ///
    /// La sintesi risponde a «cos'è questo passo», il dettaglio a «cosa c'è
    /// dentro»: il comando per intero invece della sua prima riga, il testo
    /// scritto in un file, il percorso completo invece del solo nome. Le
    /// chiavi si stampano in ordine, così un attrezzo che questa funzione non
    /// conosce mostra comunque i suoi ingressi invece di una riga vuota.
    static func detail(tool: String, input: [String: Any]) -> String {
        var righe: [String] = []
        for chiave in input.keys.sorted() {
            let valore = input[chiave]
            let testo: String
            if let stringa = valore as? String { testo = stringa }
            else if let numero = valore as? NSNumber { testo = numero.stringValue }
            else if let dati = try? JSONSerialization.data(
                        withJSONObject: valore ?? [:],
                        options: [.prettyPrinted, .withoutEscapingSlashes]) {
                testo = String(decoding: dati, as: UTF8.self)
            } else { continue }
            guard !testo.isEmpty else { continue }
            // Una chiave sola non merita l'etichetta: `Bash` è il comando e
            // basta, e scrivere «command:» sopra di esso è rumore.
            righe.append(input.count == 1 ? testo : "\(chiave): \(testo)")
        }
        return clamp(righe.joined(separator: "\n"))
    }

    /// Un passo non tiene in memoria un file intero: oltre questa taglia il
    /// testo si taglia e lo dice. Serve a leggere, non ad archiviare.
    static let detailLimit = 20_000

    static func clamp(_ text: String) -> String {
        guard text.count > detailLimit else { return text }
        return String(text.prefix(detailLimit)) + "\n… (tagliato)"
    }

    /// La prima riga di un testo, per la riga chiusa di un passo.
    static func headline(_ text: String) -> String {
        let riga = text.split(separator: "\n").first.map(String.init) ?? text
        return oneLine(riga)
    }

    static func oneLine(_ text: String) -> String {
        let piatto = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return piatto.count > 72 ? String(piatto.prefix(71)) + "…" : piatto
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        return formatter.date(from: raw) ?? plainFormatter.date(from: raw) ?? Date()
    }
}
