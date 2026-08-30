#!/usr/bin/env bash
#
# Check whether this machine can join the Explorer Grid, and then join it.
#
# CHECKING IS THE DEFAULT. Run it with no arguments and it changes nothing at
# all: no files written, no packages installed, no service created. It looks at
# the machine, tells you what it found, and exits 0 if the machine is eligible.
# Installing takes --install and happens only after every required check has
# passed, because a half-installed agent on somebody's home server is a worse
# outcome than a clear "not yet".
#
#   ./onboard.sh                          # check only
#   ./onboard.sh --node-id my-pi-01       # check, against a specific id
#   ./onboard.sh --node-id my-pi-01 --install
#
# Register the device first at the grid page to get its token; the script tells
# you where. It reads the token from NODE_HEARTBEAT_TOKEN, or prompts without
# echoing. The token is never printed, never passed as an argument (arguments
# are visible in `ps` to every user on the machine), and the file it lands in
# is created 0600.
#
# Linux and Windows both. On Linux it can install a systemd service and start
# it. On Windows there is no systemd, so it checks everything it can and then
# tells you exactly how to run it under Task Scheduler rather than pretending
# it installed something.
#
# Exit codes:  0 eligible (or installed)   1 not eligible   2 bad usage

set -uo pipefail    # deliberately NOT -e: every check runs, then we report.

BACKEND_URL="${BACKEND_URL:-https://xyo-backend.onrender.com}"
GRID_URL="${GRID_URL:-https://jimtheexplorer.com/grid}"
NODE_ID="${NODE_ID:-}"
NODE_LABEL="${NODE_LABEL:-}"
NODE_ROLE="${NODE_ROLE:-producer}"
NODE_NETWORK="${NODE_NETWORK:-sequence}"
DO_INSTALL=0
SKIP_DOCKER=0
MIN_PY_MINOR=8          # the agent is stdlib-only; 3.8 is the floor it parses on
MIN_DISK_MB=200

PASS=0; FAIL=0; WARN=0
FAILED_CHECKS=""

# --- output ------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; D=""; X=""
fi

ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$X" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_CHECKS="${FAILED_CHECKS}  - $1\n";
         printf '  %sFAIL%s  %s\n' "$R" "$X" "$1"
         [ $# -gt 1 ] && printf '        %s%s%s\n' "$D" "$2" "$X"; return 0; }
warn() { WARN=$((WARN+1)); printf '  %sWARN%s  %s\n' "$Y" "$X" "$1"
         [ $# -gt 1 ] && printf '        %s%s%s\n' "$D" "$2" "$X"; return 0; }
head_() { printf '\n%s%s%s\n' "$B" "$1" "$X"; }
die()  { printf '%serror:%s %s\n' "$R" "$X" "$1" >&2; exit 2; }

# --- arguments ---------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --install)      DO_INSTALL=1 ;;
    --node-id)      NODE_ID="${2:-}"; shift ;;
    --label)        NODE_LABEL="${2:-}"; shift ;;
    --role)         NODE_ROLE="${2:-}"; shift ;;
    --network)      NODE_NETWORK="${2:-}"; shift ;;
    --backend)      BACKEND_URL="${2:-}"; shift ;;
    --grid)         GRID_URL="${2:-}"; shift ;;
    --skip-docker)  SKIP_DOCKER=1 ;;
    -h|--help)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

BACKEND_URL="${BACKEND_URL%/}"

# --- platform ----------------------------------------------------------------
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME_S" in
  Linux*)                    OS=linux ;;
  Darwin*)                   OS=macos ;;
  MINGW*|MSYS*|CYGWIN*)      OS=windows ;;
  *)                         OS=unknown ;;
esac
# WSL is a Linux kernel, but the service story is a Linux one inside a VM the
# user may not have set to start on boot -- worth naming rather than hiding.
IS_WSL=0
if [ "$OS" = linux ] && grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=1; fi

have() { command -v "$1" >/dev/null 2>&1; }

# curl or wget, since a minimal box may have only one.
fetch() { # fetch <url> -> body on stdout
  if have curl; then curl -fsSL --max-time 25 "$1" 2>/dev/null
  elif have wget; then wget -qO- --timeout=25 "$1" 2>/dev/null
  else return 127; fi
}
http_code() {
  if have curl; then curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$1" 2>/dev/null
  else echo "000"; fi
}

printf '%sExplorer Grid -- device onboarding%s\n' "$B" "$X"
printf '%s%s%s\n' "$D" "checking this machine; nothing is changed unless --install is given" "$X"

# =============================================================================
head_ "The machine"
# =============================================================================
ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "$OS" in
  linux)   ok "Linux ($ARCH)$( [ "$IS_WSL" = 1 ] && printf ' -- under WSL')" ;;
  macos)   ok "macOS ($ARCH)" ;;
  windows) ok "Windows ($ARCH, via $UNAME_S)" ;;
  *)       bad "unrecognised platform: $UNAME_S" \
               "the agent is plain Python and may still run; the service install will not" ;;
esac

if [ "$IS_WSL" = 1 ]; then
  warn "WSL does not start on boot by default" \
       "a device that only reports while you have a terminal open will look offline; see the notes at the end"
fi

# =============================================================================
head_ "Python"
# =============================================================================
PY=""
for c in python3 python py; do
  if have "$c"; then
    v="$("$c" -c 'import sys;print("%d %d"%sys.version_info[:2])' 2>/dev/null)"
    set -- $v
    if [ "${1:-0}" = 3 ] && [ "${2:-0}" -ge "$MIN_PY_MINOR" ]; then PY="$c"; break; fi
  fi
done
if [ -n "$PY" ]; then
  ok "$("$PY" -V 2>&1) at $(command -v "$PY")"
  # The agent imports nothing outside the standard library, on purpose: no pip,
  # no virtualenv, nothing to drift. Proving that here means a green check is
  # actually a green check.
  if "$PY" - <<'EOF' >/dev/null 2>&1
import json, os, re, socket, subprocess, threading, sys, urllib.request, urllib.error, hashlib, hmac
EOF
  then ok "every module the agent imports is present (standard library only, no pip)"
  else bad "this Python cannot import the standard modules the agent needs" \
           "unusual -- a stripped-down or partial install?"
  fi
else
  bad "no Python 3.$MIN_PY_MINOR or newer found" \
      "Linux: apt install python3   Windows: https://python.org/downloads (tick 'Add to PATH')"
fi

# =============================================================================
head_ "Docker and the XL1 node"
# =============================================================================
if [ "$SKIP_DOCKER" = 1 ]; then
  warn "Docker checks skipped by request" \
       "the agent reads container state; without it a device reports host stats and little else"
elif ! have docker; then
  bad "docker not found" "https://docs.docker.com/get-docker/"
else
  ok "docker present ($(command -v docker))"
  if docker info >/dev/null 2>&1; then
    ok "the Docker daemon is reachable from this account"
  else
    bad "Docker is installed but this account cannot talk to the daemon" \
        "Linux: sudo usermod -aG docker \"\$USER\" then log out and back in. Windows: start Docker Desktop."
  fi
  RUNNING="$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep -i 'xl1' | head -3)"
  if [ -n "$RUNNING" ]; then
    ok "an XL1 container is running:"
    printf '%s\n' "$RUNNING" | while IFS="$(printf '\t')" read -r n i; do
      printf '        %s%s  (%s)%s\n' "$D" "$n" "$i" "$X"; done
  else
    warn "no running container with 'xl1' in its name" \
         "the agent will report the host but nothing about a node; start your node first"
  fi
fi

# =============================================================================
head_ "Reaching the grid"
# =============================================================================
case "$BACKEND_URL" in
  https://*) ok "backend is https ($BACKEND_URL)" ;;
  http://*)  warn "backend is plain http" \
                  "the ingest token travels with every request; use https for anything off the local network" ;;
  *)         bad "backend url looks wrong: $BACKEND_URL" "expected it to start with https://" ;;
esac

if ! have curl && ! have wget; then
  bad "neither curl nor wget is available" "one of them is needed to check the backend, and to register"
else
  code="$(http_code "$BACKEND_URL/api/node/status")"
  case "$code" in
    200) ok "the backend answered (HTTP 200)" ;;
    000) bad "could not reach $BACKEND_URL" \
             "DNS, a firewall, or the host being asleep. A free-tier backend can take 60s to wake -- try once more." ;;
    *)   bad "the backend answered HTTP $code, expected 200" ;;
  esac

  # Clock skew. Anchors carry an observed_at, and a device whose clock is out
  # by minutes writes a timestamp that disagrees with the chain it is
  # describing -- visible forever, and not fixable after the fact.
  if have curl; then
    rd="$(curl -sI --max-time 25 "$BACKEND_URL/api/node/status" 2>/dev/null \
          | tr -d '\r' | awk 'tolower($1)=="date:"{ $1=""; sub(/^ /,""); print }')"
    if [ -n "$rd" ] && have date; then
      them="$(date -u -d "$rd" +%s 2>/dev/null || echo "")"
      if [ -n "$them" ]; then
        us="$(date -u +%s)"; skew=$(( us > them ? us - them : them - us ))
        if   [ "$skew" -le 5 ];  then ok "clock agrees with the server (${skew}s apart)"
        elif [ "$skew" -le 60 ]; then warn "clock is ${skew}s off the server" \
             "anchors record when a reading was taken; keep NTP on"
        else bad "clock is ${skew}s off the server" \
             "timestamps on anchored readings would be wrong on a public chain, permanently. Fix time sync first."
        fi
      fi
    fi
  fi
fi

# =============================================================================
head_ "The device id"
# =============================================================================
if [ -z "$NODE_ID" ]; then
  warn "no --node-id given, so it was not checked against the grid" \
       "re-run with --node-id <name> to find out whether the name is free"
else
  case "$NODE_ID" in
    *[!A-Za-z0-9._-]*) bad "node id '$NODE_ID' has characters the backend rejects" \
                           "letters, numbers, dots, dashes and underscores only" ;;
    *) if [ "${#NODE_ID}" -gt 64 ]; then
         bad "node id is ${#NODE_ID} characters; the limit is 64"
       else
         ok "node id '$NODE_ID' is a shape the backend accepts"
         if have curl || have wget; then
           if fetch "$BACKEND_URL/api/node/status" 2>/dev/null \
              | grep -q "\"node_id\"[[:space:]]*:[[:space:]]*\"$NODE_ID\""; then
             bad "'$NODE_ID' is already reporting on the grid" \
                 "pick another name, or you will be trying to report as somebody else's device"
           else
             ok "'$NODE_ID' is not currently on the public grid"
           fi
         fi
       fi ;;
  esac
fi

# The token is required to install, but not to be eligible -- you get it by
# registering, and registering is a thing you do after the machine checks out.
if [ -n "${NODE_HEARTBEAT_TOKEN:-}" ]; then
  ok "a credential is present in the environment"
else
  warn "no credential yet (NODE_HEARTBEAT_TOKEN is unset)" \
       "register the device at $GRID_URL -- the token is shown once"
fi

# =============================================================================
head_ "Room to install"
# =============================================================================
if [ "$OS" = linux ] || [ "$OS" = macos ]; then
  if have df; then
    avail="$(df -Pm /opt 2>/dev/null || df -Pm / 2>/dev/null)"
    mb="$(printf '%s\n' "$avail" | awk 'NR==2{print $4}')"
    if [ -n "$mb" ] && [ "$mb" -ge "$MIN_DISK_MB" ] 2>/dev/null; then
      ok "disk space available (${mb} MB)"
    else
      bad "less than ${MIN_DISK_MB} MB free where the agent installs"
    fi
  fi
  if [ "$(id -u)" = 0 ]; then
    ok "running as root; the service can be installed"
  elif sudo -n true 2>/dev/null; then
    ok "passwordless sudo is available"
  elif have sudo; then
    warn "sudo will prompt for a password during --install" "expected, just be at the keyboard"
  else
    bad "no sudo and not root" "installing a system service needs one or the other"
  fi
  if have systemctl && [ -d /run/systemd/system ]; then
    ok "systemd is running; the agent can be installed as a service"
  else
    warn "systemd not detected" \
         "everything else may still work; you will need to start the agent yourself"
  fi
else
  warn "service installation is Linux-only" \
       "the checks above still apply; see the Windows notes at the end for running it as a scheduled task"
fi

# =============================================================================
head_ "Verdict"
# =============================================================================
printf '  %s%d passed%s, %s%d warnings%s, %s%d failed%s\n' \
  "$G" "$PASS" "$X" "$Y" "$WARN" "$X" "$R" "$FAIL" "$X"

if [ "$FAIL" -gt 0 ]; then
  printf '\n%sThis machine is not ready yet.%s Fix these and run it again:\n' "$R" "$X"
  printf "$FAILED_CHECKS"
  exit 1
fi

printf '\n%sThis machine is eligible.%s\n' "$G" "$X"

if [ "$DO_INSTALL" != 1 ]; then
  printf '\nNothing was changed. To install:\n'
  printf '  1. Register the device at %s\n' "$GRID_URL"
  printf '  2. NODE_HEARTBEAT_TOKEN=<the token> ./onboard.sh --node-id %s --install\n' \
         "${NODE_ID:-<name>}"
  if [ "$OS" = windows ]; then
    printf '\n%sOn Windows%s there is no systemd, so step 2 will not install a service.\n' "$B" "$X"
    printf 'Run the agent directly, and use Task Scheduler to start it at logon:\n'
    printf '  %s%s xl1_heartbeat.py%s   (with the variables set in the environment)\n' \
           "$D" "${PY:-python}" "$X"
  fi
  exit 0
fi

# =============================================================================
head_ "Installing"
# =============================================================================
if [ "$OS" != linux ]; then
  printf '  %sInstalling a service is only implemented for Linux.%s\n' "$Y" "$X"
  printf '  Every check above passed, so the agent itself will run here. Start it with:\n'
  printf '    %s xl1_heartbeat.py\n' "${PY:-python}"
  printf '  and have Task Scheduler (Windows) or launchd (macOS) run that at boot.\n'
  exit 0
fi

[ -z "$NODE_ID" ] && die "--install needs --node-id"
TOKEN="${NODE_HEARTBEAT_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  # Prompted rather than taken as an argument: arguments are visible in ps to
  # every user on the box, and land in shell history.
  printf 'Paste the token for %s (input hidden): ' "$NODE_ID"
  stty -echo 2>/dev/null; read -r TOKEN; stty echo 2>/dev/null; printf '\n'
fi
[ -z "$TOKEN" ] && die "no token given; register at $GRID_URL"

SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"
SRC_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
[ -f "$SRC_DIR/xl1_heartbeat.py" ] || die "xl1_heartbeat.py is not next to this script"

printf '  creating the service account\n'
id xl1agent >/dev/null 2>&1 || $SUDO useradd --system --no-create-home --shell /usr/sbin/nologin xl1agent
getent group docker >/dev/null 2>&1 && $SUDO usermod -aG docker xl1agent

printf '  installing the agent into /opt/xl1-heartbeat\n'
$SUDO mkdir -p /opt/xl1-heartbeat
$SUDO cp "$SRC_DIR/xl1_heartbeat.py" /opt/xl1-heartbeat/

printf '  writing /etc/xl1-heartbeat.env (0600, root-owned)\n'
# Written via a umask'd temp file rather than tee, so the token is never
# briefly readable by everyone, and never appears in ps.
umask 077
tmp="$(mktemp)"
{
  printf 'BACKEND_URL=%s\n' "$BACKEND_URL"
  printf 'NODE_ID=%s\n' "$NODE_ID"
  printf 'NODE_LABEL="%s"\n' "${NODE_LABEL:-$NODE_ID}"
  printf 'NODE_ROLE=%s\n' "$NODE_ROLE"
  printf 'NODE_NETWORK=%s\n' "$NODE_NETWORK"
  printf 'NODE_HEARTBEAT_TOKEN=%s\n' "$TOKEN"
  # Opt-in location, written only where it was actually given. An empty
  # XL1_STATED_LAT= is NOT the same as an absent one -- it overrides the
  # default with an empty string, which is the first rule in the env example.
  [ -n "${XL1_STATED_LOCATION:-}" ] && printf 'XL1_STATED_LOCATION="%s"\n' "$XL1_STATED_LOCATION"
  [ -n "${XL1_STATED_LAT:-}" ]      && printf 'XL1_STATED_LAT=%s\n' "$XL1_STATED_LAT"
  [ -n "${XL1_STATED_LON:-}" ]      && printf 'XL1_STATED_LON=%s\n' "$XL1_STATED_LON"
  [ -n "${XL1_STATED_LAT:-}" ] && [ -n "${XL1_STATED_RADIUS_KM:-}" ] \
    && printf 'XL1_STATED_RADIUS_KM=%s\n' "$XL1_STATED_RADIUS_KM"
  true
} > "$tmp"
$SUDO cp "$tmp" /etc/xl1-heartbeat.env
rm -f "$tmp"
$SUDO chmod 600 /etc/xl1-heartbeat.env
$SUDO chown root:root /etc/xl1-heartbeat.env

if [ -f "$SRC_DIR/xl1-heartbeat.service" ]; then
  printf '  installing the systemd unit\n'
  $SUDO cp "$SRC_DIR/xl1-heartbeat.service" /etc/systemd/system/
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now xl1-heartbeat
else
  die "xl1-heartbeat.service is not next to this script"
fi

printf '\n  waiting for the first heartbeat to land'
landed=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 6; printf '.'
  if fetch "$BACKEND_URL/api/node/status" 2>/dev/null \
     | grep -q "\"node_id\"[[:space:]]*:[[:space:]]*\"$NODE_ID\""; then landed=1; break; fi
done
printf '\n'

if [ "$landed" = 1 ]; then
  printf '\n%s%s is on the grid.%s\n' "$G" "$NODE_ID" "$X"
  printf '  %s%s%s\n' "$D" "$GRID_URL" "$X"
  printf '\nIt stays marked pending until it has reported for a day or anchored once.\n'
  printf 'That is the check that keeps the map honest, and it applies to every device.\n'
else
  printf '\n%sThe service is installed but nothing has arrived yet.%s\n' "$Y" "$X"
  printf 'Look at what it is saying:\n'
  printf '  sudo journalctl -u xl1-heartbeat -n 40 --no-pager\n'
  printf 'A refused heartbeat now prints the reason and what to do about it.\n'
  exit 1
fi
