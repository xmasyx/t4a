# Kill only the T4A instances THIS bench started — and run one bench at a time.
#
# Every bench used to open with `pkill -f "T4A.app/Contents/MacOS/T4A"`, which
# was harmless while T4A was a thing under construction and nothing else. It
# stopped being harmless the day the principal started working inside it: on
# 2026-08-24 a bench run closed his live session, tabs and agents included,
# and nothing in the output said so.
#
# The first discriminator was time: whatever was already running when the
# bench started is his, and is never touched. Time is not enough the night
# three sessions bench in parallel (2026-08-28, 00:55-01:03, ISC-218): an
# instance born AFTER this bench started is, to this bench, "mine to clean",
# even when another bench opened it — so two benches killed each other's app
# mid-pole, with no crash report and a green-looking log that just stopped.
#
# Two things fix that here, and neither needs the 37 benches touched:
#
#   1. The channel. Every bench opens the app with
#      `--env T4A_TEST_CHANNEL="$FIFO"`, and `ps eww <pid>` shows that
#      environment for a process of the same user (measured 2026-08-28: it
#      does, the older comment that said macOS refuses it was wrong for the
#      same-user case). So a bench that has `$FIFO` set only ever kills the
#      instances carrying ITS channel. Without `$FIFO`, or when the environment
#      cannot be read, it falls back to the time rule, which is what it did.
#   2. The lock. Sourcing this file takes `/tmp/t4a-bench.lock` (an atomic
#      `mkdir`) before the bench does anything, and holds it for the life of
#      the bench process. Nothing has to release it: the directory records the
#      owner pid, and a lock whose owner is dead is stale and taken over. A
#      lock without an owner file was taken by hand (the manual protocol of the
#      same night) and is honoured until it disappears, up to a ceiling, after
#      which the bench says so and goes on rather than hanging for ever.
#
# The `|| true` is not decoration: under `set -e` a `pgrep` that finds nothing
# exits 1, the assignment inherits it, and the whole bench dies before printing
# a single line. Cost of learning it: two silent runs, 2026-08-24.
T4A_PREEXISTING_PIDS="$(pgrep -f 'T4A.app/Contents/MacOS/T4A' 2>/dev/null | tr '\n' ' ' || true)"

T4A_BENCH_LOCK="${T4A_BENCH_LOCK:-/tmp/t4a-bench.lock}"
T4A_BENCH_LOCK_WAIT="${T4A_BENCH_LOCK_WAIT:-1800}"   # seconds before giving up on a foreign lock

# The channel this bench's instances carry, read off the process environment.
# Empty when the environment is not readable (then the caller falls back).
t4a_channel_of() {
    ps eww "$1" 2>/dev/null | grep -o 'T4A_TEST_CHANNEL=[^ ]*' | head -1 | cut -d= -f2-
}

# Is this pid one of OURS: born after the bench started, and — when the bench
# has a channel — carrying that channel. A readable environment with a
# different channel is somebody else's app, whatever its age.
t4a_owns_pid() {
    local pid="$1" chan
    case " $T4A_PREEXISTING_PIDS " in
        *" $pid "*) return 1 ;;                     # his, from before the bench
    esac
    [ -n "${FIFO:-}" ] || return 0                  # no channel known: the time rule
    chan="$(t4a_channel_of "$pid")"
    [ -n "$chan" ] || return 0                      # environment unreadable: the time rule
    [ "$chan" = "$FIFO" ]
}

t4a_stop_bench() {
    local pid
    for pid in $(pgrep -f 'T4A.app/Contents/MacOS/T4A' 2>/dev/null); do
        t4a_owns_pid "$pid" && kill "$pid" 2>/dev/null || true
    done
}

# The instances THIS bench is answerable for. Anyone asking "is one still
# alive?" or "how many are there?" has to ask it of these and never of `pgrep`
# alone — his own T4A answers `pgrep` too, and so does another bench's.
t4a_bench_pids() {
    local pid
    for pid in $(pgrep -f 'T4A.app/Contents/MacOS/T4A' 2>/dev/null); do
        t4a_owns_pid "$pid" && printf '%s\n' "$pid"
    done
    return 0
}

t4a_note_his_app() {
    [ -n "${T4A_PREEXISTING_PIDS// /}" ] || return 0
    echo "==> a T4A of yours is open (pid${T4A_PREEXISTING_PIDS%% *}): the bench leaves it alone."
}

# One bench at a time. Returns once this process holds the lock (or once the
# ceiling passed, loudly). The owner file is what makes release unnecessary.
t4a_bench_lock() {
    local waited=0 owner
    while :; do
        if mkdir "$T4A_BENCH_LOCK" 2>/dev/null; then
            printf '%s\n' "$$" > "$T4A_BENCH_LOCK/owner"
            return 0
        fi
        owner="$(cat "$T4A_BENCH_LOCK/owner" 2>/dev/null || true)"
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$T4A_BENCH_LOCK" 2>/dev/null || true   # stale: its bench is gone
            continue
        fi
        if [ "$waited" -ge "$T4A_BENCH_LOCK_WAIT" ]; then
            echo "==> bench lock held for ${waited}s by ${owner:-an unknown holder}; going on without it." >&2
            return 0
        fi
        [ "$waited" -eq 0 ] && echo "==> another bench holds $T4A_BENCH_LOCK (${owner:-no owner file}); waiting." >&2
        sleep 2; waited=$((waited + 2))
    done
}

# Explicit release, for a bench that wants to hand over early. Never required.
t4a_bench_unlock() {
    [ "$(cat "$T4A_BENCH_LOCK/owner" 2>/dev/null)" = "$$" ] && rm -rf "$T4A_BENCH_LOCK" 2>/dev/null
    return 0
}

[ "${T4A_BENCH_NO_LOCK:-}" = "1" ] || t4a_bench_lock
