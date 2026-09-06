#!/bin/bash
# ISC-220 — sibling claude panes follow only the transcript attributed to them.
#
#   Scripts/bench-fratelli.sh [--head <old-app-bundle>] [app-bundle]
#
# Two tabs are deliberate. The channel can select a tab, but `clickpane` only
# clicks inside the pane that is already active. A starts claude, B starts the
# same vendor in the same directory without sending a message, and only then A
# sends: this is the order in which HEAD's app-wide, first-come adoption can
# dress B in A's transcript. The vendor's sessions/<pid>.json records are the
# independent oracle: each is written when its TUI reaches the prompt after
# startup dialogs, while the transcript .jsonl is born with the first message.
# Transcript mtime is never used by this bench.

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
  printf '%-56s NOT RUN  %s\n' "220b A follows its own transcript and has a turn" "$reason"
  printf '%-56s NOT RUN  %s\n' "220a B follows nothing and says why" "$reason"
  printf '%-56s NOT RUN  %s\n' "220c B follows its own transcript within 5 s" "$reason"
  printf '%-56s NOT RUN  %s\n' "220d A is untouched by B's message" "$reason"
  if [ -n "$HEAD" ]; then
    printf '%-56s NOT RUN  %s\n' "H-220a HEAD misattributes A's transcript to B" "$reason"
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

# Sourcing takes the one-bench lock and records every T4A that was already his.
source "$(dirname "$0")/lib/bench-stop.sh"

WORK="$(mktemp -d -t t4a-fratelli)" || exit 1
FIFO="$WORK/channel.fifo"
CFG="$WORK/config"
DUMP="$WORK/dump.json"
CLAUDE_HOME="$WORK/claude-home"
CHAT_DIR="${T4A_BENCH_DIR:-$HOME/Movies/t4a-bench-chat}"
CLAUDE_CMD="ANTHROPIC_MODEL=claude-haiku-4-5-20251001 claude"
STATUS=0
CLEANED=0
RUN_ERROR=""

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

# Here success means the old defect was actually observed. A green HEAD is a
# failed falsifier, not evidence for the repair.
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
  # At most 5 s: leave the loop as soon as every instance carrying our FIFO is gone.
  for _ in $(seq 1 20); do
    [ -z "$(t4a_bench_pids)" ] && break
    sleep 0.25
  done
  case "$(basename "$WORK")" in t4a-fratelli.*) rm -rf "$WORK";; esac
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
  # At most 5 s: the condition is a non-empty answer at the requested path.
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
if not isinstance(root.get("agents"), list):
    raise SystemExit("dump has no agents array")
PY
  then
    RUN_ERROR="the app wrote an invalid dump"
    return 1
  fi
}

# Read pane facts and agent facts from one dump. Agent lookup is by the pane's
# session UUID, never by the incidental order of the agents array.
json_value() {
  /usr/bin/python3 - "$DUMP" "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
scope, tab_text, key = sys.argv[2:]
tab_index = int(tab_text)
value = ""
try:
    tab = d["tabs"][tab_index]
    pane = tab["panes"][0]
    if scope == "tabs":
        value = len(d["tabs"])
    elif scope == "tab":
        value = tab.get(key, "")
    elif scope == "pane" and key == "blocksCount":
        value = len(pane.get("blocks", []))
    elif scope == "pane":
        value = pane.get(key, "")
    else:
        agent = next(a for a in d["agents"] if a.get("session") == pane.get("id"))
        if scope == "agent":
            value = agent.get(key, "")
        elif scope == "adapter":
            value = agent.get("adapter", {}).get(key, "")
except (IndexError, KeyError, StopIteration, TypeError, ValueError):
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

write_config() {
  rm -rf "$CFG"
  mkdir -p "$CFG/t4a" || return 1
  printf '# isolated config written by bench-fratelli.sh\n' > "$CFG/t4a/config.toml"
}

seed_claude_config() {
  rm -rf "$CLAUDE_HOME"
  mkdir -p "$CLAUDE_HOME" || return 1
  chmod 700 "$CLAUDE_HOME" || return 1
  /usr/bin/python3 Scripts/claude-config-copy.py \
    "$REAL_CLAUDE_CONFIG" "$CLAUDE_HOME/.claude.json" || {
      echo "could not seed the isolated claude config" >&2
      return 1
    }
}

wait_first_prompt() {
  local blocks
  # At most 20 s of 0.25 s polls: the first pane must report a prompt block.
  for _ in $(seq 1 80); do
    dump || return 1
    read_value blocks pane 0 blocksCount || return 1
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
  # At most 5 s: do not reuse the FIFO until our preceding instance is gone.
  for _ in $(seq 1 20); do
    [ -z "$(t4a_bench_pids)" ] && break
    sleep 0.25
  done
  if [ -n "$(t4a_bench_pids)" ]; then
    RUN_ERROR="the preceding instance did not stop within 5 seconds"
    return 1
  fi
  rm -f "$FIFO" "$DUMP"
  if ! write_config; then RUN_ERROR="could not write the isolated t4a config"; return 1; fi
  if ! seed_claude_config; then RUN_ERROR="could not seed the isolated claude config"; return 1; fi
  if ! open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" \
       --env XDG_CONFIG_HOME="$CFG" --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME"; then
    RUN_ERROR="could not open $bundle"
    return 1
  fi
  # At most 10 s: launch is ready for commands only when its private FIFO exists.
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

screen_rows() {
  /usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
active = next((tab for tab in d.get("tabs", []) if tab.get("active")), {})
panes = active.get("panes", [])
pane = panes[0] if panes else {}
if "screen" in pane:
    rows = pane["screen"]
else:
    # Older dumps may omit pane screen; scannerText is a truncated fallback.
    rows = ["".join(chr(int(code, 16)) for code in row.split())
            for row in d.get("scannerText", [])]
for row in rows:
    row = row.rstrip()
    if row:
        print(row)
PY
}

arrow_dialog_rows() {
  /usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
active = next((tab for tab in d.get("tabs", []) if tab.get("active")), {})
panes = active.get("panes", [])
pane = panes[0] if panes else {}
if "screen" in pane:
    raw_rows = pane["screen"]
else:
    # Older dumps may omit pane screen; scannerText is a truncated fallback.
    raw_rows = ["".join(chr(int(code, 16)) for code in row.split())
                for row in d.get("scannerText", [])]
rows = [row.rstrip() for row in raw_rows]
rows = [row for row in rows if row]
confirm = any("Enter to confirm" in row for row in rows)
selected = next((row.lstrip() for row in rows
                 if row.lstrip().startswith("\u276f")), "")
trust = any("Yes, I trust" in row for row in rows)
state = "dialog" if confirm and selected else "none"
print("\x1f".join((state, "trust" if trust else "default", selected)))
PY
}

# Drain claude's arrow-menu dialogs separately from card-shaped approvals. A
# dialog has both an "Enter to confirm" row and a row beginning with the arrow;
# the ordinary `❯ Try "..."` prompt therefore does not match.
answer_arrow_dialogs() {
  local details state choice selected highlighted changed polls
  local dialogs=0 clear_polls=0 deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    dump || return 1
    if ! details="$(arrow_dialog_rows)"; then
      RUN_ERROR="could not read the arrow-dialog rows"
      return 1
    fi
    IFS=$'\x1f' read -r state choice selected <<< "$details"
    if [ "$state" = "dialog" ]; then
      clear_polls=0
      if [ "$dialogs" -ge 8 ]; then
        RUN_ERROR="more than 8 arrow dialogs appeared within 30 seconds"
        return 1
      fi
      dialogs=$((dialogs + 1))
      echo "      dialog on screen: $selected"
      highlighted="$selected"
      if [ "$choice" = "trust" ]; then
        checked_send "key down" "move the trust dialog arrow" || return 1
      fi
      checked_send "key return" "accept the highlighted dialog choice" || return 1

      changed=0
      polls=0
      # At most 4 s: the answered arrow menu must disappear or be replaced.
      for _ in $(seq 1 8); do
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 0.5
        polls=$((polls + 1))
        dump || return 1
        if ! details="$(arrow_dialog_rows)"; then
          RUN_ERROR="could not reread the arrow-dialog rows"
          return 1
        fi
        IFS=$'\x1f' read -r state choice selected <<< "$details"
        if [ "$state" = "none" ]; then
          changed=1
          clear_polls=1
          break
        fi
        if [ "$selected" != "$highlighted" ]; then
          changed=1
          break
        fi
      done
      if [ "$changed" -eq 0 ]; then
        if [ "$polls" -ge 8 ]; then
          RUN_ERROR="the arrow dialog '$highlighted' did not change within 4 seconds"
          return 1
        fi
        break
      fi
    else
      clear_polls=$((clear_polls + 1))
      [ "$clear_polls" -ge 2 ] && return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  RUN_ERROR="arrow dialogs did not clear for two consecutive polls within 30 seconds"
  return 1
}

# Drain card-shaped permissions separately from the arrow menus. Each
# approval waits on the card changing or disappearing, never on a naked delay.
answer_any_cards() {
  local showing title after_showing after_title
  for _ in 1 2 3 4; do
    checked_send "scan" "scan for permission cards" || return 1
    dump || return 1
    # `showing` is at root, so read it directly and validate the helper result.
    if ! showing="$(/usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
print("true" if json.load(open(sys.argv[1])).get("card", {}).get("showing") else "false")
PY
)"; then RUN_ERROR="could not read card.showing"; return 1; fi
    [ "$showing" = "true" ] || return 0
    if ! title="$(/usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("card", {}).get("title", ""))
PY
)"; then RUN_ERROR="could not read card.title"; return 1; fi
    echo "      answering card: $title"
    checked_send "approve yes" "approve the permission card" || return 1
    # At most 6 s: the approved card must disappear or be replaced.
    for _ in $(seq 1 12); do
      dump || return 1
      if ! after_showing="$(/usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
print("true" if json.load(open(sys.argv[1])).get("card", {}).get("showing") else "false")
PY
)"; then RUN_ERROR="could not reread card.showing"; return 1; fi
      if ! after_title="$(/usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("card", {}).get("title", ""))
PY
)"; then RUN_ERROR="could not reread card.title"; return 1; fi
      { [ "$after_showing" != "true" ] || [ "$after_title" != "$title" ]; } && break
      sleep 0.5
    done
  done
  return 0
}

select_tab() {
  local index="$1" active
  checked_send "selecttab $index" "select tab $index" || return 1
  # At most 2 s: selection is complete when the requested tab reports active.
  for _ in $(seq 1 20); do
    dump || return 1
    read_value active tab "$index" active || return 1
    [ "$active" = "true" ] && return 0
    sleep 0.1
  done
  RUN_ERROR="tab $index did not become active within 2 seconds"
  return 1
}

wait_second_tab_prompt() {
  local tabs blocks
  # At most 20 s: newtab must create tab 1 and its only pane must reach a prompt.
  for _ in $(seq 1 80); do
    dump || return 1
    read_value tabs tabs 0 count || return 1
    read_value blocks pane 1 blocksCount || return 1
    case "$tabs:$blocks" in
      2:*[!0-9]*|2:) ;;
      2:*) [ "$blocks" -gt 0 ] && return 0;;
      *) ;;
    esac
    sleep 0.25
  done
  RUN_ERROR="the second tab did not reach a prompt within 20 seconds"
  return 1
}

ensure_second_tab_active() {
  local active
  dump || return 1
  read_value active tab 1 active || return 1
  [ "$active" = "true" ] && return 0
  select_tab 1
}

wait_agent_pid() {
  local tab="$1" other_pid="$2" pid
  WAIT_PID=""
  # At most 20 s, at 0.5 s intervals: the pane must adopt a numeric agent pid.
  for _ in $(seq 1 40); do
    dump || return 1
    read_value pid pane "$tab" agentPid || return 1
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        if [ -z "$other_pid" ] || [ "$pid" != "$other_pid" ]; then
          WAIT_PID="$pid"
          return 0
        fi
        ;;
    esac
    sleep 0.5
  done
  RUN_ERROR="tab $tab did not adopt a distinct numeric agent pid within 20 seconds"
  return 1
}

wait_session_record() {
  local pid="$1" record="$CLAUDE_HOME/sessions/$1.json" value
  ORACLE_SESSION=""
  # At most 10 s: claude's own live-pid record must name its sessionId.
  for _ in $(seq 1 20); do
    if [ -s "$record" ]; then
      if value="$(/usr/bin/python3 - "$record" 2>/dev/null <<'PY'
import json, sys
value = json.load(open(sys.argv[1])).get("sessionId", "")
print(value if isinstance(value, str) else "")
PY
)" && [ -n "$value" ]; then
        ORACLE_SESSION="$value"
        return 0
      fi
    fi
    sleep 0.5
  done
  RUN_ERROR="claude's sessions/$pid.json did not name a sessionId within 10 seconds"
  return 1
}

session_record_names() {
  local directory="$CLAUDE_HOME/sessions" path names=""
  if [ -d "$directory" ]; then
    for path in "$directory"/*; do
      [ -e "$path" ] || continue
      names="${names}${names:+,}$(basename "$path")"
    done
  fi
  printf '%s\n' "${names:-(none)}"
}

setup_pair() {
  local bundle="$1" active turns activity b_follow chat_quoted
  local a_has_turn=0 a_reason a_following record_names
  A_PID=""; B_PID=""; SESSION_A=""; SESSION_B=""; A_FINISHED=0
  launch "$bundle" || return 1
  printf -v chat_quoted '%q' "$CHAT_DIR"
  checked_send "text cd $chat_quoted && $CLAUDE_CMD\\n" "start claude in A" || return 1
  wait_agent_pid 0 "" || return 1
  A_PID="$WAIT_PID"
  answer_any_cards || return 1
  answer_arrow_dialogs || return 1
  answer_any_cards || return 1

  checked_send "newtab" "open B in a new tab" || return 1
  wait_second_tab_prompt || return 1
  ensure_second_tab_active || return 1
  dump || return 1
  read_value active tab 1 active || return 1
  if [ "$active" != "true" ]; then RUN_ERROR="tab 1 is not active before typing into B"; return 1; fi
  checked_send "text cd $chat_quoted && $CLAUDE_CMD\\n" "start claude in B" || return 1
  wait_agent_pid 1 "$A_PID" || return 1
  B_PID="$WAIT_PID"

  # B is already attached but has sent no message. This exact order gives the
  # old app-wide adopter a chance to hand A's newly born transcript to B.
  select_tab 0 || return 1
  answer_arrow_dialogs || return 1
  checked_send "text prova" "type A's message" || return 1
  checked_send "activate" "activate A before Return" || return 1
  checked_send "key return" "submit A's message" || return 1

  # At most 60 s, polled every 2 s: A must have a turn; the loop also waits for
  # idle when time permits. Permission cards are drained because a real claude
  # may ask mid-turn.
  for _ in $(seq 1 30); do
    sleep 2
    answer_any_cards || return 1
    dump || return 1
    read_value turns adapter 0 turns || return 1
    read_value activity agent 0 activity || return 1
    case "$turns" in ''|*[!0-9]*) ;; *)
      if [ "$turns" -ge 1 ]; then
        a_has_turn=1
        if [ "$activity" = "idle" ]; then A_FINISHED=1; break; fi
      fi
      ;;
    esac
  done

  if [ "$a_has_turn" -eq 0 ]; then
    a_reason="$(json_value adapter 0 transcriptReason 2>/dev/null)" || a_reason="(unreadable)"
    a_following="$(json_value adapter 0 following 2>/dev/null)" || a_following="(unreadable)"
    record_names="$(session_record_names)"
    RUN_ERROR="A did not reach turns >= 1 within 60 seconds; transcriptReason=[$a_reason] following=${a_following:-empty} turns=${turns:-missing} sessions=[$record_names]"
    return 1
  fi

  # The live-pid record already exists once the TUI reaches its prompt; reading
  # it here after A's first turn remains a bounded way to establish the oracle.
  wait_session_record "$A_PID" || return 1
  SESSION_A="$ORACLE_SESSION"

  # Up to 5 s in 0.5 s polls: on repaired code the full negative-observation
  # window elapses; on HEAD the loop may leave early once B adopts A's file.
  for _ in $(seq 1 10); do
    sleep 0.5
    dump || return 1
    read_value b_follow adapter 1 following || return 1
    [ "$b_follow" = "$SESSION_A.jsonl" ] && break
  done
  dump || return 1
}

run_new_build() {
  local following_a following_b turns_a turns_b source_a reason_b source_b result elapsed matched i
  echo "=== ISC-220 · pid-attributed sibling transcripts =========="
  if ! setup_pair "$APP"; then
    not_run "220b A follows its own transcript and has a turn" "${RUN_ERROR:-pair setup failed}"
    not_run "220a B follows nothing and says why" "${RUN_ERROR:-pair setup failed}"
    not_run "220c B follows its own transcript within 5 s" "${RUN_ERROR:-pair setup failed}"
    not_run "220d A is untouched by B's message" "${RUN_ERROR:-pair setup failed}"
    return
  fi
  if ! read_value following_a adapter 0 following \
     || ! read_value turns_a adapter 0 turns \
     || ! read_value source_a adapter 0 transcriptSource \
     || ! read_value following_b adapter 1 following \
     || ! read_value reason_b adapter 1 transcriptReason \
     || ! read_value source_b adapter 1 transcriptSource; then
    not_run "220b A follows its own transcript and has a turn" "$RUN_ERROR"
    not_run "220a B follows nothing and says why" "$RUN_ERROR"
    not_run "220c B follows its own transcript within 5 s" "$RUN_ERROR"
    not_run "220d A is untouched by B's message" "$RUN_ERROR"
    return
  fi

  result=1
  case "$turns_a" in ''|*[!0-9]*) ;; *)
    [ "$following_a" = "$SESSION_A.jsonl" ] && [ "$turns_a" -ge 1 ] && result=0
    ;;
  esac
  pole "220b A follows its own transcript and has a turn" "$result" \
    "following=$following_a turns=${turns_a:-missing} transcriptSource=${source_a:-empty} A.finished=$A_FINISHED"

  result=1
  [ -z "$following_b" ] && [ -n "$reason_b" ] && result=0
  pole "220a B follows nothing and says why" "$result" \
    "reason=[$reason_b] transcriptSource=${source_b:-empty}"

  if ! select_tab 1 \
     || ! checked_send "text prova" "type B's message" \
     || ! checked_send "activate" "activate B before Return" \
     || ! checked_send "key return" "submit B's message"; then
    not_run "220c B follows its own transcript within 5 s" "${RUN_ERROR:-could not send the B message}"
    not_run "220d A is untouched by B's message" "${RUN_ERROR:-could not send the B message}"
    return
  fi

  # B's oracle record exists from its prompt; its message creates the transcript,
  # so this bounded read remains inside 220c after that message is submitted.
  if ! wait_session_record "$B_PID"; then
    not_run "220c B follows its own transcript within 5 s" "$RUN_ERROR"
    not_run "220d A is untouched by B's message" "$RUN_ERROR"
    return
  fi
  SESSION_B="$ORACLE_SESSION"

  matched=0; i=0
  # At most 5 s, polled every 0.5 s: B must select its oracle transcript.
  for i in $(seq 1 10); do
    sleep 0.5
    dump || break
    read_value following_b adapter 1 following || break
    if [ "$following_b" = "$SESSION_B.jsonl" ]; then matched=1; break; fi
  done
  if ! elapsed="$(awk -v ticks="$i" 'BEGIN { printf "%.1f", ticks / 2 }')"; then
    RUN_ERROR="could not calculate B's adoption latency"
    not_run "220c B follows its own transcript within 5 s" "$RUN_ERROR"
    not_run "220d A is untouched by B's message" "$RUN_ERROR"
    return
  fi
  if [ "$matched" -eq 0 ] && [ -n "$RUN_ERROR" ]; then
    not_run "220c B follows its own transcript within 5 s" "$RUN_ERROR"
    not_run "220d A is untouched by B's message" "$RUN_ERROR"
    return
  fi

  # At most 1 more second: following may be visible one poll before turn count.
  for _ in 1 2; do
    read_value turns_b adapter 1 turns || break
    # ≥ 1: the claim is ATTRIBUTION (B follows its own file, not A's). Under the
    # bench's isolated CLAUDE_CONFIG_DIR claude is «Not logged in» and the turn
    # count after a refused message oscillates between 1 and 2 (runs 5, 6 and
    # the operator's rerun of 29/08); judging it measured claude, not T4A.
    case "$turns_b" in ""|*[!0-9]*) ;; *) [ "$turns_b" -ge 1 ] && break;; esac
    sleep 0.5
    dump || break
  done
  dump || {
    not_run "220c B follows its own transcript within 5 s" "$RUN_ERROR"
    not_run "220d A is untouched by B's message" "$RUN_ERROR"
    return
  }
  if ! read_value following_a adapter 0 following \
     || ! read_value following_b adapter 1 following \
     || ! read_value turns_a adapter 0 turns \
     || ! read_value turns_b adapter 1 turns; then
    not_run "220c B follows its own transcript within 5 s" "$RUN_ERROR"
    not_run "220d A is untouched by B's message" "$RUN_ERROR"
    return
  fi

  result=1
  [ "$matched" -eq 1 ] && [ "$following_b" = "$SESSION_B.jsonl" ] \
    && [ "$following_b" != "$SESSION_A.jsonl" ] && [ "${turns_b:-0}" -ge 1 ] 2>/dev/null && result=0
  pole "220c B follows its own transcript within 5 s" "$result" \
    "elapsed=${elapsed}s A.following=$following_a B.following=$following_b A.turns=$turns_a B.turns=$turns_b"

  result=1
  [ "$following_a" = "$SESSION_A.jsonl" ] && result=0
  pole "220d A is untouched by B's message" "$result" \
    "A.following=$following_a expected=$SESSION_A.jsonl B.following=$following_b"
}

run_head() {
  local following_a following_b defect
  echo "=== HEAD · the old app-wide adoption must show red ========="
  if ! setup_pair "$HEAD"; then
    not_run "H-220a HEAD misattributes A's transcript to B" "${RUN_ERROR:-pair setup failed}"
    return
  fi
  read_value following_a adapter 0 following || {
    not_run "H-220a HEAD misattributes A's transcript to B" "$RUN_ERROR"; return;
  }
  read_value following_b adapter 1 following || {
    not_run "H-220a HEAD misattributes A's transcript to B" "$RUN_ERROR"; return;
  }
  defect=1
  # This is the one timing-sensitive falsifier: the setup above is the measured
  # order that makes HEAD's already-attached B race for A's first transcript.
  # The second spelling is kept explicit because it identifies which observer
  # won HEAD's first-come claim: B has A's file while A follows nothing.
  if [ "$following_b" = "$SESSION_A.jsonl" ] \
     || { [ -z "$following_a" ] && [ "$following_b" = "$SESSION_A.jsonl" ]; }; then
    defect=0
  fi
  expected_red "H-220a HEAD misattributes A's transcript to B" "$defect" \
    "A.following=$following_a B.following=$following_b SESSION_A=$SESSION_A"
}

t4a_note_his_app
if ! command -v claude >/dev/null 2>&1; then
  early_not_run "claude is not on PATH"
  STATUS=1
  finish
fi
if ! mkdir -p "$CHAT_DIR"; then
  early_not_run "could not create chat directory $CHAT_DIR"
  STATUS=1
  finish
fi

if [ -x "$APP/Contents/MacOS/T4A" ]; then
  run_new_build
else
  not_run "220b A follows its own transcript and has a turn" "no bundle at $APP"
  not_run "220a B follows nothing and says why" "no bundle at $APP"
  not_run "220c B follows its own transcript within 5 s" "no bundle at $APP"
  not_run "220d A is untouched by B's message" "no bundle at $APP"
fi

if [ -n "$HEAD" ]; then
  # launch() first stops only the instance carrying this bench's FIFO.
  if [ -x "$HEAD/Contents/MacOS/T4A" ]; then
    run_head
  else
    not_run "H-220a HEAD misattributes A's transcript to B" "no HEAD bundle at $HEAD"
  fi
fi

finish
