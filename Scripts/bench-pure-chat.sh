#!/bin/bash
# ISC-114 — «pure chat», EXPERIMENTAL: T4A covers the input box the hosted
# agent drew for itself, and uncovers it the moment the agent asks something.
#
#   Scripts/bench-pure-chat.sh [--with-claude] [app-bundle]
#
# Every pole starts from a VIRGIN configuration directory. The claim of this
# feature is mostly a claim about its DEFAULT — that a principal who never
# hears of it is unaffected — and a default is only visible where no file on
# disk has an opinion.
#
# What is read back is the app's own report of the cover (armed, covering,
# the rows it is over, its height in points, the reason when it covers
# nothing, and the reveal latency in milliseconds) rather than a look at a
# picture. The pictures are taken too, but they are evidence for a person,
# not the measurement.
#
#   1. flag off, bare shell               nothing covered, and the flag is off
#  1b. the switch in the preferences      turns it on, and writes it down
#  1c. the same switch again             turns it off
#   2. flag ON, bare shell                still nothing: no agent, no cover
#   3. flag off, `claude` alive at rest   nothing covered  <- THE ANTI-POLE
#   4. flag ON, `claude` alive at rest    the box is covered, photographed
#   5. a menu opens over the resting box  UNCOVERED, and how fast
#   6. the menu goes                      the cover comes back
#   7. a line typed in T4A's own bubble   reaches the agent's real prompt
#   8. a real numbered selector           uncovered, photographed
#
# Poles 3-8 need a live agent and only run with --with-claude. Poles 1-2 are
# the ones that guard the principal who never switches this on, so they run
# always.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

WITH_CLAUDE=0
if [ "${1:-}" = "--with-claude" ]; then WITH_CLAUDE=1; shift; fi
APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-pure-chat.fifo"
CONFIG_HOME="/tmp/t4a-pure-chat-config"
DUMP=/tmp/t4a-pure-chat-dump.json
SHOTS=design/evidence
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  rm -f "$DUMP"; send "dump $DUMP"
  for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done
}

# Reads one pole: expected enabled and expected covering, each "yes"/"no"/"any".
# Prints what the app actually said, always — including the reason it gave for
# covering nothing, because "covered nothing" and "never looked" are the same
# shape from outside and only one of them is a defect.
pole() {
  local name="$1" want_enabled="$2" want_covering="$3"
  dump
  local line
  line="$(/usr/bin/python3 -c "
import json
p = json.load(open('$DUMP'))['pureChat']
print('%s|%s|%s|%s|%s|%s|%s' % (
    'yes' if p.get('enabled') else 'no',
    'yes' if p.get('armed') else 'no',
    'yes' if p.get('covering') else 'no',
    p.get('rows', 0),
    round(float(p.get('heightPoints', 0)), 1),
    p.get('flips', 0),
    (p.get('reason') or '-')[:52]))
")"
  local enabled armed covering rows height flips reason
  IFS='|' read -r enabled armed covering rows height flips reason <<<"$line"
  local verdict="ok"
  [ "$want_enabled" = "any" ] || [ "$enabled" = "$want_enabled" ] || verdict="FAILED"
  [ "$want_covering" = "any" ] || [ "$covering" = "$want_covering" ] || verdict="FAILED"
  # A cover that claims no rows and no height is not a cover.
  if [ "$covering" = "yes" ] && { [ "$rows" = "0" ] || [ "${height%.*}" = "0" ]; }; then
    verdict="FAILED"
  fi
  # Nothing covered must always come with a reason: a silent branch and a
  # branch that never ran are indistinguishable.
  if [ "$covering" = "no" ] && [ "$reason" = "-" ]; then verdict="FAILED"; fi
  printf '%-36s on=%-3s armed=%-3s covering=%-3s rows=%-2s h=%-6s flips=%-2s %s\n' \
    "$name" "$enabled" "$armed" "$covering" "$rows" "$height" "$flips" "$verdict"
  [ "$covering" = "no" ] && printf '%-36s   because: %s\n' "" "$reason"
  [ "$verdict" = "ok" ] || STATUS=1
}

# What the cover is actually over, read out of the dump: the rows under the
# patch, so the claim "it covers the prompt" can be checked and not believed.
covered_text() {
  /usr/bin/python3 -c "
import json
p = json.load(open('$DUMP'))['pureChat']
for row in p.get('coveredText', []):
    print('      | %s' % row)
print('      marker %r on row %s, rows %s-%s' % (
    p.get('marker'), p.get('markerRow'), p.get('topRule'), p.get('bottomRule')))
" 2>/dev/null || true
}

# Waits until the pane's screen contains a string, or gives up. The poles below
# used to wait a fixed fourteen seconds for `claude` to come up; on a loaded
# machine it sometimes had not drawn a thing by then, and the bench reported the
# feature broken when what it had photographed was a bare shell prompt
# (2026-08-21). A clock is not a precondition — the screen is.
#
# What is waited FOR is deliberately never the thing being claimed: the hint
# line `auto mode on` sits OUTSIDE the input box, and the unit test
# `theRestingHintIsNotAFooter` is there to keep it that way.
wait_for_screen() {
  local needle="$1" limit="${2:-45}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    dump
    # The needle goes in as an ARGUMENT, never spliced into the source. The
    # first version of this pasted it between quotes inside the program text;
    # the quotes were lost on the way to disk, every run raised SyntaxError,
    # and a `2>/dev/null` turned that into a patient, permanent "not yet".
    # The bench then waited the full minute and declared a healthy app broken.
    # Errors are left LOUD here for the same reason.
    if /usr/bin/python3 -c '
import json, sys
needle = sys.argv[2]
tabs = json.load(open(sys.argv[1]))["tabs"]
panes = [q for t in tabs for q in t["panes"] if q.get("active")]
panes = panes or [q for t in tabs for q in t["panes"]]
for pane in panes:
    screen = pane.get("screen") or ""
    text = "\n".join(screen) if isinstance(screen, list) else str(screen)
    if needle in text:
        sys.exit(0)
sys.exit(1)
' "$DUMP" "$needle"; then
      echo "      (the pane showed \"$needle\" after ~${waited}s)"
      return 0
    fi
    sleep 2; waited=$((waited + 2))
  done
  echo "      GAVE UP waiting for \"$needle\" after ${limit}s"
  STATUS=1
  return 1
}

# The same look, without the verdict. `wait_for_screen` marks the run FAILED
# when it gives up, which is right for a screen the bench needs and wrong for
# one it is only asking about: the trust question appears on the FIRST run in a
# folder and never again, so its absence is the normal case, and reporting it
# as a failure made a green bench print "a pole FAILED".
maybe_screen() {
  local needle="$1" limit="${2:-20}" waited=0
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

launch() {
  t4a_stop_bench
  sleep 1.5
  rm -f "$FIFO"
  open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "test channel never appeared" >&2; exit 1; }
  sleep 3
}

shoot() {
  local name="$1"
  mkdir -p "$SHOTS"
  local wid
  wid="$(.build/t4a-winid 2>/dev/null || { swiftc -O Scripts/winid.swift -o .build/t4a-winid && .build/t4a-winid; })"
  if [ -n "$wid" ]; then
    screencapture -x -o -l "$wid" "$SHOTS/$name"
    echo "      photographed: $SHOTS/$name"
  else
    echo "      no window id: no photograph taken"; STATUS=1
  fi
}

rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME"
echo "==> virgin config: $CONFIG_HOME (no config.toml)"
launch
ls "$CONFIG_HOME/t4a/config.toml" >/dev/null 2>&1 \
  && echo "note: a config file exists already: $(cat "$CONFIG_HOME/t4a/config.toml")" \
  || echo "no config file on disk: what follows is the compiled default"

# ON out of the box since ISC-150, so this pole reads the other way round: what
# a person gets with no configuration at all is the experiment RUNNING. Nothing
# is covered yet, because there is no agent in the pane to have a prompt.
pole "1 the compiled default is ON, bare shell" yes no

# The flag has to be reachable WHERE THE CLAIM SAYS IT IS — a switch in the
# preferences — and not only through a verb on the test channel. A feature
# whose only door is the bench is a feature the principal does not have. The
# direction is off-then-on now that on is the default: what has to be provable
# is that the switch WORKS, and a switch is only proved by both of its throws.
echo "==> the switch in the preferences, pressed the way a person presses it"
send "settings Layout"; sleep 1.5
send "toggle Pure chat"; sleep 1
pole "1b the preferences switch turns it OFF" no no
grep -q 'pure-chat = false' "$CONFIG_HOME/t4a/config.toml" \
  && echo "      and it is written down: $(grep 'pure-chat' "$CONFIG_HOME/t4a/config.toml")" \
  || { echo "      FAILED: nothing was written to config.toml"; STATUS=1; }
send "toggle Pure chat"; sleep 1
pole "1c and the same switch turns it back ON" yes no
send "settings close"; sleep 0.5

send "pure-chat on"; sleep 0.8
pole "2 flag ON, bare shell" yes no
send "pure-chat off"; sleep 0.5

if [ "$WITH_CLAUDE" = "1" ]; then
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude is not on PATH: the live poles were NOT run"
    STATUS=1
  else
    echo "==> the real thing: claude in the pane"
    # A scratch folder, not this repo. Started in the project itself, `claude`
    # picks up the project's instructions and whatever else the machine hangs
    # off a session start, and on 2026-08-23 that was sixty-eight seconds with
    # nothing drawn — poles 4 to 8 then reported pure chat as broken when what
    # had not happened was the agent. This bench measures a cover, not a
    # startup, so it stops paying for one.
    # A scratch folder with a FIXED name, not one stamped with the process id.
    #
    # Two things had to be true at once and only this shape gives both. It must
    # not be the project, because `claude` started in here spends more than a
    # minute before drawing anything (measured 2026-08-23: `WORKER cd · 68s`
    # with an empty screen) and poles 4 to 8 then report a cover that never
    # happened. And it must not be a NEW folder every run: a new folder is one
    # claude has never seen, so it asks whether to trust it, and answering that
    # writes an entry into the principal's own `~/.claude.json` — three of them
    # accumulated on 2026-08-23 before the guard below caught it.
    #
    # A fixed folder is trusted once, ever, and every run after that walks
    # straight to a prompt. The real configuration stays in force, which is
    # what keeps the agent LOGGED IN: `CLAUDE_CONFIG_DIR` moves the credential
    # lookup as well as the bookkeeping, and a logged-out claude draws a
    # different screen — a hint inside the input box, which this feature
    # correctly refuses to cover, so the bench measured the login and called it
    # a broken cover. Pole 10 is the one that WANTS the dialog and it gets its
    # own isolated configuration down there.
    CHATDIR="$HOME/Movies/t4a-bench-chat"
    mkdir -p "$CHATDIR"
    send "text cd $CHATDIR && claude"; send "key return"
    if maybe_screen "trust" 25; then
      echo "      (first ever run in $CHATDIR: answering its trust question once)"
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
      echo "      claude never came up: the live poles are NOT a verdict on the claim"
      STATUS=1
    fi
    sleep 2

    pole "3 flag off, claude at rest" no no

    send "pure-chat on"; sleep 1
    send "scan"; sleep 0.5
    pole "4 flag ON, claude at rest" yes yes
    covered_text
    shoot "f5-114-pure-chat-covered.png"
    # The same screen under the name ISC-150 asks for: this is what he sees now
    # that the mode is the default — the agent's own input line gone, T4A's
    # bubble the only place to type.
    shoot "f9-150-pure-chat.png"

    # A menu over the resting box. The slash list is drawn ABOVE the box and
    # puts what was typed INSIDE it, which is a shape the F4 card scanner
    # never sees — so this pole is also the one that proves the cover does not
    # rely on that scanner alone.
    echo "==> a menu opens over the covered box"
    send "text /"; sleep 1.2
    pole "5 flag ON, the slash list is open" yes no
    /usr/bin/python3 -c "
import json
p = json.load(open('$DUMP'))['pureChat']
ms = p.get('lastRevealMillis')
if ms is None:
    print('      reveal latency: NOT MEASURED'); raise SystemExit(1)
print('      reveal latency: %.1f ms (budget 200)' % ms)
raise SystemExit(0 if ms < 200 else 1)
" || { echo "      reveal latency FAILED"; STATUS=1; }
    shoot "f5-114-pure-chat-revealed-slash.png"

    # Backspace, not escape: escape closes the list but leaves the `/` sitting
    # in the box, and a box with text in it is a box this feature never covers.
    # Measured 2026-08-21 — with escape the cover correctly stayed away and the
    # pole read as a failure of the feature when it was a failure of the bench.
    send "key backspace"; sleep 1.2
    pole "6 the slash list is gone" yes yes

    # A REAL numbered selector of the agent's own, opening over a box that is
    # covered at that moment — so this pole measures the transition that
    # matters and not just an end state.
    #
    # `/model` rather than the workspace-trust question, and the reason is
    # worth keeping: trust is asked ONCE per folder, so a bench built on it
    # passes the first time and then quietly measures nothing. Watched doing
    # exactly that on 2026-08-21 — a fresh directory under $HOME drew the
    # dialog on one run and, minutes later, went straight to a resting prompt
    # on the next. `/model` opens every time, costs no model call, and Esc
    # closes it without changing a setting.
    echo "==> a real numbered selector: /model, over a covered box"
    send "text /model"; send "key return"
    wait_for_screen "Select model" 30 || true
    send "scan"; sleep 0.5
    pole "7 flag ON, a real selector" yes no
    /usr/bin/python3 -c "
import json, sys
p = json.load(open('$DUMP'))['pureChat']
why = p.get('reason') or ''
ms = p.get('lastRevealMillis')
print('      the reason given: %r' % why)
print('      reveal latency: %s ms (budget 200)' % ('%.1f' % ms if ms is not None else 'NOT MEASURED'))
sys.exit(0 if ('selector' in why and ms is not None and ms < 200) else 1)
" || { echo "      FAILED: not the selector path, or outside its budget"; STATUS=1; }
    shoot "f5-114-pure-chat-revealed.png"
    # The photograph and the measurement must be of the SAME screen. A window
    # that is not frontmost can hand back a stale frame, and a picture of a
    # state that has already gone is evidence of nothing.
    pole "7b still uncovered when photographed" yes no

    send "key escape"; sleep 1.5
    pole "8 the selector is gone" yes yes

    # LAST, because it is the only pole that changes what is on the screen:
    # `/help` leaves a panel behind that swallows the next keystrokes, and
    # running it earlier stopped `/model` from ever opening (2026-08-21).
    # `/help` is chosen because `claude` runs it locally, so delivery is
    # proved without spending a model call on a bench.
    echo "==> a line typed in T4A's own bubble"
    send "compose /help"; sleep 4
    dump
    if /usr/bin/python3 -c '
import json, sys
tabs = json.load(open(sys.argv[1]))["tabs"]
panes = [q for t in tabs for q in t["panes"] if q.get("active")]
panes = panes or [q for t in tabs for q in t["panes"]]
def text(pane):
    screen = pane.get("screen") or ""
    return "\n".join(screen) if isinstance(screen, list) else str(screen)
lines = "\n".join(text(q) for q in panes).splitlines()
# A count alone cannot tell "absent" from "present but wrong", so the lines
# that matched are PRINTED and the verdict can be read by a person.
hits = [l.strip()[:70] for l in lines
        if any(w in l.lower() for w in ("/help", "usage", "shortcut", "available commands"))]
for h in hits[:6]:
    print("      found: %s" % h)
sys.exit(0 if hits else 1)
' "$DUMP"; then
      echo "9 the bubble reaches the agent      ok"
    else
      echo "9 the bubble reaches the agent      FAILED (agent shows no sign of it)"
      STATUS=1
    fi

    # ==================================================================
    # The third shape of a menu, and the one that matters most: a real
    # PERMISSION (ISC-150).
    #
    # Poles 5 and 7 are a completion list and a settings selector. Neither is
    # a question put to a person about something irreversible, and that is the
    # case this feature could do real harm in: covering a permission means the
    # agent is waiting for an answer nobody can see it wants. Two shapes are
    # not three, and the default cannot move on two.
    #
    # The workspace-trust question is used because it is a permission that
    # costs no model call. The note at pole 7 is right that it is asked once
    # per folder — so it is made repeatable rather than avoided: a folder made
    # fresh every run, and claude's own bookkeeping pointed at a directory of
    # ours that is deleted first (ISC-132: the real `~/.claude.json` is not
    # touched, and the checksum below says so instead of promising it).
    echo "==> the third shape: a REAL permission, in a folder claude has never seen"
    # This pole, and only this pole, runs under a configuration of ours: it is
    # the one that answers a trust question, so it is the one that would write
    # into the principal's file. The copy is the real config MINUS `projects`,
    # which is where trust lives — built from nothing, claude reads it as a
    # machine that never logged in (bench-card, 22/08). The checksum is taken
    # HERE rather than at the top of the bench, because poles 3-9 above run
    # under the real configuration on purpose and the first ever run of them
    # legitimately trusts one folder, once.
    CLAUDE_HOME="/tmp/t4a-pure-chat-claude"
    REAL_CLAUDE_CONFIG="$HOME/.claude.json"
    BEFORE_REAL="$(shasum -a 256 "$REAL_CLAUDE_CONFIG" 2>/dev/null | cut -d' ' -f1)"
    rm -rf "$CLAUDE_HOME"; mkdir -p "$CLAUDE_HOME"; chmod 700 "$CLAUDE_HOME"
    /usr/bin/python3 Scripts/claude-config-copy.py \
      "$REAL_CLAUDE_CONFIG" "$CLAUDE_HOME/.claude.json"
    # A folder claude has never seen, under $HOME like bench-card's — and NOT
    # by overriding HOME, which would take the shell's own rc file away and
    # with it the PATH `claude` is on.
    WORK="$HOME/Movies/t4a-pure-chat-$$-$(date +%H%M%S)"
    mkdir -p "$WORK"

    t4a_stop_bench
    sleep 1.5
    rm -f "$FIFO"
    open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" \
      --env XDG_CONFIG_HOME="$CONFIG_HOME" \
      --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME"
    for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
    sleep 3
    send "pure-chat on"; sleep 0.8
    send "text cd $WORK && claude"; send "key return"
    # Waited for by the words of the question, never by a clock: a pole that
    # measures a screen the question has not reached yet is a green light
    # wired to nothing.
    if wait_for_screen "trust" 60; then
      send "scan"; sleep 0.5
      pole "10 flag ON, a real permission" yes no
      /usr/bin/python3 -c "
import json, sys
d = json.load(open('$DUMP'))
p = d['pureChat']
why = p.get('reason') or ''
print('      the reason given: %r' % why)
print('      and the recogniser called it: %r' % d.get('selector', {}).get('kind'))
sys.exit(0 if why else 1)
" || { echo "      FAILED: nothing covered and no reason given"; STATUS=1; }
      shoot "f9-150-pure-chat-permission.png"
    else
      echo "      the trust question never appeared: pole 10 NOT run"
      STATUS=1
    fi
    # The guard, pointed at the question the isolation is FOR.
    #
    # A whole-file checksum is the wrong metre here and was measured being
    # wrong on 2026-08-23: a running `claude` writes its own bookkeeping —
    # `lastCost`, `lastDuration`, `lastSessionId` — into `~/.claude.json` as it
    # goes and as it dies, so poles 3-9, which use the real configuration on
    # purpose, change that file no matter what this bench does. Comparing the
    # file therefore reports a failure on every run and stops meaning anything.
    #
    # What the isolation promises is narrower and checkable: the folder THIS
    # pole handed trust to must not appear in the principal's own file. That is
    # the write the bench would otherwise be making, and it is the only one.
    POLE=0
    /usr/bin/python3 -c "
import json, sys
real = json.load(open('$REAL_CLAUDE_CONFIG')).get('projects', {})
leaked = [k for k in real if k == '$WORK']
ours = json.load(open('$CLAUDE_HOME/.claude.json')).get('projects', {})
print('      the folder is trusted in OUR config: %s' % ('$WORK' in ours))
print('      and absent from the real one       : %s' % (not leaked))
sys.exit(1 if leaked else 0)
" || POLE=$?
    if [ "$POLE" = "0" ]; then
      echo "      the trust this pole gave went to the bench's copy, not to his"
    else
      echo "      FAILED: the bench wrote a folder into the real ~/.claude.json"
      STATUS=1
    fi
    # The copy carries the user's own account data: it goes when the bench
    # does. `$CHATDIR` stays: it is trusted once and reused, which is the whole
    # reason it has a fixed name.
    rm -rf "$WORK" "$CLAUDE_HOME"
  fi
fi

t4a_stop_bench
rm -f "$FIFO"
[ "$STATUS" = "0" ] && echo "pure chat: every pole held" || echo "pure chat: a pole FAILED"
exit "$STATUS"
