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

`receiver/.env.example` lists every setting the receiver understands, with
notes on each. **It is a reference, not a file the receiver reads** — the app
takes its settings from the environment, however they got there.

Running locally, a file is the convenient way to set them:

```bash
cp .env.example .env        # .env is gitignored
nano .env                   # paste your token
set -a; . ./.env; set +a    # loads it into this shell
uvicorn app:app --host 0.0.0.0 --port 8000
```

Deploying to a host instead? Skip the file and type the same settings into the
service's environment page — see [Hosting the receiver](#hosting-the-receiver).

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

`agent/xl1-heartbeat.env.example` is a complete, commented reference — every
setting the agent reads, with its real default and what it does. The values in
it are made up; replace them.

Most of it is commented out on purpose. **Setting a variable to nothing is not
the same as leaving it out**: `XL1_HEIGHT_URL=` overrides the default with an
empty string and switches that feature off, where deleting the line gets the
default. A working file is often just the six lines below.

Set these four at minimum:

| Setting | What to put |
|---|---|
| `BACKEND_URL` | Your receiver's URL, e.g. `https://your-receiver.example.com` |
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

## Where every setting lives

Two machines, two different ways of being configured. Getting them confused is
the most common way a first setup fails.

| | Configured by | Lives where |
|---|---|---|
| **Agent** (node machine) | a file | `/etc/xl1-heartbeat.env`, root-owned, `chmod 600` |
| **Receiver** (wherever you host it) | environment variables | your host's settings page — **no file** |

The `.env.example` files in this repository are references for both. Only the
agent's is copied into place; the receiver's is a list of what to type.

### On the node machine — `/etc/xl1-heartbeat.env`

Read by the agent. `chmod 600`, owned by root. Full annotated reference:
[`agent/xl1-heartbeat.env.example`](agent/xl1-heartbeat.env.example).

| Setting | Required | Notes |
|---|---|---|
| `BACKEND_URL` | yes | Your receiver's public URL, no trailing slash |
| `NODE_HEARTBEAT_TOKEN` | yes | Must match the receiver's exactly |
| `XL1_IMAGE` | yes | Image tag from `docker ps` |
| `NODE_ID`, `NODE_LABEL`, `NODE_ROLE`, `NODE_NETWORK` | no | Identity on the status page. Quote values containing spaces |
| `XL1_CONTAINER` | no | Pin the container by name instead of discovering by image |
| `XL1_HEALTH_PORT`, `XL1_HEALTH_URL` | no | Only if you published the health port |
| `HEARTBEAT_INTERVAL` | no | Default `30` seconds |
| `XL1_HEIGHT_URL`, `XL1_PRODUCER_URL` | no | Only for [block counting](#optional-block-production-counts) |
| `XL1_REWARD_ADDRESS` | no | Only if discovery from the container fails |

### On the receiver host — environment variables, not a file

**There is no configuration file for the receiver.** Unlike the agent, which
reads `/etc/xl1-heartbeat.env`, the receiver takes everything from environment
variables. On a hosting provider you type them into that service's settings
page; nothing is written to disk and nothing is committed.

`receiver/.env.example` is a **checklist of what to type there**, with notes on
each setting. It is not a file you deploy. (Running the receiver on your own
machine is the one case where turning it into a real `.env` is convenient —
see [Step 3](#3-start-the-receiver).)

| Setting | Required | Notes |
|---|---|---|
| `NODE_HEARTBEAT_TOKEN` | yes | The same value as on the node machine |
| `DB_PATH` | no | Where SQLite writes. Default `nodes.db` beside the app — see below |
| `HEARTBEAT_TTL_SECONDS` | no | Default `90`. Seconds of silence before a node reads `OFFLINE` |

**The token is a secret.** It is the only thing stopping a stranger posting
fake heartbeats. Never commit it, and give the agent and receiver the same
value by pasting it into both, not by storing it anywhere shared.

---

## Hosting the receiver

Running `uvicorn` in a terminal is fine for a first try. For something you rely
on, it needs to survive restarts and be reachable over HTTPS.

### On a platform host (Render, Fly, Railway…)

Point the service at the `receiver/` directory and set:

| | |
|---|---|
| **Build command** | `pip install -r requirements.txt` |
| **Start command** | `uvicorn app:app --host 0.0.0.0 --port $PORT` |
| **Environment** | `NODE_HEARTBEAT_TOKEN` = your token |

`$PORT` matters: these platforms assign a port and expect your process to bind
to it. Hard-coding `8000` gets the deploy marked unhealthy even though the app
started fine.

You get HTTPS automatically, so `BACKEND_URL` on the node machine becomes
`https://your-service.example.com` with no trailing slash.

### The storage trap

**The bundled receiver writes to SQLite on local disk, and most platform hosts
give you a filesystem that is wiped on every deploy and restart.** The service
keeps working — it recreates the database and carries on — but you silently
lose the block-production cursor and the lifetime total, and counting restarts
from wherever the next scan begins.

Three ways to deal with it, in increasing order of effort:

**1. Accept it.** Live status is unaffected: heartbeats, `ONLINE`/`OFFLINE`,
temperature and CPU are all derived from the most recent report. Only the
counting history is lost. Fine if you are just watching whether the node is up.

**2. Attach a persistent disk.** Most platforms offer one. Mount it and set
`DB_PATH` to a file on it, e.g. `/data/nodes.db`. Smallest change that keeps
your totals.

**3. Use a hosted database.** If you want managed backups, or several receivers
sharing one store, replace the SQLite calls in `receiver/app.py` with a client
for the database of your choice — MongoDB Atlas, hosted Postgres, whatever you
already run. The receiver is one file and touches storage in four small
functions (`db`, `load`, `save`, and the query in `status`), so this is a
contained change rather than a rewrite.

Whichever you pick, **the database belongs with the receiver, not on the node
machine.** A store that dies with the node cannot tell you the node died.

### A note on where the receiver runs

Do not run it on the machine running the node. It will work, and it will tell
you nothing at the moment you most need it — when that machine loses power, the
thing that would have noticed went down with it.

### Building a status page

This repository ships no user interface — it ends at a JSON API. If you want a
page, host a frontend anywhere static (Vercel, Netlify, Cloudflare Pages) and
have it fetch `GET /api/node/status` from your receiver.

Two things to expect when you do:

- **CORS.** A browser on a different origin will be refused unless the receiver
  sends the matching headers. FastAPI's `CORSMiddleware` handles it; allow only
  your own site's origin, not `*`.
- **The status endpoint is public and deliberately narrow.** It returns an
  allow-list of fields, so a browser can call it directly without exposing
  anything you would not put on a public page.

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

## Optional: build new node images automatically

**This does not update your node.** It builds an image and stops there; your
node keeps running whatever it was running until you promote the new one
yourself. That is deliberate — see below.

`agent/rebuild-xl1-image.sh` and its timer rebuild weekly when a newer CLI is
published, or when the current build is over 30 days old, since base images
collect security patches even when the CLI does not.

```bash
sudo install -m 755 /tmp/xl1-agent/rebuild-xl1-image.sh /opt/xl1-heartbeat/
sudo install -m 644 /tmp/xl1-agent/xl1-image-rebuild.service /etc/systemd/system/
sudo install -m 644 /tmp/xl1-agent/xl1-image-rebuild.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now xl1-image-rebuild.timer
```

Run it once by hand rather than waiting for Sunday:

```bash
sudo systemctl start xl1-image-rebuild.service
journalctl -u xl1-image-rebuild -n 30 --no-pager
```

Forcing a rebuild when nothing has changed, to check the whole path works:

```bash
sudo XL1_MAX_IMAGE_AGE_DAYS=0 /opt/xl1-heartbeat/rebuild-xl1-image.sh
```

Note that has to run the script directly. Going through
`systemctl start` uses the unit file's environment, so the override is ignored
and it skips as usual.

### Why it stops short of updating

Swapping the image under a running node is a decision for a human at a time of
their choosing, not something to discover happened overnight. A failed build
leaves the node untouched, and a smoke test runs before anything is suggested
for promotion.

New images are tagged by version — `xl1:5.2.2` — and the tag your node actually
runs, usually `xl1:local`, is never moved by the script.

### Promoting a built image

When you are ready, point your running tag at the new build and recreate the
container **with the same command you originally started it with**:

```bash
docker tag xl1:5.2.2 xl1:local          # use the version the build reported
docker rm -f xl1-producer
docker run -d --name xl1-producer --restart unless-stopped   --env-file /path/to/your.env xl1:local
```

The script prints these three lines, filled in for your setup, whenever it
builds something newer than what is running — check the journal rather than
retyping them from here.

### Rolling back

Old versions keep their own tags, so a rollback needs no rebuild:

```bash
docker images xl1
docker tag xl1:5.2.1 xl1:local          # the version you were on before
docker rm -f xl1-producer
# then the same docker run as above
```

Retagging briefly leaves the running container on an untagged image. The
agent's container discovery falls back to the entrypoint path, so it keeps
reporting through the gap rather than showing the node as missing.

---

## Optional: block production counts

Everything so far works without this. Skip it unless you want the panel to
report **how many blocks your node has signed**.

Counting needs something that can read the chain. The agent deliberately does
not: it never speaks JSON-RPC and holds no keys. It calls two HTTP endpoints
and does the accounting from what they return, so **you supply a small service
that answers them**. One is not bundled here.

### What you have to provide

A service reachable from the node machine — usually a container on the same
host — exposing two `GET` endpoints. Build it with
[`@xyo-network/xl1-sdk`](https://www.npmjs.com/package/@xyo-network/xl1-sdk),
which is the supported way to read XL1. Do not hand-roll JSON-RPC.

**1. Chain height**

```
GET /block-height?network=sequence
→ { "height": 566690 }
```

Called once per network in `XL1_HEIGHT_NETWORKS`. Anything other than a number
is ignored, so a failure here costs you the height display and nothing else.

**2. Producer activity**

```
GET /producer?address=<40-hex>&window=200
GET /producer?address=<40-hex>&window=200&since=566500     # incremental
GET /producer?address=<40-hex>&window=200&from=0&to=49999  # backfill chunk
```

Returns the blocks that address signed in the range it scanned:

| Field | Meaning |
|---|---|
| `fromBlock`, `toBlock` | The range actually scanned. The receiver counts only an exact continuation of its cursor, so these must be honest |
| `produced` | How many blocks in that range the address signed |
| `height` | The head the scan was bounded by |
| `finalized` | `true` if `height` is the **finalized** head. See below — this one matters |
| `floor` | Lowest block the service will read. `0` for a full-history indexer |
| `lastProducedBlock`, `blocksSinceProduced` | Most recent sighting, if any |
| `window`, `latestEpoch`, `pendingTransactions`, `pendingBlocks` | Optional context |
| `explorer.lastProducedBlock` | Optional explorer URL for that block |

**Bound the scan by the finalized head, not the latest block**, and report
`finalized: false` if you cannot. A block counted before it finalizes can be
removed by a reorg, and the cursor never goes back to correct it. When
`finalized` is `false` the receiver *pauses* counting rather than recording a
figure that could quietly drift.

### Configuration, once the service is running

Add to `/etc/xl1-heartbeat.env`:

```bash
XL1_HEIGHT_URL=http://127.0.0.1:8090/block-height
XL1_PRODUCER_URL=http://127.0.0.1:8090/producer
```

Then restart and watch one cycle:

```bash
sudo systemctl restart xl1-heartbeat
journalctl -u xl1-heartbeat -f
```

Within about fifteen minutes the heartbeat log gains a `scan=` field, and
`produced_total` appears in `/api/node/status`.

### Which address is counted

The agent reads the reward address **out of the running container's
environment** — you usually need to set nothing. Override only if that fails:

```bash
XL1_REWARD_ADDRESS=your40hexaddresswithout0xprefix
```

The address is used on the node machine to build the scan request. It is not
sent to the receiver, and the mnemonic sharing that container environment is
never read.

### Tuning

| Setting | Default | What it does |
|---|---|---|
| `XL1_HEIGHT_NETWORKS` | `sequence,mainnet` | Which networks to ask for heights |
| `XL1_PRODUCER_INTERVAL` | `900` | Seconds between scans. Scanning is the expensive call, so it is far less frequent than the heartbeat |
| `XL1_PRODUCER_WINDOW` | `200` | Blocks to scan on the very first run, before a cursor exists |
| `XL1_BACKFILL_CHUNK` | `50000` | Blocks per history chunk, walking backwards toward genesis. `0` disables backfill and counts only from today |

Backfill runs alongside normal counting: the agent walks history downward in
chunks while the forward scan keeps up with the head, so the lifetime total
grows until the whole chain has been read. `counting_since_block` reaching `0`
means it got to genesis.

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
