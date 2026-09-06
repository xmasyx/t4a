#!/bin/bash
# Parte 10 — the round of defects he found using the app on 23/08 evening.
#
#   Scripts/bench-f10.sh [section] [app-bundle]
#   sections: alarm ladder close settings layout bubble agentbubble all
#             (default all)
#
# Sections and what each one is a claim about:
#
#   alarm    ISC-152 — a warning wears a mark, and a calm row wears nothing.
#   ladder   ISC-153 — live/used/dim are three colours, and `used` is not the
#            brightest thing on the bar. ISC-160 rides here: the cross-vendor
#            rungs are the same three states drawn by the same code.
#   close    ISC-154 — the × on a rail row is there without the pointer, and
#            the turn count never lands on it.
#   settings ISC-155 — the panel opens on the window that opened it, wherever
#            that window is, and remembers where it was put.
#   layout   ISC-156 — the fourth glyph points at where the sessions would GO,
#            and says so in words; the dead switch beside it is gone.
#   agentbubble ISC-174 — la bolla compare SOLO dove c'è un agente connesso.
#            Quattro poli letti dal dump più il giro del file.
#   bubble   ISC-158/159 — the keyboard stays in the bubble while the agent's
#            own line is covered, ⇧↩ makes a line and ↩ sends. With
#            --with-claude it runs against a real agent, which is the only
#            place ISC-157 can be measured at all.
#
# Every pole runs under its own XDG_CONFIG_HOME. Nothing here touches
# ~/.config/t4a/config.toml (ISC-132).

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

WITH_CLAUDE=0
if [ "${1:-}" = "--with-claude" ]; then WITH_CLAUDE=1; shift; fi
SECTION="${1:-all}"
APP="${2:-dist/T4A.app}"
FIFO="/tmp/t4a-f10.fifo"
CONFIG_HOME="/tmp/t4a-f10-config"
CONFIG="$CONFIG_HOME/t4a/config.toml"
DUMP=/tmp/t4a-f10-dump.json
BIN=/tmp/t4a-f10-bin
SHOTS=design/evidence
STATUS=0

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

for tool in movepoint clickpoint dragpoint keypress winid winframe; do
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
  printf '%-54s %-28s (want %s) %s\n' "$name" "$got" "$want" "$mark"
}
note() { printf '%-54s %s\n' "$1" "$2"; }
# For the readings that need more than one statement. `field` wraps its
# argument in a print(), which a for-loop cannot live inside — three poles
# came out as SyntaxError and were reported as failures of the app.
prog() { /usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
$1
"; }

stop() { t4a_stop_bench; sleep 1.5; rm -f "$FIFO"; }
launch() {
  rm -f "$FIFO"
  open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME" "$@"
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
  sleep 3
}
shoot() {
  mkdir -p "$SHOTS"
  local wid; wid="$(.build/t4a-winid 2>/dev/null || true)"
  if [ -n "$wid" ]; then
    screencapture -x -o -l "$wid" "$SHOTS/$1"; note "      photographed" "$SHOTS/$1"
  else
    note "      no window id" "no photograph taken"; STATUS=1
  fi
}

fresh_config() { rm -rf "$CONFIG_HOME"; mkdir -p "$CONFIG_HOME/t4a"; }

# A provider written by this bench, so what is measured is the contract and
# not one particular program.
#
# OGNUNO EMETTE UNA RIGA `session`, ed è una ribasatura del 25/08, non un
# ornamento. Con ISC-173 la barra disegna solo su un pannello CONNESSO, e un
# fornitore che non ha riconosciuto la sessione descrive per definizione un
# pannello a cui non è attaccato nessuno: le sue righe parlano della macchina,
# non di quel riquadro. I poli qui sotto riguardano come una barra connessa
# DISEGNA — il marchio dell'allarme, i tre colori della scala — quindi il loro
# apparecchio deve rappresentare un pannello connesso, o misurerebbero il
# cancello invece del disegno. `session` è la riga che solo un riconoscimento
# esatto produce, cioè esattamente il segno che il cancello cerca.
mkdir -p "$BIN"
cat > "$BIN/loud.sh" <<'EOF'
#!/bin/bash
echo "#name	session	Session title"
printf 'session	bench	accent\n'
echo "#name	weather	Weather"
printf 'weather\tSTORM\tcritical\n'
printf 'weather\t102%%\tcritical\n'
EOF
cat > "$BIN/calm.sh" <<'EOF'
#!/bin/bash
echo "#name	session	Session title"
printf 'session	bench	accent\n'
echo "#name	weather	Weather"
printf 'weather\tCLEAR\tok\n'
printf 'weather\t4%%\tok\n'
EOF
# The ladder, in the three states, plus the two cross-vendor rungs (ISC-160).
cat > "$BIN/ladder.sh" <<'EOF'
#!/bin/bash
echo "#name	session	Session title"
printf 'session	bench	accent\n'
echo "#name	active	Active models (ladder)"
printf 'active\tACTIVE\tmuted\n'
printf 'active\tHAIKU\tdim\n'
printf 'active\tSONNET\tused\n'
printf 'active\tOPUS\tlive\n'
printf 'active\tFABLE\tdim\n'
printf 'active\t│\tdim\n'
printf 'active\tMAX\tdim\n'
printf 'active\tSOL\tlive\n'
printf 'active\tGEMINI\tused\n'
EOF
chmod +x "$BIN"/*.sh

# ==================================================================== alarm
if [ "$SECTION" = "alarm" ] || [ "$SECTION" = "all" ]; then
  echo "==> ISC-152 · a warning is marked as one"
  fresh_config
  launch
  send "facts $BIN/loud.sh"; sleep 3
  dump
  verdict "152a the complaining row is on the bar" \
    "$(field "'yes' if 'fact-weather' in d['dash']['painted'] else 'no'")" "yes"
  # Switched OFF, and it comes back — ISC-146, which must not change.
  send "settings Dashboard rows"; sleep 1.2
  send "toggle Weather"; sleep 1.2
  send "settings close"; sleep 0.8
  dump
  verdict "152b switched off, it is still on the bar" \
    "$(field "'yes' if 'fact-weather' in d['dash']['off'] and 'fact-weather' in d['dash']['alarms'] else 'no'")" "yes"
  verdict "152c and it wears the mark" \
    "$(field "d['dash']['alarmLabels'][0] if d['dash']['alarmLabels'] else '(none)'")" "!"
  note "      painted" "$(field "d['dash']['painted'].get('fact-weather')")"
  note "      inks" "$(field "d['dash']['inks'].get('fact-weather')")"
  shoot "f10-152-warning-is-marked.png"
  # THE NEGATIVE POLE: the same row, switched off, with nothing to complain
  # about. No lane, no mark, nothing on the bar — otherwise the mark above is
  # a mark this bench would have found on anything.
  send "facts $BIN/calm.sh"; sleep 4
  dump
  verdict "152d calm and off: no lane at all" \
    "$(field "len(d['dash']['alarms'])")" "0"
  verdict "152e calm and off: nothing on the bar" \
    "$(field "'yes' if 'fact-weather' in d['dash']['painted'] else 'no'")" "no"
  stop
fi

# =================================================================== ladder
if [ "$SECTION" = "ladder" ] || [ "$SECTION" = "all" ]; then
  echo "==> ISC-153 · three states, three colours — and ISC-160 with them"
  fresh_config
  launch
  send "facts $BIN/ladder.sh"; sleep 3
  dump
  note "      painted" "$(field "d['dash']['painted'].get('fact-active')")"
  note "      tones" "$(field "d['dash']['tones'].get('fact-active')")"
  note "      inks" "$(field "d['dash']['inks'].get('fact-active')")"
  # The colours, read once out of the drawing and handed back as one line, so
  # every verdict below is a comparison and not a second reading.
  LADDER="$(/usr/bin/python3 -c "
import json
d = json.load(open('$DUMP'))
pairs = d['dash']['tones']['fact-active']
inks = dict(zip([t[0] for t in pairs], d['dash']['inks']['fact-active']))
print('|'.join([
    str(len(set([inks['OPUS'], inks['SONNET'], inks['HAIKU']]))),
    'same' if inks['SONNET'] == inks['OPUS'] else 'different',
    'same' if inks['SONNET'] == inks['HAIKU'] else 'different',
    'ink' if inks['SONNET'].upper() == '#EDECEC' else 'not-ink',
    inks['OPUS'].upper(),
    'same' if inks['SOL'] == inks['OPUS'] else 'different',
    'same' if inks['GEMINI'] == inks['SONNET'] else 'different',
    'same' if inks['MAX'] == inks['HAIKU'] else 'different',
]))
")"
  IFS='|' read -r L_DISTINCT L_USED_LIVE L_USED_DIM L_BRIGHT L_ACCENT \
                 L_SOL L_GEMINI L_MAX <<<"$LADDER"
  verdict "153a live, used and dim are three colours" "$L_DISTINCT" "3"
  verdict "153b used is not the colour of live" "$L_USED_LIVE" "different"
  verdict "153c used is not the colour of dim" "$L_USED_DIM" "different"
  # The one that would have caught the defect: `used` used to resolve to the
  # brightest text this bar draws, which is what made a rung nobody switched on
  # read as switched on. `#EDECEC` is the black theme's `ink`.
  verdict "153d used is NOT the bar's brightest ink" "$L_BRIGHT" "not-ink"
  verdict "153e live is the accent" "$L_ACCENT" "#4582BF"
  # ISC-160: the cross-vendor rungs are the same three states, drawn by the
  # same code. A worker of another vendor lights up exactly as OPUS does.
  verdict "160a SOL live is drawn as live" "$L_SOL" "same"
  verdict "160b GEMINI used is drawn as used" "$L_GEMINI" "same"
  verdict "160c MAX dim is drawn as dim" "$L_MAX" "same"
  shoot "f10-153-ladder-three-states.png"
  stop
fi

# ==================================================================== close
if [ "$SECTION" = "close" ] || [ "$SECTION" = "all" ]; then
  echo "==> ISC-154 · the × is there before you look for it"
  fresh_config
  printf 'layout-sessions = rail\nshow-sessions-panel = true\n' > "$CONFIG"
  launch
  # The pointer is put somewhere that is NOT the rail, on purpose: the whole
  # claim is that the × does not need it.
  .build/t4a-movepoint 1200 700; sleep 1
  send "newtab"; sleep 2
  send "text echo one"; send "key return"; sleep 1.5
  dump
  verdict "154a every rail row shows a ×, pointer away" \
    "$(field "'yes' if d['rail']['rows'] and all(r['showingClose'] for r in d['rail']['rows']) else 'no'")" "yes"
  note "      rows" "$(field "len(d['rail']['rows'])")"
  # And the count is still drawn, beside it and never under it.
  verdict "154b the count and the × do not overlap" \
    "$(prog "
bad = []
for r in d['rail']['rows']:
    c, x = r.get('countLocal'), r.get('closeLocal')
    if c and x and c['x'] + c['w'] > x['x']:
        bad.append(r['title'])
print('overlap:' + ','.join(bad) if bad else 'clear')
")" "clear"
  note "      one row's boxes" "$(field "str((d['rail']['rows'][0].get('countLocal'), d['rail']['rows'][0].get('closeLocal')))")"
  shoot "f10-154-close-always-there.png"
  # The negative pole is not "a row without a ×" — there is none any more —
  # but the guard behind it: with the rail switched off, no row draws one,
  # because there are no rows.
  send "layout tabs"; sleep 1.5
  dump
  verdict "154c no rail, no × (the rows are gone)" \
    "$(field "len(d['rail']['rows']) if not d['rail']['hidden'] else 0")" "0"
  stop
fi

# ================================================================= settings
if [ "$SECTION" = "settings" ] || [ "$SECTION" = "all" ]; then
  echo "==> ISC-155 · the panel opens on the window that opened it"
  fresh_config
  launch
  # Smaller than the screen first, on purpose. A window the full width of the
  # display can only be at x=0, so «three positions» would be one position
  # three times — and a panel centred on a window that hangs off the right of
  # the screen is pushed back on by the guard in `place`, which is right and
  # would read here as the centring failing.
  send "resize 1000x700"; sleep 1.2
  # Three real positions. `movewindow` takes an ORIGIN and nothing else — the
  # first version of this pole handed it four numbers, the verb refused all
  # four, and the same window position was measured three times and called
  # three positions.
  for spot in "40,60" "460,60" "240,200"; do
    send "movewindow $spot"; sleep 1.2
    send "settings close"; sleep 0.6
    send "settings open"; sleep 1.2
    dump
    # Not «the centre falls inside the window»: the panel is 820 points wide
    # inside a window of 1512, so a panel that never moved at all lands inside
    # a window that did — which is how the first version of this pole passed
    # three times while measuring one position. The two centres have to MEET.
    verdict "155a opened on the main window at $spot" \
      "$(prog "
s, o = d['settings']['settings'], d['settings']['owner']
print('centred' if abs(s['cx'] - o['cx']) < 2 and abs(s['cy'] - o['cy']) < 2
      else 'off by %d,%d' % (s['cx'] - o['cx'], s['cy'] - o['cy']))
")" "centred"
    note "      settings" "$(field "str(d['settings']['settings'])")"
    note "      owner" "$(field "str(d['settings']['owner'])")"
  done
  verdict "155b it wears the app's titlebar" \
    "$(field "'yes' if d['settings']['titlebarTransparent'] else 'no'")" "yes"
  # Moved BY HAND — a real press, drag and release on the titlebar — and then
  # closed and opened again. A programmatic `setFrame` was the first version
  # of this pole and it moved the window without ever telling the delegate,
  # which is a gesture no person can make.
  send "settings close"; sleep 0.6
  send "settings open"; sleep 1.2
  dump
  SX="$(field "d['settings']['settings']['x']")"
  SY="$(field "d['settings']['settings']['y']")"
  SW="$(field "d['settings']['settings']['w']")"
  SH="$(field "d['settings']['settings']['h']")"
  GRAB_X="$(/usr/bin/python3 -c "print(int($SX + $SW / 2))")"
  GRAB_Y="$(/usr/bin/python3 -c "print(int($SY + $SH - 12))")"
  .build/t4a-dragpoint "$GRAB_X" "$GRAB_Y" \
    "$(/usr/bin/python3 -c "print($GRAB_X + 50)")" \
    "$(/usr/bin/python3 -c "print($GRAB_Y - 40)")" 14
  sleep 1.5
  dump
  note "      remembered" "$(field "d['settings']['savedOffset']")"
  note "      why" "$(field "d['settings']['lastRemember']")"
  verdict "155c the move was written down" \
    "$(field "'yes' if d['settings']['savedOffset'] else 'no'")" "yes"
  WANT="$(field "d['settings']['savedOffset']")"
  send "settings close"; sleep 0.8
  send "settings open"; sleep 1.2
  dump
  verdict "155d and it comes back where it was put" \
    "$(prog "
s, o = d['settings']['settings'], d['settings']['owner']
print('%d %d %d %d' % (s['cx'] - o['cx'], s['cy'] - o['cy'], s['w'], s['h']))
")" "$WANT"
  shoot "f10-155-settings-on-the-window.png"
  stop
fi

# =================================================================== layout
if [ "$SECTION" = "layout" ] || [ "$SECTION" = "all" ]; then
  echo "==> ISC-156 · the fourth glyph points where the sessions would go"
  fresh_config
  printf 'layout-sessions = rail\nshow-sessions-panel = true\n' > "$CONFIG"
  launch
  dump
  GLYPH="[b for b in d['band']['buttons'] if b['label']=='sessions layout'][0]"
  verdict "156a in rail layout the arrow points up" \
    "$(field "$GLYPH['arrow']")" "top"
  note "      tooltip" "$(field "$GLYPH['tip']")"
  verdict "156b and says so in words" \
    "$(field "'yes' if 'top' in $GLYPH['tip'] else 'no'")" "yes"
  verdict "156c it is not the same glyph as its neighbour" \
    "$(field "'same' if ($GLYPH['edge'], $GLYPH['arrow']) == (d['band']['buttons'][0]['edge'], d['band']['buttons'][0].get('arrow','')) else 'different'")" "different"
  shoot "f10-156-arrow-rail.png"
  send "layout tabs"; sleep 1.5
  dump
  verdict "156d in tab layout the arrow points left" \
    "$(field "$GLYPH['arrow']")" "left"
  note "      tooltip" "$(field "$GLYPH['tip']")"
  # ISC-162, retired UPWARD on 25/08: the sessions-panel switch is gone for
  # good — the sessions cannot be hidden at all any more, so the control that
  # commanded it would command nothing in EVERY layout. The pole now guards
  # the stronger fact: no button by that name exists.
  verdict "162a the dead switch is gone for good" \
    "$(field "'gone' if not [b for b in d['band']['buttons'] if b['label']=='sessions panel'] else 'still there'")" "gone"
  shoot "f10-156-arrow-tabs.png"
  send "layout rail"; sleep 1.5
  dump
  verdict "162b and gone in rail layout too" \
    "$(field "'gone' if not [b for b in d['band']['buttons'] if b['label']=='sessions panel'] else 'still there'")" "gone"
  stop
fi

# =================================================================== bubble
if [ "$SECTION" = "bubble" ] || [ "$SECTION" = "all" ]; then
  echo "==> ISC-158/159 · the bubble keeps the keyboard, and makes lines"
  fresh_config
  # `always`, dichiarato, e non il default. Da ISC-174 il default è `agent`:
  # sopra una shell nuda la bolla non c'è, e questi poli — ⌘L, ⇧↩, ↩ — parlano
  # di come la bolla TIENE la tastiera, non di quando compare. Senza questa
  # riga misurerebbero il cancello di ISC-174 invece del comportamento, e
  # cadrebbero tutti con la bolla legittimamente assente. Quando compare lo
  # misura la sezione `agentbubble`, qui sotto.
  printf 'composer-mode = always\n' > "$CONFIG"
  launch
  # ⇧↩ and ↩, told apart with REAL keystrokes through the window server: the
  # shift is gone by the time a text view is handed a selector, so a probe
  # that synthesised the selector would be measuring the thing that cannot
  # tell them apart.
  send "activate"; sleep 1
  dump
  H0="$(field "d['composer']['height']")"
  # ⌘L and not a click at a guessed point. The first version of this pole
  # clicked at 300,190 — the coordinates the bubble happened to have in
  # ANOTHER run, under another window frame — and hit the terminal, so every
  # verdict after it was measuring the wrong view.
  .build/t4a-keypress 37 cmd; sleep 0.8
  dump
  verdict "158a ⌘L puts the keyboard in the bubble" \
    "$(field "d['composer']['firstResponder']")" "ComposerField"
  send "typekey echo AAA"; sleep 0.6
  # ⇧↩ and ↩, told apart with REAL keystrokes through the window server: the
  # shift is gone by the time a text view is handed a selector, so a probe
  # that synthesised the selector would be measuring the thing that cannot
  # tell them apart.
  .build/t4a-keypress 36 shift; sleep 0.5
  send "typekey echo BBB"; sleep 0.6
  dump
  verdict "159a ⇧↩ made a second line" "$(field "d['composer']['lines']")" "2"
  note "      the bubble holds" "$(field "repr(d['composer']['text'])")"
  H1="$(field "d['composer']['height']")"
  verdict "159b and the bubble grew" \
    "$(/usr/bin/python3 -c "print('taller' if $H1 > $H0 else 'same')")" "taller"
  note "      height" "$H0 -> $H1"
  shoot "f10-159-two-lines.png"
  # ↩ on its own sends, and the bubble empties: the negative pole of the same
  # key, without which "shift makes a line" is a claim about one keystroke.
  .build/t4a-keypress 36; sleep 2
  dump
  verdict "159c ↩ sent it and emptied the bubble" \
    "$(field "repr(d['composer']['text'])")" "''"
  # The OUTPUT of both lines, not the echo of them. `echo AAA` on the screen
  # proves the characters arrived; a line that is exactly `AAA` proves the
  # shell ran it — and the first version of this pole looked for the string
  # anywhere, which a terminal that had merely echoed what was typed into IT
  # satisfies just as well.
  verdict "159d and the shell ran both lines" \
    "$(prog "
panes = [q for t in d['tabs'] for q in t['panes'] if q.get('active')]
screen = panes[0].get('screen') or []
rows = [r.strip() for r in (screen if isinstance(screen, list) else str(screen).splitlines())]
print('yes' if 'AAA' in rows and 'BBB' in rows else 'no')
")" "yes"
  # THE NEGATIVE POLE of ISC-158, and it is the half that keeps the rule
  # honest. With a bare shell nothing is covered — the shell's own prompt is
  # right there — so the keyboard goes back to the terminal after a send,
  # exactly as it always did. Keeping it in the bubble here would be the same
  # mistake pointed the other way: a person who cannot type at the prompt they
  # can see.
  verdict "158b nothing covered: the keyboard went back" \
    "$(field "d['composer']['firstResponder']")" "TappedTerminalView"
  stop

  if [ "$WITH_CLAUDE" = "1" ]; then
    echo "==> ISC-157/158 · the real thing: a covered agent, and a second line"
    if ! command -v claude >/dev/null 2>&1; then
      echo "claude is not on PATH: the live poles were NOT run"; STATUS=1
    else
      fresh_config
      launch
      CHATDIR="$HOME/Movies/t4a-bench-chat"
      mkdir -p "$CHATDIR"
      send "text cd $CHATDIR && claude"; send "key return"
      waited=0
      while [ "$waited" -lt 90 ]; do
        dump
        if /usr/bin/python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
panes = [q for t in d["tabs"] for q in t["panes"] if q.get("active")] \
        or [q for t in d["tabs"] for q in t["panes"]]
for pane in panes:
    screen = pane.get("screen") or ""
    text = "\n".join(screen) if isinstance(screen, list) else str(screen)
    if "auto mode on" in text or "? for shortcuts" in text:
        sys.exit(0)
sys.exit(1)
' "$DUMP"; then break; fi
        sleep 2; waited=$((waited + 2))
      done
      sleep 3
      send "scan"; sleep 0.8
      dump
      verdict "157a the agent's own line is covered" \
        "$(field "'yes' if d['pureChat']['covering'] else 'no'")" "yes"
      # THE REPRODUCTION, in order. A line goes out through the bubble, and
      # then somebody types — which is what he did, and what used to land in
      # an input box nobody could see.
      send "compose ciao"; sleep 4
      dump
      verdict "158c after sending, the keyboard is still in the bubble" \
        "$(field "d['composer']['firstResponder']")" "ComposerField"
      send "typekey pippo"; sleep 1.5
      dump
      verdict "158d what was typed went into the bubble" \
        "$(field "repr(d['composer']['text'])")" "'pippo'"
      verdict "157b and the agent's line is still empty" \
        "$(prog "
panes = [q for t in d['tabs'] for q in t['panes'] if q.get('active')]
screen = panes[0].get('screen') or []
rows = screen if isinstance(screen, list) else str(screen).splitlines()
box = [r for r in rows if r.strip().startswith('❯') or r.strip().startswith('>')]
print(repr(box[-1].strip()) if box else 'no-box')
")" "'❯'"
      verdict "157c so the cover never got out of the way" \
        "$(field "'yes' if d['pureChat']['covering'] else 'no · ' + (d['pureChat'].get('reason') or '')")" "yes"
      note "      the reason, if any" "$(field "repr(d['pureChat'].get('reason'))")"
      shoot "f10-157-still-covered-after-typing.png"
      # The other half of ISC-159, and the only place it can be answered: a
      # two-line message has to reach the AGENT as two lines. T4A sends the
      # text in one write and the Return on its own eighty milliseconds later
      # (ISC-42), so the newline in the middle is part of the paste and not a
      # send — that is the reasoning, and this is the measurement.
      #
      # It costs one small model call, which is why it lives behind
      # --with-claude and says «primo/secondo» rather than anything worth
      # answering.
      send "compose primo\\nsecondo"; sleep 5
      dump
      verdict "159e the agent got ONE message of two lines" \
        "$(prog "
panes = [q for t in d['tabs'] for q in t['panes'] if q.get('active')]
screen = panes[0].get('screen') or []
rows = [r.rstrip() for r in (screen if isinstance(screen, list) else str(screen).splitlines())]
hit = [i for i, r in enumerate(rows) if r.strip() in ('❯ primo', '> primo')]
if not hit:
    print('the first line never arrived')
elif rows[hit[0] + 1].strip() == 'secondo':
    print('two lines')
else:
    print('second line went elsewhere: %r' % rows[hit[0] + 1].strip())
")" "two lines"
      shoot "f10-159-two-lines-to-the-agent.png"
      stop
    fi
  fi
fi

# ============================================================== agentbubble
if [ "$SECTION" = "agentbubble" ] || [ "$SECTION" = "all" ]; then
  echo "==> ISC-174 · la bolla compare solo dove c'è un agente connesso"
  # Sua richiesta del 25/08: «la bolla con message this session la mettiamo
  # solo quando viene aperto claude, un agente, codex». Il modo si chiama `agent`
  # ed è il default; usa la STESSA funzione «connesso» di ISC-173, non una
  # copia — se cambia cosa vuol dire connesso, la barra e la bolla cambiano
  # insieme e non possono contraddirsi.
  #
  # I quattro poli sono a coppie, e le coppie sono il punto: due tengono fermo
  # il modo e cambiano il pannello, due tengono fermo il pannello e cambiano il
  # modo. Un polo solo direbbe «la bolla è nascosta», che è anche quello che
  # direbbe una bolla rotta.
  fresh_config
  launch
  send "activate"; sleep 1
  dump
  verdict "174a il default nel file e' agent" \
    "$(field "d['composer']['mode']")" "agent"
  verdict "174b shell nuda: la bolla non c'è" \
    "$(field "'yes' if not d['composer']['shown'] else 'no'")" "yes"
  verdict "174c e non costa altezza" \
    "$(field "int(d['composer']['height'])")" "0"
  note "      e con lei la pagina della chat" \
    "$(field "'nascosta' if not d['chatPage']['showing'] else 'VISIBILE'")"

  if ! command -v claude >/dev/null 2>&1; then
    echo "      claude NON È SUL PATH: i poli con l'agente NON SONO STATI ESEGUITI"
    STATUS=1
  else
    send "text cd $(pwd) && ANTHROPIC_MODEL=claude-haiku-4-5-20251001 claude"
    send "key return"
    ATTACHED=0
    for _ in $(seq 1 45); do
      sleep 2; dump
      if [ "$(field "d['agents'][0]['adapter'].get('attached')")" = "True" ]; then
        ATTACHED=1; break
      fi
    done
    if [ "$ATTACHED" = "0" ]; then
      echo "      l'adattatore non si è mai agganciato: i poli con l'agente NON ESEGUITI"
      STATUS=1
    else
      sleep 2; dump
      verdict "174d con claude agganciato la bolla c'è" \
        "$(field "'yes' if d['composer']['shown'] else 'no'")" "yes"
      note "      altezza" "$(field "int(d['composer']['height'])")"
      # Il polo che tiene fermo il PANNELLO e cambia il MODO: `never` resta una
      # scelta esplicita e vince sull'agente, altrimenti ISC-174 non avrebbe
      # affinato ISC-113, l'avrebbe ribaltato.
      send "composer-mode never"; sleep 1
      dump
      verdict "174e never con claude: nascosta lo stesso" \
        "$(field "'yes' if not d['composer']['shown'] else 'no'")" "yes"
      send "composer-mode agent"; sleep 1
      dump
      verdict "174f e tornando ad agent ricompare" \
        "$(field "'yes' if d['composer']['shown'] else 'no'")" "yes"
    fi
  fi

  echo "--> il giro del file: quello che si sceglie è quello che si rilegge"
  MODE_ON_DISK="$(grep '^composer-mode' "$CONFIG" | head -1 | sed 's/.*= *//')"
  note "      la riga in config.toml" "$(grep '^composer-mode' "$CONFIG" | head -1)"
  stop
  launch
  send "activate"; sleep 1
  dump
  verdict "174g riletto al riavvio, identico" \
    "$(field "d['composer']['mode']")" "$MODE_ON_DISK"
  verdict "174h e con la shell nuda è di nuovo nascosta" \
    "$(field "'yes' if not d['composer']['shown'] else 'no'")" "yes"

  echo "--> il polo opposto: always con una shell nuda, la bolla c'e'"
  # Senza questo, «la bolla è nascosta» sarebbe compatibile con una bolla che
  # non si accende mai più.
  stop
  fresh_config
  printf 'composer-mode = always\n' > "$CONFIG"
  launch
  send "activate"; sleep 1
  dump
  verdict "174i always con shell nuda: la bolla c'e'" \
    "$(field "'yes' if d['composer']['shown'] else 'no'")" "yes"
  note "      modo letto" "$(field "d['composer']['mode']")"
  stop
fi

[ "$STATUS" = "0" ] && echo "parte 10: every pole held" || echo "parte 10: a pole FAILED"
exit "$STATUS"
