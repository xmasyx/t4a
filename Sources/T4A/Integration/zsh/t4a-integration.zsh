# T4A shell integration for zsh — OSC 133 command blocks.
#
# Loaded through ZDOTDIR, so nothing under $HOME is ever written or edited.
# Sourced last, after the user's own .zshrc, so the hooks survive whatever the
# user's configuration does to precmd_functions.

if [[ -n "$T4A_INTEGRATION_LOADED" ]]; then
  return 0
fi
T4A_INTEGRATION_LOADED=1

autoload -Uz add-zsh-hook 2>/dev/null || return 0

__t4a_osc() { builtin printf '\033]%s\007' "$1" }

__t4a_precmd() {
  local status_code=$?
  if [[ -n "$__t4a_command_running" ]]; then
    __t4a_osc "133;D;${status_code}"
    unset __t4a_command_running
  fi
  __t4a_osc "133;A"
  # Mark where the prompt ends and typing begins. Guarded so a prompt that is
  # rebuilt on every draw does not accumulate copies of the marker.
  if [[ "$PS1" != *"133;B"* ]]; then
    PS1="${PS1}"$'%{\033]133;B\007%}'
  fi
}

__t4a_preexec() {
  local encoded
  encoded=$(builtin print -rn -- "$1" | base64 | tr -d '\n')
  __t4a_osc "633;E;${encoded}"
  __t4a_osc "133;C"
  __t4a_command_running=1
}

add-zsh-hook precmd __t4a_precmd
add-zsh-hook preexec __t4a_preexec
