#!/bin/bash
# Il crash del 26/08 09:33:34 — un tooltip che parla a memoria liberata.
#
#   Scripts/bench-tooltip.sh [app-bundle]
#
# COSA MISURA. Il puntatore VERO si posa sui comandi della testa
# dell'anteprima e ci resta, che è il gesto che ha ucciso la sua T4A e che
# nessun banco faceva: `bench-preview.sh` leggeva le frasi dal dump, cioè da
# una struttura dati, e un tooltip letto lì non è un tooltip mostrato.
#
#   1. l'app è viva dopo aver tenuto il puntatore fermo su ogni comando;
#   2. e il tooltip è COMPARSO davvero (`window.toolTipShowing`, che è la
#      finestra di AppKit e non una nostra registrazione).
#
# Il polo 2 non è decorazione: rifare i tooltip a ogni disegno non fa
# crashare niente, disarma il timer, e il suggerimento non appare MAI. Un
# banco che guardasse solo «l'app è viva» darebbe verde su quel guasto.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-tip.fifo"
CONFIG_HOME="/tmp/t4a-tip-config"
DUMP=/tmp/t4a-tip-dump.json
WORK=/tmp/t4a-tip
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
swift build --package-path . -c debug >/dev/null 2>&1 || true
[ -x .build/t4a-movepoint ] || swiftc -O Scripts/movepoint.swift -o .build/t4a-movepoint

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done
}
field() { /usr/bin/python3 -c "import json;d=json.load(open('$DUMP'));print($1)"; }
verdict() {
  printf '%-56s %s  %s\n' "$1" "$([ "$2" = "0" ] && echo PASS || echo FAIL)" "$3"
  [ "$2" = "0" ] || STATUS=1
}

t4a_stop_bench
sleep 1
rm -rf "$CONFIG_HOME" "$WORK" "$FIFO"; mkdir -p "$CONFIG_HOME" "$WORK"
printf '# Un file da anteprimare\n\nDue righe, e basta.\n' > "$WORK/nota.md"

open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3
PID="$(pgrep -f "$APP/Contents/MacOS/T4A" | head -1)"

send "preview-path $WORK/nota.md"; sleep 2
dump
SHOWING="$(field "d['preview']['showing']")"
verdict "l'anteprima è aperta" "$([ "$SHOWING" = "True" ] && echo 0 || echo 1)" "showing=$SHOWING"

# Ogni comando della testa, uno per uno: ci si posa sopra e ci si resta.
CONTROLS="$(field "' '.join(sorted(d['preview']['controls']))")"
for NAME in $CONTROLS; do
  X="$(field "d['preview']['controls']['$NAME']['x']")"
  Y="$(field "d['preview']['controls']['$NAME']['y']")"
  .build/t4a-movepoint "$X" "$Y" >/dev/null 2>&1
  # Il tooltip di AppKit ci mette il suo tempo, e la striscia in basso
  # ridisegna nel frattempo: è esattamente la finestra in cui il difetto
  # liberava l'oggetto sotto il timer.
  SEEN=false
  for _ in $(seq 1 12); do
    sleep 0.5
    dump 2>/dev/null || break
    [ "$(field "d['window']['toolTipShowing']" 2>/dev/null)" = "True" ] && { SEEN=true; break; }
  done
  ALIVE=1; kill -0 "$PID" 2>/dev/null && ALIVE=0
  verdict "vivo col puntatore fermo su «${NAME}»" "$ALIVE" "pid=$PID"
  [ "$ALIVE" = "0" ] || break
  verdict "il tooltip di «${NAME}» è comparso" "$([ "$SEEN" = "true" ] && echo 0 || echo 1)" "shown=$SEEN"
  # Via dal comando, così il prossimo hover riparte da fermo.
  .build/t4a-movepoint 40 400 >/dev/null 2>&1; sleep 1
done

t4a_stop_bench
rm -f "$FIFO"
exit $STATUS
