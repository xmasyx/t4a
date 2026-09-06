T4A_SHIM_DIR=${ZDOTDIR:-$0:A:h}
ZDOTDIR=$T4A_USER_ZDOTDIR
[[ -r "$T4A_USER_ZDOTDIR/.zlogin" ]] && source "$T4A_USER_ZDOTDIR/.zlogin"
__t4a_restore_histfile
unset T4A_SHIM_DIR
unset -f __t4a_restore_histfile 2>/dev/null
