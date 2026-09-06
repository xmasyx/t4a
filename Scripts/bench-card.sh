#!/bin/bash
# ISC-122 — the approval card appears on a PERMISSION and never on a menu.
#
#   Scripts/bench-card.sh [app-bundle]
#
# Two poles, both on a live `claude`, because the thing being measured is a
# shape drawn on a screen and there is nowhere else it exists:
#
#   POSITIVE  a real permission — the workspace-trust question, which a folder
#             that has never been opened before always asks — must raise the
#             card, with the two answers read off the drawing.
#             The tool-permission case is measured end to end by
#             `bench-agent.sh live`, which answers one with the card and
#             watches the file appear.
#
#   NEGATIVE  `/model`, five choices that stand beside each other and nobody
#             asking permission for anything, must raise NOTHING. This is the
#             screen the claim was opened for: the card used to lie on top of
#             it (design/evidence/f5-114-pure-chat-revealed.png).
#
# A NOTE PAID FOR ON 22/08 by the chat before this one: the trust question is
# asked ONCE per directory, so a bench built on it passes its first run and
# then measures nothing. The directory here is new every run, and the bench
# says so before it uses it.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-card.fifo"
CONFIG_HOME="/tmp/t4a-card-config"
# claude's own configuration, isolated (ISC-132). Answering a trust question is
# a WRITE: without this the bench leaves a folder marked trusted in the real
# `~/.claude.json` every time it runs, which is the user's setup being changed
# by a measurement. `CLAUDE_CONFIG_DIR` is honoured — probed on 2.1.239, the
# directory gets its own `.claude.json` and the real one keeps its checksum.
CLAUDE_HOME="/tmp/t4a-card-claude"
DUMP=/tmp/t4a-card-dump.json
STATUS=0

# What must come out of this run untouched.
REAL_T4A_CONFIG="$HOME/.config/t4a/config.toml"
REAL_CLAUDE_CONFIG="$HOME/.claude.json"
hash_of() { [ -e "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "(absent)"; }
BEFORE_T4A="$(hash_of "$REAL_T4A_CONFIG")"
BEFORE_CLAUDE="$(hash_of "$REAL_CLAUDE_CONFIG")"

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "claude is not on PATH" >&2; exit 1; }

for tool in winid; do
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
  local name="$1" got="$2" want="$3" mark="ok"
  [ "$got" = "$want" ] || { mark="FAILED"; STATUS=1; }
  printf '%-46s %-30s (want %s) %s\n' "$name" "$got" "$want" "$mark"
}
note() { printf '%-46s %s\n' "$1" "$2"; }
shot() {
  mkdir -p design/evidence
  local id; id="$(.build/t4a-winid || true)"
  if [ -n "$id" ]; then screencapture -x -o -l "$id" "design/evidence/$1"
    echo "    photographed: design/evidence/$1"
  else echo "    no window id: $1 NOT taken"; STATUS=1; fi
}
front() {
  for _ in $(seq 1 6); do
    # Two independent ways of asking; see the note in bench-f5.sh.
    send "activate"; sleep 0.6
    open -a "$PWD/$APP" 2>/dev/null || true
    sleep 1.4; dump
    [ "$(field "d['appActive']")" = "True" ] && { sleep 1; return 0; }
  done
  echo "    T4A would not come to the front"; return 1
}
stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }

stop
rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME"
# A claude configuration of our own: the real one MINUS `projects`, which is
# where the trust bookkeeping lives.
#
# A config built from nothing was the first try and it measured the wrong
# screen: claude read it as a machine that had never logged in, put "Not logged
# in - Run /login" in its footer, and `/model` -- the negative pole -- never
# opened. Every other key has to be the real one for the run to be a run; only
# the one key the bench WRITES is emptied. The copy carries the user's own
# account data, so it is made 0700 and removed when the bench ends.
rm -rf "$CLAUDE_HOME"; mkdir -p "$CLAUDE_HOME"; chmod 700 "$CLAUDE_HOME"
/usr/bin/python3 Scripts/claude-config-copy.py \
  "$REAL_CLAUDE_CONFIG" "$CLAUDE_HOME/.claude.json"
# Never opened before, so the trust question is certain to be asked. Under
# $HOME because that is where claude's own trust bookkeeping lives.
WORK="$HOME/Movies/t4a-card-$$-$(date +%H%M%S)"
mkdir -p "$WORK"
note "a folder claude has never seen" "$WORK"
rm -f "$FIFO"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME" \
  --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3

echo "=== the positive pole: a real permission ==========================="
send "text cd $WORK && claude"; send "key return"
sleep 22
send "scan"; sleep 1.5
dump
verdict "a numbered question is on screen" \
  "$(field "'yes' if d['card']['showing'] else 'no'")" "yes"
note "  the card's title" "$(field "repr(d['card'].get('title'))")"
note "  the two answers it offers" \
  "$(field "' / '.join('%s->%s' % (o.get('label'), o.get('keys')) for o in d['card'].get('options', []))")"
note "  why the scanner called it a permission" "$(field "d['selector'].get('reason', '(no reason field)')")"
# Where the caret sits relative to the box (ISC-127). The number is printed
# whether or not the guard let the card through, because "no card" and "a box
# the caret was not in" are the same silence from outside.
# ISC-136: the one accent on the screen, at the one moment it exists for.
verdict "the big number counts the session that is asking" \
  "$(field "d['waiting']")" "1"
note "  box rows / caret / inside" \
  "$(field "'%s..%s  caret %s  inside=%s' % (d['selector'].get('firstRow'), d['selector'].get('lastRow'), d['selector'].get('cursorRow'), d['selector'].get('cursorInside'))")"
front || STATUS=1
shot "f5-122-card-on-permission.png"
echo ""
echo "=== ISC-127: the click reads the screen again before it types ======="
# The race, staged instead of waited for. `stalecard` puts the LIVE question's
# options on the card under a different title, which is what a box redrawn
# between the scan and the click looks like from the app's side.
send "stalecard A question nobody asked"; sleep 1.5
dump
verdict "a stale card is on screen" \
  "$(field "repr(d['card'].get('title'))")" "'A question nobody asked'"
send "approve yes"; sleep 3
dump
verdict "nothing was sent, and the card said so" \
  "$(field "'withdrawn' if not d['card']['showing'] and d['card'].get('withdrawn') else 'it typed anyway'")" \
  "withdrawn"
note "  what the card said" "$(field "repr(d['card'].get('withdrawn'))")"
# The falsifier lives at the pty, not in the app's own state: had `1\r` gone
# down, claude would have taken it as the answer and the trust question would
# be gone from the screen.
verdict "the real question is untouched on the screen" \
  "$(field "'still asking' if any('trust this folder' in l for l in d['tabs'][0]['panes'][0]['screen']) else 'it was answered'")" \
  "still asking"

echo ""
echo "=== back to the real question, and the card DOES answer that one ===="
send "scan"; sleep 2
dump
verdict "the card is showing the real question again" \
  "$(field "repr(d['card'].get('title'))")" "'Accessing workspace:'"
# Answered with the card, which is the ISC-29 path: the keystroke goes into
# the agent's own prompt.
send "approve yes"; sleep 6
dump
# "A card is still up" has two readings and only one is a defect: the card that
# was answered, or a SECOND question the agent asked next. Measured on
# 2026-08-22: under its own configuration claude asks the trust question and
# then "Allow external CLAUDE.md file imports?", which the real config answered
# months ago — a bench that asserted "no card" right here would be calling a
# working app broken because it isolated the config properly. So the follow-ups
# are answered the same way, by the card, and each one is named.
for attempt in 1 2 3 4; do
  dump
  [ "$(field "'yes' if d['card']['showing'] else 'no'")" = "yes" ] || break
  note "  another permission, answered by the card" "$(field "repr(d['card'].get('title'))")"
  send "approve yes"; sleep 6
done
dump
verdict "the card answered and went away" \
  "$(field "'gone' if not d['card']['showing'] else 'still there'")" "gone"
verdict "and the big number went back to zero" "$(field "d['waiting']")" "0"

echo ""
echo "=== the negative pole: /model, five choices and no permission ======"
send "text /model"; sleep 1.5; send "key return"; sleep 4
dump
verdict "no card over the menu" \
  "$(field "'none' if not d['card']['showing'] else 'a card is on top of it'")" "none"
# The menu really IS on the screen: without this the pole would be satisfied
# by a claude that never opened it, which is the same green for the wrong
# reason. Read off the pane, not off the card.
verdict "the menu is genuinely open" \
  "$(field "'yes' if any('Select model' in line for line in d['tabs'][0]['panes'][0]['screen']) else 'no'")" \
  "yes"
verdict "and the scanner still SEES it (so ISC-114 uncovers)" \
  "$(field "d['selector'].get('kind', 'missing')")" "selector"
note "  what the scanner read" "$(field "d['selector'].get('reason', '(no selector field)')")"
note "  the options it read off the screen" "$(field "' | '.join(d['selector'].get('options', []))")"
front || STATUS=1
shot "f5-122-no-card-on-model.png"
send "key escape"; sleep 1

send "key ctrl-c"; sleep 0.5; send "key ctrl-c"; sleep 1
stop
rmdir "$WORK" 2>/dev/null || true

echo ""
echo "=== the pole that is about the machine, not the app (ISC-132) ========"
verdict "the real t4a config is byte-identical" \
  "$(hash_of "$REAL_T4A_CONFIG")" "$BEFORE_T4A"
verdict "the real claude config is byte-identical" \
  "$(hash_of "$REAL_CLAUDE_CONFIG")" "$BEFORE_CLAUDE"
note "  where the trust went instead" \
  "$(/usr/bin/python3 -c "
import json
print(' '.join(json.load(open('$CLAUDE_HOME/.claude.json')).get('projects', {}).keys()) or '(none)')" 2>/dev/null)"
# The copy carries the account, so it does not outlive the run.
rm -rf "$CLAUDE_HOME"

[ "$STATUS" = "0" ] && echo "card: both poles held" || echo "card: a pole FAILED"
exit "$STATUS"
