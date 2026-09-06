#!/bin/bash
# F3 — the numbers the GPU renderer is judged on.
#
#   Scripts/bench-render.sh [seconds]
#
# Three measurements, in this order:
#
#   1. THE POUR. A log of at least 200 MB is cat'ed into the terminal. This
#      fills the buffer and, incidentally, measures how fast the engine can
#      parse — reported separately, because parsing is SwiftTerm's job and
#      drawing is ours, and a single number that mixes them says nothing about
#      either.
#   2. THE SCROLL (this is ISC-20/21/37). With the buffer full, the viewport
#      is scrolled continuously for thirty seconds, so every single frame has
#      content the renderer has never drawn. Dropped frames, GPU time and CPU
#      time come out of the renderer's own counters — the GPU time is the
#      command buffer's own clock, not a stopwatch around the encode.
#   3. THE SILENCE (ISC-22). The terminal is left alone for ten seconds and
#      the frames it drew in that time are counted. The answer has to be zero,
#      not "a few".
#
# Everything runs against the RELEASE bundle, because a debug build measures
# the debug build.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

SECONDS_TO_SCROLL="${1:-30}"
FIFO="/tmp/t4a-render.fifo"
CONFIG_HOME="/tmp/t4a-render-config"
LOG="/tmp/t4a-200mb.log"
APP="${T4A_APP:-dist/T4A.app}"

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
stats() {
  rm -f "$2"
  send "renderstats $2"
  for _ in $(seq 1 40); do [ -s "$2" ] && break; sleep 0.1; done
}

# The log: 200 MB of realistic terminal output — colour, varying line length,
# the occasional box character — not 200 MB of the same byte, which would let
# every cache in the stack look better than it is.
if [ ! -s "$LOG" ] || [ "$(stat -f %z "$LOG")" -lt 209715200 ]; then
  echo "==> writing $LOG (this happens once)"
  /usr/bin/python3 - "$LOG" <<'PY'
import sys, random
random.seed(20260820)
words = ["compiling", "linking", "resolving", "fetching", "TerminalCore", "MetalRenderer",
         "SwiftTermBackend", "warning:", "note:", "ok", "failed", "0x1f4a2", "…", "┌───┐"]
colours = [f"\033[3{i}m" for i in range(1, 8)] + [f"\033[38;5;{i}m" for i in (33, 208, 118, 141)]
with open(sys.argv[1], "w") as out:
    written = 0
    line = 0
    while written < 210 * 1024 * 1024:
        parts = [f"{line:08d}"]
        for _ in range(random.randint(4, 14)):
            parts.append(random.choice(colours) + random.choice(words) + "\033[0m")
        text = " ".join(parts) + "\n"
        out.write(text)
        written += len(text)
        line += 1
PY
fi
echo "==> log is $(du -h "$LOG" | cut -f1), $(wc -l < "$LOG" | tr -d ' ') lines"

t4a_stop_bench
sleep 1.5
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME/t4a"
# A big scrollback, because "a full buffer" is the point: a hundred thousand
# lines of a hundred and eighteen cells is the ~200 MB of cells the claim is
# about, and it is what makes the scroll traverse real content.
cat > "$CONFIG_HOME/t4a/config.toml" <<'CONF'
# written by bench-render.sh
scrollback-lines = 100000
theme = black
CONF

# A stale fifo from a killed run is refused by the app now (ISC-128),
# so the bench clears its own doorstep instead of inheriting one.
rm -f "$FIFO"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3
send "fullscreen on"
sleep 4

echo "==> 1. the pour"
send "renderreset"
POUR_START=$(/usr/bin/python3 -c "import time; print(time.time())")
send "text cat $LOG"
send "key return"
# Wait for the prompt to come back: the block log knows when the command ended.
for _ in $(seq 1 600); do
  rm -f /tmp/t4a-render-dump.json
  send "dump /tmp/t4a-render-dump.json"
  sleep 0.5
  if [ -s /tmp/t4a-render-dump.json ] && /usr/bin/python3 -c "
import json, sys
d = json.load(open('/tmp/t4a-render-dump.json'))
b = [p for t in d['tabs'] for p in t['panes'] if p['active']][0]['blocks']
sys.exit(0 if b and b[-1]['durationMs'] == -1 and not b[-1]['command'] else 1)
" 2>/dev/null; then break; fi
done
POUR_END=$(/usr/bin/python3 -c "import time; print(time.time())")
stats "" /tmp/t4a-render-pour.json

echo "==> 2. the scroll, ${SECONDS_TO_SCROLL}s after a 1.5s warm-up"
send "scrollbench $SECONDS_TO_SCROLL 1.5"
sleep "$((SECONDS_TO_SCROLL + 5))"
stats "" /tmp/t4a-render-scroll.json

echo "==> 3. the silence, 10s"
send "renderreset"
sleep 11
stats "" /tmp/t4a-render-idle.json

send "fullscreen off"
sleep 3
t4a_stop_bench
rm -f "$FIFO"

/usr/bin/python3 - "$POUR_START" "$POUR_END" "$LOG" "$SECONDS_TO_SCROLL" <<'PY'
import json, os, sys
start, end, log, wanted = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3], float(sys.argv[4])
def load(name): return json.load(open(f"/tmp/t4a-render-{name}.json"))
pour, scroll, idle = load("pour"), load("scroll"), load("idle")
size = os.path.getsize(log)

ok = True
def check(label, condition, detail):
    global ok
    ok = ok and condition
    print(f"{'PASS' if condition else 'FAIL'}  {label}: {detail}")

print(f"\n--- the pour: {size / 1e6:.0f} MB in {end - start:.1f}s "
      f"= {size / 1e6 / max(0.001, end - start):.1f} MB/s through the parser")
print(f"    frames drawn while pouring {pour['frames']:.0f}, "
      f"gpu median {pour['gpuMedianMs']:.3f} ms, cpu median {pour['cpuMedianMs']:.3f} ms")

print(f"\n--- the scroll: {scroll['seconds']:.1f}s, {scroll['frames']:.0f} frames, "
      f"display running at {scroll['vsyncHz']:.1f} Hz")
check("ISC-20  zero frames dropped",
      scroll['vsyncGaps'] == 0 and scroll['presentGaps'] == 0,
      f"{scroll['vsyncGaps']:.0f} skipped vsyncs, {scroll['presentGaps']:.0f} gaps between "
      f"presented frames, over {scroll['presentedSamples']:.0f} presentations")
check("ISC-21  GPU median <= 1.0 ms",
      scroll['gpuMedianMs'] <= 1.0,
      f"median {scroll['gpuMedianMs']:.3f} ms, p95 {scroll['gpuP95Ms']:.3f} ms, "
      f"max {scroll['gpuMaxMs']:.3f} ms over {scroll['gpuSamples']:.0f} frames")
check("ISC-37  CPU median <= 0.5 ms",
      scroll['cpuMedianMs'] <= 0.5,
      f"median {scroll['cpuMedianMs']:.3f} ms, p95 {scroll['cpuP95Ms']:.3f} ms, "
      f"max {scroll['cpuMaxMs']:.3f} ms")
print(f"    waiting for the display to hand over a drawable, kept out of the CPU figure: "
      f"median {scroll.get('waitMedianMs', 0):.3f} ms, p95 {scroll.get('waitP95Ms', 0):.3f} ms")
print(f"    {scroll['instances']:.0f} instances in the last frame, "
      f"{scroll['atlasGlyphs']:.0f} glyphs in the atlas, "
      f"{scroll['atlasResets']:.0f} atlas resets")

print(f"\n--- the silence: {idle['seconds']:.1f}s")
check("ISC-22  zero frames while nothing changes",
      idle['frames'] == 0,
      f"{idle['frames']:.0f} frames drawn, {idle['idleSkips']:.0f} vsyncs skipped before the "
      f"link stopped, link paused = {bool(idle['paused'])}")
sys.exit(0 if ok else 1)
PY
