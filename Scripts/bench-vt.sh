#!/bin/bash
# ISC-135 — what this terminal tells a program that asks, measured.
#
#   Scripts/bench-vt.sh [app-bundle]
#
# The claim allowed the answer to be read off SwiftTerm's source and written in
# the README. It is read there, and then asked of the running terminal, because
# a reply is a behaviour and a source file is a plan: the version resolved in
# Package.resolved, the branch it was built from and a conditional nobody
# noticed all sit between the two.
#
# Every probe is a shell line inside a real pane. The reply arrives as INPUT —
# that is what these sequences do — so each one is read back with `read -d` up
# to its terminator and printed where the dump can see it.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-vt.fifo"
CONFIG_HOME="/tmp/t4a-vt-config"
DUMP=/tmp/t4a-vt-dump.json
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 60); do [ -s "$DUMP" ] && break; sleep 0.1; done
  [ -s "$DUMP" ] || { echo "the app never answered a dump" >&2; exit 1; }
}
screen_has() { /usr/bin/python3 -c "
import json, sys
d = json.load(open('$DUMP'))
rows = d['tabs'][0]['panes'][0]['screen']
print('yes' if any('$1' in row for row in rows) else 'no')
"; }
line_with() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
rows = d['tabs'][0]['panes'][0]['screen']
hit = [r.strip() for r in rows if '$1' in r and 'read' not in r]
print(hit[-1] if hit else '(nothing came back)')
"; }
verdict() {
  local name="$1" got="$2" want="$3" mark="ok"
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-40s %-12s (want %s) %s\n' "$name" "$got" "$want" "$mark"
}
note() { printf '%-40s %s\n' "$1" "$2"; }
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }

stop
rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
printf 'theme = black\n' > "$CONFIG_HOME/t4a/config.toml"
rm -f "$FIFO"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3

REPLIES=/tmp/t4a-vt-replies.txt
rm -f "$REPLIES"
reply_of() { /usr/bin/python3 -c "
import sys
try:
    for line in open('$REPLIES'):
        if line.startswith('$1='):
            print(line.rstrip('\n')[len('$1='):] or '(silence)')
            sys.exit()
except FileNotFoundError:
    pass
print('(no answer file)')
"; }

echo "=== what the terminal answers, asked of the terminal ================"
# The probe is COPIED out of the repo before it is run.
#
# Reading it from ~/Desktop made the pane's shell hang with no output and no
# file: a child of the app touching a TCC-protected folder waits on a consent
# it cannot ask for, because the app is not the front process. Measured on
# 2026-08-22 — the identical script under /tmp finished in a second. It is not
# a length problem: a 231-character command line through the same channel runs
# fine, which was the first guess and was wrong.
cp Scripts/vt-probe.zsh /tmp/t4a-vt-probe.zsh
send "text zsh -f /tmp/t4a-vt-probe.zsh $REPLIES"
send "key return"
for _ in $(seq 1 40); do
  grep -q '^DONE=' "$REPLIES" 2>/dev/null && break
  sleep 0.5
done
grep -q '^DONE=' "$REPLIES" 2>/dev/null || { echo "the probe never finished" >&2; STATUS=1; }
[ -s "$REPLIES" ] && sed 's/^/    /' "$REPLIES"
echo ""

verdict "DA1 is the xterm-class VT525 reply" \
  "$(reply_of DA1)" "ESC[?65;4;1;2;6;21;22;17;28c"
verdict "DA2 is VT525, firmware 20, PC keyboard" "$(reply_of DA2)" "ESC[>65;20;1c"
verdict "DSR says no malfunction" "$(reply_of DSR)" "ESC[0n"
note    "CPR (a row and a column, wherever the cursor was)" "$(reply_of CPR)"
verdict "CPR answers with a position" \
  "$(reply_of CPR | grep -cE '^ESC\[[0-9]+;[0-9]+R$')" "1"
note    "XTVERSION" "$(reply_of XTV)"
verdict "XTVERSION names the emulator" "$(reply_of XTV | grep -c 'SwiftTerm')" "1"
verdict "OSC 21 answers nothing" "$(reply_of OSC21)" "(silence)"

echo ""
echo "=== SGR 5: parsed, not drawn, and not a crash ======================="
dump
verdict "the text is on the screen" "$(screen_has 'blinking text stays legible')" "yes"
verdict "and the pane is alive" "$(/usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
print('yes' if not d['tabs'][0]['panes'][0]['exited'] else 'no')")" "yes"

stop
[ "$STATUS" = "0" ] && echo "vt: every pole held" || echo "vt: a pole FAILED"
exit "$STATUS"
