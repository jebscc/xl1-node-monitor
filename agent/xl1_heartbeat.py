#!/usr/bin/env python3
"""XL1 node heartbeat agent.

Runs ON the node (Raspberry Pi), collects real health/host metrics, and POSTs
them outbound to the site backend. Nothing inbound is ever opened on the Pi.

Standard library only -- no pip install needed on the Pi.

Health is read by `docker exec`ing curl inside the container (the xl1 image
ships curl), so the container's ports do NOT need to be published. If you have
published the health port, set XL1_HEALTH_URL and it will be used instead.

Configure via /etc/xl1-heartbeat.env, then run under systemd. See README.md.
"""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import threading
import sys
import traceback
import time
import urllib.error
import urllib.parse
import urllib.request

# Shown on the operator panel as the "Agent" tile, which exists to answer one
# question: which agent is on the Pi right now. A constant answers it wrongly --
# this sat at 1.0.0 through twelve commits and several deploys, so the tile said
# the same thing before and after every one of them.
#
# Semantic versioning against the heartbeat payload, which is the agent's only
# interface:
#
#   MAJOR  a field is removed or changes meaning. Nothing has, and the receiver
#          ignores fields it does not know, so this is genuinely rare.
#   MINOR  a new field is reported, or a new thing is measured.
#   PATCH  a fix that changes no field.
#
# test_reported_fields_are_pinned_to_the_version() fails when the payload gains
# a field, so this cannot quietly freeze again.
AGENT_VERSION = "1.25.1"

BACKEND_URL = os.environ.get("BACKEND_URL", "").rstrip("/")
NODE_TOKEN = os.environ.get("NODE_HEARTBEAT_TOKEN", "")
NODE_ID = os.environ.get("NODE_ID", socket.gethostname())
NODE_LABEL = os.environ.get("NODE_LABEL", "Raspberry Pi")
NODE_ROLE = os.environ.get("NODE_ROLE", "producer")
NODE_NETWORK = os.environ.get("NODE_NETWORK", "sequence")

CONTAINER = os.environ.get("XL1_CONTAINER", "")        # empty => discover by image
CONTAINER_IMAGE = os.environ.get("XL1_IMAGE", "xl1:local")
# Substring of the node's entrypoint command. Used as a last-resort way to
# identify the container when the image tag no longer matches.
COMMAND_HINT = os.environ.get("XL1_COMMAND_HINT", "/opt/xl1/")
HEALTH_PORT = os.environ.get("XL1_HEALTH_PORT", "9099")
HEALTH_URL = os.environ.get("XL1_HEALTH_URL", "")      # set only if port is published

# Local xl1-service (read-only gateway) for chain height. Empty disables it.
HEIGHT_URL = os.environ.get("XL1_HEIGHT_URL", "http://127.0.0.1:8090/block-height")
# Networks to report heights for. The site shows mainnet even though this node
# runs on sequence, so both are fetched by default.
HEIGHT_NETWORKS = [n.strip() for n in
                   os.environ.get("XL1_HEIGHT_NETWORKS", "sequence,mainnet").split(",")
                   if n.strip()]

# Producer activity. Costs one RPC call per block inspected, so it runs on a
# much slower cycle than the heartbeat.
PRODUCER_URL = os.environ.get("XL1_PRODUCER_URL", "http://127.0.0.1:8090/producer")
# Whether the producer is *able* to produce, as distinct from whether it is.
# The node gates redeclaring its intent on having a balance above zero: at zero
# it stops redeclaring, stops being scheduled, and produces nothing -- while the
# container stays up and healthy throughout. Watching blocks alone cannot tell
# that apart from a quiet slot, which is the gap this closes. Empty disables.
STANDING_URL = os.environ.get("XL1_STANDING_URL", "http://127.0.0.1:8090/standing")
STANDING_INTERVAL = int(os.environ.get("XL1_STANDING_INTERVAL", "900"))
# What an anchor costs, measured on the chain from this wallet's own recent
# transfers. Separate from the standing call rather than folded into it: if
# this endpoint is missing or fails, the balance tile must keep working and
# simply lose its runway estimate.
ANCHOR_COST_URL = os.environ.get(
    "XL1_ANCHOR_COST_URL", "http://127.0.0.1:8090/anchor-cost")
# Whether an anchor this node recorded is actually on the chain. Same service,
# and this node is the only party that can ask: the gateway SDK lives there, on
# loopback, and neither the backend nor a browser can reach a chain client.
TX_CHECK_URL = os.environ.get("XL1_TX_CHECK_URL", "http://127.0.0.1:8090/transaction")
# How many to check per slow cycle. Small on purpose: there is no deadline,
# an unchecked anchor is not an alarm, and this shares a Pi with a producer.
TX_CHECK_BATCH = int(os.environ.get("XL1_TX_CHECK_BATCH", "5"))
# What the node EARNED by producing, as distinct from what it holds. The
# balance moves for reasons that are not earnings -- funding sent in to
# start the producer, anything transferred out -- so a panel deriving
# earnings from it counts that money as income. Same cadence as standing:
# two RPC calls behind the service, answering a slowly-changing question.
EARNINGS_URL = os.environ.get("XL1_EARNINGS_URL", "http://127.0.0.1:8090/earnings")
EARNINGS_INTERVAL = int(os.environ.get("XL1_EARNINGS_INTERVAL", "900"))
# Minutes of container log to search for the node's own eligibility verdict.
ELIGIBILITY_WINDOW = os.environ.get("XL1_ELIGIBILITY_WINDOW", "20m")
# Lines of container log to ship with each heartbeat, so the operator panel can
# show what the node is saying without anyone reaching the machine. Set 0 to
# send none.
#
# This is raw node output leaving the Pi. It is operator-only at the far end,
# but it is worth knowing that is what it is: the node prints its derived
# wallet ADDRESSES at startup -- public, they appear in every block it signs --
# and never the mnemonic. Lines are capped so one enormous stack trace cannot
# turn a heartbeat into a megabyte.
LOG_TAIL_LINES = int(os.environ.get("XL1_LOG_TAIL_LINES", "20"))
# How long the node takes to build a block, and what counts as too long.
#
# This is the only leading indicator the panel has. Blocks produced and share
# of the field both report a decline that has already happened; build time
# crosses the block interval BEFORE races start being lost, so it is the one
# figure that gives any warning.
#
# The budget is not the block interval. It is well below it on purpose: the
# useful moment to look is when builds are trending toward the interval, not
# when they have already passed it and the node is losing.
BUILD_WINDOW = os.environ.get("XL1_BUILD_WINDOW", "60m")
BUILD_BUDGET_MS = int(os.environ.get("XL1_BUILD_BUDGET_MS", "1000"))
BUILD_SAMPLES_MAX = int(os.environ.get("XL1_BUILD_SAMPLES_MAX", "500"))
# Host package updates. Read on a slow cycle: this shells out to apt, the
# answer changes daily at most, and a heartbeat must never wait on it. Set
# XL1_OS_UPDATE_INTERVAL to 0 to switch the check off entirely.
OS_UPDATE_INTERVAL = int(os.environ.get("XL1_OS_UPDATE_INTERVAL", "21600"))
# How often to look again while something IS pending. The expensive case is
# "nothing to report", which is nearly always, and six hours is right for it.
# But the moment an operator is actually patching is the moment the panel
# should keep up: at the slow cadence a patched host went on showing the old
# count, and the all-clear email did not arrive, for up to six hours -- unless
# you knew to restart the agent, which is a step this created and then asked
# someone to remember.
OS_PENDING_INTERVAL = int(os.environ.get("XL1_OS_PENDING_INTERVAL", "900"))
# Peer context: how this node's block share compares with the rest of the
# field. One scan of a wide window, so it runs far slower than the heartbeat.
PEERS_URL = os.environ.get("XL1_PEERS_URL", "http://127.0.0.1:8090/peers")
PEERS_WINDOW = int(os.environ.get("XL1_PEERS_WINDOW", "1000"))
PEERS_INTERVAL = int(os.environ.get("XL1_PEERS_INTERVAL", "3600"))
LOG_TAIL_MAX_CHARS = 300

# What the node says when it refuses to declare itself a producer. Matched as
# substrings of its own error lines:
#
#   `Producer ${address} has insufficient stake.`
#   `Producer ${address} has no balance.`
#
# Taken from the node's log rather than recomputed. The stake figure is not
# readable from the public gateway -- activeByStaked is not exposed there, and
# the call that is exposed returns an empty list for a node that is demonstrably
# producing, so reporting it would be a false alarm. The node has already made
# this determination on the code path that decides whether it can produce; its
# verdict is worth more than a number reconstructed from outside.
# What the node says when it cannot produce. Matched against its own log,
# because the node knows why it was passed over and nothing else does.
#
# The last four are the protocol's own words for it. producerIneligibility in
# @xyo-network/xl1-protocol returns exactly these when it refuses an address:
# a missing intent declaration, stake that is too new, stake that is too new OR
# too small, and too little bonded by the producer on itself. Watching for them
# now costs four tuples and means the panel says something useful on the first
# day staking is enforced rather than after somebody notices the silence.
BLOCKED_PATTERNS = (
    ("insufficient stake", "insufficient stake"),
    ("has no balance", "no balance"),
    ("no-intent", "no stake intent declared"),
    ("unseasoned-or-understaked", "stake too new or too small"),
    ("unseasoned", "stake not yet seasoned"),
    ("insufficient-self-bond", "self-bond below the minimum"),
)
PRODUCER_WINDOW = int(os.environ.get("XL1_PRODUCER_WINDOW", "200"))
PRODUCER_INTERVAL = int(os.environ.get("XL1_PRODUCER_INTERVAL", "900"))
REWARD_ADDRESS = os.environ.get("XL1_REWARD_ADDRESS", "")
# Blocks of history to walk back per cycle. The service fetches these in
# batched RPC calls (~0.6 ms/block), so 50,000 is roughly 20-30 seconds of work
# and a 565k-block chain is fully counted in about 3 hours. Set to 0 to leave
# history uncounted.
BACKFILL_CHUNK = int(os.environ.get("XL1_BACKFILL_CHUNK", "50000"))
# The mint walk reads every payload of every block rather than testing one
# field, so the same range costs it far more. 50000 did not finish inside
# the request timeout on a Pi, which does not read as slow -- the request
# fails, the cursor never moves, and the walk reports 0% indefinitely.
MINTED_CHUNK = int(os.environ.get("XL1_MINTED_CHUNK", "5000"))
# Version checking. The image is built once and never patched unless someone
# notices it has fallen behind, so the node reports what it runs and what is
# current. Set XL1_CLI_REGISTRY empty to skip the outbound lookup entirely.
CLI_REGISTRY = os.environ.get(
    "XL1_CLI_REGISTRY", "https://registry.npmjs.org/@xyo-network/xl1-cli/latest")
# The CLI version above tracks what runs *inside* the image. It says nothing
# about the repository the image is *built from* -- and a fix to the
# Dockerfile, the entrypoint or a role preset changes neither the npm version
# nor anything else the agent could otherwise notice. Without this, upstream
# could ship a fix for a problem you reported and you would never hear about
# it. Set XL1_IMAGES_REPO_API empty to switch the check off.
IMAGES_REPO = os.environ.get("XL1_IMAGES_REPO", "/opt/xl1-docker-images")
IMAGES_REPO_API = os.environ.get(
    "XL1_IMAGES_REPO_API", "https://api.github.com/repos/XYOracleNetwork/xl1-docker-images")
IMAGES_REPO_BRANCH = os.environ.get("XL1_IMAGES_REPO_BRANCH", "main")
# The update email used to state flatly that a weekly timer builds the new
# image. That is only true where the timer exists and is running, which the
# email cannot know -- and an alert that claims an automated job is handling
# something, when nothing is, is worse than one that says nothing at all. Ask
# systemd instead of asserting. Set empty to skip.
REBUILD_TIMER = os.environ.get("XL1_REBUILD_TIMER", "xl1-image-rebuild.timer")
# Which systemd unit, if any, owns the producer container. The update runbook
# has to name the right thing to restart: telling an operator running under
# systemd to `docker stop` the container is worse than useless, because
# Restart=always brings it straight back and the instruction reads as broken.
PRODUCER_UNIT = os.environ.get("XL1_PRODUCER_UNIT", "xl1-producer.service")
CLI_CHECK_INTERVAL = int(os.environ.get("XL1_CLI_CHECK_INTERVAL", "21600"))
# The CLI version above covers the node container. Nothing covered the SDK the
# companion service reads the chain WITH, which is the more consequential of
# the two: that service decodes blocks, payloads and mint transfers, so a
# protocol change met by a library too old to understand it does not raise an
# error -- it puts a plausible wrong number on an earnings panel.
#
# Asked over HTTP rather than by `docker exec`. The agent keeps exec down to a
# single call because exec is what makes Docker socket access dangerous, and a
# version string is not worth spending that on. The service is also the
# authority on what it actually loaded, which is not always what its
# package.json asked for. Set either URL empty to switch the check off.
VERSIONS_URL = os.environ.get("XL1_VERSIONS_URL", "http://127.0.0.1:8090/versions")
SDK_REGISTRY = os.environ.get(
    "XL1_SDK_REGISTRY", "https://registry.npmjs.org/@xyo-network/xl1-sdk/latest")
SDK_PACKAGE = "@xyo-network/xl1-sdk"
# Attestation. The node anchors a hash of its own readings so a stranger can
# tell they have not been edited since -- the hardware half of the panel is
# otherwise just the machine describing itself.
#
# Off unless ATTEST_URL is set, and the service refuses to sign without its own
# key and token, so this cannot start spending gas by being deployed.
ATTEST_URL = os.environ.get("XL1_ATTEST_URL", "")
ATTEST_INTERVAL = int(os.environ.get("XL1_ATTEST_INTERVAL", "3600"))
# Written to disk the moment an anchor succeeds, BEFORE the backend is told.
# The chain stores only a hash and the gateway will not serve the payload back,
# so between anchoring and storing, this file is the only copy in existence. An
# earlier payload survived solely because 120,699 candidate timestamps could be
# searched for one that hashed correctly; that worked once and is no way to run
# a system.
ATTEST_SPOOL = os.environ.get(
    "XL1_ATTEST_SPOOL", "/var/lib/xl1-heartbeat/attestations")
# The service refuses to sign for an unauthenticated caller, and it is right to:
# a signing key behind an open endpoint is worse than no signing. So the agent
# has to present the same token. Same name as the service reads, so one value
# configured in one place covers both.
ATTEST_TOKEN = os.environ.get("XL1_ANCHOR_TOKEN", "")
# Where the operator SAYS this device is. Opt-in and unset by default: a
# machine that says nothing about its location stays off any map, which is the
# right default for hardware that mostly lives in people's houses.
#
# Nothing verifies this, and the receiver rounds it to one decimal place (~11km)
# on the way in, so sending a precise fix gains nothing and reveals nothing.
# Send a coarse one anyway -- the rounding is a backstop, not permission.
STATED_LOCATION = os.environ.get("XL1_STATED_LOCATION", "").strip()[:60]


def _stated_coord(name, limit):
    """A coordinate from the environment, or None if it is absent or nonsense.

    Refuses rather than clamps. A latitude of 500 is a typo or a misread
    config, and quietly turning it into 90 would put the device on the map at a
    place nobody chose.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        return None
    return value if -limit <= value <= limit else None


STATED_LAT = _stated_coord("XL1_STATED_LAT", 90)
STATED_LON = _stated_coord("XL1_STATED_LON", 180)

# How wide the claim is, in kilometres. Defaults to 25 because the usual way to
# fill the coordinates in is an IP lookup, and city-level IP geolocation is
# routinely tens of kilometres out -- a point would be a smaller number than the
# method can support. The receiver floors it at 11 km, which is the rounding it
# applies anyway.
try:
    STATED_RADIUS_KM = max(1, int(os.environ.get("XL1_STATED_RADIUS_KM", "25")))
except ValueError:
    STATED_RADIUS_KM = 25

CLI_PACKAGE_PATH = "/usr/local/lib/node_modules/@xyo-network/xl1-cli/package.json"
# A version string reaches us from a public registry and from inside a
# container. The backend caps these fields at 32 characters, so an unexpected
# value would fail validation and take the WHOLE heartbeat with it -- the node
# would read OFFLINE and raise an alert because of someone else's bad metadata.
_VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+){0,3}(-[0-9A-Za-z.]+)?$")


def _valid_version(value):
    return (isinstance(value, str) and 0 < len(value) <= 32
            and _VERSION_RE.match(value) is not None)

INTERVAL = int(os.environ.get("HEARTBEAT_INTERVAL", "30"))
# Generous by default: a free-tier host that has spun down can take 30-60s
# to answer the first request. A short timeout turns that into a false alarm.
TIMEOUT = int(os.environ.get("HEARTBEAT_TIMEOUT", "60"))


def run(args, timeout=10, merge_stderr=False):
    """Run a command, returning stripped stdout or None on any failure.

    merge_stderr folds the command's stderr into the result. It is off by
    default and must stay that way: `apt list` writes its "unstable CLI"
    warning to stderr, and docker writes progress there, so folding those into
    text that then gets parsed would corrupt it.

    It is switched on only for `docker logs`, where the discarded half was the
    interesting one. A container's stderr comes back on the COMMAND's stderr,
    so reading stdout alone silently drops every warning the node emits --
    which is how a producer could sit and print "insufficient stake" every few
    seconds while the panel showed nothing but "Building block", and the
    eligibility check found no reason to report.
    """
    try:
        out = subprocess.run(
            args, timeout=timeout, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def find_container():
    """Locate the running node container, most reliable strategy first.

    Name, if configured. Otherwise the image tag. Otherwise the entrypoint
    command.

    The command fallback exists because `ancestor=` resolves the tag to an
    image ID: once that tag is reassigned or removed, a container that is
    still happily running stops matching and looks like it disappeared.
    Reporting a healthy node as missing is the worst failure this agent can
    have, so it is worth a third strategy.
    """
    if CONTAINER:
        return CONTAINER if run(["docker", "inspect", "-f", "{{.Id}}", CONTAINER]) else None

    out = run(["docker", "ps", "--filter", "ancestor=" + CONTAINER_IMAGE,
               "--format", "{{.Names}}"])
    if out:
        name = out.splitlines()[0].strip()
        if name:
            return name

    out = run(["docker", "ps", "--no-trunc", "--format", "{{.Names}}	{{.Image}}	{{.Command}}"])
    if out:
        for line in out.splitlines():
            parts = line.split("	")
            if len(parts) < 3:
                continue
            name, image, command = parts[0].strip(), parts[1].strip(), parts[2]
            if image == CONTAINER_IMAGE or (COMMAND_HINT and COMMAND_HINT in command):
                if name:
                    return name

    # Nothing running. Look for a STOPPED container of our image so we can
    # report why it stopped -- otherwise a container that crashed reports as
    # "missing", which is indistinguishable from never having existed.
    #
    # Deliberately matched on the image tag only, never the command hint:
    # unrelated old node containers from other images linger in `docker ps -a`
    # and reporting their stale exit code would be worse than saying nothing.
    out = run(["docker", "ps", "-a", "--filter", "ancestor=" + CONTAINER_IMAGE,
               "--format", "{{.Names}}"])
    if out:
        name = out.splitlines()[0].strip()
        if name:
            return name
    return None


def list_node_containers():
    """Every running container that looks like an XL1 node.

    Discovery returns one container, but more than one can be running -- an
    old container left behind after a rebuild, say. Silently monitoring the
    first and ignoring the rest hides exactly the situation worth flagging.
    """
    out = run(["docker", "ps", "--no-trunc", "--format", "{{.Names}}	{{.Image}}	{{.Command}}"])
    if not out:
        return []
    names = []
    for line in out.splitlines():
        parts = line.split("	")
        if len(parts) < 3:
            continue
        name, image, command = parts[0].strip(), parts[1].strip(), parts[2]
        if image == CONTAINER_IMAGE or (COMMAND_HINT and COMMAND_HINT in command):
            if name:
                names.append(name)
    return names


def container_info(name):
    """State, uptime, restart count and exit status straight from the daemon.

    Exit code and finish time matter when the container is down: "exited 78"
    (a config error) needs a different response than "exited 137" (OOM-killed),
    and knowing which without SSHing in is most of the value of monitoring.
    """
    fmt = ("{{.State.Status}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.Config.Image}}"
           "|{{.State.ExitCode}}|{{.State.FinishedAt}}|{{.State.Error}}"
           "|{{if .State.Health}}{{.State.Health.Status}}{{end}}")
    raw = run(["docker", "inspect", "-f", fmt, name])
    if not raw:
        return {}
    parts = raw.split("|")
    if len(parts) != 8:
        return {}
    status, started, restarts, image, exit_code, finished, error, health = parts

    def _int(value):
        try:
            return int(value)
        except (ValueError, TypeError):
            return None

    info = {"container_status": status, "container_started_at": started,
            "restart_count": _int(restarts), "image": image}
    # Docker's own healthcheck state. "starting" is the grace period after a
    # restart, when /livez is legitimately not answering yet -- distinguishing
    # it from "unhealthy" is what stops every restart looking like an outage.
    if health.strip():
        info["health_status"] = health.strip()
    # Only meaningful once it has stopped; a running container reports 0.
    if status != "running":
        info["exit_code"] = _int(exit_code)
        info["exited_at"] = finished or None
        if error.strip():
            info["container_error"] = error.strip()[:200]
    return info


def container_stats(name):
    """CPU/memory for the container itself (not the whole Pi)."""
    raw = run(["docker", "stats", "--no-stream", "--format",
               "{{.CPUPerc}}|{{.MemUsage}}", name], timeout=20)
    if not raw:
        return {}
    try:
        cpu_s, mem_s = raw.split("|")
        cpu = float(cpu_s.strip().rstrip("%"))
        mem = _to_mb(mem_s.split("/")[0].strip())
    except (ValueError, IndexError):
        return {}
    # Raspberry Pi OS disables the kernel memory cgroup by default, so docker
    # reports 0B here. That is "unavailable", not "zero" -- send null and let
    # host memory stand in, rather than rendering a convincing 0 MB.
    return {"cpu_percent": round(cpu, 2), "mem_used_mb": mem or None}


def _to_mb(value):
    """'412.3MiB' / '1.2GiB' -> megabytes."""
    units = [("GIB", 1024.0), ("MIB", 1.0), ("KIB", 1 / 1024), ("B", 1 / 1024 / 1024)]
    upper = value.upper()
    for suffix, factor in units:
        if upper.endswith(suffix):
            try:
                return round(float(value[: -len(suffix)]) * factor, 1)
            except ValueError:
                return None
    return None


def check_health(name):
    """(live, ready). Direct HTTP if the port is published, else docker exec."""
    if HEALTH_URL:
        return _http_ok(HEALTH_URL), None
    if not name:
        return False, None
    base = "http://127.0.0.1:" + HEALTH_PORT
    live = run(["docker", "exec", name, "curl", "-fsS", "-m", "5", base + "/livez"]) is not None
    if not live:
        return False, None
    ready = run(["docker", "exec", name, "curl", "-fsS", "-m", "5", base + "/readyz"])
    return True, ready is not None


def _http_ok(url):
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return 200 <= resp.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def fetch_block_height(network=None):
    """Current height for one network from the local xl1-service, or None.

    The service reaches XL1 through the SDK's read-only gateway; this agent
    never speaks JSON-RPC itself. Entirely optional -- if the service is not
    running, the heartbeat simply carries no heights.
    """
    if not HEIGHT_URL:
        return None
    url = HEIGHT_URL
    if network:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode({"network": network})
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            if not (200 <= resp.status < 300):
                return None
            height = json.loads(resp.read().decode("utf-8")).get("height")
        return int(height) if isinstance(height, (int, float)) else None
    except (urllib.error.URLError, OSError, ValueError, TypeError):
        return None


def fetch_block_heights():
    """{network: height} for every configured network, skipping failures."""
    out = {}
    for net in HEIGHT_NETWORKS:
        height = fetch_block_height(net)
        if height is not None:
            out[net] = height
    return out


def _windows_memory():
    """(total_mb, avail_mb, swap_total_mb, swap_avail_mb) on Windows, or Nones.

    There is no /proc here, so the numbers come from GlobalMemoryStatusEx.
    "Swap" is the page file, which is the honest analogue rather than the same
    thing: Windows commits memory against RAM plus page file together, so the
    page-file figures are what an operator would recognise as swap pressure.
    """
    try:
        import ctypes

        class _MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong),
                        ("dwMemoryLoad", ctypes.c_ulong),
                        ("ullTotalPhys", ctypes.c_ulonglong),
                        ("ullAvailPhys", ctypes.c_ulonglong),
                        ("ullTotalPageFile", ctypes.c_ulonglong),
                        ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong),
                        ("ullAvailVirtual", ctypes.c_ulonglong),
                        ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]

        st = _MEMORYSTATUSEX()
        st.dwLength = ctypes.sizeof(_MEMORYSTATUSEX)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
            return (None, None, None, None)
        mb = lambda b: round(b / 1048576.0, 1)
        # TotalPageFile is RAM + page file on Windows, so the page file alone is
        # the difference. Reported as swap because that is what it is used for.
        swap_total = max(0, st.ullTotalPageFile - st.ullTotalPhys)
        swap_avail = max(0, st.ullAvailPageFile - st.ullAvailPhys)
        return (mb(st.ullTotalPhys), mb(st.ullAvailPhys),
                mb(swap_total), mb(swap_avail))
    except Exception:
        return (None, None, None, None)


def read_swap_devices():
    """Swap split by what is actually backing it, or {}.

    SwapTotal in /proc/meminfo adds every device together, which on a
    Raspberry Pi means compressed RAM and an SD-card file counted as one
    number. They are not the same resource and they do not fail the same way:
    filling zram costs CPU and is routine, while touching the file means real
    pressure, slow reads and wear on the card the whole node boots from.

    rpi-swap wires them together deliberately -- the file is zram's writeback
    device -- so seeing both at once is what makes the pairing legible.

    /dev/zram* is the compressed-RAM side; anything else is backed by storage.
    """
    # Four counters rather than a dict keyed by strings. The guard that pins
    # heartbeat fields to the agent version reads every quoted dict key in
    # this function, so bucket names in a dict literal read to it as two new
    # fields nobody declared -- and it said so. (Writing that pattern out in
    # this comment tripped it a second time. Prose about a scanner is still
    # input to the scanner.)
    zram_used = zram_total = file_used = file_total = 0
    seen = False
    try:
        with open("/proc/swaps") as fh:
            next(fh, None)                     # the header
            for line in fh:
                parts = line.split()
                if len(parts) < 4:
                    continue
                name, _kind, size_kb, used_kb = parts[0], parts[1], parts[2], parts[3]
                try:
                    size_kb, used_kb = int(size_kb), int(used_kb)
                except ValueError:
                    continue
                if name.startswith("/dev/zram"):
                    zram_used += used_kb
                    zram_total += size_kb
                else:
                    file_used += used_kb
                    file_total += size_kb
                seen = True
    except (OSError, ValueError):
        return {}
    if not seen:
        return {}
    # Written out rather than built from the bucket name. The names are the
    # heartbeat's contract, and the guard that pins them to the agent version
    # reads this source -- a key assembled at runtime is one it cannot see, so
    # four new fields looked to it like four that had been removed.
    out = {}
    if zram_total:
        out["zram_used_mb"] = round(zram_used / 1024, 1)
        out["zram_total_mb"] = round(zram_total / 1024, 1)
    if file_total:
        out["swapfile_used_mb"] = round(file_used / 1024, 1)
        out["swapfile_total_mb"] = round(file_total / 1024, 1)
    return out


def _have(tool):
    """Whether a command exists on PATH. shutil is imported here rather than at
    the top because this is the only place the agent needs it."""
    import shutil
    return bool(shutil.which(tool))


# Set when vcgencmd is present but would not answer -- which is a failure, as
# distinct from not being on a Pi at all. Read by collect() so the operator
# sees "this could not be read" rather than a blank that looks deliberate.
_throttle_unreadable = False


def read_throttling():
    """The Pi's own account of power and clock, or {} anywhere else.

    `vcgencmd get_throttled` answers with a bit field. Four of its bits matter
    and they come in pairs: what is happening now, and what has happened since
    boot. The distinction is the useful part -- a board that undervolted once
    during a cold start is a different machine from one browning out under load
    right now, and collapsing them into "there was a problem" loses the half an
    operator would act on.

    Silent off a Pi, and silent when vcgencmd is not reachable. Neither is a
    failure: it is a question this hardware cannot be asked.
    """
    global _throttle_unreadable
    out = run(["vcgencmd", "get_throttled"], timeout=5)
    if not out or "=" not in out:
        # Only a failure if the tool is there. Absent means this is not a Pi,
        # which is an answer.
        _throttle_unreadable = _have("vcgencmd")
        return {}
    _throttle_unreadable = False
    try:
        bits = int(out.strip().split("=", 1)[1], 16)
    except (ValueError, IndexError):
        return {}
    return {
        "undervolted_now": bool(bits & 0x1),
        "undervolted_ever": bool(bits & 0x10000),
        "throttled_now": bool(bits & 0x4),
        "throttled_ever": bool(bits & 0x40000),
    }


def host_metrics():
    """Pi vitals: SoC temperature, root disk pressure, host uptime, RAM, swap,
    load and the board's own power and clock state.

    Every reader is guarded and simply absent when it cannot answer. Some of
    them cannot answer anywhere but a Pi -- SoC temperature and the throttling
    bits have no equivalent elsewhere -- and some cannot answer on Windows at
    all, load average being the obvious one: it is not a number that exists
    there, and inventing something from CPU percentage would be a different
    measurement wearing its name.
    """
    data = {}

    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as fh:
            data["temperature_c"] = round(int(fh.read().strip()) / 1000.0, 1)
    except (OSError, ValueError):
        pass

    try:
        with open("/proc/uptime") as fh:
            data["host_uptime_seconds"] = int(float(fh.read().split()[0]))
    except (OSError, ValueError, IndexError):
        pass

    if "host_uptime_seconds" not in data:
        # Windows keeps the same number behind a different door.
        try:
            import ctypes
            ticks = ctypes.windll.kernel32.GetTickCount64()
            data["host_uptime_seconds"] = int(ticks / 1000)
        except Exception:
            pass

    try:
        # statvfs is POSIX-only; guarded so the agent stays runnable off-Pi.
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total:
            data["disk_used_percent"] = round((total - free) / total * 100, 1)
            data["disk_free_gb"] = round(free / 1073741824.0, 1)
    except (OSError, AttributeError):
        pass

    if "disk_used_percent" not in data:
        # shutil answers everywhere, including Windows. Not the first choice on
        # a Pi: statvfs distinguishes free from available-to-this-user, and on
        # a filesystem with reserved blocks those differ by a few percent --
        # which is exactly the range where a disk warning fires.
        try:
            import shutil
            total, _, free = shutil.disk_usage(os.path.abspath(os.sep))
            if total:
                data["disk_used_percent"] = round((total - free) / total * 100, 1)
                data["disk_free_gb"] = round(free / 1073741824.0, 1)
        except Exception:
            pass

    try:
        meminfo = {}
        with open("/proc/meminfo") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                if key in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
                    meminfo[key] = int(rest.split()[0])
        if "MemTotal" in meminfo:
            data["mem_total_mb"] = round(meminfo["MemTotal"] / 1024, 1)
            if "MemAvailable" in meminfo:
                used = meminfo["MemTotal"] - meminfo["MemAvailable"]
                data["host_mem_used_mb"] = round(used / 1024, 1)
        # Swap sized as well as used. A percentage without the size behind it
        # cannot tell 3% of 100 MB from 3% of 5 GB, and on a board with 1 GB of
        # RAM that difference is the whole story.
        if "SwapTotal" in meminfo:
            data["swap_total_mb"] = round(meminfo["SwapTotal"] / 1024, 1)
            if "SwapFree" in meminfo:
                used = meminfo["SwapTotal"] - meminfo["SwapFree"]
                data["swap_used_mb"] = round(used / 1024, 1)
    except (OSError, ValueError, IndexError):
        pass

    # No /proc: ask Windows for the same four numbers.
    if "mem_total_mb" not in data:
        total, avail, swap_total, swap_avail = _windows_memory()
        if total is not None:
            data["mem_total_mb"] = total
            if avail is not None:
                data["host_mem_used_mb"] = round(total - avail, 1)
        if swap_total:
            data["swap_total_mb"] = swap_total
            if swap_avail is not None:
                data["swap_used_mb"] = round(swap_total - swap_avail, 1)

    # Load, and the cores it is spread over. One without the other says very
    # little: 4.0 is a busy single-core board and an idle quad.
    try:
        one, five, fifteen = os.getloadavg()
        data["load_1"] = round(one, 2)
        data["load_5"] = round(five, 2)
        data["load_15"] = round(fifteen, 2)
    except (OSError, AttributeError):
        # Windows has no load average. Not a failure -- there is no such number
        # to read, and deriving one from CPU percentage would be a different
        # measurement borrowing the name.
        pass

    cores = os.cpu_count()
    if cores:
        data["cpu_cores"] = cores

    data.update(read_swap_devices())
    data.update(read_throttling())

    return data


_warned = set()


def _warn_once(key, message):
    """Say why something is not happening, once, rather than failing silently.

    A component that quietly does nothing looks identical to one that is
    working, which is the hardest kind of fault to notice.
    """
    if key not in _warned:
        _warned.add(key)
        print("WARN: %s" % message, file=sys.stderr, flush=True)


_producer_cache = {"at": 0.0, "value": None}
# Where to resume scanning. Supplied by the backend on every heartbeat
# response, so this agent stores nothing durable of its own.
# "known" flips once the backend has told us where it is up to. Until then a
# scan would have to guess a range, and after a restart that guess overlaps
# already-counted blocks and is rightly rejected -- burning a whole cycle.
_producer_cursor = {"block": None, "backfill": None, "backfill_done": False,
                    "minted": None, "minted_done": False,
                    "known": False, "last_produced": None}

# Explorer link for the block the panel displays, keyed by block number so it
# is fetched once rather than on every beat.
_explorer_link = {"block": None, "url": None}


def read_reward_address(name):
    """Reward address from the node container, or None.

    Reads the container environment, which also holds XL1_MNEMONIC. Only the
    reward address is extracted; nothing else is retained, logged, or sent.
    The reward address is public -- it appears in every block the node
    produces -- whereas the mnemonic must never leave the Pi.
    """
    if REWARD_ADDRESS:
        return REWARD_ADDRESS
    if not name:
        return None
    raw = run(["docker", "inspect", "-f",
               "{{range .Config.Env}}{{println .}}{{end}}", name])
    if not raw:
        return None
    for line in raw.splitlines():
        if line.startswith("XL1_REWARD_ADDRESS="):
            # docker --env-file does not strip quotes, so a value written as
            # KEY="0xabc..." arrives with them attached.
            value = line.split("=", 1)[1].strip().strip('"').strip("'")
            if re.fullmatch(r"(0x)?[0-9a-fA-F]{40}", value):
                return value
            _warn_once("reward-format",
                       "XL1_REWARD_ADDRESS in the container is not a 20-byte "
                       "address; block production will not be counted")
            return None
    _warn_once("reward-missing",
               "XL1_REWARD_ADDRESS not found in the node container; set it in "
               "/etc/xl1-heartbeat.env to count block production")
    return None


def _producer_request(address, params, timeout=180):
    """One call to the local producer endpoint. Returns parsed JSON or None.

    The timeout is an argument because the callers are not alike: the forward
    scan reads a dozen blocks and the history walks thousands, and one number
    cannot be generous to the second without hiding a hang in the first.
    """
    query = urllib.parse.urlencode({"address": address, **params})
    try:
        with urllib.request.urlopen(PRODUCER_URL + "?" + query, timeout=timeout) as resp:
            if not (200 <= resp.status < 300):
                return None
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as e:
        _warn_once("producer-request",
                   "producer endpoint unreachable at %s (%s); block production "
                   "will not be counted" % (PRODUCER_URL, type(e).__name__))
        return None


def fetch_backfill_chunk(name):
    """One chunk of historical blocks, walking down toward genesis.

    Returns None until forward counting has started -- the backend supplies
    the cursor, so there is nothing to walk back from before then.
    """
    if not PRODUCER_URL or BACKFILL_CHUNK <= 0:
        return None
    if _producer_cursor["backfill_done"]:
        return None
    cursor = _producer_cursor["backfill"]
    if cursor is None or cursor < 0:
        return None
    address = read_reward_address(name)
    if not address:
        return None
    start = max(0, cursor - BACKFILL_CHUNK + 1)
    return _producer_request(address, {"from": start, "to": cursor})


def minted_by_day(stats):
    """{"YYYY-MM-DD": "<atto>"} from a scan result, or None.

    Validated rather than forwarded, because this one is accumulated: the
    backend adds it to a running per-day total, so a malformed key or a
    negative value would corrupt a figure nobody re-derives afterwards. A
    date that is not a date, or an amount that is not a non-negative integer
    string, drops the whole map rather than a part of it -- a partial day is
    worse than a missing one, because it looks like a real number.

    Capped at 400 days. A 50000-block chunk spans about 35 days at a 60s
    block time, so anything near the cap is a bug rather than a big chunk.
    """
    raw = (stats or {}).get("mintedByDay")
    if not isinstance(raw, dict) or not raw:
        return None
    if len(raw) > 400:
        return None
    out = {}
    for day, atto in raw.items():
        if not isinstance(day, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
            return None
        if not isinstance(atto, str) or not re.fullmatch(r"[0-9]{1,40}", atto):
            return None
        out[day] = atto
    return out


def fetch_minted_chunk(name):
    """One chunk of mint history, walking down toward genesis.

    Separate from the block backfill because that one completes and stops. A
    node that finished counting blocks before this existed still has its whole
    mint history to collect, and would never be asked for it otherwise.
    """
    if not PRODUCER_URL or BACKFILL_CHUNK <= 0:
        return None
    if _producer_cursor["minted_done"]:
        return None
    cursor = _producer_cursor["minted"]
    if cursor is None or cursor < 0:
        return None
    address = read_reward_address(name)
    if not address:
        return None
    start = max(0, cursor - MINTED_CHUNK + 1)
    return _producer_request(address, {"from": start, "to": cursor}, timeout=600)


def explorer_block_url(block):
    """Explorer URL for one block, from the local service, or None.

    The service builds it with the SDK; this agent must not assemble explorer
    paths itself. Cached by block number, and any failure is swallowed -- a
    cosmetic link must never cost a heartbeat.
    """
    if not block or not PRODUCER_URL:
        return None
    if _explorer_link["block"] == block:
        return _explorer_link["url"]
    base = PRODUCER_URL.rsplit("/producer", 1)[0]
    url = "%s/explorer/block/%d?network=%s" % (
        base, block, urllib.parse.quote(NODE_NETWORK))
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        link = body.get("url")
    except Exception:
        return None
    if isinstance(link, str) and link.startswith("https://"):
        _explorer_link["block"] = block
        _explorer_link["url"] = link
        return link
    return None


def fetch_producer_stats(name):
    """Block production counts for this node's reward address, or None.

    Refreshed every PRODUCER_INTERVAL seconds rather than every heartbeat.
    The address is sent only to the service on this host's loopback; the
    heartbeat carries counts alone, never the address.
    """
    if not PRODUCER_URL:
        return None
    if not _producer_cursor["known"]:
        # Wait for one heartbeat response. The cursor is held by the backend so
        # a reimaged Pi resumes correctly, which means a freshly started agent
        # does not know it yet -- and scanning blind would overlap.
        return None
    now = time.monotonic()
    # Rate limiter, not a cache to serve from: returning the previous scan
    # would re-send an already-counted range on every heartbeat, ~30 payloads
    # per cycle that the backend can only reject as replays. Report a scan
    # once, when it is actually new.
    if _producer_cache["at"] and now - _producer_cache["at"] < PRODUCER_INTERVAL:
        return None

    address = read_reward_address(name)
    if not address:
        return None
    params = {"address": address, "window": PRODUCER_WINDOW}
    if _producer_cursor["block"] is not None:
        # Scan only what is new. ~15 blocks per 15 minutes at a 60s block time,
        # versus re-reading the whole window every cycle.
        params["since"] = _producer_cursor["block"]
    stats = _producer_request(address, params)
    if stats is None:
        return None
    _producer_cache["at"] = now
    _producer_cache["value"] = stats
    return stats


def producer_scan_due():
    """Whether a production scan should have run on this beat.

    fetch_producer_stats returns None for two very different reasons: the scan
    is not due (the overwhelmingly common case -- it runs once per
    PRODUCER_INTERVAL, roughly one heartbeat in thirty), or it was due and
    failed. Only the second is a fault.

    Conflating them reported a perfectly healthy node as half-blind on 29 beats
    out of 30, naming the most consequential reader it has. The rate limiter is
    stamped only on success, so after a real failure this stays true and the
    fault is still reported.
    """
    if not PRODUCER_URL or not _producer_cursor["known"]:
        return False
    if not _producer_cache["at"]:
        return True
    return (time.monotonic() - _producer_cache["at"]) >= PRODUCER_INTERVAL


_cli_cache = {"installed_at": 0.0, "installed": None,
              "latest_at": 0.0, "latest": None}


def read_cli_version(name):
    """Version of the XL1 CLI inside the running container, or None.

    Read from the container rather than the image tag: the tag can be moved
    without recreating anything, so it is not evidence of what is running.

    This is the only `docker exec` left once health is read over HTTP, and
    exec is the call that makes socket access dangerous. Setting
    XL1_CLI_REGISTRY empty turns version checking off entirely -- both halves,
    since a local version with nothing to compare it against is not useful --
    which lets the agent run against a read-only Docker API.
    """
    if not name or not CLI_REGISTRY:
        return None
    now = time.monotonic()
    if _cli_cache["installed"] and now - _cli_cache["installed_at"] < 3600:
        return _cli_cache["installed"]
    raw = run(["docker", "exec", name, "cat", CLI_PACKAGE_PATH])
    if not raw:
        return None
    try:
        version = json.loads(raw).get("version")
    except (ValueError, AttributeError):
        return None
    if not _valid_version(version):
        return None
    if version:
        _cli_cache["installed"] = version
        _cli_cache["installed_at"] = now
    return version


_sdk_cache = {"installed_at": 0.0, "installed": None,
              "latest_at": 0.0, "latest": None}


def read_sdk_version():
    """Version of the XL1 SDK the companion service actually loaded, or None.

    Cached for an hour: it can only change when that service is redeployed,
    and a heartbeat must never wait on it.
    """
    if not VERSIONS_URL:
        return None
    now = time.monotonic()
    if _sdk_cache["installed"] and now - _sdk_cache["installed_at"] < 3600:
        return _sdk_cache["installed"]
    try:
        with urllib.request.urlopen(VERSIONS_URL, timeout=10) as resp:
            if not (200 <= resp.status < 300):
                return None
            packages = json.loads(resp.read().decode("utf-8")).get("packages") or {}
    except (urllib.error.URLError, OSError, ValueError):
        # The service being down is already reported by other fields; it must
        # not also cost us the heartbeat.
        return None
    version = packages.get(SDK_PACKAGE)
    if not _valid_version(version):
        return None
    _sdk_cache["installed"] = version
    _sdk_cache["installed_at"] = now
    return version


def fetch_sdk_latest():
    """Newest published XL1 SDK version, or None. Checked a few times a day."""
    if not SDK_REGISTRY:
        return None
    now = time.monotonic()
    if _sdk_cache["latest"] and now - _sdk_cache["latest_at"] < CLI_CHECK_INTERVAL:
        return _sdk_cache["latest"]
    try:
        with urllib.request.urlopen(SDK_REGISTRY, timeout=20) as resp:
            if not (200 <= resp.status < 300):
                return None
            version = json.loads(resp.read().decode("utf-8")).get("version")
    except (urllib.error.URLError, OSError, ValueError):
        return None
    if not _valid_version(version):
        _warn_once("sdk-version-format",
                   "registry returned an implausible SDK version; ignoring it")
        return None
    _sdk_cache["latest"] = version
    _sdk_cache["latest_at"] = now
    return version


def fetch_cli_latest():
    """Newest published CLI version, or None. Checked a few times a day."""
    if not CLI_REGISTRY:
        return None
    now = time.monotonic()
    if _cli_cache["latest"] and now - _cli_cache["latest_at"] < CLI_CHECK_INTERVAL:
        return _cli_cache["latest"]
    try:
        with urllib.request.urlopen(CLI_REGISTRY, timeout=20) as resp:
            if not (200 <= resp.status < 300):
                return None
            version = json.loads(resp.read().decode("utf-8")).get("version")
    except (urllib.error.URLError, OSError, ValueError):
        # Never let a registry outage affect the heartbeat.
        return None
    if not _valid_version(version):
        _warn_once("cli-version-format",
                   "registry returned an implausible version; ignoring it")
        return None
    if version:
        _cli_cache["latest"] = version
        _cli_cache["latest_at"] = now
    return version


_repo_cache = {"upstream_at": 0.0, "upstream": None, "behind": None,
               "local_tag": None, "upstream_tag": None}

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def read_repo_head():
    """The commit the local images checkout sits on, or None.

    Read straight out of .git rather than by running git. The repo belongs to
    the operator and this agent runs as its own user, so git would refuse it as
    "dubious ownership" -- the same refusal the rebuild script has to work
    around. Reading the files sidesteps the question entirely, and needs no
    subprocess.
    """
    try:
        head_path = os.path.join(IMAGES_REPO, ".git", "HEAD")
        with open(head_path, "r", encoding="utf-8") as fh:
            head = fh.read().strip()
    except OSError:
        return None
    if _SHA_RE.match(head):
        return head  # detached HEAD
    if not head.startswith("ref: "):
        return None
    ref = head[5:].strip()
    try:
        with open(os.path.join(IMAGES_REPO, ".git", ref), "r", encoding="utf-8") as fh:
            sha = fh.read().strip()
        return sha if _SHA_RE.match(sha) else None
    except OSError:
        pass
    # Loose ref absent: it has been packed. packed-refs is "<sha> <refname>".
    try:
        with open(os.path.join(IMAGES_REPO, ".git", "packed-refs"), "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) == 2 and parts[1] == ref and _SHA_RE.match(parts[0]):
                    return parts[0]
    except OSError:
        pass
    return None


def _github_json(url):
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "xl1-node-monitor",
    })
    with urllib.request.urlopen(req, timeout=20) as resp:
        if not (200 <= resp.status < 300):
            return None
        return json.loads(resp.read().decode("utf-8"))


def fetch_repo_upstream(local):
    """(upstream_sha, commits_behind, local_tag, upstream_tag).

    Checked a few times a day. Unauthenticated GitHub allows 60 requests an
    hour per address; at the CLI check interval this uses three at most.

    Tags are looked up because a release name is legible and a commit hash is
    not: "v5.2.2" tells an operator where they stand, "e48317d" asks them to go
    and find out. The API dereferences annotated tags to their commit for us,
    which reading .git directly would not.
    """
    if not IMAGES_REPO_API:
        return None, None, None, None
    now = time.monotonic()
    if _repo_cache["upstream"] and now - _repo_cache["upstream_at"] < CLI_CHECK_INTERVAL:
        return (_repo_cache["upstream"], _repo_cache["behind"],
                _repo_cache["local_tag"], _repo_cache["upstream_tag"])
    try:
        body = _github_json("%s/commits/%s" % (IMAGES_REPO_API, IMAGES_REPO_BRANCH))
        upstream = (body or {}).get("sha")
    except (urllib.error.URLError, OSError, ValueError):
        return None, None, None, None  # an API outage must never affect a heartbeat
    if not upstream or not _SHA_RE.match(upstream):
        return None, None, None, None

    behind = None
    if local and local != upstream:
        try:
            cmp_body = _github_json("%s/compare/%s...%s" % (IMAGES_REPO_API, local, upstream))
            value = (cmp_body or {}).get("ahead_by")
            if isinstance(value, int) and value >= 0:
                behind = value
        except (urllib.error.URLError, OSError, ValueError):
            # A local commit upstream has never seen gives a 404 here. The
            # checkout still differs; we just cannot say by how much.
            behind = None

    # A commit with no tag is normal -- upstream commits between releases --
    # so both of these are frequently absent and the panel falls back to the
    # short sha.
    tags = {}
    try:
        for tag in (_github_json("%s/tags?per_page=100" % IMAGES_REPO_API) or []):
            sha = (tag.get("commit") or {}).get("sha")
            name = tag.get("name")
            if sha and name and sha not in tags:
                tags[sha] = name[:32]
    except (urllib.error.URLError, OSError, ValueError, AttributeError):
        pass

    _repo_cache["upstream"] = upstream
    _repo_cache["behind"] = behind
    _repo_cache["local_tag"] = tags.get(local) if local else None
    _repo_cache["upstream_tag"] = tags.get(upstream)
    _repo_cache["upstream_at"] = now
    return (upstream, behind,
            _repo_cache["local_tag"], _repo_cache["upstream_tag"])


def read_rebuild_timer():
    """(active, next_run) for the image rebuild timer, or (None, None).

    `systemctl show` needs no privilege for this, and reports the timer's own
    view rather than ours. A host with no such timer reports nothing and the
    email falls back to manual instructions, which is the honest answer.
    """
    if not REBUILD_TIMER:
        return None, None
    out = run(["systemctl", "show", REBUILD_TIMER,
               "-p", "ActiveState", "-p", "NextElapseUSecRealtime"])
    if not out:
        return None, None
    fields = {}
    for line in out.splitlines():
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    state = fields.get("ActiveState")
    if not state or state == "":
        return None, None
    active = state == "active"
    raw = fields.get("NextElapseUSecRealtime", "")
    nxt = None
    if raw and raw not in ("0", "n/a", "infinity"):
        if raw.isdigit():
            # Older systemd reports microseconds since the epoch; newer ones
            # already give a human timestamp. Accept either.
            try:
                nxt = time.strftime("%a %d %b %H:%M UTC",
                                    time.gmtime(int(raw) / 1_000_000))
            except (ValueError, OSError, OverflowError):
                nxt = None
        else:
            nxt = raw[:64]
    return active, nxt


_standing_cache = {"at": 0.0, "value": None}


def fetch_standing(name):
    """(balance, funded, symbol, raw, stake_raw, stake_min_raw), or all None.

    The stake pair is read by the service from the chain's BACKING EVM -- it is
    not on XL1 -- and is absent unless that service has an EVM endpoint
    configured. Absent and zero are different answers and are kept different:
    zero stake is the thing that stops a producer being scheduled, so an
    unconfigured or unreachable read must never arrive looking like it.

    Same cadence as the production scan: this is one RPC call, but it answers a
    question that changes slowly, and a heartbeat must never wait on it.

    The symbol comes from the service rather than being assumed here, so the
    panel cannot end up labelling a number with a ticker nothing verified. The
    raw, undivided value is carried because the displayed float is rounded: a
    balance of a few wei shows as 0.00 beside a tile saying "funded to
    produce", and only the raw resolves which is true.
    """
    if not STANDING_URL:
        return NO_STANDING
    address = read_reward_address(name)
    if not address:
        return NO_STANDING
    now = time.monotonic()
    cached = _standing_cache["value"]
    if cached is not None and now - _standing_cache["at"] < STANDING_INTERVAL:
        return cached
    try:
        url = STANDING_URL + "?" + urllib.parse.urlencode(
            {"address": address, "network": NODE_NETWORK})
        with urllib.request.urlopen(url, timeout=60) as resp:
            if not (200 <= resp.status < 300):
                return NO_STANDING
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return NO_STANDING
    balance = body.get("balance")
    funded = body.get("fundedForProduction")
    symbol = body.get("symbol")
    raw = body.get("balanceRaw")
    if not isinstance(balance, (int, float)):
        balance = None
    if not isinstance(funded, bool):
        funded = None
    # An older service does not send these; the panel falls back rather than
    # inventing a ticker.
    if not isinstance(symbol, str) or not re.fullmatch(r"[A-Za-z0-9]{1,12}", symbol):
        symbol = None
    if not isinstance(raw, str) or not re.fullmatch(r"[0-9]{1,40}", raw):
        raw = None
    # An older service, or one with no EVM endpoint, sends no stake at all.
    stake = body.get("stake")
    stake_raw = stake.get("activeRaw") if isinstance(stake, dict) else None
    stake_min_raw = stake.get("minStakeRaw") if isinstance(stake, dict) else None
    if not isinstance(stake_raw, str) or not re.fullmatch(r"[0-9]{1,40}", stake_raw):
        stake_raw = None
    if not isinstance(stake_min_raw, str) or not re.fullmatch(r"[0-9]{1,40}", stake_min_raw):
        stake_min_raw = None
    # Only cache an answer. A 200 carrying a null balance is a failure wearing
    # a success's clothes -- the service returns one when it cannot read the
    # chain, or when it was handed an address it will not accept. Caching that
    # for the full interval pins the tile blank long after the cause is fixed,
    # which is precisely what happened the first time this shipped.
    if balance is None:
        return NO_STANDING
    _standing_cache["value"] = (balance, funded, symbol, raw, stake_raw, stake_min_raw)
    _standing_cache["at"] = now
    return _standing_cache["value"]


NO_STANDING = (None, None, None, None, None, None)


_peers_cache = {"at": 0.0, "value": None}


# Beside the other interval caches rather than next to the function that
# uses it. The reported-fields guard reads `"key":` literals inside
# collect() as heartbeat fields, and a cache declared in that span is read
# as one -- a false positive that costs more to explain than to avoid.
# None, not 0.0, because time.monotonic() counts from boot. Zero means "an
# hour has passed" only on a machine that has been up an hour -- so a freshly
# rebooted node would silently wait up to ATTEST_INTERVAL before its first
# anchor, and the same arithmetic made six tests pass locally and fail on a CI
# runner that had been alive for twenty seconds. None says "never run" without
# depending on how long the host has been awake.
_attest_cache = {"at": None, "signer": None}


_earnings_cache = {"at": 0.0, "value": None}


def fetch_earnings(name):
    """What the reward address earned by producing, or None.

    Returns (earned, blocks_rewarded, reward_per_block, non_reward, sdk_ok).

    Why this is not derived from the balance. A balance rises when a block is
    produced and also when someone sends XL1 in, and falls when any is sent
    out. The service splits them: block rewards are minted, so a balance built
    only from rewards is an exact multiple of the per-block reward, and the
    remainder is everything that cannot be reward money.

    It is a lifetime figure. The balance carries the whole history, so this
    does not begin the day monitoring did -- which the day-over-day figure
    does, and which is why the two will not agree.

    sdk_ok carries the service's cross-check against the SDK reward schedule.
    False is not a reason to drop the reading: the chain is what was actually
    paid. It is a reason for the panel to say so.
    """
    if not EARNINGS_URL:
        return None
    address = read_reward_address(name)
    if not address:
        return None
    now = time.monotonic()
    cached = _earnings_cache["value"]
    if cached is not None and now - _earnings_cache["at"] < EARNINGS_INTERVAL:
        return cached
    try:
        url = EARNINGS_URL + "?" + urllib.parse.urlencode(
            {"address": address, "network": NODE_NETWORK})
        with urllib.request.urlopen(url, timeout=60) as resp:
            if not (200 <= resp.status < 300):
                return None
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return None
    earned = body.get("earned")
    blocks = body.get("blocksRewarded")
    reward = body.get("rewardPerBlock")
    non_reward = body.get("nonReward")
    sdk_ok = body.get("sdkAgrees")
    # A 200 carrying nulls is the service saying it could not read, which is a
    # failure wearing a success code. Do not cache it, and do not report it.
    if not isinstance(earned, (int, float)) or not isinstance(reward, (int, float)):
        return None
    if not isinstance(blocks, int):
        return None
    if not isinstance(non_reward, (int, float)):
        non_reward = None
    if not isinstance(sdk_ok, bool):
        sdk_ok = None
    _earnings_cache["value"] = (earned, blocks, reward, non_reward, sdk_ok)
    _earnings_cache["at"] = now
    return _earnings_cache["value"]


def fetch_peers(name):
    """(peer_count, our_share_percent, window) for the producing field.

    A block count on its own says nothing: the same number is healthy against
    three other producers and alarming against ten. The share, and whether the
    share moved, is what makes a quiet day readable.

    Only aggregates are sent. The other producers' addresses stay on this
    machine for the same reason ours does -- they are public on the chain, but
    a dashboard has no need to hold a list of them, and not collecting is
    simpler than deciding later who may read it.

    No predicted share is computed. Blocks are not handed out in proportion to
    balance -- measured over 1000 blocks, a 10x balance spread produced a 2x
    block spread -- so any "expected" figure would be a model invented here
    rather than anything the chain does.
    """
    if not PEERS_URL:
        return None, None, None
    address = read_reward_address(name)
    if not address:
        return None, None, None
    now = time.monotonic()
    cached = _peers_cache["value"]
    if cached is not None and now - _peers_cache["at"] < PEERS_INTERVAL:
        return cached
    try:
        url = PEERS_URL + "?" + urllib.parse.urlencode(
            {"network": NODE_NETWORK, "window": PEERS_WINDOW})
        with urllib.request.urlopen(url, timeout=120) as resp:
            if not (200 <= resp.status < 300):
                return None, None, None
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return None, None, None

    producers = body.get("producers")
    total = body.get("totalBlocks")
    if not isinstance(producers, list) or not isinstance(total, int) or total <= 0:
        return None, None, None

    # NOT lstrip("0x") -- that strips every leading 0 and x, so 0x0a65... loses
    # its leading zero, never matches, and the node silently reports a 0% share
    # of its own blocks. The same class of quiet wrongness as the prefix bug
    # that once made a working balance look unreadable.
    target = re.sub(r"^0x", "", address.lower())
    mine = 0
    for p in producers:
        if isinstance(p, dict) and str(p.get("address", "")).lower() == target:
            mine = p.get("blocks") or 0
            break
    value = (len(producers), round(100.0 * mine / total, 2), body.get("window"))
    # Cache only a real answer, for the same reason the balance does: a cached
    # failure pins the tile blank long after the cause is gone.
    _peers_cache["value"] = value
    _peers_cache["at"] = now
    return value


_attestor_cache = {"at": None, "value": None}


def fetch_attestor_balance():
    """(address, balance, raw) for the wallet that pays for anchoring, or Nones.

    Every hourly anchor costs gas from a throwaway key that controls nothing.
    It was funded once by hand, and nothing watches it -- so the failure this
    prevents is anchoring stopping quietly, months from now, because a wallet
    nobody was looking at reached zero. The panel that proves the readings
    have not been edited would simply stop having anything to prove.

    The address is not configured anywhere: it arrives in the anchoring
    response, which is the only place that knows it, and is remembered from
    there. Before the first anchor of a run there is nothing to report, which
    is correct -- an unconfigured anchoring service has no wallet to watch.

    Same slow cadence as the producer's own standing. A balance that moves by
    a ten-thousandth of a token per hour does not need a faster question.
    """
    signer = _attest_cache.get("signer")
    if not STANDING_URL or not signer:
        return None, None, None
    now = time.monotonic()
    cached = _attestor_cache["value"]
    at = _attestor_cache["at"]
    if cached is not None and at is not None and now - at < STANDING_INTERVAL:
        return cached
    try:
        url = STANDING_URL + "?" + urllib.parse.urlencode(
            {"address": signer, "network": NODE_NETWORK})
        with urllib.request.urlopen(url, timeout=60) as resp:
            if not (200 <= resp.status < 300):
                return None, None, None
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return None, None, None
    balance = body.get("balance")
    raw = body.get("balanceRaw")
    if not isinstance(balance, (int, float)):
        balance = None
    if not isinstance(raw, str) or not re.fullmatch(r"[0-9]{1,40}", raw):
        raw = None
    if balance is None:
        # Same rule as the producer's standing: a 200 carrying no balance is a
        # failure wearing a success's clothes, and caching it would pin the
        # tile blank long after the cause was gone.
        return None, None, None
    value = (signer, balance, raw)
    _attestor_cache["value"] = value
    _attestor_cache["at"] = now
    return value


_anchor_cost_cache = {"at": None, "value": None}


def fetch_anchor_cost():
    """What one anchor costs this wallet, measured on the chain, or None.

    The panels used to estimate this and both estimates were wrong in ways
    that mattered. One carried a constant measured by hand months earlier; the
    other derived it as (funded - balance) / anchors, which is arithmetic on an
    assumed starting balance -- fine on the wallet it was written for, meaning
    nothing on anyone else's, and actively broken after a top-up, where it
    reports a negative spend and therefore an infinite runway. A wallet that
    has just been funded is exactly when a runway must not read "forever".

    So the number comes from the chain: every anchor leaves a transfer from
    this wallet, and the service takes the median of the recent ones. None is
    a perfectly good answer -- a wallet that has not anchored yet has no cost
    to measure -- and the panel then shows a balance without a runway rather
    than a runway without a basis.
    """
    signer = _attest_cache.get("signer")
    if not ANCHOR_COST_URL or not signer:
        return None
    now = time.monotonic()
    cached = _anchor_cost_cache["value"]
    at = _anchor_cost_cache["at"]
    if cached is not None and at is not None and now - at < STANDING_INTERVAL:
        return cached
    try:
        url = ANCHOR_COST_URL + "?" + urllib.parse.urlencode(
            {"address": signer, "network": NODE_NETWORK})
        with urllib.request.urlopen(url, timeout=60) as resp:
            if not (200 <= resp.status < 300):
                return None
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return None
    cost = body.get("costPerAnchor")
    if not isinstance(cost, (int, float)) or cost <= 0:
        # Not cached. An unmeasurable wallet becomes measurable the moment it
        # anchors twice, and caching the null would hold the tile back for a
        # quarter of an hour after the data arrived.
        return None
    _anchor_cost_cache["value"] = cost
    _anchor_cost_cache["at"] = now
    return cost


WITNESS_URL = os.environ.get("XL1_WITNESS_URL", "")


def fetch_witness_target():
    """Another device's latest anchor, for this one to commit to. Or None.

    Devices here accept no inbound connections -- that is what makes them safe
    to run at home -- so one cannot reach out and touch another. What it can do
    is put a peer's anchor hash inside its own anchor. It cannot forge that:
    the hash belongs to the peer and is already on chain, so anybody can check
    the reference points at something real, and that this anchor came after it.

    It proves nothing about the peer being a different person. One operator can
    run both ends. This is a record of mutual reference, not a reputation.

    Absent is a perfectly good answer -- on a grid of one there is nothing to
    witness, and anchoring proceeds unchanged.
    """
    if not WITNESS_URL or not NODE_TOKEN:
        return None
    try:
        url = WITNESS_URL + "?" + urllib.parse.urlencode({"node_id": NODE_ID})
        req = urllib.request.Request(url, headers={"X-Node-Token": NODE_TOKEN})
        with urllib.request.urlopen(req, timeout=30) as resp:
            if not (200 <= resp.status < 300):
                return None
            target = (json.loads(resp.read().decode("utf-8")) or {}).get("target")
    except (urllib.error.URLError, OSError, ValueError):
        return None
    if not isinstance(target, dict):
        return None
    node = target.get("node_id")
    digest = target.get("content_hash")
    # Checked here as well as at the far end: a malformed reference would be
    # hashed into the anchor and then be wrong on chain for good.
    if not isinstance(node, str) or not node:
        return None
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        return None
    return {"node": node[:64], "hash": digest}


def read_blocked_reason(name):
    """Why the node says it cannot produce, or None if it has not said so.

    Scans a window of its own log rather than the whole history: a complaint
    from days ago that has since been resolved is not a current fault, and
    reporting it as one would be worse than reporting nothing.
    """
    if not name or not BLOCKED_PATTERNS:
        return None
    # merge_stderr: the node announces ineligibility on stderr.
    out = run(["docker", "logs", "--since", ELIGIBILITY_WINDOW, name],
              timeout=30, merge_stderr=True)
    if not out:
        return None
    lowered = out.lower()
    for needle, reason in BLOCKED_PATTERNS:
        if needle in lowered:
            return reason
    return None


_BUILD_MS = re.compile(r"generated\s+time\s+payload\s+in\s+(\d+(?:\.\d+)?)\s*ms",
                       re.IGNORECASE)


def read_build_times(name):
    """How long the node took to build blocks, or None.

    Returns (samples, avg_ms, max_ms, over_budget), or None if the log could
    not be read at all.

    samples of 0 -- with no average and no peak -- means the log WAS read and
    held no build lines. That is a node which has built nothing, and it is a
    different fact from a node we could not ask. Both used to come back as
    None, so the panel said "not reported" about a node that was reporting
    perfectly well and simply had nothing to time. On a device that is up but
    never selected to produce, that is not a temporary gap; it is the steady
    state, and it read as a broken reader for as long as it lasted.

    THE SAMPLE IS NOT EVERY ATTEMPT. The node decides which of these lines to
    print -- on the machines seen so far it tags them "[Slow]" and prints them
    when it judges the build slow by its own standard, which is far below the
    budget here. So the average is the average of what was logged, not the
    node's mean build time, and it is biased upward by exactly the builds the
    node thought worth mentioning.

    That is still worth reporting, because the question being asked is "are
    the slow ones getting slower", and a trend in the logged figures answers
    it. But the count travels with the numbers so the reader can see what they
    are an average OF -- three samples in an hour is a different claim from
    three hundred, and without the count both render as one confident figure.

    Windowed rather than cumulative, for the same reason read_blocked_reason
    is: a slow build last Tuesday is not a current fault.
    """
    if not name or not BUILD_WINDOW:
        return None
    # merge_stderr for the same reason as everywhere else here -- the node
    # splits its output across both streams and reading one silently halves it.
    out = run(["docker", "logs", "--since", BUILD_WINDOW, name],
              timeout=30, merge_stderr=True)
    # None means run() could not get an answer -- the container is gone, docker
    # refused us, the call timed out. An empty string means it answered with an
    # empty log, which is a reading. Only the first is "we do not know".
    if out is None:
        return None
    vals = []
    for match in _BUILD_MS.finditer(out):
        try:
            value = float(match.group(1))
        except ValueError:
            continue
        # A build cannot take negative time, and an hour is a misparse rather
        # than a very slow Pi. Bounded so one malformed line cannot drag the
        # average somewhere impossible.
        if 0 <= value <= 3_600_000:
            vals.append(value)
    if not vals:
        # Read it, found nothing to time. Deliberately not (0, 0, 0, 0): a zero
        # average would render as instant builds, which is the opposite of what
        # happened.
        return (0, None, None, 0)
    # Newest, if a busy hour produced more than we intend to weigh.
    vals = vals[-BUILD_SAMPLES_MAX:]
    over = sum(1 for v in vals if v > BUILD_BUDGET_MS)
    return (len(vals), round(sum(vals) / len(vals)), round(max(vals)), over)


def read_log_tail(name):
    """The last few lines the node printed, or None.

    Pushed rather than pulled: nothing on this machine accepts inbound
    connections, so the panel cannot ask for a log. It gets whatever the last
    heartbeat carried.
    """
    if not name or LOG_TAIL_LINES <= 0:
        return None
    # Ask docker for more lines than we intend to keep.
    #
    # Blank lines are dropped after the fact, so a tail of exactly N arrives as
    # fewer than N and the panel's count wobbles -- 20 lines one minute, 16 the
    # next, for no reason the reader can see. Over-fetching keeps it at N
    # whenever the log actually holds N non-blank lines, which is the whole
    # point of asking for a fixed number.
    fetch = min(LOG_TAIL_LINES * 5, LOG_TAIL_LINES + 200)
    # merge_stderr: a log tail that shows only stdout is not a log tail. The
    # lines an operator most needs -- warnings, errors, refusals -- are exactly
    # the ones the node writes to the other stream.
    out = run(["docker", "logs", "--tail", str(fetch), name],
              timeout=20, merge_stderr=True)
    if not out:
        return None
    lines = [ln[:LOG_TAIL_MAX_CHARS] for ln in out.splitlines() if ln.strip()]
    return lines[-LOG_TAIL_LINES:] or None


_os_cache = {"at": 0.0, "value": None}


def read_os_updates():
    """Pending host package updates, or None if apt could not be asked.

    Returns (total, security, apt_age_hours, reboot_required).

    The staleness figure is not decoration. `apt list --upgradable` reports
    against the last `apt update`, so a host whose package lists have not been
    refreshed in months answers "0 updates" -- confidently, and wrongly. That
    is a worse failure than not checking at all, because it looks like good
    news. Reporting how old the lists are makes the zero interpretable.
    """
    if not OS_UPDATE_INTERVAL:
        return None
    now = time.monotonic()
    cached = _os_cache["value"]
    if cached is not None:
        total, security, _age, reboot = cached
        # Pending means someone may be about to act on it, so look again soon.
        pending = bool(total or security or reboot)
        if now - _os_cache["at"] < (OS_PENDING_INTERVAL if pending else OS_UPDATE_INTERVAL):
            return cached

    out = run(["apt", "list", "--upgradable"], timeout=60)
    if out is None:
        return None

    total = security = 0
    for line in out.splitlines():
        # pkg/suite version arch [upgradable from: older]
        if "[upgradable from:" not in line:
            continue
        total += 1
        # pkg/suite -- and the suite may be a comma list, e.g. "stable,stable".
        suite = line.split("/", 1)[1].split(None, 1)[0] if "/" in line else ""
        # Stock Debian puts security fixes in their own suite. Raspberry Pi OS
        # does NOT: its packages arrive through plain `stable`, security fixes
        # included, so on that platform this finds nothing however many
        # security updates are pending. It is kept because it is right where it
        # applies and costs nothing where it does not -- but the alert must not
        # depend on it, or it goes permanently silent on a Pi.
        if any(part.endswith("-security") for part in suite.lower().split(",")):
            security += 1

    # How old the package lists are. apt-daily refreshes these on most Debian
    # hosts, but "most" is not "this one", so it is measured rather than assumed.
    age_hours = None
    for path in ("/var/lib/apt/periodic/update-success-stamp",
                 "/var/lib/apt/lists"):
        try:
            age_hours = round((time.time() - os.path.getmtime(path)) / 3600.0, 1)
            break
        except OSError:
            continue

    # Created by a kernel or libc upgrade. Absent on a host without
    # update-notifier-common, which is why absence is reported as False rather
    # than as a failure.
    reboot = os.path.exists("/var/run/reboot-required")

    value = (total, security, age_hours, reboot)
    _os_cache["value"] = value
    _os_cache["at"] = now
    return value


def read_image_inventory():
    """How many versioned node images are on disk, or None.

    One accumulates per CLI release at roughly half a gigabyte each, and
    nothing used to say so -- the first sign would have been a full disk. The
    rebuild script prunes them, so a count that keeps climbing means the prune
    is not running, which is worth seeing before the disk is.
    """
    repo = CONTAINER_IMAGE.split(":")[0]
    out = run(["docker", "images", repo, "--format", "{{.Tag}}"])
    if out is None:
        return None
    tags = [t.strip() for t in out.splitlines() if t.strip()]
    return sum(1 for t in tags if re.fullmatch(r"[0-9]+(\.[0-9]+){2}", t))


def read_producer_unit():
    """The systemd unit managing the producer, or None if nothing does.

    `systemctl is-active` exits non-zero for anything but an active unit, and
    run() turns a non-zero exit into None, so an absent unit reports nothing
    rather than guessing.
    """
    if not PRODUCER_UNIT:
        return None
    return PRODUCER_UNIT if run(["systemctl", "is-active", PRODUCER_UNIT]) == "active" else None


# Every collector above returns None on failure rather than raising, so that a
# failed `docker exec` or an unreachable registry can never take down a
# heartbeat. That is deliberate, and it has a cost: a blank field on the panel
# could mean "not collected yet" or "collection is failing", and there was no
# way to tell them apart. An agent could go half-blind while still reporting
# ONLINE with every sign of health.
#
# So the ones that failed say so. What this does NOT do is report every empty
# collector: most of them are legitimately silent. No rebuild timer installed,
# no systemd unit managing the container, no reason the node is blocked --
# those are answers, not failures, and listing them would replace a missing
# signal with a false one. Each entry below is guarded by the condition that
# makes silence genuinely wrong: something was there to read, and reading it
# did not work.
def _degraded_note(degraded, field, failed):
    if failed:
        degraded.append(field)


# --- keeping slow work off the heartbeat path --------------------------------
#
# Every collector used to run inline, which meant the beat waited on the
# slowest of them. The production scan alone allows 180 seconds and the peer
# scan 120, against a 90-second staleness threshold at the backend -- so one
# slow scan could push the next heartbeat past the point where a node that is
# producing perfectly well is declared OFFLINE, and an alert goes out about it.
# The agent could make its own node look dead by doing its job.
#
# These now run on a worker thread and publish their last result here. The beat
# reads what is ready and never waits.

_slow = {"lock": threading.Lock(), "data": {}, "degraded": set(), "on": False}
SLOW_CYCLE = int(os.environ.get("XL1_SLOW_CYCLE", "60"))


def _slow_put(key, value):
    with _slow["lock"]:
        _slow["data"][key] = value


def _slow_get(key, fn, take=False):
    """The worker's last value, or a direct call when it is not running.

    The fallback keeps this testable: with no worker thread every collector
    behaves exactly as before, so the tests exercise the real code path rather
    than a stub of it.

    `take` consumes the value. The production scan and the backfill chunk
    report a RANGE the receiver accumulates, so re-reading one on every beat
    would re-send an already-counted range thirty times a cycle.
    """
    if not _slow["on"]:
        return fn()
    with _slow["lock"]:
        return _slow["data"].pop(key, None) if take else _slow["data"].get(key)


def _step(label, thunk, default=None):
    """Run one collector. A failure costs that reading and nothing else.

    The worker used to wrap the entire cycle in a single try, so the first
    collector to raise skipped every collector after it -- for that cycle, and
    for every cycle after it if the cause persisted. The result would be a node
    showing ONLINE with a fresh heartbeat while the readings behind it had
    quietly stopped moving, and one line on stderr nobody was reading to say
    why.

    That is the exact failure this file exists to prevent, so it should not be
    the shape of the file's own worker. CI found it: a collector reached a real
    subprocess, which on POSIX polls with time.sleep, and a test that had
    replaced time.sleep saw its sentinel swallowed here -- every field after
    that point silently missing.
    """
    try:
        return thunk()
    except Exception as e:
        # Name the type. Several exceptions worth seeing have an empty str(),
        # and "failed: " with nothing after the colon is not a bug report.
        print("collector %s failed: %s: %s" % (label, type(e).__name__, e),
              file=sys.stderr, flush=True)
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        return default


def _slow_worker():
    """Runs the expensive collectors. Must never die -- a dead worker is a
    silent one, and every field it feeds would simply stop updating."""
    while True:
        try:
            name = _step("find_container", find_container)
            _step("cli_version", lambda: _slow_put("cli_version", read_cli_version(name)))
            _step("cli_latest", lambda: _slow_put("cli_latest", fetch_cli_latest()))
            _step("sdk_version", lambda: _slow_put("sdk_version", read_sdk_version()))
            # Anything anchored earlier that the backend has not yet
            # acknowledged. Cheap when the spool is empty, which is the
            # normal case.
            _step("flush_attestations", flush_attestations)
            # And then ask the chain whether the ones already sent are really
            # there. A few per cycle; see check_anchors_on_chain for why the
            # failing answer is the only one worth anything.
            _step("check_anchors", check_anchors_on_chain)
            _step("sdk_latest", lambda: _slow_put("sdk_latest", fetch_sdk_latest()))
            _step("log_tail", lambda: _slow_put("log_tail", read_log_tail(name)))
            _step("image_inventory", lambda: _slow_put("image_inventory", read_image_inventory()))
            _step("blocked_reason", lambda: _slow_put("blocked_reason", read_blocked_reason(name)))
            _step("build_times", lambda: _slow_put("build_times", read_build_times(name)))
            _step("producer_unit", lambda: _slow_put("producer_unit", read_producer_unit()))
            _step("rebuild_timer", lambda: _slow_put("rebuild_timer", read_rebuild_timer()))
            _step("repo_head", lambda: _slow_put("repo_head", read_repo_head()))
            _step("repo_upstream", lambda: _slow_put(
                "repo_upstream", fetch_repo_upstream(_slow["data"].get("repo_head"))))
            _step("standing", lambda: _slow_put("standing", fetch_standing(name)))
            _step("earnings", lambda: _slow_put("earnings", fetch_earnings(name)))
            _step("peers", lambda: _slow_put("peers", fetch_peers(name)))
            _step("os_updates", lambda: _slow_put("os_updates", read_os_updates()))
            # Last, and only when the backend has told us where to resume.
            stats = _step("producer_stats", lambda: fetch_producer_stats(name))
            if stats:
                _slow_put("producer_stats", stats)
                chunk = _step("backfill_chunk", lambda: fetch_backfill_chunk(name))
                if chunk:
                    _slow_put("backfill_chunk", chunk)
            # Outside the `if stats:` above on purpose. The walk has its own
            # cursor and never needed the production scan; waiting for it
            # capped the whole history at one chunk per fifteen minutes.
            mint_chunk = _step("minted_chunk", lambda: fetch_minted_chunk(name))
            if mint_chunk:
                _slow_put("minted_chunk", mint_chunk)
        except Exception as e:
            # Every collector is isolated above, so reaching here means the
            # loop's own scaffolding broke. Still caught: the worker must never
            # die, because a dead worker is a silent one.
            print("slow collector cycle failed: %s: %s" % (type(e).__name__, e),
                  file=sys.stderr, flush=True)
            traceback.print_exc(file=sys.stderr)
            sys.stderr.flush()
        time.sleep(SLOW_CYCLE)


def start_slow_worker():
    """Called from main(), never from a test. Until it runs, every collector is
    called inline exactly as before."""
    _slow["on"] = True
    t = threading.Thread(target=_slow_worker, name="xl1-slow", daemon=True)
    t.start()
    return t


def collect():
    name = find_container()
    degraded = []
    live, ready = check_health(name)
    payload = {
        "node_id": NODE_ID, "label": NODE_LABEL, "role": NODE_ROLE,
        "network": NODE_NETWORK, "live": live, "ready": ready,
        "agent_version": AGENT_VERSION,
    }
    if name:
        payload.update(container_info(name))
        payload.update(container_stats(name))
    else:
        # Container gone entirely -- report that rather than silently sending nothing.
        payload["container_status"] = "missing"
    payload.update(host_metrics())

    installed = _slow_get("cli_version", lambda: read_cli_version(name))
    if installed:
        payload["cli_version"] = installed
    # Only a failure if there was a container to ask in the first place.
    _degraded_note(degraded, "throttling", _throttle_unreadable)
    _degraded_note(degraded, "cli_version", bool(name) and not installed)
    latest = _slow_get("cli_latest", fetch_cli_latest)
    if latest:
        payload["cli_latest"] = latest
    # CLI_REGISTRY empty means the lookup was switched off deliberately.
    _degraded_note(degraded, "cli_latest", bool(CLI_REGISTRY) and not latest)

    # Same pair for the SDK the companion service reads the chain with.
    sdk_installed = _slow_get("sdk_version", read_sdk_version)
    if sdk_installed:
        payload["sdk_version"] = sdk_installed
    _degraded_note(degraded, "sdk_version", bool(VERSIONS_URL) and not sdk_installed)
    sdk_latest = _slow_get("sdk_latest", fetch_sdk_latest)
    if sdk_latest:
        payload["sdk_latest"] = sdk_latest
    _degraded_note(degraded, "sdk_latest", bool(SDK_REGISTRY) and not sdk_latest)

    # Image recipe drift -- independent of the CLI version above.
    repo_head = _slow_get("repo_head", read_repo_head)
    if repo_head:
        payload["repo_commit"] = repo_head
    # A checkout that exists but cannot be read is broken; no checkout is fine.
    _degraded_note(degraded, "repo_commit",
                   os.path.isdir(os.path.join(IMAGES_REPO, ".git")) and not repo_head)
    repo_upstream, repo_behind, repo_tag, repo_upstream_tag = (
        _slow_get("repo_upstream", lambda: fetch_repo_upstream(repo_head))
        or (None, None, None, None))
    # Knowing the recipe is behind is the whole point of reading it.
    # Keyed on the upstream commit, NOT on repo_behind. `behind` is left None
    # whenever local and upstream match, because there is nothing to compare --
    # so keying on it reported every up-to-date checkout as a broken reader,
    # while the tile beside it read "up to date". Both on the same screen,
    # contradicting each other.
    _degraded_note(degraded, "repo_upstream",
                   bool(repo_head) and bool(IMAGES_REPO_API) and repo_upstream is None)
    if repo_upstream:
        payload["repo_upstream"] = repo_upstream
    if repo_behind is not None:
        payload["repo_behind"] = repo_behind
    if repo_tag:
        payload["repo_tag"] = repo_tag
    if repo_upstream_tag:
        payload["repo_upstream_tag"] = repo_upstream_tag

    balance, funded, symbol, raw, stake_raw, stake_min_raw = (
        _slow_get("standing", lambda: fetch_standing(name)) or NO_STANDING)
    if balance is not None:
        payload["producer_balance"] = balance
    if symbol:
        payload["producer_balance_symbol"] = symbol
    if raw:
        payload["producer_balance_raw"] = raw
    _degraded_note(degraded, "producer_balance",
                   bool(STANDING_URL) and bool(name) and balance is None)

    # Opt-in location. Absent unless configured, and named so that whatever
    # renders it cannot mistake it for something measured.
    if STATED_LOCATION:
        payload["stated_location"] = STATED_LOCATION
    if STATED_LAT is not None:
        payload["stated_lat"] = STATED_LAT
    if STATED_LON is not None:
        payload["stated_lon"] = STATED_LON
    # Only alongside a position -- a radius around nothing says nothing.
    if STATED_LAT is not None and STATED_LON is not None:
        payload["stated_radius_km"] = STATED_RADIUS_KM

    # The anchoring wallet. Operator-only: see PUBLIC_NODE_FIELDS -- a balance
    # has never been on the public panel and this one is no different.
    attestor, attestor_balance, attestor_raw = fetch_attestor_balance()
    if attestor:
        payload["attestor_address"] = attestor
    if attestor_balance is not None:
        payload["attestor_balance"] = attestor_balance
    if attestor_raw:
        payload["attestor_balance_raw"] = attestor_raw
    if attestor:
        # The two halves of a runway, both measured rather than assumed: what
        # an anchor costs, read off this wallet's own transfers, and how often
        # this node anchors, which is not an estimate at all -- it is the
        # interval this process is running on.
        cost = fetch_anchor_cost()
        if cost is not None:
            payload["attestor_cost_per_anchor"] = cost
        payload["attestor_anchor_interval_s"] = ATTEST_INTERVAL
    if funded is not None:
        payload["producer_funded"] = funded
    # Raw only, and no verdict. Whether a given stake is ENOUGH depends on
    # thresholds the network has not settled -- minStake reads as 1 against
    # 18-decimal balances, so even its unit is unclear -- and a panel that
    # asserts eligibility from numbers this unsettled would be inventing an
    # answer. Report both figures and let a reader compare them.
    if stake_raw is not None:
        payload["producer_stake_raw"] = stake_raw
    if stake_min_raw is not None:
        payload["producer_stake_min_raw"] = stake_min_raw

    earnings = _slow_get("earnings", lambda: fetch_earnings(name))
    if earnings is not None:
        earned, rewarded, reward_each, non_reward, sdk_ok = earnings
        payload["producer_earned"] = earned
        payload["producer_blocks_rewarded"] = rewarded
        payload["producer_reward_per_block"] = reward_each
        if non_reward is not None:
            payload["producer_non_reward"] = non_reward
        if sdk_ok is not None:
            payload["producer_reward_sdk_ok"] = sdk_ok
    # Degraded only when the service is configured and the address is known:
    # a node with neither is not broken, it is unconfigured.
    _degraded_note(degraded, "producer_earned",
                   bool(EARNINGS_URL) and bool(name) and earnings is None)

    tail = _slow_get("log_tail", lambda: read_log_tail(name))
    if tail:
        payload["log_tail"] = tail
    _degraded_note(degraded, "log_tail", bool(name) and not tail)

    build = _slow_get("build_times", lambda: read_build_times(name))
    if build:
        samples, avg_ms, max_ms, over = build
        payload["build_samples"] = samples
        payload["build_over_budget"] = over
        # Omitted rather than nulled when there were no builds. A null in a
        # duration field reads like a duration the reader failed to get, and
        # the count beside it already says there was nothing to measure.
        if avg_ms is not None:
            payload["build_ms_avg"] = avg_ms
            payload["build_ms_max"] = max_ms
        # Sent rather than assumed at the far end: the budget is settable per
        # device, and a panel that hard-codes its own would draw one node's
        # figures against another node's line.
        payload["build_budget_ms"] = BUILD_BUDGET_MS
    # Not degraded when absent. A node that has logged no build lines in the
    # window is a node that has not built anything, which is a real state and
    # not a fault in the agent.

    images = _slow_get("image_inventory", read_image_inventory)
    if images is not None:
        payload["node_image_count"] = images
    # Docker is not optional for this agent, so this one is never "n/a".
    _degraded_note(degraded, "node_image_count", images is None)

    peer_count, peer_share, peer_window = (
        _slow_get("peers", lambda: fetch_peers(name)) or (None, None, None))
    if peer_count is not None:
        payload["peer_count"] = peer_count
        payload["produced_share"] = peer_share
        payload["peer_window"] = peer_window
    _degraded_note(degraded, "peers",
                   bool(PEERS_URL) and bool(name) and peer_count is None)

    updates = _slow_get("os_updates", read_os_updates)
    if updates is not None:
        total, security, apt_age, reboot = updates
        payload["os_updates"] = total
        payload["os_security_updates"] = security
        payload["os_apt_age_hours"] = apt_age
        payload["os_reboot_required"] = reboot
    # A host with no apt is not broken; a host with apt that would not answer is.
    _degraded_note(degraded, "os_updates",
                   bool(OS_UPDATE_INTERVAL) and updates is None
                   and os.path.exists("/usr/bin/apt"))

    blocked = _slow_get("blocked_reason", lambda: read_blocked_reason(name))
    if blocked:
        payload["producer_blocked"] = blocked

    unit = _slow_get("producer_unit", read_producer_unit)
    if unit:
        payload["producer_unit"] = unit

    timer_active, timer_next = _slow_get("rebuild_timer", read_rebuild_timer) or (None, None)
    if timer_active is not None:
        payload["rebuild_timer_active"] = timer_active
    if timer_next:
        payload["rebuild_timer_next"] = timer_next

    # Surface duplicates rather than quietly monitoring one of them.
    node_containers = list_node_containers()
    if node_containers:
        payload["node_containers"] = node_containers

    stats = _slow_get("producer_stats", lambda: fetch_producer_stats(name), take=True)
    # The most consequential of these: production counting stops without it,
    # and the panel would show a frozen total with no explanation.
    #
    # Checked AFTER the call, and only when a scan was actually due. A scan
    # that just succeeded stamps the rate limiter and is no longer due; one
    # that failed leaves it due and is still reported. Without this the
    # not-due case -- 29 beats out of 30 -- read as a failure.
    _degraded_note(degraded, "producer_stats",
                   bool(name) and not stats and producer_scan_due())
    if stats:
        # Counts only. The reward address stays on this machine.
        payload["produced_recent"] = stats.get("produced")
        payload["produced_window"] = stats.get("window")
        payload["pending_transactions"] = stats.get("pendingTransactions")
        payload["pending_blocks"] = stats.get("pendingBlocks")
        payload["last_block_epoch"] = stats.get("latestEpoch")
        payload["scan_from_block"] = stats.get("fromBlock")
        payload["scan_to_block"] = stats.get("toBlock")
        payload["scan_produced"] = stats.get("produced")
        # The head the scan was bounded by, and the floor it will not read
        # below. Both let the backend report whether counting is keeping up.
        payload["finalized_head"] = stats.get("height")
        payload["indexer_floor"] = stats.get("floor")
        # Whether that head really was the finalized one. A scan bounded by
        # the latest block instead can count a block that a reorg later
        # removes, and the cursor never goes back to correct it.
        payload["scan_finalized"] = stats.get("finalized")
        # Only report a sighting; absence here means "none in this range",
        # not "never produced", so it must not overwrite a known value.
        if stats.get("lastProducedBlock") is not None:
            payload["last_produced_block"] = stats.get("lastProducedBlock")
            payload["blocks_since_produced"] = stats.get("blocksSinceProduced")
            # Built by the SDK's ExplorerLinks, not concatenated here: the
            # explorer owns those paths and ours had already drifted.
            explorer = stats.get("explorer") or {}
            if explorer.get("lastProducedBlock"):
                payload["explorer_block_url"] = explorer["lastProducedBlock"]

        # What the scanned range actually minted to this address, by day.
        # Counted by RECIPIENT while `produced` above counts by SIGNER, so the
        # two are independent readings of the same range rather than one
        # number restated -- which is what makes them worth comparing.
        scanned = minted_by_day(stats)
        if scanned:
            payload["scan_minted_by_day"] = scanned

        chunk = _slow_get("backfill_chunk", lambda: fetch_backfill_chunk(name), take=True)
        if chunk:
            payload["backfill_from_block"] = chunk.get("fromBlock")
            payload["backfill_to_block"] = chunk.get("toBlock")
            payload["backfill_produced"] = chunk.get("produced")
            # The point of the whole exercise: this is where the history
            # before monitoring started comes from.

            # A backfill chunk sees far more blocks than a forward scan, so it
            # is often the only source of a sighting for a low-share producer.
            # It walks backwards, so its sighting may be older than one already
            # known -- the backend keeps whichever is more recent.
            if (payload.get("last_produced_block") is None
                    and chunk.get("lastProducedBlock") is not None):
                payload["last_produced_block"] = chunk["lastProducedBlock"]


    # Outside the producer-scan branch, like the fetch that feeds it.
    mint_chunk = _slow_get("minted_chunk", lambda: fetch_minted_chunk(name), take=True)
    if mint_chunk and mint_chunk.get("fromBlock") is not None:
        payload["minted_from_block"] = mint_chunk.get("fromBlock")
        payload["minted_to_block"] = mint_chunk.get("toBlock")
        # A range where this address earned nothing still reports its bounds,
        # or the cursor never passes it and the walk stalls on the first quiet
        # stretch -- which for a young node is most of the chain.
        walked = minted_by_day(mint_chunk)
        if walked:
            payload["minted_by_day"] = walked

    # A scan reports only blocks it saw, so a node that has stopped producing
    # would never supply a link for the block still on display. Fall back to
    # the one the backend says it is showing.
    if not payload.get("explorer_block_url"):
        link = explorer_block_url(_producer_cursor["last_produced"])
        if link:
            payload["explorer_block_url"] = link

    heights = fetch_block_heights()
    _degraded_note(degraded, "chain_heights", not heights)
    if heights:
        payload["chain_heights"] = heights
        # block_height stays this node's own network, for the node card.
        own = heights.get(NODE_NETWORK)
        if own is not None:
            payload["block_height"] = own

    # Sent even when empty: "nothing failed" is the useful reading, and an
    # absent field would be indistinguishable from an older agent that does
    # not report this at all.
    payload["agent_degraded"] = degraded
    return payload


def _spool_path(content_hash):
    return os.path.join(ATTEST_SPOOL, content_hash + ".json")


def spool_attestation(record):
    """Persist an anchored attestation locally before anything else.

    Returns True when it is safely on disk. A failure here is the one case
    where the anchor should not have happened -- but it already has, so the
    next best thing is to say so loudly rather than continue as if fine.
    """
    try:
        os.makedirs(ATTEST_SPOOL, exist_ok=True)
        path = _spool_path(record["content_hash"])
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(record, fh)
            fh.flush()
            os.fsync(fh.fileno())
        # Atomic: a reader never sees a half-written payload, and a crash
        # mid-write leaves the .tmp rather than a corrupt record.
        os.replace(tmp, path)
        return True
    except OSError as e:
        _warn_once("attest-spool", "could not save an anchored attestation: %s" % e)
        return False


def post_attestation(record):
    """Send one spooled attestation to the backend. True when it is stored."""
    if not BACKEND_URL or not NODE_TOKEN:
        return False
    req = urllib.request.Request(
        BACKEND_URL + "/api/node/attestation",
        data=json.dumps(record).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "X-Node-Token": NODE_TOKEN,
                 "User-Agent": "xl1-heartbeat/" + AGENT_VERSION},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return 200 <= resp.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def flush_attestations():
    """Send anything still spooled, oldest first, and delete what lands.

    Runs every slow cycle rather than only after anchoring, so a backend that
    was down when an attestation was made still receives it later. The store
    keys on the content hash, so re-sending one that already arrived is
    harmless -- which is what makes deleting only on success the safe order.
    """
    try:
        names = sorted(n for n in os.listdir(ATTEST_SPOOL) if n.endswith(".json"))
    except OSError:
        return
    for name in names[:20]:
        path = os.path.join(ATTEST_SPOOL, name)
        try:
            with open(path, encoding="utf-8") as fh:
                record = json.load(fh)
        except (OSError, ValueError):
            continue
        if post_attestation(record):
            try:
                os.remove(path)
            except OSError:
                pass


def check_one_transaction(tx_hash):
    """Ask the chain whether this transaction exists. (found, block, sender).

    None means the question could not be asked -- a service that is down, a
    gateway having a bad minute -- and is deliberately different from False,
    which means the chain answered and does not have it. Reporting the first
    as the second would put a permanent red mark on a perfectly good anchor.
    """
    if not TX_CHECK_URL or not tx_hash:
        return None
    try:
        url = TX_CHECK_URL + "?" + urllib.parse.urlencode(
            {"hash": tx_hash, "network": NODE_NETWORK})
        with urllib.request.urlopen(url, timeout=60) as resp:
            if not (200 <= resp.status < 300):
                return None
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return None
    if not isinstance(body.get("found"), bool):
        return None
    block = body.get("block")
    sender = body.get("from")
    fees = body.get("fees")
    return (body["found"],
            block if isinstance(block, int) else None,
            sender if isinstance(sender, str) else None,
            fees if isinstance(fees, dict) else None)


def post_transaction_check(content_hash, found, block, sender, fees=None):
    """Tell the backend what the chain said about one of our anchors."""
    if not BACKEND_URL or not NODE_TOKEN:
        return False
    body = {"node_id": NODE_ID, "content_hash": content_hash, "found": found}
    if block is not None:
        body["block"] = block
    if sender:
        body["tx_from"] = sender
    if fees:
        body["fees"] = fees
    req = urllib.request.Request(
        BACKEND_URL + "/api/node/attestation/check",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "X-Node-Token": NODE_TOKEN,
                 "User-Agent": "xl1-heartbeat/" + AGENT_VERSION},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return 200 <= resp.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def check_anchors_on_chain():
    """Check a few of this node's own anchors against the chain.

    The panels list anchors out of the site's records -- what this system says
    it did. Those rows carry real transaction hashes and link to the explorer,
    but until now nothing ever went and looked. The check worth having is the
    failing one: an anchor recorded as done that never landed means the record
    has quietly stopped meaning what it claims.

    Only the unchecked, and only a few per cycle. There is no deadline here,
    and a brand new anchor legitimately reads as absent for a while before it
    is included -- so an unchecked or not-yet-found anchor is not an alarm, it
    is a question that has not been answered yet.
    """
    if not BACKEND_URL or not TX_CHECK_URL:
        return
    try:
        # Ask for the ones that still need checking rather than the newest
        # fifty. Filtering locally meant anything older than the fifty most
        # recent anchors was never even fetched, so a backlog older than that
        # could not be worked through -- it just sat there.
        url = (BACKEND_URL + "/api/node/attestations?"
               + urllib.parse.urlencode({"node_id": NODE_ID, "unchecked": 1,
                                         "limit": TX_CHECK_BATCH * 4}))
        with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
            if not (200 <= resp.status < 300):
                return
            body = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return

    done = 0
    for row in body.get("attestations") or []:
        if done >= TX_CHECK_BATCH:
            break
        tx_hash = row.get("tx_hash")
        content_hash = row.get("content_hash")
        if not tx_hash or not content_hash:
            continue
        # The server filtered these, but an older backend does not know the
        # parameter and answers with everything -- in which case this is what
        # stops a confirmed row being checked again. Re-checking one buys
        # nothing: a transaction on the chain does not leave it.
        if row.get("chain_found") is True:
            continue
        result = check_one_transaction(tx_hash)
        if result is None:
            # Could not ask. Not an answer, so nothing is recorded.
            continue
        found, block, sender, fees = result
        post_transaction_check(content_hash, found, block, sender, fees)
        done += 1


def attest(name, payload):
    """Ask the service to anchor the current readings. Returns None normally.

    Rate limited by ATTEST_INTERVAL because each anchoring is a transaction
    that costs gas -- unlike every other collector here, calling this too often
    spends money rather than merely wasting effort.
    """
    if not ATTEST_URL:
        return
    # Remember the freshest chain values seen on ANY beat, before the rate
    # limit returns. A producer scan runs about once in thirty beats, so the
    # beat that happens to trigger an anchor usually carries none -- which is
    # why the first anchored reading reported no last produced block despite
    # the node having produced one minutes earlier.
    for key in ("last_produced_block", "block_height"):
        value = payload.get(key)
        if value is not None:
            _attest_cache[key] = value
    now = time.monotonic()
    last = _attest_cache["at"]
    if last is not None and now - last < ATTEST_INTERVAL:
        return
    body = {
        "producer": read_reward_address(name) or "",
        "height": _attest_cache.get("block_height"),
        "lastProducedBlock": _attest_cache.get("last_produced_block"),
        # No producedTotal. The node does not have one: that figure is the
        # backend accumulating scan results over time, and a node attesting it
        # would be vouching for arithmetic done somewhere else. An attestation
        # should carry what this machine observed and nothing more.
        "cpuPercent": payload.get("cpu_percent"),
        "memUsedMb": payload.get("host_mem_used_mb"),
        "temperatureC": payload.get("temperature_c"),
        "uptimeSeconds": payload.get("host_uptime_seconds"),
        "network": NODE_NETWORK,
    }
    # Inside the record that gets hashed, never beside it. A reference carried
    # alongside the anchor would be something this node could revise later,
    # which is the exact thing anchoring exists to stop.
    witness = fetch_witness_target()
    if witness:
        body["witnessed"] = witness

    headers = {"Content-Type": "application/json"}
    if ATTEST_TOKEN:
        headers["X-Anchor-Token"] = ATTEST_TOKEN
    req = urllib.request.Request(
        ATTEST_URL, data=json.dumps(body).encode("utf-8"),
        headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            if not (200 <= resp.status < 300):
                _warn_once("attest-status", "attest refused: HTTP %s" % resp.status)
                return
            result = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        # Named separately because this is the one an operator can act on. A
        # 401 means the token is missing or wrong, and swallowing it silently
        # is indistinguishable from attestation being switched off -- which is
        # exactly how a misconfigured agent looked correct for an hour.
        _warn_once("attest-http",
                   "attest refused: HTTP %s%s" % (
                       e.code,
                       " (set XL1_ANCHOR_TOKEN to the value the service uses)"
                       if e.code in (401, 403) else ""))
        return
    except (urllib.error.URLError, OSError, ValueError) as e:
        _warn_once("attest-unreachable", "attest could not be reached: %s" % e)
        return
    # The clock advances on any answer, including one that did not anchor.
    # Retrying a service with no key configured every thirty seconds would be
    # pointless noise.
    _attest_cache["at"] = now
    # Remember who signed, so the wallet paying for all this can be watched
    # without configuring its address a second time. The service reports it
    # and only the service knows it -- the agent never holds that key.
    signer = result.get("attestedBy")
    if isinstance(signer, str) and re.fullmatch(r"(0x)?[0-9a-fA-F]{40}", signer):
        _attest_cache["signer"] = signer.lower().replace("0x", "")
    if not result.get("anchored"):
        return
    record = {
        "node_id": NODE_ID,
        "network": result.get("network") or NODE_NETWORK,
        "kind": "reading",
        "payload": json.dumps(result.get("payload"), separators=(",", ":")),
        "content_hash": result.get("contentHash") or "",
        "tx_hash": result.get("txHash") or "",
        "attested_by": result.get("attestedBy"),
        "explorer_url": result.get("explorerUrl"),
        "observed_at": (result.get("record") or {}).get("observedAt"),
        # Indexed alongside the payload rather than instead of it. The payload
        # is what was hashed and is the authority; these two only let the
        # backend answer "who referenced whom" without re-parsing every record.
        "witnessed_node_id": (witness or {}).get("node"),
        "witnessed_hash": (witness or {}).get("hash"),
    }
    if not record["content_hash"] or not record["tx_hash"]:
        return
    # Disk first, always. Between the anchor and the backend knowing, this file
    # is the only copy of what that transaction committed to.
    if not spool_attestation(record):
        # Anchored but not saved. Nothing can recover the payload from the
        # chain, so say so rather than let it look routine.
        _warn_once("attest-unsaved",
                   "anchored %s but could not save the payload locally"
                   % record["content_hash"][:12])
        return
    if post_attestation(record):
        try:
            os.remove(_spool_path(record["content_hash"]))
        except OSError:
            # Left behind, which flush_attestations will retry. The store keys
            # on the content hash, so a second delivery changes nothing.
            pass


def send(payload):
    req = urllib.request.Request(
        BACKEND_URL + "/api/node/heartbeat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "X-Node-Token": NODE_TOKEN,
                 "User-Agent": "xl1-heartbeat/" + AGENT_VERSION},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            if not (200 <= resp.status < 300):
                return False
            try:
                body = json.loads(resp.read().decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                body = {}
            # Any successful response tells us the backend's position, even
            # when that position is "nothing counted yet" (null).
            _producer_cursor["known"] = True
            cursor = body.get("producer_cursor")
            if isinstance(cursor, int):
                _producer_cursor["block"] = cursor
            minted_cursor = body.get("minted_cursor")
            if isinstance(minted_cursor, int):
                _producer_cursor["minted"] = minted_cursor
            _producer_cursor["minted_done"] = bool(body.get("minted_complete"))
            backfill = body.get("backfill_cursor")
            if isinstance(backfill, int):
                _producer_cursor["backfill"] = backfill
            _producer_cursor["backfill_done"] = bool(body.get("backfill_complete"))
            shown = body.get("last_produced_block")
            if isinstance(shown, int):
                _producer_cursor["last_produced"] = shown
            return True
    except urllib.error.HTTPError as e:
        # Print what the backend SAID, not just that it said no. A 401 now
        # carries the reason and the page to fix it on -- "register it at
        # ..." -- and printing only the status code threw that away, leaving
        # the operator to guess at exactly the moment they were being told.
        detail = ""
        try:
            detail = (json.loads(e.read().decode("utf-8")) or {}).get("detail") or ""
        except (ValueError, UnicodeDecodeError, OSError, AttributeError):
            pass
        print("heartbeat rejected: HTTP %s %s%s"
              % (e.code, e.reason, " -- " + str(detail)[:300] if detail else ""),
              file=sys.stderr, flush=True)
    except (urllib.error.URLError, OSError) as e:
        print("heartbeat failed: %s" % e, file=sys.stderr, flush=True)
    return False


def main():
    if not BACKEND_URL or not NODE_TOKEN:
        print("BACKEND_URL and NODE_HEARTBEAT_TOKEN must be set", file=sys.stderr)
        return 2

    once = "--once" in sys.argv
    # --once stays synchronous: a single run should do the work and report
    # it, not start a thread and report whatever it managed in time.
    if not once:
        start_slow_worker()
    while True:
        payload = collect()
        ok = send(payload)
        # After the heartbeat, never before it. Anchoring can take a minute --
        # it waits for the transaction to confirm -- and a beat delayed behind
        # it would read as a node that had gone quiet. Rate limited internally,
        # so calling it every cycle costs nothing until one is due.
        try:
            attest(find_container(), payload)
        except Exception as e:                       # noqa: BLE001
            # Attestation is an extra, not the job. It must never be able to
            # stop the thing that reports whether this node is alive.
            _warn_once("attest-failed", "attestation attempt failed: %s" % e)
        status = payload.get("container_status")
        if payload.get("exit_code") is not None:
            status = "%s(%s)" % (status, payload["exit_code"])
        scan = ("scan=%s-%s" % (payload["scan_from_block"], payload["scan_to_block"])
                if payload.get("scan_to_block") is not None else "scan=-")
        print("%s live=%s status=%s temp=%sC heights=%s %s" % (
            "sent" if ok else "FAILED", payload["live"], status,
            payload.get("temperature_c"), payload.get("chain_heights") or "-", scan),
            flush=True)
        if once:
            return 0 if ok else 1
        time.sleep(INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
