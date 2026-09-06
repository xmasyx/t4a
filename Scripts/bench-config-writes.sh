#!/bin/bash
# ISC-106 bench — how many times does the configuration file get written while
# the window is being resized?
#
#   Scripts/bench-config-writes.sh [app-bundle] [label]
#
# The window is resized 60 times over three seconds, the pace of a hand
# dragging an edge. Two independent counters watch the file:
#
#   * from outside, a sampler reads the file's inode 200 times a second. The
#     app writes atomically — a temporary file and a rename — so every write
#     is a NEW inode, and counting distinct inodes counts writes without
#     trusting anything the app says about itself.
#   * from inside, the app's own `configWrites` counter, incremented at the
#     write call. Present only on builds that have it; a build without it
#     prints "n/a" rather than a zero that would read like a pass.
#
# The two poles are two bundles: the one in this tree, and one built from the
# commit before the repair. A bench that only ever sees green has not been
# shown to be able to go red.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
LABEL="${2:-after}"
FIFO="/tmp/t4a-bench-$LABEL.fifo"
CONFIG_HOME="/tmp/t4a-bench-config-$LABEL"
CONFIG="$CONFIG_HOME/t4a/config.toml"
RESIZES=60
PACE=0.05

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

t4a_stop_bench
sleep 1
rm -rf "$CONFIG_HOME" "$FIFO"
mkdir -p "$CONFIG_HOME"

open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }

# The file has to exist before its inode means anything, and changing a
# setting is the honest way to make it exist.
/usr/bin/python3 Scripts/sendline.py "$FIFO" "theme warm"
for _ in $(seq 1 40); do [ -s "$CONFIG" ] && break; sleep 0.25; done
[ -s "$CONFIG" ] || { echo "the configuration file was never written" >&2; exit 1; }

before_dump=/tmp/t4a-bench-$LABEL-before.json
rm -f "$before_dump"
/usr/bin/python3 Scripts/sendline.py "$FIFO" "dump $before_dump"
sleep 0.5

# The sampler runs for the whole storm plus the settle window.
INODES=/tmp/t4a-bench-$LABEL-inodes.txt
: > "$INODES"
(
  end=$(( $(date +%s) + 6 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    stat -f %i "$CONFIG" 2>/dev/null >> "$INODES" || true
  done
) &
SAMPLER=$!

echo "==> $RESIZES resizes over $(echo "$RESIZES * $PACE" | bc)s on $APP"
for i in $(seq 1 "$RESIZES"); do
  width=$(( 1100 + (i % 30) * 8 ))
  height=$(( 700 + (i % 30) * 5 ))
  /usr/bin/python3 Scripts/sendline.py "$FIFO" "resize ${width}x${height}" || true
  sleep "$PACE"
done

wait "$SAMPLER" 2>/dev/null || true

after_dump=/tmp/t4a-bench-$LABEL-after.json
rm -f "$after_dump"
/usr/bin/python3 Scripts/sendline.py "$FIFO" "dump $after_dump"
sleep 0.6

/usr/bin/python3 - "$LABEL" "$INODES" "$before_dump" "$after_dump" "$RESIZES" <<'PY'
import json, sys, os
label, inodes, before, after, resizes = sys.argv[1:6]
seen, order = set(), 0
for line in open(inodes):
    line = line.strip()
    if line and line not in seen:
        seen.add(line); order += 1
samples = sum(1 for _ in open(inodes))

def field(path, *keys):
    if not os.path.exists(path) or os.path.getsize(path) == 0: return None
    d = json.load(open(path))
    for k in keys:
        if not isinstance(d, dict) or k not in d: return None
        d = d[k]
    return d

w0, w1 = field(before, "configWrites"), field(after, "configWrites")
f0, f1 = field(before, "window", "frameChanges"), field(after, "window", "frameChanges")
writes = "n/a (build has no counter)" if w1 is None else str(w1 - w0)
changes = "n/a" if f1 is None else str(f1 - f0)
print(f"label            {label}")
print(f"resizes sent     {resizes}")
print(f"frame changes    {changes}   (windowDidResize calls the app saw)")
print(f"file versions    {order}   (distinct inodes, from {samples} samples outside the app)")
print(f"configWrites     {writes}   (counted at the write, inside the app)")
PY

t4a_stop_bench
rm -f "$FIFO"
