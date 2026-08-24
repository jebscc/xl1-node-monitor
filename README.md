# xl1-node-monitor

<!-- No CI badge while this repository is private. GitHub proxies README images
     anonymously, so the badge endpoint returns 404 and renders as failing no
     matter what the run did. Add it back if this ever goes public:
     ![CI](https://github.com/OWNER/xl1-node-monitor/actions/workflows/ci.yml/badge.svg) -->

Monitoring for a self-hosted [XYO Layer One](https://xyo.network/layer-one/)
node. A small agent runs beside your node and reports in; a receiver collects
those reports and serves a status page.

It answers three questions a node operator actually has:

- **Is my node up, and would I find out if it stopped?**
- **How many blocks has it produced, over its whole life, without double-counting?**
- **Is the software it runs still current?**

Built for a Raspberry Pi producing on the Sequence network, but nothing in it
is Pi-specific — any Linux machine running the node in Docker will do.

---

## Before you start

You need three things:

| | |
|---|---|
| **A running XL1 node** | In Docker, from [xl1-docker-images](https://github.com/XYOracleNetwork/xl1-docker-images). This tool watches a node; it does not create one. |
| **Shell access to that machine** | With `sudo`. Referred to below as *the node machine*. |
| **Somewhere to run the receiver** | Any machine the node machine can reach over HTTP. See [Where to run the receiver](#where-to-run-the-receiver). |

Check your node is actually running before going further:

```bash
docker ps
```

You should see a container from your XL1 image. Note its **image tag** (often
`xl1:local`) — you will need it in Step 5.

---

## How it fits together

The agent **pushes**; nothing polls your node. That matters for two reasons: a
node on a home network usually cannot be reached from outside, and **a machine
that has lost power cannot report that it is down**. Status is worked out by
the receiver from how long ago the last heartbeat arrived, so silence is itself
the signal.

```
node machine                                   anywhere
┌──────────────────────────┐                  ┌─────────────────────┐
│  XL1 node (Docker)       │                  │  receiver           │
│  xl1_heartbeat.py ───────┼── every 30s ────▶│  POST /heartbeat    │
└──────────────────────────┘  X-Node-Token    │  GET  /status       │
                                              └─────────────────────┘
```

---

## Part 1 — Run the receiver

### Where to run the receiver

Anywhere the node machine can reach:

- **Another machine on the same network** — simplest, and fine if you only ever
  check the status from home.
- **A small VPS or a PaaS** (Render, Fly, Railway…) — needed if you want to see
  the status from anywhere, or be told the node went down while you were out.
- **The node machine itself** — works, but tells you nothing when *that* machine
  dies, which is the case you most want covered. First trials only.

### 1. Get the code and install dependencies

```bash
git clone https://github.com/OWNER/xl1-node-monitor.git
cd xl1-node-monitor/receiver
pip install -r requirements.txt
```

Needs Python 3.9 or newer.

### 2. Make a shared secret

The agent and receiver authenticate with one shared token. Generate it now and
keep it to hand — you need the same value in two places.

```bash
openssl rand -hex 32
```

### 3. Start the receiver

```bash
export NODE_HEARTBEAT_TOKEN=paste-the-token-here
uvicorn app:app --host 0.0.0.0 --port 8000
```

Leave it running. In another terminal:

```bash
curl -s http://localhost:8000/healthz
```

Expected: `{"ok":true,"configured":true}`. If `configured` is `false`, the
token is not set in the shell that started `uvicorn`.

> **For real use**, run it under a process manager rather than a terminal, and
> put HTTPS in front of it. A token sent over plain HTTP is readable in transit.

---

## Part 2 — Install the agent on the node machine

Everything below runs **on the node machine**. Copy `agent/` there first, from
your own machine:

```bash
scp -r agent USER@NODE-MACHINE:/tmp/xl1-agent
```

### 4. Create the service account

The agent never needs root — it reads Docker state and `/proc`, nothing else.
This account exists so it cannot do more than that:

```bash
sudo useradd -r -s /usr/sbin/nologin -G docker xl1agent
```

`-G docker` grants access to the Docker socket, which is how it reads container
state. That is the only privilege it gets.

### 5. Write the configuration

```bash
sudo install -m 755 -d /opt/xl1-heartbeat
sudo cp /tmp/xl1-agent/xl1-heartbeat.env.example /etc/xl1-heartbeat.env
sudo nano /etc/xl1-heartbeat.env
```

Set these four at minimum:

| Setting | What to put |
|---|---|
| `BACKEND_URL` | Where your receiver is, e.g. `http://192.168.1.50:8000` |
| `NODE_HEARTBEAT_TOKEN` | The token from Step 2 — must match exactly |
| `XL1_IMAGE` | Your node's image tag from `docker ps`, e.g. `xl1:local` |
| `NODE_LABEL` | Any name you like; it appears on the status page |

Then lock it down, because it holds the token:

```bash
sudo chmod 600 /etc/xl1-heartbeat.env
```

> It does **not** hold your wallet mnemonic. The agent never reads, needs, or
> transmits your seed phrase.

### 6. Test one cycle before installing the service

This catches a wrong token or an unfindable container while you are still
watching:

```bash
sudo install -m 755 /tmp/xl1-agent/xl1_heartbeat.py /opt/xl1-heartbeat/
sudo sh -c 'set -a; . /etc/xl1-heartbeat.env; set +a; python3 /opt/xl1-heartbeat/xl1_heartbeat.py --once'
```

Expected output:

```
sent live=True status=running temp=41.2C
```

If it fails, see [Troubleshooting](#troubleshooting) before continuing.

### 7. Install and start the service

```bash
sudo install -m 644 /tmp/xl1-agent/xl1-heartbeat.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now xl1-heartbeat
```

`enable` makes it start again after a reboot; `--now` starts it immediately.

### 8. Confirm it is running

```bash
systemctl status xl1-heartbeat --no-pager
journalctl -u xl1-heartbeat -n 20 --no-pager
```

---

## Part 3 — Check it end to end

Ask the receiver what it knows:

```bash
curl -s http://YOUR-RECEIVER:8000/api/node/status
```

You should see your node with `"status":"ONLINE"` and a small
`seconds_since_heartbeat`. If it is `OFFLINE`, no heartbeat has arrived — the
agent's journal will say why.

**Then prove the monitoring reacts**, by stopping the node for a minute:

```bash
docker stop YOUR-CONTAINER
# wait ~90 seconds, check /api/node/status again -> DEGRADED
docker start YOUR-CONTAINER
```

A monitor you have never seen react is not yet a monitor.

---

## Reading the status

| Field | Meaning |
|---|---|
| `status` | `ONLINE`, `STARTING`, `DEGRADED` (machine reporting, node not serving), `OFFLINE` (no heartbeat) |
| `seconds_since_heartbeat` | Age of the last report — what `OFFLINE` is derived from |
| `produced_total` | Blocks this node has signed, counted once each |
| `counting_since_block` | Where counting began; `0` means from genesis |
| `blocks_skipped` | Blocks the counter could not account for. Should stay `0` |
| `temperature_c`, `cpu_percent` | Host vitals, measured on the machine itself |

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `BACKEND_URL and NODE_HEARTBEAT_TOKEN must be set` | The env file was not loaded. Check the path is exactly `/etc/xl1-heartbeat.env` |
| `HTTP 401` | Token mismatch. The agent's and the receiver's must be identical |
| `HTTP 503` | The receiver has no `NODE_HEARTBEAT_TOKEN` in its own environment |
| `DEGRADED` but the node looks fine | The agent cannot find the container. Check `XL1_IMAGE` matches `docker ps`, or set `XL1_CONTAINER` to the exact name |
| `permission denied … docker.sock` | `xl1agent` is not in the `docker` group. Re-run the `useradd` line, then `sudo systemctl restart xl1-heartbeat` |
| Memory shows as unavailable | Expected on Raspberry Pi OS — it ships with the kernel memory cgroup disabled, so `docker stats` reports `0B`. Host memory is substituted |
| Nothing in `/api/node/status` | The agent never reached the receiver. Run `curl -s BACKEND_URL/healthz` **from the node machine** |

---

## Optional: keep the node image current

`agent/rebuild-xl1-image.sh` and its timer rebuild the node image weekly when a
newer CLI is published, or when the current build is over 30 days old — base
images collect security patches even when the CLI does not.

```bash
sudo install -m 755 /tmp/xl1-agent/rebuild-xl1-image.sh /opt/xl1-heartbeat/
sudo install -m 644 /tmp/xl1-agent/xl1-image-rebuild.service /etc/systemd/system/
sudo install -m 644 /tmp/xl1-agent/xl1-image-rebuild.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now xl1-image-rebuild.timer
```

**It builds only.** It never retags the running image, stops a container, or
restarts the node. Swapping the image under a live node is a decision for a
human at a time of their choosing, not something to discover happened
overnight. A failed build leaves the running node untouched.

Run it once by hand rather than waiting for Sunday:

```bash
sudo systemctl start xl1-image-rebuild.service
journalctl -u xl1-image-rebuild -n 30 --no-pager
```

---

## Optional: block production counts

Counting blocks needs a service that can read the chain through
`@xyo-network/xl1-sdk` and report which blocks your address signed. That service
is **not included here**.

Without it the agent works normally and reports no production figures. With it,
point `XL1_HEIGHT_URL` at its `/block-height` endpoint and the counts appear.

---

## Design notes

The parts that took longest to get right, and why they are the way they are.

**Staleness is computed by the receiver.** A node that has lost power cannot
report that it is down, so `OFFLINE` is an absence of heartbeats rather than
anything the agent claims.

**Block counting is idempotent.** The agent is stateless; the receiver holds the
cursor and tells the agent where to resume, so a reimaged machine carries on
correctly. Only an *exact* continuation of the cursor is counted. A range
overlapping already-counted blocks is dropped rather than partly credited,
because there is no way to tell which of its hits fall after the cursor, and
guessing would quietly corrupt a figure meant to last years.

**Counting is bounded by the finalized head, never the latest block.** A block
counted before it finalizes can be removed by a reorg, and the cursor never goes
back to correct it. If finality is unavailable, counting *pauses* rather than
falling back: a counter that visibly stops is recoverable, one that quietly goes
wrong is not.

**Container discovery has three strategies** — explicit name, image tag, then
the entrypoint path. A tag can be moved during an image promotion, and when it
was, the node briefly looked missing while being perfectly healthy.

**The public view is an allow-list.** A block-list is only correct until someone
adds a field — which is exactly how a version string reached a public page after
a different version string had been deliberately withheld.

**A registry outage must not affect a heartbeat.** The version check is a
separate, swallowed request; the heartbeat goes out either way.

---

## The ingest contract

`POST /api/node/heartbeat` with an `X-Node-Token` header. The receiver replies
with the cursors the agent should resume from:

```json
{ "ok": true, "producer_cursor": 566143, "backfill_cursor": null,
  "backfill_complete": true, "last_produced_block": 565182 }
```

Unknown fields in a heartbeat are ignored rather than rejected, so an older
receiver keeps working against a newer agent.

The bundled receiver is deliberately small: SQLite, one file, no alerting, no
dashboard. Those are application decisions. What it does implement is the part
that is easy to get wrong — staleness, idempotent accounting, and the
public/private split — so the contract has an executable definition rather than
only prose.

---

## Tests

The agent needs only pytest — it imports nothing outside the standard library:

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

---

## Licence

MIT. Not affiliated with XY Labs or XYO — an independent tool built by a node
operator.
