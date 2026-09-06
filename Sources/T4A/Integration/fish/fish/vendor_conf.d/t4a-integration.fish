# T4A shell integration for fish.
#
# fish already emits OSC 133 itself — prompt, input, output and exit code all
# arrive without anyone's help. Measured 2026-08-20: adding our own marks gave
# every command TWO blocks. So here T4A adds the one thing fish leaves out,
# the command line, and touches nothing else.
#
# fish offers vendor_conf.d for exactly this: every directory in
# XDG_DATA_DIRS gets its fish/vendor_conf.d read at startup, so nothing under
# $HOME is written or edited.

# A conf.d file must never `exit`: that would kill the shell it is
# configuring. The whole body is guarded instead.
if not set -q T4A_INTEGRATION_LOADED
    set -g T4A_INTEGRATION_LOADED 1

    function __t4a_announce_command --on-event fish_preexec
        set -l encoded (printf '%s' "$argv[1]" | base64 | tr -d '\n')
        printf '\033]633;E;%s\007' $encoded
    end
end
