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
# Set once the interactive loop is running. Only there may an update restart
# the process; `xl1-menu u` is a one-shot and its next run is new anyway.
MENU_LOOP=0
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

# THE SAME RUNNER, WITH THE OUTPUT HANDED BACK.
#
# One action needs to read what a command said -- the CLI update reads the
# version the rebuild script promoted, rather than asking npm a second time
# and hoping the two answers agree. Everything else about it is do_cmd: the
# same showing, the same asking, the same dry run. A second runner that
# skipped either would be precisely the path the note above exists to forbid.
#
# The command's own output goes to STDERR so the operator watches it happen,
# and to stdout so the caller can read it. Without that split, capturing the
# output would silence the command -- and a several-minute image build with
# nothing on screen reads as a hung menu.
do_capture() { # do_capture <command string> -> the command's output on stdout
  printf '   %s$ %s%s\n' "$B" "$1" "$X" >&2
  if [ "$DRY_RUN" = 1 ]; then note "dry run, nothing done" >&2; return 0; fi
  ask_yn "run it?" >&2 || { note "skipped" >&2; return 1; }
  _cap="${TMPDIR:-/tmp}/xl1-menu.$$.out"
  sh -c "$1" >"$_cap" 2>&1
  _rc=$?
  sed 's/^/   /' "$_cap" >&2
  cat "$_cap"
  rm -f "$_cap"
  return $_rc
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

# HOW THIS NODE REHEARSES ITS CONFIG, and there are two shapes of node.
#
# A unit-supervised node keeps its environment in a file and its presets in a
# mounted directory, and a restart re-reads BOTH -- so the rehearsal is a
# fresh container handed that same pair, which is exactly what the next start
# would get.
#
# A wizard-built node has no unit. bootstrap-pi.sh starts the producer with
# `docker run --env-file <runtime file>` and then DELETES that file on
# purpose: a second copy of the mnemonic on disk is the thing to avoid, and it
# says so. So there is no env file to hand a fresh container, and building one
# out of `docker inspect` would put back precisely what the wizard refused to
# leave lying about. `docker restart` reuses the environment already baked
# into the container and re-reads the mounted presets -- so running the dump
# INSIDE the running container asks the question a restart answers, copies
# nothing and writes nothing.
#
# SPELT ONCE. The gate below runs whatever this prints, so the command that is
# shown and the command that decides are the same string; two copies would
# drift into rehearsing one thing and displaying another.
dump_config_cmd() {   # the command, or nothing when this node cannot be asked
  if [ -n "$PRODUCER_ENV" ]; then
    printf 'sudo docker run --rm --env-file %s %s xl1:local --dump-config' \
      "$PRODUCER_ENV" "$PRESET_ARGS"
  elif [ -n "$PRODUCER_CONTAINER" ]; then
    printf 'sudo docker exec %s node /opt/xl1/lib/entrypoint.mjs --dump-config' \
      "$PRODUCER_CONTAINER"
  fi
}

a_dump() {
  say "${B}Check the producer's configuration${X}"
  note "Resolves presets, env file and flags and exits WITHOUT starting an actor."
  _cmd="$(dump_config_cmd)"
  if [ -z "$_cmd" ]; then
    err "this node has no producer env file and no running producer container,"
    err "so there is nothing here to rehearse the configuration from."
    return 1
  fi
  if [ -z "$PRODUCER_ENV" ]; then
    note "No unit on this node, so this asks the running container, which is"
    note "the environment a restart reuses."
  fi
  do_cmd "$_cmd"
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
  _cmd="$(dump_config_cmd)"
  [ -n "$_cmd" ] || return 1
  [ "$DRY_RUN" = 1 ] && return 1
  sh -c "$_cmd" >/dev/null 2>&1
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

# THE WHOLE CLI UPDATE, IN ONE CHOICE: fetch the newest release, build it,
# put the node on it, and undo that if the node will not have it.
#
# It used to build and stop, leaving the operator to read a version off the
# screen and type it into option 6. That split is right for the unattended
# weekly timer -- nobody should discover overnight that their producer moved
# version -- and wrong here, where a person has just asked for the update and
# is watching it happen.
#
# THE ORDER IS THE SAFETY, and each step is undoable until the next one:
#
#   build       nothing is running it; a failure leaves the node untouched
#   smoke       the entrypoint answers --version, or the build is not promoted
#   promote     a tag move, reversible for free -- the producer is still on
#               the OLD image, because tagging restarts nothing
#   config      ask the NEW image what it thinks of THIS node's env file
#   restart     the only step that can leave a node down, and the only one
#               taken after everything above has agreed
#
# THE CONFIG STEP IS THE ONE THAT EARNS ITS KEEP. A smoke test proves the
# image runs; it says nothing about whether the CLI inside still understands
# the settings this node is configured with. A release that renames or drops
# a setting passes the smoke test and then exits 78 on start -- and a producer
# that will not start is a producer signing nothing until someone notices.
a_build_image() {
  say "${B}Update the node CLI (build, promote, restart)${X}"

  _rb=""
  [ -n "$REPO_AGENT" ] && [ -f "$REPO_AGENT/rebuild-xl1-image.sh" ] \
    && _rb="$REPO_AGENT/rebuild-xl1-image.sh"

  if [ -z "$_rb" ]; then
    # THE UNIT CAN ONLY BUILD. Its ExecStart is fixed and carries no
    # --promote, so this path is the old behaviour and says so rather than
    # quietly doing half of what the menu offered.
    if systemctl cat xl1-image-rebuild.service >/dev/null 2>&1; then
      warn "no rebuild-xl1-image.sh in a checkout here, so the rebuild unit"
      warn "is used instead -- it BUILDS ONLY. Promote with option 6."
      do_cmd "sudo systemctl start xl1-image-rebuild.service && journalctl -u xl1-image-rebuild -n 30 --no-pager"
      return
    fi
    err "no rebuild-xl1-image.sh on this machine and no rebuild unit either."
    err "The wizard (choice 4) fetches the agent scripts, which brings it."
    return 1
  fi

  _was="$(running_cli)"
  note "the producer is running CLI ${_was:-<unreadable>}"
  warn "This RESTARTS the producer if a newer release builds cleanly."

  # --promote moves the tag inside the script, which is where the version
  # just built is known without parsing a log line for it. The last two lines
  # it prints are the contract between the two files.
  # do_capture has already shown this as it ran; _out is for reading, not
  # for printing again.
  _out="$(do_capture "sudo bash $_rb --promote")" || {
    err "the rebuild failed. Nothing was promoted and the node is untouched."
    return 1
  }

  _new="$(printf '%s\n' "$_out" | sed -n 's/^PROMOTED=//p' | tail -1)"
  _prev="$(printf '%s\n' "$_out" | sed -n 's/^PREVIOUS=//p' | tail -1)"
  if [ -z "$_new" ]; then
    note "nothing was promoted -- either the build was already current or it"
    note "declined to promote. The producer is untouched."
    return 0
  fi
  if [ "$_new" = "$_prev" ]; then
    ok "already on $_new; nothing to restart onto."
    return 0
  fi

  ok "xl1:local now points at $_new (was ${_prev:-unknown})"

  # THE NEW IMAGE, ASKED ABOUT THIS NODE'S ENV, BEFORE ANYTHING RESTARTS.
  if config_refused; then
    err "the NEW CLI refuses this node's configuration (exit 78)."
    err "Restarting would crash-loop it, so it has not been restarted."
    rollback_cli "$_prev"
    return 1
  fi

  a_restart_producer || {
    err "the restart did not come up clean."
    rollback_cli "$_prev"
    return 1
  }
  ok "the producer is running CLI $_new"
  note "roll back with: sudo docker tag xl1:${_prev:-<version>} xl1:local"
  note "then option 3 to restart onto it."
}

# PUT THE POINTER BACK. Only ever called with a version this run recorded
# before it moved the tag -- never a guess at which of the kept images was
# the good one.
rollback_cli() {
  if [ -z "$1" ]; then
    err "and the version xl1:local pointed at could not be named, so there is"
    err "no automatic rollback. 'docker images xl1' lists what is still here;"
    err "option 6 promotes one of them."
    return 1
  fi
  warn "putting xl1:local back to $1"
  do_cmd "sudo docker tag xl1:$1 xl1:local" \
    && ok "xl1:local points at $1 again. The producer never left it." \
    || err "could not retag xl1:local -- do it by hand before any restart."
}

# WHAT THE PRODUCER IS ACTUALLY RUNNING, asked of the container rather than of
# the tag: xl1:local is a pointer and may already have been moved past what
# the running container started from.
running_cli() {
  [ -n "$PRODUCER_CONTAINER" ] || return 0
  docker exec "$PRODUCER_CONTAINER" xl1 --version 2>/dev/null | head -1 || true
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
  # ALL THREE SCOPES, the same set bump-xyo-stack.sh takes. This read two of
  # them while the service also pins @ariestools/sdk, so on 2026-09-23 the
  # screen listed four packages, said every pinned package was the newest
  # published, and had never asked npm about the fifth. A report that leaves a
  # package out is worse than one that cannot run: it answers the question.
  sed -n 's/.*"\(@\(xyo-network\|xylabs\|ariestools\)\/[^"]*\)": *"\([^"]*\)".*/  \1 \3/p' \
    "$SERVICE_DIR/package.json" | sort
}

# WHICH COMPOSE THIS MACHINE HAS, IF ANY. The wizard never installs one --
# it creates the anchor with `docker run --name` -- so a node that has only
# ever met the wizard has no compose plugin, and every compose command here
# comes back as a docker usage screen. Debian's docker.io package ships
# without it too. `docker compose version` is answered by the client alone,
# so this needs no daemon and no sudo.
compose_bin() {
  if docker compose version >/dev/null 2>&1; then printf 'docker compose'
  elif command -v docker-compose >/dev/null 2>&1; then printf 'docker-compose'
  fi
}
COMPOSE_BIN="$(compose_bin)"

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
    printf '%s%s%s\n' "$Y" "$_behind" "$X"
    return 1
  fi
  ok "every pinned package is the newest published"
  return 0
}

# WHERE THE BUMP SCRIPT IS. It ships inside the service in the published tree
# and beside it in the private one, so both are looked at rather than one
# being assumed -- the node has the published layout.
find_bump() {
  for _b in "$SERVICE_DIR/scripts/bump-xyo-stack.sh" \
            "${REPO:-/nonexistent}/scripts/bump-xyo-stack.sh"; do
    [ -f "$_b" ] && { printf '%s' "$_b"; return; }
  done
}

a_service() {
  say "${B}Update the XYO SDK${X}"
  # THIS TAKES THE NEWEST PUBLISHED VERSIONS AND PROVES THEM. The pins are
  # exact versions in package.json, so moving them is a change to that file;
  # the bump script asks npm what is newest, writes it, resolves the lockfile
  # and runs every gate in the tree, putting the files back if any fails.
  #
  # IT DOES NOT DEPLOY. The container goes on running the code it was built
  # from until something rebuilds it, which is a separate act on a separate
  # line -- and the line it needs differs by node, so it is named, not run.
  if [ -z "$REPO_SERVICE" ]; then
    err "no checkout of the anchor service here, so nothing to update."
    return 1
  fi
  _before="$(xyo_stack)"
  note "pinned in this checkout now:"
  printf '%s%s%s\n' "$D" "$_before" "$X"
  [ "$REPO_IS_CLONE" = 1 ] && do_cmd "cd $REPO && git pull --ff-only"

  if report_behind; then
    report_running
    deploy_line
    return 0
  fi

  _bump="$(find_bump)"
  if [ -z "$_bump" ]; then
    err "there are newer releases and no bump-xyo-stack.sh in this checkout"
    err "to take them with. The wizard (choice 4) re-fetches main, which"
    err "brings it."
    return 1
  fi
  # IT BORROWS NODE FROM THE SERVICE'S OWN IMAGE, so this host needs no
  # toolchain -- which is the point, the Pi has neither node nor pnpm.
  do_cmd "sudo bash $_bump --apply" || return 1

  _after="$(xyo_stack)"
  if [ "$_before" = "$_after" ]; then
    err "the pins did not move. The bump puts the files back when a gate"
    err "fails, so this checkout is as it was -- read the gate above."
    return 1
  fi
  ok "the XYO SDK moved:"
  printf '%s\n' "$_after" | comm -13 <(printf '%s\n' "$_before") - \
    | sed "s/^/   ${G}now${X} /"
  report_running
  deploy_line
}

# WHAT WOULD RUN IT, spelt for THIS node and printed rather than done. The two
# shapes need different commands and getting it wrong is expensive: the
# one-file compose form drops the tailnet publish and the container's DNS.
deploy_line() {
  say ""
  note "This does not deploy. What would run the code now on disk:"
  if [ -z "$COMPOSE_BIN" ]; then
    note "  choice r -- rebuilds from this checkout and puts the"
    note "  container on it, keeping the image it replaced."
  else
    note "  $(compose_cmd) up -d --build"
    note "  A wizard-made container is removed first; compose will not adopt"
    note "  one it did not create."
  fi
}

# WHERE THE NODE IMAGE RECIPE IS. XYO's xl1-docker-images, cloned by the
# wizard on a machine that builds its own image. A node that was given a
# built image has none, and that is not a fault.
#
# THE OVERRIDE IS CHECKED ON ITS OWN, QUOTED. Inside the loop it was
# `for _d in ${XL1_IMAGES_REPO:-} ...` -- unquoted, so a checkout whose path
# contains a space splits into fragments and is never found. find_repo above
# was fixed for exactly this earlier in the same day and this reintroduced it
# three functions later; the test below now covers both.
find_images_repo() {
  if [ -n "${XL1_IMAGES_REPO:-}" ] && [ -d "$XL1_IMAGES_REPO/.git" ]; then
    printf '%s' "$XL1_IMAGES_REPO"; return
  fi
  for _d in /opt/xl1-docker-images "$HOME/xl1-docker-images"; do
    [ -d "$_d/.git" ] && { printf '%s' "$_d"; return; }
  done
}

# Update the recipe the node image is built FROM -- which is not where the
# CLI version comes from.
#
# THE CLI COMES FROM npm AT BUILD TIME. rebuild-xl1-image.sh asks the registry
# for @xyo-network/xl1-cli/latest and passes it as a build arg, so a plain
# rebuild takes a newer CLI whatever state this checkout is in. Updating the
# recipe is about the Dockerfile, the entrypoint and the presets in it.
#
# AND IT DOES NOT PULL. On the board that builds its own image this checkout
# is also the LIVE PRESETS MOUNT -- the producer reads roles/producer-rest.json
# out of it while it runs, local edits and all. A merge that would overwrite
# one of those is refused by git rather than silently taken, and this says so
# before asking for a yes instead of after.
a_recipe() {
  say "${B}Update the node image recipe${X}"
  _ir="$(find_images_repo)"
  if [ -z "$_ir" ]; then
    err "no xl1-docker-images checkout here, so there is no recipe to update."
    note "That is normal on a node given a prebuilt image. The CLI version"
    note "does not come from here in any case -- the rebuild asks npm for it."
    return 1
  fi
  note "recipe   $_ir"
  do_cmd "git -C '$_ir' fetch --quiet origin" || return 1

  _behind="$(git -C "$_ir" rev-list --count HEAD..@{u} 2>/dev/null)"
  if [ -z "$_behind" ]; then
    err "could not compare with upstream -- no tracking branch here."
    return 1
  fi
  if [ "$_behind" = 0 ]; then
    ok "the recipe is current with upstream"
    return 0
  fi
  warn "$_behind commit(s) upstream that this checkout does not have:"
  do_cmd "git -C '$_ir' log --oneline HEAD..@{u} | head -10" || true

  # WHAT ACTUALLY REACHES THE IMAGE. On 2026-09-23 the Pi 4 was seventeen
  # commits behind and every one of them touched .github/, README.md or
  # CLAUDE.md -- nothing the build copies. Merging would have changed the
  # node not at all, and a rebuild afterwards would have produced the same
  # image. A count of commits is not a reason to rebuild anything.
  _touch="$(git -C "$_ir" diff --name-only HEAD..@{u} 2>/dev/null \
            | grep -vE '^\.github/|\.md$' | head -10)"
  if [ -z "$_touch" ]; then
    ok "none of it reaches the built image -- docs and CI only"
    note "Taking it is harmless and changes nothing the node runs."
  else
    warn "these reach the built image:"
    printf '%s%s%s\n' "$D" "$_touch" "$X"
  fi

  # THE LIVE PRESETS SIT IN THIS DIRECTORY. Said before the merge is offered,
  # because afterwards is no use.
  _dirty="$(git -C "$_ir" status --short -- presets 2>/dev/null | head -5)"
  if [ -n "$_dirty" ]; then
    warn "this checkout has local preset changes, which the producer is"
    warn "reading right now:"
    printf '%s%s%s\n' "$D" "$_dirty" "$X"
    warn "git refuses a merge that would overwrite them rather than taking"
    warn "it quietly. If it refuses, keep the local value -- it is the one"
    warn "this node was tuned to."
  fi

  do_cmd "git -C '$_ir' merge --ff-only @{u}" || return 1
  ok "recipe updated"
  say ""
  note "Nothing running has changed. Choice 5 builds an image from it, and"
  note "choice 6 puts the node on the result."
}

# THE MISSING HALF. Moving the pins changes the checkout; the container goes
# on running the image it was built from. A node with compose closes that with
# `up -d --build`; a wizard-built one had no answer narrower than re-running
# the whole wizard, which also re-fetches main and would throw a local bump
# away. redeploy-anchor.sh builds from what is on disk and puts the container
# on it using the wizard's OWN run flags, read out of bootstrap-pi.sh -- so
# there is still one copy of that list, and this follows it.
a_redeploy() {
  say "${B}Redeploy the anchor service${X}"
  _rd=""
  for _c in "${REPO_AGENT:-/nonexistent}/redeploy-anchor.sh"; do
    [ -f "$_c" ] && _rd="$_c"
  done
  if [ -z "$_rd" ]; then
    err "no redeploy-anchor.sh in this checkout. The wizard (choice 4)"
    err "re-fetches main, which brings it."
    return 1
  fi
  note "Rebuilds the image from $SERVICE_DIR and puts the container on it,"
  note "with the run flags taken from the wizard rather than copied."
  note "The image it replaces is kept as xl1-service:previous, and a build"
  note "that fails, a service that will not answer, or a container that"
  note "comes back publishing fewer ports all put it back."
  do_cmd "sudo bash $_rd" || return 1
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

  # AND THEN RUN THE NEW ONE. A warning that has to be obeyed for the result
  # to be right is a weaker thing than simply doing it. On 2026-09-22 the
  # commands were installed, the session carried on in the old code because
  # bash had the old inode open, and the next choice reproduced the exact bug
  # that had just been fixed -- character for character, including a path it
  # printed as empty. The report looked like the fix had not worked.
  _self="$(command -v xl1-menu 2>/dev/null)"
  if [ "$DRY_RUN" = 1 ] || [ "$MENU_LOOP" != 1 ] || [ -z "$_self" ]; then
    note "The next xl1-menu you start is the new one; this process keeps the"
    note "old one open until it exits."
    return 0
  fi
  # NEVER INTO SOMETHING THAT DOES NOT PARSE. The old menu in memory still
  # works, and replacing it with a half-downloaded file would leave nothing.
  if ! bash -n "$_self" 2>/dev/null; then
    err "the newly installed $_self does not parse, so it is not being run."
    err "You are still in the old menu, which works. Fetch it again."
    return 1
  fi
  ok "restarting into the new menu"
  exec "$_self"
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
5|Update the node CLI (build, promote, restart)|a_build_image
6|Promote an image and restart onto it|a_promote
7|Update the XYO SDK (no deploy)|a_service
8|Update the heartbeat agent|a_agent
9|Logs|a_logs
i|Update the node image recipe (xl1-docker-images)|a_recipe
r|Redeploy the anchor service (rebuild + restart)|a_redeploy
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
  MENU_LOOP=1
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
