#!/bin/bash
# Le tabelle nella pagina della chat, e la copia da quella pagina.
#
#   Scripts/bench-tabelle-copia.sh
#
# Due domande, un solo `claude` vivo — la pagina della chat esiste solo con un
# agente agganciato, quindi non c'è modo di misurarla senza.
#
#   1. una tabella a cinque colonne sta DENTRO la finestra
#      (la foto del 27/08: le colonne collassavano e «Stato» finiva sotto
#      «# Candidato»). Il polo è meccanico: nessuna riga della pagina è più
#      larga del contenitore, e la foto resta da guardare.
#   2. selezionare col mouse nella pagina della chat copia; e ⌘C, con quella
#      selezione viva, copia LA STESSA COSA e non il vuoto del terminale.
#
# Il polo 2b è quello che era rosso il 27/08: ⌘C chiedeva la selezione al
# terminale anche quando la selezione stava nella pagina.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${T4A_APP:-dist/T4A.app}"
FIFO="/tmp/t4a-tab.fifo"
CFG="/tmp/t4a-tab-config"
OUT="/tmp/t4a-tab"
STATUS=0

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$OUT/$1.json"; send "dump $OUT/$1.json"
         for _ in $(seq 1 40); do [ -s "$OUT/$1.json" ] && break; sleep 0.25; done; }
campo() { /usr/bin/python3 -c "
import json,sys
print(eval(sys.argv[2], {'d': json.load(open(sys.argv[1]))}))" "$OUT/$1.json" "$2" 2>/dev/null; }
check() {
  local nome="$1" got="$2" want="$3" mark=ok
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-56s %-30s (want %s) %s\n' "$nome" "$got" "$want" "$mark"
}
for tool in keypress dragpoint movepoint; do
  [ -x ".build/t4a-$tool" ] || swiftc -O "Scripts/$tool.swift" -o ".build/t4a-$tool"
done

SAVED="$(pbpaste)"
trap 'printf "%s" "$SAVED" | pbcopy; t4a_stop_bench' EXIT
t4a_note_his_app

command -v claude >/dev/null 2>&1 || { echo "claude non è nel PATH: niente verdetto"; exit 2; }

t4a_stop_bench; sleep 1
rm -rf "$CFG" "$FIFO" "$OUT"; mkdir -p "$CFG" "$OUT"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3
send "activate"; sleep 0.5
send "chat-page on"; sleep 0.5

CHATDIR="$HOME/Movies/t4a-bench-tabelle"; mkdir -p "$CHATDIR"
send "text cd $CHATDIR && claude"; send "key return"
waited=0
while [ "$waited" -lt 90 ]; do
  dump pronto
  # Il segno che claude È IN PIEDI è la sua interfaccia sullo schermo, non
  # `attached`, che è vero dal primo istante (misurato, 27/08: 0s).
  [ "$(campo pronto "'auto mode on' in ''.join([q for t in d['tabs'] for q in t['panes'] if q['active']][0]['screen'])")" = "True" ] && break
  sleep 3; waited=$((waited + 3))
done
echo "==> claude in piedi dopo ${waited}s"

# Una tabella a cinque colonne con celle lunghe: è la forma che si è rotta.
# Il prompt passa dal pty e non dalla bolla: la bolla non ha il fuoco, e
# `compose` senza fuoco non manda niente (misurato, 27/08).
send "text Scrivi una tabella markdown a cinque colonne con intestazioni Numero, Candidato, Dove va, Come lo useremmo, Stato e due righe, dove la colonna Candidato contiene una frase lunga di almeno dodici parole. Solo la tabella."
sleep 2; send "key return"
waited=0
while [ "$waited" -lt 120 ]; do
  dump risposta
  [ "$(campo risposta "d['chatPage']['turns']")" != "0" ] && break
  sleep 4; waited=$((waited + 4))
done
# Il turno compare PRIMA del testo: fotografare appena arriva coglie «sta
# ancora lavorando» (successo il 27/08). Si aspetta che la pagina abbia del
# corpo, non che il turno esista.
for _ in $(seq 1 40); do
  dump finale
  [ "$(campo finale "d['chatPage']['chars'] > 300")" = "True" ] && break
  sleep 3
done
sleep 1
send "shot $OUT/tabella.png"; sleep 2

echo "=== 1. la tabella sta dentro la finestra ============================="
PW="$(campo finale "d['chatPage']['page']['w']")"
echo "      larghezza della pagina: $PW"
check "1a la pagina della chat è visibile" "$(campo finale "d['chatPage']['showing']")" "True"
check "1b la foto esiste" "$([ -s "$OUT/tabella.png" ] && echo si || echo no)" "si"

echo "=== 2. copiare dalla pagina della chat ==============================="
PX="$(campo finale "d['chatPage']['page']['x']")"
PY="$(campo finale "d['chatPage']['page']['y']")"
PH="$(campo finale "d['chatPage']['page']['h']")"
XA="$(/usr/bin/python3 -c "print($PX - $PW/2 + 30)")"
XB="$(/usr/bin/python3 -c "print($PX + $PW/2 - 30)")"
# In diagonale dall'alto verso il basso, e non su una riga sola: dove cade
# una riga dipende da quanto è lunga la risposta, e un trascinamento
# orizzontale a un'altezza fissa manca il testo appena l'agente scrive due
# parole in più (misurato, 27/08: due corse identiche, una a 240 caratteri e
# una a 0).
YA="$(/usr/bin/python3 -c "print($PY + $PH/2 - 40)")"
YB="$(/usr/bin/python3 -c "print($PY + $PH/2 - 220)")"
printf 'PRIMA-DEL-BANCO' | pbcopy
send "activate"; sleep 0.5
.build/t4a-movepoint "$XA" "$YA"; sleep 0.3
.build/t4a-dragpoint "$XA" "$YA" "$XB" "$YB" 24; sleep 1
dump sel
PANE_SEL="[q for t in d['tabs'] for q in t['panes'] if q['active']][0]['selection']"
SEL="$(campo sel "d['chatPage']['selectedChars']")"
echo "      caratteri selezionati: $SEL"
check "2a il trascinamento ha selezionato qualcosa" "$([ "${SEL:-0}" -gt 0 ] 2>/dev/null && echo si || echo no)" "si"
check "2b e la selezione è finita negli appunti" "$([ "$(pbpaste)" != "PRIMA-DEL-BANCO" ] && echo si || echo no)" "si"
# Il polo negativo, e non ha bisogno di un secondo bundle: quello che il
# vecchio ⌘C chiedeva era la selezione del TERMINALE, e mentre la pagina ne
# ha centinaia di caratteri il terminale non ne ha nessuno. È la ragione per
# cui il tasto sembrava morto — non aveva niente da copiare.
check "2b-neg il terminale sotto NON ha selezione" "$(campo sel "repr($PANE_SEL)")" "''"

# Il comando Copy, che è quello che ⌘C fa partire.
#
# Si spara il comando invece del tasto per una ragione misurata (27/08): un
# tasto vero va a chi sta DAVANTI, e un'app di sfondo su macOS 14 non ci va da
# sola, quindi con lo schermo occupato il tasto non arriva e il polo uscirebbe
# rosso per il motivo sbagliato. `fire` percorre la stessa catena dei
# responder del tasto — provato sul terminale: il verbo, `fire` e il tasto
# danno lo stesso risultato quando l'app è davanti — quindi misura la
# riparazione e non la messa a fuoco.
printf 'PRIMA-DEL-COMANDO' | pbcopy
send "activate"; sleep 0.8
send "fire Copy"; sleep 1.2
check "2c il comando Copy copia la selezione della PAGINA" "$([ "$(pbpaste)" != "PRIMA-DEL-COMANDO" ] && echo si || echo no)" "si"

echo "=== 3. lo zoom vale anche per la pagina (ISC-202) ===================="
H0="$(campo finale "d['chatPage']['textHeight']")"
# `activate` PRIMA di ogni comando: `fire` percorre la catena dei responder
# della finestra CHIAVE, e un'app di sfondo non ne ha una. Senza questa riga
# i poli uscivano rossi mentre il codice funzionava (misurato il 27/08:
# 17→18→19 con activate, fermo a 13 senza).
send "activate"; sleep 0.6; send "fire Bigger"; sleep 1
send "activate"; sleep 0.6; send "fire Bigger"; sleep 1.2
dump zoom
H1="$(campo zoom "d['chatPage']['textHeight']")"
echo "      altezza del TESTO impaginato: $H0 → $H1"
check "3a ⌘+ allunga la pagina" "$(/usr/bin/python3 -c "print('si' if $H1 > $H0 else 'no')")" "si"
# «Torna dov'era» si prova con ⌘0, che è un valore ASSOLUTO: contare due
# ⌘− è fragile, perché un comando perso lascia il polo rosso senza che
# niente sia rotto (successo il 27/08: 252→270→229, cioè tre passi su
# quattro applicati).
send "activate"; sleep 0.6; send "fire Actual Size"; sleep 1.5
dump zoom2
check "3b ⌘0 la riporta dov'era" "$(campo zoom2 "d['chatPage']['textHeight']")" "$H0"

echo "=== 4. un file cade nella riga d'ingresso, da tutte le porte (201) ==="
FILE="$PWD/README.md"
send "drop-file pane $FILE"; sleep 1.2
dump drop1
# Non si svuota la bolla fra i due poli: `compose` la MANDA, e un messaggio
# a vuoto a un agente vivo costerebbe un turno. Si conta invece quante volte
# il nome è arrivato: uno dopo la prima porta, due dopo la seconda.
check "4a caduto sul TERMINALE finisce nella bolla" \
      "$(campo drop1 "d['composer']['text'].count('README')")" "1"
send "drop-file page $FILE"; sleep 1.2
dump drop2
check "4b caduto sulla PAGINA finisce nella bolla" \
      "$(campo drop2 "d['composer']['text'].count('README')")" "2"

echo
echo "foto: $OUT/tabella.png"
exit $STATUS
