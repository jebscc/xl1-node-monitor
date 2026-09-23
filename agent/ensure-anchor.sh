#!/usr/bin/env bash
#
# Keep the anchor service actually serving, not merely existing.
#
# WHAT THIS IS FOR. On 2026-09-15 and 2026-09-16 the Pi 4 stopped anchoring at
# 03:34 and 06:34 in the morning and did not start again until somebody
# rebuilt the container by hand -- 14.9 hours the first day, 15.4 the second.
# Nothing was down. The container was up the whole time, and `docker ps` said
# so. Its outbound DNS had failed, every call to the XYO RPC timed out, and
# Docker's answer to a container that has gone bad is to write "unhealthy" in
# a column nobody is reading. THERE IS NO RESTART POLICY FOR UNHEALTHY. That
# is the gap this closes.
#
# It also covers a second failure, seen on the unclean reset of 2026-09-16:
# the container came back with its network config gone -- NetworkMode empty,
# Networks {}, no published ports -- running, listening inside, and reachable
# by nothing. `docker start` cannot repair that. Only a recreate can, which is
# why the remedy here is a recreate and not a restart.
#
# THREE CHECKS, BECAUSE THE SERVICE FAILED THREE DIFFERENT WAYS:
#
#   is it running        -- the obvious one, and the one that was never the
#                           problem on any of the three days
#   does it publish      -- the tailnet publish is how Render reads the chain
#                           height. One line instead of two means /chain on
#                           the site goes quiet while the container is healthy
#   does it answer       -- /health on loopback, which is what the heartbeat
#                           agent talks to and therefore the only check that
#                           tests the thing anybody uses
#
# WHAT IT WILL NOT DO. It will not recreate on one bad reading. When the XYO
# RPC is down for everybody, every node's /health fails at once, and a fleet
# that reacts by rebuilding itself in unison is worse than one that waits. It
# takes STREAK consecutive failures, and then no more than one recreate per
# COOLDOWN. A service that is broken for its own reasons gets rebuilt once an
# hour, not twelve times, and the alert is left to say so.
#
# It is deliberately not clever about WHY. Telling a wedged resolver from a
# dead upstream from a damaged container record needs a person; all three want
# the same first move, and this makes that move at four in the morning.
#
set -euo pipefail

CONF="${ANCHOR_WATCH_CONF:-/etc/xl1-anchor-watch.env}"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

CONTAINER="${ANCHOR_CONTAINER:-xl1-service-anchor-1}"
HEALTH_URL="${ANCHOR_HEALTH_URL:-http://127.0.0.1:8090/health}"
# How many published host bindings this machine should have. The Pi 4 has two
# -- loopback for the agent, tailnet for Render. A wizard-built node has one,
# and must say so rather than being rebuilt every five minutes for ever.
WANT_PORTS="${ANCHOR_WANT_PORTS:-1}"
# An address that must exist before any of this means anything. On the Pi 4
# the container binds the Tailscale address, and on the boot of 2026-09-16
# dockerd finished at 19:38:26 while tailscaled did not serve this machine's
# tailnet address until 19:43:14 -- five minutes in which a bind could only
# fail. The address itself stays out of the repo and lives in the env file.
# disables the wait.
REQUIRE_ADDR="${ANCHOR_REQUIRE_ADDR:-}"
ADDR_WAIT="${ANCHOR_ADDR_WAIT:-300}"
STREAK="${ANCHOR_FAIL_STREAK:-3}"
COOLDOWN="${ANCHOR_RECREATE_COOLDOWN:-3600}"
STATE="${ANCHOR_WATCH_STATE:-/var/lib/xl1-anchor-watch}"
# How long to let a freshly recreated container settle before asking whether
# it worked. Configurable so the tests do not have to wait out a real one.
CONFIRM_WAIT="${ANCHOR_CONFIRM_WAIT:-20}"
UP_CMD="${ANCHOR_UP_CMD:-}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

now()      { date +%s; }
read_num() { [ -r "$1" ] && tr -cd '0-9' < "$1" | head -c 18 || printf '0'; }

# --- is the address this container binds even here yet? ----------------------
wait_for_addr() {
  [ -n "$REQUIRE_ADDR" ] || return 0
  local waited=0
  while ! ip -o addr show 2>/dev/null | grep -qF " $REQUIRE_ADDR/"; do
    if [ "$waited" -ge "$ADDR_WAIT" ]; then
      log "WARN: $REQUIRE_ADDR never appeared after ${ADDR_WAIT}s; checking anyway"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  [ "$waited" -gt 0 ] && log "waited ${waited}s for $REQUIRE_ADDR"
  return 0
}

# --- the three checks --------------------------------------------------------
# Each prints its own verdict, because "the anchor is down" is not an
# actionable sentence and "it publishes one port, not two" is.
check_anchor() {
  local faults=0

  local state
  state="$(docker inspect "$CONTAINER" --format '{{.State.Status}}' 2>/dev/null || true)"
  if [ "$state" != "running" ]; then
    log "FAULT: container is [${state:-absent}], not running"
    return 1
  fi

  local ports
  ports="$(docker port "$CONTAINER" 2>/dev/null | grep -c ':' || true)"
  if [ "${ports:-0}" -lt "$WANT_PORTS" ]; then
    # The 2026-09-16 shape exactly: up, healthy to look at, publishing nothing.
    log "FAULT: publishes ${ports:-0} binding(s), expected $WANT_PORTS"
    faults=1
  fi

  local body
  body="$(curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null || true)"
  if [ -z "$body" ]; then
    log "FAULT: $HEALTH_URL did not answer"
    faults=1
  elif ! printf '%s' "$body" | grep -q '"ok" *: *true'; then
    log "FAULT: health says not ok"
    faults=1
  fi

  return "$faults"
}

# --- the remedy --------------------------------------------------------------
# WHETHER COMPOSE MADE THIS CONTAINER, which decides whether compose can
# replace it. A container created by `docker run --name` -- which is what
# bootstrap-pi.sh does, taking by hand the exact name compose would use --
# carries no compose project label, and compose will not adopt it. It fails
# instantly with "the container name is already in use", which is a different
# thing from a deploy that went wrong.
compose_owns() {
  [ -n "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' \
          "$CONTAINER" 2>/dev/null)" ]
}

recreate() {
  if [ -z "$UP_CMD" ]; then
    # Nothing is worse here than guessing. Reconstructing the Pi 4's docker
    # run flags by hand is how its second publish was nearly lost for good;
    # each machine states its own command or this does nothing but complain.
    log "WARN: no ANCHOR_UP_CMD configured in $CONF -- cannot recreate. Fix by hand."
    return 1
  fi
  log "recreating with: $UP_CMD"
  # THE OUTPUT IS THE DIAGNOSIS, and throwing it away is why this went unread
  # for eight hours on 2026-09-23: five hourly attempts, each failing in under
  # a second, each logged as four words that say nothing about the cause. A
  # remedy that reports only that it failed is barely better than one that
  # reports nothing.
  _out="$(bash -c "$UP_CMD" 2>&1)"; _rc=$?
  if [ "$_rc" = 0 ]; then
    log "recreate returned ok"
    return 0
  fi
  log "FAILED: recreate exited $_rc"
  printf '%s\n' "$_out" | tail -6 | while IFS= read -r _l; do log "  | $_l"; done

  # THE ONE FAILURE WITH A KNOWN REMEDY, and only where the remedy can work.
  #
  # A wizard run recreates the anchor with `docker run`, so the next compose
  # deploy hits a name it may not take. Removing it is safe here in a way it
  # is not in general: this runs only after the anchor has failed its check
  # STREAK times in a row, so what is being replaced is already not serving.
  #
  # BUT ONLY IF UP_CMD CAN CREATE A CONTAINER. The CM4 has no compose and its
  # command is `docker restart xl1-service-anchor-1` -- remove the container
  # in front of that and the retry fails with "No such container", turning a
  # service that was merely unhealthy into a node with no anchor at all. A
  # restart repairs a wedged container; it cannot conjure a missing one.
  case "$UP_CMD" in
    *compose*up*) _can_create=1 ;;
    *)            _can_create=0 ;;
  esac
  if [ "$_can_create" = 1 ] && docker inspect "$CONTAINER" >/dev/null 2>&1 \
     && ! compose_owns; then
    log "$CONTAINER was not created by compose, so compose cannot replace it"
    log "removing it and trying once more"
    if ! docker rm -f "$CONTAINER" >/dev/null 2>&1; then
      log "FAILED: could not remove $CONTAINER -- this needs a person"
      return 1
    fi
    _out="$(bash -c "$UP_CMD" 2>&1)"; _rc=$?
    if [ "$_rc" = 0 ]; then
      log "recreate returned ok after the handover"
      return 0
    fi
    log "FAILED: still $_rc after removing it"
    printf '%s\n' "$_out" | tail -6 | while IFS= read -r _l; do log "  | $_l"; done
  fi
  return 1
}

main() {
  command -v docker >/dev/null || { log "FAILED: docker not found"; exit 1; }
  mkdir -p "$STATE" 2>/dev/null || true

  wait_for_addr || true

  if check_anchor; then
    # Only say something when the streak breaks, or a healthy node writes a
    # line every five minutes for ever and the journal becomes unreadable --
    # which is how the one line that mattered got missed in the first place.
    local had; had="$(read_num "$STATE/streak")"
    if [ "${had:-0}" -gt 0 ]; then
      log "anchor is serving again after ${had} bad check(s)"
    fi
    printf '0' > "$STATE/streak" 2>/dev/null || true
    exit 0
  fi

  local streak; streak=$(( $(read_num "$STATE/streak") + 1 ))
  printf '%s' "$streak" > "$STATE/streak" 2>/dev/null || true
  log "anchor is not serving (consecutive bad checks: $streak of $STREAK)"

  [ "$streak" -ge "$STREAK" ] || exit 1

  local last since
  last="$(read_num "$STATE/last-recreate")"
  since=$(( $(now) - ${last:-0} ))
  if [ "${last:-0}" -gt 0 ] && [ "$since" -lt "$COOLDOWN" ]; then
    log "within the ${COOLDOWN}s cooldown (${since}s since the last recreate); leaving it alone"
    exit 1
  fi

  printf '%s' "$(now)" > "$STATE/last-recreate" 2>/dev/null || true
  recreate || exit 1

  # Say whether it worked, in the same run. A remedy that reports only that it
  # ran is the thing this whole file exists to stop.
  sleep "$CONFIRM_WAIT"
  if check_anchor; then
    log "anchor is serving after the recreate"
    printf '0' > "$STATE/streak" 2>/dev/null || true
    exit 0
  fi
  log "FAILED: still not serving after the recreate -- this needs a person"
  exit 1
}

main "$@"
