#!/bin/bash
# A screenshot dragged onto T4A lands somewhere.
#
#   Scripts/bench-drop.sh [app-bundle]
#
# Before this, neither the pane nor the bubble had registered a single dragged
# type, so a drag bounced with no sign at all. Three poles:
#
#   1. the pane says which types it registered — a handler nobody registered
#      for is never called, and from outside that looks exactly like a handler
#      that does nothing
#   2. a file dropped on the pane reaches the pty as its path
#   3. a file dropped on the bubble becomes text in the bubble
#
# What is NOT here: AppKit carrying the mouse. `performDragOperation` calls the
# same `acceptDrop` this bench calls, and the registered types above are what
# decides whether AppKit calls it at all.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-drop.fifo"
CONFIG_HOME="/tmp/t4a-drop-config"
DUMP=/tmp/t4a-drop-dump.json
OUT=/tmp/t4a-drop-out.txt
SHOT=/tmp/t4a-drop-probe.png
STATUS=0

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$DUMP"; send "dump $DUMP"; for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done; }
field() { /usr/bin/python3 -c "import json,sys;print(json.load(open('$DUMP'))['composer'][sys.argv[1]])" "$1"; }
verdict() {
  if [ "$2" = "1" ]; then printf '%-36s %-44s ok\n' "$1" "$3"
  else printf '%-36s %-44s FAILED\n' "$1" "$3"; STATUS=1; fi
}

trap 't4a_stop_bench; rm -f "$FIFO"' EXIT
t4a_note_his_app
t4a_stop_bench
rm -rf "$CONFIG_HOME" "$FIFO" "$OUT"; mkdir -p "$CONFIG_HOME"
screencapture -x -R 0,0,12,12 "$SHOT"

open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "test channel never appeared" >&2; exit 1; }
sleep 3

# ---- pole 1: the pane is listening for drags -------------------------------
dump
types="$(field dropTypes)"
case "$types" in *public.file-url*) p1=1 ;; *) p1=0 ;; esac
verdict "1 il riquadro registra i tipi" "$p1" "$(echo "$types" | cut -c1-40)"

# ---- pole 2: dropped on the pane -------------------------------------------
send "composer-mode never"; sleep 0.6
send "text cat > $OUT"; send "key return"; sleep 1.2
send "drop-file $SHOT"; sleep 0.8
send "key return"; sleep 1.2
got="$(head -1 "$OUT" 2>/dev/null | tr -d '"')"
[ "$got" = "$SHOT" ] && p2=1 || p2=0
verdict "2 il riquadro riceve il percorso" "$p2" "${got:-nulla}"

# ---- pole 3: dropped on the bubble -----------------------------------------
send "composer-mode always"; sleep 0.6
send "fire Message This Session"; sleep 0.6
send "drop-file $SHOT"; sleep 0.8; dump
text="$(field text)"
[ "$text" = "[Image #1]" ] && p3=1 || p3=0
verdict "3 la bolla mostra [Image #1]" "$p3" "${text:-nulla}"

[ "$STATUS" = 0 ] && echo "drop: every pole held" || echo "drop: SOMETHING FAILED"
exit $STATUS
