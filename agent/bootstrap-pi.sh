#!/usr/bin/env bash
#
# From a freshly flashed Raspberry Pi to a device on the Explorer Grid, in
# eleven steps. It asks before each one, and shows what it will do first.
#
#   curl -fsSL <this-url> | bash
#
# What it installs, all of it on this machine:
#
#   the heartbeat agent    reports how the Pi is doing, every 30 seconds
#   an XL1 block producer  built here and run in Docker          (step 10)
#   the anchoring service  writes a hash of each reading to XL1  (step 11)
#
# The last two are required, deliberately. A device that cannot anchor is a
# machine making claims about itself that nobody can check afterwards, and
# checkable claims are the whole argument the grid rests on.
#
# Every answer can also be given as a flag, and anything given is not asked
# about -- which is what makes this usable from a script as well as a chair:
#
#   --node-id NAME     what the device is called on the grid
#   --label TEXT       a human name for it
#   --location TEXT    a town, region or country -- shown as stated, not checked
#   --lat N --lon N    coordinates for the map
#   --postcode CODE    look the coordinates up from a postal code instead
#   --country CC       country for that lookup (default us)
#   --radius KM        how wide the location claim is (default 25)
#   --no-location      do not ask about location; report none
#   --with-docker      install Docker without asking (the node needs it)
#   --tailscale-key K  join the tailnet with an auth key instead of a browser
#   --backend URL      the grid's backend
#   --account URL      where an operator signs in to see their devices
#   --grid URL         the older name for --account, still accepted
#   --agent-from PATH  use a local xl1_heartbeat.py instead of downloading
#   --yes, -y          take the answers given and ask nothing
#   --check            report what it found and stop, changing nothing
#   --fresh            ignore a half-finished run and start from the top
#
# Tailscale is required too, and has no flag to skip it -- see step 5.
#
# Piped into bash, stdin is this script, so questions are read from /dev/tty
# instead. A plain `read` would swallow the rest of the file and the run would
# end somewhere in the middle of a function. With no terminal at all (cron,
# CI) it says so and asks for flags rather than hanging on a prompt nobody can
# answer.

set -uo pipefail

# Where a device is registered. This was the public grid page, which offered a
# proof-of-work puzzle and no account; it is the operator's own portal now, so a
# device belongs to somebody from the moment it exists. GRID_URL is still read
# so an older invocation keeps working.
ACCOUNT_URL="${ACCOUNT_URL:-${GRID_URL:-https://jimtheexplorer.com/portal}}"
# The map itself, named separately: it is what the device joins, it needs no
# account to look at, and a self-hosted copy overrides it on its own.
GRID_URL="${MAP_URL:-https://jimtheexplorer.com/grid}"
BACKEND_URL="${BACKEND_URL:-https://xyo-backend.onrender.com}"
# The XL1 block producer. Built on the device from the published images repo,
# because that repo publishes no registry tags yet. The entrypoint is compiled
# in a container first -- the Dockerfile COPYs the result and does not produce
# it -- so no Node or pnpm is needed on this host.
IMAGES_REPO="${IMAGES_REPO:-/opt/xl1-docker-images}"
IMAGES_URL="${IMAGES_URL:-https://github.com/XYOracleNetwork/xl1-docker-images.git}"
CLI_REGISTRY="${CLI_REGISTRY:-https://registry.npmjs.org/@xyo-network/xl1-cli/latest}"
# Matches the default in the images repo's own build-image.sh, and is the Node
# the resulting image runs. Compiling the entrypoint on a different major than
# the one that will execute it is a difference nothing here would notice.
NODE_VERSION="${NODE_VERSION:-24.14.1}"
# Root-owned, 0600, and deliberately NOT inside IMAGES_REPO: the weekly rebuild
# does a git fetch and ff-only merge in there, and a wallet phrase does not
# belong in a directory something else is pulling into.
PRODUCER_ENV="${PRODUCER_ENV:-/etc/xl1-producer.env}"
XL1_NET="${XL1_NET:-sequence}"
# The public gateway for each network. A federated producer serves no RPC of
# its own, so reads go here. Same defaults as docker-compose.pi.yml, and
# overridable the same way: every read in the service builds a gateway first,
# so without these it starts cleanly and answers 503 to everything.
XL1_SEQUENCE_RPC_URL="${XL1_SEQUENCE_RPC_URL:-https://beta.api.chain.xyo.network/rpc}"
XL1_MAINNET_RPC_URL="${XL1_MAINNET_RPC_URL:-https://api.chain.xyo.network/rpc}"
# Checked in step 1, because a node that cannot reach this cannot take part and
# that is worth knowing before anything is built or any phrase is asked for.
XL1_RPC_URL="${XL1_RPC_URL:-https://beta.api.chain.xyo.network/rpc}"
# The anchor service. Published in the same repo as this script, under service/,
# so a stranger needs nothing that is not already public.
MONITOR_REPO="${MONITOR_REPO:-/opt/xl1-node-monitor}"
# An archive of github.com/jebscc/xl1-node-monitor, not a clone of it: this
# needs the service's files and never its history. The clone URL used to sit
# here beside it and went unused once the clone did, which is the kind of thing
# that has the next reader looking for the git command that is not there.
MONITOR_TAR="${MONITOR_TAR:-https://codeload.github.com/jebscc/xl1-node-monitor/tar.gz/refs/heads/main}"
# The attestation phrase is written here by new-attestor.ts, 0600, on the host
# rather than in the container so a rebuild cannot take it with it.
KEYS_DIR="${KEYS_DIR:-/opt/xl1-keys}"
# Same reasoning as PRODUCER_ENV: out of the checkout, since this step
# fetches and merges in there. Compose reads it through --env-file rather
# than by it sitting beside the compose file.
ANCHOR_ENV="${ANCHOR_ENV:-/etc/xl1-anchor.env}"
# Which producer the delegation on chain was made FOR. Written beside the key
# it describes rather than into the state file, because the state file lives in
# a home directory and is missing on plenty of working devices -- and a check
# that cannot run is worse here than no check, since it would silently pass.
ANCHOR_PRODUCER_FILE="${ANCHOR_PRODUCER_FILE:-/etc/xl1-anchor.producer}"
AGENT_ENV="${AGENT_ENV:-/etc/xl1-heartbeat.env}"
PUBLIC_REPO="${PUBLIC_REPO:-https://raw.githubusercontent.com/jebscc/xl1-node-monitor/main/agent}"
NODE_ID=""; NODE_LABEL=""; STATED_LOCATION=""; STATED_LAT=""; STATED_LON=""
STATED_RADIUS="25"; WITH_DOCKER=""; NO_LOCATION=0
POSTCODE=""; COUNTRY_CC="us"; TS_KEY=""; FRESH=0; REUSING_INSTALLED=0
DONE_PREREQS=0; DONE_TAILSCALE=0; DONE_AGENT=0
AGENT_FROM=""; ASSUME_YES=0; CHECK_ONLY=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'
  B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else G=""; R=""; Y=""; C=""; B=""; D=""; X=""; fi
# Erase to end of line, for the spinner that redraws itself with \r.
#
# This used to blank a hard-coded 78 columns, which is shorter than the line
# it clears once the attestation address is in it -- so "gas arrived" landed
# on top of the old line and left its tail showing, reading like a corrupted
# address at the exact moment somebody is being asked to fund one.
#
# Empty when stdout is not a terminal, where the redraw is meaningless and
# the escape would only be noise in a log.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then EOL=$'\033[K'; else EOL=""; fi

# Marks and rules, in two sets.
#
# A tick reads faster than the word "ok" and a heavy rule separates steps
# better than a blank line -- but only where the terminal can draw them. This
# runs over SSH from phones, from cron, and into log files, and a box-drawing
# character that arrives as a question mark is worse than the plain word it
# replaced.
#
# So the test is the same one the colours use, plus the locale actually saying
# UTF-8. Anything short of that gets ASCII that has always worked.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && \
   printf '%s' "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" | grep -qi 'utf-*8'; then
  M_OK=$'\u2714'; M_WARN=$'\u25b2'; M_BAD=$'\u2718'
  M_STEP=$'\u25b8'; RULE=$'\u2500'
else
  M_OK="ok"; M_WARN="!!"; M_BAD="xx"; M_STEP=">"; RULE="-"
fi

# A rule as wide as the terminal, capped so it stays readable on a wide one
# and never wraps on a narrow one. tput is not always there; 62 is a sane
# width for a phone-sized SSH window.
rule() {
  cols="$(tput cols 2>/dev/null || echo 62)"
  [ "$cols" -gt 72 ] 2>/dev/null && cols=72
  [ "$cols" -lt 24 ] 2>/dev/null && cols=24
  i=0; line=""
  while [ "$i" -lt "$cols" ]; do line="$line$RULE"; i=$((i + 1)); done
  printf '%s%s%s\n' "$D" "$line" "$X"
}

say()  { printf '  %s\n' "$1"; }
ok()   { printf '  %s%s%s  %s\n' "$G" "$M_OK" "$X" "$1"; }
warn() { printf '  %s%s%s  %s\n' "$Y" "$M_WARN" "$X" "$1"; [ $# -gt 1 ] && printf '     %s%s%s\n' "$D" "$2" "$X"; return 0; }
bad()  { printf '  %s%s%s  %s\n' "$R" "$M_BAD" "$X" "$1"; [ $# -gt 1 ] && printf '     %s%s%s\n' "$D" "$2" "$X"; return 0; }
# A step header: a rule, then the number in colour and the title in bold, so a
# reader scrolling back can find where each step began.
head_(){
  printf '\n'
  rule
  printf '%s%s%s %s%s%s\n\n' "$C" "$M_STEP" "$X" "$B" "$1" "$X"
}
note() { printf '  %s%s%s\n' "$D" "$1" "$X"; }
die()  { printf '%serror:%s %s\n' "$R" "$X" "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --node-id)     NODE_ID="${2:-}"; shift ;;
    --label)       NODE_LABEL="${2:-}"; shift ;;
    --location)    STATED_LOCATION="${2:-}"; shift ;;
    --lat)         STATED_LAT="${2:-}"; shift ;;
    --postcode)    POSTCODE="${2:-}"; shift ;;
    --country)     COUNTRY_CC="${2:-}"; shift ;;
    --lon)         STATED_LON="${2:-}"; shift ;;
    --radius)      STATED_RADIUS="${2:-}"; shift ;;
    --no-location) NO_LOCATION=1 ;;
    --backend)     BACKEND_URL="${2:-}"; shift ;;
    --grid)        ACCOUNT_URL="${2:-}"; shift ;;   # kept: older callers pass it
    --account)     ACCOUNT_URL="${2:-}"; shift ;;
    --with-docker) WITH_DOCKER=1 ;;
    --tailscale-key) TS_KEY="${2:-}"; shift ;;
    --agent-from)  AGENT_FROM="${2:-}"; shift ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --fresh)       FRESH=1 ;;
    --check)       CHECK_ONLY=1 ;;
    -h|--help)     sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

have() { command -v "$1" >/dev/null 2>&1; }

# Whichever python actually RUNS, not merely whichever name resolves. On
# Windows "python3" is often a Store stub that resolves and then does nothing,
# and on some minimal images only "python" exists. Everything below that needs
# an interpreter uses this one.
PY=""
for _c in python3 python; do
  if command -v "$_c" >/dev/null 2>&1 && "$_c" -c 'import json,sys' >/dev/null 2>&1; then
    PY="$_c"; break
  fi
done

# --- asking -------------------------------------------------------------------
# Every prompt reads /dev/tty, never stdin, because stdin is this script when
# it arrives through a pipe.
# Detected by OPENING it, not by testing the path. A -r/-w test on /dev/tty
# succeeds on a machine with no controlling terminal -- the node exists, it
# just cannot be opened -- and the script then believes it can ask questions,
# prints a prompt nobody answers, and loops on the empty reply forever.
TTY_OK=0
if { : < /dev/tty; } 2>/dev/null && { : > /dev/tty; } 2>/dev/null; then TTY_OK=1; fi

ask() { # ask <prompt> <default> -> answer on stdout
  local prompt="$1" default="${2:-}" reply=""
  if [ "$TTY_OK" != 1 ]; then printf '%s' "$default"; return; fi
  if [ -n "$default" ]; then printf '%s %s[%s]%s: ' "$prompt" "$D" "$default" "$X" > /dev/tty
  else printf '%s: ' "$prompt" > /dev/tty; fi
  IFS= read -r reply < /dev/tty || reply=""
  printf '%s' "${reply:-$default}"
}

ask_yn() { # ask_yn <prompt> <default y|n> -> 0 yes, 1 no
  local prompt="$1" default="${2:-n}" reply="" hint="y/N"
  # --yes took the default at two call sites and asked at the rest, so it read
  # as broken rather than partial: an operator who passed it still sat through
  # questions. Taken here, it covers every prompt in the script.
  if [ "$TTY_OK" != 1 ] || [ "${ASSUME_YES:-0}" = 1 ]; then
    [ "$default" = y ] && return 0 || return 1
  fi
  [ "$default" = y ] && hint="Y/n"
  printf '%s %s[%s]%s: ' "$prompt" "$D" "$hint" "$X" > /dev/tty
  IFS= read -r reply < /dev/tty || reply=""
  reply="${reply:-$default}"
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ask_secret() { # ask_secret <prompt> -> answer on stdout, never echoed
  local prompt="$1" reply=""
  [ "$TTY_OK" != 1 ] && { printf ''; return; }
  printf '%s: ' "$prompt" > /dev/tty
  stty -echo < /dev/tty 2>/dev/null
  IFS= read -r reply < /dev/tty || reply=""
  stty echo < /dev/tty 2>/dev/null
  printf '\n' > /dev/tty
  printf '%s' "$reply"
}


# Look a postal code up. Sets FOUND_NAME / FOUND_LAT / FOUND_LON, or leaves
# FOUND_NAME empty. Coordinates are rounded to one decimal HERE, not merely on
# arrival: a value that was never precise locally cannot leak from anywhere
# else either, and a postcode centroid was never precise to begin with.
FOUND_NAME=""; FOUND_LAT=""; FOUND_LON=""
lookup_postcode() { # lookup_postcode <country> <code>
  FOUND_NAME=""; FOUND_LAT=""; FOUND_LON=""
  have curl || return 1
  local cc pc enc resp
  cc="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  # Spaces are legal in plenty of postcodes and illegal in a URL path.
  enc="$(printf '%s' "$2" | sed 's/ /%20/g')"
  resp="$(curl -fsSL --max-time 25 "https://api.zippopotam.us/$cc/$enc" 2>/dev/null)" || return 1
  [ -n "$resp" ] || return 1
  [ -n "$PY" ] || return 1
  eval "$(printf '%s' "$resp" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    p = d["places"][0]
    bits = [p["place name"], p.get("state abbreviation") or p.get("state") or "",
            d.get("country abbreviation", "")]
    print("FOUND_NAME=%s" % json.dumps(", ".join(x for x in bits if x)))
    print("FOUND_LAT=%.1f" % float(p["latitude"]))
    print("FOUND_LON=%.1f" % float(p["longitude"]))
except Exception:
    print("FOUND_NAME=")
' 2>/dev/null)"
  [ -n "$FOUND_NAME" ]
}


# Tailscale, from Tailscale's own apt repository rather than by piping their
# install script into a shell. Slightly more code, and the difference is that
# every step here is visible and the packages are signed and updated by apt
# like everything else on the machine.
install_tailscale() {
  local id cn base
  id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-debian}")"
  cn="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-bookworm}")"
  case "$id" in raspbian) base=raspbian ;; *) base=debian ;; esac
  # A codename newer than anything Tailscale publishes would 404 the whole
  # install; bookworm is the safe floor and its packages run fine on trixie.
  curl -fsI --max-time 20 \
    "https://pkgs.tailscale.com/stable/$base/$cn.tailscale-keyring.list" >/dev/null 2>&1 \
    || cn=bookworm
  curl -fsSL --max-time 40 "https://pkgs.tailscale.com/stable/$base/$cn.noarmor.gpg" \
    | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null || return 1
  curl -fsSL --max-time 40 "https://pkgs.tailscale.com/stable/$base/$cn.tailscale-keyring.list" \
    | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null || return 1
  sudo apt-get update -qq || return 1
  sudo apt-get install -y -qq tailscale || return 1
}


# --- remembering where we got to ---------------------------------------------
# Setup involves a web page, a browser sign-in and a token shown once, so
# stopping halfway is an ordinary thing to do rather than a failure. Answers
# are written as they are given and replayed on the next run.
#
# THE TOKEN IS NEVER WRITTEN HERE. It is a credential; it goes into the
# root-owned 0600 env file and nowhere else. Everything in this file is an
# answer the operator would happily give again.
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xl1-grid"
STATE="$STATE_DIR/bootstrap.state"

save_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  chmod 700 "$STATE_DIR" 2>/dev/null
  {
    printf '# Explorer Grid setup, unfinished. Delete this to start over.\n'
    printf 'NODE_ID=%q\n'         "${NODE_ID:-}"
    printf 'NODE_LABEL=%q\n'      "${NODE_LABEL:-}"
    printf 'STATED_LOCATION=%q\n' "${STATED_LOCATION:-}"
    printf 'STATED_LAT=%q\n'      "${STATED_LAT:-}"
    printf 'STATED_LON=%q\n'      "${STATED_LON:-}"
    printf 'STATED_RADIUS=%q\n'   "${STATED_RADIUS:-25}"
    printf 'WITH_DOCKER=%q\n'     "${WITH_DOCKER:-}"
    printf 'DONE_PREREQS=%q\n'    "${DONE_PREREQS:-0}"
    printf 'DONE_TAILSCALE=%q\n'  "${DONE_TAILSCALE:-0}"
    printf 'DONE_AGENT=%q\n'      "${DONE_AGENT:-0}"
    printf 'DONE_PRODUCER=%q\n' "${DONE_PRODUCER:-0}"
    printf 'REWARD_ADDRESS=%q\n' "${REWARD_ADDRESS:-}"
    printf 'DONE_ANCHOR=%q\n'   "${DONE_ANCHOR:-0}"
    # Public, and the wizard stops on it waiting for gas -- so it has to
    # survive the operator closing the terminal and coming back tomorrow.
    printf 'ATTESTOR_ADDRESS=%q\n' "${ATTESTOR_ADDRESS:-}"
    # XL1_MNEMONIC is deliberately absent, for the same reason the device
    # token is: a resumable wizard that writes a secret to a plain file in
    # the home directory has quietly made a second copy of the one thing
    # that matters most. It is asked for again on the next run.
  } > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE" 2>/dev/null
  chmod 600 "$STATE" 2>/dev/null
  return 0
}

clear_state() { rm -f "$STATE" "$STATE.tmp" 2>/dev/null; return 0; }

# Ctrl+C is a normal way to leave this -- the token may simply not exist yet --
# so it says what happens next instead of dumping the reader out at a bare ^C.
on_interrupt() {
  printf '\n\n%sStopped.%s Everything you answered is saved.\n' "$Y" "$X"
  printf '  Run the same command again and it resumes from here.\n'
  printf '  To start over instead:  rm %s\n' "$STATE"
  exit 130
}
trap on_interrupt INT


# What device this machine is ALREADY set up as, if any.
#
# More authoritative than anything remembered from a previous run: the config
# on disk is what the agent is actually using, whereas the state file is what
# somebody was part way through deciding. Reading it wrong is how a machine
# ends up renamed, with the old device left revoked or silent and the new one
# refused -- which is exactly what happened the first time this was used in
# anger.
INSTALLED_ID=""
read_installed_id() {
  [ -f /etc/xl1-heartbeat.env ] || return 0
  # 0600 and root-owned, so this needs sudo. Non-interactive first: asking for
  # a password before saying why is a bad way to open a conversation.
  INSTALLED_ID="$(sudo -n grep -m1 '^NODE_ID=' /etc/xl1-heartbeat.env 2>/dev/null \
                  | cut -d= -f2- | tr -d '"' | tr -d "'")"
  if [ -z "$INSTALLED_ID" ]; then
    printf '  %sThis machine already has an agent installed.%s\n' "$B" "$X"
    note "Reading which device it is set up as -- that needs sudo."
    INSTALLED_ID="$(sudo grep -m1 '^NODE_ID=' /etc/xl1-heartbeat.env 2>/dev/null \
                    | cut -d= -f2- | tr -d '"' | tr -d "'")"
  fi
  return 0
}

printf '%sExplorer Grid -- Raspberry Pi setup%s\n' "$B" "$X"

# Someone running this may never have heard of any of it. Four sentences up
# front costs nothing and is the difference between answering questions and
# guessing at them.
printf '\n'
note "This adds this Raspberry Pi to the Explorer Grid: a public map of real"
note "devices, run by real people, each reporting on itself."
note ""
note "It installs a small agent that reports how the machine is doing every"
note "30 seconds -- uptime, temperature, whether it is online. Optionally it"
note "also commits those readings to XYO Layer One, so anyone can check they"
note "were not edited afterwards."
note ""
note "It also installs an XL1 block producer and the anchoring service"
note "that commits those readings -- steps 10 and 11, both required."
note ""
note "It never asks for a wallet, a seed phrase or a private key, with one"
note "exception it will explain when it gets there: binding the anchoring"
note "key to your producer needs the producer phrase, once, typed by you."

# =============================================================================
head_ "1. What this machine is"
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

# uname -m reports the KERNEL. Raspberry Pi OS ships a 64-bit kernel with a
# 32-bit userland by default on some images, and that combination passes the
# check above and then fails at the node image, which is published for arm64
# only -- after a twenty-minute build, having asked for a wallet phrase.
if have dpkg; then
  USERLAND="$(dpkg --print-architecture 2>/dev/null)"
  case "$ARCH:$USERLAND" in
    aarch64:armhf|arm64:armhf)
      bad "64-bit kernel, 32-bit userland (armhf)"
      note "  This is the default on some Raspberry Pi OS images and it cannot"
      note "  run the node: XL1 images are arm64 only. Reflash with the 64-bit"
      note "  Raspberry Pi OS."
      BLOCKED=1 ;;
    *:arm64|*:amd64) ok "64-bit userland ($USERLAND)" ;;
    *) [ -n "$USERLAND" ] && say "userland: $USERLAND" ;;
  esac
fi

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

# 500 MB was right when this installed a Python agent and nothing else. It now
# builds the node image on the device -- around 545 MB before its base layers --
# and then a second image for the anchor service, with build cache alongside.
# A machine that passes at 500 MB is one that fails part way through a build,
# which is a much worse place to find out.
#
# 3 GB is what the images repo's own preflight asks for, and it is not
# conservative: it is roughly what the two builds and their layers occupy.
if [ -n "${DISK_MB:-}" ]; then
  if [ "$DISK_MB" -lt 1000 ]; then
    bad "${DISK_MB} MB free on / -- the node images need about 3 GB to build"
    BLOCKED=1
  elif [ "$DISK_MB" -lt 3000 ]; then
    warn "${DISK_MB} MB free on / -- tight" \
         "building both images wants about 3 GB with layers and cache. It may finish; it may stop part way through, which is the expensive way to find out."
  else
    ok "${DISK_MB} MB free on /"
  fi
fi

# The Pi has no clock of its own. It signs against chain time, and a producer
# whose clock has drifted is refused rather than merely late.
if have timedatectl; then
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    ok "clock is synchronised"
  else
    warn "clock is not synchronised yet" \
         "usually clears on its own within a minute of boot; the producer signs against chain time, so it matters here more than on a desktop"
  fi
fi

# The one endpoint the producer cannot work without. The backend check further
# down proves this site is reachable, which is a different question.
if have curl; then
  # POST with an empty body, and not a GET: the endpoint answers 404 to a GET,
  # which would report every healthy network as unreachable. `{}` names no
  # method -- this asks whether the endpoint is THERE, and deliberately does not
  # call anything on it. Chain reads belong in the SDK, never in a shell.
  if curl -fsS --max-time 15 -o /dev/null -X POST -H "content-type: application/json" \
          -d "{}" "$XL1_RPC_URL" 2>/dev/null; then
    ok "the XL1 network is reachable"
  else
    warn "could not reach the XL1 network at $XL1_RPC_URL" \
         "the agent still installs and reports; the node cannot take part until this resolves. A proxy or a filtered network is the usual cause."
  fi
fi

# --- how the board itself is doing -------------------------------------------
# These four are lifted from the preflight in LewSales/xl1-block-producer-pi,
# which checks things this did not and which matter more on a Pi than on a
# server. Undervoltage in particular: a marginal supply is the usual cause of
# corrupted SD cards and of nodes that "randomly" stop, and it is invisible
# unless something asks the firmware.
if have vcgencmd; then
  T="$(vcgencmd get_throttled 2>/dev/null | sed 's/.*=//')"
  if [ -n "$T" ]; then
    TV=$(( T ))
    if   [ $(( TV & 0x1 )) -ne 0 ]; then
      bad "the power supply is undervolting RIGHT NOW" \
          "this corrupts SD cards and stops nodes at random. A Pi 3 wants a real 5V/2.5A supply -- a phone charger usually is not one."
      BLOCKED=1
    elif [ $(( TV & 0x10000 )) -ne 0 ]; then
      warn "the supply has undervolted since boot" \
           "marginal rather than broken. Worth replacing before this runs unattended."
    else
      ok "power supply is steady"
    fi
    [ $(( TV & 0x4 )) -ne 0 ] && warn "the CPU is being throttled right now" \
      "usually heat, sometimes the supply"
  fi
fi

TEMP=""
[ -r /sys/class/thermal/thermal_zone0/temp ] && \
  TEMP=$(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) / 1000 ))
if [ -n "$TEMP" ]; then
  if [ "$TEMP" -ge 75 ]; then
    warn "${TEMP}C already, before doing any work" \
         "a Pi 3 throttles around 80C. A heatsink or a case with a fan pays for itself here."
  else
    ok "${TEMP}C"
  fi
fi

# Wi-Fi works. It is just the first thing to blame when a device starts
# looking offline for a few minutes at a time.
IFACE="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
case "$IFACE" in
  wl*) warn "connected over Wi-Fi ($IFACE)" \
            "fine, but less steady under load than Ethernet -- a device that drops off for a minute reads as OFFLINE on the map" ;;
  "")  ;;
  *)   ok "wired network ($IFACE)" ;;
esac

if [ "$(id -u)" = 0 ]; then
  bad "run this as your normal user, not root" \
      "it adds THAT user to the docker group; as root it would add the wrong one. It will ask for sudo when it needs it."
  BLOCKED=1
elif ! have sudo; then
  bad "sudo is not installed"; BLOCKED=1
else
  ok "running as $(id -un); sudo will be used where needed"
fi

if [ "$BLOCKED" = 1 ]; then
  printf '\n%sNot proceeding.%s Fix the items marked stop above.\n' "$R" "$X"
  exit 1
fi

if [ "$TTY_OK" != 1 ] && [ "$ASSUME_YES" != 1 ] && [ "$CHECK_ONLY" != 1 ]; then
  printf '\n%sThere is no terminal to ask questions on.%s\n' "$Y" "$X"
  printf '  Give the answers as flags and add --yes, or run it from a shell:\n\n'
  printf '    bash bootstrap-pi.sh --node-id NAME --yes\n\n'
  printf '  --help lists every question as a flag.\n'
  exit 2
fi

# Anything already answered is replayed rather than asked again. A flag given
# now still wins: resuming must not overrule someone who has just said
# something different on the command line.
if [ -f "$STATE" ] && [ "$FRESH" != 1 ]; then
  SAVED_ID="$(sed -n "s/^NODE_ID=//p" "$STATE" | head -1 | tr -d "'" | tr -d '"')"
  head_ "Picking up where you left off"
  say "There is an unfinished setup here${SAVED_ID:+ for \"$SAVED_ID\"}."
  note "The answers were kept. The credential never was -- it is not the sort"
  note "of thing that belongs in a file like that."
  printf '\n'
  if [ "$ASSUME_YES" = 1 ] || ask_yn "  Carry on with it?" "y"; then
    _ID="$NODE_ID"; _LB="$NODE_LABEL"; _LO="$STATED_LOCATION"
    _LA="$STATED_LAT"; _LN="$STATED_LON"; _DK="$WITH_DOCKER"
    # shellcheck disable=SC1090
    . "$STATE" 2>/dev/null || true
    [ -n "$_ID" ] && NODE_ID="$_ID"
    [ -n "$_LB" ] && NODE_LABEL="$_LB"
    [ -n "$_LO" ] && STATED_LOCATION="$_LO"
    [ -n "$_LA" ] && STATED_LAT="$_LA"
    [ -n "$_LN" ] && STATED_LON="$_LN"
    [ -n "$_DK" ] && WITH_DOCKER="$_DK"
    RESUMED_ID="$NODE_ID"
    ok "restored${NODE_ID:+ -- device \"$NODE_ID\"}"
    [ "${DONE_PREREQS:-0}" = 1 ]   && ok "packages were already installed"
    [ "${DONE_TAILSCALE:-0}" = 1 ] && ok "already joined to the tailnet"
    [ "${DONE_AGENT:-0}" = 1 ]     && ok "the agent is already installed"
    true
  else
    clear_state
    NODE_ID=""; NODE_LABEL=""; STATED_LOCATION=""; STATED_LAT=""; STATED_LON=""
    DONE_PREREQS=0; DONE_TAILSCALE=0; DONE_AGENT=0
    ok "starting over"
  fi
fi

# =============================================================================
head_ "2. Naming the device"
# =============================================================================
read_installed_id
if [ -n "$INSTALLED_ID" ]; then
  printf '\n'
  say "This machine is currently set up as \"$INSTALLED_ID\"."
  if [ -n "$NODE_ID" ] && [ "$NODE_ID" != "$INSTALLED_ID" ]; then
    # A flag or a resumed answer disagreeing with the installed config. The
    # config wins the default, because it is what is actually running.
    note "A different name was given or remembered: \"$NODE_ID\"."
  fi
  note ""
  note "Keeping it re-uses that device -- which is what you want if its token"
  note "needs replacing, or if the last run stopped part way."
  note ""
  note "Setting up a different one leaves \"$INSTALLED_ID\" behind: it stops"
  note "reporting the moment this machine starts answering to another name."
  note "Its record, history and anchors stay, and you can revoke it from Your"
  note "devices when you are sure."
  printf '\n'
  if ask_yn "  Carry on as \"$INSTALLED_ID\"?" "y"; then
    NODE_ID="$INSTALLED_ID"
    REUSING_INSTALLED=1
  else
    NODE_ID=""
    note "Right -- a different device then."
  fi
fi

# The tutorial below is for somebody naming a device for the first time.
# Anyone carrying on with the machine's existing one has already done it.
if [ "${REUSING_INSTALLED:-0}" != 1 ]; then
  note "Two names are asked for, and they do different jobs."
  note ""
  note "This first one is the device's ID -- the permanent handle the grid"
  note "uses in its API, its records and its credential. Think of it as a"
  note "username: short, no spaces, and it CANNOT be changed later."
  note ""
  note "Letters, numbers, dots, dashes and underscores. For example:"
  note "  attic-pi-3     lew-garage-01     pi3-spare"
fi

printf '\n'
# Bounded. A prompt loop with no ceiling is one broken read away from spinning
# until someone notices, and "someone notices" is not an error path.
TRIES=0
while :; do
  TRIES=$((TRIES+1))
  [ "$TRIES" -gt 10 ] && die "too many invalid answers; try --node-id NAME"
  [ -n "$NODE_ID" ] || NODE_ID="$(ask "  A name for this device" "")"
  if [ -z "$NODE_ID" ]; then
    [ "$TTY_OK" = 1 ] || die "--node-id is required"
    printf '  %sA name is required.%s\n' "$Y" "$X"; continue
  fi
  case "$NODE_ID" in
    *[!A-Za-z0-9._-]*)
      printf '  %s"%s" has characters the grid will reject.%s\n' "$Y" "$NODE_ID" "$X"
      NODE_ID=""; [ "$TTY_OK" = 1 ] || die "invalid --node-id"; continue ;;
  esac
  if [ "${#NODE_ID}" -gt 64 ]; then
    printf '  %sThat is %s characters; the limit is 64.%s\n' "$Y" "${#NODE_ID}" "$X"
    NODE_ID=""; [ "$TTY_OK" = 1 ] || die "--node-id too long"; continue
  fi
  # Asked of the grid rather than assumed. This used to read the list of
  # REPORTING devices, which is a different question: an id that holds a
  # credential and has never reported is absent from it, so a name that was
  # already taken came back "free" and the truth arrived much later.
  AVAIL=""; REASON=""
  if have curl && [ -n "$PY" ]; then
    AV_JSON="$(curl -fsSL --max-time 25 \
      "$BACKEND_URL/api/node/devices/available?node_id=$NODE_ID" 2>/dev/null)"
    if [ -n "$AV_JSON" ]; then
      eval "$(printf '%s' "$AV_JSON" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("AVAIL=%s" % ("1" if d.get("available") else "0"))
    print("REASON=%s" % json.dumps(d.get("reason") or ""))
except Exception:
    pass
' 2>/dev/null)"
    fi
  fi

  # This machine's own device is decided first, and reason by reason. Order
  # matters: a live device would otherwise be refused as "reporting right now"
  # when it is simply itself, and a revoked one would be waved through and then
  # fail at the far end, which is the failure this whole change came from.
  if [ "${REUSING_INSTALLED:-0}" = 1 ] && [ "$AVAIL" = 0 ]; then
    if [ "$REASON" = revoked ]; then
      printf '  %s"%s" has been revoked.%s
' "$Y" "$NODE_ID" "$X"
      note "Its credential is refused, so re-installing here cannot help. Open"
      note "Your devices (or the operator panel), re-issue a credential for it"
      note "-- that mints a fresh token and keeps the id, its history and its"
      note "anchors -- then run this again with the new token to hand."
      die "nothing was changed"
    fi
    ok "\"$NODE_ID\" is this machine's device"
    break
  fi

  if [ "$AVAIL" = 0 ] && [ "$REASON" = reporting ]; then
    printf '  %s"%s" is a device that is reporting right now.%s\n' "$Y" "$NODE_ID" "$X"
    note "That name belongs to a machine already on the grid. Pick another."
    NODE_ID=""; [ "$TTY_OK" = 1 ] || die "node id already taken"; continue
  fi

  if [ "$AVAIL" = 0 ] && [ "$REASON" = registered ]; then
    # Refused outright, and the reason is worth stating: nothing here can tell
    # whether the person at this keyboard is the one who registered that name.
    # Offering to carry on asked them to assert it, and an assertion is not a
    # check -- it is the same shape as "trust me, I am node X", which is the
    # thing per-device credentials exist to stop accepting.
    #
    # The real answer is an account that owns its devices, so reclaiming a name
    # is something a person proves rather than declares. Until that exists,
    # taken means taken.
    printf '  %s"%s" is already taken.%s\n' "$Y" "$NODE_ID" "$X"
    note "A credential exists for that name, so it cannot be used here."
    note ""
    note "That holds even if you registered it yourself: this script has no"
    note "way to tell you apart from anyone else typing the same name, and"
    note "taking your word for it would defeat the point of the credential."
    note ""
    note "  Pick a different name now, or"
    note "  remove that device from Admin -> Node -> Devices and reuse it."
    NODE_ID=""; [ "$TTY_OK" = 1 ] || die "node id already registered"; continue
  fi

  if [ "$AVAIL" = 1 ]; then
    ok "\"$NODE_ID\" is free"
  else
    # No answer: an older backend, or the network. Say what was and was not
    # established rather than claiming a check that did not happen.
    warn "could not confirm whether \"$NODE_ID\" is taken" \
         "carrying on -- registration will refuse it if it is"
  fi
  break
done

# The prompt that prompted all this. "A label to show beside it" assumed the
# reader already knew there were two names and what the other one was for.
# A label carried over from a name that was abandoned belongs to nothing. The
# first device to hit this ended up called jim-home-04 wearing the label
# "jim-home-03" -- on a public map, claiming to be something else.
if [ -n "${RESUMED_ID:-}" ] && [ "$NODE_ID" != "$RESUMED_ID" ]    && [ "$NODE_LABEL" = "$RESUMED_ID" ]; then
  NODE_LABEL=""
fi
if [ -z "$NODE_LABEL" ]; then
  printf '\n'
  note "The second name is the LABEL -- what people actually read. It appears"
  note "beside this device on the public map and in the device list, and it"
  note "can be anything you like: spaces, capitals and punctuation are fine."
  note ""
  note "  ID     $NODE_ID"
  note "  label  \"Attic Pi 3\"   <- this is the human-readable one"
  note ""
  note "Press Enter to reuse the ID if you would rather not have two."
  printf '\n'
  NODE_LABEL="$(ask "  A label for people to read" "$NODE_ID")"
fi

# =============================================================================
head_ "3. Saying where it is"
# =============================================================================
# Given as a flag, it is resolved here and the questions below never come up.
if [ -n "$POSTCODE" ] && [ -z "$STATED_LAT" ]; then
  if lookup_postcode "$COUNTRY_CC" "$POSTCODE"; then
    STATED_LOCATION="${STATED_LOCATION:-$FOUND_NAME}"
    STATED_LAT="$FOUND_LAT"; STATED_LON="$FOUND_LON"
    ok "$POSTCODE -> $FOUND_NAME ($FOUND_LAT, $FOUND_LON)"
  else
    warn "could not look up postal code \"$POSTCODE\" in \"$COUNTRY_CC\"" \
         "carrying on without a map position"
  fi
fi

if [ "$NO_LOCATION" = 1 ]; then
  note "Skipped. The device will report no location and appear on no map."
elif [ -n "$STATED_LOCATION" ] || [ -n "$STATED_LAT" ]; then
  ok "location given on the command line"
else
  note "Optional, and off unless you fill it in. A device that says nothing"
  note "appears on no map, which is the right default for hardware that lives"
  note "in somebody's house."
  note ""
  note "Nothing verifies this. The grid names the fields 'stated' so nothing"
  note "can render it as a measurement, and rounds coordinates to about 11 km"
  note "on arrival -- a precise position is never stored."
  printf '\n'
  if ask_yn "  Say where this device is?" "n"; then
    printf '\n'
    note "Two ways to place it. A postal code is the easier one, and it is"
    note "also the coarser: a postcode covers a whole area, so you never"
    note "handle an exact position at any point."
    note ""
    note "  1  look it up from a postal code"
    note "  2  type coordinates yourself"
    note "  3  name the place, but keep it off the map"
    printf '\n'
    METHOD="$(ask "  Which" "1")"

    if [ "$METHOD" = 1 ]; then
      note "The lookup sends the postal code -- and nothing else about this"
      note "device -- to api.zippopotam.us. Like any web request it also"
      note "shows that service this Pi's IP address. If you would rather it"
      note "did not, answer 2 and type the numbers in yourself."
      printf '\n'
      LOOK_TRIES=0
      while :; do
        LOOK_TRIES=$((LOOK_TRIES+1))
        if [ "$LOOK_TRIES" -gt 5 ]; then METHOD=2; break; fi
        CC="$(ask "  Country code (us, gb, ca, de ...)" "us")"
        PC="$(ask "  Postal code" "")"
        [ -z "$PC" ] && { METHOD=2; break; }
        # Spaces are legal in plenty of postcodes and illegal in a URL path.
        if ! lookup_postcode "$CC" "$PC"; then
          printf '  %sNo match for "%s" in %s.%s\n' "$Y" "$PC" "$CC" "$X"
          note "A wrong country code is the usual reason. Blank to type"
          note "coordinates instead."
          continue
        fi
        printf '\n'
        ok "$FOUND_NAME  ->  $FOUND_LAT, $FOUND_LON"
        note "Rounded to one decimal here, before anything is sent."
        printf '\n'
        if ask_yn "  Use this?" "y"; then
          STATED_LOCATION="${STATED_LOCATION:-$FOUND_NAME}"
          STATED_LAT="$FOUND_LAT"; STATED_LON="$FOUND_LON"
          break
        fi
      done
    fi

    if [ "$METHOD" = 2 ]; then
      STATED_LOCATION="$(ask "  Town, region or country" "$STATED_LOCATION")"
      note "One decimal is plenty; anything finer is discarded on arrival."
      while :; do
        STATED_LAT="$(ask "  Latitude  (-90 to 90, blank to skip)" "")"
        [ -z "$STATED_LAT" ] && break
        if awk -v v="$STATED_LAT" 'BEGIN{exit !(v+0==v && v>=-90 && v<=90)}' 2>/dev/null; then break; fi
        printf '  %sOut of range or not a number. Refused rather than rounded, so a\n' "$Y"
        printf '  typo cannot put the device somewhere nobody chose.%s\n' "$X"
      done
      if [ -n "$STATED_LAT" ]; then
        while :; do
          STATED_LON="$(ask "  Longitude (-180 to 180)" "")"
          [ -z "$STATED_LON" ] && break
          if awk -v v="$STATED_LON" 'BEGIN{exit !(v+0==v && v>=-180 && v<=180)}' 2>/dev/null; then break; fi
          printf '  %sOut of range or not a number.%s\n' "$Y" "$X"
        done
      fi
    fi

    if [ "$METHOD" = 3 ]; then
      STATED_LOCATION="$(ask "  Town, region or country" "")"
      note "No coordinates, so it will be named in the device list but will"
      note "not appear on the map."
    fi

    if [ -n "$STATED_LAT" ] && [ -n "$STATED_LON" ]; then
      printf '\n'
      note "How wide the claim is. 25 km is a sensible default and suits a"
      note "postcode centroid; the grid will not accept anything under 11 km."
      STATED_RADIUS="$(ask "  Radius in km" "25")"
    fi
  fi
fi

save_state

# =============================================================================
head_ "4. Docker"
# =============================================================================
# Docker used to be a question here, and the honest answer for most people was
# no. It is not optional any more: the XL1 node runs in a container, and step 10
# installs it.
#
# Anchoring needs a SECOND container -- the anchor service -- which this wizard
# does not install yet. So a device set up by it today produces and reports but
# does not anchor, and cannot witness anybody until that piece lands. Docker
# being here is what makes that a follow-up rather than a rebuild.
WITH_DOCKER=1
if have docker; then
  ok "Docker is already installed"
else
  note "Docker is required. The XL1 node -- the software that takes part in"
  note "the chain itself -- runs in a container, and this wizard installs it."
  note ""
  note "Anchoring, which is what makes a reading checkable by anyone later,"
  note "needs a second container that is not part of this wizard yet."
fi

save_state

# =============================================================================
head_ "5. Joining your private network  (required)"
# =============================================================================
if have tailscale && tailscale status >/dev/null 2>&1; then
  ok "already on a tailnet as $(tailscale ip -4 2>/dev/null | head -1)"
  TS_DONE=1
else
  TS_DONE=0
  note "Every device on the grid is reachable over Tailscale, so this part is"
  note "required rather than offered. Two concrete reasons:"
  note ""
  note "  Devices on different home networks cannot see each other. A device"
  note "  on 192.168.1.x cannot reach one on 192.168.2.x, which is exactly"
  note "  the case where one wants to anchor through another's service."
  note ""
  note "  A headless Pi in a cupboard is otherwise reachable only from its"
  note "  own network, and only until its address changes."
  note ""
  note "It is a private network between your own machines. It opens no ports"
  note "on your router and puts nothing on the public internet."
  printf '\n'

  if [ -n "$TS_KEY" ]; then
    ok "an auth key was supplied; no browser step needed"
  else
    printf '  %sWhat you need first: a free Tailscale account.%s\n\n' "$B" "$X"
    printf '    If you do not have one, open this on your phone or laptop:\n'
    printf '      %shttps://login.tailscale.com/start%s\n\n' "$C" "$X"
    printf '    Sign in with Google, Microsoft, GitHub or Apple. No card, and\n'
    printf '    the personal plan covers 100 devices.\n\n'
    if [ "$TTY_OK" = 1 ] && [ "$ASSUME_YES" != 1 ]; then
      ask "  Press Enter once you have an account ready" "ok" >/dev/null
    fi
  fi
fi

save_state

# =============================================================================
head_ "6. What will happen"
# =============================================================================
NEED_APT=""
have python3 || NEED_APT="$NEED_APT python3"
have curl    || NEED_APT="$NEED_APT curl"
[ "$WITH_DOCKER" = 1 ] && ! have docker && NEED_APT="$NEED_APT docker.io"

printf '  %-14s %s\n' "device"  "$NODE_ID"
printf '  %-14s %s\n' "label"   "$NODE_LABEL"
if [ -n "$STATED_LAT" ] && [ -n "$STATED_LON" ]; then
  printf '  %-14s %s  (%s, %s within ~%s km)\n' "location" \
         "${STATED_LOCATION:-unnamed}" "$STATED_LAT" "$STATED_LON" "$STATED_RADIUS"
elif [ -n "$STATED_LOCATION" ]; then
  printf '  %-14s %s  (no coordinates -- named but not on the map)\n' "location" "$STATED_LOCATION"
else
  printf '  %-14s %s\n' "location" "none -- will not appear on the map"
fi
printf '  %-14s %s\n' "grid"    "$BACKEND_URL"
printf '  %-14s %s\n' "apt"     "${NEED_APT:-nothing to install}"
printf '  %-14s %s\n' "docker"  "$( [ "$WITH_DOCKER" = 1 ] && echo yes || echo no )"
printf '  %-14s %s\n' "tailscale" "$( [ "${TS_DONE:-0}" = 1 ] && echo "already joined" || echo "will join (required)" )"
printf '  %-14s %s\n' "agent"   "${AGENT_FROM:-$PUBLIC_REPO}"
printf '  %-14s %s\n' "installs" "/opt/xl1-heartbeat, running as user xl1agent"
printf '  %-14s %s\n' "producer" "XL1 $XL1_NET producer, built here (this takes a while)"

if [ "$CHECK_ONLY" = 1 ]; then
  printf '\n%sCheck only -- nothing was changed.%s\n' "$G" "$X"
  exit 0
fi
if [ "$ASSUME_YES" != 1 ]; then
  printf '\n'
  ask_yn "  Go ahead?" "y" || { printf '\nNothing was changed.\n'; exit 0; }
fi

# =============================================================================
head_ "7. Installing"
# =============================================================================
if [ -n "$NEED_APT" ]; then
  sudo apt-get update -qq || die "apt-get update failed"
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq $NEED_APT || die "apt-get install failed"
  ok "installed:$NEED_APT"
else
  ok "nothing to install"
fi
DONE_PREREQS=1; save_state

if [ "$WITH_DOCKER" = 1 ] && getent group docker >/dev/null 2>&1; then
  sudo usermod -aG docker "$(id -un)"
  ok "added $(id -un) to the docker group"
  warn "log out and back in before Docker works for this user" \
       "group membership is applied at login"
fi

# Required, so a failure here stops the run. Nothing of the agent has been
# installed at this point, which is the reason this sits before it: giving up
# now leaves a machine exactly as it was found rather than half provisioned.
if [ "$TS_DONE" != 1 ]; then
  if ! have tailscale; then
    printf '\n  %s[5.1]%s Installing the Tailscale package.\n' "$B" "$X"
    note "From Tailscale's own apt repository, so it is signed and updated"
    note "by apt like everything else on this machine."
    if install_tailscale; then
      ok "installed ($(tailscale version 2>/dev/null | head -1))"
    else
      die "Tailscale would not install. Check the network and run this again -- nothing else has been changed."
    fi
  fi

  # A node id may contain dots, underscores and capitals; a Tailscale name is
  # a DNS label and may not. Sanitising here means the machine appears in the
  # tailnet under a name close to its grid id instead of whatever Tailscale
  # would have silently rewritten it to.
  TS_HOST="$(printf '%s' "$NODE_ID" \
    | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//' | cut -c1-63)"
  [ -n "$TS_HOST" ] || TS_HOST="xl1-node"

  printf '\n  %s[5.2]%s Signing this Pi in to your tailnet.\n' "$B" "$X"
  [ "$TS_HOST" = "$NODE_ID" ] || note "On the tailnet it will be called \"$TS_HOST\" -- Tailscale names are DNS names, so capitals and underscores cannot survive."
  if [ -n "$TS_KEY" ]; then
    # Through a file, not the command line: an --auth-key argument is visible
    # in ps to every user on the machine for as long as the command runs.
    kf="$(mktemp)"; chmod 600 "$kf"; printf '%s' "$TS_KEY" > "$kf"
    sudo tailscale up --auth-key="file:$kf" --hostname="$TS_HOST" >/dev/null 2>&1
    ts_rc=$?; rm -f "$kf"
    [ "$ts_rc" -eq 0 ] || die "that auth key was refused. Generate another at https://login.tailscale.com/admin/settings/keys"
  else
    note "A link will appear just below. Open it on your phone or laptop,"
    note "sign in, and approve this machine. Setup continues on its own the"
    note "moment you do -- nothing else is needed here."
    printf '\n'
    if [ "$TTY_OK" = 1 ]; then
      sudo tailscale up --hostname="$TS_HOST" < /dev/tty > /dev/tty 2>&1 \
        || die "sign-in did not complete. Run 'sudo tailscale up' and then start this again."
    else
      sudo tailscale up --hostname="$TS_HOST" \
        || die "sign-in did not complete. Run 'sudo tailscale up' and then start this again."
    fi
  fi

  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$TS_IP" ] || die "Tailscale reports no address. Run 'tailscale status' to see why."
  printf '\n'
  ok "this Pi is on your tailnet as $TS_IP"
  note "Reachable from any of your other Tailscale machines at that address,"
  note "from anywhere, with no ports opened on your router."
fi
DONE_TAILSCALE=1; save_state

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ -n "$AGENT_FROM" ]; then
  [ -f "$AGENT_FROM" ] || die "no such file: $AGENT_FROM"
  cp "$AGENT_FROM" "$WORK/xl1_heartbeat.py"
  svc="$(dirname "$AGENT_FROM")/xl1-heartbeat.service"
  [ -f "$svc" ] && cp "$svc" "$WORK/xl1-heartbeat.service"
  ok "agent copied from $AGENT_FROM"
else
  curl -fsSL --max-time 60 "$PUBLIC_REPO/xl1_heartbeat.py"      -o "$WORK/xl1_heartbeat.py" \
    || die "could not download the agent"
  curl -fsSL --max-time 60 "$PUBLIC_REPO/xl1-heartbeat.service" -o "$WORK/xl1-heartbeat.service" \
    || die "could not download the service unit"
  ok "agent $(grep -m1 '^AGENT_VERSION' "$WORK/xl1_heartbeat.py" | cut -d'"' -f2) downloaded"
fi

# It is about to run as a service. Parsing it catches a truncated or
# half-served download here rather than in systemd's logs.
if [ -n "$PY" ]; then
  "$PY" -m py_compile "$WORK/xl1_heartbeat.py" 2>/dev/null \
    && ok "the agent parses" \
    || die "the downloaded agent does not parse -- a truncated download? Run this again."
else
  warn "no working python found to check the download with" \
       "the agent needs one to run at all; the checks in the next step will say so"
fi

id xl1agent >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin xl1agent
getent group docker >/dev/null 2>&1 && sudo usermod -aG docker xl1agent
sudo mkdir -p /opt/xl1-heartbeat
sudo cp "$WORK/xl1_heartbeat.py" /opt/xl1-heartbeat/
[ -f "$WORK/xl1-heartbeat.service" ] && sudo cp "$WORK/xl1-heartbeat.service" /etc/systemd/system/
ok "installed to /opt/xl1-heartbeat"
DONE_AGENT=1; save_state

# =============================================================================
head_ "8. Its credential"
# =============================================================================
TOKEN="${NODE_HEARTBEAT_TOKEN:-}"

# A device already set up on this machine has its credential in the agent's
# env, and there is no way to get another copy: the portal shows a token once.
# Without this, re-running the wizard on a working device -- which is exactly
# what adding the producer and anchoring asks every existing operator to do --
# demanded a token they cannot read back, and the only way through was to
# revoke and re-issue a credential that was working perfectly.
#
# Only when the id matches what is installed. Reading it for a DIFFERENT device
# would hand one device's credential to another.
if [ -z "$TOKEN" ] && [ -n "${INSTALLED_ID:-}" ] && [ "$NODE_ID" = "$INSTALLED_ID" ]; then
  # sudo is warm by now -- step 7 ran apt through it -- so -n normally answers.
  # Falling back the same way step 1 does rather than failing on a cold cache.
  TOKEN="$(sudo -n sed -n 's/^NODE_HEARTBEAT_TOKEN=//p' /etc/xl1-heartbeat.env 2>/dev/null | head -1)"
  [ -z "$TOKEN" ] && TOKEN="$(sudo sed -n 's/^NODE_HEARTBEAT_TOKEN=//p' /etc/xl1-heartbeat.env 2>/dev/null | head -1)"
  [ -n "$TOKEN" ] && ok "using the credential already on this machine"
fi

if [ -z "$TOKEN" ]; then
  printf '  Register %s%s%s in your account:\n\n' "$B" "$NODE_ID" "$X"
  printf '     %s%s%s\n\n' "$C" "$ACCOUNT_URL" "$X"
  printf '  Open that on any device. It asks you to sign in and offers to make\n'
  printf '  an account if you have not got one. That account owns this device\n'
  printf '  afterwards, so you can rename, revoke or re-issue it yourself.\n'
  printf '  Add %s%s%s there and it shows a token once.\n' "$B" "$NODE_ID" "$X"
  printf '  Copy it before closing the page -- it cannot be read back, and a\n'
  printf '  lost one is replaced by revoking and minting another.\n\n'
  printf '  %sNothing is typed back to you as you paste.%s That is deliberate:\n' "$D" "$X"
  printf '  %sa credential should not sit in your scrollback.%s\n\n' "$D" "$X"

  # There is no blank answer here. The device cannot report without a
  # credential, so accepting an empty one would only mean failing later and
  # less clearly. Leaving is still free -- Ctrl+C keeps every answer and this
  # picks up here on the next run.
  printf '  %sNo token yet? Ctrl+C. Everything you have answered is saved and\n' "$D"
  printf '  this resumes at exactly this point.%s\n\n' "$X"

  TOK_TRIES=0
  while [ -z "$TOKEN" ]; do
    TOK_TRIES=$((TOK_TRIES+1))
    if [ "$TOK_TRIES" -gt 6 ]; then
      printf '\n  %sLeaving it there for now.%s Your answers are saved; run the same\n' "$Y" "$X"
      printf '  command again once you have the token.\n'
      exit 1
    fi
    [ "$TTY_OK" = 1 ] || die "no terminal to read the token from; pass NODE_HEARTBEAT_TOKEN=... instead"
    TOKEN="$(ask_secret "  Paste the token")"
    if [ -z "$TOKEN" ]; then
      printf '  %sA token is required -- the device cannot report without one.%s\n' "$Y" "$X"
      continue
    fi
    # Shape only, never the value. A half-selected paste is the likely mistake
    # and it would otherwise surface as a 401 several steps later.
    case "$TOKEN" in
      *[!A-Za-z0-9_-]*)
        printf '  %sThat contains characters a token does not. Did a stray space\n' "$Y"
        printf '  or a line break come with it?%s\n' "$X"; TOKEN="" ;;
      *) if [ "${#TOKEN}" -lt 20 ]; then
           printf '  %sThat is only %s characters; these are around 43. Looks like\n' "$Y" "${#TOKEN}"
           printf '  only part of it was copied.%s\n' "$X"; TOKEN=""
         fi ;;
    esac
  done
  ok "token accepted (${#TOKEN} characters)"
fi

# =============================================================================
head_ "9. Checking, then starting the agent"
# =============================================================================
# onboard.sh does the eligibility checks and the install. Fetched the same way
# this script was when there is no copy alongside -- piped into bash there is
# no adjacent file to find, because $0 is "bash".
CHECKER="$(dirname "$0")/onboard.sh"
if [ ! -f "$CHECKER" ]; then
  CHECKER="$WORK/onboard.sh"
  curl -fsSL --max-time 60 "$PUBLIC_REPO/onboard.sh" -o "$CHECKER" 2>/dev/null \
    || die "could not download onboard.sh"
fi

# Docker installed this run cannot answer this session -- the group was added
# after login. Checking it here would fail a machine that is fine, so the
# checks are skipped and the reason said out loud.
extra=""
if [ "$WITH_DOCKER" != 1 ]; then
  extra="--skip-docker"
elif ! docker info >/dev/null 2>&1; then
  extra="--skip-docker"
  warn "Docker will not answer until you log out and back in" \
       "expected when it was just installed: this session still has the groups it started with. Skipping its checks; the agent picks the node up once you have logged back in."
fi
# The token travels in the environment, never as an argument: arguments are
# visible in ps to every user on the machine.
# shellcheck disable=SC2086
NODE_HEARTBEAT_TOKEN="$TOKEN" \
NODE_LABEL="$NODE_LABEL" \
XL1_STATED_LOCATION="$STATED_LOCATION" \
XL1_STATED_LAT="$STATED_LAT" \
XL1_STATED_LON="$STATED_LON" \
XL1_STATED_RADIUS_KM="$STATED_RADIUS" \
bash "$CHECKER" --node-id "$NODE_ID" --backend "$BACKEND_URL" --account "$ACCOUNT_URL" \
     $extra --install
rc=$?

if [ "$rc" -ne 0 ]; then
  printf '\n  %sThat did not finish.%s Your answers are saved -- run the same\n' "$Y" "$X"
  printf '  command again and it will resume.\n'
  exit "$rc"
fi
DONE_AGENT=1
save_state

# =============================================================================
head_ "10. The XL1 block producer  (required)"
# =============================================================================
# Everything above puts a device on the grid. This is the part that puts it on
# the CHAIN, and it is required for a reason worth stating plainly: a device
# that does not run this cannot anchor, and a device that cannot anchor is a
# machine making claims about itself that nobody can check afterwards.
#
# Built here rather than pulled: the images repo publishes no registry tags yet.
# Every docker call below goes through sudo, NOT the docker group -- if Docker
# was installed a few minutes ago this session still has the groups it started
# with, and `docker` would fail for a machine that is completely fine.
SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"

# A running producer is the answer, on its own.
#
# This used to read `DONE_PRODUCER = 1 AND the container is running`, which
# looks like belt and braces and is not: the flag lives in a state file in the
# invoking user's home, so on any device set up before the wizard kept state,
# under another user, or under sudo, it is absent -- and the live check could
# not rescue it, because AND needs both. The else branch below does
# `docker rm -f xl1-producer` and builds a fresh one, so a re-run on those
# machines destroyed and recreated a block producer that was working, with
# nothing on screen saying it was about to.
#
# The container being up IS the evidence that this step has been done. The
# flag never added anything the check could not establish, and it subtracted
# on exactly the machines that had been running longest.
if $SUDO docker ps --filter name=xl1-producer \
     --format '{{.Names}}' 2>/dev/null | grep -q xl1-producer; then
  ok "the producer is already running here"
  # Adopt it, so the state file agrees from now on.
  if [ "${DONE_PRODUCER:-0}" != 1 ]; then
    DONE_PRODUCER=1
    save_state
  fi
else

case "$ARCH" in
  aarch64|arm64|x86_64) : ;;
  *) die "XL1 node images are published for arm64 and x86_64 only; this is $ARCH.
     Reflash with the 64-bit Raspberry Pi OS and run this again." ;;
esac

# Firewall first, because it is the only part of this that can lock you out of
# your own machine, and doing it before anything is running means a mistake
# costs nothing. Order matters: SSH is allowed BEFORE the default-deny takes
# effect, or an operator working over SSH loses the session that is running
# this. --force because `ufw enable` otherwise asks a question nothing here can
# answer.
#
# 30303 is NOT opened, and that is a change from XYO's published steps.
#
# Measured on the reference node rather than reasoned about: a producer with
# 1211 blocks to its name publishes no ports at all (PortBindings is empty),
# nothing on the machine listens on 30303, and it had signed a block six before
# the current head when this was checked. A federated producer submits through
# the JsonRpc mempool; it does not gossip, and it does not accept inbound
# connections -- which is the same property the whole grid depends on.
#
# So the rule opened a port to nothing. Small, but a firewall whose rules do not
# match what listens is a firewall nobody can reason about later. If a role that
# does peer ever lands here, open it then, with something behind it.
if have ufw; then
  say "setting up the firewall"
  $SUDO ufw allow ssh >/dev/null 2>&1 || true
  # Tailscale is required by step 5 and its traffic arrives on its own
  # interface. Default-deny would otherwise make the tailnet address
  # unreachable, which is the one route you would use to fix a firewall.
  $SUDO ufw allow in on tailscale0 >/dev/null 2>&1 || true
  $SUDO ufw default deny incoming >/dev/null 2>&1 || true
  $SUDO ufw default allow outgoing >/dev/null 2>&1 || true
  $SUDO ufw --force enable >/dev/null 2>&1 \
    && ok "firewall on: ssh and tailscale in, everything else outbound only" \
    || warn "could not enable the firewall" "not fatal -- the node runs either way; see: sudo ufw status"
else
  note "ufw is not installed, so no firewall rules were set. The node runs"
  note "either way; XYO's published steps use ufw if you want to add it later."
fi
# Raspberry Pi OS ships /usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf
# setting Storage=volatile, to spare the SD card. The effect is invisible until
# it matters: /var/log/journal exists and stays empty, journald writes to
# /run/log/journal, and every log dies at reboot -- so the crash you most want
# to read has already erased itself, and it reads as journald being
# misconfigured rather than deliberately overridden.
#
# The name must sort AFTER 40-. Drop-ins merge by filename across directories
# and the last name wins, so a 10- file is silently beaten by the vendor's.
#
# The caps keep the vendor's concern honest rather than pretending it was
# wrong: a bounded journal, not an unbounded one.
JOURNAL_CONF=/etc/systemd/journald.conf.d/99-xl1-persistent.conf
if [ ! -f "$JOURNAL_CONF" ]; then
  say "keeping logs across reboots"
  $SUDO mkdir -p /etc/systemd/journald.conf.d
  tmp_j="$(mktemp)"
  chmod 644 "$tmp_j"
  {
    printf '# Explorer Grid: keep the journal across reboots, bounded.\n'
    printf '# Must sort after 40-rpi-volatile-storage.conf, which sets Storage=volatile.\n'
    printf '[Journal]\n'
    printf 'Storage=persistent\n'
    printf 'SystemMaxUse=200M\n'
    printf 'SystemMaxFileSize=20M\n'
    printf 'SystemKeepFree=500M\n'
    printf 'MaxRetentionSec=2week\n'
  } > "$tmp_j"
  $SUDO install -o root -g root -m 644 "$tmp_j" "$JOURNAL_CONF"
  rm -f "$tmp_j"
  $SUDO systemctl restart systemd-journald 2>/dev/null || true
  ok "logs now survive a reboot (capped at 200M, kept two weeks)"
else
  ok "logs already survive a reboot"
fi
# --- giving the board back what it is not using ------------------------------
# A headless node has no use for 48 MB of GPU memory, and on a 905 MB board that
# is 5% of everything there is. Raspberry Pi only: the config file is the tell,
# and its absence means this is not a Pi and there is nothing to reclaim.
#
# Backed up first. This file decides whether the board boots at all, and an
# unbootable Pi is a card reader and a trip to wherever it is mounted.
BOOT_CONFIG=/boot/firmware/config.txt
[ -f "$BOOT_CONFIG" ] || BOOT_CONFIG=/boot/config.txt
if [ -f "$BOOT_CONFIG" ]; then
  if grep -qE '^[[:space:]]*gpu_mem=16[[:space:]]*$' "$BOOT_CONFIG" 2>/dev/null; then
    ok "gpu_mem is already 16M"
  else
    $SUDO cp -n "$BOOT_CONFIG" "$BOOT_CONFIG.bak-xl1" 2>/dev/null || true
    # Delete then append, rather than edit in place: a config.txt with two
    # gpu_mem lines takes the last, so editing the first changes nothing
    # visible and costs an afternoon.
    $SUDO sed -i -E '/^[[:space:]]*gpu_mem=/d' "$BOOT_CONFIG" 2>/dev/null || true
    printf '\n# Explorer Grid: headless node, GPU memory returned to the system\ngpu_mem=16\n' \
      | $SUDO tee -a "$BOOT_CONFIG" >/dev/null
    ok "gpu_mem=16 written to $BOOT_CONFIG -- about 48 MB back on the next boot"
  fi
fi

# The stock governor idles the CPU down between blocks. Whether a Pi 3 keeps up
# is the open question about this hardware, and this is the one setting that
# speaks to it directly.
#
# Skipped where there is no cpufreq at all, which is most virtual machines: a
# governor cannot be set on a CPU whose speed the kernel does not control.
CPUFREQ=/sys/devices/system/cpu/cpu0/cpufreq
if [ -r "$CPUFREQ/scaling_available_governors" ] \
   && grep -qw performance "$CPUFREQ/scaling_available_governors" 2>/dev/null; then
  for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [ -w "$c" ] || [ -e "$c" ] || continue
    printf 'performance' | $SUDO tee "$c" >/dev/null 2>&1 || true
  done
  # Applied again at boot: the governor is not persistent, and a node that runs
  # fast until its first reboot and slowly afterwards is the kind of difference
  # nobody connects back to this.
  if [ ! -f /etc/systemd/system/xl1-cpu-governor.service ]; then
    tmp_g="$(mktemp)"
    chmod 644 "$tmp_g"
    {
      printf '[Unit]\n'
      printf 'Description=Pin the CPU governor to performance for the XL1 node\n'
      printf 'After=multi-user.target\n\n'
      printf '[Service]\n'
      printf 'Type=oneshot\n'
      printf 'RemainAfterExit=yes\n'
      # \$c, escaped. Unescaped it expands HERE, in this shell, and bakes in
      # whichever core the loop above finished on -- so the unit would set one
      # CPU at boot and look entirely correct doing it. The loop has to reach
      # systemd as text.
      printf "ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo performance > \"\$c\" 2>/dev/null || true; done'\n\n"
      printf '[Install]\n'
      printf 'WantedBy=multi-user.target\n'
    } > "$tmp_g"
    $SUDO install -o root -g root -m 644 "$tmp_g" /etc/systemd/system/xl1-cpu-governor.service
    rm -f "$tmp_g"
    $SUDO systemctl daemon-reload 2>/dev/null || true
    $SUDO systemctl enable --now xl1-cpu-governor.service >/dev/null 2>&1 || true
  fi
  ok "CPU governor set to performance, and pinned there across reboots"
else
  say "no cpufreq here, so the CPU governor is left alone"
fi

printf '\n'

note "This runs the XL1 producer: the software that takes part in the chain"
note "itself, proposing blocks and earning the rewards for them."
note ""
# Said BEFORE the phrase is asked for and before twenty minutes of building,
# because it is the one thing that makes a healthy-looking node worthless and
# nothing in the logs will tell you. `Published block:` means "candidate
# submitted", never "accepted".
warn "Your address has to be on the network's producer list first" \
     "until it is, the node runs perfectly, submits candidates, and has every one ignored. It looks identical to a working producer. Ask to be added before you count on rewards."
note ""
note "You need a wallet phrase. It is the node's identity on the chain and it"
note "is the only thing here that is genuinely irreplaceable -- lose it and you"
note "lose the identity, and anyone who copies it can produce as you."
note ""
note "Generate it in a wallet you already back up (the XYO extension or"
note "MetaMask both work -- XL1 uses the same derivation), then paste it here."
note "It is written to $PRODUCER_ENV, readable by root only, and is never"
note "sent anywhere, never logged, and never saved with your other answers."
printf '\n'

MNEMONIC=""
tries=0
while [ -z "$MNEMONIC" ] && [ "$tries" -lt 5 ]; do
  tries=$((tries + 1))
  MNEMONIC="$(ask_secret "  Wallet phrase (hidden as you type)")"
  words="$(printf '%s' "$MNEMONIC" | tr -s "[:space:]" " " | tr -d "\r" | wc -w | tr -d " ")"
  case "$words" in
    12|15|18|21|24) : ;;
    *) printf '  %sThat is %s words.%s A BIP39 phrase is 12, 15, 18, 21 or 24.\n' \
              "$Y" "${words:-0}" "$X"; MNEMONIC="" ;;
  esac
  # Shape only. A full checksum needs the 2048-word list, and a wrong phrase
  # fails visibly at startup anyway -- this catches the typo, not the forgery.
  if [ -n "$MNEMONIC" ] && printf '%s' "$MNEMONIC" | grep -qv "^[a-z ]*$"; then
    printf '  %sThat contains something other than lowercase words.%s\n' "$Y" "$X"
    MNEMONIC=""
  fi
done
[ -n "$MNEMONIC" ] || die "no wallet phrase given. Nothing was changed; run this again when you have one."

REWARD_ADDRESS="${REWARD_ADDRESS:-}"
tries=0
while [ -z "$REWARD_ADDRESS" ] && [ "$tries" -lt 5 ]; do
  tries=$((tries + 1))
  note "Where block rewards are paid. Usually that wallet's own address."
  REWARD_ADDRESS="$(ask "  Reward address (0x...)" "")"
  if ! printf '%s' "$REWARD_ADDRESS" | grep -qE "^0x[0-9a-fA-F]{40}$"; then
    printf '  %sThat is not an address.%s It is 0x followed by 40 hex characters.\n' "$Y" "$X"
    REWARD_ADDRESS=""
  fi
done
[ -n "$REWARD_ADDRESS" ] || die "no reward address given. Nothing was changed."
save_state

# --- the images repo ---------------------------------------------------------
if [ -d "$IMAGES_REPO/.git" ]; then
  say "updating $IMAGES_REPO"
  # Scoped to this path rather than root's global config: the checkout belongs
  # to the operator and this runs as root, which git refuses as dubious
  # ownership. The exception stays on the one directory that needs it.
  $SUDO git -C "$IMAGES_REPO" -c "safe.directory=$IMAGES_REPO" fetch --quiet origin \
    || warn "could not fetch the images repo" "building what is already there"
  $SUDO git -C "$IMAGES_REPO" -c "safe.directory=$IMAGES_REPO" merge --ff-only --quiet '@{u}' 2>/dev/null || true
else
  say "cloning the XL1 images repo into $IMAGES_REPO"
  $SUDO git clone --quiet "$IMAGES_URL" "$IMAGES_REPO" \
    || die "could not clone $IMAGES_URL"
fi

# From the published steps. Unused by the federated producer preset, which
# keeps no local store, but the repo's own instructions make them and an empty
# directory costs nothing next to guessing which roles need one.
$SUDO mkdir -p "$IMAGES_REPO/data" "$IMAGES_REPO/config" "$IMAGES_REPO/keystore"

CLI_VERSION="$(curl -fsSL --max-time 30 "$CLI_REGISTRY" 2>/dev/null \
  | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$CLI_VERSION" ] || die "could not read the current xl1-cli version from npm"
ok "building xl1:$CLI_VERSION"

# The Dockerfile does `COPY dist/node`, and dist/ is NOT in the repository.
# Upstream's build-image.sh compiles it first with `pnpm xy compile`, which a
# plain docker build skips -- so a fresh clone fails at that COPY. It worked on
# the reference Pi 4 only because that checkout had been compiled by hand once,
# years of weekly rebuilds inheriting the result.
#
# Compiled in a container rather than on the host. Doing it on the host means
# Node 24 and the whole xy toolchain installed on a Raspberry Pi, to build
# something that then runs in a container anyway.
if [ ! -f "$IMAGES_REPO/dist/node/entrypoint.mjs" ]; then
  say "compiling the image entrypoint"
  printf '  A few minutes, and it is downloading a toolchain the first time.\n\n'
  $SUDO docker run --rm -v "$IMAGES_REPO":/w -w /w "node:$NODE_VERSION-bookworm-slim" \
    sh -c 'corepack enable && pnpm install --frozen-lockfile && pnpm xy compile' \
    || die "could not compile the image entrypoint. Nothing was started; the agent is unaffected."
  # Checked rather than assumed: a compile that exits 0 and writes nothing
  # would otherwise fail later at the COPY, which reads as a Docker problem.
  [ -f "$IMAGES_REPO/dist/node/entrypoint.mjs" ] \
    || die "the compile finished but produced no entrypoint at dist/node"
  ok "entrypoint compiled"
fi

printf '\n  %sThis is the long part.%s Ten to twenty minutes on a Pi 4, longer on a\n' "$Y" "$X"
printf '  Pi 3. It is compiling, not hung. Leave it be.\n\n'
# Upstream's own build script rather than a hand-rolled docker build, so build
# arguments it grows later arrive here for free. It compiles first when dist is
# missing -- which by now it is not, so the pnpm it would reach for on the host
# is never needed.
# `env` and not a bare VAR=... prefix: with sudo in front, a prefix is consumed
# by the shell and never crosses into the sudo environment. And `$SUDO -E`
# would expand to `-E bash` when this runs as root, where SUDO is empty --
# which is not a command.
$SUDO env XL1_CLI_VERSION="$CLI_VERSION" TAG="xl1:$CLI_VERSION" \
  bash "$IMAGES_REPO/scripts/build-image.sh" \
  || die "the image did not build. Nothing was started; the agent is unaffected."
# Tagged by version AND as local. The version tag is what the weekly rebuild
# compares against; xl1:local is what the container actually runs, so promoting
# a new build later is a retag rather than a reconfiguration.
$SUDO docker tag "xl1:$CLI_VERSION" xl1:local
ok "built xl1:$CLI_VERSION"

# From the published steps, and worth the seconds: it proves the binary in the
# image runs at all. Without it the first evidence of a broken image is a
# producer that will not stay up, which reads as a configuration problem.
# -f, not -x: it is invoked through bash either way, and testing the exec bit
# would silently skip the check on any clone that did not preserve it.
if [ -f "$IMAGES_REPO/scripts/smoke-run.sh" ]; then
  if $SUDO bash "$IMAGES_REPO/scripts/smoke-run.sh" >/dev/null 2>&1; then
    ok "the image runs"
  else
    die "the image built but does not run. Nothing was started; the agent is unaffected."
  fi
fi

# --- the secret --------------------------------------------------------------
# Written through a 0600 temp file and installed as root. Never passed as
# `docker -e`, which would put a wallet phrase in `ps` for every user on the
# machine, and never echoed back.
# chmod, not umask. `umask 077` used to sit here and was never restored, so it
# leaked into everything that followed -- and sudo takes the UNION of the
# caller's umask and its own, so every later `sudo mkdir` produced a 0700
# root-owned directory. That is what emptied /opt/xl1-node-monitor: the files
# were extracted correctly and this unprivileged shell simply could not see
# into the directory holding them.
#
# The file is empty between mktemp and chmod, so nothing is exposed in the gap.
# Same shape as the Tailscale key handling further up.
tmp_env="$(mktemp)"
chmod 600 "$tmp_env"
{
  printf '# XL1 block producer. Root-only: this file contains a wallet phrase.\n'
  printf 'XL1_NETWORK=%s\n' "$XL1_NET"
  printf 'XL1_ROLE=producer\n'
  printf 'XL1_MNEMONIC=%s\n' "$MNEMONIC"
  printf 'XL1_REWARD_ADDRESS=%s\n' "$REWARD_ADDRESS"
} > "$tmp_env"
$SUDO install -o root -g root -m 600 "$tmp_env" "$PRODUCER_ENV"
rm -f "$tmp_env"
MNEMONIC=""
ok "wrote $PRODUCER_ENV (root only)"

# --- start it ----------------------------------------------------------------
# Node picks its default heap ceiling from TOTAL system memory -- and inside the
# container it sees the HOST's, because stock Raspberry Pi OS ships without the
# memory cgroup controller, so `docker --memory` is accepted and discarded.
# Measured: 32 GB of RAM gives a 4288 MB default. It scales with memory and tops
# out around 4 GB.
#
# Which means the cap does the MOST work on a big board and the least on a small
# one -- the opposite of the intuition. A 4 GB Pi 4 defaults to roughly 4 GB of
# heap for a producer measured at ~287 MB resident, sharing the machine with the
# anchor service and the agent. A 905 MB Pi 3 already defaults to about 450, so
# a flat 512 there was ABOVE the default: it loosened the ceiling on the one
# board it was meant to protect.
#
# Derived from what is left after everything else rather than from the board,
# because the board does not tell you the memory: a Pi 4 ships with 1, 2, 4 or
# 8 GB and a Pi 5 with 4, 8 or 16. RAM is readable and exact; the model is not
# a proxy for it.
#
# 320 MB reserved: the OS, the anchor service (~80 measured), the agent, and the
# producer's own non-heap memory. 70% of the rest, so a spike has somewhere to
# go before the SD card does. Floor 256 -- below that the producer cannot work
# and a cap is the wrong tool for a board that is too small.
if [ -n "${RAM_MB:-}" ] && [ "$RAM_MB" -gt 576 ]; then
  NODE_HEAP_MB=$(( (RAM_MB - 320) * 7 / 10 ))
else
  NODE_HEAP_MB=256
fi
[ "$NODE_HEAP_MB" -lt 256 ] && NODE_HEAP_MB=256
# The ceiling is 2048, and it was 1024 until the default was measured rather
# than guessed. Node reports a 2090 MB limit on a 3795 MB board -- roughly half
# of RAM, not the ~4 GB assumed here earlier. A 1024 ceiling therefore did not
# trim an over-generous default, it HALVED the working heap of the reference
# producer, which is a much larger intervention than this was ever meant to be.
#
# 2048 sits just under that measured default, so on the boards anyone runs this
# on the cap trims rather than constrains, while still bounding a machine large
# enough for the default to become permission to swap.
#
# Measure again before lowering this. The producer's resident set is ~287 MB,
# but resident is not heap, and nobody has yet watched one work under a cap for
# long enough to know what it actually wants.
[ "$NODE_HEAP_MB" -gt 2048 ] && NODE_HEAP_MB=2048

# Docker's default json-file driver NEVER rotates. A producer logging a line a
# block fills the card over months and then everything stops at once -- the
# node, the agent and the anchor service -- with the logs that would explain it
# being the thing that filled the disk.
$SUDO docker rm -f xl1-producer >/dev/null 2>&1 || true
$SUDO docker run -d --name xl1-producer --restart unless-stopped \
  -e NODE_OPTIONS="--max-old-space-size=$NODE_HEAP_MB" \
  --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
  --env-file "$PRODUCER_ENV" xl1:local >/dev/null \
  || die "the producer would not start. Check: sudo docker logs xl1-producer"
ok "heap capped at ${NODE_HEAP_MB}M, logs rotate at 10M x 3"

sleep 15
if $SUDO docker ps --filter name=xl1-producer --format '{{.Names}}' | grep -q xl1-producer; then
  ok "xl1-producer is running"
else
  printf '\n'
  $SUDO docker logs --tail 20 xl1-producer 2>&1 | sed 's/^/    /'
  die "the producer started and stopped again. The lines above say why -- a wrong phrase shows up here."
fi

DONE_PRODUCER=1
save_state
fi

# =============================================================================
head_ "11. Anchoring  (required)"
# =============================================================================
# Producing blocks puts this machine on the chain. Anchoring is what makes the
# things it says about ITSELF -- temperature, load, uptime -- checkable by a
# stranger afterwards, which is the entire argument the grid rests on. Blocks
# are already public; hardware readings are the machine describing itself, and
# nothing stops a description being edited later.
#
# Three moving parts, and only two of them can be automated:
#
#   the service      a container that hashes a reading and writes the hash to
#                    XL1, bound to loopback so nothing on your network sees it
#   a throwaway key  it anchors hashes and holds a little gas; it controls no
#                    producer, no stake, nothing worth taking
#   one delegation   your producer signs a single statement binding that key to
#                    it, by hand, once -- so a verifier can follow
#                    attestation -> delegation -> producer without the producer
#                    key ever going near a service with an HTTP endpoint
#
# The part that cannot be automated is putting gas in the throwaway key. The
# wizard stops there and waits, and the wait survives closing the terminal.
# Whether this device has finished anchoring, asked of the machine rather than
# of the state file. Both of these are written at the very end of this step,
# after the delegation is on chain, so together they mean it ran to completion.
#
# The state file cannot answer this on its own. It lives in the invoking user's
# home, so it is missing on devices set up before the wizard kept state, under
# another user, or under sudo -- and on those the wizard offered to delegate a
# key that was already delegated, which costs gas and buys nothing. Step 10 has
# always paired its flag with a live docker ps for the same reason; this is
# that, for anchoring.
# The address the node currently signs as, from its own eligibility line.
# Empty when the node has not said -- a staked one stops complaining -- and an
# empty answer must never be read as "changed".
current_producer() {
  $SUDO docker logs --since 60m xl1-producer 2>&1 \
    | grep -oiE 'producer +(0x)?[0-9a-f]{40}' \
    | grep -oiE '[0-9a-f]{40}' | head -1 | tr 'A-Z' 'a-z'
}

anchor_configured() {
  $SUDO test -s "$ANCHOR_ENV" 2>/dev/null || return 1
  $SUDO grep -q '^XL1_ANCHOR_TOKEN=.' "$AGENT_ENV" 2>/dev/null || return 1

  # Both files are present. That says this ran before; it does not say the two
  # still agree with each other.
  #
  # The delegation binds the attestation key to ONE producer address. Give the
  # node a new wallet phrase and it becomes a different producer, while the
  # delegation goes on naming the old one -- so readings are still signed and
  # stored, and the link saying which node made the claim points at an identity
  # that machine no longer has. Nothing fails, which is why it would sit like
  # that indefinitely.
  #
  # Only when BOTH are known. A recorded address with no current one is a
  # staked node that has stopped complaining, not a changed key, and treating
  # silence as a mismatch would re-delegate -- for gas -- on every run.
  delegated="$($SUDO cat "$ANCHOR_PRODUCER_FILE" 2>/dev/null | tr -d ' \r\n')"
  if [ -n "$delegated" ]; then
    running="$(current_producer)"
    if [ -n "$running" ] && [ "$running" != "$delegated" ]; then
      warn "this node signs as a different producer than the delegation names" \
           "delegated for ...${delegated#"${delegated%??????}"}, now signing as ...${running#"${running%??????}"} -- anchoring will be set up again for the current key"
      return 1
    fi
  fi
  return 0
}

if [ "${DONE_ANCHOR:-0}" != 1 ] && anchor_configured; then
  ok "anchoring is already set up on this machine"
  # Adopt it, so the rest of this run and every run after it agree.
  DONE_ANCHOR=1
  save_state
fi

# Re-running this is how a device is upgraded, so what follows has to happen
# every time -- the source is re-fetched, the image rebuilt and the container
# recreated. That is the only way a newer SDK reaches a Pi: it is pinned by
# the lockfile inside the image, so nothing changes until the image does.
#
# What must NOT happen twice is below: generating a key, waiting for gas, and
# putting a delegation on chain. Those cost money and are done once.
if [ "${DONE_ANCHOR:-0}" != 1 ]; then

note "Anchoring writes the hash of each reading to XL1, so anyone can check"
note "later that the reading was not edited. Only the hash goes on chain --"
note "no telemetry is published by it."
note ""
note "It costs gas: about 0.0001186 XL1 per anchor, hourly, so roughly one"
note "XL1 a year. That is measured on Sequence, not estimated."
printf '\n'

fi

# --- the service source ------------------------------------------------------
# Only the files are wanted here, never the history, so this is a tarball
# rather than a clone. A clone on the Pi 3 reported success and left no
# working tree, and there was no way to tell from the failure whether the
# repository, the network or the disk was at fault -- `git clone --quiet`
# says nothing on the way past. curl and tar say what they did.
#
# It is also less to go wrong: no git on PATH, no ownership exception, no
# default-branch assumption, and re-running simply overwrites.
SVC="$MONITOR_REPO/service"
# Fetched EVERY run, not only when it is missing.
#
# This used to be wrapped in `if [ ! -f "$SVC/Dockerfile" ]`, which meant the
# first run decided what the service would be forever. Re-running to pick up a
# fix picked up nothing: the source was already on disk, so the download was
# skipped, the image rebuilt from the same files, and every COPY layer came
# back CACHED. A published fix could not reach a machine that had run this
# before -- which is every machine that hit a problem, which is exactly the
# population the fix was for.
#
# It cost a real evening. An older new-attestor.ts predating --from stayed on
# a Pi through repeated runs; the wizard asked it to read an existing key, the
# old copy did not know the flag, generated a new one instead, and failed
# writing it to a path inside the image. The error pointed at permissions and
# the cause was a file that was never replaced.
#
# A tarball over a slow link is a few seconds. Being unable to ship a fix is
# not worth saving them.
say "fetching the anchor service"
$SUDO mkdir -p "$MONITOR_REPO"
# Stated rather than inherited: the checks below run unprivileged and have to
# be able to read what lands here.
$SUDO chmod 755 "$MONITOR_REPO"
tarball="$(mktemp)"
if curl -fsSL --max-time 120 "$MONITOR_TAR" -o "$tarball"; then
  # --strip-components=1 drops the <repo>-<branch>/ wrapper the archive adds.
  $SUDO tar -xzf "$tarball" -C "$MONITOR_REPO" --strip-components=1 \
    || { rm -f "$tarball"; die "the anchor service archive would not unpack"; }
elif [ -f "$SVC/Dockerfile" ]; then
  # A network blip should not stop a re-run that has everything it needs, but
  # it must say so: from here on this is whatever was downloaded last time,
  # which is the situation the refetch above exists to prevent.
  warn "could not reach $MONITOR_TAR" \
       "continuing with the copy already in $MONITOR_REPO -- it may be older than this script"
else
  rm -f "$tarball"
  die "could not download the anchor service from $MONITOR_TAR"
fi
rm -f "$tarball"

# Said with what is actually there. The previous version failed with only the
# path it had looked at, which is the least useful half of the problem.
if [ ! -f "$SVC/Dockerfile" ]; then
  printf '\n  What arrived in %s instead:\n' "$MONITOR_REPO"
  ls -A "$MONITOR_REPO" 2>/dev/null | head -20 | sed 's/^/    /'
  printf '  Disk: %s\n' "$(df -h "$MONITOR_REPO" 2>/dev/null | awk 'NR==2 {print $4" free of "$2}')"
  die "no Dockerfile at $SVC -- see above"
fi

printf '\n  %sBuilding the anchor service.%s A few minutes.\n\n' "$Y" "$X"
# --build is not optional, here or ever: the Dockerfile COPYs src, so a plain
# `up -d` silently brings the container back on the previous code.
$SUDO docker build --tag xl1-service:local "$SVC" \
  || die "the anchor service did not build. The producer and agent are untouched."
ok "built xl1-service:local"

# --- the service, read-only for now ------------------------------------------
# Started before the key exists and long before any phrase reaches it, because
# /standing is how the wait below sees a balance arrive. With no mnemonic it
# holds no signing key at all and /health says signing:false, which is the
# state it ships in.
$SUDO mkdir -p "$KEYS_DIR" /var/lib/xl1-attestations

# Both of these are mounted into the service, which runs as a non-root uid, so
# root-owned mounts are not writable by it. The key generator fails outright
# with EACCES and says so.
#
# The archive would have failed LATER and quieter: a payload is written there
# the moment an anchor succeeds and before the backend is told, so between
# those two events it is the only copy of what the on-chain hash commits to.
# An unwritable archive is not a broken directory, it is a lost payload.
#
# Asked rather than assumed. The node image happens to use 1000, but reading it
# off the image costs one call and does not go stale.
SVC_UID="$($SUDO docker run --rm --entrypoint id xl1-service:local -u 2>/dev/null | tr -d '\r\n')"
case "$SVC_UID" in ''|*[!0-9]*) SVC_UID=1000 ;; esac
$SUDO chown "$SVC_UID:$SVC_UID" "$KEYS_DIR" /var/lib/xl1-attestations
# The phrase is readable only by that uid; the archive holds published payloads
# and is left readable so verify-attestation.py needs no sudo.
$SUDO chmod 700 "$KEYS_DIR"
$SUDO chmod 755 /var/lib/xl1-attestations

start_anchor_service() { # start_anchor_service [env-file]
  $SUDO docker rm -f xl1-service-anchor-1 >/dev/null 2>&1 || true
  # Deliberately not `docker compose`. The wizard installs docker.io from apt,
  # which does not ship the compose plugin, so a compose call would fail on a
  # fresh Pi -- and this is one container. service/docker-compose.pi.yml is
  # the reference for these values, and keeping the two in step is not
  # optional: this list drifted from it once and cost a clean install.
  #
  # The gateway URLs were the ones missing. Nothing here fails loudly without
  # them -- the container starts, the process runs, and /health answers 503
  # "RPC URL not configured" because every read builds a gateway first. The
  # wizard then waits sixty seconds for a service that was never going to
  # answer. It did not show up on the Pi that already worked, because that one
  # runs under compose and compose supplies them.
  #
  # test-bootstrap.sh now compares the two lists, so the next omission is a
  # failing test rather than a failed install.
  #
  # Two other values that are not obvious:
  #
  #   0.0.0.0 INSIDE the container, because Docker forwards a published port to
  #   the bridge address and not to the namespace loopback, so a service bound
  #   to 127.0.0.1 in there is unreachable through the mapping.
  #
  #   127.0.0.1 on the HOST side, which is the actual containment: the only
  #   interface that decides what your network can reach.
  # shellcheck disable=SC2086
  # Rotation for the same reason as the producer. No heap ceiling: this one's
  # resident set is small, but /producer walks the whole chain, and a cap set
  # too low turns something slow into something that crashes.
  $SUDO docker run -d --name xl1-service-anchor-1 --restart unless-stopped \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    ${1:+--env-file "$1"} \
    -e XL1_NETWORK="$XL1_NET" \
    -e XL1_SERVICE_PORT=8090 \
    -e XL1_SERVICE_HOST=0.0.0.0 \
    -e XL1_SEQUENCE_RPC_URL="$XL1_SEQUENCE_RPC_URL" \
    -e XL1_MAINNET_RPC_URL="$XL1_MAINNET_RPC_URL" \
    -e XL1_ATTEST_ARCHIVE=/attestations \
    -e XL1_INDEXER_FLOOR_BLOCK=0 \
    -v /var/lib/xl1-attestations:/attestations \
    -p 127.0.0.1:8090:8090 \
    xl1-service:local >/dev/null 2>&1
}

wait_for_service() { # up to ~60s for /health to answer
  i=0
  while [ "$i" -lt 30 ]; do
    curl -fsS --max-time 5 http://127.0.0.1:8090/health >/dev/null 2>&1 && return 0
    i=$((i + 1)); sleep 2
  done
  return 1
}

# With its key if this device already has one. A re-run rebuilds the image and
# recreates the container, and the handoff further down is skipped on an
# already-configured device -- so starting read-only here would leave it
# running without a signing key and quietly not anchoring, which is the exact
# failure the whole step exists to prevent.
# The env file existing IS the evidence that this device has a signing key.
# Not DONE_ANCHOR: the state file lives in the invoking user's home, so it is
# absent on any device set up before this wizard kept state, under a different
# user, or under sudo -- while the key on disk is still perfectly real. Keying
# this off the flag meant a device with a working key was restarted read-only
# and stopped anchoring, and the machines it happened to were exactly the
# oldest and most established ones.
ANCHOR_ENV_ARG=""
$SUDO test -s "$ANCHOR_ENV" && ANCHOR_ENV_ARG="$ANCHOR_ENV"

# Marked as anchoring, but the key file it would use is not there. Say so
# rather than start read-only and move on: the one-time block below is skipped
# on this device, so nothing further would notice, and it would sit healthy and
# quietly not anchoring until someone read the panel closely.
if [ "${DONE_ANCHOR:-0}" = 1 ] && [ -z "$ANCHOR_ENV_ARG" ]; then
  warn "marked as anchoring, but $ANCHOR_ENV is missing or empty" \
       "it will come up read-only and stop anchoring. Restore that file, or remove DONE_ANCHOR=1 from $STATE to set anchoring up from scratch."
fi
start_anchor_service $ANCHOR_ENV_ARG \
  || die "the anchor service would not start. Check: sudo docker logs xl1-service-anchor-1"
wait_for_service || {
  # The body, not just "no answer". This service starts cleanly and then
  # refuses every read when a gateway URL is missing, so the container log
  # shows nothing wrong and the reason is only ever in the reply.
  why="$(curl -sS --max-time 5 http://127.0.0.1:8090/health 2>&1 | head -c 300)"
  [ -n "$why" ] && printf '  the service replied: %s\n' "$why" >&2
  die "the anchor service started but is not answering on 127.0.0.1:8090. Check: sudo docker logs xl1-service-anchor-1"
}
if [ -n "$ANCHOR_ENV_ARG" ]; then
  ok "anchor service rebuilt and holding its key"
  sdk="$(curl -fsS --max-time 10 http://127.0.0.1:8090/versions 2>/dev/null \
         | sed -n 's/.*"@xyo-network\/xl1-sdk":"\([^"]*\)".*/\1/p')"
  [ -n "$sdk" ] && ok "service SDK $sdk"
else
  ok "anchor service is up (read-only -- it holds no key yet)"
fi

if [ "${DONE_ANCHOR:-0}" = 1 ]; then
  ok "anchoring was already set up here -- nothing to sign again"
else

# --- the throwaway key -------------------------------------------------------
if [ -z "${ATTESTOR_ADDRESS:-}" ] && $SUDO test -s "$KEYS_DIR/attestor.key"; then
  # A key is already here and this run does not know its address, which happens
  # whenever the previous run died between writing the key and saving the
  # state. Generating another is refused -- correctly, since replacing a
  # delegated key leaves the delegation pointing at an address nobody can sign
  # for -- so the address is read back off the key that exists.
  say "reading the attestation key already on this machine"
  out="$($SUDO docker run --rm -v "$KEYS_DIR":/keys xl1-service:local \
          node_modules/.bin/tsx new-attestor.ts --from /keys/attestor.key 2>&1)" \
    || { printf '%s\n' "$out" | sed 's/^/    /'; die "could not read $KEYS_DIR/attestor.key"; }
  ATTESTOR_ADDRESS="$(printf '%s' "$out" | grep -oiE '(0x)?[0-9a-f]{40}' | head -1)"
  [ -n "$ATTESTOR_ADDRESS" ] || { printf '%s\n' "$out" | sed 's/^/    /'; die "could not read an address from the output above"; }
  save_state
fi

if [ -z "${ATTESTOR_ADDRESS:-}" ]; then
  # Writes the phrase to the host 0600 and prints only the address. Refuses to
  # overwrite: replacing a key that has already been delegated would leave the
  # delegation pointing at an address nobody can sign for.
  out="$($SUDO docker run --rm -v "$KEYS_DIR":/keys xl1-service:local \
          node_modules/.bin/tsx new-attestor.ts --out /keys/attestor.key 2>&1)" \
    || { printf '%s\n' "$out" | sed 's/^/    /'; die "could not create the attestation key"; }
  printf '%s\n' "$out" | sed 's/^/    /'
  # 0x optional: these addresses are printed bare, and requiring the prefix
  # threw away a key that had just been written correctly.
  ATTESTOR_ADDRESS="$(printf '%s' "$out" | grep -oiE '(0x)?[0-9a-f]{40}' | head -1)"
  [ -n "$ATTESTOR_ADDRESS" ] || die "the key was made but its address could not be read from the output above"
  save_state
fi
ok "attestation address: $ATTESTOR_ADDRESS"

# --- waiting for gas ---------------------------------------------------------
# The one part nobody can automate, so the script waits on it rather than
# failing. It used to exit and ask for a re-run, which meant the operator had
# to come back, remember the command, and sit through the checks again for a
# transfer that usually lands in under a minute.
attestor_balance() { # echoes a decimal balance, or nothing
  curl -fsS --max-time 10 \
    "http://127.0.0.1:8090/standing?address=$ATTESTOR_ADDRESS&network=$XL1_NET" 2>/dev/null \
    | sed -n 's/.*"balance"[[:space:]]*:[[:space:]]*\([0-9.eE+-]*\).*/\1/p' | head -1
}

bal="$(attestor_balance)"
case "${bal:-0}" in ''|0|0.0|0.00) funded=0 ;; *) funded=1 ;; esac

if [ "$funded" = 1 ]; then
  ok "the attestation key already holds gas ($bal)"
else
  printf '\n'
  printf '  %sThis address needs gas before anchoring can start.%s\n\n' "$Y" "$X"
  printf '    %s%s%s\n\n' "$C" "$ATTESTOR_ADDRESS" "$X"
  printf '  It pays for every anchor -- about 0.0001186 XL1 each, hourly, so\n'
  printf '  roughly one XL1 a year. Send more and forget about it.\n\n'
  printf '  %sWaiting for it to arrive. Leave this running; it checks every 10\n' "$D"
  printf '  seconds and continues by itself. Ctrl+C is safe -- everything so far\n'
  printf '  is saved and the same command picks up here.%s\n\n' "$X"

  # A visible clock, so a wait that is working looks different from a wedge.
  spin='|/-\'
  waited=0
  while [ "$funded" != 1 ]; do
    n=0
    while [ "$n" -lt 10 ]; do
      c="$(printf '%s' "$spin" | cut -c$(( (waited + n) % 4 + 1 )))"
      printf '\r  %s waiting for gas at %s   %dm %02ds ' \
             "$c" "$ATTESTOR_ADDRESS" "$((waited / 60))" "$((waited % 60))"
      sleep 1
      n=$((n + 1))
    done
    waited=$((waited + 10))
    bal="$(attestor_balance)"
    case "${bal:-0}" in ''|0|0.0|0.00) : ;; *) funded=1 ;; esac
    # Hourly, in case the balance can never be read -- so a wait that will
    # never end says so rather than spinning until somebody gives up.
    if [ "$funded" != 1 ] && [ "$((waited % 3600))" -eq 0 ]; then
      printf '\r%s' "$EOL"
      warn "still nothing after $((waited / 3600))h" \
           "check the address is right, and that the service can reach the network: sudo docker logs xl1-service-anchor-1"
    fi
  done
  printf '\r%s' "$EOL"
  ok "gas arrived: $bal"
fi

# --- the delegation ----------------------------------------------------------
# The producer phrase goes in on STDIN. Never an argument, never an -e: the
# delegate tool reads stdin for exactly this reason.
note "Binding that key to your producer. This is the only time the producer"
note "phrase is used after setup, and it is used here by you, once."
PRODUCER_MNEMONIC="$($SUDO sed -n 's/^XL1_MNEMONIC=//p' "$PRODUCER_ENV" 2>/dev/null)"
[ -n "$PRODUCER_MNEMONIC" ] || die "could not read the producer phrase from $PRODUCER_ENV"

spin_char() { # spin_char <n> -> one frame of the spinner
  printf '%s' '|/-\' | cut -c$(( ${1:-0} % 4 + 1 ))
}

# One live line for the confirmation wait, instead of one line per attempt.
#
# The SDK prints "Transaction not confirmed yet, attempt N. Retrying..." with
# the full 64-character hash every time. Nine of those scrolled the payload off
# the screen -- and the payload is the one thing on that page the operator is
# told to keep and publish, shown to them exactly once.
#
# Same shape as the gas wait: a spinner, an elapsed clock, a short hash.
# Anything that is not a retry passes through untouched, so the anchored /
# tx hash / signed by block still arrives in full.
#
# Node block-buffers stdout into a pipe, so these can arrive in a burst rather
# than as they happen, which makes the clock approximate. Nine lines still
# collapse to one, which is the point of it.
confirm_progress() {
  line=""; hash=""; attempt=0; started="$(date +%s)"
  while IFS= read -r line; do
    case "$line" in
      *"Confirming transaction "*)
        hash="${line##* }"
        # Swallowed on a terminal, where the live line below replaces it.
        # Kept in a log, where it marks when the wait began.
        [ -z "$EOL" ] && printf '    %s\n' "$line"
        ;;
      *"not confirmed yet, attempt "*)
        attempt=$((attempt + 1))
        [ -z "$hash" ] && hash="${line##* }"
        if [ -n "$EOL" ]; then
          printf '\r    %s confirming %.12s  %ds  (check %d)%s' \
                 "$(spin_char "$attempt")" "$hash" \
                 "$(( $(date +%s) - started ))" "$attempt" "$EOL"
        else
          # No terminal to redraw on, so keep every line: this is a log, and a
          # collapsed one loses the history it exists to hold.
          printf '    %s\n' "$line"
        fi
        ;;
      *"Transaction confirmed"*)
        [ -n "$EOL" ] && printf '\r%s' "$EOL"
        if [ "$attempt" -gt 0 ]; then
          printf '    confirmed after %ds and %d checks\n' \
                 "$(( $(date +%s) - started ))" "$attempt"
        else
          printf '    confirmed after %ds\n' "$(( $(date +%s) - started ))"
        fi
        # The wait is over, so what follows needs no clearing -- and without
        # this every remaining line of the anchored block carries an escape
        # for nothing.
        attempt=0
        ;;
      *)
        # Leaving the spinner line in place under a new one would strand it.
        [ -n "$EOL" ] && [ "$attempt" -gt 0 ] && printf '\r%s' "$EOL"
        printf '    %s\n' "$line"
        ;;
    esac
  done
}

# Dry run first, printed in full, so what is about to go on chain is seen
# before it goes there.
printf '%s' "$PRODUCER_MNEMONIC" | $SUDO docker run --rm -i xl1-service:local \
  node_modules/.bin/tsx delegate-attestor.ts --attestor "$ATTESTOR_ADDRESS" 2>&1 | sed 's/^/    /'

printf '\n'
if ask_yn "  Put that on chain?" "y"; then
  printf '%s' "$PRODUCER_MNEMONIC" | $SUDO docker run --rm -i xl1-service:local \
    node_modules/.bin/tsx delegate-attestor.ts --attestor "$ATTESTOR_ADDRESS" --anchor 2>&1 \
    | confirm_progress \
    || { PRODUCER_MNEMONIC=""; die "the delegation did not anchor. Nothing else was changed."; }
  ok "the delegation is on chain"
  # Recorded so a later run can tell "already set up" from "set up for a
  # producer this node no longer is". Public information -- it appears in every
  # block the node signs -- so it is readable, unlike the key beside it.
  delegated_for="$(current_producer)"
  if [ -n "$delegated_for" ]; then
    printf '%s\n' "$delegated_for" | $SUDO tee "$ANCHOR_PRODUCER_FILE" >/dev/null
    $SUDO chmod 0644 "$ANCHOR_PRODUCER_FILE" 2>/dev/null || true
  fi
else
  PRODUCER_MNEMONIC=""
  die "stopped before delegating. Run this again when you are ready; nothing was changed."
fi
PRODUCER_MNEMONIC=""

# --- hand the service its key -------------------------------------------------
# One value on both sides. The service refuses to serve /attest at all when a
# signing key is set without it -- a key behind an unprotected endpoint is
# worse than no key.
ANCHOR_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
ATTESTOR_PHRASE="$($SUDO cat "$KEYS_DIR/attestor.key" 2>/dev/null | tr -d '\r\n')"
[ -n "$ATTESTOR_PHRASE" ] || die "could not read $KEYS_DIR/attestor.key"

tmp_env="$(mktemp)"
chmod 600 "$tmp_env"
{
  printf '# Anchor service. Root-only: contains the attestation phrase.\n'
  printf 'XL1_NETWORK=%s\n' "$XL1_NET"
  printf 'XYO_WALLET_MNEMONIC=%s\n' "$ATTESTOR_PHRASE"
  printf 'XL1_ANCHOR_TOKEN=%s\n' "$ANCHOR_TOKEN"
} > "$tmp_env"
$SUDO install -o root -g root -m 600 "$tmp_env" "$ANCHOR_ENV"
rm -f "$tmp_env"
ATTESTOR_PHRASE=""
ok "wrote the service config"

start_anchor_service "$ANCHOR_ENV" \
  || die "the anchor service would not restart. Check: sudo docker logs xl1-service-anchor-1"
wait_for_service || die "the anchor service is not answering on 127.0.0.1:8090"

health="$(curl -fsS --max-time 10 http://127.0.0.1:8090/health 2>/dev/null || true)"
case "$health" in
  *'"signing":true'*|*'"signing": true'*) ok "the anchor service is holding its key" ;;
  *) warn "the service is up but reports no signing key" \
          "anchoring will not start until that is fixed: sudo docker logs xl1-service-anchor-1" ;;
esac

# --- tell the agent about it -------------------------------------------------
# Appended to the agent's env and the service restarted. Both sides carry the
# same token under the same variable name, so one value covers both.
$SUDO sed -i '/^XL1_ATTEST_URL=/d;/^XL1_ANCHOR_TOKEN=/d' "$AGENT_ENV" 2>/dev/null || true
printf 'XL1_ATTEST_URL=http://127.0.0.1:8090/attest\nXL1_ANCHOR_TOKEN=%s\n' "$ANCHOR_TOKEN" \
  | $SUDO tee -a "$AGENT_ENV" >/dev/null
ANCHOR_TOKEN=""
$SUDO systemctl restart xl1-heartbeat 2>/dev/null || true
ok "the agent will anchor from its next cycle"

DONE_ANCHOR=1
save_state
fi

printf '\n'
note "Watching it:      sudo docker logs -f xl1-producer"
note "Its config:       $PRODUCER_ENV  (root only)"
note ""
note "Anchor service:   sudo docker logs -f xl1-service-anchor-1"
note "Attestation key:  $KEYS_DIR/attestor.key  (root only -- back this up)"
note ""
note "'Published block: ...' in the log means a candidate was SUBMITTED. It"
note "does not mean it was accepted -- that needs your address on the producer"
note "list. Blocks produced on the grid panel is the number that settles it."
note ""
note "Anchoring runs hourly. The first one lands within the hour, and ends"
note "this device's probation early -- it is the faster of the two ways off"
note "pending."

clear_state
printf '\n  %sSetup is complete.%s\n' "$G" "$X"
exit 0
