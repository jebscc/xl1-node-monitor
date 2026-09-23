#!/usr/bin/env bash
#
# The things you actually do to this node, from a menu, on the node.
#
#   xl1-menu               pick from a list
#   DRY_RUN=1 xl1-menu     print what each choice would run, change nothing
#
# Install it:
#
#   sudo install -m 755 pi-agent/xl1-menu.sh /usr/local/bin/xl1-menu
#
# WHY THIS IS NOT PART OF xl1-help. That one prints and never acts, and a test
# greps its source to keep it that way -- which is what makes it safe to run on
# a producing node at three in the morning without reading it first. Bolting
# actions onto it would take that away from the command whose whole value is
# not having to think before running it. Two commands, one of which cannot
# hurt you.
#
# EVERY ACTION SHOWS ITS COMMAND AND ASKS, in the wizard's own manner: the
# exact line, then a yes or no. Nothing here is a surprise, and anything you
# would not have typed yourself you can decline. Non-interactive -- cron, a
# pipe, CI -- it prints the menu and exits rather than choosing for you.
#
# THE RISKY ONES ARE GATED ON THE NODE'S OWN OPINION, not on a confirmation.
# Restarting the producer runs `xl1 --dump-config` first and refuses on exit
# 78, which is the check that turns a crash loop into a message. A prompt only
# proves somebody pressed a key.
#
set -u

DRY_RUN="${DRY_RUN:-0}"
[ -t 0 ] && [ -t 1 ] && TTY_OK=1 || TTY_OK=0

# --- what this machine is, discovered not assumed -----------------------------
#
# The same discovery xl1-help does, and for the same reason: on 2026-09-21 a
# config was dumped from the script default while the unit loaded a different
# file. Here it matters more -- this one restarts things.

PRODUCER_CONTAINER="$(docker ps -a --filter name=xl1-producer --format '{{.Names}}' 2>/dev/null | head -1)"
ANCHOR_CONTAINER="$(docker ps -a --filter name=xl1-service-anchor --format '{{.Names}}' 2>/dev/null | head -1)"

producer_unit() {
  for u in xl1-producer xl1-node xl1; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then printf '%s.service' "$u"; return; fi
  done
}
PRODUCER_UNIT="$(producer_unit)"
unit_field() { # unit_field <sed-expression>
  [ -n "$PRODUCER_UNIT" ] || return
  systemctl show "$PRODUCER_UNIT" -p ExecStart --value 2>/dev/null | sed -n "$1" | head -1
}
PRODUCER_ENV="$(unit_field 's/.*--env-file[= ]\([^ ;"]*\).*/\1/p')"
PRESETS_DIR="$(unit_field 's/.*-v[= ]\([^ ;"]*\):\/presets.*/\1/p')"
PRESET_ARGS=""
[ -n "$PRESETS_DIR" ] && PRESET_ARGS="-e XL1_PRESETS_DIR=/presets -v $PRESETS_DIR:/presets"

# --- this deployment, discovered ---------------------------------------------
#
# NOTHING BELOW NAMES A PARTICULAR SITE. These shipped with paths from the
# machine they were written on -- one operator's checkout, one operator's
# backend, one operator's tailnet override -- which was fine while they were
# that operator's private tools and is wrong the moment the wizard installs
# them for somebody else. A hardcoded path on a stranger's Pi is worse than a
# missing one: it exists, it is wrong, and it is followed.
#
# Every value here is read from this machine, and where it cannot be read it
# says so rather than offering a plausible default. That is the same rule the
# producer env file taught on 2026-09-21, applied to the rest.

AGENT_ENV="${AGENT_ENV:-/etc/xl1-heartbeat.env}"

env_value() { # env_value <KEY> -- from the agent's own config, commented or not
  # ROOT-ONLY, because it holds the heartbeat token. bootstrap-pi.sh hit this
  # first and solved it the same way at its line 1082: try without sudo, then
  # try `sudo -n`, which never prompts. What it must NOT do is prompt -- this
  # is the command whose whole value is being safe to run without thinking,
  # and a password prompt from a help screen is a command people stop running.
  [ -f "$AGENT_ENV" ] || return
  if [ -r "$AGENT_ENV" ]; then
    sed -n "s/^#\{0,1\} *$1=//p" "$AGENT_ENV" | head -1 \
      | sed 's/^"//; s/"$//' | tr -d '[:cntrl:]'
  else
    sudo -n sed -n "s/^#\{0,1\} *$1=//p" "$AGENT_ENV" 2>/dev/null | head -1 \
      | sed 's/^"//; s/"$//' | tr -d '[:cntrl:]'
  fi
}

# WHY a value is missing, which is three different answers and was one. "not
# found on this machine" is wrong for a file that is there and unreadable:
# it sends somebody looking for a configuration problem that is a permission.
env_why() {
  if [ ! -f "$AGENT_ENV" ]; then printf 'no %s on this machine' "$AGENT_ENV"
  elif [ ! -r "$AGENT_ENV" ] && ! sudo -n true 2>/dev/null; then
    printf 'root-only -- run this with sudo to see it'
  else printf 'not set in %s' "$AGENT_ENV"
  fi
}

# THE OPERATOR'S OWN BACKEND, not the one this was written against. The
# published env example ships `https://your-backend.onrender.com`, so every
# grid has its own -- and a status command pointed at somebody else's is
# reporting on hardware that is not yours.
BACKEND="$(env_value BACKEND_URL)"
NODE_ID="$(env_value NODE_ID)"

# THE CHECKOUT, if this machine has one. The wizard can run from a clone or
# from a pipe, so there may be none at all -- and the options that need one
# say so rather than guessing at a directory.
find_repo() {
  # THE OVERRIDE IS CHECKED ON ITS OWN, QUOTED. Inside the loop it was
  # `for d in ${XL1_REPO:-} ...` -- unquoted, so a checkout whose path
  # contains a space splits into fragments and is never found. It failed
  # silently, reporting "no checkout on this machine" about a directory that
  # was right there, which is the same shape as every other bug in these
  # scripts: a confident answer about something never actually looked at.
  if [ -n "${XL1_REPO:-}" ]; then
    [ -f "$XL1_REPO/pi-agent/xl1_heartbeat.py" ] && { printf '%s' "$XL1_REPO"; return; }
    [ -f "$XL1_REPO/agent/xl1_heartbeat.py" ] && { printf '%s' "$XL1_REPO"; return; }
  fi
  for d in /opt/MyAdventureWebsite /opt/xl1-node-monitor \
           "$HOME/xl1-node-monitor" /opt/xl1-tools; do
    [ -f "$d/pi-agent/xl1_heartbeat.py" ] && { printf '%s' "$d"; return; }
    [ -f "$d/agent/xl1_heartbeat.py" ] && { printf '%s' "$d"; return; }
  done
}
REPO="$(find_repo)"
# A CHECKOUT IS NOT NECESSARILY A CLONE. The wizard can fetch its files one by
# one, and the CM4 -- the only machine running the published layout -- has a
# directory of them with no .git at all. `git pull` there is not a slow path,
# it is a fatal error, and every option that began with one silently did
# nothing useful afterwards. Asked, so the answer can be "fetch instead".
REPO_IS_CLONE=0
[ -n "$REPO" ] && [ -d "$REPO/.git" ] && REPO_IS_CLONE=1
PUBLIC_REPO="${PUBLIC_REPO:-${XL1_AGENT_RAW:-https://raw.githubusercontent.com/jebscc/xl1-node-monitor/main/agent}}"
# The agent and service live under different names in the two checkouts: the
# private tree calls them pi-agent/ and xl1-service/, the published one agent/
# and service/. Asked rather than assumed, so either works.
if [ -n "$REPO" ] && [ -d "$REPO/pi-agent" ]; then
  REPO_AGENT="$REPO/pi-agent"; REPO_SERVICE="$REPO/xl1-service"
elif [ -n "$REPO" ]; then
  REPO_AGENT="$REPO/agent"; REPO_SERVICE="$REPO/service"
else
  REPO_AGENT=""; REPO_SERVICE=""
fi

# The checkout is whatever find_repo above discovered -- there may be none, and
# the options that need one say so rather than acting on a guess.
AGENT_DIR="${AGENT_DIR:-/opt/xl1-heartbeat}"
SERVICE_DIR="${SERVICE_DIR:-$REPO_SERVICE}"

# A SECOND COMPOSE FILE IS THIS SITE'S BUSINESS, not the product's. One grid
# publishes the anchor on a tailnet address as well as loopback and keeps the
# override for it beside the checkout; most will have neither. Found if it is
# there, named as absent if it is not -- never invented, because deploying
# without one that IS needed drops a publish and the container's DNS.
TAILNET_OVERRIDE=""
for _t in ${XL1_COMPOSE_OVERRIDE:-} "$HOME/xl1-deploy/docker-compose.tailnet.yml" \
          "${REPO_SERVICE:-/nonexistent}/docker-compose.override.yml"; do
  [ -n "$_t" ] && [ -f "$_t" ] && { TAILNET_OVERRIDE="$_t"; break; }
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; X=$'\033[0m'
else B=""; D=""; G=""; R=""; Y=""; X=""; fi

say()  { printf '%s\n' "$1"; }
note() { printf '   %s%s%s\n' "$D" "$1" "$X"; }
warn() { printf '   %s%s%s\n' "$Y" "$1" "$X"; }
ok()   { printf '   %s%s%s\n' "$G" "$1" "$X"; }
err()  { printf '   %s%s%s\n' "$R" "$1" "$X"; }

ask_yn() { # ask_yn <prompt> -> 0 yes
  [ "$TTY_OK" = 1 ] || return 1
  printf '   %s [y/N]: ' "$1"
  IFS= read -r reply || reply=""
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# Show the command, ask, then run it. ONE PLACE, so no action can grow a path
# that skips the showing or the asking -- and so DRY_RUN covers all of them
# without each remembering to.
do_cmd() { # do_cmd <command string>
  printf '   %s$ %s%s\n' "$B" "$1" "$X"
  if [ "$DRY_RUN" = 1 ]; then note "dry run, nothing done"; return 0; fi
  ask_yn "run it?" || { note "skipped"; return 1; }
  sh -c "$1"
}

# A value this node could not tell us. Refuse rather than substitute: every
# action below that needs one would act on the wrong thing without it.
need() { # need <what> <value>
  if [ -z "$2" ]; then err "this node has no $1 that could be found, so that is not safe to do here"; return 1; fi
}

# --- the actions --------------------------------------------------------------

a_status() {
  say "${B}How it is${X}"
  do_cmd "docker ps --format 'table {{.Names}}\t{{.Status}}'"
  [ -n "$PRODUCER_UNIT" ] && do_cmd "systemctl status $PRODUCER_UNIT --no-pager | head -20"
  do_cmd "curl -s localhost:8090/health"
}

a_dump() {
  say "${B}Check the producer's configuration${X}"
  note "Resolves presets, env file and flags and exits WITHOUT starting an actor."
  need "producer env file" "$PRODUCER_ENV" || return 1
  do_cmd "sudo docker run --rm --env-file $PRODUCER_ENV $PRESET_ARGS xl1:local --dump-config"
}

# THE GATE, and the reason this menu is worth having over typing the commands.
# Exit 78 is EX_CONFIG -- the node refusing the file it is about to be given.
# Asking it costs one container that removes itself; not asking cost eighty-four
# restarts on 2026-09-21.
config_refused() {
  # UNKNOWN IS NOT A REFUSAL, and neither is a dry run. A gate that cannot ask
  # must not answer: reporting "the node refuses this" because we could not
  # find the file would stop a healthy node on the strength of our own
  # ignorance, which is the opposite of what the gate is for.
  [ -n "$PRODUCER_ENV" ] || return 1
  [ "$DRY_RUN" = 1 ] && return 1
  sudo docker run --rm --env-file "$PRODUCER_ENV" $PRESET_ARGS \
    xl1:local --dump-config >/dev/null 2>&1
  [ $? = 78 ]
}

a_restart_producer() {
  say "${B}Restart the producer${X}"
  if config_refused; then
    err "the node REFUSES the configuration in $PRODUCER_ENV (exit 78)."
    err "Restarting now would crash-loop it. Run option 2 to see what it objects to."
    return 1
  fi
  if [ -n "$PRODUCER_UNIT" ]; then
    warn "systemd owns this container, so the unit is restarted, not docker."
    do_cmd "sudo systemctl restart $PRODUCER_UNIT"
  else
    need "producer container" "$PRODUCER_CONTAINER" || return 1
    do_cmd "sudo docker restart $PRODUCER_CONTAINER"
  fi
  do_cmd "sleep 15; docker ps --filter name=xl1-producer --format '{{.Names}} {{.Status}}'"
}

a_wizard() {
  say "${B}Run the wizard${X}"
  note "Eleven steps, asks before each one, and shows what it will do first."
  warn "It RESTARTS the producer at the end."
  if [ -n "$REPO_AGENT" ] && [ -f "$REPO_AGENT/bootstrap-pi.sh" ]; then
    note "Running this checkout's copy, not the internet's."
    if [ "$REPO_IS_CLONE" = 1 ]; then
      do_cmd "cd $REPO && git pull --ff-only && bash ${REPO_AGENT#"$REPO/"}/bootstrap-pi.sh"
    else
      note "this checkout is not a clone, so there is nothing to pull first"
      do_cmd "bash $REPO_AGENT/bootstrap-pi.sh"
    fi
  else
    do_cmd "curl -fsSL ${XL1_AGENT_RAW:-https://raw.githubusercontent.com/jebscc/xl1-node-monitor/main/agent}/bootstrap-pi.sh | bash"
  fi
}

a_build_image() {
  say "${B}Build a new node image (CLI update)${X}"
  note "BUILDS ONLY. It never retags xl1:local, stops a container or"
  note "restarts the producer -- swapping the image is option 6."

  # THE TIMER IS OPTIONAL AND DELIBERATELY NOT INSTALLED BY THE WIZARD: a
  # component that acts on a running producer by itself is one an operator
  # should switch on knowingly. So most nodes do not have it, and offering
  # its unit unconditionally fails with "Unit not found" on every one of
  # them -- which reads as a broken menu rather than an absent extra.
  if systemctl cat xl1-image-rebuild.service >/dev/null 2>&1; then
    do_cmd "sudo systemctl start xl1-image-rebuild.service && journalctl -u xl1-image-rebuild -n 30 --no-pager"
    return
  fi

  note "the weekly rebuild timer is not installed here, which is the"
  note "default -- it acts on a running producer, so it is opt-in."
  if [ -n "$REPO_AGENT" ] && [ -f "$REPO_AGENT/rebuild-xl1-image.sh" ]; then
    note "Running the script directly instead. Same work, once, now."
    do_cmd "sudo bash $REPO_AGENT/rebuild-xl1-image.sh"
  else
    err "and there is no rebuild-xl1-image.sh on this machine to run"
    err "instead. See the README for installing the weekly timer."
    return 1
  fi
}

a_promote() {
  say "${B}Promote a built image and restart onto it${X}"
  do_cmd "docker images 'xl1:*' --format 'table {{.Tag}}\t{{.CreatedSince}}\t{{.Size}}'"
  [ "$TTY_OK" = 1 ] || { note "needs a terminal to ask which version"; return 1; }
  printf '   which tag (e.g. 5.3.3), or blank to stop: '
  IFS= read -r tag || tag=""
  [ -n "$tag" ] || { note "stopped"; return 1; }
  case "$tag" in
    local) err "xl1:local is the pointer, not a version. Pick the version to point it AT."; return 1 ;;
  esac
  if ! docker image inspect "xl1:$tag" >/dev/null 2>&1 && [ "$DRY_RUN" != 1 ]; then
    err "no image tagged xl1:$tag on this machine"; return 1
  fi
  do_cmd "docker tag xl1:$tag xl1:local" || return 1
  note "Now restart onto it. Rolling back means tagging the old version and repeating."
  a_restart_producer
}

# THE WHOLE STACK, NOT ONE PACKAGE OF IT. The first version of this printed
# @xyo-network/xl1-sdk alone, which was wrong twice over: it is not the only
# SDK in here -- @xyo-network/sdk sits beside it -- and singling out any one
# of them misrepresents how they move. Dependabot groups every
# `@xyo-network/*` and `@xylabs/*` into ONE pull request, deliberately,
# because they release in lockstep and typecheck only together. So the thing
# to show before and after is the group.
xyo_stack() {
  [ -f "$SERVICE_DIR/package.json" ] || { printf '<no checkout>\n'; return; }
  sed -n 's/.*"\(@\(xyo-network\|xylabs\)\/[^"]*\)": *"\([^"]*\)".*/  \1 \3/p' \
    "$SERVICE_DIR/package.json" | sort
}

compose_cmd() { # the compose command for THIS node, spelt once
  # THE OVERRIDE IS AN EXTRA, NOT A REQUIREMENT. A wizard-built node publishes
  # one port and has no second compose file; the base file is the whole of its
  # configuration. Naming a file that is not there makes compose fail on every
  # such node, which is most of them.
  if [ -n "$TAILNET_OVERRIDE" ]; then
    printf 'cd %s && sudo docker compose -f docker-compose.pi.yml -f %s' \
      "$SERVICE_DIR" "$TAILNET_OVERRIDE"
  else
    printf 'cd %s && sudo docker compose -f docker-compose.pi.yml' "$SERVICE_DIR"
  fi
}

# WHO MADE THE CONTAINER, which decides whether compose may touch it at all.
# bootstrap-pi.sh creates xl1-service-anchor-1 with `docker run --name`, taking
# by hand the exact name compose would use -- and compose will not adopt a
# container it did not create. It fails with "the container name is already in
# use", having already built the image, so the build succeeds and the swap
# does not. Every wizard run puts the node back into this state.
compose_owns_anchor() {
  [ -n "$ANCHOR_CONTAINER" ] || return 1
  [ -n "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
          "$ANCHOR_CONTAINER" 2>/dev/null)" ]
}

# Hand the container over to compose, without losing what the running one has.
#
# THE ONLY DANGER HERE IS THE PUBLISHES. The wizard's container carries the
# loopback publish and, on this machine, a tailnet one the Render backend
# reads; the compose override file is what reproduces both, plus the DNS the
# container needs to resolve anything at all. Remove the old container when
# compose would give you fewer, and the anchor comes back healthy, reachable
# by nothing, with the chain height quietly gone from the site.
#
# So this counts them on both sides and refuses on a shortfall. It does not
# try to be clever about which port is which: fewer is fewer.
swap_anchor_to_compose() {
  warn "This container was made by the wizard, not by compose, so compose"
  warn "cannot adopt it -- that is the name conflict above. Handing it over"
  warn "means removing it and letting compose create its own."
  _had="$(docker port "$ANCHOR_CONTAINER" 2>/dev/null | grep -c ':')"
  note "the running container publishes $_had:"
  do_cmd "docker port $ANCHOR_CONTAINER"
  note "what compose would create instead:"
  do_cmd "$(compose_cmd) config | grep -E 'published:|dns:|- \"?[0-9.]*:?[0-9]+:' "
  _will="$(sh -c "$(compose_cmd) config" 2>/dev/null | grep -c 'published:')"
  if [ "${_will:-0}" -lt "${_had:-0}" ]; then
    err "compose would publish $_will where the running container publishes $_had."
    err "Removing it would lose a binding. Nothing done -- check the override at"
    err "$TAILNET_OVERRIDE before trying again."
    return 1
  fi
  note "compose publishes $_will, which is not fewer. Safe to hand over."
  do_cmd "sudo docker rm -f $ANCHOR_CONTAINER" || return 1
  do_cmd "$(compose_cmd) up -d" || return 1
  _now="$(docker port "$ANCHOR_CONTAINER" 2>/dev/null | grep -c ':')"
  if [ "${_now:-0}" -lt "${_had:-0}" ]; then
    err "it came back publishing $_now where it had $_had. The Render proxy"
    err "reads the second one -- check $TAILNET_OVERRIDE and docker port."
    return 1
  fi
  ok "handed over to compose, still publishing $_now"
}

# WHAT NPM HAS, BESIDE WHAT WE PIN. Dependabot proposes a bump weekly and a
# merged one only arrives when the checkout is pulled -- so a node can sit a
# patch or two behind for a week with nothing saying so. This asks the registry
# directly, which is the same thing the panel's SDK tile does and the reason it
# reads "5.6.1 available" while the service runs 5.6.0.
#
# IT ONLY EVER REPORTS. Rewriting package.json on the node would put the Pi on
# a version no typecheck in this repository has ever seen, and the lockfile
# beside it would no longer describe the tree -- `pnpm install
# --frozen-lockfile`, which is what the image build runs, would then refuse it.
# The bump belongs where it can be verified and committed.
xyo_latest() { # xyo_latest <package> -> version, or nothing
  curl -fsSL --max-time 20 "https://registry.npmjs.org/$1/latest" 2>/dev/null \
    | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' | head -1
}

# WHAT THE CONTAINER IS ACTUALLY RUNNING, which is a third reading and the
# one that was missing. The checkout can pin 5.6.1 while the running image was
# built from 5.6.0, and then "every pinned package is the newest published" is
# true, unhelpful, and reads as though there is nothing to do.
#
# THE SAME SOURCE THE PORTAL USES. The panel's SDK tile is the service's own
# /versions endpoint, read by the agent -- a process is the authority on what
# it actually resolved at runtime, which is not always what package.json asked
# for. Asking the file instead is how a stale container goes unnoticed.
running_stack() {
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsSL --max-time 10 http://localhost:8090/versions 2>/dev/null \
    | sed -n 's/.*"packages" *: *{\([^}]*\)}.*/\1/p' \
    | tr ',' "\n" \
    | sed -n 's/"\([^"]*\)" *: *"\([^"]*\)"/\1 \2/p'
}

report_running() {
  _run="$(running_stack | sort)"
  if [ -z "$_run" ]; then
    note "the running service did not answer /versions, so what it loaded is unknown"
    return 0
  fi
  _stale=""
  _pins="$(xyo_stack)"
  # `|| [ -n "$_n" ]` BECAUSE THE LAST LINE HAS NO NEWLINE. Command
  # substitution strips the trailing one, so `read` returns non-zero on the
  # final record and a plain loop silently drops it -- which it did: sorted
  # last, @xyo-network/xl1-sdk was the one package never reported stale, and
  # it is the package the panel's own SDK tile reads.
  _stale="$(printf '%s' "$_run" | while read -r _n _v || [ -n "$_n" ]; do
    [ -n "$_n" ] || continue
    _want="$(printf '%s' "$_pins" | awk -v n="$_n" '$1 == n { print $2 }')"
    [ -n "$_want" ] || continue
    [ "$_want" = "$_v" ] && continue
    printf '   %s running %s, this checkout pins %s\n' "$_n" "$_v" "$_want"
  done)"
  if [ -n "$_stale" ]; then
    warn "the CONTAINER is behind the checkout:"
    printf '%s%s%s\n' "$Y" "$_stale" "$X"
    note "This is what a rebuild fixes. Nothing was merged because nothing"
    note "needed to be -- the image simply predates what is already here."
  else
    ok "the running container matches what this checkout pins"
  fi
}

report_behind() {
  [ -f "$SERVICE_DIR/package.json" ] || return 0
  command -v curl >/dev/null 2>&1 || { note "no curl, so npm was not asked"; return 0; }
  # CAPTURED, NOT WRITTEN TO A TEMP FILE. The loop runs in a subshell because
  # it is on the right of a pipe, so anything it sets is lost -- the first
  # version carried the answer out through /tmp and needed an `rm` afterwards,
  # which is a command running outside do_cmd. The test that forbids that
  # caught it, and the fix is to need neither.
  _behind="$(xyo_stack | while read -r _name _have; do
    [ -n "$_name" ] || continue
    _new="$(xyo_latest "$_name")"
    [ -n "$_new" ] || continue
    [ "$_new" = "$_have" ] && continue
    printf '   %s %s -> %s available
' "$_name" "$_have" "$_new"
  done)"
  if [ -n "$_behind" ]; then
    warn "newer releases are published than this checkout pins:"
    printf '%s%s%s
' "$Y" "$_behind" "$X"
    note "scripts/bump-xyo-stack.sh --apply takes them and runs every gate."
    note "It borrows node from the service's own image, so this host needs"
    note "no toolchain. Commit and push after it, then pull here."
  else
    ok "every pinned package is the newest published"
  fi
}

a_service() {
  say "${B}Update the service XYO stack (SDK) and redeploy${X}"
  # THE PULL IS THE UPDATE, and the first version of this had no pull at all.
  # `@xyo-network/xl1-sdk` is pinned to an exact version in package.json, so
  # the bump is a change to that file: Dependabot proposes it, CI typechecks
  # it, you merge it, and it reaches this machine only when the checkout is
  # pulled. `docker compose up --build` alone rebuilds whatever is already on
  # disk -- which looks exactly like a successful update and installs nothing.
  if [ -z "$REPO_SERVICE" ]; then
    err "this machine has no checkout of the anchor service, so there is"
    err "nothing here to update it from."
    return 1
  fi
  _before="$(xyo_stack)"
  note "the XYO stack this checkout pins right now:"
  printf '%s%s%s
' "$D" "$_before" "$X"
  if [ "$REPO_IS_CLONE" = 1 ]; then
    do_cmd "cd $REPO && git pull --ff-only"
  else
    warn "this checkout is not a clone, so a merged bump cannot be collected"
    warn "here. The rebuild below uses whatever is already on disk."
  fi
  _after="$(xyo_stack)"
  # THE DIFFERENCE, NOT TWO LISTS. Nine lines before and nine after is a
  # spot-the-difference puzzle at the exact moment somebody is tired, and the
  # answer that matters is usually "none of them".
  report_behind
  report_running
  if [ "$_before" = "$_after" ]; then
    note "nothing moved -- there was nothing merged to collect, which is not a failure"
  else
    ok "the stack moved:"
    printf '%s
' "$_after" | comm -13 <(printf '%s
' "$_before") - | sed "s/^/   ${G}now${X} /"
  fi
  # THE TWO-FILE FORM OR NOTHING. The bare -f docker-compose.pi.yml drops the
  # tailnet publish AND the container's DNS: every chain read then fails
  # EAI_AGAIN while the producer beside it stays perfectly fine. That is not a
  # hypothesis, it happened on 2026-09-18 from a one-file command quoted out
  # of a note.
  # AN ABSENT OVERRIDE IS ONLY A PROBLEM IF SOMETHING NEEDS IT. This refused
  # outright, which was right for the node it was written on -- that one
  # publishes a tailnet address as well as loopback, and the override is the
  # only thing that reproduces it. On a wizard-built node there is one
  # publish, no override and nothing to lose, so refusing there made the
  # option unusable on the ordinary shape. It also printed "no override at "
  # with nothing after it, which is a path nobody can go and look at.
  #
  # The question is not "is there an override" but "would this deploy publish
  # fewer ports than the container already has". The count answers it either
  # way, and needs no knowledge of which node this is.
  if [ -z "$TAILNET_OVERRIDE" ]; then
    _have="$(docker port "$ANCHOR_CONTAINER" 2>/dev/null | grep -c ':')"
    if [ "${_have:-0}" -gt 1 ]; then
      err "this container publishes $_have ports and no compose override was"
      err "found to reproduce them. Deploying would drop one, and the chain"
      err "height goes with it. Set XL1_COMPOSE_OVERRIDE and try again."
      [ "$DRY_RUN" = 1 ] || return 1
    else
      note "no compose override here, and none needed: the container"
      note "publishes ${_have:-0}, which the base file already describes."
    fi
  fi
  # BEFORE THE BUILD, not after it. Compose builds the image first and only
  # then discovers it cannot have the name -- so the old shape spent two
  # minutes succeeding and then failed at the one step that mattered, twice,
  # on 2026-09-22. Asked first, the handover happens or the run stops.
  if [ -n "$ANCHOR_CONTAINER" ] && ! compose_owns_anchor; then
    swap_anchor_to_compose || return 1
  fi
  do_cmd "$(compose_cmd) up -d --build" || return 1
  say ""
  note "Two published ports, or the Render proxy is down:"
  do_cmd "docker port ${ANCHOR_CONTAINER:-xl1-service-anchor-1}"
  warn "A healthy container nothing can talk to looks exactly like a working one."
  warn "Check something can still authenticate, not merely that it came up."
}

a_agent() {
  say "${B}Update the heartbeat agent${X}"
  note "Copies the checkout's agent over the installed one and restarts it."
  if [ -z "$REPO_AGENT" ] || [ ! -f "$REPO_AGENT/xl1_heartbeat.py" ]; then
    err "this machine has no checkout of the agent to copy from."
    err "The wizard can install from a pipe, which leaves none behind. Clone"
    err "the repository, or re-run the wizard (option 4) to take a new agent."
    [ "$DRY_RUN" = 1 ] || return 1
  fi
  if [ "$REPO_IS_CLONE" = 1 ]; then
    do_cmd "cd $REPO && git pull --ff-only && sudo cp ${REPO_AGENT#"$REPO/"}/xl1_heartbeat.py $AGENT_DIR/ && sudo systemctl restart xl1-heartbeat"
  else
    note "not a clone, so the agent is fetched the way the wizard fetches it"
    do_cmd "curl -fsSL $PUBLIC_REPO/xl1_heartbeat.py -o /tmp/xl1_heartbeat.py && sudo install -m 644 /tmp/xl1_heartbeat.py $AGENT_DIR/xl1_heartbeat.py && rm -f /tmp/xl1_heartbeat.py && sudo systemctl restart xl1-heartbeat"
  fi
  do_cmd "journalctl -u xl1-heartbeat -n 20 --no-pager"
}

a_logs() {
  say "${B}Logs${X}"
  need "producer container" "$PRODUCER_CONTAINER" || return 1
  do_cmd "docker logs --tail 80 $PRODUCER_CONTAINER"
  do_cmd "journalctl -u xl1-heartbeat -n 40 --no-pager"
}

a_selfupdate() {
  say "${B}Update these commands${X}"
  # NO CLONE IS NOT NO SOURCE. The published repo is where the wizard got
  # these in the first place, and fetching them again is the same act. This
  # used to refuse outright, on the one machine that most needed it.
  if [ "$REPO_IS_CLONE" = 1 ]; then
    do_cmd "cd $REPO && git pull --ff-only"
  else
    note "not a clone, so these are fetched from the published repository"
  fi

  for _c in xl1-menu xl1-help; do
    if [ "$REPO_IS_CLONE" = 1 ] && [ -f "$REPO_AGENT/$_c.sh" ]; then
      _src="$REPO_AGENT/$_c.sh"
    else
      _src="/tmp/$_c.fetched.sh"
      do_cmd "curl -fsSL $PUBLIC_REPO/$_c.sh -o $_src" || { note "could not fetch $_c"; continue; }
    fi
    # WHERE IT ACTUALLY IS, not where it is usually put. Same rule as every
    # other path here: /usr/local/bin is a convention, not a fact about this
    # machine, and installing beside a copy rather than over it leaves two.
    _dst="$(command -v "$_c" 2>/dev/null)"
    if [ -z "$_dst" ]; then
      note "$_c is not installed; skipping it"
      continue
    fi
    if [ ! -f "$_src" ] && [ "$DRY_RUN" != 1 ]; then
      err "$_src is missing from the checkout"; continue
    fi
    # A RENAME, NOT A WRITE OVER THE LIVE FILE, and the difference is this
    # script. `install` truncates the destination and writes into it, while
    # bash reads a script INCREMENTALLY as it runs -- so a menu overwriting
    # itself mid-run has the rest of its own source replaced underneath the
    # interpreter, and what executes next is whatever now sits at that offset.
    # The temp file is made in the SAME directory so the rename is atomic
    # rather than a copy across filesystems, and the running process keeps
    # reading the old inode until it exits.
    _dir="$(dirname "$_dst")"
    do_cmd "sudo install -m 755 '$_src' '$_dir/.$_c.new' && sudo mv -f '$_dir/.$_c.new' '$_dst'"
  done

  warn "The menu you are reading is still the old one -- bash has it open."
  warn "Quit and run xl1-menu again to be sure you are on the new one."
}

a_help() {
  if command -v xl1-help >/dev/null 2>&1; then xl1-help
  else err "xl1-help is not installed; see pi-agent/xl1-help.sh"; fi
}

# --- the menu -----------------------------------------------------------------
#
# The number, the label, and the function. ONE TABLE, so the menu a reader sees
# and the action that runs cannot disagree -- two lists would, and the one that
# lost would send somebody's keypress somewhere else.
ITEMS="
1|Status -- containers, unit, anchor health|a_status
2|Check the producer's config (no restart)|a_dump
3|Restart the producer|a_restart_producer
4|Run the wizard (bootstrap-pi.sh)|a_wizard
5|Build a new node image (CLI update)|a_build_image
6|Promote an image and restart onto it|a_promote
7|Update the service SDK and redeploy|a_service
8|Update the heartbeat agent|a_agent
9|Logs|a_logs
u|Update xl1-menu and xl1-help|a_selfupdate
h|The help reference (xl1-help)|a_help
"

menu() {
  printf '\n%s== This node%s\n' "$B" "$X"
  printf '   producer   %s\n' "${PRODUCER_CONTAINER:-<none found>}${PRODUCER_UNIT:+  (unit: $PRODUCER_UNIT)}"
  printf '   env file   %s\n' "${PRODUCER_ENV:-<not discoverable>}"
  printf '   anchor     %s\n' "${ANCHOR_CONTAINER:-<none found>}"
  printf '   checkout   %s\n' "${REPO:-<none found>}"
  printf '   backend    %s\n' "${BACKEND:-<not set in $AGENT_ENV>}"
  [ "$DRY_RUN" = 1 ] && printf '   %sDRY RUN -- nothing will be done%s\n' "$Y" "$X"
  printf '\n%s== What would you like to do%s\n' "$B" "$X"
  printf '%s' "$ITEMS" | while IFS='|' read -r k label _fn; do
    [ -n "$k" ] && printf '   %s) %s\n' "$k" "$label"
  done
  printf '   q) quit\n\n'
}

dispatch() { # dispatch <key>
  local fn=""
  while IFS='|' read -r k _label f; do
    [ -n "$k" ] && [ "$k" = "$1" ] && fn="$f"
  done <<EOF
$ITEMS
EOF
  if [ -z "$fn" ]; then err "no such choice: $1"; return 2; fi
  printf '\n'
  "$fn"
}

main() {
  if [ "$TTY_OK" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    menu
    err "Not a terminal, so nothing is chosen for you. Run it from a shell,"
    err "or use DRY_RUN=1 to see what each choice would run."
    exit 1
  fi
  while :; do
    menu
    printf 'choice: '
    IFS= read -r choice || break
    case "$choice" in
      q|Q|"") printf '\n'; break ;;
      *) dispatch "$choice" || true ;;
    esac
  done
}

case "${1:-}" in
  -h|--help) menu ;;
  "") main ;;
  *) dispatch "$1" ;;
esac
