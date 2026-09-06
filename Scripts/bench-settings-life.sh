#!/bin/bash
# ISC-191 e ISC-193 — il pannello delle impostazioni come cosa che si tocca e
# che si chiude.
#
#   Scripts/bench-settings-life.sh [app-bundle]
#
# ISC-191 — «questo non mi permette di toglierlo e metterlo», detto
# dell'interruttore «Running work». La causa non è l'interruttore: è che il
# pannello si RICOSTRUISCE a ogni battito del fornitore mentre la categoria
# «Dashboard rows» è aperta, e una ricostruzione che cade fra la pressione e
# il rilascio di un click vero porta via la vista su cui il click è stato
# fatto. Il gesto muore lì, senza errori e senza traccia.
#
# Per questo i poli girano con un fornitore a 0,3 s e un click tenuto 400 ms:
# così la ricostruzione cade DENTRO ogni pressione e il difetto smette di
# essere una moneta lanciata. Misurato il 27/08 sul bundle di prima: sei
# click su sei non hanno fatto niente. Col fornitore vero dell'autore, che
# batte ogni 2 s, ne moriva uno ogni tre o quattro — che è peggio, perché
# sembra un interruttore lunatico invece che un interruttore rotto.
#
# Il polo 2 misura la seconda metà: il bersaglio è 34×18 dentro una riga alta
# 46 e larga quanto il pannello, e nove punti sopra il centro sono già fuori
# (misurato lo stesso giorno, otto punti attorno all'interruttore). Adesso la
# riga intera è l'interruttore, che è la regola di casa sui bottoni.
#
# ISC-193 — «quando chiudo l'app devi chiudere anche i settings insieme».
# Chiusa la principale, il pannello se ne va con lei e il processo esce.
#
# I poli 4 e 5 sono i negativi che tengono onesta la riparazione della riga:
# un rilascio fuori dalla riga non commuta niente, e una riga con più comandi
# non è diventata un interruttore largo quanto il pannello.
#
# IL POLO SU HEAD si esegue passando un altro bundle:
#
#   git archive HEAD | (mkdir -p /tmp/t4a-head && tar -x -C /tmp/t4a-head)
#   # più la sola diagnostica `switchRects` in `testSettingsState`, senza la
#   # quale il banco non sa dove sta l'interruttore. È un campo del dump, non
#   # un comportamento: senza, il polo non isolerebbe la riparazione.
#   (cd /tmp/t4a-head && swift build -c release && Scripts/build-app.sh)
#   Scripts/bench-settings-life.sh /tmp/t4a-head/dist/T4A.app
#
# Là i poli 1, 2, 3 e 6 devono FALLIRE. Se passano, la riparazione non era
# quella, e il resoconto lo dice invece di prendersi il merito.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO=/tmp/t4a-slife.fifo
CONFIG_HOME=/tmp/t4a-slife-config
PROV=/tmp/t4a-slife-provider.sh
DUMP=/tmp/t4a-slife-dump.json
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done
}
field() { /usr/bin/python3 -c "import json;d=json.load(open('$DUMP'));print($1)"; }
verdict() {
  local name="$1" ok="$2" detail="$3"
  printf '%-56s %s  %s\n' "$name" "$([ "$ok" = "0" ] && echo PASS || echo FAIL)" "$detail"
  [ "$ok" = "0" ] || STATUS=1
}

[ -x .build/t4a-click ] || swiftc -O Scripts/clickpoint.swift -o .build/t4a-click
[ -x .build/t4a-drag ] || swiftc -O Scripts/dragpoint.swift -o .build/t4a-drag

t4a_note_his_app
t4a_stop_bench; sleep 1.5
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME/t4a"
# Un fornitore che cambia a OGNI battito, perché `onUpdate` scatta solo quando
# una lettura è cambiata davvero: un contatore è ciò che rende il caso peggiore
# riproducibile invece che casuale. `composer-mode = agent` come da lui.
cat > "$PROV" <<'SH'
#!/bin/bash
printf '#name\tusage\tUsage\n'; printf 'usage\t5HR %s\tmuted\n' "$(date +%s%N)"
SH
chmod +x "$PROV"
cat > "$CONFIG_HOME/t4a/config.toml" <<TOML
composer-mode = agent
pure-chat = true
facts-provider = "$PROV"
facts-interval = 0.3
TOML

open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3
send "activate"; sleep 1
send "settings open"; sleep 1
# `settings <nome>`, non `settings category <nome>`: il canale prende tutto il
# resto della riga come nome della categoria. Scritto con `category` davanti,
# `currentCategory` diventa la stringa «category Dashboard rows», il pannello
# giusto compare lo stesso (è il ramo `default`) e la guardia che ricostruisce
# smette di combaciare — cioè il banco misurerebbe l'app con il difetto
# spento. Costato due giri di sonde il 27/08.
send "settings Dashboard rows"; sleep 1
send "settings place 200,200,880,592"; sleep 1
dump

CAT="$(field "d['settings']['category']")"
POLE=0; [ "$CAT" = "Dashboard rows" ] || POLE=1
verdict "0 la categoria aperta è davvero «Dashboard rows»" "$POLE" "category=$CAT"
[ "$POLE" = "0" ] || { echo "senza la categoria giusta i poli sotto non misurano niente" >&2; }

X="$(field "round(d['settings']['switchRects']['Running work']['x'])")"
Y="$(field "round(d['settings']['switchRects']['Running work']['y'])")"
echo "      interruttore  centro $X,$Y  $(field "'%dx%d' % (d['settings']['switchRects']['Running work']['w'], d['settings']['switchRects']['Running work']['h'])")   fornitore runs=$(field "d['dash']['facts']['runs']")"
echo

# Un click, e la sola domanda che conta: lo stato è cambiato?
click_toggles() {  # dx dy holdMs -> SI/NO
  local dx="$1" dy="$2" hold="$3" before after
  dump; before="$(field "'worker' in d['dash']['off']")"
  .build/t4a-click "$((X + dx))" "$((Y + dy))" "$hold" >/dev/null 2>&1
  sleep 1
  dump; after="$(field "'worker' in d['dash']['off']")"
  [ "$before" != "$after" ] && echo SI || echo NO
}

echo "=== 1. ISC-191: sei click veri tenuti 400 ms, col pannello che batte ==="
OK=0
for i in $(seq 1 6); do
  R="$(click_toggles 0 0 400)"
  printf '      click %s in mezzo all'\''interruttore: commutato=%s\n' "$i" "$R"
  [ "$R" = "SI" ] && OK=$((OK + 1))
done
POLE=0; [ "$OK" = "6" ] || POLE=1
verdict "1 sei click su sei commutano (ROSSO su HEAD: 0 su 6)" "$POLE" "$OK su 6"

echo
echo "=== 2. e la riga intera è l'interruttore ==========================="
# Fuori dall'interruttore (alto 18, quindi il bordo è a nove) e dentro la riga
# (alta 46): il punto dove cade un dito che mira e sbaglia di poco.
R="$(click_toggles 0 -12 120)"
POLE=0; [ "$R" = "SI" ] || POLE=1
verdict "2 dodici punti sopra il centro (ROSSO su HEAD)" "$POLE" "commutato=$R"

echo
echo "=== 3. e anche il NOME, che è l'altra metà della riga =============="
R="$(click_toggles -300 0 120)"
POLE=0; [ "$R" = "SI" ] || POLE=1
verdict "3 il nome «Running work» commuta (ROSSO su HEAD)" "$POLE" "commutato=$R"

echo
echo "=== 4. il negativo: premuto sulla riga, rilasciato altrove ========="
dump; BEFORE="$(field "'worker' in d['dash']['off']")"
.build/t4a-drag "$X" "$((Y - 12))" "$X" "$((Y + 60))" >/dev/null 2>&1
sleep 1; dump; AFTER="$(field "'worker' in d['dash']['off']")"
POLE=0; [ "$BEFORE" = "$AFTER" ] || POLE=1
verdict "4 rilasciato fuori dalla riga: non commuta" "$POLE" "prima=$BEFORE dopo=$AFTER"

echo
echo "=== 5. il negativo: una riga con più comandi non è un interruttore ="
# La fila «Input» di Layout ha due bottoni uno-di-N. Cliccata nel mezzo, dove
# non c'è nessun comando, non deve succedere niente: la riparazione vale per la
# riga che ha UN interruttore e per nessun'altra.
send "settings Layout"; sleep 1
dump
HAS="$(field "'the T4A bubble' in d['settings']['choices']")"
if [ "$HAS" != "True" ]; then
  # Fallire chiuso: la prima stesura di questo polo cercava un bottone che non
  # c'era, cliccava a coordinate vuote e usciva VERDE senza aver misurato
  # niente. Un polo che non trova il suo bersaglio è rosso, non silenzioso.
  verdict "5 la fila di scelte non commuta se cliccata nel vuoto" 1 \
    "bersaglio assente: choices=$(field "sorted(d['settings']['choices'])")"
else
  CX="$(field "round(d['settings']['choices']['the T4A bubble']['x'])")"
  CY="$(field "round(d['settings']['choices']['the T4A bubble']['y'])")"
  BEFORE="$(field "d['settings']['choiceSelected']")"
  .build/t4a-click "$((CX - 200))" "$CY" 120 >/dev/null 2>&1
  sleep 1; dump
  AFTER="$(field "d['settings']['choiceSelected']")"
  POLE=0; [ "$BEFORE" = "$AFTER" ] || POLE=1
  verdict "5 la fila di scelte non commuta se cliccata nel vuoto" "$POLE" \
    "$([ "$BEFORE" = "$AFTER" ] && echo "invariata, cliccata a $((CX - 200)),$CY" || echo "cambiata")"
fi

echo
echo "=== 6. ISC-193: chiusa la finestra, il pannello e l'app se ne vanno ="
send "settings open"; sleep 1
dump
echo "      pannello aperto=$(field "d['settings']['open']")   finestre visibili=$(field "d['windows']")"
echo "      pid del banco: $(t4a_bench_pids | tr '\n' ' ')"
send "closewindow"
ALIVE=""
for _ in 1 2 3 4 5 6; do
  sleep 0.5
  ALIVE="$(t4a_bench_pids | tr '\n' ' ')"
  [ -z "${ALIVE// /}" ] && break
done
POLE=0; [ -z "${ALIVE// /}" ] || POLE=1
verdict "6 chiusa la principale, il processo esce (ROSSO su HEAD)" "$POLE" \
  "$([ -z "${ALIVE// /}" ] && echo "uscito entro 3 s" || echo "ancora vivo: $ALIVE")"

t4a_stop_bench
rm -f "$FIFO" "$PROV"
[ "$STATUS" = "0" ] && echo "settings-life: ogni polo ha tenuto" \
  || echo "settings-life: un polo È FALLITO"
exit "$STATUS"
