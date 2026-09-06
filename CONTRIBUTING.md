# Contributing

Issues and pull requests are welcome. A few things that will save us both time.

## Before you open a PR

```sh
swift build -c release
swift test
./Scripts/build-app.sh release
```

`build-app.sh` also parses every shipped shell script, so a syntax error in `Scripts/` fails
the build rather than the user.

## What the design is committed to

These are not preferences, they are the reason the project exists. A change that breaks one
of them needs to argue the case in the issue first.

- **The terminal stays a terminal.** Everything T4A adds is observation. No proxy between you
  and the CLI, no protocol of our own, no bundled SDK, no API key.
- **Read-only on agent data.** `~/.claude` and `~/.codex` are never written to. Ever.
- **No network from T4A.** No telemetry, no update check, no account. If a change opens a
  socket, it is the wrong change.
- **The GPU earns its silence.** When nothing changes, zero frames — not few.
- **Zero config on first run.** Everything on, no setup step.

## Where things live

| Target | What it may import |
|---|---|
| `TerminalCore` | nothing — cells, rows, sessions; the contract |
| `MetalRenderer` | `TerminalCore` and Metal. No VT library |
| `AgentAdapters` | `TerminalCore`. No VT library, no AppKit, no vendor SDK |
| `SwiftTermBackend` | the only target allowed to `import SwiftTerm` |
| `T4A` | the app: AppKit, chrome, windows |

`Scripts/drive.sh check-seam` enforces the SwiftTerm boundary and fails if `import SwiftTerm`
appears outside its target.

## Adding an agent vendor

A new vendor is one file in `Sources/AgentAdapters` plus a line in the registry. Each adapter
declares its own model families — there is deliberately no default, so the compiler asks the
question of anyone writing a new one.

Bring a real captured screen with you: the tests in `Tests/AgentAdaptersTests` are dumps of
live panes, never hand-written, and a permission recogniser that has only seen invented input
is a recogniser nobody should trust. Home paths and shell prompts in captures are sanitised.

## Benches

`Scripts/bench-*.sh` are the measurement harnesses — rendering, agents, chrome, themes,
layout, idle CPU. They drive the real app through a test channel that only exists when
`T4A_TEST_CHANNEL` is set in the environment, so a shipped T4A has no such channel.

A bench that cannot go red is not a bench. If you add one, show it failing on the code before
your change as well as passing after it.

### The door bench

Build the bench bundle, then run all 18 door poles:

```sh
Scripts/build-app.sh
Scripts/bench-door.sh
```

The build goes to `dist/T4A.app`, which is the bundle the bench uses by default. To run the
feature's negative pole, give the bench a bundle built without the door:

```sh
Scripts/bench-door.sh --head <bundle>
```

Benches run one at a time on a machine. `Scripts/lib/bench-stop.sh` takes
`/tmp/t4a-bench.lock`, so two benches never kill each other's app.

Door request files must be published atomically: write a temporary name, then `mv` it to the
request name. The app reads the file the instant its directory entry appears.
