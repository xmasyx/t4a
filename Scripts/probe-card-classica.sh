#!/bin/bash
# ISC-232: con la griglia classica (chat-page = false) la card NON compare sopra la conferma di
# claude; con chat-page = true compare. Sua configurazione, claude vero. Usage: [--page]
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh
t4a_note_his_app
PAGE=false; [ "${1:-}" = "--page" ] && PAGE=true
WORK=/tmp/t4a-card-probe; CFG="$WORK/config"; FIFO="$WORK/channel.fifo"; DUMPS="$WORK/dumps"
rm -rf "$WORK"; mkdir -p "$CFG/t4a" "$DUMPS"
grep -v '^window-\|^settings-offset\|^chat-page' ~/.config/t4a/config.toml > "$CFG/t4a/config.toml"; echo "chat-page = $PAGE" >> "$CFG/t4a/config.toml"
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
open -n "${BUNDLE:-dist/T4A.app}" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep .25; done
[ -p "$FIFO" ] || { echo "FAIL: nessun canale"; exit 1; }
sleep 1.5; send activate; send "text cd $HOME/Movies/t4a-bench-chat && claude"; send "key return"
ok=0; for _ in $(seq 1 45); do dump rr || true; [ "$(campo rr "'? for shortcuts' in x or 'mode on' in x or 'for agents' in x")" = True ] && { ok=1; break; }; sleep 2; done
[ "$ok" = 1 ] || { echo "FAIL: claude non pronto"; t4a_stop_bench; exit 1; }
sleep 3; send "text prova"; send "key return"
w=0; for _ in $(seq 1 90); do dump wt || true; [ "$(campo wt "p['activity']")" = waiting ] && { w=1; break; }; sleep 1; done
[ "$w" = 1 ] || { echo "FAIL: turno mai finito"; t4a_stop_bench; exit 1; }
sleep 1.5; send "text /model"; send "key return"
m=0; for i in $(seq 1 8); do sleep .5; send scan; dump "m$i" || continue; [ "$(campo "m$i" "'select model' in x.lower()")" = True ] && { m=1; break; }; done
[ "$m" = 1 ] || { echo "FAIL: menu mai apparso"; t4a_stop_bench; exit 1; }
send "key down"; sleep .4; send "text s"
c=0; for i in $(seq 1 10); do sleep .3; send scan; dump "c$i" || continue; [ "$(campo "c$i" "'switch model' in x.lower()")" = True ] && { c=1; cp "$DUMPS/c$i.json" "$DUMPS/conf.json"; break; }; done
[ "$c" = 1 ] || { echo "FAIL: nessuna conferma"; t4a_stop_bench; exit 1; }
CARD="$(campo conf "d['card']['showing']")"; ASK="$(campo conf "p.get('asking')")"; PG="$(campo conf "d['chatPage']['showing']")"
echo "chat-page=$PAGE · conferma a schermo · asking=$ASK card.showing=$CARD page.showing=$PG"
send "text 2"; sleep .8; send "key escape"; sleep .5; send "text /exit"; send "key return"; sleep 3; t4a_stop_bench
if [ "$PAGE" = false ]; then [ "$CARD" = False ] && echo "SUMMARY PASS (niente card sulla griglia classica)" || { echo "SUMMARY FAIL (card=$CARD)"; exit 1; }
else [ "$CARD" = True ] && echo "SUMMARY PASS (card con la pagina)" || { echo "SUMMARY FAIL (card=$CARD)"; exit 1; }; fi
