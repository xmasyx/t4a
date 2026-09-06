# T4A shell integration for bash — OSC 133 command blocks.
#
# bash reads --rcfile only for an interactive, non-login shell, so T4A starts
# it that way and this file takes over the job the login sequence would have
# done: /etc/profile, then the first of the user's profile files, then their
# own .bashrc. Nothing under $HOME is written or edited.

if [ -n "$T4A_INTEGRATION_LOADED" ]; then
  return 0 2>/dev/null || true
fi
T4A_INTEGRATION_LOADED=1

# Read what the shell would have read on its own, in bash's order.
if [ -n "$T4A_BASH_LOGIN" ]; then
  [ -r /etc/profile ] && . /etc/profile
  for __t4a_candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -r "$__t4a_candidate" ]; then . "$__t4a_candidate"; break; fi
  done
  unset __t4a_candidate
fi
[ -r /etc/bashrc ] && . /etc/bashrc
[ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
unset T4A_BASH_LOGIN

__t4a_osc() { printf '\033]%s\007' "$1"; }

__t4a_prompt_command() {
  local status_code=$?
  if [ -n "$__t4a_command_running" ]; then
    __t4a_osc "133;D;${status_code}"
    __t4a_command_running=
  fi
  __t4a_osc "133;A"
  __t4a_at_prompt=1
  return $status_code
}

__t4a_preexec() {
  # The DEBUG trap also fires for the prompt command itself; only the first
  # command after a prompt is the one the user typed.
  [ -n "$__t4a_at_prompt" ] || return 0
  case "$BASH_COMMAND" in __t4a_*) return 0 ;; esac
  __t4a_at_prompt=
  # BASH_COMMAND is the first simple command of the line, so `sleep 1; echo x`
  # would be recorded as `sleep 1`. The history entry is the line the user
  # actually typed, which is the thing worth showing.
  local line encoded
  line=$(HISTTIMEFORMAT= builtin history 1)
  line=${line#*[0-9]}
  line=${line#"${line%%[![:space:]]*}"}
  [ -n "$line" ] || line="$BASH_COMMAND"
  encoded=$(printf '%s' "$line" | base64 | tr -d '\n')
  __t4a_osc "633;E;${encoded}"
  __t4a_osc "133;C"
  __t4a_command_running=1
}

case "$PS1" in
  *133\;B*) ;;
  *) PS1="${PS1}\[\033]133;B\007\]" ;;
esac

case "$PROMPT_COMMAND" in
  *__t4a_prompt_command*) ;;
  "") PROMPT_COMMAND="__t4a_prompt_command" ;;
  *) PROMPT_COMMAND="__t4a_prompt_command; ${PROMPT_COMMAND}" ;;
esac

trap '__t4a_preexec' DEBUG
