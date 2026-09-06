#!/bin/bash
# ISC-171 — Esc e Ctrl-C scritti nella BOLLA arrivano al processo.
#
#   Scripts/bench-composer-keys.sh [app-bundle]
#
# La regola è sua (25/08): «la bolla deve solo essere una variante estetica
# dell'altra». Quindi quello che nella riga d'ingresso ferma un programma deve
# fermarlo anche dalla bolla. Prima del 25/08 non era così: `ComposerField`
# trattava solo Invio e freccia destra, tutto il resto finiva nella scatola di
# testo, e con la bolla come unico ingresso un agente partito per la tangente
# non si poteva fermare.
#
# Due poli, e nessuno dei due chiama la funzione che il tasto avrebbe chiamato:
# i tasti sono VERI, posati dal window server con `keypress`, e l'esito si
# legge nel processo.
#
#   1. Ctrl-C dalla bolla uccide un `sleep 100`   -> il blocco finisce
#   2. Esc dalla bolla arriva come ^[ dentro `cat -v`
#   polo negativo: una lettera qualunque dalla bolla NON arriva al processo,
#                  resta nella scatola di testo dov'è stata scritta.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-composer-keys.fifo"
CFG="/tmp/t4a-composer-keys-config"
OUT="/tmp/t4a-composer-keys"
STATUS=0
rm -rf "$CFG" "$FIFO" "$OUT"; mkdir -p "$CFG" "$OUT"

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$OUT/$1.json"; send "dump $OUT/$1.json"
         for _ in $(seq 1 40); do [ -s "$OUT/$1.json" ] && break; sleep 0.25; done; }
campo() { /usr/bin/python3 -c "
import json,sys
print(eval(sys.argv[2], {'d': json.load(open(sys.argv[1]))}))" "$OUT/$1.json" "$2" 2>/dev/null; }
check() {
  local nome="$1" got="$2" want="$3" mark=ok
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-52s %-24s (want %s) %s\n' "$nome" "$got" "$want" "$mark"
}

t4a_note_his_app
[ -x "Scripts/.build-keypress" ] || swiftc -O -o Scripts/.build-keypress Scripts/keypress.swift 2>/dev/null
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3
# La bolla sempre visibile: il banco misura la bolla, non la scelta di quando
# mostrarla (quella ha il suo banco, bench-pure-chat).
send "composer-mode always"; sleep 1

echo "=== 1. Ctrl-C dalla bolla uccide quello che sta girando ============"
# Il testimone è il PROCESSO, non il modello dei blocchi: `exitCode` resta
# -9999 anche a comando finito quando la shell non ha annunciato il blocco, e
# un banco costruito su quel campo dice «non ucciso» di un processo che non
# esiste più (misurato il 25/08, prima versione di questo banco).
send "text sleep 3771"; send "key return"; sleep 2
check "il comando sta girando" "$(pgrep -f 'sleep 3771' | wc -l | tr -d ' ')" "1"
# ⌘L porta la tastiera nella bolla (ISC-158): il gesto vero, non un comando di comodo.
Scripts/.build-keypress 37 cmd app=dev.t4a.terminal; sleep 1
dump fuoco
check "la tastiera è nella bolla" "$(campo fuoco "d['firstResponder']")" "ComposerField"
Scripts/.build-keypress 8 ctrl app=dev.t4a.terminal; sleep 2
check "Ctrl-C dalla bolla lo ha ucciso" "$(pgrep -f 'sleep 3771' | wc -l | tr -d ' ')" "0"

echo "=== 2. Esc dalla bolla arriva al processo ==========================="
# Il lettore mette il tty in modo RAW e legge UN byte. In modo cotto — quello
# di una shell a riposo — il tty non consegna niente finché non arriva un
# a-capo, quindi un Esc premuto da solo resta nel buffer del kernel e un banco
# costruito su `head -c 1` legge un file vuoto e accusa l'app. Misurato il
# 25/08: con `head` il polo era rosso col fuoco nel TERMINALE, cioè su un
# percorso che non c'entra niente con la bolla.
LETTORE="python3 -c \"import sys,tty;tty.setraw(0);open('$OUT/esc.bin','wb').write(sys.stdin.buffer.read(1))\""
send "newtab"; sleep 1.5
send "text $LETTORE"; send "key return"; sleep 2
Scripts/.build-keypress 37 cmd app=dev.t4a.terminal; sleep 1
Scripts/.build-keypress 53 app=dev.t4a.terminal; sleep 2
check "il processo ha letto l'escape" "$(xxd -p "$OUT/esc.bin" 2>/dev/null | tr -d '\n')" "1b"

echo "=== polo negativo: una lettera resta nella bolla ===================="
LETTORE2="python3 -c \"import sys,tty;tty.setraw(0);open('$OUT/lettera.bin','wb').write(sys.stdin.buffer.read(1))\""
send "newtab"; sleep 1.5
send "text $LETTORE2"; send "key return"; sleep 2
Scripts/.build-keypress 37 cmd app=dev.t4a.terminal; sleep 1
Scripts/.build-keypress 0 app=dev.t4a.terminal; sleep 2        # 'a'
dump lettera
check "la lettera è finita nel testo della bolla" "$(campo lettera "d['composer']['text']")" "a"
check "e NON è arrivata al processo" "$(xxd -p "$OUT/lettera.bin" 2>/dev/null | tr -d '\n')" ""

t4a_stop_bench
[ "$STATUS" = "0" ] && echo "composer-keys: i poli tengono" || echo "composer-keys: un polo FALLITO"
exit "$STATUS"
