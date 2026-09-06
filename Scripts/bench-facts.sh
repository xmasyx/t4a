#!/bin/bash
# ISC-139 — the bar shows the facts of a program T4A did not write.
#
#   Scripts/bench-facts.sh [section] [app-bundle]
#   sections: paint settings place parity speak alarm crowd lines dead slow writes absent all
#             (default all)
#
# Every provider used here is written BY this script, into a scratch directory,
# so what is being tested is the contract and not one particular program. Five
# of them, each one a pole:
#
#   good.sh   repeated keys with different tones, a `#name`, an empty label, a
#             row long enough that it cannot fit, a key that must be refused,
#             a tone that does not exist, and the arguments echoed back — which
#             is how the bench sees whether --session/--cwd/--agent arrived.
#   dead.sh   exits 1 and prints nothing.
#   slow.sh   sleeps five seconds, which is five times its own deadline.
#   wide.sh   thirteen readings for the WHOLE lines (ISC-142): three short
#             ones and a very long one on the first line, so that the same
#             line fits untouched on a wide window and overflows on a narrow
#             one, plus eight fillers and a row that is complaining.
#   spread.sh six short readings for ISC-143, which a saved layout scatters
#             across half lines AND whole lines — plus three keys the file
#             names and the provider never emits, which is the anti-pole.
#   pathecho  prints its own $PATH as a reading, so the environment the child
#             was given is read off the BAR and not off the app's own report.
#   missing   a `#!/usr/bin/env` line naming an interpreter that exists
#             nowhere: it must die at 127 and the app must SAY so.
#   (absent)  no provider at all, compared against the bundle built from HEAD.
#
# The readings are taken from the DRAWING. `painted` and `tones` in the dump
# are filled in by the paint code itself, after truncation, so a cell that was
# planned and never drawn cannot be reported as shown — which is the whole
# difference between measuring the bar and measuring the intention.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

SECTION="${1:-all}"
APP="${2:-dist/T4A.app}"
FIFO="/tmp/t4a-facts.fifo"
CONFIG_HOME="/tmp/t4a-facts-config"
CONFIG="$CONFIG_HOME/t4a/config.toml"
DUMP=/tmp/t4a-facts-dump.json
BIN=/tmp/t4a-facts-bin
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

for tool in dragpoint movepoint winid; do
  bin=".build/t4a-$tool"
  if [ ! -x "$bin" ] || [ "Scripts/$tool.swift" -nt "$bin" ]; then
    mkdir -p .build && swiftc -O "Scripts/$tool.swift" -o "$bin"
  fi
done

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 50); do [ -s "$DUMP" ] && break; sleep 0.1; done
  [ -s "$DUMP" ] || { echo "the app never answered a dump" >&2; exit 1; }
}
field() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
try:
    print($1)
except Exception as error:
    print('missing:%s' % type(error).__name__)
"; }
verdict() {
  local name="$1" got="$2" want="$3"
  local mark="ok"
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-52s %-30s (want %s) %s\n' "$name" "$got" "$want" "$mark"
}
note() { printf '%-52s %s\n' "$1" "$2"; }

stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }
launch() {
  rm -f "$FIFO"
  open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
  sleep 3
}
# The same bundle, started the way the DOCK starts it (ISC-143). `open` hands
# the app whatever environment this shell has, which on a developer's machine
# is a PATH with everything on it — so a bench that only ever uses `launch` is
# measuring a machine the user does not have. A Finder launch goes through
# launchd, and launchd's PATH is four directories. Running the executable
# directly with a scrubbed environment is that case, exactly, and it is the
# case the app was broken in.
launch_minimal() {
  rm -f "$FIFO"
  env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
      TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      XDG_CONFIG_HOME="$CONFIG_HOME" T4A_TEST_CHANNEL="$FIFO" \
      "$APP/Contents/MacOS/T4A" >/dev/null 2>&1 &
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
  sleep 3
}
virgin() { stop; rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"; }
front() {
  for _ in $(seq 1 6); do
    send "activate"; sleep 0.6
    open -a "$PWD/$APP" 2>/dev/null || true
    sleep 1.2
    dump
    [ "$(field "d['appActive']")" = "True" ] && { sleep 1.2; return 0; }
  done
  echo "    T4A would not come to the front"
  return 1
}

# ---------------------------------------------------------------- providers
rm -rf "$BIN"; mkdir -p "$BIN"

cat > "$BIN/good.sh" <<'PROVIDER'
#!/bin/bash
# A ladder: one reading, four words, three tones.
printf '#name\tactive\tModel ladder\n'
printf 'active\tHAIKU\tdim\n'
printf 'active\tSONNET\tdim\n'
printf 'active\tOPUS\tlive\n'
printf 'active\tFABLE\tused\n'
# An EMPTY label: a reading that says what it is without one.
printf '#name\tusage\t\n'
printf 'usage\t5HR 5%%\tok\n'
printf 'usage\tWK 86%%\tcritical\n'
printf 'usage\tFB 81%%\twarn\n'
printf 'usage\tSUB\tmuted\n'
# Two readings with the SAME words, one named and one not. If `#name` ever
# reached the bar, the named one would be wider, or shorter after truncation.
printf '#name\ttwina\tA rather long human name that lives in the settings\n'
printf 'twina\tTWIN SAME WORDS HERE\tmuted\n'
printf 'twinb\tTWIN SAME WORDS HERE\tmuted\n'
# The arguments, straight back out: this is how the bench sees the contract.
printf '#name\targs\tArguments\n'
printf 'args\t%s\tmuted\n' "$*"
# Longer than any bar is wide.
printf '#name\tlong\tLong reading\n'
printf 'long\t%s\taccent\n' "ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL INDIA JULIETT KILO LIMA MIKE NOVEMBER OSCAR PAPA QUEBEC ROMEO SIERRA TANGO UNIFORM VICTOR WHISKEY XRAY YANKEE ZULU"
# Two lines that must be REFUSED, and one that must not be a row at all.
printf 'left-1:boom\tcorrupt the layout\n'
printf 'ctx\t7%%\tmagenta\n'
printf '# a comment\n'
PROVIDER

cat > "$BIN/crowd.sh" <<'PROVIDER'
#!/bin/bash
# More long readings than any bar is wide, with one of them complaining.
for row in alpha bravo charlie delta echo foxtrot golf hotel india juliett \
           kilo lima mike november oscar papa; do
  printf '#name\t%s\t%s\n' "$row" "$row"
  printf '%s\tSOMETHING RATHER LONG TO READ HERE\tmuted\n' "$row"
done
printf '#name\ttrouble\tTrouble\n'
printf 'trouble\tDISK 100%% AND CLIMBING\tcritical\n'
PROVIDER

cat > "$BIN/wide.sh" <<'PROVIDER'
#!/bin/bash
# Thirteen rows for the whole lines. The first four are the line the claim is
# about: three short readings and one of a hundred and three characters, sized
# so the line fits WHOLE on a 1512 pt window and overflows a 900 pt one — which
# is what makes "nothing is compressed while there is room" a measurement and
# not a hope.
printf '#name\ts1\tShort one\n';   printf 's1\tREADY FOR THIS\tok\n'
printf '#name\ts2\tShort two\n';   printf 's2\tREADY FOR THAT\tok\n'
printf '#name\ts3\tShort three\n'; printf 's3\tREADY FOR MORE\tok\n'
printf '#name\tlong\tLong reading\n'
printf 'long\t%s\taccent\n' \
  "ALPHA BRAVO CHARLIE DELTA ECHO FOXTROT GOLF HOTEL INDIA JULIETT KILO LIMA MIKE NOVEMBER OSCAR PAPA QUEB"
# Eight fillers of twenty-three characters: four of them fill the second whole
# line without overflowing it at either width, so the only cell that changes
# between the two windows is the one the claim names.
for row in f1 f2 f3 f4 f5 f6 f7 f8; do
  printf '#name\t%s\tFiller %s\n' "$row" "$row"
  printf '%s\tFILLER READING NUMBER 1\tmuted\n' "$row"
done
printf '#name\ttrouble\tTrouble\n'
printf 'trouble\tDISK 100%% AND CLIMBING\tcritical\n'
PROVIDER

cat > "$BIN/spread.sh" <<'PROVIDER'
#!/bin/bash
# Six readings for ISC-143, which the saved layout scatters: three onto half
# lines and three onto whole ones. Short on purpose — this pole asks WHERE a
# reading is drawn, and a reading long enough to be squeezed would be asking a
# second question at the same time.
for row in h1 h2 h3 w1 w2 w3; do
  printf '#name\t%s\tRow %s\n' "$row" "$row"
  printf '%s\tREADING %s\tok\n' "$row" "$row"
done
PROVIDER

cat > "$BIN/pathecho.sh" <<'PROVIDER'
#!/bin/bash
# Its own PATH, as a reading. Read off the BAR, this is the environment the
# child was actually given — not a number the app reports about itself.
printf '#name\tpath\tThe PATH the provider got\n'
printf 'path\t%s\tmuted\n' "$PATH"
PROVIDER

cat > "$BIN/missing.sh" <<'PROVIDER'
#!/usr/bin/env t4a-bench-no-such-interpreter-9271
printf 'never\tthis line cannot run\tok\n'
PROVIDER

cat > "$BIN/alarming.sh" <<'PROVIDER'
#!/bin/bash
# One reading that is complaining, and one calm one long enough to be worth
# shortening — so a narrow bar has a choice about whose letters it takes.
printf '#name\ttrouble\tTrouble\n'
printf 'trouble\tDISK 100%% AND CLIMBING\tcritical\n'
printf '#name\tchatter\tChatter\n'
printf 'chatter\tEVERYTHING IS PERFECTLY FINE AND HAS BEEN FOR A WHILE NOW\tmuted\n'
PROVIDER

cat > "$BIN/calm.sh" <<'PROVIDER'
#!/bin/bash
# The SAME two keys, and nothing to complain about. This is the anti-pole:
# the only difference from alarming.sh is a tone.
printf '#name\ttrouble\tTrouble\n'
printf 'trouble\tDISK 41%% AND STEADY\tok\n'
printf '#name\tchatter\tChatter\n'
printf 'chatter\tEVERYTHING IS PERFECTLY FINE AND HAS BEEN FOR A WHILE NOW\tmuted\n'
PROVIDER

cat > "$BIN/noisy.sh" <<'PROVIDER'
#!/bin/bash
# Says what is wrong on stderr, then dies. Nothing it prints there may ever
# reach the bar as a reading (ISC-139); what it says must reach `problems`
# (ISC-145), because a status code says something broke and this says what.
echo "the token file is missing and I cannot ask" >&2
echo "a second line nobody needs" >&2
exit 3
PROVIDER

cat > "$BIN/dead.sh" <<'PROVIDER'
#!/bin/bash
exit 1
PROVIDER

cat > "$BIN/slow.sh" <<'PROVIDER'
#!/bin/bash
sleep 5
printf 'slow\ttoo late\tok\n'
PROVIDER

# RIBASATURA DEL 25/08 (ISC-173): chi RIESCE dichiara anche la sessione.
#
# Da ISC-173 la barra disegna soltanto su un pannello CONNESSO, e un fornitore
# che non ha riconosciuto la sessione del riquadro descrive per definizione un
# pannello a cui non è attaccato niente — le sue righe parlano della macchina.
# È la cosa che il 25/08 riempiva la barra sopra una shell nuda di fatti veri
# di un'altra sessione. I poli qui sotto riguardano COME una barra connessa
# disegna le righe di un fornitore, quindi il loro apparecchio deve
# rappresentare un pannello connesso, o misurerebbero il cancello invece del
# disegno.
#
# I QUATTRO CHE FALLISCONO restano come sono, e l'esclusione è il punto: sono
# apparecchi costruiti per non produrre niente — interprete inesistente, uscita
# non zero, stderr e basta, cinque secondi di sonno — e mettergli in bocca una
# riga che riesce li snaturerebbe. Il pannello, nei poli che li usano, viene
# connesso dal fornitore BUONO che gira prima di loro: è così che si misura
# «le letture restano, poi sbiadiscono», che parla appunto di letture che
# c'erano già.
# IN CODA e non in testa: le linee intere si riempiono nell'ordine in cui il
# fornitore stampa, quattro per linea, quindi una riga messa davanti farebbe
# slittare tutte le altre di un posto e i poli sull'ordine misurerebbero lo
# slittamento invece della regola.
for script in good crowd wide spread pathecho alarming calm; do
  {
    printf "printf '#name\\tsession\\tSession title\\n'\n"
    printf "printf 'session\\tbench\\taccent\\n'\n"
  } >> "$BIN/$script.sh"
done
# E un apparecchio che è CONNESSO e non ha niente da dire: serve a misurare la
# barra prima che arrivi una lettura, che con ISC-173 non si può più fare
# spegnendo il fornitore — un pannello senza fornitore adesso non è una barra
# corta, è nessuna barra.
cat > "$BIN/bare.sh" <<'PROVIDER'
#!/bin/bash
printf '#name\tsession\tSession title\n'
printf 'session\tbench\taccent\n'
PROVIDER

chmod +x "$BIN"/*.sh
for script in "$BIN"/*.sh; do bash -n "$script"; done

config_with() {
  mkdir -p "$CONFIG_HOME/t4a"
  {
    printf '# written by bench-facts.sh\n\n'
    printf 'facts-provider = "%s"\n' "$1"
    printf 'facts-interval = %s\n' "${2:-0.5}"
    # A saved layout, when the pole is about rows the USER has already put
    # somewhere. Without it every provider row lands on the whole lines
    # (ISC-142), and a pole about the half lines would be measuring a bar
    # nothing is on.
    #
    # E `fact-session` ha SEMPRE una casa esplicita su `left-3`. Non basta
    # spegnerla: una riga di fornitore che il file già nomina viene scoperta
    # PRIMA che il layout sia riparato — è la riga che impedisce a un
    # arrangiamento salvato di resettarsi a ogni avvio — quindi finiva prima
    # di tutte nel catalogo e si prendeva il primo posto delle linee intere
    # anche da spenta, spostando di uno ogni polo sull'ordine. Con una casa
    # sua non consuma nessun posto, e spenta non si vede.
    printf 'dash-slots = "%s"\n' \
      "$(/usr/bin/python3 -c "
import sys
saved = sys.argv[1]
parts = saved.split('|') if saved else []
out, seen = [], False
for part in parts:
    slot, _, keys = part.partition(':')
    if slot == 'left-3':
        seen = True
        keys = (keys + ',fact-session') if keys else 'fact-session'
    out.append('%s:%s' % (slot, keys))
if not seen:
    out.append('left-3:fact-session')
print('|'.join(out))
" "${3:-}")"
    # And which rows are switched OFF, when the pole is about a reading the
    # user has hidden (ISC-146).
    #
    # `fact-session` è SEMPRE fra queste, ed è la seconda metà della
    # ribasatura di ISC-173. Gli apparecchi di questo banco dichiarano la
    # sessione perché la barra disegni — un pannello che nessun fornitore ha
    # riconosciuto adesso non disegna niente — ma quella riga è una lettura
    # come le altre e comparirebbe sulla barra, prendendo un posto sulle linee
    # intere e spostando di uno tutti i poli sull'ordine. Spenta connette lo
    # stesso: il cancello guarda se il fornitore l'ha EMESSA, non se è
    # accesa, che è anche il comportamento giusto — chi spegne la riga del
    # titolo di sessione non si aspetta che la barra sparisca.
    printf 'dash-off = "%s"\n' \
      "$(printf '%s' "${4:+$4,}fact-session")"
  } > "$CONFIG"
}

run() { [ "$SECTION" = "all" ] || [ "$SECTION" = "$1" ]; }

# ------------------------------------------------------------------- paint
if run paint; then
  echo "==> a provider that answers: the tokens, the tones, the names"
  virgin; config_with "$BIN/good.sh" 0.5; launch
  sleep 2
  dump
  verdict "the provider ran" "$(field "'yes' if d['dash']['facts']['runs'] >= 1 else 'no'")" "yes"
  note "  runs / misses / last exit" \
    "$(field "'%s / %s / %s' % (d['dash']['facts']['runs'], d['dash']['facts']['misses'], d['dash']['facts']['lastExit'])")"
  note "  how long it takes" "$(field "'%s ms' % d['dash']['facts']['lastDurationMs']")"

  verdict "the ladder is one cell of four words" \
    "$(field "' '.join(t[0] for t in d['dash']['tones']['fact-active'])")" \
    "HAIKU SONNET OPUS FABLE"
  verdict "and each word kept its own tone" \
    "$(field "','.join(t[1] for t in d['dash']['tones']['fact-active'])")" \
    "dim,dim,live,used"
  verdict "the two reds are the two the bar already uses (ISC-103)" \
    "$(field "'%s %s' % (d['dash']['inks']['fact-usage'][1], d['dash']['inks']['fact-usage'][2])")" \
    "#D4574A #A8635B"
  note "  the ladder, word by word, in ink" "$(field "list(zip([t[0] for t in d['dash']['tones']['fact-active']], d['dash']['inks']['fact-active']))")"
  verdict "the usage row carries both reds" \
    "$(field "','.join(t[1] for t in d['dash']['tones']['fact-usage'])")" \
    "ok,critical,warn,muted"
  verdict "the #name became the human name" \
    "$(field "[e['name'] for e in d['dash']['catalog'] if e['key']=='fact-active'][0]")" \
    "Model ladder"
  verdict "a row with no #name is named from its key" \
    "$(field "[e['name'] for e in d['dash']['catalog'] if e['key']=='fact-ctx'][0]")" "Ctx"
  verdict "no reading carries a label on the bar" \
    "$(field "'yes' if set(v for k, v in d['dash']['labels'].items() if k.startswith('fact-')) == {''} else 'no'")" "yes"
  echo "--> and the pole that says so in width: two identical readings, one named"
  verdict "the named twin says exactly what the unnamed one says" \
    "$(field "repr(d['dash']['painted']['fact-twina'])")" \
    "$(field "repr(d['dash']['painted']['fact-twinb'])")"
  verdict "and is exactly as wide, to the point" \
    "$(field "round(d['dash']['ink']['fact-twina']['w'], 3)")" \
    "$(field "round(d['dash']['ink']['fact-twinb']['w'], 3)")"
  note "  the name only a person opening the settings sees" \
    "$(field "[e['name'] for e in d['dash']['catalog'] if e['key']=='fact-twina'][0]")"
  verdict "the refused key never became a row" \
    "$(field "'yes' if not [e for e in d['dash']['catalog'] if 'boom' in e['key']] else 'no'")" "yes"
  verdict "and nothing corrupted dash-slots" \
    "$(field "'yes' if ':boom' not in d['dash']['slots'] and d['dash']['slots'].count('|') == 8 else 'no'")" "yes"
  verdict "the unknown tone was dropped, the word kept" \
    "$(field "repr([t[1] for t in d['dash']['tones']['fact-ctx']])")" "['']"
  note "  what the provider was told" "$(field "d['dash']['values']['fact-args']")"
  verdict "it was given --cwd" \
    "$(field "'yes' if '--cwd' in d['dash']['values']['fact-args'] else 'no'")" "yes"
  verdict "it was given --session and --agent" \
    "$(field "'yes' if '--session' in d['dash']['values']['fact-args'] and '--agent' in d['dash']['values']['fact-args'] else 'no'")" "yes"

  echo "--> the long row is cut, and its neighbours are still there"
  verdict "the long reading was truncated" \
    "$(field "'yes' if d['dash']['painted']['fact-long'].endswith('…') else 'no'")" "yes"
  note "  what fitted" "$(field "d['dash']['painted']['fact-long']")"
  verdict "it did not push anyone off the bar" \
    "$(field "'yes' if all(k in d['dash']['painted'] for k in ['fact-active','fact-usage','fact-args','fact-long','fact-ctx']) else 'no'")" "yes"
  # Where a provider's rows LAND changed with ISC-142: they no longer share
  # the third half lines with what a terminal knows, they get whole lines of
  # their own. The question this pole asks is the same one it always asked —
  # did the bar find room for them — and the place it reads the answer moved.
  verdict "the whole lines opened for them" \
    "$(field "'yes' if len(d['dash']['full']) == 2 else 'no'")" "yes"
  note "  what is on each whole line" "$(field "[len(l) for l in d['dash']['full']]")"
  note "  and the half lines, untouched" "$(field "[len(l) for l in d['dash']['left']] + [len(l) for l in d['dash']['right']]")"
  note "  bar height / rows / whole lines" \
    "$(field "'%s pt / %s / %s' % (int(d['dash']['height']), d['dash']['rows'], d['dash']['fullRows'])")"
  verdict "the two groups are still three rows at most" \
    "$(field "'yes' if d['dash']['rows'] <= 3 else 'no'")" "yes"
  verdict "and the whole lines are three at most" \
    "$(field "'yes' if d['dash']['fullRows'] <= 3 else 'no'")" "yes"
fi

# ---------------------------------------------------------------- settings
if run settings; then
  echo "==> the rows are rows: a switch, a drag, and both survive a restart"
  if [ "$SECTION" = "settings" ]; then
    virgin; config_with "$BIN/good.sh" 0.5; launch; sleep 2
  fi
  # 900 e non 560, e il numero è stato misurato non scelto. Con ISC-172 la
  # lista delle righe è passata da 15 a 18 voci: in un pannello alto 560 il
  # bersaglio di questo trascinamento (`right-3`) non è più raggiungibile
  # nell'area visibile, e il trascinamento atterra su «none» — provato ai due
  # poli lo stesso giorno, 820x560 rosso e 820x900 verde, tutto il resto
  # uguale. Non è un difetto dell'app: il pannello vero scorre
  # (`NSScrollView`), ma un trascinamento non può scorrere mentre è in corso,
  # quindi origine e destinazione devono stare sullo schermo insieme.
  send "settings place 120,60,820,900"; sleep 1
  send "settings Dashboard rows"; sleep 0.8
  dump
  verdict "the provider rows are in the settings, by their human name" \
    "$(field "'yes' if 'Model ladder' in d['settings']['switches'] and 'Long reading' in d['settings']['switches'] and 'A rather long human name that lives in the settings' in d['settings']['switches'] else 'no'")" "yes"

  echo "--> switching one off, with the switch a person presses"
  send "toggle Model ladder"; sleep 1
  dump
  verdict "the switch is off" "$(field "d['settings']['on']['Model ladder']")" "False"
  verdict "and the row left the bar" \
    "$(field "'yes' if 'fact-active' not in d['dash']['painted'] else 'no'")" "yes"
  verdict "dash-off names it by key" \
    "$(grep -c 'fact-active' <(grep '^dash-off' "$CONFIG"))" "1"
  note "  the line in config.toml" "$(grep '^dash-off' "$CONFIG")"

  echo "--> dragging it to the other group, with a real mouse"
  send "toggle Model ladder"; sleep 0.8   # back on, so a drag has something to move
  front || STATUS=1
  # 900 e non 560, e il numero è stato misurato non scelto. Con ISC-172 la
  # lista delle righe è passata da 15 a 18 voci: in un pannello alto 560 il
  # bersaglio di questo trascinamento (`right-3`) non è più raggiungibile
  # nell'area visibile, e il trascinamento atterra su «none» — provato ai due
  # poli lo stesso giorno, 820x560 rosso e 820x900 verde, tutto il resto
  # uguale. Non è un difetto dell'app: il pannello vero scorre
  # (`NSScrollView`), ma un trascinamento non può scorrere mentre è in corso,
  # quindi origine e destinazione devono stare sullo schermo insieme.
  send "settings place 120,60,820,900"; sleep 1
  dump
  HX="$(field "int([r['handle']['x'] for r in d['settings']['rows'] if r['key']=='fact-active'][0])")"
  HY="$(field "int([r['handle']['y'] for r in d['settings']['rows'] if r['key']=='fact-active'][0])")"
  TX="$(field "int([l['rect']['x'] for l in d['settings']['lines'] if l['slot']=='right-3'][0])")"
  TY="$(field "int([l['rect']['y'] for l in d['settings']['lines'] if l['slot']=='right-3'][0])")"
  note "  handle at" "$HX,$HY  →  right-3 at $TX,$TY"
  .build/t4a-dragpoint "$HX" "$HY" "$TX" "$TY" 30
  sleep 1.5
  dump
  # The LINE it landed on, not the row it landed before: where inside the
  # line the drop falls is the drop point's business, and asserting it would
  # be the bench asking a narrower question than the claim.
  verdict "the drag landed on right-3" \
    "$(field "d['settings']['trace'].get('ended','none').split('/')[0]")" "right-3"
  verdict "the row is on the third right line" \
    "$(field "'yes' if 'fact-active' in d['dash']['slots'].split('right-3:')[1] else 'no'")" "yes"
  verdict "and it is drawn in the right-hand group" \
    "$(field "'yes' if any('fact-active' in line for line in d['dash']['right']) else 'no'")" "yes"
  SAVED_SLOTS="$(grep '^dash-slots' "$CONFIG" | sed 's/.*= *//' | tr -d '"')"
  note "  dash-slots on disk" "$SAVED_SLOTS"

  echo "--> and now the restart, which is the only thing that proves it stuck"
  send "toggle Long reading"; sleep 1
  stop
  launch
  sleep 2
  dump
  verdict "the drag survived the restart" \
    "$(field "'yes' if 'fact-active' in d['dash']['slots'].split('right-3:')[1] else 'no'")" "yes"
  verdict "the switch survived it too" \
    "$(field "'yes' if 'fact-long' in d['dash']['off'] else 'no'")" "yes"
  verdict "the row that was off is off" \
    "$(field "'yes' if 'fact-long' not in d['dash']['painted'] else 'no'")" "yes"
  verdict "the row that was on is on" \
    "$(field "'yes' if 'fact-active' in d['dash']['painted'] else 'no'")" "yes"
fi

# ------------------------------------------------------------------- place
if run place; then
  echo "==> a provider's row draws in ANY line it is put in, and only if it exists (ISC-143)"
  # Nine provider keys named by the file, six of which the provider emits.
  # The three it does not — ghost1, ghost2, ghost3 — sit one on a half line,
  # one on a whole line, and they are the negative pole: a key nobody has a
  # reading for must leave no gap, no empty cell, and no line standing open.
  SPREAD="left-1:fact-h1,blocks,failed,turns,state"
  SPREAD="$SPREAD|left-2:fact-h2,scrollback,grid|left-3:fact-ghost1"
  SPREAD="$SPREAD|right-1:fact-h3,dir,proc,agent,model"
  SPREAD="$SPREAD|right-2:fact-ghost2,shell,blocks-on,panes,theme|right-3:"
  SPREAD="$SPREAD|facts-1:fact-w1,fact-w2|facts-2:fact-ghost3|facts-3:fact-w3"
  virgin; config_with "$BIN/spread.sh" 0.5 "$SPREAD"; launch; sleep 2
  dump
  note "  the layout the file asked for" "$(field "d['dash']['slots']")"
  note "  what the provider emitted" "$(field "d['dash']['facts']['keys']")"
  verdict "every emitted key has a reading" \
    "$(field "'yes' if all('fact-'+k in d['dash']['values'] for k in ['h1','h2','h3','w1','w2','w3']) else 'no'")" "yes"

  echo "--> the three on HALF lines are drawn on their half lines"
  verdict "fact-h1 is on the first left line" \
    "$(field "'yes' if d['dash']['left'][0][0] == 'fact-h1' else 'no'")" "yes"
  verdict "fact-h2 is on the second left line" \
    "$(field "'yes' if d['dash']['left'][1][0] == 'fact-h2' else 'no'")" "yes"
  verdict "fact-h3 is on the first right line" \
    "$(field "'yes' if d['dash']['right'][0][0] == 'fact-h3' else 'no'")" "yes"
  note "  the left group" "$(field "d['dash']['left']")"
  note "  the right group" "$(field "d['dash']['right']")"

  echo "--> the three on WHOLE lines are drawn on their whole lines"
  verdict "the first whole line carries w1 and w2" \
    "$(field "'yes' if d['dash']['full'][0] == ['fact-w1','fact-w2'] else 'no'")" "yes"
  verdict "and the other whole line carries w3" \
    "$(field "'yes' if d['dash']['full'][1] == ['fact-w3'] else 'no'")" "yes"
  note "  the whole lines" "$(field "d['dash']['full']")"

  echo "--> and the PAINT agrees with the arrangement, key by key"
  verdict "all six were painted" \
    "$(field "'yes' if all('fact-'+k in d['dash']['painted'] for k in ['h1','h2','h3','w1','w2','w3']) else 'no'")" "yes"
  verdict "each one whole, none cut" \
    "$(field "sorted(k for k in d['dash']['painted'] if k.startswith('fact-') and k[-1:] == '…')")" "[]"
  verdict "a half-line row says what a whole-line row says" \
    "$(field "'yes' if d['dash']['painted']['fact-h1'] == 'READING h1' and d['dash']['painted']['fact-w1'] == 'READING w1' else 'no'")" "yes"
  note "  what each one was painted with" \
    "$(field "sorted((k, v) for k, v in d['dash']['painted'].items() if k.startswith('fact-'))")"

  echo "--> the anti-pole: a key the provider never emitted"
  verdict "no ghost has a value" \
    "$(field "sorted(k for k in d['dash']['values'] if 'ghost' in k)")" "[]"
  verdict "no ghost was painted" \
    "$(field "sorted(k for k in d['dash']['painted'] if 'ghost' in k)")" "[]"
  verdict "the half line holding only a ghost does not exist" \
    "$(field "len(d['dash']['left'])")" "2"
  verdict "nor does the whole line holding only a ghost" \
    "$(field "len(d['dash']['full'])")" "2"
  verdict "and nothing on the bar is an empty cell" \
    "$(field "sorted(k for k, v in d['dash']['painted'].items() if not v.strip())")" "[]"
  verdict "the ghosts are still in the file, where the user put them" \
    "$(field "'yes' if 'left-3:fact-ghost1' in d['dash']['slots'] and 'facts-2:fact-ghost3' in d['dash']['slots'] else 'no'")" "yes"

  echo "--> the cause the claim was written for: the PATH a provider is run with"
  # This is the pole that was red. Launched the way the Dock launches it, the
  # app's own PATH is four directories, and before the fix the provider was
  # handed exactly those four — which is why a `#!/usr/bin/env bun` provider
  # died at 127, every two seconds, showing nothing and saying nothing.
  virgin; config_with "$BIN/pathecho.sh" 0.5; launch_minimal
  sleep 2
  dump
  verdict "the app itself was started with launchd's PATH" \
    "$(field "d['dash']['facts']['appPath']")" "/usr/bin:/bin:/usr/sbin:/sbin"
  verdict "the provider was NOT given that PATH" \
    "$(field "'yes' if d['dash']['facts']['pathEnv'] != d['dash']['facts']['appPath'] else 'no'")" "yes"
  # Read off the bar, from the child's own $PATH, not from the app's report.
  verdict "and the reading on the bar says the same" \
    "$(field "'yes' if d['dash']['values']['fact-path'].strip() not in ('', '/usr/bin:/bin:/usr/sbin:/sbin') else 'no'")" "yes"
  verdict "the four launchd directories are still there, behind the rest" \
    "$(field "'yes' if all(p in d['dash']['values']['fact-path'] for p in ['/usr/bin','/bin','/usr/sbin','/sbin']) else 'no'")" "yes"
  note "  the PATH the child got" "$(field "d['dash']['values']['fact-path'].strip()[:96] + '…'")"

  echo "--> and a provider that cannot start says so, instead of showing an empty bar"
  virgin; config_with "$BIN/missing.sh" 0.5; launch_minimal
  sleep 3
  dump
  verdict "it exited 127" "$(field "d['dash']['facts']['lastExit']")" "127"
  verdict "no reading arrived" "$(field "d['dash']['facts']['keys']")" "[]"
  verdict "and the app WROTE DOWN why" \
    "$(field "'yes' if any('127' in p for p in d['dash']['facts']['problems']) else 'no'")" "yes"
  note "  what it says" "$(field "d['dash']['facts']['problems'][0] if d['dash']['facts']['problems'] else '(nothing — the silent failure)'")"
  verdict "one sentence, not one per tick" \
    "$(field "len(d['dash']['facts']['problems'])")" "1"
  note "  runs behind that one sentence" "$(field "d['dash']['facts']['runs']")"
fi

# ------------------------------------------------------------------ parity
if run parity; then
  echo "==> the whole lines in the SETTINGS are the same rows as the half ones (ISC-144)"
  virgin; config_with "$BIN/spread.sh" 0.5 \
    "left-1:fact-h1,blocks|left-2:fact-h2|left-3:|right-1:fact-h3,dir|right-2:|right-3:|facts-1:fact-w1|facts-2:fact-w2,fact-w3|facts-3:"
  launch; sleep 2
  send "settings open"; sleep 0.8
  send "settings Dashboard rows"; sleep 0.8
  send "settings place 120,120,1200,1000"; sleep 1.2
  dump
  note "  every line, as a box" \
    "$(field "[(l['slot'], int(l['rect']['w']), int(l['rect']['h']), l['empty']) for l in d['settings']['lines']]")"
  verdict "all nine lines are the same width" \
    "$(field "len(set(round(l['rect']['w']) for l in d['settings']['lines']))")" "1"
  verdict "every empty line is one row tall, half and whole alike" \
    "$(field "sorted(set(round(l['rect']['h']) for l in d['settings']['lines'] if l['empty']))")" "[30]"
  verdict "a line's height is its rows, at thirty points each" \
    "$(field "'yes' if all(round(l['rect']['h']) == 30 * max(1, len([r for r in d['settings']['rows'] if r['slot'] == l['slot']])) for l in d['settings']['lines']) else 'no'")" "yes"
  verdict "a whole-line switch sits where a left-column switch sits" \
    "$(field "'yes' if round([r['switch']['x'] for r in d['settings']['rows'] if r['slot']=='facts-2'][0]) == round([r['switch']['x'] for r in d['settings']['rows'] if r['slot']=='left-1'][0]) else 'no'")" "yes"
  verdict "and so does its handle" \
    "$(field "'yes' if round([r['handle']['x'] for r in d['settings']['rows'] if r['slot']=='facts-2'][0]) == round([r['handle']['x'] for r in d['settings']['rows'] if r['slot']=='left-1'][0]) else 'no'")" "yes"
  verdict "every row is the same height, whichever line it is on" \
    "$(field "sorted(set(round(r['handle']['h']) for r in d['settings']['rows']))")" "[22]"
  verdict "an empty whole line is a drop target with a body" \
    "$(field "'yes' if [l for l in d['settings']['lines'] if l['slot']=='facts-3'][0]['rect']['h'] >= 30 else 'no'")" "yes"

  echo "--> at most ONE row is lit, which is the thing five lit rows disproved"
  verdict "nothing is lit before the pointer arrives" \
    "$(field "repr(d['settings']['hovered'])")" "''"
  front || STATUS=1
  send "settings place 120,120,1200,1000"; sleep 1
  dump
  HX="$(field "int([r['handle']['x'] for r in d['settings']['rows'] if r['key']=='fact-w2'][0])")"
  HY="$(field "int([r['handle']['y'] for r in d['settings']['rows'] if r['key']=='fact-w2'][0])")"
  LX="$(field "int([r['handle']['x'] for r in d['settings']['rows'] if r['key']=='fact-h1'][0])")"
  LY="$(field "int([r['handle']['y'] for r in d['settings']['rows'] if r['key']=='fact-h1'][0])")"
  # A real pointer, walked onto a whole-line row and then onto a half-line
  # one. The app reports ONE name, so "how many rows are lit" is a question
  # with only two possible answers — and the second move is what would have
  # caught the old behaviour, where the first row kept its highlight.
  .build/t4a-movepoint "$HX" "$HY"
  sleep 0.8
  dump
  verdict "the pointer over a whole-line row lights THAT row" \
    "$(field "d['settings']['hovered']")" "fact-w2"
  .build/t4a-movepoint "$LX" "$LY"
  sleep 0.8
  dump
  verdict "moving to a half-line row lights that one INSTEAD" \
    "$(field "d['settings']['hovered']")" "fact-h1"
  # And off every row: the highlight has to be able to go out, or "one at a
  # time" is being kept by never letting go of the first.
  .build/t4a-movepoint "$((LX - 180))" "$LY"
  sleep 0.8
  dump
  verdict "and off the rows, nothing is lit" \
    "$(field "repr(d['settings']['hovered'])")" "''"
fi

# ------------------------------------------------------------------- speak
if run speak; then
  echo "==> a provider that cannot start SAYS so, on the bar and in the log (ISC-145)"
  # Si parte da un fornitore che FUNZIONA e poi si rompe, invece di partire
  # già rotti. Con ISC-173 un pannello che nessuno ha mai riconosciuto non
  # disegna niente — allarmi compresi, sua decisione esplicita del 25/08 —
  # quindi partendo diritti su un interprete inesistente non ci sarebbe
  # nessuna barra su cui il cartello possa comparire, e questi poli
  # misurerebbero il cancello invece del cartello. È anche il caso vero: un
  # fornitore che si guasta è quasi sempre un fornitore che prima andava.
  virgin; config_with "$BIN/bare.sh" 0.5; launch_minimal
  sleep 2
  send "facts $BIN/missing.sh"
  sleep 3
  dump
  verdict "it exited 127" "$(field "d['dash']['facts']['lastExit']")" "127"
  verdict "the live state names the failure" \
    "$(field "'yes' if '127' in d['dash']['facts']['lastFailure'] else 'no'")" "yes"
  verdict "and the history keeps it too" \
    "$(field "'yes' if any('127' in p for p in d['dash']['facts']['problems']) else 'no'")" "yes"
  note "  what it says" "$(field "d['dash']['facts']['lastFailure']")"

  echo "--> and it is ON THE BAR, where a person is looking"
  verdict "there is one cell in the alarm lane" \
    "$(field "d['dash']['alarms']")" "['facts']"
  verdict "it is drawn on the second left line, after the last cell" \
    "$(field "'yes' if d['dash']['left'][1][-1] == 'facts' else 'no'")" "yes"
  note "  the second left line" "$(field "d['dash']['left'][1]")"
  verdict "it names the failure" \
    "$(field "'yes' if '127' in d['dash']['painted']['facts'] else 'no'")" "yes"
  note "  what the cell says" "$(field "repr(d['dash']['painted']['facts'])")"
  # The tone read off the PAINT, not off a field the app could be wrong about.
  verdict "painted in the warn red of ISC-103" \
    "$(field "d['dash']['inks']['facts'][0]")" "#A8635B"
  verdict "and after three misses it says it is not being refreshed" \
    "$(field "'yes' if d['dash']['facts']['stale'] and 'NOT REFRESHING' in d['dash']['painted']['facts'] else 'no'")" "yes"

  echo "--> a provider that explains itself on stderr: the line reaches the log"
  virgin; config_with "$BIN/noisy.sh" 0.5; launch
  sleep 2
  dump
  verdict "it exited 3" "$(field "d['dash']['facts']['lastExit']")" "3"
  verdict "and what it printed is in the failure" \
    "$(field "'yes' if 'the token file is missing' in d['dash']['facts']['lastFailure'] else 'no'")" "yes"
  note "  the whole sentence" "$(field "d['dash']['facts']['lastFailure']")"
  verdict "only the FIRST line of it, not the second" \
    "$(field "'yes' if 'a second line nobody needs' not in d['dash']['facts']['lastFailure'] else 'no'")" "yes"
  verdict "and none of it became a reading" \
    "$(field "sorted(k for k in d['dash']['values'] if k.startswith('fact-'))")" "[]"

  echo "--> the anti-pole: a provider that works says nothing at all"
  virgin; config_with "$BIN/spread.sh" 0.5; launch
  sleep 2
  dump
  verdict "nothing failed" "$(field "d['dash']['facts']['lastExit']")" "0"
  verdict "the log is empty" "$(field "d['dash']['facts']['problems']")" "[]"
  verdict "the live state is empty" \
    "$(field "repr(d['dash']['facts']['lastFailure'])")" "''"
  verdict "the lane is empty" "$(field "d['dash']['alarms']")" "[]"
  verdict "and there is no such cell on the bar" \
    "$(field "'yes' if 'facts' not in d['dash']['painted'] else 'no'")" "yes"
  verdict "the second left line is exactly what it always was" \
    "$(field "d['dash']['left'][1]")" "['scrollback', 'grid']"

  echo "--> and it goes away by itself when the provider comes back"
  send "facts $BIN/missing.sh"; sleep 3
  dump
  verdict "the cell arrived" "$(field "d['dash']['alarms']")" "['facts']"
  send "facts $BIN/spread.sh"; sleep 3
  dump
  verdict "and left again on the first good answer" "$(field "d['dash']['alarms']")" "[]"
  verdict "with the bar back to what it was" \
    "$(field "d['dash']['left'][1]")" "['scrollback', 'grid']"
fi

# ------------------------------------------------------------------- alarm
if run alarm; then
  echo "==> a warning is on the bar even when its row is off (ISC-146)"
  # Both provider rows switched off. One is complaining; the other is not.
  OFF_SLOTS="left-1:blocks,failed,turns,state|left-2:scrollback,grid|left-3:|right-1:dir,proc,agent,model|right-2:shell,blocks-on,panes,theme|right-3:|facts-1:fact-trouble,fact-chatter|facts-2:|facts-3:"
  virgin; config_with "$BIN/alarming.sh" 0.5 "$OFF_SLOTS" "fact-trouble,fact-chatter"
  launch; sleep 2
  dump
  verdict "both rows are switched off" \
    "$(field "','.join(sorted(d['dash']['off']))")" "fact-chatter,fact-session,fact-trouble"
  verdict "the calm one stayed hidden" \
    "$(field "'yes' if 'fact-chatter' not in d['dash']['painted'] else 'no'")" "yes"
  verdict "the complaining one is in the lane" \
    "$(field "d['dash']['alarms']")" "['fact-trouble']"
  verdict "drawn on the second left line, after the last cell" \
    "$(field "'yes' if d['dash']['left'][1][-1] == 'fact-trouble' else 'no'")" "yes"
  note "  the second left line" "$(field "d['dash']['left'][1]")"
  verdict "in the full red of ISC-103" \
    "$(field "d['dash']['inks']['fact-trouble'][0]")" "#D4574A"
  verdict "whole, and not a word shorter" \
    "$(field "repr(d['dash']['painted']['fact-trouble'])")" "'DISK 100% AND CLIMBING'"
  verdict "and the line it was PUT on never opened for it" \
    "$(field "d['dash']['full']")" "[]"

  echo "--> the anti-pole: the same row, the same place, nothing wrong"
  BEFORE_LEFT="$(field "d['dash']['left'][1]")"
  send "facts $BIN/calm.sh"; sleep 2
  dump
  verdict "the reading changed" \
    "$(field "'yes' if 'STEADY' in d['dash']['values']['fact-trouble'] else 'no'")" "yes"
  verdict "the lane emptied itself" "$(field "d['dash']['alarms']")" "[]"
  verdict "nothing of it is on the bar" \
    "$(field "'yes' if 'fact-trouble' not in d['dash']['painted'] else 'no'")" "yes"
  verdict "and the second left line is exactly what it was" \
    "$(field "d['dash']['left'][1]")" "['scrollback', 'grid']"
  note "  it had been" "$BEFORE_LEFT"

  echo "--> the pole that matters most: never twice"
  # The same key, complaining, but PLACED and switched ON in another line.
  ON_SLOTS="left-1:fact-trouble,blocks,failed,turns,state|left-2:scrollback,grid|left-3:|right-1:dir,proc,agent,model|right-2:shell,blocks-on,panes,theme|right-3:|facts-1:fact-chatter|facts-2:|facts-3:"
  virgin; config_with "$BIN/alarming.sh" 0.5 "$ON_SLOTS"
  launch; sleep 2
  dump
  verdict "it is drawn where the user put it" \
    "$(field "'yes' if d['dash']['left'][0][0] == 'fact-trouble' else 'no'")" "yes"
  verdict "the lane is empty" "$(field "d['dash']['alarms']")" "[]"
  verdict "and it is NOT on the second left line as well" \
    "$(field "'yes' if 'fact-trouble' not in d['dash']['left'][1] else 'no'")" "yes"
  verdict "one rectangle for it on the whole bar" \
    "$(field "sum(1 for line in d['dash']['left'] + d['dash']['right'] + d['dash']['full'] for k in line if k == 'fact-trouble')")" "1"

  echo "--> and on a bar too narrow for it, the calm cells pay (not the warning)"
  # The long calm reading is ON and sits on `left-2` itself, so the line the
  # warning lands on genuinely cannot hold both. Without this the pole passed
  # while nothing was ever squeezed — a green that measured nothing.
  TIGHT="left-1:blocks,failed,turns,state|left-2:scrollback,grid,fact-chatter|left-3:|right-1:dir,proc,agent,model|right-2:shell,blocks-on,panes,theme|right-3:|facts-1:fact-trouble|facts-2:|facts-3:"
  virgin; config_with "$BIN/alarming.sh" 0.5 "$TIGHT" "fact-trouble"
  launch; sleep 2
  send "resize 760x700"; sleep 1.5
  dump
  note "  the second left line, squeezed" "$(field "d['dash']['left'][1]")"
  note "  what it was painted with" \
    "$(field "[(k, d['dash']['painted'][k]) for line in d['dash']['left'] for k in line if k in d['dash']['painted']]")"
  verdict "the line really did run out of room" \
    "$(field "'yes' if d['dash']['hidden'] or any(v.endswith('…') for v in d['dash']['painted'].values()) else 'no'")" "yes"
  verdict "the warning is still there" \
    "$(field "'yes' if 'fact-trouble' in d['dash']['painted'] else 'no'")" "yes"
  verdict "and still whole, to the character" \
    "$(field "repr(d['dash']['painted']['fact-trouble'])")" "'DISK 100% AND CLIMBING'"
  verdict "it was never one of the dropped" \
    "$(field "'yes' if 'fact-trouble' not in d['dash']['hidden'] else 'no'")" "yes"
  verdict "the calm reading paid instead" \
    "$(field "'yes' if 'fact-chatter' not in d['dash']['painted'] or d['dash']['painted']['fact-chatter'].endswith('…') else 'no'")" "yes"
  note "  what the bar gave up" "$(field "d['dash']['hidden'] or [k for k, v in d['dash']['painted'].items() if v.endswith('…')]")"
fi

# ------------------------------------------------------------------- crowd
if run crowd; then
  echo "==> more rows than the bar is wide: what goes, and what may never go"
  # The seventeen rows are PUT on the two third half lines, because that is
  # where they used to land by themselves and this pole is about the half
  # lines' rule: the widest cells give up characters first, down to twelve,
  # and then cells fall from the end. ISC-142 sends untouched provider rows to
  # the whole lines instead, so without this saved layout the pole would be
  # asking its question of a bar that no longer answers it — and the layout is
  # not an invention: it is exactly what a person dragging them there gets.
  CROWD_SLOTS="left-3:fact-alpha,fact-charlie,fact-echo,fact-golf,fact-india,fact-kilo,fact-mike,fact-oscar,fact-trouble|right-3:fact-bravo,fact-delta,fact-foxtrot,fact-hotel,fact-juliett,fact-lima,fact-november,fact-papa"
  virgin; config_with "$BIN/crowd.sh" 0.5 "$CROWD_SLOTS"; launch; sleep 2
  dump
  # Diciotto: le diciassette di sempre più la riga di sessione del banco.
  verdict "eighteen rows arrived" "$(field "len(d['dash']['facts']['keys'])")" "18"
  note "  what is on the bar" "$(field "sorted(k for k in d['dash']['painted'] if k.startswith('fact-'))")"
  note "  what there was no room for" "$(field "d['dash']['hidden']")"
  verdict "some of them did not fit" \
    "$(field "'yes' if d['dash']['hidden'] else 'no'")" "yes"
  verdict "and the bar says how many, out loud" \
    "$(field "sum(int(v[1:]) for k, v in d['dash']['painted'].items() if k.startswith('more-'))")" \
    "$(field "len(d['dash']['hidden'])")"
  verdict "the row that is complaining was NOT one of them" \
    "$(field "'yes' if 'fact-trouble' not in d['dash']['hidden'] else 'no'")" "yes"
  verdict "it is on the bar, in the critical red" \
    "$(field "d['dash']['inks']['fact-trouble'][0]")" "#D4574A"
  verdict "nothing on the bar is a five-letter stump" \
    "$(field "'yes' if all(len(v) >= 12 for k, v in d['dash']['painted'].items() if k.startswith('fact-')) else 'no'")" "yes"
  echo "--> the negative pole: switch enough of them off and nothing is hidden"
  # 900 e non 560, e il numero è stato misurato non scelto. Con ISC-172 la
  # lista delle righe è passata da 15 a 18 voci: in un pannello alto 560 il
  # bersaglio di questo trascinamento (`right-3`) non è più raggiungibile
  # nell'area visibile, e il trascinamento atterra su «none» — provato ai due
  # poli lo stesso giorno, 820x560 rosso e 820x900 verde, tutto il resto
  # uguale. Non è un difetto dell'app: il pannello vero scorre
  # (`NSScrollView`), ma un trascinamento non può scorrere mentre è in corso,
  # quindi origine e destinazione devono stare sullo schermo insieme.
  send "settings place 120,60,820,900"; sleep 1
  send "settings Dashboard rows"; sleep 0.8
  # The names as the PROVIDER wrote them: `#name` gives the label verbatim,
  # and only a row that never named itself gets its key capitalised.
  for row in alpha bravo charlie delta echo foxtrot golf hotel india juliett \
             kilo lima mike november; do send "toggle $row"; sleep 0.35; done
  sleep 1
  dump
  verdict "with fourteen switched off, nothing is hidden any more" \
    "$(field "d['dash']['hidden']")" "[]"
  verdict "and the +N is gone with them" \
    "$(field "'yes' if not [k for k in d['dash']['painted'] if k.startswith('more-')] else 'no'")" "yes"
  send "settings close"; sleep 0.5
fi

# ------------------------------------------------------------------- lines
if run lines; then
  echo "==> the whole lines: readings you READ, not readings you guess at (ISC-142)"
  # One launch, one window, one variable: the provider. The bar is measured
  # with nothing configured, then pointed at a program without relaunching —
  # which is what a person changing the setting does — so the height before
  # and after cannot be two different windows.
  # `bare.sh` e non «nessun fornitore»: con ISC-173 un pannello senza niente
  # attaccato non disegna nulla, quindi «la barra prima» misurata così
  # sarebbe zero e il delta sotto sarebbe l'intera barra invece delle due
  # linee intere che si aprono. L'apparecchio dichiara la sessione e non
  # emette nessuna lettura: è esattamente «la barra prima di una lettura».
  virgin; config_with "$BIN/bare.sh" 0.5; launch; sleep 1.5
  send "resize 1512x900"; sleep 1.2
  dump
  H0="$(field "int(d['dash']['height'])")"
  R0="$(field "d['dash']['rows']")"
  note "  window" "$(field "'%s x %s' % (d['window']['width'], d['window']['height'])")"
  verdict "a connected pane with no readings has no whole lines" \
    "$(field "d['dash']['full']")" "[]"
  verdict "and none of them is holding height" \
    "$(field "d['dash']['fullRows']")" "0"
  note "  the bar without a provider" "$H0 pt / $R0 rows"

  send "facts $BIN/wide.sh"; sleep 2
  dump
  H1="$(field "int(d['dash']['height'])")"
  # Quattordici e non tredici: la quattordicesima è la riga con cui questo
  # banco dichiara la sessione (ISC-173), stampata per ultima proprio perché
  # non sposti le altre.
  verdict "fourteen readings arrived" "$(field "len(d['dash']['facts']['keys'])")" "14"
  # TWO whole lines, not three: ISC-146 changed where an off-and-complaining
  # row comes back. It used to punch back into the line it had been placed on
  # — `facts-3` — which opened a whole line of the bar for one warning sitting
  # wherever that row happened to be. Now it comes back in the lane at the end
  # of `left-2`, and `facts-3` stays shut. The pole below was rewritten on
  # purpose, not repaired: the older behaviour is the one this claim replaced.
  verdict "and they went to the whole lines, four to a line" \
    "$(field "' | '.join(','.join(l) for l in d['dash']['full'])")" \
    "fact-s1,fact-s2,fact-s3,fact-long | fact-f1,fact-f2,fact-f3,fact-f4"
  # No `{...}` in a field expression, ever: bash brace-expands it BEFORE the
  # substitution runs, so `verdict` is handed one argument per element and the
  # value it compares lands in the `want` slot — the check then compares a
  # value with itself and prints ok whatever the app did. Caught here with a
  # pole that was green while the set it named was wrong. Sorted lists instead.
  verdict "the ninth onwards arrived switched OFF" \
    "$(field "','.join(sorted(d['dash']['off']))")" \
    "fact-f5,fact-f6,fact-f7,fact-f8,fact-session,fact-trouble"
  verdict "except the one that is complaining, which came back anyway" \
    "$(field "'yes' if 'fact-trouble' in d['dash']['painted'] else 'no'")" "yes"
  verdict "and it came back in the lane, not on its own line (ISC-146)" \
    "$(field "d['dash']['alarms']")" "['fact-trouble']"
  verdict "the two groups did not move" "$(field "d['dash']['rows']")" "$R0"
  verdict "the bar grew by exactly the two lines it opened" "$((H1 - H0))" "42"
  note "  the bar with the provider" "$H1 pt / $(field "'%s + %s' % (d['dash']['rows'], d['dash']['fullRows'])") rows"

  echo "--> a wide window: not one character is given up"
  verdict "every reading is painted whole, to the letter" \
    "$(field "'yes' if all(d['dash']['painted'][k] == d['dash']['values'][k][1:] for l in d['dash']['full'] for k in l) else 'no'")" "yes"
  verdict "nothing was cut" \
    "$(field "[k for l in d['dash']['full'] for k in l if d['dash']['painted'][k].endswith('…')]")" "[]"
  verdict "and nothing was dropped" "$(field "d['dash']['hidden']")" "[]"
  note "  the long one, in full" "$(field "d['dash']['painted']['fact-long']")"
  note "  how wide the first line came out" \
    "$(field "'%s pt of %s' % (int(sum(d['dash']['ink'][k]['w'] + 20 for k in d['dash']['full'][0])), d['window']['width'] - 28)")"

  echo "--> the anti-pole: a narrow window, where only the LAST cell may give way"
  send "resize 900x900"; sleep 1.5
  dump
  note "  the first line now" "$(field "[d['dash']['painted'][k] for k in d['dash']['full'][0]]")"
  verdict "the last cell of the line that overflows is cut" \
    "$(field "'yes' if d['dash']['painted'][d['dash']['full'][0][-1]].endswith('…') else 'no'")" "yes"
  verdict "and the ones before it are untouched" \
    "$(field "'yes' if all(d['dash']['painted'][k] == d['dash']['values'][k][1:] for k in d['dash']['full'][0][:-1]) else 'no'")" "yes"
  verdict "exactly one cell on the whole bar was cut" \
    "$(field "len([k for l in d['dash']['full'] for k in l if d['dash']['painted'][k].endswith('…')])")" "1"
  verdict "the line that had room kept every letter" \
    "$(field "'yes' if all(d['dash']['painted'][k] == d['dash']['values'][k][1:] for k in d['dash']['full'][1]) else 'no'")" "yes"
  # The WHOLE lines, which is what this section is about — `hidden` is one
  # list for the whole bar, and the half lines have their own story two lines
  # down. Narrowed on 23/08 with the reason written here rather than quietly:
  # the pole read `[]` and started reading `['grid']`, and the cause is the
  # mark ISC-152 put in front of a warning. It is four points wide, the alarm
  # rides the end of `left-2`, and at exactly 900 points those four were the
  # ones `GRID 96×24` did not have. That is the rule of ISC-146 working — a
  # calm cell gives way so the warning stays whole — so the pole below says
  # so out loud instead of being deleted.
  verdict "and nobody was dropped from the whole lines yet" \
    "$(field "[k for k in d['dash']['hidden'] if any(k in l for l in d['dash']['full'])]")" "[]"
  verdict "on the half lines the calm cell gave way to the warning" \
    "$(field "sorted(k for k in d['dash']['hidden'] if not any(k in l for l in d['dash']['full']))")" "['grid']"
  verdict "and the bar said so with a +N" \
    "$(field "'yes' if any(k.startswith('more-left') for k in d['dash']['painted']) else 'no'")" "yes"
  note "  the warning, painted" "$(field "d['dash']['painted'].get('fact-trouble')")"
  verdict "no cell was cut below the floor" \
    "$(field "'yes' if all(len(d['dash']['painted'][k]) >= 12 for l in d['dash']['full'] for k in l) else 'no'")" "yes"

  echo "--> past the floor: cells fall, a +N says how many, and never the alarm"
  # Thirteen rows on ONE whole line — the layout of somebody who dragged them
  # all there. At 900 pt every one of them is down at the floor and the line
  # still does not fit, which is the only state in which a cell is allowed to
  # go. The complaining row is put LAST on purpose: dropping happens from the
  # end, so it is the first cell the rule has to refuse to take.
  PILE="facts-1:fact-f1,fact-f2,fact-f3,fact-f4,fact-f5,fact-f6,fact-f7,fact-f8,fact-s1,fact-s2,fact-s3,fact-long,fact-trouble"
  virgin; config_with "$BIN/wide.sh" 0.5 "$PILE"; launch; sleep 2
  send "resize 900x900"; sleep 1.5
  dump
  note "  the pile, as painted" "$(field "[d['dash']['painted'].get(k,'—') for k in d['dash']['full'][0]]")"
  verdict "some of them fell" "$(field "'yes' if d['dash']['hidden'] else 'no'")" "yes"
  note "  what fell" "$(field "d['dash']['hidden']")"
  verdict "and the bar says how many, out loud" \
    "$(field "sum(int(v[1:]) for k, v in d['dash']['painted'].items() if k.startswith('more-'))")" \
    "$(field "len(d['dash']['hidden'])")"
  verdict "the marker belongs to the whole line it is on" \
    "$(field "'yes' if 'more-full-0' in d['dash']['painted'] else 'no'")" "yes"
  verdict "the row that is complaining did NOT fall" \
    "$(field "'yes' if 'fact-trouble' not in d['dash']['hidden'] else 'no'")" "yes"
  verdict "it is on the bar, in the critical red" \
    "$(field "d['dash']['inks']['fact-trouble'][0]")" "#D4574A"
  verdict "and what stayed is at the floor, never under it" \
    "$(field "'yes' if all(len(v) >= 12 for k, v in d['dash']['painted'].items() if k.startswith('fact-')) else 'no'")" "yes"
  DROPPED_AT_900="$(field "len(d['dash']['hidden'])")"
  echo "--> the negative pole: the same pile, a wider window, and nobody falls"
  send "resize 1512x900"; sleep 1.5
  dump
  note "  what fell at 900" "$DROPPED_AT_900 rows"
  verdict "at 1512 pt all thirteen are back on the line" \
    "$(field "d['dash']['hidden']")" "[]"
  verdict "and the +N went with them" \
    "$(field "'yes' if not [k for k in d['dash']['painted'] if k.startswith('more-')] else 'no'")" "yes"
  verdict "every one of them is drawn" \
    "$(field "len([k for k in d['dash']['painted'] if k.startswith('fact-')])")" "13"

  echo "--> a row goes either way: a provider row to a half line, a native one to a whole line"
  virgin; config_with "$BIN/wide.sh" 0.5; launch; sleep 2
  send "resize 1512x900"; sleep 1
  front || STATUS=1
  send "settings place 60,40,900,900"; sleep 1
  send "settings Dashboard rows"; sleep 0.8
  dump
  verdict "the three whole lines are destinations in the settings" \
    "$(field "','.join(sorted(l['slot'] for l in d['settings']['lines'] if l['slot'].startswith('facts-')))")" \
    "facts-1,facts-2,facts-3"
  for MOVE in "fact-s1 right-1" "grid facts-2"; do
    KEY="${MOVE%% *}"; DEST="${MOVE##* }"
    dump
    HX="$(field "int([r['handle']['x'] for r in d['settings']['rows'] if r['key']=='$KEY'][0])")"
    HY="$(field "int([r['handle']['y'] for r in d['settings']['rows'] if r['key']=='$KEY'][0])")"
    TX="$(field "int([l['rect']['x'] for l in d['settings']['lines'] if l['slot']=='$DEST'][0])")"
    TY="$(field "int([l['rect']['y'] for l in d['settings']['lines'] if l['slot']=='$DEST'][0])")"
    note "  dragging $KEY" "$HX,$HY  →  $DEST at $TX,$TY"
    .build/t4a-dragpoint "$HX" "$HY" "$TX" "$TY" 30
    sleep 1.5
    dump
    verdict "  $KEY landed on $DEST" \
      "$(field "d['settings']['trace'].get('ended','none').split('/')[0]")" "$DEST"
  done
  send "settings close"; sleep 0.5
  SAVED="$(grep '^dash-slots' "$CONFIG" | sed 's/.*= *//' | tr -d '\"')"
  note "  dash-slots on disk" "$SAVED"
  echo "--> and the restart, which is the only thing that proves it stuck"
  stop; launch; sleep 2
  dump
  verdict "the provider row is still on a half line" \
    "$(field "'yes' if 'fact-s1' in d['dash']['slots'].split('right-1:')[1].split('|')[0] else 'no'")" "yes"
  verdict "and it is drawn in the right-hand group" \
    "$(field "'yes' if any('fact-s1' in line for line in d['dash']['right']) else 'no'")" "yes"
  verdict "the native row is still on a whole line" \
    "$(field "'yes' if 'grid' in d['dash']['slots'].split('facts-2:')[1].split('|')[0] else 'no'")" "yes"
  verdict "and it is drawn on one" \
    "$(field "'yes' if any('grid' in line for line in d['dash']['full']) else 'no'")" "yes"
fi

# -------------------------------------------------------------------- dead
if run dead; then
  echo "==> a provider that dies: the readings stay, then they go dim"
  virgin; config_with "$BIN/good.sh" 0.5; launch; sleep 2
  dump
  BEFORE="$(field "d['dash']['painted']['fact-active']")"
  PID="$(pgrep -f 'T4A.app/Contents/MacOS/T4A' | head -1)"
  send "facts $BIN/dead.sh"; sleep 1
  dump
  verdict "one miss, and the reading is untouched" \
    "$(field "d['dash']['painted'].get('fact-active','gone')")" "$BEFORE"
  note "  misses so far" "$(field "d['dash']['facts']['misses']")"
  sleep 2.5
  dump
  verdict "three misses in, the row is stale" "$(field "d['dash']['facts']['stale']")" "True"
  verdict "the reading is still the one it had" \
    "$(field "d['dash']['painted'].get('fact-active','gone')")" "$BEFORE"
  verdict "and every word is drawn dim, whatever its tone said" \
    "$(field "','.join(t[1] for t in d['dash']['tones']['fact-active'])")" "dim,dim,dim,dim"
  verdict "in the one colour, read off the paint" \
    "$(field "','.join(sorted(set(d['dash']['inks']['fact-active'])))")" "#5E5E5E"
  verdict "the exit code was noticed" "$(field "d['dash']['facts']['lastExit']")" "1"
  verdict "nothing crashed" "$(pgrep -f 'T4A.app/Contents/MacOS/T4A' | head -1)" "$PID"
  echo "--> and a provider that comes back is not stale any more"
  send "facts $BIN/good.sh"; sleep 2
  dump
  verdict "the row is fresh again" "$(field "d['dash']['facts']['stale']")" "False"
fi

# -------------------------------------------------------------------- slow
if run slow; then
  echo "==> a provider that sleeps five seconds: the window does not"
  virgin; config_with "$BIN/slow.sh" 0.5; launch; sleep 1
  PID="$(pgrep -f 'T4A.app/Contents/MacOS/T4A' | head -1)"
  send "renderreset"; sleep 0.2
  # How many copies of the provider are alive AT ONCE, sampled while it is
  # sleeping rather than counted afterwards — afterwards they are all dead,
  # and a count of zero taken then would be a green light wired to nothing.
  CONCURRENT=/tmp/t4a-facts-concurrent.txt
  : > "$CONCURRENT"
  (
    end=$(( $(date +%s) + 12 ))
    while [ "$(date +%s)" -lt "$end" ]; do
      # `pgrep -c` does not exist on macOS: it exits 2 with a usage message,
      # the file gets the fallback zero, and the count reads as "none were
      # running" for ever. That is how this probe first came out green.
      pgrep -f "$BIN/slow.sh" 2>/dev/null | wc -l | tr -d ' ' >> "$CONCURRENT"
      sleep 0.1
    done
  ) &
  SAMPLER=$!
  WORST=0
  for _ in $(seq 1 6); do
    START="$(/usr/bin/python3 -c 'import time; print(time.time())')"
    send "text echo tick"; send "key return"
    dump
    ELAPSED="$(/usr/bin/python3 -c "import time; print(int((time.time() - $START) * 1000))")"
    [ "$ELAPSED" -gt "$WORST" ] && WORST="$ELAPSED"
    sleep 0.3
  done
  wait "$SAMPLER" 2>/dev/null || true
  MOST="$(sort -n "$CONCURRENT" | tail -1)"
  SEEN="$(grep -c '^[1-9]' "$CONCURRENT" || true)"
  send "renderstats /tmp/t4a-facts-render.json"; sleep 0.6
  FRAMES="$(/usr/bin/python3 -c "import json; print(int(json.load(open('/tmp/t4a-facts-render.json'))['frames']))")"
  note "  worst round trip while it slept" "$WORST ms"
  verdict "the app answered throughout" "$([ "$WORST" -lt 1000 ] && echo yes || echo no)" "yes"
  verdict "frames were drawn while it slept" \
    "$([ "$FRAMES" -gt 0 ] && echo yes || echo no)" "yes"
  note "  frames counted" "$FRAMES"
  dump
  verdict "it was killed at the deadline" "$(field "d['dash']['facts']['lastTimedOut']")" "True"
  verdict "so it never put a row on the bar" \
    "$(field "'yes' if 'fact-slow' not in d['dash']['painted'] else 'no'")" "yes"
  note "  samples that caught it running" "$SEEN of $(wc -l < "$CONCURRENT" | tr -d ' ')"
  verdict "the sampler could see it at all" \
    "$([ "$SEEN" -gt 0 ] && echo yes || echo no)" "yes"
  verdict "and never more than one at a time" "$MOST" "1"
  verdict "nothing crashed" "$(pgrep -f 'T4A.app/Contents/MacOS/T4A' | head -1)" "$PID"
fi

# ------------------------------------------------------------------ writes
if run writes; then
  echo "==> sixty ticks of a live provider: how many times is config.toml written?"
  virgin; config_with "$BIN/good.sh" 0.1; launch; sleep 2
  dump
  W0="$(field "d['configWrites']")"
  R0="$(field "d['dash']['facts']['runs']")"
  sleep 8
  dump
  W1="$(field "d['configWrites']")"
  R1="$(field "d['dash']['facts']['runs']")"
  note "  runs in the window" "$((R1 - R0))"
  verdict "at least sixty ticks happened" \
    "$([ "$((R1 - R0))" -ge 60 ] && echo yes || echo no)" "yes"
  verdict "and the file was written none of those times" "$((W1 - W0))" "0"
fi

# ------------------------------------------------------------------ absent
if run absent; then
  echo "==> niente fornitore e niente agente: la barra non c'è (ISC-173)"
  WORK=/tmp/t4a-facts-head
  # The baseline is the commit BEFORE this feature landed, and it is worked out
  # from the repository rather than typed: the parent of whatever commit added
  # the parser. Pinning it to `HEAD` was wrong the moment the feature was
  # committed — the pole then compared the bar against itself with the provider
  # switched off, which is a weaker question than the one the claim asks.
  BASE="${BASE:-$(git rev-parse "$(git log --format=%H --diff-filter=A -1 \
      -- Sources/TerminalCore/FactsFeed.swift)^" 2>/dev/null)}"
  [ -n "$BASE" ] || { echo "could not work out the baseline commit" >&2; STATUS=1; }
  echo "    baseline $BASE ($(git log -1 --format=%s "$BASE" 2>/dev/null))"
  rm -rf "$WORK"
  git worktree remove --force "$WORK" 2>/dev/null || true
  git worktree add --detach "$WORK" "$BASE" >/dev/null 2>&1 \
    || { echo "could not make a worktree at $BASE" >&2; STATUS=1; }
  if [ -d "$WORK" ]; then
    ( cd "$WORK" && ./Scripts/build-app.sh bench >/tmp/t4a-facts-head-build.log 2>&1 ) \
      || { echo "HEAD would not build; see /tmp/t4a-facts-head-build.log" >&2; STATUS=1; }
  fi
  for POLE in head new; do
    virgin
    if [ "$POLE" = "head" ]; then THIS="$WORK/dist/T4A.app"; else THIS="$APP"; fi
    [ -x "$THIS/Contents/MacOS/T4A" ] || { echo "no bundle for $POLE" >&2; STATUS=1; continue; }
    rm -f "$FIFO"
    open -n "$THIS" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
    for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
    sleep 4
    dump
    cp "$DUMP" "/tmp/t4a-facts-$POLE.json"
    stop
  done
  /usr/bin/python3 - <<'PY'
import json, sys
head = json.load(open('/tmp/t4a-facts-head.json'))['dash']
new = json.load(open('/tmp/t4a-facts-new.json'))['dash']

# RISCRITTO IL 25/08 PER ISC-173, e la premessa vecchia va detta perché
# capire questa riscrittura richiede di sapere cosa c'era prima.
#
# Prima questo polo chiedeva: «la barra di chi non ha un fornitore è la stessa
# di prima che la funzione dei fatti esistesse?», e confrontava campo per
# campo il build di allora con quello di adesso. Era la domanda giusta finché
# la risposta doveva essere «sì».
#
# ISC-173 la cambia per DECISIONE, non per deriva: sopra una shell nuda, senza
# niente attaccato, la barra adesso non disegna nulla e non costa niente. Il
# confronto campo per campo quindi non può più tenere, e lasciarlo lì rosso
# avrebbe reso il banco un rumore che si impara a ignorare — che è il modo in
# cui un banco muore.
#
# La domanda nuova ha ancora due poli, e usa il build vecchio come TESTIMONE
# invece che come metro: quello di prima disegnava una barra sopra una shell
# nuda, questo non la disegna. Se un giorno il cancello di ISC-173 sparisse,
# il polo `new` tornerebbe a somigliare a `head` e questo diventerebbe rosso.
problemi = []

# Il testimone: prima ISC-173 la barra c'era, ed è ciò che rende «adesso non
# c'è» una notizia invece di una tautologia.
if head['rows'] < 1 or not (head.get('values') or {}):
    problemi.append("il build di riferimento non disegnava una barra: "
                    "il testimone non testimonia niente "
                    f"(rows={head['rows']}, values={len(head.get('values') or {})})")
else:
    print(f"    prima (build di riferimento)  rows={head['rows']} "
          f"celle={len(head.get('values') or {})} altezza={head.get('height')}")

# Il fatto: adesso, stesse condizioni, niente.
painted = new.get('painted') or {}
print(f"    adesso                        rows={new['rows']} "
      f"dipinte={len(painted)} altezza={new.get('height')}")
if new['rows'] != 0:
    problemi.append(f"rows={new['rows']} invece di 0")
if painted:
    problemi.append(f"dipinge {sorted(painted)}")
if float(new.get('height') or 0) != 0.0:
    problemi.append(f"altezza {new.get('height')} invece di 0")

if problemi:
    print("    SBAGLIATO: " + " · ".join(problemi))
ok = not problemi
print(f"{'ok' if ok else 'FAILED'}  la barra senza fornitore e senza agente non c'è più (ISC-173)")
sys.exit(0 if ok else 1)
PY
  [ $? -eq 0 ] || STATUS=1
  git worktree remove --force /tmp/t4a-facts-head 2>/dev/null || true
fi

stop
echo
[ "$STATUS" = "0" ] && echo "facts: every pole held" || echo "facts: SOMETHING IS RED"
exit "$STATUS"
