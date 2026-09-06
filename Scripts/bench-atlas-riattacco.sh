#!/bin/bash
# ISC-243 — a tab switch reattaches the pane; its history rows come back the
# same pixels.
#
#   Scripts/bench-atlas-riattacco.sh [app-bundle]      (default dist/T4A.app)
#
# `installActiveTabView` removes the pane from the window and adds it back, so
# every switch runs `viewDidMoveToWindow`, which used to call `setFont` on the
# atlas — a full wipe — without dropping the row cache. Rows below the live
# screen are served from that cache, holding texture coordinates into a texture
# refilled from a different corner: the same rows, the wrong glyphs, for ever
# (his screenshot of 2026-09-05 22:44). ISC-129's bench fills the atlas
# mid-frame; this one wipes it between frames, which is a different door.
#
# The corpus printed in the OTHER tab is what makes the refill land elsewhere:
# after the wipe the first glyphs rasterised are that tab's, so tab 0's rows
# point at CJK where their Latin used to be.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"
source "$(dirname "$0")/lib/bench-split.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-riattacco.fifo"
CONFIG_HOME="/tmp/t4a-riattacco-config"
DUMP=/tmp/t4a-riattacco-dump.json
STATS=/tmp/t4a-riattacco-stats.json
SHOTS=/tmp/t4a-riattacco-shots
TEXT=/tmp/t4a-riattacco-text.txt
CORPUS=/tmp/t4a-riattacco-cjk.txt
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
for tool in winid imagediff; do
  bin=".build/t4a-$tool"
  if [ ! -x "$bin" ] || [ "Scripts/$tool.swift" -nt "$bin" ]; then
    mkdir -p .build && swiftc -O "Scripts/$tool.swift" -o "$bin"
  fi
done

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
grab() { rm -f "$2"; send "$1 $2"; for _ in $(seq 1 60); do [ -s "$2" ] && break; sleep 0.1; done
         [ -s "$2" ] || { echo "the app never answered $1" >&2; exit 1; }; }
field() { /usr/bin/python3 -c "
import json
d = json.load(open('$2'))
try:
    print($1)
except Exception as error:
    print('missing:%s' % type(error).__name__)
"; }
note() { printf '%-48s %s\n' "$1" "$2"; }
verdict() { local mark="ok"; [ "$2" = "$3" ] || { mark="FAILED"; STATUS=1; }
            printf '%-48s %-24s (want %s) %s\n' "$1" "$2" "$3" "$mark"; }
shot() {
  local id; id="$(.build/t4a-winid "$PID" || true)"
  [ -n "$id" ] || { echo "no window id for pid $PID" >&2; STATUS=1; return 1; }
  screencapture -x -o -l "$id" "$1"
}
top_of() { field "d['tabs'][$1]['panes'][0]['topVisibleRow']" "$DUMP"; }
goto_row() {
  local tab="$1" target="$2"
  for _ in $(seq 1 12); do
    grab dump "$DUMP"
    local now; now="$(top_of "$tab")"
    [ "$now" = "$target" ] && return 0
    send "scroll $(( now - target ))"
    sleep 0.35
  done
  note "  could not land on row $target" "stopped at $(top_of "$tab")"
  return 1
}
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }

# Tab 0: Latin text with the characters his transcripts carry — accents, the
# euro, box drawing — 400 distinct lines so the history is real history.
/usr/bin/python3 - "$TEXT" <<'PY'
import sys
words = "Il documento Nashwan riporta ancora €47.905 IVA inclusa, mentre l'accordo è €40.600 — rasatura a gesso; controsoffitto; più robusta ┼ ─ │".split(" ")
with open(sys.argv[1], "w") as out:
    for i in range(400):
        out.write("riga %03d: %s\n" % (i, " ".join(words[i % 7:] + words[:i % 7])))
PY
/usr/bin/python3 - "$CORPUS" <<'PY'
import sys
codepoints = [chr(0x4E00 + i) for i in range(3000)]
with open(sys.argv[1], "w") as out:
    for i in range(0, len(codepoints), 48):
        out.write("".join(codepoints[i:i + 48]) + "\n")
PY

rm -rf "$SHOTS"; mkdir -p "$SHOTS"
stop
rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
printf 'scrollback-lines = 20000\ntheme = black\ncursor-motion = off\n' \
  > "$CONFIG_HOME/t4a/config.toml"
rm -f "$FIFO"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3
PID="$(t4a_bench_pids | tail -1)"
t4a_split_screen "$PID"
send "activate"; sleep 1

echo "=== ISC-243: the history rows survive a tab switch ================="
send "text cat $TEXT"; send "key return"; sleep 4
grab dump "$DUMP"
END="$(field "d['tabs'][0]['panes'][0]['endRow']" "$DUMP")"
ROWS="$(field "d['tabs'][0]['panes'][0]['rows']" "$DUMP")"
MARK=$(( END - ROWS - 150 ))
note "  buffer" "endRow $END, rows $ROWS, landing on $MARK"
goto_row 0 "$MARK" || STATUS=1
sleep 1.2
shot "$SHOTS/243-before.png" && note "  photographed" "$SHOTS/243-before.png"
grab renderstats "$STATS"
note "  rows in the cache before" "$(field "int(d.get('rowCacheSize', 0))" "$STATS")"

send "newtab"; sleep 2
send "text cat $CORPUS"; send "key return"; sleep 5
send "selecttab 0"; sleep 1.5
goto_row 0 "$MARK" || STATUS=1
sleep 1.2
shot "$SHOTS/243-after.png" && note "  photographed" "$SHOTS/243-after.png"
grab renderstats "$STATS"
note "  rows in the cache after" "$(field "int(d.get('rowCacheSize', 0))" "$STATS")"
note "  atlas glyphs now" "$(field "int(d.get('atlasGlyphs', d.get('glyphCount', -1)))" "$STATS")"

DIFF="$(.build/t4a-imagediff "$SHOTS/243-before.png" "$SHOTS/243-after.png" \
        --out "$SHOTS/243-diff.png" 2>&1 || true)"
printf '%s\n' "$DIFF" | sed 's/^/    /'
# The verdict is on the TERMINAL SURFACE only: the rail legitimately gains a
# row (the second tab's session) between the two photographs, and a
# whole-window comparison would fail a fixed build for that. The surface's
# rect comes from the same dump, in Cocoa points; the photograph is pixels
# at the backing scale, y down.
SURF="$(field "' '.join(str(int(v)) for v in (d['tabs'][0]['panes'][0]['surfaceRect'][k] for k in ('x','y','w','h')))" "$DUMP")"
SCREEN_H="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | awk -F', ' '{print $4}')"
SCALE="$(/usr/bin/python3 -c "import subprocess; w=int(subprocess.check_output(['magick','identify','-format','%w','$SHOTS/243-before.png']).decode()); print(2 if w > 2000 else 1)")"
CROP="$(/usr/bin/python3 -c "
x, y, w, h = [int(v) for v in '$SURF'.split()]
s = $SCALE; sh = $SCREEN_H
# midpoint → top-left, Cocoa → CG, points → pixels; 40 pt of margin so the
# cursor row and the window edge stay out of the comparison.
left = int((x - w / 2 + 20) * s); top = int((sh - (y + h / 2) + 40) * s)
print('%dx%d+%d+%d' % (int((w - 40) * s), int((h - 80) * s), left, top))")"
note "  surface crop (pixels)" "$CROP"
magick "$SHOTS/243-before.png" -crop "$CROP" +repage "$SHOTS/243-before-surface.png"
magick "$SHOTS/243-after.png" -crop "$CROP" +repage "$SHOTS/243-after-surface.png"
DIFFERENT="$(magick compare -metric AE "$SHOTS/243-before-surface.png" "$SHOTS/243-after-surface.png" "$SHOTS/243-surface-diff.png" 2>&1 || true)"
verdict "surface pixels that changed across the switch" "${DIFFERENT%% *}" "0"

stop
[ "$STATUS" = "0" ] && echo "riattacco: every pole held" || echo "riattacco: a pole FAILED"
exit "$STATUS"
