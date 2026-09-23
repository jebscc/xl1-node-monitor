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
gate_says() { # gate_says <docker exit code> -> "refused" | "fine"
  ( eval "$(printf '%s' "$SRC" | sed -n '/^config_refused() {/,/^}/p')"
    PRODUCER_ENV=/tmp/env; PRESET_ARGS=""; DRY_RUN=0
    sudo() { shift 0; return "$FAKE"; }
    docker() { return "$FAKE"; }
    FAKE="$1"
    config_refused && echo refused || echo fine )
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
# RUN, not merely mentioned. The error two lines below also names the script,
# so a bare grep passed against a body with the fallback deleted -- the fourth
# guard in this session satisfied by the text describing the thing it checks.
if printf '%s' "$BUILD" | grep -qE 'do_cmd .*rebuild-xl1-image\.sh'; then
  ok "and falls back to running the script directly"
else
  bad "with no timer there is nothing offered at all"       "naming the script in an error is not offering to run it"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
