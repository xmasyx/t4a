#!/bin/bash
# ISC-241 — a file or image paste reaches the hosted program as the same
# bracketed-paste object measured in bench-paste-form.sh.
#
#   Scripts/bench-paste-fedele.sh [--head old-app-bundle] [app-bundle]
#
# P1, P4, and the live half of P5 need a logged-in Claude and a live
# WindowServer. P2/P3/P5 also use the app's real NSPasteboard. A denied
# precondition is printed as NOT RUN, never turned into a product failure or
# a green placeholder.

set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-stop.sh

HEAD=""
if [ "${1:-}" = "--head" ]; then
  [ "$#" -ge 2 ] || { echo "--head needs an app bundle" >&2; exit 2; }
  HEAD="$2"
  shift 2
fi
APP="${1:-dist/T4A.app}"
WORK="$(mktemp -d -t t4a-paste-fedele)" || exit 1
FIFO="$WORK/channel.fifo"
CONFIG_HOME="$WORK/config"
DUMPS="$WORK/dumps"
CAPTURE="$PWD/Scripts/fixtures/paste-capture.py"
PNG="$WORK/prova paste fedele.png"
FILE="$WORK/cartella con spazi/film intero.mov"
NSIRD_FIXTURE="${TMPDIR%/}/TemporaryItems/NSIRD_bench"
P5_PNG="$NSIRD_FIXTURE/screenshot bench.PNG"
P5_MOV="$NSIRD_FIXTURE/film bench.mov"
CLIPBOARD_TOOL="$WORK/pasteboard-preserve"
CLIPBOARD_SNAPSHOT="$WORK/pasteboard.json"
REAL_CLAUDE_CONFIG="$HOME/.claude.json"
CLAUDE_HOME="${T4A_BENCH_CLAUDE_HOME:-$HOME/.cache/t4a/bench-claude-home}"
STATUS=0
DUMP=""

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }

# HEAD predates `paste-here`. Its channel does have `activate`, so make the
# old responder-chain fallback key the bench window before every menu action.
head_fire() {
  send "activate"
  sleep 0.6
  send "fire $1"
}

dump() {
  local name="$1"
  DUMP="$DUMPS/$name.json"
  rm -f "$DUMP"
  send "dump $DUMP" || return 1
  for _ in $(seq 1 50); do [ -s "$DUMP" ] && return 0; sleep 0.1; done
  return 1
}

field() {
  /usr/bin/python3 - "$DUMP" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
try:
    value = eval(sys.argv[2], {"d": d})
except Exception as error:
    print("missing:" + type(error).__name__)
else:
    if isinstance(value, bool): print("True" if value else "False")
    elif isinstance(value, (dict, list)): print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    else: print(value)
PY
}

pane_expr="next((p for t in d.get('tabs',[]) if t.get('active') for p in t.get('panes',[]) if p.get('active')),{})"

screen_has() {
  local needle="$1"
  [ "$(field "any('$needle'.lower() in row.lower() for row in ($pane_expr).get('screen',[]))")" = True ]
}

visible_row() {
  local needle="$1"
  /usr/bin/python3 - "$DUMP" "$needle" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
needle = sys.argv[2].lower()
pane = next((p for t in d.get("tabs", []) if t.get("active")
             for p in t.get("panes", []) if p.get("active")), {})
screen = pane.get("screen", [])
row = next((r for r in screen if needle and needle in r.lower()), None)
if row is None:
    index = pane.get("cursorRow", 0) - pane.get("topVisibleRow", 0)
    row = screen[index] if 0 <= index < len(screen) else ""
print(json.dumps(row.strip(), ensure_ascii=False))
PY
}

last_screen_row() {
  if [ ! -s "$DUMP" ]; then printf '""\n'; return; fi
  /usr/bin/python3 - "$DUMP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pane = next((p for t in d.get("tabs", []) if t.get("active")
             for p in t.get("panes", []) if p.get("active")), {})
row = next((r for r in reversed(pane.get("screen", [])) if r.strip()), "")
print(json.dumps(row.strip(), ensure_ascii=False))
PY
}

record() {
  local pole="$1" state="$2" detail="$3"
  printf '%-7s %-8s %s\n' "$pole" "$state" "$detail"
  [ "$state" = PASS ] || STATUS=1
}

cleanup() {
  if [ -x "$CLIPBOARD_TOOL" ] && [ -s "$CLIPBOARD_SNAPSHOT" ]; then
    "$CLIPBOARD_TOOL" restore "$CLIPBOARD_SNAPSHOT" >/dev/null 2>&1 || true
  fi
  t4a_stop_bench
  rm -f "$P5_PNG" "$P5_MOV"
  rmdir "$NSIRD_FIXTURE" 2>/dev/null || true
  case "$(basename "$WORK")" in t4a-paste-fedele.*) rm -rf "$WORK";; esac
  t4a_bench_unlock
}
trap cleanup EXIT

mkdir -p "$CONFIG_HOME/t4a" "$DUMPS" "$(dirname "$FILE")" "$CLAUDE_HOME" \
  "$NSIRD_FIXTURE"
chmod 700 "$CLAUDE_HOME"
cp Icon/icon-1024.png "$PNG"
cp Icon/icon-1024.png "$P5_PNG"
: > "$FILE"
: > "$P5_MOV"
mkdir -p "$WORK/module-cache"
CLANG_MODULE_CACHE_PATH="$WORK/module-cache" \
  xcrun swiftc -O -framework AppKit -o "$CLIPBOARD_TOOL" \
  Scripts/fixtures/pasteboard-preserve.swift || exit 2
"$CLIPBOARD_TOOL" save "$CLIPBOARD_SNAPSHOT" || exit 2

start_app() {
  local config="$1"
  local bundle="${2:-$APP}"
  t4a_stop_bench
  rm -f "$FIFO"
  open -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" \
      --env XDG_CONFIG_HOME="$config" --env CLAUDE_CONFIG_DIR="$CLAUDE_HOME" || return 1
  for _ in $(seq 1 40); do [ -p "$FIFO" ] && break; sleep 0.25; done
  [ -p "$FIFO" ] || return 1
  sleep 1
}

start_capture() {
  local output="$1" mode="$2"
  local argv64 bracketed process
  rm -f "$output"
  send "composer-mode never"
  argv64="$(/usr/bin/python3 - "$CAPTURE" "$output" "$mode" <<'PY'
import base64, json, sys
raw = json.dumps(["/usr/bin/python3", *sys.argv[1:]], separators=(",", ":")).encode()
print(base64.b64encode(raw).decode())
PY
)"
  send "open-pane-cmd $argv64"
  for _ in $(seq 1 100); do
    dump capture-ready || return 1
    bracketed="$(field "($pane_expr).get('bracketedPaste',False)")"
    process="$(field "($pane_expr).get('process','')")"
    # This active pane was born with the reader as its leader. The conjunction
    # still matters: a pid without DECSET is early, DECSET without its process
    # would belong to the wrong pane.
    if [ "$bracketed" = True ] && [ -n "$process" ]; then return 0; fi
    sleep 0.1
  done
  return 1
}

# An old bundle cannot know the new verb. Keep its historical negative pole
# runnable through its own shell; this fallback is never used for current P1/P2/P3.
start_capture_legacy() {
  local output="$1" mode="$2"
  local bracketed process
  rm -f "$output"
  send "composer-mode never"
  send "text /usr/bin/python3 $CAPTURE $output $mode"
  send "key return"
  for _ in $(seq 1 100); do
    dump capture-ready-head || return 1
    bracketed="$(field "($pane_expr).get('bracketedPaste',False)")"
    process="$(field "($pane_expr).get('process','')")"
    if [ "$bracketed" = True ] \
       && [[ "$process" == *python* || "$process" == *Python* ]]; then return 0; fi
    sleep 0.1
  done
  return 1
}

wait_capture() {
  local output="$1"
  # The reader owns raw mode for at most 12 seconds. Wait beyond that even on
  # a zero-byte failure, otherwise the next pole types its launch command into
  # the still-running previous reader and one red pole contaminates the rest.
  for _ in $(seq 1 140); do [ -s "$output" ] && return 0; sleep 0.1; done
  return 1
}

inspect_capture() {
  local output="$1" expected="$2" mode="$3"
  /usr/bin/python3 - "$output" "$expected" "$mode" <<'PY'
import json, pathlib, sys
start, end = b"\x1b[200~", b"\x1b[201~"
data = pathlib.Path(sys.argv[1]).read_bytes()
body = sys.argv[2].encode()
wanted = start + body + end + (b"\r" if sys.argv[3] == "submit" else b"")
print(f"payload={json.dumps(sys.argv[2], ensure_ascii=False)} raw={data.hex()}")
raise SystemExit(0 if data == wanted else 1)
PY
}

capture_payload() {
  local output="$1" mode="$2"
  /usr/bin/python3 - "$output" "$mode" <<'PY'
import pathlib, sys
start, end = b"\x1b[200~", b"\x1b[201~"
data = pathlib.Path(sys.argv[1]).read_bytes()
trailer = b"\r" if sys.argv[2] == "submit" else b""
if not data.startswith(start) or not data.endswith(end + trailer):
    raise SystemExit(1)
body_end = len(data) - len(end) - len(trailer)
sys.stdout.write(data[len(start):body_end].decode("utf-8"))
PY
}

# P5's pasteboard must be written by ANOTHER process, never by the app itself.
# TemporaryItems is gated by TCC (com.apple.macl): the read grant is minted at
# readObjects time only when the file URL crosses processes with user intent,
# which is what the real Finder ⌘C does. A self-written pasteboard gets EPERM
# (Cocoa 513 on copy, 257 on read — measured in-app 2026-08-31), so the old
# clipboard-file fixture made the product look broken when only the probe was.
finder_clipboard() {
  /usr/bin/osascript -e \
    "tell application \"Finder\" to set the clipboard to (POSIX file \"$1\")" \
    >/dev/null 2>&1
}

printf '%-7s %-8s %s\n' POLE STATE OBSERVED
printf '%-7s %-8s %s\n' ---- ----- --------
t4a_note_his_app

# P2/P3 and the serialization half of P1 use a raw reader in the actual pty.
printf '%s\n' 'chat-page = false' 'composer-mode = never' 'pure-chat = false' \
  > "$CONFIG_HOME/t4a/config.toml"
if ! start_app "$CONFIG_HOME"; then
  record P1-PTY "NOT RUN" "the test bundle/channel did not start"
  record P2 "NOT RUN" "the test bundle/channel did not start"
  record P3 "NOT RUN" "the test bundle/channel did not start"
  record P5-PTY "NOT RUN" "the test bundle/channel did not start"
  record P5-neg "NOT RUN" "the test bundle/channel did not start"
else
  p2_capture="$WORK/p2.raw"
  if start_capture "$p2_capture" paste; then
    send "clipboard-file $FILE\tname.mov"
    dump p2-fixture || true
    types="$(field "d.get('clipboardTypes',[])")"
    advertised="$(field "d.get('clipboard','')")"
    # A file URL takes the backend road directly. Keeping this pty pole in
    # the background prevents AppKit focus from becoming an accidental part
    # of a byte-serialization claim.
    send "paste-here"
    if wait_capture "$p2_capture"; then
      quoted_file="\"$FILE\""
      detail="$(inspect_capture "$p2_capture" "$quoted_file" paste 2>&1)"
      if inspect_capture "$p2_capture" "$quoted_file" paste >/dev/null 2>&1 \
         && [[ "$types" == *public.file-url* ]] && [ "$advertised" = name.mov ]; then
        record P2 PASS "$detail types=$types string=$advertised"
      else
        record P2 FAIL "$detail types=$types string=$advertised"
      fi
    else
      record P2 FAIL "capture did not arrive; types=$types string=$advertised"
    fi
  else
    record P2 "NOT RUN" "the pty reader never enabled bracketed paste"
  fi

  p3_capture="$WORK/p3.raw"
  pure_text=$'byte-identico: à €\tTAB\nseconda riga senza file-url'
  pure64="$(printf %s "$pure_text" | /usr/bin/base64 | tr -d '\n')"
  # Plain text intentionally keeps pasteHere's AppKit responder road. Establish
  # its real user precondition before the reader arms DECSET 2004: changing
  # window/responder state afterwards makes a byte-serialization pole depend
  # on an unrelated focus transition.
  # The verb alone is refused by macOS 14+ cooperative activation on a busy
  # Mac (key stayed False on two runs, 6/09); Launch Services on the live
  # bundle gets the key window for real, as bench-link does since 31/08.
  for _ in 1 2 3; do
    open -a "$PWD/$APP" 2>/dev/null || true
    send "activate"
    sleep 0.6
    send "focus-pane"
    dump p3-precondition || true
    app_active="$(field "d.get('appActive',False)")"
    window_key="$(field "d.get('window',{}).get('key',False)")"
    responder="$(field "d.get('firstResponder','')")"
    [ "$app_active" = True ] && [ "$window_key" = True ] && break
  done
  if [ "$app_active" != True ] || [ "$window_key" != True ] \
     || [ "$responder" != TappedTerminalView ]; then
    record P3 "NOT RUN" \
      "plain-text paste needs active=True key=True responder=TappedTerminalView; got active=$app_active key=$window_key responder=$responder"
  elif start_capture "$p3_capture" paste; then
    send "clipboard-text64 $pure64"
    dump p3-fixture || true
    types="$(field "d.get('clipboardTypes',[])")"
    send "paste-here"
    if wait_capture "$p3_capture"; then
      detail="$(inspect_capture "$p3_capture" "$pure_text" paste 2>&1)"
      if inspect_capture "$p3_capture" "$pure_text" paste >/dev/null 2>&1 \
         && [[ "$types" != *public.file-url* ]]; then
        record P3 PASS "$detail types=$types precondition=active/key/pane"
      else
        record P3 FAIL "$detail types=$types precondition=active/key/pane"
      fi
    else
      record P3 FAIL "byte dump did not arrive; types=$types precondition=active/key/pane"
    fi
  else
    record P3 "NOT RUN" "the pty reader never enabled bracketed paste"
  fi

  p1_capture="$WORK/p1.raw"
  if start_capture "$p1_capture" submit; then
    send "composer-mode always"
    send "activate"
    sleep 0.6
    send "fire Message This Session"
    # Both representations deliberately spell the same quoted path. The new
    # product must choose the file URL and create an attachment; HEAD chooses
    # the string and leaves that same spelling as ordinary Claude input.
    send "clipboard-file $PNG\t\"$PNG\""
    send "paste-here"
    dump p1-composer || true
    token="$(field "d.get('composer',{}).get('text','')")"
    send "composer-send"
    if wait_capture "$p1_capture"; then
      # Since the cache slice (31/08, fetta 6) EVERY pasted image travels as a
      # quoted copy under ~/Library/Caches/T4A/pasted — the original WORK path
      # would now be a failure. Assert the framing, the location, and that the
      # copy carries the source bytes; [Image #1] stays the composer half.
      p1_body="$(capture_payload "$p1_capture" submit)" || p1_body=""
      p1_path="${p1_body#\"}"; p1_path="${p1_path%\"}"
      p1_src_sha="$(/usr/bin/shasum "$PNG" | cut -d" " -f1)"
      p1_dst_sha="$(/usr/bin/shasum "$p1_path" 2>/dev/null | cut -d" " -f1)"
      detail="payload=$p1_body sha-match=$([ "$p1_src_sha" = "$p1_dst_sha" ] && echo yes || echo no)"
      case "$p1_path" in
        "$HOME/Library/Caches/T4A/pasted/"*)
          if [ "$p1_src_sha" = "$p1_dst_sha" ] && [ "$token" = "[Image #1]" ]; then
            record P1-PTY PASS "$detail composer=$token"
          else
            record P1-PTY FAIL "$detail composer=$token"
          fi ;;
        *) record P1-PTY FAIL "$detail (non in cache) composer=$token" ;;
      esac
    else
      record P1-PTY FAIL "composer byte dump did not arrive; composer=$token"
    fi
  else
    record P1-PTY "NOT RUN" "the pty reader never enabled bracketed paste"
  fi

  p5_capture="$WORK/p5.raw"
  if ! finder_clipboard "$P5_PNG"; then
    record P5-PTY "NOT RUN" "Finder refused the clipboard write (automation permission?)"
  elif start_capture "$p5_capture" paste; then
    send "paste-here"
    if wait_capture "$p5_capture"; then
      p5_payload="$(capture_payload "$p5_capture" paste 2>/dev/null || true)"
      p5_copy="$(/usr/bin/python3 - "$p5_payload" <<'PY'
import json, sys
try:
    path = json.loads(sys.argv[1])
except (json.JSONDecodeError, IndexError):
    raise SystemExit(1)
if not isinstance(path, str):
    raise SystemExit(1)
print(path)
PY
)" || p5_copy=""
      cache_root="$HOME/Library/Caches/T4A/pasted/"
      source_sum="$(/usr/bin/shasum "$P5_PNG" | awk '{print $1}')"
      copy_sum=""
      [ -f "$p5_copy" ] && copy_sum="$(/usr/bin/shasum "$p5_copy" | awk '{print $1}')"
      if [ -n "$p5_copy" ] && [[ "$p5_copy" == "$cache_root"* ]] \
         && [ -f "$p5_copy" ] && [ "$copy_sum" = "$source_sum" ]; then
        record P5-PTY PASS \
          "payload=$(printf '%q' "$p5_payload") copy=$p5_copy shasum=$copy_sum"
      else
        record P5-PTY FAIL \
          "payload=$(printf '%q' "$p5_payload") copy=$(printf '%q' "$p5_copy") source-sha=$source_sum copy-sha=$copy_sum"
      fi
    else
      record P5-PTY FAIL "capture did not arrive"
    fi
  else
    record P5-PTY "NOT RUN" "the pty reader never enabled bracketed paste"
  fi

  p5_neg_capture="$WORK/p5-neg.raw"
  if ! finder_clipboard "$P5_MOV"; then
    record P5-neg "NOT RUN" "Finder refused the clipboard write (automation permission?)"
  elif start_capture "$p5_neg_capture" paste; then
    send "paste-here"
    if wait_capture "$p5_neg_capture"; then
      quoted_p5_mov="\"$P5_MOV\""
      detail="$(inspect_capture "$p5_neg_capture" "$quoted_p5_mov" paste 2>&1)"
      if inspect_capture "$p5_neg_capture" "$quoted_p5_mov" paste >/dev/null 2>&1; then
        record P5-neg PASS "$detail"
      else
        record P5-neg FAIL "$detail"
      fi
    else
      record P5-neg FAIL "capture did not arrive"
    fi
  else
    record P5-neg "NOT RUN" "the pty reader never enabled bracketed paste"
  fi
fi
t4a_stop_bench

prepare_claude_config() {
  /usr/bin/python3 Scripts/claude-config-copy.py \
    "$REAL_CLAUDE_CONFIG" "$CLAUDE_HOME/.claude.json"
}

start_claude() {
  local chat="$1" bundle="${2:-$APP}"
  DUMP=""
  mkdir -p "$chat"
  printf '%s\n' 'chat-page = false' 'composer-mode = never' \
    'show-turn-map = false' 'pure-chat = false' > "$CONFIG_HOME/t4a/config.toml"
  start_app "$CONFIG_HOME" "$bundle" || return 1
  send "text cd $(printf '%q' "$chat") && claude"
  send "key return"
  local ready=0
  for _ in $(seq 1 100); do
    dump claude-ready || return 1
    if screen_has "Yes, I trust this folder"; then
      send "key down"; send "key return"; sleep 0.5; continue
    fi
    if screen_has "Enter to confirm"; then
      send "key return"; sleep 0.5; continue
    fi
    if screen_has "Not logged in" || screen_has "/login"; then return 2; fi
    bracketed="$(field "($pane_expr).get('bracketedPaste',False)")"
    attached="$(field "($pane_expr).get('attached',False)")"
    process="$(field "($pane_expr).get('process','')")"
    if [ "$attached" = True ] && [ "$bracketed" = True ] && [ -n "$process" ]; then
      ready=$((ready + 1)); [ "$ready" -ge 2 ] && return 0
    else
      ready=0
    fi
    sleep 0.5
  done
  return 1
}

prepare_claude_config

# P4 decides whether Claude's own Ctrl-V remains the image road. The general
# pasteboard is shared with the person using this Mac, so a change after our
# fixture was installed invalidates the attempt instead of condemning T4A.
p4_finished=0
p4_contested=0
for attempt in 1 2; do
  start_claude "$WORK/chat-p4-$attempt"
  claude_state=$?
  if [ "$claude_state" -ne 0 ]; then
    reason="Claude did not reach an attached input line"
    [ "$claude_state" -eq 2 ] && reason="log in once with CLAUDE_CONFIG_DIR=$CLAUDE_HOME claude /login"
    record P4 "NOT RUN" "$reason; attempt=$attempt lastRow=$(last_screen_row)"
    p4_finished=1
    break
  fi
  send "clipboard-png $PNG"
  send "composer-mode never"
  send "focus-pane"
  if ! dump "p4-$attempt-before"; then
    record P4 "NOT RUN" "could not read pasteboard changeCount before attempt=$attempt"
    p4_finished=1
    break
  fi
  change_before="$(field "d.get('clipboardChangeCount',-1)")"
  send "fire Paste"
  sleep 2
  if ! dump "p4-$attempt-after"; then
    record P4 "NOT RUN" "could not read pasteboard changeCount after attempt=$attempt"
    p4_finished=1
    break
  fi
  change_after="$(field "d.get('clipboardChangeCount',-1)")"
  if [ "$change_before" != "$change_after" ]; then
    printf '%-7s %-8s %s\n' P4-TRY "CONTESO" \
      "attempt=$attempt changeCount=$change_before→$change_after; retrying"
    p4_contested=$((p4_contested + 1))
    t4a_stop_bench
    continue
  fi
  if screen_has "[Image #1]"; then
    record P4 PASS \
      "YES → keep 0x16; attempt=$attempt changeCount=$change_before row=$(visible_row '[Image #1]')"
  else
    record P4 FAIL \
      "NO → replace 0x16 with disk+quoted paste; attempt=$attempt changeCount=$change_before row=$(visible_row '[Image #')"
  fi
  p4_finished=1
  break
done
if [ "$p4_finished" -eq 0 ] && [ "$p4_contested" -eq 2 ]; then
  record P4 "CONTESO" "rigirare; both attempts saw the user's pasteboard change"
fi
t4a_stop_bench

# P1 is a fresh Claude so `[Image #1]` cannot be inherited from P4.
start_claude "$WORK/chat-p1"
claude_state=$?
if [ "$claude_state" -ne 0 ]; then
  reason="Claude did not reach an attached input line"
  [ "$claude_state" -eq 2 ] && reason="log in once with CLAUDE_CONFIG_DIR=$CLAUDE_HOME claude /login"
  record P1 "NOT RUN" "$reason"
else
  send "composer-mode always"
  send "fire Message This Session"
  send "drop-file $PNG"
  send "composer-send"
  found=0
  for _ in $(seq 1 30); do
    dump p1-live || break
    if screen_has "[Image #1]"; then found=1; break; fi
    sleep 0.1
  done
  if [ "$found" -eq 1 ]; then
    record P1 PASS "row=$(visible_row '[Image #1]')"
    send "key ctrl-c"
  else
    record P1 FAIL "row=$(visible_row '[Image #' 2>/dev/null || printf '""')"
  fi
fi
t4a_stop_bench

# P5 is fresh too: its visible attachment must come from the TemporaryItems
# file URL just installed on the pasteboard, not from an earlier Claude input.
start_claude "$WORK/chat-p5"
claude_state=$?
if [ "$claude_state" -ne 0 ]; then
  reason="Claude did not reach an attached input line"
  [ "$claude_state" -eq 2 ] && reason="log in once with CLAUDE_CONFIG_DIR=$CLAUDE_HOME claude /login"
  record P5 "NOT RUN" "$reason"
elif ! finder_clipboard "$P5_PNG"; then
  record P5 "NOT RUN" "Finder refused the clipboard write (automation permission?)"
else
  send "composer-mode never"
  send "focus-pane"
  send "paste-here"
  found=0
  for _ in $(seq 1 30); do
    dump p5-live || break
    if screen_has "[Image #1]"; then found=1; break; fi
    sleep 0.1
  done
  if [ "$found" -eq 1 ]; then
    record P5 PASS "row=$(visible_row '[Image #1]')"
    send "key ctrl-c"
  else
    record P5 FAIL "row=$(visible_row '[Image #' 2>/dev/null || printf '""')"
  fi
fi

if [ -n "$HEAD" ]; then
  # The old bundle cannot construct the two-type pasteboard fixture itself.
  # The current test channel creates it, then exits; NSPasteboard owns the
  # content, so HEAD receives the exact same file-url + misleading string.
  if start_app "$CONFIG_HOME" "$APP"; then
    send "clipboard-file $FILE\tname.mov"
    dump head-seed || true
    t4a_stop_bench
    if start_app "$CONFIG_HOME" "$HEAD"; then
      head_capture="$WORK/head-p2.raw"
      if start_capture_legacy "$head_capture" paste; then
        head_fire "Paste"
        if wait_capture "$head_capture"; then
          actual="$(/usr/bin/python3 - "$head_capture" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1]).read_bytes()
s, e = b"\x1b[200~", b"\x1b[201~"
i, j = d.find(s), d.find(e)
print(d[i+len(s):j].decode("utf-8", "replace") if i >= 0 and j >= 0 else "<no frame>")
PY
)"
          if [ "$actual" = name.mov ]; then
            record H-P2 PASS "HEAD reproduced the bare display name; payload=\"$actual\""
          else
            record H-P2 FAIL "HEAD payload=$(printf '%q' "$actual")"
          fi
        else
          record H-P2 "NOT RUN" "HEAD byte dump did not arrive"
        fi
      else
        record H-P2 "NOT RUN" "HEAD pty reader did not start"
      fi
    else
      record H-P2 "NOT RUN" "HEAD bundle/channel did not start"
    fi
  else
    record H-P2 "NOT RUN" "current channel could not seed the Finder fixture"
  fi
  t4a_stop_bench

  # Seed the same file-url + quoted-string fixture P1-PTY used. HEAD cannot
  # construct it, and cannot understand `paste-here`, so its own `activate`
  # plus `fire Paste` is the declared compatibility road.
  if start_app "$CONFIG_HOME" "$APP"; then
    send "clipboard-file $PNG\t\"$PNG\""
    dump head-p1-seed || true
    t4a_stop_bench
    start_claude "$WORK/chat-head-p1" "$HEAD"
    head_state=$?
    if [ "$head_state" -ne 0 ]; then
      attached="unreadable"
      [ -s "$DUMP" ] && attached="$(field "($pane_expr).get('attached',False)")"
      record H-P1 "NOT RUN" \
        "HEAD Claude did not reach an attached input line; attached=$attached lastRow=$(last_screen_row)"
    else
      send "composer-mode always"
      head_fire "Message This Session"
      head_fire "Paste"
      send "composer-send"
      sleep 1
      dump head-p1-live || true
      if ! screen_has "[Image #1]" && screen_has "prova paste fedele"; then
        record H-P1 PASS "HEAD reproduced quoted text; row=$(visible_row 'prova paste fedele')"
      else
        record H-P1 FAIL "row=$(visible_row '[Image #' 2>/dev/null || visible_row 'prova paste fedele')"
      fi
    fi
  else
    record H-P1 "NOT RUN" "current channel could not seed the quoted image fixture"
  fi
fi

[ "$STATUS" -eq 0 ] && echo "paste fedele: every runnable pole held" \
  || echo "paste fedele: FAIL, NOT RUN, or CONTESO above"
exit "$STATUS"
