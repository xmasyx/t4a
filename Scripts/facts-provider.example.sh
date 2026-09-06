#!/bin/bash
# An example facts provider (ISC-139).
#
#   facts-provider = "/path/to/facts-provider.example.sh"
#   facts-interval = 2
#
# T4A runs this every `facts-interval` seconds and reads its standard output.
# Nothing else: no plugin, no socket, no protocol. It is given three arguments
# about the pane the keyboard is on, and it is free to ignore all three:
#
#   --session <the agent's own session id, or empty>
#   --cwd     <the pane's working directory>
#   --agent   <claude-code | codex | empty>
#
# The output is one reading per line:
#
#   key<TAB>text[<TAB>tone]
#
# tone is one of ok warn critical live used dim accent muted, and it names a
# MEANING — the theme decides what colour that is. Repeat a key to add another
# word to the same row, each word with its own tone, which is how a scale or a
# ladder comes out coloured word by word. `#name<TAB>key<TAB>Label` gives the
# row the name a person reads in the SETTINGS; it is never drawn on the bar, so
# put the caption in the reading itself (`Clock 11:19`, not just `11:19`).
#
# Exit non-zero, or take longer than a second, and the bar keeps the previous
# values; after three of those in a row the row goes dim to say so.
#
# Words, not pictures: the bar is a statusline, so labels are words (Clock,
# Battery) and readings are text. No emoji, no pictograms. T4A draws whatever
# it is handed and filters nothing, so keeping them out is the provider's job.

set -u

# --- the clock -------------------------------------------------------------
printf '#name\tclock\tClock\n'
printf 'clock\tCLOCK\tmuted\n'
printf 'clock\t%s\t%s\n' "$(date '+%H:%M')" "ok"

# --- how busy the machine is ----------------------------------------------
# One-minute load average against the number of cores, so the same number
# means the same thing on any machine.
cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
[ -n "${load:-}" ] || load=0
busy=$(awk -v l="$load" -v c="$cores" 'BEGIN { printf "%d", (l / c) * 100 }')
if   [ "$busy" -ge 100 ]; then tone=critical
elif [ "$busy" -ge 70  ]; then tone=warn
else                           tone=ok
fi
printf '#name\tload\tMachine load\n'
printf 'load\tLOAD\tmuted\n'
printf 'load\t%s\t%s\n' "${busy}%" "$tone"
printf 'load\t%s\t%s\n' "of ${cores} cores" "dim"

# --- the battery, when there is one ---------------------------------------
if pmset -g batt >/dev/null 2>&1; then
  line=$(pmset -g batt | sed -n '2p')
  percent=$(printf '%s' "$line" | grep -oE '[0-9]+%' | head -1)
  state=$(printf '%s' "$line" | grep -oE 'charging|discharging|charged' | head -1)
  if [ -n "$percent" ]; then
    number=${percent%\%}
    if   [ "$number" -le 10 ]; then tone=critical
    elif [ "$number" -le 25 ]; then tone=warn
    else                            tone=ok
    fi
    printf '#name\tbattery\tBattery\n'
    printf 'battery\tBATTERY\tmuted\n'
    printf 'battery\t%s\t%s\n' "$percent" "$tone"
    [ -n "$state" ] && printf 'battery\t%s\t%s\n' "$state" "dim"
  fi
fi
