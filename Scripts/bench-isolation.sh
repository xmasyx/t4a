#!/bin/bash
# ISC-218 — a bench kills only the T4A instances it opened, and two benches
# never run at once.
#
#   Scripts/bench-isolation.sh [app-bundle]
#
# Poles:
#   1  the lock: a second bench waits while a live holder exists, and goes on
#      the moment the holder dies (stale lock taken over).
#   2  the stop: two instances with two channels; `t4a_stop_bench` from the
#      bench that owns channel A leaves the instance on channel B alive.
#   2n the same with the bench-stop.sh of HEAD~ (the time-only rule): the
#      instance on channel B dies — the defect this bench exists for.
#   3  `t4a_bench_pids` lists only the instance on our channel.
#
# Runs its own T4A copies with a throwaway config; the principal's app is never
# touched (it predates the bench). Uses a private lock path so it can test the
# lock without fighting the real one.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/T4A.app}"
LIB="Scripts/lib/bench-stop.sh"
STATUS=0
verdict() { if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1${3:+ — $3}"; STATUS=1; fi; }

export T4A_BENCH_LOCK=/tmp/t4a-bench-isolation.lock
rm -rf "$T4A_BENCH_LOCK"

echo "=== 1. the lock ==="
# A holder that lives 6 s: a second sourcing must block until it dies.
# Real processes, not subshells: in bash 3.2 a subshell keeps the parent's $$,
# so a subshell holder would write THIS script's pid as owner and never look stale.
bash -c 'source "$0"; sleep 6' "$LIB" &
HOLDER=$!
sleep 1
START=$(date +%s)
bash -c 'source "$0"; echo "got the lock after $(( $(date +%s) - $1 ))s"' "$LIB" "$START" > /tmp/t4a-isolation-lock.txt
wait "$HOLDER" 2>/dev/null
WAITED=$(sed -n 's/.*after \([0-9]*\)s/\1/p' /tmp/t4a-isolation-lock.txt)
POLE=0; [ -n "$WAITED" ] && [ "$WAITED" -ge 4 ] && [ "$WAITED" -le 12 ] || POLE=1
verdict "1 the second bench waited for the live holder, then went on (waited ${WAITED:-?}s)" "$POLE"
rm -rf "$T4A_BENCH_LOCK"

# From here the bench itself holds the private lock, like any bench would.
source "$LIB"
t4a_note_his_app

open_one() {  # $1 fifo  $2 config home
    rm -rf "$2" "$1"; mkdir -p "$2/t4a"
    printf 'composer-mode = never\n' > "$2/t4a/config.toml"
    open -n "$APP" --env T4A_TEST_CHANNEL="$1" --env XDG_CONFIG_HOME="$2"
    for _ in $(seq 1 40); do [ -p "$1" ] && return 0; sleep 0.25; done
    echo "the test channel $1 never appeared" >&2; return 1
}
pid_of() { for p in $(pgrep -f 'T4A.app/Contents/MacOS/T4A'); do [ "$(t4a_channel_of "$p")" = "$1" ] && echo "$p"; done; }

# Channel names carry this run's pid: a leftover instance from an interrupted run
# must never be mistaken for one of ours.
FIFO_A=/tmp/t4a-iso-a-$$.fifo; FIFO_B=/tmp/t4a-iso-b-$$.fifo
open_one "$FIFO_A" /tmp/t4a-iso-a-config-$$ || STATUS=1
open_one "$FIFO_B" /tmp/t4a-iso-b-config-$$ || STATUS=1
sleep 2
PID_A="$(pid_of "$FIFO_A")"; PID_B="$(pid_of "$FIFO_B")"
echo "    A=$PID_A on $FIFO_A · B=$PID_B on $FIFO_B"

echo "=== 3. t4a_bench_pids lists only our channel ==="
FIFO="$FIFO_A"
LISTED="$(t4a_bench_pids | tr '\n' ' ')"
POLE=0; case " $LISTED " in *" $PID_A "*) ;; *) POLE=1 ;; esac; case " $LISTED " in *" $PID_B "*) POLE=1 ;; esac
verdict "3 bench_pids = [$LISTED] (A in, B out)" "$POLE"

echo "=== 2. stop from the bench that owns A leaves B alive ==="
FIFO="$FIFO_A"; t4a_stop_bench; sleep 1.5
POLE=0; kill -0 "$PID_A" 2>/dev/null && POLE=1; kill -0 "$PID_B" 2>/dev/null || POLE=1
verdict "2 A gone, B alive" "$POLE" "A alive=$(kill -0 "$PID_A" 2>/dev/null && echo yes || echo no) B alive=$(kill -0 "$PID_B" 2>/dev/null && echo yes || echo no)"

echo "=== 2n. the same stop with the OLD bench-stop.sh (time rule only) kills B ==="
OLD=/tmp/t4a-iso-old-bench-stop.sh
# 8cfd8b4 is the last main before the channel rule (b4f3691): the time-only bench-stop.sh.
if git show 8cfd8b4:Scripts/lib/bench-stop.sh > "$OLD" 2>/dev/null; then
    # A fresh bench under the old rule, started AFTER B was born: B looks like its own.
    # T4A_BENCH_NO_LOCK guards against a future old-file that already knows the lock.
    ( FIFO="$FIFO_A"; T4A_BENCH_NO_LOCK=1; T4A_PREEXISTING_PIDS=""; source "$OLD"; T4A_PREEXISTING_PIDS=""; t4a_stop_bench )
    sleep 1.5
    POLE=0; kill -0 "$PID_B" 2>/dev/null && POLE=1
    verdict "2n old rule killed B (the defect, shown red on the old code)" "$POLE"
else
    echo "SKIP 2n: no old bench-stop.sh in history"
fi
kill "$PID_B" 2>/dev/null || true
rm -rf "/tmp/t4a-iso-a-config-$$" "/tmp/t4a-iso-b-config-$$" "$FIFO_A" "$FIFO_B" "$OLD" /tmp/t4a-isolation-lock.txt "$T4A_BENCH_LOCK"
echo; [ "$STATUS" -eq 0 ] && echo "ALL GREEN" || echo "RED"
exit "$STATUS"
