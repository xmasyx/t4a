#!/bin/bash
# ISC-149 e ISC-173 — quando la barra parla, e cosa dice quando parla.
#
#   Scripts/bench-rows.sh [app-bundle]
#
# LE DUE REGOLE, che sembrano opposte e non lo sono.
#
# ISC-149 dice cosa fa una riga ACCESA che non ha una lettura: disegna un
# trattino. Il difetto che l'ha aperta, misurato il 2026-08-22: con una shell
# nuda, QUATTRO righe delle quattordici che si possono accendere — `Agent
# turns`, `Session state`, `Agent`, `Model` — erano accese, stavano sulla loro
# riga di default, e non disegnavano niente. Niente lo diceva: `hidden` era
# vuoto, quindi non erano state schiacciate fuori; semplicemente non avevano
# una lettura, e una chiave senza lettura restava fuori dalla barra.
#
# ISC-173 dice QUANDO quella domanda ha senso. Sopra una shell nuda non c'è
# nessuna sessione di cui dire niente, e quattordici trattini in fila non sono
# onestà: sono una barra che si prende lo schermo per dire che non sa nulla.
# Peggio, il 25/08 quella barra era piena di fatti VERI del fornitore — `ACTIVE
# HAIKU SONNET OPUS FABLE`, `MEMORY OK`, `5HR 8%` — nessuno dei quali
# riguardava il pannello sotto. Quindi: pannello non connesso, barra muta, zero
# punti di altezza. Appena si connette, ISC-149 riprende a valere per intero.
#
# PERCHÉ QUESTO BANCO È STATO RIBASATO. I poli 1-5 misuravano una shell nuda,
# ed erano giusti finché una shell nuda disegnava la popolazione intera. Con
# ISC-173 una shell nuda disegna ZERO, quindi lì non c'è più niente da contare:
# gli stessi cinque poli si eseguono adesso con `claude` agganciato, che è il
# posto dove la domanda «una riga accesa è una riga disegnata?» esiste ancora.
#
# L'ordine, e ogni passo è dove è per un motivo:
#
#   A.  shell nuda: `painted` vuoto, `rows` 0, altezza 0. Nemmeno `DIR`.
#   B1. un `false` nella shell nuda con la sua riga SPENTA: ancora niente. È
#       il polo che dice che nemmeno un allarme buca un pannello non connesso.
#   --- si aggancia `claude`, e da qui in poi la barra è intera ---
#   B2. lo STESSO `false`, la STESSA riga spenta: adesso `failed` è dipinta,
#       nel rosso critico. ISC-104.3 vale, ma solo a pannello connesso.
#   1.  LA POPOLAZIONE, non un campione: ogni riga piazzabile del catalogo
#       cercata in quello che la barra ha DIPINTO. Il conto viene dal catalogo
#       dell'app, così il giorno che nasce una riga in più il banco la chiede
#       da sé senza che nessuno tocchi questo file.
#   2.  Il polo negativo, che è ciò che dà un senso al primo: una riga SPENTA
#       non è dipinta. Senza, «è tutto disegnato» è una frase che produrrebbe
#       anche un banco incapace di vedere la barra.
#   3.  Ognuna, spenta e riaccesa dalla finestra delle impostazioni, una per
#       volta — così «accesa implica disegnata» è verificato riga per riga e
#       non solo sull'insieme.
#   4.  Un segnaposto dice `—` e nient'altro. Prima del primo turno `model`,
#       `context`, `output` ed `effort` non hanno una lettura, e una riga senza
#       lettura non se ne inventa una.
#   5.  La barra non è cresciuta. Righe in più non devono costare una riga di
#       finestra, o la riparazione avrebbe comprato l'onestà con il suo schermo.
#   6.  Dopo un turno VERO, i quattro trattini cedono ai numeri: contesto in
#       token, uscita in token, effort e modello, presi dal transcript che
#       l'adattatore già apre (ISC-172). Nessun fornitore configurato: la
#       config di questo banco è vergine, quindi è nudo per costruzione.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-rows.fifo"
CONFIG_HOME="/tmp/t4a-rows-config"
DUMP=/tmp/t4a-rows-dump.json
SHOTS=design/evidence
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
  printf '%-52s %s  %s\n' "$name" "$([ "$ok" = "0" ] && echo PASS || echo FAIL)" "$detail"
  [ "$ok" = "0" ] || STATUS=1
}
# `set -e` e un banco sono nemici naturali: un polo che diventa rosso è il
# banco che FUNZIONA, e un controllo non protetto porterebbe giù il processo
# prima che il verdetto sia stampato. Ogni controllo passa di qui, che
# trasforma un'uscita diversa da zero in un numero invece che in una fine.
POLE=0
shoot() {
  mkdir -p "$SHOTS" .build
  [ -x .build/t4a-winid ] || swiftc -O Scripts/winid.swift -o .build/t4a-winid
  local wid; wid="$(.build/t4a-winid || true)"
  if [ -n "$wid" ]; then
    screencapture -x -o -l "$wid" "$SHOTS/$1"
    echo "      photographed: $SHOTS/$1"
  else
    echo "      no window id: no photograph taken"; STATUS=1
  fi
}

# L'attesa che conta non è una FRASE sullo schermo, è il fatto.
#
# Questo banco aspettava che comparisse «auto mode on», ed è un'asserzione
# sulla MACCHINA e non sul codice: quella riga dipende da come è configurata
# la sessione di chi esegue il banco. Il 25/08 la stessa identica corsa ha
# stampato «manual mode on», e il banco ha dichiarato che claude non era mai
# partito mentre l'adattatore era agganciato da dodici secondi. La condizione
# vera — l'unica che serve ai poli sotto — è che l'adattatore si sia
# agganciato, e sta nel dump.
wait_for_attached() {
  local limit="${1:-60}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    dump
    [ "$(field "d['agents'][0]['adapter'].get('attached')" 2>/dev/null || echo False)" = "True" ] \
      && return 0
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

t4a_note_his_app
t4a_stop_bench
sleep 1.5
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3
send "activate"; sleep 1

echo "=== A. shell nuda: la barra non dice niente ========================"
dump
POLE=0
/usr/bin/python3 - <<'PY' || POLE=$?
import json, sys
d = json.load(open('/tmp/t4a-rows-dump.json'))
dash = d['dash']
painted, rows, height = dash['painted'], dash['rows'], dash['height']
alarms = dash.get('alarms') or []
print("      painted : %r" % painted)
print("      rows    : %s   height: %s   alarms: %s" % (rows, height, alarms))
bad = []
if painted: bad.append("dipinge %d celle: %s" % (len(painted), sorted(painted)))
if rows != 0: bad.append("rows=%s invece di 0" % rows)
if float(height) != 0.0: bad.append("altezza %s invece di 0" % height)
if alarms: bad.append("allarmi: %s" % alarms)
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "A shell nuda: niente dipinto, zero righe, zero altezza" "$POLE" \
  "$(field "'painted=%d rows=%s height=%s' % (len(d['dash']['painted']), d['dash']['rows'], d['dash']['height'])")"
shoot "f9-173-bare-shell-no-bar.png"

echo
echo "=== B1. e nemmeno un allarme la fa comparire ======================="
# La riga si spegne: con ISC-104.3 una riga spenta che si lamenta torna da
# sola. Il punto di questo polo è che quella regola vale solo a pannello
# connesso — qui non c'è niente da cui tornare.
send "settings open"; sleep 1
send "settings Dashboard rows"; sleep 0.8
send "toggle Failed commands"; sleep 0.8
send "settings close"; sleep 0.5
send "text false"; send "key return"; sleep 2
dump
POLE=0
/usr/bin/python3 - <<'PY' || POLE=$?
import json, sys
d = json.load(open('/tmp/t4a-rows-dump.json'))
dash = d['dash']
print("      comandi falliti visti dalla shell: %s"
      % d['dash']['values'].get('failed', '(nessuna cella)'))
print("      painted: %r   alarms: %s" % (dash['painted'], dash.get('alarms') or []))
bad = []
if dash['painted']: bad.append("painted non è vuoto: %s" % sorted(dash['painted']))
if dash.get('alarms'): bad.append("la corsia degli allarmi ha %s" % dash['alarms'])
if float(dash['height']) != 0.0: bad.append("altezza %s" % dash['height'])
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "B1 un comando fallito non buca un pannello spento" "$POLE" \
  "$(field "'painted=%d alarms=%d' % (len(d['dash']['painted']), len(d['dash'].get('alarms') or []))")"

echo
echo "=== si aggancia claude ============================================"
if ! command -v claude >/dev/null 2>&1; then
  echo "      claude NON È SUL PATH: da qui in poi il banco NON È STATO ESEGUITO."
  echo "      Rosso e non verde: un banco che non ha misurato niente non ha"
  echo "      niente da promuovere."
  t4a_stop_bench; rm -f "$FIFO"
  echo "rows: NON ESEGUITO (claude non è sul PATH)"
  exit 1
fi
# Il modello più economico, e passato con l'ambiente: `--model` è un flag del
# lanciatore e non del programma, e con un `CLAUDE_CONFIG_DIR` vergine Claude
# Code aprirebbe l'onboarding lasciando la sessione a zero turni. Quindi si
# gira nella casa vera, con la config di T4A vergine — che è ciò che rende
# questo banco NUDO: nessun fornitore di fatti configurato, per costruzione.
send "text cd $(pwd) && ANTHROPIC_MODEL=claude-haiku-4-5-20251001 claude"
send "key return"
if ! wait_for_attached 90; then
  echo "      l'adattatore non si è mai agganciato: il banco NON È STATO ESEGUITO"
  t4a_stop_bench; rm -f "$FIFO"
  echo "rows: NON ESEGUITO (claude non si è avviato)"
  exit 1
fi
sleep 3
dump
ATTACHED="$(field "d['agents'][0]['adapter'].get('attached')")"
POLE=0; [ "$ATTACHED" = "True" ] || POLE=1
verdict "l'adattatore si è agganciato" "$POLE" "attached=$ATTACHED"

echo
echo "=== B2. lo stesso false, la stessa riga spenta, adesso si vede ====="
# `Failed commands` è ancora spenta da B1, e il `false` è lo stesso di prima:
# cambia solo che il pannello adesso è connesso.
POLE=0
/usr/bin/python3 - <<'PY' || POLE=$?
import json, sys
d = json.load(open('/tmp/t4a-rows-dump.json'))
dash = d['dash']
off = dash['off']
painted = dash['painted'].get('failed')
ink = dash['inks'].get('failed')
print("      failed è spenta: %s" % ('failed' in off))
print("      ed è dipinta   : %r  in %s" % (painted, ink))
bad = []
if 'failed' not in off: bad.append("la riga non è spenta, il polo non misura niente")
if not painted: bad.append("spenta e NON dipinta: l'allarme non ha bucato")
sys.exit(1 if bad else 0)
PY
verdict "B2 spenta ma in allarme, a pannello connesso, torna" "$POLE" \
  "$(field "'%r in %s' % (d['dash']['painted'].get('failed'), d['dash']['inks'].get('failed'))")"
send "settings open"; sleep 0.8
send "settings Dashboard rows"; sleep 0.6
send "toggle Failed commands"; sleep 0.8
send "settings close"; sleep 0.5

echo
echo "=== 1. la popolazione intera, con claude agganciato ================"
dump
cp "$DUMP" /tmp/t4a-rows-attached.json
POLE=0
/usr/bin/python3 - <<'PY' || POLE=$?
import json, sys
d = json.load(open('/tmp/t4a-rows-attached.json'))
dash = d['dash']
# Il catalogo è la lista dell'app, così una riga aggiunta domani viene chiesta
# senza che questo file sia toccato. `worker` è escluso perché è transitorio
# per dichiarazione: esiste solo mentre qualcosa gira e non vive su nessuna riga.
placeable = [e['key'] for e in dash['catalog'] if e['key'] != 'worker']
painted = set(dash['painted'])
missing = [k for k in placeable if k not in painted]
print("      catalogo : %d righe piazzabili" % len(placeable))
print("      dipinte  : %d" % len([k for k in placeable if k in painted]))
if missing:
    print("      MANCANO  : %s" % ", ".join(missing))
    for k in missing:
        print("        %-12s value=%r  su una riga=%s  spenta=%s" % (
            k, dash['values'].get(k),
            dash['slots'].find(k) >= 0, k in dash['off']))
sys.exit(1 if missing else 0)
PY
verdict "1 ogni riga accesa è disegnata" "$POLE" \
  "$(field "'%d di %d dipinte' % (len([e for e in d['dash']['catalog'] if e['key']!='worker' and e['key'] in d['dash']['painted']]), len([e for e in d['dash']['catalog'] if e['key']!='worker']))")"
shoot "f9-149-all-rows-visible.png"

echo
echo "=== 2. il polo negativo: una riga SPENTA non è disegnata ==========="
send "settings open"; sleep 1
send "settings Dashboard rows"; sleep 0.8
send "toggle Grid size"; sleep 1
dump
GRID_OFF="$(field "'grid' in d['dash']['painted']")"
POLE=0; [ "$GRID_OFF" = "False" ] || POLE=1
verdict "2 spenta, Grid size lascia la barra" "$POLE" "painted=$GRID_OFF"
send "toggle Grid size"; sleep 1
dump
GRID_ON="$(field "'grid' in d['dash']['painted']")"
POLE=0; [ "$GRID_ON" = "True" ] || POLE=1
verdict "2b e riaccesa torna" "$POLE" "painted=$GRID_ON"

echo
echo "=== 3. una riga per volta, tutte quante ==========================="
# I nomi come li mostra la finestra delle IMPOSTAZIONI, letti dall'app invece
# che scritti qui: una lista scritta a mano scade il giorno che una riga viene
# rinominata, e un interruttore che nessuno ha premuto si legge esattamente
# come un interruttore che ha funzionato.
#
# NOTA, e va letta prima di guardare il verdetto: `Running work` (`worker`)
# esce SBAGLIATA, ed è un rosso che c'era già prima di questo lavoro. Non è la
# riga, è questo polo: `worker` è transitoria — esiste solo mentre un attrezzo
# gira — quindi il polo 1 la esclude per nome e questo la include, perché la
# prende dagli interruttori. Fuori da un turno vale nil accesa e spenta, e
# nil non è dipinto in nessuno dei due casi. La riparazione sta nel piano
# (`PIANO-RIPARAZIONI-20260825.md`) e non è stata fatta qui: ripararla
# nascondendola dentro un lavoro sulle righe native avrebbe cambiato il metro
# nello stesso momento in cui si misurava.
#
# E una riga che si LAMENTA torna da sola anche da spenta (ISC-104.3): per
# quelle la metà negativa del polo non vale, ed è dichiarato invece che
# subìto. La lista arriva dal campo `alarmed` del dump, non da un elenco
# scritto qui: un nome scritto a mano sarebbe di nuovo un metro che scade.
NAMES="$(field "'|'.join(sorted(d['settings']['switches']))")"
COUNT=0
BAD=""
IFS='|' read -r -a NAMEARR <<<"$NAMES"
for name in "${NAMEARR[@]}"; do
  KEY="$(/usr/bin/python3 -c "
import json
d=json.load(open('$DUMP'))
print(next((e['key'] for e in d['dash']['catalog'] if e['name']=='''$name'''), ''))
")"
  [ -n "$KEY" ] || continue
  COUNT=$((COUNT + 1))
  send "toggle $name"; sleep 0.55
  dump
  OFF="$(field "'$KEY' in d['dash']['painted']")"
  ALARMED="$(field "'$KEY' in d['dash'].get('alarmed', [])")"
  send "toggle $name"; sleep 0.55
  dump
  ON="$(field "'$KEY' in d['dash']['painted']")"
  if [ "$ON" = "True" ] && [ "$OFF" = "False" ]; then
    printf '      %-22s %-12s spenta->via  accesa->disegnata\n' "$name" "($KEY)"
  elif [ "$ON" = "True" ] && [ "$ALARMED" = "True" ]; then
    printf '      %-22s %-12s accesa->disegnata  spenta->RESTA, si lamenta (ISC-104.3)\n' \
      "$name" "($KEY)"
  else
    printf '      %-22s %-12s off=%s on=%s allarme=%s  <- SBAGLIATA\n' \
      "$name" "($KEY)" "$OFF" "$ON" "$ALARMED"
    BAD="$BAD $KEY"
  fi
done
POLE=0; [ -z "$BAD" ] || POLE=1
verdict "3 ognuna delle $COUNT righe: accesa implica disegnata" "$POLE" "${BAD:-nessuna sbagliata}"
send "settings close"; sleep 0.5

echo
echo "=== 4. una riga senza lettura dice il trattino, e nient'altro ======"
dump
POLE=0
/usr/bin/python3 - <<'PY' || POLE=$?
import json, sys
d = json.load(open('/tmp/t4a-rows-dump.json'))
dash = d['dash']
# Prima del primo turno queste quattro NON possono avere una lettura: nessun
# record `assistant` è ancora stato scritto, quindi non c'è né un modello né
# un conteggio di token né uno sforzo da leggere. `turns`, `state` e `agent`
# invece adesso ce l'hanno — l'agente è agganciato — ed è il polo 6 che
# guarda cosa succede a queste quattro quando la lettura arriva.
blank = ['model', 'context', 'output', 'effort']
bad = []
for key in blank:
    drawn = dash['painted'].get(key)
    if drawn != '—':
        bad.append('%s=%r' % (key, drawn))
    else:
        print("      %-8s dipinta %r con l'etichetta %r" % (key, drawn, dash['labels'].get(key)))
if bad:
    print("      INVENTATE: %s" % ", ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "4 senza lettura un trattino, mai una stima" "$POLE" "model/context/output/effort"

echo
echo "=== 5. e non è costato niente alla finestra ========================"
ROWS="$(field "d['dash']['rows']")"
HEIGHT="$(field "d['dash']['height']")"
HIDDEN="$(field "d['dash']['hidden']")"
POLE=0; { [ "$ROWS" = "2" ] && [ "$HIDDEN" = "[]" ]; } || POLE=1
verdict "5 la barra è ancora due righe, niente schiacciato fuori" "$POLE" \
  "rows=$ROWS height=$HEIGHT hidden=$HIDDEN"

echo
echo "=== 6. dopo un turno vero, la barra dice quello che dice il file ==="
# Non «non è più un trattino», che è la domanda debole: si ricalcolano i tre
# numeri dal transcript, con codice che non è quello dell'app, e si pretende
# che la barra dica LA STESSA COSA. Un numero plausibile e sbagliato passerebbe
# la prima domanda e non questa.
#
# E `effort` non si pretende: si pretende che coincida col file. Misurato il
# 25/08, una sessione haiku non scrive affatto quel campo, quindi lì il
# trattino è la risposta GIUSTA — un polo che pretendesse un valore starebbe
# chiedendo all'app di inventarne uno, che è la cosa che ISC-149 vieta.
send "text ciao"; sleep 0.5; send "key return"
FOUND=0
for _ in $(seq 1 40); do
  sleep 3; dump
  if [ "$(field "d['dash']['painted'].get('context', '—') != '—'")" = "True" ]; then
    FOUND=1; break
  fi
done
if [ "$FOUND" = "0" ]; then
  echo "      nessuna risposta in due minuti: il polo 6 NON È STATO ESEGUITO"
  STATUS=1
else
  POLE=0
  /usr/bin/python3 Scripts/lib/rows-parity.py /tmp/t4a-rows-dump.json || POLE=$?
  verdict "6 la barra dice quello che dice il file" "$POLE" "context/output/effort/model"
  shoot "f9-172-native-rows-with-claude.png"
fi

echo
echo "=== 7. ISC-192: la nativa cede alla gemella del fornitore =========="
# Parole sue, 27/08: «togli la voce model, teniamo solo active model; context
# (provider) e context, teniamo solo context (provider)». Tre coppie —
# `model`/`fact-active`, `context`/`fact-context`, `effort`/`fact-effort` — e
# la tabella che le tiene sta in un posto solo, `DashCatalog.twins`.
#
# Il polo si gira QUI e non in un'istanza nuova per una ragione sola: la barra
# disegna solo a pannello connesso (ISC-173), e claude è agganciato adesso. Il
# «senza fornitore» quindi non è un altro banco, è il PRIMA di questo: la
# config di questa istanza è vergine, le tre native sono nell'elenco e sulla
# barra, e il fornitore arriva a metà polo con `facts`, che è la stessa strada
# di chi lo scrive nel file e riavvia.
send "settings open"; sleep 0.8
send "settings Dashboard rows"; sleep 0.8
dump
BEFORE_LIST="$(field "sorted(n for n in d['settings']['switches'] if n in ('Model','Context','Effort'))")"
BEFORE_BAR="$(field "[k for k in ('model','context','effort') if k in d['dash']['painted']]")"
echo "      senza fornitore, nell'elenco: $BEFORE_LIST"
echo "      senza fornitore, sulla barra: $BEFORE_BAR"
POLE=0
[ "$BEFORE_LIST" = "['Context', 'Effort', 'Model']" ] || POLE=1
[ "$BEFORE_BAR" = "['model', 'context', 'effort']" ] || POLE=1
verdict "7a senza fornitore le tre native ci sono (ISC-172)" "$POLE" \
  "elenco=$BEFORE_LIST barra=$BEFORE_BAR"

TWINS=/tmp/t4a-rows-twins.sh
cat > "$TWINS" <<'SH'
#!/bin/bash
printf '#name\tactive\tActive models\n'; printf 'active\tACTIVE HAIKU OPUS\tmuted\n'
printf '#name\tcontext\tContext\n';      printf 'context\tCONTEXT 17%%\tmuted\n'
printf '#name\teffort\tEffort\n';        printf 'effort\tHIGH\tmuted\n'
SH
chmod +x "$TWINS"
send "facts $TWINS"; sleep 3
dump
AFTER_LIST="$(field "sorted(n for n in d['settings']['switches'] if n in ('Model','Context','Effort'))")"
AFTER_BAR="$(field "[k for k in ('model','context','effort') if k in d['dash']['painted']]")"
TWIN_LIST="$(field "sorted(n for n in d['settings']['switches'] if 'Active models' in n or 'Effort' in n or 'Context' in n)")"
TWIN_BAR="$(field "sorted(k for k in d['dash']['painted'] if k.startswith('fact-'))")"
echo "      col fornitore, native nell'elenco: $AFTER_LIST"
echo "      col fornitore, native sulla barra: $AFTER_BAR"
echo "      e le gemelle, nell'elenco: $TWIN_LIST"
echo "      e le gemelle, sulla barra : $TWIN_BAR"
POLE=0
[ "$AFTER_LIST" = "[]" ] || POLE=1
[ "$AFTER_BAR" = "[]" ] || POLE=1
# La metà che rende il polo una misura e non una cancellazione: sparite le
# native, le gemelle devono esserci. Un'app che avesse tolto tutte e sei
# passerebbe le due righe qui sopra.
[ "$(field "len([k for k in d['dash']['painted'] if k.startswith('fact-')])")" -ge 3 ] || POLE=1
verdict "7b col fornitore la nativa sparisce, la gemella resta" "$POLE" \
  "native=$AFTER_LIST gemelle dipinte=$TWIN_BAR"
# La chiave resta nel file: sparisce dall'elenco, non dal layout di chi un
# domani toglie il fornitore.
POLE=0
[ "$(field "'model' in d['dash']['slots'] and 'context' in d['dash']['slots']")" = "True" ] || POLE=1
verdict "7c e la chiave resta al suo posto in dash-slots" "$POLE" \
  "$(field "d['dash']['slots'].split('|')[3]")"
send "settings close"; sleep 0.5
rm -f "$TWINS"

echo
echo "=== A2. un fornitore che risponde SENZA conoscere la sessione non connette ==="
# Il caso che il banco non copriva, e che il 26/08 alle 01:04 ha riempito la
# barra dell'autore sopra una shell nuda con `composer-mode = agent`: il
# fornitore risponde SEMPRE — scala dei modelli, memoria, finestre —
# e quando non riconosce la sessione manda la riga del contesto come
# didascalia più trattino, `CONTEXT —`. Nessuna di quelle è una lettura di
# QUESTO pannello: la barra resta vuota e la bolla nascosta. Un fornitore
# finto che fa esattamente questo; il polo era rosso sul bundle 1682a63.
t4a_stop_bench; sleep 1.5
PROV=/tmp/t4a-rows-provider.sh
cat > "$PROV" <<'SH'
#!/bin/bash
printf '#name\tactive\tActive models\n'; printf 'active\tACTIVE\tmuted\n'; printf 'active\tHAIKU\tmuted\n'
printf '#name\tmemory\tMemory\n';         printf 'memory\tMEMORY OK\tok\n'
printf '#name\tcontext\tContext\n';       printf 'context\tCONTEXT\tmuted\n'; printf 'context\t—\tdim\n'
printf '#name\tusage\tUsage\n';           printf 'usage\t5HR 8%%\tmuted\n'
SH
chmod +x "$PROV"
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME/t4a"
printf 'facts-provider = "%s"\nfacts-interval = 1\ncomposer-mode = agent\n' "$PROV" > "$CONFIG_HOME/t4a/config.toml"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared (A2)" >&2; STATUS=1; }
sleep 5
send "activate"; sleep 1
dump
POLE=0
/usr/bin/python3 - <<'PY2' || POLE=$?
import json, sys
d = json.load(open('/tmp/t4a-rows-dump.json'))
dash, comp = d['dash'], d['composer']
answered = any(e['key'].startswith('fact-') for e in dash['catalog'])
print("      il fornitore ha risposto (righe fact- nel catalogo): %s" % answered)
print("      painted : %r" % dash['painted'])
print("      rows    : %s   height: %s   bolla shown=%s height=%s mode=%s" % (
    dash['rows'], dash['height'], comp.get('shown'), comp.get('height'), comp.get('mode')))
bad = []
if not answered: bad.append('il fornitore non ha risposto: il polo non misura niente')
if dash['painted']: bad.append('dipinte %d celle' % len(dash['painted']))
if dash['rows'] != 0 or dash['height'] != 0: bad.append('rows=%s height=%s' % (dash['rows'], dash['height']))
if comp.get('shown') or comp.get('height', 0) != 0: bad.append('bolla shown=%s height=%s' % (comp.get('shown'), comp.get('height')))
if bad: print("      WRONG: " + "; ".join(bad))
sys.exit(1 if bad else 0)
PY2
verdict "A2 fornitore che risponde ma non conosce la sessione: barra vuota, bolla nascosta" "$POLE" \
  "painted=$(field "len(d['dash']['painted'])") bolla=$(field "d['composer'].get('shown')")"
rm -f "$PROV"

echo
echo "=== A3. ISC-192: il RICORDO di un fornitore non è un fornitore ====="
# Il buco che la coppia di ISC-192 apre se la si scrive nel modo ovvio, e che
# nessun polo di sopra vedrebbe. `dash-slots` di chi ha usato un fornitore
# contiene le sue chiavi per sempre, e all'avvio `DashLayout.decode` le rimette
# nel catalogo — deve farlo, o al primo lancio della giornata la barra si
# riordinerebbe da sola. Se «scoperta» bastasse a far cedere la nativa, chi
# TOGLIE il fornitore dal file resterebbe senza `Model`, senza `Context` e
# senza `Effort`, sostituite da tre fantasmi che non disegnano niente
# (ISC-143). Qui il file nomina le tre gemelle e nessun fornitore le dice: le
# native devono esserci tutte e tre.
t4a_stop_bench; sleep 1.5
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME/t4a"
cat > "$CONFIG_HOME/t4a/config.toml" <<'TOML'
dash-slots = "left-1:blocks,failed|right-1:dir,proc,agent,model|facts-1:fact-active,fact-context,fact-effort"
TOML
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 4
send "activate"; sleep 1
send "settings open"; sleep 0.8
send "settings Dashboard rows"; sleep 0.8
dump
NATIVE="$(field "sorted(n for n in d['settings']['switches'] if n in ('Model','Context','Effort'))")"
GHOSTS="$(field "sorted(e['key'] for e in d['dash']['catalog'] if e['discovered'])")"
echo "      il file nomina: $GHOSTS"
echo "      nell'elenco   : $NATIVE"
POLE=0
[ "$NATIVE" = "['Context', 'Effort', 'Model']" ] || POLE=1
# E il polo non misura niente se il file non ha davvero rimesso le gemelle nel
# catalogo: senza questa riga, un'app che ignorasse `dash-slots` passerebbe.
[ "$(field "len([e for e in d['dash']['catalog'] if e['discovered']])")" = "3" ] || POLE=1
verdict "A3 senza fornitore vivo le tre native restano" "$POLE" \
  "native=$NATIVE fantasmi=$GHOSTS"
send "settings close"; sleep 0.5

t4a_stop_bench
rm -f "$FIFO"
[ "$STATUS" = "0" ] && echo "rows: ogni polo ha tenuto" || echo "rows: un polo È FALLITO"
exit "$STATUS"
