#!/bin/bash
# ISC-226/227/228/229 — the footerless `/model` confirmation, the chat-page
# reveal rule, refusal at the composer boundary, and claude's own waiting line.
#
# Usage: Scripts/bench-switch.sh [--head <bundle>]
#
# This bench requires a real `claude`: the second «Switch model?» question is
# produced only with real history and model cache. The current bundle is held
# to the claims; an optional HEAD bundle is held to the named negative poles.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh

# The lock is acquired by bench-stop.sh when sourced. One bench per machine is
# the rule: two GUI benches otherwise kill each other's measured processes.
rilascia_lock() { t4a_bench_unlock; }

WORK=/tmp/t4a-switch-bench
CFG="$WORK/config"
FIFO="$WORK/channel.fifo"
DUMPS="$WORK/dumps"
CHAT_DIR="$HOME/Movies/t4a-bench-chat"
PROJECT_TRANSCRIPTS="$HOME/.claude/projects/-Users-christian-Movies-t4a-bench-chat"
APP="${T4A_APP:-dist/T4A.app}"
HEAD=""
STATUS=0
LAST_DUMP=""
TRANSCRIPT=""

usage() { echo "usage: Scripts/bench-switch.sh [--head <bundle>]" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --head) [ $# -ge 2 ] || { usage; exit 2; }; HEAD="$2"; shift ;;
    *) usage; exit 2 ;;
  esac
  shift
done

abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
APP="$(abs "$APP")"
[ -z "$HEAD" ] || HEAD="$(abs "$HEAD")"

send() {
  /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1" || {
    echo "invio rifiutato: $1" >&2
    STATUS=1
    return 1
  }
}
dump() {
  local n="$1" p="$DUMPS/$1.json"
  rm -f "$p"
  send "dump $p" || return 1
  for _ in $(seq 1 40); do
    [ -s "$p" ] && return 0
    sleep .25
  done
  echo "dump $n mai arrivato" >&2
  STATUS=1
  return 1
}
campo() {
  /usr/bin/python3 - "$DUMPS/$1.json" "$2" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1]));p=[q for t in d["tabs"] for q in t["panes"] if q.get("active")][0]
 s=p.get("screen")or[];x="\n".join(s)if isinstance(s,list)else str(s)
 print(eval(sys.argv[2],{"d":d,"p":p,"x":x}))
except Exception as e:print("missing:%s"%type(e).__name__)
PY
}
check() {
  local n="$1" g="$2" w="$3" m=ok
  [ "$g" = "$w" ] || { m=FAILED; STATUS=1; }
  printf '%-62s %-22s (want %s) %s\n' "$n" "$g" "$w" "$m"
}
check_head() {
  local n="$1" g="$2" w="$3" m=ok
  [ "$g" != "$w" ] || { m="FAILED (verde su HEAD)"; STATUS=1; }
  printf '%-62s %-22s (HEAD: want ≠ %s) %s\n' "$n" "$g" "$w" "$m"
}
note() { printf '%-62s %s\n' "$1" "$2"; }

# Only instances carrying this bench's FIFO belong to this bench.
mio_pid() {
  local pid
  for pid in $(pgrep -f 'T4A.app/Contents/MacOS/T4A' 2>/dev/null); do
    if ps eww "$pid" 2>/dev/null | tr ' ' '\n' | grep -qx "T4A_TEST_CHANNEL=$FIFO"; then
      echo "$pid"
      return 0
    fi
  done
  return 1
}
ferma_mie() {
  local pid
  for pid in $(pgrep -f 'T4A.app/Contents/MacOS/T4A' 2>/dev/null); do
    if ps eww "$pid" 2>/dev/null | tr ' ' '\n' | grep -qx "T4A_TEST_CHANNEL=$FIFO"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

avvia() {
  local bundle="$1"
  [ -x "$bundle/Contents/MacOS/T4A" ] || {
    echo "bundle non eseguibile: $bundle"
    STATUS=1
    return 1
  }
  ferma_mie
  sleep .5
  rm -rf "$CFG" "$DUMPS" "$FIFO"
  mkdir -p "$CFG" "$DUMPS" "$CHAT_DIR" || { STATUS=1; return 1; }
  open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG" || {
    STATUS=1
    return 1
  }
  for _ in $(seq 1 60); do
    [ -p "$FIFO" ] && break
    sleep .25
  done
  [ -p "$FIFO" ] || { echo "nessun canale FAILED"; STATUS=1; return 1; }
  sleep 1
  send activate
  note "processo del bundle" "$(mio_pid || echo missing)"
}

ready_real() {
  local ok=0
  for _ in $(seq 1 45); do
    dump rr || true
    if /usr/bin/python3 - "$DUMPS/rr.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));p=[q for t in d["tabs"] for q in t["panes"] if q.get("active")][0]
s=p.get("screen")or[];x="\n".join(s)if isinstance(s,list)else str(s)
sys.exit(0 if "? for shortcuts" in x or "auto mode on" in x else 1)
PY
    then ok=1; break; fi
    sleep 2
  done
  [ "$ok" = 1 ] || { echo "claude non pronto FAILED"; STATUS=1; return 1; }
  sleep 3
  send scan
  for _ in $(seq 1 20); do
    dump rc
    [ "$(campo rc "d['composer']['suggestions']['state']")" = ready ] && return 0
    sleep .5
  done
  echo "catalogo slash non pronto FAILED"
  STATUS=1
  return 1
}

attendi_attivita() {
  local wanted="$1" prefix="$2" rounds="$3" delay="$4" i
  LAST_DUMP=""
  for i in $(seq 1 "$rounds"); do
    send scan
    dump "$prefix-$i" || continue
    LAST_DUMP="$prefix-$i"
    [ "$(campo "$LAST_DUMP" "p['activity']")" = "$wanted" ] && return 0
    sleep "$delay"
  done
  echo "$prefix: activity $wanted mai arrivata FAILED"
  STATUS=1
  return 1
}

attendi_schermo() {
  local needle="$1" prefix="$2" rounds="$3" i
  LAST_DUMP=""
  for i in $(seq 1 "$rounds"); do
    sleep .25
    send scan
    dump "$prefix-$i" || continue
    LAST_DUMP="$prefix-$i"
    [ "$(campo "$LAST_DUMP" "'$needle' in x.lower()")" = True ] && return 0
  done
  echo "$prefix: [$needle] mai apparso FAILED"
  STATUS=1
  return 1
}

attendi_turno_nuovo() {
  local prima="$1" prefix="$2" i
  LAST_DUMP=""
  for i in $(seq 1 40); do
    send scan
    dump "$prefix-$i" || continue
    LAST_DUMP="$prefix-$i"
    [ "$(campo "$LAST_DUMP" "d['chatPage']['turns']>$prima")" = True ] && return 0
    sleep .25
  done
  echo "$prefix: il nuovo turno non è arrivato alla pagina FAILED"
  STATUS=1
  return 1
}

attendi_waiting_line() {
  local prefix="$1" i
  LAST_DUMP=""
  for i in $(seq 1 80); do
    send scan
    dump "$prefix-$i" || continue
    LAST_DUMP="$prefix-$i"
    [ "$(campo "$LAST_DUMP" "isinstance(p.get('waitingLine'),str) and bool(p['waitingLine'])")" = True ] && return 0
    sleep .25
  done
  echo "$prefix: waitingLine non arrivata entro 20s FAILED"
  STATUS=1
  return 1
}

trova_transcript() {
  /usr/bin/python3 - "$PROJECT_TRANSCRIPTS" "$1" <<'PY'
import glob,os,sys
root,start=sys.argv[1],float(sys.argv[2])
files=[p for p in glob.glob(os.path.join(root,"*.jsonl")) if os.path.getmtime(p)>=start]
print(max(files,key=os.path.getmtime) if files else "")
PY
}

conta() {
  /usr/bin/python3 - "$1" <<'PY'
import json,sys
n=0
for line in open(sys.argv[1],encoding="utf-8"):
 r=json.loads(line);c=(r.get("message")or{}).get("content")
 if r.get("type")!="user" or r.get("isMeta") is True:continue
 if isinstance(c,str) and not c.startswith(("<local-command-stdout>","<local-command-stderr>","<local-command-caveat>")):n+=1
 elif isinstance(c,list):
  k=[b.get("type") for b in c if isinstance(b,dict)]
  if "text" in k and "tool_result" not in k:n+=1
print(n)
PY
}

transizioni_mostrate() {
  /usr/bin/python3 - "$DUMPS" "$1" <<'PY'
import glob,json,os,sys
files=sorted(glob.glob(os.path.join(sys.argv[1],sys.argv[2]+"*.json")),key=os.path.getmtime)
values=[]
for path in files:
 try:values.append(bool(json.load(open(path)).get("chatPage",{}).get("showing")))
 except Exception:pass
print(sum(a!=b for a,b in zip(values,values[1:])))
PY
}

leggi_modello() {
  /usr/bin/python3 - <<'PY'
import json,os
p=os.path.expanduser("~/.claude/settings.json")
try:print(json.load(open(p)).get("model"))
except Exception:print("<missing>")
PY
}

run_switch() {
  local bundle="$1" mode="$2" tag="$3"
  local started model_before model_after first_turns flips_before flips_after delta
  local work_dump rest_dump long_dump turn_id menu_dump confirm_dump before after responder
  started="$(date +%s)"
  model_before="$(leggi_modello)"
  echo "=== $tag · ISC-226/227/228/229 ====================================="
  avvia "$bundle" || { echo "$tag SKIPPED: bundle non avviato"; return; }
  send "text cd $CHAT_DIR && claude"
  send activate
  send "key return"
  ready_real || { echo "$tag SKIPPED: claude non pronto"; ferma_mie; return; }

  # ISC-227 is measured with the pure-chat cover experiment explicitly OFF:
  # the page's reveal rule must stand without help from that experiment.
  send "composer-mode always"
  send "chat-page on"
  send "pure-chat off"
  send scan

  send "compose prova"
  attendi_attivita working "$tag-227-working" 40 .25 || { ferma_mie; return; }
  work_dump="$LAST_DUMP"
  flips_before="$(campo "$work_dump" "d.get('chatPage',{}).get('pageFlips','absent')")"
  if [ "$mode" = current ]; then
    note "227c pageFlips all'inizio" "$flips_before"
  else
    note "H-227c pageFlips" "$flips_before"
  fi
  attendi_attivita waiting "$tag-227-wait" 360 .25 || { ferma_mie; return; }
  rest_dump="$LAST_DUMP"
  dump "$tag-227c"
  if [ "$mode" = current ]; then
    flips_after="$(campo "$tag-227c" "d['chatPage']['pageFlips']")"
    delta="$(campo "$tag-227c" "d['chatPage']['pageFlips']-$flips_before")"
    note "227c pageFlips dopo − prima" "$flips_after − $flips_before = $delta"
    check "227c non più di due cambi di pagina" \
      "$(campo "$tag-227c" "d['chatPage']['pageFlips']-$flips_before<=2")" True
    check "227b a riposo la riga d'ingresso è vista" \
      "$(campo "$tag-227c" "d['chatPage']['inputBoxSeen']")" True
    check "227b a riposo la pagina è mostrata" \
      "$(campo "$tag-227c" "d['chatPage']['showing']")" True
  else
    note "H-227c transizioni di showing (campione, non conteggio)" \
      "$(transizioni_mostrate "$tag-227-")"
    note "H-227b inputBoxSeen/showing" \
      "$(campo "$tag-227c" "d['chatPage'].get('inputBoxSeen','absent')")/$(campo "$tag-227c" "d['chatPage']['showing']")"
  fi

  TRANSCRIPT="$(trova_transcript "$started")"
  note "$tag transcript reale" "${TRANSCRIPT:-missing}"
  if [ -z "$TRANSCRIPT" ]; then
    echo "$tag: transcript nuovo non trovato FAILED"
    STATUS=1
    ferma_mie
    return
  fi
  first_turns="$(campo "$tag-227c" "d['chatPage']['turns']")"

  send "compose Scrivi i numeri da 1 a 300, uno per riga, senza usare strumenti e senza spiegazioni."
  attendi_attivita working "$tag-229-working" 40 .25 || { ferma_mie; return; }
  attendi_turno_nuovo "$first_turns" "$tag-229-turn" || { ferma_mie; return; }
  long_dump="$LAST_DUMP"
  if [ "$mode" = current ]; then
    attendi_waiting_line "$tag-229-line" || { ferma_mie; return; }
    long_dump="$LAST_DUMP"
  fi
  turn_id="$(campo "$long_dump" "d['chatPage']['turns']")"
  send "chat-page off"
  send "turn-open $turn_id"
  sleep .4
  dump "$tag-229a"
  if [ "$mode" = current ]; then
    check "229a il lettore contiene waitingLine dello stesso dump" \
      "$(campo "$tag-229a" "isinstance(p.get('waitingLine'),str) and p['waitingLine'] in d['turnReader']['text']")" True
    note "229a waitingLine verbatim" "$(campo "$tag-229a" "p.get('waitingLine')")"
    check "229c glifo reale ed ellissi" \
      "$(campo "$tag-229a" "isinstance(p.get('waitingLine'),str) and p['waitingLine'][:1] in '✻✳✶✽·✢' and '…' in p['waitingLine']")" True
  else
    check_head "H-229 il lettore contiene ancora un nostro (sta …)" \
      "$(campo "$tag-229a" "'(sta ' in d['turnReader']['text']")" False
  fi
  send turn-close
  send "chat-page on"
  # The long turn is left to FINISH, never interrupted: an Esc makes claude
  # 2.1.250 put the interrupted prompt back into its box and the transcript
  # keeps the turn open, so `activity` stays `working` for ever (measured
  # 2026-08-28, first run of this bench: 360 rounds on both bundles).
  attendi_attivita waiting "$tag-229-stop" 960 .25 || { ferma_mie; return; }

  send "compose /model"
  attendi_schermo "select model" "$tag-226-menu" 16 || { ferma_mie; return; }
  menu_dump="$LAST_DUMP"
  if [ "$mode" = current ]; then
    check "226-menu asking" "$(campo "$menu_dump" "p['asking']")" True
    check "226-menu reading.kind" "$(campo "$menu_dump" "p['reading']['kind']")" selector
  else
    note "H-226-menu asking/kind (già verdi su HEAD)" \
      "$(campo "$menu_dump" "p.get('asking')")/$(campo "$menu_dump" "p.get('reading',{}).get('kind')")"
  fi

  send "key down"
  sleep .4
  send "text s"
  attendi_schermo "switch model" "$tag-226-confirm" 16 || { ferma_mie; return; }
  confirm_dump="$LAST_DUMP"
  if [ "$mode" = current ]; then
    check "226a la conferma è una domanda" "$(campo "$confirm_dump" "p['asking']")" True
    check "226a la conferma è permission" \
      "$(campo "$confirm_dump" "p['reading']['kind']")" permission
    check "226b la card è mostrata" "$(campo "$confirm_dump" "d['card']['showing']")" True
    note "226b etichette approva / nega" \
      "$(campo "$confirm_dump" "next((o['label'] for o in d['card']['options'] if o.get('approval')), '')+' / '+next((o['label'] for o in d['card']['options'] if not o.get('approval')), '')")"
    check "226c la pagina è nascosta" "$(campo "$confirm_dump" "d['chatPage']['showing']")" False
    check "227a la riga d'ingresso non è vista" \
      "$(campo "$confirm_dump" "d['chatPage']['inputBoxSeen']")" False
  else
    check_head "H-226a reading.kind è esattamente none" \
      "$(campo "$confirm_dump" "p.get('reading',{}).get('kind')=='none'")" False
    note "H-226b card.showing" "$(campo "$confirm_dump" "d.get('card',{}).get('showing')")"
    check_head "H-226c la pagina copre la conferma" \
      "$(campo "$confirm_dump" "d.get('chatPage',{}).get('showing') is True")" False
    note "H-227a inputBoxSeen assente" "$(campo "$confirm_dump" "'inputBoxSeen' in p")"
  fi

  before="$(conta "$TRANSCRIPT")"
  send "compose x"
  sleep 1.5
  send scan
  dump "$tag-228a"
  after="$(conta "$TRANSCRIPT")"
  if [ "$mode" = current ]; then
    check "228a la conferma è ancora sullo schermo" \
      "$(campo "$tag-228a" "'switch model' in x.lower()")" True
    check "228a il testo resta nella bolla" "$(campo "$tag-228a" "d['composer']['text']")" x
    check "228a il rifiuto è visibile nel modello" \
      "$(campo "$tag-228a" "bool(d['composer']['refusal'])")" True
    note "228a testo del rifiuto" "$(campo "$tag-228a" "d['composer']['refusal']")"
    check "228a nessuna falsa ricevuta di coda" \
      "$(campo "$tag-228a" "d['queued']['visible']")" False
    check "228a nessun nuovo turno nel transcript" "$after" "$before"
    responder="$(campo "$tag-228a" "d['composer']['firstResponder']")"
    check "228k la tastiera è sulla superficie terminale" "$responder" TappedTerminalView
  else
    check_head "H-228a il testo ha lasciato la bolla" \
      "$(campo "$tag-228a" "d.get('composer',{}).get('text','missing')==''")" False
    note "H-228a switch model ancora a schermo" \
      "$(campo "$tag-228a" "'switch model' in x.lower()")"
    note "H-228a delta transcript" "$after − $before"
  fi

  if [ "$mode" = current ]; then
    send activate
    send "text 2"
    sleep 1
    send scan
    dump "$tag-228b-menu"
    # «No, go back» goes BACK to the `/model` menu, which is a question too
    # (measured 2026-08-28, second run: the refusal rightly stayed up on the
    # menu). Esc closes the menu; only then is the input line back.
    note "228b dopo «2» il menu /model è tornato" \
      "$(campo "$tag-228b-menu" "'select model' in x.lower()")"
    send activate
    send "key escape"
    sleep 1
    send scan
    dump "$tag-228b-clear"
    check "228b la conferma è uscita dallo schermo" \
      "$(campo "$tag-228b-clear" "'switch model' in x.lower()")" False
    check "228b il rifiuto si è cancellato" \
      "$(campo "$tag-228b-clear" "d['composer']['refusal']")" ""
    check "228b la riga d'ingresso è tornata" \
      "$(campo "$tag-228b-clear" "d['chatPage']['inputBoxSeen']")" True
    send "compose x"
    sleep 1.5
    dump "$tag-228b-send"
    after="$(conta "$TRANSCRIPT")"
    check "228b il testo è partito dalla bolla" \
      "$(campo "$tag-228b-send" "d['composer']['text']")" ""
    check "228b un solo nuovo turno nel transcript" "$after" "$((before+1))"
    attendi_attivita waiting "$tag-228b-wait" 360 .25 || { ferma_mie; return; }
  else
    note "H-228b SKIPPED" "la conferma è già stata risposta dal passo 228a"
    attendi_attivita waiting "$tag-228-head-wait" 360 .25 || { ferma_mie; return; }
  fi

  send "compose /exit"
  sleep 3
  ferma_mie
  model_after="$(leggi_modello)"
  if [ "$mode" = current ]; then
    note "settings model prima / dopo" "$model_before / $model_after"
    check "settings il modello salvato non cambia" "$model_after" "$model_before"
  else
    note "H-settings model prima / dopo" "$model_before / $model_after"
  fi
}

t4a_note_his_app
trap 'ferma_mie; rilascia_lock' EXIT
run_switch "$APP" current app
[ -z "$HEAD" ] || run_switch "$HEAD" head head

# The pattern is split in this file so the static pole does not count its own
# command. At runtime grep receives the exact forbidden word.
STATIC_COUNT="$(grep -rn "rimugi""nando" Sources Scripts | wc -l | tr -d ' ')"
check "229b nessun verbo locale proibito" "$STATIC_COUNT" 0

ferma_mie
[ "$STATUS" = 0 ] && echo "switch: i poli tengono" || echo "switch: un polo FALLITO"
exit "$STATUS"
