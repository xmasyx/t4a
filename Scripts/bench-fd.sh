#!/bin/bash
# ISC-219 — pane shells and their children inherit no T4A descriptors.
#
#   Scripts/bench-fd.sh [--head <old-app-bundle>] [app-bundle]
#
# forkpty closes a child's own pty master, so the first pane cannot expose the
# leak. The second pane is the witness: before the repair it inherited the
# first pane's /dev/ptmx master, the test FIFO, and the t4a door. In lsof, cwd,
# txt and rtd belong to the process itself, as do CHR descriptors on its ttys;
# every other numeric FD >= 3 is reported, while ptmx/fifo/door/KQUEUE rows are
# the pole subset that can only have arrived from T4A.

set -uo pipefail
cd "$(dirname "$0")/.."

APP="dist/T4A.app"
HEAD=""
APP_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --head)
      [ $# -ge 2 ] || { echo "--head needs an app bundle" >&2; exit 2; }
      HEAD="$2"
      shift 2
      ;;
    --*)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
    *)
      [ "$APP_SET" -eq 0 ] || { echo "only one app bundle is accepted" >&2; exit 2; }
      APP="$1"
      APP_SET=1
      shift
      ;;
  esac
done

REAL_T4A_CONFIG="$HOME/.config/t4a/config.toml"
REAL_CLAUDE_CONFIG="$HOME/.claude.json"
hash_of() {
  [ -e "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "(absent)"
}
BEFORE_T4A="$(hash_of "$REAL_T4A_CONFIG")"
BEFORE_CLAUDE="$(hash_of "$REAL_CLAUDE_CONFIG")"

early_not_run() {
  local reason="$1"
  printf '%-56s NOT RUN  %s\n' "219a second shell has no T4A descriptors" "$reason"
  printf '%-56s NOT RUN  %s\n' "219b grandchild has no T4A descriptors" "$reason"
  printf '%-56s NOT RUN  %s\n' "219c the shell still works" "$reason"
  printf '%-56s NOT RUN  %s\n' "219d the close-on-exec sweep ran" "$reason"
  if [ -n "$HEAD" ]; then
    printf '%-56s NOT RUN  %s\n' "H-219a HEAD leaks T4A descriptors" "$reason"
  fi
}

echo '==> preflight: pgrep -fl "T4A.app/Contents/MacOS/T4A"'
PREFLIGHT="$(pgrep -fl "T4A.app/Contents/MacOS/T4A" 2>&1)"
PREFLIGHT_STATUS=$?
if [ -n "$PREFLIGHT" ]; then printf '%s\n' "$PREFLIGHT"; else echo '(no matches)'; fi
if [ "$PREFLIGHT_STATUS" -gt 1 ]; then
  REASON="pgrep failed with status $PREFLIGHT_STATUS; safe cleanup is unavailable"
  early_not_run "$REASON"
  AFTER_T4A="$(hash_of "$REAL_T4A_CONFIG")"
  AFTER_CLAUDE="$(hash_of "$REAL_CLAUDE_CONFIG")"
  [ "$AFTER_T4A" = "$BEFORE_T4A" ] && CHECK=PASS || CHECK=FAIL
  printf '%-56s %s  before=%s after=%s\n' "real t4a config sha256 (byte-identical)" \
    "$CHECK" "$BEFORE_T4A" "$AFTER_T4A"
  [ "$AFTER_CLAUDE" = "$BEFORE_CLAUDE" ] && CHECK=PASS || CHECK=FAIL
  printf '%-56s %s  before=%s after=%s\n' "real claude config sha256 (byte-identical)" \
    "$CHECK" "$BEFORE_CLAUDE" "$AFTER_CLAUDE"
  exit 1
fi

# The lock and pid discriminator must be installed only after preflight speaks.
source "$(dirname "$0")/lib/bench-stop.sh"

WORK="$(mktemp -d -t t4a-fd)" || exit 1
FIFO="$WORK/channel.fifo"
CFG="$WORK/config"
CLAUDE_HOME="$WORK/claude-home"
DUMP="$WORK/dump.json"
STATUS=0
CLEANED=0
RUN_ERROR=""
P1=""
P2=""

pole() {
  local name="$1" result="$2" detail="$3"
  if [ "$result" -eq 0 ]; then
    printf '%-56s PASS  %s\n' "$name" "$detail"
  else
    printf '%-56s FAIL  %s\n' "$name" "$detail"
    STATUS=1
  fi
}

not_run() {
  printf '%-56s NOT RUN  %s\n' "$1" "$2"
  STATUS=1
}

expected_red() {
  local name="$1" defect_present="$2" detail="$3"
  if [ "$defect_present" -eq 0 ]; then
    printf '%-56s PASS (expected on HEAD)  %s\n' "$name" "$detail"
  else
    printf '%-56s FAIL (unexpected on HEAD)  %s\n' "$name" "$detail"
    STATUS=1
  fi
}

print_checksums() {
  local after_t4a after_claude result
  after_t4a="$(hash_of "$REAL_T4A_CONFIG")"
  after_claude="$(hash_of "$REAL_CLAUDE_CONFIG")"
  result=PASS
  if [ "$after_t4a" != "$BEFORE_T4A" ]; then result=FAIL; STATUS=1; fi
  printf '%-56s %s  before=%s after=%s\n' "real t4a config sha256 (byte-identical)" \
    "$result" "$BEFORE_T4A" "$after_t4a"
  result=PASS
  if [ "$after_claude" != "$BEFORE_CLAUDE" ]; then result=FAIL; STATUS=1; fi
  printf '%-56s %s  before=%s after=%s\n' "real claude config sha256 (byte-identical)" \
    "$result" "$BEFORE_CLAUDE" "$after_claude"
}

cleanup() {
  local pid found=0
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  t4a_stop_bench
  # At most 5 s: stop waiting as soon as no process carries this bench's FIFO.
  for _ in $(seq 1 20); do
    [ -z "$(t4a_bench_pids)" ] && break
    sleep 0.25
  done
  case "$(basename "$WORK")" in t4a-fd.*) rm -rf "$WORK";; esac
  echo '==> teardown: T4A still running, test-channel count per pid (0 = his)'
  for pid in $(pgrep -f "T4A.app/Contents/MacOS/T4A" 2>/dev/null); do
    found=1
    printf '%s %s\n' "$pid" "$(ps eww "$pid" | tr ' ' '\n' | grep -c T4A_TEST_CHANNEL)"
  done
  [ "$found" -eq 1 ] || echo '(none)'
  print_checksums
}
trap cleanup EXIT

finish() {
  cleanup
  trap - EXIT
  exit "$STATUS"
}

send() {
  /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"
}

checked_send() {
  local command="$1" description="$2"
  if ! send "$command"; then
    RUN_ERROR="could not $description through the test channel"
    echo "$RUN_ERROR" >&2
    return 1
  fi
  return 0
}

dump() {
  rm -f "$DUMP"
  checked_send "dump $DUMP" "request a dump" || return 1
  # At most 5 s: the requested JSON file is the response condition.
  for _ in $(seq 1 50); do
    [ -s "$DUMP" ] && break
    sleep 0.1
  done
  if [ ! -s "$DUMP" ]; then
    RUN_ERROR="the app did not answer the dump within 5 seconds"
    echo "$RUN_ERROR" >&2
    return 1
  fi
  if ! /usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    root = json.load(stream)
if not isinstance(root, dict) or not isinstance(root.get("tabs"), list):
    raise SystemExit("dump has no tabs array")
PY
  then
    RUN_ERROR="the app wrote an invalid dump"
    return 1
  fi
}

json_value() {
  /usr/bin/python3 - "$DUMP" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
scope, tab_text, pane_text, key = sys.argv[2:]
value = ""
try:
    tab = d["tabs"][int(tab_text)]
    pane = tab["panes"][int(pane_text)]
    if scope == "tab":
        value = tab.get(key, "")
    elif scope == "pane" and key == "blocksCount":
        value = len(pane.get("blocks", []))
    elif scope == "pane":
        value = pane.get(key, "")
    elif scope == "diagnostics":
        value = pane.get("diagnostics", {}).get(key, "")
    elif scope == "panes":
        value = len(tab.get("panes", []))
except (IndexError, KeyError, TypeError, ValueError):
    value = ""
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

read_value() {
  local destination="$1" value
  shift
  if ! value="$(json_value "$@")"; then
    RUN_ERROR="could not read $* from the dump"
    echo "$RUN_ERROR" >&2
    return 1
  fi
  printf -v "$destination" '%s' "$value"
}

screen_contains() {
  /usr/bin/python3 - "$DUMP" "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
try:
    rows = d["tabs"][int(sys.argv[2])]["panes"][int(sys.argv[3])].get("screen", [])
except (IndexError, KeyError, TypeError, ValueError):
    rows = []
print("true" if any(sys.argv[4] in row for row in rows) else "false")
PY
}

write_config() {
  rm -rf "$CFG" "$CLAUDE_HOME"
  mkdir -p "$CFG/t4a" "$CLAUDE_HOME" || return 1
  chmod 700 "$CLAUDE_HOME" || return 1
  printf '# isolated config written by bench-fd.sh\n' > "$CFG/t4a/config.toml"
}

wait_first_prompt() {
  local blocks
  # At most 20 s of 0.25 s polls: pane one must expose a prompt block.
  for _ in $(seq 1 80); do
    dump || return 1
    read_value blocks pane 0 0 blocksCount || return 1
    case "$blocks" in ''|*[!0-9]*) ;; *) [ "$blocks" -gt 0 ] && return 0;; esac
    sleep 0.25
  done
  RUN_ERROR="the first pane did not reach a prompt within 20 seconds"
  return 1
}

launch() {
  local bundle="$1"
  RUN_ERROR=""
  t4a_stop_bench
  # At most 5 s: the old instance must release our private channel identity.
  for _ in $(seq 1 20); do
    [ -z "$(t4a_bench_pids)" ] && break
    sleep 0.25
  done
  if [ -n "$(t4a_bench_pids)" ]; then
    RUN_ERROR="the preceding instance did not stop within 5 seconds"
    return 1
  fi
  rm -f "$FIFO" "$DUMP"
  if ! write_config; then RUN_ERROR="could not write the isolated config"; return 1; fi
  if ! open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" \
       --env XDG_CONFIG_HOME="$CFG" --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME"; then
    RUN_ERROR="could not open $bundle"
    return 1
  fi
  # At most 10 s: commands begin only after the app creates the private FIFO.
  for _ in $(seq 1 40); do
    [ -p "$FIFO" ] && break
    sleep 0.25
  done
  if [ ! -p "$FIFO" ]; then
    RUN_ERROR="the test channel did not appear within 10 seconds"
    return 1
  fi
  wait_first_prompt
}

wait_second_prompt() {
  local panes blocks active
  # At most 20 s: splitv must create active pane 2 and its prompt block.
  for _ in $(seq 1 80); do
    dump || return 1
    read_value panes panes 0 0 count || return 1
    read_value blocks pane 0 1 blocksCount || return 1
    read_value active pane 0 1 active || return 1
    if [ "$panes" = "2" ] && [ "$active" = "true" ]; then
      case "$blocks" in ''|*[!0-9]*) ;; *) [ "$blocks" -gt 0 ] && return 0;; esac
    fi
    sleep 0.25
  done
  RUN_ERROR="the second pane did not become active at a prompt within 20 seconds"
  return 1
}

prepare_two_panes() {
  local bundle="$1"
  P1=""; P2=""
  launch "$bundle" || return 1
  dump || return 1
  read_value P1 pane 0 0 pid || return 1
  case "$P1" in ''|*[!0-9]*) RUN_ERROR="first pane pid is not numeric: $P1"; return 1;; esac
  checked_send "splitv" "split the first pane vertically" || return 1
  wait_second_prompt || return 1
  dump || return 1
  read_value P2 pane 0 1 pid || return 1
  case "$P2" in ''|*[!0-9]*) RUN_ERROR="second pane pid is not numeric: $P2"; return 1;; esac
  if [ "$P2" = "$P1" ]; then RUN_ERROR="the two pane pids are identical: $P1"; return 1; fi
}

# lsof's own rows (cwd/txt/rtd) never pass the numeric-FD predicate. Extra tty
# descriptors are opened by the shell itself and are excluded explicitly.
inherited_rows() {
  local pid="$1"
  "$LSOF_BIN" -p "$pid" 2>/dev/null | awk '
    NR > 1 && $4 ~ /^[0-9]+[rwu]?$/ && ($4 + 0) >= 3 \
      && !($5 == "CHR" && $NF ~ /^\/dev\/ttys/) { print $4, $5, $NF }
  '
}

pole_rows() {
  inherited_rows "$1" | awk '
    $2 == "KQUEUE" || $3 ~ /\/dev\/ptmx|\.fifo$|\/t4a\/door|KQUEUE/ { print }
  '
}

row_count() {
  awk 'NF { count++ } END { print count + 0 }' <<EOF
$1
EOF
}

print_rows() {
  local label="$1" rows="$2" row
  echo "      $label"
  if [ -n "$rows" ]; then
    while IFS= read -r row; do printf '        %s\n' "$row"; done <<EOF
$rows
EOF
  else
    echo "        (none)"
  fi
}

wait_background_sleep() {
  local parent="$1" candidate
  SLEEP_PID=""
  # At most 3 s, polled every 0.1 s: pgrep is the child-process condition.
  for _ in $(seq 1 30); do
    if candidate="$(pgrep -P "$parent" -x sleep 2>/dev/null | awk 'NR == 1 { print; exit }')" \
       && [ -n "$candidate" ]; then
      SLEEP_PID="$candidate"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

measure_descriptor_poles() {
  local p2_rows p2_poles p1_rows p1_count p2_count p2_pole_count result
  if p2_rows="$(inherited_rows "$P2")" && p2_poles="$(pole_rows "$P2")" \
     && p2_count="$(row_count "$p2_rows")" && p2_pole_count="$(row_count "$p2_poles")"; then
    result=1
    [ -z "$p2_poles" ] && result=0
    pole "219a second shell has no T4A descriptors" "$result" \
      "inherited=$p2_count pole-rows=$p2_pole_count pid=$P2"
    print_rows "second pane inherited rows (FD TYPE NAME):" "$p2_rows"
  else
    not_run "219a second shell has no T4A descriptors" "lsof failed for pid $P2"
  fi

  if p1_rows="$(inherited_rows "$P1")" && p1_count="$(row_count "$p1_rows")"; then
    printf '%-56s INFO  inherited=%s pid=%s\n' "219a-first first shell descriptor inventory" "$p1_count" "$P1"
    print_rows "first pane inherited rows (FD TYPE NAME):" "$p1_rows"
  else
    printf '%-56s INFO  %s\n' "219a-first first shell descriptor inventory" "lsof failed for pid $P1"
    STATUS=1
  fi
}

measure_grandchild() {
  local rows poles count pole_count result
  if ! checked_send "text sleep 30 &\\n" "start the background sleep in pane 2"; then
    not_run "219b grandchild has no T4A descriptors" "$RUN_ERROR"
    return
  fi
  if ! wait_background_sleep "$P2"; then
    not_run "219b grandchild has no T4A descriptors" "no sleep child of $P2 appeared within 3 seconds"
    return
  fi
  if rows="$(inherited_rows "$SLEEP_PID")" && poles="$(pole_rows "$SLEEP_PID")" \
     && count="$(row_count "$rows")" && pole_count="$(row_count "$poles")"; then
    result=1
    [ -z "$poles" ] && result=0
    pole "219b grandchild has no T4A descriptors" "$result" \
      "inherited=$count pole-rows=$pole_count pid=$SLEEP_PID parent=$P2"
    print_rows "sleep grandchild inherited rows (FD TYPE NAME):" "$rows"
  else
    not_run "219b grandchild has no T4A descriptors" "lsof failed for sleep pid $SLEEP_PID"
  fi
}

measure_shell_works() {
  local marker_seen=false cwd_seen=false prompt_seen=false foreground_seen=false
  local contains cwd process marker_result cwd_result process_result result
  if ! checked_send "text echo fd-ok-marker\\n" "run the marker command in pane 2"; then
    not_run "219c the shell still works" "$RUN_ERROR"
    return
  fi
  # At most 3 s, polled every 0.1 s: a screen row must contain the marker.
  for _ in $(seq 1 30); do
    dump || { not_run "219c the shell still works" "$RUN_ERROR"; return; }
    if ! contains="$(screen_contains 0 1 fd-ok-marker)"; then
      not_run "219c the shell still works" "could not read pane 2 screen rows"
      return
    fi
    if [ "$contains" = "true" ]; then marker_seen=true; break; fi
    sleep 0.1
  done

  if ! checked_send "text cd /tmp\\n" "change pane 2 to /tmp"; then
    not_run "219c the shell still works" "$RUN_ERROR"
    return
  fi
  # At most 3 s, polled every 0.1 s: cwd must resolve to /tmp or /private/tmp.
  for _ in $(seq 1 30); do
    dump || { not_run "219c the shell still works" "$RUN_ERROR"; return; }
    read_value cwd pane 0 1 cwd || { not_run "219c the shell still works" "$RUN_ERROR"; return; }
    case "$cwd" in */tmp) cwd_seen=true; break;; esac
    sleep 0.1
  done

  # At most 3 s: at the prompt the foreground process must be a known shell.
  for _ in $(seq 1 30); do
    dump || { not_run "219c the shell still works" "$RUN_ERROR"; return; }
    read_value process pane 0 1 process || { not_run "219c the shell still works" "$RUN_ERROR"; return; }
    case "$process" in zsh|bash|fish) prompt_seen=true; break;; esac
    sleep 0.1
  done
  PROMPT_PROCESS="$process"

  if ! checked_send "text sleep 3\\n" "run the foreground sleep in pane 2"; then
    not_run "219c the shell still works" "$RUN_ERROR"
    return
  fi
  FOREGROUND_PROCESS=""
  # At most 3 s, polled every 0.3 s: the pane must expose sleep as foreground.
  for _ in $(seq 1 10); do
    dump || { not_run "219c the shell still works" "$RUN_ERROR"; return; }
    read_value FOREGROUND_PROCESS pane 0 1 process \
      || { not_run "219c the shell still works" "$RUN_ERROR"; return; }
    if [ "$FOREGROUND_PROCESS" = "sleep" ]; then foreground_seen=true; break; fi
    sleep 0.3
  done

  marker_result=FAIL; [ "$marker_seen" = true ] && marker_result=PASS
  cwd_result=FAIL; [ "$cwd_seen" = true ] && cwd_result=PASS
  process_result=FAIL
  [ "$prompt_seen" = true ] && [ "$foreground_seen" = true ] && process_result=PASS
  result=1
  [ "$marker_seen" = true ] && [ "$cwd_seen" = true ] \
    && [ "$prompt_seen" = true ] && [ "$foreground_seen" = true ] && result=0
  pole "219c the shell still works" "$result" \
    "marker=$marker_result cwd=$cwd_result process-transition=$process_result"
  printf '      marker row contains fd-ok-marker: %s\n' "$marker_result"
  printf '      cwd after cd /tmp: %s  cwd=%s\n' "$cwd_result" "${cwd:-missing}"
  printf '      process shell -> sleep: %s  prompt=%s foreground=%s\n' \
    "$process_result" "${PROMPT_PROCESS:-missing}" "${FOREGROUND_PROCESS:-missing}"
}

measure_sweep() {
  local marked1 marked2 result=1
  dump || { not_run "219d the close-on-exec sweep ran" "$RUN_ERROR"; return; }
  read_value marked1 diagnostics 0 0 cloexecMarked \
    || { not_run "219d the close-on-exec sweep ran" "$RUN_ERROR"; return; }
  read_value marked2 diagnostics 0 1 cloexecMarked \
    || { not_run "219d the close-on-exec sweep ran" "$RUN_ERROR"; return; }
  # The sweep marks what is NOT yet close-on-exec. The first spawn finds our
  # descriptors and marks them; the second finds nothing left to mark, and a
  # zero there is the proof that the marks stuck (the operator's rerun, 29/08 01:40:
  # pane2=0 with 219a/219b green). So the pole reads pane 1, and pane 2 is
  # reported, not judged.
  case "$marked1" in ''|*[!0-9]*) ;; *) [ "$marked1" -ge 1 ] && result=0;; esac
  pole "219d the close-on-exec sweep ran" "$result" \
    "pane1.cloexecMarked=${marked1:-missing} pane2.cloexecMarked=${marked2:-missing}"
}

run_new_build() {
  echo "=== ISC-219 · descriptors across pane spawns ==============="
  if ! prepare_two_panes "$APP"; then
    not_run "219a second shell has no T4A descriptors" "${RUN_ERROR:-two-pane setup failed}"
    not_run "219b grandchild has no T4A descriptors" "${RUN_ERROR:-two-pane setup failed}"
    not_run "219c the shell still works" "${RUN_ERROR:-two-pane setup failed}"
    not_run "219d the close-on-exec sweep ran" "${RUN_ERROR:-two-pane setup failed}"
    return
  fi
  measure_descriptor_poles
  measure_grandchild
  measure_shell_works
  measure_sweep
}

run_head() {
  local rows poles count pole_count defect sleep_rows sleep_count
  echo "=== HEAD · the descriptor leak must still be visible ======="
  if ! prepare_two_panes "$HEAD"; then
    not_run "H-219a HEAD leaks T4A descriptors" "${RUN_ERROR:-two-pane setup failed}"
    return
  fi
  if rows="$(inherited_rows "$P2")" && poles="$(pole_rows "$P2")" \
     && count="$(row_count "$rows")" && pole_count="$(row_count "$poles")"; then
    defect=1
    [ -n "$poles" ] && defect=0
    expected_red "H-219a HEAD leaks T4A descriptors" "$defect" \
      "inherited=$count pole-rows=$pole_count pid=$P2"
    print_rows "HEAD second pane inherited rows (FD TYPE NAME):" "$rows"
    print_rows "HEAD leak subset (ptmx/fifo/door/KQUEUE):" "$poles"
  else
    not_run "H-219a HEAD leaks T4A descriptors" "lsof failed for HEAD pane pid $P2"
  fi

  if ! checked_send "text sleep 30 &\\n" "start HEAD's background sleep"; then
    printf '%-56s INFO  %s\n' "H-219a HEAD sleep grandchild inventory" "$RUN_ERROR"
    STATUS=1
    return
  fi
  if ! wait_background_sleep "$P2"; then
    printf '%-56s INFO  no sleep child of %s within 3 seconds\n' \
      "H-219a HEAD sleep grandchild inventory" "$P2"
    STATUS=1
    return
  fi
  if sleep_rows="$(inherited_rows "$SLEEP_PID")" \
     && sleep_count="$(row_count "$sleep_rows")"; then
    printf '%-56s INFO  inherited=%s pid=%s parent=%s\n' \
      "H-219a HEAD sleep grandchild inventory" "$sleep_count" "$SLEEP_PID" "$P2"
    print_rows "HEAD sleep grandchild inherited rows (FD TYPE NAME):" "$sleep_rows"
  else
    printf '%-56s INFO  lsof failed for sleep pid %s\n' \
      "H-219a HEAD sleep grandchild inventory" "$SLEEP_PID"
    STATUS=1
  fi
}

t4a_note_his_app
if ! LSOF_BIN="$(command -v lsof)" || [ -z "$LSOF_BIN" ]; then
  early_not_run "lsof is not on PATH"
  STATUS=1
  finish
fi

if [ -x "$APP/Contents/MacOS/T4A" ]; then
  run_new_build
else
  not_run "219a second shell has no T4A descriptors" "no bundle at $APP"
  not_run "219b grandchild has no T4A descriptors" "no bundle at $APP"
  not_run "219c the shell still works" "no bundle at $APP"
  not_run "219d the close-on-exec sweep ran" "no bundle at $APP"
fi

if [ -n "$HEAD" ]; then
  # prepare_two_panes() calls launch(), which first stops only our new-build app.
  if [ -x "$HEAD/Contents/MacOS/T4A" ]; then
    run_head
  else
    not_run "H-219a HEAD leaks T4A descriptors" "no HEAD bundle at $HEAD"
  fi
fi

finish
