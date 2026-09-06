#!/bin/bash
# ISC-253 — a window a bench opens places itself in the right half.
#
#   Scripts/bench-split-default.sh [app-bundle]      (default dist/T4A.app)
#
# Three launches, each from an empty config home, frame read from the dump:
#   1. plain test mode          → x at the half, width at most a half (right half)
#   2. a saved `window-frame`   → that frame, untouched (ISC-109 still wins)
#   3. T4A_BENCH_FRAME=free     → the centre, as before (the way out)
# Negative on HEAD before ISC-253: pole 1 fails, 2 and 3 pass.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-splitdef.fifo"
CONFIG_HOME="/tmp/t4a-splitdef-config"
DUMP=/tmp/t4a-splitdef-dump.json
STATUS=0
[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
grab() { rm -f "$2"; send "$1 $2"; for _ in $(seq 1 60); do [ -s "$2" ] && break; sleep 0.1; done
         [ -s "$2" ] || { echo "the app never answered $1" >&2; exit 1; }; }
win() { /usr/bin/python3 -c "
import json; w = json.load(open('$DUMP'))['window']; print(w['x'], w['y'], w['width'], w['height'])"; }
pole() { if [ "$2" -eq 0 ]; then printf 'PASS  %s  %s\n' "$1" "$3"; else printf 'FAIL  %s  %s\n' "$1" "$3"; STATUS=1; fi; }
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }

read -r SW SH <<< "$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | awk -F', ' '{print $3, $4}')"
HALF=$(( SW / 2 ))

# launch <extra open args…>: fresh config home (plus whatever the caller wrote), one window, one dump.
launch() {
  stop; rm -f "$FIFO"
  open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME" "$@"
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
  sleep 2.5
  grab dump "$DUMP"
  read -r X Y W H <<< "$(win)"
}

echo "=== ISC-253: screen ${SW}x${SH}, half $HALF ===================="

rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
launch
[ "$X" -ge $(( HALF - 1 )) ] && [ "$W" -le $(( HALF + 1 )) ] && [ "$W" -ge $(( HALF - 40 )) ]; pole "1 right half on a first launch" $? "x=$X w=$W (half $HALF)"

rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
printf 'window-frame = "120 200 900 600 0 0 %d %d "\n' "$SW" "$SH" > "$CONFIG_HOME/t4a/config.toml"
launch
[ "$X" -eq 120 ] && [ "$W" -eq 900 ]; pole "2 a saved frame still wins" $? "x=$X y=$Y w=$W h=$H (asked 120 200 900 600)"

rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
launch --env T4A_BENCH_FRAME=free
[ "$X" -lt $(( HALF - 1 )) ] || [ "$W" -gt $(( HALF + 1 )) ]; pole "3 T4A_BENCH_FRAME=free keeps the centre" $? "x=$X w=$W"

stop
exit $STATUS
