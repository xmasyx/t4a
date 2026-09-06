T4A_SHIM_DIR=${ZDOTDIR:-$0:A:h}
ZDOTDIR=$T4A_USER_ZDOTDIR
[[ -r "$T4A_USER_ZDOTDIR/.zshrc" ]] && source "$T4A_USER_ZDOTDIR/.zshrc"
[[ -r "$T4A_SHIM_DIR/t4a-integration.zsh" ]] && source "$T4A_SHIM_DIR/t4a-integration.zsh"
__t4a_restore_histfile
# Login shells still have .zlogin to read; non-login shells end here, so the
# handback happens in both places and is written to be harmless twice.
if [[ ! -o login ]]; then
  ZDOTDIR=$T4A_USER_ZDOTDIR
  unset T4A_SHIM_DIR
else
  ZDOTDIR=$T4A_SHIM_DIR
fi
