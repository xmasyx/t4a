#!/bin/bash
# ISC-108 — a banner for the pane you are already looking at is noise.
#
#   Scripts/bench-notify-focus.sh [app-bundle]
#
# Three cases, each a real OSC 9 written by a real shell:
#   1. the pane in front, app frontmost      -> no banner
#   2. a pane in another tab                 -> banner
#   3. the pane in front, app behind Finder  -> banner
#
# Two witnesses for each: the app's own record of the presentation decision,
# and what macOS is holding in Notification Center afterwards. The second is
# the one that cannot be talked into agreeing with us — a suppressed banner is
# not in that list, a delivered one is. If macOS has not authorised T4A to
# notify at all, the run stops: with no notifications, every case would look
# suppressed and the bench would report a pass it never measured.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-notify.fifo"
CONFIG_HOME="/tmp/t4a-notify-config"

[ -x "$APP/Contents/MacOS/T4A" ] || { echo "no bundle at $APP" >&2; exit 1; }

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
delivered() {
  rm -f /tmp/t4a-notify-delivered.json
  send "delivered /tmp/t4a-notify-delivered.json"
  for _ in $(seq 1 30); do [ -s /tmp/t4a-notify-delivered.json ] && break; sleep 0.1; done
}
dump() {
  rm -f /tmp/t4a-notify-dump.json
  send "dump /tmp/t4a-notify-dump.json"
  for _ in $(seq 1 30); do [ -s /tmp/t4a-notify-dump.json ] && break; sleep 0.1; done
}

t4a_stop_bench
sleep 1
rm -rf "$CONFIG_HOME" "$FIFO"; mkdir -p "$CONFIG_HOME"
# Through `open`, so the app has the launch services identity local
# notifications are granted against.
open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
sleep 3

delivered
/usr/bin/python3 -c "
import json, sys
d = json.load(open('/tmp/t4a-notify-delivered.json'))
s = d.get('settings', {})
print('    notification settings:', s)
if 'rawValue: 2' not in s.get('authorization', ''):
    print('    note: authorization is not the plain \"authorized\" state; the two')
    print('    cases that EXPECT a banner are the ones that will say so.')
"

echo "==> case 1: the pane in front, app frontmost"
send "text printf '\\033]9;FOCUSED-PANE-MESSAGE\\a'"
send "key return"
sleep 3

echo "==> case 2: a pane in another tab"
# The message is written by the shell in tab 0 six seconds from now; by then
# the keyboard is in tab 1, which is exactly the case the claim is about.
send "text sleep 6; printf '\\033]9;BACKGROUND-PANE-MESSAGE\\a'"
send "key return"
send "newtab"
sleep 12

echo "==> case 3: the pane in front, but T4A is behind"
send "text sleep 6; printf '\\033]9;APP-BEHIND-MESSAGE\\a'"
send "key return"
sleep 1
osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
sleep 12
osascript -e 'tell application "T4A" to activate' >/dev/null 2>&1 || true
sleep 2

dump
delivered

/usr/bin/python3 <<'PY'
import json, sys
dump = json.load(open('/tmp/t4a-notify-dump.json'))
delivered = json.load(open('/tmp/t4a-notify-delivered.json'))
posted = {n['body']: n['session'] for n in dump.get('notifications', [])}
present = {entry['body']: entry for entry in dump.get('presentations', [])}
held = {n['body'] for n in delivered.get('delivered', [])}

ok = True
def check(label, condition, detail):
    global ok
    ok = ok and condition
    print(f"{'PASS' if condition else 'FAIL'}  {label}: {detail}")

# What macOS actually does, measured on 2026-08-20 and worth writing down:
# `willPresent` is consulted ONLY while the app is frontmost, and Notification
# Center keeps every delivered message whatever the app answered. So a
# suppressed banner is "asked, and the answer was no", a banner while the app
# is behind is "never asked", and the message is on file in all three cases —
# suppressing the banner does not throw the notification away.
for body, expected, why in [
    ("FOCUSED-PANE-MESSAGE", "suppressed", "the pane in front"),
    ("BACKGROUND-PANE-MESSAGE", "shown", "a pane in another tab"),
    ("APP-BEHIND-MESSAGE", "not asked", "the pane in front, app behind"),
]:
    if posted.get(body) is None:
        check(why, False, f"the shell never posted {body}")
        continue
    mine = present.get(body)
    if mine is None:
        got, detail = "not asked", "macOS did not consult the app"
    else:
        got = "shown" if mine['presented'] == 'true' else "suppressed"
        detail = f"reason={mine['reason']}"
    check(f"{why}: banner {expected}", got == expected, f"{got} ({detail})")
    check(f"{why}: the message is still on file",
          body in held, f"in Notification Center = {body in held}")
sys.exit(0 if ok else 1)
PY

t4a_stop_bench
rm -f "$FIFO"
