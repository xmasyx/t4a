#!/bin/bash
# The README photographs, all of them, built on the bench bundle (ISC-251).
#
#   Scripts/shot-readme-set.sh [app-bundle]
#
# Same rules as shot-readme.sh, which stays the owner of the approval card:
# codex and never claude (claude's banner prints the account's email), a
# neutral folder, the prompt reduced to `%~ %#`, no command that prints an
# account name, and the dump swept against the identity denylist before every
# shutter. Seven frames: hero, the right column at work, the file preview,
# the palette, the warm-paper and light themes, and (via shot-readme.sh) the
# approval card.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"
APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-shotset.fifo"
CONFIG_HOME="/tmp/t4a-shotset-config"
DUMP=/tmp/t4a-shotset-dump.json
SCENE=/tmp/t4a-demo
OUTDIR=design/readme
PATTERN_FILE="Scripts/release/identity.pattern"
STATUS=0
[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
command -v codex >/dev/null 2>&1 || { echo "codex is not on PATH" >&2; exit 1; }
[ -x .build/t4a-winid ] || { mkdir -p .build && swiftc -O Scripts/winid.swift -o .build/t4a-winid; }
send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 60); do [ -s "$DUMP" ] && break; sleep 0.1; done
  [ -s "$DUMP" ] || { echo "the app never answered a dump" >&2; exit 1; }
}
field() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
try: print($1)
except Exception as e: print('?')"; }
note() { printf '  %-34s %s\n' "$1" "$2"; }
front() {
  for _ in $(seq 1 6); do
    send "activate"; sleep 0.6
    open -a "$PWD/$APP" 2>/dev/null || true
    sleep 1.2; dump
    [ "$(field "d['appActive']")" = "True" ] && { sleep 0.6; return 0; }
  done
  echo "T4A would not come to the front"; return 1
}
sweep() {  # -> prints hits found in what the frame can SHOW; empty is clean
  dump
  [ -s "$PATTERN_FILE" ] || { echo "NO-DENYLIST"; return; }
  # Internal state (the adapter's executable path, the facts provider's PATH)
  # carries the account name and is never drawn. What is drawn: the screen
  # rows, the titles, the rail, the palette, the preview path, the dash cells.
  /usr/bin/python3 -c "
import json, re
d = json.load(open('$DUMP'))
shown = []
for tab in d.get('tabs', []):
    shown.append(tab.get('title', ''))
    for pane in tab.get('panes', []):
        shown.extend(pane.get('screen', [])); shown.append(pane.get('title', '')); shown.append(pane.get('cwd', ''))
shown.append(json.dumps(d.get('rail', ''), ensure_ascii=False))
shown.append(json.dumps(d.get('palette', ''), ensure_ascii=False))
shown.append(json.dumps(d.get('preview', ''), ensure_ascii=False))
shown.append(json.dumps(d.get('dash', {}).get('cells', ''), ensure_ascii=False))
shown.append(json.dumps(d.get('card', ''), ensure_ascii=False))
pattern = open('$PATTERN_FILE').readline().strip()
print(' '.join(sorted(set(re.findall(pattern, '\\n'.join(map(str, shown)))))))"
}
shot() {  # name [keep-front]  — keep-front: the frame is already procured, do not touch focus
  local hits; hits="$(sweep)"
  if [ -n "$hits" ]; then note "IDENTITY IN THE DUMP ($1)" "$hits"; STATUS=1; return 1; fi
  [ "${2:-}" = "keep-front" ] || front || { STATUS=1; return 1; }
  local pid wid; pid="$(t4a_bench_pids | head -1)"
  wid="$(.build/t4a-winid ${pid:+$pid} || true)"
  [ -n "$wid" ] || { echo "no window id"; STATUS=1; return 1; }
  mkdir -p "$OUTDIR"
  screencapture -x -o -l "$wid" "$OUTDIR/$1.png"
  note "photographed" "$OUTDIR/$1.png"
}
wait_turn_closed() {  # seconds — the pane says waitingForYou once the agent stops
  sleep 3
  for _ in $(seq 1 "$1"); do
    sleep 2; dump
    [ "$(field "d['tabs'][0]['panes'][0]['waitingForYou']")" = "True" ] && return 0
  done
  return 1
}

mkdir -p "$SCENE/src"
printf 'fn main() {\n    println!("hello from t4a");\n}\n' > "$SCENE/main.rs"
printf '# demo\n\nA folder with two files in it.\n' > "$SCENE/README.md"
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$SCENE/src/lib.rs"

t4a_note_his_app 2>/dev/null || true
t4a_stop_bench
rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
printf 'theme = black\n' > "$CONFIG_HOME/t4a/config.toml"
rm -f "$FIFO"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME" --env LANG=en_US.UTF-8
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3
send "resize 1380x860"; sleep 0.5; send "movewindow 120,120"; sleep 0.6
send "text PROMPT='%~ %# '"; send "key return"; sleep 0.8
send "text clear"; send "key return"; sleep 0.8
send "text cd $SCENE && codex --sandbox read-only"
send "key return"
sleep 12

send "text Read main.rs and say in one sentence what it prints."; send "key return"
wait_turn_closed 30 || note "turn 1" "did not close in time"
send "text Which file in this folder is the library, and what does its one function do?"; send "key return"
wait_turn_closed 30 || note "turn 2" "did not close in time"
sleep 1
shot t4a-hero

# The column at work: the frame is procured first, then the question is
# asked and the shutter follows while the tools are still running.
front || STATUS=1
send "text Read all three files, then explain in one line each what they are for."; send "key return"
sleep 2.2
shot t4a-column-at-work keep-front
wait_turn_closed 30 || note "turn 3" "did not close in time"

send "preview-path $SCENE/README.md"; sleep 1.5
shot t4a-preview
send "preview-close"; sleep 0.6

# The palette folds when the window loses key, so focus comes first.
front || STATUS=1
send "palette open"; sleep 0.9
dump; note "palette open" "$(field "d['palette']['open']")"
shot t4a-palette keep-front
send "palette close"; sleep 0.3; send "key escape"; sleep 0.6

# Themes on a plain shell: an agent paints its own dark cells, and a dark
# cell on warm paper is the agent's palette, not ours.
send "key ctrl-c"; sleep 0.5; send "key ctrl-c"; sleep 1.5
send "clearbuffer"; sleep 0.4
send "text cat main.rs src/lib.rs README.md"; send "key return"; sleep 1.2
send "theme paper"; sleep 1
shot t4a-theme-paper
send "theme light"; sleep 1
shot t4a-theme-light
send "theme black"; sleep 0.5
t4a_stop_bench
rm -f "$FIFO"
[ "$STATUS" = "0" ] && echo "shots: taken" || echo "shots: INCOMPLETE"
exit "$STATUS"
