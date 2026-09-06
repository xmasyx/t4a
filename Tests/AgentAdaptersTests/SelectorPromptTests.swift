//  SelectorPromptTests.swift — the permission scanner, against screens taken
//  out of the running app.
//
//  Both fixtures below were dumped from a live T4A pane with
//  `Scripts/drive.sh dump` while a real `claude` session held the question
//  open. They are photographs of the terminal, which is the only kind of
//  fixture worth having here: a screen invented by the person writing the
//  parser tests the parser against itself.
//
//  The home directory, the machine name, and anything a private system printed
//  into the transcript are replaced with placeholders: a fixture is a
//  photograph of a screen, and this repo is public, so the photograph gets the
//  same treatment a screenshot would (ISC-1). The SHAPE — the box, the
//  markers, the numbering, the footer — is untouched, which is the only part
//  any of these tests reads.
//
//  ONE thing the dumps did not record and these fixtures have to supply: where
//  the caret was. The scanner requires it inside the question (ISC-127), so
//  `asked` below puts it on the option carrying the selection marker, which is
//  where a live measurement found it — claude's trust question on 2026-08-22
//  read `box rows 3..17, caret 14`, and 14 is the marked option's row. It is
//  reconstruction, and it is written down as reconstruction rather than left
//  to look like part of the photograph.

import Testing
import TerminalCore
@testable import AgentAdapters

/// The workspace-trust question, captured 2026-08-20 (alternate screen off).
let trustScreen: [String] = [
        "you@mac ~ % cd /tmp/t4a-perm && claude --permission-mode default",
        "",
        "Resume this session with:",
        "claude --resume e8bc000f-d80b-4842-82ba-136d6bfe762c",
        "you@mac t4a-perm % cd /tmp/t4a-trust-20968 && claude --permission-mode defaul",
        "t",
        "",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────",
        " Accessing workspace:",
        "",
        " /private/tmp/t4a-trust-20968",
        "",
        " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known",
        " open source project, or work from your team). If not, take a moment to review what's in this folder",
        " first.",
        "",
        " Claude Code'll be able to read, edit, and execute files here.",
        "",
        " Security guide",
        "",
        " ❯ 1. Yes, I trust this folder",
        "   2. No, exit",
        "",
        " Enter to confirm · Esc to cancel",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
]

/// The Bash-command permission, captured 2026-08-20 (alternate screen ON).
let permissionScreen: [String] = [
        "│               Welcome back!                       │ Run /init to create a CLAUDE.md file with inst… │",
        "│                                                    │ ─────────────────────────────────────────────── │",
        "│                       ▐▛███▛█                      │ What's new                                      │",
        "│                      ▝▜██████▀                     │ Fixed prompt caching for sessions using an LLM… │",
        "│                        ▝▝ ▝▝                       │ Added a built-in \"Concise\" output style: Claud… │",
        "│   Opus 5 (1M context) with high… · Claude Max ·    │ Added `ANTHROPIC_DEFAULT_MODEL` environment va… │",
        "│   you@example.com's Organization    │ /release-notes for more                         │",
        "│               /private/tmp/t4a-perm                │                                                 │",
        "╰──────────────────────────────────────────────────────────────────────────────────────────────────────╯",
        "",
        " ⚠ 1 MCP server needs authentication · run /mcp",
        "",
        "❯ elenca i file qui con Bash ls, poi dimmi quanti sono",
        "",
        "  Listed 1 directory",
        "",
        "⏺ ════ Notebook ═════════════════════════",
        "",
        "  Due file: prova.txt e tee.txt.",
        "",
        "  🗣️ Ada: Cartella quasi vuota, solo quei due.",
        "",
        "✻ Crunched for 8s",
        "",
        "❯ esegui con Bash: sw_vers -productVersion",
        "",
        "  Showing macOS product version",
        "  ⎿  $ sw_vers -productVersion",
        "",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────",
        " Bash command",
        "",
        "   sw_vers -productVersion",
        "   Show macOS product version",
        "",
        " This command requires approval",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don’t ask again for: sw_vers *",
        "   3. No",
        "",
        " Esc to cancel · Tab to amend · ctrl+e to explain",
]

/// claude 2.1.250's «Switch model?» confirmation, captured 2026-08-28 on the
/// alternate screen after choosing a model in `/model` (184 columns, 41 rows).
/// It has NO footer line: the yes/no pair is the only proof it is a question.
/// The caret on the marked option is a reconstruction; the live cursor was on
/// row 38, the `❯ 1.` row.
let switchModelScreen: [String] = [
    "",
    " ▐▛███▛█   Claude Code v2.1.250",
    "▝▜██████▀  Fable 5 with high effort · Claude Max",
    "  ▝▝ ▝▝    ~/Movies/t4a-bench",
    "",
    "⚠ 1 MCP server needs authentication · run /mcp",
    "",
    "❯ prova",
    "",
    "⏺ 📋 Prova ricevuta",
    "",
    "  Ti sento. Sono qui nella chat t4a-bench, contesto caricato, nessun lavoro in corso. Dimmi cosa vuoi fare e partiamo.",
    "",
    "  🗣️ Prova riuscita, sono pronto.",
    "",
    "✻ Cooked for 7s · done 12:54",
    "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    String(repeating: "▔", count: 184),
    "   Switch model?",
    "   Your next response will be slower and use more tokens",
    "",
    "   This conversation is cached for the current model. Switching to Sonnet 5 means the full history gets re-read on your next message.",
    "",
    "   ❯ 1. Yes, switch to Sonnet 5",
    "     2. No, go back",
    "",
]

/// An ordinary screen with a numbered list in it and nobody being asked
/// anything: the negative pole. Without it a scanner that raised a card over
/// every list would pass every test above.
let innocentScreen: [String] = [
    "you@mac ~ % cat README.md",
    "Install:",
    " 1. clone the repo",
    " 2. run bun install",
    " 3. press Enter to confirm nothing",
    "",
    "you@mac ~ % ",
]

/// A captured screen with the caret where a live one puts it: on the option
/// carrying the marker. The marker line is found the way the scanner finds an
/// option, so a fixture whose numbering changes cannot silently keep an
/// out-of-date caret.
@MainActor
func asked(_ screen: [String], alternate: Bool = false) -> FakeGrid {
    let grid = FakeGrid(screen, alternate: alternate)
    let marked = screen.lastIndex { line in
        guard line.contains("❯") || line.contains("›") || line.contains("▶") else { return false }
        var text = line
        for marker in ["❯", "›", "▶"] { text = text.replacingOccurrences(of: marker, with: " ") }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let dot = trimmed.firstIndex(of: "."), dot > trimmed.startIndex else { return false }
        return Int(trimmed[trimmed.startIndex..<dot]) != nil
    }
    if let marked { grid.cursorRow = marked }
    return grid
}

@MainActor
@Test func findsTheTrustQuestion() {
    let prompt = SelectorScanner.scan(asked(trustScreen))
    #expect(prompt != nil)
    #expect(prompt?.options.count == 2)
    #expect(prompt?.options.first?.label.hasPrefix("Yes") == true)
    #expect(prompt?.options.first?.isCurrent == true)
}

@MainActor
@Test func findsThePermissionOnTheAlternateScreen() {
    let prompt = SelectorScanner.scan(asked(permissionScreen, alternate: true))
    #expect(prompt != nil)
    #expect(prompt?.title == "Bash command")
    #expect(prompt?.options.count == 3)
    #expect(prompt?.options.last?.label == "No")
    #expect(prompt?.detail.contains("sw_vers -productVersion") == true)
    let answers = SelectorScanner.answers(for: prompt!)
    #expect(answers.approve.keystrokes == "1\r")
    #expect(answers.deny.keystrokes == "3\r")
}

@MainActor
@Test func ignoresANumberedListNobodyIsAsking() {
    #expect(SelectorScanner.scan(FakeGrid(innocentScreen)) == nil)
}

@MainActor
@Test func findsTheSwitchModelConfirmationWithoutFooter() {
    #expect(switchModelScreen.count == 41)
    let prompt = SelectorScanner.scan(asked(switchModelScreen, alternate: true))
    #expect(prompt != nil)
    #expect(prompt?.kind == .permission)
    #expect(prompt?.decision.yes?.number == 1)
    #expect(prompt?.decision.no?.number == 2)
    #expect(prompt?.footer == "")
    #expect(prompt?.title == "Switch model?")
    if let prompt {
        let answers = SelectorScanner.answers(for: prompt)
        #expect(answers.approve.keystrokes == "1\r")
        #expect(answers.deny.keystrokes == "2\r")
        let lastOptionRow = switchModelScreen.firstIndex { $0.contains("2. No, go back") }
        #expect(prompt.lastRow == lastOptionRow)
    }
}

@MainActor
@Test func ignoresTheSameScreenWithoutAMarker() {
    var screen = switchModelScreen
    screen[38] = screen[38].replacingOccurrences(of: "❯", with: " ")
    #expect(SelectorScanner.scan(asked(screen, alternate: true)) == nil)
}

@MainActor
@Test func ignoresAMarkedMenuWithoutFooter() {
    var screen = switchModelScreen
    screen[38] = "   ❯ 1. Sonnet"
    screen[39] = "     2. Haiku"
    #expect(SelectorScanner.scan(asked(screen, alternate: true)) == nil)
}

/// Codex's own trust question, captured from a live pane 2026-08-20. A
/// different selection marker, a different footer ("Press enter to continue"),
/// a different vendor, and the same shape — which is the claim ISC-31 makes.
/// Home paths and the shell prompt in these captures are sanitised; nothing the
/// scanner reads depends on them.
let codexTrustScreen: [String] = [
        ">\u{0020}You\u{0020}are\u{0020}in\u{0020}~/Movies/t4a-4918/w",
        "",
        "\u{0020}\u{0020}Do\u{0020}you\u{0020}trust\u{0020}the\u{0020}contents\u{0020}of\u{0020}this\u{0020}directory?\u{0020}Working\u{0020}with\u{0020}untrusted\u{0020}contents\u{0020}comes\u{0020}with\u{0020}higher\u{0020}risk\u{0020}of",
        "\u{0020}\u{0020}prompt\u{0020}injection.\u{0020}Trusting\u{0020}the\u{0020}directory\u{0020}allows\u{0020}project-local\u{0020}config,\u{0020}hooks,\u{0020}and\u{0020}exec\u{0020}policies\u{0020}to",
        "\u{0020}\u{0020}load.",
        "",
        "›\u{0020}1.\u{0020}Yes,\u{0020}continue",
        "\u{0020}\u{0020}2.\u{0020}No,\u{0020}quit",
        "",
        "\u{0020}\u{0020}Press\u{0020}enter\u{0020}to\u{0020}continue",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
]

@MainActor
@Test func findsTheOtherVendorsQuestion() {
    let prompt = SelectorScanner.scan(asked(codexTrustScreen))
    #expect(prompt != nil)
    #expect(prompt?.options.count == 2)
    #expect(prompt?.options.first?.isCurrent == true)
    let answers = SelectorScanner.answers(for: prompt!)
    #expect(answers.approve.keystrokes == "1\r")
    #expect(answers.deny.label == "No, quit")
}

/// A REAL tool permission from the second vendor: Codex asking to write a
/// file, with its diff on the screen above. Captured from a live pane on
/// 2026-08-20 with `codex --ask-for-approval untrusted`.
let codexEditApprovalScreen: [String] = [
        "",
        "•\u{0020}Added\u{0020}scritto-da-codex.txt\u{0020}(+1\u{0020}-0)",
        "\u{0020}\u{0020}\u{0020}\u{0020}1\u{0020}+ciao",
        "",
        "•\u{0020}Explored",
        "\u{0020}\u{0020}└\u{0020}Read\u{0020}scritto-da-codex.txt",
        "",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "",
        "•\u{0020}Creato\u{0020}scritto-da-codex.txt\u{0020}con\u{0020}la\u{0020}riga\u{0020}ciao.",
        "",
        "────────────────────────────────────────────────────────────────────────────────────────────────────────",
        "Token\u{0020}usage:\u{0020}total=9997\u{0020}input=9817\u{0020}(+\u{0020}33.024\u{0020}cached)\u{0020}output=180",
        "To\u{0020}continue\u{0020}this\u{0020}session,\u{0020}run\u{0020}codex\u{0020}resume\u{0020}01a02110-912f-7513-8bd2-b1f145d6ebd3",
        "you@mac\u{0020}t4a-bench\u{0020}%\u{0020}cd\u{0020}~/Movies/t4a-bench\u{0020}&&\u{0020}codex\u{0020}--ask-for-a",
        "pproval\u{0020}untrusted\u{0020}--sandbox\u{0020}read-only",
        "╭───────────────────────────────────────────╮",
        "│\u{0020}>_\u{0020}OpenAI\u{0020}Codex\u{0020}(v0.148.0)\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}│",
        "│\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}│",
        "│\u{0020}model:\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}gpt-5.6-sol\u{0020}\u{0020}\u{0020}/model\u{0020}to\u{0020}change\u{0020}│",
        "│\u{0020}directory:\u{0020}~/Movies/t4a-bench\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}\u{0020}│",
        "╰───────────────────────────────────────────╯",
        "",
        "\u{0020}\u{0020}Tip:\u{0020}New\u{0020}Use\u{0020}/fast\u{0020}to\u{0020}enable\u{0020}our\u{0020}fastest\u{0020}inference\u{0020}with\u{0020}increased\u{0020}plan\u{0020}usage.",
        "",
        "",
        "›\u{0020}crea\u{0020}il\u{0020}file\u{0020}permesso-vero.txt\u{0020}con\u{0020}dentro\u{0020}la\u{0020}parola\u{0020}ok",
        "",
        "",
        "•\u{0020}Creo\u{0020}il\u{0020}file\u{0020}richiesto\u{0020}nella\u{0020}cartella\u{0020}di\u{0020}lavoro.",
        "",
        "•\u{0020}Added\u{0020}permesso-vero.txt\u{0020}(+1\u{0020}-0)",
        "\u{0020}\u{0020}\u{0020}\u{0020}1\u{0020}+ok",
        "",
        "",
        "\u{0020}\u{0020}Would\u{0020}you\u{0020}like\u{0020}to\u{0020}make\u{0020}the\u{0020}following\u{0020}edits?",
        "",
        "",
        "›\u{0020}1.\u{0020}Yes,\u{0020}proceed\u{0020}(y)",
        "\u{0020}\u{0020}2.\u{0020}Yes,\u{0020}and\u{0020}don't\u{0020}ask\u{0020}again\u{0020}for\u{0020}these\u{0020}files\u{0020}(a)",
        "\u{0020}\u{0020}3.\u{0020}No,\u{0020}and\u{0020}tell\u{0020}Codex\u{0020}what\u{0020}to\u{0020}do\u{0020}differently\u{0020}(esc)",
        "",
        "\u{0020}\u{0020}Press\u{0020}enter\u{0020}to\u{0020}confirm\u{0020}or\u{0020}esc\u{0020}to\u{0020}cancel",
]

@MainActor
@Test func findsTheOtherVendorsToolPermission() {
    let prompt = SelectorScanner.scan(asked(codexEditApprovalScreen))
    #expect(prompt != nil)
    #expect(prompt?.options.count == 3)
    #expect(prompt?.title == "Would you like to make the following edits?")
    let answers = SelectorScanner.answers(for: prompt!)
    #expect(answers.approve.keystrokes == "1\r")
    #expect(answers.deny.keystrokes == "3\r")
}

/// `/model` on claude 2.1.239, captured from a live T4A pane on 2026-08-22
/// with the app's own `dump`. Five choices that stand beside each other, a
/// marker on the one in force, a footer naming keys — every shape test a
/// permission passes, and nobody is being asked for permission to do
/// anything. This is the screen ISC-122 was opened for: the card used to sit
/// on top of it (design/evidence/f5-114-pure-chat-revealed.png).
///
/// The banner above it is trimmed to what it says, with the working directory
/// replaced: this repo is public and a fixture is a photograph of a screen.
let modelMenuScreen: [String] = [
    " ▐▛███▛█   Claude Code v2.1.239",
    "▝▜██████▀  Opus 5 (1M context) with high effort · Claude Max",
    "  ▝▝ ▝▝    ~/somewhere/T4A",
    " ⚠ 1 MCP server needs authentication · run /mcp",
    "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔",
    "   Select model",
    "   Switch between Claude models. Your pick becomes the default for new sessions.",
    "   specify with --model.",
    "     1. Default (recommended)  Opus 5 with 1M context · Best for everyday, complex tasks",
    "   ❯ 2. Opus (1M context) ✔    Opus 5 with 1M context · Best for everyday, complex tasks",
    "     3. Fable                  Fable 5 · Most capable for your hardest tasks",
    "     4. Sonnet                 Sonnet 5 · Efficient for routine tasks",
    "     5. Haiku                  Haiku 4.5 · Fastest for quick answers",
    "   ● High effort (default) ←/→ to adjust",
    "   Enter to set as default · s to use this session only · Esc to cancel",
]

@MainActor
@Test func aMenuIsStillFoundButIsNotAPermission() {
    // Both halves matter. The scanner must still SEE it — «pure chat» uncovers
    // the input box on anything the scanner recognises, and a menu it cannot
    // see is a menu that stays hidden under a bubble (ISC-114).
    let grid = asked(modelMenuScreen, alternate: true)
    let seen = SelectorScanner.scan(grid)
    #expect(seen != nil)
    #expect(seen?.options.count == 5)
    #expect(seen?.kind == .selector)
    // And the card must not be offered one.
    #expect(SelectorScanner.permission(on: grid) == nil)
}

@MainActor
@Test func everyRealPermissionIsStillAPermission() {
    // The positive pole, on all four photographs: two vendors, a trust
    // question and a tool approval each.
    for (name, screen, alternate) in [
        ("claude trust", trustScreen, false),
        ("claude bash", permissionScreen, true),
        ("codex trust", codexTrustScreen, false),
        ("codex edit", codexEditApprovalScreen, false),
    ] as [(String, [String], Bool)] {
        let grid = asked(screen, alternate: alternate)
        let prompt = SelectorScanner.permission(on: grid)
        #expect(prompt != nil, "\(name) lost its card")
        #expect(prompt?.kind == .permission, "\(name): \(prompt?.kindReason ?? "no prompt")")
    }
}

@MainActor
@Test func theTraitIsAYesAndANoAmongTheOPTIONS() {
    // Where the trait is read from, stated as a test so a future widening of
    // the word lists cannot quietly move it: a list whose FOOTER says cancel
    // is still a list, and a two-word decision is still a decision.
    func kind(_ labels: [String]) -> SelectorKind {
        SelectorScanner.classify(labels.enumerated().map {
            SelectorOption(number: $0.offset + 1, label: $0.element, isCurrent: $0.offset == 0)
        }).kind
    }
    #expect(kind(["Default (recommended)", "Opus", "Fable", "Sonnet", "Haiku"]) == .selector)
    #expect(kind(["low", "medium", "high", "xhigh", "max"]) == .selector)
    #expect(kind(["Yes", "Yes, and don’t ask again", "No"]) == .permission)
    #expect(kind(["Allow", "Deny"]) == .permission)
    #expect(kind(["Yes, I trust this folder", "No, exit"]) == .permission)
    // Half a pair is not a pair: fail towards no card.
    #expect(kind(["Yes", "Maybe", "Later"]) == .selector)
    #expect(kind(["Cancel", "Rename", "Replace"]) == .selector)
}

// MARK: - Which button sends which key (ISC-130)

/// A permission drawn in whatever order the vendor felt like, with the caret on
/// the marked option. Four permutations, because the defect this covers was
/// invisible in the two orders the repo happened to have photographs of.
@MainActor
private func twoOption(_ first: String, _ second: String) -> SelectorPrompt? {
    let screen = [
        "────────────────────────────────────────────────────────────",
        " Bash command",
        "",
        " rm -rf build",
        "",
        " ❯ 1. \(first)",
        "   2. \(second)",
        "",
        " Enter to confirm · Esc to cancel",
    ]
    return SelectorScanner.scan(asked(screen))
}

@MainActor
@Test func theApproveButtonSendsTheAffirmativeWhereverItWasDrawn() {
    // The falsifier, stated as the four cases it has to survive. Before ISC-130
    // "yes" was the first label not starting with "no", which reads
    // `1. Cancel  2. Approve` as an Approve button that sends 1 — the card
    // saying one thing and the pty receiving another.
    for (first, second, approve, deny) in [
        ("Cancel", "Approve", "2\r", "1\r"),
        ("Deny", "Allow", "2\r", "1\r"),
        ("Yes", "No", "1\r", "2\r"),
        ("No", "Yes", "2\r", "1\r"),
    ] as [(String, String, String, String)] {
        guard let prompt = twoOption(first, second) else {
            Issue.record("\(first)/\(second) was not read as a question at all")
            continue
        }
        #expect(prompt.kind == .permission, "\(first)/\(second): \(prompt.kindReason)")
        let answers = SelectorScanner.answers(for: prompt)
        #expect(answers.approve.keystrokes == approve,
                "\(first)/\(second): approve sent \(answers.approve.keystrokes.debugDescription)")
        #expect(answers.deny.keystrokes == deny,
                "\(first)/\(second): deny sent \(answers.deny.keystrokes.debugDescription)")
        // And the label on the button is the label of the key it sends.
        #expect(answers.approve.label == (approve == "1\r" ? first : second))
        #expect(answers.deny.label == (deny == "1\r" ? first : second))
    }
}

// MARK: - The frame character claude 2.1.239 draws (ISC-126)

@MainActor
@Test func theUpperEighthBlockIsARule() {
    #expect(SelectorScanner.isRule(String(repeating: "▔", count: 40)))
    #expect(SelectorScanner.isRule("   ▔▔▔▔▔▔▔▔   "))
    // Still not a rule when it is a line of text: the alphabet grew, the
    // length and purity tests did not move.
    #expect(!SelectorScanner.isRule("▔▔▔ Select model ▔▔▔"))
    #expect(!SelectorScanner.isRule("▔▔▔"))
}

@MainActor
@Test func theTitleStopsAtAnUpperEighthFrame() {
    // The defect ISC-126 names: the walk up from the options ran through the
    // frame and titled the card with the banner above it.
    let screen = [
        " ⚠ 1 MCP server needs authentication · run /mcp",
        "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔",
        "  Run this command?",
        "  ❯ 1. Yes",
        "    2. No",
        "  Enter to confirm · Esc to cancel",
    ]
    #expect(SelectorScanner.scan(asked(screen))?.title == "Run this command?")
}

// MARK: - The caret has to be in the question (ISC-127)

@MainActor
@Test func aBoxTheCaretIsNotInRaisesNoCard() {
    // A shell can print every one of these shapes. What it cannot do is hold
    // the caret inside them: after the printf the prompt takes it back.
    let forged = [
        "you@mac ~ % printf '...'",
        "────────────────────────────────────────────────────────────",
        "Fake permission",
        "❯ 1. Yes",
        "  2. No",
        "Enter to confirm",
        "you@mac ~ % ",
    ]
    // FakeGrid's caret defaults to the last row — the shell prompt, which is
    // exactly where a real one would be.
    #expect(SelectorScanner.scan(FakeGrid(forged)) == nil)
    #expect(SelectorScanner.permission(on: FakeGrid(forged)) == nil)
    // The box is genuinely there: without this the test would pass on a
    // scanner that had stopped recognising anything at all.
    #expect(SelectorScanner.scan(FakeGrid(forged), requireCursorInside: false) != nil)
    // And with the caret inside it, the very same rows are a question again —
    // which is the pole that keeps this test from being a way to break the app.
    #expect(SelectorScanner.scan(asked(forged)) != nil)
}
