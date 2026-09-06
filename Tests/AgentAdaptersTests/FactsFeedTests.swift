//  FactsFeedTests.swift — the contract a facts provider is held to (ISC-139).
//
//  These are here rather than beside the bar because the parser is the half of
//  the feature that has no window in it, and a contract with an outside
//  program is the half most worth pinning down: the provider is somebody
//  else's code, and every line it can send that we did not think about is a
//  line that has to land somewhere harmless.
//
//  The tests that matter most are the refusals. A key is written verbatim into
//  `dash-slots`, where `:` `,` and `|` are the punctuation of the file, so a
//  provider sending `left-1:x` as a key would corrupt the saved layout of the
//  whole bar — and it would do it quietly, on somebody else's next launch.

import Testing
import TerminalCore

@Test func readsOneReadingPerLine() {
    let reading = FactsFeed.parse("context\t7%\nmodel\tOpus 5\twarn\n")
    #expect(reading.rows.count == 2)
    #expect(reading.row("context")?.tokens == [FactToken(text: "7%")])
    #expect(reading.row("model")?.tokens == [FactToken(text: "Opus 5", tone: .warn)])
    #expect(reading.problems.isEmpty)
}

@Test func repeatingAKeyAppendsTokensEachWithItsOwnTone() {
    // This is the ladder, and it is the whole reason the format is not one
    // line per cell: one reading, eight words, three colours.
    let reading = FactsFeed.parse("""
    active\tHAIKU\tdim
    active\tSONNET\tdim
    active\tOPUS\tlive
    active\tFABLE\tused
    """)
    let row = reading.row("active")
    #expect(reading.rows.count == 1)
    #expect(row?.tokens.map(\.text) == ["HAIKU", "SONNET", "OPUS", "FABLE"])
    #expect(row?.tokens.map { $0.tone?.rawValue } == ["dim", "dim", "live", "used"])
    #expect(row?.text == "HAIKU SONNET OPUS FABLE")
}

@Test func nameGivesTheRowAHumanLabelWhicheverSideOfItArrives() {
    let after = FactsFeed.parse("usage\t5HR 5%\n#name\tusage\tToken budget\n")
    #expect(after.row("usage")?.label == "Token budget")
    let before = FactsFeed.parse("#name\tusage\tToken budget\nusage\t5HR 5%\n")
    #expect(before.row("usage")?.label == "Token budget")
    // An empty label is a provider saying "this reading speaks for itself".
    // It is not the same as never naming the row, and the two must not
    // collapse into one another.
    let bare = FactsFeed.parse("#name\tusage\t\nusage\t5HR 5%\n")
    #expect(bare.row("usage")?.label == "")
    let unnamed = FactsFeed.parse("usage\t5HR 5%\n")
    #expect(unnamed.row("usage")?.label == nil)
}

@Test func refusesAKeyThatWouldCorruptTheSavedLayout() {
    for bad in ["left-1:x", "a,b", "a|b", "", "-lead", "a b",
                String(repeating: "k", count: 33)] {
        #expect(!FactsFeed.isValidKey(bad), "\(bad) should not be a key")
    }
    for good in ["usage", "five-hour", "ctx_2", "A9"] {
        #expect(FactsFeed.isValidKey(good), "\(good) should be a key")
    }
    let reading = FactsFeed.parse("left-1:x\tboom\ncontext\t7%\n")
    #expect(reading.rows.map(\.key) == ["context"])
    #expect(reading.problems.count == 1)
}

@Test func aLineItCannotReadIsSaidOutLoudRatherThanShown() {
    let reading = FactsFeed.parse("no-tab-here\ncontext\t7%\tmagenta\n# a comment\n")
    #expect(reading.rows.map(\.key) == ["context"])
    // The token survives; only the tone it asked for is refused, because the
    // reading is still true and only its colour was nonsense.
    #expect(reading.row("context")?.tokens == [FactToken(text: "7%", tone: nil)])
    #expect(reading.problems.count == 2)
}

@Test func emptyOutputIsNoRowsAndNoComplaint() {
    let reading = FactsFeed.parse("\n  \n")
    #expect(reading.rows.isEmpty)
    #expect(reading.problems.isEmpty)
}

@Test func clippingKeepsTheColoursOfWhatSurvives() {
    let tokens = [FactToken(text: "5HR", tone: .used), FactToken(text: "86%", tone: .critical),
                  FactToken(text: "↻SUN@2300", tone: .dim)]
    let full = FactsFeed.clip(tokens, to: 100)
    #expect(full == tokens)

    let cut = FactsFeed.clip(tokens, to: 12)
    #expect(cut.map(\.text).joined(separator: " ").count <= 12)
    #expect(cut.first?.tone == .used)
    #expect(cut.last?.text.hasSuffix("…") == true)
    // Whatever is left keeps the tone it had: in a coloured reading the
    // colour IS the reading, so a truncation that greyed the survivors would
    // change what the row says.
    #expect(cut.allSatisfy { $0.tone != nil })

    // A cut too small for even the first word still leaves something to see.
    let stump = FactsFeed.clip(tokens, to: 1)
    #expect(stump.count == 1)
    #expect(!stump[0].text.isEmpty)
}
