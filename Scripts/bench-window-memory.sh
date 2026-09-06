#!/bin/bash
# ISC-109 — does the window come back where you left it, and does full screen
# poison the size it comes back to?
#
#   Scripts/bench-window-memory.sh [app-bundle]
#
# Three launches on one isolated configuration directory:
#   1. place the window at a size and a position nobody would land on by
#      accident, then quit;
#   2. relaunch and read the frame back — both numbers, not just the size;
#   3. go full screen, come back, quit, relaunch, and read it again. A window
#      that reopens the size of a display has lost the size the user picked.
#
# The frames are read from the window server, so what is compared is where the
# window IS, not what the app believes about it.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-memory.fifo"
CONFIG_HOME="/tmp/t4a-memory-config"
CONFIG="$CONFIG_HOME/t4a/config.toml"
FRAME_BIN=".build/t4a-winframe"

WANT_X=140
WANT_Y=150
WANT_W=1180
WANT_H=760

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
if [ ! -x "$FRAME_BIN" ] || [ Scripts/winframe.swift -nt "$FRAME_BIN" ]; then
  mkdir -p .build && swiftc -O Scripts/winframe.swift -o "$FRAME_BIN"
fi

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }
launch() {
  rm -f "$FIFO"
  open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
  sleep 2
}

stop
rm -rf "$CONFIG_HOME"
mkdir -p "$CONFIG_HOME"

echo "==> 1. place the window and quit"
launch
send "resize ${WANT_W}x${WANT_H}"
sleep 0.5
send "movewindow ${WANT_X},${WANT_Y}"
sleep 1.2
PLACED="$("$FRAME_BIN")"
echo "    placed at: $PLACED"
stop

echo "==> 2. relaunch and read the frame back"
launch
REOPENED="$("$FRAME_BIN")"
echo "    reopened at: $REOPENED"

echo "==> 3. full screen, back, quit"
send "fullscreen on"
sleep 4
FULL="$("$FRAME_BIN")"
SAVED_WHILE_FULL="$(grep '^window-frame' "$CONFIG" || true)"
echo "    full screen frame: $FULL"
echo "    file while full screen: $SAVED_WHILE_FULL"
send "fullscreen off"
sleep 4
stop

echo "==> 4. relaunch after full screen"
launch
AFTER_FULL="$("$FRAME_BIN")"
echo "    reopened at: $AFTER_FULL"
stop

/usr/bin/python3 - "$PLACED" "$REOPENED" "$FULL" "$AFTER_FULL" "$WANT_X $WANT_Y $WANT_W $WANT_H" <<'PY'
import sys
placed, reopened, full, after_full, want = sys.argv[1:6]
def n(s): return [int(v) for v in s.split()]
ok = True
def check(label, got, expect, tolerance=2):
    global ok
    good = all(abs(a - b) <= tolerance for a, b in zip(n(got), n(expect)))
    ok = ok and good
    print(f"{'PASS' if good else 'FAIL'}  {label}: {got}  (expected {expect})")

check("the window was placed where the test asked", placed, want)
check("it reopened at the same size AND position", reopened, placed)
gotfull, gotplaced = n(full), n(placed)
bigger = gotfull[2] > gotplaced[2] and gotfull[3] > gotplaced[3]
print(f"{'PASS' if bigger else 'FAIL'}  full screen really filled the display: {full}")
check("after full screen it still reopens at the chosen frame", after_full, placed)
sys.exit(0 if ok and bigger else 1)
PY
