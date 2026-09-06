#!/bin/bash
# ISC-238 — the titlebar inset is reclaimed in full screen, inside the
# system transition, and restored point-for-point afterwards.
#
#   Scripts/bench-fullscreen.sh [--head <bundle>]
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh

APP="${T4A_APP:-dist/T4A.app}"
HEAD=""
STATUS=0
WORK="$(mktemp -d /tmp/t4a-fullscreen-bench.XXXXXX)" || exit 1
FIFO=""
DUMP=""
RUN_ROOT=""

usage() { echo "usage: Scripts/bench-fullscreen.sh [--head <bundle>]" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --head)
      [ $# -ge 2 ] || { usage; exit 2; }
      HEAD="$2"; shift
      ;;
    *) usage; exit 2 ;;
  esac
  shift
done

absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
APP="$(absolute "$APP")"
[ -z "$HEAD" ] || HEAD="$(absolute "$HEAD")"

cleanup() {
  t4a_stop_bench
  t4a_bench_unlock
  case "$(basename "$WORK")" in t4a-fullscreen-bench.*) rm -rf "$WORK" ;; esac
}
trap cleanup EXIT INT TERM

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }

dump() {
  local name="$1"
  DUMP="$RUN_ROOT/$name.json"
  rm -f "$DUMP"
  send "dump $DUMP" || return 1
  for _ in $(seq 1 100); do [ -s "$DUMP" ] && return 0; sleep .05; done
  echo "dump $name never arrived" >&2
  return 1
}

pole() {
  local label="$1" result="$2" detail="$3"
  if [ "$result" -eq 0 ]; then
    printf 'PASS  %-43s %s\n' "$label" "$detail"
  else
    printf 'FAIL  %-43s %s\n' "$label" "$detail"
    STATUS=1
  fi
}

not_run() {
  printf 'NOT RUN  %-39s %s\n' "$1" "$2"
  STATUS=1
}

launch() {
  local bundle="$1" label="$2"
  t4a_stop_bench
  RUN_ROOT="$WORK/$label"
  FIFO="$RUN_ROOT/channel.fifo"
  DUMP="$RUN_ROOT/dump.json"
  mkdir -p "$RUN_ROOT/config/t4a"
  /usr/bin/python3 - "$RUN_ROOT/config/t4a/config.toml" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
    'theme = black\nlayout-sessions = rail\nshow-turn-map = true\n'
    'show-dashboard = false\ncomposer-mode = never\nmotion = true\n')
PY
  [ -x "$bundle/Contents/MacOS/T4A" ] || return 1
  open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" \
    --env XDG_CONFIG_HOME="$RUN_ROOT/config" || return 1
  for _ in $(seq 1 80); do [ -p "$FIFO" ] && break; sleep .1; done
  [ -p "$FIFO" ] || return 1
  sleep 2
  send activate
  send "layout rail"
  sleep .4
  echo "bundle=$bundle"
  echo "channel=$FIFO"
}

wait_state() {
  local name="$1" expression="$2"
  for _ in $(seq 1 100); do
    dump "$name" || continue
    /usr/bin/python3 - "$DUMP" "$expression" <<'PY' && return 0
import json, sys
d = json.load(open(sys.argv[1]))
try:
    result = bool(eval(sys.argv[2], {"__builtins__": {}}, {"d": d}))
except Exception:
    result = False
raise SystemExit(0 if result else 1)
PY
    sleep .05
  done
  return 1
}

# New bundles expose the three drawn ink rectangles directly. HEAD predates
# that field, so its negative reads the equivalent existing witnesses: the
# side-heading origin is panelTop+14 and BandView already publishes title ink.
geometry() {
  /usr/bin/python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if "fullScreenLayout" in d:
    g = d["fullScreenLayout"]
    rail, content, inspector = g["railY"], g["contentY"], g["inspectorY"]
else:
    rail = d["panels"]["rail"]["topFromWindow"] + 14
    content = d["band"]["title"]["topFromWindow"]
    inspector = d["panels"]["inspector"]["topFromWindow"] + 14
spread = max(rail, content, inspector) - min(rail, content, inspector)
print(f"rail={rail:.3f} content={content:.3f} inspector={inspector:.3f} spread={spread:.3f}")
PY
}

geometry_check() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
mode = sys.argv[2]
g = d.get("fullScreenLayout")
if g:
    values = [g["railY"], g["contentY"], g["inspectorY"]]
else:
    values = [d["panels"]["rail"]["topFromWindow"] + 14,
              d["band"]["title"]["topFromWindow"],
              d["panels"]["inspector"]["topFromWindow"] + 14]
spread = max(values) - min(values)
ok = spread <= 1.0 if mode == "aligned" else spread > 1.0
raise SystemExit(0 if ok else 1)
PY
}

windowed_same() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:])
def signature(d):
    g = d["fullScreenLayout"]
    return {
        "railY": g["railY"], "contentY": g["contentY"],
        "inspectorY": g["inspectorY"], "bandTop": g["bandTop"],
        "bandHeight": g["bandHeight"], "tabStripTop": g["tabStripTop"],
        "terminalTopInset": g["terminalTopInset"],
        "panels": d["panels"], "band": {
            key: d["band"].get(key) for key in
            ("bandHeight", "topInset", "title", "path")
        },
    }
sa, sb = signature(a), signature(b)
print("before=" + json.dumps(sa, sort_keys=True, separators=(",", ":")))
print("after =" + json.dumps(sb, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if sa == sb else 1)
PY
}

echo "=== ISC-238 · F0 geometry =========================================="
if ! launch "$APP" current; then
  CAUSE="bundle non avviato o canale di prova assente (LaunchServices/WindowServer): $APP"
  not_run "F0 geometry and exact restoration" "$CAUSE"
  not_run "F1 negative on HEAD" "$CAUSE"
  not_run "F2 120 Hz transition frames" "$CAUSE; inoltre il metro ISC-235 conserva solo hash/timestamp globali e non può provare doppie posizioni o quiete post-Did senza ROI/pixel e marker host-clock"
  not_run "F3 tabstrip + segni + render" "$CAUSE"
  exit "$STATUS"
fi

if dump window; then
  WINDOW_DUMP="$DUMP"
  WINDOW_GEO="$(geometry "$WINDOW_DUMP")"
  geometry_check "$WINDOW_DUMP" different
  pole "F0 windowed starts remain intentional" "$?" "$WINDOW_GEO"
else
  not_run "F0 windowed geometry" "initial dump unavailable"
  WINDOW_DUMP=""
fi

send "fullscreen on"
if wait_state full 'd["window"]["fullScreen"] and d.get("fullScreenLayout",{}).get("transition") == "fullScreen"'; then
  FULL_DUMP="$DUMP"
  FULL_GEO="$(geometry "$FULL_DUMP")"
  geometry_check "$FULL_DUMP" aligned
  pole "F0 full-screen starts align within 1 pt" "$?" "$FULL_GEO"
  /usr/bin/python3 - "$FULL_DUMP" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))["fullScreenLayout"]
ok = (g["compactBand"] and g["bandTop"] == 7 and g["bandHeight"] == 38
      and g["terminalTopInset"] == 38)
print("layout=" + json.dumps(g, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if ok else 1)
PY
  pole "F0 compact target is the measured target" "$?" "bandTop=7 bandHeight=38 terminalTopInset=38"
else
  not_run "F0 full-screen geometry" "DidEnter/full-screen dump did not settle within 10 s"
fi

send "fullscreen off"
if wait_state back 'not d["window"]["fullScreen"] and d.get("fullScreenLayout",{}).get("transition") == "windowed"'; then
  BACK_DUMP="$DUMP"
  BACK_GEO="$(geometry "$BACK_DUMP")"
  if [ -n "$WINDOW_DUMP" ]; then
    RESTORE_DETAIL="$(windowed_same "$WINDOW_DUMP" "$BACK_DUMP" 2>&1)"
    pole "F0 windowed geometry returns point-for-point" "$?" "$BACK_GEO"
    printf '%s\n' "$RESTORE_DETAIL"
  fi
else
  not_run "F0 return to window" "DidExit/windowed dump did not settle within 10 s"
fi
t4a_stop_bench

echo "=== ISC-238 · F1 HEAD negative ====================================="
if [ -z "$HEAD" ]; then
  not_run "F1 negative on HEAD" "pass --head <bundle built from 26e97db>"
elif ! launch "$HEAD" head; then
  not_run "F1 negative on HEAD" "could not launch $HEAD"
else
  send "fullscreen on"
  # HEAD has no transition field; its styleMask is the settling witness.
  if wait_state head-full 'd["window"]["fullScreen"]'; then
    HEAD_DUMP="$DUMP"
    HEAD_GEO="$(geometry "$HEAD_DUMP")"
    geometry_check "$HEAD_DUMP" different
    pole "F1 HEAD does not align in full screen" "$?" "$HEAD_GEO"
  else
    not_run "F1 negative on HEAD" "HEAD did not enter full screen within 10 s"
  fi
  send "fullscreen off"
  sleep 3
  t4a_stop_bench
fi

echo "=== ISC-238 · F2 transition fluidity ==============================="
not_run "F2 no duplicate/post-Did frames at 120 Hz" \
  "Scripts/.build-scrolllatency hashes a decimated whole window and injects mandatory scroll events; it retains no ROI/pixels or hook boundary, so it cannot detect two vertical copies or post-Did reflow. Required meter: passive 120 Hz ScreenCaptureKit ROI with vertical template correlation, frame retention, and host-clock Will/Did markers (now exposed in fullScreenLayout.hooks)."

echo "=== ISC-238 · F3 established regressions ==========================="
echo "--- bench-tabstrip (complete output)"
T4A_BENCH_NO_LOCK=1 Scripts/bench-tabstrip.sh "$APP"
TAB_STATUS=$?
pole "F3 bench-tabstrip 4/4" "$TAB_STATUS" "status=$TAB_STATUS"

echo "--- bench-segni (complete output)"
T4A_BENCH_NO_LOCK=1 T4A_APP="$APP" Scripts/bench-segni.sh
SEGNI_STATUS=$?
pole "F3 bench-segni S0-S9" "$SEGNI_STATUS" "status=$SEGNI_STATUS"

echo "--- bench-render (complete output)"
T4A_BENCH_NO_LOCK=1 T4A_APP="$APP" Scripts/bench-render.sh 30
RENDER_STATUS=$?
pole "F3 bench-render" "$RENDER_STATUS" "status=$RENDER_STATUS"

exit "$STATUS"
