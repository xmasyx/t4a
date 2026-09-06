#!/bin/bash
# A long paste collapses to one line and travels whole.
#
#   Scripts/bench-paste.sh [app-bundle]
#
# Two poles, because a threshold with only one side proves nothing:
#   1. 200 lines  → the bubble holds ONE line, the marker with the count
#   2. 4 lines    → nothing is collapsed, the text is there as it was
# Then the marker is sent, and what reaches the pty must be the 200 lines
# again: collapsing is a way of SHOWING, never of trimming.
#
# The clipboard is saved and put back: this runs on a machine somebody uses.
set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-paste.fifo"
CONFIG_HOME="/tmp/t4a-paste-config"
DUMP=/tmp/t4a-paste-dump.json
STATUS=0
CLIP=/tmp/t4a-paste-clipboard.bak

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$DUMP"; send "dump $DUMP"; for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done; }
read_field() { /usr/bin/python3 -c "
import json,sys
c = json.load(open('$DUMP'))['composer']
print(c[sys.argv[1]])" "$1"; }

pbpaste > "$CLIP" 2>/dev/null || true
restore() { pbcopy < "$CLIP" 2>/dev/null || true; rm -f "$CLIP"; }
trap 'restore; t4a_stop_bench; rm -f "$FIFO"' EXIT

t4a_note_his_app
t4a_stop_bench
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "test channel never appeared" >&2; exit 1; }
sleep 3

# The pane must be listening BEFORE anything is pasted: while the bubble is on
# screen it owns the keyboard, so the command that opens the file has to be
# typed with the bubble away, or it lands in the bubble instead of the shell.
send "composer-mode never"; sleep 0.6
rm -f /tmp/t4a-paste-out.txt
send 'text cat > /tmp/t4a-paste-out.txt'; send "key return"; sleep 1
send "composer-mode always"; sleep 0.6

# ---- pole 1: 200 lines collapse -------------------------------------------
seq 1 200 | pbcopy
send "composer-paste"; sleep 0.7; dump
text="$(read_field text)"; lines="$(read_field lines)"
if [ "$lines" = "1" ] && [[ "$text" == *"+200 lines]" ]]; then verdict=ok; else verdict=FAILED; STATUS=1; fi
printf '%-28s lines=%-4s text=%-32s %s\n' "1 duecento righe" "$lines" "$text" "$verdict"

# ---- the whole text still travels -----------------------------------------
# `cat` writes as it reads, so the file can be counted with the pipe still
# open: closing it would need a key, and the key would go to the bubble.
send "composer-send"; sleep 2
got=$(wc -l < /tmp/t4a-paste-out.txt 2>/dev/null || echo 0)
if [ "$got" -ge 200 ]; then verdict=ok; else verdict=FAILED; STATUS=1; fi
printf '%-28s righe arrivate al pty=%-6s %s\n' "2 il testo viaggia intero" "$got" "$verdict"

# ---- pole 2 (negative): four lines are left alone -------------------------
printf 'uno\ndue\ntre\nquattro' | pbcopy
send "composer-paste"; sleep 0.7; dump
text="$(read_field text)"; lines="$(read_field lines)"
if [ "$lines" = "4" ] && [[ "$text" != *"Pasted text"* ]]; then verdict=ok; else verdict=FAILED; STATUS=1; fi
printf '%-28s lines=%-4s text=%-32s %s\n' "3 quattro righe, intatte" "$lines" "$(echo "$text" | tr '\n' '/')" "$verdict"

[ "$STATUS" = 0 ] && echo "paste: every pole held" || echo "paste: SOMETHING FAILED"
exit $STATUS
