#!/usr/bin/env bash
#
# From a freshly flashed Raspberry Pi to a device on the Explorer Grid.
#
# It asks. Run it with no arguments and it walks through every decision --
# what the device is called, whether it says where it is, whether it needs
# Docker -- and shows what it will do before doing any of it.
#
#   curl -fsSL <this-url> | bash
#
# Every answer can also be given as a flag, and anything given is not asked
# about. That is what makes it usable from a script as well as from a chair:
#
#   --node-id NAME     what the device is called on the grid
#   --label TEXT       a human name for it
#   --location TEXT    a town, region or country -- shown as stated, not checked
#   --lat N --lon N    coordinates for the map
#   --postcode CODE    look the coordinates up from a postal code instead
#   --country CC       country for that lookup (default us)
#   --radius KM        how wide the location claim is (default 25)
#   --no-location      do not ask about location; report none
#   --with-docker      install Docker (only if this Pi will run a node)
#   --tailscale-key K  join the tailnet with an auth key instead of a browser
#
# Tailscale is required, not optional. Every device on the grid is reachable
# over it, and there is no flag to skip it -- see step 5.
#   --backend URL      the grid's backend
#   --grid URL         where devices are registered
#   --agent-from PATH  use a local xl1_heartbeat.py instead of downloading
#   --yes              take the answers given and ask nothing
#   --check            report what it found and stop, changing nothing
#   --fresh            ignore a half-finished run and start from the top
#
# Piped into bash, stdin is this script -- so the questions are read from
# /dev/tty instead. A plain `read` would swallow the rest of the file and the
# run would end somewhere in the middle of a function. Where there is no
# terminal at all (cron, CI), it says so and asks for flags rather than
# hanging on a prompt nobody can answer.
#
# WHAT IT DOES NOT DO: install an XL1 node. That is a much larger thing and a
# decision about what the machine is for, rather than a step in joining the
# grid. A device that reports and anchors is a full member of a grid without
# one -- corroboration is the point, and it does not require producing blocks.

set -uo pipefail

GRID_URL="${GRID_URL:-https://jimtheexplorer.com/grid}"
BACKEND_URL="${BACKEND_URL:-https://xyo-backend.onrender.com}"
PUBLIC_REPO="${PUBLIC_REPO:-https://raw.githubusercontent.com/jebscc/xl1-node-monitor/main/agent}"
NODE_ID=""; NODE_LABEL=""; STATED_LOCATION=""; STATED_LAT=""; STATED_LON=""
STATED_RADIUS="25"; WITH_DOCKER=""; NO_LOCATION=0
POSTCODE=""; COUNTRY_CC="us"; WANT_TS=""; TS_KEY=""; FRESH=0
DONE_PREREQS=0; DONE_TAILSCALE=0; DONE_AGENT=0
AGENT_FROM=""; ASSUME_YES=0; CHECK_ONLY=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'
  B=$'\033[1m'; D=$'\033[2m'; X=$'\033[0m'
else G=""; R=""; Y=""; C=""; B=""; D=""; X=""; fi

say()  { printf '  %s\n' "$1"; }
ok()   { printf '  %sok%s    %s\n' "$G" "$X" "$1"; }
warn() { printf '  %swarn%s  %s\n' "$Y" "$X" "$1"; [ $# -gt 1 ] && printf '        %s%s%s\n' "$D" "$2" "$X"; return 0; }
bad()  { printf '  %sstop%s  %s\n' "$R" "$X" "$1"; [ $# -gt 1 ] && printf '        %s%s%s\n' "$D" "$2" "$X"; return 0; }
head_(){ printf '\n%s%s%s\n' "$B" "$1" "$X"; }
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
    --grid)        GRID_URL="${2:-}"; shift ;;
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
  if [ "$TTY_OK" != 1 ]; then [ "$default" = y ] && return 0 || return 1; fi
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
note "It does NOT install an XL1 node, and it never asks for a wallet, a"
note "seed phrase or a private key. Nothing here can spend anything."

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
note "Two names are asked for, and they do different jobs."
note ""
note "This first one is the device's ID -- the permanent handle the grid"
note "uses in its API, its records and its credential. Think of it as a"
note "username: short, no spaces, and it CANNOT be changed later."
note ""
note "Letters, numbers, dots, dashes and underscores. For example:"
note "  attic-pi-3     lew-garage-01     pi3-spare"
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

  if [ "$AVAIL" = 0 ] && [ "$REASON" = reporting ]; then
    printf '  %s"%s" is a device that is reporting right now.%s\n' "$Y" "$NODE_ID" "$X"
    note "That name belongs to a machine already on the grid. Pick another."
    NODE_ID=""; [ "$TTY_OK" = 1 ] || die "node id already taken"; continue
  fi

  if [ "$AVAIL" = 0 ] && [ "$REASON" = registered ]; then
    printf '  %s"%s" already has a credential.%s\n' "$Y" "$NODE_ID" "$X"
    note "Someone has registered that name -- quite possibly you, in a run"
    note "that stopped before this one. That is not automatically a problem:"
    note ""
    note "  If it is yours AND you still have its token, carry on and paste"
    note "  that token when asked. Nothing needs registering again."
    note ""
    note "  If you do not have the token, it cannot be recovered. Remove the"
    note "  device from Admin -> Node -> Devices and use the name again, or"
    note "  simply choose a different one now."
    printf '\n'
    if ask_yn "  Carry on with \"$NODE_ID\" anyway?" "n"; then
      ok "using \"$NODE_ID\" -- you will need its existing token"
      break
    fi
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
if [ -n "$WITH_DOCKER" ]; then
  ok "Docker requested on the command line"
elif have docker; then
  WITH_DOCKER=1; ok "Docker is already installed"
else
  note "Docker is only needed if this Pi will ALSO run an XL1 node -- the"
  note "software that takes part in the chain itself. That is a much bigger"
  note "job than this agent, and a separate decision."
  note ""
  note "  no   this Pi reports on itself and joins the map. Most people."
  note "  yes  you already intend to run a node here, or you run one now."
  note ""
  note "Answering no changes nothing about being a member of the grid, and"
  note "you can install Docker later without redoing any of this."
  printf '\n'
  if ask_yn "  Install Docker?" "n"; then WITH_DOCKER=1; else WITH_DOCKER=0; fi
fi

save_state

# =============================================================================
head_ "5. Joining your private network  (required)"
# =============================================================================
WANT_TS=1     # required: there is deliberately no way to answer no
if have tailscale && tailscale status >/dev/null 2>&1; then
  ok "already on a tailnet as $(tailscale ip -4 2>/dev/null | head -1)"
  TS_DONE=1
else
  TS_DONE=0
  note "Every device on the grid is reachable over Tailscale, so this part is"
  note "required rather than offered. Two concrete reasons:"
  note ""
  note "  Devices on different home networks cannot see each other. A device"
  note "  on 192.168.4.x cannot reach one on 192.168.5.x, which is exactly"
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
if [ -z "$TOKEN" ]; then
  printf '  Register %s%s%s here:\n\n' "$B" "$NODE_ID" "$X"
  printf '     %s%s%s\n\n' "$C" "$GRID_URL" "$X"
  printf '  Open that on any device, add %s%s%s, and it shows a token once.\n' "$B" "$NODE_ID" "$X"
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
head_ "9. Checking, then starting"
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

extra=""; [ "$WITH_DOCKER" = 1 ] || extra="--skip-docker"
# The token travels in the environment, never as an argument: arguments are
# visible in ps to every user on the machine.
# shellcheck disable=SC2086
NODE_HEARTBEAT_TOKEN="$TOKEN" \
NODE_LABEL="$NODE_LABEL" \
XL1_STATED_LOCATION="$STATED_LOCATION" \
XL1_STATED_LAT="$STATED_LAT" \
XL1_STATED_LON="$STATED_LON" \
XL1_STATED_RADIUS_KM="$STATED_RADIUS" \
bash "$CHECKER" --node-id "$NODE_ID" --backend "$BACKEND_URL" --grid "$GRID_URL" \
     $extra --install
rc=$?

# Only on success. A failed install is exactly the case where the next run
# should still know the answers.
if [ "$rc" -eq 0 ]; then
  clear_state
  printf '\n  %sSetup is complete.%s\n' "$G" "$X"
else
  printf '\n  %sThat did not finish.%s Your answers are saved -- run the same\n' "$Y" "$X"
  printf '  command again and it will resume.\n'
fi
exit "$rc"
