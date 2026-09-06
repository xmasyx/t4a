#!/bin/bash
# ISC-234 — a trackpad scroll is drawn on the next frame, not on the next byte.
#
#   Scripts/bench-wheel-redraw.sh [app-bundle]      (default dist/T4A.app)
#
# The engine asks for a repaint after a scroll through `setNeedsDisplay(rect)`,
# a different door from the `needsDisplay` property the GPU view used to watch:
# on HEAD 6de72cf the grid moved 22 rows and the renderer presented 0 frames.
#
# Pole 0 is a CONTROL and runs first: an `echo` must produce frames and vsyncs.
# With the display asleep the display link never ticks and every count below
# is zero for a reason that has nothing to do with the code (30/08: three
# identical photographs of a black screen were written up as a defect). A
# control that fails makes the whole bench NOT RUN.
#
# Events come from `Scripts/scrollgen.swift`: precise (trackpad) deltas posted
# by the window server, each carrying its own location, aimed by pid.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh
APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-wheel.fifo"; CFG="/tmp/t4a-wheel-config"
send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
grab() { rm -f "$2"; send "$1 $2"; for _ in $(seq 1 60); do [ -s "$2" ] && break; sleep 0.2; done; }
stat_of() { /usr/bin/python3 -c "import json; s=json.load(open('$1')); print(int(s['$2']))"; }
top_of() { /usr/bin/python3 -c "
import json; d=json.load(open('$1'))
print(next(p['topVisibleRow'] for t in d['tabs'] if t.get('active') for p in t['panes'] if p.get('active')))"; }
STATUS=0
pole() { if [ "$2" -eq 0 ]; then printf 'PASS  %s  %s\n' "$1" "$3"; else printf 'FAIL  %s  %s\n' "$1" "$3"; STATUS=1; fi; }
[ -x Scripts/.build-scrollgen ] || swiftc -O -o Scripts/.build-scrollgen Scripts/scrollgen.swift
[ -x Scripts/.build-movepoint ] || swiftc -O -o Scripts/.build-movepoint Scripts/movepoint.swift
t4a_stop_bench; sleep 1
rm -rf "$CFG" "$FIFO"; mkdir -p "$CFG/t4a"; printf 'scrollback-lines = 100000\ntheme = black\n' > "$CFG/t4a/config.toml"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done; sleep 3
PID=$(t4a_bench_pids | tail -1)
send "text seq 1 3000"; send "key return"; sleep 3
send activate; sleep 0.5; Scripts/.build-movepoint 400 650; sleep 0.5

send renderreset; send "text echo controllo"; send "key return"; sleep 0.6; grab renderstats /tmp/wheel-control.json
CF=$(stat_of /tmp/wheel-control.json frames); CV=$(stat_of /tmp/wheel-control.json vsyncs)
if [ "$CF" -lt 1 ] || [ "$CV" -lt 1 ]; then
  echo "NOT RUN  0 control: an echo produced frames=$CF vsyncs=$CV — display asleep or renderer inactive"
  t4a_stop_bench; exit 3
fi
pole "0 control: an echo is drawn" 0 "frames=$CF vsyncs=$CV"

grab dump /tmp/wheel-before.json; T0=$(top_of /tmp/wheel-before.json)
send renderreset
Scripts/.build-scrollgen 120 3 8.33 pid=$PID loc=400,650 >/dev/null
sleep 0.3; grab renderstats /tmp/wheel-after.json; grab dump /tmp/wheel-dump.json
T1=$(top_of /tmp/wheel-dump.json); ROWS=$((T0 - T1)); FR=$(stat_of /tmp/wheel-after.json frames)
R=1; [ "$ROWS" -ge 10 ] && R=0
pole "1 the wheel moved the grid" $R "rows=$ROWS (top $T0 -> $T1)"
R=1; [ "$FR" -ge "$ROWS" ] && [ "$ROWS" -ge 10 ] && R=0
pole "2 the scroll was drawn: frames >= rows moved" $R "frames=$FR rows=$ROWS  (HEAD 6de72cf: frames=0)"
t4a_stop_bench
exit $STATUS
