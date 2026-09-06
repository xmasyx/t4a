#!/bin/bash
# ISC-237 — a tab says whether its chat works, finished, or needs a decision;
# «N waiting» takes you to the exact session counted.
#
#   Scripts/bench-segni.sh [--head <bundle>]
#
# The agents are deterministic local `codex` processes. Each holds a
# real rollout open under CODEX_HOME, so T4A's production adapter attributes
# and tails it through the kernel just as it does a live Codex session. No
# account, network, or vendor configuration is touched.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh

APP="${T4A_APP:-dist/T4A.app}"
HEAD=""
STATUS=0
LOCK_RELEASED=0
WORK="$(mktemp -d /tmp/t4a-segni-bench.XXXXXX)"
RUN_ROOT=""
FIFO=""
DUMP=""
FAKE="$WORK/fake"

usage() { echo "usage: Scripts/bench-segni.sh [--head <bundle>]" >&2; }
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
  [ "$LOCK_RELEASED" -eq 1 ] || t4a_bench_unlock
}
trap cleanup EXIT INT TERM

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  local name="$1"
  DUMP="$RUN_ROOT/$name.json"
  rm -f "$DUMP"
  send "dump $DUMP" || return 1
  for _ in $(seq 1 100); do [ -s "$DUMP" ] && return 0; sleep .05; done
  echo "dump $name never arrived"
  return 1
}
value() {
  /usr/bin/python3 - "$DUMP" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
try:
    value = eval(sys.argv[2], {"__builtins__": {}, "len": len, "all": all}, {"d": d})
    if isinstance(value, bool): print("true" if value else "false")
    elif isinstance(value, (list, dict)): print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    else: print(value)
except Exception as error:
    print("missing:" + type(error).__name__)
PY
}
pole() {
  local label="$1" result="$2" detail="$3"
  if [ "$result" -eq 0 ]; then
    printf 'PASS  %-42s %s\n' "$label" "$detail"
  else
    printf 'FAIL  %-42s %s\n' "$label" "$detail"
    STATUS=1
  fi
}
not_run() { printf 'NOT RUN  %-39s %s\n' "$1" "$2"; }

wait_for() {
  local name="$1" expression="$2" rounds="${3:-100}"
  for _ in $(seq 1 "$rounds"); do
    dump "$name" || continue
    /usr/bin/python3 - "$DUMP" "$expression" <<'PY' && return 0
import json, sys
d = json.load(open(sys.argv[1]))
try: result = bool(eval(sys.argv[2], {"__builtins__": {}, "len": len, "all": all}, {"d": d}))
except Exception: result = False
raise SystemExit(0 if result else 1)
PY
    sleep .1
  done
  return 1
}

mkdir -p "$FAKE"
FAKE_SOURCE="$WORK/fake-codex.c"
/usr/bin/python3 - "$FAKE_SOURCE" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(r'''
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) return 3;
    if (strcmp(argv[2], "decision") == 0) {
        const char prompt[] = "Do you want to proceed?\n"
            "\342\235\257 1. Yes\n  2. No\n"
            "Enter to confirm \302\267 Esc to cancel";
        write(STDOUT_FILENO, prompt, sizeof(prompt) - 1);
    }
    for (;;) pause();
}
''')
PY
if ! /usr/bin/clang -O2 "$FAKE_SOURCE" -o "$FAKE/codex"; then
  echo "the deterministic codex fixture did not compile" >&2
  exit 1
fi

write_rollout() {
  local file="$1" cwd="$2" state="$3" title="$4"
  /usr/bin/python3 - "$file" "$cwd" "$state" "$title" <<'PY'
import json, pathlib, sys
path, cwd, state, title = sys.argv[1:]
rows = [
    {"timestamp":"2026-08-30T20:00:00Z","type":"session_meta",
     "payload":{"cwd":cwd,"model":"gpt-5.6-sol"}},
    {"timestamp":"2026-08-30T20:00:01Z","type":"event_msg",
     "payload":{"type":"user_message","message":title}},
]
if state == "finished":
    rows.append({"timestamp":"2026-08-30T20:00:02Z","type":"event_msg",
                 "payload":{"type":"task_complete","last_agent_message":"done"}})
p = pathlib.Path(path); p.parent.mkdir(parents=True, exist_ok=True)
p.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))
PY
}

append_event() {
  local file="$1" kind="$2" message="$3"
  /usr/bin/python3 - "$file" "$kind" "$message" <<'PY'
import json, sys
path, kind, message = sys.argv[1:]
payload = ({"type":"user_message","message":message} if kind == "working"
           else {"type":"task_complete","last_agent_message":message})
with open(path, "a") as out:
    out.write(json.dumps({"timestamp":"2026-08-30T20:10:00Z",
                          "type":"event_msg","payload":payload},
                         separators=(",", ":")) + "\n")
PY
}

launch() {
  local bundle="$1" label="$2"
  t4a_stop_bench
  RUN_ROOT="$WORK/$label"
  FIFO="$RUN_ROOT/channel.fifo"
  DUMP="$RUN_ROOT/dump.json"
  local config="$RUN_ROOT/config" codex_home="$RUN_ROOT/codex-home"
  mkdir -p "$config/t4a" "$codex_home/sessions/$(date +%Y/%m/%d)"
  /usr/bin/python3 - "$config/t4a/config.toml" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text(
    "agent-adapter = true\ncomposer-mode = never\nmotion = true\ntheme = black\n")
PY
  [ -x "$bundle/Contents/MacOS/T4A" ] || return 1
  open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" \
    --env XDG_CONFIG_HOME="$config" --env CODEX_HOME="$codex_home"
  for _ in $(seq 1 80); do [ -p "$FIFO" ] && break; sleep .25; done
  [ -p "$FIFO" ] || return 1
  sleep 2
  send activate
  send "layout tabs"
  sleep .5
  echo "bundle=$bundle"
  echo "channel=$FIFO"
}

rollout_path() {
  echo "$RUN_ROOT/codex-home/sessions/$(date +%Y/%m/%d)/rollout-segni-$1.jsonl"
}

start_chat() {
  local index="$1" state="$2" mode="$3" title="$4"
  local cwd="$RUN_ROOT/chat-$index" rollout
  mkdir -p "$cwd"
  rollout="$(rollout_path "$index")"
  write_rollout "$rollout" "$cwd" "$state" "$title"
  [ "$index" -eq 0 ] || { send newtab; sleep .4; }
  send "text cd $cwd && exec $FAKE/codex $rollout $mode"
  send "key return"
  wait_for "attach-$index" \
    "len(d['tabs']) > $index and d['tabs'][$index]['panes'][0].get('attached') is True" 140
}

echo "=== ISC-237 · current bundle ========================================"
if ! launch "$APP" current; then
  CAUSE="bundle non avviato o canale di prova assente (LaunchServices/WindowServer): $APP"
  not_run "S0 tre segni distinti" "$CAUSE"
  not_run "S1 salto diretto" "$CAUSE"
  not_run "S2 menu con due righe" "$CAUSE"
  not_run "S3 zero non muove" "$CAUSE"
  not_run "S4 quiete per 5 s" "$CAUSE"
  not_run "S5 Reduce Motion" "$CAUSE"
  if [ -z "$HEAD" ]; then
    not_run "S6 negativo su HEAD" "nessun --head <bundle> fornito"
  else
    not_run "S6 negativo su HEAD" "$CAUSE"
  fi
  not_run "S7 visto spegne" "$CAUSE"
  not_run "S8 nuovo fine-turno riaccende" "$CAUSE"
  not_run "S9 decisione sopravvive alla vista" "$CAUSE"
  exit 1
fi

start_chat 0 working work "Working chat" || STATUS=1
start_chat 1 working rest "Finished chat" || STATUS=1
start_chat 2 working decision "Decision chat" || STATUS=1
# The finished chat must finish while another tab is selected. Attaching an
# already-finished transcript in its own focused pane is now correctly born
# seen, so it would no longer be an honest S0 fixture.
append_event "$(rollout_path 1)" finished "Finished chat done elsewhere"
send scan
wait_for s0 "[m['kind'] for m in d['band']['strip']['marks']] == ['working','finished','decision']" 120 || true

echo
echo "--- S0 controllo: i tre segni ---------------------------------------"
dump s0
S0_MARKS="$(value "d['band']['strip']['marks']")"
S0_STATES="$(value "[[p['activity'] for p in t['panes']] for t in d['tabs']]")"
/usr/bin/python3 - "$DUMP" <<'PY'; CHECK=$?
import json, sys
d=json.load(open(sys.argv[1])); marks=d["band"]["strip"].get("marks", [])
raise SystemExit(0 if [m.get("kind") for m in marks] ==
                 ["working", "finished", "decision"] and
                 [m.get("shape") for m in marks] ==
                 ["gap-ring", "solid-dot", "number-circle"] else 1)
PY
pole "S0 lavora / finita / decisione" "$CHECK" "activity=$S0_STATES marks=$S0_MARKS"

echo
echo "--- S2 menu: due attese, seconda riga -------------------------------"
send "selecttab 0"
wait_for s2-count "d['waiting'] == 2" 80 || true
RESPONDER_BEFORE="$(value "d['composer']['firstResponder']")"
send waiting-press
wait_for s2-open "d['waitingMenu']['shown'] is True and len(d['waitingMenu']['rows']) == 2" 50 || true
ROWS="$(value "d['waitingMenu']['rows']")"
RESPONDER_OPEN="$(value "d['composer']['firstResponder']")"
send waiting-dismiss
sleep .2; dump s2-dismiss
RESPONDER_AFTER="$(value "d['composer']['firstResponder']")"
[ "$RESPONDER_BEFORE" = "$RESPONDER_OPEN" ] && [ "$RESPONDER_BEFORE" = "$RESPONDER_AFTER" ]; CHECK=$?
pole "S2 chiudere non ruba la tastiera" "$CHECK" "before=$RESPONDER_BEFORE open=$RESPONDER_OPEN after=$RESPONDER_AFTER"
send waiting-press
wait_for s2-reopen "d['waitingMenu']['shown'] is True" 30 || true
send "waiting-choose 1"
wait_for s2-chosen "d['tabs'][2]['active'] is True and d['tabs'][2]['panes'][0]['active'] is True" 50 || true
/usr/bin/python3 - "$DUMP" <<'PY'; CHECK=$?
import json, sys
d=json.load(open(sys.argv[1]))
raise SystemExit(0 if len(d["waitingMenu"]["rows"]) == 0 and
                 d["tabs"][2]["active"] and d["tabs"][2]["panes"][0]["active"] else 1)
PY
pole "S2 menu con 2 righe, scelta seconda" "$CHECK" "rows=$ROWS selected=$(value "d['band']['strip']['selected']")"

echo
echo "--- S1 salto diretto: una sola attesa -------------------------------"
send clearbuffer
send scan
append_event "$(rollout_path 2)" working "Decision handled; working again"
wait_for s1-ready "d['waiting'] == 1 and d['tabs'][2]['panes'][0]['activity'] == 'working'" 100 || true
send waiting-press
wait_for s1-jump "d['tabs'][1]['active'] is True and d['tabs'][1]['panes'][0]['active'] is True" 50 || true
/usr/bin/python3 - "$DUMP" <<'PY'; CHECK=$?
import json, sys
d=json.load(open(sys.argv[1]))
raise SystemExit(0 if d["waiting"] == 0 and d["tabs"][1]["active"] and
                 d["tabs"][1]["panes"][0]["active"] and
                 not d["waitingMenu"]["shown"] else 1)
PY
pole "S1 click porta all'unica sessione" "$CHECK" "selected=$(value "d['band']['strip']['selected']") paneActive=$(value "d['tabs'][1]['panes'][0]['active']") menu=$(value "d['waitingMenu']['shown']")"

echo
echo "--- S3 zero: il click non muove -------------------------------------"
dump s3-before
BEFORE="$(value "d['band']['strip']['selected']")"
send waiting-press
sleep .3; dump s3-after
AFTER="$(value "d['band']['strip']['selected']")"
COUNT="$(value "d['waiting']")"
[ "$COUNT" = 0 ] && [ "$BEFORE" = "$AFTER" ]; CHECK=$?
pole "S3 zero non cambia scheda" "$CHECK" "waiting=$COUNT selected=$BEFORE->$AFTER"

echo
echo "--- S4 quiete: cinque secondi senza ridisegni -----------------------"
append_event "$(rollout_path 0)" finished "Working chat done"
append_event "$(rollout_path 2)" finished "Decision chat done"
wait_for s4-ready "all(m['kind'] != 'working' for m in d['band']['strip']['marks']) and not d['band']['strip']['workAnimationActive']" 100 || true
sleep .3
dump s4-baseline
REDRAWS_BEFORE="$(value "d['band']['strip']['redrawCount']")"
sleep 5
dump s4-after
REDRAWS_AFTER="$(value "d['band']['strip']['redrawCount']")"
[ "$REDRAWS_BEFORE" = "$REDRAWS_AFTER" ]; CHECK=$?
pole "S4 striscia quieta per 5 s" "$CHECK" "redrawCount=$REDRAWS_BEFORE->$REDRAWS_AFTER animation=$(value "d['band']['strip']['workAnimationActive']")"

echo
echo "--- S5 Reduce Motion: anello fermo, non pallino ---------------------"
append_event "$(rollout_path 0)" working "Working under reduced motion"
wait_for s5-working "d['band']['strip']['marks'][0]['kind'] == 'working'" 100 || true
send "reduce-motion on"
wait_for s5-reduced "d['band']['strip']['reducedMotion'] is True and not d['band']['strip']['workAnimationActive']" 50 || true
S5_MARKS="$(value "d['band']['strip']['marks']")"
/usr/bin/python3 - "$DUMP" <<'PY'; CHECK=$?
import json, sys
d=json.load(open(sys.argv[1])); strip=d["band"]["strip"]; marks=strip["marks"]
raise SystemExit(0 if strip["reducedMotion"] and not strip["workAnimationActive"] and
                 marks[0]["kind"] == "working" and marks[0]["shape"] == "gap-ring" and
                 marks[0]["animated"] is False and marks[2]["shape"] == "solid-dot" else 1)
PY
pole "S5 lavora fermo e distinto" "$CHECK" "marks=$S5_MARKS reduced=$(value "d['band']['strip']['reducedMotion']")"
send "reduce-motion system"

echo
echo "--- S7 visto: selezionare spegne pallino e waiting ------------------"
wait_for s7-before "d['waiting'] == 1 and d['band']['strip']['marks'][2]['kind'] == 'finished' and d['tabs'][2]['panes'][0]['finishedTurnSeen'] is False" 80 || true
S7_BEFORE="waiting=$(value "d['waiting']") mark=$(value "d['band']['strip']['marks'][2]['kind']") seen=$(value "d['tabs'][2]['panes'][0]['finishedTurnSeen']")"
send "selecttab 2"
wait_for s7-seen "d['waiting'] == 0 and d['band']['strip']['marks'][2]['kind'] == 'none' and d['tabs'][2]['panes'][0]['finishedTurnSeen'] is True" 50 || true
send "selecttab 0"
wait_for s7-left "d['tabs'][0]['active'] is True and d['waiting'] == 0 and d['band']['strip']['marks'][2]['kind'] == 'none' and d['tabs'][0]['panes'][0]['finishedTurnSeen'] is False" 50 || true
/usr/bin/python3 - "$DUMP" <<'PY'; CHECK=$?
import json, sys
d=json.load(open(sys.argv[1])); pane=d["tabs"][2]["panes"][0]
raise SystemExit(0 if d["tabs"][0]["active"] and d["waiting"] == 0 and
                 d["band"]["strip"]["marks"][2]["kind"] == "none" and
                 pane["activity"] == "waiting" and pane["finishedTurnSeen"] and
                 not d["tabs"][0]["panes"][0]["finishedTurnSeen"] else 1)
PY
pole "S7 visita spegne e resta spenta" "$CHECK" "$S7_BEFORE -> waiting=$(value "d['waiting']") mark=$(value "d['band']['strip']['marks'][2]['kind']") seen=$(value "d['tabs'][2]['panes'][0]['finishedTurnSeen']")"

echo
echo "--- S8 nuovo fine-turno: l'attenzione si riaccende ------------------"
append_event "$(rollout_path 2)" working "A new turn starts"
wait_for s8-working "d['tabs'][2]['panes'][0]['activity'] == 'working' and d['band']['strip']['marks'][2]['kind'] == 'working'" 100 || true
append_event "$(rollout_path 2)" finished "The new turn finished elsewhere"
wait_for s8-finished "d['waiting'] == 1 and d['band']['strip']['marks'][2]['kind'] == 'finished' and d['tabs'][2]['panes'][0]['finishedTurnSeen'] is False" 100 || true
/usr/bin/python3 - "$DUMP" <<'PY'; CHECK=$?
import json, sys
d=json.load(open(sys.argv[1])); pane=d["tabs"][2]["panes"][0]
raise SystemExit(0 if d["waiting"] == 1 and
                 d["band"]["strip"]["marks"][2]["kind"] == "finished" and
                 pane["activity"] == "waiting" and not pane["finishedTurnSeen"] else 1)
PY
pole "S8 nuovo fine-turno riaccende" "$CHECK" "waiting=$(value "d['waiting']") mark=$(value "d['band']['strip']['marks'][2]['kind']") seen=$(value "d['tabs'][2]['panes'][0]['finishedTurnSeen']")"

# Consume S8 before the approval pole, so its exact count can be one.
send "selecttab 2"
wait_for s9-clean "d['waiting'] == 0 and d['band']['strip']['marks'][2]['kind'] == 'none'" 50 || true

echo
echo "--- S9 decisione: vista o lasciata, aspetta ancora ------------------"
start_chat 3 working decision "Viewed decision chat" || STATUS=1
send scan
wait_for s9-viewed "d['tabs'][3]['active'] is True and d['band']['strip']['marks'][3]['kind'] == 'decision' and d['waiting'] == 1" 100 || true
S9_VIEWED="waiting=$(value "d['waiting']") mark=$(value "d['band']['strip']['marks'][3]['kind']") selected=$(value "d['band']['strip']['selected']")"
send "selecttab 0"
wait_for s9-left "d['tabs'][0]['active'] is True and d['band']['strip']['marks'][3]['kind'] == 'decision' and d['waiting'] == 1" 50 || true
/usr/bin/python3 - "$DUMP" <<'PY'; CHECK=$?
import json, sys
d=json.load(open(sys.argv[1])); mark=d["band"]["strip"]["marks"][3]
pane=d["tabs"][3]["panes"][0]
raise SystemExit(0 if d["tabs"][0]["active"] and d["waiting"] == 1 and
                 mark["kind"] == "decision" and mark["decisions"] == 1 and
                 pane["waitingForYou"] else 1)
PY
pole "S9 decisione vista resta contata" "$CHECK" "$S9_VIEWED -> waiting=$(value "d['waiting']") mark=$(value "d['band']['strip']['marks'][3]['kind']") selected=$(value "d['band']['strip']['selected']")"

echo
echo "--- S6 negativo c-bis su HEAD ---------------------------------------"
if [ -z "$HEAD" ]; then
  not_run "S6 HEAD: vista lascia il pallino" "nessun --head <bundle> fornito"
elif ! launch "$HEAD" head; then
  not_run "S6 HEAD: vista lascia il pallino" "bundle o canale di prova non disponibile: $HEAD"
  STATUS=1
else
  start_chat 0 working work "HEAD finished chat" || true
  start_chat 1 working rest "HEAD other chat" || true
  append_event "$(rollout_path 0)" finished "HEAD finished elsewhere"
  wait_for s6-before "d['waiting'] == 1 and d['band']['strip']['marks'][0]['kind'] == 'finished'" 120 || true
  send "selecttab 0"
  wait_for s6-viewed "d['tabs'][0]['active'] is True" 40 || true
  send "selecttab 1"
  wait_for s6-left "d['tabs'][1]['active'] is True and d['waiting'] == 1 and d['band']['strip']['marks'][0]['kind'] == 'finished'" 60 || true
  /usr/bin/python3 - "$DUMP" <<'PY'; CHECK=$?
import json, sys
d=json.load(open(sys.argv[1])); pane=d["tabs"][0]["panes"][0]
# 7c319b3 carries ISC-237 but predates c-bis: returning from the finished tab
# makes both the dot and the waiting entry come back.
raise SystemExit(0 if d["tabs"][1]["active"] and d["waiting"] == 1 and
                 d["band"]["strip"]["marks"][0]["kind"] == "finished" and
                 pane["activity"] == "waiting" else 1)
PY
  pole "S6 HEAD conserva il difetto c-bis" "$CHECK" "waiting=$(value "d['waiting']") mark=$(value "d['band']['strip']['marks'][0]['kind']") selected=$(value "d['band']['strip']['selected']")"
fi

echo
[ "$STATUS" -eq 0 ] && echo "bench-segni: all executed poles held" \
  || echo "bench-segni: SOMETHING FAILED"
exit "$STATUS"
