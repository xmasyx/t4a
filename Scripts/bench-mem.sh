#!/bin/bash
# ISC-236 — inactive tabs keep their grid and atlas, but not full-size Metal
# drawable pools.
#
#   Scripts/bench-mem.sh [--head <bundle>]
#
# The current build is `T4A_APP` or dist/T4A.app. An optional testable bundle
# from main supplies the negative control. Every process this script stops is
# identified by this run's private T4A_TEST_CHANNEL; an already-running T4A is
# never a target.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh

APP="${T4A_APP:-dist/T4A.app}"
HEAD=""
STATUS=0
P0="NOT RUN"
P1="NOT RUN"
P2="NOT RUN"
P3="NOT RUN (no --head bundle supplied)"
P4="NOT RUN"
LOCK_RELEASED=0
WORK="$(mktemp -d /tmp/t4a-mem-bench.XXXXXX)"
RUN_ROOT=""
FIFO=""
PID=""
DUMP=""

usage() { echo "usage: Scripts/bench-mem.sh [--head <bundle>]" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --head)
      [ $# -ge 2 ] || { usage; exit 2; }
      HEAD="$2"
      shift
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
  [ "$LOCK_RELEASED" -eq 1 ] || t4a_bench_unlock
}
trap cleanup EXIT INT TERM

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  local name="$1"
  DUMP="$RUN_ROOT/$name.json"
  send "dump $DUMP" || return 1
  for _ in $(seq 1 100); do [ -s "$DUMP" ] && return 0; sleep .05; done
  echo "dump $name never arrived"
  return 1
}
stats() {
  local path="$1"
  send "renderstats $path" || return 1
  for _ in $(seq 1 100); do [ -s "$path" ] && return 0; sleep .05; done
  echo "renderstats never arrived at $path"
  return 1
}
field() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": data}))
PY
}
verdict() {
  local label="$1" result="$2" detail="$3"
  if [ "$result" -eq 0 ]; then
    printf 'PASS  %-38s %s\n' "$label" "$detail"
  else
    printf 'FAIL  %-38s %s\n' "$label" "$detail"
    STATUS=1
  fi
}

bench_pid() {
  local candidate
  for candidate in $(t4a_bench_pids); do
    [ "$(t4a_channel_of "$candidate")" = "$FIFO" ] && echo "$candidate"
  done | tail -1
}

launch() {
  local bundle="$1" name="$2"
  [ -x "$bundle/Contents/MacOS/T4A" ] || {
    echo "$name bundle is not executable: $bundle"
    return 1
  }
  RUN_ROOT="$WORK/$name"
  FIFO="$RUN_ROOT/channel.fifo"
  DUMP="$RUN_ROOT/dump.json"
  local config="$RUN_ROOT/config"
  mkdir -p "$config/t4a"
  printf 'scrollback-lines = 10000\ntheme = black\ncursor-motion = off\nfont-size = 20\n' \
    > "$config/t4a/config.toml"
  open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$config"
  for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep .25; done
  [ -p "$FIFO" ] || { echo "$name: test channel never appeared"; return 1; }
  sleep 3
  PID="$(bench_pid)"
  [ -n "$PID" ] || { echo "$name: no process owns $FIFO"; return 1; }
  send activate
  sleep 1
  printf 'bundle=%s\npid=%s\nchannel=%s\n' "$bundle" "$PID" "$FIFO"
}

wait_for_sentinel() {
  local sentinel="$1" name="$2"
  for _ in $(seq 1 60); do
    dump "$name" || continue
    if /usr/bin/python3 - "$DUMP" "$sentinel" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
panes = [p for t in d["tabs"] if t.get("active") for p in t["panes"] if p.get("active")]
screen = panes[0].get("screen", []) if panes else []
text = "\n".join(screen) if isinstance(screen, list) else str(screen)
sys.exit(0 if sys.argv[2] in text else 1)
PY
    then return 0; fi
    sleep .2
  done
  return 1
}

fill_six_tabs() {
  local words=(ONE TWO THREE FOUR FIVE SIX)
  local index word sentinel
  for index in 0 1 2 3 4 5; do
    word="${words[$index]}"
    sentinel="MEMORY TAB $word READY"
    if [ "$index" -gt 0 ]; then send newtab; sleep .6; fi
    # Both halves are real terminal output: a repeating stream fills every
    # grid cell and ls -R exercises varied paths rather than one cached line.
    send "text yes 'MEMORY TAB $word FILL' | head -n 180; ls -R /usr/share/man | head -n 140; echo $sentinel"
    send "key return"
    if ! wait_for_sentinel "$sentinel" "fill-$index"; then
      echo "tab $index never showed [$sentinel]"
      return 1
    fi
  done
  return 0
}

print_drawable_state() {
  /usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = len(d.get("tabs", [])) == 6
for tab in d.get("tabs", []):
    pane = tab["panes"][0]
    r = pane.get("renderer", {})
    active = bool(tab.get("active"))
    width = r.get("drawableWidth", "missing")
    height = r.get("drawableHeight", "missing")
    suspended = r.get("drawablesSuspended", "missing")
    print("tab=%d active=%s drawable=%sx%s suspended=%s sentinel=%s"
          % (tab["index"], active, width, height, suspended,
             "READY" in "\n".join(pane.get("screen", []))))
    if active:
        ok &= suspended == 0 and isinstance(width, (int, float)) and width > 1 and height > 1
    else:
        ok &= suspended == 1 and width == 1 and height == 1
sys.exit(0 if ok else 1)
PY
}

total_bytes() {
  /usr/bin/python3 - "$1" <<'PY'
import re, sys
for line in open(sys.argv[1], errors="replace"):
    if not re.search(r"\bTOTAL\b", line):
        continue
    for token in line.replace(",", "").split():
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([KMGTPE]?)(?:i?B)?", token,
                             re.IGNORECASE)
        if not match:
            continue
        value = float(match.group(1))
        power = " KMGTPE".index(match.group(2).upper())
        print(int(value * (1024 ** power)))
        sys.exit(0)
sys.exit(1)
PY
}

footprint_reading() {
  local path="$1"
  if ! footprint -p "$PID" -f bytes > "$path" 2>&1; then
    echo "footprint failed for pid $PID"
    sed -n '1,30p' "$path"
    return 1
  fi
  echo "--- $(basename "$path"): TOTAL / IOSurface / IOAccelerator"
  /usr/bin/python3 - "$path" <<'PY'
import re, sys
for line in open(sys.argv[1], errors="replace"):
    if re.search(r"\b(?:TOTAL|IOSurface|IOAccelerator)\b", line):
        print(line.rstrip())
PY
  total_bytes "$path"
}

measure_three() {
  local prefix="$1" threshold="$2" direction="$3"
  local values=() path value index
  echo "10 seconds of quiet before the first reading"
  sleep 10
  for index in 1 2 3; do
    path="$RUN_ROOT/$prefix-$index.txt"
    value="$(footprint_reading "$path")" || return 1
    # footprint_reading prints evidence and leaves the byte count on its last
    # line; echo the evidence back before retaining that last line.
    printf '%s\n' "$value" | sed '$d'
    value="$(printf '%s\n' "$value" | tail -1)"
    case "$value" in ''|*[!0-9]*) echo "unreadable TOTAL in $path"; return 1 ;; esac
    values+=("$value")
    /usr/bin/python3 - "$index" "$value" <<'PY'
import sys
print("reading %s: %.1f MiB" % (sys.argv[1], int(sys.argv[2]) / 1024 / 1024))
PY
    [ "$index" -eq 3 ] || sleep 5
  done
  local result
  result="$(/usr/bin/python3 - "${values[@]}" "$threshold" "$direction" <<'PY'
import statistics, sys
values = list(map(int, sys.argv[1:4]))
threshold = int(sys.argv[4]) * 1024 * 1024
direction = sys.argv[5]
median = int(statistics.median(values))
passed = median <= threshold if direction == "max" else median >= threshold
print("%d %d %.1f" % (0 if passed else 1, median, median / 1024 / 1024))
PY
)"
  printf '%s\n' "$result"
}

run_current() {
  echo "=== P0 control: six real grids, display link, readable footprint ==="
  launch "$APP" current || { P0="FAIL launch"; STATUS=1; return 1; }
  fill_six_tabs || { P0="FAIL setup"; STATUS=1; return 1; }
  dump p0-state || { P0="FAIL dump"; STATUS=1; return 1; }
  local layout_status=0
  print_drawable_state || layout_status=$?

  send renderreset
  send "text echo MEMORY CONTROL FRAME"
  send "key return"
  sleep .7
  local control="$RUN_ROOT/control.json"
  stats "$control" || { P0="FAIL renderstats"; STATUS=1; return 1; }
  local frames vsyncs
  frames="$(field "$control" "int(d.get('frames', 0))")"
  vsyncs="$(field "$control" "int(d.get('vsyncs', 0))")"
  local first="$RUN_ROOT/control-footprint.txt" control_total control_status=0
  control_total="$(footprint_reading "$first")" || control_status=$?
  printf '%s\n' "$control_total" | sed '$d'
  local result=0
  [ "$layout_status" -eq 0 ] && [ "$frames" -ge 1 ] && [ "$vsyncs" -ge 1 ] \
    && [ "$control_status" -eq 0 ] || result=1
  verdict "P0 six tabs + echo + footprint" "$result" \
    "frames=$frames vsyncs=$vsyncs TOTAL=$(printf '%s\n' "$control_total" | tail -1) bytes"
  [ "$result" -eq 0 ] && P0="PASS" || P0="FAIL"

  echo
  echo "=== P1 memory: three readings, median <= 250 MiB ==="
  local measured measure_status=0 decision median mib
  measured="$(measure_three current 250 max)" || measure_status=$?
  printf '%s\n' "$measured" | sed '$d'
  decision="$(printf '%s\n' "$measured" | tail -1)"
  read -r result median mib <<< "$decision"
  [ "$measure_status" -eq 0 ] || result=1
  verdict "P1 median <= 250 MiB" "$result" "median=${mib:-unreadable} MiB (${median:-0} bytes)"
  [ "$result" -eq 0 ] && P1="PASS (${mib} MiB)" || P1="FAIL"

  echo
  echo "=== P2 first frame after returning to a tab ==="
  # Reset the target while it is in front, leave it, then return. The reset
  # makes resumeSamples belong to this switch alone.
  send "selecttab 1"; sleep .5
  send renderreset; sleep .1
  local winid reference reference_dump reference_probe reference_status=0
  winid="$(.build/t4a-winid "$PID" 2>/dev/null || true)"
  reference="$RUN_ROOT/p2-reference.png"
  reference_dump="$RUN_ROOT/p2-reference.json"
  reference_probe="$RUN_ROOT/p2-reference-probe.json"
  send "dump $reference_dump"
  for _ in $(seq 1 100); do [ -s "$reference_dump" ] && break; sleep .01; done
  if [ -z "$winid" ] || [ ! -s "$reference_dump" ] \
     || ! screencapture -x -o -l "$winid" "$reference" \
     || ! .build/t4a-imageprobe "$reference" > "$reference_probe"; then
    echo "P2 reference capture failed (window=$winid reference=$reference)"
    reference_status=1
  fi
  send "selecttab 5"; sleep .5
  local acknowledge="$RUN_ROOT/p2-ack.json"
  send "selecttab 1"
  send "dump $acknowledge"
  for _ in $(seq 1 100); do [ -s "$acknowledge" ] && break; sleep .01; done
  local shot probe capture_status=0
  shot="$RUN_ROOT/p2-first-frame.png"
  probe="$RUN_ROOT/p2-first-frame.json"
  if [ -z "$winid" ] || ! screencapture -x -o -l "$winid" "$shot" \
     || ! .build/t4a-imageprobe "$shot" > "$probe"; then
    echo "P2 first-frame capture failed (window=$winid shot=$shot)"
    capture_status=1
  fi
  local diff="$RUN_ROOT/p2-image-diff.txt" diff_status=0 exact=0 far=100
  if [ "$reference_status" -eq 0 ] && [ "$capture_status" -eq 0 ]; then
    .build/t4a-imagediff "$reference" "$shot" --tolerance 4 \
      --out "$RUN_ROOT/p2-diff.png" > "$diff" 2>&1 || diff_status=$?
    sed 's/^/    /' "$diff"
    exact="$(awk '/^exact/ { gsub("%", "", $3); print $3; exit }' "$diff")"
    far="$(awk '/^far/ { gsub("%", "", $3); print $3; exit }' "$diff")"
  else
    diff_status=1
  fi
  sleep .2
  local resume="$RUN_ROOT/p2-resume.json"
  stats "$resume" || capture_status=1
  local p2_result=0 resume_samples=0 resume_ms=0 mean=0 deviation=0 text="" ocr_error=""
  if [ "$reference_status" -eq 0 ] && [ "$capture_status" -eq 0 ]; then
    resume_samples="$(field "$resume" "int(d.get('resumeSamples', 0))")"
    resume_ms="$(field "$resume" "float(d.get('resumeLastMs', 0))")"
    mean="$(field "$probe" "round(d['meanLuminance'], 4)")"
    deviation="$(field "$probe" "round(d['luminanceStddev'], 4)")"
    text="$(field "$probe" "d['text']")"
    ocr_error="$(field "$probe" "d.get('ocrError', '')")"
    /usr/bin/python3 - "$probe" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
lines=[x for x in d["text"].splitlines() if "MEMORY" in x.upper()]
print("OCR MEMORY lines: %s" % (" | ".join(lines[-8:]) if lines else "<none>"))
print("OCR error: %s" % (d.get("ocrError") or "none"))
print("image: %sx%s meanLuminance=%.4f stddev=%.4f"
      % (d["width"], d["height"], d["meanLuminance"], d["luminanceStddev"]))
PY
    /usr/bin/python3 - "$reference_dump" "$text" "$ocr_error" "$resume_samples" \
      "$resume_ms" "$deviation" "${far:-100}" <<'PY' || p2_result=$?
import json, sys
d=json.load(open(sys.argv[1]))
text=sys.argv[2].upper(); ocr_error=sys.argv[3]
samples=int(sys.argv[4]); latency=float(sys.argv[5]); deviation=float(sys.argv[6])
far=float(sys.argv[7])
panes=[p for t in d["tabs"] if t.get("active") for p in t["panes"] if p.get("active")]
screen="\n".join(panes[0].get("screen", [])) if panes else ""
sentinel="MEMORY TAB TWO READY" in screen.upper()
wrong="MEMORY TAB SIX READY" in text
ocr_agrees=bool(ocr_error) or not text.strip() or "MEMORY TAB TWO READY" in text
sys.exit(0 if sentinel and ocr_agrees and not wrong and far <= .01 and samples >= 1
         and latency < 100 and deviation > .005 else 1)
PY
  else
    p2_result=1
  fi
  verdict "P2 right, nonblack frame < 100 ms" "$p2_result" \
    "resumeSamples=$resume_samples resumeLastMs=$resume_ms exact=${exact:-0}% far=${far:-100}% luminance=${mean:-?}±${deviation:-?} shot=$shot"
  [ "$p2_result" -eq 0 ] && P2="PASS (${resume_ms} ms)" || P2="FAIL"
  t4a_stop_bench
  return 0
}

run_head() {
  [ -n "$HEAD" ] || { echo "=== P3 negative: NOT RUN — no --head bundle supplied ==="; return 0; }
  echo "=== P3 negative on HEAD: median >= 500 MiB ==="
  launch "$HEAD" head || { P3="FAIL launch"; STATUS=1; return 1; }
  fill_six_tabs || { P3="FAIL setup"; STATUS=1; return 1; }
  local measured measure_status=0 decision result median mib
  measured="$(measure_three head 500 min)" || measure_status=$?
  printf '%s\n' "$measured" | sed '$d'
  decision="$(printf '%s\n' "$measured" | tail -1)"
  read -r result median mib <<< "$decision"
  [ "$measure_status" -eq 0 ] || result=1
  verdict "P3 HEAD median >= 500 MiB" "$result" "median=${mib:-unreadable} MiB (${median:-0} bytes)"
  [ "$result" -eq 0 ] && P3="PASS negative (${mib} MiB)" || P3="FAIL negative"
  t4a_stop_bench
}

build_helpers() {
  mkdir -p .build
  if [ ! -x .build/t4a-winid ] || [ Scripts/winid.swift -nt .build/t4a-winid ]; then
    swiftc -O Scripts/winid.swift -o .build/t4a-winid
  fi
  if [ ! -x .build/t4a-imageprobe ] || [ Scripts/imageprobe.swift -nt .build/t4a-imageprobe ]; then
    swiftc -O Scripts/imageprobe.swift -o .build/t4a-imageprobe
  fi
  if [ ! -x .build/t4a-imagediff ] || [ Scripts/imagediff.swift -nt .build/t4a-imagediff ]; then
    swiftc -O Scripts/imagediff.swift -o .build/t4a-imagediff
  fi
}

build_helpers || { echo "helper build failed"; STATUS=1; exit 1; }
run_current || true
echo
run_head || true

# The child benches acquire this same machine-wide lock. Hand it over only
# after both measured app instances are gone, or they would wait on us.
t4a_stop_bench
t4a_bench_unlock
LOCK_RELEASED=1

echo
echo "=== P4 regressions on the new bundle ==="
render_status=0
wheel_status=0
T4A_APP="$APP" Scripts/bench-render.sh || render_status=$?
Scripts/bench-wheel-redraw.sh "$APP" || wheel_status=$?
if [ "$render_status" -eq 0 ] && [ "$wheel_status" -eq 0 ]; then
  verdict "P4 render + wheel" 0 "both benches passed"
  P4="PASS"
else
  verdict "P4 render + wheel" 1 "bench-render=$render_status bench-wheel-redraw=$wheel_status"
  P4="FAIL (render=$render_status wheel=$wheel_status)"
fi

echo
echo "=== SUMMARY =========================================================="
printf 'P0  %s\nP1  %s\nP2  %s\nP3  %s\nP4  %s\n' "$P0" "$P1" "$P2" "$P3" "$P4"
echo "evidence: $WORK"
exit "$STATUS"
