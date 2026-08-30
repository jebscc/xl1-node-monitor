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
#   --backend URL      the grid's backend
#   --grid URL         where devices are registered
#   --agent-from PATH  use a local xl1_heartbeat.py instead of downloading
#   --yes              take the answers given and ask nothing
#   --check            report what it found and stop, changing nothing
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
POSTCODE=""; COUNTRY_CC="us"
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
    --agent-from)  AGENT_FROM="${2:-}"; shift ;;
    --yes|-y)      ASSUME_YES=1 ;;
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
  # Asked of the grid rather than assumed: finding out later means a 401 after
  # the service is already running.
  if have curl && curl -fsSL --max-time 25 "$BACKEND_URL/api/node/status" 2>/dev/null \
       | grep -q "\"node_id\"[[:space:]]*:[[:space:]]*\"$NODE_ID\""; then
    printf '  %s"%s" is already reporting on the grid -- pick another.%s\n' "$Y" "$NODE_ID" "$X"
    NODE_ID=""; [ "$TTY_OK" = 1 ] || die "node id already taken"; continue
  fi
  ok "\"$NODE_ID\" is free"
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

# =============================================================================
head_ "5. What will happen"
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
head_ "6. Installing"
# =============================================================================
if [ -n "$NEED_APT" ]; then
  sudo apt-get update -qq || die "apt-get update failed"
  # shellcheck disable=SC2086
  sudo apt-get install -y -qq $NEED_APT || die "apt-get install failed"
  ok "installed:$NEED_APT"
else
  ok "nothing to install"
fi

if [ "$WITH_DOCKER" = 1 ] && getent group docker >/dev/null 2>&1; then
  sudo usermod -aG docker "$(id -un)"
  ok "added $(id -un) to the docker group"
  warn "log out and back in before Docker works for this user" \
       "group membership is applied at login"
fi

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

# =============================================================================
head_ "7. Its credential"
# =============================================================================
TOKEN="${NODE_HEARTBEAT_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  printf '  Register %s%s%s here:\n\n' "$B" "$NODE_ID" "$X"
  printf '     %s%s%s\n\n' "$C" "$GRID_URL" "$X"
  printf '  The token is shown once and cannot be read back afterwards, so copy\n'
  printf '  it before closing the page. Leave this blank to stop and finish later.\n\n'
  TOKEN="$(ask_secret "  Paste the token")"
fi

if [ -z "$TOKEN" ]; then
  printf '\n  %sStopped before the credential.%s The agent is installed and idle.\n' "$Y" "$X"
  printf '  When you have the token:\n\n'
  printf '    NODE_HEARTBEAT_TOKEN=<token> bash onboard.sh --node-id %s%s --install\n' \
         "$NODE_ID" "$( [ "$WITH_DOCKER" = 1 ] || printf ' --skip-docker' )"
  exit 0
fi

# =============================================================================
head_ "8. Checking, then starting"
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
