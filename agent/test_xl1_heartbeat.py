"""Tests for the node heartbeat agent.

No Docker required -- `run()` is stubbed with real `docker ps` output.
Run with:  pytest pi-agent/test_xl1_heartbeat.py
"""

import re
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

import xl1_heartbeat as agent  # noqa: E402


# Real output from the Pi on 2026-08-22, when the tag had moved off the
# running producer and it showed as a bare image ID.
PS_FULL = (
    "xl1-service-xl1-service-1\txl1-service:local\tnpx tsx src/server.ts\n"
    "charming_einstein\t3a27a9e5f10d\tnode /opt/xl1/lib/entrypoint.mjs\n"
)


REPORTED_FIELDS = {
    'agent_degraded',
    'backfill_from_block',
    'backfill_produced',
    'backfill_to_block',
    'block_height',
    'blocks_since_produced',
    'chain_heights',
    'cli_latest',
    'cli_version',
    'container_status',
    'explorer_block_url',
    'finalized_head',
    'indexer_floor',
    'last_block_epoch',
    'last_produced_block',
    'log_tail',
    'node_containers',
    'node_image_count',
    'os_updates',
    'os_security_updates',
    'os_apt_age_hours',
    'os_reboot_required',
    'pending_blocks',
    'pending_transactions',
    'produced_recent',
    'produced_window',
    'producer_blocked',
    'producer_unit',
    'rebuild_timer_active',
    'rebuild_timer_next',
    'scan_finalized',
    'scan_from_block',
    'scan_produced',
    'scan_to_block',
}

def _stub_run(monkeypatch, responses):
    """responses: list of (match_substring, return_value), first match wins."""
    def fake_run(args, timeout=10):
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
    only_sidecar = "xl1-service-xl1-service-1\txl1-service:local\tnpx tsx src/server.ts\n"
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
    "xl1-service-xl1-service-1\txl1-service:local\tdocker-entrypoint.sh\n"
    "charming_einstein\t3a27a9e5f10d\tnode /opt/xl1/lib/entrypoint.mjs\n"
)


def test_lists_every_running_node_container(monkeypatch):
    """Real state from the Pi: a rebuild left two node containers running."""
    _stub_run(monkeypatch, [("docker ps", PS_TWO_NODES)])
    assert agent.list_node_containers() == ["keen_bassi", "charming_einstein"]


def test_sidecar_is_not_counted_as_a_node(monkeypatch):
    _stub_run(monkeypatch, [("docker ps", PS_TWO_NODES)])
    assert "xl1-service-xl1-service-1" not in agent.list_node_containers()


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
    def fake_run(args, timeout=10):
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
    _reward_env(monkeypatch, "0000000000000000000000000000000000000abc")
    assert agent.read_reward_address("node") == "0000000000000000000000000000000000000abc"


def test_quoted_reward_address_is_accepted(monkeypatch):
    """docker --env-file does not strip quotes; a quoted value must still work."""
    _reward_env(monkeypatch, '"0x0000000000000000000000000000000000000abc"')
    assert agent.read_reward_address("node") == "0x0000000000000000000000000000000000000abc"


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
    _reward_env(monkeypatch, "0000000000000000000000000000000000000abc")
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


def test_version_check_off_means_no_docker_exec(monkeypatch):
    """`docker exec` is the call that makes socket access root-equivalent.
    With health read over HTTP, this is the last one -- so switching version
    checking off has to remove it, or read-only Docker access is impossible."""
    calls = []
    monkeypatch.setattr(agent, "run", lambda cmd, **kw: calls.append(cmd))
    monkeypatch.setattr(agent, "CLI_REGISTRY", "")
    agent._cli_cache["installed"] = None
    assert agent.read_cli_version("node") is None
    assert calls == [], f"expected no docker call, got {calls}"


def test_version_check_on_still_reads_the_container(monkeypatch):
    monkeypatch.setattr(agent, "CLI_REGISTRY", "https://registry.example/latest")
    monkeypatch.setattr(agent, "run", lambda cmd, **kw: '{"version": "5.2.2"}')
    agent._cli_cache["installed"] = None
    assert agent.read_cli_version("node") == "5.2.2"


# --- is the agent working, or merely running? --------------------------------
#
# Every collector returns None on failure so that a failure can never break a
# heartbeat. The cost is that a blank field could mean "not collected yet" or
# "collection is failing", and a half-blind agent looks exactly like a healthy
# one. collect() reports which readers came back empty.


def _blind_agent(monkeypatch):
    """An ESTABLISHED agent where a container exists and every reader fails.

    Established matters. A freshly started agent has not been told its cursor
    and deliberately does not scan -- scanning blind would re-count a range the
    receiver already has -- so producer_stats returning nothing is correct
    there, and must not read as a fault.

    The caches are reset because they are what makes this agent cheap: the CLI
    version is read once an hour, not every 30 seconds. A value left behind by
    an earlier test would be served from cache here and the reader would look
    healthy -- which is a genuine property of the feature, not just a test
    artefact. A cached reading means the last successful one, not the current
    one, so a reader that has only just started failing stays quiet until its
    cache expires.
    """
    monkeypatch.setitem(agent._cli_cache, "installed", None)
    monkeypatch.setitem(agent._cli_cache, "latest", None)
    monkeypatch.setitem(agent._producer_cursor, "known", True)
    monkeypatch.setitem(agent._producer_cache, "at", agent.time.monotonic() - 4000)
    monkeypatch.setattr(agent, "PRODUCER_INTERVAL", 900)
    monkeypatch.setattr(agent, "run", lambda *a, **k: None)
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: None)
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: None)
    monkeypatch.setattr(agent, "fetch_cli_latest", lambda: None)


def test_a_blind_agent_says_so(monkeypatch):
    _blind_agent(monkeypatch)
    failing = agent.collect()["agent_degraded"]
    for expected in ("cli_version", "cli_latest", "log_tail",
                     "producer_stats", "chain_heights", "node_image_count"):
        assert expected in failing, f"{expected} failed silently: {failing}"


def test_silence_that_is_an_answer_is_not_a_failure(monkeypatch):
    """The guard that decides whether this is a signal or a nuisance.

    Most collectors are legitimately quiet: no rebuild timer installed, no
    systemd unit managing the container, no reason the node is blocked. Those
    are answers. An operator who learns this line cries wolf stops reading it.
    """
    _blind_agent(monkeypatch)
    failing = agent.collect()["agent_degraded"]
    for never in ("rebuild_timer_active", "producer_unit", "producer_blocked",
                  "node_containers", "backfill_chunk"):
        assert never not in failing, f"{never} is normally absent, not broken"


def test_optional_services_are_not_blamed_when_not_configured(monkeypatch):
    """Running without the companion service is supported, so its absence is a
    choice rather than a fault."""
    _blind_agent(monkeypatch)
    monkeypatch.setattr(agent, "HEIGHT_URL", "")
    monkeypatch.setattr(agent, "PRODUCER_URL", "")
    monkeypatch.setattr(agent, "CLI_REGISTRY", "")
    failing = agent.collect()["agent_degraded"]
    for never in ("chain_heights", "producer_stats", "cli_latest"):
        assert never not in failing, failing


def test_no_container_means_no_container_readers_are_blamed(monkeypatch):
    """With the container gone the panel already says so. Six more failures
    underneath it are noise about a cause already known."""
    _blind_agent(monkeypatch)
    monkeypatch.setattr(agent, "find_container", lambda: None)
    failing = agent.collect()["agent_degraded"]
    for needs_container in ("cli_version", "log_tail", "producer_stats"):
        assert needs_container not in failing, failing


def test_a_healthy_agent_reports_an_empty_list(monkeypatch):
    """Sent even when empty: absent would be indistinguishable from an older
    agent that cannot report this at all."""
    _blind_agent(monkeypatch)
    monkeypatch.setattr(agent, "find_container", lambda: None)
    monkeypatch.setattr(agent, "HEIGHT_URL", "")
    monkeypatch.setattr(agent, "PRODUCER_URL", "")
    monkeypatch.setattr(agent, "CLI_REGISTRY", "")
    monkeypatch.setattr(agent, "read_image_inventory", lambda: 2)
    # A blind agent is not a healthy one until every reader works, and apt was
    # the one still left blind. Without this the test agrees with whichever
    # machine runs it: /usr/bin/apt is absent on Windows and present on the
    # Ubuntu runner, so it passed locally and failed in CI.
    monkeypatch.setattr(agent, "read_os_updates", lambda: (0, 0, 1.0, False))
    assert agent.collect()["agent_degraded"] == []


def _stub_docker_logs(monkeypatch, all_lines):
    """A `docker logs` stub that honours --tail, as the real one does. A tail
    test whose stub ignores --tail passes with the bug present."""
    def fake_run(args, timeout=10):
        if "logs" not in args:
            return None
        n = int(args[args.index("--tail") + 1])
        return "\n".join(all_lines[-n:])
    monkeypatch.setattr(agent, "run", fake_run)


def test_blank_lines_do_not_shrink_the_tail(monkeypatch):
    """Blanks are dropped after the tail is taken, so asking for exactly N
    returns fewer than N and the panel reads "last 20 lines" one minute and
    "last 16" the next, for no reason a reader can see."""
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 20)
    _stub_docker_logs(monkeypatch, ["" if i % 3 else "line%d" % i for i in range(90)])
    tail = agent.read_log_tail("xl1-producer")
    assert len(tail) == 20, f"expected a full 20 despite blanks, got {len(tail)}"
    assert all(line.strip() for line in tail)


def test_the_tail_is_the_most_recent_lines(monkeypatch):
    """Filling the count must not mean reaching further back than asked."""
    monkeypatch.setattr(agent, "LOG_TAIL_LINES", 5)
    _stub_docker_logs(monkeypatch, ["line%d" % i for i in range(50)])
    assert agent.read_log_tail("xl1-producer") == [
        "line45", "line46", "line47", "line48", "line49"]


def test_every_setting_is_documented():
    """A setting a reader cannot discover is not really a setting: this file is
    the whole reason nobody should have to read the source to configure the
    agent. It drifted in the sibling repo, which is why it is pinned here.
    """
    here = Path(__file__).parent
    src = (here / "xl1_heartbeat.py").read_text(encoding="utf-8")
    example = (here / "xl1-heartbeat.env.example").read_text(encoding="utf-8")
    read = set(re.findall(r'os\.environ\.get\(\s*"([A-Z0-9_]+)"', src))
    documented = set(re.findall(r'^#?\s*([A-Z0-9_]+)=', example, re.M))
    missing = read - documented
    assert not missing, (
        f"read by the agent but absent from the example file: {sorted(missing)}")


# --- the two faults this version fixes ---------------------------------------


@pytest.fixture
def worker_on(monkeypatch):
    """Pretend the worker thread is running, without starting one."""
    monkeypatch.setitem(agent._slow, "on", True)
    monkeypatch.setitem(agent._slow, "data", {})
    return agent._slow


def test_a_healthy_steady_state_agent_reports_nothing_failing(monkeypatch):
    """The test that catches a collector whose quiet path is normal.

    Checking a hand-picked list of normally-quiet collectors only ever covers
    cases already thought of, and it passed while this agent reported
    producer_stats as failing on a perfectly healthy node -- 29 beats out of
    30, naming the most consequential reader it has. This instead builds an
    agent where everything works and asserts that NOTHING is reported.
    """
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "read_cli_version", lambda name: "5.3.0")
    monkeypatch.setattr(agent, "fetch_cli_latest", lambda: "5.3.0")
    monkeypatch.setattr(agent, "read_log_tail", lambda name: ["a block"])
    monkeypatch.setattr(agent, "read_image_inventory", lambda: 3)
    monkeypatch.setattr(agent, "read_blocked_reason", lambda name: None)
    monkeypatch.setattr(agent, "read_producer_unit", lambda: None)
    monkeypatch.setattr(agent, "read_rebuild_timer", lambda: (None, None))
    monkeypatch.setattr(agent, "list_node_containers", lambda: ["xl1-producer"])
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 571178})

    # A scan ran nine minutes ago and is not due again for fifteen: the
    # overwhelmingly common state on any given heartbeat.
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: None)
    monkeypatch.setitem(agent._producer_cursor, "known", True)
    monkeypatch.setitem(agent._producer_cache, "at", agent.time.monotonic() - 540)
    monkeypatch.setattr(agent, "PRODUCER_INTERVAL", 900)
    # apt too, or this passes on a machine without it and fails on the Ubuntu
    # runner that actually executes it -- which is testing the operating system
    # rather than the agent.
    monkeypatch.setattr(agent, "read_os_updates", lambda: (0, 0, 1.0, False))

    failing = agent.collect()["agent_degraded"]
    assert failing == [], f"a healthy node must report nothing failing, got {failing}"


def test_a_scan_that_was_due_and_failed_is_still_reported(monkeypatch):
    """Suppressing the not-due case must not suppress the real one."""
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_producer_stats", lambda name: None)
    monkeypatch.setitem(agent._producer_cursor, "known", True)
    monkeypatch.setitem(agent._producer_cache, "at", agent.time.monotonic() - 4000)
    monkeypatch.setattr(agent, "PRODUCER_INTERVAL", 900)
    assert "producer_stats" in agent.collect()["agent_degraded"]


def test_the_beat_does_not_wait_for_a_slow_collector(worker_on, monkeypatch):
    """The production scan allows 180 seconds against the receiver's 90-second
    staleness threshold, so run inline it could report a healthy node OFFLINE."""
    def glacial(*a, **k):
        time.sleep(5)
        raise AssertionError("the beat called a slow collector directly")

    for slow in ("fetch_producer_stats", "read_log_tail", "fetch_cli_latest"):
        monkeypatch.setattr(agent, slow, glacial)
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 1})

    started = time.monotonic()
    agent.collect()
    assert time.monotonic() - started < 1.0, "the beat waited on background work"


def test_a_scan_is_reported_once_not_on_every_beat(worker_on, monkeypatch):
    """The scan reports a RANGE the receiver accumulates, so re-reading the
    worker's last result each beat would re-send an already-counted range."""
    monkeypatch.setattr(agent, "find_container", lambda: "xl1-producer")
    monkeypatch.setattr(agent, "fetch_block_heights", lambda: {"sequence": 1})
    agent._slow_put("producer_stats", {"fromBlock": 100, "toBlock": 199, "produced": 3})
    assert agent.collect().get("scan_from_block") == 100
    assert agent.collect().get("scan_from_block") is None, "and not reported again"


def test_reported_fields_are_pinned_to_the_version():
    """Every field this agent sends, pinned to the version that sends it.

    The sibling repo has had this for a while and it caught three version
    bumps that would otherwise have shipped silently. This one did not, and
    drifted eight releases behind as a result.

    If this fails: add the field below and raise the MINOR. If a field was
    removed instead, that is a MAJOR -- the receiver stops seeing something it
    was shown.
    """
    src = (Path(__file__).parent / "xl1_heartbeat.py").read_text(encoding="utf-8")
    found = set(re.findall(r'payload\["([a-z_0-9]+)"\]\s*=', src))
    added = found - REPORTED_FIELDS
    gone = REPORTED_FIELDS - found
    assert not added, f"heartbeat gained field(s) {sorted(added)} — add them and bump the MINOR"
    assert not gone, f"heartbeat lost field(s) {sorted(gone)} — that is a MAJOR"


# --- host packages -----------------------------------------------------------
#
# The layer under the node. A machine can sit unpatched for months while every
# node signal reads perfectly normal, because nothing else here looks at it.

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
