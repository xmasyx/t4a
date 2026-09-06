#!/bin/bash
# ISC-209/210 — the facts provider and an idle pane adopt the real agent pid.
#
#   Scripts/bench-barra-pid.sh [app-bundle] [--head <old-app-bundle>]
#
# The provider is written by this bench and echoes its arguments as one `args`
# reading. HEAD is a falsifier: both claims must remain red on the old bundle.

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

echo '==> preflight: pgrep -fl "T4A.app/Contents/MacOS/T4A"'
PREFLIGHT="$(pgrep -fl "T4A.app/Contents/MacOS/T4A" 2>&1)"
PREFLIGHT_STATUS=$?
if [ -n "$PREFLIGHT" ]; then printf '%s\n' "$PREFLIGHT"; else echo '(no matches)'; fi
if [ "$PREFLIGHT_STATUS" -gt 1 ]; then
  REASON="pgrep failed with status $PREFLIGHT_STATUS; safe cleanup is unavailable"
  printf '%-56s NOT RUN  %s\n' "209a provider receives the claude child pid" "$REASON"
  printf '%-56s NOT RUN  %s\n' "209b bare shell has no --pid" "$REASON"
  printf '%-56s NOT RUN  %s\n' "209c session and pid coexist after a message" "$REASON"
  printf '%-56s NOT RUN  %s\n' "210a observer adopts without another key" "$REASON"
  printf '%-56s NOT RUN  %s\n' "HEAD 209a provider still has no --pid" "$REASON"
  printf '%-56s NOT RUN  %s\n' "HEAD 210a idle observer still has no pid" "$REASON"
  exit 1
fi

source "$(dirname "$0")/lib/bench-stop.sh"

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
if [ -n "$HEAD" ] && [ ! -x "$HEAD/Contents/MacOS/T4A" ]; then
  echo "no HEAD bundle at $HEAD" >&2
  exit 1
fi

WORK="$(mktemp -d -t t4a-barra-pid)" || exit 1
FIFO="$WORK/channel.fifo"
CFG="$WORK/config"
DUMP="$WORK/dump.json"
PROVIDER="$WORK/good.sh"
# claude's own configuration for the run: the real one with `projects` emptied
# (Scripts/claude-config-copy.py), so the trust answer for the pane's folder
# lands here and his ~/.claude.json keeps its checksum (ISC-132).
CLAUDE_HOME="$WORK/claude-home"
STATUS=0

cleanup() {
  t4a_stop_bench
  case "$(basename "$WORK")" in t4a-barra-pid.*) rm -rf "$WORK";; esac
  # His app carries no test channel in its environment: a `0` here is the proof
  # the bench left it alive (2026-08-27, one closed under his hands).
  echo '==> teardown: T4A still running, test-channel count per pid (0 = his)'
  local pid found=0
  for pid in $(pgrep -f "T4A.app/Contents/MacOS/T4A" 2>/dev/null); do
    found=1
    printf '%s %s\n' "$pid" "$(ps eww "$pid" | tr ' ' '\n' | grep -c T4A_TEST_CHANNEL)"
  done
  [ "$found" -eq 1 ] || echo '(none)'
}
trap cleanup EXIT

cat > "$PROVIDER" <<'PROVIDER'
#!/bin/bash
printf '#name\targs\tArguments\n'
printf 'args\t%s\tmuted\n' "$*"
printf '#name\tsession\tSession title\n'
printf 'session\tpid bench\taccent\n'
PROVIDER
chmod +x "$PROVIDER"
[ -x "$PROVIDER" ] || { echo "could not create the echo provider" >&2; exit 1; }

# The falsifier for ISC-210 has to be an agent that never writes a byte: a
# real claude redraws its TUI for seconds after the banner, and HEAD adopts
# the pid on those bytes (measured 2026-08-28, HEAD 210a came out green with
# claude 2.1.248). And it has to appear AFTER the pane announced it, the way
# the bun launcher exposes the versioned binary late: a `claude` that exists
# at the first scan is attached WITH its pid and no timer is ever needed.
# So: a shell function named claude, a launcher that sleeps, then a silent
# Mach-O whose name and argv[0] are `claude` — the two witnesses the registry
# reads.
FAKE="$WORK/fake"
mkdir -p "$FAKE"
cat > "$FAKE/claude.c" <<'FAKE_C'
#include <unistd.h>
int main(void) { for (;;) pause(); return 0; }
FAKE_C
cat > "$FAKE/launcher" <<LAUNCHER
#!/bin/bash
sleep 3
exec "$FAKE/claude"
LAUNCHER
chmod +x "$FAKE/launcher"
SILENT_AGENT=1
if ! /usr/bin/clang -o "$FAKE/claude" "$FAKE/claude.c" 2>"$FAKE/clang.err"; then
  echo "could not compile the silent agent: $(head -1 "$FAKE/clang.err")" >&2
  SILENT_AGENT=0
fi

send() {
  /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"
}

dump() {
  rm -f "$DUMP"
  send "dump $DUMP" || return 1
  for _ in $(seq 1 50); do
    [ -s "$DUMP" ] && break
    sleep 0.1
  done
  [ -s "$DUMP" ] || { echo "the app did not answer the dump within 5 seconds" >&2; return 1; }
  /usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    root = json.load(stream)
if not isinstance(root, dict) or not isinstance(root.get("tabs"), list):
    raise SystemExit("dump has no tabs array")
if not isinstance(root.get("dash"), dict):
    raise SystemExit("dump has no dash object")
PY
}

field() {
  /usr/bin/python3 - "$DUMP" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    d = json.load(stream)
print(eval(sys.argv[2], {"d": d}))
PY
}

write_config() {
  rm -rf "$CFG"
  mkdir -p "$CFG/t4a"
  {
    printf '# written by bench-barra-pid.sh\n\n'
    printf 'facts-provider = "%s"\n' "$PROVIDER"
    printf 'facts-interval = 0.5\n'
    printf 'dash-off = "fact-session"\n'
  } > "$CFG/t4a/config.toml"
}

seed_claude_config() {
  rm -rf "$CLAUDE_HOME"; mkdir -p "$CLAUDE_HOME"; chmod 700 "$CLAUDE_HOME"
  /usr/bin/python3 Scripts/claude-config-copy.py "$HOME/.claude.json" "$CLAUDE_HOME/.claude.json" \
    || { echo "could not seed the isolated claude config" >&2; return 1; }
}

launch() {
  local bundle="$1"
  t4a_stop_bench
  sleep 1
  rm -f "$FIFO" "$DUMP"
  write_config || { echo "could not write the temporary config" >&2; return 1; }
  seed_claude_config || return 1
  if ! open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG" \
       --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME"; then
    echo "could not open $bundle" >&2
    return 1
  fi
  for _ in $(seq 1 40); do
    [ -p "$FIFO" ] && break
    sleep 0.25
  done
  [ -p "$FIFO" ] || { echo "the test channel did not appear within 10 seconds" >&2; return 1; }
  sleep 1
}

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
  local name="$1" feature_absent="$2" detail="$3"
  if [ "$feature_absent" -eq 0 ]; then
    printf '%-56s FAIL (expected on HEAD)  %s\n' "$name" "$detail"
  else
    printf '%-56s PASS (unexpected on HEAD)  %s\n' "$name" "$detail"
    STATUS=1
  fi
}

active_pane_expression="[p for t in d['tabs'] for p in t['panes'] if p.get('active')][0]"

args_value() {
  field "d['dash'].get('values', {}).get('fact-args', '')"
}

argument_value() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import sys
tokens = sys.argv[1].split()
flag = sys.argv[2]
try:
    index = tokens.index(flag)
except ValueError:
    print("")
    raise SystemExit(0)
if index + 1 >= len(tokens) or tokens[index + 1].startswith("--"):
    print("")
else:
    print(tokens[index + 1])
PY
}

claude_child() {
  local shell_pid="$1" child command
  for child in $(pgrep -P "$shell_pid" 2>/dev/null || true); do
    case "$child" in *[!0-9]*|'') continue;; esac
    command="$(ps -p "$child" -o command= 2>/dev/null || true)"
    case "$command" in
      *claude*|*/versions/*) printf '%s\n' "$child"; return 0;;
      *) ;; # Other direct children are not the agent oracle.
    esac
  done
  return 1
}

# The cheapest model, as bench-rows.sh does: 209c sends one real message.
CLAUDE_CMD="ANTHROPIC_MODEL=claude-haiku-4-5-20251001 claude"

# Under its own configuration claude asks the trust question (and whatever
# else is new) as cards; the bench answers them the way bench-agent.sh does.
# A Return sent while the trust card is up picks "No, exit" and kills the
# agent — measured 2026-08-28, one red 209c before this existed.
answer_any_cards() {
  local _
  for _ in 1 2 3 4; do
    send "scan"; sleep 1.5
    dump || return 1
    /usr/bin/python3 - "$DUMP" <<'PY2' || return 0
import json, sys
d = json.load(open(sys.argv[1]))
card = d.get("card", {})
if not card.get("showing"): sys.exit(1)
print("      answering card:", card.get("title"))
PY2
    send "approve yes"; sleep 6
  done
}

# claude 2.1.248 draws the trust question as an arrow menu, not a numbered
# one, so no card comes up (selector.kind = none, seen 2026-08-28): the bench
# reads the rows from the dump's scannerText and moves the arrow itself.
trust_dialog_rows() {
  /usr/bin/python3 - "$DUMP" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
rows = ["".join(chr(int(h, 16)) for h in r.split()) for r in d.get("scannerText", [])]
exit_row = any("\u276f No, exit" in r for r in rows)
yes_row = any("Yes, I tr" in r for r in rows)
print("dialog" if exit_row and yes_row else "none")
PY2
}

answer_trust_dialog() {
  local _ state dialog_seen=""
  for _ in $(seq 1 10); do
    dump || return 1
    state="$(trust_dialog_rows)"
    if [ "$state" = "dialog" ]; then
      dialog_seen=1
      echo "      trust dialog on screen: choosing 'Yes, I trust this folder'"
      send "key down"; sleep 0.3; send "key return"; sleep 4
      dump || return 1
      [ "$(trust_dialog_rows)" = "none" ] && return 0
    fi
    sleep 1
  done
  [ "$state" = "none" ] || echo "      the trust dialog did not go away" >&2
  # No dialog seen in ten seconds: say what WAS on the screen, so a red 209c
  # after this is explainable from the output alone.
  [ "$state" = "none" ] && [ -z "${dialog_seen:-}" ] && screen_rows | sed 's/^/      screen: /'
  return 0
}

# The first twelve characters of every non-empty row, as the scanner saw them.
screen_rows() {
  /usr/bin/python3 - "$DUMP" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d.get("scannerText", []):
    if r:
        print("".join(chr(int(h, 16)) for h in r.split()))
PY2
}

# Types the shell function and `claude`, then watches for two moments: the
# silent binary showing up as the foreground process, and the agent adopting
# its pid. Prints "<seconds to binary> <seconds to adoption or never> <pid>".
silent_agent_timeline() {
  local shell_pid="$1" t_bin="" t_adopt="" process agent_pid has_process pid i
  send "text claude() { $FAKE/launcher; }\\n" || return 1
  sleep 1
  send "text claude\\n" || return 1
  # Twenty-four 0.5 s polls: the launcher sleeps 3 s, the timer fires every 2.5 s.
  for i in $(seq 1 24); do
    sleep 0.5
    dump || return 1
    process="$(field "$active_pane_expression.get('process')")"
    pid="$(field "$active_pane_expression.get('pid')")"
    agent_pid="$(field "$active_pane_expression.get('agentPid', 'missing')")"
    has_process="$(field "d.get('agents', [{}])[0].get('adapter', {}).get('hasProcess', 'missing')")"
    if [ -z "$t_bin" ] && [ "$process" = "claude" ]; then t_bin=$((i / 2)); fi
    if [ -n "$t_bin" ] && [ -z "$t_adopt" ]; then
      if [ "$agent_pid" = "$pid" ] || { [ "$agent_pid" = "missing" ] && [ "$has_process" = "True" ]; }; then
        t_adopt=$((i / 2)); break
      fi
    fi
  done
  printf '%s %s %s\n' "${t_bin:-never}" "${t_adopt:-never}" "$pid"
}

t4a_note_his_app

echo "=== 209b · a bare shell sends no pid ========================"
if launch "$APP" && dump; then
  BARE_ARGS="$(args_value)"
  BARE_PID="$(field "d['dash'].get('factsContext', {}).get('pid')")"
  POLE=0
  case " $BARE_ARGS " in *" --pid "*) POLE=1;; *) ;; esac
  [ "$BARE_PID" = "None" ] || POLE=1
  pole "209b bare shell has no --pid" "$POLE" "args=[$BARE_ARGS] factsContext.pid=$BARE_PID"
else
  not_run "209b bare shell has no --pid" "launch or dump failed"
fi

echo "=== 209a/210a · idle claude, before any message ============="
if ! command -v claude >/dev/null 2>&1; then
  not_run "209a provider receives the claude child pid" "claude is not on PATH"
  not_run "210a observer adopts without another key" "claude is not on PATH"
  not_run "209c session and pid coexist after a message" "claude is not on PATH"
elif launch "$APP" && dump; then
  SHELL_PID="$(field "$active_pane_expression['pid']")"
  case "$SHELL_PID" in
    *[!0-9]*|'')
      not_run "209a provider receives the claude child pid" "dump.pid is not numeric: $SHELL_PID"
      not_run "210a observer adopts without another key" "dump.pid is not numeric: $SHELL_PID"
      not_run "209c session and pid coexist after a message" "dump.pid is not numeric: $SHELL_PID"
      ;;
    *)
      send "text $CLAUDE_CMD\\n" || { echo "could not launch claude through the pane" >&2; STATUS=1; }
      CHILD_PID=""; FACTS_PID=""; AGENT_PID="None"; LIVE_ARGS=""
      # Sixteen 0.2 s polls leave room for dump round trips inside the 5 s pole.
      for _ in $(seq 1 16); do
        sleep 0.2
        dump || break
        CHILD_PID="$(claude_child "$SHELL_PID" || true)"
        LIVE_ARGS="$(args_value)"
        FACTS_PID="$(field "d['dash'].get('factsContext', {}).get('pid')")"
        AGENT_PID="$(field "$active_pane_expression.get('agentPid')")"
        [ -n "$CHILD_PID" ] || continue
        [ "$(argument_value "$LIVE_ARGS" --pid)" = "$CHILD_PID" ] || continue
        [ "$FACTS_PID" = "$CHILD_PID" ] || continue
        [ "$AGENT_PID" = "$CHILD_PID" ] && break
      done

      POLE=0
      [ -n "$CHILD_PID" ] || POLE=1
      [ "$(argument_value "$LIVE_ARGS" --pid)" = "$CHILD_PID" ] || POLE=1
      [ "$FACTS_PID" = "$CHILD_PID" ] || POLE=1
      pole "209a provider receives the claude child pid" "$POLE" \
        "shell=$SHELL_PID child=$CHILD_PID args=[$LIVE_ARGS] factsContext.pid=$FACTS_PID"

      POLE=0
      [ -n "$CHILD_PID" ] || POLE=1
      [ "$AGENT_PID" = "$CHILD_PID" ] || POLE=1
      pole "210a observer adopts without another key" "$POLE" \
        "child=$CHILD_PID agentPid=$AGENT_PID"

      answer_any_cards
      answer_trust_dialog
      send "text ciao" || { echo "could not type the message through the pane" >&2; STATUS=1; }
      sleep 0.5
      # A key walks the KEY window's responder chain; a background app has none
      # and the pole would go red with sane code (measured 2026-08-27).
      send "activate" || { echo "could not activate the app" >&2; STATUS=1; }
      sleep 0.3
      send "key return" || { echo "could not submit the message through the pane" >&2; STATUS=1; }
      # The transcript is born when the message lands; bounded at 60 s, read
      # every 2 s, and the loop leaves as soon as --session is there.
      MESSAGE_ARGS=""; SESSION_ID=""; MESSAGE_PID=""; MESSAGE_DUMP=0
      for _ in $(seq 1 30); do
        sleep 2
        dump || break
        MESSAGE_DUMP=1
        MESSAGE_ARGS="$(args_value)"
        SESSION_ID="$(argument_value "$MESSAGE_ARGS" --session)"
        MESSAGE_PID="$(argument_value "$MESSAGE_ARGS" --pid)"
        [ -n "$SESSION_ID" ] && break
      done
      if [ "$MESSAGE_DUMP" -eq 1 ]; then
        POLE=0
        [ -n "$SESSION_ID" ] || POLE=1
        [ "$MESSAGE_PID" = "$CHILD_PID" ] || POLE=1
        pole "209c session and pid coexist after a message" "$POLE" \
          "session=$SESSION_ID pid=$MESSAGE_PID args=[$MESSAGE_ARGS]"
      else
        not_run "209c session and pid coexist after a message" "dump failed inside the bounded 60-second wait"
      fi
      ;;
  esac
else
  not_run "209a provider receives the claude child pid" "launch or initial dump failed"
  not_run "210a observer adopts without another key" "launch or initial dump failed"
  not_run "209c session and pid coexist after a message" "launch or initial dump failed"
fi

echo "=== 210b · a silent, launcher-shaped agent: only a timer can adopt it ="
if [ "$SILENT_AGENT" -eq 0 ]; then
  not_run "210b silent agent adopted within 5 s of appearing" "no compiler for the silent agent"
elif launch "$APP" && dump; then
  SHELL_PID="$(field "$active_pane_expression['pid']")"
  TIMELINE="$(silent_agent_timeline "$SHELL_PID")"
  T_BIN="${TIMELINE%% *}"; REST="${TIMELINE#* }"; T_ADOPT="${REST%% *}"; FAKE_PID="${REST#* }"
  POLE=1
  if [ "$T_BIN" != "never" ] && [ "$T_ADOPT" != "never" ] && [ $((T_ADOPT - T_BIN)) -le 5 ]; then POLE=0; fi
  pole "210b silent agent adopted within 5 s of appearing" "$POLE" \
    "binary at t+${T_BIN}s, adopted at t+${T_ADOPT}s, pid=$FAKE_PID (no byte written after the banner)"
else
  not_run "210b silent agent adopted within 5 s of appearing" "launch or initial dump failed"
fi

if [ -n "$HEAD" ]; then
  echo "=== HEAD · both repaired claims must be red =================="
  if command -v claude >/dev/null 2>&1 && launch "$HEAD" && dump; then
    HEAD_SHELL_PID="$(field "$active_pane_expression['pid']")"
    send "text $CLAUDE_CMD\\n" || { echo "could not launch claude in the HEAD pane" >&2; STATUS=1; }
    HEAD_CHILD_PID=""; HEAD_ARGS=""; HEAD_AGENT_PID="missing"; HEAD_HAS_PROCESS="missing"
    for _ in $(seq 1 16); do
      sleep 0.2
      dump || break
      HEAD_CHILD_PID="$(claude_child "$HEAD_SHELL_PID" || true)"
      HEAD_ARGS="$(args_value)"
      HEAD_AGENT_PID="$(field "$active_pane_expression.get('agentPid', 'missing')")"
      HEAD_HAS_PROCESS="$(field "d.get('agents', [{}])[0].get('adapter', {}).get('hasProcess', 'missing')")"
    done
    POLE=0
    case " $HEAD_ARGS " in *" --pid "*) POLE=1;; *) ;; esac
    expected_red "HEAD 209a provider still has no --pid" "$POLE" \
      "shell=$HEAD_SHELL_PID child=$HEAD_CHILD_PID args=[$HEAD_ARGS]"

    # Not a verdict: a real claude keeps writing bytes after its banner and
    # HEAD adopts the pid on those bytes, so this line cannot go red on HEAD
    # by construction (measured 2026-08-28, five runs). The falsifier for
    # ISC-210 is 210b below; this stays as the measurement the ISA asked for.
    printf '%-56s INFO  %s\n' "HEAD 210a idle observer with a real claude" \
      "agentPid=$HEAD_AGENT_PID hasProcess=$HEAD_HAS_PROCESS (bytes from claude's own TUI; see 210b)"
  else
    not_run "HEAD 209a provider still has no --pid" "claude, launch, or dump unavailable"
    not_run "HEAD 210a idle observer still has no pid" "claude, launch, or dump unavailable"
  fi
  if [ "$SILENT_AGENT" -eq 0 ]; then
    not_run "HEAD 210b silent agent is never adopted" "no compiler for the silent agent"
  elif launch "$HEAD" && dump; then
    HEAD_SHELL_PID="$(field "$active_pane_expression['pid']")"
    TIMELINE="$(silent_agent_timeline "$HEAD_SHELL_PID")"
    T_BIN="${TIMELINE%% *}"; REST="${TIMELINE#* }"; T_ADOPT="${REST%% *}"; FAKE_PID="${REST#* }"
    POLE=0
    [ "$T_ADOPT" = "never" ] || POLE=1
    expected_red "HEAD 210b silent agent is never adopted" "$POLE" \
      "binary at t+${T_BIN}s, adoption within 12 s: $([ "$T_ADOPT" = never ] && echo never || echo "t+${T_ADOPT}s"), pid=$FAKE_PID"
  else
    not_run "HEAD 210b silent agent is never adopted" "launch or dump unavailable"
  fi
else
  not_run "HEAD 209a provider still has no --pid" "no --head bundle supplied"
  not_run "HEAD 210a idle observer still has no pid" "no --head bundle supplied"
fi

t4a_stop_bench
exit "$STATUS"
