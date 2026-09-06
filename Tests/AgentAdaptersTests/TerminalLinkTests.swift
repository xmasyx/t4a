import XCTest
import TerminalCore

final class TerminalLinkTests: XCTestCase {
    private func line(_ text: String, wrapped: Bool = false) -> GridLine {
        GridLine(cells: text.map { GridCell(text: $0) }, isWrapped: wrapped)
    }

    private func column(of needle: Character, occurrence: Int = 0,
                        in text: String) -> Int {
        text.enumerated().filter { $0.element == needle }[occurrence].offset
    }

    private func detect(_ text: String, column: Int,
                        existing: [String: TerminalLinkKind]) -> TerminalLinkMatch? {
        TerminalLinkDetector.detect(
            in: [line(text)], hovered: GridPosition(column: column, row: 0),
            homeDirectory: "/Users/example", inspectPath: { existing[$0] })
    }

    func testQuotedPathKeepsSpacesAndDropsQuotes() {
        let text = "open \"/tmp/My File.txt\" now"
        let result = detect(text, column: column(of: "F", in: text),
                            existing: ["/tmp/My File.txt": .file])

        XCTAssertEqual(result?.link,
                       TerminalLink(text: "/tmp/My File.txt", target: "/tmp/My File.txt",
                                    kind: .file))
        XCTAssertEqual(result?.span.start.column, 6)
        XCTAssertEqual(result?.span.end.column, 22)
    }

    func testEscapedSpaceBecomesFilesystemSpace() {
        let text = "cat /tmp/My\\ File.txt"
        let result = detect(text, column: column(of: "M", in: text),
                            existing: ["/tmp/My File.txt": .file])

        XCTAssertEqual(result?.link.text, "/tmp/My\\ File.txt")
        XCTAssertEqual(result?.link.target, "/tmp/My File.txt")
        XCTAssertEqual(result?.link.kind, .file)
    }

    func testTildeExpandsBeforeInspection() {
        let text = "open ~/Documents/note.md"
        let result = detect(text, column: column(of: "D", in: text),
                            existing: ["/Users/example/Documents/note.md": .file])

        XCTAssertEqual(result?.link.text, "~/Documents/note.md")
        XCTAssertEqual(result?.link.target, "/Users/example/Documents/note.md")
    }

    func testURLKeepsQueryAndDropsOnlyUnmatchedFinalParenthesis() {
        let text = "see (https://example.com/a(b)?x=1&y=two)) now"
        let result = detect(text, column: column(of: "x", in: text), existing: [:])

        XCTAssertEqual(result?.link,
                       TerminalLink(text: "https://example.com/a(b)?x=1&y=two",
                                    target: "https://example.com/a(b)?x=1&y=two",
                                    kind: .url))
    }

    /// Come stampa claude: relativo alla cartella del processo, col numero di riga.
    private func detectInProject(_ text: String, column: Int,
                                 existing: [String: TerminalLinkKind]) -> TerminalLinkMatch? {
        TerminalLinkDetector.detect(
            in: [line(text)], hovered: GridPosition(column: column, row: 0),
            homeDirectory: "/Users/example", workingDirectory: "/Users/example/proj",
            inspectPath: { existing[$0] })
    }

    func testRelativePathResolvesAgainstTheWorkingDirectory() {
        let text = "edited Sources/T4A/PaneView.swift today"
        let result = detectInProject(text, column: column(of: "V", in: text),
                                     existing: ["/Users/example/proj/Sources/T4A/PaneView.swift": .file])
        XCTAssertEqual(result?.link.text, "Sources/T4A/PaneView.swift")
        XCTAssertEqual(result?.link.target, "/Users/example/proj/Sources/T4A/PaneView.swift")
        XCTAssertEqual(result?.span.start.column, 7)
        XCTAssertEqual(result?.span.end.column, 7 + "Sources/T4A/PaneView.swift".count)
    }

    func testLineAndColumnSuffixStayInTheTextButNotInTheTarget() {
        let text = "see Sources/T4A/PaneView.swift:123:7 here"
        let result = detectInProject(text, column: column(of: "V", in: text),
                                     existing: ["/Users/example/proj/Sources/T4A/PaneView.swift": .file])
        XCTAssertEqual(result?.link.text, "Sources/T4A/PaneView.swift:123:7")
        XCTAssertEqual(result?.link.target, "/Users/example/proj/Sources/T4A/PaneView.swift")
        XCTAssertEqual(result?.link.line, 123)
    }

    func testTrailingProsePunctuationIsNotPartOfThePath() {
        let text = "wrote /tmp/note.md, then /tmp/other.md."
        let first = detectInProject(text, column: column(of: "n", occurrence: 0, in: text),
                                    existing: ["/tmp/note.md": .file, "/tmp/other.md": .file])
        XCTAssertEqual(first?.link.text, "/tmp/note.md")
        let second = detectInProject(text, column: column(of: "h", occurrence: 1, in: text),
                                     existing: ["/tmp/note.md": .file, "/tmp/other.md": .file])
        XCTAssertEqual(second?.link.text, "/tmp/other.md")
        XCTAssertEqual(second?.span.end.column, text.count - 1)
    }

    func testPathInsideToolCallParenthesesIsALink() {
        let text = "Update(Sources/T4A/PaneView.swift)"
        let result = detectInProject(text, column: column(of: "V", in: text),
                                     existing: ["/Users/example/proj/Sources/T4A/PaneView.swift": .file])
        XCTAssertEqual(result?.link.text, "Sources/T4A/PaneView.swift")
        XCTAssertEqual(result?.span.start.column, 7)
        XCTAssertEqual(result?.span.end.column, text.count - 1)
    }

    func testAbsolutePathWithLineSuffixStillResolvesWithoutWorkingDirectory() {
        let text = "at /tmp/a.swift:9"
        let result = detect(text, column: 8, existing: ["/tmp/a.swift": .file])
        XCTAssertEqual(result?.link.target, "/tmp/a.swift")
        XCTAssertEqual(result?.link.line, 9)
    }

    func testBareWordsAndDotsNeverBecomeRelativeLinks() {
        // `.` e `..` esistono sempre: senza questa guardia ogni punto sarebbe un link.
        XCTAssertNil(detectInProject("cd . now", column: 3,
                                     existing: ["/Users/example/proj": .directory]))
        XCTAssertNil(detectInProject("cd .. now", column: 3,
                                     existing: ["/Users/example": .directory]))
        XCTAssertNil(detectInProject("plain words here", column: 7, existing: [:]))
    }

    func testOrdinaryTextIsNotALink() {
        XCTAssertNil(detect("nothing to open here", column: 3, existing: [:]))
    }

    func testMissingAbsolutePathIsNotALink() {
        XCTAssertNil(detect("/tmp/does-not-exist", column: 8, existing: [:]))
    }

    func testSoftWrappedPathReturnsOneSpanAcrossBothRows() {
        let first = "/tmp/a-very-long-"
        let second = "filename.txt"
        let target = first + second
        let result = TerminalLinkDetector.detect(
            in: [line(first), line(second, wrapped: true)],
            hovered: GridPosition(column: 4, row: 1),
            homeDirectory: "/Users/example",
            inspectPath: { $0 == target ? .file : nil })

        XCTAssertEqual(result?.link.target, target)
        XCTAssertEqual(result?.span.start, GridPosition(column: 0, row: 0))
        XCTAssertEqual(result?.span.end, GridPosition(column: second.count, row: 1))
    }

    /// bench-link L5: the shell echoes the path QUOTED and the grid wraps it,
    /// so the opening quote sits on the first row and the closing one on the
    /// second, with the pointer over the tail. Both mechanisms at once.
    func testQuotedSoftWrappedPathIsOneLinkFromItsTail() {
        let dir = "/tmp/t4a-link-long/" + String(repeating: "a", count: 60)
            + "/" + String(repeating: "b", count: 60)
            + "/" + String(repeating: "c", count: 60)
        let target = dir + "/wrapped-target.txt"
        let printed = "\"" + target + "\""
        let width = 117
        let first = String(printed.prefix(width))
        let second = String(printed.dropFirst(width)) + String(repeating: " ", count: 12)
        let result = TerminalLinkDetector.detect(
            in: [line(first), line(second, wrapped: true)],
            hovered: GridPosition(column: 89, row: 1),
            homeDirectory: "/Users/example",
            workingDirectory: "/Users/example",
            inspectPath: { $0 == target ? .file : nil })

        XCTAssertEqual(result?.link.target, target)
        XCTAssertEqual(result?.span.start, GridPosition(column: 1, row: 0))
        XCTAssertEqual(result?.span.end, GridPosition(column: 104, row: 1))
    }

    func testExistingDirectoryHasItsOwnOpeningKind() {
        let result = detect("cd /tmp/folder", column: 9,
                            existing: ["/tmp/folder": .directory])
        XCTAssertEqual(result?.link.kind, .directory)
    }

    func testCursorTraceMakesTheLiveHoverAndBalancedReleaseMeasurable() {
        var state = TerminalLinkCursorState()

        XCTAssertEqual(state.setHover(active: true, at: 10), .push)
        XCTAssertEqual(state.setHover(active: true, at: 11), .none)
        for timestamp in 12..<112 {
            XCTAssertEqual(state.setHover(active: true, at: TimeInterval(timestamp)), .none)
        }
        XCTAssertEqual(state.handle(.mouseMoved, at: 112),
                       TerminalLinkCursorEventAction(reassertPointingHand: true,
                                                     consume: false))
        XCTAssertEqual(state.handle(.cursorUpdate, at: 113),
                       TerminalLinkCursorEventAction(reassertPointingHand: true,
                                                     consume: true))

        XCTAssertTrue(state.stackHeld)
        XCTAssertEqual(state.trace.pushes, 1)
        XCTAssertEqual(state.trace.pops, 0)
        XCTAssertEqual(state.trace.pointingHandSets, 2)
        XCTAssertEqual(state.trace.cursorUpdatesConsumed, 1)
        XCTAssertEqual(state.trace.lastTransition,
                       .init(kind: "cursorUpdate:setPointingHand+consumed", timestamp: 113))

        XCTAssertEqual(state.setHover(active: false, at: 114), .pop)
        XCTAssertEqual(state.setHover(active: false, at: 115), .none)
        XCTAssertFalse(state.stackHeld)
        XCTAssertEqual(state.trace.pushes, 1)
        XCTAssertEqual(state.trace.pops, 1)
        XCTAssertEqual(state.trace.lastTransition, .init(kind: "pop", timestamp: 114))
    }
}
