#!/bin/bash
# ISC-194..198 — i cinque difetti del 27/08, a tasti e mouse VERI.
#
#   Scripts/bench-27ago.sh [--with-claude] [--head <bundle>]
#
#   --with-claude   gira anche la ricevuta dei messaggi in coda (ISC-194) e la
#                   cella WORKER (ISC-196) contro un `claude` vero, che è
#                   l'unico posto dove le due domande esistono.
#   --head <app>    il bundle costruito PRIMA della riparazione: su quello i
#                   poli marcati «HEAD» devono uscire ROSSI, o il banco sta
#                   misurando qualcosa che non si è mai rotto.
#
# Ogni polo posa un evento vero dal window server — `keypress`, `dragpoint`,
# `clickpoint` — e legge l'esito nel PROCESSO o negli appunti, mai nella
# funzione che il gesto avrebbe chiamato (lezione di T4A, 26/08).
#
#   1. Esc con la PAGINA DELLA CHAT a fuoco arriva come ^[ al pty      (198)
#      polo negativo: Esc con l'elenco `/` aperto chiude l'elenco e NON
#      arriva al processo
#   2. un trascinamento vero sul terminale copia negli appunti          (197)
#      polo negativo: con `copy-on-select` spento gli appunti restano
#      quelli di prima
#   3. [--with-claude] un invio a turno aperto lascia la ricevuta, che
#      sparisce quando l'agente lo prende in mano                       (194)
#   4. [--with-claude] agente agganciato e fermo: NESSUNA cella WORKER  (196)
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

WITH_CLAUDE=0; HEAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-claude) WITH_CLAUDE=1;;
    --head) HEAD="$2"; shift;;
    *) echo "argomento sconosciuto: $1" >&2; exit 2;;
  esac
  shift
done

APP="${T4A_APP:-dist/T4A.app}"
FIFO="/tmp/t4a-27ago.fifo"
CFG="/tmp/t4a-27ago-config"
OUT="/tmp/t4a-27ago"
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
  printf '%-58s %-26s (want %s) %s\n' "$nome" "$got" "$want" "$mark"
}
# Un polo che DEVE fallire sul bundle vecchio: verde = il banco non misura.
check_head() {
  local nome="$1" got="$2" want="$3" mark=ok
  [ "$got" != "$want" ] || { mark="FAILED (verde su HEAD)"; STATUS=1; }
  printf '%-58s %-26s (HEAD: want ≠ %s) %s\n' "$nome" "$got" "$want" "$mark"
}
for tool in keypress dragpoint clickpoint movepoint; do
  [ -x ".build/t4a-$tool" ] || swiftc -O "Scripts/$tool.swift" -o ".build/t4a-$tool"
done
KEY=.build/t4a-keypress
# Un tasto vero va a chi sta davanti: prima si porta davanti l'app, poi si
# preme. Il 27/08 ⌘L è uscito «never came to the front» senza questo.
tasto() { send "activate"; sleep 0.5; $KEY "$@"; }

SAVED="$(pbpaste)"
restore() { printf '%s' "$SAVED" | pbcopy; }
trap 'restore; t4a_stop_bench' EXIT

lancia() {
  local app="$1"
  t4a_stop_bench; sleep 1
  rm -rf "$CFG" "$FIFO" "$OUT"; mkdir -p "$CFG" "$OUT"
  open -n "$app" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
  for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep 0.25; done
  sleep 3
  send "activate"; sleep 0.5
}

# Il lettore in modo RAW che scrive UN byte: la stessa sonda di
# bench-composer-keys, per la stessa ragione (in modo cotto un Esc da solo
# resta nel kernel).
lettore() { echo "python3 -c \"import sys,tty;tty.setraw(0);open('$OUT/$1.bin','wb').write(sys.stdin.buffer.read(1))\""; }

t4a_note_his_app

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 1. ISC-198 · Esc dalla PAGINA DELLA CHAT arriva al processo ======"
# La pagina della chat esiste solo con un agente agganciato; senza `claude` il
# polo si fa sulla superficie più vicina che ruba il fuoco allo stesso modo:
# il lettore di un turno non c'è, quindi si prova con il TERMINALE e con la
# bolla, e la pagina vera sta nel blocco --with-claude qui sotto.
lancia "$APP"
send "composer-mode always"; sleep 1
send "text $(lettore esc-term)"; send "key return"; sleep 2
# La tastiera nel terminale (click vero sulla superficie), poi Esc vero.
dump geo
SX="$(campo geo "[q for t in d['tabs'] for q in t['panes'] if q['active']][0]['surfaceRect']['x']")"
SY="$(campo geo "[q for t in d['tabs'] for q in t['panes'] if q['active']][0]['surfaceRect']['y']")"
.build/t4a-movepoint "$SX" "$SY"; sleep 0.3; .build/t4a-clickpoint "$SX" "$SY" 40; sleep 0.6
dump fuoco1
check "1a la tastiera è nel terminale" "$(campo fuoco1 "d['firstResponder']")" "TappedTerminalView"
tasto 53 app=dev.t4a.terminal; sleep 1.5
check "1b un Esc solo, dal terminale, arriva come ^[" "$(xxd -p "$OUT/esc-term.bin" 2>/dev/null | tr -d '\n')" "1b"
ls "$OUT"/esc-term.bin >/dev/null 2>&1 && check "1c e ne è arrivato UNO (1 byte, non due)" "$(stat -f %z "$OUT/esc-term.bin")" "1"

echo "--- polo negativo: Esc a elenco / aperto chiude l'elenco, non tocca il pty"
# Senza agente il catalogo è vuoto e l'elenco non si apre: si punta sulla
# fixture, come fa bench-slash, così i comandi sono sei e sempre gli stessi.
FIXTURE="$PWD/Scripts/fixtures/slash-fixture.txt"
send "slash-catalog $FIXTURE"; sleep 2
send "text $(lettore esc-slash)"; send "key return"; sleep 2
tasto 37 cmd app=dev.t4a.terminal; sleep 0.8            # ⌘L → bolla
dump fuocoL
check "1d0 ⌘L ha messo la tastiera nella bolla" "$(campo fuocoL "d['firstResponder']")" "ComposerField"
send "typekey /"; sleep 1
dump elenco
check "1d l'elenco dei comandi è aperto" "$(campo elenco "d['composer']['suggestions']['shown']")" "True"
tasto 53 app=dev.t4a.terminal; sleep 1
dump elenco2
check "1e Esc lo ha chiuso" "$(campo elenco2 "d['composer']['suggestions']['shown']")" "False"
check "1f e il processo NON ha letto niente" "$(xxd -p "$OUT/esc-slash.bin" 2>/dev/null | tr -d '\n')" ""
# Il secondo Esc, a elenco chiuso, arriva (ISC-171 intatta).
tasto 53 app=dev.t4a.terminal; sleep 1.5
check "1g il secondo Esc arriva al processo" "$(xxd -p "$OUT/esc-slash.bin" 2>/dev/null | tr -d '\n')" "1b"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== 2. ISC-197 · un trascinamento vero sul terminale copia ============"
printf 'PRIMA-DEL-BANCO' | pbcopy
send "newtab"; sleep 1.5
# Due spazi per lato: SwiftTerm mette l'ancora della selezione sul PRIMO
# evento di trascinamento e non sulla pressione, quindi il confine esatto
# dipende dal passo del mouse. La domanda del polo è «quello che ho
# trascinato sta negli appunti, byte per byte», e quella si misura come
# appunti == selezione; la parola dentro è il controllo che ho preso la riga
# giusta.
send "text echo \"  alpha-bravo-charlie  \""; send "key return"; sleep 1.5
dump geo2
PANE="[q for t in d['tabs'] for q in t['panes'] if q['active']][0]"
X0="$(campo geo2 "$PANE['surfaceRect']['x'] - $PANE['surfaceRect']['w']/2 + 4")"
W="$(campo geo2 "$PANE['surfaceRect']['w']")"
H="$(campo geo2 "$PANE['surfaceRect']['h']")"
Y0="$(campo geo2 "$PANE['surfaceRect']['y'] + $PANE['surfaceRect']['h']/2")"
CH="$(campo geo2 "$PANE['cellHeight']")"
COLS="$(campo geo2 "$PANE['columns']")"
# La riga con l'output: la cerco nello schermo e la converto in y di schermo
# (Cocoa: l'origine in basso, la riga 0 in alto).
ROW="$(campo geo2 "[i for i,r in enumerate($PANE['screen']) if 'alpha-bravo-charlie' in r and '\$' not in r and '❯' not in r][-1]")"
Y="$(/usr/bin/python3 -c "print($Y0 - ($ROW + 0.5) * $CH)")"
CW="$(/usr/bin/python3 -c "print($W / $COLS)")"
# SwiftTerm arrotonda al CONFINE di cella più vicino (misurato: partendo a
# 0,7 celle dal bordo la selezione cominciava alla colonna 1), quindi il
# puntatore parte a 2 pt dal bordo e finisce a 2 pt oltre il confine 19.
LEFT="$(campo geo2 "$PANE['surfaceRect']['x'] - $PANE['surfaceRect']['w']/2")"
XA="$(/usr/bin/python3 -c "print($LEFT + 2)")"
XB="$(/usr/bin/python3 -c "print($LEFT + 23 * $CW + 2)")"
echo "      geometria: riga=$ROW y=$Y xa=$XA xb=$XB cw=$CW ch=$CH"
send "hittest $XA,$Y"; sleep 0.4; dump hit
echo "      sotto il puntatore: $(campo hit "d['hitTest']")"
send "activate"; sleep 0.5
.build/t4a-movepoint "$XA" "$Y"; sleep 0.3
.build/t4a-dragpoint "$XA" "$Y" "$XB" "$Y" 24; sleep 1
dump sel
check "2a la selezione è la riga trascinata" "$(campo sel "$PANE['selection'].strip()")" "alpha-bravo-charlie"
check "2b e gli appunti sono la selezione, byte per byte" "$(pbpaste | /usr/bin/python3 -c 'import sys;print(repr(sys.stdin.read()))')" "$(campo sel "repr($PANE['selection'])")"

echo "--- polo negativo: interruttore spento, gli appunti restano"
send "settings Terminal"; sleep 1
send "press-switch Copy on select"; sleep 0.8
send "settings close"; sleep 0.5
printf 'PRIMA-DEL-BANCO-2' | pbcopy
send "activate"; sleep 0.4
.build/t4a-movepoint "$XA" "$Y"; sleep 0.3
.build/t4a-dragpoint "$XA" "$Y" "$XB" "$Y" 24; sleep 1
dump sel2
check "2c la selezione c'è ancora" "$(campo sel2 "$PANE['selection'].strip()")" "alpha-bravo-charlie"
check "2d ma gli appunti sono quelli di prima" "$(pbpaste)" "PRIMA-DEL-BANCO-2"
check "2e (config) copy-on-select = false" "$(grep -c 'copy-on-select = false' "$CFG/t4a/config.toml" 2>/dev/null)" "1"

# ─────────────────────────────────────────────────────────────────────────────
if [ -n "$HEAD" ]; then
  echo "=== HEAD · sul bundle di prima i poli DEVONO essere rossi ============"
  lancia "$HEAD"
  printf 'PRIMA-DEL-BANCO-HEAD' | pbcopy
  send "text echo \"  alpha-bravo-charlie  \""; send "key return"; sleep 1.5
  # Il bundle vecchio non porta surfaceRect: uso la finestra e la geometria
  # di prima, che è la stessa (stessa config vuota, stessa taglia).
  .build/t4a-movepoint "$XA" "$Y"; sleep 0.3
  .build/t4a-dragpoint "$XA" "$Y" "$XB" "$Y" 24; sleep 1
  dump head-sel
  check "H-2a (HEAD) la selezione si fa comunque" "$(campo head-sel "$PANE['selection'].strip()")" "alpha-bravo-charlie"
  check_head "H-2b (HEAD) ma NON finisce negli appunti" "$(pbpaste | /usr/bin/python3 -c 'import sys;print(repr(sys.stdin.read()))')" "$(campo head-sel "repr($PANE['selection'])")"
fi

# ─────────────────────────────────────────────────────────────────────────────
if [ "$WITH_CLAUDE" = "1" ]; then
  echo "=== 3/4. ISC-194/196/198 · con un claude VERO ========================"
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude non è nel PATH: i poli vivi NON sono stati eseguiti"; STATUS=1
  else
    lancia "$APP"
    CHATDIR="$HOME/Movies/t4a-bench-chat"; mkdir -p "$CHATDIR"
    send "text cd $CHATDIR && claude"; send "key return"
    waited=0
    while [ "$waited" -lt 90 ]; do
      dump pronto
      if /usr/bin/python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
panes = [q for t in d["tabs"] for q in t["panes"] if q.get("active")]
screen = panes[0].get("screen") or []
text = "\n".join(screen) if isinstance(screen, list) else str(screen)
sys.exit(0 if ("? for shortcuts" in text or "auto mode on" in text) else 1)
' "$OUT/pronto.json"; then break; fi
      sleep 2; waited=$((waited + 2))
    done
    sleep 3; send "scan"; sleep 0.8
    dump att
    check "3a l'agente è agganciato" "$(campo att "$PANE['attached']")" "True"

    echo "--- ISC-196: agganciato e fermo → nessuna cella WORKER"
    check "4a WORKER non è fra le celle dipinte" "$(campo att "'worker' in d['dash']['values']")" "False"

    echo "--- ISC-194: un invio a turno aperto lascia la ricevuta"
    # Un turno che dura DAVVERO: quaranta numeri escono in tre secondi e il
    # turno era già chiuso quando arrivava il secondo messaggio (prima corsa,
    # 27/08: nessuna ricevuta, e giustamente). Un `sleep` via Bash dura quanto
    # dice, e la cartella del banco ha la modalità automatica accesa.
    send "compose Esegui esattamente questo comando con lo strumento Bash e poi rispondi solo «fatto»: sleep 25"; sleep 6
    dump prima
    echo "      prima del secondo invio: turni=$(campo prima "d['chatPage']['turns']") attività=$(campo prima "$PANE['activity']")"
    check "3b0 il turno è aperto quando spedisco il secondo" "$(campo prima "$PANE['activity']")" "working"
    send "compose secondo messaggio in coda"; sleep 1.2
    dump coda
    check "3b la ricevuta è visibile" "$(campo coda "d['queued']['visible']")" "True"
    check "3c e porta il testo spedito" "$(campo coda "d['queued']['line']")" "in coda · secondo messaggio in coda"
    # Aspetto che l'agente prenda il secondo messaggio: i turni crescono.
    # Tre minuti: il turno con lo `sleep 25` porta anche gli hook di casa, che
    # a fine turno fanno il loro giro prima che l'agente prenda la coda.
    for _ in $(seq 1 90); do
      dump coda2
      [ "$(campo coda2 "d['queued']['visible']")" = "False" ] && break
      sleep 2
    done
    echo "      dopo l'attesa: turni=$(campo coda2 "d['chatPage']['turns']") attività=$(campo coda2 "$PANE['activity']")"
    check "3d la ricevuta se ne va quando il turno parte" "$(campo coda2 "d['queued']['visible']")" "False"
    # Il consumo lo dichiara l'agente: `remove` (assorbito nel turno) o
    # `dequeue` (a fine turno o su interruzione). Senza questo contatore una
    # ricevuta mai comparsa e una sparita sarebbero la stessa riga.
    check "3e ed è stato l'agente a consumarlo (remove/dequeue)" "$(campo coda2 "d['queued']['consumed'] >= 1")" "True"

    echo "--- ISC-198: Esc VERO con la pagina della chat a fuoco"
    # Aspetto che l'agente sia fermo, poi lancio un lettore RAW... ma qui il
    # pty è di claude: il testimone è il TRANSCRIPT, che registra
    # «[Request interrupted by user]» quando un Esc arriva a turno aperto.
    sleep 6
    send "compose Scrivi i numeri da 1 a 60, uno per riga, senza usare strumenti e senza spiegazioni."; sleep 2.5
    dump pagina
    PX="$(campo pagina "d['chatPage']['page']['x']")"
    PY="$(campo pagina "d['chatPage']['page']['y']")"
    check "3f la pagina della chat è sullo schermo" "$(campo pagina "d['chatPage']['showing']")" "True"
    send "activate"; sleep 0.5
    .build/t4a-movepoint "$PX" "$PY"; sleep 0.3; .build/t4a-clickpoint "$PX" "$PY" 40; sleep 0.6
    dump fuoco2
    # Girato il 28/08: da ISC-203 (a65a899) un click SEMPLICE sulla pagina
    # restituisce la tastiera alla bolla (`onPlainClick`); la pagina la tiene
    # solo con una selezione. L'Esc che segue parte quindi dalla bolla, e 3h
    # resta la prova che interrompe lo stesso.
    check "3g il click semplice rimanda la tastiera alla bolla" "$(campo fuoco2 "d['firstResponder']")" "ComposerField"
    tasto 53 app=dev.t4a.terminal; sleep 4
    dump dopo
    check "3h l'agente è stato interrotto (turno chiuso, non aspetta)" \
      "$(campo dopo "'interrupted' in ' '.join($PANE['screen']).lower() or $PANE['activity'] in ('idle','waiting')")" "True"
    send "compose /exit"; sleep 3
  fi
fi

t4a_stop_bench
[ "$STATUS" = "0" ] && echo "27ago: i poli tengono" || echo "27ago: un polo FALLITO"
exit "$STATUS"
