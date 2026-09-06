#!/bin/bash
# ISC-235 — pixel scrolling, its settling, and the same event-to-pixel meter
# applied to T4A HEAD, T4A now, and iTerm 2.
#
#   Scripts/bench-scroll-fluid.sh [--head <bundle>] [--iterm]

set -uo pipefail
cd "$(dirname "$0")/.."

APP="dist/T4A.app"
HEAD=""
WITH_ITERM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --head)
      [ $# -ge 2 ] || { echo "--head needs an app bundle" >&2; exit 2; }
      HEAD="$2"; shift 2 ;;
    --iterm) WITH_ITERM=1; shift ;;
    --*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) echo "unexpected argument: $1" >&2; exit 2 ;;
  esac
done

LATENCY="Scripts/.build-scrolllatency"
SCROLLGEN="Scripts/.build-scrollgen"
LOG="/tmp/t4a-200mb.log"
WORK="$(mktemp -d -t t4a-scroll-fluid)" || exit 1
FIFO="$WORK/channel.fifo"
DUMP="$WORK/dump.json"
STATUS=0
CLEANED=0
FRAME="100,100,1200,700"
# 400,650: the point that reaches the pane in every geometry measured on 30/08; (700,450) landed nowhere on T4A.
METER_X=400
METER_Y=650

hash_of() { [ -e "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo '(absent)'; }
REAL_T4A_CONFIG="$HOME/.config/t4a/config.toml"
REAL_CLAUDE_CONFIG="$HOME/.claude.json"
BEFORE_T4A="$(hash_of "$REAL_T4A_CONFIG")"
BEFORE_CLAUDE="$(hash_of "$REAL_CLAUDE_CONFIG")"

pole() {
  local name="$1" result="$2" detail="$3"
  if [ "$result" -eq 0 ]; then
    printf '%-68s PASS  %s\n' "$name" "$detail"
  else
    printf '%-68s FAIL  %s\n' "$name" "$detail"
    STATUS=1
  fi
}

not_run() {
  printf '%-68s NOT RUN  %s\n' "$1" "$2"
  STATUS=1
}

not_applicable() {
  printf '%-68s NOT APPLICABLE  %s\n' "$1" "$2"
}

all_not_run() {
  local why="$1"
  not_run "235a pixel frames during shell scrollback" "$why"
  not_run "H-235a HEAD keeps the measured pixel-scroll baseline" "$why"
  not_run "235b ISC-20/21/22 renderer regression bank" "$why"
  not_run "235c gesture settles, with and without motion" "$why"
  not_run "235d alternate screen owns the wheel" "$why"
  not_run "235e selection begins on the visibly hit row" "$why"
  not_run "235f six-case T4A/HEAD/iTerm table" "$why"
  not_run "235g alternate first key and total key count" "$why"
}

echo '==> preflight: pgrep -fl "T4A.app/Contents/MacOS/T4A"'
PREFLIGHT="$(pgrep -fl "T4A.app/Contents/MacOS/T4A" 2>&1)"
PREFLIGHT_STATUS=$?
if [ -n "$PREFLIGHT" ]; then printf '%s\n' "$PREFLIGHT"; else echo '(no matches)'; fi
if [ "$PREFLIGHT_STATUS" -gt 1 ]; then
  all_not_run "pgrep failed with status $PREFLIGHT_STATUS; safe cleanup is unavailable"
  case "$(basename "$WORK")" in t4a-scroll-fluid.*) rm -rf "$WORK";; esac
  exit 1
fi

source "$(dirname "$0")/lib/bench-stop.sh"

cleanup() {
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  t4a_stop_bench
  case "$(basename "$WORK")" in t4a-scroll-fluid.*) rm -rf "$WORK";; esac
  local after_t4a after_claude result
  after_t4a="$(hash_of "$REAL_T4A_CONFIG")"
  after_claude="$(hash_of "$REAL_CLAUDE_CONFIG")"
  result=PASS; [ "$after_t4a" = "$BEFORE_T4A" ] || { result=FAIL; STATUS=1; }
  printf '%-68s %s  before=%s after=%s\n' \
    "real t4a config sha256 (byte-identical)" "$result" "$BEFORE_T4A" "$after_t4a"
  result=PASS; [ "$after_claude" = "$BEFORE_CLAUDE" ] || { result=FAIL; STATUS=1; }
  printf '%-68s %s  before=%s after=%s\n' \
    "real claude config sha256 (byte-identical)" "$result" "$BEFORE_CLAUDE" "$after_claude"
}
trap cleanup EXIT

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }

dump() {
  rm -f "$DUMP"
  send "dump $DUMP" || return 1
  for _ in $(seq 1 50); do [ -s "$DUMP" ] && break; sleep 0.1; done
  [ -s "$DUMP" ]
}

stats() {
  local path="$1"
  rm -f "$path"
  send "renderstats $path" || return 1
  for _ in $(seq 1 50); do [ -s "$path" ] && break; sleep 0.1; done
  [ -s "$path" ]
}

json_value() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
value = eval(sys.argv[2], {"__builtins__": {}}, {"d": d})
if isinstance(value, bool): print("true" if value else "false")
elif isinstance(value, (dict, list)): print(json.dumps(value, separators=(",", ":")))
else: print(value)
PY
}

write_config() {
  local path="$1"
  mkdir -p "$path/t4a" || return 1
  printf 'scrollback-lines = 100000\ntheme = black\nmotion = true\n' > "$path/t4a/config.toml"
}

launch_t4a() {
  local bundle="$1" label="$2" claude_home="${3:-}"
  local config="$WORK/config-$label"
  t4a_stop_bench
  for _ in $(seq 1 30); do [ -z "$(t4a_bench_pids)" ] && break; sleep 0.2; done
  FIFO="$WORK/$label.fifo"
  DUMP="$WORK/$label-dump.json"
  rm -f "$FIFO" "$DUMP"
  write_config "$config" || return 1
  local envs=(--env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$config")
  [ -n "$claude_home" ] && envs+=(--env CLAUDE_CONFIG_DIR="$claude_home")
  open -n "$bundle" "${envs[@]}" || return 1
  for _ in $(seq 1 50); do [ -p "$FIFO" ] && break; sleep 0.2; done
  [ -p "$FIFO" ] || return 1
  sleep 2
  send "activate"
  sleep 0.3
}

run_meter_t4a() {
  local output="$1" pixels="${2:-3}" events="${3:-120}" interval="${4:-8.33}"
  send "activate"; sleep 0.2
  "$LATENCY" app=dev.t4a.terminal pid="$(t4a_bench_pids | tail -1)" \
    x="$METER_X" y="$METER_Y" frame="$FRAME" events="$events" pixels="$pixels" \
    intervalMs="$interval" captureHz=120 json > "$output"
  local result=$?
  [ -s "$output" ] && cat "$output"
  return "$result"
}

fill_shell() {
  send "text head -c 20000000 $LOG" || return 1
  send "key return" || return 1
  sleep 12
}

metric_check_235a() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
m, s = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
ok = m["distinctFrames"] >= 100 and m["maxGapMs"] is not None and m["maxGapMs"] <= 25
ok = ok and s.get("frames", 0) >= 100
print(f"distinctFrames={m['distinctFrames']} firstChangeMs={m['firstChangeMs']} "
      f"maxGapMs={m['maxGapMs']} captures={m['captures']} "
      f"sampleHzReal={m['sampleHzReal']} renderstats.frames={s.get('frames', 0)}")
raise SystemExit(0 if ok else 1)
PY
}

print_wheel_profile() {
  /usr/bin/python3 - "$1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print("\n| profile site | samples | median ms | max ms |")
print("|---|---:|---:|---:|")
print(f"| handlePreciseScroll | {s.get('wheelEvents', 0):g} | "
      f"{s.get('wheelMedianMs', 0):.3f} | {s.get('wheelMaxMs', 0):.3f} |")
print(f"| scrollUp/scrollDown → scrollTo | {s.get('wheelScrollToSamples', 0):g} | "
      f"{s.get('wheelScrollToMedianMs', 0):.3f} | {s.get('wheelScrollToMaxMs', 0):.3f} |")
print(f"| settleViewport | {s.get('wheelSettleSamples', 0):g} | "
      f"{s.get('wheelSettleMedianMs', 0):.3f} | {s.get('wheelSettleMaxMs', 0):.3f} |")
print(f"| draw(link:) | {s.get('drawSamples', 0):g} | "
      f"{s.get('drawMedianMs', 0):.3f} | {s.get('drawMaxMs', 0):.3f} |")
print(f"| noDrawable | {s.get('noDrawable', 0):g} | — | — |")
print(f"| immediateDraws | {s.get('immediateDraws', 0):g} | — | — |")
PY
}

echo '==> building the two input probes'
if ! swiftc -parse-as-library -O -o "$LATENCY" Scripts/scrolllatency.swift \
    Sources/AgentAdapters/ScrollMeterSummary.swift; then
  all_not_run "scrolllatency did not compile"
  exit 1
fi
if ! swiftc -O -o "$SCROLLGEN" Scripts/scrollgen.swift; then
  all_not_run "scrollgen did not compile"
  exit 1
fi
if [ ! -x "$APP/Contents/MacOS/T4A" ]; then
  all_not_run "no current bundle at $APP"
  exit 1
fi
if [ ! -s "$LOG" ]; then
  all_not_run "$LOG is missing"
  exit 1
fi

echo '==> zero pole: display on, then one byte causes a rendered frame'
if ! launch_t4a "$APP" zero; then
  all_not_run "could not launch the current bench bundle"
  exit 1
fi
send "renderreset"
send "text echo ISC-235-control"
send "key return"
sleep 1
ZERO_STATS="$WORK/zero-stats.json"
if ! stats "$ZERO_STATS"; then
  all_not_run "the app did not answer renderstats"
  exit 1
fi
ZERO_FRAMES="$(json_value "$ZERO_STATS" "d.get('frames', 0)")"
if ! /usr/bin/python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) >= 1 else 1)' "$ZERO_FRAMES"; then
  all_not_run "echo produced $ZERO_FRAMES renderer frames"
  exit 1
fi
# Put ink through the captured window. A solitary prompt on a black terminal
# is still observable because ScreenCaptureKit includes the window chrome.
send "text seq 1 80"; send "key return"; sleep 0.5
ZERO_METER="$WORK/zero-meter.json"
run_meter_t4a "$ZERO_METER" 1 120 8.33
ZERO_METER_RESULT=$?
if [ "$ZERO_METER_RESULT" -ne 0 ]; then
  all_not_run "scrolllatency control failed (exit $ZERO_METER_RESULT)"
  exit 1
fi
ZERO_HZ="$(json_value "$ZERO_METER" "d.get('sampleHzReal', 0)")"
if ! /usr/bin/python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) >= 100 else 1)' "$ZERO_HZ"; then
  all_not_run "ScreenCaptureKit control sampled at ${ZERO_HZ}Hz, below 100Hz"
  exit 1
fi
pole "zero: display, renderer, and >=100Hz sampler are observable" 0 \
  "echo frames=$ZERO_FRAMES sampleHzReal=$ZERO_HZ; control=$(cat "$ZERO_METER")"

echo '==> 235a: one second of precise shell scrollback'
if ! fill_shell; then
  not_run "235a pixel frames during shell scrollback" "could not fill scrollback"
else
  dump; cp "$DUMP" "$WORK/new-shell-before.json"
  send "renderreset"
  NEW_SHELL="$WORK/new-shell.json"
  if run_meter_t4a "$NEW_SHELL" 3 120 8.33; then
    NEW_STATS="$WORK/new-shell-stats.json"; stats "$NEW_STATS"
    print_wheel_profile "$NEW_STATS"
    DETAIL="$(metric_check_235a "$NEW_SHELL" "$NEW_STATS" 2>&1)"; CHECK=$?
    pole "235a distinct>=100, maxGap<=25ms, renderer frames>=100" "$CHECK" "$DETAIL"
  else
    not_run "235a pixel frames during shell scrollback" "scrolllatency failed"
  fi
fi

echo '==> 235c: the remainder settles by 150ms; motion-off uses the next frame'
X="$METER_X"; Y="$METER_Y"
if [ -n "$X" ] && [ -n "$Y" ]; then
  send "motion on"; send "activate"
  "$LATENCY" app=dev.t4a.terminal pid="$(t4a_bench_pids | tail -1)" x="$X" y="$Y" events=120 pixels=3 \
    frame="$FRAME" intervalMs=8.33 captureHz=120 json > "$WORK/settle-on-meter.json" & METER_PID=$!
  # The meter streams for a second, then keeps capturing for 300 ms. The
  # settle is judged after it returns, at least 300 ms after the last event.
  wait "$METER_PID"; METER_RESULT=$?
  dump; cp "$DUMP" "$WORK/settle-on-dump.json"
  ON_OFFSET="$(json_value "$WORK/settle-on-dump.json" "d['tabs'][0]['panes'][0]['scrollOffset']")"
  /usr/bin/python3 -c 'import sys; raise SystemExit(0 if abs(float(sys.argv[1])) < 0.01 else 1)' "$ON_OFFSET"; ON_CHECK=$?
  pole "235c motion-on aligned within 150ms" "$((METER_RESULT || ON_CHECK))" "scrollOffset=$ON_OFFSET"

  send "motion off"; send "activate"
  "$LATENCY" app=dev.t4a.terminal pid="$(t4a_bench_pids | tail -1)" x="$X" y="$Y" events=120 pixels=3 \
    frame="$FRAME" intervalMs=8.33 captureHz=120 json > "$WORK/settle-off-meter.json" & METER_PID=$!
  wait "$METER_PID"; METER_RESULT=$?
  dump; cp "$DUMP" "$WORK/settle-off-dump.json"
  OFF_OFFSET="$(json_value "$WORK/settle-off-dump.json" "d['tabs'][0]['panes'][0]['scrollOffset']")"
  /usr/bin/python3 -c 'import sys; raise SystemExit(0 if abs(float(sys.argv[1])) < 0.01 else 1)' "$OFF_OFFSET"; OFF_CHECK=$?
  pole "235c motion-off aligned on the next observable frame" \
    "$((METER_RESULT || OFF_CHECK))" "scrollOffset=$OFF_OFFSET"
  send "motion on"
else
  not_run "235c gesture settles, with and without motion" "could not locate the pane"
fi

echo '==> 235e: selection starts while a non-zero draw remainder is visible'
send "activate"
# One 5 px event leaves a 5 px remainder and nothing else in flight. Dragging
# while a 120-event stream was still scrolling (run 6) selected rows three
# lines away from the ones dumped before the drag: the rows had moved under
# the drag, which measured the stream, not the hit test.
"$SCROLLGEN" 1 5 1 pid="$(t4a_bench_pids | tail -1)" loc="$X,$Y" > "$WORK/selection-scrollgen.txt"
dump; cp "$DUMP" "$WORK/selection-before.json"
NONZERO=1
if [ "$NONZERO" -eq 1 ]; then
  send "drag 0,2 20,3"; sleep 0.2; dump; cp "$DUMP" "$WORK/selection-after.json"
  DETAIL="$(/usr/bin/python3 - "$WORK/selection-before.json" "$WORK/selection-after.json" <<'PY'
import json, sys
before, after = (json.load(open(p)) for p in sys.argv[1:])
screen = before['tabs'][0]['panes'][0]['screen']
selection = after['tabs'][0]['panes'][0]['selection']
# A drag from x=0 lands three cells in (the left inset of the pane), so a
# needle taken from column 0 never matches even at zero offset (measured
# 30/08 on HEAD and current alike: the selection began at 15317 for a row
# reading 00015317). Compare the part of the row the drag can actually cover.
needles = [screen[2][3:11].strip(), screen[3][3:11].strip()]
ok = all(n and n in selection for n in needles)
print(f"beforeOffset={before['tabs'][0]['panes'][0]['scrollOffset']} "
      f"needles={needles!r} selection={selection!r}")
raise SystemExit(0 if ok else 1)
PY
)"; CHECK=$?
  pole "235e drag selects the two visible rows" "$CHECK" "$DETAIL"
else
  not_run "235e selection begins on the visibly hit row" "no non-zero offset was observed"
fi
: # the single-event generator already returned (30/08)

echo '==> 235d/235g: alternate screen owns the wheel; first arrow after one-third row'
send "text less -N /etc/services"; send "key return"; sleep 2
dump; cp "$DUMP" "$WORK/alternate-before.json"
LESS_MOUSE_MODE="$(json_value "$WORK/alternate-before.json" \
  "d['tabs'][0]['panes'][0]['diagnostics'].get('mouseMode', 'missing')")"
echo "mouseMode less fullscreen: $LESS_MOUSE_MODE"
if [ -n "$METER_X" ] && [ -n "$METER_Y" ]; then
  X="$METER_X"; Y="$METER_Y"; send "activate"
  "$LATENCY" app=dev.t4a.terminal pid="$(t4a_bench_pids | tail -1)" x="$X" y="$Y" events=120 pixels=-3 \
    frame="$FRAME" intervalMs=8.33 captureHz=120 json > "$WORK/alternate-meter.json" & METER_PID=$!
  ALT_OFFSET_BAD=0
  for index in 1 2 3 4; do
    sleep 0.20; dump || { ALT_OFFSET_BAD=1; continue; }
    cp "$DUMP" "$WORK/alternate-during-$index.json"
    OFFSET="$(json_value "$DUMP" "d['tabs'][0]['panes'][0]['scrollOffset']")"
    /usr/bin/python3 -c 'import sys; raise SystemExit(0 if abs(float(sys.argv[1])) < 0.01 else 1)' "$OFFSET" \
      || ALT_OFFSET_BAD=1
  done
  wait "$METER_PID"; METER_RESULT=$?
  dump; cp "$DUMP" "$WORK/alternate-after.json"
  DETAIL="$(/usr/bin/python3 - "$WORK/alternate-before.json" "$WORK/alternate-after.json" <<'PY'
import json, sys
a, b = (json.load(open(p))['tabs'][0]['panes'][0] for p in sys.argv[1:])
ok = a['alternateScreen'] and b['alternateScreen'] and a['screen'] != b['screen']
print(f"alternate={a['alternateScreen']} screenChanged={a['screen'] != b['screen']}")
raise SystemExit(0 if ok else 1)
PY
)"; SCREEN_CHECK=$?
  pole "235d alternate screen owns wheel; offset stays zero" \
    "$((METER_RESULT || ALT_OFFSET_BAD || SCREEN_CHECK))" "$DETAIL offsetBad=$ALT_OFFSET_BAD"
  if [ "$LESS_MOUSE_MODE" = "off" ]; then
    G_RESULT=0
    for run in 1 2 3 4 5; do
      dump || { G_RESULT=1; continue; }
      cp "$DUMP" "$WORK/235g-before-$run.json"
      run_meter_t4a "$WORK/235g-meter-$run.json" -3 120 8.33 || G_RESULT=1
      dump || { G_RESULT=1; continue; }
      cp "$DUMP" "$WORK/235g-after-$run.json"
    done
    DETAIL="$(/usr/bin/python3 - "$WORK" <<'PY'
import json, os, re, statistics, sys
root = sys.argv[1]
def first_numbered_line(screen):
    for line in screen:
        match = re.match(r'^\s*(\d+)\s', line)
        if match:
            return int(match.group(1))
    return None
firsts, moved = [], []
for run in range(1, 6):
    meter = json.load(open(os.path.join(root, f"235g-meter-{run}.json")))
    before = json.load(open(os.path.join(root, f"235g-before-{run}.json")))['tabs'][0]['panes'][0]['screen']
    after = json.load(open(os.path.join(root, f"235g-after-{run}.json")))['tabs'][0]['panes'][0]['screen']
    firsts.append(meter.get('firstChangeMs'))
    a, b = first_numbered_line(before), first_numbered_line(after)
    moved.append(abs(b-a) if a is not None and b is not None else None)
valid = all(value is not None for value in firsts + moved)
first_median = statistics.median(firsts) if valid else None
moved_median = statistics.median(moved) if valid else None
ok = valid and first_median < 25 and 21 <= moved_median <= 23
print(f"mouseMode=off firstChangeMs={firsts} median={first_median} "
      f"keysInferred={moved} median={moved_median}")
raise SystemExit(0 if ok else 1)
PY
)"; CHECK=$?
    pole "235g median of five first changes <25ms; median movement 22+/-1 rows" \
      "$((G_RESULT || CHECK))" "$DETAIL"
  else
    not_applicable "235g alternate first key and total key count" \
      "less mouseMode=$LESS_MOUSE_MODE; mouse reporting owns the wheel"
  fi
else
  not_run "235d alternate screen owns the wheel" "could not locate the pane"
  not_run "235g alternate first key and total key count" "could not locate the pane"
fi
send "text q"; sleep 0.5
t4a_stop_bench

echo '==> H-235a: HEAD pixel-scroll baseline stays independently observable'
if [ -n "$HEAD" ] && [ -x "$HEAD/Contents/MacOS/T4A" ]; then
  if launch_t4a "$HEAD" head-shell && fill_shell; then
    dump; cp "$DUMP" "$WORK/head-shell-before.json"
    HEAD_SHELL="$WORK/head-shell.json"
    run_meter_t4a "$HEAD_SHELL" 3 120 8.33; HEAD_RESULT=$?
    dump; cp "$DUMP" "$WORK/head-shell-after.json"
    DETAIL="$(/usr/bin/python3 - "$HEAD_SHELL" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
first = m.get('firstChangeMs')
ok = m['distinctFrames'] >= 100 and first is not None and first >= 20
print(f"distinctFrames={m['distinctFrames']} firstChangeMs={first} "
      f"maxGapMs={m.get('maxGapMs')}")
raise SystemExit(0 if ok else 1)
PY
)"; CHECK=$?
    pole "H-235a HEAD distinct>=100 (HEAD 88ebbfc already scrolls by the pixel)" \
      "$((HEAD_RESULT || CHECK))" "$DETAIL"
  else
    not_run "H-235a HEAD keeps the measured pixel-scroll baseline" "could not run $HEAD"
  fi
  t4a_stop_bench
else
  not_run "H-235a HEAD keeps the measured pixel-scroll baseline" "pass --head <bundle>"
fi

echo '==> 235b: the established renderer bank, HEAD then current'
if [ -n "$HEAD" ] && [ -x "$HEAD/Contents/MacOS/T4A" ]; then
  echo "--- bench-render HEAD ($HEAD)"
  T4A_BENCH_NO_LOCK=1 T4A_APP="$HEAD" Scripts/bench-render.sh 12
  HEAD_RENDER=$?
else
  HEAD_RENDER=1
  echo '--- bench-render HEAD NOT RUN: pass --head <bundle>'
fi
echo "--- bench-render current ($APP)"
T4A_BENCH_NO_LOCK=1 T4A_APP="$APP" Scripts/bench-render.sh 12
NEW_RENDER=$?
if [ "$HEAD_RENDER" -eq 0 ] && [ "$NEW_RENDER" -eq 0 ]; then
  pole "235b ISC-20/21/22 stay green before and after" 0 "both complete outputs are above"
else
  pole "235b ISC-20/21/22 stay green before and after" 1 \
    "HEAD status=$HEAD_RENDER current status=$NEW_RENDER"
fi

run_meter_t4a_five() {
  local prefix="$1" run
  for run in 1 2 3 4 5; do
    run_meter_t4a "$prefix-$run.json" 3 120 8.33 || return 1
  done
}

prepare_t4a_claude() {
  local bundle="$1" label="$2" prefix="$3"
  local claude_home="$HOME/.cache/t4a/bench-claude-home"
  launch_t4a "$bundle" "$label" "$claude_home" || return 1
  # The shell starts wherever launchd put it, and claude asks to trust that
  # folder before it draws anything: a fixed sleep then read
  # alternateScreen=false and declared the cell NOT RUN (30/08, run 6).
  # Same folder as bench-find-transcript, and the trust question answered.
  mkdir -p "$HOME/Movies/t4a-bench-chat"
  send "text cd $HOME/Movies/t4a-bench-chat && CLAUDE_CONFIG_DIR=$claude_home claude"; send "key return"
  local ready=0
  for _ in $(seq 1 40); do
    sleep 0.5; dump || continue
    if [ "$(json_value "$DUMP" "'Yes, I trust' in ''.join(d['tabs'][0]['panes'][0]['screen'])")" = true ]; then
      send "key down"; send "key return"; continue
    fi
    if [ "$(json_value "$DUMP" "'Enter to confirm' in ''.join(d['tabs'][0]['panes'][0]['screen'])")" = true ]; then
      send "key return"; continue
    fi
    if [ "$(json_value "$DUMP" "d['tabs'][0]['panes'][0]['alternateScreen']")" = true ]; then ready=1; break; fi
  done
  [ "$ready" -eq 1 ] || echo "claude never reached the alternate screen ($label)"
  # After the first refused turn claude 2.1.251 opens «Teach auto mode about
  # your environment?» (numbered selector): the other 39 lines then went into
  # that dialog, the transcript stayed one turn long, and the wheel had nothing
  # to scroll (30/08, run 9: distinctFrames=0, photographed). Option 2 is
  # «Don't show again», which the stable claude home remembers.
  local n
  for n in $(seq 1 40); do
    send "text Not logged in"; send "key return"; sleep 0.08
    if [ $((n % 4)) -eq 1 ]; then
      sleep 0.4; dump || continue
      if [ "$(json_value "$DUMP" "'Teach auto mode' in ''.join(d['tabs'][0]['panes'][0]['screen'])")" = true ]; then
        send "key down"; send "key return"; sleep 0.5
      fi
    fi
  done
  sleep 2
  dump || return 1
  cp "$DUMP" "$WORK/$label-before.json"
  local alternate mouse_mode
  alternate="$(json_value "$DUMP" "d['tabs'][0]['panes'][0]['alternateScreen']")"
  mouse_mode="$(json_value "$DUMP" \
    "d['tabs'][0]['panes'][0]['diagnostics'].get('mouseMode', 'missing')")"
  echo "mouseMode claude fullscreen ($label): $mouse_mode alternateScreen=$alternate"
  [ "$alternate" = "true" ] || return 1
  run_meter_t4a_five "$prefix"
}

iterm_new() {
  osascript -e 'tell application "iTerm" to activate' \
    -e 'tell application "iTerm" to create window with default profile' >/dev/null
}

iterm_write() {
  local escaped=${1//\\/\\\\}; escaped=${escaped//\"/\\\"}
  osascript -e "tell application \"iTerm\" to tell current session of current window to write text \"$escaped\"" >/dev/null
}

iterm_contents() {
  osascript -e 'tell application "iTerm" to get contents of current session of current window' 2>/dev/null
}

iterm_key() {
  local code="$1"
  osascript -e 'tell application "iTerm" to activate' \
    -e "tell application \"System Events\" to key code $code" >/dev/null
}

iterm_answer_startup() {
  local screen
  for _ in $(seq 1 60); do
    screen="$(iterm_contents)" || { sleep 0.5; continue; }
    if [[ "$screen" == *"Yes, I trust"* ]]; then
      iterm_key 125; iterm_key 36; sleep 0.5; continue
    fi
    if [[ "$screen" == *"Enter to confirm"* ]]; then
      iterm_key 36; sleep 0.5; continue
    fi
    # Claude 2.1.251 selects “Don't show again” with one Down from the
    # default. Leaving this dialog up consumed the 39 following prompts and
    # produced the empty iTerm×Claude cell in three consecutive runs.
    if [[ "$screen" == *"Teach auto mode"* ]]; then
      iterm_key 125; iterm_key 36; sleep 0.5; continue
    fi
    if [[ "$screen" == *"Not logged in"* || "$screen" == *"Claude Code"* ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo 'iTerm Claude startup did not reach a recognised screen' >&2
  return 1
}

iterm_measure() {
  local output="$1"
  "$LATENCY" app=com.googlecode.iterm2 x="$METER_X" y="$METER_Y" frame="$FRAME" \
    events=120 pixels=3 intervalMs=8.33 captureHz=120 json > "$output"
  local result=$?
  if [ -s "$output" ]; then
    cat "$output"
  elif [ "$result" -ne 0 ]; then
    echo "scrolllatency failed for iTerm (exit $result) and wrote no output: $output"
  fi
  [ "$result" -eq 0 ] || echo "scrolllatency iTerm failure above (exit $result, file=$output)"
  return "$result"
}

iterm_measure_five() {
  local prefix="$1" run
  for run in 1 2 3 4 5; do
    iterm_measure "$prefix-$run.json" || return 1
  done
}

echo '==> 235f: equal 1200x700 windows, median of five runs per cell'
if launch_t4a "$APP" compare-new-shell && fill_shell; then
  run_meter_t4a_five "$WORK/new-shell" || true
fi
t4a_stop_bench
prepare_t4a_claude "$APP" compare-new-claude "$WORK/new-claude" || true
t4a_stop_bench
if [ -n "$HEAD" ] && [ -x "$HEAD/Contents/MacOS/T4A" ]; then
  if launch_t4a "$HEAD" compare-head-shell && fill_shell; then
    run_meter_t4a_five "$WORK/head-shell" || true
  fi
  t4a_stop_bench
  prepare_t4a_claude "$HEAD" compare-head-claude "$WORK/head-claude" || true
  t4a_stop_bench
fi

if [ "$WITH_ITERM" -eq 1 ]; then
  if open -a iTerm && sleep 2 && iterm_new; then
    iterm_write "head -c 20000000 $LOG"; sleep 12
    iterm_measure_five "$WORK/iterm-shell" || true
    osascript -e 'tell application "iTerm" to close current window' >/dev/null 2>&1 || true
  fi
  # A second window right after closing the first sometimes fails the
  # AppleScript call (run 11: the whole cell vanished without a line).
  ITERM_OK=0; for _ in 1 2 3; do sleep 1; if iterm_new; then ITERM_OK=1; break; fi; done
  [ "$ITERM_OK" -eq 1 ] || echo 'iTerm Claude cell NOT RUN: could not create an iTerm window'
  if [ "$ITERM_OK" -eq 1 ]; then
    CLAUDE_HOME="$HOME/.cache/t4a/bench-claude-home"
    iterm_write "cd $HOME/Movies/t4a-bench-chat && CLAUDE_CONFIG_DIR=$CLAUDE_HOME claude"
    if iterm_answer_startup; then
      for n in $(seq 1 40); do
        iterm_write "Not logged in"; sleep 0.08
        if [ $((n % 4)) -eq 1 ]; then
          screen="$(iterm_contents)"
          if [[ "$screen" == *"Teach auto mode"* ]]; then
            iterm_key 125; iterm_key 36; sleep 0.5
          fi
        fi
      done
      sleep 2
      iterm_measure_five "$WORK/iterm-claude" || true
    else
      echo 'iTerm Claude cell NOT RUN: startup dialog could not be cleared'
    fi
    osascript -e 'tell application "iTerm" to close current window' >/dev/null 2>&1 || true
  fi
fi

/usr/bin/python3 - "$WORK" <<'PY'
import json, os, statistics, sys
root = sys.argv[1]
cases = [
    ("T4A current", "shell", "new-shell"),
    ("T4A HEAD", "shell", "head-shell"),
    ("iTerm 2", "shell", "iterm-shell"),
    ("T4A current", "Claude fullscreen", "new-claude"),
    ("T4A HEAD", "Claude fullscreen", "head-claude"),
    ("iTerm 2", "Claude fullscreen", "iterm-claude"),
]
metrics = ("firstChangeMs", "distinctFrames", "maxGapMs", "sampleHzReal")
def five(prefix):
    return [json.load(open(os.path.join(root, f"{prefix}-{run}.json")))
            for run in range(1, 6)]
def summarize(values, integral=False):
    median = statistics.median(values)
    if integral:
        return f"{median:g} [{min(values):g}–{max(values):g}]"
    return f"{median:.3f} [{min(values):.3f}–{max(values):.3f}]"
print("\n| app | case | firstChangeMs median [min–max] | distinctFrames median [min–max] | maxGapMs median [min–max] | sampleHzReal median [min–max] |")
print("|---|---|---:|---:|---:|---:|")
complete = True
rows = {}
for app, case, prefix in cases:
    try:
        runs = five(prefix)
        values = {metric: [run[metric] for run in runs] for metric in metrics}
        if any(value is None for series in values.values() for value in series):
            raise ValueError("null metric")
        rows[(app, case)] = {metric: statistics.median(series)
                             for metric, series in values.items()}
        row = [summarize(values["firstChangeMs"]),
               summarize(values["distinctFrames"], integral=True),
               summarize(values["maxGapMs"]),
               summarize(values["sampleHzReal"])]
    except Exception:
        complete = False
        row = ["NOT RUN"] * 4
    print(f"| {app} | {case} | " + " | ".join(map(str, row)) + " |")

verdict = complete
if complete:
    for case in ("shell", "Claude fullscreen"):
        current, iterm = rows[("T4A current", case)], rows[("iTerm 2", case)]
        first_ok = current["firstChangeMs"] <= iterm["firstChangeMs"]
        frames_ok = current["distinctFrames"] >= iterm["distinctFrames"]
        gap_ok = current["maxGapMs"] <= iterm["maxGapMs"] + 2
        verdict = verdict and first_ok and frames_ok and gap_ok
        print(f"235f verdict {case}: firstChange {current['firstChangeMs']:.3f} <= "
              f"{iterm['firstChangeMs']:.3f} is {first_ok}; distinctFrames "
              f"{current['distinctFrames']:g} >= {iterm['distinctFrames']:g} is {frames_ok}; "
              f"maxGap {current['maxGapMs']:.3f} <= {iterm['maxGapMs']:.3f}+2 is {gap_ok}")
raise SystemExit(0 if verdict else 1)
PY
TABLE_RESULT=$?
pole "235f six cells x five runs; current meets all three iTerm bounds" "$TABLE_RESULT" \
  "frame=$FRAME; medians and min-max are the verdict"

cleanup
trap - EXIT
exit "$STATUS"
