#!/bin/bash
# Punti 1 e 2 della sua lista del 29/08 mattina, sulla SUA configurazione con claude VERO e loggato:
# 1) due claude nella stessa cartella: la seconda non prende i turni della prima; poi contano separati
# 2) la shell di un pannello (e il claude che ci gira dentro) non portano i nostri descrittori
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh
t4a_note_his_app
WORK=/tmp/t4a-fratelli-sua; CFG="$WORK/config"; FIFO="$WORK/channel.fifo"; DUMPS="$WORK/dumps"
rm -rf "$WORK"; mkdir -p "$CFG/t4a" "$DUMPS"
grep -v '^window-\|^settings-offset' ~/.config/t4a/config.toml > "$CFG/t4a/config.toml"
send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1" || return 1; }
dump() { local p="$DUMPS/$1.json"; rm -f "$p"; send "dump $p" || return 1; for _ in $(seq 1 40); do [ -s "$p" ] && return 0; sleep .25; done; return 1; }
q() { /usr/bin/python3 - "$DUMPS/$1.json" "$2" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); print(eval(sys.argv[2],{"d":d}))
except Exception as e: print("missing:%s"%type(e).__name__)
PY
}
ready() { local t="$1" ok=0; for _ in $(seq 1 45); do dump rr || true; x="$(q rr "'\n'.join(d['tabs'][$t]['panes'][0].get('screen') or [])")"; case "$x" in *"? for shortcuts"*|*"mode on"*|*"for agents"*) ok=1; break;; esac; sleep 2; done; [ "$ok" = 1 ]; }
waitidle() { local a="$1"; for _ in $(seq 1 90); do dump wt || true; [ "$(q wt "d['agents'][$a]['adapter'].get('activity')")" = waiting ] && return 0; sleep 1; done; return 1; }
open -n "${BUNDLE:-dist/T4A.app}" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep .25; done
[ -p "$FIFO" ] || { echo "FAIL: nessun canale"; exit 1; }
sleep 1.5; send activate
send "text cd $HOME/Movies/t4a-bench-chat && claude"; send "key return"; ready 0 || { echo "FAIL: A non pronta"; t4a_stop_bench; exit 1; }
sleep 2; send "text prova"; send "key return"; waitidle 0 || { echo "FAIL: A turno mai finito"; t4a_stop_bench; exit 1; }
sleep 1; dump a1; echo "A dopo «prova»: following=$(q a1 "d['agents'][0]['adapter']['following']") turns=$(q a1 "d['agents'][0]['adapter']['turns']") source=$(q a1 "d['agents'][0]['adapter'].get('transcriptSource')")"
send newtab; sleep 1; send activate; send "text cd $HOME/Movies/t4a-bench-chat && claude"; send "key return"; ready 1 || { echo "FAIL: B non pronta"; t4a_stop_bench; exit 1; }
sleep 4; send scan; dump b0
echo "B senza messaggi: following=[$(q b0 "d['agents'][1]['adapter']['following']")] turns=$(q b0 "d['agents'][1]['adapter']['turns']") reason=[$(q b0 "d['agents'][1]['adapter'].get('transcriptReason')")]"
echo "A intanto: following=$(q b0 "d['agents'][0]['adapter']['following']") turns=$(q b0 "d['agents'][0]['adapter']['turns']")"
send "text prova"; send "key return"; waitidle 1 || { echo "FAIL: B turno mai finito"; t4a_stop_bench; exit 1; }
sleep 1; dump b1
echo "B dopo «prova»: following=$(q b1 "d['agents'][1]['adapter']['following']") turns=$(q b1 "d['agents'][1]['adapter']['turns']") source=$(q b1 "d['agents'][1]['adapter'].get('transcriptSource')")"
echo "A dopo B: following=$(q b1 "d['agents'][0]['adapter']['following']") turns=$(q b1 "d['agents'][0]['adapter']['turns']")"
FA="$(q b1 "d['agents'][0]['adapter']['following']")"; FB="$(q b1 "d['agents'][1]['adapter']['following']")"
# punto 2: shell nuda in una terza scheda + il claude di A
send newtab; sleep 2; dump c0; SH="$(q c0 "d['tabs'][2]['panes'][0]['pid']")"; A_SH="$(q c0 "d['tabs'][0]['panes'][0]['pid']")"; A_CL="$(pgrep -P "$A_SH" | head -1)"
echo "shell scheda 3 pid=$SH: righe ptmx/fifo/door = $(lsof -p "$SH" 2>/dev/null | grep -c 'ptmx\|\.fifo\|/door')"
echo "claude di A pid=${A_CL:-?}: righe ptmx/fifo/door = $(lsof -p "${A_CL:-0}" 2>/dev/null | grep -c 'ptmx\|\.fifo\|/door')"
lsof -p "$SH" 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]+[rwu]$/ {print "   fd "$4" "$5" "$NF}' | head -8
send "text /exit"; send "key return"; sleep 2; t4a_stop_bench
[ -n "$FA" ] && [ -n "$FB" ] && [ "$FA" != "$FB" ] && echo "SUMMARY punto 1: PASS (A=$FA B=$FB)" || { echo "SUMMARY punto 1: FAIL"; exit 1; }
