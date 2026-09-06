#!/bin/bash
# ISC-240 — Command-hover links in the terminal grid.
#
#   Scripts/bench-link.sh [--head /path/to/HEAD/T4A.app]
#
# The main poles drive dist/T4A.app. --head adds L6 against an older bundle;
# it is supplied by the caller because this bench never runs git or builds a
# second tree behind the reader's back.

set -euo pipefail
cd "$(dirname "$0")/.."
source "$(dirname "$0")/lib/bench-stop.sh"

APP="dist/T4A.app"
HEAD_APP=""
if [ "${1:-}" = "--head" ]; then
  HEAD_APP="${2:?--head needs a T4A.app path}"
fi

FIFO="/tmp/t4a-link.fifo"
CONFIG_HOME="/tmp/t4a-link-config"
FIXTURE="/tmp/t4a-link-lines.txt"
SPACE_DIR="/tmp/t4a link bench"
SPACE_FILE="$SPACE_DIR/file with spaces.txt"
MISSING="/tmp/t4a-link-this-does-not-exist-240"
URL="https://example.com/search?q=terminal%20links&mode=cmd"
LONG_DIR="/tmp/t4a-link-long/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
LONG_FILE="$LONG_DIR/wrapped-target.txt"
DUMP="/tmp/t4a-link-dump.json"
PHOTO="design/evidence/f14-240-link-hover.png"
COMMAND_HELD=0
ORIGINAL_FRONT_PID=""
FOCUS_BORROWED=0

send() { /usr/bin/python3 Scripts/sendline.py "$FIFO" "$1"; }
command_down() {
  COMMAND_HELD=1
  .build/t4a-keymodifier cmd down
}
command_up() {
  .build/t4a-keymodifier cmd up
  COMMAND_HELD=0
}
restore_front() {
  [ "$FOCUS_BORROWED" -eq 1 ] || return 0
  if .build/t4a-appfocus activate "$ORIGINAL_FRONT_PID"; then
    FOCUS_BORROWED=0
    return 0
  fi
  echo "      original front app pid $ORIGINAL_FRONT_PID could not be restored" >&2
  return 1
}
cleanup() {
  if [ "$COMMAND_HELD" -eq 1 ] && [ -x .build/t4a-keymodifier ]; then
    .build/t4a-keymodifier cmd up >/dev/null 2>&1 || true
  fi
  restore_front || true
  t4a_stop_bench
  rm -f "$FIFO"
  t4a_bench_unlock
}
trap cleanup EXIT INT TERM

dump_to() {
  DUMP="$1"
  rm -f "$DUMP"
  send "dump $DUMP"
  for _ in $(seq 1 40); do [ -s "$DUMP" ] && break; sleep 0.1; done
  [ -s "$DUMP" ] || { echo "dump did not arrive: $DUMP" >&2; exit 1; }
}

# Prints the screen coordinate of a character inside a visible marker. The
# calculation uses the renderer's cell width and the surface rectangle that
# the app itself dumped; no pixel or window position is guessed by the bench.
point_for() {
  /usr/bin/python3 - "$DUMP" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
needle = sys.argv[2]
pane = d["tabs"][0]["panes"][0]
for row, line in enumerate(pane["screen"]):
    column = line.find(needle)
    if column >= 0:
        surface = pane["surfaceRect"]
        cell_width = pane["renderer"].get("cellWidth", surface["w"] / pane["columns"])
        cell_height = pane["renderer"].get("cellHeight", pane["cellHeight"])
        x = surface["x"] - surface["w"] / 2 + (column + 0.5) * cell_width
        y = surface["y"] + surface["h"] / 2 - (row + 0.5) * cell_height
        print(f"{x:.2f} {y:.2f}")
        raise SystemExit(0)
raise SystemExit(f"marker not visible: {needle!r}")
PY
}

show_line() {
  send "clearbuffer"
  sleep 0.25
  send "text sed -n '${1}p' '$FIXTURE'"
  send "key return"
  sleep 0.8
  dump_to "$2"
}

launch_bundle() {
  local bundle="$1"
  rm -rf "$CONFIG_HOME"
  rm -f "$FIFO"
  mkdir -p "$CONFIG_HOME/t4a"
  printf 'theme = "black"\ncomposer-mode = "never"\nchat-page = false\npure-chat = false\n' \
    > "$CONFIG_HOME/t4a/config.toml"
  open -g -n "$bundle" --env T4A_TEST_CHANNEL="$FIFO" --env XDG_CONFIG_HOME="$CONFIG_HOME"
  for _ in $(seq 1 60); do [ -p "$FIFO" ] && break; sleep 0.2; done
  [ -p "$FIFO" ] || { echo "the test channel never appeared for $bundle" >&2; exit 1; }
  sleep 2
}

# The cursor shown by macOS belongs to the active app. This is a declared
# precondition of L1/L3, procured immediately before the gesture and verified
# before a WindowServer event is posted. Every other pole stays background.
# A Command-hover that is expected to find a link. The move is retried,
# leaving and re-entering the cell, because event delivery is the flaky
# part of this bench (his pointer, a focus hand-off, macOS 26 turning
# mouse-moved reporting on only after a real ⌘): the pole measures the
# resolver, so the pointer is procured like the focus is, and a link that
# never appears after three real entries is a red that means something.
# Leaves Command held when the dump has a hover, so a caller can release it
# for L3; releases it itself when it gives up.
hover_link() {  # x y dump
  local x="$1" y="$2" out="$3" attempt
  for attempt in 1 2 3; do
    command_down
    .build/t4a-movepoint "$x" "$y" cmd
    sleep 0.5
    dump_to "$out"
    if /usr/bin/python3 -c "import json,sys; sys.exit(0 if 'linkHover' in json.load(open('$out')) else 1)"; then
      return 0
    fi
    command_up
    .build/t4a-movepoint "$((${x%.*} + 260))" "$((${y%.*} + 120))"
    sleep 0.3
  done
  return 1
}

activate_cursor_pole() {
  local attempt active
  FOCUS_BORROWED=1
  for attempt in 1 2 3; do
    # macOS 14+ cooperative activation: un'app in background che chiama
    # NSApp.activate su di se' puo' essere rifiutata. Launch Services (`open`
    # sul bundle gia' vivo) ottiene il fuoco davvero (sonda 31/08 20:35:
    # appActive True al primo colpo, mentre il solo verbo restava False).
    open "$APP" 2>/dev/null || true
    send "activate"
    sleep 0.5
    dump_to /tmp/t4a-link-l1-active.json
    active="$(/usr/bin/python3 - <<'PY'
import json
print(json.load(open('/tmp/t4a-link-l1-active.json')).get('appActive', False))
PY
)"
    [ "$active" = "True" ] && return 0
  done
  echo "NOT RUN  L1/L3 cursor: bench app did not become active (appActive=$active)" >&2
  return 1
}

mkdir -p "$SPACE_DIR" "$LONG_DIR" .build design/evidence
printf 'link bench\n' > "$SPACE_FILE"
printf 'wrapped link bench\n' > "$LONG_FILE"
rm -f "$MISSING"
printf '"%s"\n%s\nordinary words only\n%s\n"%s"\n' \
  "$SPACE_FILE" "$URL" "$MISSING" "$LONG_FILE" > "$FIXTURE"

for tool in movepoint clickpoint keymodifier appfocus; do
  [ -x ".build/t4a-$tool" ] || swiftc -O "Scripts/$tool.swift" -o ".build/t4a-$tool"
done
ORIGINAL_FRONT_PID="$(.build/t4a-appfocus current || true)"
[ -n "$ORIGINAL_FRONT_PID" ] || {
  echo "could not identify the app that must regain focus after L1/L3" >&2
  exit 1
}

if [ ! -d "$APP" ]; then
  echo "missing $APP; run Scripts/build-app.sh first" >&2
  exit 1
fi

t4a_note_his_app
t4a_stop_bench
launch_bundle "$APP"

echo "=== L1 path with spaces + Command-hover ========================="
show_line 1 /tmp/t4a-link-l1-before.json
read -r X Y < <(point_for "file with spaces.txt")
activate_cursor_pole
hover_link "$X" "$Y" /tmp/t4a-link-l1.json || true
BENCH_PID="$(t4a_bench_pids | head -1)"
if [ -n "$BENCH_PID" ]; then
  Scripts/shot.sh "$BENCH_PID" "$PHOTO" >/dev/null 2>&1 \
    || echo "      photo NOT RUN (screen capture unavailable)"
fi

echo "=== L3 stationary hover after Command release ==================="
command_up
sleep 0.5
dump_to /tmp/t4a-link-l3.json
# Rendere il fuoco all'app di partenza e' una CORTESIA, non una misura, e sotto
# `set -e` il suo `return 1` uccideva la corsa a meta': il 6/09 L1 e L3 avevano
# gia' misurato bene e i loro dump sono rimasti sul disco senza che nessun polo
# venisse stampato, perche' l'attivazione cooperativa di macOS 14 aveva rifiutato
# sia il terminale di partenza sia il Finder. I poli che seguono vogliono T4A
# davanti, non l'app di prima: il fallimento si dice forte e si continua.
restore_front || echo "      focus not returned; the poles below do not need it"

echo "=== L2 URL hover + Command-click ================================"
# Il fuoco si riafferma PRIMA di ogni polo, non una volta sola all'inizio: una
# corsa lunga lo perde per strada (macOS 14 puo' rifiutare l'attivazione, e il
# 6/09 l'ha rifiutata) e un polo che misura senza fuoco misura il nulla e lo
# chiama rosso. L1 passava e L2/L5 fallivano per questo, non per il codice.
activate_cursor_pole
show_line 2 /tmp/t4a-link-l2-before.json
read -r X Y < <(point_for "example.com")
# The Command KEY, not only the flag on the synthetic move: on macOS 26
# SwiftTerm turns mouse-moved delivery on in flagsChanged, so a move that
# carries the flag without the key never reaches any monitor (6/09: L5 red
# on two runs out of three, green whenever a real ⌘ had been pressed since
# the window opened).
hover_link "$X" "$Y" /tmp/t4a-link-l2-hover.json || true
.build/t4a-clickpoint "$X" "$Y" 40 cmd
sleep 0.5
dump_to /tmp/t4a-link-l2.json
command_up

echo "=== L4 ordinary text and a missing path ========================="
activate_cursor_pole
show_line 3 /tmp/t4a-link-l4a-before.json
read -r X Y < <(point_for "ordinary")
command_down
.build/t4a-movepoint "$X" "$Y" cmd
sleep 0.4
dump_to /tmp/t4a-link-l4a.json
command_up
show_line 4 /tmp/t4a-link-l4b-before.json
read -r X Y < <(point_for "does-not-exist")
command_down
.build/t4a-movepoint "$X" "$Y" cmd
sleep 0.4
dump_to /tmp/t4a-link-l4b.json
command_up

echo "=== L5 one path across soft-wrapped rows ========================"
activate_cursor_pole
show_line 5 /tmp/t4a-link-l5-before.json
read -r X Y < <(point_for "wrapped-target")
hover_link "$X" "$Y" /tmp/t4a-link-l5.json || true
command_up

t4a_stop_bench
rm -f "$FIFO"

HEAD_RAN=0
if [ -n "$HEAD_APP" ]; then
  echo "=== L6 negative bundle =========================================="
  [ -d "$HEAD_APP" ] || { echo "HEAD bundle does not exist: $HEAD_APP" >&2; exit 1; }
  FIFO="/tmp/t4a-link-head.fifo"
  CONFIG_HOME="/tmp/t4a-link-head-config"
  launch_bundle "$HEAD_APP"
  for item in "1:file with spaces.txt:h1" "2:example.com:h2" "5:wrapped-target:h5"; do
    IFS=: read -r LINE MARK NAME <<<"$item"
    show_line "$LINE" "/tmp/t4a-link-${NAME}-before.json"
    read -r X Y < <(point_for "$MARK")
    command_down
    .build/t4a-movepoint "$X" "$Y" cmd
    sleep 0.35
    dump_to "/tmp/t4a-link-${NAME}.json"
    command_up
  done
  HEAD_RAN=1
  t4a_stop_bench
  rm -f "$FIFO"
else
  echo "=== L6 NOT RUN: pass --head /path/to/HEAD/T4A.app =============="
fi

/usr/bin/python3 - "$SPACE_FILE" "$URL" "$LONG_FILE" "$HEAD_RAN" <<'PY'
import json, sys
space_file, url, long_file, head_ran = sys.argv[1:]
ok = True
def load(name): return json.load(open(f"/tmp/t4a-link-{name}.json"))
def check(label, condition, detail):
    global ok
    ok = ok and condition
    print(f"{'PASS' if condition else 'FAIL'}  {label}: {detail}")

l1_active = load("l1-active")
l1_before = load("l1-before")
l1, l2, l3 = load("l1"), load("l2"), load("l3")
l4a, l4b, l5 = load("l4a"), load("l4b"), load("l5")
h1 = l1.get("linkHover", {})
rect = h1.get("rect", {})
check("L1 cursor precondition was procured",
      l1_active.get("appActive") is True and l1.get("appActive") is True,
      f"before-hover={l1_active.get('appActive')}, at-dump={l1.get('appActive')}")
check("L1 path with spaces is a file link",
      h1.get("text") == space_file and h1.get("path") == space_file
      and h1.get("type") == "file" and rect.get("w", 0) > 0 and rect.get("h", 0) > 0,
      f"hover={h1!r}")
check("L1 cursor is the pointing hand", l1["window"]["cursor"] == "pointingHand",
      f"cursor={l1['window']['cursor']}")
t0 = l1_before.get("cursorTrace", {})
t1 = l1.get("cursorTrace", {})
check("L1 holds exactly one cursor-stack entry",
      t1.get("pushes", 0) - t0.get("pushes", 0) == 1
      and t1.get("pops", 0) - t0.get("pops", 0) == 0,
      f"before={t0!r}, hover={t1!r}")

h2 = l2.get("linkHover", {})
opened = l2.get("linkOpen", {})
check("L2 URL keeps its query", h2.get("text") == url and h2.get("type") == "url",
      f"hover={h2!r}")
check("L2 Command-click reaches only the opening spy",
      opened.get("path") == url and opened.get("type") == "url",
      f"linkOpen={opened!r}")

check("L3 releasing Command without moving clears hover and restores the I-beam",
      "linkHover" not in l3 and l3["window"]["cursor"] == "ibeam",
      f"linkHover={'linkHover' in l3}, cursor={l3['window']['cursor']}")
t3 = l3.get("cursorTrace", {})
check("L3 releases that cursor-stack entry exactly once",
      t3.get("pushes", 0) == t1.get("pushes", 0)
      and t3.get("pops", 0) - t1.get("pops", 0) == 1
      and t3.get("pushes", 0) == t3.get("pops", 0),
      f"hover={t1!r}, release={t3!r}")
check("L4 ordinary text is not a link", "linkHover" not in l4a,
      f"linkHover={l4a.get('linkHover')!r}")
check("L4 a missing path is not a link", "linkHover" not in l4b,
      f"linkHover={l4b.get('linkHover')!r}")

h5 = l5.get("linkHover", {})
span = h5.get("span", {})
check("L5 the whole soft-wrapped path is one link",
      h5.get("path") == long_file and h5.get("text") == long_file
      and span.get("endRow", 0) > span.get("startRow", 0)
      and len(h5.get("rects", [])) >= 2,
      f"path={h5.get('path')!r}, span={span!r}, rects={len(h5.get('rects', []))}")

if head_ran == "1":
    heads = [load("h1"), load("h2"), load("h5")]
    check("L6 HEAD has no terminal-link layer",
          all("linkHover" not in item and "linkOpen" not in item for item in heads),
          f"keys={[sorted(set(item) & {'linkHover', 'linkOpen'}) for item in heads]}")
else:
    print("NOT RUN  L6 HEAD negative: no --head bundle was supplied")

raise SystemExit(0 if ok else 1)
PY
