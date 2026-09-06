#!/bin/bash
# Measures what T4A costs while nothing is happening (ISC-38).
#
# Two numbers, both from the system rather than from the app's opinion of
# itself: the CPU time the process actually consumed over the window, and
# whether a periodic wake-up shows up in a stack sample. A terminal that
# redraws on a timer looks fine in a screenshot and eats a battery.
#
#   Scripts/bench-idle.sh [seconds]

set -euo pipefail
cd "$(dirname "$0")/.."

WINDOW="${1:-60}"
PID="$(pgrep -f 'T4A.app/Contents/MacOS/T4A' | head -1 || true)"
[ -n "$PID" ] || { echo "T4A is not running" >&2; exit 1; }

# Cumulative CPU seconds, straight from the kernel's accounting.
cpu_seconds() {
  ps -o cputime= -p "$1" | tr -d ' ' | awk -F: '{
    if (NF == 3) { print $1 * 3600 + $2 * 60 + $3 }
    else if (NF == 2) { print $1 * 60 + $2 }
    else { print $1 }
  }'
}

echo "pid $PID · window ${WINDOW}s · terminal idle"
START="$(cpu_seconds "$PID")"
sleep "$WINDOW"
END="$(cpu_seconds "$PID")"

/usr/bin/python3 - "$START" "$END" "$WINDOW" <<'PY'
import sys
start, end, window = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
used = end - start
percent = used / window * 100
print(f"cpu time used: {used:.2f}s over {window:.0f}s")
print(f"average cpu:   {percent:.3f}%")
print(f"threshold:     0.5%  ->  {'PASS' if percent < 0.5 else 'FAIL'}")
PY

echo
echo "stack sample (5s) — looking for a periodic wake-up:"
sample "$PID" 5 -mayDie 2>/dev/null > /tmp/t4a-idle-sample.txt || true
/usr/bin/python3 - <<'PY'
import re
text = open("/tmp/t4a-idle-sample.txt").read()
# Threads that are parked in a wait are free; a thread that is running, or one
# sitting in a repeating timer, is not.
suspects = ["CFRunLoopTimer", "NSTimer", "__psynch_cvwait ... poll", "kevent_id",
            "DispatchSource", "nanosleep", "usleep"]
lines = text.splitlines()
for name in ["CFRunLoopTimer", "NSTimer", "nanosleep", "usleep", "select", "poll"]:
    hits = sum(1 for line in lines if name in line)
    if hits:
        print(f"  {name}: {hits} frame(s)")
running = [l for l in lines if "state: running" in l.lower()]
print(f"  threads reported running: {len(running)}")
total = re.search(r"Call graph:", text)
print("  sample captured:", "yes" if total else "no")
PY
