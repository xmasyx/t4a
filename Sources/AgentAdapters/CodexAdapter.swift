//  CodexAdapter.swift — the second vendor, and the proof that the first one
//  was not the design.
//
//  Nothing outside this file knows Codex exists except one line in the
//  registry. The rail, the inspector, the card, the composer and the fold all
//  run on `AgentTurn` and `AgentActivity`, which is what ISC-31 is asking:
//  detection, state and turns arrive from a new vendor with no change to the
//  core.
//
//  The shapes below were read off the rollout files on disk on 2026-08-20, not
//  taken from documentation: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`,
//  a `session_meta` first line carrying `cwd`, then `event_msg` records for
//  the conversation and `response_item` records for the tool traffic.

import Foundation
import TerminalCore

@MainActor
final class CodexAdapter: AgentAdapter {
    static let identifier = "codex"

    static func recognises(process: String, commandLine: String) -> Bool {
        let bare = (process as NSString).lastPathComponent
        if bare == "codex" { return true }
        return ShellCommandLine.programs(in: commandLine).contains("codex")
    }

    /// Codex files its sessions by DATE, not by project, so the directory says
    /// nothing about which pane wrote it and the `cwd` in the file says
    /// everything. Today's directory is watched, and the month above it, which
    /// is what carries the watch across midnight.
    static func transcriptDirectories(home: URL, cwd: URL) -> [URL] {
        let root = configurationRoot(home: home).appendingPathComponent("sessions")
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: Date())
        guard let year = parts.year, let month = parts.month, let day = parts.day
        else { return [root] }
        let monthDirectory = root
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
        return [monthDirectory.appendingPathComponent(String(format: "%02d", day)),
                monthDirectory]
    }

    static func configurationRoot(home: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent(".codex")
    }

    static func file(_ url: URL, belongsTo cwd: URL) -> Bool {
        guard url.pathExtension == "jsonl",
              url.lastPathComponent.hasPrefix("rollout-") else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 16), !head.isEmpty
        else { return false }
        let wanted = Set([cwd.path, cwd.resolvingSymlinksInPath().path])
        for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any] else { continue }
            guard object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let recorded = payload["cwd"] as? String else { continue }
            let resolved = URL(fileURLWithPath: recorded).resolvingSymlinksInPath().path
            return wanted.contains(recorded) || wanted.contains(resolved)
        }
        return false
    }

    // MARK: - The model

    private(set) var turns: [AgentTurn] = []
    private(set) var model = ""
    private(set) var latestRecordAt: Date?

    /// Questo fornitore non scrive i token né lo sforzo nei suoi rollout: i
    /// record letti il 20/08 portano la conversazione e il traffico degli
    /// attrezzi, e niente di simile a un conteggio. Quindi `nil`, che nella
    /// barra diventa un trattino — un numero preso da un'altra parte sarebbe
    /// una stima, ed è la cosa che ISC-149 vieta.
    ///
    /// Sono scritte a mano e non ereditate da un'estensione di comodo: il
    /// giorno che i rollout cominceranno a portare i token, il compilatore
    /// non dirà niente, ma queste tre righe sono il posto dove qualcuno le
    /// cercherà, con scritto accanto perché oggi non ci sono.
    var contextTokens: Int? { nil }
    var outputTokens: Int? { nil }
    var effort: String? { nil }
    /// Codex non scrive una coda nel rollout: niente ricevuta da lui.
    var queued: [String] { [] }
    var queueConsumed: Int { 0 }
    /// La cartella in cui gira questa sessione, letta dal rollout: il
    /// `session_meta` la porta in prima riga e il `turn_context` la ripete.
    /// Serve solo a risolvere i percorsi relativi degli strumenti che
    /// scrivono (ISC-175).
    private(set) var sessionCwd: String?
    private var openTurn: Int?
    private var nextID = 1

    init() {}

    var activity: AgentActivity {
        guard !turns.isEmpty else { return .idle }
        return openTurn == nil ? .waiting : .working
    }

    /// What this vendor calls its families (ISC-123).
    static let modelFamilies = ["codex", "gpt"]

    func rewind() {
        turns.removeAll()
        model = ""
        latestRecordAt = nil
        sessionCwd = nil
        openTurn = nil
        nextID = 1
    }

    /// Codex draws the same kind of numbered question, so the same scanner
    /// reads it. It is shared code and not a shared assumption: the scanner
    /// looks for a selection marker plus either a key footer or a yes/no pair,
    /// all properties of the drawing rather than of the vendor.
    func approval(on grid: any TerminalGrid) -> AgentApproval? {
        // A card is offered on a PERMISSION and never on a menu: on
        // `/model` it used to sit on top of the five choices (ISC-122).
        guard let prompt = SelectorScanner.permission(on: grid) else { return nil }
        let answers = SelectorScanner.answers(for: prompt)
        let noise = ["do you want to proceed?", "allow command?"]
        return AgentApproval(title: prompt.title,
                             detail: prompt.detail.filter { !noise.contains($0.lowercased()) },
                             options: [answers.approve, answers.deny],
                             firstRow: prompt.firstRow)
    }

    func ingest(lines: [String]) {
        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any],
                let payload = record["payload"] as? [String: Any] else { continue }
            let when = ClaudeCodeAdapter.date(record["timestamp"] as? String)
            if let raw = record["timestamp"] as? String, !raw.isEmpty {
                if latestRecordAt == nil || when > latestRecordAt! { latestRecordAt = when }
            }
            // `cwd` sta nel `session_meta` e nel `turn_context`, e serve a
            // risolvere i percorsi relativi degli strumenti che scrivono
            // (ISC-175). Si legge qui, prima dello switch, perché i due
            // record che lo portano sono due e la riga sarebbe la stessa.
            if let where_ = payload["cwd"] as? String, !where_.isEmpty {
                sessionCwd = where_
            }
            switch record["type"] as? String {
            case "session_meta":
                if let named = payload["model"] as? String { model = named }
            case "turn_context":
                if let named = payload["model"] as? String, !named.isEmpty { model = named }
            case "event_msg":
                ingestEvent(payload, at: when)
            case "response_item":
                ingestItem(payload, at: when)
            default: continue
            }
        }
    }

    private func ingestEvent(_ payload: [String: Any], at when: Date) {
        switch payload["type"] as? String {
        case "user_message":
            beginTurn(prompt: payload["message"] as? String ?? "", at: when)
        // `task_started` deliberately opens nothing. It is written BEFORE the
        // prompt it belongs to (record 1 against record 8 in a real rollout),
        // so a turn opened here is an empty one that the real prompt then
        // closes — two turns in the inspector for one thing the person did.
        // The prompt opens the turn; a tool call opens one only if nothing is
        // open, which is what covers attaching to a session already running.
        case "agent_message":
            if let index = openTurn, turns.indices.contains(index),
               let text = payload["message"] as? String, !text.isEmpty {
                turns[index].answer = text
            }
        case "task_complete":
            guard let index = openTurn, turns.indices.contains(index) else { return }
            if let last = payload["last_agent_message"] as? String, !last.isEmpty {
                turns[index].answer = last
            }
            turns[index].finishedAt = when
            for tool in turns[index].tools.indices
            where turns[index].tools[tool].finishedAt == nil {
                turns[index].tools[tool].finishedAt = when
            }
            openTurn = nil
        default: return
        }
    }

    private func ingestItem(_ payload: [String: Any], at when: Date) {
        switch payload["type"] as? String {
        case "function_call", "custom_tool_call":
            if openTurn == nil { beginTurn(prompt: "", at: when) }
            guard let index = openTurn, turns.indices.contains(index) else { return }
            let name = payload["name"] as? String ?? "tool"
            let raw = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
            let id = payload["call_id"] as? String ?? UUID().uuidString
            let summary = Self.summarise(tool: name, arguments: raw)
            turns[index].tools.append(AgentToolUse(
                id: id, name: name, summary: summary, startedAt: when))
            // Il passo, con la stessa forma che ha dall'altro fornitore: senza
            // di lui il lavoro di un turno Codex non ha blocchi da aprire, e
            // soprattutto non ha dove appendere il percorso del file scritto,
            // che è quello che ISC-175 chiede anche a questo adattatore. Il
            // dettaglio sono gli argomenti come Codex li ha scritti — una
            // stringa JSON — che è tutto quello che il rollout contiene.
            turns[index].steps.append(AgentStep(
                id: id, kind: .tool,
                title: summary.isEmpty ? name
                    : "\(name) · \(ClaudeCodeAdapter.oneLine(summary))",
                detail: ClaudeCodeAdapter.clamp(raw),
                filePath: Self.writtenFile(tool: name, arguments: raw,
                                           cwd: sessionCwd)))
        case "function_call_output", "custom_tool_call_output":
            closeTool(id: payload["call_id"] as? String,
                      output: payload["output"], at: when)
        case "message":
            ingestMessage(payload, at: when)
        default: return
        }
    }

    /// A turn of the conversation, as Codex files it.
    ///
    /// The prompt is not in the `user_message` event — it is in a
    /// `response_item/message` with `role: user`, alongside two kinds of
    /// record that are NOT the person talking: the `developer` messages that
    /// carry the system instructions, and a `user` message whose text is an
    /// `<environment_context>` block Codex writes for itself. Taking every
    /// user-role message as a prompt would open a turn for the harness's own
    /// preamble, so the synthetic ones are recognised by their shape: they are
    /// a tagged block and nothing else.
    private func ingestMessage(_ payload: [String: Any], at when: Date) {
        guard let role = payload["role"] as? String else { return }
        let blocks = payload["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch role {
        case "user":
            guard !text.hasPrefix("<") else { return }
            beginTurn(prompt: text, at: when)
        case "assistant":
            if let index = openTurn, turns.indices.contains(index) {
                turns[index].answer = text
            }
        default: return
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

    private func closeTool(id: String?, output: Any?, at when: Date) {
        guard let id else { return }
        // Codex writes the outcome in the body rather than in a flag, so the
        // failure is read from the body — and only from a shape it actually
        // uses, never from the word "error" appearing in some tool's text.
        var failed = false
        if let dictionary = output as? [String: Any] {
            if let success = dictionary["success"] as? Bool { failed = !success }
            if let code = dictionary["exit_code"] as? Int { failed = failed || code != 0 }
        }
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

    /// Il file che questo strumento ha SCRITTO, assoluto, o `nil` (ISC-175).
    ///
    /// Due forme, perché Codex ne usa due. Gli strumenti che scrivono un file
    /// nominato lo mettono in `path` o `file_path` dentro gli argomenti, come
    /// tutti; `apply_patch` invece non ha un campo, e i percorsi stanno dentro
    /// il CORPO della patch, sulle righe `*** Add File:`, `*** Update File:`
    /// e `*** Move to:`.
    ///
    /// Su una patch che tocca più file si prende il PRIMO, e lo dico invece di
    /// lasciarlo scoprire: un passo è una riga sola con un nome sopra, quindi
    /// o si sceglie o si inventa una riga per file — e inventarla vorrebbe
    /// dire che un blocco non corrisponde più a una chiamata. `*** Move to:`
    /// vince su `*** Update File:` nella stessa patch perché è la
    /// destinazione, cioè il file che dopo la patch esiste davvero.
    ///
    /// `*** Delete File:` NON conta: dopo quella patch il file non c'è più, e
    /// un link che si apre solo per dire «non è più sul disco» è un link che
    /// esiste per fallire.
    static func writtenFile(tool: String, arguments: String,
                            cwd: String?) -> String? {
        let raw: String?
        if tool.contains("apply_patch") || arguments.contains("*** Begin Patch") {
            raw = patchTarget(in: arguments)
        } else if let parsed = try? JSONSerialization.jsonObject(
                    with: Data(arguments.utf8)) as? [String: Any] {
            // Solo gli strumenti che SCRIVONO. Un `read_file` porta lo stesso
            // `path` e non deve diventare un link, per la stessa ragione per
            // cui `Read` non lo diventa dall'altra parte.
            let writes = ["write", "create", "edit", "patch", "apply", "update"]
            guard writes.contains(where: { tool.lowercased().contains($0) })
            else { return nil }
            raw = (parsed["path"] as? String) ?? (parsed["file_path"] as? String)
        } else {
            raw = nil
        }
        return WrittenFile.absolute(raw, cwd: cwd)
    }

    /// Il primo file che la patch scrive, letto dalle sue intestazioni.
    static func patchTarget(in patch: String) -> String? {
        var update: String?
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let riga = line.trimmingCharacters(in: .whitespaces)
            for marker in ["*** Move to:", "*** Add File:", "*** Update File:"] {
                guard riga.hasPrefix(marker) else { continue }
                let value = riga.dropFirst(marker.count)
                    .trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                // Una destinazione chiude la domanda subito; un aggiornamento
                // si tiene da parte, perché una `*** Move to:` più in basso
                // nella stessa patch lo sostituisce.
                if marker == "*** Update File:" || marker == "*** Add File:" {
                    if update == nil { update = value }
                } else {
                    return value
                }
            }
        }
        return update
    }

    /// Codex passes tool arguments as a JSON STRING, so the one line worth
    /// showing is inside a second parse rather than beside the first.
    static func summarise(tool: String, arguments: String) -> String {
        guard !arguments.isEmpty else { return "" }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(arguments.utf8))
            as? [String: Any] else {
            // Codex 0.148 hands its `exec` tool a fragment of JavaScript, not
            // JSON: `const r = await tools.exec_command({"cmd":"cat a.txt",…})`.
            // The command is in there and is the only part worth showing, so it
            // is lifted out by name rather than the whole wrapper being printed
            // at somebody who wanted to know what ran.
            // Both spellings, because the same Codex build writes both: the
            // key is quoted for some fields of the same object literal and
            // bare for others (`{cmd:"cat a.txt","workdir":"…"}`, read off a
            // rollout 2026-08-20). A matcher taught only the quoted form
            // printed the whole JavaScript wrapper at the reader.
            for key in ["\"cmd\":", "\"command\":", "cmd:", "command:"] {
                guard let start = arguments.range(of: key) else { continue }
                let rest = arguments[start.upperBound...]
                    .drop { $0 == " " }
                guard rest.first == "\"" else { continue }
                let body = rest.dropFirst()
                guard let close = body.firstIndex(of: "\"") else { continue }
                let value = String(body[..<close])
                if !value.isEmpty { return value }
            }
            return String(arguments.prefix(120))
        }
        for key in ["command", "cmd", "query", "path", "file_path", "pattern", "input"] {
            if let value = parsed[key] as? String, !value.isEmpty { return value }
            if let list = parsed[key] as? [String], !list.isEmpty {
                return list.joined(separator: " ")
            }
        }
        for key in parsed.keys.sorted() {
            if let value = parsed[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }
}
