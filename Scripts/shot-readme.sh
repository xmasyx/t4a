#!/bin/bash
# Rebuilds the approval photograph in the README (ISC-136).
#
#   Scripts/shot-readme.sh [app-bundle]
#
# The old one was taken before the waiting counter was fixed and shows
# `0 waiting` with a permission on the screen — the one thing the accent is
# for, dark at the one moment it exists for. This builds the same scene again.
#
# The scene is CONSTRUCTED, and every rule it follows was paid for:
#   * `codex`, never `claude`: claude's banner prints the account's email, and
#     codex's prints its model and directory and nothing else. Verified by
#     looking at it rather than assumed.
#   * a neutral directory, /tmp/t4a-demo, with a couple of ordinary files.
#   * the shell prompt reduced to `%~ %#`, because the real one is a username
#     and a machine name.
#   * no command that prints filesystem metadata — `ls -l`, `ps`, `id`,
#     `whoami`, `env` all put an account name on the screen, and no check on
#     the FILES of the repo can see what a command printed.
# Before the shutter, the whole dump is grepped for anything personal.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-shot.fifo"
CONFIG_HOME="/tmp/t4a-shot-config"
DUMP=/tmp/t4a-shot-dump.json
SCENE=/tmp/t4a-demo
OUT=design/readme/t4a-approval.png
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
command -v codex >/dev/null 2>&1 || { echo "codex is not on PATH" >&2; exit 1; }

for tool in winid; do
  bin=".build/t4a-$tool"
  if [ ! -x "$bin" ] || [ "Scripts/$tool.swift" -nt "$bin" ]; then
    mkdir -p .build && swiftc -O "Scripts/$tool.swift" -o "$bin"
  fi
done

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 60); do [ -s "$DUMP" ] && break; sleep 0.1; done
  [ -s "$DUMP" ] || { echo "the app never answered a dump" >&2; exit 1; }
}
field() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
try:
    print($1)
except Exception as error:
    print('missing:%s' % type(error).__name__)
"; }
note() { printf '%-44s %s\n' "$1" "$2"; }
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }
front() {
  for _ in $(seq 1 6); do
    send "activate"; sleep 0.6
    open -a "$PWD/$APP" 2>/dev/null || true
    sleep 1.4; dump
    [ "$(field "d['appActive']")" = "True" ] && { sleep 1; return 0; }
  done
  echo "T4A would not come to the front"; return 1
}

# The scene on disk: two small ordinary files and nothing of anybody's.
mkdir -p "$SCENE/src"
printf 'fn main() {\n    println!("hello from t4a");\n}\n' > "$SCENE/main.rs"
printf '# demo\n\nA folder with two files in it.\n' > "$SCENE/README.md"
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$SCENE/src/lib.rs"
/bin/rm -f "$SCENE/notes.txt"

stop
rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
# The card lives on the chat page, which is OFF by default since 6/09: this
# frame shows the option, and the README says so.
printf 'theme = black\nchat-page = true\n' > "$CONFIG_HOME/t4a/config.toml"
rm -f "$FIFO"
# English on purpose: the README is English, and `language = system` would
# follow the Mac. LANG is what Lang.detect reads first.
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME" --env LANG=en_US.UTF-8
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3

send "resize 1380x860"; sleep 0.5; send "movewindow 120,120"; sleep 0.6
send "text PROMPT='%~ %# '"; send "key return"; sleep 1
send "text clear"; send "key return"; sleep 1
# `untrusted` was the value in codex 0.148; 0.149 renamed the set to
# on-request/never and rejects the old word outright. Asked of the binary that
# is installed rather than remembered from a screenshot.
APPROVAL=on-request
codex --help 2>&1 | grep -q 'untrusted' && APPROVAL=untrusted
send "text cd $SCENE && codex --ask-for-approval $APPROVAL --sandbox read-only"
send "key return"
sleep 12
# Typed into codex's own line: the composer is off by default since 6/09.
send "text Read main.rs and then create a file notes.txt containing one line: hello"; send "key return"

echo "waiting for the permission to be asked..."
for _ in $(seq 1 30); do
  sleep 4
  dump
  [ "$(field "'yes' if d['card']['showing'] else 'no'")" = "yes" ] && break
done
note "the card is up" "$(field "repr(d['card'].get('title'))")"
note "the counter reads" "$(field "d['waiting']")"
[ "$(field "d['waiting']")" = "1" ] || { echo "the counter is not 1; nothing photographed"; STATUS=1; }

# The sonda that costs nothing and catches what no file check can: the whole
# observable state, read for anything personal, BEFORE the shutter.
# The same denylist make-release-tree.sh uses, from the same gitignored file:
# a script that spelled these words out would publish them (ISC-1).
PATTERN_FILE="Scripts/release/identity.pattern"
if [ ! -s "$PATTERN_FILE" ]; then
  note "NO DENYLIST at $PATTERN_FILE" "the scene was NOT swept"
  LEAKS=""
else
LEAKS="$(/usr/bin/python3 -c "
import json, re
raw = json.dumps(json.load(open('$DUMP')), ensure_ascii=False)
pattern = open('$PATTERN_FILE').readline().strip()
hits = sorted(set(re.findall(pattern, raw)))
print(' '.join(hits))
")"
fi
if [ -n "$LEAKS" ]; then
  note "IDENTITY IN THE DUMP" "$LEAKS"
  /usr/bin/python3 -c "
import json, re
d = json.load(open('$DUMP'))
pattern = open('$PATTERN_FILE').readline().strip()
rows = [r for r in d['tabs'][0]['panes'][0]['screen'] if re.search(pattern, r)]
print('    on the SCREEN:', rows if rows else 'nothing (only internal state)')
"
else
  note "nothing personal anywhere in the dump" "clean"
fi

if [ "$STATUS" = "0" ]; then
  front || STATUS=1
  # THIS instance, by pid: a leftover bench T4A would be photographed otherwise.
  WID="$(.build/t4a-winid "$(t4a_bench_pids | head -1)" || true)"
  if [ -n "$WID" ]; then
    mkdir -p design/readme
    screencapture -x -o -l "$WID" "$OUT"
    note "photographed" "$OUT"
  else
    echo "no window id"; STATUS=1
  fi
fi

send "key escape"; sleep 1
send "key ctrl-c"; sleep 0.5; send "key ctrl-c"; sleep 1
stop
[ "$STATUS" = "0" ] && echo "shot: taken" || echo "shot: FAILED"
exit "$STATUS"
