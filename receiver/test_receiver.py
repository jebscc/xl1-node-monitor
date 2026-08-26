"""Tests for the reference receiver.

These pin the three properties the receiver exists to demonstrate: ingest is
closed to strangers, block accounting cannot be inflated by a replay, and the
public view is an allow-list.

    pip install -r requirements.txt pytest
    python -m pytest -q
"""

import os

import pytest

os.environ.setdefault("NODE_HEARTBEAT_TOKEN", "test-token")

AUTH = {"X-Node-Token": "test-token"}
BEAT = {"node_id": "pi-01", "label": "Pi 4", "network": "sequence",
        "live": True, "container_status": "running", "temperature_c": 41.2}


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DB_PATH", str(tmp_path / "test.db"))
    import importlib

    import app as mod
    importlib.reload(mod)
    from fastapi.testclient import TestClient
    return TestClient(mod.app)


def scan(client, frm, to, produced, finalized=True):
    return client.post("/api/node/heartbeat", headers=AUTH, json={
        **BEAT, "scan_from_block": frm, "scan_to_block": to,
        "scan_produced": produced, "scan_finalized": finalized})


def total(client):
    return client.get("/api/node/status").json()["nodes"][0].get("produced_total")


def _beat(client, **extra):
    return client.post("/api/node/heartbeat", headers=AUTH, json={**BEAT, **extra})


def _doc(client):
    """The operator view -- the public one is an allow-list by design."""
    return client.get("/api/node/detail", headers=AUTH).json()["nodes"][0]


def test_ingest_rejects_an_unauthenticated_post(client):
    assert client.post("/api/node/heartbeat", json=BEAT).status_code == 401


def test_ingest_accepts_the_shared_secret(client):
    assert client.post("/api/node/heartbeat", json=BEAT, headers=AUTH).status_code == 200


def test_an_exact_continuation_accumulates(client):
    scan(client, 100, 199, 3)
    scan(client, 200, 299, 2)
    assert total(client) == 5


def test_a_replayed_range_cannot_inflate_the_total(client):
    """A duplicated or out-of-order heartbeat must not be credited twice."""
    scan(client, 100, 199, 3)
    scan(client, 200, 299, 2)
    scan(client, 200, 299, 2)
    assert total(client) == 5


def test_an_unfinalized_scan_is_not_counted(client):
    """A block counted before it finalizes can be reorged away, and the cursor
    never goes back to correct it."""
    scan(client, 100, 199, 3)
    scan(client, 200, 299, 9, finalized=False)
    assert total(client) == 3


def test_counting_records_where_it_started(client):
    scan(client, 100, 199, 3)
    scan(client, 200, 299, 2)
    node = client.get("/api/node/status").json()["nodes"][0]
    assert node["counting_since_block"] == 100


def test_the_public_view_is_an_allow_list(client):
    client.post("/api/node/heartbeat", headers=AUTH, json=BEAT)
    body = client.get("/api/node/status").text
    for private in ("container_status", "producer_cursor", "scan_finalized", "live"):
        assert private not in body, private


def test_status_is_derived_from_heartbeat_age(client, monkeypatch):
    """A node that has lost power cannot report that it is down, so OFFLINE is
    an absence of heartbeats rather than anything the agent claims."""
    client.post("/api/node/heartbeat", headers=AUTH, json=BEAT)
    assert client.get("/api/node/status").json()["nodes"][0]["status"] == "ONLINE"

    import app as mod
    monkeypatch.setattr(mod, "HEARTBEAT_TTL_SECONDS", -1)
    assert client.get("/api/node/status").json()["nodes"][0]["status"] == "OFFLINE"


def test_a_stopped_container_is_degraded_not_offline(client):
    """The Pi is still reporting; the node is not serving. Different faults."""
    client.post("/api/node/heartbeat", headers=AUTH,
                json={**BEAT, "container_status": "exited", "live": False})
    assert client.get("/api/node/status").json()["nodes"][0]["status"] == "DEGRADED"


def test_unknown_fields_are_ignored_not_rejected(client):
    """An older receiver must keep working against a newer agent."""
    r = client.post("/api/node/heartbeat", headers=AUTH,
                    json={**BEAT, "some_future_field": 42})
    assert r.status_code == 200


# --- present-tense fields must not outlive the beat that reported them -------

def test_a_resolved_block_stops_being_reported(client):
    """The receiver carries fields forward when the agent stops sending them,
    which is what keeps running totals alive. For anything describing the
    present moment it is wrong: a node that recovered sends no reason at all,
    so the old one would survive every later beat and the node would read as
    permanently broken after a problem it had already fixed.
    """
    _beat(client, producer_blocked="insufficient stake")
    assert _doc(client)["producer_blocked"] == "insufficient stake"
    _beat(client)                                   # recovered: sends no reason
    assert "producer_blocked" not in _doc(client)


def test_a_stale_log_tail_is_not_shown_as_current(client):
    _beat(client, log_tail=["starting up", "block 1"])
    assert _doc(client)["log_tail"] == ["starting up", "block 1"]
    _beat(client)
    assert "log_tail" not in _doc(client)


def test_degraded_readers_round_trip(client):
    _beat(client, agent_degraded=["chain_heights", "log_tail"])
    assert _doc(client)["agent_degraded"] == ["chain_heights", "log_tail"]


def test_reader_names_are_not_free_text(client):
    _beat(client, agent_degraded=["chain_heights", "<img src=x onerror=alert(1)>"])
    assert _doc(client)["agent_degraded"] == ["chain_heights"]


def test_operator_detail_is_not_public(client):
    """A log tail can carry peer addresses and other detail that has no place
    on a public page. The allow list means this needs no thought -- but it
    needs a test, because the allow list is the only thing standing there."""
    _beat(client, log_tail=["peer 10.0.0.5 connected"], agent_degraded=["log_tail"],
          producer_blocked="insufficient stake", node_image_count=4)
    public = client.get("/api/node/status").json()["nodes"][0]
    for private in ("log_tail", "agent_degraded", "producer_blocked", "node_image_count"):
        assert private not in public, f"{private} leaked to the public view"


def test_the_operator_view_is_closed_to_strangers(client):
    """It returns everything, including the log tail."""
    _beat(client)
    assert client.get("/api/node/detail").status_code == 401
