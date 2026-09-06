#!/bin/bash
# The screen split, by hand.
#
#   Scripts/split.sh begin     his terminal → left half (saved), for a stretch of work that opens windows
#   Scripts/split.sh end       every parked terminal back where it was — the work is over
#   Scripts/split.sh status    what is parked right now
#
# Benches call the same library on their own; this is for the DA between them
# and at the end (his request, 2026-09-05: half screen while I work, full again
# when I am done).
set -uo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib/bench-split.sh
case "${1:-}" in
  begin) t4a_split_screen "" ;;
  end) t4a_split_end ;;
  status) ls "$T4A_SPLIT_DIR"/*.frame 2>/dev/null | while read -r f; do echo "$(basename "$f" .frame): $(cat "$f")"; done; [ -n "$(ls "$T4A_SPLIT_DIR"/*.frame 2>/dev/null)" ] || echo "nothing parked" ;;
  *) echo "usage: $0 begin|end|status" >&2; exit 2 ;;
esac
