#!/bin/bash
# A clipboard that carries the paste-end sequence must not be able to type
# (ISC-166, Gemini audit 2026-09-06).
#
#   Scripts/bench-paste-inject.sh [app-bundle]
#
# A raw-mode reader in the pane turns DECSET 2004 on and prints the bytes it
# received. The clipboard holds `safe ESC[201~ echo INJECTED \r ESC[200~ tail`.
# PASS: one paste object, our start and end at the edges, no marker inside,
# and nothing arrived outside the bracket. A bundle without the sanitizer
# prints the inner ESC[201~ and the command after it as keystrokes.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"
APP="${1:-dist/T4A.app}"
FIFO=/tmp/t4a-inj.fifo
CONFIG_HOME=/tmp/t4a-inj-config
DUMP=/tmp/t4a-inj-dump.json
READER=/tmp/t4a-inj-reader.py
[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }
send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$DUMP"; send "dump $DUMP"; for _ in $(seq 1 60); do [ -s "$DUMP" ] && break; sleep 0.1; done; }
cat > "$READER" <<'PY'
import os, sys, tty, termios, time, select
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
sys.stdout.write("\x1b[?2004h"); sys.stdout.flush()
tty.setraw(fd)
got = b""
end = time.time() + 12
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        got += os.read(fd, 4096)
        if got: end = min(end, time.time() + 1.5)
termios.tcsetattr(fd, termios.TCSADRAIN, old)
sys.stdout.write("\x1b[?2004l")
sys.stdout.write("GOT " + repr(got) + "\r\n"); sys.stdout.flush()
PY
t4a_note_his_app 2>/dev/null || true
t4a_stop_bench; sleep 1
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME/t4a"; printf 'theme = black\n' > "$CONFIG_HOME/t4a/config.toml"
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME" --env LANG=en_US.UTF-8
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "the test channel never appeared" >&2; exit 1; }
sleep 3
send "text /usr/bin/python3 $READER"; send "key return"; sleep 2
B64=$(printf 'safe\x1b[201~echo INJECTED\r\x1b[200~tail' | base64)
send "clipboard-text64 $B64"; sleep 0.4
send "activate"; sleep 0.4
send "paste-here"; sleep 4
dump
VERDICT="$(/usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); rows = d['tabs'][0]['panes'][0]['screen']
text = "".join(r for r in rows)
i = text.find("GOT b'")
got = text[i + 4:] if i >= 0 else ""
ok = (i >= 0
      and got.startswith("b'\\x1b[200~safeecho INJECTED\\rtail\\x1b[201~'")
      and got.count("\\x1b[201~") == 1 and got.count("\\x1b[200~") == 1)
print("PASS" if ok else "FAIL")
print("      received:", got[:90])
PY
)"
echo "$VERDICT"
t4a_stop_bench; rm -f "$FIFO"
case "$VERDICT" in PASS*) exit 0 ;; *) exit 1 ;; esac
