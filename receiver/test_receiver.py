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
BEAT = {"node_id": "pi-01", "label": "Pi 5", "network": "sequence",
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
