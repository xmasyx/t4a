#!/bin/bash
# Real app switch (not the channel's `activate`): Finder in front via AppleScript, then T4A back.
# Three states before the switch: (a) plain; (b) after "/" + Esc in the bubble; (c) after a drag
# selection on the page. Expected (his ask): after T4A comes back, firstResponder = ComposerField.
set -uo pipefail
cd ~/Desktop/lifeos/05-Tools/T4A
source Scripts/lib/bench-stop.sh; t4a_note_his_app
for s in dragpoint keypress; do b=.build/t4a-$s; [ -x "$b" ] || swiftc -O -o "$b" "Scripts/$s.swift" 2>/dev/null; done
CFG=/tmp/t4a-fuoco-cfg; FIFO=/tmp/t4a-fuoco.fifo; OUT=/tmp/t4a-fuoco-out
rm -rf "$CFG" "$FIFO" "$OUT"; mkdir -p "$CFG/t4a" "$OUT"
grep -v '^window-\|^settings-offset' ~/.config/t4a/config.toml > "$CFG/t4a/config.toml"
open -n dist/T4A.app --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CFG"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "FAIL: no channel"; exit 1; }
send() { python3 Scripts/sendline.py "$FIFO" "$1"; }
fr() { send "dump $OUT/$1.json"; sleep 0.6; python3 -c "import json;d=json.load(open('$OUT/$1.json'));c=d['composer'];print('$1 firstResponder=', c.get('firstResponder'), 'keyWindow=', d.get('window',{}).get('isKey'), 'selected=', d.get('chatPage',{}).get('selectedChars'))"; }
switch() { osascript -e 'tell application "Finder" to activate' >/dev/null; sleep 1.2; osascript -e 'tell application id "dev.t4a.terminal" to activate' >/dev/null 2>&1 || open -a "$PWD/dist/T4A.app"; sleep 1.2; }
sleep 2; send "activate"; sleep 1
send "text cd ~/Movies/t4a-bench-chat && claude\n"; sleep 8
send "text prova\n"; echo "message sent $(date +%T); waiting 20 s"; sleep 20
fr a0
echo "=== (a) plain: Finder, then T4A back"; switch; fr a1
echo "=== (b) '/' then Esc in the bubble, then switch"
send "activate"; sleep 0.5; send "typekey /"; sleep 0.8; .build/t4a-keypress 53; sleep 0.8; fr b0; switch; fr b1
echo "=== (c) drag selection on the page, then switch"
python3 - "$OUT/b1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pg=d['chatPage']['page']
xa=int(pg['x']-pg['w']/2+40); y=int(pg['y']+pg['h']/2-30); open('/tmp/t4a-fuoco-out/pts.txt','w').write(f"{xa} {y}")
PY
read XA Y < "$OUT/pts.txt"; .build/t4a-dragpoint "$XA" "$Y" "$((XA+260))" "$Y" 24; sleep 0.8; fr c0; switch; fr c1
echo "=== (d) switch again with nothing changed"; switch; fr d1
send "text \x03"; sleep 1; t4a_stop_bench; sleep 1; rm -rf "$CFG" "$FIFO"
