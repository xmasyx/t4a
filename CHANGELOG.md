# Changelog

Dates are release dates. Versions follow [semver](https://semver.org): the minor number moves when
something new arrives, the patch number when something already there gets fixed.

## 0.1.0 — 2026-09-06

The first public release. It is used every day on the machine it was built on, and nowhere
else yet: expect bugs, and please report them with the steps that produce them.

### What it is

- A native macOS terminal, drawn by the GPU with a Metal renderer against a cell grid, with the
  CPU renderer kept alive behind a flag.
- Agent sessions (`claude`, `codex`) are objects: turn blocks in the scrollback, a rail that sorts
  the sessions waiting for you first, a turn map on the right with tools and durations, and a bar
  along the bottom with the session's model, context, output and effort read from its own file.
- You type where the agent reads. Nothing sits between you and the agent's own input line by
  default; the composer and the chat page exist as options and are off.
- Approval cards, with the chat page enabled: a permission request lifted out of the TUI with
  the command or the diff inside it, answered with a real keystroke into the real PTY.
- `⌘`-hover turns a path or a URL into a link, `⌘`-click opens it, as iTerm does. A path that
  wraps across rows is one link.
- File preview inside the window: on the chat page, a file the agent wrote opens beside the
  session with QuickLook (`⌥⌘P` collapses it, `⇧⌥⌘P` brings it forward as a card).
- Five built-in themes switching live, a command palette (`⌘K`), sessions as a rail or as tabs,
  split panes, shell integration (OSC 133) for command blocks.
- Interface in English or Italian, following the system by default, switchable live in Settings.
- Updates from Settings: a button that asks GitHub only when pressed and installs through
  Homebrew. No network traffic before that click.

### Fixed before shipping

- A pasted clipboard carrying the bracketed-paste end sequence (`ESC[201~`) could close the paste
  early and hand the rest of itself to the program as keystrokes. Both markers are now removed
  from a pasted body, and `⌘V` into the pane goes through the same writer.
- Releasing `⌘` over a link without moving left the arrow cursor instead of the I-beam.

### Known limits

- Signed with a self-made identity, not notarized: the first launch needs the usual right-click
  → Open, or `brew install --cask` which strips the quarantine.
- The update path has no end-to-end proof yet, for the plain reason that there is no earlier
  version to update from. 0.1.1 will be that proof.
- Memory with six sessions open is above the target the project set itself (about 505 MiB
  against 250). The renderer keeps a full-resolution surface per visible pane.
