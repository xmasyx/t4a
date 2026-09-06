#!/bin/bash
# ISC-66 and ISC-67 — searching on the GPU, and a cursor with a physics.
#
#   Scripts/bench-find-cursor.sh
#
# ISC-66: ⌘F over a full scrollback, literal and regular expression, with the
# hits handed to the renderer as spans and painted with the cells. "No delay
# at the first keystroke" is measured as the time the search itself took over
# the whole retained buffer — the thing that would make a keystroke feel slow.
#
# ISC-67: the cursor's drawn position is recorded frame by frame. What the
# numbers have to show is movement BETWEEN cells — fractions, not integers —
# a settle, and then two poles: the same jump with the motion switch off, and
# the same jump under the system's Reduce Motion setting.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

FIFO="/tmp/t4a-find.fifo"
CONFIG_HOME="/tmp/t4a-find-config"
LOG="/tmp/t4a-200mb.log"

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
grab() { rm -f "$2"; send "$1 $2"; for _ in $(seq 1 40); do [ -s "$2" ] && break; sleep 0.15; done; }

t4a_stop_bench
sleep 1.5
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME/t4a"
printf 'scrollback-lines = 100000\ntheme = black\ncursor-motion = glide\n' \
  > "$CONFIG_HOME/t4a/config.toml"
open -n dist/T4A.app --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3

echo "==> filling the buffer"
send "text head -c 30000000 $LOG"
send "key return"
sleep 14

echo "==> ⌘F, literal"
send "find MetalRenderer"
sleep 1.5
grab dump /tmp/t4a-find-literal.json
Scripts/drive.sh shot design/evidence/f3-find.png >/dev/null

echo "==> next match, and the one after"
send "findstep 1"; sleep 0.8
grab dump /tmp/t4a-find-step.json

echo "==> ⌘F, regular expression"
send "find regex warning:|failed"
sleep 1.5
grab dump /tmp/t4a-find-regex.json
send "findclose"
sleep 0.5

echo "==> the cursor, with motion"
send "renderreset"
send "key return"; sleep 0.8; send "text aaaaaaaa"
sleep 1.2
grab renderstats /tmp/t4a-cursor-glide.json

echo "==> the cursor, with the switch off"
send "motion off"
send "renderreset"
send "key return"; sleep 0.8; send "text bbbbbbbb"
sleep 1.2
grab renderstats /tmp/t4a-cursor-off.json
send "motion on"

echo "==> the cursor, under the system's Reduce Motion"
BEFORE=$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo 0)
defaults write com.apple.universalaccess reduceMotion -bool true 2>/dev/null || true
sleep 1
send "renderreset"
send "key return"; sleep 0.8; send "text cccccccc"
sleep 1.2
grab renderstats /tmp/t4a-cursor-reduce.json
if [ "$BEFORE" = "1" ]; then
  defaults write com.apple.universalaccess reduceMotion -bool true 2>/dev/null || true
else
  defaults write com.apple.universalaccess reduceMotion -bool false 2>/dev/null || true
fi

send "key return"
sleep 0.5
t4a_stop_bench
rm -f "$FIFO"

/usr/bin/python3 <<'PY'
import json, sys
def load(name): return json.load(open(f"/tmp/t4a-{name}.json"))
ok = True
def check(label, condition, detail):
    global ok
    ok = ok and condition
    print(f"{'PASS' if condition else 'FAIL'}  {label}: {detail}")

literal = load("find-literal")["find"]
step = load("find-step")["find"]
regex = load("find-regex")["find"]

check("ISC-66  ⌘F opens and finds", literal["open"] and literal["matches"] > 100,
      f"{literal['matches']} hits for {literal['query']!r} over "
      f"{literal['rowsScanned']} rows")
check("ISC-66  the whole buffer is searched in a keystroke's worth of time",
      literal["seconds"] < 0.1,
      f"{literal['seconds'] * 1000:.1f} ms for {literal['rowsScanned']} rows"
      f"{' (stopped at the limit)' if literal['truncated'] else ''}")
check("ISC-66  next moves to another match",
      step["current"] != literal["current"] and step["matches"] == literal["matches"],
      f"match {literal['current']} -> {step['current']} of {step['matches']}, "
      f"row {literal['currentRow']} -> {step['currentRow']}")
check("ISC-66  a regular expression is a different search",
      regex["matches"] > 0 and regex["query"] != literal["query"]
      and regex["currentRow"] != literal["currentRow"],
      f"{regex['matches']} hits for {regex['query']!r} in "
      f"{regex['seconds'] * 1000:.1f} ms, first at row {regex['currentRow']} "
      f"against {literal['currentRow']} for {literal['query']!r}")

def trail(name):
    return [tuple(p) for p in load(name).get("cursorTrail", [])]

glide, off, reduce = trail("cursor-glide"), trail("cursor-off"), trail("cursor-reduce")
def fractions(points):
    return [p for p in points if abs(p[1] - round(p[1])) > 0.02]
check("ISC-67  the cursor is drawn BETWEEN cells while it travels",
      len(fractions(glide)) > 10,
      f"{len(fractions(glide))} of {len(glide)} recorded positions are sub-cell, "
      f"x from {glide[0][1]:.2f} to {glide[-1][1]:.2f}" if glide else "no trail recorded")
check("ISC-67  and it settles",
      bool(glide) and abs(glide[-1][1] - round(glide[-1][1])) < 0.05,
      f"last position x={glide[-1][1]:.3f}" if glide else "—")
check("ISC-67  the switch off means no in-between positions at all",
      len(fractions(off)) == 0,
      f"{len(fractions(off))} sub-cell positions in {len(off)} frames")
check("ISC-67  Reduce Motion does the same without being asked",
      len(fractions(reduce)) == 0 and load("cursor-reduce").get("reduceMotion", 0) == 1,
      f"{len(fractions(reduce))} sub-cell positions, "
      f"reduceMotion = {load('cursor-reduce').get('reduceMotion', 0):.0f}")
sys.exit(0 if ok else 1)
PY
