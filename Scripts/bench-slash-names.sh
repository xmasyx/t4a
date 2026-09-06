#!/bin/bash
# ISC-187 — con che NOME claude espone una skill e un comando di plugin.
#
#   Scripts/bench-slash-names.sh [app-bundle]
#
# COSA MISURA, e perché non è una lettura di documentazione.
#
#   Il catalogo di T4A costruisce i nomi dalle stesse fonti che legge claude:
#   la cartella di una skill diventa `/<cartella>`, un comando di un plugin
#   diventa `/<plugin>:<comando>`. Quelle due regole NON sono scritte da
#   nessuna parte che si possa citare: sono state dedotte. L'unico posto dove
#   si leggono davvero è il menu di claude, quindi qui si apre claude VERO,
#   si scrive `/` più un prefisso, e si legge la griglia.
#
#   Non si manda MAI un messaggio all'agente: si scrive nella riga e si
#   cancella. L'unico invio è `/exit`.
#
#   Il polo che rende leggibile un rosso è il passo 1: `/cs` è un comando
#   `.md` in `commands/`, la forma su cui non c'è dubbio. Se non compare
#   nemmeno quello, il banco sta misurando un menu che non si è aperto, e i
#   due passi dopo non vogliono dire niente.
#
# Effetto collaterale dichiarato: claude gira con la configurazione VERA (è il
# punto — servono le skill e i plugin di casa), quindi lascia dietro di sé una
# sessione in `~/.claude/projects` e una voce di progetto in `~/.claude.json`,
# come qualunque altro avvio di claude.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-slash.fifo"
CONFIG_HOME="/tmp/t4a-slash-config"
DUMP=/tmp/t4a-slash-dump.json
WORK="$HOME/Movies/t4a-bench-chat"
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
t4a_note_his_app

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1" >/dev/null; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done
}
field() { /usr/bin/python3 -c "import json;d=json.load(open('$DUMP'));print($1)" 2>/dev/null; }
screen() {
  /usr/bin/python3 -c "
import json
d=json.load(open('$DUMP'))
for line in d['tabs'][0]['panes'][0]['screen']:
    line=line.rstrip()
    if line: print('    |'+line)
" 2>/dev/null
}
verdict() {
  printf '%-58s %s  %s\n' "$1" "$([ "$2" = "0" ] && echo PASS || echo FAIL)" "${3:-}"
  [ "$2" = "0" ] || STATUS=1
}
# Cancella la riga d'ingresso di claude un carattere per volta: il canale non
# conosce ctrl-U, e un `text` nuovo si accoderebbe al precedente.
erase() { for _ in $(seq 1 "$1"); do send "key backspace"; done; sleep 0.6; }

mkdir -p "$WORK" "$CONFIG_HOME/t4a"
# Configurazione vergine, con `pure-chat = false`: la riga d'ingresso di claude
# deve essere VISIBILE, altrimenti il menu che questo banco legge non è sullo
# schermo che il dump riporta.
cat > "$CONFIG_HOME/t4a/config.toml" <<'TOML'
pure-chat = false
composer-mode = agent
TOML

rm -f "$FIFO"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "il canale non si è aperto" >&2; exit 1; }
sleep 1.5
BENCH_PID="$(pgrep -f 'T4A.app/Contents/MacOS/T4A' | grep -vxF "$(echo $T4A_PREEXISTING_PIDS | tr ' ' '\n')" | head -1)"
trap 't4a_stop_bench' EXIT

echo "==> claude vero in $WORK"
send "text cd $WORK && claude\\n"
ATTACHED=1
for _ in $(seq 1 60); do
  dump
  if [ "$(field "d['tabs'][0]['panes'][0]['attached']")" = "True" ]; then ATTACHED=0; break; fi
  sleep 1
done
verdict "0. claude è agganciato" "$ATTACHED" "$(field "d['tabs'][0]['panes'][0]['process']")"
[ "$ATTACHED" = "0" ] || { send "text /exit\\n"; exit 1; }
sleep 2

# Il percorso del binario dell'agente, che è l'INGRESSO del catalogo: senza
# quello non c'è niente da scansionare.
#
# QUESTO POLO È INTERMITTENTE, e il rosso è un difetto FUORI da questa fetta
# che va lasciato rosso. `AgentObserver.executable` è corretto — provato
# all'unità in `SlashCommandCatalogTests` col pid del processo di prova — ma in
# un aggancio vero il pid arriva solo a volte: `Session.probeForAgent` cammina
# l'albero dei processi del pannello, e quando `claude` viene riconosciuto
# l'albero è spesso ancora vuoto, quindi scatta il ripiego di
# `Session.swift:663`, che aggancia SENZA pid. Da lì in poi nessuno riprova, e
# `agentPid` resta nil per tutta la sessione — con lui resta spenta anche la
# lettura del transcript dal kernel (quella del 25/08).
# Misurato il 27/08 su 7 agganci veri: **2 col pid, 5 senza** (`agentPid` -1),
# mentre il pannello conosce benissimo il pid del suo processo in primo piano.
# Se questo polo esce rosso, NON è il banco che si è rotto: è quella corsa che
# è caduta nel ripiego.
EXE="$(field "d['agents'][0]['adapter']['executable']")"
CMD="$(field "d['tabs'][0]['panes'][0]['process']")"
PANEPID="$(field "d['tabs'][0]['panes'][0]['pid']")"
if [ -z "$EXE" ]; then
  verdict "0b. proc_pidpath dà il binario dell'agente" 1 \
    "vuoto — l'aggancio è avvenuto senza pid (il pannello però ha pid $PANEPID)"
elif [ -x "$EXE" ]; then
  # E il polo che rende la riga sopra una misura e non una constatazione: il
  # valore è un percorso eseguibile, e NON è il nome del processo.
  case "$EXE" in
    "$CMD") verdict "0b. proc_pidpath dà il binario dell'agente" 1 "è solo il nome del processo" ;;
    /*)     verdict "0b. proc_pidpath dà il binario dell'agente" 0 "$EXE" ;;
    *)      verdict "0b. proc_pidpath dà il binario dell'agente" 1 "non è un percorso assoluto: $EXE" ;;
  esac
else
  verdict "0b. proc_pidpath dà il binario dell'agente" 1 "non eseguibile: $EXE"
fi

probe() {                     # probe <testo> <etichetta>
  local typed="$1" label="$2"
  send "text $typed"; sleep 1.8
  dump
  echo "--- $label: ho scritto \"$typed\" ---"
  screen
  erase "${#typed}"
}

probe "/cs" "1. un comando .md in commands/ (la forma sicura)"
probe "/Inter" "2. una SKILL — la cartella si chiama Interceptor"
probe "/code-review" "3. un PLUGIN — la cartella si chiama code-review"

echo "==> chiudo claude"
send "text /exit\\n"; sleep 3
exit $STATUS
