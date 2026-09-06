#!/bin/bash
# La porta: una scheda che si apre da fuori con un comando dentro, e si
# chiude a richiesta (ISC-211/212/213).
#
#   Scripts/bench-door.sh [--head <bundle>]
#
# La porta è una cartella ($T4A_DOOR): chi vuole una scheda ci scrive
# <nome>.open.json con cwd, command e label; l'app apre la scheda, esegue il
# comando e risponde con <nome>.opened.json {"session": uuid}. Una richiesta
# malformata riceve <nome>.rejected.json e nessuna scheda. <nome>.close.json
# {"session": uuid} chiude quel pannello solo se è fermo, e risponde
# <nome>.closed.json {"closed": true|false, "reason": ...}. Mai un foglio di
# conferma: dall'altra parte c'è un programma, non una persona.
#
# I poli, in ordine di rischio:
#   1  una richiesta valida → scheda nuova, titolo = label, cwd giusta,
#      comando eseguito (il marcatore è sullo schermo), risposta con l'uuid
#   2  cwd inesistente → rejected, nessuna scheda in più
#   3a chiusura mentre `sleep` gira → closed:false / working, scheda ancora lì
#   3b chiusura a shell ferma → closed:true, scheda sparita
#   3c uuid sconosciuto → closed:false / unknown
#   4  nome fuori charset → ignorato, nessuna risposta, app viva
#   5  (--head) sul bundle senza la porta la richiesta resta senza risposta:
#      è il polo negativo dell'intera feature.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${T4A_APP:-dist/T4A.app}"
HEAD_APP=""
if [ "${1:-}" = "--head" ]; then HEAD_APP="${2:?bundle}"; fi
FIFO="/tmp/t4a-door.fifo"
CFG="/tmp/t4a-door-config"
OUT="/tmp/t4a-door-out"
DOOR="/tmp/t4a-door"
CWD1="/tmp/t4a-door-cwd"
STATUS=0

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$OUT/$1.json"; send "dump $OUT/$1.json"
         for _ in $(seq 1 40); do [ -s "$OUT/$1.json" ] && break; sleep 0.25; done; }
campo() { /usr/bin/python3 -c "
import json,sys
print(eval(sys.argv[2], {'d': json.load(open(sys.argv[1]))}))" "$OUT/$1.json" "$2" 2>/dev/null; }
jsonfield() { /usr/bin/python3 -c "
import json,sys
v=json.load(open(sys.argv[1])).get(sys.argv[2], '')
print(v if not isinstance(v,bool) else str(v).lower())" "$1" "$2" 2>/dev/null; }
check() {
  local nome="$1" got="$2" want="$3" mark=ok
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-60s %-28s (want %s) %s\n' "$nome" "$got" "$want" "$mark"
}
attendi_file() { # <path> <secondi>
  local n=$(( ${2} * 4 ))
  for _ in $(seq 1 "$n"); do [ -s "$1" ] && return 0; sleep 0.25; done
  return 1
}
tabs() { dump "$1"; campo "$1" "len(d['tabs'])"; }
pane_by_session() { # <dumpname> <uuid> <field>
  campo "$1" "[p for t in d['tabs'] for p in t['panes'] if p['id'].lower()=='$2'.lower()][0]['$3']"
}

trap 't4a_stop_bench' EXIT
t4a_note_his_app

t4a_stop_bench; sleep 1
rm -rf "$CFG" "$FIFO" "$OUT" "$DOOR" "$CWD1"; mkdir -p "$CFG" "$OUT" "$DOOR" "$CWD1"
# Il path REALE: /tmp è un link a /private/tmp e la cwd letta dal kernel è quella.
CWD1="$(cd "$CWD1" && pwd -P)"
BUNDLE="$APP"; [ -n "$HEAD_APP" ] && BUNDLE="$HEAD_APP"
open -n "$BUNDLE" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG" --env T4A_DOOR="$DOOR"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3
send "activate"; sleep 0.5

check "all'avvio una scheda sola" "$(tabs avvio)" "1"

# ---- polo 1: una richiesta valida ---------------------------------------
MARK="DOOR-OK-$$"
printf '{"cwd": "%s", "command": "echo %s; sleep 12", "label": "Tappa uno"}\n' "$CWD1" "$MARK" > "$DOOR/tappa-uno.open.json.tmp" && mv "$DOOR/tappa-uno.open.json.tmp" "$DOOR/tappa-uno.open.json"
if attendi_file "$DOOR/tappa-uno.opened.json" 6; then
  SESSION="$(jsonfield "$DOOR/tappa-uno.opened.json" session)"
else
  SESSION=""
fi
if [ -n "$HEAD_APP" ]; then
  # Il polo negativo: senza la porta nessuno risponde. Rosso qui vorrebbe
  # dire che il banco passa anche su un'app che non ha la feature.
  check "HEAD: la richiesta resta senza risposta" "$( [ -z "$SESSION" ] && echo nessuna || echo risposta )" "nessuna"
  check "HEAD: nessuna scheda in più" "$(tabs head)" "1"
  exit $STATUS
fi
check "1 · risponde con un uuid di sessione" "${#SESSION}" "36"
check "1 · la richiesta è stata consumata" "$( [ -e "$DOOR/tappa-uno.open.json" ] && echo resta || echo sparita )" "sparita"
sleep 2
dump uno
check "1 · una scheda in più" "$(campo uno "len(d['tabs'])")" "2"
check "1 · il titolo è l'etichetta" "$(pane_by_session uno "$SESSION" title)" "Tappa uno"
check "1 · la cartella è quella chiesta" "$(pane_by_session uno "$SESSION" cwd)" "$CWD1"
check "1 · il comando è stato eseguito" "$(campo uno "'$MARK' in ''.join([p for t in d['tabs'] for p in t['panes'] if p['id'].lower()=='$SESSION'.lower()][0]['screen'])")" "True"

# ---- polo 2: cwd inesistente --------------------------------------------
printf '{"cwd": "/nessuna/cartella/%s", "command": "echo mai"}\n' "$$" > "$DOOR/tappa-due.open.json.tmp" && mv "$DOOR/tappa-due.open.json.tmp" "$DOOR/tappa-due.open.json"
attendi_file "$DOOR/tappa-due.rejected.json" 6
check "2 · cwd inesistente → rejected con una ragione" "$( [ -n "$(jsonfield "$DOOR/tappa-due.rejected.json" reason 2>/dev/null)" ] && echo ragione || echo niente )" "ragione"
check "2 · nessuna scheda in più" "$(tabs due)" "2"

# ---- polo 3a: chiusura mentre gira `sleep` ------------------------------
printf '{"session": "%s"}\n' "$SESSION" > "$DOOR/chiudi-a.close.json.tmp" && mv "$DOOR/chiudi-a.close.json.tmp" "$DOOR/chiudi-a.close.json"
attendi_file "$DOOR/chiudi-a.closed.json" 6
check "3a · con un programma dentro non chiude" "$(jsonfield "$DOOR/chiudi-a.closed.json" closed)" "false"
check "3a · e dice perché" "$(jsonfield "$DOOR/chiudi-a.closed.json" reason)" "working"
check "3a · la scheda è ancora lì" "$(tabs tre_a)" "2"

# ---- polo 3b: chiusura a shell ferma ------------------------------------
sleep 12
printf '{"session": "%s"}\n' "$SESSION" > "$DOOR/chiudi-b.close.json.tmp" && mv "$DOOR/chiudi-b.close.json.tmp" "$DOOR/chiudi-b.close.json"
attendi_file "$DOOR/chiudi-b.closed.json" 6
check "3b · a shell ferma chiude" "$(jsonfield "$DOOR/chiudi-b.closed.json" closed)" "true"
sleep 1
check "3b · la scheda è sparita" "$(tabs tre_b)" "1"

# ---- polo 3c: uuid sconosciuto ------------------------------------------
printf '{"session": "%s"}\n' "00000000-0000-4000-8000-000000000000" > "$DOOR/chiudi-c.close.json.tmp" && mv "$DOOR/chiudi-c.close.json.tmp" "$DOOR/chiudi-c.close.json"
attendi_file "$DOOR/chiudi-c.closed.json" 6
check "3c · uuid sconosciuto → closed:false / unknown" "$(jsonfield "$DOOR/chiudi-c.closed.json" closed)/$(jsonfield "$DOOR/chiudi-c.closed.json" reason)" "false/unknown"

# ---- polo 4: nome fuori charset -----------------------------------------
printf '{"cwd": "%s", "command": "echo MAI-$$"}\n' "$CWD1" > "$DOOR/con spazio.open.json.tmp" && mv "$DOOR/con spazio.open.json.tmp" "$DOOR/con spazio.open.json"
sleep 3
check "4 · un nome fuori charset non riceve risposta" "$(ls "$DOOR" | grep -c '^con spazio\.\(opened\|rejected\)')" "0"
check "4 · e non apre niente" "$(tabs quattro)" "1"
check "4 · l'app è ancora viva" "$( [ -s "$OUT/quattro.json" ] && echo viva || echo morta )" "viva"

[ "$STATUS" = 0 ] && echo "==> bench-door: tutto verde" || echo "==> bench-door: QUALCOSA È ROSSO"
exit $STATUS
