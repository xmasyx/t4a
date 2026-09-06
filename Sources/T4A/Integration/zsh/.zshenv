# T4A: never edits the user's files. It borrows ZDOTDIR for the length of
# startup and gives it back before the first prompt.
T4A_SHIM_DIR=${ZDOTDIR:-$0:A:h}
: ${T4A_USER_ZDOTDIR:=$HOME}
export T4A_USER_ZDOTDIR

# Anything zsh DERIVES from ZDOTDIR must still point where the user expects.
# The history file is the one that matters: with ZDOTDIR borrowed, zsh puts
# $HISTFILE inside the app bundle, where the shell writes the user's history
# into a signed read-only directory and then blocks forever trying to take its
# lock. Measured 2026-08-20 — every shell after the first hung at startup.
__t4a_restore_histfile() {
  if [[ -z "$HISTFILE" || "$HISTFILE" == "$T4A_SHIM_DIR"/* ]]; then
    HISTFILE="$T4A_USER_ZDOTDIR/.zsh_history"
  fi
}
__t4a_restore_histfile

ZDOTDIR=$T4A_USER_ZDOTDIR
[[ -r "$T4A_USER_ZDOTDIR/.zshenv" ]] && source "$T4A_USER_ZDOTDIR/.zshenv"
ZDOTDIR=$T4A_SHIM_DIR
__t4a_restore_histfile
