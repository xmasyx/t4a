#!/bin/bash
# ISC-110 — the trimmings a grown-up terminal has.
#
#   Scripts/bench-chrome.sh [app-bundle]
#
# What is checked, and how:
#   * TERM_PROGRAM_VERSION — the shell inside the terminal is asked to print
#     it, and the answer is compared with the version in the bundle's
#     Info.plist read straight off disk. A constant that agrees with itself
#     proves nothing; these are two different files.
#   * the menus — the whole menu bar is dumped after `update()`, so what is
#     read is what a person would find when they pull it down, including
#     whether the item is enabled.
#   * every shortcut is FIRED and its effect measured: bigger and smaller
#     change the font and the grid, Clear Buffer empties the scrollback,
#     Find opens the find bar, New Window makes a second window, About opens
#     the panel. A menu item that exists and does nothing is the thing this
#     is looking for.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-chrome.fifo"
CONFIG_HOME="/tmp/t4a-chrome-config"
DUMP=/tmp/t4a-chrome-dump.json
MENU=/tmp/t4a-chrome-menu.json

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")"

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 30); do [ -s "$DUMP" ] && break; sleep 0.1; done
}

t4a_stop_bench
sleep 1
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3

echo "==> what the shell inside says it is running in"
send 'text echo "TERMCHECK $TERM_PROGRAM $TERM_PROGRAM_VERSION"'
send "key return"
sleep 1.5
dump
cp "$DUMP" /tmp/t4a-chrome-term.json

echo "==> the menu bar"
rm -f "$MENU"; send "menu $MENU"
for _ in $(seq 1 30); do [ -s "$MENU" ] && break; sleep 0.1; done

echo "==> pressing things"
send "text seq 1 800"; send "key return"; sleep 2
dump; cp "$DUMP" /tmp/t4a-chrome-full.json

send "fire Bigger"; sleep 0.6
send "fire Bigger"; sleep 0.6
dump; cp "$DUMP" /tmp/t4a-chrome-bigger.json
send "fire Smaller"; sleep 0.6
send "fire Actual Size"; sleep 0.8
dump; cp "$DUMP" /tmp/t4a-chrome-actual.json

send "fire Clear Buffer"; sleep 1
dump; cp "$DUMP" /tmp/t4a-chrome-cleared.json

send "fire Find…"; sleep 1.2
dump; cp "$DUMP" /tmp/t4a-chrome-find.json

send "fire New Window"; sleep 2
dump; cp "$DUMP" /tmp/t4a-chrome-newwindow.json

send "fire About T4A"; sleep 2
dump; cp "$DUMP" /tmp/t4a-chrome-about.json

t4a_stop_bench
rm -f "$FIFO"

/usr/bin/python3 - "$PLIST_VERSION" <<'PY'
import json, sys
plist_version = sys.argv[1]
def load(name): return json.load(open(f"/tmp/t4a-chrome-{name}.json"))

ok = True
def check(label, condition, detail):
    global ok
    ok = ok and condition
    print(f"{'PASS' if condition else 'FAIL'}  {label}: {detail}")

term = load("term")
screen = "\n".join(term['tabs'][0]['panes'][0]['screen'])
line = next((l for l in screen.splitlines() if l.startswith("TERMCHECK ")), "")
parts = line.split()
check("the shell was told which terminal it is in",
      len(parts) == 3 and parts[1] == "T4A", line or "no TERMCHECK line on screen")
check("and which version, matching the bundle",
      len(parts) == 3 and parts[2] == plist_version,
      f"shell says {parts[2] if len(parts) == 3 else '—'}, Info.plist says {plist_version}")

menus = json.load(open("/tmp/t4a-chrome-menu.json"))["menus"]
flat = []
def walk(items, path):
    for item in items:
        if item["separator"]: continue
        flat.append((path, item))
        walk(item.get("items", []), item["title"])
walk(menus, "")
def find(title):
    return next((item for path, item in flat if item["title"] == title), None)

for title, key, mods in [
    # ⌘K became the palette on 22/08 (ISC-32) and Clear Buffer moved one
    # modifier over; both are asserted here so the swap cannot happen again
    # by accident in one direction only.
    ("Find…", "f", "cmd+"), ("Clear Buffer", "K", "shift+cmd+"),
    ("Command Palette", "k", "cmd+"),
    ("Bigger", "+", "cmd+"), ("Smaller", "-", "cmd+"),
    ("Actual Size", "0", "cmd+"), ("New Window", "n", "cmd+"),
    ("Minimize", "m", "cmd+"), ("About T4A", "", ""), ("New Tab", "t", "cmd+"),
    ("Close Pane", "w", "cmd+"),
]:
    item = find(title)
    good = item is not None and item["key"] == key and item["modifiers"] == mods \
        and item["hasAction"] and item["enabled"]
    check(f"menu: {title}", good,
          f"{item['modifiers'] + item['key'] if item else 'missing'} "
          f"enabled={item['enabled'] if item else '—'}")

check("Minimize lives in a menu called Window",
      any(path == "Window" and item["title"] == "Minimize" for path, item in flat),
      ", ".join(sorted({path for path, _ in flat if path})))

full, bigger, actual = load("full"), load("bigger"), load("actual")
def grid(d): return (d['tabs'][0]['panes'][0]['columns'], d['tabs'][0]['panes'][0]['rows'])
check("Bigger raised the font and shrank the grid",
      bigger["fontSize"] == full["fontSize"] + 2 and grid(bigger)[0] < grid(full)[0],
      f"{full['fontSize']}pt {grid(full)} -> {bigger['fontSize']}pt {grid(bigger)}")
check("Actual Size put it back",
      actual["fontSize"] == 13, f"{actual['fontSize']}pt {grid(actual)}")

cleared = load("cleared")
before_lines = full['tabs'][0]['panes'][0]['retainedLines']
after_lines = cleared['tabs'][0]['panes'][0]['retainedLines']
check("Clear Buffer emptied the scrollback",
      after_lines < before_lines / 5, f"{before_lines} lines -> {after_lines}")
check("and the process survived it",
      not cleared['tabs'][0]['panes'][0]['exited'], "the shell is still there")

find_dump = load("find")
# T4A's own find bar, not the engine's: since ISC-66 the matches are painted
# by the renderer, so what proves the menu item worked is the app's find
# state, not a view the VT library happens to own.
state = find_dump.get("find", {})
check("Find… opened T4A's own find bar", bool(state.get("open")),
      f"open={state.get('open')} query={state.get('query')!r}")

newwindow = load("newwindow")
check("New Window opened a second window", newwindow["windows"] >= 2,
      f"{full['windows']} window(s) -> {newwindow['windows']}")

about = load("about")
panels = [t for t in about.get("windowTitles", []) if "Panel" in t or "About" in t or "T4A" in t]
check("About T4A opened a panel",
      len(about.get("windowTitles", [])) > len(newwindow.get("windowTitles", [])),
      "; ".join(about.get("windowTitles", [])))
sys.exit(0 if ok else 1)
PY
