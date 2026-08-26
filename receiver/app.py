"""Reference receiver for xl1-node-monitor.

Deliberately small: one file, SQLite, no external services. It exists so the
agent can be run end to end without first building a backend, and so the
ingest contract has an executable definition rather than only prose.

What it does implement is the part that is easy to get wrong:

  * staleness derived from heartbeat AGE, on this side. A node that has lost
    power cannot report that it is down, so "down" must never be something the
    agent claims.
  * idempotent block accounting. Only an exact continuation of the cursor is
    counted, so a replayed, duplicated or out-of-order heartbeat cannot inflate
    a total meant to run for years.
  * a public view built from an allow-list, so a field added later is private
    until someone decides otherwise.

What it does not implement: email alerting, daily rollups, or an operator
dashboard. Those are application decisions, and this is a reference.

    pip install -r requirements.txt
    NODE_HEARTBEAT_TOKEN=$(openssl rand -hex 32) uvicorn app:app --port 8000
"""

from __future__ import annotations

import hmac
import json
import re
import os
import sqlite3
import time
from contextlib import closing
from datetime import datetime, timezone
from typing import List, Any, Dict, Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field, field_validator

DB_PATH = os.environ.get("DB_PATH", "nodes.db")
NODE_TOKEN = os.environ.get("NODE_HEARTBEAT_TOKEN", "")
# A node is OFFLINE once this much time has passed with no heartbeat. Three
# missed beats at the default 30s interval.
HEARTBEAT_TTL_SECONDS = int(os.environ.get("HEARTBEAT_TTL_SECONDS", "90"))

app = FastAPI(title="xl1-node-monitor receiver")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("CREATE TABLE IF NOT EXISTS nodes (node_id TEXT PRIMARY KEY, doc TEXT NOT NULL)")
    return conn


def load(node_id: str) -> Dict[str, Any]:
    with closing(db()) as conn:
        row = conn.execute("SELECT doc FROM nodes WHERE node_id = ?", (node_id,)).fetchone()
    return json.loads(row["doc"]) if row else {}


def save(node_id: str, doc: Dict[str, Any]) -> None:
    with closing(db()) as conn:
        conn.execute("INSERT INTO nodes (node_id, doc) VALUES (?, ?) "
                     "ON CONFLICT(node_id) DO UPDATE SET doc = excluded.doc",
                     (node_id, json.dumps(doc)))
        conn.commit()


class Heartbeat(BaseModel):
    """Only the fields this reference uses. The agent sends more; unknown
    fields are ignored rather than rejected, so an older receiver keeps
    working against a newer agent."""

    model_config = {"extra": "allow"}

    node_id: str = Field(max_length=64)

    @field_validator("agent_degraded")
    @classmethod
    def _bound_degraded(cls, v):
        """Field names, not free text. The agent picks from a fixed set, but
        the token is all it takes to post here."""
        if v is None:
            return v
        return [n for n in v if isinstance(n, str) and re.fullmatch(r"[a-z_]{1,40}", n)]

    label: Optional[str] = Field(default=None, max_length=64)
    role: Optional[str] = Field(default=None, max_length=32)
    network: Optional[str] = Field(default=None, max_length=32)
    live: Optional[bool] = None
    container_status: Optional[str] = Field(default=None, max_length=32)
    cpu_percent: Optional[float] = None
    temperature_c: Optional[float] = None
    chain_heights: Optional[Dict[str, int]] = None
    # The node's own most recent output, and the reason it says it cannot
    # produce, so an operator can see both without reaching the machine.
    log_tail: Optional[List[str]] = Field(default=None, max_length=100)
    producer_blocked: Optional[str] = Field(default=None, max_length=200)
    node_image_count: Optional[int] = Field(default=None, ge=0, le=10000)
    # Which of the agent's own readers came back empty when they should not
    # have. Every collector in the agent returns None on failure so a failure
    # can never break a heartbeat, which makes a blank field ambiguous between
    # "not collected yet" and "collection is broken". This resolves it.
    agent_degraded: Optional[List[str]] = Field(default=None, max_length=40)
    last_produced_block: Optional[int] = None
    # One scanned range. The receiver accumulates these; the agent stays
    # stateless and is told where to resume.
    scan_from_block: Optional[int] = None
    scan_to_block: Optional[int] = None
    scan_produced: Optional[int] = None
    # Whether the scan was bounded by the FINALIZED head. A block counted
    # before it finalizes can be reorged away, and the cursor never returns to
    # correct it, so an unfinalized scan is not counted at all.
    scan_finalized: Optional[bool] = None


def require_token(x_node_token: str = Header(default="")) -> None:
    """Shared secret for ingest, compared in constant time."""
    if not NODE_TOKEN:
        raise HTTPException(503, "NODE_HEARTBEAT_TOKEN is not configured")
    if not hmac.compare_digest(x_node_token, NODE_TOKEN):
        raise HTTPException(401, "Invalid node token")


def accumulate(prev: Dict[str, Any], hb: Heartbeat) -> Dict[str, Any]:
    """Add one scanned range to the lifetime total, idempotently.

    Only an exact continuation of the cursor counts. A range that overlaps
    already-counted blocks is dropped rather than partially credited: there is
    no way to tell which of its hits fall after the cursor, and guessing would
    quietly corrupt the figure.
    """
    if hb.scan_finalized is False:
        return {}                       # wait for finality rather than drift
    frm, to, produced = hb.scan_from_block, hb.scan_to_block, hb.scan_produced
    if frm is None or to is None or produced is None or to < frm:
        return {}

    cursor = prev.get("producer_cursor")
    if cursor is None:                                  # first scan
        return {"produced_total": (prev.get("produced_total") or 0) + produced,
                "producer_cursor": to,
                "counting_since_block": frm}
    if frm == cursor + 1:                               # exact continuation
        return {"produced_total": (prev.get("produced_total") or 0) + produced,
                "producer_cursor": to,
                "counting_since_block": prev.get("counting_since_block", frm)}
    if to <= cursor:
        return {}                                       # already counted
    return {"blocks_skipped": (prev.get("blocks_skipped") or 0) + (frm - cursor - 1),
            "produced_total": (prev.get("produced_total") or 0) + produced,
            "producer_cursor": to,
            "counting_since_block": prev.get("counting_since_block", frm)}


def decorate(doc: Dict[str, Any]) -> Dict[str, Any]:
    """Add the fields derived HERE rather than reported by the node."""
    out = dict(doc)
    age = None
    if doc.get("received_at"):
        try:
            age = int((datetime.now(timezone.utc)
                       - datetime.fromisoformat(doc["received_at"])).total_seconds())
        except ValueError:
            age = None
    out["seconds_since_heartbeat"] = age
    if age is None or age > HEARTBEAT_TTL_SECONDS:
        out["status"] = "OFFLINE"       # silence is the signal, not a claim
    elif not doc.get("live") or doc.get("container_status") != "running":
        out["status"] = "DEGRADED"
    else:
        out["status"] = "ONLINE"
    return out


# An allow-list, not a block-list. A block-list is only correct until someone
# adds a field; this way anything new is private until it is chosen.
PUBLIC_FIELDS = (
    "node_id", "label", "role", "network", "status",
    "produced_total", "counting_since_block", "blocks_skipped",
    "last_produced_block", "chain_heights",
    "cpu_percent", "temperature_c", "seconds_since_heartbeat",
)


@app.post("/api/node/heartbeat")
def heartbeat(hb: Heartbeat, _: None = Depends(require_token)):
    prev = load(hb.node_id)
    doc = {**prev, **hb.model_dump(exclude_none=True), "received_at": now_iso()}
    # exclude_none carries a field forward when the agent stops sending it,
    # which is what keeps running totals alive across beats -- and is wrong for
    # anything describing the present moment. A node that was blocked and has
    # recovered reports no reason at all, so without this the old reason
    # survives every later heartbeat and the node reads as permanently broken
    # after a problem it already resolved. Same for a log tail, which would sit
    # there looking current long after it was.
    for transient in ("producer_blocked", "log_tail"):
        if getattr(hb, transient, None) is None:
            doc.pop(transient, None)
    doc.update(accumulate(prev, hb))
    save(hb.node_id, doc)
    # Tell the agent where to resume, so it holds no durable state of its own
    # and a reimaged Pi carries on from the right place.
    return {"ok": True,
            "producer_cursor": doc.get("producer_cursor"),
            "backfill_cursor": doc.get("backfill_cursor"),
            "backfill_complete": bool(doc.get("backfill_complete")),
            "last_produced_block": doc.get("last_produced_block")}


@app.get("/api/node/status")
def status():
    with closing(db()) as conn:
        rows = conn.execute("SELECT doc FROM nodes").fetchall()
    nodes = [decorate(json.loads(r["doc"])) for r in rows]
    public = [{k: v for k, v in n.items() if k in PUBLIC_FIELDS} for n in nodes]
    return {"nodes": sorted(public, key=lambda n: n.get("node_id") or ""),
            "online": sum(1 for n in nodes if n["status"] == "ONLINE"),
            "heartbeat_ttl_seconds": HEARTBEAT_TTL_SECONDS,
            "generated_at": now_iso()}


@app.get("/api/node/detail")
def detail(_: None = Depends(require_token)):
    """Everything the node reports, for whoever runs it.

    The public view above is a strict allow-list, which is right: a log tail
    can carry peer addresses, and which of an operator's readers are failing is
    nobody else's business. But an allow-list with nothing behind it means the
    detailed fields are written and never read, so this serves them.

    Gated by the ingest token because this reference has exactly one secret. A
    real deployment should put a separate operator credential here -- a token
    that can WRITE heartbeats should not be the same one that can READ
    everything the node knows.
    """
    with closing(db()) as conn:
        rows = conn.execute("SELECT doc FROM nodes").fetchall()
    nodes = [decorate(json.loads(r["doc"])) for r in rows]
    return {"nodes": sorted(nodes, key=lambda n: n.get("node_id") or ""),
            "generated_at": now_iso()}


@app.get("/healthz")
def healthz():
    return {"ok": True, "configured": bool(NODE_TOKEN)}
