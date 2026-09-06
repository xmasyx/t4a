//  FindBar.swift — ⌘F, and the hits lit on the GPU.
//
//  The bar itself is ordinary AppKit — a field, a count, two arrows, a regex
//  switch. What matters is where the highlighting happens: the matches are
//  handed to the renderer as spans and painted with the cells, in the same
//  frame as the text, instead of being drawn over the terminal by a second
//  layer that has to be kept in step with it (ISC-66).

import AppKit
import TerminalCore

enum FindSource: String { case grid, transcript }

@MainActor
final class FindBar: NSView, NSTextFieldDelegate, ThemeAware, LanguageAware {
    func applyTheme() {
        layer?.backgroundColor = Theme.current.panel.cgColor
        layer?.borderColor = Theme.current.panelEdge.cgColor
        counter.textColor = Theme.current.whisper
        hitList.applyTheme()
    }

    func applyLanguage() {
        field.placeholderString = S.findPlaceholder
        regexToggle.toolTip = S.findRegexTooltip
        if let presentation { display(presentation) }
        hitList.needsDisplay = true
    }

    private let field = NSTextField()
    private let counter = NSTextField(labelWithString: "")
    private let regexToggle = NSButton(checkboxWithTitle: ".*", target: nil, action: nil)
    private var previous = ChromeButton(title: "‹", action: {})
    private var next = ChromeButton(title: "›", action: {})
    private let hitList = FindHitListView()
    private var hitListHeight: NSLayoutConstraint!
    private typealias Presentation = (
        count: Int, current: Int?, truncated: Bool, seconds: Double,
        source: FindSource, hits: [TranscriptHit], request: SearchRequest
    )
    private var presentation: Presentation?

    var onChange: ((SearchRequest) -> Void)?
    var onStep: ((Int) -> Void)?
    var onSelect: ((Int) -> Void)?
    var onOpen: ((TranscriptHit) -> Void)?
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.current.panel.cgColor
        layer?.cornerRadius = Theme.Metric.cardRadius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.current.panelEdge.cgColor

        field.placeholderString = S.findPlaceholder
        field.font = Theme.uiFont(12)
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        counter.font = Theme.labelFont(11)
        counter.textColor = Theme.current.whisper
        regexToggle.font = Theme.labelFont(11)
        regexToggle.target = self
        regexToggle.action = #selector(regexChanged)
        regexToggle.toolTip = S.findRegexTooltip

        previous = ChromeButton(title: "‹") { [weak self] in self?.onStep?(-1) }
        next = ChromeButton(title: "›") { [weak self] in self?.onStep?(1) }
        let close = ChromeButton(title: "✕") { [weak self] in self?.onClose?() }

        let toolbar = NSStackView(views: [field, counter, regexToggle, previous, next, close])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        hitList.translatesAutoresizingMaskIntoConstraints = false
        hitList.isHidden = true
        hitList.onChoose = { [weak self] in self?.onSelect?($0) }
        addSubview(toolbar)
        addSubview(hitList)
        hitListHeight = hitList.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),
            hitList.leadingAnchor.constraint(equalTo: leadingAnchor),
            hitList.trailingAnchor.constraint(equalTo: trailingAnchor),
            hitList.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            hitList.bottomAnchor.constraint(equalTo: bottomAnchor),
            hitListHeight,
            field.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var query: String { field.stringValue }

    /// Puts text in the field, as typing does. The test channel uses it so
    /// what is measured is the bar a person sees, filled in.
    func setQuery(_ text: String, regex: Bool) {
        field.stringValue = text
        regexToggle.state = regex ? .on : .off
    }
    var request: SearchRequest {
        SearchRequest(text: field.stringValue,
                      mode: regexToggle.state == .on ? .regex : .literal)
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func show(count: Int, current: Int?, truncated: Bool, seconds: Double,
              source: FindSource, hits: [TranscriptHit], request: SearchRequest) {
        let next: Presentation = (count, current, truncated, seconds, source, hits, request)
        presentation = next
        display(next)
    }

    private func display(_ presentation: Presentation) {
        let sourceLabel = presentation.source == .transcript ? S.findInChat : S.findOnScreen
        if presentation.count == 0 {
            counter.stringValue = field.stringValue.isEmpty
                ? "" : S.noFindResults(source: sourceLabel)
        } else {
            let position = presentation.current.map { "\($0 + 1)/" } ?? ""
            counter.stringValue = "\(position)\(presentation.count)"
                + "\(presentation.truncated ? "+" : "") \(sourceLabel)"
        }
        counter.toolTip = String(format: "%.0f ms", presentation.seconds * 1000)

        let showsHits = presentation.source == .transcript && !presentation.hits.isEmpty
        hitList.isHidden = !showsHits
        hitList.show(presentation.hits, selection: presentation.current ?? 0,
                     request: presentation.request)
        hitListHeight.constant = showsHits ? hitList.preferredHeight : 0
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 540, height: 36 + hitListHeight.constant)
    }

    @objc private func regexChanged() { onChange?(request) }

    func controlTextDidChange(_ notification: Notification) { onChange?(request) }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            onStep?(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            onStep?(1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let hit = hitList.selectedHit {
                onOpen?(hit)
                return true
            }
            onStep?(NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// The transcript results use the same hand-drawn panel and selected-row veil
/// as the slash list. A system table would bring a second palette and scroller
/// into a window whose colours are explicit everywhere else.
@MainActor
private final class FindHitListView: NSView, ThemeAware {
    private static let maxRows = 6
    private static let rowHeight: CGFloat = 30
    private static let padding: CGFloat = 6

    private var hits: [TranscriptHit] = []
    private var selection = 0
    private var top = 0
    private var request = SearchRequest(text: "")
    private var rowRects: [(NSRect, Int)] = []
    var onChoose: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    var preferredHeight: CGFloat {
        CGFloat(min(Self.maxRows, hits.count)) * Self.rowHeight + 2 * Self.padding
    }
    var selectedHit: TranscriptHit? {
        hits.indices.contains(selection) ? hits[selection] : nil
    }

    func applyTheme() { needsDisplay = true }

    func show(_ next: [TranscriptHit], selection nextSelection: Int,
              request nextRequest: SearchRequest) {
        hits = next
        request = nextRequest
        selection = hits.isEmpty ? 0 : max(0, min(hits.count - 1, nextSelection))
        clampScroll()
        needsDisplay = true
    }

    private func clampScroll() {
        let rows = min(Self.maxRows, hits.count)
        guard rows > 0 else { top = 0; return }
        top = min(top, max(0, hits.count - rows))
        if selection < top { top = selection }
        if selection >= top + rows { top = selection - rows + 1 }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = rowRects.first(where: { $0.0.contains(point) }) else { return }
        selection = row.1
        clampScroll()
        needsDisplay = true
        onChoose?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        palette.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        rowRects.removeAll(keepingCapacity: true)

        let rows = min(Self.maxRows, hits.count)
        let scrolls = hits.count > rows
        let right = bounds.maxX - (scrolls ? 14 : 8)
        var y = Self.padding
        for index in top ..< min(hits.count, top + rows) {
            let row = NSRect(x: 5, y: y, width: bounds.width - 10,
                             height: Self.rowHeight)
            rowRects.append((row, index))
            if index == selection {
                palette.accentDim.setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: 1),
                             xRadius: Theme.Metric.cardRadius,
                             yRadius: Theme.Metric.cardRadius).fill()
            }
            let line = attributedLine(for: hits[index], selected: index == selection)
            line.draw(with: NSRect(x: 10, y: y + 7, width: right - 10, height: 17),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += Self.rowHeight
        }

        guard scrolls else { return }
        let track = NSRect(x: bounds.maxX - 8, y: Self.padding, width: 3,
                           height: CGFloat(rows) * Self.rowHeight)
        let share = CGFloat(rows) / CGFloat(hits.count)
        let thumb = NSRect(x: track.minX,
                           y: track.minY + track.height * CGFloat(top) / CGFloat(hits.count),
                           width: 3, height: max(24, track.height * share))
        palette.hairlineSoft.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        palette.whisper.setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func attributedLine(for hit: TranscriptHit, selected: Bool) -> NSAttributedString {
        let prefix = S.findTurnPrefix(id: hit.turnID)
        let palette = Theme.current
        let regular = Theme.uiFont(11)
        let line = NSMutableAttributedString(string: prefix + hit.excerpt, attributes: [
            .font: regular,
            .foregroundColor: selected ? palette.ink : palette.muted,
        ])
        line.addAttributes([.font: Theme.labelFont(10),
                            .foregroundColor: palette.whisper],
                           range: NSRange(location: 0, length: prefix.utf16.count))

        let pattern = request.mode == .regex
            ? request.text : NSRegularExpression.escapedPattern(for: request.text)
        let smartCase = request.caseSensitive
            ?? request.text.contains(where: { $0.isUppercase })
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: smartCase ? [] : [.caseInsensitive]) else { return line }
        let excerptRange = NSRange(hit.excerpt.startIndex..., in: hit.excerpt)
        let matches = regex.matches(in: hit.excerpt, range: excerptRange)
            .filter { $0.range.length > 0 }
        let middle = excerptRange.length / 2
        guard let match = matches.min(by: {
            abs(($0.range.location + $0.range.length / 2) - middle)
                < abs(($1.range.location + $1.range.length / 2) - middle)
        }) else { return line }
        line.addAttributes([.font: Theme.uiFont(11, weight: .bold),
                            .foregroundColor: palette.ink],
                           range: NSRange(location: prefix.utf16.count + match.range.location,
                                          length: match.range.length))
        return line
    }
}
