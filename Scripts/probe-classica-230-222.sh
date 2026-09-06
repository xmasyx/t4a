#!/bin/bash
# In griglia classica (sua config del 28/08 sera): ISC-230 (Esc durante un turno lungo → activity?)
# e ISC-222 (/model → nasce un turno?). Stampa e basta: il verdetto lo dà chi legge.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh
t4a_note_his_app
WORK=/tmp/t4a-classica-probe; CFG="$WORK/config"; FIFO="$WORK/channel.fifo"; DUMPS="$WORK/dumps"
rm -rf "$WORK"; mkdir -p "$CFG/t4a" "$DUMPS"
grep -v '^window-\|^settings-offset' ~/.config/t4a/config.toml > "$CFG/t4a/config.toml"
send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1" || return 1; }
dump() { local p="$DUMPS/$1.json"; rm -f "$p"; send "dump $p" || return 1; for _ in $(seq 1 40); do [ -s "$p" ] && return 0; sleep .25; done; return 1; }
campo() { /usr/bin/python3 - "$DUMPS/$1.json" "$2" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); p=[q for t in d["tabs"] for q in t["panes"] if q.get("active")][0]; s=p.get("screen") or []
 x="\n".join(s) if isinstance(s,list) else str(s); print(eval(sys.argv[2],{"d":d,"p":p,"x":x}))
except Exception as e: print("missing:%s"%type(e).__name__)
PY
}
stato() { echo "$1: activity=$(campo $2 "p['activity']") turns=$(campo $2 "p.get('turns')") waiting=$(campo $2 "d.get('waiting', d.get('rail',{}).get('waiting'))") tabState=$(campo $2 "[t.get('state', t.get('activity')) for t in d['tabs']]")"; }
open -n "${BUNDLE:-dist/T4A.app}" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep .25; done
[ -p "$FIFO" ] || { echo "FAIL: nessun canale"; exit 1; }
sleep 1.5; send activate; send "text cd $HOME/Movies/t4a-bench-chat && claude"; send "key return"
ok=0; for _ in $(seq 1 45); do dump rr || true; [ "$(campo rr "'? for shortcuts' in x or 'mode on' in x or 'for agents' in x")" = True ] && { ok=1; break; }; sleep 2; done
[ "$ok" = 1 ] || { echo "FAIL: claude non pronto"; t4a_stop_bench; exit 1; }
sleep 3; send scan; dump s0; stato "S0 aggancio" s0
echo "--- chiavi di primo livello del dump: $(campo s0 "sorted(d.keys())")"
send "text prova"; send "key return"
w=0; for _ in $(seq 1 90); do dump wt || true; [ "$(campo wt "p['activity']")" = waiting ] && { w=1; break; }; sleep 1; done
[ "$w" = 1 ] || { echo "FAIL: turno mai finito"; t4a_stop_bench; exit 1; }
sleep 1; send scan; dump s1; stato "S1 dopo «prova»" s1
# ISC-222: /model → turno?
send "text /model"; send "key return"; sleep 1.5; send "key escape"; sleep 2; send scan; dump s2; stato "S2 dopo /model+Esc (menu chiuso)" s2
send "text /model"; send "key return"; sleep 1.5; send "key down"; sleep .3; send "text s"; sleep 1.5; send "text 1"; sleep 3; send scan; dump s3; stato "S3 dopo /model → altro modello" s3
# ISC-230: turno lungo + Esc
send "text Scrivi i numeri da 1 a 1500, uno per riga, senza usare strumenti e senza spiegazioni."; send "key return"; sleep 5; send scan; dump s4; stato "S4 turno lungo in corso" s4
send "key escape"; sleep 2; send scan; dump s5; stato "S5 +2 s dopo Esc" s5
sleep 6; send scan; dump s6; stato "S6 +8 s dopo Esc" s6
echo "S6 schermo, ultime righe:"; campo s6 "'\n'.join(repr(l) for l in (p.get('screen') or []) if l.strip())[-500:]"
sleep 10; send scan; dump s7; stato "S7 +18 s dopo Esc" s7
send "text /exit"; send "key return"; sleep 3; t4a_stop_bench
