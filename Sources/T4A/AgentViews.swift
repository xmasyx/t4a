//  AgentViews.swift — the two places T4A talks BACK to a session: the
//  approval card and the composer.
//
//  Both obey the same rule, and it is the rule that keeps T4A a terminal.
//  Neither of them decides anything. The card does not grant a permission and
//  the composer does not send a message: they put a keystroke into the pty,
//  exactly the keystroke a person's fingers would have put there, and the
//  agent's own prompt does the rest. If T4A vanished mid-sentence the session
//  would carry on, because nothing was ever routed through it.

import AppKit
import TerminalCore

/// The card that appears when an agent asks for permission (ISC-29).
///
/// It shows what is being asked in the terminal's own type, with the CONTENT
/// of a diff carried in value rather than in hue — brighter for what is being
/// added, dimmer for what is going — because a green-and-red diff on a dark
/// page is two accents on a screen that is allowed one.
@MainActor
final class ApprovalCard: NSView, ThemeAware, LanguageAware {
    /// The card paints its labels once, when the question arrives, so a theme
    /// or language change asks it to build the same question again.
    func applyTheme() {
        rebuildVisibleState()
    }

    func applyLanguage() {
        rebuildVisibleState()
    }

    private func rebuildVisibleState() {
        if !withdrawnReason.isEmpty {
            renderWithdrawal(withdrawnReason)
            return
        }
        guard let held = current else { return }
        current = nil
        show(held, kind: currentKind)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let body = NSStackView()
    private let approve = ChromeButton(title: S.approve, action: {})
    private let deny = ChromeButton(title: S.deny, action: {})
    private var current: AgentApproval?
    private var currentKind = ""

    /// Called with the keystrokes to put down the pty.
    var onAnswer: ((String) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.uiFont(13, weight: .medium)
        kindLabel.font = Theme.labelFont(10)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 2

        let buttons = NSStackView(views: [deny, approve])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [titleLabel, kindLabel, body, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            kindLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            kindLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 9),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            approve.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            deny.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            approve.heightAnchor.constraint(equalToConstant: 28),
            deny.heightAnchor.constraint(equalToConstant: 28),
        ])
        approve.isSelected = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The approval on screen, or nil to take the card away.
    func show(_ approval: AgentApproval?, kind: String) {
        guard let approval else {
            isHidden = true
            current = nil
            return
        }
        // Same question, already drawn: rebuilding would blink the card in
        // the middle of somebody reading it.
        if current == approval, !isHidden, withdrawnReason.isEmpty { return }
        current = approval
        currentKind = kind
        withdrawnReason = ""
        approve.isHidden = false
        deny.isHidden = false
        isHidden = false
        let palette = Theme.current
        layer?.backgroundColor = palette.panel.cgColor
        layer?.borderColor = palette.accent.withAlphaComponent(0.55).cgColor
        titleLabel.stringValue = approval.title
        titleLabel.textColor = palette.ink
        kindLabel.stringValue = kind.uppercased()
        kindLabel.textColor = palette.whisper

        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in approval.detail.prefix(10) {
            let label = NSTextField(labelWithString: line)
            label.font = Theme.monoFont(11)
            label.lineBreakMode = .byTruncatingTail
            label.textColor = Self.value(of: line, palette: palette)
            body.addArrangedSubview(label)
        }

        let yes = approval.options.first { $0.isApproval }
        let no = approval.options.first { !$0.isApproval }
        approve.title = yes?.label.count ?? 0 > 24 ? S.approve : (yes?.label ?? S.approve)
        deny.title = no?.label.count ?? 0 > 18 ? S.deny : (no?.label ?? S.deny)
        approve.onClick = { [weak self] in
            guard let keys = yes?.keystrokes else { return }
            self?.onAnswer?(keys)
        }
        deny.onClick = { [weak self] in
            guard let keys = no?.keystrokes else { return }
            self?.onAnswer?(keys)
        }
        needsDisplay = true
    }

    /// A diff line's meaning in VALUE, never in hue: what is arriving reads
    /// brighter than the page, what is leaving reads dimmer, and the accent
    /// stays reserved for the one thing it marks.
    private static func value(of line: String, palette: Theme.Palette) -> NSColor {
        if line.hasPrefix("+") { return palette.ink }
        if line.hasPrefix("-") { return palette.whisper }
        return palette.muted
    }

    /// Why the card took itself away without sending anything, while the
    /// notice is up. Empty the rest of the time.
    private(set) var withdrawnReason = ""

    /// The question on the card is not the question on the screen any more, so
    /// the card takes itself away and SAYS so (ISC-127).
    ///
    /// Silence here would read as a click that did nothing, and a click that
    /// does nothing on a permission is the one thing a person must not be left
    /// guessing about: they would click again, or go and type the digit
    /// themselves at a prompt that has moved on.
    func withdraw(_ reason: String) {
        current = nil
        withdrawnReason = reason
        isHidden = false
        renderWithdrawal(reason)
        let notice = withdrawnReason
        Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            Task { @MainActor in
                // Only if nothing else has happened to the card since.
                guard self.withdrawnReason == notice, self.current == nil else { return }
                self.withdrawnReason = ""
                self.isHidden = true
                self.approve.isHidden = false
                self.deny.isHidden = false
            }
        }
    }

    private func renderWithdrawal(_ reason: String) {
        let palette = Theme.current
        layer?.backgroundColor = palette.panel.cgColor
        layer?.borderColor = palette.failed.withAlphaComponent(0.55).cgColor
        titleLabel.stringValue = S.nothingWasSent
        titleLabel.textColor = palette.ink
        kindLabel.stringValue = S.withdrawn
        kindLabel.textColor = palette.failedSoft
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: reason)
        label.font = Theme.labelFont(11)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = palette.muted
        body.addArrangedSubview(label)
        approve.isHidden = true
        deny.isHidden = true
        needsDisplay = true
    }

    var isShowing: Bool { !isHidden && current != nil }
    var shownApproval: AgentApproval? { isHidden ? nil : current }

    /// Presses one of the card's own buttons, the way a click does. The bench
    /// uses this so what it proves is the button a person sees, not a private
    /// door into the same function (ISC-29).
    func press(approve wanted: Bool) -> Bool {
        guard isShowing else { return false }
        let button = wanted ? approve : deny
        button.performClick(nil)
        return true
    }
}

/// The composer (ISC-42): a line of text that goes into the pty of the
/// selected session, as if it had been typed at the agent's own prompt.
///
/// A TEXT VIEW and not a text field since ISC-159. A field is one line by
/// construction: `⇧↩` and `↩` both reach it as `insertNewline(_:)`, so there
/// is no shift to notice, and even if there were the field could not show
/// what it had inserted. The bubble now grows with what is written in it,
/// between one line and six, and stops growing rather than eating the
/// terminal.
@MainActor
final class ComposerView: NSView, ThemeAware, LanguageAware {
    func applyTheme() {
        hint.textColor = Theme.current.whisper
        field.textColor = Theme.current.ink
        field.insertionPointColor = Theme.current.ink
        needsDisplay = true
    }

    func applyLanguage() {
        field.placeholder = S.messageThisSessionPlaceholder
    }

    /// Not private since ISC-158: `testFirstResponder` has to tell the
    /// composer's own editor from any other text view in the window, and the
    /// only honest way is to compare against the view itself.
    let field = ComposerField()
    /// The bubble stops growing at six lines; past that the text has to be
    /// reachable, and a text view alone just clips it. Everything the field
    /// already does — height reporting, placeholder, Return — is unchanged:
    /// only who holds it changes (his report, 2026-08-24).
    private let scroller = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    /// Called with the text the user wrote. The newline is added by the
    /// caller, so a composer that is reused for something that does not want
    /// one does not have to strip it back off.
    /// False leaves the text in place: the controller can refuse a send
    /// before it reaches the pty without making the user's message disappear.
    var onSend: ((ComposerSubmission) -> Bool)?
    /// I tasti che interrompono, inoltrati al processo del pannello.
    var onRawKey: (([UInt8]) -> Void)?
    /// The bubble changed height: the window has to give it the room.
    var onHeightChange: (() -> Void)?
    /// The three wires of the `/` list (ISC-187). The list itself is not owned
    /// here: it lives over the whole window, above the chat page and the
    /// terminal, so it belongs to the controller that lays those out.
    var onTextChange: ((String) -> Void)?
    var onSlashKey: ((NSEvent) -> Bool)?
    var onResign: (() -> Void)?
    /// Told, not asked: the controller decides whether the list is open, and
    /// the field only needs to know so it can stand its ghost down.
    var listaAperta: Bool {
        get { field.listaAperta }
        set { field.listaAperta = newValue }
    }
    /// Where the list should sit, in this view's own coordinates: the top edge
    /// of the drawn card, which is what the eye reads as the bubble.
    static let cardInset: CGFloat = 10

    /// One line of bubble, and the most it may grow to. Six lines is the
    /// height at which a message stops being a line you send and becomes a
    /// document you write; past it the view scrolls.
    static let oneLine: CGFloat = 44
    static let maximumHeight: CGFloat = 44 + 5 * 17

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Inside a scroll view the document view is placed by frame, not by
        // constraints: leaving this false gives an empty, zero-sized document.
        field.translatesAutoresizingMaskIntoConstraints = true
        field.autoresizingMask = [.width]
        field.minSize = NSSize(width: 0, height: 0)
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        field.font = Theme.monoFont(12)
        field.drawsBackground = false
        field.textColor = Theme.current.ink
        field.insertionPointColor = Theme.current.ink
        field.isRichText = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.textContainerInset = NSSize(width: 0, height: 0)
        field.textContainer?.lineFragmentPadding = 0
        field.placeholder = S.messageThisSessionPlaceholder
        field.onSubmit = { [weak self] submission in
            guard let self, !submission.text.isEmpty else { return false }
            guard self.onSend?(submission) ?? true else { return false }
            self.remember(submission.text)
            self.field.string = ""
            self.field.didChangeText()
            return true
        }
        field.onRawKey = { [weak self] bytes in self?.onRawKey?(bytes) }
        field.suggest = { [weak self] prefix in
            guard let self, prefix.count >= 2 else { return nil }
            return self.history.last { $0.hasPrefix(prefix) && $0 != prefix }
        }
        field.onSizeChange = { [weak self] in self?.onHeightChange?() }
        field.onTextChange = { [weak self] in
            guard let self else { return }
            self.onTextChange?(self.field.string)
        }
        field.slashKeys = { [weak self] event in self?.onSlashKey?(event) ?? false }
        field.onResign = { [weak self] in self?.onResign?() }
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.drawsBackground = false
        scroller.borderType = .noBorder
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        scroller.documentView = field
        hint.font = Theme.labelFont(10)
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroller)
        addSubview(hint)
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroller.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -10),
            scroller.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            // The caption stays on the FIRST line whatever the bubble grows
            // to: a hint that floats down the side of a six-line message is a
            // hint that has stopped being a caption.
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 15),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// How tall the bubble wants to be, from what the text actually laid out
    /// to — measured, never counted off the newlines, because a long line
    /// wraps and a wrap is a row like any other.
    var preferredHeight: CGFloat {
        // Grows with the text the way claude's own input line does (his ask,
        // 25/08): the ceiling is a share of the window, not six lines. Past
        // the ceiling the scroller takes over, so nothing is ever clipped.
        let ceiling = max(Self.maximumHeight, (window?.frame.height ?? 0) * 0.45)
        return min(ceiling, max(Self.oneLine, field.usedHeight + 28))
    }

    func describe(target: String) {
        hint.stringValue = target.isEmpty ? "" : "→ \(target)   ⏎"
        hint.textColor = Theme.current.whisper
        field.textColor = Theme.current.ink
        needsDisplay = true
    }

    // MARK: - History, for the ghost

    /// What was sent from this bubble before, oldest first. The ghost the
    /// field shows is the newest line that begins with what is being typed —
    /// the same convention as a shell's autosuggestion, accepted with →
    /// (his ask, 25/08).
    private var history: [String] = []
    /// Where the history survives a restart; nil keeps it in memory only.
    var historyFile: URL? {
        didSet {
            guard let historyFile,
                  let text = try? String(contentsOf: historyFile, encoding: .utf8) else { return }
            history = text.split(separator: "\n").map(String.init).suffix(200)
        }
    }

    private func remember(_ line: String) {
        let flat = line.replacingOccurrences(of: "\n", with: " ")
        history.removeAll { $0 == flat }
        history.append(flat)
        if history.count > 200 { history.removeFirst(history.count - 200) }
        if let historyFile {
            try? history.joined(separator: "\n").write(to: historyFile,
                                                        atomically: true, encoding: .utf8)
        }
    }

    /// The text sitting in the composer, for the bench.
    var text: String {
        get { field.string }
        set { field.string = newValue; field.didChangeText() }
    }

    /// Sends what is in the field, through the same path Return takes.
    @discardableResult
    func submit() -> Bool { field.fire() }

    func focus() { window?.makeFirstResponder(field) }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Theme.current
        palette.ground.setFill()
        bounds.fill()
        let card = bounds.insetBy(dx: 10, dy: 5)
        let path = NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9)
        palette.panel.setFill()
        path.fill()
        palette.panelEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The bubble's editor. Return sends; shift-Return makes a line (ISC-159).
@MainActor
final class ComposerField: NSTextView {
    var onSubmit: ((ComposerSubmission) -> Bool)?
    /// I byte da mandare al processo così come sono, senza passare dal testo.
    var onRawKey: (([UInt8]) -> Void)?

    /// Il tasto premuto, tradotto nei byte che un terminale manderebbe.
    ///
    /// Solo i due che INTERROMPONO, e non l'intero alfabeto dei controlli: un
    /// Ctrl-A che scappa al processo dentro una scatola di testo sposta il
    /// cursore di qualcun altro invece del tuo, e la bolla resta una scatola
    /// di testo. Se un giorno servirà Ctrl-D, si aggiunge qui una riga e un
    /// polo, non si apre un varco a tutto.
    static func controlBytes(for event: NSEvent) -> [UInt8]? {
        if event.keyCode == 53 { return [0x1b] }                     // Esc
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "c" { return [0x03] }
        return nil
    }
    var onSizeChange: (() -> Void)?
    /// The text changed. Raised BEFORE the ghost is worked out, because
    /// whoever answers this decides whether there is a `/` list open, and a
    /// ghost is not drawn under one (ISC-187).
    var onTextChange: (() -> Void)?
    /// Offered every key while the `/` list is open; `true` means the list
    /// took it and nothing else may see it. It sits above the interrupt bytes
    /// on purpose: with the list open Esc closes the list, and only a second
    /// Esc — with nothing open — is the `^[` of ISC-171.
    var slashKeys: ((NSEvent) -> Bool)?
    /// The `/` list is on screen. The ghost tail stands down while it is: two
    /// completions offering different things at the same caret is one too
    /// many.
    var listaAperta = false { didSet {
        guard listaAperta != oldValue else { return }
        if listaAperta { ghostTail = "" }
        needsDisplay = true
    } }
    /// The bubble stopped being the first responder, so anything hanging off
    /// the caret has to go.
    var onResign: (() -> Void)?
    /// Asked with what is typed so far; answers with the WHOLE line it
    /// completes to, or nil. The tail is drawn in whisper after the caret and
    /// → takes it — claude's own input line does this, and a bubble that
    /// replaces that line has to keep the habit (his ask, 25/08).
    var suggest: ((String) -> String?)?
    private var ghostTail = ""
    /// Drawn by hand, because a text view has no placeholder of its own.
    var placeholder = "" { didSet { needsDisplay = true } }

    private var lastReportedHeight: CGFloat = -1

    convenience init() {
        self.init(frame: .zero)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainer?.widthTracksTextView = true
        autoresizingMask = [.width]
        allowsUndo = true
        registerForDraggedTypes(DroppedItems.types + registeredDraggedTypes)
    }

    override var isFlipped: Bool { true }
    /// A text view claims the whole rectangle it is given; the height comes
    /// from the bubble's constraints, so it must not fight them.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: usedHeight)
    }

    /// The height the text actually laid out to.
    var usedHeight: CGFloat {
        guard let manager = layoutManager, let container = textContainer else { return 16 }
        manager.ensureLayout(for: container)
        return max(16, manager.usedRect(for: container).height)
    }

    /// Long pastes, kept whole but shown as one line.
    ///
    /// A terminal collapses a big paste into `[Pasted text #1 +203 lines]`
    /// rather than filling the screen with it, and the bubble did not: a
    /// two-hundred-line paste made the composer a wall (his report,
    /// 2026-08-24). The text is never touched — it is parked here and put back
    /// on the way out, so what the session receives is exactly what was
    /// copied.
    private struct StoredAttachment {
        let body: String
        let isolated: Bool
    }
    private var attachments: [String: StoredAttachment] = [:]
    private var nextPasteNumber = 1
    private var nextImageNumber = 1
    /// Below this a paste is just text: a handful of lines is still something
    /// the writer can read at a glance, and hiding it would cost more than it
    /// saves. Lowered from eight on his word, 2026-08-24.
    static let pasteLineThreshold = 4

    private static func token(_ number: Int, lines: Int) -> String {
        "[Pasted text #\(number) +\(lines) lines]"
    }

    /// Lines the way a person counts them: a text that ends with a newline has
    /// no empty last line. `seq 1 200` is two hundred lines, and the marker
    /// said 201 until this existed (bench-paste, first run).
    private static func lineCount(_ text: String) -> Int {
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return body.components(separatedBy: "\n").count
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let lines = Self.lineCount(text)
        guard lines > Self.pasteLineThreshold else {
            super.paste(sender)
            return
        }
        let number = nextPasteNumber
        nextPasteNumber += 1
        let mark = Self.token(number, lines: lines)
        attachments[mark] = StoredAttachment(body: text, isolated: false)
        insertText(mark, replacementRange: selectedRange())
        didChangeText()
    }

    /// A collapsed paste is one object, so backspace takes all of it.
    ///
    /// Without this the token comes apart a character at a time, and a
    /// half-eaten `[Pasted text #1 +20` no longer matches anything, so it
    /// would travel to the session as literal text.
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        if caret.length == 0, caret.location > 0 {
            let head = (string as NSString).substring(to: caret.location)
            for mark in attachments.keys where head.hasSuffix(mark) {
                let start = caret.location - (mark as NSString).length
                shouldChangeText(in: NSRange(location: start, length: (mark as NSString).length),
                                 replacementString: "")
                replaceCharacters(in: NSRange(location: start, length: (mark as NSString).length), with: "")
                attachments[mark] = nil
                didChangeText()
                return
            }
        }
        super.deleteBackward(sender)
    }

    /// What the session receives: ordinary collapsed text is expanded inline,
    /// while every image path becomes a paste object of its own. Claude makes
    /// the attachment decision at the end of that object; prose concatenated
    /// into the same frame turns the measured-good path back into plain text.
    func submission(_ written: String) -> ComposerSubmission {
        let inline = attachments.filter { !$0.value.isolated }.mapValues(\.body)
        let isolated = attachments.filter(\.value.isolated).mapValues(\.body)
        return ComposerSubmission(written: written,
                                  inlineExpansions: inline,
                                  isolatedAttachments: isolated)
    }

    @discardableResult
    func fire() -> Bool {
        let submission = submission(string)
        guard onSubmit?(submission) ?? true else { return false }
        attachments.removeAll()
        nextPasteNumber = 1
        nextImageNumber = 1
        return true
    }

    /// Return and shift-Return, told apart HERE and not in a delegate.
    ///
    /// `insertNewline(_:)` is what a text view is handed for both of them —
    /// the shift is gone by the time the selector is chosen — so the two can
    /// only be separated where the event still exists.
    override func keyDown(with event: NSEvent) {
        // L'elenco dei comandi `/` per primo, quando è aperto (ISC-187). È
        // sopra i byte che interrompono perché Esc a elenco aperto lo chiude e
        // NON deve arrivare al processo: il `^[` di ISC-171 è il secondo Esc,
        // quello premuto senza niente aperto, e resta intatto.
        if slashKeys?(event) == true { return }
        // I tasti che INTERROMPONO vanno al processo, non alla scatola di
        // testo. Sua regola del 25/08: la bolla è una variante estetica della
        // riga d'ingresso, quindi quello che nella riga ferma `claude` deve
        // fermarlo anche qui. Prima di questa riga Esc e Ctrl-C morivano
        // dentro la NSTextView (trattava solo 36, 76 e 124), e con la bolla
        // come unico ingresso un agente partito per la tangente non si poteva
        // fermare in nessun modo.
        if let bytes = Self.controlBytes(for: event) {
            onRawKey?(bytes)
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift) {
            fire()
            return
        }
        // → at the end of the text takes the ghost. Only there: in the middle
        // of the text the arrow keeps its ordinary job of moving the caret.
        if event.keyCode == 124, !ghostTail.isEmpty,
           selectedRange().location == (string as NSString).length,
           selectedRange().length == 0 {
            insertText(ghostTail, replacementRange: selectedRange())
            didChangeText()
            return
        }
        super.keyDown(with: event)
    }

    /// A picture in the bubble reads as `[Image #N]`, the way claude's own
    /// input line shows one (his ask, 25/08). The token is what you look at;
    /// the path is what travels, swapped back in by `expanded` on the way out.
    /// A file that is not a picture stays a path: there is no convention for
    /// it to hide behind.
    func insertAttachment(path quoted: String) {
        let bare = quoted.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let pictures: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp", "bmp"]
        guard pictures.contains((bare as NSString).pathExtension.lowercased()) else {
            insertText(quoted + " ", replacementRange: selectedRange())
            return
        }
        let mark = "[Image #\(nextImageNumber)]"
        nextImageNumber += 1
        attachments[mark] = StoredAttachment(body: quoted, isolated: true)
        insertText(mark, replacementRange: selectedRange())
        didChangeText()
    }

    /// A file dragged onto the bubble becomes its path.
    ///
    /// The bubble sends words, so a path is the only shape a file can take
    /// here — the same shape ⌘V gives it (his report, 2026-08-24).
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        DroppedItems.paths(from: sender.draggingPasteboard).isEmpty
            ? super.draggingEntered(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let paths = DroppedItems.paths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return super.performDragOperation(sender) }
        for path in paths { insertAttachment(path: path) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        onResign?()
        return super.resignFirstResponder()
    }

    override func didChangeText() {
        super.didChangeText()
        // The list hears about the new text FIRST, because whether it opens is
        // what decides the ghost below. Worked out the other way round the
        // ghost would be drawn for the frame between the two.
        onTextChange?()
        if string.isEmpty || listaAperta {
            ghostTail = ""
        } else if let whole = suggest?(string), whole.hasPrefix(string), whole != string {
            ghostTail = String(whole.dropFirst(string.count))
        } else {
            ghostTail = ""
        }
        needsDisplay = true
        invalidateIntrinsicContentSize()
        let height = usedHeight
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onSizeChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !ghostTail.isEmpty, !string.isEmpty,
           let manager = layoutManager, let container = textContainer {
            let glyphs = manager.glyphRange(for: container)
            if glyphs.length > 0 {
                let last = manager.boundingRect(
                    forGlyphRange: NSRange(location: glyphs.upperBound - 1, length: 1),
                    in: container)
                let origin = textContainerOrigin
                NSAttributedString(string: ghostTail, attributes: [
                    .font: font ?? Theme.monoFont(12),
                    .foregroundColor: Theme.current.whisper,
                ]).draw(at: NSPoint(x: last.maxX + origin.x, y: last.minY + origin.y))
            }
        }
        guard string.isEmpty, !placeholder.isEmpty else { return }
        NSAttributedString(string: placeholder, attributes: [
            .font: font ?? Theme.monoFont(12),
            .foregroundColor: Theme.current.whisper,
        ]).draw(at: NSPoint(x: 0, y: 0))
    }
}
