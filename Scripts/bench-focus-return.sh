#!/bin/bash
# ISC-188 — la bolla prende il cursore quando torni a guardare la finestra o
# scegli una chat, senza cliccarci dentro.
#
#   Scripts/bench-focus-return.sh [--with-claude] [app-bundle]
#
# Sua frase del 27/08: «non serve che io clicchi nella bolla, basta che clicchi
# sulla chat». Prima di oggi la tastiera andava alla bolla solo nel momento in
# cui la bolla COMPARIVA: tornando da un'altra app, o scegliendo una sessione,
# restava dov'era e l'unica via era il clic dentro la scatola di testo.
#
# Ogni gesto qui è VERO. Il ritorno dell'app si fa con `open -a` sul bundle e
# la partenza con un `activate` di AppleScript sul Finder — due gesti che
# passano dal window server, non dal canale di prova; i clic li posa
# `clickpoint`; ⌘2 lo posa `keypress`. Il canale serve solo a leggere lo stato
# (`dump`) e a preparare la scena, mai a produrre il gesto misurato.
#
# La lettura è sempre `composer.firstResponder`, cioè chi ha la tastiera
# secondo la FINESTRA:
#
#   ComposerField       la bolla
#   TappedTerminalView  la superficie del terminale (non il pannello che la
#                       contiene: sono due, e il difetto del 26/08 stava lì)
#   NSTextView          il campo della ricerca, che ha il suo editor
#
# I poli:
#   1  torni da un'altra app                       -> bolla
#   2  scegli una chat dal pannello di sinistra    -> bolla, ed è quella chat
#   3  scegli una scheda dalla striscia, e con ⌘2  -> bolla
#   4  NEGATIVO, la domanda: con un permesso sullo schermo il ritorno porta la
#      tastiera alla SUPERFICIE del terminale, mai alla bolla (ISC-182)
#   5  NEGATIVO, il ladro: con la ricerca aperta, e con le impostazioni
#      aperte, la tastiera resta dov'è
#
# Il polo di controllo contro HEAD non è qui dentro: si esegue questo stesso
# banco sul bundle compilato da un worktree a HEAD e si guarda quali poli
# diventano rossi (1 e 2 — la riparazione è quella).
#
# Il finto agente del polo 4: un binario chiamato `claude` che fa `exec` di
# /bin/sh. T4A riconosce un agente dal nome del processo e dalla sua riga di
# comando, quindi questo si aggancia davvero, e il riquadro di permesso lo
# stampa una `printf` — «any shell output shaped like a permission can raise a
# card» (bench-card.sh). Serve perché `staChiedendo` legge lo schermo SOLO con
# un agente agganciato: senza, il polo negativo misurerebbe una domanda che
# l'app non sta nemmeno guardando. Il `claude` vero resta la prova finale, e si
# fa con --with-claude.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

WITH_CLAUDE=0
if [ "${1:-}" = "--with-claude" ]; then WITH_CLAUDE=1; shift; fi
APP="${1:-dist/T4A.app}"
case "$APP" in /*) APP_ABS="$APP" ;; *) APP_ABS="$PWD/$APP" ;; esac
FIFO="/tmp/t4a-focus-return.fifo"
CFG="${T4A_BENCH_CONFIG_HOME:-/tmp/t4a-focus-return-config}"
OUT="/tmp/t4a-focus-return"
FAKEBIN="/tmp/t4a-focus-return-bin"
STATUS=0
DUMP="$OUT/d.json"

[ -x "$APP_ABS/Contents/MacOS/T4A" ] || { echo "no bundle at $APP_ABS" >&2; exit 1; }
rm -rf "$FIFO" "$OUT"; mkdir -p "$OUT" .build "$FAKEBIN"
[ -n "${T4A_BENCH_CONFIG_HOME:-}" ] || { rm -rf "$CFG"; mkdir -p "$CFG"; }
for tool in clickpoint keypress; do
  bin=".build/t4a-${tool%point}"
  case "$tool" in clickpoint) bin=".build/t4a-click" ;; keypress) bin=".build/t4a-keypress" ;; esac
  if [ ! -x "$bin" ] || [ "Scripts/$tool.swift" -nt "$bin" ]; then
    swiftc -O "Scripts/$tool.swift" -o "$bin"
  fi
done

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 60); do [ -s "$DUMP" ] && break; sleep 0.25; done
  [ -s "$DUMP" ] || { echo "the app never answered a dump" >&2; STATUS=1; }
}
field() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
try:
    print($1)
except Exception as error:
    print('missing:%s' % type(error).__name__)
"; }
resp() { field "d['composer']['firstResponder']"; }
check() {
  local nome="$1" got="$2" want="$3" mark=ok
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-56s got %-20s want %-20s %s\n' "$nome" "$got" "$want" "$mark"
}
note() { printf '%-56s %s\n' "$1" "$2"; }

# Il centro della zona del terminale, calcolato dalla finestra e dalle due
# colonne che il dump dichiara: un punto scritto a mano nel banco è un punto
# che il giorno che lui allarga il pannello finisce sul divisorio.
termxy() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
w, p = d['window'], d['panels']
left = 0 if p['rail']['hidden'] else p['rail']['x'] + p['rail']['width']
right = w['width'] if p['inspector']['hidden'] else p['inspector']['x']
print('%f %f' % (w['x'] + (left + right) / 2, w['y'] + w['height'] / 2))
"; }

# T4A davanti, e non per modo di dire: un clic vero atterra su qualunque
# finestra il window server abbia in cima, quindi un polo che clicca senza
# essersi assicurato il fronte ha cliccato su un'altra app.
front() {
  for _ in $(seq 1 6); do
    open -a "$APP_ABS" 2>/dev/null || true
    sleep 1.5
    dump
    [ "$(field "d['appActive']")" = "True" ] && { sleep 0.5; return 0; }
  done
  echo "      T4A non viene davanti: qualcuno se la prende"
  STATUS=1
  return 1
}

# Via davvero, con un gesto vero. Il Finder è sempre lì e non ha niente da
# perdere.
via() { osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1; sleep 2; }

clicca_nel_terminale() {
  dump
  local x y
  read -r x y <<<"$(termxy)"
  .build/t4a-click "$x" "$y"
  sleep 1.2
}

t4a_note_his_app
echo "==> bundle: $APP_ABS"
echo "==> configurazione: $CFG"
open -n "$APP_ABS" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "il canale di prova non è mai comparso" >&2; exit 1; }
sleep 3
# La bolla sempre visibile: qui si misura DOVE va la tastiera, non quando la
# bolla si mostra (quella ha il suo banco). La prova sulla sua configurazione,
# con `composer-mode = agent`, si fa con --with-claude.
# `T4A_BENCH_KEEP_MODE=1` lascia la configurazione com'è e salta i poli
# vergini: è il modo in cui questo banco si esegue sulla SUA configurazione,
# dove `composer-mode = agent` e la bolla esiste solo con un agente vero. Un
# banco che scrivesse `always` là dentro misurerebbe la propria impostazione.
KEEP_MODE="${T4A_BENCH_KEEP_MODE:-0}"
[ "$KEEP_MODE" = "1" ] || { send "composer-mode always"; sleep 1; }
front || true

poli_vergini() {
echo
echo "=== 1. tornare da un'altra app ====================================="
clicca_nel_terminale
dump
check "1a un clic vero nel terminale gli dà la tastiera" "$(resp)" "TappedTerminalView"
via
dump
check "1b il Finder è davanti, T4A no" "$(field "d['appActive']")" "False"
check "1b la tastiera non si è mossa da sola" "$(resp)" "TappedTerminalView"
front || true
dump
check "1c torni su T4A e la tastiera è nella bolla" "$(resp)" "ComposerField"
note "   (la bolla è mostrata?)" "shown=$(field "d['composer']['shown']")"
# La contabilità di `aggiornaTastiera` (`tastieraPrestata`, `bollaEraVisibile`)
# gira a ogni refresh, e un refresh lo fa qualunque byte in arrivo dal pannello:
# se i due contatori fossero incoerenti la tastiera tornerebbe nel terminale un
# istante dopo, cioè il difetto sarebbe invisibile a un banco che legge subito.
send "text echo rimbalzo\n"; sleep 2
dump
check "1d e non rimbalza al primo refresh che passa" "$(resp)" "ComposerField"

echo
echo "=== 2. scegliere una chat dal pannello di sinistra =================="
send "newtab"; sleep 2
clicca_nel_terminale
dump
check "2a due schede, la tastiera è nel terminale della seconda" "$(resp)" "TappedTerminalView"
note "   schede aperte" "$(field "len(d['tabs'])") · attiva $(field "d['band']['strip']['selected']")"
ALTRA="$(field "[r for r in d['rail']['rows'] if not r['selected']][0]['id']")"
RX="$(field "[r for r in d['rail']['rows'] if not r['selected']][0]['row_x']")"
RY="$(field "[r for r in d['rail']['rows'] if not r['selected']][0]['row_y']")"
note "   clic vero sulla riga non selezionata" "($RX, $RY)"
.build/t4a-click "$RX" "$RY"; sleep 1.5
dump
check "2b la tastiera è nella bolla" "$(resp)" "ComposerField"
check "2c ed è la sessione che ho cliccato" \
  "$(field "[q['id'] for t in d['tabs'] for q in t['panes'] if q['active']][0] == '$ALTRA'")" "True"

echo
echo "=== 3. scegliere una scheda dalla striscia =========================="
send "layout tabs"; sleep 1.5
clicca_nel_terminale
dump
check "3a la tastiera è nel terminale" "$(resp)" "TappedTerminalView"
PRIMA="$(field "d['band']['strip']['selected']")"
BX="$(field "[b for i, b in enumerate(d['band']['strip']['boxes']) if i != d['band']['strip']['selected']][0]['x']")"
BY="$(field "[b for i, b in enumerate(d['band']['strip']['boxes']) if i != d['band']['strip']['selected']][0]['y']")"
note "   clic vero sull'altra scheda" "($BX, $BY)"
.build/t4a-click "$BX" "$BY"; sleep 1.5
dump
check "3b la tastiera è nella bolla" "$(resp)" "ComposerField"
check "3c ed è cambiata scheda" "$(field "d['band']['strip']['selected'] != $PRIMA")" "True"

clicca_nel_terminale
dump
check "3d ⌘2: prima la tastiera è nel terminale" "$(resp)" "TappedTerminalView"
.build/t4a-keypress 19 cmd app=dev.t4a.terminal; sleep 1.5     # ⌘2
dump
check "3e ⌘2 vero, e la tastiera è nella bolla" "$(resp)" "ComposerField"
check "3f ed è la seconda scheda" "$(field "d['band']['strip']['selected']")" "1"

echo
echo "=== 5. NEGATIVO, il ladro: la ricerca e le impostazioni ============"
# Prima la ricerca, che vive DENTRO questa finestra: è il caso in cui la regola
# potrebbe rubare e non deve.
send "find ciao"; sleep 1.5
dump
check "5a la ricerca ha la tastiera" "$(resp)" "NSTextView"
via
front || true
dump
check "5b torni, e la ricerca ce l'ha ancora" "$(resp)" "NSTextView"
send "findclose"; sleep 1

# Poi le impostazioni, che sono un'ALTRA finestra: tornando sull'app è lei a
# tornare chiave, quindi la finestra principale non riceve niente e il suo
# primo responder non si muove.
clicca_nel_terminale
dump
check "5c la tastiera è nel terminale" "$(resp)" "TappedTerminalView"
send "settings open"; sleep 2
via
front || true
dump
check "5d impostazioni aperte" "$(field "len([t for t in d['windowTitles'] if 'Settings' in t]) > 0")" "True"
check "5e torni, e il responder della principale non è cambiato" "$(resp)" "TappedTerminalView"
send "settings close"; sleep 1.5

echo
echo "=== 4. NEGATIVO, la domanda sullo schermo ==========================="
cat > "$FAKEBIN/fake.c" <<'EOF'
#include <unistd.h>
int main(int argc, char **argv) { execl("/bin/sh", "claude", (char *)0); return 1; }
EOF
/usr/bin/cc -o "$FAKEBIN/claude" "$FAKEBIN/fake.c" || { echo "il finto agente non compila" >&2; STATUS=1; }
send "newtab"; sleep 2
send "text $FAKEBIN/claude"; send "key return"; sleep 3
send 'text printf "Do you want to proceed?\n\342\235\257 1. Yes\n  2. No\nEnter to confirm \302\267 Esc to cancel\n"'
send "key return"; sleep 2
send "scan"; sleep 1.5
dump
check "4a un agente è agganciato" \
  "$(field "[q['attached'] for t in d['tabs'] for q in t['panes'] if q['active']][0]")" "True"
check "4b e l'app vede la domanda" \
  "$(field "[q['asking'] for t in d['tabs'] for q in t['panes'] if q['active']][0]")" "True"
note "   cosa ha letto" "$(field "[q['reading'] for t in d['tabs'] for q in t['panes'] if q['active']][0]")"
clicca_nel_terminale
via
front || true
send "scan"; sleep 1
dump
check "4c torni, e la tastiera va alla SUPERFICIE, non alla bolla" "$(resp)" "TappedTerminalView"
check "4d la domanda è ancora sullo schermo" \
  "$(field "[q['asking'] for t in d['tabs'] for q in t['panes'] if q['active']][0]")" "True"
# La tastiera è PRESTATA, non tolta: finita la domanda torna nella bolla da
# sé, per la contabilità di `aggiornaTastiera`. Senza questo polo «va alla
# superficie» e «ci resta per sempre» sarebbero lo stesso verde.
send "clearbuffer"; sleep 1
send "scan"; sleep 1.5
dump
check "4e finita la domanda, il prestito torna alla bolla" "$(resp)" "ComposerField"
check "4f e la domanda non c'è più" \
  "$(field "[q['asking'] for t in d['tabs'] for q in t['panes'] if q['active']][0]")" "False"
send "text exit"; send "key return"; sleep 1.5
}

[ "$KEEP_MODE" = "1" ] || poli_vergini

if [ "$WITH_CLAUDE" = "1" ]; then
  echo
  echo "=== la prova con claude VERO ========================================"
  if ! command -v claude >/dev/null 2>&1; then
    echo "      claude non è nel PATH: la prova viva NON è stata fatta"
    STATUS=1
  else
    # Una cartella fissa, mai il repo: `claude` avviato qui dentro prenderebbe
    # le istruzioni e gli hook di questo progetto, e una cartella nuova ogni
    # volta lascia una voce morta nella sua configurazione (ISC-132).
    CHATDIR="$HOME/Movies/t4a-bench-chat"
    mkdir -p "$CHATDIR"
    send "newtab"; sleep 2
    send "text cd $CHATDIR && claude"; send "key return"
    for _ in $(seq 1 45); do
      dump
      [ "$(field "[q['attached'] for t in d['tabs'] for q in t['panes'] if q['active']][0]")" = "True" ] && break
      sleep 2
    done
    check "L1 claude è agganciato" \
      "$(field "[q['attached'] for t in d['tabs'] for q in t['panes'] if q['active']][0]")" "True"
    note "   la bolla, con la sua configurazione" \
      "mode=$(field "d['composer']['mode']") shown=$(field "d['composer']['shown']")"
    clicca_nel_terminale
    dump
    note "   prima del giro" "$(resp)"
    via
    front || true
    dump
    check "L2 vai al Finder, torni, e la tastiera è nella bolla" "$(resp)" "ComposerField"
    # `/exit` con la tastiera nella bolla ci finirebbe dentro: la si riporta
    # nel terminale con un clic vero, che è come lo farebbe lui.
    clicca_nel_terminale
    send "text /exit"; send "key return"; sleep 3
  fi
fi

t4a_stop_bench
rm -f "$FIFO"
[ "$STATUS" = "0" ] && echo "focus-return: ogni polo tiene" || echo "focus-return: un polo FALLITO"
exit "$STATUS"
