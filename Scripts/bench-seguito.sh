#!/bin/bash
# ISC-216/217/203/204/205/206 — seguito, ricevuta dei comandi locali e i
# quattro gesti della pagina finora privi di misura.
# Uso: bench-seguito.sh [--with-claude] [--head bundle] [--sample jsonl]
#                       [216|217|203|204|205|206|all]
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

# Un banco per volta sulla macchina (regola del 28/08, dopo che due banchi di
# due figlie si sono uccisi a vicenda). Il lock lo prende `bench-stop.sh` al
# `source` qui sopra, con il file `owner` che rende stale un lock orfano.
# Questo banco ne prendeva un SECONDO sulla stessa cartella con un `mkdir` a
# vuoto: dopo il merge dei due rami del 28/08 il `mkdir` trovava la cartella
# appena creata dalla libreria e girava per sempre (misurato il 28/08 alle
# 10:08: owner = il pid del banco stesso, `sleep 2` in loop, log vuoto).
rilascia_lock() { t4a_bench_unlock; }

# Si fermano SOLO le istanze aperte da questo banco: quelle il cui ambiente
# porta il NOSTRO fifo. `t4a_stop_bench` uccide tutto ciò che è nato dopo
# l'avvio del banco, quindi anche il banco di un'altra chat partito nel
# frattempo (successo due volte il 28/08).
mio_pid() {
  local pid
  for pid in $(pgrep -f 'T4A.app/Contents/MacOS/T4A' 2>/dev/null); do
    if ps eww "$pid" 2>/dev/null | tr ' ' '\n' | grep -qx "T4A_TEST_CHANNEL=$FIFO"; then
      echo "$pid"; return 0
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

usage() { echo "usage: Scripts/bench-seguito.sh [--with-claude] [--head <bundle>] [--sample <jsonl>] [216|217|203|204|205|206|all]" >&2; }
WITH_CLAUDE=0; HEAD=""; SECTION=all; SEEN=0
SAMPLE="${HOME}/.claude/projects/-Users-christian--claude/f9a248e7-2d79-436d-8f27-bd4b9b8180e9.jsonl"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-claude) WITH_CLAUDE=1 ;;
    --head) [ $# -ge 2 ] || { usage; exit 2; }; HEAD="$2"; shift ;;
    --sample) [ $# -ge 2 ] || { usage; exit 2; }; SAMPLE="$2"; shift ;;
    216|217|203|204|205|206|all) [ "$SEEN" = 0 ] || { usage; exit 2; }; SECTION="$1"; SEEN=1 ;;
    *) usage; exit 2 ;;
  esac; shift
done

APP="${T4A_APP:-dist/T4A.app}"
WORK="/tmp/t4a-seguito-bench"
BENCHCWD="$WORK/cwd"; CLAUDE_HOME="$WORK/claude"; CFG="$WORK/config"
FIFO="$WORK/channel.fifo"; DUMPS="$WORK/dumps"; SAMPLE_COPY="$WORK/sample.jsonl"
TRANSCRIPT=""; CURRENT_BUNDLE=""; STATUS=0; EXPECTED=""; FLAT=""
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
APP="$(abs "$APP")"; [ -z "$HEAD" ] || HEAD="$(abs "$HEAD")"

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1" || { echo "invio rifiutato: $1" >&2; STATUS=1; return 1; }; }
dump() {
  local n="$1" p="$DUMPS/$1.json"; rm -f "$p"; send "dump $p" || return 1
  for _ in $(seq 1 40); do [ -s "$p" ] && return 0; sleep .25; done
  echo "dump $n mai arrivato" >&2; STATUS=1; return 1
}
campo() {
  /usr/bin/python3 - "$DUMPS/$1.json" "$2" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1])); print(eval(sys.argv[2],{"d":d}))
except Exception as e: print("missing:%s" % type(e).__name__)
PY
}
check() { local n="$1" g="$2" w="$3" m=ok; [ "$g" = "$w" ] || { m=FAILED; STATUS=1; }; printf '%-58s %-22s (want %s) %s\n' "$n" "$g" "$w" "$m"; }
check_head() { local n="$1" g="$2" w="$3" m=ok; [ "$g" != "$w" ] || { m="FAILED (verde su HEAD)"; STATUS=1; }; printf '%-58s %-22s (HEAD: want ≠ %s) %s\n' "$n" "$g" "$w" "$m"; }
note() { printf '%-58s %s\n' "$1" "$2"; }

prepara_base() {
  rm -rf "$WORK"; mkdir -p "$WORK/bin" "$BENCHCWD" "$CLAUDE_HOME/projects" "$DUMPS" .build || return 1
  FLAT="$(/usr/bin/python3 -c 'import re,sys;print(re.sub(r"[^A-Za-z0-9_]","-",sys.argv[1]))' "$BENCHCWD")"
  mkdir -p "$CLAUDE_HOME/projects/$FLAT"; TRANSCRIPT="$CLAUDE_HOME/projects/$FLAT/sample.jsonl"
  cat > "$WORK/bin/fake.c" <<'EOF'
#include <unistd.h>
int main(int argc, char **argv) { execl("/bin/sh", "claude", (char *)0); return 1; }
EOF
  /usr/bin/cc -o "$WORK/bin/claude" "$WORK/bin/fake.c" || return 1
  local s b
  for s in clickpoint movepoint keypress; do
    case "$s" in clickpoint) b=.build/t4a-click ;; movepoint) b=.build/t4a-movepoint ;; *) b=.build/t4a-keypress ;; esac
    if [ ! -x "$b" ] || [ "Scripts/$s.swift" -nt "$b" ]; then swiftc -O "Scripts/$s.swift" -o "$b" || return 1; fi
  done
}

# Campioni veri e sintetici passano dalla stessa riscrittura privata del cwd.
prepara() {
  local s="$1" d="$2"; [ -r "$s" ] || { echo "transcript non leggibile: $s"; STATUS=1; return 1; }
  /usr/bin/python3 - "$s" "$d" "$BENCHCWD" <<'PY'
import json,sys
s,d,cwd=sys.argv[1:]
with open(s,encoding="utf-8") as a,open(d,"w",encoding="utf-8") as b:
 for n,line in enumerate(a,1):
  try:r=json.loads(line)
  except Exception as e:raise SystemExit("record %d non valido: %s"%(n,e))
  r["cwd"]=cwd;b.write(json.dumps(r,ensure_ascii=False,separators=(",",":"))+"\n")
PY
  [ $? = 0 ] || { STATUS=1; return 1; }; chmod 600 "$d"
}
conta() { /usr/bin/python3 - "$1" <<'PY'
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

avvia() {
  local b="$1" home="${2:-no}"; [ -x "$b/Contents/MacOS/T4A" ] || { echo "bundle non eseguibile: $b"; STATUS=1; return 1; }
  ferma_mie; sleep .5; rm -rf "$CFG" "$DUMPS" "$FIFO"; mkdir -p "$CFG" "$DUMPS"; CURRENT_BUNDLE="$b"
  if [ "$home" = yes ]; then open -n "$b" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG" --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME" || return 1
  else open -n "$b" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG" || return 1; fi
  for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep .25; done
  [ -p "$FIFO" ] || { STATUS=1; return 1; }; sleep 1; send activate
}
lancia() {
  local b="$1" src="$2" copied=0 attached=False turns=0; avvia "$b" yes || return 1; rm -f "$TRANSCRIPT"
  send "composer-mode always"; send "chat-page on"; send "text cd $BENCHCWD && PATH=$WORK/bin:\$PATH exec claude"; send activate; send "key return"
  for i in $(seq 1 40); do
    dump "wait-$i" || true; attached="$(campo "wait-$i" "[q for t in d['tabs'] for q in t['panes'] if q['active']][0]['attached']")"; turns="$(campo "wait-$i" "d['chatPage']['turns']")"
    if [ "$attached" = True ] && [ "$copied" = 0 ]; then /usr/bin/install -m 600 "$src" "$TRANSCRIPT" || return 1; copied=1; fi
    [ "$attached" = True ] && [ "$turns" -gt 0 ] 2>/dev/null && return 0
    send scan; sleep .5
  done
  echo "aggancio/transcript mai pronti: $attached/$turns"; STATUS=1; return 1
}
front() { for _ in $(seq 1 6); do open -a "$CURRENT_BUNDLE" 2>/dev/null||true; sleep 1.5; dump front||true; [ "$(campo front "d['appActive']")" = True ]&&return 0; done; STATUS=1; return 1; }
via() { osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1; sleep 2; }
click() { send activate; sleep .2; .build/t4a-click "$1" "$2"; }
# Due mosse e non una: `cursorUpdate` scatta sull'ingresso in un'area di
# tracciamento, e un solo evento posato dal window server può cadere già
# dentro (prima corsa: tre letture `arrow` a puntatore sul link e sul testo).
move() { send activate; sleep .2; .build/t4a-movepoint "$(/usr/bin/python3 -c "print($1+6)")" "$(/usr/bin/python3 -c "print($2+6)")"; sleep .15; .build/t4a-movepoint "$1" "$2"; sleep .15; .build/t4a-movepoint "$(/usr/bin/python3 -c "print($1+1)")" "$2"; }
shot() { local p; p="$(mio_pid)"; [ -n "$p" ] || { echo "$1 SKIPPED: nessun pid"; STATUS=1; return; }; Scripts/shot.sh "$p" "$WORK/$1"||{ echo "$1 FAILED";STATUS=1;}; }

s216() {
 echo "=== ISC-216 · lo Stop hook continua il turno ========================"; prepara "$SAMPLE" "$SAMPLE_COPY"||{ echo "216a-f SKIPPED: campione non preparato";return; }; EXPECTED="$(conta "$SAMPLE_COPY")"; echo "==> turni attesi: $EXPECTED"
 if lancia "$APP" "$SAMPLE_COPY"; then
  dump app; local p="[q for t in d['tabs'] for q in t['panes'] if q['active']][0]" f
  check "216a agente agganciato" "$(campo app "$p['attached']")" True; check "216b pagina mostrata" "$(campo app "d['chatPage']['showing']")" True
  check "216c turni senza fantasmi" "$(campo app "d['chatPage']['turns']")" "$EXPECTED"; check "216d un seguito" "$(campo app "d['chatPage']['followUps']")" 1; check "216e prompt vuoti" "$(campo app "d['chatPage']['emptyPrompts']")" 0
  f="$(campo app "d['chatPage']['followUpTurns'][0] if d['chatPage']['followUpTurns'] else 'missing:no-follow-up-turn'")"
  if [[ "$f" = missing:* ]];then echo "216f $f FAILED";STATUS=1;else send "chat-page off";send "turn-open $f";sleep .5;dump reader;check "216f seguito nel lettore" "$(campo reader "'↳ after Stop hook · RulesNudgeGate' in d['turnReader']['tail']")" True;send turn-close;send "chat-page on";send "turn-open $f";sleep .5;echo "==> foto sul turno $f";shot 216-seguito-reale.png;fi
 else echo "216a-f SKIPPED: bundle o transcript non avviato";fi; ferma_mie
 if [ -n "$HEAD" ];then echo "=== HEAD · attesi 22 turni misurati ================================";if lancia "$HEAD" "$SAMPLE_COPY";then dump head;check_head "H-216c HEAD diverso dal corretto" "$(campo head "d['chatPage']['turns']")" "$EXPECTED";note "H-216e emptyPrompts" "$(campo head "d['chatPage']['emptyPrompts']")";else echo "H-216c/e SKIPPED: HEAD non avviato";fi;ferma_mie;fi
 if mk216&&prepara "$WORK/216src" "$WORK/216.jsonl";then
  if lancia "$APP" "$WORK/216.jsonl";then
   dump 216s;check "216g sintetico: un turno" "$(campo 216s "d['chatPage']['turns']")" 1;check "216h sintetico: un seguito" "$(campo 216s "d['chatPage']['followUps']")" 1
   send "chat-page off";send "turn-open 1";sleep .5;dump 216i;check "216i seguito corto nel lettore" "$(campo 216i "'↳ after Stop hook · RulesNudgeGate' in d['turnReader']['text'] and 'Seconda risposta, dopo la lettura.' in d['turnReader']['text']")" True
   send turn-close;send "chat-page on";send "turn-open 1";sleep .5;shot 216-seguito-corto.png
  else echo "216g-i SKIPPED: bundle o transcript sintetico non avviato";fi
 else echo "216g-i SKIPPED: transcript sintetico non preparato";STATUS=1;fi;ferma_mie
}

mk216(){ /usr/bin/python3 - "$WORK/216src" "$BENCHCWD" <<'PY'
import json,os,sys
p,cwd=sys.argv[1:];life=os.path.join(cwd,"docs/PROJECT_RULES.md");base={"cwd":cwd,"entrypoint":"cli","sessionId":"s216","parentUuid":"root"}
hook="Stop hook feedback:\n[$HOME/.claude/hooks/RulesNudgeGate.hook.ts]: 📖 RULES-NUDGE GATE: il file non è stato letto. Prima di chiudere, Read:\n- docs/PROJECT_RULES.md\n"
r=[{**base,"type":"user","timestamp":"2026-08-28T12:16:00Z","uuid":"u1","message":{"role":"user","content":"Leggi le regole."}},{**base,"type":"assistant","timestamp":"2026-08-28T12:16:01Z","uuid":"a1","message":{"id":"msg_A","role":"assistant","content":[{"type":"text","text":"Prima risposta."}],"stop_reason":"end_turn"}},{**base,"type":"user","timestamp":"2026-08-28T12:16:02Z","uuid":"u2","isMeta":True,"message":{"role":"user","content":hook}},{**base,"type":"assistant","timestamp":"2026-08-28T12:16:03Z","uuid":"a2","message":{"id":"msg_B","role":"assistant","content":[{"type":"tool_use","id":"read-1","name":"Read","input":{"file_path":life}}],"stop_reason":"tool_use"}},{**base,"type":"user","timestamp":"2026-08-28T12:16:04Z","uuid":"u3","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"read-1","content":"regole","is_error":False}]}},{**base,"type":"assistant","timestamp":"2026-08-28T12:16:05Z","uuid":"a3","message":{"id":"msg_C","role":"assistant","content":[{"type":"text","text":"Seconda risposta, dopo la lettura."}],"stop_reason":"end_turn"}}]
with open(p,"w") as f:
 for x in r:f.write(json.dumps(x,separators=(",",":"))+"\n")
PY
}

ready_real() {
 local ok=0
 for _ in $(seq 1 45);do dump rr||true;if /usr/bin/python3 - "$DUMPS/rr.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]));p=[q for t in d["tabs"] for q in t["panes"] if q.get("active")][0];s=p.get("screen")or[];x="\n".join(s)if isinstance(s,list)else str(s)
sys.exit(0 if "? for shortcuts" in x or "auto mode on" in x else 1)
PY
 then ok=1;break;fi;sleep 2;done
 [ "$ok" = 1 ]||{ echo "claude non pronto FAILED";STATUS=1;return 1;};sleep 3;send scan
 for _ in $(seq 1 20);do dump rc;[ "$(campo rc "d['composer']['suggestions']['state']")" = ready ]&&return 0;sleep .5;done
 echo "catalogo slash non pronto FAILED";STATUS=1;return 1
}
run217() {
 local b="$1" h="$2" dir="$HOME/Movies/t4a-bench-chat";avvia "$b" no||{ echo "217a-e SKIPPED: bundle non avviato";return; };mkdir -p "$dir";send "text cd $dir && claude";send activate;send "key return";ready_real||{ echo "217a-e SKIPPED: claude o catalogo non pronto";ferma_mie;return; }
 send "composer-mode always";send "chat-page on";send "pure-chat on";send "compose Scrivi i numeri da 1 a 1500, uno per riga, senza usare strumenti e senza spiegazioni.";sleep 6;dump 217w
 local p="[q for t in d['tabs'] for q in t['panes'] if q['active']][0]" shown=False elapsed="oltre 3.0s" md=217w waiting=0
 if [ "$h" = no ];then check "217a turno aperto" "$(campo 217w "$p['activity']")" working;else note "H-217a attività" "$(campo 217w "$p['activity']")";fi
 send "compose /model"
 for i in $(seq 1 6);do sleep .5;send scan;md="217m$i";dump "$md";shown="$(campo "$md" "'select model' in ' '.join($p['screen']).lower()")";if [ "$shown" = True ];then elapsed="$(/usr/bin/python3 -c "print('%.1fs'%($i*.5))")";break;fi;done
 if [ "$h" = no ];then check "217b menu entro 3s ($elapsed)" "$shown" True;check "217c ricevuta assente" "$(campo "$md" "d['queued']['visible']")" False;check "217d pagina nascosta" "$(campo "$md" "d['chatPage']['showing']")" False
 else note "H-217b menu (informativo, $elapsed)" "$shown";check_head "H-217c falsa ricevuta presente" "$(campo "$md" "d['queued']['visible']")" False;fi
 send activate;send "key escape";sleep 1;send scan;dump 217e
 if [ "$h" = no ];then check "217e menu chiuso" "$(campo 217e "'select model' in ' '.join($p['screen']).lower()")" False;else note "H-217e menu dopo Esc" "$(campo 217e "'select model' in ' '.join($p['screen']).lower()")";fi
 for _ in $(seq 1 90);do dump 217wait||true;[ "$(campo 217wait "$p['activity']")" = waiting ]&&{ waiting=1;break;};sleep 1;done
 [ "$waiting" = 1 ]&&echo "217 fine turno: ok"||{ echo "217 fine turno: FAILED";STATUS=1;};send "compose /exit";sleep 3;ferma_mie
}
s217(){ echo "=== ISC-217 · comando locale senza ricevuta =========================";if [ "$WITH_CLAUDE" = 0 ];then echo "217 SKIPPED: serve --with-claude e un claude reale";return;fi;command -v claude>/dev/null||{ echo "217 FAILED: claude assente";STATUS=1;return;};run217 "$APP" no;[ -z "$HEAD" ]||run217 "$HEAD" yes; }

s203(){
 echo "=== ISC-203 · tastiera dalla pagina ================================";mk204||{ echo "203a-e SKIPPED: transcript sintetico non scritto";STATUS=1;return; };prepara "$WORK/204src" "$WORK/203.jsonl"||{ echo "203a-e SKIPPED: transcript sintetico non preparato";return; }
 [ -x .build/t4a-dragpoint ]&&[ ! Scripts/dragpoint.swift -nt .build/t4a-dragpoint ]||swiftc -O Scripts/dragpoint.swift -o .build/t4a-dragpoint
 if lancia "$APP" "$WORK/203.jsonl";then dump 203s;local x y w x1 x2 bx by i
  # Un CLICK semplice sul testo restituisce la tastiera alla bolla (è la regola
  # di ISC-203, `onPlainClick`): la pagina tiene la tastiera solo quando ci
  # SELEZIONI qualcosa, cioè con un trascinamento (ReaderText.mouseDown: con
  # una selezione non vuota `onClick` non parte). Quindi il gesto che le dà la
  # tastiera è un trascinamento vero sulla riga del gruppo, che è testo.
  x="$(campo 203s "[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['x']")";y="$(campo 203s "[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['y']")";w="$(campo 203s "[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['w']")"
  x1="$(/usr/bin/python3 -c "print($x-$w/2+2)")";x2="$(/usr/bin/python3 -c "print($x+$w/2-2)")"
  send activate;sleep .2;.build/t4a-dragpoint "$x1" "$y" "$x2" "$y" 16;sleep .6;dump 203a
  note "203a caratteri selezionati dal trascinamento" "$(campo 203a "d['chatPage']['selectedChars']")"
  check "203a la selezione dà la tastiera alla pagina" "$(campo 203a "d['composer']['firstResponder']")" ReaderText
  via;front||true;dump 203b;check "203b ritorno porta alla bolla" "$(campo 203b "d['composer']['firstResponder']")" ComposerField
  send activate;sleep .2;.build/t4a-dragpoint "$x1" "$y" "$x2" "$y" 16;sleep .6;dump 203c;check "203c la selezione riprende la pagina" "$(campo 203c "d['composer']['firstResponder']")" ReaderText
  # Coordinate Cocoa e centro pubblicato: il basso è y-h/2.
  bx="$(campo 203c "d['chatPage']['page']['x']")";by="$(campo 203c "d['chatPage']['page']['y']-d['chatPage']['page']['h']/2+20")";click "$bx" "$by"
  for i in $(seq 1 4);do sleep .25;dump "203d$i";[ "$(campo "203d$i" "d['composer']['firstResponder']")" = ComposerField ]&&break;done
  note "203d primo click nel vuoto: responder/selezione" "$(campo "203d$i" "d['composer']['firstResponder']")/$(campo "203d$i" "d['chatPage']['selectedChars']")"
  # Con una selezione viva il primo click la toglie e basta (`mouseDown`: con
  # una selezione non vuota `onClick` non parte): la bolla arriva col secondo.
  if [ "$(campo "203d$i" "d['composer']['firstResponder']")" != ComposerField ];then click "$bx" "$by";for i in $(seq 1 4);do sleep .25;dump "203d-secondo$i";[ "$(campo "203d-secondo$i" "d['composer']['firstResponder']")" = ComposerField ]&&break;done;check "203d vuoto porta alla bolla (secondo click, selezione tolta dal primo)" "$(campo "203d-secondo$i" "d['composer']['firstResponder']")/$(campo "203d-secondo$i" "d['chatPage']['selectedChars']")" ComposerField/0
  else check "203d vuoto porta alla bolla entro 1s" "$(campo "203d$i" "d['composer']['firstResponder']")" ComposerField;fi
  send activate;sleep .2;.build/t4a-dragpoint "$x1" "$y" "$x2" "$y" 16;sleep .6;dump 203e-pre
  note "203e caratteri selezionati prima del click" "$(campo 203e-pre "d['chatPage']['selectedChars']")";check "203e precondizione: tastiera sulla pagina" "$(campo 203e-pre "d['composer']['firstResponder']")" ReaderText
  bx="$(campo 203e-pre "d['chatPage']['page']['x']")";by="$(campo 203e-pre "d['chatPage']['page']['y']-d['chatPage']['page']['h']/2-220")";note "203e punto nel vuoto" "x=$bx y=$by";note "203e rettangolo host" "$(campo 203e-pre "d['chatPage']['host']")";check "203e il punto sta nel contenitore, sotto la pagina" "$(campo 203e-pre "d['chatPage']['host']['y']-d['chatPage']['host']['h']/2<$by<d['chatPage']['page']['y']-d['chatPage']['page']['h']/2")" True
  click "$bx" "$by";for i in $(seq 1 4);do sleep .25;dump "203e$i";[ "$(campo "203e$i" "d['composer']['firstResponder']")" = ComposerField ]&&break;done
  check "203e click nel vuoto sotto la pagina → bolla entro 1s" "$(campo "203e$i" "d['composer']['firstResponder']")" ComposerField;check "203e selezione tolta" "$(campo "203e$i" "d['chatPage']['selectedChars']")" 0
 else echo "203a-e SKIPPED: bundle o transcript non avviato";fi;ferma_mie
 if [ -n "$HEAD" ];then echo "=== HEAD · ISC-203e vuoto sotto la pagina ==========================";if lancia "$HEAD" "$WORK/203.jsonl";then dump h203s;x="$(campo h203s "[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['x']")";y="$(campo h203s "[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['y']")";w="$(campo h203s "[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['w']")";x1="$(/usr/bin/python3 -c "print($x-$w/2+2)")";x2="$(/usr/bin/python3 -c "print($x+$w/2-2)")";send activate;sleep .2;.build/t4a-dragpoint "$x1" "$y" "$x2" "$y" 16;sleep .6;dump h203sel;bx="$(campo h203sel "d['chatPage']['page']['x']")";by="$(campo h203sel "d['chatPage']['page']['y']-d['chatPage']['page']['h']/2-220")";click "$bx" "$by";sleep 1;dump h203e;note "H-203e responder/selezione misurati" "$(campo h203e "d['composer']['firstResponder']")/$(campo h203e "d['chatPage']['selectedChars']")";check_head "H-203e click nel vuoto non porta alla bolla" "$(campo h203e "d['composer']['firstResponder']")" ComposerField;else echo "H-203e SKIPPED: HEAD non avviato";fi;ferma_mie;fi
}

mk204(){ /usr/bin/python3 - "$WORK/204src" "$BENCHCWD" <<'PY'
import json,os,sys
p,cwd=sys.argv[1:];note=os.path.join(cwd,"NOTE.md");c={"cwd":cwd,"entrypoint":"cli","sessionId":"s204","parentUuid":"root"}
r=[{**c,"type":"user","timestamp":"2026-08-28T12:04:00Z","uuid":"u1","message":{"role":"user","content":"Scrivi NOTE.md"}},{**c,"type":"assistant","timestamp":"2026-08-28T12:04:01Z","uuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"w1","name":"Write","input":{"file_path":note,"content":"# Nota\n"}}],"stop_reason":"tool_use"}},{**c,"type":"user","timestamp":"2026-08-28T12:04:02Z","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"w1","content":"ok"}]}},{**c,"type":"assistant","timestamp":"2026-08-28T12:04:03Z","uuid":"a2","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Fatto."}],"stop_reason":"end_turn"}}]
with open(p,"w") as f:
 for x in r:f.write(json.dumps(x,separators=(",",":"))+"\n")
open(note,"w").write("# Nota\n")
PY
}
s204(){
 echo "=== ISC-204 · mano, asta, freccia ==================================";mk204||{ echo "204a-f SKIPPED: transcript sintetico non scritto";STATUS=1;return; };prepara "$WORK/204src" "$WORK/204.jsonl"||{ echo "204a-f SKIPPED: transcript non preparato";return; }
 if lancia "$APP" "$WORK/204.jsonl";then dump 204s;local x y xLink yLink xWord yWord xVoid yVoid screenH topY shotX
  xLink="$(campo 204s "[l for l in d['chatPage']['links'] if l['visible']][0]['link']['x']")";yLink="$(campo 204s "[l for l in d['chatPage']['links'] if l['visible']][0]['link']['y']")";move "$xLink" "$yLink";sleep .4;dump 204a;note "204a cursorAsks/hovered" "$(campo 204a "d['chatPage']['cursorAsks']")/$(campo 204a "d['chatPage']['hovered']")";check "204a link = mano" "$(campo 204a "d['window']['cursor']")" pointingHand;shot 204-mano.png
  # `groups[].row` è il FRAMMENTO di riga intero (`lineFragmentRect`), largo
  # quanto la colonna: il suo centro sta a destra dell'etichetta, nel vuoto,
  # dove la freccia è giusta (quarta corsa: `arrow` con cursorAsks 3 → 4).
  # La parola sta a sinistra: trenta punti dentro il bordo sinistro.
  xWord="$(campo 204a "[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['x']-[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['w']/2+30")";yWord="$(campo 204a "[g for g in d['chatPage']['groups'] if g['visible']][0]['row']['y']")";move "$xWord" "$yWord";sleep .4;dump 204b;note "204b cursorAsks" "$(campo 204b "d['chatPage']['cursorAsks']")";check "204b parola = asta" "$(campo 204b "d['window']['cursor']")" ibeam;shot 204-asta.png
  # Coordinate Cocoa e centro pubblicato: il basso è y-h/2.
  x="$(campo 204b "d['chatPage']['page']['x']")";y="$(campo 204b "d['chatPage']['page']['y']-d['chatPage']['page']['h']/2+20")";move "$x" "$y";sleep .4;dump 204c;check "204c vuoto = freccia" "$(campo 204c "d['window']['cursor']")" arrow;shot 204-freccia.png
  note "204d griglia" "SKIPPED: coperta dalla pagina; resta intatta"
  xVoid="$(campo 204c "d['chatPage']['page']['x']")";yVoid="$(campo 204c "d['chatPage']['page']['y']-d['chatPage']['page']['h']/2-220")";move "$xVoid" "$yVoid";sleep .4;dump 204e;note "204e cursore misurato nel vuoto" "$(campo 204e "d['window']['cursor']")";check "204e vuoto sotto la pagina = freccia" "$(campo 204e "d['window']['cursor']")" arrow
  screenH="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | /usr/bin/awk -F, '{gsub(/ /,"",$4);print $4}')";topY="$(/usr/bin/python3 -c "print(int(round($screenH-$yVoid)))")";shotX="$(/usr/bin/python3 -c "print(int(round($xVoid-40)))")";if screencapture -C -x -R "$shotX,$((topY-40)),80,80" "$WORK/204e-vuoto-puntatore.png";then note "204e foto del puntatore" "$WORK/204e-vuoto-puntatore.png";else echo "204e-vuoto-puntatore.png FAILED";STATUS=1;fi
  move "$xWord" "$yWord";sleep .4;dump 204f-word;check "204f ritorno sulla parola = asta" "$(campo 204f-word "d['window']['cursor']")" ibeam;move "$xLink" "$yLink";sleep .4;dump 204f-link;check "204f ritorno sul link = mano" "$(campo 204f-link "d['window']['cursor']")" pointingHand
 else echo "204a-f SKIPPED: bundle o transcript non avviato";fi;ferma_mie
 if [ -n "$HEAD" ];then echo "=== HEAD · ISC-204e vuoto sotto la pagina ==========================";if lancia "$HEAD" "$WORK/204.jsonl";then dump h204s;xVoid="$(campo h204s "d['chatPage']['page']['x']")";yVoid="$(campo h204s "d['chatPage']['page']['y']-d['chatPage']['page']['h']/2-220")";move "$xVoid" "$yVoid";sleep .4;dump h204e;note "H-204e cursore misurato nel vuoto" "$(campo h204e "d['window']['cursor']")";check_head "H-204e vuoto sotto la pagina non è freccia" "$(campo h204e "d['window']['cursor']")" arrow;else echo "H-204e SKIPPED: HEAD non avviato";fi;ferma_mie;fi
}

s205(){
 echo "=== ISC-205 · scrivere torna in fondo ==============================";if avvia "$APP" no;then local p="[q for t in d['tabs'] for q in t['panes'] if q['active']][0]"
  send "text seq 1 400";send activate;send "key return";sleep 1.5;dump 205base;note "205 base" "top=$(campo 205base "$p['topVisibleRow']") bottom=$(campo 205base "max($p['firstRetainedRow'],$p['endRow']-$p['rows'])")"
  # SwiftTermSession: positivo = scrollUp; -50 scorrerebbe in basso.
  send "scroll 50";sleep .4;dump 205a;check "205a siamo sopra" "$(campo 205a "$p['topVisibleRow']<max($p['firstRetainedRow'],$p['endRow']-$p['rows'])")" True
  send "text echo giu";send activate;send "key return";sleep 1;dump 205b;check "205b comando al nuovo fondo" "$(campo 205b "$p['topVisibleRow']==max($p['firstRetainedRow'],$p['endRow']-$p['rows'])")" True
  send "scroll 50";sleep .4;dump 205c;check "205c di nuovo sopra" "$(campo 205c "$p['topVisibleRow']<max($p['firstRetainedRow'],$p['endRow']-$p['rows'])")" True
  # Decisione 28/08: Esc interrompe e il suo effetto si vede in fondo; come
  # negli altri terminali ogni tasto chiude la lettura dello scrollback.
  send activate;send "key escape";sleep .4;dump 205d;check "205d Esc torna al fondo" "$(campo 205d "$p['topVisibleRow']==max($p['firstRetainedRow'],$p['endRow']-$p['rows'])")" True;note "205d topVisibleRow" "$(campo 205d "$p['topVisibleRow']")"
 else echo "205a-d SKIPPED: bundle non avviato";fi;ferma_mie
}

mk206(){ /usr/bin/python3 - "$WORK/206src" "$BENCHCWD" <<'PY'
import json,sys
p,c=sys.argv[1:];r={"type":"user","timestamp":"2026-08-28T12:06:00Z","cwd":c,"entrypoint":"cli","sessionId":"s206","uuid":"u1","parentUuid":"root","message":{"role":"user","content":"Pensa."}};open(p,"w").write(json.dumps(r)+"\n")
PY
}
s206(){
 echo "=== ISC-206 · attesa senza spinner ================================";mk206||{ echo "206a-c SKIPPED: transcript sintetico non scritto";STATUS=1;return; };prepara "$WORK/206src" "$WORK/206.jsonl"||{ echo "206a-c SKIPPED: transcript non preparato";return; }
 if lancia "$APP" "$WORK/206.jsonl";then send "chat-page off";send "turn-open 1";sleep .4;dump 206a;local ready=0 i
  check "206a ripiego nel lettore, nessun verbo nostro" "$(campo 206a "'…' in d['turnReader']['text'] and '(sta ' not in d['turnReader']['text']")" True;note "206a attesa" "…"
  send turn-close;send "turn-open 1";sleep .4;dump 206b;check "206b riapertura: stesso ripiego" "$(campo 206b "'…' in d['turnReader']['text'] and '(sta ' not in d['turnReader']['text']")" True
  /usr/bin/python3 - "$TRANSCRIPT" "$BENCHCWD" <<'PY'
import json,os,sys
p,c=sys.argv[1:];r={"type":"user","timestamp":"2026-08-28T12:06:01Z","cwd":c,"entrypoint":"cli","sessionId":"s206","uuid":"u2","parentUuid":"u1","message":{"role":"user","content":"Pensa ancora."}}
with open(p,"a") as f:
 f.write(json.dumps(r)+"\n");f.flush();os.fsync(f.fileno())
PY
  # La pagina SPENTA non riceve i turni (`chatPage.mostra` solo se visibile,
  # MainWindowController ~959): prima corsa ferma a 1 con la pagina off.
  send "chat-page on"
  for i in $(seq 1 40);do send scan;sleep .25;dump "206w$i";[ "$(campo "206w$i" "d['chatPage']['turns']")" = 2 ]&&{ ready=1;break;};done
  note "206c chatPage.turns a fine attesa" "$(campo "206w$i" "d['chatPage']['turns']")"
  # Il fake non disegna la riga animata di claude: anche il secondo turno usa
  # `…`. Il vecchio polo «verbo diverso» non risponde più ad alcun contratto.
  if [ "$ready" = 0 ];then echo "206c secondo turno missing FAILED";STATUS=1;else send "chat-page off";send "turn-open 2";sleep .4;dump 206c;check "206c secondo turno usa il ripiego" "$(campo 206c "'…' in d['turnReader']['text'] and '(sta ' not in d['turnReader']['text']")" True;note "206c attesa" "…";fi
 else echo "206a-c SKIPPED: bundle o transcript non avviato";fi;ferma_mie
}

t4a_note_his_app; trap 'ferma_mie; rilascia_lock' EXIT; prepara_base||exit 1
case "$SECTION" in
 216)s216;;217)s217;;203)s203;;204)s204;;205)s205;;206)s206;;all)s216;s217;s203;s204;s205;s206;;
esac
ferma_mie;[ "$STATUS" = 0 ]&&echo "seguito: i poli tengono"||echo "seguito: un polo FALLITO";exit "$STATUS"
