#!/bin/bash
# F3 fidelity — does the GPU renderer draw the same terminal as the CPU one?
#
#   Scripts/bench-fidelity.sh
#
# The same app, the same window size and position, the same keystrokes, twice:
# once with the Metal renderer and once with `T4A_RENDERER=cpu`, which hands
# the pane back to SwiftTerm's own CoreText drawing (ISC-24). Then the two
# screenshots are compared pixel by pixel.
#
# The sample deliberately contains the four things that can go wrong
# separately: plain text and its metrics, the 256-colour palette, a selection
# made by a real drag, and emoji with a grapheme cluster in one cell.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

FIFO="/tmp/t4a-fidelity.fifo"
CONFIG_HOME="/tmp/t4a-fidelity-config"
SHOTS="design/evidence"
DIFF_BIN=".build/t4a-imagediff"
FRAME_BIN=".build/t4a-winframe"

mkdir -p .build "$SHOTS"
for pair in "imagediff:$DIFF_BIN" "winframe:$FRAME_BIN"; do
  name="${pair%%:*}"; binary="${pair##*:}"
  if [ ! -x "$binary" ] || [ "Scripts/$name.swift" -nt "$binary" ]; then
    swiftc -O "Scripts/$name.swift" -o "$binary"
  fi
done

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }

# The sample: plain text and its metrics, the palette, the attributes, a box
# drawing, emoji and a grapheme cluster.
/usr/bin/python3 - <<'PY'
lines = [
    "The quick brown fox jumps over the lazy dog 0123456789",
    "".join(f"\033[3{i}m ansi{i} \033[9{i}m bright{i}\033[0m" for i in range(1, 7)),
    "".join(f"\033[48;5;{16 + i * 7}m  \033[0m" for i in range(0, 24)),
    "\033[48;5;53m block \033[0m \033[1mbold\033[0m \033[3mitalic\033[0m "
    "\033[4munder\033[0m \033[9mstrike\033[0m \033[7minverse\033[0m \033[2mdim\033[0m",
    "emoji 🎉 ✅ 🚀 family 👩‍👩‍👦 accents àèìòù ünïcödé",
    "box ┌───┬───┐  │ x │ y │  └───┴───┘  blocks ░▒▓█",
]
open("/tmp/t4a-sample.txt", "w").write("\n".join(lines) + "\n")
PY

# The same window, in the same place, both times: a window one pixel wider
# would move every glyph and make the comparison meaningless.
run() {
  local renderer="$1" shot="$2"
  t4a_stop_bench
  sleep 1.5
  rm -f "$FIFO"
  open -n dist/T4A.app --env T4A_TEST_CHANNEL="$FIFO" \
    --env XDG_CONFIG_HOME="$CONFIG_HOME" --env T4A_RENDERER="$renderer"
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  sleep 3
  send "resize 1200x800"
  sleep 0.5
  send "movewindow 100,120"
  sleep 1

  # One command, one file, written outside the terminal. Typing the sample in
  # was the first attempt and it was wrong: the shell's own line wrapping and
  # continuation prompts landed differently in the two runs, so the two
  # screenshots showed different TEXT and the pixel comparison was measuring
  # that instead of the renderers.
  send "text clear && cat /tmp/t4a-sample.txt"
  send "key return"; sleep 2.5
  # A real drag over the first line, so the selection is the engine's own.
  send "drag 6,1 40,1"
  sleep 1.2
  Scripts/drive.sh shot "$shot" >/dev/null
  # What the screen SAYS, so the pixel comparison can be refused if the two
  # runs are not looking at the same text.
  rm -f "/tmp/t4a-fidelity-$renderer.json"
  send "dump /tmp/t4a-fidelity-$renderer.json"
  for _ in $(seq 1 30); do [ -s "/tmp/t4a-fidelity-$renderer.json" ] && break; sleep 0.1; done
  echo "    $renderer -> $shot"
}

rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME"
echo "==> the GPU renderer"
run gpu "$SHOTS/f3-fidelity-gpu.png"
echo "==> the engine's CPU renderer"
run cpu "$SHOTS/f3-fidelity-cpu.png"
t4a_stop_bench
rm -f "$FIFO"

echo "==> is it the same terminal in both runs?"
/usr/bin/python3 - <<'PY' || exit 1
import json, sys
def screen(name):
    d = json.load(open(f"/tmp/t4a-fidelity-{name}.json"))
    pane = d['tabs'][0]['panes'][0]
    return pane['screen'], pane['columns'], pane['rows'], pane['selection']
gpu, gc, gr, gsel = screen("gpu")
cpu, cc, cr, csel = screen("cpu")
if (gc, gr) != (cc, cr):
    print(f"FAIL  different grids: {gc}x{gr} vs {cc}x{cr}"); sys.exit(1)
if gpu != cpu:
    for index, (a, b) in enumerate(zip(gpu, cpu)):
        if a != b:
            print(f"FAIL  row {index} differs:\n  gpu {a!r}\n  cpu {b!r}")
            break
    sys.exit(1)
if gsel != csel:
    print(f"FAIL  different selection: {gsel!r} vs {csel!r}"); sys.exit(1)
print(f"PASS  same {gc}x{gr} grid, same {len(gpu)} rows of text, same selection {gsel!r}")
PY

echo "==> whole window"
"$DIFF_BIN" "$SHOTS/f3-fidelity-gpu.png" "$SHOTS/f3-fidelity-cpu.png" \
  --tolerance "${TOLERANCE:-16}" --out "$SHOTS/f3-fidelity-diff.png" || true

# The flat-colour band: twenty-four background blocks from the 256-colour
# cube, with no text in them. Antialiasing has nothing to do here, so this
# region has to be EXACT — it is the part of the comparison that can fail for
# a real reason (a palette off by one, a cell half a pixel wide).
echo "==> the colour ramp, where there is no antialiasing to hide behind"
"$DIFF_BIN" "$SHOTS/f3-fidelity-gpu.png" "$SHOTS/f3-fidelity-cpu.png" \
  --crop "${RAMP_CROP:-250,258,1350,24}" --tolerance 2 || true

echo "==> and the colour each renderer resolved, block by block"
SAMPLE_BIN=".build/t4a-samplecolours"
if [ ! -x "$SAMPLE_BIN" ] || [ Scripts/samplecolours.swift -nt "$SAMPLE_BIN" ]; then
  swiftc -O Scripts/samplecolours.swift -o "$SAMPLE_BIN"
fi
"$SAMPLE_BIN" "$SHOTS/f3-fidelity-gpu.png" "$SHOTS/f3-fidelity-cpu.png" \
  ${RAMP_SAMPLE:-268 556 30} \
  | awk '{print} $NF+0 > 2 {bad++} END {print "blocks off by more than 2 levels:", bad+0}'
