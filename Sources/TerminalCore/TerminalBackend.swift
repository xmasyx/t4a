//  TerminalBackend.swift — the write side and the event stream.
//
//  Everything above this protocol (tabs, splits, blocks, notifications, the
//  agent adapter of F4) is written against these types. Exactly one target in
//  this package imports a VT library, and it is not this one.

import AppKit
import Foundation

/// What a terminal tells the app about itself. Rows are scroll-invariant.
public enum TerminalEvent: Sendable {
    /// The program set the window/tab title (OSC 0/1/2).
    case title(String)
    /// The shell reported its working directory (OSC 7).
    case workingDirectory(URL)
    case bell
    /// OSC 9 or OSC 777: the program asked the desktop to say something.
    case notification(title: String, body: String)
    /// OSC 133;A — a prompt was drawn at this row.
    case promptStarted(row: Int)
    /// OSC 133;C — the command the user typed began producing output.
    case commandStarted(row: Int, command: String)
    /// The shell named the command line (OSC 633 `E`). It can arrive on either
    /// side of `C`: fish emits its own `C` before the pre-exec hook runs, so a
    /// command line that only ever applied forwards would always be lost.
    case commandLineAnnounced(String)
    /// OSC 133;D — the command finished. `exitCode` is nil when the shell
    /// did not report one.
    case commandFinished(row: Int, exitCode: Int32?)
    /// The child process is gone.
    case processExited(code: Int32?)
    case sizeChanged(columns: Int, rows: Int)
    /// Bytes arrived from the child. Carries no payload: it exists so the app
    /// can wake, and so ISC-38 can prove waking is the only thing that
    /// happens when the terminal is quiet.
    case outputArrived
}

public struct TerminalLaunch {
    /// Absolute path of the program to exec. Empty means "the login shell".
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL
    /// Variables added to the child's environment. T4A never edits the user's
    /// shell rc files (ISC-16); everything it needs to inject rides here.
    public var environment: [String: String]
    /// argv[0] for the child. Nil means the POSIX login form, `-name`, which
    /// is what makes a shell read the user's profile. A shell whose
    /// integration loads by another route sets this to plain `name` and reads
    /// the profile itself.
    public var argv0: String?

    public init(executable: String, arguments: [String] = [],
                workingDirectory: URL, environment: [String: String] = [:],
                argv0: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.argv0 = argv0
    }
}

/// One process in a pane's foreground tree: just enough to recognise it.
public struct ForegroundProcess: Sendable {
    public let pid: Int32
    public let name: String
    /// The argv the process was started with, joined. The name alone cannot
    /// recognise claude: the binary is versioned, so the kernel calls the
    /// process `2.1.243` — but argv[0] still says `claude` (measured 25/08).
    public let commandLine: String
    public init(pid: Int32, name: String, commandLine: String = "") {
        self.pid = pid
        self.name = name
        self.commandLine = commandLine
    }
}

/// The link currently armed by Command-hover. Rectangles use the terminal
/// surface's local coordinates and contain one entry per visible wrapped row.
public struct TerminalLinkHover: Equatable, Sendable {
    public let link: TerminalLink
    public let span: GridSpan
    public let rects: [CGRect]

    public init(link: TerminalLink, span: GridSpan, rects: [CGRect]) {
        self.link = link
        self.span = span
        self.rects = rects
    }
}

/// A live terminal: a child process, a grid, and a stream of events.
@MainActor
public protocol TerminalBackend: AnyObject {
    /// The drawing surface. Today it is a CPU renderer; in F3 a Metal view
    /// takes its place, and no caller changes, because no caller asks what
    /// kind of view this is.
    var surface: NSView { get }

    var grid: TerminalGrid { get }

    /// The height of one row, as the engine actually lays it out. Read from
    /// the engine rather than recomputed from the font: a second derivation
    /// of a number the engine already holds exactly is how overlays end up a
    /// pixel off the text they annotate. Height only, deliberately — width is
    /// the one the engine reports with its scroller reserve folded in, and a
    /// number that is nearly right is worse than one that is absent.
    var cellHeight: CGFloat { get }

    /// Called on the main thread for every event.
    var onEvent: ((TerminalEvent) -> Void)? { get set }

    func start(_ launch: TerminalLaunch)
    func send(text: String)
    func send(bytes: [UInt8])

    /// True when the program on the other side has turned bracketed paste on
    /// (DECSET 2004). Read from the engine, never assumed: the markers are
    /// literal characters to a program that did not ask for them.
    var acceptsBracketedPaste: Bool { get }

    /// Puts a whole message into the child as one or more paste objects, then
    /// Return.
    ///
    /// Not `send(text:)` with a newline after it, and the difference is the
    /// whole of ISC-166: keystrokes reach the child in tty-sized pieces and a
    /// TUI that keeps one of them keeps only the tail of a long message. See
    /// `PasteFraming` for the measurement. `submitAfter` is the gap before the
    /// Return — nil sends none — and it is honoured AFTER the last byte of the
    /// message has left, so the two can never interleave.
    func compose(payloads: [String], submitAfter: TimeInterval?)

    /// Nil until the child exits.
    var exitCode: Int32? { get }

    /// The child's current working directory, when it can be read.
    func currentWorkingDirectory() -> URL?
    /// The name of the foreground program in the child's terminal group.
    func foregroundProcessName() -> String?

    /// The working directory of the FOREGROUND process, from the kernel.
    /// `currentWorkingDirectory()` answers for the shell; an agent that was
    /// started with `cd somewhere && agent` lives somewhere the shell's OSC 7
    /// has not caught up with yet.
    func foregroundWorkingDirectory() -> URL?

    /// The foreground process group as a small tree: the leader first, then
    /// its descendants, a couple of levels deep. The launcher case is the
    /// reason it exists — `lifeos` is an alias for `bun lifeos.ts`, so the
    /// leader is `bun` and the claude the pane is really running is a CHILD;
    /// an attach that only looks at the leader never fires (his report,
    /// 25/08: every session opened through the launcher had no turn map and
    /// dead indicators, while a bare `claude` worked).
    func foregroundProcesses() -> [ForegroundProcess]

    /// The kernel's working directory for one process of the tree above.
    func workingDirectory(ofProcess pid: Int32) -> URL?

    /// Whatever the backend can say about its own health, for diagnosis and
    /// for the tests. Free-form on purpose: a different engine reports
    /// different things, and the app only ever prints them.
    var diagnostics: [String: String] { get }

    /// The leader of the child's foreground process group, when readable.
    var foregroundProcessID: Int32? { get }

    var selectedText: String? { get }
    func selectAll()

    /// La selezione col MOUSE è appena finita e non è vuota (ISC-197).
    ///
    /// Solo il mouse: `selectAll` e le selezioni fatte dal canale non passano
    /// di qui, perché copiare gli appunti di qualcuno per un ⌘A sarebbe un
    /// effetto che nessuno ha chiesto. Il testo viaggia già estratto e il
    /// backend non sa che esistano gli appunti: chi riceve decide.
    var onSelectionFinished: ((String) -> Void)? { get set }

    /// Takes what a drag is carrying and puts it where the pane can use it.
    /// Split from AppKit's `performDragOperation` so a bench can hand it a
    /// pasteboard: what a drop DOES is testable, what AppKit does with a mouse
    /// is not.
    /// Chi ha davvero la riga d'ingresso si prende quello che cade sul
    /// pannello. Torna `true` se se l'è preso; con `false`, o senza nessuno
    /// in ascolto, i percorsi finiscono nel pty come prima — che è il caso
    /// della shell senza agente (suo, 27/08: «trascinato nella bolla o sullo
    /// schermo, deve finire nella riga di testo»).
    var onDropPaths: (([String]) -> Bool)? { get set }

    /// Nil whenever Command is not held. Opening is handed upwards so AppKit's
    /// workspace call can be replaced by the test-channel spy.
    var linkHover: TerminalLinkHover? { get }
    var linkCursorTrace: TerminalLinkCursorTrace { get }
    var onOpenLink: ((TerminalLink) -> Void)? { get set }

    @discardableResult
    func acceptDrop(from board: NSPasteboard) -> Bool

    /// The dragged types the pane really registered, for the bench: a drop
    /// handler nobody registered for is never called, and from outside that
    /// is indistinguishable from a handler that does nothing.
    var registeredDropTypes: [String] { get }
    func clearSelection()

    /// Lines of scrollback retained on top of the visible screen.
    var scrollbackLimit: Int { get set }

    /// The cell font. Setting it re-lays the grid out and tells the child its
    /// new size, which is what ⌘+ and ⌘- do (ISC-110).
    var font: NSFont { get set }

    /// Throws away the screen and the retained scrollback, the way ⌘K does in
    /// every other Mac terminal. The child process is not touched: the buffer
    /// is ours, the program is not.
    func clearBuffer()

    /// The renderer drawing this pane, when there is one to talk to.
    var renderer: TerminalRenderer? { get }

    /// The colours this terminal resolves its cells to. Read from the engine,
    /// so every renderer draws the same blue.
    var palette: TerminalPalette { get }

    /// Hands the app's theme to the grid (ISC-33).
    ///
    /// The theme owns the ground, the ink, the cursor and the selection —
    /// a window whose chrome changed colour and whose terminal did not is a
    /// window with two themes in it. The sixteen ANSI colours stay the
    /// engine's unless the theme names its own.
    func applyTheme(_ theme: TerminalTheme)

    /// Folds runs of HISTORY rows away. The backend clips them against its own
    /// live screen and makes sure the viewport is not left standing inside
    /// one, which is the half a renderer cannot do for itself.
    func setFolds(_ ranges: [ClosedRange<Int>])

    /// The folds actually in force, after the backend clipped them against
    /// its own live screen. Read rather than remembered by the caller: the
    /// overlay has to draw its labels on the SAME rows the renderer skipped,
    /// and a second derivation of that number is how an overlay ends up a row
    /// off the thing it annotates.
    var folds: RowFold { get }

    /// Moves the viewport by whole lines: positive scrolls towards the
    /// scrollback, negative towards the live screen.
    func scroll(lines: Int)

    /// Brings a scroll-invariant row into view.
    func reveal(row: Int)

    func focus()
    /// Free the child and every OS resource it holds.
    func terminate()
}

public extension TerminalBackend {
    /// The ordinary one-object spelling used everywhere except isolated
    /// composer attachments.
    func compose(text: String, submitAfter: TimeInterval?) {
        compose(payloads: [text], submitAfter: submitAfter)
    }
}
