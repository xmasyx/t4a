#!/bin/bash
# ISC-242 — the fold pills sit on the rows they label while a precise scroll
# is in flight.
#
#   Scripts/bench-overlay-scroll.sh [app-bundle]      (default dist/T4A.app)
#
# The GPU translates every row by `scrollOffset` points between two trackpad
# deltas (ISC-235); the AppKit overlay placed its pills at whole rows. His
# video of 2026-09-05 17:49, read at 120 fps: bands glide, pills jump, and at
# 3.2 s a pill sits on the question below it. The probe is arithmetic on the
# dump — the pill's y must be a whole number of rows MINUS the offset the
# renderer reports, on the same dump.
#
# One precise event with no gesture end leaves the offset standing: the settle
# runs only when the trackpad says the gesture is over, and scrollgen never
# says so.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"
source "$(dirname "$0")/lib/bench-split.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-overlay.fifo"
CONFIG_HOME="/tmp/t4a-overlay-config"
DUMP=/tmp/t4a-overlay-dump.json
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
[ -x Scripts/.build-scrollgen ] || swiftc -O -o Scripts/.build-scrollgen Scripts/scrollgen.swift

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
grab() { rm -f "$2"; send "$1 $2"; for _ in $(seq 1 60); do [ -s "$2" ] && break; sleep 0.1; done
         [ -s "$2" ] || { echo "the app never answered $1" >&2; exit 1; }; }
py() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
p = next(p for t in d['tabs'] if t.get('active') for p in t['panes'] if p.get('active'))
$1"; }
pole() { if [ "$2" -eq 0 ]; then printf 'PASS  %s  %s\n' "$1" "$3"; else printf 'FAIL  %s  %s\n' "$1" "$3"; STATUS=1; fi; }
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }

stop
rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
printf 'scrollback-lines = 20000\ntheme = black\ncursor-motion = off\nmotion = true\n' \
  > "$CONFIG_HOME/t4a/config.toml"
rm -f "$FIFO"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3
PID="$(t4a_bench_pids | tail -1)"
t4a_split_screen "$PID"
send "activate"; sleep 1

echo "=== ISC-242: the pills move with the rows, at the pixel =============="
send "text seq 1 400"; send "key return"; sleep 3
grab dump "$DUMP"
END="$(py "print(p['endRow'])")"
ROWS="$(py "print(p['rows'])")"
# A fold in history, then the viewport parked so the strip is on screen.
FOLD_FROM=$(( END - ROWS - 60 )); FOLD_TO=$(( FOLD_FROM + 20 ))
send "foldrows $FOLD_FROM-$FOLD_TO"; sleep 0.5
TARGET=$(( FOLD_FROM - 5 ))
for _ in $(seq 1 12); do
  grab dump "$DUMP"; NOW="$(py "print(p['topVisibleRow'])")"
  [ "$NOW" = "$TARGET" ] && break
  send "scroll $(( NOW - TARGET ))"; sleep 0.35
done
sleep 0.8; grab dump "$DUMP"
AT_REST="$(py "
h = p['cellHeight']; off = p['scrollOffset']; ys = [f['y'] for f in d['foldTargets']]
print('offset=%.2f pills=%s rows=%s' % (off, ys, [round(y / h, 2) for y in ys]))")"
REST_OK="$(py "print(0 if p['scrollOffset'] == 0 and d['foldTargets'] and all(abs(f['y'] % p['cellHeight']) < 0.5 for f in d['foldTargets']) else 1)")"
pole "0 control: at rest, a pill on a whole row and offset zero" "$REST_OK" "$AT_REST"
[ "$REST_OK" -eq 0 ] || { echo "NOT RUN  no fold strip on screen — nothing to measure"; stop; exit 3; }

# One precise delta, aimed at the pane, no gesture end: the offset stands.
# The dump's rect is Cocoa (midpoint, y up); scrollgen wants CG (y down from
# the top of the main screen). Same lesson as 28/08: the two coordinate
# spaces mirror each other, and a bench that guesses one holds by luck.
SCREEN_H="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | awk -F', ' '{print $4}')"
X="$(py "print(int(p['surfaceRect']['x']))")"
Y="$(py "print(int($SCREEN_H - p['surfaceRect']['y']))")"
# A gesture that never ends: one pixel every 15 ms for six seconds (the engine calls the gesture over after 25 ms of silence). A single
# event is not enough — the engine declares the gesture over after a short
# silence and the settle animates the offset back to zero within 100 ms,
# which is what a dump 0.6 s later measured (first run of this bench: offset
# 0.00 on HEAD and on the fix alike, i.e. nothing measured).
Scripts/.build-scrollgen 400 1 15 pid="$PID" loc="$X,$Y" >/dev/null &
GEN=$!
sleep 1.5
# Three samples. Each is informative only when the offset sits at least two
# pixels from a row boundary: near a boundary a pill on a whole row and a
# pill on the offset are the same pixel, and HEAD would pass by accident.
LANDED=0; INFORMATIVE=0; WRONG=0; DETAIL=""
for sample in 1 2 3; do
  grab dump "$DUMP"
  read -r off info bad line <<< "$(py "
h = p['cellHeight']; off = p['scrollOffset']; ys = [f['y'] for f in d['foldTargets']]
informative = 1 if (ys and 2 <= off <= h - 2) else 0
# distance of (y + off) from the nearest whole row, in pixels
wrong = 1 if any(abs(((y + off) % h + h / 2) % h - h / 2) > 1.5 for y in ys) else 0
print('%.2f %d %d offset=%.2f/pills=%s' % (off, informative, wrong, off, ys))")"
  DETAIL="$DETAIL [$line]"
  /usr/bin/python3 -c "import sys; sys.exit(0 if float('$off') > 0.5 else 1)" && LANDED=$(( LANDED + 1 ))
  INFORMATIVE=$(( INFORMATIVE + info )); [ "$info" -eq 1 ] && WRONG=$(( WRONG + bad ))
  sleep 0.45
done
kill "$GEN" 2>/dev/null; wait "$GEN" 2>/dev/null
[ "$LANDED" -ge 1 ]; pole "1 the stream landed: the renderer holds a sub-row offset" "$?" "landed=$LANDED/3$DETAIL"
[ "$LANDED" -ge 1 ] || { echo "NOT RUN  the wheel events never reached the pane"; stop; exit 3; }
[ "$INFORMATIVE" -ge 2 ]; pole "   at least two samples away from a row boundary" "$?" "informative=$INFORMATIVE/3"
[ "$INFORMATIVE" -ge 2 ] || { echo "NOT RUN  the samples all fell near row boundaries — run again"; stop; exit 3; }
[ "$WRONG" -eq 0 ]; pole "2 every pill is a whole row MINUS the renderer's offset (±1.5 px)" "$?" "wrong=$WRONG of $INFORMATIVE"

stop
[ "$STATUS" = "0" ] && echo "overlay-scroll: every pole held" || echo "overlay-scroll: a pole FAILED"
exit "$STATUS"
