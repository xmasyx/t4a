//  SlashCommandCatalogTests.swift — the `/` list comes from the agent, or it
//  does not come at all (ISC-187).
//
//  The negative pole here is `unBinarioSenzaTabellaNonNeInventaUna`: a file
//  with no command literals must say `.unavailable`, because the whole point
//  of reading the binary is that a made-up list is worse than no list. If that
//  one ever goes green with commands in it, everything above it has stopped
//  meaning anything.
//
//  The fixture is a 20 MB file rather than a small one on purpose: the scanner
//  reads in 8 MB pieces, and a literal placed astride the first boundary is
//  the only way to find out whether the slack either side does its job. A
//  small fixture would pass with the chunking broken.

import Foundation
import Testing
@testable import AgentAdapters

// MARK: - Ground

/// A cache root of our own, so a run never reads or writes the real one under
/// `~/.cache`. The first measurement in this process would otherwise be a
/// cache hit left by yesterday's run, and would prove nothing about the scan.
private let cacheRoot: URL = {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t4a-slash-tests-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    setenv("XDG_CACHE_HOME", url.path, 1)
    return url
}()

private func temporaryDirectory(_ name: String) -> URL {
    _ = cacheRoot
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("t4a-\(name)-\(getpid())-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The path with every link followed, as `FileManager` reports it when it
/// lists a directory. Not `resolvingSymlinksInPath`, which on macOS does the
/// OPPOSITE for this one case — it rewrites `/private/var` back to `/var`, so
/// an origin read off the disk never equals a URL put through it.
private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

/// `refresh` and then wait for the background scan, without a sleep: the
/// callback is the signal. Everything here is on the main actor, so the scan's
/// hop back cannot land between the refresh and the state check below it.
@MainActor
private func settle(_ catalog: SlashCommandCatalog, executable: URL?,
                    config: URL, project: URL? = nil) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var resumed = false
        func finish() {
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }
        catalog.onChange = {
            if catalog.state == .scanning { return }
            finish()
        }
        catalog.refresh(executable: executable, configDirectory: config, projectDirectory: project)
        if catalog.state != .scanning { finish() }
    }
    catalog.onChange = nil
}

// MARK: - A binary that carries a table

/// Six literals in the shapes the real bundle uses, buried in 20 MB of random
/// bytes. Each one gets a short brace-free prologue in front of it, because
/// that is what a bundler emits (`…;var K0s=` before the object) and because
/// the scanner walks backwards to the object's own opening brace.
private func fixtureBinary(named name: String) -> URL {
    let literals = [
        // Normal: aliases and a hint.
        #"{type:"local",name:"forge",description:"Build the thing",aliases:["build","mk"],argumentHint:"<target>"}"#,
        // The pair that has to be merged. This half computes its description
        // at runtime, so there is no literal to read; it does carry the hint.
        #"{type:"local",name:"twin",get description(){return"computed at runtime"},argumentHint:"[x]"}"#,
        #"{type:"local-jsx",name:"twin",description:"The twin, described",immediate:!0}"#,
        // Hidden on purpose.
        #"{type:"local",name:"ghost",description:"Not for people",isHidden:!0}"#,
        // Switched off at build time.
        #"{type:"local-jsx",name:"retired",description:"Gone",isEnabled:()=>!1}"#,
        // Internal.
        #"{type:"local",name:"__interno",description:"Internal plumbing"}"#,
        // The shape that hides `/brief` in the real bundle: a template literal
        // with another template inside its `${…}`, and an apostrophe in the
        // inner one. A reader that pairs backticks blindly is one out of step
        // by the time it reaches `user's`, and then that quote opens a string
        // which swallows the rest of the object.
        "{type:\"local-jsx\",name:\"mirror\",get description(){return`state ${r?`the user's view`:`none`}`}"
            + ",requires:{ink:!0},argumentHint:\"[q]\"}",
        // An opening brace inside a plain string, closed nowhere. A counter
        // that does not know it is inside a string never gets back to zero and
        // loses the command.
        #"{type:"local",name:"curly",description:"Opens a block with { and leaves it",aliases:["brace"]}"#,
    ]
    let prologue = ";var qq=1,zz=2;var ww="

    let url = temporaryDirectory("fixture").appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: url) else { return url }
    defer { try? handle.close() }

    // Where each literal goes. The second one starts 40 bytes before the 8 MB
    // piece boundary, so it can only be read whole if the slack works.
    let boundary = 8 << 20
    let spots = [1_000_000, boundary - 40, boundary + 900_000,
                 12_000_000, 15_000_000, 17_000_000, 19_000_000, 19_500_000]
    var written = 0
    for (index, literal) in literals.enumerated() {
        let payload = Data((prologue + literal).utf8)
        let target = spots[index]
        while written < target {
            let step = min(1 << 20, target - written)
            handle.write(noise(step))
            written += step
        }
        handle.write(payload)
        written += payload.count
    }
    while written < 20 << 20 {
        let step = min(1 << 20, (20 << 20) - written)
        handle.write(noise(step))
        written += step
    }
    return url
}

/// Filled by the system rather than a byte at a time: 20 MB of
/// `UInt8.random(in:)` in a debug build costs seconds, and those seconds land
/// inside the timing assertion of whatever test is running beside this one.
private func noise(_ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
    return data
}

@MainActor
@Test func iLetteraliDelBinarioDiventanoComandi() async {
    let binary = fixtureBinary(named: "agent-with-table")
    let catalog = SlashCommandCatalog()
    await settle(catalog, executable: binary, config: temporaryDirectory("empty-config"))

    #expect(catalog.state == .ready(builtin: 4, declared: 0))
    #expect(catalog.commands.map(\.name) == ["curly", "forge", "mirror", "twin"])

    let forge = catalog.commands.first { $0.name == "forge" }
    #expect(forge?.description == "Build the thing")
    #expect(forge?.argumentHint == "<target>")
    #expect(forge?.aliases == ["build", "mk"])
    #expect(forge?.source == .builtin)
    // The origin names the binary, so a reader can tell WHICH build answered.
    #expect(forge?.origin == "agent-with-table")

    // The pair became one command: the description from the half that has a
    // literal, the hint from the half that carries it.
    let twin = catalog.commands.first { $0.name == "twin" }
    #expect(twin?.description == "The twin, described")
    #expect(twin?.argumentHint == "[x]")

    // A description behind a getter is empty, not invented — the value only
    // exists while the agent is running.
    let mirror = catalog.commands.first { $0.name == "mirror" }
    #expect(mirror?.description == "")
    #expect(mirror?.argumentHint == "[q]")

    // The brace that lives inside a string, and the fields that come after it.
    let curly = catalog.commands.first { $0.name == "curly" }
    #expect(curly?.description == "Opens a block with { and leaves it")
    #expect(curly?.aliases == ["brace"])

    // The three that must not be listed, each for its own reason.
    let names = Set(catalog.commands.map(\.name))
    #expect(!names.contains("ghost"))
    #expect(!names.contains("retired"))
    #expect(!names.contains("__interno"))
}

@MainActor
@Test func unBinarioSenzaTabellaNonNeInventaUna() async {
    // The negative pole. Codex and gemini are this case, and the only correct
    // answer for them is to say so.
    let url = temporaryDirectory("fixture").appendingPathComponent("codex")
    var bytes = noise(2 << 20)
    // Not even close to empty of the WORD: what is missing is the shape.
    bytes.append(Data("local commands are configured elsewhere in codex".utf8))
    try? bytes.write(to: url)

    let catalog = SlashCommandCatalog()
    await settle(catalog, executable: url, config: temporaryDirectory("empty-config"))

    #expect(catalog.state == .unavailable("no command table in codex"))
    #expect(catalog.commands.isEmpty)
}

@MainActor
@Test func senzaAgenteAgganciatoLoStatoLoDice() async {
    let config = temporaryDirectory("config")
    write("---\ndescription: A command\n---\n", to: config.appendingPathComponent("commands/solo.md"))

    let catalog = SlashCommandCatalog()
    await settle(catalog, executable: nil, config: config)

    // The user's own commands are real whether or not a binary was readable,
    // so they stay: only the built-ins are missing.
    #expect(catalog.state == .unavailable("no agent attached"))
    #expect(catalog.commands.map(\.name) == ["solo"])

    catalog.clear()
    #expect(catalog.state == .idle)
    #expect(catalog.commands.isEmpty)
}

// MARK: - The files on disk

@MainActor
@Test func leFontiSuDiscoDannoNomeSorgenteEProvenienza() async {
    let config = temporaryDirectory("config")
    let project = temporaryDirectory("project")
    let pluginRoot = temporaryDirectory("plugin-kit")
    let unusedPlugin = temporaryDirectory("plugin-elsewhere")

    write("""
    ---
    name: not-the-command-name
    description: Search prior work
    argument-hint: [topic]
    ---
    body
    """, to: config.appendingPathComponent("commands/cs.md"))
    write("---\ndescription: Check a site\n---\n",
          to: config.appendingPathComponent("commands/isdown.md"))
    write("""
    ---
    name: Interceptor
    description: "Real Chrome, real sessions."
    version: 4.3.18
    ---
    """, to: config.appendingPathComponent("skills/Interceptor/SKILL.md"))
    write("""
    ---
    name: _PRIVATE
    description: Never on the menu
    user-invocable: false
    ---
    """, to: config.appendingPathComponent("skills/_PRIVATE/SKILL.md"))

    write("---\ndescription: Only in this project\n---\n",
          to: project.appendingPathComponent(".claude/commands/deploy.md"))

    write("---\ndescription: Code review a pull request\n---\n",
          to: pluginRoot.appendingPathComponent("commands/code-review.md"))
    write("---\ndescription: The plugin's own skill\n---\n",
          to: pluginRoot.appendingPathComponent("skills/Reviewer/SKILL.md"))
    write("---\ndescription: Belongs to another tree\n---\n",
          to: unusedPlugin.appendingPathComponent("commands/nope.md"))

    let manifest = """
    {"version":2,"plugins":{
      "code-review@official":[
        {"scope":"user","installPath":"\(pluginRoot.path)"},
        {"scope":"project","projectPath":"\(project.path)","installPath":"\(pluginRoot.path)"}
      ],
      "elsewhere@official":[
        {"scope":"project","projectPath":"/somewhere/else","installPath":"\(unusedPlugin.path)"}
      ]
    }}
    """
    write(manifest, to: config.appendingPathComponent("plugins/installed_plugins.json"))

    let catalog = SlashCommandCatalog()
    await settle(catalog, executable: nil, config: config, project: project)

    // User first, then project, then plugin; alphabetical inside each.
    #expect(catalog.commands.map(\.name) == ["cs", "Interceptor", "isdown", "deploy",
                                             "code-review:code-review", "code-review:Reviewer"])

    let cs = catalog.commands.first { $0.name == "cs" }
    // The FILE NAME is the command, not the `name:` field, which here says
    // something else on purpose.
    #expect(cs?.description == "Search prior work")
    #expect(cs?.argumentHint == "[topic]")
    #expect(cs?.source == .user)
    #expect(cs?.origin == realPath(config.appendingPathComponent("commands/cs.md")))

    let skill = catalog.commands.first { $0.name == "Interceptor" }
    #expect(skill?.description == "Real Chrome, real sessions.")
    #expect(skill?.source == .user)
    #expect(skill?.origin == realPath(config.appendingPathComponent("skills/Interceptor/SKILL.md")))

    #expect(catalog.commands.first { $0.name == "deploy" }?.source == .project)

    let pluginCommand = catalog.commands.first { $0.name == "code-review:code-review" }
    #expect(pluginCommand?.source == .plugin)
    #expect(pluginCommand?.origin
            == realPath(pluginRoot.appendingPathComponent("commands/code-review.md")))

    // A skill that says it is not for people is absent, and a plugin scoped to
    // another project's tree is absent.
    let names = Set(catalog.commands.map(\.name))
    #expect(!names.contains("_PRIVATE"))
    #expect(!names.contains("elsewhere:nope"))
    // The same plugin listed twice (user AND project) is still one command.
    #expect(catalog.commands.filter { $0.name == "code-review:code-review" }.count == 1)
}

// MARK: - What the bubble asks

@Test func riconosceSoloUnPrimoTokenDichiaratoComeComandoLocale() {
    let commands = [
        SlashCommand(name: "model", description: "Choose model", aliases: ["mod"],
                     source: .builtin, origin: "fixture"),
    ]

    #expect(SlashCommandCatalog.isLocalCommand("/model", commands: commands))
    #expect(SlashCommandCatalog.isLocalCommand("/model opus", commands: commands))
    #expect(SlashCommandCatalog.isLocalCommand("/MODEL\nopus", commands: commands))
    #expect(SlashCommandCatalog.isLocalCommand("/mod", commands: commands))
    #expect(!SlashCommandCatalog.isLocalCommand("/models", commands: commands))
    #expect(!SlashCommandCatalog.isLocalCommand("/tmp/notes.md", commands: commands))
    #expect(!SlashCommandCatalog.isLocalCommand("model", commands: commands))
    #expect(!SlashCommandCatalog.isLocalCommand("/model", commands: []))
}

@MainActor
@Test func matchesRispondeAlTestoDellaBolla() async {
    let binary = fixtureBinary(named: "agent-for-matches")
    let config = temporaryDirectory("config")
    write("---\ndescription: Mine\n---\n", to: config.appendingPathComponent("commands/format.md"))

    let catalog = SlashCommandCatalog()
    await settle(catalog, executable: binary, config: config)

    // Everything, in source order.
    #expect(catalog.matches("/").map(\.name) == ["curly", "forge", "mirror", "twin", "format"])
    // A prefix on the name.
    #expect(catalog.matches("/fo").map(\.name) == ["forge", "format"])
    #expect(catalog.matches("/FO").map(\.name) == ["forge", "format"])
    // A prefix on an ALIAS: `build` is only reachable through forge's aliases.
    #expect(catalog.matches("/bui").map(\.name) == ["forge"])
    // Nothing that matches is an empty list, not everything.
    #expect(catalog.matches("/zzz").isEmpty)
    // Not a command line at all.
    #expect(catalog.matches("").isEmpty)
    #expect(catalog.matches("ripara il notch").isEmpty)
    // The word is settled once a space follows it: what comes after is an
    // argument, and the list has no business being on screen.
    #expect(catalog.matches("/forge ").isEmpty)
    #expect(catalog.matches("/forge Sources").isEmpty)

    // The cache answers the same thing: a second catalog over the same binary
    // never reads it again, and must not therefore answer differently.
    let second = SlashCommandCatalog()
    await settle(second, executable: binary, config: config)
    #expect(second.matches("/").map(\.name) == catalog.matches("/").map(\.name))
    #expect(second.state == catalog.state)
}

// MARK: - The agent that is actually installed

/// `claude` as this machine resolves it, or nil.
private func installedClaude() -> URL? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "command -v claude"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
}

@MainActor
@Test func ilBinarioVeroDiClaudePortaLaSuaTabella() async throws {
    guard let binary = installedClaude() else {
        // Said out loud rather than passed quietly: a skipped test that looks
        // like a green one is the reason nobody notices coverage leaving.
        Issue.record("claude is not installed here — the real-binary pole did not run")
        return
    }
    let catalog = SlashCommandCatalog()
    let started = Date()
    await settle(catalog, executable: binary, config: temporaryDirectory("empty-config"))
    let cold = Date().timeIntervalSince(started)

    guard case let .ready(builtin, _) = catalog.state else {
        Issue.record("expected a table in \(binary.path), got \(catalog.state)")
        return
    }
    #expect(builtin >= 20)
    let names = Set(catalog.commands.map(\.name))
    for wanted in ["compact", "model", "help", "clear", "config"] {
        #expect(names.contains(wanted), "\(wanted) missing from \(binary.lastPathComponent)")
    }
    #expect(catalog.commands.first { $0.name == "config" }?.aliases.contains("settings") == true)
    #expect(catalog.commands.first { $0.name == "compact" }?.description
            == "Free up context by summarizing the conversation so far")
    // Hidden and switched-off built-ins really are gone from a real table too.
    #expect(!names.contains("__remote-workflow"))
    #expect(!names.contains("update"))
    #expect(cold < 5, "the cold scan took \(cold)s")

    // The second time is the cache, and the cache is the whole reason opening
    // the app twice does not scan 230 MB twice.
    let warmStart = Date()
    let second = SlashCommandCatalog()
    await settle(second, executable: binary, config: temporaryDirectory("empty-config"))
    let warm = Date().timeIntervalSince(warmStart)
    #expect(second.commands.map(\.name) == catalog.commands.map(\.name))
    #expect(warm < 0.05, "the cached answer took \(warm)s")
    print("[slash] cold scan \(String(format: "%.3f", cold))s, cached \(String(format: "%.4f", warm))s, "
          + "\(builtin) built-ins from \(binary.path)")
}

// MARK: - The pieces underneath

@Test func ilNomeDelBinarioSiLeggeAncheQuandoEUnNumeroDiVersione() {
    #expect(BinaryCommandTable.label(for: URL(fileURLWithPath:
        "/Users/example/.local/share/claude/versions/2.1.246")) == "claude 2.1.246")
    #expect(BinaryCommandTable.label(for: URL(fileURLWithPath: "/usr/local/bin/codex")) == "codex")
    #expect(BinaryCommandTable.label(for: URL(fileURLWithPath: "/opt/gemini/bin/gemini")) == "gemini")
}

@Test func leSequenzeDiFugaDelBundlerNonArrivanoSulloSchermo() {
    #expect(BinaryCommandTable.unescapeJS(#"posture=… scope=…"#) == "posture=… scope=…")
    #expect(BinaryCommandTable.unescapeJS(#"say \"yes\""#) == "say \"yes\"")
    #expect(BinaryCommandTable.unescapeJS("nothing to undo") == "nothing to undo")
}

@Test func ilFrontmatterSiLeggeSoloFraLeDueBarriere() {
    let text = """
    ---
    name: cs
    description: "A skill, quoted"
    argument-hint: [topic]
    ---

    # Body
    description: this line is not frontmatter
    """
    let front = Frontmatter.parse(text)
    #expect(front["name"] == "cs")
    #expect(front["description"] == "A skill, quoted")
    #expect(front["argument-hint"] == "[topic]")
    // A file that opens with something else has no frontmatter at all.
    #expect(Frontmatter.parse("# Just a document\ndescription: no").isEmpty)
}

// MARK: - The principal's own configuration

/// `$CLAUDE_CONFIG_DIR` or `~/.claude`, when it is there.
private func installedConfig() -> URL? {
    let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        ?? NSHomeDirectory() + "/.claude"
    let url = URL(fileURLWithPath: path)
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("skills").path)
        ? url : nil
}

/// The three naming rules, against the config that is actually installed.
///
/// Each one was read off claude's own menu on 2026-08-27 with
/// `Scripts/bench-slash-names.sh`, which types the prefix into a real `claude` and
/// photographs the grid. That is the only place these rules are written down:
/// a `.md` command is its FILE NAME, a skill is its DIRECTORY name with the
/// case kept, and a plugin command is `<plugin>:<command>`.
@MainActor
@Test func iNomiDelleFontiVereCoincidonoColMenuDiClaude() async {
    guard let config = installedConfig() else {
        Issue.record("no config directory here — the naming pole did not run")
        return
    }
    let catalog = SlashCommandCatalog()
    await settle(catalog, executable: nil, config: config)
    let names = Set(catalog.commands.map(\.name))

    // 1. `~/.claude/commands/cs.md` → the TUI shows `/cs`.
    #expect(names.contains("cs"))
    // 2. `~/.claude/skills/Interceptor/SKILL.md` → the TUI shows
    //    `/Interceptor`, not `/interceptor` and not the frontmatter `name`.
    #expect(names.contains("Interceptor"))
    // 3. A plugin's `commands/code-review.md` → the TUI shows
    //    `/code-review:code-review`, labelled `(code-review)`.
    #expect(names.contains("code-review:code-review"))

    // THE DECLARED GAP, pinned rather than left to be noticed.
    //
    // claude's menu also carries `/simplify` and `/code-review` with no
    // prefix: skills bundled inside the binary, registered under a minified
    // variable this catalog refuses to guess at (see the header of
    // SlashCommandCatalog.swift). If either of these ever appears, the gap has
    // been closed and the comment that describes it is now a lie.
    #expect(!names.contains("simplify"), "the bundled-skill gap has closed — update the header")
    #expect(!names.contains("dataviz"), "the bundled-skill gap has closed — update the header")
}

// MARK: - Which binary is running in this pane

/// `executable` is read off the KERNEL, or it is nothing.
///
/// The command line cannot answer this: it says `claude` while the file on
/// disk is `…/claude/versions/2.1.246`, and the catalog has to open the file.
/// The positive pole uses the test runner's own pid, which is the one process
/// whose path can be checked independently on any machine.
@MainActor
@Test func ilPercorsoDelBinarioVieneDalPidNonDallaRigaDiComando() {
    let mine = AgentObserver.executablePath(of: getpid())
    #expect(mine != nil)
    #expect(FileManager.default.isExecutableFile(atPath: mine?.path ?? ""))
    // A pid nobody has: nil, never a guess.
    #expect(AgentObserver.executablePath(of: Int32.max) == nil)

    let cwd = temporaryDirectory("observer")
    let observer = AgentObserver()
    observer.programChanged(process: "claude", commandLine: "claude", cwd: cwd, pid: getpid())
    #expect(observer.executable == mine)

    observer.detach()
    #expect(observer.executable == nil)

    // The negative pole. Attaching WITHOUT a pid must leave it nil rather than
    // reach for the command line — and this is not a hypothetical branch: a
    // live attach measured on 2026-08-27 came through it, because the pane's
    // process tree was still empty when the agent was recognised
    // (Sources/T4A/Session.swift:663 passes no pid). Repaired on 2026-08-27 by
    // the test below, which is about what happens NEXT — the attach itself is
    // still allowed to arrive empty-handed.
    observer.programChanged(process: "claude", commandLine: "claude", cwd: cwd)
    #expect(observer.isAttached)
    #expect(observer.executable == nil)
    #expect(!observer.hasProcess)
    observer.detach()
}

/// A pid that arrives after the attach is ADOPTED, and the adapter survives it.
///
/// The two halves matter equally. Without the adoption a pane that lost the
/// process-tree race stayed pid-less for the whole session (5 attaches in 7,
/// measured 2026-08-27). With an adoption done by detaching and re-attaching,
/// every turn read so far and its proven transcript tail would be thrown away,
/// so the identity check below is not ceremony, it is the anti-claim: the
/// adapter object has to be the SAME one.
@MainActor
@Test func unPidArrivatoDopoVieneAdottatoSenzaRiagganciare() {
    let cwd = temporaryDirectory("observer-late-pid")
    let observer = AgentObserver()

    observer.programChanged(process: "claude", commandLine: "claude", cwd: cwd)
    #expect(observer.isAttached)
    #expect(!observer.hasProcess)
    #expect(observer.executable == nil)
    let first = observer.adapterIdentity

    observer.programChanged(process: "claude", commandLine: "claude", cwd: cwd, pid: getpid())
    #expect(observer.hasProcess)
    #expect(observer.executable == AgentObserver.executablePath(of: getpid()))
    #expect(observer.adapterIdentity == first, "adopting a pid must not re-attach")

    // A pid whose path cannot be read is not adopted: pinning a dead process
    // would stop the pane retrying and give it nothing. The negative pole of
    // the same branch, on an observer that starts without one.
    let other = AgentObserver()
    other.programChanged(process: "claude", commandLine: "claude", cwd: cwd)
    other.programChanged(process: "claude", commandLine: "claude", cwd: cwd, pid: Int32.max)
    #expect(!other.hasProcess)
    #expect(other.executable == nil)

    // And the pid does not outlive the attach it belongs to.
    observer.detach()
    #expect(!observer.hasProcess)
    other.detach()
}
