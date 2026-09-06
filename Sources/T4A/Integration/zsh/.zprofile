T4A_SHIM_DIR=${ZDOTDIR:-$0:A:h}
ZDOTDIR=$T4A_USER_ZDOTDIR
[[ -r "$T4A_USER_ZDOTDIR/.zprofile" ]] && source "$T4A_USER_ZDOTDIR/.zprofile"
ZDOTDIR=$T4A_SHIM_DIR
__t4a_restore_histfile
