#!/bin/bash
# La finestra di T4A fotografata dal SERVER DELLE FINESTRE, terminale compreso.
#
#   Scripts/shot.sh [pid] <file.png>
#
# Il comando `shot` del canale disegna dalle viste, e il terminale è uno strato
# Metal: là esce bianco (vedi `testShot`). Questo passa da `screencapture -l`,
# che vede quello che vedi tu. Il permesso di registrazione dello schermo serve
# al PROCESSO CHE LANCIA il banco, non all'app: è la regola dei permessi minimi
# di T4A, e il motivo per cui questa strada sta in uno script e non dentro
# l'app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ge 2 ]; then PID="$1"; OUT="$2"; else
  PID="$(pgrep -f 'T4A.app/Contents/MacOS/T4A' | head -1)"; OUT="$1"
fi
[ -n "${PID:-}" ] || { echo "nessuna T4A viva" >&2; exit 1; }
[ -x .build/t4a-winid ] || swiftc -O Scripts/winid.swift -o .build/t4a-winid
WID="$(.build/t4a-winid "$PID" | head -1)"
[ -n "$WID" ] || { echo "nessuna finestra per il pid $PID" >&2; exit 1; }
screencapture -o -x -l "$WID" "$OUT"
# Una foto tutta bianca è il sintomo del permesso mancante, e va detto qui
# invece di lasciare che il banco la guardi e concluda che l'app è rotta.
if [ ! -s "$OUT" ]; then
  echo "screencapture non ha scritto niente: manca il permesso di registrazione dello schermo?" >&2
  exit 2
fi
echo "$OUT"
