#!/bin/zsh
# Asks the terminal it is running in what it answers, and writes the replies
# to a file (ISC-135).
#
# It lives on disk rather than being typed through the test channel: these
# lines are made of quotes and escapes, and a probe whose quoting is mangled on
# the way in measures the mangling. Run BY the bench, INSIDE a real pane, so
# the thing answering is the terminal a person opens.

out="${1:-/tmp/t4a-vt-replies.txt}"
: > "$out"

# Everything that arrives within a short quiet period, one character at a time.
#
# NOT `read -d <terminator>`: the first version did that and hung the probe for
# ever on the one case it exists to measure. zsh's `-t` tests whether input is
# AVAILABLE and then reads without a bound, so a sequence nobody answers —
# `OSC 21`, the negative pole — leaves the read waiting for a delimiter that is
# never coming. Reading a character at a time with a timeout on each is bounded
# whatever the terminal does, which is the only kind of probe worth having
# where the interesting answer is silence.
drain() {
  local accumulated="" character
  while IFS= read -r -s -t 0.4 -k 1 character; do
    accumulated+="$character"
  done
  # ESC spelled out, so the answer survives being read off a file or a screen.
  print -r -- "${accumulated//$'\e'/ESC}"
}

ask() {
  local label="$1" sequence="$2"
  printf "$sequence"
  print -r -- "$label=$(drain)" >> "$out"
}

ask DA1 '\033[c'
ask DA2 '\033[>c'
ask DSR '\033[5n'
ask CPR '\033[6n'
ask XTV '\033[>0q'
# The negative pole: a sequence with no handler comes back empty. Without it
# every reply above could be an echo of the request.
ask OSC21 '\033]21;?\033\\'

# And SGR 5, which is about drawing rather than answering: the attribute is
# parsed by the engine and ignored by the GPU renderer, and the text must still
# be there.
printf '\033[5mblinking text stays legible\033[0m\n'
print -r -- "DONE=yes" >> "$out"
