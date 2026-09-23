#!/usr/bin/env bash
# What xl1-help promises, checked against a machine that has none of it.
#
# THE TWO WAYS A HELP COMMAND GOES WRONG, and both are silent:
#
#   it stops running      nobody runs it on a good day, so a parse error is
#                         found at the worst possible hour by the one person
#                         who needed it
#   it starts lying       a section that names the wrong path is worse than
#                         no section, because it is followed
#
# Run with no docker and no systemd, which is also the state of a laptop and
# of CI. Every discovery must degrade to a stated gap rather than to a
# plausible default -- that is the property this file exists for.
set -u

SCRIPT="${1:?path to xl1-help.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

run() { NO_COLOR=1 bash "$SCRIPT" "$@" 2>&1; }
SRC="$(tr -d '\r' < "$SCRIPT")"

printf '\nthe script itself\n'
if bash -n "$SCRIPT" 2>/dev/null; then ok "it parses"; else bad "it parses"; fi

# --- it changes nothing ------------------------------------------------------
#
# The whole reason this is safe to run on a producing node. A help command
# that restarts something is a help command nobody dares run, which makes it
# useless exactly when it is needed.
printf '\nit changes nothing\n'
# `> *!/dev/null` rather than `> */`: the discovery lines redirect stderr to
# /dev/null, which is not a write to anything. The first version of this
# regex flagged them and would have taught whoever hit it to loosen the whole
# check rather than the one term that was wrong.
DANGER='systemctl (restart|start|stop|enable)|docker (restart|rm|stop|run|build|tag)|sudo (tee|install|mv|cp|sed)|rm -[rf]|> */(etc|opt|usr|var|home)'
if printf '%s' "$SRC" | grep -vE "^\s*(#|c |w |n )" | grep -qE "$DANGER"; then
  bad "no section actually runs a dangerous command" \
      "$(printf '%s' "$SRC" | grep -vE '^\s*(#|c |w |n )' | grep -nE "$DANGER" | head -2)"
else
  ok "the dangerous commands are only ever PRINTED, never run"
fi

# --- every section exists, and every function is reachable -------------------
printf '\nsections\n'
LISTED="$(run --list | tr -d '\r')"
DEFINED="$(printf '%s' "$SRC" | sed -n 's/^s_\([a-z]*\)() {/\1/p')"
if [ "$(printf '%s\n' "$LISTED" | sort)" = "$(printf '%s\n' "$DEFINED" | sort)" ]; then
  ok "every listed section has a function and every function is listed"
else
  bad "the section list and the functions disagree" \
      "listed: $(echo "$LISTED" | tr '\n' ' ') / defined: $(echo "$DEFINED" | tr '\n' ' ')"
fi

# The usage text is a THIRD copy of the same list, and the one a reader meets
# first. A section missing from it is a section nobody knows to ask for.
MISSING=""
for s in $LISTED; do
  printf '%s' "$(run --help)" | grep -qE "^  $s " || MISSING="$MISSING $s"
done
if [ -z "$MISSING" ]; then ok "usage describes every section"
else bad "usage does not describe:$MISSING" "a section nobody is told about"; fi

for s in $LISTED; do
  if [ -n "$(run "$s")" ]; then :; else bad "section '$s' prints nothing"; fi
done
ok "every section prints something"

if run '' | grep -q "Where things are"; then
  ok "no argument prints the lot"
else bad "no argument prints the lot"; fi

# --- a bad argument is refused, not executed ---------------------------------
#
# The argument becomes a function name. It is matched against the list rather
# than by pattern, and this watches that hold.
printf '\narguments\n'
OUT="$(run 'where; echo PWNED')"
# ON ITS OWN LINE, which is the difference between run and quoted back. The
# refusal prints the argument it is refusing -- `No section "where; echo
# PWNED"` -- so a bare grep for the marker matches the very message that
# proves nothing was executed, and the guard fails against correct code.
if printf '%s' "$OUT" | grep -qx PWNED; then
  bad "an argument can smuggle a command past the matcher" "$OUT"
else
  ok "an unknown argument is refused rather than run"
fi

# A REGEX METACHARACTER IS THE REAL FAILURE, and the first version of this
# section did not test for it. Matching the argument with grep cannot inject a
# command -- it can only let the WRONG section through, which is quieter: `.`
# matches every entry in the list, and the dispatcher then calls a function
# named after whatever the reader typed.
if printf '%s' "$(run '.')" | grep -q 'No section'; then
  ok "an argument that is a pattern matches no section"
else
  bad "an argument is matched as a pattern, not as a name"       "'.' matched a section it does not name"
fi
if run nonsense >/dev/null 2>&1; then
  bad "an unknown section exits 0" "a typo reads as success in a script"
else
  ok "an unknown section exits non-zero"
fi

# --- discovery degrades to a stated gap --------------------------------------
#
# THE PROPERTY THAT MATTERS. On 2026-09-21 a config was dumped from the
# script's DEFAULT env path while the unit loaded a different file; the
# default existed, opened and parsed, and the diagnosis went the wrong way for
# an hour. With no systemd here, every discovered value is unknown -- and an
# unknown must read as unknown.
printf '\nwhat it does not know\n'
WHERE="$(run where)"
if printf '%s' "$WHERE" | grep -q "not found on this machine"; then
  ok "an undiscoverable path says so"
else
  bad "an undiscoverable path was filled in anyway" "$WHERE"
fi
if printf '%s' "$WHERE" | grep -qE "producer env file +/etc/xl1-producer.env"; then
  bad "the env file fell back to the script default" \
      "that default is a real file on the Pi and is NOT what the unit loads"
else
  ok "the env file is never defaulted"
fi

# --- the agent env is root-only ----------------------------------------------
#
# /etc/xl1-heartbeat.env holds the heartbeat token, so it is root-only and a
# plain read as the operator returns nothing. On the CM4 that showed as
# "BACKEND_URL ... not found on this machine" about a file that was there and
# correct -- sending somebody to look for a configuration problem that was a
# permission. bootstrap-pi.sh hit this first and answers it at its line 1082.
printf '\nthe root-only agent env\n'
# CODE ONLY. The comment above the fallback explains `sudo -n`, so grepping
# the function wholesale passed against a body with the fallback deleted --
# the guard was satisfied by the note describing the thing it was checking.
EV="$(printf '%s' "$SRC" | sed -n '/^env_value() {/,/^}/p' | grep -vE '^[[:space:]]*#')"
if printf '%s' "$EV" | grep -q 'sudo -n'; then
  ok "it falls back to sudo -n, as the wizard does"
else
  bad "a root-only env file reads as empty" "a correct file then reports as missing"
fi
# AND NEVER PROMPTS. This is the command whose whole value is being safe to
# run without thinking; a password prompt from a help screen is a command
# people stop running.
if printf '%s' "$EV" | grep -qE 'sudo +[^-]'; then
  bad "it can prompt for a password" "a help command that asks for one is not run"
else
  ok "it never prompts -- only the non-interactive form is used"
fi

# THREE ANSWERS, NOT ONE. Absent, unreadable and unset are different problems
# and only one of them is about configuration.
WHY="$(printf '%s' "$SRC" | sed -n '/^env_why() {/,/^}/p')"
MISSING=""
for phrase in 'on this machine' 'root-only' 'not set in'; do
  printf '%s' "$WHY" | grep -q -- "$phrase" || MISSING="$MISSING [$phrase]"
done
if [ -z "$MISSING" ]; then ok "absent, root-only and unset are told apart"
else bad "env_why does not distinguish:$MISSING"; fi

ENVTMP="$(mktemp)"; printf 'NODE_ID=cm4-01\n' > "$ENVTMP"
OUT="$(AGENT_ENV="$ENVTMP" run where)"
if printf '%s' "$OUT" | grep -q 'not set in'; then
  ok "a key missing from a readable file says so"
else bad "a missing key reads as a missing file" "$OUT"; fi
# AND THE OVERRIDE IS HONOURED. A second, unconditional assignment further
# down the file silently shadowed it, so every one of these answers named
# /etc/xl1-heartbeat.env whatever it had actually read.
if printf '%s' "$OUT" | grep -q "$ENVTMP"; then
  ok "the env path it reports is the one it read"
else bad "it names a different env file from the one it used" "$OUT"; fi
rm -f "$ENVTMP"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
