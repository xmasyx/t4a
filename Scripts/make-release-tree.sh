#!/bin/bash
# Rebuilds the public tree from scratch (ISC-138).
#
#   Scripts/make-release-tree.sh [destination]
#
# The public repo is a NEW history, not this one: one commit out of forty-two
# in here carries a real name and a machine's hostname, and one is enough to
# make the whole history unpublishable. Rewriting it would break every stub in
# the ISA that points at a hash, so the release is a fresh `git init` holding
# only the files this repo tracks.
#
# It was copied by hand the first time and the audit's repairs arrived
# afterwards, which is the reason this exists: a tree assembled by hand is a
# tree that silently stops matching the source the moment anything changes.
# Run it twice and the second run must produce the same file list.
#
# It ends with the gates rather than a promise: the identity sweep over both
# the files and the log, a release build, the tests, and the seam check. Any of
# them failing stops the script, so a tree that fails is never left looking
# finished.
#
# It adds no remote and pushes nothing. Publishing is a person's decision.

set -uo pipefail
cd "$(dirname "$0")/.."
SOURCE="$PWD"

DESTINATION="${1:-$(cd .. && pwd)/T4A-release}"
NAME="xmasyx"
EMAIL="16624475+xmasyx@users.noreply.github.com"
SUBJECT="T4A 0.1.0 — a GPU-drawn terminal that treats agent sessions as objects"

# Everything the sweep must not find, in the tracked files OR in the log.
#
# It lives in a gitignored FILE rather than in this script, and that is not
# tidiness: the list is the author's own name and projects, so a script
# carrying it inline is a script that publishes the thing it is looking for —
# and, on the first run of this one, trips its own sweep. Whole words for the
# project names, because a pattern that also matched innocent words would
# train whoever runs this to ignore it.
#
# Missing, the script STOPS. Running the release build with no sweep at all is
# the one outcome worth refusing outright.
PATTERN_FILE="$SOURCE/Scripts/release/identity.pattern"
[ -s "$PATTERN_FILE" ] || die "no identity pattern at $PATTERN_FILE; refusing to publish unswept"
PATTERN="$(head -1 "$PATTERN_FILE")"

say() { printf '%s\n' "$*"; }
die() { printf 'STOPPED: %s\n' "$*" >&2; exit 1; }

case "$DESTINATION" in
  "$SOURCE"|"$SOURCE"/*) die "the destination is inside the source: $DESTINATION" ;;
  /|"$HOME") die "refusing to treat $DESTINATION as a build directory" ;;
esac

command -v git >/dev/null || die "no git"
command -v swift >/dev/null || die "no swift"
[ -d "$SOURCE/.git" ] || die "$SOURCE is not a git repository"

# A public tree has to correspond to a commit. rsync copies the WORKING TREE
# content of the tracked paths, so building from a dirty repo produces a
# published tree that matches nothing in the history — including, on the run
# that found this, a half-finished edit of the script doing the copying.
DIRTY="$(git -C "$SOURCE" status --porcelain)"
if [ -n "$DIRTY" ] && [ "${T4A_ALLOW_DIRTY:-0}" != "1" ]; then
  printf '%s\n' "$DIRTY"
  die "the source tree is dirty; commit first, or set T4A_ALLOW_DIRTY=1 to publish it anyway"
fi
[ -n "$DIRTY" ] && say "==> WARNING: publishing a dirty tree, on request"

say "==> source      $SOURCE at $(git -C "$SOURCE" rev-parse --short HEAD)"
say "==> destination $DESTINATION"

# From zero. A destination that is emptied instead of deleted keeps whatever
# the last run left behind, which is the failure this claim is about.
if [ -e "$DESTINATION" ]; then
  [ -d "$DESTINATION/.git" ] || [ -z "$(ls -A "$DESTINATION" 2>/dev/null)" ] \
    || die "$DESTINATION exists and is not a git tree; not deleting it"
  rm -rf "$DESTINATION"
fi
mkdir -p "$DESTINATION"

# Only what the source TRACKS. `git ls-files` and not a copy of the directory,
# so anything gitignored here — the ISA, the briefs, the bench screenshots, the
# local demo data — cannot arrive by being present on the disk.
git -C "$SOURCE" ls-files -z > /tmp/t4a-release-files.z
COUNT="$(git -C "$SOURCE" ls-files | wc -l | tr -d ' ')"
say "==> copying $COUNT tracked files"
( cd "$SOURCE" && rsync -a --files-from=- --from0 . "$DESTINATION" < /tmp/t4a-release-files.z ) \
  || die "the copy failed"

# The public .gitignore replaces this repo's, which is written for the person
# working here. The lines naming private files STAY even though those files are
# not in this tree: they cost five lines and they fail closed the day somebody
# copies an ISA.md into it.
cp "$SOURCE/Scripts/release/gitignore.public" "$DESTINATION/.gitignore"

cd "$DESTINATION" || die "cannot enter $DESTINATION"
git init -q
# LOCAL, never inherited: the global identity on this machine is a real name.
git config user.name "$NAME"
git config user.email "$EMAIL"
git add -A
git -c commit.gpgsign=false commit -q -m "$SUBJECT" || die "the commit failed"

say ""
say "=== the gates, on the tree that was just built ======================"

say "--> the identity sweep, over the files"
# One home path is SANCTIONED, and it is named here rather than carved out of
# the pattern: `/Users/example` is the placeholder every fixture and every
# sample uses. It is neutralised before the grep instead of being excluded
# inside it, so the home-directory prefix stays as broad in the pattern as it
# ever was, and any OTHER name under it still trips the sweep. Widening the pattern to let the fixtures through would
# have been the easy fix and the wrong one (ISC-247, 2026-09-06).
SANCTIONED='/Users/example'
if git ls-files -z | while IFS= read -r -d "" f; do
     sed "s#$SANCTIONED#<HOME>#g" "$f" 2>/dev/null | grep -InE "$PATTERN" | sed "s#^#$f:#"
   done | grep .; then
  die "the sweep found something in the tracked files"
fi
say "    clean ($(git ls-files | wc -l | tr -d ' ') files)"

say "--> the identity sweep, over the log"
if git log --format='%an <%ae> %s%n%b' | grep -InE "$PATTERN"; then
  die "the sweep found something in the history"
fi
say "    clean ($(git log --oneline | wc -l | tr -d ' ') commit, $(git log -1 --format='%an <%ae>'))"

say "--> swift build -c release"
swift build -c release > /tmp/t4a-release-build.log 2>&1 || {
  tail -20 /tmp/t4a-release-build.log; die "the release build failed"; }
say "    built"

say "--> swift test"
swift test > /tmp/t4a-release-test.log 2>&1 || {
  tail -20 /tmp/t4a-release-test.log; die "the tests failed"; }
say "    $(grep -oE 'Test run with [0-9]+ tests[^.]*' /tmp/t4a-release-test.log | tail -1)"

say "--> Scripts/drive.sh check-seam"
./Scripts/drive.sh check-seam || die "the engine is not behind the grid interface"

say "--> the build left nothing behind"
DIRT="$(git status --porcelain)"
[ -z "$DIRT" ] || { printf '%s\n' "$DIRT"; die "the tree is dirty after building"; }
say "    git status is empty"

say ""
say "the tree is at $DESTINATION — no remote, nothing pushed."
