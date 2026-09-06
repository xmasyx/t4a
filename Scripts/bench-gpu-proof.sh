#!/bin/bash
# ISC-19, ISC-23 and ISC-24 — the three claims that are about HOW the renderer
# works rather than how fast it is.
#
#   Scripts/bench-gpu-proof.sh
#
#   * ISC-19: the glyphs live in a texture on the GPU and every cell of every
#     frame is one instance of ONE draw. The counters say so; a captured frame
#     (`.gputrace`, opened in Xcode's frame debugger) is where a person can
#     see it. The app is launched with MTL_CAPTURE_ENABLED=1 for that.
#   * ISC-23: emoji come out in the font's own colour, and a grapheme cluster
#     — a family emoji made of five scalars joined by zero-width joiners —
#     occupies one cell. Read off the CELLS, not off a screenshot.
#   * ISC-24: the CPU renderer takes the pane back at any moment, on a live
#     session, and gives it back again.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

FIFO="/tmp/t4a-proof.fifo"
CONFIG_HOME="/tmp/t4a-proof-config"
SHOTS="design/evidence"

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
wait_for() { for _ in $(seq 1 40); do [ -s "$1" ] && break; sleep 0.15; done; }

t4a_stop_bench
sleep 1.5
rm -rf "$CONFIG_HOME" "$FIFO" /tmp/t4a-frame.gputrace; mkdir -p "$CONFIG_HOME"
open -n dist/T4A.app --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME" \
  --env MTL_CAPTURE_ENABLED=1
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3

echo "==> a line with emoji, a joined cluster, and wide characters"
send "text printf 'A\\360\\237\\216\\211B\\360\\237\\221\\251\\342\\200\\215\\360\\237\\221\\251\\342\\200\\215\\360\\237\\221\\246C\\346\\227\\245\\346\\234\\254D\\n'"
send "key return"
sleep 1.5
rm -f /tmp/t4a-cells.json
# The row above the cursor is the one that was just printed.
send "cells $(/usr/bin/python3 - <<'PY'
import json, subprocess, time
PY
) /tmp/t4a-cells.json" 2>/dev/null || true
rm -f /tmp/t4a-proof-dump.json
send "dump /tmp/t4a-proof-dump.json"
wait_for /tmp/t4a-proof-dump.json
ROW=$(/usr/bin/python3 -c "
import json
d = json.load(open('/tmp/t4a-proof-dump.json'))
p = [q for t in d['tabs'] for q in t['panes'] if q['active']][0]
print(p['cursorRow'] - 1)")
rm -f /tmp/t4a-cells.json
send "cells $ROW /tmp/t4a-cells.json"
wait_for /tmp/t4a-cells.json

echo "==> capturing one frame for the GPU debugger"
send "renderreset"
sleep 0.5
send "capture /tmp/t4a-frame.gputrace"
sleep 2
rm -f /tmp/t4a-proof-render.json
send "renderstats /tmp/t4a-proof-render.json"
wait_for /tmp/t4a-proof-render.json
Scripts/drive.sh shot "$SHOTS/f3-emoji.png" >/dev/null

echo "==> handing the pane to the CPU renderer, live"
send "renderer cpu"
sleep 1.5
Scripts/drive.sh shot "$SHOTS/f3-fallback-cpu.png" >/dev/null
rm -f /tmp/t4a-proof-cpu.json
send "dump /tmp/t4a-proof-cpu.json"
wait_for /tmp/t4a-proof-cpu.json
send "text echo still-alive-on-cpu"
send "key return"
sleep 1.5
rm -f /tmp/t4a-proof-cpu2.json
send "dump /tmp/t4a-proof-cpu2.json"
wait_for /tmp/t4a-proof-cpu2.json

echo "==> and taking it back"
send "renderer gpu"
sleep 1.5
rm -f /tmp/t4a-proof-gpu.json
send "renderstats /tmp/t4a-proof-gpu.json"
wait_for /tmp/t4a-proof-gpu.json
Scripts/drive.sh shot "$SHOTS/f3-fallback-gpu.png" >/dev/null

t4a_stop_bench
rm -f "$FIFO"

/usr/bin/python3 <<'PY'
import json, os, subprocess, sys
def load(path): return json.load(open(path))
cells = load('/tmp/t4a-cells.json')
render = load('/tmp/t4a-proof-render.json')
cpu = load('/tmp/t4a-proof-cpu.json')
cpu2 = load('/tmp/t4a-proof-cpu2.json')
gpu = load('/tmp/t4a-proof-gpu.json')

ok = True
def check(label, condition, detail):
    global ok
    ok = ok and condition
    print(f"{'PASS' if condition else 'FAIL'}  {label}: {detail}")

# ISC-19
trace = '/tmp/t4a-frame.gputrace'
size = 0
if os.path.exists(trace):
    size = int(subprocess.run(['du', '-sk', trace], capture_output=True, text=True)
               .stdout.split()[0])
check("ISC-19  a frame was captured for the GPU debugger", size > 0,
      f"{trace}, {size} KB" if size else open('/tmp/t4a-capture-result.txt').read().strip())
check("ISC-19  the atlas is a texture on the GPU",
      render['atlasGlyphs'] > 0 and render['atlasBytes'] > 0,
      f"{render['atlasGlyphs']:.0f} glyphs ({render['atlasColouredGlyphs']:.0f} in colour) "
      f"in a {render['atlasBytes'] / 1024 / 1024:.0f} MB texture")
check("ISC-19  one draw call per frame, whatever is on screen",
      render['drawCalls'] == render['frames'] and render['frames'] > 0,
      f"{render['drawCalls']:.0f} draw calls for {render['frames']:.0f} frames, "
      f"{render['instances']:.0f} instances in the last one")

# ISC-23
def cell(index): return cells['cells'][index]
row = "".join(c['text'] for c in cells['cells'] if c['width'] > 0).rstrip()
print(f"    the row reads: {row!r}")
emoji = [c for c in cells['cells'] if len(c['scalars']) == 1
         and int(c['scalars'][0][2:], 16) == 0x1F389]
family = [c for c in cells['cells'] if len(c['scalars']) > 3]
wide = [c for c in cells['cells'] if len(c['scalars']) == 1
        and int(c['scalars'][0][2:], 16) == 0x65E5]
check("ISC-23  the party emoji is one cell of the grid", len(emoji) == 1,
      f"{emoji[0]['scalars']} at column {emoji[0]['column']}, width {emoji[0]['width']}"
      if emoji else "not found in the row")
check("ISC-23  the joined family is ONE cell, not five",
      len(family) == 1 and family[0]['width'] >= 1,
      f"{family[0]['scalars']} in one cell at column {family[0]['column']}, "
      f"width {family[0]['width']}" if family else "not found in the row")
check("ISC-23  a wide character claims two columns",
      len(wide) == 1 and wide[0]['width'] == 2,
      f"{wide[0]['scalars']} width {wide[0]['width']}" if wide else "not found")
check("ISC-23  colour glyphs went into the atlas as colour",
      render['atlasColouredGlyphs'] >= 2,
      f"{render['atlasColouredGlyphs']:.0f} coloured entries")

# ISC-24
pane = lambda d: [q for t in d['tabs'] for q in t['panes'] if q['active']][0]
check("ISC-24  the CPU renderer took the pane on a live session",
      any('still-alive-on-cpu' in line for line in pane(cpu2)['screen']),
      "a command typed and echoed while the GPU renderer was off")
check("ISC-24  and the GPU renderer took it back",
      gpu['active'] == 1, f"active = {gpu['active']:.0f}")
sys.exit(0 if ok else 1)
PY
