#!/usr/bin/env bash
# Rebuild the anchor service from this checkout and put the container on it.
#
#   sudo bash redeploy-anchor.sh              do it
#   bash redeploy-anchor.sh --dry-run         print the plan, change nothing
#
# WHY THIS EXISTS. Moving the SDK pins changes package.json in the checkout;
# the container goes on running the image it was BUILT from, which is a
# different thing on disk and looks identical from the outside. A node with
# compose closes that gap with `up -d --build`. A wizard-built node has no
# compose -- deliberately, because docker.io from apt ships no plugin and this
# is one container -- and until now the only answer there was re-running the
# whole wizard, which also re-fetches main and would throw a local bump away.
#
# IT WRITES NO `docker run` FLAGS OF ITS OWN, and that is the whole design.
# bootstrap-pi.sh owns that list and says in as many words that keeping it in
# step with docker-compose.pi.yml is not optional: it drifted once and cost a
# clean install. A third copy here would be a third thing to keep in step. So
# the wizard's own function is read at run time and called -- one copy, and
# this follows it wherever it goes.
#
# WHAT IT REFUSES TO DO QUIETLY. A container that comes back healthy but
# publishing fewer ports than it had looks exactly like a working one, and the
# site's chain height goes quiet. The publishes are counted on both sides, the
# image it replaced is kept as xl1-service:previous, and a failure puts that
# back and starts it again rather than leaving the node on something broken.
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; X=$'\033[0m'
else B=""; D=""; G=""; R=""; Y=""; X=""; fi
say()  { printf '%s\n' "$1"; }
note() { printf '   %s%s%s\n' "$D" "$1" "$X"; }
ok()   { printf '   %s%s%s\n' "$G" "$1" "$X"; }
warn() { printf '   %s%s%s\n' "$Y" "$1" "$X"; }
err()  { printf '   %s%s%s\n' "$R" "$1" "$X"; }
die()  { err "$1"; exit 2; }

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"
command -v docker >/dev/null 2>&1 || die "docker is not installed"

# --- where the wizard is, because its function is the thing being borrowed ---
find_bootstrap() {
  for d in "${XL1_REPO:-/nonexistent}/pi-agent" "${XL1_REPO:-/nonexistent}/agent" \
           /opt/MyAdventureWebsite/pi-agent /opt/xl1-node-monitor/agent \
           "$HOME/xl1-node-monitor/agent" /opt/xl1-tools/agent; do
    [ -f "$d/bootstrap-pi.sh" ] && { printf '%s' "$d/bootstrap-pi.sh"; return; }
  done
}
BOOTSTRAP="${XL1_BOOTSTRAP:-$(find_bootstrap)}"
[ -n "$BOOTSTRAP" ] || die "no bootstrap-pi.sh on this machine, and its start_anchor_service is what this runs"

find_service() {
  for d in "${XL1_REPO:-/nonexistent}/xl1-service" "${XL1_REPO:-/nonexistent}/service" \
           /opt/MyAdventureWebsite/xl1-service /opt/xl1-node-monitor/service \
           "$HOME/xl1-node-monitor/service" /opt/xl1-tools/service; do
    [ -f "$d/Dockerfile" ] && { printf '%s' "$d"; return; }
  done
}
SVC="${XL1_SERVICE_DIR:-$(find_service)}"
[ -n "$SVC" ] || die "no checkout of the anchor service on this machine"

# THE FUNCTION AND THE DEFAULTS, TAKEN FROM THE WIZARD. Only these four
# assignments and two functions are evaluated -- named one by one rather than
# sourcing the file, which would run the whole installer.
eval "$(sed -n 's/^\(XL1_NET\|XL1_SEQUENCE_RPC_URL\|XL1_MAINNET_RPC_URL\|ANCHOR_ENV\)=\(.*\)$/\1=\2/p' "$BOOTSTRAP")"
eval "$(sed -n '/^start_anchor_service() {/,/^}/p' "$BOOTSTRAP")"
eval "$(sed -n '/^wait_for_service() {/,/^}/p' "$BOOTSTRAP")"
command -v start_anchor_service >/dev/null 2>&1 \
  || die "could not read start_anchor_service out of $BOOTSTRAP"

CONTAINER="${XL1_ANCHOR_CONTAINER:-xl1-service-anchor-1}"

# WHAT IT IS RUNNING NOW BEATS WHAT THE DEFAULTS SAY. A node pointed at a
# different chain or a different RPC would otherwise be silently moved back
# onto the defaults by its own redeploy.
inspect_env() { # inspect_env <VAR>
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null \
    | sed -n "s/^$1=//p" | head -1
}
_net="$(inspect_env XL1_NETWORK)";          [ -n "$_net" ] && XL1_NET="$_net"
_seq="$(inspect_env XL1_SEQUENCE_RPC_URL)"; [ -n "$_seq" ] && XL1_SEQUENCE_RPC_URL="$_seq"
_main="$(inspect_env XL1_MAINNET_RPC_URL)"; [ -n "$_main" ] && XL1_MAINNET_RPC_URL="$_main"

HAD="$(docker port "$CONTAINER" 2>/dev/null | grep -c ':')"

say "${B}Redeploy the anchor service${X}"
note "checkout   $SVC"
note "flags from $BOOTSTRAP (start_anchor_service)"
note "network    $XL1_NET"
note "env file   $ANCHOR_ENV"
note "publishes  ${HAD:-0} now"
# ROOT-ONLY, so a plain test as the operator says nothing either way.
if [ ! -f "$ANCHOR_ENV" ] && ! $SUDO test -f "$ANCHOR_ENV" 2>/dev/null; then
  warn "$ANCHOR_ENV is not there; the container would start with no key"
fi

if [ "$DRY" = 1 ]; then
  note ""
  note "would run:"
  note "  docker tag xl1-service:local xl1-service:previous"
  note "  docker build --tag xl1-service:local $SVC"
  note "  start_anchor_service $ANCHOR_ENV   (from the wizard)"
  note "  then wait for /health and compare the publishes"
  exit 0
fi

# --- a way back, before anything is replaced ---------------------------------
if docker image inspect xl1-service:local >/dev/null 2>&1; then
  $SUDO docker tag xl1-service:local xl1-service:previous \
    && note "kept the running image as xl1-service:previous"
  HAVE_PREV=1
else
  HAVE_PREV=0
  note "no xl1-service:local yet, so there is nothing to keep"
fi

say ""
note "building from the checkout -- this takes a few minutes on a Pi"
$SUDO docker build --tag xl1-service:local "$SVC" \
  || die "the image did not build. Nothing was replaced: the container is still running."
ok "built xl1-service:local"

restore_previous() {
  [ "$HAVE_PREV" = 1 ] || { err "and there is no previous image to go back to"; return 1; }
  warn "putting xl1-service:previous back"
  $SUDO docker tag xl1-service:previous xl1-service:local
  start_anchor_service "$ANCHOR_ENV"
  if wait_for_service; then ok "the old one is back and answering"
  else err "the old one did not come back either: sudo docker logs $CONTAINER"; fi
}

say ""
note "replacing the container"
start_anchor_service "$ANCHOR_ENV" || { err "the new container would not start."; restore_previous; exit 1; }

if ! wait_for_service; then
  err "it started but /health never answered."
  restore_previous
  exit 1
fi
ok "it is answering on 127.0.0.1:8090"

# A HEALTHY CONTAINER NOTHING CAN TALK TO LOOKS EXACTLY LIKE A WORKING ONE.
NOW="$(docker port "$CONTAINER" 2>/dev/null | grep -c ':')"
if [ "${NOW:-0}" -lt "${HAD:-0}" ]; then
  err "it came back publishing $NOW where it had $HAD -- a binding was lost."
  restore_previous
  exit 1
fi
ok "publishes ${NOW:-0}, which is not fewer than the ${HAD:-0} it had"

health="$(curl -fsS --max-time 10 http://127.0.0.1:8090/health 2>/dev/null || true)"
case "$health" in
  *'"signing":true'*|*'"signing": true'*) ok "it is holding its attestation key" ;;
  *) warn "it is up but reports no signing key -- anchoring will not start"
     warn "until that is fixed: sudo docker logs $CONTAINER" ;;
esac

say ""
ok "the anchor service is running the code in $SVC"
note "xl1-service:previous is the image it replaced, if you need it back."
