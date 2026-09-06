//  InspectorView.swift — the right panel, in the register of the Pages
//  inspector: flush to the window edge, its own surface, a small centred
//  title, modules underneath (MacAppRules §9, ISC-85).
//
//  It holds the map of what happened in this pane. With no agent that is the
//  shell's commands, read from OSC 133. With an agent attached it is the
//  agent's TURNS, read from its transcript: what you asked, how long it took,
//  which tools ran, and a red tick against a turn where one of them failed
//  (ISC-26). It is called a map and not a history because both live in it.

import AppKit
import TerminalCore

@MainActor
final class InspectorView: FlushPanel, LanguageAware {
    /// The heading is drawn and the rows are rebuilt from the session, so a
    /// language change is a reload: nothing here caches a translated string.
    func applyLanguage() { reload() }

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var session: Session?
    var onSelectBlock: ((CommandBlock) -> Void)?
    /// A turn was clicked: go to the row it was drawn on.
    var onSelectTurn: ((AgentTurn) -> Void)?
    /// Its disclosure triangle was clicked: fold or unfold its work.
    var onToggleTurn: ((AgentTurn) -> Void)?
    /// Turns whose work is folded away in the terminal right now.
    var foldedTurns: Set<Int> = []

    private var showingTurns = false
    /// The heading's drawn rectangle, in this view's flipped coordinates.
    /// F0 compares ink with ink, never a guessed container edge (ISC-238).
    private(set) var headingRect = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = stack
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ session: Session?) {
        self.session = session
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        reload()
    }

    /// What the panel is showing right now, by name. The dump reads it, so a
    /// claim about the inspector is checked against the panel's own answer
    /// rather than against a screenshot.
    var mode: String { showingTurns ? "turns" : "commands" }

    /// Says the truth about an agent that has not spoken yet. Before this, an
    /// attached agent with zero turns fell back to the command map, which
    /// reads as «the panel is broken» (his report, 25/08).
    private lazy var emptyNote: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "no turns yet")
        label.font = Theme.labelFont(10)
        label.textColor = Theme.current.whisper
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    func reload() {
        let turns = session?.turns ?? []
        let wantsTurns = session?.agent?.isAttached == true
        if wantsTurns != showingTurns {
            showingTurns = wantsTurns
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        if showingTurns { reloadTurns(turns) } else { reloadBlocks() }
        needsDisplay = true
    }

    private func reloadTurns(_ turns: [AgentTurn]) {
        if turns.isEmpty {
            if emptyNote.superview == nil {
                stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
                stack.addArrangedSubview(emptyNote)
            }
            return
        }
        if emptyNote.superview != nil { emptyNote.removeFromSuperview() }
        let existing = stack.arrangedSubviews.compactMap { $0 as? TurnRow }
        if existing.count != turns.count {
            existing.forEach { $0.removeFromSuperview() }
            for turn in turns { addTurnRow(turn) }
        } else {
            for (row, turn) in zip(existing, turns) {
                row.turn = turn
                row.isFolded = foldedTurns.contains(turn.id)
            }
        }
    }

    private func addTurnRow(_ turn: AgentTurn) {
        let row = TurnRow(turn: turn)
        row.isFolded = foldedTurns.contains(turn.id)
        row.onSelect = { [weak self] in self?.onSelectTurn?($0) }
        row.onToggle = { [weak self] in self?.onToggleTurn?($0) }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 42).isActive = true
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func reloadBlocks() {
        let blocks = session?.blocks.blocks ?? []
        // The present is at the bottom, as in every terminal (ISC-73): the
        // list is drawn oldest first and the view holds its place at the end.
        let existing = stack.arrangedSubviews.compactMap { $0 as? BlockRow }
        if existing.count != blocks.count {
            existing.forEach { $0.removeFromSuperview() }
            for block in blocks { addRow(block) }
        } else {
            for (row, block) in zip(existing, blocks) { row.block = block }
        }
    }

    private func addRow(_ block: CommandBlock) {
        let row = BlockRow(block: block) { [weak self] in
            guard let session = self?.session else { return }
            session.blocks.acknowledgeFailure(id: $0.id)
            self?.onSelectBlock?($0)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let palette = Theme.current
        let heading = NSAttributedString(string: showingTurns ? S.inspectorTurns : S.inspectorCommandMap,
                                         attributes: [
            .font: Theme.labelFont(10), .foregroundColor: palette.whisper, .kern: 0.8,
        ])
        let origin = NSPoint(x: 14, y: 14)
        heading.draw(at: origin)
        headingRect = NSRect(origin: origin, size: heading.size())

        let count = showingTurns
            ? (session?.turns.count ?? 0)
            : (session?.blocks.blocks.count ?? 0)
        let countText = NSAttributedString(string: "\(count)", attributes: [
            .font: Theme.labelFont(10), .foregroundColor: palette.whisper,
        ])
        countText.draw(at: NSPoint(x: bounds.width - countText.size().width - 14, y: 14))
    }
}

/// One agent turn: the question, the time it took, the tools it ran, and a
/// tick when one of them failed.
@MainActor
final class TurnRow: NSView {
    var turn: AgentTurn { didSet { needsDisplay = true } }
    var isFolded = false { didSet { needsDisplay = true } }
    var onSelect: ((AgentTurn) -> Void)?
    var onToggle: ((AgentTurn) -> Void)?
    private var triangle = NSRect.zero

    init(turn: AgentTurn) {
        self.turn = turn
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The triangle folds the work; anywhere else goes to the turn. Two
        // targets in one row, and the small one is given a generous margin
        // because a disclosure triangle you have to aim at is a bad one.
        if triangle.insetBy(dx: -6, dy: -6).contains(point) { onToggle?(turn) }
        else { onSelect?(turn) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        if turn.failed {
            palette.failed.setFill()
            NSRect(x: 0, y: 4, width: 2, height: bounds.height - 8).fill()
        }

        let canFold = turn.workRows != nil
        triangle = NSRect(x: 10, y: 8, width: 10, height: 10)
        if canFold {
            let mark = NSAttributedString(string: isFolded ? "▸" : "▾", attributes: [
                .font: Theme.uiFont(9),
                .foregroundColor: palette.whisper,
            ])
            mark.draw(at: NSPoint(x: triangle.minX, y: triangle.minY - 1))
        }

        let headline = NSAttributedString(string: turn.headline, attributes: [
            .font: Theme.uiFont(12),
            .foregroundColor: turn.failed ? palette.failedSoft : palette.ink,
        ])
        let durationLabel = turn.isOpen ? "…" : BlockOverlayView.format(turn.duration ?? 0)
        let duration = NSAttributedString(string: durationLabel, attributes: [
            .font: Theme.labelFont(10),
            .foregroundColor: turn.isOpen ? palette.accentText : palette.whisper,
        ])
        let durationWidth = duration.size().width
        headline.draw(in: NSRect(x: 24, y: 5, width: bounds.width - durationWidth - 38,
                                 height: 15))
        duration.draw(at: NSPoint(x: bounds.width - durationWidth - 12, y: 6))

        // The second line names the work, which is the thing the turn map
        // exists for: not that something happened, but what ran.
        let failedTools = turn.tools.filter(\.isError).count
        var summary = turn.tools.isEmpty ? S.noTools : S.tools(count: turn.tools.count)
        if let last = turn.tools.last, !last.summary.isEmpty {
            summary += " · \(last.name.lowercased()) \(last.summary)"
        }
        if failedTools > 0 { summary += " · " + S.failed(count: failedTools) }
        let detail = NSAttributedString(string: summary, attributes: [
            .font: Theme.uiFont(10.5),
            .foregroundColor: failedTools > 0 ? palette.failedSoft : palette.whisper,
        ])
        detail.draw(in: NSRect(x: 24, y: 23, width: bounds.width - 36, height: 14))
    }
}

@MainActor
final class BlockRow: NSView {
    var block: CommandBlock { didSet { needsDisplay = true } }
    private let onClick: (CommandBlock) -> Void

    init(block: CommandBlock, onClick: @escaping (CommandBlock) -> Void) {
        self.block = block
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick(block) }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        if block.showsFailureMark {
            palette.failed.setFill()
            NSRect(x: 0, y: 3, width: 2, height: bounds.height - 6).fill()
        }

        let name = block.command.isEmpty ? S.inspectorPromptBlock : block.command
        let text = NSAttributedString(string: name, attributes: [
            .font: Theme.monoFont(11),
            .foregroundColor: block.didFail ? palette.failedSoft : palette.muted,
        ])
        let durationLabel = block.duration.map { BlockOverlayView.format($0) } ?? "…"
        let duration = NSAttributedString(string: durationLabel, attributes: [
            .font: Theme.labelFont(10), .foregroundColor: palette.whisper,
        ])
        let durationWidth = duration.size().width
        text.draw(in: NSRect(x: 12, y: 6, width: bounds.width - durationWidth - 26, height: 14))
        duration.draw(at: NSPoint(x: bounds.width - durationWidth - 12, y: 7))
    }
}
