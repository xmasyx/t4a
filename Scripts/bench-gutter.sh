#!/bin/bash
# ISC-137 — two durations never print on top of each other.
#
#   Scripts/bench-gutter.sh [app-bundle]
#
# The case is BUILT rather than waited for. A fold collapses several source
# rows onto one visual line, and the durations of every command inside it then
# want the same y: that is how `7ms` and `12ms` ended up stacked into a smudge
# in the light-theme photographs of 22/08. Real folds come from agent turns and
# cost an agent; the collision they cause costs a shell and a verb.
#
# Two things are asserted, and the second is what stops the first being empty:
# no two labels share a row, AND the guard actually refused at least one — a
# screen where no two labels ever wanted the same row would satisfy the first
# on any build, including the broken one.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-gutter.fifo"
CONFIG_HOME="/tmp/t4a-gutter-config"
DUMP=/tmp/t4a-gutter-dump.json
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
for tool in winid cropshot; do
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
  printf '%-52s %-16s (want %s) %s\n' "$name" "$got" "$want" "$mark"
}
note() { printf '%-52s %s\n' "$1" "$2"; }
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }

stop
rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"
printf 'theme = light\n' > "$CONFIG_HOME/t4a/config.toml"
rm -f "$FIFO"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3
send "activate"; sleep 0.8
open -a "$PWD/$APP" 2>/dev/null || true
sleep 2

# Puts the top of the view on an exact scroll-invariant row by correcting
# rather than counting: a scroll that reaches the end of the buffer clamps.
goto_row() {
  local target="$1"
  for _ in $(seq 1 12); do
    dump
    local now; now="$(field "d['tabs'][0]['panes'][0]['topVisibleRow']")"
    [ "$now" = "$target" ] && return 0
    send "scroll $(( now - target ))"
    sleep 0.3
  done
  note "  could not land on row $target" "stopped at $(field "d['tabs'][0]['panes'][0]['topVisibleRow']")"
  return 1
}

echo "=== three commands, each with a time beside it ======================"
for command in 'sleep 0.007' 'sleep 0.012' 'sleep 0.02'; do
  send "text $command"; send "key return"; sleep 1.5
done
# A FOLD MAY ONLY COVER HISTORY — the live screen belongs to the program
# drawing it, so RowFold clips every range against it. The three commands have
# to be pushed off the live screen before they can be folded at all; the first
# version of this bench folded rows 0-2 while they were still live, the range
# was discarded, and the bench reported that the guard had nothing to do. Which
# was true, and about the bench.
send "text seq 1 200"; send "key return"; sleep 3
dump
BLOCKS="$(field "len([b for b in d['tabs'][0]['panes'][0]['blocks'] if b['durationMs'] >= 0])")"
note "  blocks with a time" "$BLOCKS"
note "  labels printed, one row each" "$(field "d['tabs'][0]['panes'][0]['durationLabels']")"

echo ""
echo "=== now fold them onto ONE visual line =============================="
FIRST="$(field "min(b['promptRow'] for b in d['tabs'][0]['panes'][0]['blocks'] if b['durationMs'] >= 0)")"
LAST="$(field "max(b['promptRow'] for b in d['tabs'][0]['panes'][0]['blocks'] if b['durationMs'] >= 0)")"
note "  folding rows" "$FIRST-$LAST"
note "  live screen starts at" "$(field "d['tabs'][0]['panes'][0]['endRow'] - d['tabs'][0]['panes'][0]['rows']")"
# Scrolled back so the folded run is on screen; a label that is not drawn
# cannot be drawn twice.
goto_row "$(( FIRST > 2 ? FIRST - 2 : 0 ))" || STATUS=1
send "foldrows $FIRST-$LAST"; sleep 1.5
dump
LABELS="$(field "d['tabs'][0]['panes'][0]['durationLabels']")"
note "  labels printed" "$LABELS"
verdict "no two labels share a row" \
  "$(field "'ok' if len({l['row'] for l in d['tabs'][0]['panes'][0]['durationLabels']}) == len(d['tabs'][0]['panes'][0]['durationLabels']) else 'two on one row'")" \
  "ok"
DROPPED="$(field "d['tabs'][0]['panes'][0]['durationLabelsDropped']")"
verdict "and the guard really refused one" \
  "$(field "'yes' if d['tabs'][0]['panes'][0]['durationLabelsDropped'] > 0 else 'it had nothing to do'")" \
  "yes"
note "  labels refused" "$DROPPED"

mkdir -p design/evidence
WID="$(.build/t4a-winid || true)"
if [ -n "$WID" ]; then
  screencapture -x -o -l "$WID" design/evidence/f5-137-gutter-folded.png
  # A close-up of the TOP RIGHT of the terminal, which is where a duration is
  # printed. The first version cropped the middle of the page and photographed
  # blank paper — a photograph of the wrong place proves nothing at all.
  /usr/bin/python3 - <<'PY'
import json, subprocess
d = json.load(open('/tmp/t4a-gutter-dump.json'))
scale = 2                       # the screenshot is in device pixels
panels = d['panels']
right = panels['inspector']['x']            # the terminal ends where the inspector starts
top = panels['rail']['topFromWindow']       # and starts under the band
x = int((right - 260) * scale)
y = int(top * scale)
subprocess.run(['.build/t4a-cropshot', 'design/evidence/f5-137-gutter-folded.png',
                'design/evidence/f5-137-gutter-closeup.png',
                str(max(0, x)), str(max(0, y)), '520', '200'], check=True)
print(f'    crop {x},{y} 520x200 (terminal right edge {right}, band {top})')
PY
  note "  photographed" "design/evidence/f5-137-gutter-closeup.png"
else
  echo "no window id; no photograph"; STATUS=1
fi

send "foldrows"; sleep 0.5
stop
[ "$STATUS" = "0" ] && echo "gutter: every pole held" || echo "gutter: a pole FAILED"
exit "$STATUS"
