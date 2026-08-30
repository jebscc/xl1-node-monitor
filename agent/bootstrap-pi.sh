#!/usr/bin/env bash
#
# From a freshly flashed Raspberry Pi to a device on the Explorer Grid.
#
# Run this ON the Pi, as the normal user (not root -- it needs to add that user
# to a group, and root is not the account you will be logged in as).
#
#   bash bootstrap-pi.sh --node-id my-pi-02
#
# It shows a plan and asks once before changing anything. --yes skips the
# question. Everything it does is idempotent: run it twice and the second run
# installs nothing and says so.
#
# WHAT IT DOES NOT DO: install an XL1 node. That is a much larger thing and a
# decision about what the machine is for, rather than a step in joining the
# grid. A device that reports and anchors is a full member of a grid without
# one -- corroboration is the point, and it does not require producing blocks.
#
# Options:
#   --node-id NAME     what the device is called on the grid (required)
#   --backend URL      the grid's backend (defaults to the reference grid)
#   --grid URL         where to register a device (same)
#   --label TEXT       a human name for it
#   --with-docker      also install Docker (only useful if this Pi will run a node)
#   --agent-from PATH  use a local xl1_heartbeat.py instead of downloading one
#   --yes              do not ask before making changes
#   --check            report and stop; change nothing at all

set -uo pipefail

PUBLIC_AGENT="https://raw.githubusercontent.com/jebscc/xl1-node-monitor/main/agent"
GRID_URL="${GRID_URL:-https://jimtheexplorer.com/grid}"
BACKEND_URL="${BACKEND_URL:-https://xyo-backend.onrender.com}"
PUBLIC_REPO="${PUBLIC_REPO:-https://raw.githubusercontent.com/jebscc/xl1-node-monitor/main/agent}"
NODE_ID=""; NODE_LABEL=""; WITH_DOCKER=0; AGENT_FROM=""; ASSUME_YES=0; CHECK_ONLY=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else G=""; R=""; Y=""; B=""; D=""; X=""; fi

say()  { printf '  %s\n' "$1"; }
ok()   { printf '  %sok%s    %s\n' "$G" "$X" "$1"; }
warn() { printf '  %swarn%s  %s\n' "$Y" "$X" "$1"; [ $# -gt 1 ] && printf '        %s%s%s\n' "$D" "$2" "$X"; return 0; }
bad()  { printf '  %sstop%s  %s\n' "$R" "$X" "$1"; [ $# -gt 1 ] && printf '        %s%s%s\n' "$D" "$2" "$X"; return 0; }
head_(){ printf '\n%s%s%s\n' "$B" "$1" "$X"; }
die()  { printf '%serror:%s %s\n' "$R" "$X" "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --node-id)     NODE_ID="${2:-}"; shift ;;
    --backend)     BACKEND_URL="${2:-}"; shift ;;
    --grid)        GRID_URL="${2:-}"; shift ;;
    --label)       NODE_LABEL="${2:-}"; shift ;;
    --with-docker) WITH_DOCKER=1 ;;
    --agent-from)  AGENT_FROM="${2:-}"; shift ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --check)       CHECK_ONLY=1 ;;
    -h|--help)     sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

have() { command -v "$1" >/dev/null 2>&1; }

printf '%sExplorer Grid -- Raspberry Pi bootstrap%s\n' "$B" "$X"

# =============================================================================
head_ "What this machine is"
# =============================================================================
MODEL="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
ARCH="$(uname -m)"
RAM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
SWAP_MB="$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
DISK_MB="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
OS_NAME="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"

say "${MODEL:-unknown model}"
say "${OS_NAME:-unknown OS} on $ARCH"
say "${RAM_MB:-?} MB RAM, ${SWAP_MB:-0} MB swap, ${DISK_MB:-?} MB free on /"

BLOCKED=0
case "$ARCH" in
  aarch64|arm64) ok "64-bit ARM -- the agent and the node images both target this" ;;
  armv7l|armv6l)
    warn "32-bit OS on 64-bit hardware" \
         "the agent is plain Python and runs fine; XL1 node images are published for arm64 only, so a node would need the 64-bit Raspberry Pi OS" ;;
  x86_64) ok "x86_64" ;;
  *) warn "unfamiliar architecture: $ARCH" ;;
esac

# Measured rather than guessed, because the guess was wrong. An earlier version
# of this said 1 GB "is not enough to run a producer", on the strength of the
# reference Pi 4 showing ~1000 MB used -- which is the whole system, page cache
# and all, not the node. The node's actual footprint there, by process tree:
# producer ~287 MB, anchor service ~80 MB. About 370 MB.
#
# So a 1 GB board is not disqualified, and saying it was would have talked
# people out of hardware that works. What is genuinely unknown is whether a
# Pi 3 keeps UP: its CPU is materially slower than a Pi 4's, and memory use
# grows with the chain. That is a question for whoever runs it, not something
# this script can settle -- so it reports the numbers and leaves the decision.
if [ -n "${RAM_MB:-}" ]; then
  if [ "$RAM_MB" -lt 1200 ]; then
    warn "${RAM_MB} MB RAM -- enough for the agent, tight for a node" \
         "the reference node measures about 370 MB (producer ~287, anchor service ~80), so it fits on paper once the OS is accounted for. Whether this board keeps up is the open question, and it is not a memory one. This script installs no node either way."
  elif [ "$RAM_MB" -lt 3000 ]; then
    ok "${RAM_MB} MB RAM -- comfortable for the agent, workable for a node (~370 MB measured)"
  else
    ok "${RAM_MB} MB RAM"
  fi
fi

[ -n "${DISK_MB:-}" ] && { [ "$DISK_MB" -ge 500 ] && ok "disk space is fine" \
  || { bad "less than 500 MB free on /"; BLOCKED=1; }; }

if [ "$(id -u)" = 0 ]; then
  bad "run this as your normal user, not root" \
      "it adds THAT user to the docker group; as root it would add the wrong one. It will ask for sudo when it needs it."
  BLOCKED=1
elif ! have sudo; then
  bad "sudo is not installed"; BLOCKED=1
else
  ok "running as $(id -un); sudo will be used where needed"
fi

[ -z "$NODE_ID" ] && [ "$CHECK_ONLY" != 1 ] && die "--node-id is required (try --help)"
case "$NODE_ID" in
  ""|*[!A-Za-z0-9._-]*) [ -n "$NODE_ID" ] && { bad "node id '$NODE_ID' has characters the backend rejects" \
      "letters, numbers, dots, dashes, underscores"; BLOCKED=1; } ;;
esac

# =============================================================================
head_ "The plan"
# =============================================================================
NEED_APT=""
have python3 || NEED_APT="$NEED_APT python3"
have curl    || NEED_APT="$NEED_APT curl"
have ca-certificates 2>/dev/null || true
[ "$WITH_DOCKER" = 1 ] && ! have docker && NEED_APT="$NEED_APT docker.io"

if [ -n "$NEED_APT" ]; then
  say "apt install:$NEED_APT"
else
  say "apt: nothing to install, everything needed is already here"
fi
if [ "$WITH_DOCKER" = 1 ]; then
  say "add $(id -un) to the docker group"
else
  say "Docker: skipped (pass --with-docker if this Pi will run a node)"
fi
if [ -n "$AGENT_FROM" ]; then
  say "agent: copy from $AGENT_FROM"
else
  say "agent: download from $PUBLIC_AGENT"
fi
say "install to /opt/xl1-heartbeat, service account xl1agent"
say "then run the eligibility checks, and stop before touching credentials"

if [ "$BLOCKED" = 1 ]; then
  printf '\n%sNot proceeding.%s Fix the items marked stop above.\n' "$R" "$X"
  exit 1
fi
if [ "$CHECK_ONLY" = 1 ]; then
  printf '\n%sCheck only -- nothing was changed.%s\n' "$G" "$X"
  exit 0
fi
if [ "$ASSUME_YES" != 1 ]; then
  printf '\nGo ahead? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) printf 'Nothing was changed.\n'; exit 0 ;; esac
fi

# =============================================================================
head_ "Installing prerequisites"
# =============================================================================
if [ -n "$NEED_APT" ]; then
  sudo apt-get update -qq || die "apt-get update failed"
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq $NEED_APT || die "apt-get install failed"
  ok "installed:$NEED_APT"
else
  ok "nothing to install"
fi

if [ "$WITH_DOCKER" = 1 ]; then
  sudo usermod -aG docker "$(id -un)"
  ok "added $(id -un) to the docker group"
  warn "log out and back in before Docker works for this user" \
       "group membership is applied at login; until then 'docker ps' will be refused"
fi

# =============================================================================
head_ "Fetching the agent"
# =============================================================================
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ -n "$AGENT_FROM" ]; then
  [ -f "$AGENT_FROM" ] || die "no such file: $AGENT_FROM"
  cp "$AGENT_FROM" "$WORK/xl1_heartbeat.py"
  svc="$(dirname "$AGENT_FROM")/xl1-heartbeat.service"
  [ -f "$svc" ] && cp "$svc" "$WORK/xl1-heartbeat.service"
  ok "copied from $AGENT_FROM"
else
  curl -fsSL --max-time 60 "$PUBLIC_AGENT/xl1_heartbeat.py"      -o "$WORK/xl1_heartbeat.py" \
    || die "could not download the agent"
  curl -fsSL --max-time 60 "$PUBLIC_AGENT/xl1-heartbeat.service" -o "$WORK/xl1-heartbeat.service" \
    || die "could not download the service unit"
  ok "downloaded agent $(grep -m1 '^AGENT_VERSION' "$WORK/xl1_heartbeat.py" | cut -d'"' -f2)"
fi

# It is a Python file about to run as a service. Parsing it is a cheap way to
# find a truncated or half-served download before systemd does.
python3 -m py_compile "$WORK/xl1_heartbeat.py" 2>/dev/null \
  && ok "the agent parses" \
  || die "the downloaded agent does not parse -- a truncated download? Run this again."

# =============================================================================
head_ "Installing the agent"
# =============================================================================
id xl1agent >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin xl1agent
getent group docker >/dev/null 2>&1 && sudo usermod -aG docker xl1agent
ok "service account xl1agent"

sudo mkdir -p /opt/xl1-heartbeat
sudo cp "$WORK/xl1_heartbeat.py" /opt/xl1-heartbeat/
[ -f "$WORK/xl1-heartbeat.service" ] && sudo cp "$WORK/xl1-heartbeat.service" /etc/systemd/system/
ok "installed to /opt/xl1-heartbeat"

# =============================================================================
head_ "Where you are"
# =============================================================================
printf '  The machine is ready. Nothing has been given a credential yet, and the\n'
printf '  service is not running -- that is deliberate: the token is shown once,\n'
printf '  so it is worth being at the keyboard for the next two steps.\n\n'
printf '  1. Register %s%s%s at:\n     %s\n\n' "$B" "$NODE_ID" "$X" "$GRID_URL"
printf '  2. Then, on this Pi:\n\n'
printf '     %sNODE_HEARTBEAT_TOKEN=<the token> \\\n' "$D"
printf '       bash %s --node-id %s%s --install%s\n\n' \
       "${CHECKER_HINT:-onboard.sh}" "$NODE_ID" \
       "$( [ "$WITH_DOCKER" = 1 ] || printf ' --skip-docker' )" "$X"
printf '  onboard.sh runs the full eligibility check and only installs the\n'
printf '  service once every one of them passes.\n'

# Piped into bash there is no adjacent file to find -- $0 is "bash" -- so the
# checker is fetched the same way this script was. Kept next to the agent it
# checks, so the two cannot drift apart in a download.
head_ "Running the checks now"
CHECKER="$(dirname "$0")/onboard.sh"
if [ ! -f "$CHECKER" ]; then
  CHECKER="$WORK/onboard.sh"
  curl -fsSL --max-time 60 "$PUBLIC_REPO/onboard.sh" -o "$CHECKER" 2>/dev/null \
    || { warn "could not download onboard.sh" "the agent is installed; run the checks by hand"; CHECKER=""; }
fi
if [ -n "$CHECKER" ]; then
  extra=""; [ "$WITH_DOCKER" = 1 ] || extra="--skip-docker"
  # shellcheck disable=SC2086
  bash "$CHECKER" --node-id "$NODE_ID" --backend "$BACKEND_URL" --grid "$GRID_URL" $extra
fi
