#!/usr/bin/env bash
# What xl1-menu promises, on a machine with no docker and no systemd.
#
# THIS ONE CAN ACT, which is the whole difference from xl1-help and the whole
# reason it needs pinning harder. The properties that matter are not "does the
# menu draw" but:
#
#   nothing runs unasked        every command goes through one place that
#                               shows it and waits for a yes
#   nothing runs unattended     no terminal means no choices, not default ones
#   the gate holds              a producer whose config the node REFUSES is
#                               not restarted, whatever the operator pressed
#   ignorance is not a verdict  a path that could not be discovered stops the
#                               action; it never becomes a plausible default
set -u

SCRIPT="${1:?path to xl1-menu.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

SRC="$(tr -d '\r' < "$SCRIPT")"
dry() { NO_COLOR=1 DRY_RUN=1 bash "$SCRIPT" "$@" 2>&1; }

printf '\nthe script itself\n'
if bash -n "$SCRIPT" 2>/dev/null; then ok "it parses"; else bad "it parses"; fi

# --- one door for every command ----------------------------------------------
#
# do_cmd shows the line and asks. An action that runs something any other way
# has escaped both, and it would do so silently -- the output still looks like
# the others.
printf '\nnothing runs unasked\n'
ESCAPED="$(printf '%s' "$SRC" \
  | sed -n '/^a_[a-z_]*() {/,/^}/p' \
  | grep -nE '^\s*(sudo |docker |systemctl |curl |git |cp |mv |rm )' \
  | grep -v 'do_cmd' || true)"
if [ -z "$ESCAPED" ]; then
  ok "every command an action runs goes through do_cmd"
else
  bad "an action runs something outside do_cmd" "$ESCAPED"
fi

if printf '%s' "$SRC" | sed -n '/^do_cmd() {/,/^}/p' | grep -q 'ask_yn'; then
  ok "do_cmd asks before it runs"
else
  bad "do_cmd no longer asks" "every action would run on being chosen"
fi

# ask_yn must default to NO. A default of yes on a menu that restarts a block
# producer turns a stray newline into an outage.
if printf '%s' "$SRC" | sed -n '/^ask_yn() {/,/^}/p' | grep -qE 'y\|Y\|yes\|YES\) return 0'; then
  ok "only an explicit yes counts as yes"
else
  bad "ask_yn accepts something other than an explicit yes"
fi

# --- unattended means nothing happens ----------------------------------------
printf '\nnothing runs unattended\n'
OUT="$(printf '' | NO_COLOR=1 bash "$SCRIPT" 2>&1)"; RC=$?
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "Not a terminal"; then
  ok "no terminal means it refuses rather than choosing"
else
  bad "it did something without a terminal" "rc=$RC $OUT"
fi

# --- the menu and the actions cannot disagree --------------------------------
printf '\nthe menu\n'
KEYS="$(printf '%s' "$SRC" | sed -n '/^ITEMS="/,/^"$/p' | grep -E '^[0-9a-z]\|' | cut -d'|' -f1)"
MISSING=""
for k in $KEYS; do
  fn="$(printf '%s' "$SRC" | sed -n "/^ITEMS=\"/,/^\"\$/p" | grep "^$k|" | cut -d'|' -f3)"
  printf '%s' "$SRC" | grep -q "^$fn() {" || MISSING="$MISSING $k->$fn"
done
if [ -z "$MISSING" ]; then ok "every menu key calls a function that exists"
else bad "menu keys point at nothing:$MISSING" "a keypress would find no action"; fi

for k in $KEYS; do
  printf '%s' "$(dry --help)" | grep -qE "^   $k\) " || bad "key $k is not shown in the menu"
done
ok "every key that works is offered"

if dry zzz 2>&1 | grep -q "no such choice"; then
  ok "an unknown key is refused"
else bad "an unknown key is not refused"; fi

# --- ignorance is not a default ----------------------------------------------
#
# No docker and no systemd here, so nothing is discoverable. An action that
# needs a path it could not find must stop.
printf '\nwhat it does not know\n'
OUT="$(dry 3)"
if printf '%s' "$OUT" | grep -q "not safe to do here"; then
  ok "restarting stops when the producer cannot be identified"
else
  bad "it would have restarted something it could not name" "$OUT"
fi
OUT="$(dry 2)"
if printf '%s' "$OUT" | grep -q "no producer env file"; then
  ok "the config check stops when the env file cannot be found"
else
  bad "the config check invented an env file" "$OUT"
fi
if printf '%s' "$SRC" | grep -q 'PRODUCER_ENV=.*/etc/xl1-producer.env'; then
  bad "the env file falls back to the script default" \
      "that default is a real file on the Pi and is NOT what the unit loads"
else
  ok "no path is ever defaulted"
fi

# --- the gate ----------------------------------------------------------------
#
# Run the real function against a docker that answers 78, which is the node
# refusing the configuration it is about to be given.
printf '\nthe config gate\n'
# STUBBED THROUGH PATH, not through shell functions. The gate runs its command
# with `sh -c` so that what it rehearses is the same string the menu shows, and
# a function named `sudo` does not exist inside that child shell. A stub on
# PATH does, and is closer to the real thing besides.
gate_says() { # gate_says <exit code> [container] [env file] -> "refused" | "fine"
  ( _d="$(mktemp -d)"
    printf '#!/bin/sh\nexit %s\n' "$1" > "$_d/sudo"
    chmod +x "$_d/sudo"
    PATH="$_d:$PATH"
    eval "$(printf '%s' "$SRC" | sed -n '/^dump_config_cmd() {/,/^}/p')"
    eval "$(printf '%s' "$SRC" | sed -n '/^config_refused() {/,/^}/p')"
    PRODUCER_ENV="${3-/tmp/env}"; PRODUCER_CONTAINER="${2-}"
    PRESET_ARGS=""; DRY_RUN=0
    config_refused && echo refused || echo fine
    rm -rf "$_d" )
}
[ "$(gate_says 78)" = refused ] && ok "exit 78 is read as a refusal" \
  || bad "exit 78 is not read as a refusal" "the one code the node actually uses"
[ "$(gate_says 0)" = fine ] && ok "a config the node accepts is not called a refusal" \
  || bad "an accepted config is called a refusal" "it would refuse to restart a healthy node"
[ "$(gate_says 125)" = fine ] && ok "a docker that will not run is not called a refusal" \
  || bad "a broken docker reads as a bad config" "the check cannot tell its own failure from the node's"

if printf '%s' "$SRC" | sed -n '/^a_restart_producer() {/,/^}/p' | grep -q 'config_refused'; then
  ok "the restart is gated on it"
else
  bad "the restart no longer asks the node first" "this is the whole point of the menu"
fi

# --- and the node that has no unit -------------------------------------------
#
# A wizard-built node is the ordinary shape and has no systemd unit, so the
# env file the old gate needed does not exist -- bootstrap-pi.sh deletes the
# runtime copy on purpose rather than leave the mnemonic lying about. Before
# this, option 2 refused outright there and option 3 restarted with no gate at
# all: the check that exists to stop a crash-loop was simply absent on most
# nodes.
if [ "$(gate_says 78 xl1-producer "")" = refused ]; then
  ok "a node with no unit is asked through its running container"
else
  bad "a node with no unit cannot be asked at all" \
      "that is the ordinary shape, and it is the one with no gate"
fi
if [ "$(gate_says 0 xl1-producer "")" = fine ]; then
  ok "and an accepted config there is still not a refusal"
else
  bad "the container path calls a healthy node refused"
fi
if [ "$(gate_says 78 "" "")" = fine ]; then
  ok "a node with neither gives no verdict rather than a refusal"
else
  bad "no env file and no container reads as a refusal" \
      "a gate that cannot ask must not answer"
fi
# AND IT ASKS THE CONTAINER, RATHER THAN COPYING WHAT THE CONTAINER HOLDS.
# The env a wizard-built producer runs with contains the mnemonic, and
# bootstrap-pi.sh deletes its runtime copy the moment the container is up
# because a second copy on disk is the thing to avoid. Rebuilding one from
# `docker inspect` to feed `--env-file` would undo that deliberately, and it
# would pass every other check here: same command shape, same output, same
# exit code. Only this says which of the two it is.
DCC="$(printf '%s' "$SRC" | sed -n '/^dump_config_cmd() {/,/^}/p' | grep -vE '^[[:space:]]*#')"
if printf '%s' "$DCC" | grep -q 'docker exec'; then
  ok "the no-unit node is asked inside its own container"
else
  bad "it feeds the dump an env file instead of exec-ing the container" \
      "the only env file there is one we would have written, holding the phrase"
fi
if printf '%s' "$DCC" | grep -qE 'env-file (/tmp|\$\(|/var/tmp)'; then
  bad "it points --env-file at something it made" \
      "that is a second copy of the mnemonic, which the wizard refuses to leave"
else
  ok "no env file is invented for it"
fi
# THE COMMAND IS SPELT ONCE, because the gate runs what the menu displays.
STRAY="$(printf '%s' "$SRC" | grep -vE '^[[:space:]]*#' | grep -c 'dump-config')"
if [ "$STRAY" -le 2 ]; then
  ok "the rehearsal command lives in one place"
else
  bad "--dump-config is spelt $STRAY times" \
      "the gate would decide on one command and the menu show another"
fi

# --- the service deploy ------------------------------------------------------
printf '\nthe anchor service\n'
DEPLOY="$(printf '%s' "$SRC" | sed -n '/^a_service() {/,/^}/p')"
COMPOSE="$(printf '%s' "$SRC" | sed -n '/^compose_cmd() {/,/^}/p')"

# SPELT ONCE, AND CHECKED WHERE IT IS SPELT. The two-file form lives in
# compose_cmd because three copies of it are three chances for one of them to
# lose the override -- which is the failure it exists to prevent.
if printf '%s' "$COMPOSE" | grep -q 'docker-compose.pi.yml' && \
   printf '%s' "$COMPOSE" | grep -q 'TAILNET_OVERRIDE'; then
  ok "the deploy command is the two-file form"
else
  bad "the deploy uses the bare one-file form" \
      "that drops the tailnet publish AND the container's DNS -- 2026-09-18"
fi
# And nowhere else writes its own. A second spelling is how one of them drifts.
# OUTSIDE compose_cmd, which is the place it must not appear. Inside it there
# are now two branches -- with an override and without -- and both name the
# base file legitimately. Counting them all made the guard fire at the
# function doing exactly what it exists to do, which is the point at which
# somebody deletes a guard rather than reads it.
STRAY="$(printf '%s' "$SRC" | grep -vE '^[[:space:]]*#' \
  | sed '/^compose_cmd() {/,/^}/d' | grep -c 'docker-compose.pi.yml')"
if [ "$STRAY" = 0 ]; then
  ok "only compose_cmd spells the compose command"
else
  bad "docker-compose.pi.yml is spelt $STRAY times outside compose_cmd" \
      "copies drift, and the copy that loses drops the override"
fi

CC="$(printf '%s' "$SRC" | sed -n '/^compose_cmd() {/,/^}/p')"
if printf '%s' "$CC" | grep -q 'if \[ -n "\$TAILNET_OVERRIDE" \]'; then
  ok "the compose command omits an override it does not have"
else
  bad "it names an override file even when there is none"       "compose then fails on every node without one"
fi

# THE OPTIONAL WEEKLY TIMER. It is deliberately not installed by the wizard --
# it acts on a running producer, so it is opt-in -- and offering its unit
# unconditionally failed with "Unit not found" on every node that took the
# default, which reads as a broken menu rather than an absent extra.
BUILD="$(printf '%s' "$SRC" | sed -n '/^a_build_image() {/,/^}/p')"
if printf '%s' "$BUILD" | grep -q 'systemctl cat xl1-image-rebuild'; then
  ok "it checks the rebuild timer exists before starting it"
else
  bad "it starts a unit that most nodes do not have"       "Unit not found reads as a broken menu, not an optional extra"
fi
# RUN, not merely mentioned. Two error branches below also name the script,
# so a bare grep for its name passed against a body with the running deleted
# -- a guard satisfied by the text describing the thing it checks.
#
# The path now goes through $_rb, so both halves are asserted: that _rb is
# that script, and that a runner actually executes $_rb. Matching only the
# second would pass if _rb were pointed at something else entirely.
if printf '%s' "$BUILD" | grep -qE '_rb="\$REPO_AGENT/rebuild-xl1-image\.sh"'    && printf '%s' "$BUILD" | grep -qE 'do_(cmd|capture) "sudo bash \$_rb'; then
  ok "and runs that script directly rather than only naming it"
else
  bad "with no checkout there is nothing offered at all"       "naming the script in an error is not offering to run it"
fi

# THE PULL IS THE UPDATE. `@xyo-network/xl1-sdk` is pinned to an exact version
# in package.json, so the bump is a change to that FILE -- merged on the repo
# and collected here. The first version of this action had no pull in it at
# all: `docker compose up --build` rebuilt whatever was already on disk, which
# looks exactly like a successful update and installs nothing. Jim asked "how
# do I update the SDK with this" and the honest answer was that you could not.
if printf '%s' "$DEPLOY" | grep -q 'git pull'; then
  ok "it collects the merged bump first"
else
  bad "the SDK update never collects the merged bump"       "rebuilding the checkout on disk is not an update, and cannot be told from one"
fi
# CODE ONLY. The comment above the pull explains what `docker compose up
# --build` alone would do, and matching that made the build look like it came
# first -- the guard failed against correct code, which is the way a guard
# teaches people to delete it.
CODE="$(printf '%s' "$DEPLOY" | grep -vE '^\s*#')"
PULL_AT="$(printf '%s' "$CODE" | grep -n 'git pull' | head -1 | cut -d: -f1)"
BUILD_AT="$(printf '%s' "$CODE" | grep -n 'deploy_line' | head -1 | cut -d: -f1)"
if [ -n "$PULL_AT" ] && [ -n "$BUILD_AT" ] && [ "$PULL_AT" -lt "$BUILD_AT" ]; then
  ok "the collect happens before the deploy line is offered"
else
  bad "the deploy line comes before the collect" "it names the version being replaced"
fi
if [ "$(printf '%s' "$DEPLOY" | grep -c 'xyo_stack')" -ge 2 ]; then
  ok "it reports the pinned stack before and after"
else
  bad "it does not show what the versions did"       "an update you cannot see is one you cannot tell from a no-op"
fi

# THE WHOLE GROUP, NOT ONE PACKAGE. The first version reported
# @xyo-network/xl1-sdk alone and called it "the SDK". @xyo-network/sdk sits
# beside it, and Dependabot moves every @xyo-network/* and @xylabs/* in ONE
# pull request because they release in lockstep -- so a report naming one of
# them describes neither what was pinned nor what changed.
STACK="$(printf '%s' "$SRC" | sed -n '/^xyo_stack() {/,/^}/p')"
if printf '%s' "$STACK" | grep -q 'xyo-network' && printf '%s' "$STACK" | grep -q 'xylabs'; then
  ok "the report covers the whole grouped stack, both scopes"
else
  bad "the report singles out part of the stack"       "Dependabot bumps @xyo-network/* and @xylabs/* together; so must this"
fi
if printf '%s' "$STACK" | grep -q 'xl1-sdk'; then
  bad "the report is pinned to one package name"       "naming xl1-sdk specifically misses @xyo-network/sdk, which is the one asked about"
else
  ok "no single package is hard-coded"
fi

# --- handing the container over to compose ------------------------------------
#
# bootstrap-pi.sh creates xl1-service-anchor-1 with `docker run --name`, taking
# the exact name compose wants, and compose will not adopt a container it did
# not create. Every wizard run puts the node back into that state, and the
# failure arrives AFTER a successful build -- which is why it read twice as
# "the deploy worked and then did not".
# --- falling behind ----------------------------------------------------------
#
# A merged bump reaches the node only when the checkout is pulled, so a node
# can sit a patch behind for a week with nothing saying so -- which is exactly
# what happened: the panel read "5.6.1 available" while the service ran 5.6.0
# and the deploy reported success both times, correctly.
printf '
falling behind
'
BEHIND="$(printf '%s' "$SRC" | sed -n '/^report_behind() {/,/^}/p')"

if printf '%s' "$DEPLOY" | grep -q 'report_behind'; then
  ok "the deploy says when npm has something newer"
else
  bad "nothing compares the pins against the registry"       "a node stays a version behind and every run reports success"
fi

# IT ONLY REPORTS. Rewriting package.json here would put the Pi on a version
# no typecheck in this repository has ever seen, and the lockfile beside it
# would stop describing the tree -- which `pnpm install --frozen-lockfile`,
# the image build's own step, then refuses.
if printf '%s' "$BEHIND" | grep -qE '(>|tee|sed -i).*package\.json'; then
  bad "it edits package.json on the node"       "the lockfile would no longer describe the tree, and the build would refuse it"
else
  ok "it reports rather than rewriting the pins on the node"
fi
if printf '%s' "$BEHIND" | grep -q 'xyo_stack'; then
  ok "the list of packages comes from the file, not a second copy"
else
  bad "the package list is written out again" "one of the two copies goes stale"
fi
if printf '%s' "$BEHIND" | grep -q 'command -v curl'; then
  ok "no curl means it says so rather than reporting everything current"
else
  bad "a missing curl would read as up to date"       "the quietest way to be behind is to be told you are not"
fi

# --- what is actually running ------------------------------------------------
#
# A THIRD READING, and the one that was missing. The checkout can pin 5.6.1
# while the running image was built from 5.6.0, and then "every pinned package
# is the newest published" is true, unhelpful, and reads as nothing to do --
# which is exactly what it said while the service ran the older stack.
printf '
what is actually running
'
RUNNING="$(printf '%s' "$SRC" | sed -n '/^report_running() {/,/^}/p')"
RSTACK="$(printf '%s' "$SRC" | sed -n '/^running_stack() {/,/^}/p')"

if printf '%s' "$DEPLOY" | grep -q 'report_running'; then
  ok "the deploy asks the container what it loaded"
else
  bad "nothing compares the running service against the checkout"       "a stale image reads as up to date, because the pins are"
fi
# THE SAME SOURCE THE PORTAL USES. A process is the authority on what it
# actually resolved; package.json is what it was asked for.
if printf '%s' "$RSTACK" | grep -q '8090/versions'; then
  ok "it reads the service's own /versions, as the panel does"
else
  bad "it infers the running versions from a file"       "that is how a container running something else goes unnoticed"
fi
if printf '%s' "$RUNNING" | grep -q 'did not answer'; then
  ok "a service that does not answer is unknown, not current"
else
  bad "a silent service reads as matching" "the quietest way to be stale"
fi
# THE LAST LINE HAS NO NEWLINE after command substitution, and a plain
# `while read` drops it. Sorted last, @xyo-network/xl1-sdk was the single
# package never reported stale -- and it is the one the panel's tile reads.
if printf '%s' "$RUNNING" | grep -q 'read -r _n _v || \[ -n'; then
  ok "the last package is not dropped by the read loop"
else
  bad "the final record is silently skipped"       "sorted last is xl1-sdk, which is the package the panel reports"
fi

# --- updating itself ----------------------------------------------------------
#
# The install command had been handed over three times by hand, which is three
# chances to type it wrong and one reason it should be a choice. It is also the
# only action here whose target is the running script.
printf '\nupdating itself\n'
SELF="$(printf '%s' "$SRC" | sed -n '/^a_selfupdate() {/,/^}/p')"
SELF_CODE="$(printf '%s' "$SELF" | grep -vE '^[[:space:]]*#')"

if printf '%s' "$SELF_CODE" | grep -q 'git pull'; then
  ok "it collects the new version before installing one"
else
  bad "it installs without pulling" "it would reinstall the copy already there"
fi

# A RENAME, NOT A WRITE OVER THE LIVE FILE. `install` truncates the target and
# writes into it, and bash reads a script INCREMENTALLY as it runs -- so a menu
# overwriting itself has the rest of its own source replaced underneath the
# interpreter, and what runs next is whatever now sits at that offset.
if printf '%s' "$SELF_CODE" | grep -q 'mv -f'; then
  ok "the live file is replaced by a rename"
else
  bad "it writes straight over the running script" \
      "bash reads a script as it goes; the rest of this menu would be replaced mid-run"
fi
if printf '%s' "$SELF_CODE" | grep -q 'dirname'; then
  ok "the temp file is made in the destination's own directory"
else
  bad "the temp file may be on another filesystem" \
      "mv is then a copy and a delete, not an atomic rename"
fi

# WHERE IT ACTUALLY IS. /usr/local/bin is a convention; installing beside a
# copy rather than over it leaves two, and the older one keeps being found.
if printf '%s' "$SELF_CODE" | grep -q 'command -v'; then
  ok "it updates the copy this machine actually runs"
else
  bad "it assumes an install path" "a second copy would be left shadowing the first"
fi

# YOU END UP IN THE NEW ONE, rather than being told to get there yourself.
# The old text warned that bash still had the old file open and asked you to
# quit and start again. It was true, and on 2026-09-22 it was read past: the
# commands were installed, option 7 ran in the old code, and reproduced the
# bug that had just been fixed, character for character, down to a path it
# printed as empty. The run looked like the fix had failed. A warning that
# must be obeyed for the result to be right is weaker than doing the thing.
#
# Driven rather than read. `exec` is stubbed, so the four situations can be
# told apart by what the function actually does in each.
restart_verdict() { # restart_verdict <MENU_LOOP> <DRY_RUN> <new file parses?>
  ( _tmpd="$(mktemp -d)"; _fake="$_tmpd/xl1-menu"
    if [ "$3" = yes ]; then printf '#!/bin/sh\ntrue\n' > "$_fake"
    else printf '#!/bin/sh\nif then fi\n' > "$_fake"; fi
    chmod +x "$_fake"
    MENU_LOOP="$1"; DRY_RUN="$2"; REPO_IS_CLONE=0; PUBLIC_REPO=http://stub.invalid
    B=""; X=""; Y=""; G=""; R=""; D=""
    say() { :; }; note() { printf 'NOTE %s\n' "$1"; }; warn() { :; }
    ok()  { printf 'OK %s\n' "$1"; }; err() { printf 'ERR %s\n' "$1"; }
    do_cmd() { return 0; }
    # The one question the action now asks up front. Stubbed because
    # this block is about what happens AFTER the answer -- that it is
    # asked at all is checked on its own further down, where a stub
    # cannot stand in for it.
    confirm_action() { return 0; }
    update_helpers() { return 0; }
    command() { if [ "$1" = -v ]; then printf '%s\n' "$_fake"; else return 0; fi; }
    exec() { printf 'EXEC %s\n' "$1"; }
    eval "$SELF_CODE"
    a_selfupdate
    rm -rf "$_tmpd" ) 2>/dev/null
}

V="$(restart_verdict 1 0 yes)"
if printf '%s' "$V" | grep -q '^EXEC '; then
  ok "a successful update restarts the process into the new menu"
else
  bad "it only warns that the running menu is stale" \
      "the warning was read past, and the old code answered the next choice"
fi

# NOT INTO A FILE THAT DOES NOT PARSE. The menu in memory still works; a
# half-written download would replace it with nothing at all.
V="$(restart_verdict 1 0 no)"
if printf '%s' "$V" | grep -q '^EXEC '; then
  bad "it execs a file it never checked" "a bad download would leave no menu at all"
else
  ok "a new file that does not parse is not run"
fi

# AND ONLY FROM THE INTERACTIVE LOOP. `xl1-menu u` is a one-shot; restarting
# it would drop somebody into a menu they never asked for.
V="$(restart_verdict 0 0 yes)"
if printf '%s' "$V" | grep -q '^EXEC '; then
  bad "a one-shot run is turned into an interactive one" "including from a script"
else
  ok "a one-shot run is not turned into an interactive one"
fi

V="$(restart_verdict 1 1 yes)"
if printf '%s' "$V" | grep -q '^EXEC '; then
  bad "DRY_RUN restarts the process" "the one mode that must change nothing"
else
  ok "DRY_RUN changes nothing, this included"
fi

# The paths that do not restart must still say where the new code is.
if printf '%s' "$SELF" | grep -qi 'next xl1-menu'; then
  ok "where it does not restart, it says which run will be the new one"
else
  bad "it says nothing about when the update takes effect"
fi

# A CLONE IS NOT THE ONLY SOURCE. The CM4 -- the only machine running the
# published layout -- has a directory of files with no .git at all, because
# the wizard fetched them one by one. `git pull` there is not a slow path, it
# is a fatal error, and this option refused outright on the one machine that
# most needed it. The published repo is where the wizard got them; fetching
# them again is the same act.
OUT="$(dry u)"
if printf '%s' "$OUT" | grep -q 'fetched from the published repository'; then
  ok "with no clone it fetches rather than refusing"
else bad "it refuses where there is no clone" "$OUT"; fi
if printf '%s' "$OUT" | grep -q 'git pull'; then
  bad "it still tries to pull a directory that is not a clone"       "that is a fatal error, not a slow path"
else ok "it does not try to pull something that is not a clone"; fi

# EXPORTED, not prefixed. A prefix on a function call sets a shell variable,
# and the `bash "$SCRIPT"` inside the function never sees it -- so the override
# silently did nothing and this checked the no-checkout case twice.
OUT="$(export XL1_REPO="$(cd "$(dirname "$SCRIPT")/.." && pwd)"; dry u)"
if printf '%s' "$OUT" | grep -q 'not installed; skipping'; then
  ok "a command that is not installed is skipped, not invented"
else bad "it tried to update something that is not there" "$OUT"; fi

# A CHECKOUT WHOSE PATH HAS A SPACE IN IT. The override used to sit unquoted
# inside the candidate loop, so such a path split into fragments and was never
# found -- reported as "no checkout on this machine" about a directory that
# was right there. Every path on the machine this was written on has a space
# in it, and it still took a test to notice.
SP="$(mktemp -d)/a dir with spaces"
mkdir -p "$SP/pi-agent" && : > "$SP/pi-agent/xl1_heartbeat.py"
OUT="$(export XL1_REPO="$SP"; dry u)"
rm -rf "$(dirname "$SP")"
if printf '%s' "$OUT" | grep -q 'no checkout on this machine'; then
  bad "a checkout path containing a space is not found" \
      "it reports no checkout about a directory that is there"
else
  ok "a checkout path containing a space is found"
fi

# --- it fits a narrow terminal -----------------------------------------------
#
# READ OVER SSH, OFTEN ON A PHONE. The first shipped version's longest entry --
# "Status -- what is running, and is the anchor healthy" -- wrapped onto two
# lines on the CM4, breaking after "anchor". 66 leaves room: the narrowest
# thing anybody reads this on is around 70.
printf '\nit fits a narrow terminal\n'
WIDE="$(dry --help | awk 'length > 66 { print length": "$0 }' | head -3)"
if [ -z "$WIDE" ]; then
  ok "no menu line is wider than 66 columns"
else
  bad "the menu wraps on a narrow terminal" "$WIDE"
fi

# --- a compose that cannot run is not a measurement --------------------------
#
# 2026-09-22, on the CM4: `docker compose` printed a usage screen, because the
# wizard installs no compose and that node had never had one. The count of
# published ports was taken by piping straight into `grep -c`, which threw the
# exit status away, matched nothing, and reported that "compose would publish 0
# where the running container publishes 1" -- a command that could not run,
# quoted back as a fact about the deploy, sending somebody to look at an
# override file for a problem that was a missing package.
printf '\nit collects, and stops there\n'
# OPTION 7 IS THE SDK, NOT THE DEPLOY. It used to be both, and the deploy
# half assumed the board it was written on: compose installed, an override
# file beside the checkout, a container compose was willing to adopt. None of
# that holds on a wizard-built node, and the result was three wrong answers
# in one run. Collecting a bump and running it are different acts with
# different risks, and only the first belongs behind this choice.
#
# CODE ONLY: the note that prints the deploy command necessarily contains it.
SVC="$(printf '%s' "$SRC" | sed -n '/^a_service() {/,/^}/p')
$(printf '%s' "$SRC" | sed -n '/^deploy_line() {/,/^}/p')"
SVC_CODE="$(printf '%s' "$SVC" | grep -vE '^[[:space:]]*#')"
if printf '%s' "$SVC_CODE" | grep -qE 'do_cmd .*(up -d|docker rm|docker run)'; then
  bad "option 7 still deploys" \
      "$(printf '%s' "$SVC_CODE" | grep -nE 'do_cmd .*(up -d|docker rm|docker run)' | head -2)"
else
  ok "it never starts, removes or rebuilds a container"
fi
# AND IT TAKES THEM. Saying a newer version exists is not updating to it --
# that was the whole complaint: the choice read as an update and moved
# nothing. The bump script is what writes the versions, resolves the lockfile
# and runs the gates, so the choice has to actually run it.
if printf '%s' "$SVC_CODE" | grep -q 'do_cmd .*--apply'; then
  ok "it takes the newer versions rather than naming them"
else
  bad "it reports what is newer and stops"       "a choice called Update that updates nothing"
fi
# AND SHOWS WHAT MOVED. An update you cannot see is one you cannot tell from
# a no-op -- and the bump restores the files when a gate fails, so "it ran"
# is not the same as "it moved".
if printf '%s' "$SVC_CODE" | grep -q 'comm -13'; then
  ok "it shows the versions before against after"
else
  bad "it does not show what the versions did"       "a restored bump and a successful one would read the same"
fi
if printf '%s' "$SVC_CODE" | grep -q '_before" = "$_after'; then
  ok "no movement after an apply is called out, not passed over"
else
  bad "a bump that put everything back reads as a success"
fi

# AND SAYS WHAT WOULD. Stopping without naming the next step leaves a checkout
# that moved and a container that did not -- the one state that looks like a
# finished update and is not.
# SVC_CODE, NOT SVC. The comment block at the top of the function says "IT
# DOES NOT DEPLOY" in as many words, so reading the whole function passed
# against a body whose message had been replaced by "Done." -- the fifth
# guard this session satisfied by the prose describing what it checks.
if printf '%s' "$SVC_CODE" | grep -qi 'does not deploy'; then
  ok "it says plainly that nothing was deployed"
else
  bad "it stops without saying the container is still on the old code" \
      "a moved checkout and an unchanged container look like success"
fi
if printf '%s' "$SVC_CODE" | grep -q 'COMPOSE_BIN' && \
   printf '%s' "$SVC_CODE" | grep -q 'compose_cmd'; then
  ok "the command it names is the one for this node's shape"
else
  bad "it names one deploy command for every node" \
      "the wizard shape and the compose shape need different ones"
fi
# The label has to agree with it, or the menu promises a deploy it will not do.
if printf '%s' "$SRC" | grep -q '7|Update the XYO SDK'; then
  ok "the menu line says what the choice now does"
else
  bad "the menu still offers a redeploy" "the line is read before the screen is"
fi
printf '\nthe stack it reports on\n'
# THE SAME PACKAGES THE BUMP TAKES, or the report answers a different question
# from the one the update acts on. On 2026-09-23 this read @xyo-network and
# @xylabs while bump-xyo-stack.sh also took @ariestools: the screen listed
# four packages, said every one was the newest published, and had never asked
# npm about the fifth. The menu gates the bump on its own report, so a scope
# missing here is a package that can never be updated from this choice.
#
# CHECKED ACROSS THE TWO FILES, because that is where the disagreement lives.
BUMP=""
for _b in "$(dirname "$SCRIPT")/../scripts/bump-xyo-stack.sh" \
          "$(dirname "$SCRIPT")/../service/scripts/bump-xyo-stack.sh"; do
  [ -f "$_b" ] && BUMP="$_b"
done
if [ -z "$BUMP" ]; then
  # NOT A PASS. "could not look" must never read as "nothing wrong".
  bad "bump-xyo-stack.sh was not found beside this checkout" \
      "the scopes could not be compared, which is not the same as agreeing"
else
  # CODE ONLY. The comment inside xyo_stack names @ariestools/sdk as the
  # package that was being missed, so reading the whole function passed
  # against a body with that scope taken back out -- the sixth guard this
  # session satisfied by the prose describing the thing it checks.
  STACK_FN="$(printf '%s' "$SRC" | sed -n '/^xyo_stack() {/,/^}/p' | grep -vE '^[[:space:]]*#')"
  WANT="$(sed -n '/^pinned() {/,/^}/p' "$BUMP" | grep -oE '@[a-z][a-z-]+' | sort -u)"
  MISSING=""
  for _s in $WANT; do
    printf '%s' "$STACK_FN" | grep -q "${_s#@}" || MISSING="$MISSING $_s"
  done
  if [ -z "$MISSING" ]; then
    ok "it reports every scope the bump script takes"
  else
    bad "the report leaves out:$MISSING" \
        "those packages are never checked, and the choice gates on this report"
  fi
fi

printf '\nthe image recipe\n'
REC="$(printf '%s' "$SRC" | sed -n '/^a_recipe() {/,/^}/p')"
REC_CODE="$(printf '%s' "$REC" | grep -vE '^[[:space:]]*#')"

# A PATH WITH A SPACE IS STILL A PATH. The override was written unquoted
# inside the loop -- `for _d in ${XL1_IMAGES_REPO:-} ...` -- which splits
# "Code Projects" into two and finds nothing. find_repo was fixed for exactly
# this earlier the same day, and this reintroduced it three functions later.
FIR="$(printf '%s' "$SRC" | sed -n '/^find_images_repo() {/,/^}/p' | grep -vE '^[[:space:]]*#')"
if printf '%s' "$FIR" | grep -qE 'for _d in \$\{XL1_IMAGES_REPO'; then
  bad "the recipe override is expanded unquoted in the loop" \
      "a checkout whose path contains a space is then never found"
else
  ok "the recipe override is checked on its own, quoted"
fi
# AND THE PATH IT HANDS TO A COMMAND MUST SURVIVE THE TRIP. Unquoted in the
# command string, git reported `cannot change to 'C:/Users/.../Desktop/Code'`
# -- and the fetch failing that way is the quiet kind: the comparison then
# runs against a stale remote ref and reports the recipe as current.
_bare="$(printf '%s' "$REC_CODE" | grep -c 'git -C \$_ir')"
if [ "${_bare:-0}" -gt 0 ]; then
  bad "a command is built with an unquoted path ($_bare of them)" \
      "a space in the checkout path breaks the command, and a failed fetch reads as up to date"
else
  ok "every command it prints quotes the checkout path"
fi

# IT MUST NOT PULL. On the board that builds its own image the recipe checkout
# is ALSO the live presets mount -- the producer reads roles/producer-rest.json
# out of it while it runs, carrying this node's tuned check interval as a local
# modification. `git pull` merges and can overwrite; ff-only refuses instead,
# which is the difference between a refusal and a silently retuned producer.
if printf '%s' "$REC_CODE" | grep -qE 'git .*pull'; then
  bad "it pulls the recipe checkout" \
      "that directory is the live presets mount; a pull can overwrite them"
else
  ok "it never pulls"
fi
if printf '%s' "$REC_CODE" | grep -q 'merge --ff-only'; then
  ok "it takes upstream only where it fast-forwards"
else
  bad "it does not use merge --ff-only" "anything else can rewrite a live preset"
fi

# A COUNT OF COMMITS IS NOT A REASON TO REBUILD. Seventeen commits behind on
# 2026-09-23 and every one touched .github/, README.md or CLAUDE.md -- nothing
# the build copies. Reporting "17 behind" and stopping there invites a rebuild
# that produces the identical image.
if printf '%s' "$REC_CODE" | grep -q 'grep -vE ' && \
   printf '%s' "$REC_CODE" | grep -q 'diff --name-only'; then
  ok "it says which incoming files actually reach the image"
else
  bad "it reports a commit count and nothing about what changed" \
      "docs and CI churn then reads as a reason to rebuild"
fi

# SAID BEFORE THE MERGE IS OFFERED, because afterwards is no use.
_warn_at="$(printf '%s' "$REC_CODE" | grep -n 'status --short -- presets' | head -1 | cut -d: -f1)"
_merge_at="$(printf '%s' "$REC_CODE" | grep -n 'merge --ff-only' | head -1 | cut -d: -f1)"
# POSITION IS NOT REACHABILITY. The first version of this checked only that
# the presets were LOOKED AT before the merge, so disabling the branch that
# reports them left the line in place and the guard green. It must also be
# spent: computed, tested, and told.
_reported=0
printf '%s' "$REC_CODE" | grep -q '\[ -n "$_dirty" \]' && _reported=1
if [ -n "$_warn_at" ] && [ -n "$_merge_at" ] && [ "$_warn_at" -lt "$_merge_at" ]    && [ "$_reported" = 1 ]; then
  ok "local preset changes are named before the merge is offered"
else
  bad "the live presets are mentioned after the merge, or never reported"       "looking at them and saying nothing is the same as not looking"
fi

# AND IT DOES NOT PRETEND TO HAVE CHANGED THE NODE.
if printf '%s' "$REC" | grep -qi 'Nothing running has changed'; then
  ok "it says the running node is untouched, and what would change it"
else
  bad "it implies the update reached the node" \
      "the recipe is what an image is built FROM, not what is running"
fi

# A NODE WITHOUT ONE IS NOT BROKEN.
if printf '%s' "$REC" | grep -qi 'prebuilt image'; then
  ok "a node with no recipe is told that is normal"
else
  bad "a node given a built image reads as misconfigured"
fi


# --- the CLI update, which promotes and restarts -----------------------------
#
# This is the only choice that changes what a live producer will start from
# AND restarts it onto that. Every property below is about the order those
# steps happen in, because each one is undoable right up until the next:
#
#   a build nothing runs         -> a failure leaves the node untouched
#   a tag move                   -> free to reverse; the producer has not
#                                   restarted, so it is still on the old image
#   a restart                    -> the first step that can leave a node down
#
printf '\nthe CLI update promotes in an order that can be undone\n'

BODY="$(printf '%s' "$SRC" | sed -n '/^a_build_image() {/,/^}/p')"
line_of() { printf '%s' "$BODY" | grep -n "$1" | head -1 | cut -d: -f1; }

L_PROMOTE="$(line_of 'bash \$_rb --promote')"
L_CONFIG="$(line_of 'if config_refused')"
L_RESTART="$(line_of 'a_restart_producer')"

if [ -n "$L_PROMOTE" ] && [ -n "$L_CONFIG" ] && [ -n "$L_RESTART" ] \
   && [ "$L_PROMOTE" -lt "$L_CONFIG" ] && [ "$L_CONFIG" -lt "$L_RESTART" ]; then
  ok "it asks the NEW image about this node's config before restarting onto it"
else
  bad "the config gate is not between the promote and the restart" \
      "promote=$L_PROMOTE config=$L_CONFIG restart=$L_RESTART"
fi

# THE SMOKE TEST IS NOT THIS CHECK. It proves the image runs; it says nothing
# about whether the CLI still understands the settings this node has. A
# release that renames a setting passes it and then exits 78 on start.
if printf '%s' "$BODY" | grep -A 4 'if config_refused' | grep -q 'rollback_cli'; then
  ok "a refused config puts xl1:local back"
else
  bad "a refused config leaves the node pointing at an image it will not run" \
      "the next restart from any cause would crash-loop it"
fi

if printf '%s' "$BODY" | grep -A 4 'a_restart_producer ||' | grep -q 'rollback_cli'; then
  ok "a restart that does not come up clean puts xl1:local back too"
else
  bad "a failed restart leaves the new image promoted"
fi

# Nothing to promote must mean nothing to restart. Restarting a producer that
# is already on the newest CLI is an outage bought for no reason.
#
# THE RETURN, NOT THE SENTENCE. The first version of this grepped for the
# message and passed against a body with the `return 0` deleted -- the code
# said "nothing to restart onto" and then restarted. Saying the right thing
# on the way past is not the same as stopping.
if printf '%s' "$BODY" | grep -A 1 'already on \$_new; nothing to restart onto'    | grep -q 'return 0'; then
  ok "it stops, rather than saying it will and carrying on"
else
  bad "it restarts even when nothing moved"       "the message is there; the return that makes it true is not"
fi

# ROLLING BACK TO A GUESS IS WORSE THAN NOT ROLLING BACK. The version is the
# one this run recorded before it moved the tag, or there is no rollback.
RB="$(printf '%s' "$SRC" | sed -n '/^rollback_cli() {/,/^}/p')"
if printf '%s' "$RB" | grep -q 'if \[ -z "\$1" \]'; then
  ok "rollback refuses without a version it was told"
else
  bad "rollback would guess at a version"
fi

# --- the second door ---------------------------------------------------------
#
# do_capture exists because the CLI update reads what the rebuild script
# promoted rather than asking npm a second time. It is a second way to run
# things, and a second way that skipped the showing or the asking would be
# exactly the hole do_cmd was made to close.
printf '\nthe capturing runner is still a door\n'
CAP="$(printf '%s' "$SRC" | sed -n '/^do_capture() {/,/^}/p')"

if printf '%s' "$CAP" | grep -q 'ask_yn'; then
  ok "do_capture asks before it runs"
else
  bad "do_capture runs without asking" "one action would act on being chosen"
fi

if printf '%s' "$CAP" | grep -q 'DRY_RUN'; then
  ok "do_capture honours a dry run"
else
  bad "a dry run would really run this one"
fi

# The prompt and the command's output go to stderr so the caller can capture
# stdout. If the prompt went to stdout it would be swallowed -- the menu would
# look hung, waiting for an answer to a question nobody saw.
if printf '%s' "$CAP" | grep -q 'ask_yn "run it?" >&2'; then
  ok "its prompt goes where a reader can see it"
else
  bad "the prompt would be captured instead of shown"
fi

# --- the SDK update deploys what it just pinned ------------------------------
#
# Moving the pins changes a FILE. The container goes on running the code it
# was built from until something rebuilds it, and while that was left to a
# line printed on screen the checkout could say 5.7.1 over a service still
# serving 5.6.1, with nothing on the node saying so.
printf '\nthe SDK update deploys what it pinned\n'

SVC="$(printf '%s' "$SRC" | sed -n '/^a_service() {/,/^}/p')"

if printf '%s' "$SVC" | grep -q 'deploy_now'; then
  ok "it deploys rather than printing what would"
else
  bad "the SDK update still only names the deploy" \
      "a moved pin that nothing rebuilds is a checkout, not a deployment"
fi

# A BUMP THAT FAILED MUST NOT DEPLOY. The gates put the files back, so
# deploying afterwards would rebuild the code that was already there and
# report it as an update.
B_BUMP="$(printf '%s' "$SVC" | grep -n 'bump.*--apply' | head -1 | cut -d: -f1)"
B_MOVED="$(printf '%s' "$SVC" | grep -n 'the pins did not move' | head -1 | cut -d: -f1)"
B_DEPLOY="$(printf '%s' "$SVC" | grep -n 'deploy_now' | head -1 | cut -d: -f1)"
if [ -n "$B_BUMP" ] && [ -n "$B_MOVED" ] && [ -n "$B_DEPLOY" ] \
   && [ "$B_BUMP" -lt "$B_MOVED" ] && [ "$B_MOVED" -lt "$B_DEPLOY" ]; then
  ok "it deploys only after the pins are confirmed to have moved"
else
  bad "the deploy is not behind the check that the bump took" \
      "bump=$B_BUMP moved=$B_MOVED deploy=$B_DEPLOY"
fi

DN="$(printf '%s' "$SRC" | sed -n '/^deploy_now() {/,/^}/p')"

# THE TAILNET PUBLISH. The one-file compose form drops it, and a node that
# loses it reads healthy from the box while the website goes stale.
if printf '%s' "$DN" | grep -q 'compose_cmd'; then
  ok "the compose path uses this node's own compose command"
else
  bad "the deploy spells its own compose line" \
      "the one-file form drops the tailnet publish"
fi

if printf '%s' "$DN" | grep -q 'compose_made'; then
  ok "a wizard-made container is removed before compose is asked to take over"
else
  bad "compose is asked to adopt a container it did not create" \
      "it refuses with a name clash, which reads as something else entirely"
fi

# THE CHECK THAT WAS NOT MADE COST EIGHT HOURS. Counting before and after is
# the whole of it: a dropped binding is invisible from the node.
VA="$(printf '%s' "$SRC" | sed -n '/^verify_anchor() {/,/^}/p')"
if printf '%s' "$DN" | grep -q '_ports_before="$(anchor_ports)"' \
   && printf '%s' "$DN" | grep -q 'verify_anchor "$_ports_before"'; then
  ok "it counts the published bindings before the deploy and after"
else
  bad "nothing compares the bindings across the deploy"
fi

if printf '%s' "$VA" | grep -q 'lt "${1:-0}"'; then
  ok "and fewer than before is an error, not a shrug"
else
  bad "a dropped binding is not treated as a failure"
fi

# The label is the only thing most operators read before pressing the key.
if printf '%s' "$SRC" | grep -q '7|Update the XYO SDK (and deploy it)|a_service'; then
  ok "the menu says it deploys"
elif printf '%s' "$SRC" | grep -q '7|.*no deploy'; then
  bad "the menu still promises not to deploy" "it does now"
else
  bad "choice 7 is not in the table under a name this checks"
fi

# --- the build must not bury the thing it was asked about --------------------
#
# buildkit redraws its progress in place on a terminal and APPENDS when it
# cannot. Through this menu it cannot, so a 96-second build wrote hundreds of
#
#   [+] Building 31.5s (9/16)
#
# and scrolled the gate results the operator had just been told to read off
# the top of the screen.
printf '
the deploy reports steps, not refreshes
'
CC="$(printf '%s' "$SRC" | sed -n '/^compose_cmd() {/,/^}/p')"

if [ "$(printf '%s' "$CC" | grep -c -- '--progress plain')" = 2 ]; then
  ok "both shapes of the compose command ask for plain progress"
else
  bad "a compose form still uses the redrawing progress display"       "through this menu that appends a line per refresh"
fi

# A GLOBAL FLAG, so it belongs before -f. After it, compose reads it as an
# argument to the subcommand and refuses.
if [ "$(printf '%s' "$CC" | grep -c 'docker compose --progress plain -f')" = 2 ]; then
  ok "and it is placed where compose takes it"
else
  bad "--progress is after the file arguments" "compose rejects it there"
fi

# NOT quiet. A build takes a minute and a half on this hardware, and that long
# with nothing on screen is indistinguishable from a hang.
if printf '%s' "$CC" | grep -q -- '--progress quiet'; then
  bad "the build says nothing at all while it runs"       "ninety seconds of silence reads as a hung menu"
else
  ok "it does not go silent for the length of a build"
fi

# --- the config gate must be about the NEW image -----------------------------
#
# With an env file the check is `docker run ... xl1:local --dump-config`, and
# after a promotion xl1:local IS the new image. Without one it falls back to
# `docker exec` into the RUNNING container -- still on the OLD image, because
# tagging restarts nothing. That answers about the wrong subject and answers
# "fine", clearing the new image on the old one's behalf. The CM4 has no
# discoverable env file, so this is not hypothetical.
printf '\nthe config gate only speaks about the image it can see\n'

if printf '%s' "$SRC" | sed -n '/^a_build_image() {/,/^}/p' \
   | grep -q 'config_gate_asks_new_image'; then
  ok "the gate is consulted only when it is about the new image"
else
  bad "the gate is trusted even when it can only see the old image" \
      "after a promote that clears the new image on the old one's behalf"
fi

CG="$(printf '%s' "$SRC" | sed -n '/^config_gate_asks_new_image() {/,/^}/p')"
if printf '%s' "$CG" | grep -q 'PRODUCER_ENV'; then
  ok "and it is the env file that decides, which is what picks the subject"
else
  bad "what the gate can see is decided by something other than the env file"
fi

# SAID, NOT SKIPPED QUIETLY. A check that could not be made is worth knowing
# about; silence here reads as a check that passed.
if printf '%s' "$SRC" | sed -n '/^a_build_image() {/,/^}/p' \
   | grep -A 6 'else' | grep -q 'not be asked about it'; then
  ok "and a check that could not be made says so"
else
  bad "the skipped check is silent" "silence reads as a pass"
fi

# --- the menu updates what it RUNS, not only itself --------------------------
#
# On a tarball node the menu updated, its labels changed, and option 5 went on
# running the rebuild script the wizard unpacked weeks earlier -- which read,
# twice on the CM4, as a fix that had not worked. A clone gets them from
# `git pull`; a tarball node got nothing.
printf '\nthe self-update refreshes the scripts the menu runs\n'

SU="$(printf '%s' "$SRC" | sed -n '/^a_selfupdate() {/,/^}/p')"
UH="$(printf '%s' "$SRC" | sed -n '/^update_helpers() {/,/^}/p')"

if printf '%s' "$SU" | grep -q 'update_helpers'; then
  ok "it refreshes them as well as the two commands"
else
  bad "only the menu and the help are updated" \
      "option 5 would keep running whatever the wizard last unpacked"
fi

# EVERY SCRIPT A CHOICE INVOKES, WHEREVER IT LIVES. One left out is one that
# silently stays old -- and the version of this list that said "agent/" and
# meant it left bump-xyo-stack.sh stale under service/, so option 7 failed
# with `corepack: not found` from a script fixed two commits earlier.
MH="$(printf '%s' "$SRC" | sed -n '/^menu_helpers() {/,/^}/p')"
for _s in rebuild-xl1-image.sh redeploy-anchor.sh bootstrap-pi.sh \
          xl1_heartbeat.py bump-xyo-stack.sh; do
  if printf '%s' "$MH" | grep -q "$_s"; then
    ok "  $_s is refreshed"
  else
    bad "  $_s is never refreshed" "a choice runs it and nothing updates it"
  fi
done

# THE PUBLISHED PATH AND THE LOCAL PATH ARE NOT THE SAME, and assuming they
# were is what left one helper behind: PUBLIC_REPO points INTO agent/, while
# the bump script is published under service/scripts/.
if printf '%s' "$MH" | grep -q 'service/scripts/bump-xyo-stack.sh|'; then
  ok "and the one that is published elsewhere says where it comes from"
else
  bad "the fetch path is assumed to match the install path" \
      "the bump script would be fetched from agent/ and 404"
fi

# EVERY LINE IN THE LIST MUST NAME BOTH. A half-written entry would fetch to
# nowhere or install from nothing, and the loop skips it silently.
BAD_ROWS="$(printf '%s' "$MH" | grep -oE '"[a-z0-9/._-]+\|[^"]*"' | grep -v '|\$' || true)"
if [ -z "$BAD_ROWS" ]; then
  ok "every entry says where it comes from and where it goes"
else
  bad "an entry is missing one side of the pair" "$BAD_ROWS"
fi

# PUBLIC_ROOT, not PUBLIC_REPO, for anything outside agent/.
if printf '%s' "$SRC" | grep -q 'PUBLIC_ROOT="\${PUBLIC_REPO%/agent}"' \
   && printf '%s' "$SRC" | sed -n '/^update_helpers() {/,/^}/p' \
      | grep -q 'PUBLIC_ROOT/\$_rel'; then
  ok "and fetches are rooted above agent/, where all of them actually are"
else
  bad "the fetch is still rooted inside agent/" \
      "which is only right for four of the five"
fi

# A 200 IS NOT A SCRIPT. A captive portal, a 404 page and a rate-limit notice
# all arrive with a body; installing one over a working tool replaces it with
# an apology.
if printf '%s' "$UH" | grep -q '_looks_like_source'; then
  ok "what came back is checked for a shebang before it is installed"
else
  bad "anything that downloads is installed over a working script"
fi

# REFRESHED, NOT INTRODUCED. A file the wizard never placed belongs to a node
# shape this is not, and adding it changes what the menu does next time.
if printf '%s' "$UH" | grep -q 'is not on this node; left alone'; then
  ok "and a script this node never had is not invented for it"
else
  bad "it would add scripts the wizard never put here"
fi

# A CLONE ALREADY HAS THEM. Fetching over a pull would overwrite local work
# with published main, which is the opposite of what a checkout is for.
# Positional, not a fixed window of context: the first version looked two
# lines back for the `else` and it sits three above, so a correct
# arrangement failed. Where the call is relative to the branch is the
# actual question.
SU_ELSE="$(printf '%s' "$SU" | grep -n '^  else$' | head -1 | cut -d: -f1)"
SU_CALL="$(printf '%s' "$SU" | grep -n 'update_helpers$' | head -1 | cut -d: -f1)"
SU_PULL="$(printf '%s' "$SU" | grep -n 'git pull' | head -1 | cut -d: -f1)"
if [ -n "$SU_ELSE" ] && [ -n "$SU_CALL" ] && [ -n "$SU_PULL" ] \
   && [ "$SU_PULL" -lt "$SU_ELSE" ] && [ "$SU_ELSE" -lt "$SU_CALL" ]; then
  ok "and a clone is left to its pull"
else
  bad "it fetches over a git checkout" \
      "that discards whatever is local (pull=$SU_PULL else=$SU_ELSE call=$SU_CALL)"
fi

# --- the loop must not eat the operator's answers ----------------------------
#
# `menu_helpers | while read ...` puts the loop body in a subshell whose STDIN
# IS THE PIPE, so ask_yn's read took the NEXT HELPER LINE as the answer. Every
# prompt printed and answered itself instantly -- "run it? [y/N]:    skipped"
# -- and the loop ate its own list on the way past: five entries, three
# prompts, two that never appeared at all.
printf '\nthe helper loop leaves stdin to the operator\n'
UH2="$(printf '%s' "$SRC" | sed -n '/^update_helpers() {/,/^}/p')"

# CODE, NOT THE COMMENT ABOUT IT. The note above update_helpers quotes the
# broken form to explain why it is broken, and an unfiltered grep read that
# as the bug being present -- the third time this evening a guard was
# satisfied by prose describing the thing it checks.
if printf '%s' "$UH2" | grep -vE '^[[:space:]]*#'    | grep -q 'menu_helpers | while'; then
  bad "the loop reads from a pipe" \
      "ask_yn's read takes the next list entry instead of the keypress"
else
  ok "the list does not arrive on the loop's stdin"
fi

if printf '%s' "$UH2" | grep -q 'read -r _rel _dst <&3' \
   && printf '%s' "$UH2" | grep -q 'done 3<<'; then
  ok "it comes in on its own descriptor, leaving stdin the terminal"
else
  bad "the list is not on a separate descriptor" \
      "whatever reads next will consume it"
fi

# Driven, not read. The shapes are a one-character difference and the symptom
# -- a prompt that answers itself -- looks like a terminal problem.
_probe() {
  ASSUME_YES=0; TTY_OK=1; DRY_RUN=0
  ask_yn() { IFS= read -r _r || _r=""; case "$_r" in y|Y) return 0 ;; *) return 1 ;; esac; }
  _rows() { printf 'a\nb\n'; }
  _got=""
  while IFS= read -r _row <&3; do
    if ask_yn "run it?"; then _got="$_got$_row:yes "; else _got="$_got$_row:no "; fi
  done 3<<ROWS
$(_rows)
ROWS
  printf '%s' "$_got"
}
GOT="$(printf 'y\ny\n' | _probe)"
if [ "$GOT" = "a:yes b:yes " ]; then
  ok "and an answer typed for each entry reaches the question, not the list"
else
  bad "the answers and the list are still crossed" "got: $GOT"
fi

# --- one question for an update, not one per command -------------------------
#
# `u` asked about twelve commands. Twelve identical prompts is not twelve
# decisions -- it is one decision and eleven keystrokes, which is how a person
# learns to hold down y without reading.
printf '\none question per update\n'
CA="$(printf '%s' "$SRC" | sed -n '/^confirm_action() {/,/^}/p')"

for _a in a_selfupdate a_agent a_build_image a_service; do
  if printf '%s' "$SRC" | sed -n "/^$_a() {/,/^}/p" | grep -q 'confirm_action'; then
    ok "  $_a asks once, up front"
  else
    bad "  $_a still asks per command" "or does not ask at all"
  fi
done

# IT IS STILL A QUESTION. Auto-yes that nobody agreed to is not consent.
if printf '%s' "$CA" | grep -q 'ask_yn'; then
  ok "the one question is actually asked"
else
  bad "ASSUME_YES is set without asking anything" "that is not consent"
fi

if printf '%s' "$CA" | grep -qE 'ASSUME_YES=1' \
   && [ "$(printf '%s' "$CA" | grep -c 'ASSUME_YES=0')" -ge 1 ]; then
  ok "and it starts from no every time it is called"
else
  bad "a previous yes could still be in force when it is called"
fi

# CLEARED EITHER SIDE OF EVERY CHOICE, or a yes given for one action answers
# for the next keypress too.
DISP="$(printf '%s' "$SRC" | sed -n '/^dispatch() {/,/^}/p')"
if [ "$(printf '%s' "$DISP" | grep -c 'ASSUME_YES=0')" -ge 2 ]; then
  ok "and the dispatcher clears it either side of the action"
else
  bad "a yes can outlive the action it was given for" \
      "the next choice would run unasked"
fi

# A DRY RUN MUST STILL WALK AN UPDATE. Making this the one thing that stops it
# dead would remove most of what DRY_RUN is for.
if printf '%s' "$CA" | grep -q 'DRY_RUN" = 1'; then
  ok "a dry run is shown, not blocked on a question nobody is there to answer"
else
  bad "DRY_RUN cannot walk an update any more"
fi

# And the assumed answer is still PRINTED: a transcript that shows only the
# commands, with no record of the agreement, is a worse record than one that
# shows twelve prompts.
AY="$(printf '%s' "$SRC" | sed -n '/^ask_yn() {/,/^}/p')"
if printf '%s' "$AY" | grep -q 'agreed above'; then
  ok "and each assumed answer is still shown in the transcript"
else
  bad "the assumed answers leave no record" "the log stops showing consent"
fi

# --- the panel is told, not left to notice -----------------------------------
#
# The agent caches both version readings for an hour, correctly: the CLI one
# is `docker exec xl1 --version`, 3.5 SECONDS on this hardware, on a machine
# whose job is producing blocks. The cost lands in the one minute an operator
# is looking -- the SDK tile sat on the pre-deploy version with its own
# "newer available" note beside it.
printf '\nan update tells the panel what it just did\n'
RP="$(printf '%s' "$SRC" | sed -n '/^refresh_panel() {/,/^}/p')"

for _a in a_build_image deploy_now; do
  if printf '%s' "$SRC" | sed -n "/^$_a() {/,/^}/p" | grep -q 'refresh_panel'; then
    ok "  $_a nudges the panel when it has changed something"
  else
    bad "  $_a leaves the tile stale for up to an hour" \
        "which is exactly the hour somebody is looking at it"
  fi
done

# A RESTART, NOT A SIGNAL. SIGHUP's default action is to TERMINATE, so
# signalling an agent older than any handler for it would kill the heartbeat
# on precisely the nodes furthest behind -- and stale files on nodes is the
# theme of the day.
if printf '%s' "$RP" | grep -q 'systemctl restart xl1-heartbeat'; then
  ok "it restarts the agent, which means the same thing to every version"
else
  bad "the nudge is not a restart" \
      "a signal an older agent does not handle kills the heartbeat"
fi
if printf '%s' "$RP" | grep -qE '\-HUP|SIGHUP'; then
  bad "it signals the agent" "SIGHUP terminates an agent with no handler for it"
else
  ok "and nothing is signalled"
fi

# ONLY WHERE THERE IS ONE. Most of what this menu runs on has the unit; a node
# that does not must not see a systemd error for an optional nicety.
if printf '%s' "$RP" | grep -q 'systemctl cat xl1-heartbeat.service'; then
  ok "and a node without the unit is left alone"
else
  bad "it would report Unit not found on a node that has no agent"
fi

# NOT AFTER A DEPLOY THAT FAILED ITS CHECK. Re-reading versions is harmless,
# but the sequence says "this worked" and it must only say that when it did.
if printf '%s' "$SRC" | sed -n '/^deploy_now() {/,/^}/p' \
   | grep -q 'verify_anchor "$_ports_before" || return 1'; then
  ok "and a deploy that lost a binding stops before claiming success"
else
  bad "the panel is nudged even when the deploy failed its own check"
fi

# --- u finishes the job, including the agent that is RUNNING -----------------
#
# `u` refreshed the copy of xl1_heartbeat.py in the checkout and stopped, so
# the file said 1.44.2 while the process answering the panel was still
# 1.44.1 -- and a fix for the CLI tile read as no fix at all. Third time in
# one evening that "running is not installed" cost a round trip.
printf '\nthe self-update leaves the running agent current too\n'
SU2="$(printf '%s' "$SRC" | sed -n '/^a_selfupdate() {/,/^}/p')"

if printf '%s' "$SU2" | grep -q 'install_agent'; then
  ok "it installs the agent when the running one is behind"
else
  bad "the agent source is refreshed and the running agent is not" \
      "the panel keeps answering from the old code"
fi

# COMPARED, NOT ASSUMED. Installing unconditionally restarts the heartbeat on
# every `u`, including the many that change nothing about it.
if printf '%s' "$SU2" | grep -q '"\$_have" != "\$_want"'; then
  ok "and only when the two actually differ"
else
  bad "every u restarts the heartbeat" "including those that change nothing"
fi

# THE SAME READER FOR BOTH SIDES. Two ways of reading a version is how the
# comparison ends up between a number and a nearly-identical number.
AV="$(printf '%s' "$SRC" | sed -n '/^agent_version_of() {/,/^}/p')"
if [ -n "$AV" ] \
   && printf '%s' "$SU2" | grep -q 'agent_version_of "\$AGENT_DIR' \
   && printf '%s' "$SU2" | grep -q 'agent_version_of "\${REPO_AGENT'; then
  ok "the installed copy and the source are read the same way"
else
  bad "the two versions are read differently" "which is how they stop comparing"
fi

# A NODE WITH NO AGENT MUST NOT BE GIVEN ONE. Same rule the helper refresh
# follows: refreshed, not introduced.
# THE `if`, NOT ANY LINE THAT LOOKS LIKE IT. A bare grep found the `elif`
# below and passed while the guard was deleted from the condition that
# actually decides -- the second time tonight a second occurrence stood in
# for the one being checked.
IF_LINE="$(printf '%s' "$SU2" | grep -m1 '^  if \[ -n "\$_want" \]')"
if printf '%s' "$IF_LINE" | grep -q '\-n "\$_have"'; then
  ok "and a node with no agent installed is left without one"
else
  bad "it would install an agent onto a node that has none"       "condition: ${IF_LINE:-<not found>}"
fi

# The install is shared with choice 8 rather than written twice: two copies of
# a command that restarts a service drift, and only one of them gets fixed.
if printf '%s' "$SRC" | sed -n '/^a_agent() {/,/^}/p' | grep -q 'install_agent'; then
  ok "choice 8 and the self-update install it the same way"
else
  bad "there are two ways to install the agent" "one of them will go stale"
fi

# --- the outcome is read, not asserted ---------------------------------------
#
# `docker restart` does NOT follow a moved tag. Measured on the Pi with a
# throwaway container: created from a tag, tag moved to another image,
# restarted, and it came back on the image it was CREATED from. So a promote
# followed by a restart leaves a wizard-built producer exactly where it was.
#
# The menu reported success anyway, because the line printed the version that
# had been PROMOTED rather than reading the producer. The panel said 5.4.1,
# the menu said 5.5.0, and the panel was right.
printf '\nthe CLI update checks whether the producer actually moved\n'
BI="$(printf '%s' "$SRC" | sed -n '/^a_build_image() {/,/^}/p')"

if printf '%s' "$BI" | grep -q '_now="$(running_cli)"'; then
  ok "it reads the producer after the restart"
else
  bad "success is claimed from the version that was promoted" \
      "which is an intention, not a check"
fi

# The success line must come from what was READ, not from what was wanted.
if printf '%s' "$BI" | grep -q 'ok "the producer is running CLI \$_now"'; then
  ok "and says what it read"
else
  bad "the success line still reports the promoted version"
fi

# A MISMATCH IS A FAILURE, and it has to name the thing that fixes it -- the
# menu cannot recreate this container itself: the run line needs the env file,
# the preset mount and the heap cap, and on a node whose env file is not
# discoverable those cannot be reconstructed. Guessing them is how a producer
# comes back as a different address.
if printf '%s' "$BI" | grep -q 'STILL running' \
   && printf '%s' "$BI" | grep -q 'wizard (choice 4)'; then
  ok "a producer that did not move is reported, with what to do about it"
else
  bad "a producer that stayed on the old image is not reported"
fi

# AND NOTHING IS ROLLED BACK THERE. The tag is where it should be; the
# producer is on the image it has been on all along. Retagging back would
# undo the one part that worked.
if printf '%s' "$BI" | grep -A 6 'STILL running' | grep -q 'rollback_cli'; then
  bad "it rolls the tag back when the producer did not move" \
      "the tag was right; it is the container that has not caught up"
else
  ok "and the tag is left where it belongs"
fi

# An unreadable version is not a failure and not a success.
if printf '%s' "$BI" | grep -q 'not confirmed'; then
  ok "an unreadable version says so rather than picking a side"
else
  bad "an unreadable version is treated as one outcome or the other"
fi

# --- the redeploy uses the node's own shape ----------------------------------
#
# Choice r ran the wizard-shaped script unconditionally. On the Pi 4 that
# script REFUSES -- correctly: the container publishes two bindings and
# start_anchor_service creates one, so going through it would drop the tailnet
# publish and take /chain down, which it did for eight hours on 2026-09-23.
#
# But a correct refusal and a missing path are the same dead end from the
# chair: there was then no choice in the menu that could deploy that node at
# all, while option 7's deploy had known how the whole time.
printf '\nthe redeploy takes the shape this node actually uses\n'
AR="$(printf '%s' "$SRC" | sed -n '/^a_redeploy() {/,/^}/p')"
DN2="$(printf '%s' "$SRC" | sed -n '/^deploy_now() {/,/^}/p')"

if printf '%s' "$AR" | grep -q 'deploy_now'; then
  ok "choice r goes through the shape-aware deploy"
else
  bad "choice r runs the wizard-shaped script whatever the node is" \
      "on a compose node that is a refusal and no way forward"
fi

# NOT BACK THROUGH THE ACTION. deploy_now calling a_redeploy, now that
# a_redeploy calls deploy_now, is an infinite loop -- and it would ask for
# confirmation a second time on the way in.
if printf '%s' "$DN2" | grep -q 'redeploy_via_script' \
   && ! printf '%s' "$DN2" | grep -q 'a_redeploy'; then
  ok "and the deploy calls the script directly, not back through the choice"
else
  bad "deploy_now calls a_redeploy, which now calls deploy_now" \
      "that recurses, and re-asks the question on the way round"
fi

# The wizard-shaped path still exists for the nodes it is right for.
if printf '%s' "$SRC" | grep -q '^redeploy_via_script() {'; then
  ok "the wizard-shaped redeploy is still there for wizard-built nodes"
else
  bad "the script path was removed along with the dead end"
fi

# --- what is waiting, said before anything is chosen --------------------------
#
# Every one of these readings already existed INSIDE the actions: choice 5 told
# you the producer was running 5.4.1 once you had already chosen 5. That is the
# wrong moment. The question on arriving is "is there anything to do here", and
# answering it meant opening each door in turn.
printf '\nthe menu says what is waiting before you pick\n'

UPD_CODE="$(printf '%s' "$SRC" \
  | sed -n '/^running_cli_tag() {/,/^update_note() {/p' \
  | grep -vE '^[[:space:]]*#')"
UPD_CODE="$UPD_CODE
$(printf '%s' "$SRC" | sed -n '/^update_note() {/,/^}/p')"

# Driven, not read: the whole point is which line comes out for which state.
scan_with() { # scan_with <running cli> <published cli> <newest built> <installed agent> <checkout agent>
  # NAMED, NOT POSITIONAL. The first version of this harness passed the five
  # states as "$1".."$5" and read them back inside the stubs, where $1 is the
  # STUB's own first argument -- so every stub returned empty, three notes
  # were never produced, and the one test expecting silence passed for the
  # wrong reason.
  ( _RUN="$1"; _PUB="$2"; _BUILT="$3"; _HAVE="$4"; _WANT="$5"
    UPDATES=""
    eval "$UPD_CODE"
    PRODUCER_CONTAINER=fake; AGENT_DIR=/a; REPO_AGENT=/b
    running_cli_tag() { printf '%s\n' "$_RUN"; }
    newest_built_tag() { printf '%s\n' "$_BUILT"; }
    xyo_latest() { case "$1" in *xl1-cli) printf '%s\n' "$_PUB" ;; *) printf '9.9.9\n' ;; esac; }
    xyo_stack() { printf '  @xyo-network/xl1-sdk 9.9.9\n'; }
    agent_version_of() { case "$1" in /a/*) printf '%s\n' "$_HAVE" ;; *) printf '%s\n' "$_WANT" ;; esac; }
    command() { if [ "$1" = -v ]; then return 1; else return 0; fi; }
    scan_updates ) 2>/dev/null
}

V="$(scan_with 5.4.1 5.5.0 5.4.1 1.45.0 1.45.0)"
if printf '%s' "$V" | grep -q '^5|CLI 5.4.1 running, 5.5.0 published'; then
  ok "choice 5 says which CLI is running and which is published"
else
  bad "a newer published CLI is not named beside the choice that installs it" "$V"
fi

# THE STATE THE CM4 SAT IN FOR TWO DAYS: 5.5.0 built, 5.4.1 running, and
# nothing on the screen saying the two were different. `docker restart` does
# not move a container onto a retagged image, so this is not self-correcting.
V="$(scan_with 5.4.1 5.4.1 5.5.0 1.45.0 1.45.0)"
if printf '%s' "$V" | grep -q '^6|xl1:5.5.0 is built here but the producer is on 5.4.1'; then
  ok "choice 6 says when an image is built and not being used"
else
  bad "an image built but never promoted goes unmentioned" "$V"
fi

V="$(scan_with 5.5.0 5.5.0 5.5.0 1.44.2 1.45.0)"
if printf '%s' "$V" | grep -q '^8|agent 1.44.2 installed, 1.45.0 in the checkout'; then
  ok "choice 8 says the running agent is not the one in the checkout"
else
  bad "a stale installed agent is not reported" "$V"
fi

# NOTHING TO SAY IS SAID WITH SILENCE. A line per choice reading "up to date"
# is nine rows of nothing on a node with nothing to do, and the eye stops
# reading rows that never change.
V="$(scan_with 5.5.0 5.5.0 5.5.0 1.45.0 1.45.0)"
if [ -z "$(printf '%s' "$V" | grep -vE '^(7\||OFFLINE\|)')" ]; then
  ok "and says nothing at all when nothing is waiting"
else
  bad "it writes a line for a choice with nothing to do" "$V"
fi

# AN UNANSWERED REGISTRY IS NOT AN ALL-CLEAR. Nothing here prints a line when
# it has no answer, so silence would read as "nothing to do" on a node that
# could not ask -- the same failure as a watcher reporting a node fine because
# its own path was wrong.
V="$( ( UPDATES=""
        eval "$UPD_CODE"
        PRODUCER_CONTAINER=""; AGENT_DIR=/a; REPO_AGENT=/b
        running_cli_tag() { :; }; newest_built_tag() { :; }
        xyo_latest() { :; }; xyo_stack() { :; }; agent_version_of() { :; }
        command() { return 1; }
        scan_updates ) 2>/dev/null )"
if printf '%s' "$V" | grep -q '^OFFLINE|'; then
  ok "a registry that could not be asked is declared, not passed off as clean"
else
  bad "no answer from npm reads the same as nothing to update" "$V"
fi

# THE NOTE THAT COULD NEVER BE CLEARED. On a tarball node nothing writes the
# checkout's copy of xl1-menu.sh -- menu_helpers does not list it, and
# a_selfupdate fetches the published one to /tmp and installs that to
# /usr/local/bin. So "this menu differs from the checkout" was true for ever
# on the CM4 and `u` could not make it false. Seen on Jim's screen the day it
# shipped.
u_note() { # u_note <REPO_IS_CLONE>
  ( _CLONE="$1"
    _t="$(mktemp -d)"; printf 'a\n' > "$_t/installed"; printf 'b\n' > "$_t/xl1-menu.sh"
    UPDATES=""
    eval "$UPD_CODE"
    REPO_IS_CLONE="$_CLONE"; REPO_AGENT="$_t"
    PRODUCER_CONTAINER=""; AGENT_DIR=/a
    running_cli_tag() { :; }; newest_built_tag() { :; }
    xyo_latest() { printf '1.0.0\n'; }; xyo_stack() { :; }
    agent_version_of() { :; }
    command() { if [ "$1" = -v ]; then printf '%s\n' "$_t/installed"; else return 0; fi; }
    scan_updates
    rm -rf "$_t" ) 2>/dev/null
}

if printf '%s' "$(u_note 1)" | grep -q '^u|'; then
  ok "a clone is told its installed menu is not the checkout's"
else
  bad "a pulled checkout does not offer to install itself" "$(u_note 1)"
fi

if printf '%s' "$(u_note 0)" | grep -q '^u|'; then
  bad "a tarball node is nagged about a file nothing can update" \
      "u cannot make them agree, so the note never clears"
else
  ok "and a tarball node, where nothing writes that copy, is not"
fi

# ON ITS OWN LINE, UNDER THE CHOICE, IN COLOUR.
printf '\nand puts it where the choice is\n'
MENU_FN="$(printf '%s' "$SRC" | sed -n '/^menu() {/,/^}/p')"
if printf '%s' "$MENU_FN" | grep -vE '^[[:space:]]*#' | grep -q 'update_note'; then
  ok "the list asks for a note per choice"
else
  bad "the notes are not drawn beside the choices" \
      "a note anywhere else is a second place to look"
fi
if printf '%s' "$MENU_FN" | grep -vE '^[[:space:]]*#' \
   | grep -q "printf '      .*\$Y.*\$_note"; then
  ok "and draws it indented on its own line, in colour"
else
  bad "the note is not set apart from the choice it belongs to" \
      "$(printf '%s' "$MENU_FN" | grep -n '_note')"
fi

# BEFORE THE LIST, NOT AFTER IT. A note printed under the prompt is a note
# printed after the choice has been typed.
if printf '%s' "$MENU_FN" | grep -vE '^[[:space:]]*#' | grep -q 'ensure_updates'; then
  ok "the readings are taken before the list is drawn"
else
  bad "the list is drawn from whatever was last known" "which may be nothing"
fi

# AND RE-READ AFTER EVERY CHOICE, because the choice is usually what changed
# it. "Still getting Node CLI 5.4.1 / 5.5.0 available" was a correct update
# reported by a reading taken before it ran.
MAIN_FN="$(printf '%s' "$SRC" | sed -n '/^main() {/,/^}/p' | grep -vE '^[[:space:]]*#')"
if printf '%s' "$MAIN_FN" | grep -q 'updates_stale'; then
  ok "and thrown away after a choice runs, so the next list is not stale"
else
  bad "the notes survive the action that changes them" \
      "an update that worked would still be advertised"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
