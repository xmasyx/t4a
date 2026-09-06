#!/bin/bash
# ISC-106, the real thing — a genuine drag of the window's corner, with the
# configuration file watched from outside while it happens.
#
#   Scripts/bench-live-resize.sh [app-bundle] [label]
#
# The mouse is really pressed on the window edge and really moved, so AppKit
# runs a real live resize: `inLiveResize` is sampled DURING the drag to prove
# the app was in one, and the file's inode is sampled throughout to count
# writes without asking the app. A run that cannot show `inLiveResize: true`
# has not resized anything and says so rather than reporting a pass.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
LABEL="${2:-after}"
FIFO="/tmp/t4a-live-$LABEL.fifo"
CONFIG_HOME="/tmp/t4a-live-config-$LABEL"
CONFIG="$CONFIG_HOME/t4a/config.toml"
DRAG_BIN=".build/t4a-dragresize"

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
if [ ! -x "$DRAG_BIN" ] || [ Scripts/dragresize.swift -nt "$DRAG_BIN" ]; then
  mkdir -p .build
  swiftc -O Scripts/dragresize.swift -o "$DRAG_BIN"
fi

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$2"; send "dump $2"; for _ in $(seq 1 30); do [ -s "$2" ] && break; sleep 0.1; done; }

t4a_stop_bench
sleep 1
rm -rf "$CONFIG_HOME" "$FIFO"
mkdir -p "$CONFIG_HOME"

open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 2

# A file to watch, and a frame to grab.
send "theme warm"
for _ in $(seq 1 40); do [ -s "$CONFIG" ] && break; sleep 0.25; done
dump "" /tmp/t4a-live-$LABEL-before.json

# The frame comes from the window server, so this bench runs unchanged
# against a build that has no dump to read it from.
FRAME_BIN=".build/t4a-winframe"
if [ ! -x "$FRAME_BIN" ] || [ Scripts/winframe.swift -nt "$FRAME_BIN" ]; then
  swiftc -O Scripts/winframe.swift -o "$FRAME_BIN"
fi
read -r X Y W H <<EOF
$("$FRAME_BIN")
EOF
[ "${W:-0}" != "0" ] || { echo "could not read the window frame" >&2; exit 1; }
echo "==> window at ${X},${Y} sized ${W}x${H}; dragging its corner"

INODES=/tmp/t4a-live-$LABEL-inodes.txt
: > "$INODES"
(
  end=$(( $(date +%s) + 6 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    stat -f %i "$CONFIG" 2>/dev/null >> "$INODES" || true
  done
) &
SAMPLER=$!

# Mid-drag, ask the app whether it is in a live resize. This is the sample
# that says the drag was real.
( sleep 1.2; /usr/bin/python3 Scripts/sendline.py "$FIFO" "dump /tmp/t4a-live-$LABEL-mid.json" ) &
MID=$!

rm -f /tmp/t4a-live-$LABEL-mid.json
"$DRAG_BIN" "$X" "$Y" "$W" "$H" -220 -140 45
wait "$MID" 2>/dev/null || true
wait "$SAMPLER" 2>/dev/null || true

sleep 0.5
dump "" /tmp/t4a-live-$LABEL-after.json

/usr/bin/python3 - "$LABEL" "$INODES" <<'PY'
import json, os, sys
label, inodes = sys.argv[1], sys.argv[2]

def load(path):
    return json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}

before = load(f"/tmp/t4a-live-{label}-before.json")
mid    = load(f"/tmp/t4a-live-{label}-mid.json")
after  = load(f"/tmp/t4a-live-{label}-after.json")

seen = set()
for line in open(inodes):
    line = line.strip()
    if line: seen.add(line)
samples = sum(1 for _ in open(inodes))

def win(d, key, default=None): return d.get("window", {}).get(key, default)
w0, w1 = before.get("configWrites"), after.get("configWrites")
writes = "n/a (build has no counter)" if w1 is None else str(w1 - w0)
changes = "n/a"
if win(after, "frameChanges") is not None:
    changes = str(win(after, "frameChanges") - (win(before, "frameChanges") or 0))

print(f"label              {label}")
print(f"in live resize     {win(mid, 'inLiveResize')}   (sampled 1.2s into the drag)")
print(f"size before/after  {win(before,'width')}x{win(before,'height')} -> {win(after,'width')}x{win(after,'height')}")
print(f"frame changes      {changes}   (windowDidResize calls during the drag)")
print(f"file versions      {len(seen)}   (distinct inodes, {samples} samples from outside)")
print(f"configWrites       {writes}")
print(f"saved frame        {win(after, 'savedFrame')}")
PY

t4a_stop_bench
rm -f "$FIFO"
