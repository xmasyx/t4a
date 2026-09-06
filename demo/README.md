# T4A — Phase 1 demo

A frontend-only prototype of T4A's layout. No PTY, no engine, no Swift: the point is to
decide the structure before any of that exists.

**Open it:** double-click `index.html`. That is the whole install — the bundle is committed
and the data is inlined, so it runs from `file://` with no server.

## What you are looking at

| Zone | What it shows |
|---|---|
| Header | Compact, one line. How many sessions want you right now, the loudest thing on screen and the only place the accent appears. Then the panel toggles and settings. |
| Sessions | Side rail or tabs on top. The button beside `sessions` moves them up; the mirrored one on the tab strip brings them back. Whoever waits for you sorts first. |
| Terminal | The recorded session as a terminal renders it: prompts, tool calls, results. |
| Turn map | A map of the run, not a copy: one row per turn with its duration and outcome, tools folded behind a caret, a red tick in the gutter when a turn failed. Click a row and the terminal jumps to it. |
| Approval card | A real permission request with a real diff. It stays until you decide; deciding sends the session back to work. |
| Composer | The bottom line. You can always answer a session; a pending permission is the one thing that blocks it. |
| Dashboard bar | A statusline across the bottom. It takes height from below, never width from the terminal, and every row on it can be switched off in settings. |

Every boundary is draggable — both panel widths, the header height, the bar height — and
the sizes are remembered. So are the layout, the theme, and which dashboard rows you keep.

⌘K opens the palette. `reset` puts the pending approval back on purpose, and says so next
to the control.

## Themes

Full black is the active theme. The warm dark measured from cursor.com stays selectable in
settings. Both keep the same ink and the same single accent.

## The data is real

Every turn, tool call, duration and diff came out of recorded Claude Code sessions —
nothing on screen was written by hand. `tools/extract.ts` reads the JSONL transcripts,
keeps the structure, and drops everything that could identify a machine or a person:

- home paths collapse to `~`, then any line still holding a path, a name, or an address is
  dropped whole;
- tool **output bodies never ship** — only their shape (`34 lines`, `failed`);
- sessions marked `activity` keep their turns and tool calls and lose their prose entirely.

A fail-closed scrub runs over the finished file: on any hit, nothing is written.

### Why you can't read a conversation in the terminal pane

Because the anonymiser took it out, not because the product works that way. Prose is the
part of a transcript most likely to carry a path, a name, or somebody's business, so the
extractor drops any line that trips a deny pattern, and sessions marked `activity` lose
their prose wholesale — you see `response · 17 lines withheld by the anonymiser` where the
words were. What survives is the part this demo is actually about: turn boundaries,
durations, tool calls, outcomes, diffs.

In the real T4A the centre pane is the true `claude` TUI running in a PTY, dialogue and
all. The gap you see here is an artefact of shipping a recording in public, and it
disappears the moment the pane is a terminal instead of a replay.

## Two levels of facts

The inspector's facts panel has a public level and a personal one.

The **public level** is `data/facts.sample.json`, bundled into `app.js`: everything Claude
Code shows by default — session title, model, permission mode, directory, branch, context,
startup load, effort — plus the token windows (5h, week, per-model) with their percentages
and reset times. Session rows come from the recorded session; the window numbers are sample
values.

Context reads as `363k of 1M`, and the ceiling belongs to the model rather than to a
constant: the `[1m]` alias is the long window, every other model gets its own. A wrong
default there multiplies every percentage and still looks plausible, which is exactly the
kind of bug nobody catches.

The **personal level** is whatever your own harness knows. `bun demo/tools/facts.ts` reads
it locally, read-only, and writes two gitignored files: `facts.local.json` and `local.html`.
Open `local.html` instead of `index.html` and the panel fills with your real dashboard —
versions, live agents, memory health, live context against the declared window, effort
scale, and each token window with its reset.

The split is structural, not a promise: the personal data lives inline in `local.html`, so
the committed `app.js` physically cannot contain it.

```bash
bun demo/tools/extract.ts demo/tools/sources.json   # regenerate (needs a local sources.json)
bun demo/tools/extract.ts --verify                  # scrub the committed data, exit 1 on a hit
bun build demo/src/main.ts --outfile demo/app.js --target browser --format iife
./node_modules/.bin/tsc --noEmit   # the project's own compiler: bunx tsc pulls a newer major that just prints help
```

`tools/sources.json` points at transcripts on one machine, so it is deliberately not
committed. It is a list of `{file, id, name, detail, state, idleMinutes}`.

## Design

Warm dark, never pure black. One grotesque for the interface, one mono for the terminal.
One accent, and it marks one thing: the session waiting for you. When nothing waits, the
colour leaves the screen entirely.

The diff is drawn in value rather than hue — brighter for added, dimmed for removed — so
the accent stays reserved.
