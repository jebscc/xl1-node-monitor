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
import time
import urllib.error
import urllib.parse
import urllib.request

AGENT_VERSION = "1.5.0"

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

# What the node says when it cannot produce, mapped to a short reason.
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

# How far back to grep the container log for the node's own reason it cannot
# produce. Long enough to survive a quiet period, short enough that a resolved
# problem stops being reported.
ELIGIBILITY_WINDOW = os.environ.get("XL1_ELIGIBILITY_WINDOW", "20m")
# How many log lines to show. The agent over-fetches and trims, so blank lines
# in the output do not shrink the count below this.
LOG_TAIL_LINES = int(os.environ.get("XL1_LOG_TAIL_LINES", "20"))
LOG_TAIL_MAX_CHARS = 300
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
# Optional systemd lookups. Both default to empty: not every host runs the
# container under systemd, and guessing a unit name that does not exist would
# report a failure where there is none.
REBUILD_TIMER = os.environ.get("XL1_REBUILD_TIMER", "")
PRODUCER_UNIT = os.environ.get("XL1_PRODUCER_UNIT", "")

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
PRODUCER_WINDOW = int(os.environ.get("XL1_PRODUCER_WINDOW", "200"))
PRODUCER_INTERVAL = int(os.environ.get("XL1_PRODUCER_INTERVAL", "900"))
REWARD_ADDRESS = os.environ.get("XL1_REWARD_ADDRESS", "")
# Blocks of history to walk back per cycle. The service fetches these in
# batched RPC calls (~0.6 ms/block), so 50,000 is roughly 20-30 seconds of work
# and a 565k-block chain is fully counted in about 3 hours. Set to 0 to leave
# history uncounted.
BACKFILL_CHUNK = int(os.environ.get("XL1_BACKFILL_CHUNK", "50000"))
# Version checking. The image is built once and never patched unless someone
# notices it has fallen behind, so the node reports what it runs and what is
# current. Set XL1_CLI_REGISTRY empty to skip the outbound lookup entirely.
CLI_REGISTRY = os.environ.get(
    "XL1_CLI_REGISTRY", "https://registry.npmjs.org/@xyo-network/xl1-cli/latest")
CLI_CHECK_INTERVAL = int(os.environ.get("XL1_CLI_CHECK_INTERVAL", "21600"))
CLI_PACKAGE_PATH = "/usr/local/lib/node_modules/@xyo-network/xl1-cli/package.json"
# A version string reaches us from a public registry and from inside a
# container. The backend caps these fields at 32 characters, so an unexpected
# value would fail validation and take the WHOLE heartbeat with it -- the node
# would read OFFLINE and raise an alert because of someone else's bad metadata.
_VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+){0,3}(-[0-9A-Za-z.]+)?$")


def _valid_version(value):
    return (isinstance(value, str) and 0 < len(value) <= 32
            and _VERSION_RE.match(value) is not None)

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
ATTEST_SPOOL = os.environ.get("XL1_ATTEST_SPOOL", "/opt/xl1-heartbeat/attestations")
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


def host_metrics():
    """Pi vitals: SoC temperature, root disk pressure, host uptime, RAM."""
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

    try:
        # statvfs is POSIX-only; guarded so the agent stays runnable off-Pi.
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total:
            data["disk_used_percent"] = round((total - free) / total * 100, 1)
    except (OSError, AttributeError):
        pass

    try:
        meminfo = {}
        with open("/proc/meminfo") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                if key in ("MemTotal", "MemAvailable"):
                    meminfo[key] = int(rest.split()[0])
        if "MemTotal" in meminfo:
            data["mem_total_mb"] = round(meminfo["MemTotal"] / 1024, 1)
            if "MemAvailable" in meminfo:
                used = meminfo["MemTotal"] - meminfo["MemAvailable"]
                data["host_mem_used_mb"] = round(used / 1024, 1)
    except (OSError, ValueError, IndexError):
        pass

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
                    # Read but never walked here: the mint history needs the
                    # companion service this build does not ship. Kept so send()
                    # stays byte-identical to the private copy, which is the one
                    # function drift in has actually caused bugs.
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


# Every collector above returns None on failure rather than raising, so that a
# failed `docker exec` or an unreachable service can never take down a
# heartbeat. That is deliberate, and it has a cost: a blank field could mean
# "not collected yet" or "collection is failing", and an agent can go
# half-blind while still reporting with every sign of health.
#
# So the ones that failed say so. What this does NOT do is report every empty
# collector: most are legitimately silent. No rebuild timer installed, no
# systemd unit managing the container, no reason the node is blocked -- those
# are answers, not failures, and listing them would replace a missing signal
# with a false one.
def _degraded_note(degraded, field, failed):
    if failed:
        degraded.append(field)


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


# --- keeping slow work off the heartbeat path --------------------------------
#
# Every collector used to run inline, so the beat waited on the slowest of
# them. The production scan alone allows 180 seconds against the receiver's
# 90-second staleness threshold, so one slow scan could delay the next
# heartbeat past the point where a node that is producing perfectly well is
# reported OFFLINE. The agent could make its own node look dead by doing its
# job.

_slow = {"lock": threading.Lock(), "data": {}, "on": False}
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


def _slow_worker():
    """Runs the expensive collectors. Must never die -- a dead worker is a
    silent one, and every field it feeds would simply stop updating."""
    while True:
        try:
            name = find_container()
            _slow_put("cli_version", read_cli_version(name))
            _slow_put("cli_latest", fetch_cli_latest())
            _slow_put("log_tail", read_log_tail(name))
            _slow_put("image_inventory", read_image_inventory())
            _slow_put("blocked_reason", read_blocked_reason(name))
            _slow_put("producer_unit", read_producer_unit())
            _slow_put("rebuild_timer", read_rebuild_timer())
            _slow_put("os_updates", read_os_updates())
            stats = fetch_producer_stats(name)
            if stats:
                _slow_put("producer_stats", stats)
                chunk = fetch_backfill_chunk(name)
                if chunk:
                    _slow_put("backfill_chunk", chunk)
        except Exception as e:
            print("slow collector cycle failed: %s" % e, file=sys.stderr, flush=True)
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
    _degraded_note(degraded, "cli_version", bool(name) and not installed)
    latest = _slow_get("cli_latest", fetch_cli_latest)
    if latest:
        payload["cli_latest"] = latest
    # CLI_REGISTRY empty means the lookup was switched off deliberately.
    _degraded_note(degraded, "cli_latest", bool(CLI_REGISTRY) and not latest)

    tail = _slow_get("log_tail", lambda: read_log_tail(name))
    if tail:
        payload["log_tail"] = tail
    _degraded_note(degraded, "log_tail", bool(name) and not tail)

    # One image accumulates per CLI release at roughly half a gigabyte. A count
    # that keeps climbing is worth seeing before the disk is full.
    images = _slow_get("image_inventory", read_image_inventory)
    if images is not None:
        payload["node_image_count"] = images
    # Docker is not optional for this agent, so this one is never "n/a".
    _degraded_note(degraded, "node_image_count", images is None)

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

    # Absence here is good news, so it is never a degraded reader.
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
    # Checked AFTER the call and only when a scan was actually due. A scan that
    # just succeeded stamps the rate limiter and is no longer due; one that
    # failed leaves it due and is still reported. Without this the not-due case
    # -- 29 beats out of 30 -- read as a failure, naming the most consequential
    # reader this agent has, permanently, on a healthy node.
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

        chunk = _slow_get("backfill_chunk", lambda: fetch_backfill_chunk(name), take=True)
        if chunk:
            payload["backfill_from_block"] = chunk.get("fromBlock")
            payload["backfill_to_block"] = chunk.get("toBlock")
            payload["backfill_produced"] = chunk.get("produced")
            # A backfill chunk sees far more blocks than a forward scan, so it
            # is often the only source of a sighting for a low-share producer.
            # It walks backwards, so its sighting may be older than one already
            # known -- the backend keeps whichever is more recent.
            if (payload.get("last_produced_block") is None
                    and chunk.get("lastProducedBlock") is not None):
                payload["last_produced_block"] = chunk["lastProducedBlock"]

    # A scan reports only blocks it saw, so a node that has stopped producing
    # would never supply a link for the block still on display. Fall back to
    # the one the backend says it is showing.
    if not payload.get("explorer_block_url"):
        link = explorer_block_url(_producer_cursor["last_produced"])
        if link:
            payload["explorer_block_url"] = link

    heights = fetch_block_heights()
    _degraded_note(degraded, "chain_heights", bool(HEIGHT_URL) and not heights)
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


# Beside the other interval caches rather than next to the function that
# uses it. The reported-fields guard reads `"key":` literals inside
# collect() as heartbeat fields, and a cache declared in that span is read
# as one -- a false positive that costs more to explain than to avoid.
_attest_cache = {"at": 0.0}


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


def attest(name, payload):
    """Ask the service to anchor the current readings. Returns None normally.

    Rate limited by ATTEST_INTERVAL because each anchoring is a transaction
    that costs gas -- unlike every other collector here, calling this too often
    spends money rather than merely wasting effort.
    """
    if not ATTEST_URL:
        return
    now = time.monotonic()
    if now - _attest_cache["at"] < ATTEST_INTERVAL:
        return
    body = {
        "producer": read_reward_address(name) or "",
        "height": payload.get("block_height"),
        "lastProducedBlock": payload.get("last_produced_block"),
        "producedTotal": payload.get("produced_total"),
        "cpuPercent": payload.get("cpu_percent"),
        "memUsedMb": payload.get("host_mem_used_mb"),
        "temperatureC": payload.get("temperature_c"),
        "uptimeSeconds": payload.get("host_uptime_seconds"),
        "network": NODE_NETWORK,
    }
    req = urllib.request.Request(
        ATTEST_URL, data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            if not (200 <= resp.status < 300):
                return
            result = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return
    # The clock advances on any answer, including one that did not anchor.
    # Retrying a service with no key configured every thirty seconds would be
    # pointless noise.
    _attest_cache["at"] = now
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
        print("heartbeat rejected: HTTP %s %s" % (e.code, e.reason), file=sys.stderr, flush=True)
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
