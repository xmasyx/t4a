//  Updater.swift — the explicit-click boundary for release checks and Homebrew installation.
//
//  Every decision comes from TerminalCore/Updates.swift. This file alone talks to GitHub,
//  Homebrew and AppKit, and constructing it performs no work: only checkNow() starts a check
//  (ISC-248).

import AppKit
import Foundation
import TerminalCore

private enum UpdaterText {
    static let preparing = "Preparing update…"
    static let brewMissing = "Homebrew was not found. Opening the release page instead."
    static let processFailed = "Homebrew could not install the update."
    static let invalidURL = "The update URL is invalid."
    static let badResponse = "The update server returned an invalid response."
    static let releaseWithoutTag = "The latest release has no version tag."
    static let releasePageFailed = "The release page could not be opened."
    static let relaunchFailed = "The updated app could not be relaunched."
}

/// Executes update I/O and reports every state change through one AppKit-friendly callback.
@MainActor
final class Updater {
    enum State {
        case idle
        case checking
        case upToDate(current: String)
        case available(version: String, action: Updates.Action)
        case upgrading(line: String)
        case failed(message: String)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// Called on the main actor whenever `state` changes.
    var onStateChange: ((State) -> Void)?

    private let environment: [String: String]
    private var releasePage: URL?
    private var acceptsProcessLines = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    /// Changes state immediately; the ten-second HTTP request then continues off the UI path.
    func checkNow() {
        guard !isBusy else { return }
        state = .checking
        Task { await check() }
    }

    /// Performs the action supplied with an available update.
    func perform(_ action: Updates.Action) {
        guard !isBusy else { return }
        switch action {
        case .openReleasePage(let url):
            open(url)
        case .upgradeAndRelaunch(let arguments):
            guard let brew = brewURL() else {
                reportFailure(UpdaterText.brewMissing)
                if let releasePage { open(releasePage) }
                return
            }
            state = .upgrading(line: UpdaterText.preparing)
            Task { await upgrade(with: brew, arguments: arguments) }
        }
    }

    private var isBusy: Bool {
        switch state {
        case .checking, .upgrading: return true
        default: return false
        }
    }

    private func check() async {
        do {
            let data = try await releaseData()
            guard let tag = Updates.latestTag(fromReleaseJSON: data) else {
                throw UpdateError.releaseWithoutTag
            }

            guard let version = Updates.newerVersion(
                current: AppVersion.short,
                latestTag: tag
            ) else {
                state = .upToDate(current: AppVersion.short)
                return
            }

            let roots = environment["T4A_CASKROOM"].map { [$0] }
                ?? ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
            let source = Updates.source(
                bundlePath: Bundle.main.bundlePath,
                caskroomRoots: roots,
                homeDirectory: NSHomeDirectory(),
                fileExists: FileManager.default.fileExists(atPath:)
            )
            let action = Updates.action(for: source, version: version)
            switch Updates.action(for: .manual, version: version) {
            case .openReleasePage(let url):
                releasePage = url
            case .upgradeAndRelaunch:
                // The manual-source action is defined to be a release page; clear stale fallback
                // state if that contract changes instead of retaining a URL for another version.
                releasePage = nil
            }
            state = .available(version: version, action: action)
        } catch {
            reportFailure(error.localizedDescription)
        }
    }

    private func releaseData() async throws -> Data {
        let rawURL = environment["T4A_UPDATES_API"]
            ?? "https://api.github.com/repos/\(Updates.repo)/releases/latest"
        guard let url = URL(string: rawURL) else { throw UpdateError.invalidURL }

        // URLSession does not load file URLs. This verification seam reads a local fixture on a
        // utility task; local filesystem I/O is deliberately unbounded and propagates its error.
        if url.isFileURL {
            return try await Task.detached(priority: .utility) {
                try Data(contentsOf: url)
            }.value
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("T4A/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse
        }
        return data
    }

    private func brewURL() -> URL? {
        let candidates: [String]
        if let selected = environment["T4A_BREW"] {
            candidates = [selected]
        } else {
            candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:))
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func processEnvironment(autoUpdate: Bool) -> [String: String] {
        var result = environment
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        result["HOME"] = NSHomeDirectory()
        result["HOMEBREW_NO_ENV_HINTS"] = "1"
        result["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        if autoUpdate {
            result.removeValue(forKey: "HOMEBREW_NO_AUTO_UPDATE")
        } else {
            result["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return result
    }

    private func upgrade(with brew: URL, arguments: [String]) async {
        let fastEnvironment = processEnvironment(autoUpdate: false)
        let repository = await ProcessRunner.run(
            executable: brew,
            arguments: ["--repository", Updates.tap],
            environment: fastEnvironment
        )

        var tapIsFresh = false
        if repository.status == 0, let path = repository.lines.last, !path.isEmpty {
            let pull = await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", path, "pull", "--ff-only", "-q"],
                environment: fastEnvironment
            )
            tapIsFresh = pull.status == 0
        }

        acceptsProcessLines = true
        // Homebrew is deliberately unbounded: interrupting a package manager midway through an
        // installation risks leaving its managed app and metadata in different states.
        let result = await ProcessRunner.run(
            executable: brew,
            arguments: arguments,
            environment: processEnvironment(autoUpdate: !tapIsFresh)
        ) { [weak self] line in
            Task { @MainActor in
                guard let self, self.acceptsProcessLines else { return }
                self.state = .upgrading(line: line)
            }
        }
        acceptsProcessLines = false

        guard result.status == 0 else {
            let reason = result.lines.suffix(2).joined(separator: " · ")
            reportFailure(reason.isEmpty ? UpdaterText.processFailed : reason)
            return
        }

        await clearQuarantine()
        do {
            try scheduleRelaunch()
        } catch {
            reportFailure("\(UpdaterText.relaunchFailed) \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Clears quarantine only from the bundle Homebrew just replaced (ISC-248).
    ///
    /// This helper process is allowed to finish naturally. A failure is logged but deliberately
    /// does not block relaunch, because the installation itself has already succeeded.
    private func clearQuarantine() async {
        let result = await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", Bundle.main.bundlePath],
            environment: processEnvironment(autoUpdate: false)
        )
        if result.status != 0 {
            let reason = result.lines.last ?? "unknown error"
            NSLog("T4A: update quarantine cleanup failed: %@", reason)
        }
    }

    private func scheduleRelaunch() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -a \"\(path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func open(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            reportFailure(UpdaterText.releasePageFailed)
            return
        }
    }

    private func reportFailure(_ message: String) {
        state = .failed(message: message)
        NSLog("T4A: update failed: %@", message)
    }
}

private enum UpdateError: LocalizedError {
    case invalidURL
    case badResponse
    case releaseWithoutTag

    var errorDescription: String? {
        switch self {
        case .invalidURL: return UpdaterText.invalidURL
        case .badResponse: return UpdaterText.badResponse
        case .releaseWithoutTag: return UpdaterText.releaseWithoutTag
        }
    }
}

private enum ProcessRunner {
    struct Result {
        let status: Int32?
        let lines: [String]
    }

    /// Child-process waits have no timeout. Homebrew must never be killed midway through an
    /// installation; the short repository and quarantine helpers use the same runner and await
    /// their natural exit so process ownership and output handling stay in one place.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        line: (@Sendable (String) -> Void)? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let output = ProcessOutput()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                output.append(data).forEach { line?($0) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile()).forEach { line?($0) }
                continuation.resume(returning: Result(
                    status: finished.terminationStatus,
                    lines: output.finish()
                ))
            }

            do {
                try process.run()
                // The parent's write descriptor must close after launch. Otherwise the reader
                // waits forever for an EOF that the parent itself still holds.
                pipe.fileHandleForWriting.closeFile()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                pipe.fileHandleForWriting.closeFile()
                continuation.resume(returning: Result(
                    status: nil,
                    lines: [error.localizedDescription]
                ))
            }
        }
    }
}

/// FileHandle callbacks arrive on different queues; the lock preserves byte order and bounds the
/// retained output to two lines. The synchronization is why unchecked sendability is sound here.
private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var latest: [String] = []

    func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var complete: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            let bytes = pending[..<newline]
            pending.removeSubrange(...newline)
            let text = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            complete.append(text)
            latest.append(text)
            latest = Array(latest.suffix(2))
        }
        return complete
    }

    func finish() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: pending, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            latest.append(text)
            latest = Array(latest.suffix(2))
        }
        pending.removeAll()
        return latest
    }
}
