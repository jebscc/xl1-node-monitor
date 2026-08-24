# xl1-node-monitor

<!-- No CI badge while this repository is private. GitHub proxies README images
     anonymously, so the badge endpoint returns 404 and renders as failing no
     matter what the run did. Add it back if this ever goes public:
     ![CI](https://github.com/OWNER/xl1-node-monitor/actions/workflows/ci.yml/badge.svg) -->

Monitoring for a self-hosted [XYO Layer One](https://xyo.network/layer-one/)
block producer: a heartbeat agent for the machine running the node, and a small
reference receiver so it works end to end out of the box.

Built for and running on a Raspberry Pi producing on the Sequence testnet. It
answers three questions a node operator actually has:

- Is my node up, and would I find out if it stopped?
- How many blocks has it produced, over its whole life, without double-counting?
- Is the software it runs still current?

## Why the agent pushes

The node sits on a home LAN. Nothing on the internet can reach it, so anything
that tries to poll it has to be on the same network — which rules out a hosted
dashboard.

The agent pushes instead. That also fixes a subtler problem: **a node that has
lost power cannot report that it is down.** Status is therefore derived on the
receiving side from heartbeat *age*, never from anything the agent claims. If
the Pi disappears, the silence is the signal.

```
Raspberry Pi                                  anywhere
┌────────────────────────────┐                ┌──────────────────────┐
│  XL1 node (Docker)         │                │  receiver            │
│  xl1-service  (optional) ──┼── block counts │   ├ POST /heartbeat  │
│  xl1_heartbeat.py ─────────┼── every 30s ──▶│   └ GET  /status     │
└────────────────────────────┘  X-Node-Token  └──────────────────────┘
```

## Quick start

**1. Run the receiver** (anywhere the Pi can reach — a VPS, a PaaS, or another
machine on the LAN):

```bash
cd receiver
pip install -r requirements.txt
export NODE_HEARTBEAT_TOKEN=$(openssl rand -hex 32)
uvicorn app:app --host 0.0.0.0 --port 8000
```

**2. Configure the agent** on the Pi. Copy `agent/xl1-heartbeat.env.example` to
`/etc/xl1-heartbeat.env`, set `BACKEND_URL` and the same
`NODE_HEARTBEAT_TOKEN`, then:

```bash
sudo chmod 600 /etc/xl1-heartbeat.env
sudo install -m 755 agent/xl1_heartbeat.py /opt/xl1-heartbeat/xl1_heartbeat.py
sudo install -m 644 agent/xl1-heartbeat.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now xl1-heartbeat
```

**3. Check it:**

```bash
curl -s http://your-receiver:8000/api/node/status
```

The agent is **stdlib-only Python 3** — no pip install on the Pi. It reads
container state through `docker`, so its service account needs to be in the
`docker` group and nothing more.

## What the agent reports

Container state and health, restarts, host uptime and reboot count, CPU,
memory, disk, SoC temperature, chain height, block production counts, and the
XL1 CLI version running *inside* the container alongside the newest published
one.

It never reads, needs, or transmits your mnemonic. The reward address is used
on the Pi to scan for produced blocks and is not sent to the receiver.

## Design notes

The parts that took the longest to get right, and why they are the way they
are:

**Staleness is computed by the receiver.** See above. `OFFLINE` is an absence
of heartbeats, not a report.

**Block counting is idempotent.** The agent is stateless; the receiver holds
the cursor and tells the agent where to resume, so a reimaged Pi carries on
correctly. Only an *exact* continuation of the cursor is counted. A range that
overlaps already-counted blocks is dropped rather than partially credited,
because there is no way to tell which of its hits fall after the cursor, and
guessing would quietly corrupt a figure meant to last years.

**Counting is bounded by the finalized head, never the latest block.** A block
counted before it finalizes can be removed by a reorg, and the cursor never
goes back to correct it. If finality is unavailable, counting *pauses* rather
than falling back to the latest block: a counter that visibly stops is
recoverable, one that quietly goes wrong is not.

**Container discovery has three strategies.** Explicit name, then image tag,
then the entrypoint path. A tag can be moved during a promotion, and when it
was, the node briefly looked missing while being perfectly healthy — hence the
fallbacks.

**Per-container memory may be unavailable.** Raspberry Pi OS ships with the
kernel memory cgroup disabled, so `docker stats` reports `0B`. That is reported
as unavailable and host memory is substituted, rather than displaying a
confident zero.

**The public view is an allow-list.** A block-list is only correct until
someone adds a field — which is exactly how a version string reached a public
page after a different version string had been deliberately withheld. Anything
new is private until someone chooses otherwise.

**A registry outage must not affect a heartbeat.** The version check is a
separate, swallowed request; the heartbeat goes out either way.

## Keeping the node image current

`agent/rebuild-xl1-image.sh` plus the accompanying systemd timer rebuild the
node image weekly when a newer CLI is published, or when the existing build has
aged past 30 days — base images collect security patches even when the CLI does
not.

**It builds only.** It never retags the running image, stops a container, or
restarts the producer. Swapping the image under a live block producer is a
decision for a human at a time of their choosing, not something to discover
happened overnight. A failed build leaves the running node untouched, and a
smoke test runs before anything is suggested for promotion.

## The ingest contract

`POST /api/node/heartbeat` with an `X-Node-Token` header. The receiver replies
with the cursors the agent should resume from:

```json
{ "ok": true, "producer_cursor": 566143, "backfill_cursor": null,
  "backfill_complete": true, "last_produced_block": 565182 }
```

Unknown fields in the heartbeat are ignored rather than rejected, so an older
receiver keeps working against a newer agent.

## What is not included

The reference receiver is deliberately small: SQLite, one file, no email
alerting, no daily rollups, no dashboard. Those are application decisions. What
it does implement is the part that is easy to get wrong — staleness, idempotent
accounting, and the public/private split — so the contract has an executable
definition rather than only prose.

Block production counting needs a service that can read the chain through
`@xyo-network/xl1-sdk`. That service is not included here; the agent works
without it and simply reports no production figures.

## Tests

The agent needs only pytest -- it imports nothing outside the standard library:

```bash
cd agent && python -m pytest -q
```

The receiver needs its runtime dependencies plus the test-only ones. Starlette's
TestClient requires an HTTP client it does not itself declare, so a clean
environment fails at import without them:

```bash
cd receiver && pip install -r requirements.txt -r requirements-dev.txt
python -m pytest -q
```

## Licence

MIT. Not affiliated with XY Labs or XYO — an independent tool built by a node
operator.
