#!/bin/bash
# Suo video 28/08 22:50: dopo il SECONDO cambio modello la tastiera non torna nella bolla.
# Riproduce con la SUA configurazione e claude vero: turno «prova», poi /model → scelta → (conferma
# «Switch model?» → 1) due volte, e legge composer.firstResponder dopo ogni giro. Poli: R1 e R2
# devono essere ComposerField. Modello scelto con «s» (solo sessione) per non toccare settings.json.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh
t4a_note_his_app
WORK=/tmp/t4a-tastiera-probe; CFG="$WORK/config"; FIFO="$WORK/channel.fifo"; DUMPS="$WORK/dumps"
rm -rf "$WORK"; mkdir -p "$CFG/t4a" "$DUMPS"
grep -v '^window-\|^settings-offset' ~/.config/t4a/config.toml > "$CFG/t4a/config.toml"
send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1" || { echo "invio rifiutato: $1" >&2; return 1; }; }
dump() { local p="$DUMPS/$1.json"; rm -f "$p"; send "dump $p" || return 1; for _ in $(seq 1 40); do [ -s "$p" ] && return 0; sleep .25; done; echo "dump $1 mai arrivato" >&2; return 1; }
campo() { /usr/bin/python3 - "$DUMPS/$1.json" "$2" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); p=[q for t in d["tabs"] for q in t["panes"] if q.get("active")][0]; s=p.get("screen") or []
 x="\n".join(s) if isinstance(s,list) else str(s); print(eval(sys.argv[2],{"d":d,"p":p,"x":x}))
except Exception as e: print("missing:%s"%type(e).__name__)
PY
}
stato() { echo "$1: responder=$(campo $2 "d['composer']['firstResponder']") page=$(campo $2 "d['chatPage']['showing']") asking=$(campo $2 "p.get('asking')") inputBox=$(campo $2 "p.get('inputBoxSeen')") refusal=$(campo $2 "repr(d['composer'].get('refusal'))")"; }
open -n "${BUNDLE:-dist/T4A.app}" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep .25; done
[ -p "$FIFO" ] || { echo "FAIL: nessun canale"; exit 1; }
sleep 1.5; send activate
send "text cd $HOME/Movies/t4a-bench-chat && claude"; send "key return"
ok=0; for _ in $(seq 1 45); do dump rr || true; [ "$(campo rr "'? for shortcuts' in x or 'mode on' in x or 'for agents' in x")" = True ] && { ok=1; break; }; sleep 2; done
[ "$ok" = 1 ] || { echo "FAIL: claude non pronto"; t4a_stop_bench; exit 1; }
sleep 3; send scan; dump s0; stato "S0 dopo aggancio" s0
send "compose prova"
w=0; for _ in $(seq 1 90); do dump wt || true; [ "$(campo wt "p['activity']")" = waiting ] && { w=1; break; }; sleep 1; done
[ "$w" = 1 ] || { echo "FAIL: turno mai finito"; t4a_stop_bench; exit 1; }
sleep 1.5; send scan; dump s1; stato "S1 a riposo dopo il turno" s1
giro() {
  local n="$1"
  send "compose /model"
  m=0; for i in $(seq 1 8); do sleep .5; send scan; dump "m$n$i" || continue; [ "$(campo "m$n$i" "'select model' in x.lower()")" = True ] && { m=1; cp "$DUMPS/m$n$i.json" "$DUMPS/menu$n.json"; break; }; done
  [ "$m" = 1 ] || { echo "G$n FAIL: menu mai apparso"; return 1; }
  stato "G$n menu aperto" "menu$n"
  send "key down"; sleep .4; send "text s"
  c=0; for i in $(seq 1 10); do sleep .3; send scan; dump "c$n$i" || continue; [ "$(campo "c$n$i" "'switch model' in x.lower()")" = True ] && { c=1; cp "$DUMPS/c$n$i.json" "$DUMPS/conf$n.json"; break; }; done
  if [ "$c" = 1 ]; then stato "G$n conferma a schermo" "conf$n"; send "text 1"; else echo "G$n: nessuna conferma (cambio diretto)"; fi
  for i in $(seq 1 12); do sleep .5; send scan; dump "a$n$i" || continue; [ "$(campo "a$n$i" "'switch model' in x.lower() or 'select model' in x.lower()")" = False ] && { cp "$DUMPS/a$n$i.json" "$DUMPS/after$n.json"; break; }; done
  sleep 1.5; send scan; dump "after${n}b"; stato "R$n dopo il cambio (+1,5 s)" "after${n}b"
  sleep 3; send scan; dump "after${n}c"; stato "R$n dopo il cambio (+4,5 s)" "after${n}c"
}
giro 1; giro 2
# Esc dalla bolla: dove arriva?
send activate; send "key escape"; sleep .6; send "key escape"; sleep .8; send scan; dump esc; stato "E dopo Esc Esc" esc; echo "E rewind a schermo: $(campo esc "'rewind' in x.lower()")"
send "key escape"; sleep .5; send "compose /exit"; sleep 3; t4a_stop_bench
echo "settings.json model: $(/usr/bin/python3 -c 'import json;print(json.load(open(__import__("os").path.expanduser("~/.claude/settings.json"))).get("model"))')"
R1="$(campo after1c "d['composer']['firstResponder']")"; R2="$(campo after2c "d['composer']['firstResponder']")"
if [ "$R1" = ComposerField ] && [ "$R2" = ComposerField ]; then echo "SUMMARY PASS (R1=$R1 R2=$R2)"; else echo "SUMMARY FAIL (R1=$R1 R2=$R2)"; exit 1; fi
