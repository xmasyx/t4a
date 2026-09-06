#!/bin/bash
# ISC-147, ISC-148, ISC-151 — the three things the sessions list owes you:
# a way to move it, a way to close one, and a name that is still true.
#
#   Scripts/bench-sessions.sh [--with-claude] [app-bundle]
#
# Every press here is a REAL one. The layout glyph and the × are controls that
# only exist on the screen, so a bench that called the method behind them would
# be measuring the method: `movepoint` puts the pointer where a hand would put
# it, `clickpoint` presses where a finger would press, and the app is asked
# afterwards what it thinks happened.
#
#   ISC-147  the band carries a glyph that moves the sessions from the rail to
#            the top and back; the glyph draws the edge they are on now; the
#            choice is written down and survives a relaunch.
#            Found by its LABEL and by being on the screen, never by counting:
#            the app builds TWO of these — one in the rail, one in the tab
#            strip — and shows whichever panel is up, so the number of glyphs
#            in the band is not a fact this bench is entitled to know
#            (ISC-189).
#   ISC-148  a row of the rail grows a × under the pointer and loses it again;
#            the × closes THAT pane and nothing else; with a program running in
#            the pane it asks first, and a No leaves everything standing.
#   ISC-151  the pane's name follows the pane: the folder with nothing running,
#            what the program reports, and — the repair — the newest question
#            when an agent is attached, because `claude` names a session once
#            and never renames it.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

WITH_CLAUDE=0
if [ "${1:-}" = "--with-claude" ]; then WITH_CLAUDE=1; shift; fi
APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-sessions.fifo"
CONFIG_HOME="/tmp/t4a-sessions-config"
DUMP=/tmp/t4a-sessions-dump.json
SHOTS=design/evidence
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

mkdir -p .build
[ -x .build/t4a-winid ] || swiftc -O Scripts/winid.swift -o .build/t4a-winid
[ -x .build/t4a-click ] || swiftc -O Scripts/clickpoint.swift -o .build/t4a-click
[ -x .build/t4a-move ] || swiftc -O Scripts/movepoint.swift -o .build/t4a-move

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done
}
field() { /usr/bin/python3 -c "import json;d=json.load(open('$DUMP'));print($1)"; }
# The glyph that moves the sessions, as an expression over the dump. Picked by
# its label AND by being on the screen, because the app builds TWO of them —
# one in the rail, one in the tab strip — and only the panel that is up has
# its own where a hand could reach it. An index into the list was right in
# rail layout and pointed at a rectangle nobody can see the moment the
# sessions moved to the top, which is where the clicks of 147e went from the
# day the band grew its fifth entry (ISC-189).
GLYPH="[b for b in d['band']['buttons'] if b['label']=='sessions layout' and b['onScreen']][0]"
verdict() {
  local name="$1" ok="$2" detail="$3"
  printf '%-52s %s  %s\n' "$name" "$([ "$ok" = "0" ] && echo PASS || echo FAIL)" "$detail"
  [ "$ok" = "0" ] || STATUS=1
}
shoot() {
  mkdir -p "$SHOTS"
  local wid; wid="$(.build/t4a-winid || true)"
  if [ -n "$wid" ]; then
    screencapture -x -o -l "$wid" "$SHOTS/$1"
    echo "      photographed: $SHOTS/$1"
  else
    echo "      no window id: no photograph taken"; STATUS=1
  fi
}
title() { field "[q for t in d['tabs'] for q in t['panes'] if q['active']][0]['title']"; }
panecount() { field "sum(len(t['panes']) for t in d['tabs'])"; }

launch() {
  t4a_stop_bench
  sleep 1.5
  rm -f "$FIFO"
  open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
  sleep 3
}

# Brings T4A to the front and insists on it: a real click lands on whatever the
# window server has on top, so a pole that clicks without the front is a pole
# that clicked on something else.
front() {
  for _ in $(seq 1 6); do
    send "activate"; sleep 0.6
    open -a "$PWD/$APP" 2>/dev/null || true
    sleep 1.2
    dump
    [ "$(field "d['appActive']")" = "True" ] && { sleep 1; return 0; }
  done
  echo "      T4A would not come to the front: something keeps taking it"
  STATUS=1
  return 1
}

wait_for_screen() {
  local needle="$1" limit="${2:-45}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    dump
    if /usr/bin/python3 -c '
import json, sys
tabs = json.load(open(sys.argv[1]))["tabs"]
panes = [q for t in tabs for q in t["panes"] if q.get("active")] \
        or [q for t in tabs for q in t["panes"]]
for pane in panes:
    screen = pane.get("screen") or ""
    if sys.argv[2] in ("\n".join(screen) if isinstance(screen, list) else str(screen)):
        sys.exit(0)
sys.exit(1)
' "$DUMP" "$needle"; then return 0; fi
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# Waits for the pane's name to become something, or gives up and returns what
# it last saw. A title that arrives with the agent's own record is not on this
# process's clock, so it is waited FOR rather than slept past.
wait_title_change() {
  local was="$1" limit="${2:-45}" waited=0 now=""
  while [ "$waited" -lt "$limit" ]; do
    dump; now="$(title)"
    [ "$now" != "$was" ] && { echo "$now"; return 0; }
    sleep 2; waited=$((waited + 2))
  done
  echo "$now"; return 1
}

rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME"
echo "==> virgin configuration: $CONFIG_HOME"
launch
front || true

echo
echo "=== ISC-147: the glyph that moves the sessions ====================="
dump
POLE=0
/usr/bin/python3 - <<'PY' || POLE=$?
import json, sys
band = json.load(open('/tmp/t4a-sessions-dump.json'))['band']
buttons = band.get('buttons') or []
for b in buttons:
    print("      %-18s edge=%-7s on=%-5s onScreen=%-5s  %.0fx%.0f at (%.0f,%.0f)"
          % (b['label'], b['edge'], b['on'], b['onScreen'], b['w'], b['h'], b['x'], b['y']))
shown = [b for b in buttons if b['onScreen']]
layout = [b for b in shown if b['label'] == 'sessions layout']
# ONE of them on the screen, which is the claim: two would be two controls
# for one question and none would be a question with no control. The rest of
# the band is not counted — glyphs come and go with the panels they command
# (the preview one exists only while a file is open), so a bench that fixed
# their number would go red for a feature. That is exactly what this one did
# from 26/08 on, and the number it was defending had been right for a week.
if len(layout) != 1:
    print("      %d of the %d glyphs on screen move the sessions"
          % (len(layout), len(shown)))
    sys.exit(1)
one = layout[0]
# The same rectangle as its neighbours, or it is a different kind of button
# wearing the same coat (ISC-104.5).
others = [b for b in shown if b['label'] != 'sessions layout']
if any(abs(b['w'] - one['w']) > 0.5 or abs(b['h'] - one['h']) > 0.5 for b in others):
    print("      it is not the size of the others: %s" % [(b['label'], b['w'], b['h']) for b in shown])
    sys.exit(1)
sys.exit(0)
PY
verdict "147a one glyph moves the sessions, sized like its neighbours" "$POLE" \
  "$(field "'%d of %d glyphs on screen' % (len([b for b in d['band']['buttons'] if b['onScreen']]), len(d['band']['buttons']))")"

LX="$(field "$GLYPH['x']")"
LY="$(field "$GLYPH['y']")"
LW="$(field "$GLYPH['w']")"
BEFORE="$(field "d['layout']")"
WRITES_BEFORE="$(field "d['configWrites']")"

# Off centre on purpose: the claim is that the whole rectangle is the button,
# so the press goes near its edge and not on the glyph in the middle.
CORNER_X="$(/usr/bin/python3 -c "print($LX - $LW/2 + 3)")"
.build/t4a-click "$CORNER_X" "$LY"; sleep 1.2
dump
AFTER="$(field "d['layout']")"
EDGE="$(field "$GLYPH['edge']")"
RAIL_HIDDEN="$(field "d['rail']['hidden']")"
POLE=0
{ [ "$BEFORE" = "rail" ] && [ "$AFTER" = "tabs" ] && [ "$EDGE" = "top" ] \
  && [ "$RAIL_HIDDEN" = "True" ]; } || POLE=1
verdict "147b a real click on its EDGE moves them to the top" "$POLE" \
  "$BEFORE -> $AFTER, glyph bar now on the $EDGE, rail hidden=$RAIL_HIDDEN"
shoot "f9-147-layout-toggle.png"

POLE=0
grep -q 'layout-sessions = tabs' "$CONFIG_HOME/t4a/config.toml" || POLE=1
verdict "147c and it is written down, once" "$POLE" \
  "$(grep 'layout-sessions' "$CONFIG_HOME/t4a/config.toml" 2>/dev/null || echo 'nothing in the file'), writes $WRITES_BEFORE -> $(field "d['configWrites']")"

launch
dump
POLE=0; [ "$(field "d['layout']")" = "tabs" ] || POLE=1
verdict "147d and it survives a relaunch" "$POLE" "layout=$(field "d['layout']")"

# The negative pole of the repair, standing exactly where the repair was
# needed. The sessions are at the top now, so the rail is gone and its copy of
# the glyph went with it — while the tab strip's copy is the one on the
# screen. Whoever picks by position picks the rail's, presses a rectangle
# outside the window, and reads the layout that did not change as a product
# that stopped working: that is what 147e reported for a day. It is asked of
# the dump rather than with a click on purpose, because that rectangle is off
# the window and the press would land on whatever is behind T4A.
POLE=0
/usr/bin/python3 -c "
import json, sys
twins = [b for b in json.load(open('$DUMP'))['band']['buttons'] if b['label'] == 'sessions layout']
print('      the two copies of the glyph: %s'
      % [(('on screen' if b['onScreen'] else 'out of sight'), round(b['x']), round(b['y'])) for b in twins])
sys.exit(0 if len(twins) == 2 and sum(b['onScreen'] for b in twins) == 1
         and not twins[0]['onScreen'] else 1)
" || POLE=$?
verdict "147d-bis by position you would press the one out of sight" "$POLE" \
  "the defect ISC-189 repaired"

front || true
dump
LX="$(field "$GLYPH['x']")"
LY="$(field "$GLYPH['y']")"
.build/t4a-click "$LX" "$LY"; sleep 1.2
dump
POLE=0
{ [ "$(field "d['layout']")" = "rail" ] \
  && [ "$(field "$GLYPH['edge']")" = "left" ]; } || POLE=1
verdict "147e and the glyph, where it now lives, brings them back" "$POLE" \
  "layout=$(field "d['layout']") edge=$(field "$GLYPH['edge']")"

echo
echo "=== ISC-148: the × on a row ========================================"
# Two panes, so that "it closed THAT one" is a question with an answer. Both
# bare shells: the pole with a program in the pane comes after.
send "splitv"; sleep 2
dump
POLE=0; [ "$(panecount)" = "2" ] || POLE=1
verdict "148a two panes to tell apart" "$POLE" "$(panecount) panes"

# The pointer somewhere else first. Until ISC-154 the claim here was the
# opposite one — no pointer, no × — and the pole was written to prove it. It
# is rewritten and not deleted, because the question it asks is still the
# question: WHERE is the × when nobody is looking for it? The answer changed
# on 23/08, on his instruction, and the old pole failing on the new bundle is
# the two claims disagreeing out loud, which is what a pole is for.
.build/t4a-move 700 400; sleep 0.8
dump
POLE=0
/usr/bin/python3 -c "
import json, sys
rows = json.load(open('$DUMP'))['rail']['rows']
shown = [r['title'] for r in rows if r['showingClose']]
print('      pointer away from the rail: %d of %d rows show a ×' % (len(shown), len(rows)))
sys.exit(0 if rows and len(shown) == len(rows) else 1)
" || POLE=$?
verdict "148b every row shows its × without the pointer" "$POLE" "ISC-154"

RX="$(field "d['rail']['rows'][0]['row_x']")"
RY="$(field "d['rail']['rows'][0]['row_y']")"
VICTIM="$(field "d['rail']['rows'][0]['id']")"
.build/t4a-move "$RX" "$RY"; sleep 0.9
dump
POLE=0
/usr/bin/python3 -c "
import json, sys
rows = json.load(open('$DUMP'))['rail']['rows']
for r in rows:
    print('      %-16s showingClose=%-5s close=%s' % (r['title'], r['showingClose'], r.get('close')))
# One × per row and no more, each with a box a finger could hit: the defect
# this replaces would have been TWO marks in one corner, not none.
boxes = [r.get('close') for r in rows]
sys.exit(0 if all(boxes) and len(set((b['x'], b['y']) for b in boxes)) == len(boxes) else 1)
" || POLE=$?
verdict "148c one × per row, each in its own corner" "$POLE" "one per row"
shoot "f9-148-close-x.png"

CX="$(field "d['rail']['rows'][0]['close']['x']")"
CY="$(field "d['rail']['rows'][0]['close']['y']")"
.build/t4a-click "$CX" "$CY"; sleep 1.5
dump
LEFT="$(panecount)"
GONE="$(field "'$VICTIM' not in [q['id'] for t in d['tabs'] for q in t['panes']]")"
POLE=0; { [ "$LEFT" = "1" ] && [ "$GONE" = "True" ]; } || POLE=1
verdict "148d a bare shell closes on the click, no question" "$POLE" \
  "2 panes -> $LEFT, the one clicked is gone=$GONE"

echo
echo "=== ISC-148: and with something running in the pane ================"
# `sleep`, and no longer `claude`. What this section asks is whether the ×
# goes through the same guard ⌘W does, and what makes that guard speak is a
# foreign program in front of the pty. It used to be `claude` here, and on
# 26/08 the principal moved the line himself: an agent ATTACHED and at rest is
# not work in progress, so closing its pane asks nothing at all
# (`closingWouldInterrupt` in Session.swift, commit 08452ac). This pole then
# went red for a decision and not for a defect — measured 27/08: asking=False,
# 2 panes -> 1, twice. The decision has a bench of its own,
# `bench-close-guard.sh`, which drives an agent to `working` and back and
# holds both sides of it; what belongs HERE is the half about the ×, and a
# program with no clock in it says that half without a race and without
# `claude` having to be on the PATH (ISC-189).
send "splitv"; sleep 2
send "text sleep 600"; send "key return"
# Waited on the KERNEL, not on the screen: what these poles need is a program
# other than the shell in front of the pty, which is the exact thing the close
# guard reads.
for _ in $(seq 1 20); do
  dump
  [ "$(field "len(d['foreground'])")" != "0" ] && break
  sleep 1
done
POLE=0; [ "$(field "len(d['foreground'])")" != "0" ] || POLE=1
verdict "148d-bis a program of its own is holding the pane" "$POLE" \
  "foreground=$(field "d['foreground']")"
[ "$POLE" = "0" ] || echo "      nothing took the pane: 148e-g below say nothing about the guard"

front || true
dump
# The row holding it, found by asking which pane has a foreign program rather
# than by counting on the order of the list.
BUSY_ID="$(field "[q['id'] for t in d['tabs'] for q in t['panes'] if q['process'] not in ('zsh','bash','sh','')][0]")"
ROW="[r for r in d['rail']['rows'] if r['id']=='$BUSY_ID'][0]"
RX="$(field "$ROW['row_x']")"
RY="$(field "$ROW['row_y']")"
.build/t4a-move "$RX" "$RY"; sleep 0.9
dump
CX="$(field "$ROW['close']['x']")"
CY="$(field "$ROW['close']['y']")"
BEFORE_PANES="$(panecount)"
.build/t4a-click "$CX" "$CY"; sleep 2
dump
ASKING="$(field "d['window'].get('askingToClose')")"
POLE=0
{ [ "$ASKING" = "True" ] && [ "$(panecount)" = "$BEFORE_PANES" ]; } || POLE=1
verdict "148e with a program running in it, the × asks first" "$POLE" \
  "asking=$ASKING, panes $BEFORE_PANES -> $(panecount)"

send "answer no"; sleep 1.5
dump
POLE=0; [ "$(panecount)" = "$BEFORE_PANES" ] || POLE=1
verdict "148f and a No leaves everything standing" "$POLE" "$(panecount) panes"

.build/t4a-move "$RX" "$RY"; sleep 0.9
dump
CX="$(field "$ROW['close']['x']")"
CY="$(field "$ROW['close']['y']")"
.build/t4a-click "$CX" "$CY"; sleep 2
send "answer yes"; sleep 2
dump
POLE=0
{ [ "$(panecount)" -lt "$BEFORE_PANES" ] \
  && [ "$(field "'$BUSY_ID' not in [q['id'] for t in d['tabs'] for q in t['panes']]")" = "True" ]; } || POLE=1
verdict "148g and a Yes closes that pane and only it" "$POLE" \
  "$BEFORE_PANES -> $(panecount) panes"

echo
echo "=== ISC-151: a name that is still true ============================="
launch
front || true
dump
POLE=0
[ "$(title)" = "$(basename "$HOME")" ] || POLE=1
verdict "151a nothing running: the pane wears its folder" "$POLE" "title=$(title)"

send 'text printf "\033]0;FIRST-NAME\007"'; send "key return"; sleep 1.5
dump
FIRST="$(title)"
send 'text printf "\033]0;SECOND-NAME\007"'; send "key return"; sleep 1.5
dump
SECOND="$(title)"
POLE=0; { [ "$FIRST" = "FIRST-NAME" ] && [ "$SECOND" = "SECOND-NAME" ]; } || POLE=1
verdict "151b what the program reports, and reports again" "$POLE" "$FIRST -> $SECOND"

# The spinner mark comes off. A vendor that animates its title must not make
# the rail's name twitch with the animation.
send 'text printf "\033]0;\342\234\263 Marked\007"'; send "key return"; sleep 1.5
dump
POLE=0; [ "$(title)" = "Marked" ] || POLE=1
verdict "151c the animation mark is not part of the name" "$POLE" "title=$(title)"

if [ "$WITH_CLAUDE" = "1" ] && command -v claude >/dev/null 2>&1; then
  echo "==> the repair itself: two topics in one chat"
  # A scratch folder, not the repo. Started here, `claude` picks up this
  # project's own instructions and hooks, and on 2026-08-23 that put it four
  # minutes into a launch with nothing drawn — the poles below then read as a
  # title that would not move, when what had not moved was the agent. The
  # thing being measured is a name, not a startup.
  # A FIXED name, shared with bench-pure-chat. A folder claude has never seen
  # is one it asks about, and answering that writes an entry into the
  # principal's own `~/.claude.json` — with a name stamped by the process id
  # that is a new dead entry every single run. One folder, trusted once, reused
  # for ever (ISC-132).
  CHATDIR="$HOME/Movies/t4a-bench-chat"
  mkdir -p "$CHATDIR"
  send "text cd $CHATDIR && claude"; send "key return"
  # A folder claude has never seen is a folder it asks about first, and the
  # trust question does not contain the hint line — so waiting for the hint
  # line alone waits for ever while the agent sits there, up, asking. Measured
  # 2026-08-23: ninety seconds of "claude never came up" with claude on the
  # screen. The question is answered the way a person answers it.
  if wait_for_screen "trust" 40; then
    echo "      (a folder claude has never seen: answering its trust question)"
    # Answered until it is GONE. The needle matches as soon as the first
    # characters land, which can be before the box is taking keys, and a
    # single Return then vanishes into a dialog that is still drawing.
    for _ in 1 2 3; do
      sleep 3; send "key return"; sleep 3
      dump
      if ! /usr/bin/python3 -c '
import json, sys
tabs = json.load(open(sys.argv[1]))["tabs"]
panes = [q for t in tabs for q in t["panes"] if q.get("active")] \
        or [q for t in tabs for q in t["panes"]]
for pane in panes:
    screen = pane.get("screen") or ""
    if "trust" in ("\n".join(screen) if isinstance(screen, list) else str(screen)):
        sys.exit(0)
sys.exit(1)
' "$DUMP"; then break; fi
    done
  fi
  if ! wait_for_screen "auto mode on" 90; then
    # NOT a failure of the claim. An agent that never came up and a name that
    # never changed are the same screen from outside, and reporting the second
    # when it was the first is how a bench sends someone to look for a defect
    # in the wrong place.
    echo "      claude never came up: poles 151d-f NOT RUN (not a verdict on the claim)"
    send "key ctrl-c"; sleep 1; send "key ctrl-c"; sleep 1
    STATUS=1
    CHATDIR=""
  fi
fi
if [ -n "${CHATDIR:-}" ]; then
  sleep 2; dump
  AT_REST="$(title)"
  echo "      claude at rest, no turn yet: $AT_REST"

  send 'text name three italian rivers'; sleep 0.6; send "key return"
  ONE="$(wait_title_change "$AT_REST" 90 || true)"
  echo "      after the first question:     $ONE"

  send 'text now something else entirely: what is a barometer'; sleep 0.6; send "key return"
  TWO="$(wait_title_change "$ONE" 90 || true)"
  echo "      after the second, on another topic: $TWO"
  POLE=0
  { [ "$ONE" != "$AT_REST" ] && [ "$TWO" != "$ONE" ] && [ -n "$TWO" ]; } || POLE=1
  verdict "151d the name follows the conversation" "$POLE" "$AT_REST -> $ONE -> $TWO"
  shoot "f9-151-title-updates.png"

  # THE pole this claim turns on. `claude` writes the session's name into the
  # terminal title once — one `ai-title` record per session, computed from the
  # first exchange and never rewritten — so a pane that repeated the title
  # verbatim would still be saying `$ONE` here. That it says something else is
  # the whole repair.
  POLE=0
  /usr/bin/python3 -c "
import sys
one, two = '''$ONE''', '''$TWO'''
print('      the vendor would still be saying %r; the pane says %r' % (one, two))
sys.exit(0 if two and two != one else 1)
" || POLE=$?
  verdict "151e and it is not the first topic any more" "$POLE" "the defect he reported"

  echo "==> and when the chat ends, its name ends with it"
  send "key ctrl-c"; sleep 1; send "key ctrl-c"; sleep 2
  send 'text exit'; send "key return"; sleep 4
  dump
  AFTER="$(title)"
  POLE=0
  { [ "$AFTER" != "$TWO" ] && [ "$AFTER" != "$ONE" ] && [ -n "$AFTER" ]; } || POLE=1
  verdict "151f a dead chat's name is not left on a live pane" "$POLE" \
    "$TWO -> $AFTER"
  # `$CHATDIR` stays: it is trusted once and reused, which is the whole reason
  # it has a fixed name.
fi

t4a_stop_bench
rm -f "$FIFO"
[ "$STATUS" = "0" ] && echo "sessions: every pole held" || echo "sessions: a pole FAILED"
exit "$STATUS"
