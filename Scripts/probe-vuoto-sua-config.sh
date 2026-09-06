#!/bin/bash
# His gesture, on HIS configuration: the page shows one short turn; the keyboard is on the
# page (drag selection); then a click FAR BELOW the text, where the ReaderText ends and the
# page background begins. Expected (ISC-203d spirit): keyboard back to the composer, caret
# visible. Also the pointer shape there (ISC-204c spirit): arrow, not I-beam.
# 28/08: ChatPageView.schermo already reports page and host in Cocoa screen coordinates
# (main-screen origin bottom-left, Y up), so no window-origin conversion belongs here.
# The point helpers accept that same space and do their own Y flip; only screencapture
# regions are flipped to top-left coordinates. See bench poles 203d/203e/204c/204e.
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh
t4a_note_his_app
for s in clickpoint movepoint dragpoint; do b=.build/t4a-$s; [ -x "$b" ] || swiftc -O -o "$b" "Scripts/$s.swift" 2>/dev/null; done
CFG=/tmp/t4a-his-void-cfg; FIFO=/tmp/t4a-his-void.fifo; OUT=/tmp/t4a-his-void-out
rm -rf "$CFG" "$FIFO" "$OUT"; mkdir -p "$CFG/t4a" "$OUT"
grep -v '^window-\|^settings-offset' ~/.config/t4a/config.toml > "$CFG/t4a/config.toml"
open -n dist/T4A.app --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "FAIL: no channel"; exit 1; }
send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() {
  local p="$1"
  rm -f "$p"
  send "dump $p" || return 1
  for _ in $(seq 1 40); do [ -s "$p" ] && return 0; sleep 0.25; done
  echo "dump never arrived: $p" >&2
  return 1
}
sleep 2; send "activate"; sleep 1
send "text cd ~/Movies/t4a-bench-chat && claude\n"; sleep 8
send "text prova\n"; echo "message sent $(date +%T); waiting 25 s"; sleep 25
send "activate"; sleep 0.5
dump "$OUT/d0.json"
SCREEN_H="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | /usr/bin/awk -F, '{gsub(/ /,"",$4);print $4}')"
SCREEN_W="$(osascript -e 'tell application "Finder" to get bounds of window of desktop' | /usr/bin/awk -F, '{gsub(/ /,"",$3);print $3}')"
/usr/bin/python3 - "$OUT/d0.json" "$SCREEN_H" "$SCREEN_W" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); cp=d['chatPage']; w=d['window']
screenH=int(sys.argv[2]); screenW=int(sys.argv[3])
pg=cp['page']; host=cp['host']  # centre-based Cocoa screen coordinates, Y up
column_x=cp['columnX']; xa=pg['x']-pg['w']/2+column_x+6; xb=xa+260
scan_top=pg['y']+pg['h']/2-column_x-4; scan_bottom=pg['y']-pg['h']/2
xvoid=pg['x']; yvoid=pg['y']-pg['h']/2-220
host_bottom=host['y']-host['h']/2; page_bottom=pg['y']-pg['h']/2
inside=host_bottom < yvoid < page_bottom
void_shot_x=int(round(xvoid-40)); void_shot_y=int(round(screenH-yvoid-40))
composer_shot_y=int(round(screenH-w['y']-140))
open('/tmp/t4a-his-void-out/pts.txt','w').write(
    f"{xa:g} {scan_top:g} {scan_bottom:g} {xb:g} {xvoid:g} {yvoid:g} "
    f"{void_shot_x} {void_shot_y} {composer_shot_y} {screenW}"
)
print(f"page Cocoa-screen centre=({pg['x']}, {pg['y']}) size=({pg['w']}, {pg['h']}); turns={cp.get('turns')} textHeight={cp.get('textHeight')}")
print(f"PRECONDITION void inside host and below page: {inside}; hostBottom={host_bottom:g} < yvoid={yvoid:g} < pageBottom={page_bottom:g}")
print(f"text scan x={xa:g}, y={scan_top:g} down to {scan_bottom:g}, columnX={column_x:g}")
print("void click (Cocoa-screen):", xvoid, yvoid, "firstResponder now:", d['composer']['firstResponder'])
PY
read XA SCAN_TOP SCAN_BOTTOM XB XV YV VOID_SHOT_X VOID_SHOT_Y COMPOSER_SHOT_Y SCREEN_W < "$OUT/pts.txt"

# WHY: the 10:17 run put the old proportional Y in a gap between lines.
# `sopraDelTesto` only accepts each letters' lineFragmentUsedRect, with a
# 1-point vertical inset, and a real "prova" answer has no groups or links
# whose row could supply a known text point. Probe the rendered rows instead.
TEXT_POINT_FOUND=0
SCAN_MOVES=0
YT=""
while IFS= read -r YSCAN; do
  SCAN_MOVES=$((SCAN_MOVES + 1))
  .build/t4a-movepoint "$XA" "$YSCAN"
  sleep 0.25
  if dump "$OUT/text-scan.json"; then
    SCAN_CURSOR="$(/usr/bin/python3 - "$OUT/text-scan.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['window']['cursor'])
PY
)"
    if [ "$SCAN_CURSOR" = ibeam ]; then
      YT="$YSCAN"
      TEXT_POINT_FOUND=1
      break
    fi
  fi
done < <(/usr/bin/python3 - "$SCAN_TOP" "$SCAN_BOTTOM" <<'PY'
import sys
y=float(sys.argv[1]); bottom=float(sys.argv[2])
while y >= bottom:
    print(f"{y:g}")
    y -= 3
PY
)

if [ "$TEXT_POINT_FOUND" = 1 ]; then
  echo "text point found at y=$YT after $SCAN_MOVES moves"
  read HOVER_X TEXT_SHOT_X TEXT_SHOT_Y < <(/usr/bin/python3 - "$XA" "$YT" "$SCREEN_H" <<'PY'
import sys
x,y,screen_h=map(float,sys.argv[1:])
hover_x=x+20
print(f"{hover_x:g} {round(hover_x-40):g} {round(screen_h-y-40):g}")
PY
)
else
  echo "TEXT POINT NOT FOUND after $SCAN_MOVES moves"
fi

echo "=== 1. drag on the text: keyboard to the page"
if [ "$TEXT_POINT_FOUND" = 1 ]; then
  echo "drag on text (Cocoa-screen): $XA $YT -> $XB $YT"
  .build/t4a-dragpoint "$XA" "$YT" "$XB" "$YT" 24; sleep 1
  dump "$OUT/d1.json"
  /usr/bin/python3 - "$OUT/d1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); selected=d['chatPage'].get('selectedChars', 0)
print('PRECONDITION after drag: firstResponder:', d['composer']['firstResponder'], 'selectedChars', selected,
      '- drag missed the text' if selected == 0 else '- text selection established')
PY
else
  echo "PRECONDITION after drag: NOT MEASURED (no text point)"
fi
echo "=== 2. pointer far below the text"
.build/t4a-movepoint "$XV" "$YV"; sleep 0.7
dump "$OUT/d2.json"
/usr/bin/python3 -c "import json;d=json.load(open('$OUT/d2.json'));print('pointer in the big void: dump cursor =', d['window']['cursor'])"
screencapture -C -x -R "$VOID_SHOT_X,$VOID_SHOT_Y,80,80" "$OUT/void-pointer.png" && echo "shot $OUT/void-pointer.png"
echo "=== 3. click there"
.build/t4a-clickpoint "$XV" "$YV" 8; sleep 1
dump "$OUT/d3.json"
/usr/bin/python3 -c "import json;d=json.load(open('$OUT/d3.json'));print('after void click firstResponder:', d['composer']['firstResponder'], 'selectedChars', d['chatPage'].get('selectedChars'))"
screencapture -x -R "0,$COMPOSER_SHOT_Y,$SCREEN_W,140" "$OUT/composer-after-click.png" && echo "shot $OUT/composer-after-click.png"
echo "=== 4. pointer over the answer text"
if [ "$TEXT_POINT_FOUND" = 1 ]; then
  .build/t4a-movepoint "$HOVER_X" "$YT"; sleep 0.7
  dump "$OUT/d4.json"
  /usr/bin/python3 -c "import json;d=json.load(open('$OUT/d4.json'));print('pointer over text: dump cursor =', d['window']['cursor'])"
  screencapture -C -x -R "$TEXT_SHOT_X,$TEXT_SHOT_Y,80,80" "$OUT/text-pointer.png"
else
  echo "pointer over text: NOT MEASURED (no text point)"
fi
send "text \x03"; sleep 1
t4a_stop_bench; sleep 1
echo "left (his = no channel):"; for pid in $(pgrep -f 'T4A.app/Contents/MacOS/T4A'); do echo "  $pid chan=$(t4a_channel_of "$pid")"; done
rm -rf "$CFG" "$FIFO"
/usr/bin/python3 - "$OUT/d2.json" "$OUT/d3.json" "$TEXT_POINT_FOUND" "$OUT/d4.json" <<'PY'
import json,sys
d2=json.load(open(sys.argv[1])); d3=json.load(open(sys.argv[2])); text_point_found=sys.argv[3]=='1'
cursor=d2['window']['cursor']; responder=d3['composer']['firstResponder']
if text_point_found:
    d4=json.load(open(sys.argv[4]))
    selected=d3['chatPage'].get('selectedChars'); text_cursor=d4['window']['cursor']
    checks=[cursor=='arrow',responder=='ComposerField',selected==0,text_cursor=='ibeam']
else:
    selected='not measured'; text_cursor='not measured'
    checks=[cursor=='arrow',responder=='ComposerField',False]
print("SUMMARY %s: void cursor=%s; after-click firstResponder=%s; selectedChars=%s; text cursor=%s" % ("PASS" if all(checks) else "FAIL",cursor,responder,selected,text_cursor))
sys.exit(0 if all(checks) else 1)
PY
