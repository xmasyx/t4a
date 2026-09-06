#!/bin/bash
# Drives the running T4A through its test channel and reads its state back.
#
#   Scripts/drive.sh start                 launch the bundle with the channel on
#   Scripts/drive.sh send 'text ls\n'      one command
#   Scripts/drive.sh dump [file]           write the app's state and print it
#   Scripts/drive.sh shot <file>           photograph the real window
#   Scripts/drive.sh stop
#
# Nothing here reimplements the app's logic: it types, waits, and reads what
# the app itself reports.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

FIFO="${T4A_TEST_CHANNEL:-/tmp/t4a-test.fifo}"
# The bundle to drive. Overridable so a bench can be pointed at a bundle built
# from another commit, which is how a negative pole gets measured instead of
# asserted.
APP="${T4A_APP:-dist/T4A.app}"

WINID_BIN=".build/t4a-winid"

window_id() {
  if [ ! -x "$WINID_BIN" ] || [ Scripts/winid.swift -nt "$WINID_BIN" ]; then
    mkdir -p .build
    swiftc -O Scripts/winid.swift -o "$WINID_BIN"
  fi
  "$WINID_BIN"
}

case "${1:-}" in
  start)
    # One instance OF THIS BENCH's, provably. Two T4A processes both read the
    # same channel and both answer `dump`, so a test can be reading one app
    # while typing into another — which looked exactly like a terminal that had
    # stopped responding, and cost an hour of chasing the wrong bug.
    #
    # "Of this bench's" is the whole of ISC-190. Every question below used to
    # be put to `pgrep`, which answers for the principal's own T4A as well: the
    # polite `t4a_stop_bench` spared his pid, the wait then sat out its ten
    # seconds waiting for a process nobody had asked to leave, and the `pkill
    # -9` underneath killed it by pattern — session, tabs and agents. Sparing a
    # process in one line and killing it by name in the next is not a guard, it
    # is a guard with a hole cut in it, and it stayed open from 24/08 to 27/08.
    t4a_stop_bench
    for _ in $(seq 1 40); do
      [ -z "$(t4a_bench_pids)" ] && break
      sleep 0.25
    done
    STUBBORN="$(t4a_bench_pids | tr '\n' ' ')"
    if [ -n "${STUBBORN// /}" ]; then
      kill -9 $STUBBORN 2>/dev/null || true
      sleep 1
    fi
    rm -f "$FIFO"
    [ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle: run Scripts/build-app.sh" >&2; exit 1; }
    # A caller that isolated its configuration expects the app to be launched
    # inside that isolation (ISC-132). `open` starts the app from launchd, so
    # nothing in this shell's environment reaches it unless it is named here.
    ENVS=(--env T4A_TEST_CHANNEL="$FIFO")
    [ -n "${XDG_CONFIG_HOME:-}" ] && ENVS+=(--env XDG_CONFIG_HOME="$XDG_CONFIG_HOME")
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && ENVS+=(--env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR")
    T4A_TEST_CHANNEL="$FIFO" open -n "$APP" "${ENVS[@]}"
    for _ in $(seq 1 40); do
      [ -p "$FIFO" ] && break
      sleep 0.25
    done
    [ -p "$FIFO" ] || { echo "test channel never appeared" >&2; exit 1; }
    # Counted among ours, not among every T4A on the machine: with his own open
    # this said "expected 1, found 2" and refused to start, which is the same
    # defect wearing its harmless face.
    COUNT="$(t4a_bench_pids | grep -c . || true)"
    [ "$COUNT" = "1" ] || { echo "expected 1 T4A process of this bench's own, found $COUNT" >&2; exit 1; }
    t4a_note_his_app
    # The pid THIS start launched, written next to the channel so that `stop`
    # — which runs in a NEW process, where "everything that was already up"
    # includes the instance started here — can kill exactly this one and
    # nothing else. Without the file `stop` stopped nothing from 25/08 to
    # 27/08 (seen by fetta C, ISC-190): `bench-agent.sh` tore down twice and
    # left two instances alive to steal the focus of the bench after it.
    t4a_bench_pids > "${FIFO}.pid"
    # The shell has to reach its first prompt before anything is typed at it.
    for _ in $(seq 1 60); do
      rm -f /tmp/t4a-ready.json
      /usr/bin/python3 Scripts/sendline.py "$FIFO" "dump /tmp/t4a-ready.json" 2>/dev/null || true
      sleep 0.25
      if [ -s /tmp/t4a-ready.json ] && /usr/bin/python3 -c "
import json,sys
d=json.load(open('/tmp/t4a-ready.json'))
p=d['tabs'][0]['panes'][0]
sys.exit(0 if p['blocks'] else 1)
" 2>/dev/null; then
        echo "started; channel $FIFO; shell at its first prompt"
        exit 0
      fi
    done
    echo "the shell never reached a prompt" >&2
    exit 1
    ;;
  check-seam)
    # The hedge, as a falsifier rather than a promise: the VT library may be
    # imported by its own target only, and the app may name that target in one
    # file — the factory whose job is naming it.
    LIB="$(git grep -l '^import SwiftTerm$' -- Sources | grep -v '^Sources/SwiftTermBackend/' || true)"
    APP="$(git grep -l '^import SwiftTermBackend$' -- Sources/T4A || true)"
    STATUS=0
    if [ -n "$LIB" ]; then echo "SwiftTerm imported outside its target: $LIB"; STATUS=1; fi
    COUNT="$(printf '%s' "$APP" | grep -c . || true)"
    if [ "$COUNT" != "1" ] || [ "$APP" != "Sources/T4A/BackendFactory.swift" ]; then
      echo "the app names the backend in: ${APP:-nothing} (expected only Sources/T4A/BackendFactory.swift)"
      STATUS=1
    fi
    [ "$STATUS" = "0" ] && echo "seam intact: the engine is behind the grid interface"
    exit "$STATUS"
    ;;
  ready)
    # Waits until the ACTIVE pane is sitting at a prompt with nothing running.
    # Typing before a new shell's line editor is up gets the characters echoed
    # and the Return swallowed, which reads exactly like a terminal that does
    # not accept input.
    for _ in $(seq 1 80); do
      rm -f /tmp/t4a-ready.json
      /usr/bin/python3 Scripts/sendline.py "$FIFO" "dump /tmp/t4a-ready.json" || exit 1
      sleep 0.25
      if [ -s /tmp/t4a-ready.json ] && /usr/bin/python3 -c "
import json, sys
d = json.load(open('/tmp/t4a-ready.json'))
panes = [p for t in d['tabs'] for p in t['panes'] if p['active']]
if not panes: sys.exit(1)
blocks = panes[0]['blocks']
sys.exit(0 if blocks and blocks[-1]['durationMs'] == -1 and not blocks[-1]['command'] else 1)
" 2>/dev/null; then
        exit 0
      fi
    done
    echo "the active pane never reached an idle prompt" >&2
    exit 1
    ;;
  send)
    shift
    /usr/bin/python3 Scripts/sendline.py "$FIFO" "$*"
    ;;
  delivered)
    OUT="${2:-/tmp/t4a-delivered.json}"
    rm -f "$OUT"
    /usr/bin/python3 Scripts/sendline.py "$FIFO" "delivered $OUT"
    for _ in $(seq 1 40); do [ -s "$OUT" ] && break; sleep 0.1; done
    cat "$OUT" 2>/dev/null || echo "[]"
    ;;
  dump)
    OUT="${2:-/tmp/t4a-dump.json}"
    rm -f "$OUT"
    /usr/bin/python3 Scripts/sendline.py "$FIFO" "dump $OUT"
    for _ in $(seq 1 40); do
      [ -s "$OUT" ] && break
      sleep 0.1
    done
    cat "$OUT"
    ;;
  shot)
    OUT="${2:?usage: drive.sh shot <file>}"
    WID="$(window_id)"
    [ -n "$WID" ] || { echo "no T4A window on screen" >&2; exit 1; }
    screencapture -x -o -l "$WID" "$OUT"
    echo "$OUT"
    ;;
  stop)
    # Kill by the pid `start` wrote, never by pattern (his T4A answers the
    # pattern too) and never by "what was up before" (from here, everything
    # was). A missing file — a start older than this rule — falls back to the
    # polite discriminator, which is at worst a no-op.
    if [ -s "${FIFO}.pid" ]; then
      while read -r pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
      done < "${FIFO}.pid"
      rm -f "${FIFO}.pid"
    else
      t4a_stop_bench
    fi
    rm -f "$FIFO"
    ;;
  *)
    echo "usage: drive.sh start|send <cmd>|dump [file]|shot <file>|stop" >&2
    exit 2
    ;;
esac
