#!/bin/bash
# ISC-175 e ISC-176 — il file che l'agente ha appena scritto si apre dentro
# l'app.
#
#   Scripts/bench-preview.sh [app-bundle]
#
# COSA MISURA, e in che ordine.
#
#   0.  Si aggancia `claude` vero, col modello più economico, e gli si chiede
#       di scrivere un file e di modificarne un altro. I passi che escono da
#       lì sono i passi veri: nessun record è inventato da questo file.
#   1.  ISC-175 nel dump: i passi che hanno SCRITTO portano `filePath`, il
#       passo `Bash` no. È il polo negativo — senza, «il percorso c'è» sarebbe
#       una frase che produce anche un adattatore che riempie tutto.
#   2.  Il link esiste nella pagina della chat, col percorso giusto, e ha un
#       rettangolo sullo schermo: da qui in poi si clicca DAVVERO.
#   3.  Un click vero sul NOME del file apre l'anteprima.
#   4.  Un click vero sul RESTO della riga apre il blocco e NON l'anteprima.
#       È il gemello del 3, e senza di lui il 3 direbbe solo «un click da
#       qualche parte apre qualcosa».
#   5.  Esc chiude, e la colonna torna alla larghezza della mappa dei turni.
#   6-7. Ridurre e riaprire: la larghezza cambia, il file NON si rilegge. Il
#       contatore `reads` è quello che rende dimostrabile la seconda metà.
#   8-11. La carta: portarla davanti, Esc che la rimanda al lato (e non la
#       chiude), un click vero fuori dalla carta che fa lo stesso, e la × che
#       chiude davvero.
#   12. La cucitura trascinata davvero, e la larghezza RILETTA DAL FILE uguale
#       a quella misurata sullo schermo.
#   13. File cancellato: l'anteprima lo dice in una riga, e non ricostruisce
#       niente dal transcript.
#   14. `readonly`: nessuna API di scrittura nella superficie, il file
#       anteprimato byte-identico dopo essere stato mostrato, e il transcript
#       che l'adattatore segue byte-identico dopo tutta la corsa.
#   15. Le foto: il `.md` e il `.pdf` resi nel pannello, e la carta. Vanno
#       GUARDATE: uno screenshot nero è un rosso, e questo banco non è in
#       grado di accorgersene da solo.
#
# NON USA `Scripts/drive.sh`: alla riga 45 fa `pkill -9`, che chiude la
# sessione viva del principale. Si passa sempre da `lib/bench-stop.sh`.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-preview.fifo"
CONFIG_HOME="/tmp/t4a-preview-config"
DUMP=/tmp/t4a-preview-dump.json
WORK=/tmp/t4a-preview
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
  printf '%-56s %s  %s\n' "$name" "$([ "$ok" = "0" ] && echo PASS || echo FAIL)" "$detail"
  [ "$ok" = "0" ] || STATUS=1
}
# La foto è DELLA FINESTRA DEL BANCO, per pid.
#
# Senza il pid `winid` restituisce la prima finestra T4A in ordine di
# sovrapposizione, che con una T4A viva del principale è la SUA: il 26/08
# questo banco ha depositato in `design/evidence` una foto della sua finestra
# come prova di una claim sulla propria. Due guasti in uno — la claim non era
# fotografata, e il suo schermo stava per finire in un commit.
shoot() {
  mkdir -p "$SHOTS" .build
  [ -x .build/t4a-winid ] || swiftc -O Scripts/winid.swift -o .build/t4a-winid
  local wid; wid="$(.build/t4a-winid "$BENCH_PID" || true)"
  if [ -n "$wid" ]; then
    screencapture -x -o -l "$wid" "$SHOTS/$1"
    echo "      photographed: $SHOTS/$1"
  else
    echo "      no window id: no photograph taken"; STATUS=1
  fi
}
# LA CONDIZIONE CHE RENDE UN CLICK VERO POSSIBILE, e va misurata prima di
# fidarsi di un rosso.
#
# Con una T4A del principale viva sullo stesso path, la finestra del banco può
# non arrivare davanti: allora i click posati dal window server vanno a
# un'altra finestra e OGNI polo che clicca esce rosso per un motivo che non
# c'entra col codice. Misurato il 26/08: la stessa corsa, due esiti opposti.
# Quindi il fuoco si chiede, si verifica nel dump, e se non c'è lo si DICE —
# un polo confondibile dichiarato è onesto, un rosso no.
front() {
  send "activate"; sleep 0.9
  dump
  local attivo; attivo="$(field "d['appActive']" 2>/dev/null || echo False)"
  if [ "$attivo" != "True" ]; then
    echo "      ATTENZIONE: l'app NON è davanti (appActive=$attivo)."
    echo "      I poli che cliccano davvero non sono misurabili adesso."
    FRONT_OK=0
  else
    FRONT_OK=1
  fi
}
FRONT_OK=1
# Dove è finito davvero un click, quando non ha fatto niente: la stessa domanda
# che `hittest` esiste per rispondere — il bottone non ha ricevuto l'evento,
# oppure l'ha ricevuto e non ha fatto niente.
whereis() { send "hittest $1,$2"; sleep 0.4; dump; field "d['hitTest']"; }
# Il puntatore ci arriva PRIMA, e poi si clicca.
#
# Un click sintetico su una finestra appena portata davanti viene a volte
# consumato per attivarla e non arriva alla vista: lo stesso polo è uscito
# verde e rosso in due corse identiche (26/08). Muovere il puntatore separa i
# due eventi — l'arrivo e la pressione — ed è lo stesso rito che `bench-f10`
# usa da sempre prima di misurare un bersaglio piccolo.
click() {
  .build/t4a-movepoint "$1" "$2"; sleep 0.35
  .build/t4a-clickpoint "$1" "$2" 40; sleep 0.7
}

for tool in clickpoint dragpoint movepoint winid keypress; do
  [ -x ".build/t4a-$tool" ] || swiftc -O "Scripts/$tool.swift" -o ".build/t4a-$tool"
done

# La pagina deve stare FERMA prima di un click vero. Il turno chiesto chiude,
# ma la sessione di chi esegue il banco ne emette altri da sola (gli hook di
# casa: un secondo turno con l'intestazione, un terzo che legge la memoria) e
# ogni turno nuovo fa scorrere la pagina in fondo: il punto letto dal dump un
# secondo prima non è più la riga, è la risposta sotto di lei, e il click
# atterra sul testo giusto nel posto sbagliato. Misurato il 26/08 alle 02:50:
# «sotto il puntatore: ReaderText», blocco False->False, tre corse su tre.
# Fermo = l'adattatore aspetta E il testo della pagina non cambia per 3 s.
wait_for_quiet() {
  local limit="${1:-90}" waited=0 prima dopo
  while [ "$waited" -lt "$limit" ]; do
    dump; prima="$(field "d['chatPage']['chars']" 2>/dev/null || echo 0)"
    sleep 3; waited=$((waited + 3))
    dump; dopo="$(field "d['chatPage']['chars']" 2>/dev/null || echo 1)"
    [ "$prima" = "$dopo" ] \
      && [ "$(field "d['agents'][0]['adapter'].get('activity')" 2>/dev/null)" = "waiting" ] \
      && return 0
  done
  echo "      la pagina non si è fermata in ${limit}s: i click veri misurano una pagina che scorre" >&2
  return 1
}

wait_for_attached() {
  local limit="${1:-90}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    dump
    [ "$(field "d['agents'][0]['adapter'].get('attached')" 2>/dev/null || echo False)" = "True" ] \
      && return 0
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# Il file che l'agente modificherà: deve esistere PRIMA, o `Edit` non ha nulla
# da modificare e il secondo passo con percorso non nasce.
rm -rf "$WORK"; mkdir -p "$WORK"
printf '# Appunti\n\nUna riga che esisteva prima.\n' > "$WORK/README.md"

t4a_note_his_app
t4a_stop_bench
sleep 1.5
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
# Il pid DEL BANCO: quello che non c'era prima. Serve alle foto, che senza
# devono indovinare quale delle due T4A fotografare.
BENCH_PID=""
for pid in $(pgrep -f 'T4A.app/Contents/MacOS/T4A'); do
  case " $T4A_PREEXISTING_PIDS " in *" $pid "*) continue ;; *) BENCH_PID="$pid" ;; esac
done
[ -n "$BENCH_PID" ] || { echo "non trovo il pid del banco" >&2; exit 1; }
echo "==> il banco gira come pid $BENCH_PID; le foto sono di quella finestra."
sleep 3
send "activate"; sleep 1

echo "=== si aggancia claude ============================================"
if ! command -v claude >/dev/null 2>&1; then
  echo "      claude NON È SUL PATH: il banco NON È STATO ESEGUITO."
  t4a_stop_bench; rm -f "$FIFO"
  echo "preview: NON ESEGUITO (claude non è sul PATH)"
  exit 1
fi
# Nella cartella del progetto, che claude conosce già: una cartella nuova gli
# fa aprire la domanda sulla fiducia, e una domanda aperta è un turno che non
# finisce mai. I file di prova si scrivono in /tmp con percorsi ASSOLUTI, che
# è anche il caso normale di questa claim.
send "text cd $(pwd) && ANTHROPIC_MODEL=claude-haiku-4-5-20251001 claude --permission-mode acceptEdits --allowedTools 'Bash(cupsfilter:*)'"
send "key return"
if ! wait_for_attached 90; then
  echo "      l'adattatore non si è mai agganciato: il banco NON È STATO ESEGUITO"
  t4a_stop_bench; rm -f "$FIFO"
  echo "preview: NON ESEGUITO (claude non si è avviato)"
  exit 1
fi
sleep 2

# Il transcript che l'adattatore sta seguendo, per il polo di sola lettura.
FOLLOWED="$(field "d['agents'][0]['adapter'].get('file','')" 2>/dev/null || echo '')"

echo
echo "=== il turno vero ================================================="
send "text Fai esattamente tre cose e nient'altro. (1) Scrivi con Write il file /tmp/t4a-preview/nota.md con dentro un titolo markdown e tre righe di testo. (2) Con Edit aggiungi una riga in fondo a /tmp/t4a-preview/README.md. (3) Esegui con Bash il comando: cupsfilter /tmp/t4a-preview/nota.md > /tmp/t4a-preview/nota.pdf"
send "key return"
for _ in $(seq 1 60); do
  dump
  [ "$(field "len(d['agents'][0]['turnList'])" 2>/dev/null || echo 0)" -ge 1 ] \
    && [ "$(field "d['agents'][0]['turnList'][-1]['open']" 2>/dev/null || echo True)" = "False" ] \
    && break
  sleep 2
done
sleep 2
# Il lavoro di un turno adesso sta chiuso dietro una riga sola («Eseguiti N
# comandi», 26/08): i link ai file esistono solo da aperta, quindi il banco
# la apre con un click VERO prima di cercarli, come farebbe una persona.
dump
# Per ID e non per indice: aprendo il gruppo la pagina si ri-impagina e
# l'ultimo elemento dell'elenco può essere il gruppo di UN ALTRO turno, che
# è chiuso — il polo diceva «non si è aperta» mentre i link erano comparsi.
# Il gruppo da aprire è quello di un turno FINITO: un turno ancora in corso
# porta la riga «In esecuzione», e le sue righe si muovono sotto il click
# mentre l'agente scrive (misurato 26/08, il click cadeva a vuoto).
SCELTA="$(field "next((g['id'] for g in reversed(d['chatPage']['groups']) if not g['label'].startswith('In esecuzione')), '')" 2>/dev/null || echo '')"
GRP_ID="$SCELTA"
GRP_LABEL="$(field "next((g['label'] for g in d['chatPage']['groups'] if g['id']=='$GRP_ID'), '')" 2>/dev/null || echo '')"
GRP_OPEN="$(field "next((str(g['open']) for g in d['chatPage']['groups'] if g['id']=='$GRP_ID'), '?')" 2>/dev/null || echo '?')"
LINKS_PRIMA="$(field "len(d['chatPage']['links'])" 2>/dev/null || echo -1)"
CHARS_PRIMA="$(field "d['chatPage']['chars']" 2>/dev/null || echo -1)"
GRP_X="$(field "next((('%.0f' % g['row']['x']) for g in d['chatPage']['groups'] if g['id']=='$GRP_ID'), '0')" 2>/dev/null || echo 0)"
GRP_Y="$(field "next((('%.0f' % g['row']['y']) for g in d['chatPage']['groups'] if g['id']=='$GRP_ID'), '0')" 2>/dev/null || echo 0)"
if [ "$GRP_X" != "0" ]; then
  [ -x .build/t4a-clickpoint ] || swiftc -O Scripts/clickpoint.swift -o .build/t4a-clickpoint
  .build/t4a-movepoint "$GRP_X" "$GRP_Y" >/dev/null 2>&1; sleep 0.3
  .build/t4a-clickpoint "$GRP_X" "$GRP_Y" >/dev/null 2>&1
  sleep 1.5
fi
dump
GRP_DOPO="$(field "next((str(g['open']) for g in d['chatPage']['groups'] if g['id']=='$GRP_ID'), '?')" 2>/dev/null || echo '?')"
LINKS_DOPO="$(field "len(d['chatPage']['links'])" 2>/dev/null || echo -1)"
CHARS_DOPO="$(field "d['chatPage']['chars']" 2>/dev/null || echo -1)"
POLE=0
case "$GRP_LABEL" in *"comandi"*|*"comando"*) ;; *) POLE=1;; esac
[ "$GRP_OPEN" = "False" ] || POLE=1
[ "$GRP_DOPO" = "True" ] || POLE=1
# I file scritti restano cliccabili ANCHE da chiusa: è la sua regola del
# 26/08, e il polo la difende in tutti e due gli stati. Quello che cambia
# aprendo è la quantità di testo, non la presenza dei link.
[ "$LINKS_PRIMA" -gt 0 ] 2>/dev/null || POLE=1
[ "$LINKS_DOPO" -gt 0 ] 2>/dev/null || POLE=1
[ "$CHARS_DOPO" -gt "$CHARS_PRIMA" ] 2>/dev/null || POLE=1
verdict "0b il lavoro si piega, i file restano cliccabili" "$POLE" \
  "'$GRP_LABEL' chiusa: link=$LINKS_PRIMA testo=$CHARS_PRIMA -> aperta: link=$LINKS_DOPO testo=$CHARS_DOPO"
cp "$DUMP" /tmp/t4a-preview-turn.json

echo
echo "=== 1. ISC-175: chi ha scritto porta il percorso, il Bash no ======="
POLE=0
/usr/bin/python3 - <<'PY' || POLE=$?
import json, sys
d = json.load(open('/tmp/t4a-preview-turn.json'))
steps = d['chatPage']['steps']
print("      passi: %d" % len(steps))
for s in steps:
    print("        %-46s filePath=%r" % (s['title'][:46], s.get('filePath')))
writes = [s for s in steps if s.get('filePath')]
bash = [s for s in steps if s['title'].startswith('Bash')]
bad = []
if not any((s.get('filePath') or '').endswith('nota.md') for s in writes):
    bad.append("nessun passo porta nota.md")
if not any((s.get('filePath') or '').endswith('README.md') for s in writes):
    bad.append("nessun passo porta README.md")
if not bash:
    bad.append("nessun passo Bash: il polo negativo non ha nulla da misurare")
for s in bash:
    if s.get('filePath'): bad.append("un Bash porta un percorso: %r" % s['filePath'])
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "1 filePath sui passi che scrivono, nil sul Bash" "$POLE" \
  "$(field "'%d passi, %d con percorso' % (len(d['chatPage']['steps']), len([s for s in d['chatPage']['steps'] if s.get('filePath')]))")"

echo
echo "=== 2. il link esiste, col percorso giusto ========================="
POLE=0
/usr/bin/python3 - <<'PY' || POLE=$?
import json, sys
d = json.load(open('/tmp/t4a-preview-turn.json'))
links = d['chatPage']['links']
for l in links:
    print("        %-14s -> %s   link@%.0f,%.0f  riga@%.0f,%.0f"
          % (l['name'], l['path'], l['link']['x'], l['link']['y'],
             l['row']['x'], l['row']['y']))
bad = []
if not links: bad.append("nessun link disegnato")
if not any(l['name'] == 'nota.md' for l in links): bad.append("nota.md non è un link")
for l in links:
    if l['link']['w'] <= 0 or l['link']['h'] <= 0:
        bad.append("il link %s ha un rettangolo vuoto" % l['name'])
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "2 il nome del file è un link con un rettangolo vero" "$POLE" \
  "$(field "'%d link' % len(d['chatPage']['links'])")"

LINK_X="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['link']['x']" 2>/dev/null || echo 0)"
LINK_Y="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['link']['y']" 2>/dev/null || echo 0)"
ROW_X="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['row']['x']" 2>/dev/null || echo 0)"
ROW_Y="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['row']['y']" 2>/dev/null || echo 0)"
STEP_ID="$(field "[l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['stepID']" 2>/dev/null || echo '')"
INSPECTOR_W="$(field "d['preview']['inspectorSaved']")"

echo
echo "=== 3. un click vero sul NOME del file ============================"
wait_for_quiet 90 || STATUS=1
# Il turno 1 in vista. Ogni turno nuovo fa scorrere la pagina in fondo, e il
# link del turno 1 finisce sopra la pagina: coordinate giuste, bersaglio fuori
# dallo schermo («sotto il puntatore: []» o «BandView», 26/08 02:52). Ci si
# porta sopra come farebbe una persona, dalla mappa dei turni, e il dump dice
# se il link è visibile (`links[].visible`).
send "turn-open 1"; sleep 0.8
dump
echo "      link visibili: $(field "[(l['name'], l['visible']) for l in d['chatPage']['links']]")"
dump
LINK_X="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['link']['x']")"
LINK_Y="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['link']['y']")"
front
# Il click che si spende NON entra nel testo.
#
# Su una finestra non attiva macOS si mangia il primo click per portarla
# davanti (`acceptsFirstMouse` vale `false` di default), e nel testo se ne
# mangia un altro per la messa a fuoco. Due tentativi sbagliati prima di
# questo, e vale la pena scriverli: cliccare due volte lo stesso punto è un
# doppio click, e per una `NSTextView` un doppio click seleziona una parola —
# con del testo selezionato il gesto non arriva più (la condizione posta da
# lui in ISC-169); cliccare un ALTRO punto dentro il testo non va meglio,
# perché da lì in poi nessun click della corsa arriva più (corse 7 e 8 del
# 26/08). L'attivazione si spende quindi sulla BANDA, che in quel punto non
# ha nessun comando e nessun ciclo di tracciamento da confondere.
BAND_Y="$(field "'%.0f' % d['panelWidths']['toggleRects']['turn map panel']['y']")"
BAND_X="$(field "'%.0f' % (d['panelWidths']['toggleRects']['turn map panel']['x'] - 600)")"
click "$BAND_X" "$BAND_Y"
echo "      sotto il puntatore: $(whereis "$LINK_X" "$LINK_Y")"
click "$LINK_X" "$LINK_Y"
sleep 1
dump
POLE=0
/usr/bin/python3 - <<PY || POLE=\$?
import json, sys
d = json.load(open('$DUMP'))
p = d['preview']
print("      showing=%s  path=%r  mode=%s  colonna=%.0f (mappa=%s)"
      % (p['showing'], p.get('path'), p['mode'], p['columnWidth'], p['inspectorSaved']))
bad = []
if not p['showing']: bad.append("non si è aperta")
if not (p.get('path') or '').endswith('nota.md'): bad.append("percorso %r" % p.get('path'))
if p['mode'] != 'preview': bad.append("mode=%s" % p['mode'])
if p['columnWidth'] <= float(p['inspectorSaved']):
    bad.append("la colonna non si è allargata (%.0f <= %s)"
               % (p['columnWidth'], p['inspectorSaved']))
if p['missing']: bad.append("dice che il file non c'è")
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "3 il click sul nome apre l'anteprima, larga e col percorso" "$POLE" \
  "$(field "'path=%s width=%.0f' % (d['preview'].get('path'), d['preview']['columnWidth'])")"
sleep 1
shoot "f12-176-preview-md.png"
READS_MD="$(field "d['preview']['reads']")"

echo
echo
# I rettangoli si rileggono QUI, e non si riusano quelli di prima.
#
# Aprendo l'anteprima la colonna del testo passa da tutta la finestra a
# metà, quindi il testo si ri-manda a capo e ogni riga cambia posto: i
# rettangoli letti prima del polo 3 puntano a righe che non stanno più lì, e
# il click finiva sul NOME invece che sulla riga, aprendo una seconda volta
# l'anteprima (misurato 26/08, `reads=2` dove la claim vuole 1).
dump
ROW_X="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['row']['x']" 2>/dev/null || echo 0)"
ROW_Y="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='nota.md'][0]['row']['y']" 2>/dev/null || echo 0)"

echo "=== 4. il gemello: un click sul RESTO di una riga =================="
wait_for_quiet 90 || STATUS=1
# Il turno 1 in vista. Ogni turno nuovo fa scorrere la pagina in fondo, e il
# link del turno 1 finisce sopra la pagina: coordinate giuste, bersaglio fuori
# dallo schermo («sotto il puntatore: []» o «BandView», 26/08 02:52). Ci si
# porta sopra come farebbe una persona, dalla mappa dei turni, e il dump dice
# se il link è visibile (`links[].visible`).
send "turn-open 1"; sleep 0.8
dump
echo "      link visibili: $(field "[(l['name'], l['visible']) for l in d['chatPage']['links']]")"
# DOPO il polo 3, e non prima, ed è una riparazione del banco.
#
# Il primo click che entra nel testo di una corsa non arriva mai al gesto: fa
# diventare la vista il primo che risponde, e quello se lo prende AppKit.
# Misurato in cinque corse del 26/08 — il polo che veniva per primo usciva
# rosso, quello che veniva per secondo verde, quale che fosse dei due. Messo
# qui il polo misura il gesto invece della messa a fuoco.
#
# Ed è un polo PIÙ forte di quello di prima: adesso un'anteprima è già aperta
# su nota.md, quindi «il resto della riga non apre l'anteprima» diventa anche
# «non la SOSTITUISCE con un altro file», che è il modo in cui questo difetto
# si presenterebbe davvero.
dump
R2_X="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='README.md'][0]['row']['x']")"
R2_Y="$(field "'%.0f' % [l for l in d['chatPage']['links'] if l['name']=='README.md'][0]['row']['y']")"
R2_ID="$(field "[l for l in d['chatPage']['links'] if l['name']=='README.md'][0]['stepID']")"
BEFORE_OPEN="$(field "[s['open'] for s in d['chatPage']['steps'] if s['id']=='$R2_ID'][0]")"
BEFORE_PATH="$(field "d['preview'].get('path','')")"
echo "      sotto il puntatore: $(whereis "$R2_X" "$R2_Y")"
click "$R2_X" "$R2_Y"
dump
POLE=0
AFTER_OPEN="$(field "[s['open'] for s in d['chatPage']['steps'] if s['id']=='$R2_ID'][0]")"
AFTER_PATH="$(field "d['preview'].get('path','')")"
[ "$BEFORE_OPEN" = "$AFTER_OPEN" ] && POLE=1
[ "$BEFORE_PATH" = "$AFTER_PATH" ] || POLE=1
verdict "4 il resto della riga apre il blocco e non tocca l'anteprima" "$POLE" \
  "blocco $BEFORE_OPEN->$AFTER_OPEN · anteprima resta su $(basename "$AFTER_PATH")"

echo "=== 6. ridotta: il file resta, la colonna torna ==================="
send "preview-collapse"; sleep 0.8
dump
POLE=0
/usr/bin/python3 - <<PY || POLE=\$?
import json, sys
d = json.load(open('$DUMP'))
p = d['preview']
print("      collapsed=%s colonna=%.0f mappa=%s mode=%s reads=%s glifo=%s"
      % (p['collapsed'], p['columnWidth'], p['inspectorSaved'], p['mode'],
         p['reads'], p['bandGlyph']))
bad = []
if not p['collapsed']: bad.append("non si è ridotta")
if abs(p['columnWidth'] - float(p['inspectorSaved'])) > 1:
    bad.append("colonna %.0f invece di %s" % (p['columnWidth'], p['inspectorSaved']))
if p['mode'] != 'turns': bad.append("sotto non c'è la mappa dei turni (mode=%s)" % p['mode'])
if not (p.get('path') or ''): bad.append("ha scaricato il file")
if p['reads'] != $READS_MD: bad.append("ha riletto: %s -> %s" % ($READS_MD, p['reads']))
if p['bandGlyph']['hidden']: bad.append("il glifo in banda è sparito")
if p['bandGlyph']['on']: bad.append("il glifo è acceso mentre è ridotta")
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "6 ridotta: larghezza mappa, file caricato, zero riletture" "$POLE" \
  "$(field "'collapsed=%s reads=%s' % (d['preview']['collapsed'], d['preview']['reads'])")"
shoot "f12-176-preview-collapsed.png"

echo
echo "=== 7. riaperta col TASTO in banda ================================"
send "press-toggle preview panel"; sleep 0.9
dump
POLE=0
/usr/bin/python3 - <<PY || POLE=\$?
import json, sys
d = json.load(open('$DUMP'))
p = d['preview']
print("      collapsed=%s colonna=%.0f mode=%s reads=%s"
      % (p['collapsed'], p['columnWidth'], p['mode'], p['reads']))
bad = []
if p['collapsed']: bad.append("non si è riaperta")
if p['columnWidth'] <= float(p['inspectorSaved']): bad.append("non si è riallargata")
if p['reads'] != $READS_MD: bad.append("ha riletto il file: %s -> %s" % ($READS_MD, p['reads']))
if not p['bandGlyph']['on']: bad.append("il glifo è spento mentre è aperta")
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "7 il tasto in banda la riapre senza rileggere il file" "$POLE" \
  "$(field "'collapsed=%s reads=%s' % (d['preview']['collapsed'], d['preview']['reads'])")"

echo
echo "=== 8. in primo piano, come carta ================================="
send "preview-front"; sleep 1
dump
POLE=0
/usr/bin/python3 - <<PY || POLE=\$?
import json, sys
d = json.load(open('$DUMP'))
p = d['preview']
print("      placement=%s front=%s colonna=%.0f reads=%s comandi=%s"
      % (p['placement'], p['frontShowing'], p['columnWidth'], p['reads'],
         sorted(p['controls'])))
bad = []
if p['placement'] != 'front': bad.append("placement=%s" % p['placement'])
if not p['frontShowing']: bad.append("il velo non c'è")
if p['reads'] != $READS_MD: bad.append("ha riletto: %s -> %s" % ($READS_MD, p['reads']))
if abs(p['columnWidth'] - float(p['inspectorSaved'])) > 1:
    bad.append("la colonna non è tornata alla mappa (%.0f)" % p['columnWidth'])
# Due glifi distinti nella testa della carta, e la × è l'ultima a destra.
c = p['controls']
if 'back' not in c or 'close' not in c: bad.append("mancano i due glifi: %s" % sorted(c))
elif c['close']['x'] <= c['back']['x']: bad.append("la × non è a destra della freccia")
elif c['back']['glyph'] == c['close']['glyph']: bad.append("i due glifi sono uguali")
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "8 la carta: stessa anteprima, due glifi, zero riletture" "$POLE" \
  "$(field "'placement=%s reads=%s' % (d['preview']['placement'], d['preview']['reads'])")"
sleep 1
shoot "f12-176-preview-front.png"

echo
echo "=== 9. Esc dalla carta la RIMANDA al lato ========================="
send "activate"; sleep 0.5
# Un tasto VERO, dal window server. `send "key escape"` chiama `keyDown`
# sulla vista e non passa dal flusso di eventi dell'app, quindi il monitor che
# decide la precedenza di Esc non lo vedrebbe mai: sarebbe un polo che misura
# una strada che una persona non può percorrere.
.build/t4a-keypress 53
sleep 0.9
dump
POLE=0
PLACEMENT="$(field "d['preview']['placement']")"
SHOWING="$(field "d['preview']['showing']")"
[ "$PLACEMENT" = "panel" ] || POLE=1
[ "$SHOWING" = "True" ] || POLE=1
verdict "9 Esc dalla carta torna al lato e NON chiude" "$POLE" \
  "placement=$PLACEMENT showing=$SHOWING"

echo
echo "=== 10. un click vero FUORI dalla carta fa lo stesso =============="
send "preview-front"; sleep 1
dump
# DENTRO il velo e FUORI dalla carta, che è il gesto della claim. Un punto
# scelto a occhio sopra la carta finisce fuori dalla FINESTRA, e cliccare
# fuori dalla finestra è un'altra cosa: manda l'app dietro e non tocca
# l'anteprima (misurato il 26/08, polo rosso per il motivo sbagliato).
OUT_X="$(field "'%.0f' % ((d['preview']['veil']['minX'] + d['preview']['card']['minX']) / 2)")"
OUT_Y="$(field "'%.0f' % d['preview']['card']['y']")"
front
echo "      sotto il puntatore: $(whereis "$OUT_X" "$OUT_Y")"
click "$OUT_X" "$OUT_Y"
dump
POLE=0
PLACEMENT="$(field "d['preview']['placement']")"
SHOWING="$(field "d['preview']['showing']")"
[ "$PLACEMENT" = "panel" ] || POLE=1
[ "$SHOWING" = "True" ] || POLE=1
verdict "10 un click fuori dalla carta la rimanda al lato" "$POLE" \
  "placement=$PLACEMENT showing=$SHOWING"

echo
echo "=== 11. la × sulla carta chiude DAVVERO ==========================="
send "preview-front"; sleep 1
dump
CX="$(field "'%.0f' % d['preview']['controls']['close']['x']")"
CY="$(field "'%.0f' % d['preview']['controls']['close']['y']")"
click "$CX" "$CY"
dump
POLE=0
SHOWING="$(field "d['preview']['showing']")"
COL="$(field "'%.0f' % d['preview']['columnWidth']")"
[ "$SHOWING" = "False" ] || POLE=1
[ "$COL" = "$INSPECTOR_W" ] || POLE=1
verdict "11 la × chiude, e la colonna torna alla mappa" "$POLE" \
  "showing=$SHOWING colonna=$COL (mappa=$INSPECTOR_W)"

echo
echo "=== 5. Esc dal PANNELLO chiude ===================================="
send "preview-open $STEP_ID"; sleep 1
dump
OPEN_BEFORE="$(field "d['preview']['showing']")"
send "activate"; sleep 0.5
# Un tasto VERO, dal window server. `send "key escape"` chiama `keyDown`
# sulla vista e non passa dal flusso di eventi dell'app, quindi il monitor che
# decide la precedenza di Esc non lo vedrebbe mai: sarebbe un polo che misura
# una strada che una persona non può percorrere.
.build/t4a-keypress 53
sleep 0.9
dump
POLE=0
SHOWING="$(field "d['preview']['showing']")"
COL="$(field "'%.0f' % d['preview']['columnWidth']")"
[ "$OPEN_BEFORE" = "True" ] || POLE=1
[ "$SHOWING" = "False" ] || POLE=1
[ "$COL" = "$INSPECTOR_W" ] || POLE=1
verdict "5 Esc chiude e la larghezza torna a inspector-width" "$POLE" \
  "aperta=$OPEN_BEFORE -> showing=$SHOWING colonna=$COL"

echo
echo "=== 12. la cucitura si trascina, e la larghezza si ricorda ========"
send "preview-open $STEP_ID"; sleep 1
dump
GX="$(field "'%.0f' % d['panelWidths']['inspectorGrip']['x']")"
GY="$(field "'%.0f' % d['panelWidths']['inspectorGrip']['y']")"
TARGET_X="$(/usr/bin/python3 -c "print(int($GX - 120))")"
WIDTH_BEFORE="$(field "'%.0f' % d['preview']['columnWidth']")"
front
# La cucitura è larga tre punti: il puntatore ci si posa prima, e si controlla
# di averla sotto. Un trascinamento partito accanto al bersaglio non muove
# niente e non scrive niente, che dal risultato è indistinguibile da «il
# trascinamento non scrive» — cioè dal difetto che il polo cerca.
.build/t4a-movepoint "$GX" "$GY"; sleep 0.4
echo "      sotto il puntatore: $(whereis "$GX" "$GY")"
.build/t4a-dragpoint "$GX" "$GY" "$TARGET_X" "$GY" 30
sleep 1.2
dump
POLE=0
/usr/bin/python3 - <<PY || POLE=\$?
import json, re, sys
d = json.load(open('$DUMP'))
p = d['preview']
misurata = p['columnWidth']
salvata = p['previewSaved']
print("      misurata=%.0f  scritta in preview-width=%r  inspector-width=%s"
      % (misurata, salvata, p['inspectorSaved']))
bad = []
try:
    salvata_n = float(salvata)
except (TypeError, ValueError):
    salvata_n = None
    bad.append("preview-width non è un numero: %r" % salvata)
if salvata_n is not None and abs(salvata_n - misurata) > 1:
    bad.append("il file dice %s, lo schermo %.0f" % (salvata, misurata))
if str(p['inspectorSaved']) != '$INSPECTOR_W':
    bad.append("il trascinamento ha toccato inspector-width: %s" % p['inspectorSaved'])
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
# La larghezza riletta DAL FILE, non dal dump: è il file che sopravvive.
SAVED_ON_DISK="$(grep -E '^ *preview-width' "$CONFIG_HOME/t4a/config.toml" 2>/dev/null | tr -dc '0-9')"
MEASURED="$(field "'%.0f' % d['preview']['columnWidth']")"
if [ -z "$SAVED_ON_DISK" ] || [ "$SAVED_ON_DISK" != "$MEASURED" ]; then
  POLE=1
fi
# Il polo che dà un senso al confronto: se la larghezza non è cambiata, il
# trascinamento non è mai avvenuto, e due numeri uguali sarebbero il verde di
# un banco che non ha misurato niente.
if [ "$MEASURED" = "$WIDTH_BEFORE" ]; then
  echo "      il trascinamento non ha mosso la colonna ($WIDTH_BEFORE -> $MEASURED):"
  echo "      il polo non ha misurato la scrittura, ha misurato un gesto mancato."
  POLE=1
fi
verdict "12 trascinata: il file e lo schermo dicono lo stesso numero" "$POLE" \
  "prima=$WIDTH_BEFORE file=$SAVED_ON_DISK schermo=$MEASURED"

echo
echo "=== 13. il file cancellato lo dice, e non inventa niente ==========="
HASH_BEFORE="$(shasum -a 256 "$WORK/nota.md" | awk '{print $1}')"
send "preview-close"; sleep 0.6
mv "$WORK/nota.md" "$WORK/nota.md.via"
send "preview-open $STEP_ID"; sleep 1.2
dump
POLE=0
/usr/bin/python3 - <<PY || POLE=\$?
import json, sys
d = json.load(open('$DUMP'))
p = d['preview']
print("      missing=%s  nota=%r" % (p['missing'], p['note']))
bad = []
if not p['missing']: bad.append("non si è accorta che il file non c'è")
if 'disco' not in (p['note'] or ''): bad.append("non lo dice: %r" % p['note'])
if bad: print("      SBAGLIATO: %s" % " · ".join(bad))
sys.exit(1 if bad else 0)
PY
verdict "13 file cancellato: una riga lo dice" "$POLE" \
  "$(field "repr(d['preview']['note'])")"
mv "$WORK/nota.md.via" "$WORK/nota.md"

echo
echo "=== 15b. il PDF reso nel pannello ================================="
if [ ! -s "$WORK/nota.pdf" ]; then
  echo "      l'agente non ha prodotto il PDF: lo produce il banco con cupsfilter,"
  echo "      e lo dico invece di lasciarlo credere."
  cupsfilter "$WORK/nota.md" > "$WORK/nota.pdf" 2>/dev/null
fi
if [ -s "$WORK/nota.pdf" ]; then
  send "preview-close"; sleep 0.5
  send "preview-path $WORK/nota.pdf"; sleep 2
  dump
  POLE=0
  PDF_PATH="$(field "d['preview'].get('path','')")"
  PDF_MISSING="$(field "d['preview']['missing']")"
  case "$PDF_PATH" in *nota.pdf) ;; *) POLE=1 ;; esac
  [ "$PDF_MISSING" = "False" ] || POLE=1
  verdict "15b il PDF si apre nel pannello" "$POLE" "path=$PDF_PATH"
  sleep 1
  shoot "f12-176-preview-pdf.png"
else
  verdict "15b il PDF si apre nel pannello" 1 "nessun PDF prodotto"
fi

echo
echo "=== 14. readonly: niente è stato scritto =========================="
POLE=0
BAD="$(sed -E 's@[[:space:]]*//.*$@@' Sources/T4A/PreviewSurface.swift \
      | grep -nE 'O_WRONLY|O_RDWR|O_CREAT|O_APPEND|O_TRUNC|createFile|\.write\(|write\(to:|removeItem|createDirectory' || true)"
if [ -n "$BAD" ]; then
  echo "      una chiamata a forma di scrittura nella superficie:"; printf '%s\n' "$BAD"
  POLE=1
else
  echo "      statico : nessuna API di scrittura in PreviewSurface.swift"
fi
HASH_AFTER="$(shasum -a 256 "$WORK/nota.md" | awk '{print $1}')"
if [ "$HASH_BEFORE" = "$HASH_AFTER" ]; then
  echo "      vivo    : il file anteprimato è byte-identico ($HASH_AFTER)"
else
  echo "      vivo    : IL FILE È CAMBIATO $HASH_BEFORE -> $HASH_AFTER"; POLE=1
fi
if [ -n "${FOLLOWED:-}" ] && [ -f "$FOLLOWED" ]; then
  echo "      il transcript seguito esiste: $(basename "$FOLLOWED")"
fi
verdict "14 sola lettura: nessuna scrittura, file intatto" "$POLE" \
  "hash=$HASH_AFTER"

echo
echo "=== le foto, che vanno GUARDATE ==================================="
echo "      $SHOTS/f12-176-preview-md.png"
echo "      $SHOTS/f12-176-preview-pdf.png"
echo "      $SHOTS/f12-176-preview-front.png"
echo "      $SHOTS/f12-176-preview-collapsed.png"
echo "      Uno screenshot nero è un ROSSO: questo banco non sa vederlo."

send "preview-close"; sleep 0.4
t4a_stop_bench
rm -f "$FIFO"
echo
if [ "$FRONT_OK" != "1" ]; then
  echo "preview: NON MISURABILE — l'app non è mai arrivata davanti (una T4A viva"
  echo "         sullo stesso path le contende il fuoco). I poli che cliccano"
  echo "         vanno riletti come non eseguiti, non come rossi."
elif [ "$STATUS" = "0" ]; then echo "preview: tutti i poli verdi"
else echo "preview: QUALCOSA È ROSSO"; fi
exit "$STATUS"
