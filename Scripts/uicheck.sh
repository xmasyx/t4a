#!/bin/bash
# The pass a person does — driven from outside the app, with real input.
#
#   Scripts/uicheck.sh
#
# Everything else in Scripts/ drives T4A through its own test channel, which
# synthesises events INSIDE the process. This one goes the other way round: it
# uses Interceptor's macOS surface, so the keystrokes come from the window
# server exactly as they do from a keyboard, and the screenshots are of the
# screen. It is the only check here that would catch a shortcut that AppKit
# never routes, or a window that draws nothing when it is really in front.
#
# It refuses to run while the screen is locked: global keystrokes would land
# in the login window, and a screenshot of a locked screen is not evidence of
# anything.

set -uo pipefail
cd "$(dirname "$0")/.."
SHOTS="design/evidence/ui"
mkdir -p "$SHOTS"

# The guard, written the long way ON PURPOSE.
#
# It was `ioreg -n Root -d1 | grep -q ...` and it FAILED OPEN: `grep -q` exits
# the moment it matches, `ioreg` is killed by SIGPIPE with status 141, and
# under `set -o pipefail` the pipeline reports 141 — so the `if` was false
# exactly when the answer was yes, and the script typed a shell command into
# the lock screen (2026-08-20). Reading into a variable first has no pipe to
# break. The pattern is checked in both poles below before it is trusted.
console=$(ioreg -n Root -d1)
case "$console" in
  *'"CGSSessionScreenIsLocked"=Yes'*)
    echo "the screen is locked: unlock it and run this again." >&2
    echo "global keystrokes would land in the login window, and a screenshot" >&2
    echo "of a locked screen proves nothing." >&2
    exit 2 ;;
  *'"CGSSessionScreenIsLocked"=No'*) : ;;
  *)
    echo "cannot tell whether the screen is locked; refusing to type" >&2
    exit 2 ;;
esac

# And a second, independent check: whatever is frontmost must be T4A before a
# single key is sent. One guard on one signal is how the first mistake got
# through.
frontmost_is_t4a() {
  interceptor macos frontmost 2>/dev/null | grep -q '"name": "T4A"'
}

step() { echo "==> $1"; }
shot() {
  rm -f "$SHOTS/$1.png"
  interceptor macos screenshot --app T4A --out "$SHOTS/$1.png" >/dev/null 2>&1 || true
  [ -s "$SHOTS/$1.png" ] || Scripts/drive.sh shot "$SHOTS/$1.png" >/dev/null 2>&1 || true
  if [ -s "$SHOTS/$1.png" ]; then
    echo "    $SHOTS/$1.png ($(stat -f %z "$SHOTS/$1.png") bytes)"
  else
    echo "    NO SHOT for $1 — the capture failed" >&2
  fi
}
guard() {
  frontmost_is_t4a && return 0
  echo "T4A is not frontmost any more; stopping before typing anywhere else" >&2
  exit 3
}
keys() { guard; interceptor macos keys "$1" >/dev/null || exit 3; sleep "${2:-1}"; }
type()  { guard; interceptor macos type "$1" >/dev/null || exit 3; sleep "${2:-1}"; }

pgrep -f "T4A.app/Contents/MacOS/T4A" >/dev/null || open dist/T4A.app
sleep 2
interceptor macos app activate T4A >/dev/null 2>&1
sleep 1.5
step "the window as it stands"
shot 01-window

step "a command, so there is something to look at"
type "ls --color=always /usr/share | head -30"
keys "return" 2
shot 02-output

step "⌘+ twice, then ⌘0"
keys "cmd+plus" 0.6; keys "cmd+plus" 0.6
shot 03-bigger
keys "cmd+0" 0.6
shot 04-actual-size

step "⌘F, type, and the matches"
keys "cmd+f" 1
type "share"
sleep 1
shot 05-find
keys "cmd+g" 0.8
shot 06-find-next
keys "escape" 0.8

step "⌘D splits, ⌘T opens a tab"
keys "cmd+d" 2
shot 07-split
keys "cmd+t" 2
shot 08-tab

step "⌘K clears the buffer"
keys "cmd+k" 1
shot 09-cleared

step "a long program, then ⌘W — it has to ask"
type "sleep 300"
keys "return" 2
keys "cmd+w" 1.5
shot 10-close-guard
keys "escape" 1

step "About T4A"
interceptor macos menu "T4A > About T4A" >/dev/null 2>&1
sleep 1.5
shot 11-about
keys "cmd+w" 1

echo "==> shots in $SHOTS"
