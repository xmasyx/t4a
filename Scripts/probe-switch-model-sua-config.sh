#!/bin/bash
# Il suo caso del 28/08 12:24 (video in design/evidence/20260828-1224-model-non-confermato.mov):
# a turno chiuso, /model, scegli un altro modello, e claude 2.1.250 fa una SECONDA domanda
# («Switch model?» 1. Yes / 2. No) che T4A copre con la pagina della chat. Questa sonda
# riproduce il giro sul bundle di dist/ con la SUA configurazione (copia, senza le chiavi
# finestra) e un claude vero, e scrive i dump della griglia nei tre momenti che contano:
#   d-thinking  la riga che claude disegna mentre pensa (verbo vero, per ISC-229)
#   d-menu      «Select model» aperto
#   d-confirm   «Switch model?» aperto — qui si legge asking/reading/chatPage.showing
# La scelta del modello è "s" (solo questa sessione) e la conferma è «2. No, go back»,
# così il default salvato in ~/.claude/settings.json non si tocca; lo confronta comunque.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh
t4a_note_his_app
WORK=/tmp/t4a-switch-probe; CFG="$WORK/config"; FIFO="$WORK/channel.fifo"; DUMPS="$WORK/dumps"
rm -rf "$WORK"; mkdir -p "$CFG/t4a" "$DUMPS"
grep -v '^window-\|^settings-offset' ~/.config/t4a/config.toml > "$CFG/t4a/config.toml"
MODEL_BEFORE="$(/usr/bin/python3 -c 'import json;print(json.load(open(__import__("os").path.expanduser("~/.claude/settings.json"))).get("model"))')"
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
open -n dist/T4A.app --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep .25; done
[ -p "$FIFO" ] || { echo "FAIL: nessun canale"; exit 1; }
sleep 1.5; send activate
send "text cd $HOME/Movies/t4a-bench-chat && claude"; send "key return"
ok=0; for _ in $(seq 1 45); do dump rr || true; [ "$(campo rr "'? for shortcuts' in x or 'mode on' in x or 'for agents' in x")" = True ] && { ok=1; break; }; sleep 2; done
[ "$ok" = 1 ] || { echo "FAIL: claude non pronto"; t4a_stop_bench; exit 1; }
sleep 3; send scan
send "compose prova"
# la riga del pensiero: il primo dump a turno aperto con una riga che porta ✻ o ✳
verbo=""; for i in $(seq 1 40); do sleep .5; send scan; dump "t$i" || continue
  act="$(campo "t$i" "p['activity']")"
  line="$(campo "t$i" "next((l for l in (p.get('screen') or []) if any(c in l for c in '✻✳✶✽·∗*') and ('…' in l or 'for' in l or 's)' in l)), '')")"
  if [ "$act" = working ] && [ -n "$line" ] && [ "$line" != "None" ]; then verbo="$line"; cp "$DUMPS/t$i.json" "$DUMPS/d-thinking.json"; echo "d-thinking al giro $i: [$line]"; break; fi
done
[ -n "$verbo" ] || echo "NOTA: nessuna riga di pensiero catturata (turno troppo breve?)"
w=0; for _ in $(seq 1 90); do dump wt || true; [ "$(campo wt "p['activity']")" = waiting ] && { w=1; break; }; sleep 1; done
[ "$w" = 1 ] || { echo "FAIL: turno mai finito"; t4a_stop_bench; exit 1; }
sleep 1; send scan; dump d-rest
echo "a riposo: asking=$(campo d-rest "p.get('asking')") page.showing=$(campo d-rest "d['chatPage']['showing']") alt=$(campo d-rest "p.get('alternateScreen')")"
send "compose /model"
m=0; for i in $(seq 1 8); do sleep .5; send scan; dump "m$i" || continue; [ "$(campo "m$i" "'select model' in x.lower()")" = True ] && { m=1; cp "$DUMPS/m$i.json" "$DUMPS/d-menu.json"; break; }; done
[ "$m" = 1 ] || { echo "FAIL: menu mai apparso"; send "key escape"; t4a_stop_bench; exit 1; }
echo "menu: asking=$(campo d-menu "p.get('asking')") reading=$(campo d-menu "p.get('reading')") page.showing=$(campo d-menu "d['chatPage']['showing']") alt=$(campo d-menu "p.get('alternateScreen')")"
# un modello diverso da quello segnato: giù di uno, poi "s" (solo questa sessione)
send "key down"; sleep .4; send "text s"
c=0; for i in $(seq 1 10); do sleep .3; send scan; dump "c$i" || continue; [ "$(campo "c$i" "'switch model' in x.lower()")" = True ] && { c=1; cp "$DUMPS/c$i.json" "$DUMPS/d-confirm.json"; break; }; done
if [ "$c" = 1 ]; then
  echo "=== CONFERMA A SCHERMO (d-confirm) ==="
  echo "asking=$(campo d-confirm "p.get('asking')") reading=$(campo d-confirm "p.get('reading')") page.showing=$(campo d-confirm "d['chatPage']['showing']") alt=$(campo d-confirm "p.get('alternateScreen')") cursor=$(campo d-confirm "p.get('cursor')")"
  echo "--- righe non vuote dello schermo ---"; campo d-confirm "'\n'.join(repr(l) for l in (p.get('screen') or []) if l.strip())"
  sleep .5; send "text 2"; sleep 1; send scan; dump d-after
  echo "dopo «2. No»: switch ancora a schermo=$(campo d-after "'switch model' in x.lower()") page.showing=$(campo d-after "d['chatPage']['showing']")"
else
  echo "NOTA: nessuna conferma «Switch model?» in 3 s (il cambio è passato diretto?)"; dump d-noconfirm; campo d-noconfirm "'\n'.join(repr(l) for l in (p.get('screen') or []) if l.strip())[-1500:]"
fi
send "key escape"; sleep .5; send "compose /exit"; sleep 3; t4a_stop_bench
MODEL_AFTER="$(/usr/bin/python3 -c 'import json;print(json.load(open(__import__("os").path.expanduser("~/.claude/settings.json"))).get("model"))')"
echo "settings.json model: prima=$MODEL_BEFORE dopo=$MODEL_AFTER"
echo "dump in $DUMPS"
