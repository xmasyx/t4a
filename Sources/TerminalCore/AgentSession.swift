//  AgentSession.swift — what an agent session looks like from the outside.
//
//  This is the contract F4 turns on, and the reason it lives here rather than
//  in the app: the core knows that SOME programs running in a pane have turns,
//  tools and a state, and knows nothing at all about Claude Code or Codex.
//  Each adapter reads its own vendor's files and fills these structures; the
//  rail, the inspector, the card and the composer are written against the
//  structures and never against a vendor (ISC-31).
//
//  Read-only, permanently. Nothing in this file or in any adapter writes a
//  byte into an agent's data directory: the only thing T4A ever sends towards
//  an agent is a keystroke down the pty, which is input, not a file.

import Foundation

/// What a session is doing, in the three words the rail uses.
public enum AgentActivity: String, Sendable, CaseIterable {
    /// The agent is thinking or running a tool. Nothing is wanted from you.
    case working
    /// It has stopped and the next move is yours — it finished its turn, or
    /// it is holding a permission prompt open.
    case waiting
    /// No agent, or the agent is gone.
    case idle
}

/// One tool call inside a turn.
public struct AgentToolUse: Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The one line worth showing: the command, the path, the pattern. Built
    /// by the adapter, because only the adapter knows its vendor's shapes.
    public var summary: String
    public var isError: Bool
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: String, name: String, summary: String, isError: Bool = false,
                startedAt: Date, finishedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isError = isError
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

/// One step of the WORK inside a turn: a thought, a note on the way to the
/// answer, or a tool call.
///
/// Why the work is a list and not three fields: what you want to read is the
/// order it happened in. "It thought, then read two files, then said this" is
/// a story; three buckets are an inventory of the same facts with the plot
/// removed. Every step carries a title short enough for one line and a detail
/// long enough to be worth opening, so a reader can show the first and hide
/// the second without asking anyone what is inside.
public struct AgentStep: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The model's own reasoning.
        case thinking
        /// Text it wrote on the way to the answer, not the answer itself.
        case note
        /// A tool call: the command, the file, the search.
        case tool
    }

    public var id: String
    public var kind: Kind
    /// The one line the reader shows while the step is closed.
    public var title: String
    /// Everything the step contains, shown when it is opened.
    public var detail: String
    public var isError: Bool
    /// The file this step WROTE, as an absolute path, or nil (ISC-175).
    ///
    /// Only a step that created or changed a file carries one. Which of a
    /// vendor's tools count as writing is the adapter's business — the core
    /// names no vendor and no tool, exactly as it names none anywhere else.
    ///
    /// Absolute, always. The adapter resolves it against the session's own
    /// working directory before it gets here: a relative path only means
    /// something beside the directory it was relative to, and by the time a
    /// view wants to open it that directory is somebody else's fact.
    public var filePath: String?

    public init(id: String, kind: Kind, title: String, detail: String,
                isError: Bool = false, filePath: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isError = isError
        self.filePath = filePath
    }

    /// The name a person reads for the file, which is what the link says.
    public var fileName: String? {
        filePath.map { ($0 as NSString).lastPathComponent }
    }

    /// How big the step is, said the way a person counts: lines when there are
    /// several, characters when it is one. Goes in the closed line, because
    /// "how much is in here" is half of deciding whether to open it.
    public var size: String {
        guard !detail.isEmpty else { return "" }
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines > 1 { return "\(lines) righe" }
        return "\(detail.count) caratteri"
    }
}

/// One more answer inside the SAME turn. A Stop hook can send the model back
/// to work after it said it was done, but the person is still reading one
/// question and one story rather than starting another exchange.
public struct AgentFollowUp: Sendable, Equatable {
    /// The hook's short name, or empty when its message did not name one.
    public var source: String
    /// Why the hook refused to let the answer stand.
    public var reason: String
    /// What the model said after doing the extra work; empty until it speaks.
    public var answer: String
    /// When the hook sent the model back, not when the later answer arrived.
    public var at: Date

    public init(source: String, reason: String, answer: String = "", at: Date) {
        self.source = source
        self.reason = reason
        self.answer = answer
        self.at = at
    }
}

/// One turn: what you asked, what it did, what it answered.
///
/// The rows are how a turn is tied back to the terminal it was drawn in. They
/// are filled by the app from the shell's own marks, not by the adapter — a
/// transcript knows what happened and has no idea where on the screen it went.
public struct AgentTurn: Sendable, Identifiable {
    public var id: Int
    public var prompt: String
    public var answer: String
    public var tools: [AgentToolUse]
    public var startedAt: Date
    public var finishedAt: Date?
    /// True when any tool in the turn came back an error.
    public var failed: Bool
    /// The work, in the order it happened: thoughts, notes, tool calls. The
    /// answer is NOT in here — it is the one thing a reader always shows.
    public var steps: [AgentStep]
    /// Scroll-invariant row where the turn's prompt was typed.
    public var promptRow: Int?
    /// Scroll-invariant rows the turn's WORK occupies — everything between the
    /// question and the answer. This is the range the compact view folds
    /// (ISC-94), and it is never allowed to cover the live screen.
    public var workRows: ClosedRange<Int>?
    /// Il turno è un comando locale (`/model`, `/clear`, una skill), non una
    /// frase detta all'agente. Chi mostra i turni lo usa per non prenderne il
    /// nome della sessione e per vestirlo più quieto: è un gesto tuo
    /// sull'attrezzo, non una domanda.
    public var isLocalCommand = false
    /// Usually empty: Stop hooks are the exceptional path where one question
    /// legitimately receives another answer before the next human message.
    public var followUps: [AgentFollowUp]

    public init(id: Int, prompt: String = "", answer: String = "",
                tools: [AgentToolUse] = [], steps: [AgentStep] = [],
                startedAt: Date,
                finishedAt: Date? = nil, failed: Bool = false,
                promptRow: Int? = nil, workRows: ClosedRange<Int>? = nil,
                followUps: [AgentFollowUp] = []) {
        self.id = id
        self.prompt = prompt
        self.answer = answer
        self.tools = tools
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.failed = failed
        self.promptRow = promptRow
        self.workRows = workRows
        self.followUps = followUps
    }

    public var isOpen: Bool { finishedAt == nil }

    public var duration: TimeInterval? {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// The turn in one line, for a list that has one line per turn.
    public var headline: String {
        let text = prompt.isEmpty ? answer : prompt
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? "(turn \(id))" : flattened
    }
}

/// One answer a permission prompt is offering, and the keys that pick it.
public struct AgentApprovalOption: Sendable {
    public var label: String
    /// Exactly what goes down the pty. A digit and a Return for a numbered
    /// list; an escape for a prompt that answers "no" that way.
    public var keystrokes: String
    /// True for the option that means "yes, go ahead".
    public var isApproval: Bool

    public init(label: String, keystrokes: String, isApproval: Bool) {
        self.label = label
        self.keystrokes = keystrokes
        self.isApproval = isApproval
    }
}

/// A permission the agent is holding the screen open for.
///
/// It is read off the LIVE GRID rather than out of a transcript, and that is a
/// finding, not a shortcut: measured across the whole transcript estate on
/// 2026-08-20, a pending permission has no record of any kind — the tool_use
/// is written, and nothing else appears until the question has been answered.
/// The only place a waiting permission exists is on the screen, which is
/// exactly the thing a terminal already has and a wrapper does not.
public struct AgentApproval: Sendable, Equatable {
    /// What kind of thing is being asked for: "Bash command", "Edit file".
    public var title: String
    /// The body of the box, line by line — the command, the diff, the path.
    public var detail: [String]
    public var options: [AgentApprovalOption]
    /// Scroll-invariant row where the box begins, so the card can sit with it.
    public var firstRow: Int

    public init(title: String, detail: [String], options: [AgentApprovalOption],
                firstRow: Int) {
        self.title = title
        self.detail = detail
        self.options = options
        self.firstRow = firstRow
    }

    public static func == (lhs: AgentApproval, rhs: AgentApproval) -> Bool {
        lhs.title == rhs.title && lhs.detail == rhs.detail
            && lhs.firstRow == rhs.firstRow
            && lhs.options.map(\.label) == rhs.options.map(\.label)
    }

    /// The same question, for the purpose of ANSWERING it (ISC-127).
    ///
    /// Narrower than `==` on purpose, and in both directions. Where the box
    /// sits is not part of it: a question that scrolled by a row is the same
    /// question, and refusing to answer it would be a card that stops working
    /// whenever the agent repaints. The keystrokes ARE part of it, because the
    /// digit is the thing that gets typed — a redraw that renumbered the
    /// options would leave the button's label right and its key wrong.
    public func asksTheSameAs(_ other: AgentApproval) -> Bool {
        title == other.title
            && options.map(\.label) == other.options.map(\.label)
            && options.map(\.keystrokes) == other.options.map(\.keystrokes)
    }
}

/// A vendor's reader. One instance per attached pane.
///
/// Everything an adapter needs is here: how to know its own program, where its
/// files live, how to fold a line of one into turns, and how to recognise its
/// own permission prompt on screen. A second vendor is a second file that
/// conforms to this and a line in the registry — nothing in the app moves.
@MainActor
public protocol AgentAdapter: AnyObject {
    /// A short stable name: `claude-code`, `codex`.
    static var identifier: String { get }

    /// Does this adapter own the program now in front of the shell?
    /// `process` is the kernel's name for it, `commandLine` what was typed.
    static func recognises(process: String, commandLine: String) -> Bool

    /// The directories where this vendor writes session files for a pane
    /// working in `cwd`. Watched, never written to.
    static func transcriptDirectories(home: URL, cwd: URL) -> [URL]

    /// The transcripts this vendor's OWN records attribute to a live process,
    /// for a vendor that does not keep its transcript open. Files that may not
    /// exist yet: the caller checks. Empty when the vendor has no such record.
    static func transcripts(attributedTo pid: Int32, home: URL, cwd: URL,
                            processStart: Date?) -> [URL]

    /// Is this file a session of a pane working in `cwd`? Answered by reading
    /// the file, so a transcript belonging to another window is never adopted.
    static func file(_ url: URL, belongsTo cwd: URL) -> Bool

    init()

    /// Fold complete lines, in order, into the model. Called with everything
    /// that has been appended since the last call.
    func ingest(lines: [String])

    /// Forget everything: a different file is about to be read.
    func rewind()

    var turns: [AgentTurn] { get }
    var activity: AgentActivity { get }

    /// The timestamp of the newest record this adapter has parsed, as the
    /// AGENT wrote it.
    ///
    /// It is what makes a latency claim measurable end to end: the distance
    /// between this and the moment T4A finished reading is the whole delay —
    /// the agent's write, the kernel's notification, the read and the parse —
    /// with no clock of ours in the middle and no polling loop outside to
    /// blur it (ISC-25, ISC-27).
    var latestRecordAt: Date? { get }
    /// The model the session is running on, when the file says so. Empty
    /// rather than a guess — the bottom bar shows what a terminal KNOWS.
    var model: String { get }

    /// How big this session's context is RIGHT NOW, in tokens, when the
    /// vendor's own file says so — and `nil` when it does not.
    ///
    /// In tokens and never as a percentage. A percentage needs the size of
    /// the window, which no vendor writes into its transcript; working it out
    /// from the model's name is exactly the guess ISC-149 forbids, and it
    /// would be wrong by a factor of five the day a session runs with a
    /// larger window than its family's usual one.
    var contextTokens: Int? { get }

    /// Everything the agent has WRITTEN in this session, in tokens, summed
    /// over the whole file rather than read off the last record: output is
    /// what a session has spent, and spending accumulates.
    var outputTokens: Int? { get }

    /// How hard the session was told to think, in the vendor's own word.
    /// `nil` when the file carries no such field — which is not the same as
    /// a session thinking as little as possible, and must not be drawn as if
    /// it were.
    var effort: String? { get }
    /// I messaggi che l'agente tiene in coda adesso, nelle sue parole, e
    /// quanti ne ha consumati finora (ISC-194). Un adattatore il cui
    /// fornitore non scrive una coda risponde vuoto e zero, ed è la stessa
    /// risposta di «non lo so»: la ricevuta di T4A copre il buco da sé.
    var queued: [String] { get }
    var queueConsumed: Int { get }

    /// The family names this adapter can produce, lower case, so a long file
    /// name can be shortened to the two words a bar has room for.
    ///
    /// It is declared by the adapter and never by the core: the core is
    /// written against turns and states and names nobody (ISC-31, ISC-123).
    /// There is no default on purpose — a new adapter is asked the question
    /// by the compiler rather than inheriting an empty answer in silence.
    static var modelFamilies: [String] { get }

    /// `model`, shortened with those names. Supplied for every adapter by an
    /// extension beside them; an adapter may override it if its vendor writes
    /// model names in some shape this cannot read.
    var shortModel: String { get }

    /// A permission prompt this vendor has drawn on screen, or nil.
    func approval(on grid: any TerminalGrid) -> AgentApproval?
}

public extension AgentAdapter {
    static func transcripts(attributedTo pid: Int32, home: URL, cwd: URL,
                            processStart: Date?) -> [URL] {
        []
    }
}

/// The programs a shell command line actually runs.
///
/// `cd /tmp && claude --permission-mode default` runs two, and only the second
/// one matters to an adapter. Reading just the first word of the line is the
/// obvious thing to do and it is wrong exactly when a person does what people
/// do: change directory and start the agent on one line (measured 2026-08-20 —
/// the adapter looked at `cd` and never attached).
public enum ShellCommandLine {
    /// The head word of every segment, with leading `VAR=value` assignments and
    /// `sudo`-style prefixes dropped, in the order they appear.
    public static func programs(in line: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
            } else if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character == ";" || character == "|" || character == "&" {
                segments.append(current)
                current = ""
            } else if character == "$", line.index(after: index) < line.endIndex,
                      line[line.index(after: index)] == "(" {
                segments.append(current)
                current = ""
                index = line.index(index, offsetBy: 2)
                continue
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        segments.append(current)

        return segments.compactMap { segment in
            let words = segment.split(separator: " ").map(String.init)
                .filter { !$0.isEmpty }
            // `FOO=bar claude` runs claude; the assignment is the environment
            // it runs in, not a program.
            guard let head = words.first(where: { !$0.contains("=") || $0.hasPrefix("-") })
            else { return nil }
            let bare = (head as NSString).lastPathComponent
            return bare.isEmpty ? nil : bare
        }
    }
}
