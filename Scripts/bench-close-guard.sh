#!/bin/bash
# ISC-107 — does ⌘W ask before it kills something that is working?
#
#   Scripts/bench-close-guard.sh [app-bundle]
#
# I poli, in una corsa sola e in quest'ordine:
#   * una shell ferma si chiude senza dire niente — una guardia che chiede di
#     tutto è una guardia che nessuno legge;
#   * un pannello con `vim` davanti alla shell chiede, sopravvive a "Cancel",
#     e muore solo su "Close anyway";
#   * il bottone rosso (`performClose`) fa la stessa domanda, perché il
#     riflesso che chiude una finestra è quello che chiude un pannello;
#   * e un `claude` AGGANCIATO ma FERMO si chiude in silenzio (sua regola,
#     26/08: la domanda vale solo se un agente sta ancora lavorando). Il polo
#     legge `attached` dal dump prima di concludere: senza, un «non ha
#     chiesto» starebbe in piedi anche se l'aggancio non fosse mai avvenuto,
#     che è il verde per la ragione sbagliata.
#
# Everything is read from the app's own live objects: how many panes are left,
# what the foreground process is, whether a sheet is up.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-close.fifo"
CONFIG_HOME="/tmp/t4a-close-config"
DUMP=/tmp/t4a-close-dump.json

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
snap() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 30); do [ -s "$DUMP" ] && break; sleep 0.1; done
  /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
panes = sum(len(t['panes']) for t in d['tabs'])
print(f\"tabs={len(d['tabs'])} panes={panes} asking={d['window']['askingToClose']} foreground={d['foreground']}\")
"
}

agentsnap() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 30); do [ -s "$DUMP" ] && break; sleep 0.1; done
  /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
pane = d['tabs'][d['window'].get('activeTab', -1)]['panes'][0] if False else \
       [p for t in d['tabs'] for p in t['panes']][-1]
print(f\"attached={pane.get('attached')} activity={pane.get('activity')} \"
      f\"process={pane.get('process')} interrupts={pane.get('interrupts') or '-'}\")
"
}

t4a_stop_bench
sleep 1
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3

echo "==> pole 1: an idle shell"
send "newtab"; sleep 3
echo "    before ⌘W:  $(snap)"
send "closepane-ask"; sleep 1.5
IDLE="$(snap)"
echo "    after  ⌘W:  $IDLE"

echo "==> polo 2: vim nel pannello, che non è un agente"
send "newtab"; sleep 3
send "text vim"; send "key return"
echo "    aspetto il TUI"
sleep 4
echo "    before ⌘W:  $(snap)"
send "closepane-ask"; sleep 1.5
ASKED="$(snap)"
echo "    after  ⌘W:  $ASKED"
Scripts/drive.sh shot design/evidence/f2-close-guard.png >/dev/null 2>&1 || true

send "answer no"; sleep 1.5
CANCELLED="$(snap)"
echo "    after Cancel: $CANCELLED"

echo "==> pole 3: the red button, same pane"
send "closewindow"; sleep 1.5
REDBUTTON="$(snap)"
echo "    after red button: $REDBUTTON"
send "answer no"; sleep 1

echo "==> e adesso sì"
sleep 1
send "closepane-ask"; sleep 2.5
send "answer yes"; sleep 3
CLOSED="$(snap)"
echo "    after Close anyway: $CLOSED"

echo "==> polo 4: claude agganciato e FERMO si chiude senza domande"
send "newtab"; sleep 3
send "text cd $(pwd) && claude"; send "key return"
echo "    aspetto che l'agente si agganci"
sleep 14
AGENT="$(agentsnap)"
echo "    prima di ⌘W:  $AGENT"
send "closepane-ask"; sleep 2
QUIET="$(snap)"
echo "    dopo  ⌘W:  $QUIET"

echo "==> polo 5: e un agente che STA LAVORANDO chiede eccome"
send "newtab"; sleep 3
send "text cd $(pwd) && ANTHROPIC_MODEL=claude-haiku-4-5-20251001 claude"
send "key return"; sleep 16
# Niente strumenti: una risposta lunga tiene l'agente su `working` senza
# chiedere un permesso, e un permesso aperto sarebbe `waiting`, cioè il polo
# opposto a quello che serve qui.
# Dalla BOLLA, non dal PTY: con un agente agganciato la riga d'ingresso è la
# bolla, e un `text` scritto nel tty mentre il TUI si sta ancora impaginando
# viene ingoiato senza lasciare traccia (misurato: turns=0 per venti secondi).
send "compose Scrivi i numeri da 1 a 400, uno per riga, senza usare strumenti."
sleep 1
send "composer-send"
echo "    aspetto che parta il lavoro"
# Si campiona finché non si vede `working`, invece di sperare che un `sleep`
# fisso cada dentro la finestra giusta: un campione solo, preso troppo presto
# o troppo tardi, direbbe `idle` in entrambi i casi.
WORKING=""
for _ in $(seq 1 20); do
  sleep 1
  WORKING="$(agentsnap)"
  case "$WORKING" in *"activity=working"*) break;; esac
done
echo "    mentre lavora:  $WORKING"
/usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
for ti,t in enumerate(d['tabs']):
    for pi,p in enumerate(t['panes']):
        print(f'      tab{ti} pane{pi} proc={p.get(\"process\")} attached={p.get(\"attached\")} act={p.get(\"activity\")} turns={len(p.get(\"turns\",[]))} rows={p.get(\"endRow\")}')
"
send "closepane-ask"; sleep 2
ASKEDAGENT="$(snap)"
echo "    dopo  ⌘W:  $ASKEDAGENT"
send "answer no"; sleep 1

t4a_stop_bench
rm -f "$FIFO"

/usr/bin/python3 - "$IDLE" "$ASKED" "$CANCELLED" "$REDBUTTON" "$CLOSED" "$AGENT" "$QUIET" "$WORKING" "$ASKEDAGENT" <<'PY'
import sys
idle, asked, cancelled, red, closed, agent, quiet, working, askedagent = sys.argv[1:10]
def field(line, key):
    for part in line.split():
        if part.startswith(key + "="): return part[len(key) + 1:]
    return ""
ok = True
def check(label, condition, detail):
    global ok
    ok = ok and condition
    print(f"{'PASS' if condition else 'FAIL'}  {label}: {detail}")

check("an idle shell closed with no question",
      field(idle, "asking") == "False" and field(idle, "tabs") == "1", idle)
check("vim in front made ⌘W ask", field(asked, "asking") == "True", asked)
check("the pane survived the question", field(asked, "tabs") == "2", asked)
check("Cancel kept the pane and dismissed the sheet",
      field(cancelled, "asking") == "False" and field(cancelled, "tabs") == "2", cancelled)
check("the red button asked too", field(red, "asking") == "True", red)
check("Close anyway closed it", field(closed, "tabs") == "1", closed)
# I due poli della regola nuova, e vanno letti insieme: senza `attached=True`
# il silenzio del secondo non prova niente.
check("l'agente si è agganciato ed è fermo",
      field(agent, "attached") == "True" and field(agent, "activity") != "working"
      and field(agent, "interrupts") == "-", agent)
check("un agente fermo si chiude senza domande",
      field(quiet, "asking") == "False" and field(quiet, "tabs") == "1", quiet)
check("l'agente sta davvero lavorando", field(working, "activity") == "working", working)
check("un agente che lavora fa chiedere", field(askedagent, "asking") == "True", askedagent)
sys.exit(0 if ok else 1)
PY
