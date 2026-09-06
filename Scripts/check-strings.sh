#!/usr/bin/env bash
# Count string literals that are written directly into a user-visible AppKit sink.
#
# This is deliberately a syntactic inventory, not a dictionary-word grep. A
# literal is counted when it contains at least one letter and is passed on the
# same expression to a text-bearing AppKit initializer, a T4A control/row
# initializer, the menu helper, or a visible text property. Empty strings,
# punctuation-only glyphs, values that merely flow through a sink, developer
# logs, identifiers, selectors, config keys, and TestChannel.swift are outside
# the rule. Strings.swift is the catalog and is excluded by definition.
#
# The rule accepts whitespace and newlines between the sink and its literal,
# then reports the literal's own source line. Keeping the patterns here, rather
# than maintaining a hand-written allowlist of files or phrases, means a new
# view is counted as soon as it uses one of the same visible sinks.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root" <<'PY'
from __future__ import annotations

import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
source_root = root / "Sources" / "T4A"

# Each alternative ends immediately before the literal. These are the places
# where this app turns a String into words a person can see.
sinks = re.compile(
    r"""
    (?:
        \.(?:stringValue|title|toolTip|placeholderString|messageText|informativeText)\s*=\s*
      | (?:NSTextField\((?:wrapping)?labelWithString:
          |NSAttributedString\(string:
          |NSMenu\(title:
          |NSMenuItem\(title:
          |addItem\(withTitle:
          |NSButton\((?:checkboxWithTitle|title):
          |ChromeButton\(title:
          |M6Switch\(label:
          |PanelToggleButton\([^)]*?label:
          |AgentApprovalOption\(label:
          |SettingRow\(label:
          |switchRow\(
          |choice\(
          |setAccessibilityLabel\()
          \s*
      | \bnote:\s*
      | \badd\(\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*
      | \baction\(\s*
      | \baggiungi\(\s*&[A-Za-z_][A-Za-z0-9_]*\s*,\s*
    )
    (?P<literal>"(?:\\\([^)]*\)|\\.|[^"\\])*")
    """,
    re.VERBOSE | re.DOTALL,
)

entries: list[tuple[str, int, str]] = []
for path in sorted(source_root.glob("*.swift")):
    if path.name in {"Strings.swift", "TestChannel.swift"}:
        continue
    text = path.read_text(encoding="utf-8")
    for match in sinks.finditer(text):
        literal = match.group("literal")
        visible = re.sub(r"\\\([^)]*\)", "", literal)
        visible = re.sub(r"\\(?:[0\\tnr\"']|u\{[0-9A-Fa-f]+\})", "", visible)
        if not any(character.isalpha() for character in visible):
            continue
        start = match.start("literal")
        line_number = text.count("\n", 0, start) + 1
        source_line = text.splitlines()[line_number - 1].strip()
        entries.append((path.relative_to(root).as_posix(), line_number, source_line))

print(f"User-facing string literals outside Strings.swift: {len(entries)}")
for path, line_number, source_line in entries:
    print(f"{path}:{line_number}:{source_line}")
PY
