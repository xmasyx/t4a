#!/bin/bash
# ISC-187 — l'elenco dei comandi `/` sopra la bolla, a tasti VERI.
#
#   Scripts/bench-slash.sh [app-bundle] [--with-claude] [--no-head]
#
# COSA MISURA. Il catalogo (`SlashCommandCatalog`, fetta B1) ha già il suo
# banco: `bench-slash-names.sh`, che legge i NOMI dal menu di claude vero.
# Questo qui misura l'altra metà, cioè la BOLLA — chi si apre, che cosa
# filtra, che cosa fanno i tasti e, soprattutto, che cosa NON arriva al
# processo. Per poterlo fare senza dipendere da quale claude è installato oggi,
# il catalogo viene puntato a mano su `Scripts/fixtures/slash-fixture.txt` col
# verbo `slash-catalog`: sei comandi, sempre gli stessi, su qualunque macchina.
#
# IL TESTIMONE È `cat -v` NEL PANNELLO. Ogni byte che raggiunge il PTY viene
# riecheggiato dal tty e finisce sulla griglia, `^[` compreso, quindi «l'elenco
# non ha scritto niente al processo» diventa una cosa che si LEGGE invece di
# una cosa che si asserisce. È l'anti-claim del brief: l'elenco si costruisce
# leggendo file, non interrogando l'agente.
#
# I TASTI SONO VERI, posati dal window server con `Scripts/keypress.swift`.
# Nessun polo chiama la funzione che il tasto avrebbe chiamato: «il campo
# accetta il Tab» non è «un Tab vero ci arriva» (lezione del 26/08).
#
# IL CODICE DI `/` DIPENDE DAL LAYOUT DI TASTIERA ATTIVO — su US è 44, su un
# layout italiano è shift+7 — quindi non è scritto qui: il passo 0 lo SCOPRE
# posando il tasto e leggendo `composer.text` dal dump, e se non lo trova il
# banco si ferma invece di misurare un `/` che non è mai stato scritto.
#
# I POLI NEGATIVI, che sono tre e nessuno è decorativo:
#   - un `/` che non è a inizio testo non apre niente (polo 7);
#   - uno spazio dopo il nome chiude l'elenco (polo 7b);
#   - il bundle di HEAD, costruito a parte, non ha `suggestions` nel dump
#     (polo 8): è quello che dice che i poli 1-6 misurano la riparazione e non
#     l'app in generale.
#
# NON PARTE SE UNA T4A TUA È GIÀ APERTA, e questo banco è più severo dei
# vicini di proposito: `keypress` posa il tasto su chi ha la tastiera, e con
# due T4A vive `app=dev.t4a.terminal` può scegliere la TUA — cioè scrivere
# nella tua sessione. Chiudila, o passa un momento in cui non ce n'è.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="dist/T4A.app"
WITH_CLAUDE=0
VS_HEAD=1
for arg in "$@"; do
  case "$arg" in
    --with-claude) WITH_CLAUDE=1 ;;
    --no-head)     VS_HEAD=0 ;;
    --*)           echo "opzione sconosciuta: $arg" >&2; exit 2 ;;
    *)             APP="$arg" ;;
  esac
done

BUNDLE_ID="dev.t4a.terminal"
FIFO="/tmp/t4a-slashlist.fifo"
CFG="/tmp/t4a-slashlist-config"
CACHE="/tmp/t4a-slashlist-cache"
OUT="/tmp/t4a-slashlist"
DUMP="$OUT/dump.json"
FIXTURE="$PWD/Scripts/fixtures/slash-fixture.txt"
HEADTREE="/tmp/t4a-head"
WORK="$HOME/Movies/t4a-bench-chat"
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "manca la fixture $FIXTURE" >&2; exit 1; }
if [ -n "${T4A_PREEXISTING_PIDS// /}" ]; then
  echo "==> c'è già una T4A aperta (pid${T4A_PREEXISTING_PIDS%% *})."
  echo "    Questo banco posa tasti VERI e non può garantire su quale finestra"
  echo "    finiscono. Non parte. Chiudi quella T4A e rilancia."
  exit 1
fi

[ -x "Scripts/.build-keypress" ] || swiftc -O -o Scripts/.build-keypress Scripts/keypress.swift

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1" >/dev/null; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 60); do [ -s "$DUMP" ] && break; sleep 0.1; done
}
field() { /usr/bin/python3 -c "import json;d=json.load(open('$DUMP'));print($1)" 2>/dev/null; }
# La griglia del pannello, su una riga sola: è il testimone di `cat -v`.
grid() {
  /usr/bin/python3 -c "
import json
d=json.load(open('$DUMP'))
print(' | '.join(l.rstrip() for l in d['tabs'][0]['panes'][0]['screen'] if l.strip()))
" 2>/dev/null
}
screen() {
  /usr/bin/python3 -c "
import json
d=json.load(open('$DUMP'))
for l in d['tabs'][0]['panes'][0]['screen']:
    l=l.rstrip()
    if l: print('    |'+l)
" 2>/dev/null
}
check() {
  local nome="$1" got="$2" want="$3" mark=PASS
  [ "$got" = "$want" ] || { mark=FAIL; STATUS=1; }
  printf '%-56s got %-34s want %-26s %s\n' "$nome" "[$got]" "[$want]" "$mark"
}
# Un tasto vero, con l'app davanti — e con tre tentativi, perché
# l'attivazione è una RICHIESTA al window server e su una scrivania viva
# un'altra app può prendersi il fuoco proprio in quel mezzo secondo (visto il
# 27/08: `dev.t4a.terminal never came to the front` a metà corsa, con la stessa
# app che un attimo prima aveva risposto). Fra un tentativo e l'altro si chiede
# all'app di venire avanti da sé, che è la via che macOS non rifiuta.
KP() {
  local try
  for try in 1 2 3 4; do
    # L'app viene avanti DA SÉ prima di ogni tasto. Su macOS un processo che
    # chiede il fuoco per conto di un altro viene rifiutato, mentre
    # `NSApp.activate` dall'interno no — ed è la differenza fra un banco che
    # gira su una scrivania vuota e uno che gira su quella di qualcuno che
    # lavora (visto il 27/08: `never came to the front` a metà corsa, con la
    # stessa app che un attimo prima aveva risposto).
    send "activate"; sleep 0.4
    if Scripts/.build-keypress "$@" "app=$BUNDLE_ID"; then sleep 0.7; return 0; fi
    sleep 1
  done
  echo "    il tasto non è arrivato: l'app non viene davanti" >&2
  STATUS=1
  return 1
}
clear_bubble() { send "compose"; sleep 0.6; }

apri() {                       # apri <bundle> <config-home>
  rm -rf "$2" "$CACHE"; mkdir -p "$2/t4a" "$CACHE"
  rm -f "$FIFO"
  open -n "$1" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$2" \
       --env XDG_CACHE_HOME="$CACHE"
  for _ in $(seq 1 80); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "il canale non si è aperto" >&2; return 1; }
  sleep 3
}

rm -rf "$OUT"; mkdir -p "$OUT"
trap 't4a_stop_bench' EXIT

# ---------------------------------------------------------------- l'app
apri "$APP" "$CFG" || exit 1
send "composer-mode always"; sleep 1
# `cat -v` è il testimone: da qui in poi qualunque byte che arrivi al PTY si
# legge sulla griglia.
send "text cat -v"; send "key return"; sleep 1.5
send "slash-catalog $FIXTURE"; sleep 2
send "activate"; sleep 0.5
# ⌘L porta la tastiera nella bolla (ISC-158): il gesto vero.
KP 37 cmd
dump
check "la tastiera è nella bolla" "$(field "d['composer']['firstResponder']")" "ComposerField"
check "il catalogo ha letto la fixture" "$(field "d['composer']['suggestions']['state']")" "ready"
# `items` è quello che sta SULLO SCHERMO, e a bolla vuota lo schermo è vuoto:
# il conto dei sei comandi si chiede al catalogo, che è `builtin`.
check "e ha sei comandi" "$(field "d['composer']['suggestions']['builtin']")" "6"
check "e nessun comando di questa macchina" \
  "$(field "d['composer']['suggestions']['declared']")" "0"
check "a bolla vuota l'elenco è chiuso" \
  "$(field "d['composer']['suggestions']['shown']")" "False"

echo
echo "=== passo 0 — quale tasto scrive '/' su QUESTA tastiera ==============="
SLASH=""
# Due passate sulle due candidate, non una: un tasto perso per una contesa sul
# fuoco (vedi `KP`) direbbe «questo codice non scrive /» di un codice che lo
# scrive, e il banco si fermerebbe su una misura del window server.
for spec in "44" "26 shift" "44" "26 shift"; do
  clear_bubble
  # shellcheck disable=SC2086
  KP $spec
  dump
  TESTO="$(field "d['composer']['text']")"
  printf '    keyCode %-10s -> composer.text [%s]\n' "$spec" "$TESTO"
  [ "$TESTO" = "/" ] && { SLASH="$spec"; break; }
done
if [ -z "$SLASH" ]; then
  echo "    nessuno dei due scrive '/': il banco si ferma invece di misurare un tasto che non c'è."
  STATUS=1
  t4a_stop_bench
  exit 1
fi
echo "    -> uso keyCode [$SLASH]"
SL() { # shellcheck disable=SC2086
       KP $SLASH; }

BASE=""
clear_bubble
dump
BASE="$(grid)"
echo "    griglia di partenza: [$BASE]"

echo
echo "=== 1. '/' apre l'elenco con tutte le voci della fixture =============="
SL
dump
check "l'elenco è aperto" "$(field "d['composer']['suggestions']['shown']")" "True"
check "sono le sei della fixture" \
  "$(field "','.join(i['name'] for i in d['composer']['suggestions']['items'])")" \
  "compact,compress,context,forge,model,review"
check "la sorgente è dichiarata riga per riga" \
  "$(field "sorted(set(i['source'] for i in d['composer']['suggestions']['items']))[0]")" "built-in"
check "e la scelta parte dalla prima" "$(field "d['composer']['suggestions']['selected']")" "0"
# IL RETTANGOLO, non la bandiera. `shown` dice solo che la vista non è
# nascosta, e la prima versione di questa fetta disegnava un riquadro alto 12
# punti — la sola imbottitura, zero righe — con `shown` VERO e tutti i poli qui
# sopra verdi. L'ha scoperto una foto. Un'altezza che deve contenere le righe
# che l'elenco dichiara è la domanda giusta, e costa una riga.
H="$(field "d['composer']['suggestions']['frame']['h']")"
ATTESA="$(field "6*30+12")"
check "ed è alto quanto le sei righe" "$H" "$ATTESA"
check "largo quanto la carta della bolla" \
  "$(field "d['composer']['suggestions']['frame']['w'] > 200")" "True"

echo
echo "=== 2. 'c','o' filtrano ==============================================="
KP 8; KP 31
dump
check "il testo della bolla" "$(field "d['composer']['text']")" "/co"
check "restano le tre che cominciano per co" \
  "$(field "','.join(i['name'] for i in d['composer']['suggestions']['items'])")" \
  "compact,compress,context"

echo
echo "=== 3. la freccia giù sposta la scelta ================================"
KP 125
dump
check "selected" "$(field "d['composer']['suggestions']['selected']")" "1"

echo
echo "=== 4. Tab completa, chiude, e NON scrive al processo ================="
KP 48
dump
check "la bolla porta il comando con lo spazio" "$(field "d['composer']['text']")" "/compress "
check "l'elenco è chiuso" "$(field "d['composer']['suggestions']['shown']")" "False"
check "cat -v non ha ricevuto niente" "$(grid)" "$BASE"

echo
echo "=== 5. Esc chiude l'elenco; il SECONDO Esc è il ^[ di ISC-171 ========="
clear_bubble
SL; KP 8
dump
check "l'elenco è aperto su /c" "$(field "d['composer']['suggestions']['shown']")" "True"
KP 53
dump
check "il primo Esc lo chiude" "$(field "d['composer']['suggestions']['shown']")" "False"
check "e il testo resta" "$(field "d['composer']['text']")" "/c"
check "senza scrivere ^[ al processo" "$(grid)" "$BASE"
KP 53
dump
ESC_ARRIVATO="$(field "'^[' in ' | '.join(d['tabs'][0]['panes'][0]['screen'])")"
check "il secondo Esc arriva al processo" "$ESC_ARRIVATO" "True"
screen

echo
echo "=== 6. Invio completa E manda il comando intero ======================="
clear_bubble
send "text \\n"; sleep 0.5      # una riga pulita in cat -v prima di misurare
KP 37 cmd
SL; KP 8; KP 31; KP 125; KP 36
sleep 1.5
dump
check "la bolla è vuota" "$(field "d['composer']['text']")" ""
check "l'elenco è chiuso" "$(field "d['composer']['suggestions']['shown']")" "False"
check "cat -v ha ricevuto /compress" \
  "$(field "'/compress' in ' | '.join(d['tabs'][0]['panes'][0]['screen'])")" "True"
screen

echo
echo "=== 7. negativo: un '/' che non è a inizio testo non apre niente ======"
clear_bubble
KP 8; KP 34; KP 0; KP 31; KP 49   # c i a o spazio
SL
dump
check "il testo" "$(field "d['composer']['text']")" "ciao /"
check "l'elenco NON si apre" "$(field "d['composer']['suggestions']['shown']")" "False"

echo
echo "=== 7b. negativo: lo spazio dopo il nome chiude l'elenco =============="
clear_bubble
SL; KP 8; KP 31
dump
check "aperto su /co" "$(field "d['composer']['suggestions']['shown']")" "True"
KP 49
dump
check "lo spazio lo chiude" "$(field "d['composer']['suggestions']['shown']")" "False"
check "il testo è /co più lo spazio" "$(field "repr(d['composer']['text'])")" "'/co '"

clear_bubble
t4a_stop_bench
sleep 1

# ------------------------------------------------- 8. controllo contro HEAD
if [ "$VS_HEAD" = "1" ]; then
  echo
  echo "=== 8. controllo: il bundle di HEAD non ha nemmeno il campo =========="
  # `git archive`, non `git worktree add`: legge l'albero committato e non
  # scrive niente dentro `.git/`, quindi non lascia tracce in un repo su cui
  # sta lavorando anche qualcun altro.
  if [ ! -x "$HEADTREE/dist/T4A.app/Contents/MacOS/T4A" ]; then
    echo "    costruisco il bundle di HEAD in $HEADTREE (la prima volta è lenta)"
    rm -rf "$HEADTREE"; mkdir -p "$HEADTREE"
    git archive HEAD | tar -x -C "$HEADTREE" || { echo "git archive fallito" >&2; exit 1; }
    (cd "$HEADTREE" && Scripts/build-app.sh >/dev/null 2>&1) \
      || { echo "    il bundle di HEAD non si costruisce" >&2; STATUS=1; }
  fi
  if [ -x "$HEADTREE/dist/T4A.app/Contents/MacOS/T4A" ]; then
    apri "$HEADTREE/dist/T4A.app" "$CFG" || exit 1
    send "composer-mode always"; sleep 1
    send "slash-catalog $FIXTURE"; sleep 2
    send "activate"; sleep 0.5
    KP 37 cmd
    SL
    dump
    check "HEAD: la bolla ha il '/'" "$(field "d['composer']['text']")" "/"
    check "HEAD: nessun elenco nel dump" \
      "$(field "'suggestions' in d['composer']")" "False"
    t4a_stop_bench
    sleep 1
  fi
fi

# ------------------------------------------------------- 9. con claude vero
if [ "$WITH_CLAUDE" = "1" ]; then
  echo
  echo "=== 9. con claude VERO ================================================"
  mkdir -p "$WORK"
  # CINQUE aperture, non una. Il passo 0 di questa fetta ripara un difetto
  # INTERMITTENTE — il pid dell'agente arrivava 2 volte su 7 (misurato da B1 il
  # 27/08) — e una corsa sola su una gara non dice niente: sarebbe uno dei due
  # esiti che c'erano anche prima. Il menu vero si misura all'ultimo giro.
  PIDOK=0
  for giro in 1 2 3 4 5; do
    rm -rf "$CFG"; mkdir -p "$CFG/t4a"
    cat > "$CFG/t4a/config.toml" <<'TOML'
pure-chat = false
composer-mode = always
TOML
    rm -f "$FIFO"; rm -rf "$CACHE"; mkdir -p "$CACHE"
    open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG" \
         --env XDG_CACHE_HOME="$CACHE"
    for _ in $(seq 1 80); do [ -p "$FIFO" ] && break; sleep 0.25; done
    sleep 3
    send "text cd $WORK && claude\\n"
    ATTACHED=1
    for _ in $(seq 1 90); do
      dump
      [ "$(field "d['tabs'][0]['panes'][0]['attached']")" = "True" ] && { ATTACHED=0; break; }
      sleep 1
    done
    if [ "$ATTACHED" != "0" ]; then
      printf '    giro %d: claude NON si è agganciato\n' "$giro"
      STATUS=1
      send "text /exit\\n"; sleep 2; t4a_stop_bench; sleep 1
      continue
    fi
    HASPID=False
    for _ in $(seq 1 25); do
      dump
      HASPID="$(field "d['agents'][0]['adapter']['hasProcess']")"
      [ "$HASPID" = "True" ] && break
      sleep 1
    done
    EXE="$(field "d['agents'][0]['adapter']['executable']")"
    if [ "$HASPID" = "True" ] && [ -n "$EXE" ] && [ -x "$EXE" ]; then
      PIDOK=$((PIDOK + 1))
      printf '    giro %d: pid adottato, executable = %s\n' "$giro" "$EXE"
    else
      printf '    giro %d: SENZA pid (hasProcess=%s executable=[%s])\n' "$giro" "$HASPID" "$EXE"
    fi

    if [ "$giro" != "5" ]; then
      send "text /exit\\n"; sleep 3; t4a_stop_bench; sleep 1
      continue
    fi

    # --- l'ultimo giro va avanti col menu vero ---
    echo "    slashSource = $(field "d['agents'][0].get('slashSource','')")"
    send "activate"; sleep 0.5
    KP 37 cmd
    clear_bubble
    SL
    sleep 3
    dump
    # PRIMA del conteggio: il `/` è un tasto VERO e un tasto vero si può
    # perdere. Senza questa riga un `/` perso dava «ready, 0 voci», che si
    # leggeva come un catalogo vuoto a schermo (fetta C, 27/08: 1 corsa su 4)
    # mentre era `matches("")` su una bolla rimasta vuota.
    check "la bolla porta il / (il tasto è arrivato)" "$(field "d['composer']['suggestions']['filter']")" "/"
    check "l'elenco è pronto" "$(field "d['composer']['suggestions']['state']")" "ready"
    N="$(field "len(d['composer']['suggestions']['items'])")"
    # Il confronto FUORI dalla sostituzione: `STATUS=1` dentro un `$( )` vive
    # in una subshell e muore lì, cioè stamperebbe FAIL lasciando il banco
    # verde — il difetto peggiore che un banco possa avere (mio, 27/08).
    if [ "${N:-0}" -ge 20 ]; then MARK=PASS; else MARK=FAIL; STATUS=1; fi
    printf '%-56s got %-34s want %-26s %s\n' "almeno 20 voci" "[$N]" "[>=20]" "$MARK"
    for nome in compact model help cs; do
      check "c'è /$nome" \
        "$(field "any(i['name']=='$nome' for i in d['composer']['suggestions']['items'])")" "True"
    done
    check "/cs è dichiarato da te, non da claude" \
      "$(field "[i['source'] for i in d['composer']['suggestions']['items'] if i['name']=='cs'][0]")" \
      "user"

    # ISC-182 tiene: col menu di claude sullo schermo la tastiera è del
    # terminale, quindi l'elenco non è raggiungibile.
    KP 53
    clear_bubble
    send "compose /model"; sleep 4
    dump
    RESP="$(field "d['composer']['firstResponder']")"
    # Il nome della classe della superficie non si scrive qui: cambia col
    # motore. La domanda è «la bolla NON ha più la tastiera», e questa è.
    check "il menu di claude ha preso la tastiera" \
      "$([ "$RESP" = "ComposerField" ] && echo "ancora la bolla" || echo "il terminale")" \
      "il terminale"
    echo "    firstResponder = $RESP"
    check "e l'elenco non c'è" "$(field "d['composer']['suggestions']['shown']")" "False"
    screen
    send "key escape"; sleep 1.5
    send "text /exit\\n"; sleep 3
    t4a_stop_bench
  done
  if [ "$PIDOK" = "5" ]; then MARK=PASS; else MARK=FAIL; STATUS=1; fi
  printf '%-56s got %-34s want %-26s %s\n' "il pid arriva a ogni aggancio" "[$PIDOK/5]" "[5/5]" "$MARK"
fi

echo
[ "$STATUS" = "0" ] && echo "slash: tutti i poli tengono" || echo "slash: un polo FALLITO"
exit "$STATUS"
