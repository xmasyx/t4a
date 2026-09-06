#!/bin/bash
# Runs a bench and proves it left the machine alone (ISC-132).
#
#   Scripts/bench-untouched.sh Scripts/bench-f5.sh all
#
# The claim is about EVERY bench, not the two the audit happened to read, and a
# claim about every bench is cheapest to keep as a wrapper: whatever the bench
# does inside, the two files a user would mind losing are hashed before and
# after and compared here. It exits with the bench's own status unless a file
# moved, in which case it exits 1 whatever the bench thought of itself.
#
# The two files: T4A's own configuration, and the agent's — the one that
# carries which folders you have told claude you trust.

set -uo pipefail
cd "$(dirname "$0")/.."

# Both poles, because a guard that has only ever said "unchanged" has never
# been shown to be able to say anything else.
if [ "${1:-}" = "--selftest" ]; then
  probe="$(mktemp /tmp/t4a-untouched-probe.XXXXXX)"
  echo "before" > "$probe"
  echo "-- the positive pole: a command that touches nothing"
  T4A_UNTOUCHED_EXTRA="$probe" "$0" true
  good=$?
  echo ""
  echo "-- the negative pole: a command that writes into a watched file"
  T4A_UNTOUCHED_EXTRA="$probe" "$0" sh -c "echo after >> '$probe'"
  bad=$?
  rm -f "$probe"
  echo ""
  if [ "$good" = "0" ] && [ "$bad" = "1" ]; then
    echo "untouched: both poles held (clean 0, dirty 1)"; exit 0
  fi
  echo "untouched: SELFTEST FAILED (clean $good, dirty $bad)"; exit 1
fi

[ "$#" -ge 1 ] || { echo "usage: $0 <bench script> [args...]   |   $0 --selftest" >&2; exit 2; }

WATCHED=(
  "$HOME/.config/t4a/config.toml"
  "$HOME/.claude.json"
  "$HOME/.codex/config.toml"
)
[ -n "${T4A_UNTOUCHED_EXTRA:-}" ] && WATCHED+=("$T4A_UNTOUCHED_EXTRA")

hash_of() { [ -e "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "(absent)"; }

BEFORE=()
for file in "${WATCHED[@]}"; do BEFORE+=("$(hash_of "$file")"); done

"$@"
BENCH_STATUS=$?

echo ""
echo "=== ISC-132: what the bench did NOT touch ==========================="
DRIFT=0
for index in "${!WATCHED[@]}"; do
  file="${WATCHED[$index]}"
  after="$(hash_of "$file")"
  if [ "$after" = "${BEFORE[$index]}" ]; then
    printf '  ok      %s  %s\n' "${after:0:16}" "$file"
  else
    printf '  CHANGED %s -> %s  %s\n' "${BEFORE[$index]:0:16}" "${after:0:16}" "$file"
    DRIFT=1
  fi
done
# A file nobody has is not evidence of anything, and saying so beats a row of
# green ticks over three absences.
[ "$DRIFT" = "0" ] && echo "  the machine is as it was" \
  || echo "  A BENCH WROTE INTO THE REAL SETUP"

[ "$DRIFT" = "0" ] || exit 1
exit "$BENCH_STATUS"
