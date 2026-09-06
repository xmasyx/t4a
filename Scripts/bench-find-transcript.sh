#!/bin/bash
# ISC-233 — ⌘F searches the transcript an alternate screen has forgotten.
#
#   Scripts/bench-find-transcript.sh [--head <old-app-bundle>] [app-bundle]
#
# A real claude is deliberate: the product boundary is the adapter's live
# transcript, not a fixture that happens to resemble one. The isolated T4A and
# claude configs preserve login state while keeping both real files byte-for-byte
# unchanged. Every wait below ends on a state read from the app.

set -uo pipefail
cd "$(dirname "$0")/.."

APP="dist/T4A.app"
HEAD=""
APP_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --head) [ $# -ge 2 ] || { echo "--head needs a bundle" >&2; exit 2; }
      HEAD="$2"; shift 2;;
    --*) echo "unknown argument: $1" >&2; exit 2;;
    *) [ "$APP_SET" -eq 0 ] || { echo "only one app bundle is accepted" >&2; exit 2; }
      APP="$1"; APP_SET=1; shift;;
  esac
done

REAL_T4A_CONFIG="$HOME/.config/t4a/config.toml"
REAL_CLAUDE_CONFIG="$HOME/.claude.json"
hash_of() { [ -e "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "(absent)"; }
BEFORE_T4A="$(hash_of "$REAL_T4A_CONFIG")"
BEFORE_CLAUDE="$(hash_of "$REAL_CLAUDE_CONFIG")"

echo '==> preflight: pgrep -fl "T4A.app/Contents/MacOS/T4A"'
PREFLIGHT="$(pgrep -fl "T4A.app/Contents/MacOS/T4A" 2>&1)"
PREFLIGHT_STATUS=$?
[ -n "$PREFLIGHT" ] && printf '%s\n' "$PREFLIGHT" || echo '(no matches)'
if [ "$PREFLIGHT_STATUS" -gt 1 ]; then
  echo "NOT RUN: pgrep failed with status $PREFLIGHT_STATUS; safe cleanup is unavailable"
  exit 1
fi

source Scripts/lib/bench-stop.sh
t4a_note_his_app

WORK="$(mktemp -d -t t4a-find-transcript)" || exit 1
FIFO="$WORK/channel.fifo"
CFG="$WORK/config"
DUMPS="$WORK/dumps"
# Stable on purpose: claude keys its Keychain credential on the path of
# CLAUDE_CONFIG_DIR, so a fresh mktemp dir is «Not logged in» every run (30/08).
# Log this one in once: CLAUDE_CONFIG_DIR="$HOME/.cache/t4a/bench-claude-home" claude /login
CLAUDE_HOME="${T4A_BENCH_CLAUDE_HOME:-$HOME/.cache/t4a/bench-claude-home}"
LOGGED_IN=unknown
CHAT_DIR="${T4A_BENCH_DIR:-$HOME/Movies/t4a-bench-chat}"
CLAUDE_CMD="ANTHROPIC_MODEL=claude-haiku-4-5-20251001 claude --permission-mode acceptEdits --allowedTools Bash"
STATUS=0
BENCH_PID=""
DUMP=""

pole() {
  local name="$1" result="$2" detail="$3"
  if [ "$result" -eq 0 ]; then printf '%-62s PASS  %s\n' "$name" "$detail"
  else printf '%-62s FAIL  %s\n' "$name" "$detail"; STATUS=1; fi
}

expected_head() {
  local name="$1" result="$2" detail="$3"
  if [ "$result" -eq 0 ]; then printf '%-62s PASS (expected on HEAD)  %s\n' "$name" "$detail"
  else printf '%-62s FAIL (unexpected on HEAD)  %s\n' "$name" "$detail"; STATUS=1; fi
}

not_run() { printf '%-62s NOT RUN  %s\n' "$1" "$2"; STATUS=1; }

cleanup() {
  t4a_stop_bench
  for _ in $(seq 1 20); do [ -z "$(t4a_bench_pids)" ] && break; sleep 0.25; done
  case "$(basename "$WORK")" in t4a-find-transcript.*) rm -rf "$WORK";; esac
  t4a_bench_unlock
  local after_t4a after_claude result
  after_t4a="$(hash_of "$REAL_T4A_CONFIG")"; after_claude="$(hash_of "$REAL_CLAUDE_CONFIG")"
  result=PASS; [ "$after_t4a" = "$BEFORE_T4A" ] || { result=FAIL; STATUS=1; }
  printf '%-62s %s  before=%s after=%s\n' "real t4a config sha256 (byte-identical)" \
    "$result" "$BEFORE_T4A" "$after_t4a"
  result=PASS; [ "$after_claude" = "$BEFORE_CLAUDE" ] || { result=FAIL; STATUS=1; }
  printf '%-62s %s  before=%s after=%s\n' "real claude config sha256 (byte-identical)" \
    "$result" "$BEFORE_CLAUDE" "$after_claude"
}
trap cleanup EXIT

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }

dump() {
  local name="$1"
  DUMP="$DUMPS/$name.json"
  rm -f "$DUMP"
  send "dump $DUMP" || return 1
  for _ in $(seq 1 50); do [ -s "$DUMP" ] && return 0; sleep 0.1; done
  echo "dump $name did not arrive within 5 seconds" >&2
  return 1
}

field() {
  /usr/bin/python3 - "$DUMP" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
try:
    value = eval(sys.argv[2], {"d": d})
except Exception as error:
    print("missing:" + type(error).__name__)
else:
    if isinstance(value, bool): print("True" if value else "False")
    elif isinstance(value, (dict, list)): print(json.dumps(value, separators=(",", ":")))
    else: print(value)
PY
}

write_config() {
  rm -rf "$CFG"
  mkdir -p "$CFG/t4a" "$CLAUDE_HOME" "$DUMPS" || return 1
  chmod 700 "$CLAUDE_HOME"
  # His claude runs the fullscreen TUI (settings.user.json: "tui": "fullscreen"),
  # which is the alternate screen the claim is about; without it claude scrolls
  # the normal grid and HEAD finds the word in history (measured 30/08, run 1).
  printf '{"tui":"fullscreen"}\n' > "$CLAUDE_HOME/settings.json"
  printf '%s\n' \
    'chat-page = false' \
    'composer-mode = never' \
    'show-turn-map = false' \
    'pure-chat = false' \
    'theme = black' > "$CFG/t4a/config.toml"
  /usr/bin/python3 Scripts/claude-config-copy.py \
    "$REAL_CLAUDE_CONFIG" "$CLAUDE_HOME/.claude.json"
}

launch() {
  local bundle="$1"
  t4a_stop_bench
  for _ in $(seq 1 20); do [ -z "$(t4a_bench_pids)" ] && break; sleep 0.25; done
  [ -z "$(t4a_bench_pids)" ] || return 1
  rm -f "$FIFO"; write_config || return 1
  open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" \
    --env XDG_CONFIG_HOME="$CFG" --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME" || return 1
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || return 1
  BENCH_PID="$(t4a_bench_pids | tail -1)"
  [ -n "$BENCH_PID" ] || return 1
  for _ in $(seq 1 80); do
    dump launch || return 1
    [ "$(field "len(d.get('tabs',[]))")" -ge 1 ] 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

screen_has() {
  local needle="$1"
  [ "$(field "any('$needle'.lower() in row.lower() for tab in d.get('tabs',[]) if tab.get('active') for pane in tab.get('panes',[]) if pane.get('active') for row in pane.get('screen',[]))")" = True ]
}

answer_startup() {
  local clear=0
  for _ in $(seq 1 60); do
    send scan >/dev/null 2>&1 || true
    dump startup || return 1
    if screen_has "Yes, I trust this folder"; then
      send "key down"; send "key return"; clear=0; sleep 0.5; continue
    fi
    if screen_has "Enter to confirm"; then
      send "key return"; clear=0; sleep 0.5; continue
    fi
    if [ "$(field "d.get('card',{}).get('showing',False)")" = True ]; then
      send "approve yes"; clear=0; sleep 0.5; continue
    fi
    if [ "$(field "d.get('agents',[{}])[0].get('adapter',{}).get('attached',False)")" = True ] \
       && [ "$(field "next((p.get('inputBoxSeen',False) for t in d.get('tabs',[]) if t.get('active') for p in t.get('panes',[]) if p.get('active')),False)")" = True ]; then
      clear=$((clear + 1)); [ "$clear" -ge 2 ] && return 0
    else clear=0; fi
    sleep 0.5
  done
  return 1
}

start_claude() {
  local quoted
  printf -v quoted '%q' "$CHAT_DIR"
  send "text cd $quoted && $CLAUDE_CMD" || return 1
  send "key return" || return 1
  answer_startup
}

turn_count() {
  field "len(d.get('agents',[{}])[0].get('turnList',[]))"
}

send_turn() {
  local message="$1" before="$2"
  send "text $message" || return 1
  send "key return" || return 1
  for _ in $(seq 1 150); do
    sleep 1
    send scan >/dev/null 2>&1 || true
    dump turn || return 1
    if [ "$(field "d.get('card',{}).get('showing',False)")" = True ]; then
      send "approve yes"; continue
    fi
    local count closed
    count="$(turn_count)"
    closed="$(field "bool(d.get('agents',[{}])[0].get('turnList',[])) and not d['agents'][0]['turnList'][-1].get('open',True)")"
    [ "$count" -gt "$before" ] 2>/dev/null && [ "$closed" = True ] && return 0
  done
  return 1
}

prepare_two_turns() {
  launch "$1" || return 1
  start_claude || return 1
  dump ready || return 1
  local count
  count="$(turn_count)"
  send "resize 1100x380"; sleep 0.8
  send_turn "Rispondi soltanto OK. Parola sentinella nella domanda: zirconio." "$count" || return 1
  dump after1 || return 1; count="$(turn_count)"
  LOGGED_IN=yes; screen_has "Not logged in" && LOGGED_IN=no
  send_turn "Scrivi i numeri da 1 a 150, uno per riga, senza altro." "$count" || return 1
  dump after2
}

run_new() {
  echo '=== ISC-233 · transcript find on a real alternate screen =========='
  if ! prepare_two_turns "$APP"; then
    not_run "233a transcript beats the alternate-screen grid" "claude, launch, or two turns unavailable"
    not_run "233b Return opens and highlights turn 1" "setup unavailable"
    not_run "233c a step-detail hit opens that step" "setup unavailable"
    not_run "233d the find field keeps the keyboard" "setup unavailable"
    return
  fi

  send "find zirconio"; dump 233a || return
  local source matches turn place absent alternate result
  source="$(field "d.get('find',{}).get('source','')")"
  matches="$(field "d.get('find',{}).get('matches',0)")"
  turn="$(field "d.get('find',{}).get('hits',[{}])[0].get('turn',-1)")"
  place="$(field "d.get('find',{}).get('hits',[{}])[0].get('place','')")"
  absent=True; screen_has zirconio && absent=False
  alternate="$(field "next((p.get('alternateScreen',False) for t in d.get('tabs',[]) if t.get('active') for p in t.get('panes',[]) if p.get('active')),False)")"
  result=1
  [ "$source" = transcript ] && [ "$matches" -ge 1 ] 2>/dev/null \
    && [ "$turn" = 1 ] && [ "$place" = prompt ] && [ "$absent" = True ] && result=0
  pole "233a transcript beats the alternate-screen grid" "$result" \
    "source=$source matches=$matches first.turn=$turn first.place=$place screenHasZirconio=$([ "$absent" = True ] && echo false || echo true) alternateScreen=$alternate"

  send findopen; dump 233b || return
  local open highlight
  open="$(field "d.get('turnReader',{}).get('open',False)")"
  turn="$(field "d.get('turnReader',{}).get('turn',-1)")"
  highlight="$(field "d.get('turnReader',{}).get('highlight',{})")"
  result=1
  [ "$open" = True ] && [ "$turn" = 1 ] \
    && [ "$(field "d.get('turnReader',{}).get('highlight',{}).get('renderedLength',0)")" -gt 0 ] 2>/dev/null \
    && result=0
  pole "233b Return opens and highlights turn 1" "$result" \
    "open=$open turn=$turn highlight=$highlight"
  mkdir -p design/evidence
  if Scripts/shot.sh "$BENCH_PID" design/evidence/f13-233-find-transcript.png; then
    echo "      photographed: design/evidence/f13-233-find-transcript.png (pid $BENCH_PID)"
  else
    pole "233b faithful window photograph" 1 "Scripts/shot.sh failed for pid $BENCH_PID"
  fi
  send turn-close; dump 233bclose || return
  result=1
  [ "$(field "d.get('composer',{}).get('firstResponder','')")" = NSTextView ] \
    && [ "$(field "d.get('find',{}).get('matches',0)")" -ge 1 ] 2>/dev/null && result=0
  pole "233b closing the reader returns to the populated find field" "$result" \
    "responder=$(field "d.get('composer',{}).get('firstResponder','')") matches=$(field "d.get('find',{}).get('matches',0)")"

  dump before3 || return; local count; count="$(turn_count)"
  if [ "$LOGGED_IN" = no ]; then
    not_run "233c a step-detail hit opens that step" "claude is not logged in under $CLAUDE_HOME: run CLAUDE_CONFIG_DIR=$CLAUDE_HOME claude /login once"
  elif ! send_turn "Esegui con Bash esattamente: printf 'tanta%s\\n' 'lio'. Poi rispondi soltanto OK." "$count"; then
    not_run "233c a step-detail hit opens that step" "the Bash turn did not finish"
  else
    send "find tantalio"; dump 233cfind || return
    source="$(field "d.get('find',{}).get('source','')")"
    matches="$(field "d.get('find',{}).get('matches',0)")"
    place="$(field "d.get('find',{}).get('hits',[{}])[0].get('place','')")"
    local step; step="$(field "d.get('find',{}).get('hits',[{}])[0].get('stepID','')")"
    send findopen; dump 233copen || return
    result=1
    [ "$source" = transcript ] && [ "$matches" -ge 1 ] 2>/dev/null && [ "$place" = step ] \
      && [ -n "$step" ] \
      && [ "$(field "'$step' in d.get('turnReader',{}).get('openSteps',[])")" = True ] \
      && [ "$(field "d.get('turnReader',{}).get('highlight',{}).get('renderedLength',0)")" -gt 0 ] 2>/dev/null \
      && result=0
    pole "233c a step-detail hit opens that step" "$result" \
      "source=$source matches=$matches place=$place stepID=$step openSteps=$(field "d.get('turnReader',{}).get('openSteps',[])") highlight=$(field "d.get('turnReader',{}).get('highlight',{})")"
    send turn-close
  fi

  send "find zirc"; sleep 3; dump 233d || return
  local responder; responder="$(field "d.get('composer',{}).get('firstResponder','')")"
  result=1; [ "$responder" = NSTextView ] && result=0
  pole "233d the find field keeps the keyboard after 3 seconds" "$result" \
    "firstResponder=$responder source=$(field "d.get('find',{}).get('source','')") query=$(field "d.get('find',{}).get('query','')")"
}

run_grid() {
  echo '=== ISC-233e · a naked shell keeps the grid search ================'
  if ! launch "$APP"; then not_run "233e no agent means grid search" "app launch unavailable"; return; fi
  send "text echo gridrame"; send "key return"; sleep 1
  send "find gridrame"; dump 233e || { not_run "233e no agent means grid search" "dump unavailable"; return; }
  local source matches result
  source="$(field "d.get('find',{}).get('source','')")"
  matches="$(field "d.get('find',{}).get('matches',0)")"
  result=1; [ "$source" = grid ] && [ "$matches" -ge 1 ] 2>/dev/null && result=0
  pole "233e no agent means grid search" "$result" \
    "source=$source matches=$matches rowsScanned=$(field "d.get('find',{}).get('rowsScanned',0)")"
}

run_head() {
  [ -n "$HEAD" ] || return 0
  echo '=== H-233a · HEAD must lose the off-screen word ==================='
  if ! prepare_two_turns "$HEAD"; then
    not_run "H-233a HEAD returns zero grid matches" "claude, launch, or two turns unavailable"
    return
  fi
  send "find zirconio"; dump h233a || return
  local matches absent result
  matches="$(field "d.get('find',{}).get('matches',-1)")"
  absent=True; screen_has zirconio && absent=False
  result=1; [ "$matches" = 0 ] && [ "$absent" = True ] && result=0
  expected_head "H-233a HEAD returns zero grid matches" "$result" \
    "matches=$matches screenHasZirconio=$([ "$absent" = True ] && echo false || echo true) source=$(field "d.get('find',{}).get('source','unreported')")"
}

if [ ! -x "$APP/Contents/MacOS/T4A" ]; then
  echo "no bundle at $APP" >&2; STATUS=1
elif ! command -v claude >/dev/null 2>&1; then
  echo "claude is not on PATH" >&2; STATUS=1
else
  run_new
  run_grid
  run_head
fi

cleanup
trap - EXIT
exit "$STATUS"
