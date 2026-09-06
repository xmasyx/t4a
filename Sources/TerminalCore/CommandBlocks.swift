//  CommandBlocks.swift — a shell command as an object: where it starts, how
//  long it ran, whether it failed.
//
//  This is the shell half of the thing T4A is for. The agent half (F4) reads
//  a transcript; this half reads what every shell already announces through
//  OSC 133, so it works with no agent in sight and with no rc file touched.

import Foundation

public struct CommandBlock: Identifiable, Sendable {
    public let id: Int
    /// Scroll-invariant row where the prompt was drawn.
    public var promptRow: Int
    /// Scroll-invariant row where output began. Nil while the user is still typing.
    public var outputRow: Int?
    /// Scroll-invariant row where the command finished.
    public var endRow: Int?
    public var command: String
    public var startedAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?
    /// A failure the user has not dismissed. The red gutter tick reads this,
    /// and it stays until dismissed — never on a timer (ISC-64).
    public var failureAcknowledged = false

    public var isRunning: Bool { startedAt != nil && finishedAt == nil }
    public var didFail: Bool { (exitCode ?? 0) != 0 }
    public var showsFailureMark: Bool { didFail && !failureAcknowledged }

    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// The row span the block covers, prompt through last output row.
    public func rowRange(endingAt fallbackEnd: Int) -> ClosedRange<Int> {
        let last = max(promptRow, endRow ?? fallbackEnd)
        return promptRow...last
    }
}

/// Turns the OSC 133 event stream into blocks. Fed by the backend; read by
/// the view that draws the gutter.
public final class CommandBlockLog {
    public private(set) var blocks: [CommandBlock] = []
    /// Raised whenever a block is added or changed.
    public var onChange: (() -> Void)?
    /// Blocks retained. Old ones fall off with the scrollback they describe.
    public var limit = 5_000

    private var nextID = 1

    public init() {}

    public var openBlock: CommandBlock? {
        guard let last = blocks.last, last.finishedAt == nil else { return nil }
        return last
    }

    public var failureCount: Int {
        blocks.reduce(0) { $0 + ($1.showsFailureMark ? 1 : 0) }
    }

    public func promptStarted(row: Int) {
        // A prompt with no command between it and the previous prompt means
        // the user pressed Return on an empty line: replace, do not stack.
        if let last = blocks.last, last.startedAt == nil {
            blocks[blocks.count - 1].promptRow = row
        } else {
            blocks.append(CommandBlock(id: nextID, promptRow: row, command: ""))
            nextID += 1
            trim()
        }
        onChange?()
    }

    public func commandStarted(row: Int, command: String, at date: Date = Date()) {
        if blocks.isEmpty || blocks[blocks.count - 1].startedAt != nil {
            // Output with no prompt seen: the shell integration is partial, or
            // we attached mid-session. A block anchored where output began is
            // still true, so record it rather than dropping the command.
            blocks.append(CommandBlock(id: nextID, promptRow: row, command: command))
            nextID += 1
            trim()
        }
        let index = blocks.count - 1
        blocks[index].outputRow = row
        blocks[index].command = command
        blocks[index].startedAt = date
        onChange?()
    }

    public func commandFinished(row: Int, exitCode: Int32?, at date: Date = Date()) {
        guard let index = blocks.lastIndex(where: { $0.finishedAt == nil && $0.startedAt != nil })
        else { return }
        blocks[index].endRow = row
        blocks[index].exitCode = exitCode
        blocks[index].finishedAt = date
        onChange?()
    }

    /// Names the command of the block that is running, or of the one about
    /// to run. Never overwrites a name the block already has.
    public func annotateCommand(_ command: String) {
        guard !command.isEmpty, let index = blocks.indices.last,
              blocks[index].command.isEmpty, blocks[index].finishedAt == nil
        else { return }
        blocks[index].command = command
        onChange?()
    }

    /// Clears the red tick on one block. It is the only way it goes away.
    public func acknowledgeFailure(id: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].failureAcknowledged = true
        onChange?()
    }

    public func acknowledgeAllFailures() {
        for index in blocks.indices where blocks[index].showsFailureMark {
            blocks[index].failureAcknowledged = true
        }
        onChange?()
    }

    /// The block covering a scroll-invariant row, if any.
    public func block(containing row: Int, screenEnd: Int) -> CommandBlock? {
        blocks.last { $0.rowRange(endingAt: screenEnd).contains(row) }
    }

    public func reset() {
        blocks.removeAll()
        onChange?()
    }

    private func trim() {
        if blocks.count > limit { blocks.removeFirst(blocks.count - limit) }
    }
}

/// Parses the OSC 133 payloads T4A emits and consumes.
public enum SemanticPromptWire {
    public struct Action {
        public var letter: Character
        public var options: [String: String]
        /// Fields with no `=`. `OSC 133;D;1` puts the exit code here, because
        /// the protocol writes it positionally, not as an option.
        public var positional: [String]
    }

    public static func parse(_ payload: String) -> Action? {
        let fields = payload.components(separatedBy: ";")
        guard let first = fields.first, first.count == 1, let letter = first.first
        else { return nil }
        var options: [String: String] = [:]
        var positional: [String] = []
        for field in fields.dropFirst() {
            guard let separator = field.firstIndex(of: "=") else {
                if !field.isEmpty { positional.append(field) }
                continue
            }
            options[String(field[..<separator])] =
                String(field[field.index(after: separator)...])
        }
        return Action(letter: letter, options: options, positional: positional)
    }

    /// The command line, if the shell put one in the `cmd` option. Kept as a
    /// fallback: T4A's own shells announce the command through OSC 633 `E`
    /// instead, because fish emits its own OSC 133 and a second `C` from us
    /// would split every command into two blocks.
    public static func command(from options: [String: String]) -> String? {
        guard let encoded = options["cmd"],
              let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    /// The command line announced by OSC 633 `E`. T4A base64-encodes it, since
    /// a command line may contain the separator and control characters; a
    /// payload that is not base64 is taken literally, which is what other
    /// terminals' shells send.
    public static func announcedCommand(_ sequence: OSCSequence) -> String? {
        let fields = sequence.fields
        guard fields.count >= 2, fields[0] == "E" else { return nil }
        let payload = fields[1...].joined(separator: ";")
        if let data = Data(base64Encoded: payload),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return payload.isEmpty ? nil : payload
    }

    public static func exitCode(from action: Action) -> Int32? {
        if let raw = action.positional.first, let value = Int32(raw) { return value }
        if let raw = action.options["exit"], let value = Int32(raw) { return value }
        return nil
    }
}
