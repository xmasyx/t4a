//  FactsProvider.swift — running the user's program, without ever waiting for it.
//
//  The whole feature is one executable named in `config.toml`, asked every
//  couple of seconds what it would like the bar to say (ISC-139). Three rules
//  hold it together, and each one exists because the alternative has a name.
//
//  It runs OFF the main thread, always. A statusline that can freeze the
//  terminal it decorates is a worse terminal, and a provider is code T4A did
//  not write: it can block on a network call, on a lock, on a disk that is
//  spinning up. The main thread never waits for it — it only receives what
//  came back.
//
//  It is killed at one second. Not asked to stop: killed, because a process
//  that ignores SIGTERM is exactly the process a timeout is for. And only ONE
//  runs at a time, so a provider that takes five seconds costs missed ticks
//  and never a pile of processes.
//
//  It cannot make the app write anything. Readings are held in memory, and
//  nothing here touches the configuration file — a row the user drags is a
//  write, a tick is not (ISC-106).

import Foundation
import TerminalCore

/// What the pane the keyboard is on can tell a provider about itself. The
/// provider is given the agent's OWN session id — the name of the transcript
/// it is writing — because that is the only identifier shared by T4A and by
/// whatever else on this machine is watching the same session.
struct FactsContext: Equatable, Sendable {
    var session: String = ""
    var cwd: String = ""
    var agent: String = ""
    var pid: Int32? = nil
}

/// What the provider wrote to stderr, carried from one queue to the other.
/// A box and not a captured local: the read happens on a second queue so the
/// two pipes cannot deadlock each other, and Swift wants somewhere with a
/// lifetime for the bytes to land.
private final class FactsNoise: @unchecked Sendable { var data = Data() }

@MainActor
final class FactsProvider {
    /// The last reading, by the provider's own key.
    private(set) var rows: [String: FactRow] = [:]
    /// The order the provider listed them in, which is the order the settings
    /// shows them.
    private(set) var order: [String] = []
    /// Three misses in a row and what is on the bar is no longer being
    /// refreshed. It stays on the bar, dimmed: erasing it would answer "is
    /// this number current?" with "there is no number", which reads as calm.
    private(set) var isStale = false
    private(set) var misses = 0
    private(set) var runs = 0
    private(set) var lastExit: Int32 = 0
    private(set) var lastDuration: TimeInterval = 0
    private(set) var lastTimedOut = false
    private(set) var problems: [String] = []
    /// Why the LAST run failed, or nil when the last run was fine (ISC-145).
    /// Separate from `problems`, which is a history and keeps every distinct
    /// complaint: this is the live state, so the cell it puts on the bar goes
    /// away by itself the moment the provider answers again.
    private(set) var lastFailure: String?

    /// Raised on the main thread when a reading changed something. The flag
    /// says whether the CATALOGUE changed with it — a row named for the first
    /// time, or renamed — as against the ordinary case, which is the same
    /// rows carrying new numbers.
    ///
    /// The two are told apart because they cost different things (ISC-191).
    /// Redrawing the bar every couple of seconds is what the bar is for; doing
    /// the same to the SETTINGS window throws away and rebuilds every row,
    /// every switch and every handle in it, and a rebuild that lands between
    /// the press and the release of a real click takes the view the click was
    /// made on with it. Measured 27/08 with a provider at 0.3 s and a hold of
    /// 400 ms: SIX clicks out of six on «Running work» did nothing at all.
    /// His words were «questo non mi permette di toglierlo e metterlo», and
    /// nothing failed, logged or looked broken — the switch simply came back
    /// the way it was, because the switch he pressed no longer existed.
    var onUpdate: ((_ catalogueChanged: Bool) -> Void)?
    /// Asked, on the main thread, right before each run.
    var context: () -> FactsContext = { FactsContext() }

    private var path = ""
    private var interval: TimeInterval = 2
    private var timer: Timer?
    private var inFlight = false
    private let queue = DispatchQueue(label: "dev.t4a.facts", qos: .utility)
    nonisolated static let timeout: TimeInterval = 1

    /// Point it at a program, or at nothing. Nothing is the default and the
    /// anti-pole of the whole claim: with no path there is no timer, no
    /// process, and no row — the bar is the bar it was before this file
    /// existed.
    func configure(path newPath: String, interval newInterval: TimeInterval) {
        let expanded = newPath.isEmpty ? "" : (newPath as NSString).expandingTildeInPath
        guard expanded != path || newInterval != interval else { return }
        path = expanded
        interval = max(0.1, newInterval)
        timer?.invalidate()
        timer = nil
        guard !path.isEmpty else {
            let had = !rows.isEmpty
            rows.removeAll()
            order.removeAll()
            problems.removeAll()
            isStale = false
            misses = 0
            if had { onUpdate?(false) }
            return
        }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // The common mode matters: on the default mode a menu held open, or a
        // window being dragged, stops the timer — and a bar that freezes while
        // you drag the window looks exactly like a bar that crashed.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One ask. Returns immediately: everything below the dispatch happens on
    /// a utility queue, and only the assignment of the result comes back here.
    func tick() {
        guard !path.isEmpty, !inFlight else { return }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            lastFailure = "is not something this machine can run"
            note("\(path) is not something this machine can run")
            miss()
            return
        }
        inFlight = true
        let context = context()
        let arguments = ["--session", context.session,
                         "--cwd", context.cwd,
                         "--agent", context.agent]
            + (context.pid.map { ["--pid", String($0)] } ?? [])
        let path = self.path
        queue.async { [weak self] in
            let result = FactsProvider.run(path: path, arguments: arguments)
            Task { @MainActor in self?.finish(result) }
        }
    }

    // MARK: - Off the main thread

    struct Run: Sendable {
        var output = ""
        /// The first line the program wrote to stderr, cut short (ISC-145).
        /// A provider's complaints still never reach the BAR as readings —
        /// that rule is ISC-139's and it stands. What changed is that they no
        /// longer go to `/dev/null` either: when a run fails, the one line the
        /// program printed before dying is usually the whole diagnosis, and
        /// throwing it away is how a failure came to have no explanation at
        /// all. Bounded on purpose: one line, 120 characters.
        var complaint = ""
        var status: Int32 = 0
        var timedOut = false
        var failure: String?
        var duration: TimeInterval = 0
    }

    /// The PATH a program the user names would actually find on this machine.
    ///
    /// An app opened from the Finder or the Dock inherits launchd's
    /// environment, and launchd's PATH is four directories:
    /// `/usr/bin:/bin:/usr/sbin:/sbin`. No Homebrew, no `~/.bun/bin`, no
    /// `~/.local/bin` — none of the places a person installs the tools they
    /// write scripts in. A facts provider is a program the user wrote for
    /// their own machine, and its first line is nearly always
    /// `#!/usr/bin/env something`: with launchd's PATH that line cannot
    /// resolve, and the program dies at **127** before printing a byte.
    /// Measured on the real one, from a Finder launch: `lastExit 127`, zero
    /// keys, a bar showing nothing — while the terminal in the same window ran
    /// that very program fine, because a login shell has the PATH and the app
    /// does not.
    ///
    /// So the provider is handed the PATH a LOGIN SHELL would hand it. It is
    /// resolved once per launch, on the provider's own queue, off the main
    /// thread, and remembered: asking a login shell is not free, and the
    /// answer does not change while the app is up. A shell that hangs or
    /// answers nothing costs the inherited PATH and nothing else — this must
    /// never itself become the reason the bar has no readings.
    private nonisolated(unsafe) static var resolvedPath: String?
    private nonisolated static let pathLock = NSLock()

    nonisolated static func loginPath() -> String {
        pathLock.lock()
        defer { pathLock.unlock() }
        if let resolvedPath { return resolvedPath }
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let answer = askLoginShellForPath()
        // The shell's PATH first, the app's own behind it: a directory the app
        // was launched with is one the user's program may still need, and
        // dropping it would trade one silent failure for another.
        let merged: String
        if answer.isEmpty {
            merged = inherited
        } else if inherited.isEmpty {
            merged = answer
        } else {
            let known = Set(answer.split(separator: ":"))
            let extras = inherited.split(separator: ":").filter { !known.contains($0) }
            merged = ([answer] + extras.map(String.init)).joined(separator: ":")
        }
        resolvedPath = merged
        return merged
    }

    /// `-lc` and not `-c`: the PATH a person has is built by their login files,
    /// which is exactly what a non-login shell skips. Bounded by the same
    /// SIGKILL the provider gets, at five seconds rather than one — this runs
    /// once per launch, and a login shell that takes a second is ordinary.
    nonisolated private static func askLoginShellForPath() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: LoginShell.path())
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // This provider is T4A's child too, and posix_spawn inherits the same table.
        DescriptorHygiene.markCloseOnExec()
        do { try process.run() } catch { return "" }
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What was resolved, WITHOUT resolving it. A dump must never be the thing
    /// that starts a login shell on the main thread.
    nonisolated static var cachedLoginPath: String? {
        pathLock.lock()
        defer { pathLock.unlock() }
        return resolvedPath
    }

    /// Nothing in here touches app state. It is `static` so that it cannot:
    /// a closure that captured `self` would be a main-actor object being read
    /// on a background queue, which is the bug this whole file is arranged to
    /// make impossible.
    nonisolated private static func run(path: String, arguments: [String]) -> Run {
        var result = Run()
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = loginPath()
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        // Kept, not discarded — and read on its OWN queue. Two pipes read one
        // after the other is a deadlock waiting for a provider that fills the
        // second buffer while we are still draining the first.
        let errors = Pipe()
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // This provider is T4A's child too, and posix_spawn inherits the same table.
        DescriptorHygiene.markCloseOnExec()
        do {
            try process.run()
        } catch {
            result.failure = error.localizedDescription
            result.status = -1
            result.duration = Date().timeIntervalSince(started)
            return result
        }
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem {
            // SIGKILL and not SIGTERM: a program that catches TERM and takes
            // its time is precisely the program a one-second bound exists for.
            kill(pid, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout,
                                                       execute: watchdog)
        // Read BEFORE waiting. A provider that prints more than a pipe buffer
        // would block forever on the write while we blocked on the wait, and
        // the timeout would be the only thing that ever ended it.
        let complaint = DispatchSemaphore(value: 0)
        let noise = FactsNoise()
        DispatchQueue.global(qos: .utility).async {
            noise.data = errors.fileHandleForReading.readDataToEndOfFile()
            complaint.signal()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        complaint.wait()
        process.waitUntilExit()
        watchdog.cancel()
        result.duration = Date().timeIntervalSince(started)
        result.timedOut = process.terminationReason == .uncaughtSignal
            || result.duration >= timeout
        result.status = process.terminationStatus
        result.output = String(decoding: data, as: UTF8.self)
        result.complaint = String(decoding: noise.data, as: UTF8.self)
            .split(separator: "\n").first
            .map { String($0.prefix(120)).trimmingCharacters(in: .whitespaces) } ?? ""
        return result
    }

    // MARK: - Back on the main thread

    private func finish(_ result: Run) {
        inFlight = false
        runs += 1
        lastExit = result.status
        lastDuration = result.duration
        lastTimedOut = result.timedOut
        if let failure = result.failure { note(failure) }
        guard !result.timedOut, result.status == 0 else {
            // The previous values stay exactly as they are. This is the case
            // the claim names: a provider that dies must cost the bar its
            // freshness, never its contents and never the app.
            //
            // And it must SAY so. A provider that has never once succeeded
            // leaves nothing on the bar and nothing to dim, so "it died" and
            // "it had nothing to say" look identical — which is exactly how a
            // provider dying at 127, every two seconds, for hours, read as an
            // empty bar with no explanation. The exit status is written down,
            // deduplicated, and 127 gets the sentence it deserves, because it
            // is not the program failing: it is the program never having run.
            let why: String
            if let failure = result.failure {
                why = failure
            } else if result.timedOut {
                why = "was still running after \(Int(Self.timeout))s and was stopped"
            } else if result.status == 127 {
                why = "exited 127 — the interpreter on its first line was not found on PATH"
            } else {
                why = "exited \(result.status)"
            }
            // The program's own last word, when it had one: an exit status
            // says that something went wrong, and this usually says what.
            let said = result.complaint.isEmpty ? "" : " · \(result.complaint)"
            lastFailure = why + said
            note("\(path) \(why)\(said)")
            miss()
            return
        }
        let reading = FactsFeed.parse(result.output)
        for problem in reading.problems { note(problem) }
        let hadFailure = lastFailure != nil
        lastFailure = nil
        misses = 0
        let wasStale = isStale
        isStale = false
        var next: [String: FactRow] = [:]
        var keys: [String] = []
        // `live: true` — questa riga il fornitore l'ha appena DETTA, e non è
        // una chiave riletta da `dash-slots` all'avvio (ISC-192).
        var tableChanged = false
        for row in reading.rows {
            next[row.key] = row
            keys.append(row.key)
            if DashCatalog.discover(row.key, label: row.label, live: true) { tableChanged = true }
        }
        // Il catalogo che cambia È un cambiamento: una riga che passa a viva
        // toglie dalle impostazioni la nativa che raddoppia, e il pannello si
        // ridisegna solo quando questo flag è vero.
        let changed = wasStale || hadFailure || keys != order || next != rows || tableChanged
        rows = next
        order = keys
        if changed { onUpdate?(tableChanged) }
    }

    private func miss() {
        inFlight = false
        misses += 1
        guard misses >= 3, !isStale else { return }
        isStale = true
        // Il catalogo non cambia quando un fornitore smette di rispondere: le
        // righe che ha nominato restano, sbiadite (ISC-143).
        onUpdate?(false)
    }

    private func note(_ message: String) {
        guard !problems.contains(message) else { return }
        problems.append(message)
        // Bounded: a provider that produces a new complaint every tick must
        // not become a memory leak with a nice name.
        if problems.count > 20 { problems.removeFirst() }
        NSLog("T4A facts: \(message)")
    }

    /// What a bench and the settings need to know about the last run.
    var diagnostics: [String: Any] {
        [
            "path": path,
            "interval": interval,
            "running": timer != nil,
            "runs": runs,
            "misses": misses,
            "stale": isStale,
            "lastExit": Int(lastExit),
            "lastTimedOut": lastTimedOut,
            "lastDurationMs": Int(lastDuration * 1000),
            "keys": order,
            "problems": problems,
            "lastFailure": lastFailure ?? "",
            // The PATH the provider was actually run with. Not the app's:
            // the whole point of ISC-143 is that those two differ when the
            // app was opened from the Finder.
            "pathEnv": Self.cachedLoginPath ?? "",
            "appPath": ProcessInfo.processInfo.environment["PATH"] ?? "",
        ]
    }
}
