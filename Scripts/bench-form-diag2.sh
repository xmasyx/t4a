#!/bin/bash
# ISC-241, stage 1 — which spelling of one image path Claude recognises.
#
#   Scripts/bench-paste-form.sh [app-bundle]
#
# One live Claude receives the same real PNG path three times, through the
# backend's bracketed-paste writer and WITHOUT Return. Two seconds later the
# visible input row is dumped. The table is the measurement that chooses the
# production spelling; this script deliberately changes no clipboard state.

set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh

APP="${1:-dist/T4A.app}"
REAL_CLAUDE_CONFIG="$HOME/.claude.json"
WORK="$(mktemp -d -t t4a-paste-form)" || exit 1
FIFO="$WORK/channel.fifo"
CONFIG_HOME="$WORK/config"
DUMPS="$WORK/dumps"
CHAT_DIR="$WORK/chat"
PNG="/tmp/prova paste t4a.png"
# Stable on purpose: Claude's Keychain credential is tied to this path.
CLAUDE_HOME="${T4A_BENCH_CLAUDE_HOME:-$HOME/.cache/t4a/bench-claude-home}"
STATUS=0
DUMP=""

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

active_screen_expr="next((p.get('screen',[]) for t in d.get('tabs',[]) if t.get('active') for p in t.get('panes',[]) if p.get('active')),[])"

screen_has() {
  local needle="$1"
  [ "$(field "any('$needle'.lower() in row.lower() for row in $active_screen_expr)")" = True ]
}

input_row() {
  /usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pane = next((p for t in d.get("tabs", []) if t.get("active")
             for p in t.get("panes", []) if p.get("active")), {})
screen = pane.get("screen", [])
index = pane.get("cursorRow", 0) - pane.get("topVisibleRow", 0)
row = screen[index] if 0 <= index < len(screen) else ""
print(json.dumps(row.strip(), ensure_ascii=False))
PY
}

cleanup() {
  t4a_stop_bench
  rm -f "$PNG"
  case "$(basename "$WORK")" in t4a-paste-form.*) rm -rf "$WORK";; esac
  t4a_bench_unlock
}
trap cleanup EXIT

not_run() {
  printf '%-10s %-38s %-8s %s\n' "$1" "$2" "NOT RUN" "$3"
  STATUS=1
}

mkdir -p "$CONFIG_HOME/t4a" "$DUMPS" "$CHAT_DIR" "$CLAUDE_HOME"
chmod 700 "$CLAUDE_HOME"
printf '%s\n' \
  'chat-page = false' \
  'composer-mode = never' \
  'show-turn-map = false' \
  'pure-chat = false' > "$CONFIG_HOME/t4a/config.toml"
/usr/bin/python3 Scripts/claude-config-copy.py \
  "$REAL_CLAUDE_CONFIG" "$CLAUDE_HOME/.claude.json"
cp Icon/icon-1024.png "$PNG"

printf '%-10s %-38s %-8s %s\n' "FORM" "PAYLOAD" "RESULT" "VISIBLE INPUT ROW"
printf '%-10s %-38s %-8s %s\n' "----" "-------" "------" "-----------------"

t4a_note_his_app
t4a_stop_bench
rm -f "$FIFO"
if ! open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" \
    --env XDG_CONFIG_HOME="$CONFIG_HOME" --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME"; then
  not_run ALL "-" "the test bundle could not be opened"
  exit "$STATUS"
fi
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
if [ ! -p "$FIFO" ]; then
  not_run ALL "-" "the test channel never appeared"
  exit "$STATUS"
fi
sleep 2

quoted_chat="$(printf '%q' "$CHAT_DIR")"
send "text cd $quoted_chat && claude"
send "key return"

# First-run prompts vary by Claude version. Answer only the two known local
# setup questions; a login screen is a precondition failure, never a red form.
ready=0
for _ in $(seq 1 90); do
  dump startup || break
  if screen_has "Yes, I trust this folder"; then
    send "key down"; send "key return"; sleep 0.5; continue
  fi
  if screen_has "Enter to confirm"; then
    send "key return"; sleep 0.5; continue
  fi
  if screen_has "Not logged in" || screen_has "/login"; then break; fi
  bracketed="$(field "next((p.get('bracketedPaste',False) for t in d.get('tabs',[]) if t.get('active') for p in t.get('panes',[]) if p.get('active')),False)")"
  process="$(field "next((p.get('process','') for t in d.get('tabs',[]) if t.get('active') for p in t.get('panes',[]) if p.get('active')),'')")"
  if [ "$bracketed" = True ] && [ -n "$process" ] && [ "$process" != zsh ]; then
    ready=$((ready + 1)); [ "$ready" -ge 2 ] && break
  else
    ready=0
  fi
  sleep 0.5
done

if [ "$ready" -lt 2 ]; then
  detail="Claude did not reach a bracketed-paste input line; log in once with CLAUDE_CONFIG_DIR=$CLAUDE_HOME claude /login"
  not_run A '"/tmp/prova paste t4a.png"' "$detail"
  not_run B '/tmp/prova\ paste\ t4a.png' "$detail"
  not_run C '/tmp/prova paste t4a.png' "$detail"
  exit "$STATUS"
fi

LONG="/tmp/prova con nome molto lungo davvero Screenshot 2026-08-31 alle 21.05.00 copia numero uno.png"
NSIRD="${TMPDIR%/}/TemporaryItems/NSIRD_probe/Screenshot 2026-08-31 alle 21.05.00.png"
NSHORT="${TMPDIR%/}/TemporaryItems/NSIRD_probe/c.png"
mkdir -p "${TMPDIR%/}/TemporaryItems/NSIRD_probe"
cp Icon/icon-1024.png "$LONG"; cp Icon/icon-1024.png "$NSIRD"; cp Icon/icon-1024.png "$NSHORT"
CACHE="$HOME/Library/Caches/T4A/pasted/paste-probe 2026.png"
mkdir -p "$HOME/Library/Caches/T4A/pasted"; cp Icon/icon-1024.png "$CACHE"
forms=(CACHE NSIRD)
payloads=("\"$CACHE\"" "\"$NSIRD\"")
for index in 0 1; do
  form="${forms[$index]}"
  payload="${payloads[$index]}"
  send "bracketed-paste $payload"
  sleep 2
  if ! dump "form-$form"; then
    not_run "$form" "$payload" "the render dump did not arrive"
    continue
  fi
  result=NO
  screen_has "[Image #" && result=YES
  # The cursor row is the hosted program's actual input row. Printing it as
  # JSON keeps even an honestly empty row controllable; a failed substring
  # search must never turn the evidence into `<no matching row>` again.
  row="$(input_row)"
  printf '%-10s %-8s %s\n' "$form" "$result" "$row"
  /usr/bin/python3 - "$DUMP" <<'PYX'
import json,sys
d=json.load(open(sys.argv[1]))
p=next((p for t in d.get("tabs",[]) if t.get("active") for p in t.get("panes",[]) if p.get("active")),{})
for r in [r for r in p.get("screen",[]) if r.strip()][-4:]: print("   |", r[:140])
PYX
  # A fresh prompt keeps the three readings independent without submitting a
  # turn. Claude handles Ctrl-C itself; no model request leaves this bench.
  send "key ctrl-c"
  sleep 1
done

exit "$STATUS"
