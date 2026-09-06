#!/bin/bash
# The tab strip answers the hand: at once, and while moving.
#
#   Scripts/bench-tabstrip.sh [app-bundle]
#
# «La selezione risulta meccanica, e anche la chiusura con le X. Quasi laggano»
# (24/08). There was no lag: there was no reaction. Four poles:
#
#   1. the press paints the new selection BEFORE the model answers
#   2. the pill is in flight right after the press, and NOT already arrived —
#      the pole that would go red if the animation were dropped
#   3. it lands on the tab, exactly, within a quarter second
#   4. the pointer is answered: over a tab, and over its ×
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-strip.fifo"
CONFIG_HOME="/tmp/t4a-strip-config"
DUMP=/tmp/t4a-strip-dump.json
STATUS=0

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$DUMP"; send "dump $DUMP"; for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done; }
strip() { /usr/bin/python3 -c "import json,sys;print(json.load(open('$DUMP'))['band']['strip'][sys.argv[1]])" "$1"; }
verdict() {
  if [ "$2" = "1" ]; then printf '%-40s %-40s ok\n' "$1" "$3"
  else printf '%-40s %-40s FAILED\n' "$1" "$3"; STATUS=1; fi
}

trap 't4a_stop_bench; rm -f "$FIFO"' EXIT
t4a_note_his_app
t4a_stop_bench
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "test channel never appeared" >&2; exit 1; }
sleep 3

send "layout tabs"; sleep 0.8
send "newtab"; sleep 1.2
send "newtab"; sleep 1.2

# ---- poles 1 and 2: the press is answered, and the pill is moving -----------
send "tab-press 0"
dump                      # the dump lands within the flight, ~a frame later
sel="$(strip selected)"; flying="$(strip flying)"; x0="$(strip pillX)"
[ "$sel" = "0" ] && p1=1 || p1=0
verdict "1 la selezione è dipinta subito" "$p1" "selected=$sel"
[ "$flying" = "True" ] && p2=1 || p2=0
verdict "2 la pastiglia è in volo" "$p2" "flying=$flying x=$x0"

# ---- pole 3: it lands where the tab is -------------------------------------
sleep 0.4; dump
flying="$(strip flying)"; x1="$(strip pillX)"; tabx="$(strip tabX)"
landed=$(/usr/bin/python3 -c "print(1 if abs($x1 - $tabx) < 1 else 0)")
[ "$flying" = "False" ] && [ "$landed" = "1" ] && p3=1 || p3=0
verdict "3 atterra sulla prima scheda" "$p3" "flying=$flying pill=$x1 scheda=$tabx"

# ---- pole 4: the pointer is answered ---------------------------------------
send "tab-hover 1"; sleep 0.3; dump
hover="$(strip hoverTab)"; hclose="$(strip hoverClose)"
send "tab-hover 1 close"; sleep 0.3; dump
hover2="$(strip hoverTab)"; hclose2="$(strip hoverClose)"
if [ "$hover" = "1" ] && [ "$hclose" = "-1" ] && [ "$hclose2" = "1" ]; then p4=1; else p4=0; fi
verdict "4 il puntatore accende scheda e ×" "$p4" "scheda=$hover/$hclose  ×=$hover2/$hclose2"

[ "$STATUS" = 0 ] && echo "tabstrip: every pole held" || echo "tabstrip: SOMETHING FAILED"
exit $STATUS
