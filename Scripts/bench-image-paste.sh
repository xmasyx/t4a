#!/bin/bash
# ⌘V with a picture on the clipboard reaches somewhere.
#
#   Scripts/bench-image-paste.sh [app-bundle]
#
# Before this, a screenshot pasted into T4A went nowhere at all: a terminal
# asks the clipboard for a string, gets nothing, and pastes nothing. Three
# poles, and the third is the one that keeps the fix honest:
#
#   1. picture + bubble focused  → the bubble holds a path, and the file is on
#                                  disk with PNG bytes in it
#   2. picture + pane focused    → the same path reaches the pty (no agent in
#                                  the pane: an agent would get ctrl+V instead)
#   3. TEXT on the clipboard     → nothing new is written, the old road is
#                                  untouched
#
# The clipboard belongs to whoever is using the Mac: it is saved and put back.
set -uo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="${1:-dist/T4A.app}"
FIFO="/tmp/t4a-image.fifo"
CONFIG_HOME="/tmp/t4a-image-config"
DUMP=/tmp/t4a-image-dump.json
OUT=/tmp/t4a-image-out.txt
SHOT=/tmp/t4a-image-probe.png
CLIP=/tmp/t4a-image-clipboard.bak
PASTED="$HOME/Library/Caches/T4A/pasted"
STATUS=0

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
dump() { rm -f "$DUMP"; send "dump $DUMP"; for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done; }
composer_text() { /usr/bin/python3 -c "import json;print(json.load(open('$DUMP'))['composer']['text'])"; }
verdict() { # name, ok?, detail
  if [ "$2" = "1" ]; then printf '%-34s %-46s ok\n' "$1" "$3"
  else printf '%-34s %-46s FAILED\n' "$1" "$3"; STATUS=1; fi
}

pbpaste > "$CLIP" 2>/dev/null || true
trap 'pbcopy < "$CLIP" 2>/dev/null || true; rm -f "$CLIP"; t4a_stop_bench; rm -f "$FIFO"' EXIT

t4a_note_his_app
t4a_stop_bench
rm -rf "$CONFIG_HOME" "$FIFO" "$OUT"; mkdir -p "$CONFIG_HOME"
screencapture -x -R 0,0,12,12 "$SHOT"
before=$(ls "$PASTED" 2>/dev/null | wc -l | tr -d ' ')

open -n "$APP" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
[ -p "$FIFO" ] || { echo "test channel never appeared" >&2; exit 1; }
sleep 3

osascript -e "set the clipboard to (read (POSIX file \"$SHOT\") as «class PNGf»)" >/dev/null 2>&1

# ---- pole 1: the bubble -----------------------------------------------------
# `always`, dichiarato, e non il default. Da ISC-174 — commit `bdb7623` del 26/08
# alle 00:39 — il default è `agent`, e sopra una shell nuda la bolla NON C'È:
# questo polo parla di una picture che finisce DENTRO la bolla, non di quando la
# bolla compare. Senza questa riga il primo responder è il terminale, `pasteHere`
# prende il ramo del riquadro, e il polo referta «la bolla è vuota» di una bolla
# che il prodotto ha deciso di non disegnare. Il banco è fermo al 25/08 e la
# decisione è del 26: rosso dal giorno dopo, e non per un difetto (ISC-189).
send "composer-mode always"; sleep 0.8
cache_before=$(ls "$PASTED" 2>/dev/null | wc -l | tr -d ' ')
send "fire Message This Session"; sleep 0.6
send "fire Paste"; sleep 1; dump
text="$(composer_text)"
cache_after=$(ls "$PASTED" 2>/dev/null | wc -l | tr -d ' ')
newest="$PASTED/$(ls -t "$PASTED" 2>/dev/null | head -1)"
if [ "$text" = "[Image #1]" ] && [ "$cache_after" -gt "$cache_before" ] \
   && [ "$(file -b --mime-type "$newest" 2>/dev/null)" = "image/png" ]; then p1=1; else p1=0; fi
verdict "1 la bolla mostra [Image #1]" "$p1" "testo=$text nuovi=$((cache_after-cache_before))"

# ---- pole 2: the pane -------------------------------------------------------
send "composer-mode never"; sleep 0.6
send "text cat > $OUT"; send "key return"; sleep 1
send "fire Paste"; sleep 1
send "key return"; sleep 1
got="$(tr -d '"' < "$OUT" 2>/dev/null | head -1)"
if [ -s "$got" ]; then p2=1; else p2=0; fi
verdict "2 il riquadro riceve il percorso" "$p2" "$(basename "${got:-nulla}")"

# ---- pole 3 (negative): text is not an image --------------------------------
printf 'solo testo' | pbcopy
count_before=$(ls "$PASTED" 2>/dev/null | wc -l | tr -d ' ')
send "fire Message This Session"; sleep 0.5
send "fire Paste"; sleep 1
count_after=$(ls "$PASTED" 2>/dev/null | wc -l | tr -d ' ')
if [ "$count_before" = "$count_after" ]; then p3=1; else p3=0; fi
verdict "3 il testo non scrive file" "$p3" "file in cache: $count_before → $count_after"

[ "$STATUS" = 0 ] && echo "image paste: every pole held" || echo "image paste: SOMETHING FAILED"
exit $STATUS
