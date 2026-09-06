//  SlashCommandCatalog.swift — the `/` commands an agent actually has, read
//  from the agent itself (ISC-187).
//
//  The list is never written down here. A hand-kept table is correct on the
//  day it is typed and wrong at the next `claude` release, and the failure is
//  silent: the bubble offers a command the agent no longer has, or hides one
//  it just gained, and nothing says so. So every name in here comes from a
//  file on this disk — the agent's own binary, the `.md` files it reads, the
//  plugins it has installed.
//
//  Nothing in this file names a vendor. `claude` is not a special case: it is
//  a binary that happens to carry a command table, and a binary that does not
//  carry one says `.unavailable` rather than being given an invented list.
//
//  ONE GAP, DECLARED. claude 2.1.246 also ships 43 skills inside its own
//  binary (`/simplify`, `/dataviz`, `/loop`, the `artifact-*` family) through
//  a second registration whose name is a MINIFIED VARIABLE — `l({name:Gr,
//  menuDescription:"…"})` — not a string. Measured on 2026-08-27: chasing the
//  variable back to a literal succeeds for 14 of the 43, and one of those 14
//  resolves to `▁▂▃▄▅▆▇█`, because a one-letter identifier matches the wrong
//  assignment. A reader that guessed would therefore put a block-glyph on his
//  screen as the name of a command. Those 43 are absent from this catalog and
//  the absence is pinned by a test, so the day somebody finds a real source
//  for them the pin goes red and this paragraph gets rewritten.

import Foundation

// MARK: - The contract

/// Where a command came from. The order of the cases is the order the bubble
/// lists them in.
public enum SlashCommandSource: String, Sendable, Codable {
    case builtin, user, project, plugin
}

public struct SlashCommand: Sendable, Hashable, Codable {
    /// Without the slash: "compact", "cs", "code-review:code-review".
    public let name: String
    /// "" when the source does not give one — a description behind a getter in
    /// the binary is computed at runtime and cannot be read from the bytes.
    public let description: String
    public let argumentHint: String?
    public let aliases: [String]
    public let source: SlashCommandSource
    /// Where it came from, readable: the path of the file, or "claude 2.1.246".
    public let origin: String

    public init(name: String, description: String, argumentHint: String? = nil,
                aliases: [String] = [], source: SlashCommandSource, origin: String) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.aliases = aliases
        self.source = source
        self.origin = origin
    }
}

public enum SlashCatalogState: Sendable, Equatable {
    case idle, scanning
    case ready(builtin: Int, declared: Int)
    /// The reason, e.g. "no command table in codex" or "no agent attached".
    /// A catalog that is empty because nobody asked and a catalog that is empty
    /// because the agent has no table are the same silence from outside, and
    /// only one of them is worth telling the reader about.
    case unavailable(String)
}

// MARK: - The catalog

@MainActor
public final class SlashCommandCatalog {
    public init() {}

    public private(set) var commands: [SlashCommand] = []
    public private(set) var state: SlashCatalogState = .idle
    /// Raised on the main actor whenever `commands` or `state` changed.
    public var onChange: (() -> Void)?

    /// Bumped by every `refresh` and every `clear`, so the result of a scan
    /// that was already in flight when the pane changed agent is dropped
    /// instead of overwriting the new pane's list.
    private var generation = 0

    /// Reads everything the agent declares, without blocking.
    ///
    /// The declared commands (a handful of small `.md` files) land immediately;
    /// the built-ins come from a 230 MB binary and arrive from a background
    /// task, so a bubble that opens the instant an agent attaches shows the
    /// user's own commands at once rather than an empty box for two seconds.
    public func refresh(executable: URL?, configDirectory: URL, projectDirectory: URL?) {
        generation += 1
        let token = generation
        let declared = DeclaredCommands.read(configDirectory: configDirectory,
                                             projectDirectory: projectDirectory)
        commands = Self.ordered(declared)
        guard let executable else {
            state = .unavailable("no agent attached")
            onChange?()
            return
        }
        state = .scanning
        onChange?()
        Task.detached(priority: .utility) {
            let found = BinaryCommandTable.commands(in: executable)
            await MainActor.run { [weak self] in
                guard let self, self.generation == token else { return }
                self.apply(builtin: found, declared: declared, executable: executable)
            }
        }
    }

    /// The agent is gone. An empty list is the honest answer, and `.idle` says
    /// nobody has asked yet — which is not the same as "asked and found none".
    public func clear() {
        generation += 1
        guard !commands.isEmpty || state != .idle else { return }
        commands = []
        state = .idle
        onChange?()
    }

    /// The commands the bubble should offer for what has been typed so far.
    ///
    /// `typed` is the WHOLE text of the bubble, slash included, because the
    /// list has to disappear the moment the line stops being a bare command:
    /// once a space has been typed the word is settled and what follows is an
    /// argument, not a name to complete.
    public func matches(_ typed: String) -> [SlashCommand] {
        guard typed.hasPrefix("/") else { return [] }
        let word = String(typed.dropFirst())
        guard !word.contains(" "), !word.contains("\n"), !word.contains("\t") else { return [] }
        guard !word.isEmpty else { return commands }
        let needle = word.lowercased()
        return commands.filter { command in
            if command.name.lowercased().hasPrefix(needle) { return true }
            return command.aliases.contains { $0.lowercased().hasPrefix(needle) }
        }
    }

    /// Un comando che il programma esegue da sé, anche mentre il modello sta
    /// lavorando. Il catalogo vuoto non autorizza congetture: senza una voce
    /// dichiarata, una riga che comincia con `/` resta un normale messaggio.
    public func isLocalCommand(_ text: String) -> Bool {
        Self.isLocalCommand(text, commands: commands)
    }

    /// Forma pura della regola, così il confine fra nome, alias e percorso si
    /// prova senza dover fabbricare lo stato asincrono di un catalogo.
    public nonisolated static func isLocalCommand(_ text: String,
                                                  commands: [SlashCommand]) -> Bool {
        guard !commands.isEmpty,
              let token = text.split(whereSeparator: { $0.isWhitespace }).first,
              token.hasPrefix("/") else { return false }
        let name = String(token.dropFirst())
        guard !name.isEmpty else { return false }
        return commands.contains { command in
            command.name.compare(name, options: .caseInsensitive) == .orderedSame
                || command.aliases.contains {
                    $0.compare(name, options: .caseInsensitive) == .orderedSame
                }
        }
    }

    private func apply(builtin: [SlashCommand], declared: [SlashCommand], executable: URL) {
        // Fewer than three literals is not a short table, it is the wrong kind
        // of binary: codex and gemini carry no command objects at all, and an
        // invented list for them would be the exact failure this file exists
        // to avoid.
        guard builtin.count >= 3 else {
            commands = Self.ordered(declared)
            state = .unavailable("no command table in \(BinaryCommandTable.label(for: executable))")
            onChange?()
            return
        }
        commands = Self.ordered(builtin + declared)
        state = .ready(builtin: builtin.count, declared: declared.count)
        onChange?()
    }

    private static func ordered(_ commands: [SlashCommand]) -> [SlashCommand] {
        commands.sorted { left, right in
            let l = rank(left.source), r = rank(right.source)
            if l != r { return l < r }
            return left.name.lowercased() < right.name.lowercased()
        }
    }

    private static func rank(_ source: SlashCommandSource) -> Int {
        switch source {
        case .builtin: return 0
        case .user: return 1
        case .project: return 2
        case .plugin: return 3
        }
    }
}

// MARK: - The binary

/// The command objects a bundled JS agent carries in its own bytes.
///
/// Every built-in is a JavaScript object literal that survived bundling with
/// its field names intact, e.g.
/// `{type:"local",name:"compact",description:"Free up context…",argumentHint:"…"}`
/// so the table can be read without running the agent and without asking it
/// anything — `--help` does not list these.
enum BinaryCommandTable {
    /// The one anchor. Everything else is found relative to it, because `type`
    /// is what makes an object a COMMAND: `name:"…"` alone matches 1712 places
    /// in claude 2.1.246 and 144 of them are commands.
    private static let anchor = Array("type:\"local".utf8)

    /// Read in 8 MB pieces with slack either side rather than mapped or slurped
    /// whole: a 230 MB `Data` held for the length of a scan is 230 MB this app
    /// does not need, and a mapping is a SIGBUS the day the file is replaced
    /// under us. The slack is what lets an object that straddles a piece
    /// boundary still be read in one go — the largest one measured is 1529
    /// bytes, against 16 KB of slack.
    private static let piece = 8 << 20
    private static let slack = 16 << 10
    /// Field scanning never runs past this from the opening brace. Generous
    /// against the real maximum, and it is what stops a missing `}` from
    /// walking the scanner through the rest of the file.
    private static let objectCeiling = 8192

    /// The built-ins in `executable`, empty when it carries no table.
    ///
    /// Cached twice: in memory for the life of the process, and on disk under
    /// `$XDG_CACHE_HOME/t4a`, both keyed by (path, size, mtime) so a new
    /// version of the agent is a new key and scans once. The second opening of
    /// the app therefore does not scan at all.
    static func commands(in executable: URL) -> [SlashCommand] {
        guard let key = cacheKey(for: executable) else { return [] }
        if let remembered = ScanMemo.shared.value(for: key) { return remembered }
        if let onDisk = DiskCache.read(key: key) {
            ScanMemo.shared.set(onDisk, for: key)
            return onDisk
        }
        let found = scan(executable)
        ScanMemo.shared.set(found, for: key)
        DiskCache.write(found, key: key)
        return found
    }

    /// How the binary should be named to a reader.
    ///
    /// The file itself is usually called after its version (`…/claude/versions/2.1.246`),
    /// which alone tells nobody what it is, so the nearest ancestor that is not
    /// plumbing gets put in front of it.
    static func label(for executable: URL) -> String {
        let parts = executable.pathComponents.filter { $0 != "/" }
        guard let last = parts.last else { return executable.path }
        guard isVersionLike(last) else { return last }
        let plumbing: Set<String> = ["versions", "bin", "sbin", "libexec", "Contents",
                                     "MacOS", "Resources", "node_modules", ".bin"]
        for part in parts.dropLast().reversed()
        where !plumbing.contains(part) && !isVersionLike(part) {
            return "\(part) \(last)"
        }
        return last
    }

    private static func isVersionLike(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        return first.properties.numericType != nil
    }

    private static func cacheKey(for executable: URL) -> String? {
        let values = try? executable.resourceValues(forKeys: [.fileSizeKey,
                                                              .contentModificationDateKey])
        guard let size = values?.fileSize,
              let modified = values?.contentModificationDate else { return nil }
        return "\(executable.path)|\(size)|\(modified.timeIntervalSince1970)"
    }

    // MARK: The scan itself

    private static func scan(_ executable: URL) -> [SlashCommand] {
        guard let handle = try? FileHandle(forReadingFrom: executable),
              let size = (try? executable.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else { return [] }
        defer { try? handle.close() }
        let origin = label(for: executable)

        // Merged by name, in the order the binary declares them: the same
        // command is usually declared TWICE, once `local` and once
        // `local-jsx`, and the two differ only in which of them computes its
        // description at runtime. First one wins, and only an empty
        // description is ever replaced.
        var order: [String] = []
        var byName: [String: SlashCommand] = [:]

        var start = 0
        while start < size {
            let from = max(0, start - slack)
            let to = min(size, start + piece + slack)
            try? handle.seek(toOffset: UInt64(from))
            guard let bytes = try? handle.read(upToCount: to - from), !bytes.isEmpty
            else { break }
            let window = start ..< min(start + piece, size)

            for local in anchors(in: bytes) {
                guard window.contains(from + local) else { continue }
                guard let object = objectSlice(bytes, around: local),
                      let parsed = command(from: object, origin: origin) else { continue }
                if let existing = byName[parsed.name] {
                    guard existing.description.isEmpty, !parsed.description.isEmpty else { continue }
                    byName[parsed.name] = SlashCommand(
                        name: parsed.name,
                        description: parsed.description,
                        argumentHint: existing.argumentHint ?? parsed.argumentHint,
                        aliases: existing.aliases.isEmpty ? parsed.aliases : existing.aliases,
                        source: .builtin, origin: origin)
                } else {
                    order.append(parsed.name)
                    byName[parsed.name] = parsed
                }
            }
            start += piece
        }
        return order.compactMap { byName[$0] }
    }

    /// Offsets of the anchor inside one piece. `memmem` rather than a Swift
    /// loop because this runs in debug builds too — a hand-rolled byte scan
    /// over 230 MB is fast when optimised and is not when it is not.
    private static func anchors(in bytes: Data) -> [Int] {
        var found: [Int] = []
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            anchor.withUnsafeBytes { needle in
                var cursor = 0
                while cursor + anchor.count <= raw.count {
                    guard let hit = memmem(base + cursor, raw.count - cursor,
                                           needle.baseAddress, anchor.count) else { return }
                    let offset = UnsafeRawPointer(hit) - base
                    // `type:"local_agent"` and friends are a different kind of
                    // object in the same bundle; only the two command types
                    // count.
                    let after = offset + anchor.count
                    if after < raw.count {
                        let next = raw[after]
                        if next == UInt8(ascii: "\"")
                            || (next == UInt8(ascii: "-") && matches(raw, at: after, "-jsx\"")) {
                            found.append(offset)
                        }
                    }
                    cursor = offset + 1
                }
            }
        }
        return found
    }

    private static func matches(_ raw: UnsafeRawBufferPointer, at offset: Int,
                                _ text: String) -> Bool {
        let wanted = Array(text.utf8)
        guard offset + wanted.count <= raw.count else { return false }
        for (index, byte) in wanted.enumerated() where raw[offset + index] != byte { return false }
        return true
    }

    /// One frame of the little JS reader below: a stretch of code with its own
    /// brace count, or the text of a template literal.
    private struct Frame {
        var isTemplate: Bool
        var depth: Int
    }

    /// The object literal the anchor sits inside, as bytes.
    ///
    /// Back to its opening brace, then forward with a brace counter that reads
    /// enough JavaScript not to be fooled. Three things in these objects break
    /// a simpler count, and all three are in claude 2.1.246 today:
    ///
    /// - a brace inside a plain string would end the object early;
    /// - a template literal nests (`` `a ${b ? `c` : `d`} e` ``), so treating
    ///   every backtick as opening or closing a string gets the reader out of
    ///   step by one;
    /// - once out of step, the apostrophe in `the user's view` inside
    ///   `/brief`'s template opens a string that never closes, and that whole
    ///   command disappears without a sound. Measured: 88 commands read with
    ///   the naive reader, 89 with this one.
    ///
    /// A fixed byte window either side of the name would fail differently and
    /// just as quietly: the commands sit shoulder to shoulder in the bundle,
    /// and `name:"model"` has `description:"Export the current conversation…"`
    /// 300 bytes behind it.
    private static func objectSlice(_ bytes: Data, around anchor: Int) -> Data? {
        var open = anchor
        let floor = max(0, anchor - 400)
        while open > floor, bytes[bytes.startIndex + open] != UInt8(ascii: "{") { open -= 1 }
        guard bytes[bytes.startIndex + open] == UInt8(ascii: "{") else { return nil }

        let quote = UInt8(ascii: "\""), apostrophe = UInt8(ascii: "'"), backtick = UInt8(ascii: "`")
        let escape = UInt8(ascii: "\\"), dollar = UInt8(ascii: "$")
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")

        var stack = [Frame(isTemplate: false, depth: 0)]
        var index = open
        let ceiling = min(bytes.count, open + objectCeiling)
        func byte(_ at: Int) -> UInt8 { bytes[bytes.startIndex + at] }

        while index < ceiling {
            let current = byte(index)
            if stack[stack.count - 1].isTemplate {
                if current == escape { index += 2; continue }
                if current == backtick { stack.removeLast(); index += 1; continue }
                if current == dollar, index + 1 < ceiling, byte(index + 1) == openBrace {
                    // Inside `${…}` it is code again, and its opening brace is
                    // already counted.
                    stack.append(Frame(isTemplate: false, depth: 1))
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if current == quote || current == apostrophe {
                index += 1
                while index < ceiling {
                    if byte(index) == escape { index += 2; continue }
                    if byte(index) == current { break }
                    index += 1
                }
                index += 1
                continue
            }
            if current == backtick {
                stack.append(Frame(isTemplate: true, depth: 0))
                index += 1
                continue
            }
            if current == openBrace {
                stack[stack.count - 1].depth += 1
            } else if current == closeBrace {
                stack[stack.count - 1].depth -= 1
                if stack[stack.count - 1].depth == 0 {
                    if stack.count == 1 {
                        return bytes.subdata(in: (bytes.startIndex + open)
                                             ..< (bytes.startIndex + index + 1))
                    }
                    stack.removeLast()
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: One object

    private static func command(from object: Data, origin: String) -> SlashCommand? {
        guard let name = string(named: "name", in: object), !name.isEmpty else { return nil }
        guard !name.hasPrefix("__"), !name.contains(" ") else { return nil }
        // Only the LITERAL gates are read. `isEnabled:()=>!1` and
        // `isHidden:!0` are decisions already taken at build time; anything
        // behind a function is a decision taken at run time with state this
        // process does not have, and guessing at it would drop commands that
        // are in fact available. The cost of not guessing is stated in the
        // doc comment of `refresh`'s caller: a command may be listed that this
        // particular session cannot run.
        guard !contains(object, "isHidden:!0"), !contains(object, "isEnabled:()=>!1")
        else { return nil }
        return SlashCommand(name: name,
                            description: string(named: "description", in: object) ?? "",
                            argumentHint: string(named: "argumentHint", in: object),
                            aliases: aliases(in: object),
                            source: .builtin, origin: origin)
    }

    private static func contains(_ object: Data, _ text: String) -> Bool {
        object.range(of: Data(text.utf8)) != nil
    }

    /// The value of `key:"…"`, unescaped. Nil when the field is absent or is a
    /// getter (`get description(){…}`), which is the same answer to the only
    /// question that matters here: there is no literal to read.
    private static func string(named key: String, in object: Data) -> String? {
        guard let range = object.range(of: Data("\(key):\"".utf8)) else { return nil }
        var index = range.upperBound
        var raw: [UInt8] = []
        while index < object.endIndex {
            let byte = object[index]
            if byte == UInt8(ascii: "\\") {
                raw.append(byte)
                index = object.index(after: index)
                if index < object.endIndex { raw.append(object[index]); index = object.index(after: index) }
                continue
            }
            if byte == UInt8(ascii: "\"") { break }
            raw.append(byte)
            index = object.index(after: index)
        }
        return unescapeJS(String(decoding: raw, as: UTF8.self))
    }

    private static func aliases(in object: Data) -> [String] {
        guard let range = object.range(of: Data("aliases:[".utf8)) else { return [] }
        var index = range.upperBound
        var out: [String] = []
        var current: [UInt8]?
        while index < object.endIndex {
            let byte = object[index]
            if byte == UInt8(ascii: "]") { break }
            if byte == UInt8(ascii: "\"") {
                if let done = current { out.append(String(decoding: done, as: UTF8.self)); current = nil }
                else { current = [] }
            } else if current != nil {
                current?.append(byte)
            }
            index = object.index(after: index)
        }
        return out
    }

    /// The escapes a bundler actually emits into these literals. `…` is in
    /// claude 2.1.246's own `argumentHint` for `/auto-mode-setup`, so leaving
    /// them raw would put backslashes on his screen.
    static func unescapeJS(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\", index + 1 < scalars.count else {
                out.unicodeScalars.append(scalars[index]); index += 1; continue
            }
            let next = scalars[index + 1]
            switch next {
            case "n": out += "\n"; index += 2
            case "t": out += "\t"; index += 2
            case "r": out += "\r"; index += 2
            case "u":
                let digits = scalars[(index + 2)...].prefix(4)
                if digits.count == 4, let value = UInt32(String(String.UnicodeScalarView(digits)),
                                                         radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                    index += 6
                } else {
                    out += "\\u"; index += 2
                }
            default:
                out.unicodeScalars.append(next); index += 2
            }
        }
        return out
    }
}

/// One scan per (path, size, mtime) for the life of the process. Not on the
/// main actor because the scan is not, and locked rather than actor-isolated
/// because the reader is a synchronous background function.
private final class ScanMemo: @unchecked Sendable {
    static let shared = ScanMemo()
    private let lock = NSLock()
    private var entries: [String: [SlashCommand]] = [:]

    func value(for key: String) -> [SlashCommand]? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    func set(_ commands: [SlashCommand], for key: String) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = commands
    }
}

/// The same result, across launches.
///
/// The file carries the key it was written for and is refused when it does not
/// match, so a hash collision or a hand-edited cache produces a fresh scan
/// rather than the wrong agent's commands.
private enum DiskCache {
    private struct Payload: Codable { let key: String; let commands: [SlashCommand] }

    static func directory() -> URL {
        let root = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map {
            URL(fileURLWithPath: $0)
        } ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache")
        return root.appendingPathComponent("t4a", isDirectory: true)
    }

    static func file(for key: String) -> URL {
        directory().appendingPathComponent("slash-\(fnv1a(key)).json")
    }

    static func read(key: String) -> [SlashCommand]? {
        guard let data = try? Data(contentsOf: file(for: key)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.key == key else { return nil }
        return payload.commands
    }

    static func write(_ commands: [SlashCommand], key: String) {
        guard !commands.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Payload(key: key, commands: commands))
        else { return }
        try? data.write(to: file(for: key), options: .atomic)
    }

    /// A hash that is the same in every process. `Hashable.hashValue` is seeded
    /// per launch, so a cache keyed on it would never be found again.
    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - The files on disk

/// The commands an agent reads from disk rather than carries: the principal's
/// own `.md` commands, the skills, the same two inside a project, and the
/// plugins.
enum DeclaredCommands {
    static func read(configDirectory: URL, projectDirectory: URL?) -> [SlashCommand] {
        var out: [SlashCommand] = []
        out += commands(in: configDirectory.appendingPathComponent("commands"), source: .user)
        out += skills(in: configDirectory.appendingPathComponent("skills"), source: .user)
        if let project = projectDirectory {
            let dot = project.appendingPathComponent(".claude")
            out += commands(in: dot.appendingPathComponent("commands"), source: .project)
            out += skills(in: dot.appendingPathComponent("skills"), source: .project)
        }
        out += plugins(configDirectory: configDirectory, projectDirectory: projectDirectory)
        // Two plugin entries can point at one installPath (the same plugin
        // installed for the user AND for a project), and one command read
        // twice is one command.
        var seen = Set<String>()
        return out.filter { seen.insert($0.name).inserted }
    }

    /// `<dir>/*.md`, one level deep only.
    ///
    /// A command in a SUBDIRECTORY is not listed. Claude namespaces those, and
    /// which separator it uses could not be verified here — there is no nested
    /// command on this disk to read the answer off. A missing name is a gap
    /// somebody notices; an invented one is a command that does not run.
    static func commands(in directory: URL, source: SlashCommandSource) -> [SlashCommand] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return entries.filter { $0.pathExtension == "md" }.compactMap { url in
            let front = Frontmatter.read(url)
            // The FILE NAME is the command, not the `name:` field: it is what
            // the agent resolves, and the two can disagree.
            return SlashCommand(name: url.deletingPathExtension().lastPathComponent,
                                description: front["description"] ?? "",
                                argumentHint: front["argument-hint"],
                                source: source, origin: url.path)
        }
    }

    /// `<dir>/<name>/SKILL.md`, invocable as `/<name>`.
    static func skills(in directory: URL, source: SlashCommandSource) -> [SlashCommand] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return entries.compactMap { url in
            let manifest = url.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            let front = Frontmatter.read(manifest)
            // Off the menu on purpose: a skill the model may call but a person
            // may not type.
            if front["user-invocable"]?.lowercased() == "false" { return nil }
            return SlashCommand(name: url.lastPathComponent,
                                description: front["description"] ?? "",
                                source: source, origin: manifest.path)
        }
    }

    /// Every installed plugin that applies here, as `/<plugin>:<command>`.
    ///
    /// `scope: user` applies everywhere; `scope: project` only inside the tree
    /// its `projectPath` names — a plugin installed for another project is not
    /// this pane's.
    static func plugins(configDirectory: URL, projectDirectory: URL?) -> [SlashCommand] {
        let manifest = configDirectory.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: manifest),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        var out: [SlashCommand] = []
        for (key, value) in plugins.sorted(by: { $0.key < $1.key }) {
            let plugin = key.split(separator: "@").first.map(String.init) ?? key
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                guard let path = entry["installPath"] as? String else { continue }
                let scope = entry["scope"] as? String ?? ""
                if scope == "project" {
                    guard let projectPath = entry["projectPath"] as? String,
                          let project = projectDirectory,
                          project.path == projectPath || project.path.hasPrefix(projectPath + "/")
                    else { continue }
                } else if scope != "user" { continue }
                let root = URL(fileURLWithPath: path)
                for command in commands(in: root.appendingPathComponent("commands"), source: .plugin) {
                    out.append(renamed(command, to: "\(plugin):\(command.name)"))
                }
                for skill in skills(in: root.appendingPathComponent("skills"), source: .plugin) {
                    out.append(renamed(skill, to: "\(plugin):\(skill.name)"))
                }
            }
        }
        return out
    }

    private static func renamed(_ command: SlashCommand, to name: String) -> SlashCommand {
        SlashCommand(name: name, description: command.description,
                     argumentHint: command.argumentHint, aliases: command.aliases,
                     source: .plugin, origin: command.origin)
    }
}

/// The `key: value` lines between the two `---` fences. Deliberately not a YAML
/// parser: these files carry flat scalars, and the first 8 KB is more than any
/// frontmatter seen — a SKILL.md body can be tens of kilobytes and none of it
/// is read.
enum Frontmatter {
    static func read(_ url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8192) else { return [:] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> [String: String] {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines.removeFirst()
        var out: [String: String] = [:]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex ..< colon]).trimmingCharacters(in: .whitespaces)
            // An indented line belongs to the value above it, not to a key of
            // its own.
            guard !key.isEmpty, !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            for quote in ["\"", "'"] where value.count >= 2
                && value.hasPrefix(quote) && value.hasSuffix(quote) {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\(quote)", with: quote)
                    .replacingOccurrences(of: "\\\\", with: "\\")
                break
            }
            out[key] = value
        }
        return out
    }
}
