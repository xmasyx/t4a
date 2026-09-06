#!/bin/bash
# The OSC 52 policy, in both poles.
#
#   Scripts/bench-clipboard.sh
#
#   * a program asking for the clipboard gets NOTHING back (the read that put
#     468 base64 characters of a real clipboard on the command line before the
#     repair of 2026-08-20);
#   * a program WRITING to the clipboard still works, because a yank over ssh
#     is why OSC 52 exists.
#
# The clipboard is saved and put back, and the query's answer is never printed
# — only its length, because the payload is the user's clipboard.

set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"
FIFO="/tmp/t4a-clip.fifo"
CONFIG="/tmp/t4a-clip-config"

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
SAVED="$(pbpaste)"
restore() { printf '%s' "$SAVED" | pbcopy; }
trap restore EXIT

printf 'CLIPBOARD-BEFORE-THE-TEST' | pbcopy
t4a_stop_bench
sleep 1.5
rm -rf "$CONFIG" "$FIFO"; mkdir -p "$CONFIG"
open -n dist/T4A.app --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 4

echo "==> a program asks for the clipboard"
send 'text printf "\033]52;c;?\a"'
sleep 0.5
send "key return"
sleep 2.5
rm -f /tmp/t4a-clip.json
send "dump /tmp/t4a-clip.json"
for _ in $(seq 1 30); do [ -s /tmp/t4a-clip.json ] && break; sleep 0.15; done

echo "==> a program writes to the clipboard"
# "written-by-osc52"
send 'text printf "\033]52;c;d3JpdHRlbi1ieS1vc2M1Mg==\a"'
sleep 0.5
send "key return"
sleep 2
WROTE="$(pbpaste)"
t4a_stop_bench
rm -f "$FIFO"

/usr/bin/python3 - "$WROTE" <<'PY'
import json, re, sys, os
wrote = sys.argv[1]
d = json.load(open('/tmp/t4a-clip.json'))
pane = [q for t in d['tabs'] for q in t['panes'] if q['active']][0]
joined = "".join(pane['screen'])
answer = re.search(r'52;c;([A-Za-z0-9+/=]{8,})', joined)
ok = True
def check(label, condition, detail):
    global ok
    ok = ok and condition
    print(f"{'PASS' if condition else 'FAIL'}  {label}: {detail}")

check("a clipboard read is refused", answer is None,
      "nothing came back" if answer is None
      else f"{len(answer.group(1))} base64 characters came back as input")
check("a clipboard write still works", wrote == "written-by-osc52",
      f"the clipboard now reads {wrote!r}")
os.remove('/tmp/t4a-clip.json')
sys.exit(0 if ok else 1)
PY
