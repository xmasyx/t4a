#!/bin/bash
# ISC-124 — the seams between the terminal and the two panels are not lines.
#
#   Scripts/bench-seam.sh [--with-claude] [app-bundle]
#
# The principal looked at the running app and said the two vertical monochrome
# bars between the rail, the terminal and the inspector were ugly. So this
# bench does not ask the app what it drew: it photographs the window and reads
# the PIXELS of the seam's own rectangle, which is the only place the answer
# can be, and it asks two things of them (Scripts/seamprobe.swift has the
# definitions).
#
# THE NEGATIVE POLE IS A BUNDLE, not a flag: point the second argument at a
# build from before the change and the same probe has to FIND the rule it says
# is gone. That is what `--head <bundle>` prints instructions for.
#
# And because the seam is also the thing you grab to resize a panel, the last
# section drags it: a seam you cannot see must still be a seam you can pull.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

WITH_CLAUDE=0
if [ "${1:-}" = "--with-claude" ]; then WITH_CLAUDE=1; shift; fi
APP="${1:-dist/T4A.app}"
# The themes to walk. Overridable, because a bundle from before ISC-125 does
# not have the same five.
THEMES="${T4A_SEAM_THEMES:-black warm violet light paper lagoon}"
# What the pictures are called. A run against an old bundle must not overwrite
# the evidence of the new one.
TAG="${T4A_SEAM_TAG:-f5-124}"

FIFO="/tmp/t4a-seam.fifo"
CONFIG_HOME="/tmp/t4a-seam-config"
DUMP=/tmp/t4a-seam-dump.json
SHOT=/tmp/t4a-seam-shot.png
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

for tool in winid winframe dragpoint seamprobe; do
  bin=".build/t4a-$tool"
  if [ ! -x "$bin" ] || [ "Scripts/$tool.swift" -nt "$bin" ]; then
    mkdir -p .build && swiftc -O "Scripts/$tool.swift" -o "$bin"
  fi
done
if [ ! -x .build/t4a-cropshot ] || [ Scripts/cropshot.swift -nt .build/t4a-cropshot ]; then
  swiftc -O Scripts/cropshot.swift -o .build/t4a-cropshot
fi

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 50); do [ -s "$DUMP" ] && break; sleep 0.1; done
  [ -s "$DUMP" ] || { echo "the app never answered a dump" >&2; exit 1; }
}
field() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
try:
    print($1)
except Exception as error:
    print('missing:%s' % type(error).__name__)
"; }
verdict() {
  local name="$1" got="$2" want="$3" mark="ok"
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-44s %-24s (want %s) %s\n' "$name" "$got" "$want" "$mark"
}
note() { printf '%-44s %s\n' "$1" "$2"; }

stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }
launch() {
  rm -f "$FIFO"
  open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
  sleep 3
}

# Insisted on, never assumed: a photograph of pixels taken while another
# application is in front is a photograph of that application.
front() {
  for _ in $(seq 1 6); do
    # Two independent ways of asking; see the note in bench-f5.sh — on macOS 14
    # the in-app one is a request the front app may refuse, and `open -a` is
    # not.
    send "activate"; sleep 0.6
    open -a "$PWD/$APP" 2>/dev/null || true
    sleep 1.4
    dump
    [ "$(field "d['appActive']")" = "True" ] && { sleep 1; return 0; }
  done
  echo "    T4A would not come to the front: something else keeps taking it"
  return 1
}

stop
rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a/themes"
# A theme of the user's own, so "in every theme, the user's included" is a
# measurement and not a hope.
cat > "$CONFIG_HOME/t4a/themes/lagoon.toml" <<'TOML'
title = "lagoon"
ground = "#07161A"
pane = "#0B1D22"
panel = "#0E242A"
panel-edge = "#1B3A42"
raised = "#123039"
hairline = "#1B3A42"
hairline-soft = "#152C33"
ink = "#E4F0F0"
muted = "#8AA6A9"
whisper = "#5B7378"
accent = "#1F6E7A"
accent-text = "#4FB3BF"
failed = "#D4574A"
failed-soft = "#A8635B"
selection = "#1F6E7A"
light = false
TOML
launch
mkdir -p design/evidence

if [ "$WITH_CLAUDE" = "1" ] && command -v claude >/dev/null 2>&1; then
  echo "--> a live claude in the pane, so the seams are photographed on a real scene"
  send "text cd $(pwd) && claude"; send "key return"
  sleep 18
fi

echo "=== ISC-124 · the seams, theme by theme ============================"
for theme in $THEMES; do
  send "theme $theme"; sleep 1
  front || STATUS=1
  dump
  verdict "$theme · in force" "$(field "d['themeState']['name']")" "$theme"
  WID="$(.build/t4a-winid || true)"
  if [ -z "$WID" ]; then echo "    no window id: $theme NOT photographed"; STATUS=1; continue; fi
  rm -f "$SHOT"
  screencapture -x -o -l "$WID" "$SHOT"
  FRAME="$(.build/t4a-winframe)"        # x y w h, points, Cocoa
  WIN="$(echo "$FRAME" | tr ' ' ',')"
  RG="$(field "'%d,%d,%d,%d' % (d['panelWidths']['railGrip']['x'], d['panelWidths']['railGrip']['y'], d['panelWidths']['railGrip']['w'], d['panelWidths']['railGrip']['h'])")"
  IG="$(field "'%d,%d,%d,%d' % (d['panelWidths']['inspectorGrip']['x'], d['panelWidths']['inspectorGrip']['y'], d['panelWidths']['inspectorGrip']['w'], d['panelWidths']['inspectorGrip']['h'])")"
  echo "--- $theme ---"
  if .build/t4a-seamprobe "$SHOT" "$WIN" "rail|terminal,$RG" "terminal|inspector,$IG"; then
    echo "    $theme: neither seam reads as a line"
  else
    echo "    $theme: a seam still reads as a line"; STATUS=1
  fi
  # A close crop of both seams side by side, for eyes rather than for the
  # probe: 120 points wide around each, the seam's own height.
  /usr/bin/python3 - "$SHOT" "$FRAME" "$RG" "$IG" "design/evidence/$TAG-seam-$theme.png" <<'PY' | tail -1
import subprocess, sys
shot, frame, rg, ig, out = sys.argv[1:6]
wx, wy, ww, wh = [float(v) for v in frame.split()]
import struct
# The picture's scale is read off the picture, the same way seamprobe does it.
head = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', shot],
                      capture_output=True, text=True).stdout
px = int([l for l in head.splitlines() if 'pixelWidth' in l][0].split(':')[1])
py = int([l for l in head.splitlines() if 'pixelHeight' in l][0].split(':')[1])
scale = px / ww
def rect(spec):
    x, y, w, h = [float(v) for v in spec.split(',')]
    return x, y, w, h
rx, ry, rw, rh = rect(rg)
ix, iy, iw, ih = rect(ig)
# One crop that holds both seams would be the whole window; two crops, stacked
# by the caller's eye, is what a close look means here. The left one is taken.
x0 = int((rx - wx - 60) * scale); y0 = int((wy + wh - (ry + rh/2)) * scale)
subprocess.run(['.build/t4a-cropshot', shot, out, str(max(0, x0)), str(max(0, y0)),
                str(int(120 * scale)), str(int(rh * scale))], check=True)
x1 = int((ix - wx - 60) * scale)
subprocess.run(['.build/t4a-cropshot', shot, out.replace('.png', '-right.png'),
                str(max(0, x1)), str(max(0, y0)),
                str(int(120 * scale)), str(int(rh * scale))], check=True)
print('    cropped: %s and %s' % (out, out.replace('.png', '-right.png')))
PY
done

echo ""
echo "=== the grab zone is untouched: a seam you cannot see, you can still pull ==="
send "theme black"; sleep 0.8
# The window is PLACED before the gesture, not merely brought to the front.
#
# A real drag lands on whatever the window server has on top of that point, and
# being frontmost does not clear a panel another process is holding there. On
# 2026-08-22 macOS put its "the system has run out of application memory" panel
# at x 218-395, which is exactly where the rail seam is when the window sits at
# the left edge: the drag went nowhere, twice, and the app was fine. Same
# lesson as the settings `place` verb of 21/08 — a gesture bench that does not
# say where the window is measures somebody else's window.
send "movewindow 620,120"; sleep 1
front || STATUS=1
dump
WRITES_BEFORE="$(field "d['configWrites']")"
BEFORE="$(field "d['panelWidths']['railSaved']")"
GX="$(field "int(d['panelWidths']['railGrip']['x'])")"
GY="$(field "int(d['panelWidths']['railGrip']['y'])")"
.build/t4a-dragpoint "$GX" "$GY" "$((GX + 90))" "$GY" 40
sleep 1.2
dump
AFTER="$(field "d['panelWidths']['railSaved']")"
WRITES_AFTER="$(field "d['configWrites']")"
note "the rail went from $BEFORE to" "$AFTER points"
verdict "the drag moved it" "$([ "$AFTER" != "$BEFORE" ] && echo moved || echo stuck)" "moved"
verdict "one write for forty steps" "$((WRITES_AFTER - WRITES_BEFORE))" "1"

if [ "$WITH_CLAUDE" = "1" ] && command -v claude >/dev/null 2>&1; then
  send "key ctrl-c"; sleep 0.5; send "key ctrl-c"; sleep 1
fi
stop
[ "$STATUS" = "0" ] && echo "seam: every pole held" || echo "seam: a pole FAILED"
exit "$STATUS"
