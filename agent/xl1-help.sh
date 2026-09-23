#!/usr/bin/env bash
#
# Everything needed to run the producer and the anchor service, on the machine
# that runs them.
#
#   xl1-help                 the lot
#   xl1-help producer        one section
#   xl1-help --list          the section names
#
# Install it, from the repo checkout on the Pi:
#
#   sudo install -m 755 pi-agent/xl1-help.sh /usr/local/bin/xl1-help
#
# or from a laptop with the checkout, to a Pi without one:
#
#   scp pi-agent/xl1-help.sh USER@HOST:/tmp/ && \
#     ssh -t USER@HOST 'sudo install -m 755 /tmp/xl1-help.sh /usr/local/bin/xl1-help'
#
# NOT ON THE PUBLIC REPO, deliberately -- see check-public-drift.sh. It names
# this deployment's paths, which is what makes its commands ready to run and
# also what makes them nobody else's.
#
# WHY THIS EXISTS AS A COMMAND AND NOT A PAGE. The README is on a laptop and
# the trouble is on the Pi, usually over SSH, usually at the wrong hour. A
# reference you have to go and find is one you reconstruct from memory
# instead, and reconstructing it is how the wrong path gets typed.
#
# IT READS THIS MACHINE, IT DOES NOT PRINT THE DEFAULTS. Every command below
# that names a file or a unit gets that name from the machine it is running
# on. The defaults are not reliable and this is not a hypothetical: on
# 2026-09-21 a config was dumped from /etc/xl1-producer.env -- the script
# default, and a real file -- while the producer was being started from
# /opt/xl1-docker-images/sequence-producer.env, which is what the systemd unit
# actually loads. The two disagreed and the diagnosis went the wrong way for
# an hour. Where a value cannot be read, it says so rather than guessing.
#
# IT CHANGES NOTHING. No writes, no restarts, no network calls that cost
# anything. Safe to run on a producing node at any time, which is the only way
# a help command is worth having. To actually DO any of it, xl1-menu offers
# the same list as choices -- separate on purpose, so this one stays the
# command you can run without reading it first.
#
set -u

# --- how this machine is actually put together -------------------------------
#
# Discovery, not assumption. Each of these answers "what is it here", and each
# falls back to a plain statement of ignorance rather than to a default that
# would read as fact.

PRODUCER_CONTAINER="$(docker ps -a --filter name=xl1-producer --format '{{.Names}}' 2>/dev/null | head -1)"
ANCHOR_CONTAINER="$(docker ps -a --filter name=xl1-service-anchor --format '{{.Names}}' 2>/dev/null | head -1)"

# The unit that owns the producer, if one does. A wizard-built node runs the
# container directly and has none; a unit-owned one must be asked, because
# `docker restart` on it races whatever systemd decides to do next.
producer_unit() {
  for u in xl1-producer xl1-node xl1; do
    if systemctl cat "$u.service" >/dev/null 2>&1; then printf '%s.service' "$u"; return; fi
  done
}
PRODUCER_UNIT="$(producer_unit)"

# THE ENV FILE THE UNIT ACTUALLY LOADS, read off its own ExecStart. See the
# note at the top: this is the value that was wrong, and it is wrong in the
# direction that wastes the most time -- the default exists, opens, and parses.
unit_env() {
  [ -n "$PRODUCER_UNIT" ] || return
  systemctl show "$PRODUCER_UNIT" -p ExecStart --value 2>/dev/null \
    | sed -n 's/.*--env-file[= ]\([^ ;"]*\).*/\1/p' | head -1
}
unit_presets() {
  [ -n "$PRODUCER_UNIT" ] || return
  systemctl show "$PRODUCER_UNIT" -p ExecStart --value 2>/dev/null \
    | sed -n 's/.*-v[= ]\([^ ;"]*\):\/presets.*/\1/p' | head -1
}
# NO FALLBACK, AND THAT IS THE POINT. Where no unit owns the producer, the
# env file it was started with is not recoverable: docker records the VALUES
# it copied in, never the --env-file it read them from. A guess here would be
# the same guess that cost the hour, so an empty answer stays an empty answer.
PRODUCER_ENV="$(unit_env)"
PRESETS_DIR="$(unit_presets)"

if [ -n "$PRESETS_DIR" ]; then
  PRESET_ARGS="-e XL1_PRESETS_DIR=/presets -v $PRESETS_DIR:/presets"
else
  PRESET_ARGS=""
fi

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

AGENT_DIR="${AGENT_DIR:-/opt/xl1-heartbeat}"
IMAGES_REPO=/opt/xl1-docker-images
SERVICE_DIR="$REPO_SERVICE"
# A SECOND COMPOSE FILE IS THIS SITE'S BUSINESS, not the product's. One grid
# publishes the anchor on a tailnet address as well as loopback and keeps the
# override for it beside the checkout; most will have neither. Found if it is
# there, named as absent if it is not -- never invented.
TAILNET_OVERRIDE=""
for _t in ${XL1_COMPOSE_OVERRIDE:-} "$HOME/xl1-deploy/docker-compose.tailnet.yml" \
          "${REPO_SERVICE:-/nonexistent}/docker-compose.override.yml"; do
  [ -n "$_t" ] && [ -f "$_t" ] && { TAILNET_OVERRIDE="$_t"; break; }
done
PUBLIC_RAW="${XL1_AGENT_RAW:-https://raw.githubusercontent.com/jebscc/xl1-node-monitor/main/agent}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; Y=$'\033[33m'; X=$'\033[0m'
else B=""; D=""; Y=""; X=""; fi

h()  { printf '\n%s== %s%s\n' "$B" "$1" "$X"; }
c()  { printf '  %s\n' "$1"; }
n()  { printf '    %s%s%s\n' "$D" "$1" "$X"; }
w()  { printf '  %s%s%s\n' "$Y" "$1" "$X"; }
# A value this machine could not tell us. Named rather than defaulted, because
# a plausible wrong path is worse than an obvious gap.
q()  { if [ -n "${2:-}" ]; then printf '%s' "$2"; else printf '<%s not found on this machine>' "$1"; fi; }

# --- sections ----------------------------------------------------------------

s_where() {
  h "Where things are, on THIS machine"
  c "producer container   $(q 'container' "$PRODUCER_CONTAINER")"
  c "producer unit        $(q 'unit' "$PRODUCER_UNIT")"
  c "producer env file    $(q 'env-file' "$PRODUCER_ENV")"
  c "preset mount         $(q 'preset mount' "$PRESETS_DIR")"
  c "anchor container     $(q 'container' "$ANCHOR_CONTAINER")"
  c "agent                $AGENT_DIR/xl1_heartbeat.py   (unit: xl1-heartbeat)"
  c "agent env            $AGENT_ENV"
  c "image recipe         $IMAGES_REPO"
  c "service checkout     $(q 'checkout' "$SERVICE_DIR")"
  c "repository           $(q 'checkout' "$REPO")"
  c "backend              ${BACKEND:-<$(env_why)>}"
  c "this node            ${NODE_ID:-<$(env_why)>}"
  c "compose override     $(q 'override' "$TAILNET_OVERRIDE")"
  n "These are read from the machine, not from defaults. A blank one means"
  n "this node does not have it -- not that the default applies."
}

s_status() {
  h "Is it well?"
  c "sudo systemctl status ${PRODUCER_UNIT:-xl1-producer} --no-pager"
  c "docker ps --format 'table {{.Names}}\t{{.Status}}'"
  c "journalctl -u xl1-heartbeat -n 40 --no-pager"
  n "The node's OWN startup summary is the one reading that never lies about"
  n "which address it signs as. NRestarts and ExecMainStatus are cumulative"
  n "counters -- they describe a past the node may have long recovered from."
  c "docker logs --tail 80 ${PRODUCER_CONTAINER:-xl1-producer}"
  h "Is it producing?"
  c "curl -s $(q 'backend' "$BACKEND")/api/node/status | python3 -m json.tool | head -40"
  n "produced_share is counted against the SIGNING address, not the reward"
  n "wallet. They differ on this fleet, which is why the share once read 0.0"
  n "on a node taking 9.85% of the field."
}

s_producer() {
  h "The producer"
  if [ -n "$PRODUCER_UNIT" ]; then
    c "sudo systemctl restart $PRODUCER_UNIT"
    w "systemd owns this container. Never docker restart/rm it directly --"
    w "the unit will race you and win, and its ExecStart is what decides the"
    w "env file, the preset mount and the heap cap."
  else
    c "sudo docker restart ${PRODUCER_CONTAINER:-xl1-producer}"
    n "No systemd unit owns this container, so docker is the right tool."
  fi
  h "Check the config BEFORE restarting"
  c "sudo docker run --rm --env-file ${PRODUCER_ENV:-<env-file>} \\"
  c "  ${PRESET_ARGS:-} xl1:local --dump-config; echo \"exit=\$?\""
  n "Exit 0 and a config it accepts. Exit 78 is EX_CONFIG -- the same code"
  n "the crash loop throws, found before the restart instead of after it."
  n "PASS THE FLAG AND NOTHING ELSE: the image entrypoint already appends"
  n "'start <actors>', so a stray word becomes an actor name."
  h "Which address does it sign as"
  c "docker logs ${PRODUCER_CONTAINER:-xl1-producer} 2>&1 | grep -A6 -i 'producer' | head -20"
  n "The wallet summary at startup names it. The reward address is a"
  n "different thing and is set by XL1_REWARD_ADDRESS."
}

s_cli() {
  h "The node CLI and its image"
  c "docker exec ${PRODUCER_CONTAINER:-xl1-producer} cat \\"
  c "  /usr/local/lib/node_modules/@xyo-network/xl1-cli/package.json | grep '\"version\"'"
  n "Read from INSIDE the running container. A tag can be moved without"
  n "recreating anything, so the tag is not evidence of what is running."
  h "Build a new image (builds only, never promotes)"
  c "sudo systemctl start xl1-image-rebuild.service"
  c "journalctl -u xl1-image-rebuild -n 30 --no-pager"
  n "Runs weekly on its own timer. It never retags xl1:local, never stops a"
  n "container and never restarts the producer: swapping the image under a"
  n "live producer is a decision for a person at a time of their choosing."
  h "Promote a built image, when you want it"
  c "docker images 'xl1:*'"
  c "docker tag xl1:<version> xl1:local"
  if [ -n "$PRODUCER_UNIT" ]; then
    c "sudo systemctl restart $PRODUCER_UNIT"
  else
    c "sudo docker rm -f ${PRODUCER_CONTAINER:-xl1-producer}"
    c "sudo docker run -d --name xl1-producer --restart unless-stopped \\"
    c "  --env-file ${PRODUCER_ENV:-<env-file>} ${PRESET_ARGS:-} xl1:local"
  fi
  n "Roll back by tagging the previous version and repeating. Old versions"
  n "stay as xl1:<version> until pruned, so a rollback needs no rebuild."
  w "A version bump is not evidence of a change. 5.3.3 was byte-identical to"
  w "5.3.2 apart from its version string and git hash. What DOES change on a"
  w "rebuild is the dependency tree: every runtime dep is a ~ range and the"
  w "image is built with npm install -g."
}

s_service() {
  h "The anchor service (xl1-service) and its SDK"
  c "curl -s localhost:8090/health | python3 -m json.tool"
  c "docker port ${ANCHOR_CONTAINER:-xl1-service-anchor-1}"
  w "TWO lines, or the Render proxy is down. One publish is loopback for the"
  w "agent, the other is the tailnet address the backend reads."
  h "Redeploy it after an SDK bump"
  c "cd $SERVICE_DIR"
  c "sudo docker compose -f docker-compose.pi.yml \\"
  c "  -f $TAILNET_OVERRIDE up -d --build"
  c "docker port ${ANCHOR_CONTAINER:-xl1-service-anchor-1}   # two lines, or the proxy is down"
  w "ALWAYS THE TWO-FILE FORM. The bare -f docker-compose.pi.yml drops the"
  w "tailnet publish AND the container's DNS: every chain read then fails"
  w "EAI_AGAIN while the producer beside it stays perfectly fine."
  n "sudo because compose reads /etc/xl1-anchor.env, which is root-only."
  n "The SDK bump itself arrives as a Dependabot PR on the repo. Merging it"
  n "is not deploying it: this command is the deploy, and it is manual on"
  n "purpose because it pulls new dependency code onto the machine holding"
  n "the attestation key."
  h "Keep it serving"
  c "sudo systemctl start xl1-anchor-watch.service"
  c "journalctl -u xl1-anchor-watch -n 15 --no-pager"
  n "A quiet journal is the pass -- it logs only faults, recoveries and its"
  n "own actions. Docker will NOT restart a container for being unhealthy;"
  n "that gap is what this closes."
}

s_agent() {
  h "The heartbeat agent"
  c "sudo systemctl restart xl1-heartbeat"
  c "journalctl -u xl1-heartbeat -n 40 --no-pager"
  h "Run one beat by hand, without the service"
  c "sudo -u xl1agent env \$(sudo grep -vE '^\\s*(#|\$)' $AGENT_ENV | xargs) \\"
  c "  python3 $AGENT_DIR/xl1_heartbeat.py --once"
  h "Update it"
  c "# from the laptop:"
  c "scp pi-agent/xl1_heartbeat.py $(whoami)@$(hostname -I 2>/dev/null | awk '{print $1}'):/tmp/"
  c "sudo mv /tmp/xl1_heartbeat.py $AGENT_DIR/ && sudo systemctl restart xl1-heartbeat"
  n "Restart it, or the file on disk is not the code that is running."
}

s_wizard() {
  h "The wizard"
  c "curl -fsSL $PUBLIC_RAW/bootstrap-pi.sh | bash"
  n "Eleven steps, asks before each one, and shows what it will do first."
  c "curl -fsSL $PUBLIC_RAW/bootstrap-pi.sh | bash -s -- --check"
  n "The report and the plan, changing nothing."
  n "Every question is also a flag, and anything given is not asked about:"
  n "  --node-id my-pi-02 --location 'Indiana, US' --lat 39.5 --lon -87.4 --yes"
  w "It is safe to re-run on a live node, but it restarts the producer. On a"
  w "unit-owned node it writes the UNIT's env file, not its own default."
}

s_alerts() {
  h "Alerts"
  c "$(q 'backend' "$BACKEND")  -- the operator portal, Alerting, then #recent"
  n "The history says what became of the last hundred alerts and why any of"
  n "them was not sent -- four of the outcomes are suppressions on purpose."
  n "Records expire after ninety days."
  c "curl -s $(q 'backend' "$BACKEND")/api/node/alerts/mine \\"
  c "  -H \"Authorization: Bearer \$TOKEN\" | python3 -m json.tool"
  n "An alert goes to the account that OWNS the device and to nobody else."
}

s_trouble() {
  h "When it will not start"
  c "sudo systemctl status ${PRODUCER_UNIT:-xl1-producer} --no-pager -l"
  c "docker logs --tail 60 ${PRODUCER_CONTAINER:-xl1-producer}"
  n "exit 78 is EX_CONFIG: the node refused the configuration. Dump it with"
  n "the command under 'producer' and read what it objects to."
  n "Two keys are records the node REJECTS and must stay commented out in"
  n "the env file: XL1_ACCOUNT_INDEX and XL1_BLOCK_CHECK_INTERVAL_MS."
  h "When it is up but not anchoring"
  c "curl -s localhost:8090/health | python3 -m json.tool"
  c "docker port ${ANCHOR_CONTAINER:-xl1-service-anchor-1}"
  w "A healthy container nothing can talk to is indistinguishable from a"
  w "working one. Check that something can still AUTHENTICATE against it,"
  w "not merely that it came up -- that cost 21.8 silent hours once."
  c "journalctl -u xl1-heartbeat --since \"\$(systemctl show xl1-heartbeat -p ExecMainStartTimestamp --value)\" | grep -i attest"
  n "Search from the agent's start, not a recent window: it warns ONCE."
  h "When the disk is filling"
  c "df -h / && docker system df"
  c "docker image prune -a --filter 'until=720h'"
  w "Never prune an image a container still holds, xl1:local included."
}

# --- driver ------------------------------------------------------------------

SECTIONS="where status producer cli service agent wizard alerts trouble"

usage() {
  printf '%susage%s  xl1-help [section]\n\n' "$B" "$X"
  printf '  where     what this machine actually has, and where\n'
  printf '  status    is it well, is it producing\n'
  printf '  producer  restart, dump-config, which address it signs as\n'
  printf '  cli       the node CLI version, rebuilding and promoting an image\n'
  printf '  service   the anchor service, its SDK, and keeping it serving\n'
  printf '  agent     the heartbeat agent\n'
  printf '  wizard    bootstrap-pi.sh\n'
  printf '  alerts    where alerts go and why one was not sent\n'
  printf '  trouble   will not start, not anchoring, disk filling\n\n'
  printf '  No section prints all of them. Nothing here changes anything.\n'
}

case "${1:-}" in
  ""|all) for s in $SECTIONS; do "s_$s"; done; printf '\n' ;;
  -h|--help|help) usage ;;
  --list) printf '%s\n' $SECTIONS ;;
  *)
    # Matched against the list, not by pattern. The argument is about to
    # become a function name, and `grep "$1"` would let it choose which.
    _found=""
    for _s in $SECTIONS; do [ "$_s" = "$1" ] && _found=1; done
    if [ -n "$_found" ]; then
      "s_$1"; printf '\n'
    else
      printf 'No section "%s".\n\n' "$1" >&2; usage >&2; exit 2
    fi ;;
esac
