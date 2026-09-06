//  AgentObserver.swift — one pane's view of the agent running inside it.
//
//  It decides WHICH adapter owns the program in front of the shell, finds the
//  file that adapter reads, follows it, and republishes what comes out. It
//  knows the name of no vendor: the list of adapters is the only place a
//  vendor appears, and a second one is a line in that list (ISC-31).

import Foundation
import TerminalCore

/// Every adapter T4A ships. The ONLY place a vendor is named.
@MainActor
public enum AgentRegistry {
    public static let adapters: [any AgentAdapter.Type] = [
        ClaudeCodeAdapter.self,
        CodexAdapter.self,
    ]

    public static func adapter(forProcess process: String,
                               commandLine: String) -> (any AgentAdapter.Type)? {
        adapters.first { $0.recognises(process: process, commandLine: commandLine) }
    }
}

/// Which transcript each pane has taken (ISC-131).
///
/// Two panes running the same agent in the same directory is an ordinary
/// thing to do. Attribution now comes from a process fact — an open descriptor
/// or the vendor's pid record — but one attributable file can still be offered
/// to two observers during a handover or duplicate process report.
///
/// The claim therefore lives here, once, for the whole app: attribution says
/// which files are eligible, and the registry ensures only one pane follows
/// each eligible file. It is keyed by observer identity rather than by a name
/// the pane could change.
@MainActor
enum TranscriptRegistry {
    private static var claims: [URL: ObjectIdentifier] = [:]

    /// True when this observer may follow that file: nobody has it, or it
    /// already does.
    static func isFree(_ url: URL, for owner: ObjectIdentifier) -> Bool {
        let holder = claims[url.resolvingSymlinksInPath()]
        return holder == nil || holder == owner
    }

    static func claim(_ url: URL, for owner: ObjectIdentifier) {
        release(owner)
        claims[url.resolvingSymlinksInPath()] = owner
    }

    static func release(_ owner: ObjectIdentifier) {
        claims = claims.filter { $0.value != owner }
    }

    /// What is held right now, for the dump: a pane following nothing because
    /// its file was taken and a pane following nothing because there is no
    /// file are the same silence from outside.
    static var held: [String] { claims.keys.map(\.lastPathComponent).sorted() }
}

@MainActor
public final class AgentObserver {
    private let home: URL
    private var adapter: (any AgentAdapter)?
    private var adapterType: (any AgentAdapter.Type)?
    private var directories: [DirectoryWatch] = []
    private var tail: TranscriptTail?
    /// The directory the agent was attached in. Readable from outside since
    /// ISC-187 so a caller that only wants to hand over a late pid can pass
    /// THIS directory back and be sure of landing in the "already following
    /// it" branch of `programChanged`, instead of triggering a re-attach.
    public private(set) var cwd: URL?

    /// Raised whenever the model changed and the views should redraw.
    public var onChange: (() -> Void)?

    public private(set) var kind = ""
    public private(set) var transcript: URL?
    /// Empty while following; otherwise why no attributable file is followed.
    public private(set) var transcriptReason: String = ""
    /// The process fact that selected `transcript`, or empty when there is none.
    public private(set) var transcriptSource: String = ""
    /// The agent's own binary, from the kernel.
    ///
    /// The command line is not it: through a launcher the typed line never
    /// names the agent, and the agent's binary is versioned, so argv[0] says
    /// `claude` while the file on disk is `…/claude/versions/2.1.246`. Only
    /// the path answers "which build is running here", which is what anything
    /// reading the binary's own tables needs (ISC-187).
    public private(set) var executable: URL?
    /// When the pane said "an agent started here".
    public private(set) var attachRequestedAt: Date?
    /// When the first bytes of its transcript had been read. The gap between
    /// the two is what ISC-25 puts a bound on, and it is recorded rather than
    /// estimated afterwards.
    public private(set) var attachedAt: Date?
    /// The approval last seen on the grid, and when the state derived from it
    /// last changed — both kept so a latency claim is read from the app.
    public private(set) var approval: AgentApproval?
    public private(set) var activityChangedAt: Date?
    private var lastActivity: AgentActivity = .idle
    /// The delay between the agent WRITING a record and T4A having read it,
    /// for the last batch and for the worst one since attaching.
    public private(set) var lastLag: TimeInterval?
    public private(set) var worstLag: TimeInterval = 0
    /// The same distance, for the very first batch: this is ISC-25's number.
    public private(set) var firstLag: TimeInterval?
    /// How many times the screen has been read, and what the last read saw.
    /// A scan that never ran and a scan that found nothing are the same shape
    /// from outside, and only one of them is a parser problem.
    public private(set) var scanCount = 0
    public private(set) var lastScanRows = 0

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
    }

    public var isAttached: Bool { adapter != nil }
    /// The adapter object itself, by identity. Internal, and it exists for one
    /// question a test cannot ask any other way: adopting a late pid must KEEP
    /// the adapter, and from outside a kept adapter and a rebuilt one look the
    /// same until the turns already read go missing.
    var adapterIdentity: ObjectIdentifier? { adapter.map(ObjectIdentifier.init) }
    /// Whether the observer ever got the agent's pid.
    ///
    /// Attached-with-a-pid and attached-without-one are two different states
    /// and only one of them can read the transcript off the kernel or open
    /// the agent's binary, so the difference has to be askable from outside:
    /// it is what tells the pane to go back and look for the process again.
    public var hasProcess: Bool { agentPid != nil }
    /// The process the observer adopted, kept optional because attachment can
    /// precede the process-tree update that supplies it.
    public var processIdentifier: Int32? { agentPid }
    /// What the AGENT calls this session: the name of the transcript it is
    /// writing, which for both adapters is the session id with the extension
    /// taken off. It is the only identifier T4A and another program watching
    /// the same session can both arrive at, so it is what a facts provider is
    /// given (ISC-139).
    public var sessionIdentifier: String {
        transcript.map { $0.deletingPathExtension().lastPathComponent } ?? ""
    }
    public var turns: [AgentTurn] { adapter?.turns ?? [] }
    public var model: String { adapter?.model ?? "" }
    /// I tre numeri che l'adattatore ha letto dal file del suo fornitore.
    /// `nil` quando non c'è nessun adattatore agganciato, che è la stessa
    /// risposta di un adattatore che quel numero non ce l'ha: in entrambi i
    /// casi la barra non ha una lettura, e disegna un trattino.
    public var contextTokens: Int? { adapter?.contextTokens }
    public var outputTokens: Int? { adapter?.outputTokens }
    public var effort: String? { adapter?.effort }
    /// La coda dei messaggi come la tiene l'agente (ISC-194).
    public var queued: [String] { adapter?.queued ?? [] }
    public var queueConsumed: Int { adapter?.queueConsumed ?? 0 }
    /// The model as the bar prints it. Shortened by the ADAPTER, because only
    /// it knows what its vendor calls its families (ISC-123).
    public var shortModel: String { adapter?.shortModel ?? "" }

    /// What the pane is doing, with the screen given the last word.
    ///
    /// A permission on screen beats anything the transcript says, and it has
    /// to: the transcript's last record is the tool call the agent is waiting
    /// to be allowed to run, which on its own reads as "working".
    public var activity: AgentActivity {
        if approval != nil { return .waiting }
        return adapter?.activity ?? .idle
    }

    // MARK: - Attaching

    /// A program came to the front of this pane. If an adapter knows it, start
    /// watching for its file.
    /// The agent's own pid, when the caller knows it: it is what lets the
    /// transcript be attributed by a process fact: either a kernel descriptor
    /// or the vendor's own record for that pid.
    private var agentPid: Int32?

    public func programChanged(process: String, commandLine: String, cwd: URL,
                               pid: Int32? = nil) {
        guard let type = AgentRegistry.adapter(forProcess: process,
                                               commandLine: commandLine) else {
            if adapter != nil { detach() }
            return
        }
        // Already following this vendor in this directory: nothing to do
        // EXCEPT take a pid that arrived late. A re-attach would throw away
        // the turns read so far, so the pid is adopted in place.
        //
        // Why a pid arrives late at all: the pane hands one over only when it
        // finds the agent in its process TREE, and at the moment the agent is
        // first recognised that tree is often still empty — the pane then
        // attaches through the fallback, with no pid, and until 2026-08-27
        // nobody ever came back. Measured on 7 real attaches that day: 2 with
        // a pid, 5 without. Everything that needs the process — the binary's
        // command table (ISC-187) and factual transcript attribution
        // (ISC-220) — was therefore off five times in seven.
        if adapterType?.identifier == type.identifier, self.cwd?.path == cwd.path,
           adapter != nil {
            // Only when the path resolves. `proc_pidpath` failing means the
            // process is already gone, and pinning a dead pid here would stop
            // the pane retrying while giving it nothing — the one outcome
            // worse than not having a pid at all.
            if agentPid == nil, let pid, let path = Self.executablePath(of: pid) {
                agentPid = pid
                executable = path
                lookForTranscript()
                onChange?()
            }
            return
        }
        detach()
        adapterType = type
        adapter = type.init()
        kind = type.identifier
        self.cwd = cwd
        self.agentPid = pid
        executable = pid.flatMap(Self.executablePath(of:))
        attachRequestedAt = Date()
        startWatching(type: type, cwd: cwd)
        onChange?()
    }

    /// The agent is gone. Everything it opened is closed here, because a
    /// descriptor held past its meaning is a resource nobody is using.
    public func detach() {
        tail?.stop()
        tail = nil
        TranscriptRegistry.release(ObjectIdentifier(self))
        directories.forEach { $0.stop() }
        directories.removeAll()
        adapter = nil
        adapterType = nil
        transcript = nil
        transcriptReason = ""
        transcriptSource = ""
        approval = nil
        attachedAt = nil
        attachRequestedAt = nil
        kind = ""
        executable = nil
        // The pid goes with it. It was left standing until 2026-08-27, which
        // was invisible while every attach re-set it a line later; it stopped
        // being invisible the moment `hasProcess` became the question a
        // detached observer gets asked.
        agentPid = nil
        cwd = nil
        lastActivity = .idle
        lastLag = nil
        firstLag = nil
        worstLag = 0
        onChange?()
    }

    private func startWatching(type: any AgentAdapter.Type, cwd: URL) {
        let wanted = type.transcriptDirectories(home: home, cwd: cwd)
        for directory in wanted {
            if let watch = DirectoryWatch(url: directory, onChange: { [weak self] in
                self?.lookForTranscript()
            }) {
                directories.append(watch)
                continue
            }
            // The directory does not exist yet: the agent has not written its
            // first turn. Watch the PARENT, which does exist, and pick the
            // child up the moment it is created — a poll here would be the
            // obvious answer and would put a tick in an idle terminal.
            let parent = directory.deletingLastPathComponent()
            if !directories.contains(where: { $0.url.path == parent.path }),
               let watch = DirectoryWatch(url: parent, onChange: { [weak self] in
                   self?.rewatch(type: type, cwd: cwd)
               }) {
                directories.append(watch)
            }
        }
        lookForTranscript()
    }

    private func rewatch(type: any AgentAdapter.Type, cwd: URL) {
        guard tail == nil else { return }
        let wanted = type.transcriptDirectories(home: home, cwd: cwd)
        for directory in wanted where FileManager.default.fileExists(atPath: directory.path) {
            guard !directories.contains(where: { $0.url.path == directory.path }) else { continue }
            if let watch = DirectoryWatch(url: directory, onChange: { [weak self] in
                self?.lookForTranscript()
            }) { directories.append(watch) }
        }
        lookForTranscript()
    }

    /// Follows only a transcript tied to this pane's adopted process.
    ///
    /// An open descriptor and the vendor's own pid record are process facts.
    /// Directory timestamps are not: a sibling session can write later at any
    /// moment, so a pane with neither fact remains empty and explains why.
    private func lookForTranscript() {
        guard let type = adapterType, let cwd else { return }
        guard let pid = agentPid else {
            if tail == nil {
                transcriptReason = "pid not adopted yet: nothing is followed until "
                    + "the agent process is known"
                transcriptSource = ""
            }
            // A non-nil tail was attributed before this transient state; its
            // source and empty reason remain valid until a pid arrives again.
            return
        }

        let vendorURLs = type.transcripts(
            attributedTo: pid, home: home, cwd: cwd,
            processStart: Self.processStart(of: pid))
        let existingVendorURLs = vendorURLs.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        var candidates: [(url: URL, source: String)] = []
        var seen: Set<String> = []
        for candidate in kernelTranscripts().map({ ($0, "kernel") })
            + existingVendorURLs.map({ ($0, "vendor-record") }) {
            let path = candidate.0.standardizedFileURL.path
            // Kernel comes first, so a duplicate keeps the stronger source.
            guard seen.insert(path).inserted else { continue }
            candidates.append((url: candidate.0, source: candidate.1))
        }

        let owner = ObjectIdentifier(self)
        let decision = Self.chooseTranscript(
            candidates: candidates, current: transcript,
            isFree: { TranscriptRegistry.isFree($0, for: owner) })
        if let selected = decision.url,
           selected.standardizedFileURL.path == transcript?.standardizedFileURL.path {
            transcriptReason = ""
            if !decision.source.isEmpty { transcriptSource = decision.source }
            // Empty means the chooser preserved a previously proven tail
            // across a transient read failure, so its old source also stays.
            return
        }
        if let selected = decision.url {
            tail?.stop()
            tail = nil
            transcript = nil
            transcriptReason = ""
            transcriptSource = ""
            TranscriptRegistry.release(owner)
            follow(selected, source: decision.source)
            return
        }
        if !candidates.isEmpty {
            tail?.stop()
            tail = nil
            transcript = nil
            transcriptReason = decision.reason
            transcriptSource = ""
            TranscriptRegistry.release(owner)
            return
        }

        transcriptSource = ""
        if vendorURLs.isEmpty {
            transcriptReason = "pid \(pid) holds no transcript open and has no matching session record"
        } else {
            transcriptReason = "session record of pid \(pid) names "
                + "\(vendorURLs[0].lastPathComponent), not on disk yet (no message sent)"
        }
    }

    /// Every `.jsonl` the agent holds open inside one of ITS adapter's
    /// transcript directories, from the kernel's file table.
    ///
    /// Until 28/08 this matched `/projects/` by name, which is Claude Code's
    /// tree only: a codex rollout lives under `~/.codex/sessions/…`, so for
    /// codex the process fact never answered. Keeping all matches matters for
    /// a process that briefly holds an old and a new session open together.
    private func kernelTranscripts() -> [URL] {
        guard let pid = agentPid, let type = adapterType, let cwd else { return [] }
        let directories = type.transcriptDirectories(home: home, cwd: cwd)
        return Self.openPaths(of: pid)
            .filter { Self.isTranscript(path: $0, under: directories) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Resolves an attributable candidate without observing app or process
    /// state, so every collision and session-switch branch is testable.
    nonisolated static func chooseTranscript(
        candidates: [(url: URL, source: String)], current: URL?,
        isFree: (URL) -> Bool
    ) -> (url: URL?, source: String, reason: String) {
        if let current {
            let currentPath = current.standardizedFileURL.path
            if let same = candidates.first(where: {
                $0.url.standardizedFileURL.path == currentPath
            }) {
                return (current, same.source, "")
            }
        }
        if let available = candidates.first(where: { isFree($0.url) }) {
            return (available.url, available.source, "")
        }
        if let held = candidates.first {
            return (nil, "", "transcript \(held.url.lastPathComponent) "
                + "is held by another pane")
        }
        if let current {
            // No contradictory attribution exists; preserve a tail that was
            // already proven while a process or record read fails transiently.
            return (current, "", "")
        }
        return (nil, "", "")
    }

    /// A `.jsonl` that sits inside one of the adapter's transcript directories.
    /// Pure, so the rule is testable without a process.
    nonisolated static func isTranscript(path: String, under directories: [URL]) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        let file = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path
        return directories.contains { file == $0.standardizedFileURL.path }
    }

    /// `proc_pidpath`, which is the kernel's answer and not a guess. Nil when
    /// the process is gone between the probe and here, or when this process is
    /// not allowed to ask.
    static func executablePath(of pid: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let path = String(cString: buffer)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The kernel start time distinguishes a live process from a stale vendor
    /// record left behind by an earlier process that had the same pid.
    nonisolated static func processStart(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard read == Int32(size), info.pbi_start_tvsec > 0 else { return nil }
        let seconds = TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    private static func openPaths(of pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let written = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bytes)
        }
        guard written > 0 else { return [] }
        var out: [String] = []
        for fd in fds.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size
            else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self,
                                          capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { out.append(path) }
        }
        return out
    }

    private func follow(_ url: URL, source: String) {
        adapter?.rewind()
        guard let newTail = TranscriptTail(url: url, onLines: { [weak self] lines in
            guard let self else { return }
            self.adapter?.ingest(lines: lines)
            let now = Date()
            if let written = self.adapter?.latestRecordAt {
                let lag = now.timeIntervalSince(written)
                self.lastLag = lag
                if lag > self.worstLag { self.worstLag = lag }
                if self.firstLag == nil { self.firstLag = lag }
            }
            if self.attachedAt == nil { self.attachedAt = now }
            self.noteActivity()
            self.onChange?()
        }, onVanished: { [weak self] in
            guard let self else { return }
            self.tail?.stop()
            self.tail = nil
            self.transcript = nil
            self.transcriptSource = ""
            TranscriptRegistry.release(ObjectIdentifier(self))
            self.lookForTranscript()
        }) else {
            transcript = nil
            transcriptReason = "transcript \(url.lastPathComponent) could not be opened"
            transcriptSource = ""
            return
        }
        TranscriptRegistry.claim(url, for: ObjectIdentifier(self))
        transcript = url
        transcriptReason = ""
        transcriptSource = source
        tail = newTail
        // A file rewritten shorter is read from the beginning again, so the
        // model built from the old bytes has to be thrown away first —
        // otherwise the turns arrive twice (ISC-134).
        newTail.onTruncated = { [weak self] in
            self?.adapter?.rewind()
            self?.onChange?()
        }
        // Everything already written, before the first kqueue event: a session
        // resumed with `--resume` has its whole history on disk already.
        newTail.drain()
    }

    /// Another go at finding the file, driven by the agent's own output.
    ///
    /// A directory watch fires when a file is CREATED, not when it is written
    /// to, and the two are not the same moment: Codex creates its rollout at
    /// startup and writes the session header a beat later, so the one dir
    /// event we got arrived at a file we could not yet identify, and nothing
    /// would ever have knocked again (measured 2026-08-20 — a live Codex
    /// session, its rollout on disk with the right `cwd` in it, and `turns 0`).
    /// Bytes arriving in the pane are the signal that costs nothing.
    public func retryFind() {
        guard adapter != nil, tail == nil else { return }
        lookForTranscript()
    }

    // MARK: - The screen

    /// Re-reads the live screen for a permission prompt. Called by the pane
    /// when output arrives, never on a timer.
    @discardableResult
    public func refreshApproval(on grid: any TerminalGrid) -> Bool {
        guard let adapter else {
            let had = approval != nil
            approval = nil
            return had
        }
        scanCount += 1
        lastScanRows = max(0, grid.endRow - max(grid.liveScreenTopRow, grid.endRow - 60))
        let found = adapter.approval(on: grid)
        guard found != approval else { return false }
        approval = found
        noteActivity()
        return true
    }

    /// What the screen is asking RIGHT NOW, without storing it.
    ///
    /// The card holds a picture of a question taken when the scan ran, and the
    /// click arrives later: between the two the agent may have finished,
    /// scrolled it away, or drawn a different question in the same place. This
    /// is how the click checks (ISC-127) — the same recogniser, one more time,
    /// against the grid as it is at the moment of the keystroke.
    public func approvalOnScreen(on grid: any TerminalGrid) -> AgentApproval? {
        adapter?.approval(on: grid)
    }

    /// Takes the card down now, rather than at the next scan. Used when the
    /// re-check above refuses: leaving a card up after refusing to act on it
    /// would invite a second click on the same stale question.
    public func withdrawApproval() {
        guard approval != nil else { return }
        approval = nil
        noteActivity()
    }

    /// What the recogniser makes of the live screen, whether or not a card
    /// came of it (ISC-122).
    ///
    /// It REPORTS and never decides: `refreshApproval` above is still the only
    /// thing that puts a card on the screen. It exists because from outside
    /// "no card" has two causes that look identical — a menu, rightly left
    /// alone, and an empty screen — and a bench that cannot tell them apart
    /// would go green on a claude that never opened the menu at all.
    public func reading(on grid: any TerminalGrid) -> [String: Any] {
        // Deliberately WITHOUT the cursor test: this is the diagnostic, and a
        // box the card refused because the caret was elsewhere is the single
        // most useful thing it can say (ISC-127).
        guard let prompt = SelectorScanner.scan(grid, requireCursorInside: false) else {
            return ["kind": "none", "reason": "no numbered question on the live screen"]
        }
        let caret = grid.cursor.row
        return [
            "kind": prompt.kind == .permission ? "permission" : "selector",
            "reason": prompt.kindReason,
            "title": prompt.title,
            "options": prompt.options.map { "\($0.number). \($0.label)" },
            "firstRow": prompt.firstRow,
            "lastRow": prompt.lastRow,
            "cursorRow": caret,
            "cursorInside": caret >= prompt.firstRow && caret <= prompt.lastRow,
        ]
    }

    private func noteActivity() {
        let now = activity
        guard now != lastActivity else { return }
        lastActivity = now
        activityChangedAt = Date()
    }

    /// Everything the observer can say about itself, for the dump the benches
    /// read. A latency claim is checked against these numbers.
    public var diagnostics: [String: Any] {
        var result: [String: Any] = [
            "kind": kind,
            "attached": isAttached,
            "following": transcript?.lastPathComponent ?? "",
            "transcriptReason": transcriptReason,
            "transcriptSource": transcriptSource,
            "turns": turns.count,
            "activity": activity.rawValue,
            "model": model,
            "executable": executable?.path ?? "",
            // Separate from `executable`: the pane can hold a pid whose path
            // it could not read, and a bench looking at an empty `executable`
            // has to be able to tell "no process" from "no path".
            "hasProcess": hasProcess,
            "watchedDirectories": directories.map(\.url.path),
            "transcriptsHeldAppWide": TranscriptRegistry.held,
        ]
        // Solo quando c'è una lettura: un Optional infilato in `Any` non è
        // serializzabile in JSON, e il dump è quello che leggono TUTTI i
        // banchi — un nil qui li avrebbe fatti cadere in blocco.
        if let contextTokens { result["contextTokens"] = contextTokens }
        if let outputTokens { result["outputTokens"] = outputTokens }
        if let effort { result["effort"] = effort }
        if let requested = attachRequestedAt, let attached = attachedAt {
            result["attachSeconds"] = attached.timeIntervalSince(requested)
        }
        if let firstLag { result["firstTurnLagSeconds"] = firstLag }
        if let lastLag { result["lastLagSeconds"] = lastLag }
        result["worstLagSeconds"] = worstLag
        result["scans"] = scanCount
        result["lastScanRows"] = lastScanRows
        if let changed = activityChangedAt {
            result["activityAgeSeconds"] = Date().timeIntervalSince(changed)
        }
        if let approval {
            result["approval"] = [
                "title": approval.title,
                "detail": approval.detail,
                "options": approval.options.map(\.label),
                "keys": approval.options.map { $0.keystrokes
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\u{1b}", with: "\\e") },
                "firstRow": approval.firstRow,
            ]
        }
        return result
    }
}
