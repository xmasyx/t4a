#!/bin/bash
# The glyph atlas and the instance ring, measured on the app you open.
#
#   Scripts/bench-atlas.sh [app-bundle]
#
# Two claims, and each has a pole that has to be able to go red:
#
#   ISC-133  A cell can want five rectangles — background, underline,
#            strikethrough and up to two pieces of a painted box character —
#            and `emit` used to drop the overflow without a word. A screen
#            where EVERY cell wants all of them must come out with zero drops.
#
#   ISC-129  When the atlas fills it starts over, and every cached history row
#            on screen is still holding texture coordinates into the texture
#            that was just wiped. The probe is a photograph: the same rows,
#            before the atlas ran out and after, have to be the same pixels.
#            Scrolling through unique CJK is what fills it, and the run says
#            how many times it actually did — a run where the atlas never
#            reset has measured nothing, and says so.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-atlas.fifo"
CONFIG_HOME="/tmp/t4a-atlas-config"
DUMP=/tmp/t4a-atlas-dump.json
STATS=/tmp/t4a-atlas-stats.json
SHOTS=/tmp/t4a-atlas-shots
CORPUS=/tmp/t4a-atlas-cjk.txt
HEAVY=/tmp/t4a-atlas-heavy.txt
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

for tool in winid imagediff; do
  bin=".build/t4a-$tool"
  if [ ! -x "$bin" ] || [ "Scripts/$tool.swift" -nt "$bin" ]; then
    mkdir -p .build && swiftc -O "Scripts/$tool.swift" -o "$bin"
  fi
done

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 60); do [ -s "$DUMP" ] && break; sleep 0.1; done
  [ -s "$DUMP" ] || { echo "the app never answered a dump" >&2; exit 1; }
}
stats() {
  rm -f "$STATS"; send "renderstats $STATS"
  for _ in $(seq 1 60); do [ -s "$STATS" ] && break; sleep 0.1; done
  [ -s "$STATS" ] || { echo "the app never answered renderstats" >&2; exit 1; }
}
field() { /usr/bin/python3 -c "
import json
d = json.load(open('$2'))
try:
    print($1)
except Exception as error:
    print('missing:%s' % type(error).__name__)
"; }
verdict() {
  local name="$1" got="$2" want="$3" mark="ok"
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-48s %-24s (want %s) %s\n' "$name" "$got" "$want" "$mark"
}
atleast() {
  local name="$1" got="$2" floor="$3" mark="ok"
  [ "${got%%.*}" -ge "$floor" ] 2>/dev/null || { mark="FAILED"; STATUS=1; }
  printf '%-48s %-24s (want >= %s) %s\n' "$name" "$got" "$floor" "$mark"
}
note() { printf '%-48s %s\n' "$1" "$2"; }
shot() {
  local id; id="$(.build/t4a-winid || true)"
  [ -n "$id" ] || { echo "no window id" >&2; STATUS=1; return 1; }
  screencapture -x -o -l "$id" "$1"
}
# Puts the top of the view on an exact scroll-invariant row, by correcting
# rather than by counting: a scroll that hits the end of the buffer clamps, and
# a bench that assumed its arithmetic would land is a bench comparing two
# different places and calling the difference a defect.
goto_row() {
  local target="$1"
  for _ in $(seq 1 12); do
    dump
    local now; now="$(field "d['tabs'][0]['panes'][0]['topVisibleRow']" "$DUMP")"
    [ "$now" = "$target" ] && return 0
    # Sign measured, not assumed: `scroll -N` moves towards the PRESENT, so
    # reaching an older row is a positive number. The first version had it the
    # other way round, drove the view to the bottom of the buffer and compared
    # two different places (2026-08-22).
    send "scroll $(( now - target ))"
    sleep 0.35
  done
  dump
  note "  could not land on row $target" "stopped at $(field "d['tabs'][0]['panes'][0]['topVisibleRow']" "$DUMP")"
  return 1
}
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }

# A corpus of CJK nobody has drawn before. Unique on purpose: a repeated glyph
# is one atlas entry however many times it is printed, so a screen of the same
# character would never fill anything.
/usr/bin/python3 - "$CORPUS" <<'PY'
import sys
start = 0x4E00          # CJK Unified Ideographs, 20k of them and all distinct
codepoints = [chr(start + i) for i in range(20000)]
per_line = 48
with open(sys.argv[1], "w") as out:
    for i in range(0, len(codepoints), per_line):
        out.write("".join(codepoints[i:i + per_line]) + "\n")
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
send "activate"; sleep 1
open -a "$PWD/$APP" 2>/dev/null || true
sleep 2

echo "=== ISC-133: every cell wants all five rectangles ==================="
send "renderreset"; sleep 0.5
# SGR 4 underline, 9 strikethrough, 41 red background, and a box-drawing
# character, which is the range painted as up to TWO pieces instead of one
# glyph. Every line is wider than any sane terminal so the wrap fills the row
# right to the edge: 80 columns of a 117-column grid was the first try and it
# peaked just UNDER the old bound, which would have made "nothing was dropped"
# a fact about a screen that never asked for anything (2026-08-22).
/usr/bin/python3 - "$HEAVY" <<'PY'
import sys
with open(sys.argv[1], "w") as out:
    out.write("\033[4;9;41m")
    for _ in range(200):
        out.write("\u253c" * 240 + "\n")
    out.write("\033[0m\n")
PY
send "text cat $HEAVY"
send "key return"
sleep 12
stats
dump
note "  grid" "$(field "'%sx%s' % (d['tabs'][0]['panes'][0]['columns'], d['tabs'][0]['panes'][0]['rows'])" "$DUMP")"
note "  ring capacity" "$(field "int(d.get('ringCapacity', -1))" "$STATS")"
verdict "no rectangle was dropped" "$(field "int(d.get('overflowed', -1))" "$STATS")" "0"
PEAK="$(field "int(d.get('emittedPeak', 0))" "$STATS")"
CELLS="$(field "d['tabs'][0]['panes'][0]['columns'] * d['tabs'][0]['panes'][0]['rows']" "$DUMP")"
note "  rectangles the busiest frame wanted" "$PEAK"
# The pole that makes the one above mean something. Zero drops is free on a
# screen that wanted less than the ring holds; it is a measurement only if the
# frame went past what the OLD bound (three a cell) would have allowed.
atleast "the frame went past the old three-a-cell bound" \
  "$PEAK" "$(( CELLS * 3 + 65 ))"
atleast "and frames really were drawn" "$(field "int(d.get('drawCalls', 0))" "$STATS")" 1
shot "$SHOTS/133-full-attributes.png" && note "  photographed" "$SHOTS/133-full-attributes.png"

echo ""
echo "=== ISC-129: the same history rows, before the atlas ran out and after"
send "key ctrl-c"; sleep 0.5
send "text clear"; send "key return"; sleep 1
send "text cat $CORPUS"; send "key return"
sleep 25
send "renderreset"; sleep 0.5

dump
END="$(field "d['tabs'][0]['panes'][0]['endRow']" "$DUMP")"
ROWS="$(field "d['tabs'][0]['panes'][0]['rows']" "$DUMP")"
# Far enough back that the rows are HISTORY (below the live screen), close
# enough that scrolling to them and away again stays under the row cache's own
# 600-row purge — otherwise the cache would empty itself and the negative pole
# would go green for a reason that has nothing to do with the atlas.
MARK=$(( END - ROWS - 120 ))
note "  buffer" "endRow $END, rows $ROWS, landing on $MARK"
goto_row "$MARK" || STATUS=1
sleep 1.2
shot "$SHOTS/129-before.png"
stats
BEFORE_RESETS="$(field "int(d.get('atlasResets', 0))" "$STATS")"
note "  atlas resets so far" "$BEFORE_RESETS"

# Now walk through rows nobody has drawn yet, which is what fills the atlas.
for step in $(seq 1 10); do send "scroll -12"; sleep 0.28; done
for step in $(seq 1 10); do send "scroll 12"; sleep 0.28; done
stats
AFTER_RESETS="$(field "int(d.get('atlasResets', 0))" "$STATS")"
atleast "the atlas really did start over" "$(( AFTER_RESETS - BEFORE_RESETS ))" 1
note "  frames rebuilt because it did" "$(field "int(d.get('atlasRestarts', 0))" "$STATS")"
note "  rebuilds that were not enough" "$(field "int(d.get('atlasRestartsGivenUp', 0))" "$STATS")"
note "  rows in the cache" "$(field "int(d.get('rowCacheSize', 0))" "$STATS")"

goto_row "$MARK" || STATUS=1
sleep 1.2
shot "$SHOTS/129-after.png"

# Same renderer, same rows, same theme: this is not a fidelity comparison
# between two rasterisers, so anything short of every pixel exact is a glyph
# that came back different.
DIFF="$(.build/t4a-imagediff "$SHOTS/129-before.png" "$SHOTS/129-after.png" \
        --out "$SHOTS/129-diff.png" 2>&1 || true)"
printf '%s\n' "$DIFF" | sed 's/^/    /'
EXACT="$(printf '%s\n' "$DIFF" | awk '/^[[:space:]]*exact/ { gsub("%","",$3); print $3; exit }')"
if [ -n "${EXACT:-}" ] && [ "$(/usr/bin/python3 -c "print(1 if float('$EXACT') >= 100.0 else 0)")" = "1" ]; then
  printf '%-48s %-24s (want %s) %s\n' "the history rows came back identical" "$EXACT%" "100%" "ok"
else
  printf '%-48s %-24s (want %s) %s\n' "the history rows came back identical" \
    "${EXACT:-unreadable}" "100%" "FAILED"
  STATUS=1
fi

send "key ctrl-c"; sleep 0.5
stop
[ "$STATUS" = "0" ] && echo "atlas: every pole held" || echo "atlas: a pole FAILED"
exit "$STATUS"
