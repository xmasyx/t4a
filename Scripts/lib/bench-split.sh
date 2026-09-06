#!/bin/bash
# Screen split for benches that open a window (his request, 2026-09-05 23:1x:
# «quando devi aprire delle schede per verificare, mi rendi la mia pagina del
# terminale metà dello schermo e quella che apri tu l'altra metà, così posso
# continuare a lavorare»).
#
#   source Scripts/lib/bench-split.sh
#   t4a_split_screen "$BENCH_PID"     # his terminal → left half, the bench → right half
#   t4a_split_end                     # his terminal back where it was — at the END OF THE WORK
#
# The split lasts for the whole piece of work, not for one bench (his second
# request, 23:20: «tienilo a metà schermo finché non è finito di lavorare e
# poi rimettilo a fullscreen»): the first bench of a session saves his frame
# under /tmp/t4a-split/<pid>.frame and every later one finds it already
# saved and leaves it alone; `Scripts/split.sh end` restores it when the DA
# says the work is done. `Scripts/split.sh begin` parks his terminal without
# a bench, for the stretches where the DA is about to open windows itself.
#
# "His terminal" is whatever app hosts the shell this bench runs from (iTerm,
# T4A, …), found by walking the parent chain, never by name: the day he moves
# to another terminal this keeps working. The bench window is moved through
# the test channel (`send` must exist), his through Accessibility
# (`Scripts/axframe.swift`), which only works from a trusted host; when it
# is not, the split is skipped and said, never faked.
T4A_SPLIT_SAVED=""
T4A_SPLIT_HOST=""
T4A_SPLIT_DIR="/tmp/t4a-split"

t4a_host_pid() {
  local p=$$ c
  for _ in 1 2 3 4 5 6 7 8; do
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [ -n "$p" ] && [ "$p" != "1" ] || return 1
    c="$(ps -o comm= -p "$p" 2>/dev/null)"
    case "$c" in *.app/Contents/MacOS/*) printf '%s\n' "$p"; return 0 ;; esac
  done
  return 1
}

t4a_screen_size() {
  osascript -e 'tell application "Finder" to get bounds of window of desktop' | awk -F', ' '{print $3, $4}'
}

t4a_split_screen() {
  local bench_pid="$1" sw sh half
  read -r sw sh <<< "$(t4a_screen_size)"
  [ -n "$sw" ] && [ -n "$sh" ] || { echo "split: no screen size" >&2; return 1; }
  half=$(( sw / 2 ))
  local frame=".build/t4a-axframe"
  if [ ! -x "$frame" ] || [ Scripts/axframe.swift -nt "$frame" ]; then
    mkdir -p .build && swiftc -O Scripts/axframe.swift -o "$frame" 2>/dev/null
  fi
  if T4A_SPLIT_HOST="$(t4a_host_pid)"; then
    mkdir -p "$T4A_SPLIT_DIR"
    local saved="$T4A_SPLIT_DIR/$T4A_SPLIT_HOST.frame"
    if [ -s "$saved" ]; then
      # Already parked by an earlier bench of this work: the saved frame is
      # the one to go back to, never the half-screen one we would read now.
      T4A_SPLIT_SAVED="$(cat "$saved")"
      "$frame" "$T4A_SPLIT_HOST" 0 25 "$half" $(( sh - 25 )) >/dev/null
      printf '%-48s %s\n' "  split: his terminal (pid $T4A_SPLIT_HOST) kept on the left" "will go back to $T4A_SPLIT_SAVED at the end of the work"
    elif T4A_SPLIT_SAVED="$("$frame" "$T4A_SPLIT_HOST" 2>/dev/null)"; then
      printf '%s\n' "$T4A_SPLIT_SAVED" > "$saved"
      # Top-left origin, under the menu bar.
      "$frame" "$T4A_SPLIT_HOST" 0 25 "$half" $(( sh - 25 )) >/dev/null
      printf '%-48s %s\n' "  split: his terminal (pid $T4A_SPLIT_HOST) → left half" "was $T4A_SPLIT_SAVED (saved in $saved)"
    else
      T4A_SPLIT_SAVED=""
      printf '%-48s %s\n' "  split: his terminal NOT moved" "Accessibility not granted to the host, or no window"
    fi
  else
    printf '%-48s %s\n' "  split: his terminal NOT moved" "no hosting app found on the parent chain"
  fi
  # The bench window: Cocoa origin (bottom-left), so y = 0 is the bottom.
  # `send` is the bench's own channel function; with none (split.sh begin)
  # there is no bench window to place.
  if [ -n "$bench_pid" ] && declare -F send >/dev/null; then
    send "resize ${half}x$(( sh - 25 ))"; sleep 0.3
    send "movewindow ${half},0"; sleep 0.3
  fi
}

# Puts every parked terminal back. Called when the WORK is over, not when a
# bench is: a bench never calls this.
t4a_split_end() {
  local frame=".build/t4a-axframe" saved pid
  [ -d "$T4A_SPLIT_DIR" ] || { echo "split: nothing parked"; return 0; }
  for saved in "$T4A_SPLIT_DIR"/*.frame; do
    [ -e "$saved" ] || continue
    pid="$(basename "$saved" .frame)"
    if kill -0 "$pid" 2>/dev/null; then
      # shellcheck disable=SC2046
      "$frame" "$pid" $(cat "$saved") >/dev/null 2>&1 \
        && printf '%-48s %s\n' "  split: terminal $pid restored" "$(cat "$saved")" \
        || printf '%-48s %s\n' "  split: terminal $pid NOT restored" "Accessibility refused"
    else
      printf '%-48s %s\n' "  split: terminal $pid is gone" "nothing to restore"
    fi
    rm -f "$saved"
  done
}
