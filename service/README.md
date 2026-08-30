# xl1-anchor-service

A small HTTP service that reads the **XYO Layer One** chain through the official
SDK and answers questions the rest of this project needs answered:

- how tall is the chain right now
- how many blocks has a given address produced
- what is the explorer URL for block N

It also anchors payloads on-chain, which is what the site's adventure log uses
to make a claim verifiable.

> **This README replaced XYO's sample-code README**, which shipped with the
> upstream template and described a different program. If you are looking for
> XYO's own Node samples, they are at
> [XYOracleNetwork/xl1-samples-nodejs](https://github.com/XYOracleNetwork/xl1-samples-nodejs).

## Why it exists

The Python backend and the Raspberry Pi agent both need chain data, and the XL1
SDK is TypeScript. Rather than reimplement the protocol badly in Python, this
service wraps the SDK and exposes a few endpoints over HTTP.

**It is optional, but less so than it used to be.** Without it you lose block
heights, the block-production counter, the producer's balance, and the
funded/not-funded state the node's own eligibility depends on. The agent
reports `producer_balance` as a failing reader when it cannot reach this, so
the panel says so rather than showing a blank.

It is also where the balance's ticker comes from. Neither the SDK nor the
explorer exposes one, so this service is the single place that names the asset
and the dashboard renders whatever it reports.

## Prerequisites

- **Node.js 24+** (`node --version`)
- **pnpm** (`corepack enable` gives you it)

## Run it

```bash
cd xl1-service
corepack enable
pnpm install
pnpm start
```

Listens on `127.0.0.1:8090` by default — loopback, so nothing on your network
reaches it whichever way you start it. That used to be true only under
`docker-compose.pi.yml`, which meant the documented `pnpm start` above served
it to the whole LAN. Set `XL1_SERVICE_HOST=0.0.0.0` if you want that on purpose.

Confirm:

```bash
curl -s http://127.0.0.1:8090/health
```

### Keeping it running

`pnpm start` is a foreground process — fine for a look, useless for a node that
has to answer at 3am. See [Running it on the Pi](#running-it-on-the-pi) below,
which is the supported arrangement.

If something is already listening, find out what before starting another:

```bash
sudo ss -lptn 'sport = :8090'
```

Two processes on that port present as a service that will not stay up, with the
cause two directories from the symptom.

## Endpoints

Every read works with no wallet configured. Only the two writes need a signer,
and both refuse without `XL1_ANCHOR_TOKEN` alongside it.

### Chain reads

| Method | Route | Purpose |
|---|---|---|
| GET | `/health` | Liveness, plus whether a signer is configured. Uses the read-only gateway path on purpose, so it answers on a node with no wallet |
| GET | `/block-height?network=` | The network's current head: `height`, `networkLabel`, `at`. A federated producer serves no RPC of its own, so this is read from the public gateway. It does **not** report finality — finality is applied inside `/producer`, which will not count unfinalized blocks into a durable total |
| GET | `/explorer/block/:number` | Canonical explorer URL for a block. Built here so callers do not hardcode the host |
| GET | `/versions` | Resolved versions of the XL1/XYO packages and of Node itself — what is actually running, not what a tag claims |

### About a producer

| Method | Route | Purpose |
|---|---|---|
| GET | `/producer?address=&from=&to=` | Blocks the address produced in a range. Walks down to `XL1_INDEXER_FLOOR_BLOCK` |
| GET | `/standing?address=&network=` | Balance as `balance` and `balanceRaw` (a string — the raw figure exceeds what a JSON number holds exactly), plus stake. **Stake is on the BACKING EVM, not on XL1**: without `XL1_SEQUENCE_EVM_RPC_URL` set, stake comes back `null` rather than zero |
| GET | `/earnings?address=&network=` | Splits what producing *paid* from what merely arrived. Block rewards are minted, so a balance built only from them is an exact multiple of the per-block reward and the remainder is everything that is not reward money. `earned: null` means the split could not be made — not that nothing was earned |
| GET | `/peers?network=&window=` | The producer set over the last N blocks (50–2000, default 1000), each with block count and balance, plus totals. One request plus a balance lookup per producer found; cached, because the walk is the expensive part. Producers whose balance could not be read are excluded from `totalBalance` rather than counted as zero |

### Writes

| Method | Route | Purpose |
|---|---|---|
| POST | `/hash` | Canonical XYO hash of a payload. Writes nothing, needs no wallet — use it to see exactly what *would* be anchored before spending anything |
| POST | `/attest` | Anchors a **node reading**: give it producer, height, lastProducedBlock and the machine figures, and it builds the canonical record, hashes it, anchors the hash and returns `attestedBy`. **Signer + token** |
| POST | `/anchor` | Anchors an arbitrary payload you supply. **Signer + token** |

`/attest` and `/anchor` differ in who builds the record. `/anchor` takes yours
as given; `/attest` constructs it here to one shape, which is what makes two
readings from different days comparable. Note what `/attest` deliberately will
not carry: a lifetime `producedTotal`. That figure is accumulated by whatever
receives it, and an attestation asserting it would be this node vouching for
arithmetic done somewhere else.

Anchoring writes only the **hash** on-chain. The payload is kept separately
(`XL1_ATTEST_ARCHIVE`), so this buys tamper-evidence, not availability — see
[If an anchor is lost in transit](#if-an-anchor-is-lost-in-transit).

## Configuration

All optional except where a feature requires it.

| Variable | Default | Notes |
|---|---|---|
| `XL1_SERVICE_PORT` | `8090` | Listen port |
| `XL1_SERVICE_HOST` | `127.0.0.1` | Interface to bind. Loopback by default; set `0.0.0.0` only if you mean it — **containers need it**, see below |
| `XL1_ANCHOR_TOKEN` | *(empty)* | Required in `X-Anchor-Token` before `/anchor` will sign. Only consulted when a mnemonic is set |
| `XL1_NETWORK` | `sequence` | Which chain reads default to |
| `XL1_SEQUENCE_RPC_URL` | SDK default | Override the sequence endpoint |
| `XL1_MAINNET_RPC_URL` | SDK default | Override the mainnet endpoint |
| `XL1_SEQUENCE_EVM_RPC_URL` | *(unset)* | Sepolia endpoint. Staking lives on the backing EVM, not on XL1; without this `/standing` reports `stake: null` |
| `XL1_MAINNET_EVM_RPC_URL` | *(unset)* | Ethereum mainnet endpoint, same purpose |
| `XL1_EXPLORER_URL` | SDK default | Base URL used to build explorer links |
| `XL1_INDEXER_FLOOR_BLOCK` | `0` | Lowest block the counter will walk back to |
| `XYO_CHAIN_RPC_URL` | SDK default | Endpoint used for anchoring |
| `XYO_WALLET_MNEMONIC` | *(unset)* | **Only needed for `/anchor`.** Without it the service starts read-only and `/health` reports `signing: false`. |

## Attesting the node's own readings

Blocks this producer signed are on chain, so anyone can check them. The hardware
readings are not: CPU, temperature and memory are the machine describing itself,
and nothing stops that description being edited afterwards.

`POST /attest` fixes the second half. Only a hash goes on chain — anchoring
publishes no telemetry — but the reading becomes tamper-evident, because editing
any part of it changes the hash.

The hash is plain `sha256` over canonical JSON with sorted keys, which is what
`PayloadBuilder.hash` computes. So verification needs no XYO code:

```bash
python verify-attestation.py attestation.json
```

That recomputes the hash, prints the readings so you see what you verified, and
exits non-zero on a mismatch.

### If an anchor is lost in transit

The anchor happens here, and the payload only reaches the caller in the HTTP
response. A response lost to a broken pipe, a timeout, or a restart mid-request
spends gas and destroys the only copy of what the transaction committed to —
the chain keeps a hash, and the gateway does not serve payloads back.

So an anchored attestation is written to `XL1_ATTEST_ARCHIVE` **before** the
caller is answered. The compose file mounts `/var/lib/xl1-attestations` on the
host for it. Anything in there can be posted to a store by hand:

```bash
curl -X POST "$BACKEND/api/node/attestation" -H "X-Node-Token: $TOKEN"   -H 'content-type: application/json' -d @/var/lib/xl1-attestations/<hash>.json
```

The archive is insurance, not the normal path — the agent spools and posts on
its own. It exists because this failure has happened twice, and its cost is a
transaction that can never be explained.

### Who is allowed to attest

An attestation proves a payload was anchored and by which address — not that the
address speaks for the producer. Signing with the producer's own key would prove
it, but that means putting the key controlling a block producer into a service
with an HTTP endpoint, which is exactly what this container avoids.

So the producer signs **one** statement instead, binding a throwaway attestation
key to itself. Routine anchoring then uses that key, and a verifier follows
attestation → delegation → producer.

These are run from the image, not the host. The service is containerised, so
the host checkout has no `node_modules` and nothing there can resolve the SDK
imports; the image has both the dependencies and these tools.

First make the attestation key. It is deliberately worth nothing — it anchors
hashes and holds a little gas, controls no producer and no stake, and losing it
means generating another and delegating again:

```bash
mkdir -p /opt/xl1-keys
docker run --rm -v /opt/xl1-keys:/keys xl1-service:local   node_modules/.bin/tsx new-attestor.ts --out /keys/attestor.key
```

It prints the attestation address and writes the phrase to the host, outside
the container, where a rebuild cannot take it with it. If the write fails on
permissions, `chown` that directory to the uid the container runs as.

Send that address a little gas. Then bind it, once, by a person:

```bash
# 1. see exactly what would be anchored, spending nothing
docker run --rm -i xl1-service:local node_modules/.bin/tsx delegate-attestor.ts   --attestor ATTESTATION_ADDRESS --producer PRODUCER_ADDRESS

# 2. anchor it
docker run --rm -i xl1-service:local node_modules/.bin/tsx delegate-attestor.ts   --attestor ATTESTATION_ADDRESS --producer PRODUCER_ADDRESS --anchor
```

`-i` keeps stdin open so the phrase can be piped or typed. It is never passed
as an argument.

The phrase is read from stdin or `XL1_PRODUCER_MNEMONIC`, never from an argument
— anything on a command line is visible in `ps` and lands in shell history. Pass
`--producer` so a wrong phrase is refused rather than anchoring a statement that
binds nothing and costs gas to discover.

Publish the payload it prints, verbatim, alongside the transaction hash. A
verifier has to hash the bytes that were hashed, not a re-serialisation of them.

The attestation key needs a little gas and nothing else; it is worth nothing if
lost, which is the point of it.


> `XYO_WALLET_MNEMONIC` is a wallet seed phrase. If you set it, treat this
> service as holding a key: do not put it on a machine you would not put a
> wallet on. Every read endpoint works without it.
>
> **Setting it also requires `XL1_ANCHOR_TOKEN`.** `/anchor` signs whatever it
> is handed, and it had no authentication at all — a read route giving away
> chain data that is already public is a different proposition from a route
> that will put your wallet's name on anything. With a mnemonic configured and
> no token set, `/anchor` refuses to sign and says so at startup rather than
> quietly accepting requests.

## Running it on the Pi

`docker-compose.pi.yml` runs it alongside the node, bound to loopback so
nothing on your network can reach it:

```bash
docker compose -f docker-compose.pi.yml up -d --build
```

That is the arrangement the heartbeat agent expects — it calls
`http://127.0.0.1:8090/block-height`, `/producer` and `/standing` by default.

**In a container, bind `0.0.0.0` and let the mapping do the containment.**
Docker forwards a published port to the container's bridge address, not to its
loopback, so a service listening on `127.0.0.1` inside the namespace cannot be
reached through `127.0.0.1:8090:8090` at all. The compose file sets
`XL1_SERVICE_HOST=0.0.0.0` for that reason. Nothing is exposed by it: the host
side of the mapping is still loopback-only, which is the interface that decides
what your network can reach.

**`--build` is not optional when updating.** The Dockerfile does `COPY src`, so
the source is baked into the image and there is no bind mount. `docker restart`
and a plain `up -d` both bring the container back on the *old* code, and
nothing says so: the service starts cleanly, answers every request, and serves
the previous build. A pull that appears to have deployed and has not is
indistinguishable from a change that did not work — which has cost time here
more than once.

The build also runs `pnpm run typecheck`, so a type error stops the rebuild
rather than reaching the running service.

## Typechecking

`pnpm start` uses `tsx`, which strips types without checking them — so a type
error only surfaces when the offending line runs. That is how a read-only
gateway once got cast to a transacting one and shipped.

```bash
pnpm run typecheck
```

CI runs this on every push. Run it before you push too.

## Notes on the SDK

Two rules that are easy to get wrong and expensive to debug:

- **Never issue raw JSON-RPC.** Go through `gateway.connection.viewer.*` for
  reads and gateway methods for writes.
- **XL1 is not an EVM chain.** `eth_*` methods and Ethereum SDKs do not apply.
  Shared address derivation is the only thing the two have in common.

Reads use `build()`; anything that transacts needs `buildRunner()` with an
account attached. `/health` deliberately uses the read-only path so it works on
a node with no wallet.
