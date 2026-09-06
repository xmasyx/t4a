#!/bin/bash
# The agent adapter, measured on the app you open (F4).
#
#   Scripts/bench-agent.sh readonly     nothing is ever written to the agents' data
#   Scripts/bench-agent.sh contract     the core names no vendor
#   Scripts/bench-agent.sh anti         adapter off -> an ordinary terminal
#   Scripts/bench-agent.sh live <cmd>   attach to a real session and print the latencies
#
# Nothing here reimplements the app's logic: it starts the real bundle, drives
# it through the test channel, and reads back what the app itself reports.

set -uo pipefail
cd "$(dirname "$0")/.."

STATUS=0
say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; STATUS=1; }
pass() { printf 'ok    %s\n' "$*"; }

# Nothing here touches the machine (ISC-132).
#
# This bench used to rewrite `~/.config/t4a/config.toml` and put `agent-adapter
# = true` back unconditionally when it finished, which is a measurement editing
# the setup of whoever ran it — and it launched the real `claude` in fresh
# directories and answered its trust question, so the trust stayed in the real
# `~/.claude.json` for ever. Both now happen inside directories this script
# owns, and the poles at the end are the checksums of the two real files.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME_OVERRIDE:-/tmp/t4a-agent-config}"
CLAUDE_HOME="/tmp/t4a-agent-claude"
CONFIG="$XDG_CONFIG_HOME/t4a/config.toml"
REAL_T4A_CONFIG="$HOME/.config/t4a/config.toml"
REAL_CLAUDE_CONFIG="$HOME/.claude.json"
hash_of() { [ -e "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "(absent)"; }
BEFORE_T4A="$(hash_of "$REAL_T4A_CONFIG")"
BEFORE_CLAUDE="$(hash_of "$REAL_CLAUDE_CONFIG")"
mkdir -p "$XDG_CONFIG_HOME/t4a"

untouched() {
  # The copy carries the account, so it does not outlive the run.
  rm -rf "$CLAUDE_HOME"
  say ""
  say "== the machine is as it was (ISC-132) =="
  [ "$(hash_of "$REAL_T4A_CONFIG")" = "$BEFORE_T4A" ] \
    && pass "the real t4a config is byte-identical" \
    || fail "the real t4a config CHANGED"
  [ "$(hash_of "$REAL_CLAUDE_CONFIG")" = "$BEFORE_CLAUDE" ] \
    && pass "the real claude config is byte-identical" \
    || fail "the real claude config CHANGED"
}
trap untouched EXIT

# claude's own configuration for the run: the real one with `projects`
# emptied, so answering a trust question leaves the answer here. Everything
# else is copied, because a config built from nothing is a machine that has
# never logged in and a bench against a logged-out agent measures a different
# screen (see Scripts/claude-config-copy.py).
seed_claude_config() {
  # A diagnostic escape hatch, and the only honest use of it: comparing the
  # timing under an isolated configuration against the timing under the real
  # one, on a directory the real one has ALREADY trusted — so nothing new is
  # written and the checksums at the end still have to match.
  if [ "${T4A_REAL_CLAUDE_CONFIG:-0}" = "1" ]; then
    say "claude config: the REAL one, by request (nothing new should be written)"
    return
  fi
  rm -rf "$CLAUDE_HOME"; mkdir -p "$CLAUDE_HOME"; chmod 700 "$CLAUDE_HOME"
  /usr/bin/python3 Scripts/claude-config-copy.py \
    "$REAL_CLAUDE_CONFIG" "$CLAUDE_HOME/.claude.json"
  export CLAUDE_CONFIG_DIR="$CLAUDE_HOME"
  # Said out loud, because a copy that quietly lost the account turns every
  # pole downstream into a measurement of a logged-out agent.
  say "claude config: $CLAUDE_HOME ($(/usr/bin/python3 -c "
import json
d = json.load(open('$CLAUDE_HOME/.claude.json'))
print('account carried' if d.get('oauthAccount') else 'NO ACCOUNT IN THE COPY',
      '·', len(d.get('projects', {})), 'projects')"))"
}

# Under its own configuration an agent asks things the real one answered months
# ago — the trust question, then external imports, then whatever is new this
# week. They are real permissions and the card answers them, which is the
# ISC-29 path; a bench that asserted "no card by now" would be calling a
# working app broken because it isolated the config properly.
answer_any_cards() {
  for _ in 1 2 3 4; do
    ./Scripts/drive.sh send 'scan' >/dev/null; sleep 1.5
    ./Scripts/drive.sh dump /tmp/t4a-agent-card.json >/dev/null
    /usr/bin/python3 -c "
import json, sys
d = json.load(open('/tmp/t4a-agent-card.json'))
card = d.get('card', {})
if not card.get('showing'): sys.exit(1)
print('    answering:', card.get('title'))
" || return 0
    ./Scripts/drive.sh send 'approve yes' >/dev/null; sleep 6
  done
}

set_config() {
  /usr/bin/python3 - "$1" "$2" "$CONFIG" <<'PY'
import sys, pathlib
key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
p.parent.mkdir(parents=True, exist_ok=True)
text = p.read_text() if p.exists() else ''
lines = [l for l in text.splitlines() if not l.startswith(key + ' ')]
lines.append(f'{key} = {value}')
p.write_text('\n'.join(lines) + '\n')
PY
}

case "${1:-live}" in

readonly)
  # The claim: T4A never writes a byte into an agent's data directory.
  #
  # Two independent poles, because each on its own has an innocent reading.
  # STATIC: no write API and no writable open() anywhere in the reader target —
  # a descriptor opened O_RDONLY cannot be made to write however the code runs.
  # LIVE: the app follows a real transcript for a while and the file it is
  # following comes out byte-identical, checked with a hash and not with a
  # glance at the modification time.
  say "== static: the reader target has no way to write =="
  # Comments are stripped first. The probe is about what the code DOES, and a
  # comment that says "no O_CREAT here" is the code being right, not wrong —
  # the first version of this line failed on its own documentation.
  BAD="$(sed -E 's@[[:space:]]*//.*$@@' Sources/AgentAdapters/*.swift \
            Sources/TerminalCore/AgentSession.swift \
        | grep -nE 'O_WRONLY|O_RDWR|O_CREAT|O_APPEND|O_TRUNC|createFile|\.write\(|write\(to:|removeItem|createDirectory' || true)"
  if [ -n "$BAD" ]; then fail "a write-shaped call in the reader:"; printf '%s\n' "$BAD"
  else pass "no write API in Sources/AgentAdapters or the agent contract"; fi

  OPENS="$(grep -c 'O_RDONLY' Sources/AgentAdapters/TranscriptTail.swift || true)"
  [ "$OPENS" -ge 2 ] && pass "every descriptor in the tail is O_RDONLY ($OPENS)" \
    || fail "expected the tail to open read-only twice, found $OPENS"

  say ""
  say "== live: the followed file is unchanged after being followed =="
  # A transcript NOBODY is writing. The obvious pick — the newest one — is the
  # session running this bench, and it changes for reasons that have nothing to
  # do with T4A: the first run of this probe reported a 1.5 KB growth and the
  # growth was these very words being written (2026-08-20).
  TARGET="$(find "$HOME"/.claude/projects -name '*.jsonl' -mmin +30 2>/dev/null | head -1)"
  if [ -z "${TARGET:-}" ]; then
    say "skip: no transcript on this machine to follow"
  else
    BEFORE="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
    BEFORE_STAT="$(stat -f '%z %m' "$TARGET")"
    ./Scripts/drive.sh start >/dev/null 2>&1
    DIR="$(dirname "$TARGET")"
    # A pane whose working directory is the one that transcript belongs to:
    # the observer attaches, watches, and follows.
    ./Scripts/drive.sh send "text cd $(dirname "$TARGET") && pwd" >/dev/null
    ./Scripts/drive.sh send 'key return' >/dev/null
    sleep 6
    ./Scripts/drive.sh stop >/dev/null 2>&1
    AFTER="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
    AFTER_STAT="$(stat -f '%z %m' "$TARGET")"
    [ "$BEFORE" = "$AFTER" ] && pass "checksum unchanged ($BEFORE_STAT)" \
      || fail "the transcript CHANGED: $BEFORE_STAT -> $AFTER_STAT"
    _=$DIR
  fi
  ;;

contract)
  # The claim behind ISC-31: the core is written against turns and states, and
  # names no vendor. The falsifier is a vendor's name outside its own adapter.
  say "== no vendor named outside its adapter =="
  HITS="$(grep -rniE 'claude|codex|anthropic|openai' Sources/TerminalCore Sources/T4A \
          --include='*.swift' | grep -viE 'CLAUDECODE|claude-code-guide' | grep -vE '^\S+: *//' || true)"
  # Comments may discuss them; code may not.
  CODE="$(printf '%s\n' "$HITS" | grep -vE ':[0-9]+: *(//|///|\*)' | grep -E 'claude|codex|Claude|Codex' || true)"
  if [ -n "$CODE" ]; then fail "a vendor named in the core:"; printf '%s\n' "$CODE"
  else pass "TerminalCore and the app name no vendor in code"; fi

  say ""
  say "== both adapters conform to the same protocol, and the registry is the list =="
  COUNT="$(grep -cE "^ +[A-Za-z]+Adapter\.self," Sources/AgentAdapters/AgentObserver.swift || true)"
  say "adapters registered: $COUNT"
  grep -l ': AgentAdapter' Sources/AgentAdapters/*.swift | while read -r f; do
    pass "adapter: $(basename "$f")"
  done
  ;;

anti)
  # ISC-30. Adapter off, and the pane is the terminal it was before F4.
  say "== adapter off =="
  set_config agent-adapter false
  ./Scripts/drive.sh start >/dev/null 2>&1
  ./Scripts/drive.sh send 'text echo anti-pole-ok' >/dev/null
  ./Scripts/drive.sh send 'key return' >/dev/null
  sleep 3
  ./Scripts/drive.sh dump /tmp/t4a-anti.json >/dev/null
  set_config agent-adapter true
  /usr/bin/python3 - <<'PY'
import json
d = json.load(open('/tmp/t4a-anti.json'))
agent = d['agents'][0]
problems = []
if agent['adapter'].get('attached'): problems.append('an adapter attached')
if d['inspectorMode'] != 'commands': problems.append('the inspector left the command map')
if d['card'].get('showing'): problems.append('a card appeared')
if agent['folds']: problems.append('rows were folded')
pane = d['tabs'][0]['panes'][0]
if not any('anti-pole-ok' in line for line in pane['screen']):
    problems.append('the shell did not run the command')
if problems:
    print('FAIL  ' + '; '.join(problems))
    raise SystemExit(1)
print('ok    adapter off: no observer, command map, no card, no folds, shell works')
PY
  [ $? -eq 0 ] || STATUS=1
  ;;

twopanes)
  # ISC-131. Two panes, one directory, one vendor — and they must not end up
  # reading the same file.
  #
  # Nothing in a transcript points back at a pty, so "which of these is mine"
  # has no answer in the data; first-come binding across the whole app is the
  # strongest rule available, and it has to be a rule and not a comment.
  #
  # The order below is the one that makes HEAD fail. Pane one is left THINKING
  # when pane two attaches: its transcript is being written at that moment, so
  # it is the newest file with a modification time after pane two started
  # looking, and an observer with no registry adopts it.
  say "== two panes, one directory =="
  seed_claude_config
  ./Scripts/drive.sh start >/dev/null 2>&1
  WORK="${T4A_BENCH_DIR:-$HOME/Movies/t4a-twopanes-$$}"
  mkdir -p "$WORK"
  say "work directory: $WORK"

  ./Scripts/drive.sh send "text cd $WORK && claude" >/dev/null
  ./Scripts/drive.sh send 'key return' >/dev/null
  sleep 20
  answer_any_cards
  # Something to think about, so its file is alive while the second pane looks.
  ./Scripts/drive.sh send 'compose conta da 1 a 40, un numero per riga' >/dev/null
  sleep 4

  # Which file the first pane took, so the race can be made to happen instead
  # of waited for.
  ./Scripts/drive.sh dump /tmp/t4a-twopanes.json >/dev/null
  FIRST_FILE="$(/usr/bin/python3 -c "
import json, os
d = json.load(open('/tmp/t4a-twopanes.json'))
name = d['agents'][0]['adapter'].get('following') or ''
root = os.path.join(os.environ.get('CLAUDE_CONFIG_DIR', os.path.expanduser('~/.claude')),
                    'projects')
for base, _, files in os.walk(root):
    if name and name in files:
        print(os.path.join(base, name)); break
")"
  say "the first pane is reading: ${FIRST_FILE:-nothing yet}"

  ./Scripts/drive.sh send 'splitv' >/dev/null; sleep 3
  ./Scripts/drive.sh send "text cd $WORK && claude" >/dev/null
  ./Scripts/drive.sh send 'key return' >/dev/null
  # Keep the first pane's transcript FRESH while the second one is looking for
  # its file. This is the condition, not a trick: an observer picks the newest
  # transcript in the directory whose modification time is after it started
  # looking, so "the other pane is busy right now" is exactly a file whose
  # mtime keeps moving. Without it the race depends on how fast the first
  # agent finished, and a pole that only sometimes happens is not a pole.
  if [ -n "$FIRST_FILE" ]; then
    ( for _ in $(seq 1 40); do touch "$FIRST_FILE"; sleep 1; done ) &
    TOUCHER=$!
  else
    TOUCHER=""
    say "WARNING: the first pane had no transcript to keep warm; the race may not happen"
  fi
  sleep 25
  [ -n "$TOUCHER" ] && { kill "$TOUCHER" 2>/dev/null; wait "$TOUCHER" 2>/dev/null; }
  answer_any_cards
  ./Scripts/drive.sh send 'compose dimmi solo la parola due' >/dev/null
  # An agent under a configuration of its own keeps thinking of things to ask —
  # the auto-mode offer turned up AFTER the first drain and left the second
  # pane sitting on a question with nothing written to its transcript, which
  # reads from outside exactly like the registry refusing it a file. So the
  # wait is a loop with a condition, not a number of seconds: answer whatever
  # is on screen, then look again.
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 6
    answer_any_cards
    ./Scripts/drive.sh dump /tmp/t4a-twopanes.json >/dev/null
    /usr/bin/python3 -c "
import json, sys
d = json.load(open('/tmp/t4a-twopanes.json'))
panes = d['agents']
sys.exit(0 if len(panes) == 2 and all(p['adapter'].get('following') for p in panes) else 1)
" && break
  done
  ./Scripts/drive.sh dump /tmp/t4a-twopanes.json >/dev/null
  ./Scripts/drive.sh stop >/dev/null 2>&1
  /usr/bin/python3 - <<'PY'
import json
d = json.load(open('/tmp/t4a-twopanes.json'))
panes = d['agents']
print(f"panes: {len(panes)}")
for index, pane in enumerate(panes):
    a = pane['adapter']
    print(f"  pane {index}  attached={a.get('attached')}  turns={a.get('turns')}  "
          f"following={a.get('following')}")
print(f"  claimed app-wide: {panes[0]['adapter'].get('transcriptsHeldAppWide')}")
problems = []
if len(panes) != 2:
    problems.append(f'expected two panes, found {len(panes)}')
else:
    following = [p['adapter'].get('following') or '' for p in panes]
    if not all(following):
        problems.append(f'a pane is following nothing: {following}')
    elif following[0] == following[1]:
        problems.append(f'BOTH panes are reading {following[0]}')
    if not all(p['adapter'].get('attached') for p in panes):
        problems.append('a pane never attached')
if problems:
    print('FAIL  ' + '; '.join(problems)); raise SystemExit(1)
print('ok    two panes in one directory, two different transcripts')
PY
  [ $? -eq 0 ] || STATUS=1
  ;;

live)
  # Attach to a real agent session and print what the app measured.
  CMD="${2:-claude}"
  say "== live attach: $CMD =="
  seed_claude_config
  ./Scripts/drive.sh start >/dev/null 2>&1
  WORK="${T4A_BENCH_DIR:-$HOME/Movies/t4a-bench}"
  mkdir -p "$WORK"
  ./Scripts/drive.sh send "text cd $WORK && $CMD" >/dev/null
  ./Scripts/drive.sh send 'key return' >/dev/null
  sleep 16
  # A brand-new directory means the agent asks whether it is trusted, and the
  # bench answers that with the CARD — which is the same click a person makes,
  # so the run exercises ISC-29 on its way to measuring anything else. Under a
  # configuration of its own it asks two or three things, not one, and it
  # thinks of new ones between versions: a fixed number of scan/approve pairs
  # left the agent sitting on a question with nothing written to its
  # transcript, and the bench read that as an app that never attached.
  answer_any_cards
  ./Scripts/drive.sh send 'compose leggi il primo file della cartella e dimmi cosa contiene' >/dev/null
  # Waited on a CONDITION. The agent has done something when it has written a
  # turn; a clock says nothing about that.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 6
    answer_any_cards
    ./Scripts/drive.sh dump /tmp/t4a-agent.json >/dev/null
    /usr/bin/python3 -c "
import json, sys
d = json.load(open('/tmp/t4a-agent.json'))
a = d['agents'][0]['adapter']
sys.exit(0 if a.get('attached') and a.get('turns', 0) >= 1 else 1)
" && break
  done
  # A SECOND turn, and this is the one ISC-25's number is read from.
  #
  # Under a configuration of its own the agent writes its first record during
  # the trust dance, before the pane has produced the output that makes the
  # observer go looking, so "first-turn lag" there is the age of a record that
  # predates the attach and not the delay between the agent writing and us
  # reading. Measured 2.32 s that way against 0.33 s under the real config,
  # same code. The delay this claim is about is measured on a record written
  # while the observer is already following the file.
  BEFORE_TURNS="$(/usr/bin/python3 -c "
import json
print(json.load(open('/tmp/t4a-agent.json'))['agents'][0]['adapter'].get('turns', 0))")"
  ./Scripts/drive.sh send 'compose rispondi solo con la parola due' >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 5
    ./Scripts/drive.sh dump /tmp/t4a-agent.json >/dev/null
    /usr/bin/python3 -c "
import json, sys
a = json.load(open('/tmp/t4a-agent.json'))['agents'][0]['adapter']
sys.exit(0 if a.get('turns', 0) > $BEFORE_TURNS else 1)
" && break
  done
  ./Scripts/drive.sh dump /tmp/t4a-agent.json >/dev/null
  /usr/bin/python3 - <<'PY'
import json
d = json.load(open('/tmp/t4a-agent.json'))
a = d['agents'][0]
ad = a['adapter']
print(f"adapter        {ad.get('kind')}  attached={ad.get('attached')}")
print(f"following      {ad.get('following')}")
print(f"model          {ad.get('model')}")
print(f"turns          {ad.get('turns')}   activity={a['activity']}")
print(f"ISC-25 first-turn lag   {ad.get('firstTurnLagSeconds')}  s   (bound 2 s)")
print(f"ISC-27 worst state lag  {ad.get('worstLagSeconds')}  s   (bound 3 s)")
print(f"inspector      {d['inspectorMode']}")
for t in a['turnList']:
    print(f"  turn {t['id']}  {t['prompt'][:40]!r}  rows={t['promptRow']} work={t['workRows']} "
          f"tools={[x['name'] + ':' + x['summary'][:24] for x in t['tools']]}")
first = ad.get('firstTurnLagSeconds')
last = ad.get('lastLagSeconds')
worst = ad.get('worstLagSeconds')
print(f"ISC-25 lag on a record written AFTER attaching  {last}  s   (bound 2 s)")
bad = []
# The bound is read from the LAST batch: a record the observer was already
# following the file for, which is the delay the claim is about.
if last is None or last > 2: bad.append(f'lag after attaching {last}')
if worst is None or worst > 3: bad.append(f'worst state lag {worst}')
if first is not None and first > 2:
    print(f"note  the FIRST record was {first:.2f} s old when it was read; under a "
          "configuration of its own the agent writes it during the trust dance, "
          "before the pane has made the observer go looking")
if bad:
    print('FAIL  ' + '; '.join(bad)); raise SystemExit(1)
print('ok    both latencies inside their bounds')
PY
  [ $? -eq 0 ] || STATUS=1
  ;;

*)
  say "usage: $0 {readonly|contract|anti|live [claude|codex]|twopanes}"
  exit 2
  ;;
esac

exit $STATUS
