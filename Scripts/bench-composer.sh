#!/bin/bash
# ISC-113 — the bubble is there by default, and `contextual` is the choice
# that takes it away.
#
#   Scripts/bench-composer.sh [--with-claude] [app-bundle]
#
# Every pole starts from a VIRGIN configuration directory, because the claim
# is about the default and a default is only visible where no file has an
# opinion. What is read back is the app's own report of the composer — mode,
# whether it is on screen, and its height in points — not a look at a
# screenshot.
#
#   1. bare shell, no config at all      NON c'è             (ISC-174)
#   2. inside `less`, alternate screen   non c'è nemmeno lì  (ISC-174)
#   3. `contextual`, still inside less   it goes away           (ISC-112 kept)
#   4. `never`, back at the shell        away everywhere
#   5. `always`, inside less             back
#   6. a value nobody recognises         cade sul DEFAULT, che dal 26/08 è
#                                        `agent`: senza un agente, niente bolla
#
# I poli 1, 2 e 6 sono stati girati il 26/08: fino ad allora dicevano «la
# bolla c'è comunque», che era il default vecchio. ISC-174 ha deciso il
# contrario — la bolla compare solo dove c'è un agente agganciato — e questo
# banco è rimasto indietro di una notte. Girato, non spento.
#
# With --with-claude the real thing is run: `claude` in the pane, the pole
# ISC-112 denied, photographed into design/evidence/.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

WITH_CLAUDE=0
if [ "${1:-}" = "--with-claude" ]; then WITH_CLAUDE=1; shift; fi
APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-composer.fifo"
CONFIG_HOME="/tmp/t4a-composer-config"
DUMP=/tmp/t4a-composer-dump.json
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done
}

# Reads one pole: expected shown ("yes"/"no") and expected frontOwnsInput
# ("yes"/"no"/"any"). Prints what the app actually said, always.
pole() {
  local name="$1" want_shown="$2" want_front="$3"
  dump
  local line
  line="$(/usr/bin/python3 -c "
import json
c = json.load(open('$DUMP'))['composer']
print('%s %s %s %s' % (c['mode'], 'yes' if c['shown'] else 'no', c['height'],
                       'yes' if c['frontOwnsInput'] else 'no'))
")"
  local mode shown height front
  read -r mode shown height front <<<"$line"
  local verdict="ok"
  [ "$shown" = "$want_shown" ] || verdict="FAILED"
  if [ "$want_front" != "any" ] && [ "$front" != "$want_front" ]; then verdict="FAILED"; fi
  if [ "$want_shown" = "yes" ] && [ "${height%.*}" = "0" ]; then verdict="FAILED"; fi
  if [ "$want_shown" = "no" ] && [ "${height%.*}" != "0" ]; then verdict="FAILED"; fi
  printf '%-34s mode=%-10s shown=%-3s height=%-5s frontOwnsInput=%-3s %s\n' \
    "$name" "$mode" "$shown" "$height" "$front" "$verdict"
  [ "$verdict" = "ok" ] || STATUS=1
}

t4a_stop_bench
sleep 1
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME"
echo "==> virgin config: $CONFIG_HOME (no config.toml)"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "test channel never appeared" >&2; exit 1; }
sleep 3
ls "$CONFIG_HOME/t4a/config.toml" >/dev/null 2>&1 \
  && echo "note: a config file exists already: $(cat "$CONFIG_HOME/t4a/config.toml")" \
  || echo "no config file on disk: what follows is the compiled default"

pole "1 bare shell, no config" no no

echo "==> into an alternate screen (less)"
send 'text seq 1 500 | less'; send "key return"; sleep 2
pole "2 inside less, default" no yes

send "composer-mode contextual"; sleep 0.5
pole "3 inside less, contextual" no yes

send "composer-mode never"; sleep 0.5
pole "4 inside less, never" no yes

send "composer-mode always"; sleep 0.5
pole "5 inside less, always" yes yes

send "text q"; sleep 1

# A value the app cannot read must not cost you your input line. It is read
# at launch, so this pole needs a launch of its own.
echo "==> relaunch with a value nobody recognises in the file"
t4a_stop_bench
sleep 1.5
rm -f "$FIFO"
printf 'composer-mode = whatever\n' > "$CONFIG_HOME/t4a/config.toml"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3
send 'text seq 1 500 | less'; send "key return"; sleep 2
pole "6 unreadable value, inside less" no yes
send "text q"; sleep 1

if [ "$WITH_CLAUDE" = "1" ]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude is not on PATH: the live pole was NOT run"
    STATUS=1
  else
    echo "==> the real pole: claude in the pane"
    send "composer-mode always"; sleep 0.3
    send "text cd $(pwd) && claude"; send "key return"
    sleep 12
    pole "7 claude alive, default" yes yes
    mkdir -p design/evidence
    WID="$(.build/t4a-winid 2>/dev/null || { swiftc -O Scripts/winid.swift -o .build/t4a-winid && .build/t4a-winid; })"
    if [ -n "$WID" ]; then
      screencapture -x -o -l "$WID" design/evidence/f5-113-bubble-in-claude.png
      echo "photographed: design/evidence/f5-113-bubble-in-claude.png"
    else
      echo "no window id: no photograph taken"; STATUS=1
    fi
    send "composer-mode contextual"; sleep 0.8
    pole "8 claude alive, contextual" no yes
    if [ -n "$WID" ]; then
      screencapture -x -o -l "$WID" design/evidence/f5-113-contextual-in-claude.png
      echo "photographed: design/evidence/f5-113-contextual-in-claude.png"
    fi
    send "composer-mode always"; sleep 0.5
    send "key ctrl-c"; sleep 0.5; send "key ctrl-c"; sleep 1
  fi
fi

t4a_stop_bench
rm -f "$FIFO"
[ "$STATUS" = "0" ] && echo "composer: every pole held" || echo "composer: a pole FAILED"
exit "$STATUS"
