# Pet witness receipts, version 1

A **pet witness receipt** is a signed statement that something looked at a block of the
[XL1](https://xyo.network/layer-one/) chain, checked it for itself, and says so. It is made by the *Blockwright*
phone app's pets, but nothing about it is specific to that app: it is a standard XYO bound witness with one
payload, and this document is everything needed to make one, or to check one without trusting anybody.

This directory is the whole of it:

| File | What it is |
|---|---|
| `SPEC.md` | this format |
| `witness.js` | a verifier with **no dependencies**: its own hashing, Keccak-256 and secp256k1 recovery |
| `verify.mjs` | a command-line checker built on it |
| `verify-day.mjs` | reads a day of the pet ledger back from XL1 by its transaction hash (`node verify-day.mjs <hash>`), or from a saved copy |
| `test.mjs` | a self-test against the vectors below |
| `fixtures/` | vectors made by the XYO SDK, and real mainnet blocks |

```
node verify.mjs receipt.json        # reads the block from XL1's public files and checks everything
node test.mjs                       # no network; checks the verifier against the SDK's own output
```

## What a receipt says, and only this

> This pet, at this time by its own clock, read block **N** on this network, recomputed the block's hash from its
> own content and found it equals **blockHash**, and checked that the block's signature comes from the address
> that signed it.

A receipt is **never made for a block that failed either check**, and its `verified` field lists the checks that
were made. It does not name who produced the block: the chain already says, and a receipt that named a producer
would be publishing something the receipt's maker has no business labelling.

### What it does not say

* **Who the pet is.** A pet's key is free to make. Two receipts from one key show one key made them, not a person.
* **When.** `seenAt` is the pet's own clock, an unattested claim. Servers that count receipts accept only a loose
  window around their own time; that is a courtesy, not a proof.
* **That the block is final or canonical.** A signed block from a fork, or from a bucket that has not caught up,
  would pass. Ask the chain's head for that.

## Shape

A receipt is a JSON object with two members, `bw` and `payload`:

```json
{
  "bw": {
    "schema": "network.xyo.boundwitness",
    "addresses": ["19e7e376e7c213b7e7e7e46cc70a5dd086daff2a"],
    "payload_hashes": ["9fcd6b6d6922c2837d96a302cef0f9f0ed47700f38fbb3bcfcb5d2a3db754df2"],
    "payload_schemas": ["com.jimtheexplorer.pet.witness"],
    "previous_hashes": [null],
    "$signatures": ["6477596faec25452fce27c9463fa166ce3bb6cf137d70d9db6ac400b2cb6c2e132b778b446962d284eeee14c94a4bcaef2fa1ea8558d69842bf48ef51bd41c15"]
  },
  "payload": {
    "schema": "com.jimtheexplorer.pet.witness",
    "v": 1,
    "network": "mainnet",
    "block": 1825700,
    "blockHash": "<64 lower-case hex>",
    "seenAt": 1792333874,
    "pet": "cat",
    "verified": ["content-hash", "producer-signature"]
  }
}
```

The payload has **exactly** these fields and no others; a verifier refuses extras, because receipts are stored and
served to the public.

| Field | Meaning |
|---|---|
| `schema` | `com.jimtheexplorer.pet.witness`. Never `network.xyo.*`: that namespace belongs to the XYO Foundation. |
| `v` | the integer `1` |
| `network` | `mainnet` or `sequence` |
| `block` | the block number, a non-negative integer |
| `blockHash` | the block's data hash, recomputed by the pet (see **Hashing**), 64 lower-case hex |
| `seenAt` | seconds since the Unix epoch, by the pet's clock |
| `pet` | 1 to 16 characters of `[a-z0-9]`: the kind of pet (`cat`, `slime`, `sentinel`, ...) |
| `verified` | exactly `["content-hash", "producer-signature"]` |

The bound witness has exactly one address, one payload hash, one payload schema, one previous hash and one
signature, and exactly the six fields shown.

## Hashing

XYO's data hash is **SHA-256 of the canonical JSON** of an object:

* keys sorted (by UTF-16 code unit) **at every level**;
* no whitespace;
* strings escaped as `JSON.stringify` does;
* **at the top level only**, every key beginning with `_` or `$` is left out. (The XYO SDK strips no deeper:
  `fixtures/` and the self-test pin a payload with nested `_` and `$` keys.)

`payload_hashes[0]` is the data hash of `payload`. The receipt's own hash is the data hash of `bw`, which
leaves out `$signatures`; it is what the signature is over and what the pet's next receipt names.

## Signing

* secp256k1, over the **32 raw bytes of a data hash** (not hashed again).
* The signature is 64 bytes, `r` then `s`, lower-case hex, with `s` in the lower half of the range. It is
  deterministic (RFC 6979, HMAC-SHA256). `fixtures/vectors.json` holds twelve SDK signatures for different keys.
* An **address** is the last 20 bytes of Keccak-256 of the 64-byte public key (x then y, no prefix), lower-case
  hex, no `0x`. This is the *original* Keccak padding, not NIST SHA-3's: they give different answers, and an
  address built with the wrong one matches nothing.
* A 64-byte signature carries no public key and no recovery id, so **who signed is worked out, not read**: both
  curve points the signature allows are recovered, and the address that was expected must be one of the two.

## Chaining

`previous_hashes[0]` is the receipt hash of the **same pet's** previous receipt, or `null` for its first. A
missing or reordered receipt shows. This is the standard per-signer chain of XYO bound witnesses; the SDK does
it for you (`Account` remembers its last hash).

## Checking a receipt

Every step is independent of the pet and of whoever served the receipt:

1. The receipt has the shape above and nothing else.
2. `payload_hashes[0]` equals the data hash of `payload`.
3. The signature recovers to `addresses[0]` over the data hash of `bw`.
4. Read block `block` from XL1's public files (below).
5. The block's data hash, **recomputed from its own content**, equals `blockHash`, and equals the block's own
   `_dataHash` where it states one.
6. For each address the block lists, the signature beside it recovers to that address over the block's data hash.

Steps 1 to 3 need no network. A verifier that cannot reach the chain's files has **not failed the receipt**: it
reports that the block could not be checked, which is a different answer.

### Reading a block

XL1's public static files, as the XL1 SDK's REST reader uses them:

```
https://blocks.<host>/block/number/<N>.json        a block: [boundWitness, payloads]
https://state.<host>/chain/head.json               the current head
```

where `<host>` is `mainnet.xyo.space` or `sequence.xyo.space`. The `blocks.` host serves recent blocks by number
but its own `chain/head.json` lags by months, so the head is read from `state.`. The files allow any origin, so a
browser can read them directly.

## A month of receipts, on the chain

Optionally, the Blockwright app lists a month's receipts as one line and has the operator's own node anchor its
hash:

```
yyyy-MM|<count>|<receipt hash>,<receipt hash>,...        hashes ascending, no repeats
```

The sha256 of that line (UTF-8, exactly as written) is written on chain by the operator's wallet as an
`network.xyo.id` payload whose `salt` is the JSON text of:

```json
{"app": "xl1-pet-witness", "v": 1, "network": "mainnet", "producer": "<node address>", "month": "2026-09", "digest": "<sha256>"}
```

Anyone holding the receipts can rebuild the line, hash it, and see it match the anchored digest: the whole
month's witnessing, committed when it closed. It covers the receipts the phone still held at that moment, and the
count is in the line, so a month is never presented as more than it was.

### By the day (v2)

The app now anchors witnessing by the **day**, the phone's own calendar day a receipt was made on, rather than the
month. The line is the same shape with a day in front, and the record carries `period` in place of `month`:

```
yyyy-MM-dd|<count>|<receipt hash>,<receipt hash>,...
{"app": "xl1-pet-witness", "v": 2, "network": "mainnet", "producer": "<node address>", "period": "2026-10-18", "digest": "<sha256>"}
```

Records with `"v": 1` and a `month` are still valid and are checked as above. A day is written only once it has
ended, and covers the receipts the phone held at that moment.

## Counting receipts (not part of the format)

A site may collect receipts and count them per block. The one at <https://www.jimtheexplorer.com/witness> does so
by **distinct account, not by key**, because a key costs nothing to make and an account does not, and it
re-verifies every receipt (steps 1 to 6) before counting it. Its numbers are counts of receipts that can each be
checked; they measure nothing else.

## Deeds: what a pet owns and has done

A second schema, `com.jimtheexplorer.pet.deed`, uses the same bound witness, hashing and signing as a receipt.
A deed is signed by a pet's **Archivist** key, a key that holds nothing, and says one of five things. `seenAt` is
the phone's own clock, as in a receipt. The payload carries exactly `schema`, `v` (1), `kind`, `seenAt` and the
fields of its kind; a verifier refuses a payload with any other field.

| kind        | fields                                                          | says |
|-------------|-----------------------------------------------------------------|------|
| `bought`    | `item` (slug), `price` (integer, at least 1)                    | the item was bought for that many marks |
| `milestone` | `stamp` (slug), `value` (integer, at least 1)                   | a stamp was reached with that much of what it measures |
| `gift`      | `item`, `to` (40 hex: the receiving Archivist's address)        | the item is given to that address |
| `received`  | `item`, `from` (40 hex), `gift` (64 hex: the hash of the gift)  | the item was taken, in answer to that gift |
| `week`      | `week` (`YYYY-Www`), `receipts`, `blocks`, `sealed`, `anchored` (integers, 0 or more), `root` (64 hex) | what the pets did that ISO week |

`root` is the sha256 of one line, `YYYY-Www|count|hash,hash,...`: the hashes of that week's receipts (the
hash of each receipt's bound witness), once each, sorted, as the day's seal is made. Anyone holding
the week's receipts can rebuild it.

A deed needs no network to check: it names no block. `checkDeed` in `witness.js` and `node verify.mjs deed.json`
check the shape, the payload hash and the signature. `fixtures/deed-receipts.json` holds one of each kind, made
by the XYO SDK.

**What a deed does not say.** It proves a holder of the Archivist key signed the statement. It does not prove an
item is rare or valuable, that a giver no longer has what they gave (a phone can be made to forget), that two keys
are two people, or when. Ownership here is a record, not a market.

### The deed ledger: a week of deeds on the chain, if the operator turns it on

A deed's own `root` (in a `week` deed) fingerprints the week's witness receipts, which the daily witness anchor already
covers. What goes on the chain for deeds is separate: a **deed ledger**, the hashes of the deeds themselves. When an ISO
week has ended, the phone seals the hash of every deed made in it (as the phone's own calendar sees the week), sorted,
once each, as one line:

    2026-W42|3|<deed hash>,<deed hash>,<deed hash>

and queues the sha256 of that line, named by the week's last day (the Sunday, `2026-10-18`). It is off unless the person
turns it on. The person's own node writes it on the chain with its own wallet, under the app name `xl1-pet-deed`:

    { "app": "xl1-pet-deed", "v": 1, "network": "...", "producer": "0x...", "period": "2026-10-18", "digest": "<sha256 of the line>" }

Anyone holding the deeds can rebuild the line from their hashes, hash it, and compare. A match shows that those deeds
existed by the time of the anchor and were not rewritten afterwards. That is all it shows: it does not make an item rare
or valuable, it does not show that a giver gave up what they gave, and it covers only the deeds the phone still held
when it sealed the week. The same period can also carry a daily witness anchor (`xl1-pet-witness`); the two are
different records under different app names and never stand in for each other.

## Sentinel batches: many pets, one fingerprint a day

A pet whose owner runs no node and has no account (a **sentinel**) still signs its receipts. It sends them to one
server, which keeps them, and once a UTC day has ended folds the hashes of that day's receipts into a single Merkle root.
One of the crew's nodes writes the root on the chain with its own wallet. The cost is one small anchor a day however many
pets there were, and no phone ever holds a wallet or a key that can spend.

**The tree.** Take the day's receipt hashes (each 64 lower-case hex characters, the `hash` of the receipt's bound
witness), sort them, drop repeats, and build:

    leaf = SHA-256( 0x00 || receipt hash, as 32 bytes )
    node = SHA-256( 0x01 || left || right )

Pair neighbours left to right at each level. An odd one out at a level is carried up unchanged (it is not paired with
itself). The single value left is the **root**. The two prefix bytes keep a leaf from ever being read as a node.

**A proof** that a receipt is in a batch is the list of siblings met on the way up, bottom to top, each marked with the side
it stands on:

    [ { "side": "L", "hash": "..." }, { "side": "R", "hash": "..." }, ... ]

Start from the receipt's leaf; at each step hash `sibling || current` if the side is `"L"`, else `current || sibling`; the
result after the last step must equal the root. A batch of one has an empty proof. `witness.js` has `batchRoot`,
`batchLeaf` and `verifyBatchProof`, and `fixtures/batch-vectors.json` has batches of one to nine receipts with every proof,
made by the server's own code and checked against hand-computed hashes and by the JavaScript here and the phone's Kotlin.

**On the chain.** The node records, as it does for a diary month or a week of deeds:

    { "app": "xl1-pet-batch", "v": 1, "network": "...", "producer": "0x...", "period": "2026-10-19", "digest": "<the root>" }

`period` is the UTC day the batch covers (the day the server RECEIVED each receipt, not the day its pet saw the block).
A day is only batched once it has been over for five minutes, so a receipt sent just after midnight belongs to the next
day, and a day is closed once and never reopened.

**What it shows.** A root on the chain, and a proof that a receipt is under it, shows the receipt existed by the time of
the anchor and was not made up afterwards. The receipt itself is still just a pet's signed statement about a block, and the
block is checked against XL1's own files when it arrives.

**What the server keeps.** Until a day's batch is on XL1 in full (see "The pet ledger on XL1" below), the server's copy of the
receipts is the only one, so it is kept and never deleted. A day's root and the receipt hashes it was built from are kept too,
and every proof is made from them.

**What it does not show.** That the server kept EVERY receipt it was sent: a receipt left out has no proof, its pet would see
that, and nothing else would. That a batch contains only honest pets: anyone can make a pet key, so a count of receipts is
a count of keys and nothing about people. And it says nothing about which pets are the same person.

## The pet ledger on XL1

A root on the chain, and a proof under it, shows a receipt existed. It still asks a reader to be handed the proof, and it leaves the
receipts themselves with a server. The ledger removes both: **every receipt is filed to XL1's data layer as a payload of its own, one small
manifest lists them by hash, and the chain commits the manifest's hash.** Anyone who fetches the manifest by the hash on the chain, and
each receipt by the hash in the manifest, can check every receipt themselves. There is nothing to be handed and nothing to take on trust.

**The filed receipt.** A payload, schema `com.jimtheexplorer.pet.receipt` (our own namespace; `network.xyo.*` is the Foundation's), that wraps
a receipt exactly as the pet made it:

    { "schema": "com.jimtheexplorer.pet.receipt", "v": 1, "bw": { ...the bound witness, with its $signatures... }, "payload": { ...the witness payload... } }

**The manifest.** One payload, schema `com.jimtheexplorer.pet.batch`:

    {
      "schema": "com.jimtheexplorer.pet.batch", "v": 1,
      "network": "mainnet",            // the chain the receipts' blocks are on, and the chain this is written to
      "day": "2026-10-20",             // the UTC day the receipts were received, as the batcher says; the BLOCK's time is what is signed
      "part": 1, "final": true,        // a day is one or more parts (over 1000 receipts, or written in windows); "final" is true on a part written once the day has ended
      "previous": null,                // the data hash of the manifest before this one in the ledger (any day, any part), or null for the first
      "root": "<64 hex>",              // the Merkle root of the receipt hashes (the data hash of each bound witness), by the rules above, so one receipt can still be proved without the rest
      "count": 2,
      "receipts": ["<64 hex>", ...]    // the filed receipts, by data hash, in ascending order, each once
    }

**Parts of a day.** A day may be written in windows while it is still open: each window's receipts are the next part (`part` 2, 3, ...), naming the part
before it, with `final` false. When the day ends, what is left is written as a last part with `final` true; if nothing is left, the last part
written stays `final` false, because nothing can be added to a day once it has ended, and a later day's first part names it all the same. So
`final` is a statement by the writer, not something a reader needs: the order is what is checked (a part follows the part before it, with the
next number, in the same day; a later day's part 1 follows an earlier day's). Each part is one transaction, so a receipt waits at most one window
for the chain.

There is no field for who wrote the manifest: the transaction that carries it names its signer, as XYO's rules say, and each receipt names its pet.

**The hash** is XYO's data hash (canonical JSON, the top level's `_` and `$` keys left out, keys sorted at every depth), for the manifest and for
each filed receipt. A filed receipt keeps the pet's `$signatures` nested inside `bw`, where the hash covers them, so a changed byte anywhere, a
replaced signature included, changes the address. `fixtures/batch-document.json` holds two parts of a day, and `xl1-service/test-batch-document.ts`
has the XYO SDK hash all of it, so the hashes are the SDK's and not this verifier agreeing with itself.

**On the chain.** A crew node's transaction carries the manifest as an off-chain payload: the data layer holds the bytes, the transaction commits
the hash (the default carrier in XYO's chain-data patterns). The block's signed time is "existed by".

**Why a receipt is filed wrapped.** Measured against the mainnet data layer (2026-10-21, `xl1-service/scripts/probe-datalake-insert.ts`):
it **refuses** a single payload that holds an array of payload-like objects, however small, so receipts are not nested in the manifest; and it
**drops** the top-level `$signatures` of a bound witness filed on its own, so a receipt cannot be filed as the bare bound witness without losing
the pet's signature. It keeps an object-valued field exactly, nested signatures and all, which is what the wrapper uses. It accepted payloads of
100 KB and 1 MB. The data layer returns each payload with `_hash`, `_dataHash` and `_sequence` added; those are the layer's and are left out
(`stripMeta`) before anything is checked. Its runner can also delete and clear: it is a store, not the record. The chain commits the hash; a
copy elsewhere is what keeps the bytes available.

**A verifier** with the manifest, the hash the chain committed, and a way to fetch a payload by hash (`verifyBatchDocument(manifest, fetchPayload,
{ expectedHash })` in `witness.js`) checks, and refuses the whole batch at the first failure:

1. The manifest has exactly these fields, a known version and network, a real day, a count that is the number listed (at most 1000), and the receipts listed in order, each once, by 64-character hash.
2. The manifest's data hash is the hash the chain committed.
3. Each listed receipt is fetched, and what comes back hashes to the address it was fetched by: a data layer cannot hand back something else.
4. Each is a filed receipt (exactly the four fields, the right schema and version), and passes the receipt checks on its own: a pet's signature over its own statement, for the manifest's network.
5. No receipt appears twice, and the root is the root of these receipts' hashes.

And, reading the ledger from the chain: `previous` must name a manifest the ledger already wrote, so a missing day shows as a break in the chain,
and only finalized blocks are read.

**What it shows.** Every receipt in a day was signed by its pet, and the whole day existed, unaltered, by the block that committed it. A receipt
cannot be altered after the fact, or one added or removed, without an address changing.

**What it does not show.** That the batcher included every receipt it was sent: a receipt left out before batching is in no manifest. A pet's
phone can tell (it keeps its own signed copy, and the proof it asked for does not come), and says so, but no design with a batcher can prevent it.
It does not make a pet a person, and it does not make a block's contents true: each receipt says what a pet saw, and a reader checks the block
against XL1's own files.

### Reading a day back from the chain

Nothing here has to be taken from a server. Given the hash of the anchoring transaction (the only thing anyone needs to be told):

1. Read the transaction from the data layer (`get/<hash>`). Its **full hash** (the canonical JSON with only the `_` keys left out, so the
   `$signatures` stay in) must equal the hash asked for, and each address must have signed its **data hash** (`$` keys left out as well).
2. The transaction lists one `network.xyo.id` payload; read it, check its data hash, and parse its `salt` as the record
   `{app, v, network, producer, period, digest}`. `app` is `xl1-pet-ledger` (the digest is a manifest's hash) or, for the first day, written
   before manifests existed, `xl1-pet-batch` (the digest is the Merkle root, and the day's receipts are not on the data layer).
3. A block lists the transaction in its `payload_hashes`, and lies in the transaction's `nbf`..`exp` window. Read the blocks of the window
   from XL1's block files and check the one that lists it as any block is checked (see "Reading a block").
4. For a manifest: read it by the digest, verify it against that digest, and check every receipt in it as above.

`witness.js` does all four (`readAnchor`, `verifyLedgerDay`), with the fetching injected, and `fixtures/anchor-mainnet.json` is the first real
day as XL1 served it. `walkLedger` then follows `previous` back from a manifest, checking each against the hash that named it and the order
of days and parts, and reports a manifest that is named but missing as a gap (a missing day, or a data layer that lost one). What step 3 does not show is that the block is the one the network finalised, only that it is signed by the address it
names; that is the same standing a receipt's block has.

## Making your own pet

Build the payload with `PayloadBuilder`, the bound witness with `BoundWitnessBuilder().signer(account).payload(p)`,
and check your output with `node verify.mjs`. Use your own `com.<your-org>.*` schema if you change the payload; do
not reuse this one for a different meaning. The reference phone implementation (Kotlin, with its own secp256k1)
is tested byte for byte against the SDK's output using the same `fixtures/`.

## Versions

`v` is `1`. A change to what the fields mean, or to the set of fields, is a new `v`; a verifier refuses a `v` it
does not know rather than guessing.

## Linking pets into an account

A pet can prove it belongs with other pets by signing a challenge with its own key, the key that signs its receipts. The XL1 Wallet can sign nothing but a transaction, so a wallet is never the proof; the pets' keys are.

1. `POST /api/pets/link/nonce {pet}` answers `{nonce, domain, schema}`. The nonce is the server's, is spent on first use, and expires in ten minutes.
2. The pet builds a bound witness (`BoundWitnessBuilder`, signed by its key) over one payload: `{schema: "com.jimtheexplorer.pet.link", v: 1, domain, nonce}`.
3. `POST /api/pets/link {pet, nonce, bw, payloads: [payload]}` makes an account (the answer carries `account_id` and a `token`, shown once) or, with `account_id` and `token`, adds the pet to one. A pet is on one account; the first to prove it keeps it.
4. `GET /api/pets/account/<account_id>` is public: the proven pets, an optional wallet shown as *named, not proved*, and the pets' recent receipts as pointers (as `/api/sentinel/today`), each with the part of the ledger that holds it and that part's transaction once it is written.

A token that was lost is replaced the same way it was earned: a pet already on the account proves itself again with `recover: true` and no token, and the answer carries a new token (the old one stops working). `POST /api/pets/unlink {account_id, token, pet}` takes a pet off. `GET /api/pets/lookup?pet=<address>` answers the account a pet is on, or 404.

A new phone has new pets with new keys, so it cannot prove itself to an account its pets were never on. For that, making an account also returns a one-time `recovery_code` (twenty Crockford base32 characters, shown in four groups; only its hash is kept). `POST /api/pets/link {pet, nonce, bw, payloads, recovery_code}` joins the proving pet to the account that code belongs to, and replaces the account's token. `POST /api/pets/recovery {account_id, token}` makes a fresh code and retires the old one. The code only manages which pets are on the account; it signs nothing, and it cannot give anyone the old pets' keys.

`fixtures/link-proofs.json` holds two proofs made by the SDK over throwaway keys, which the server's tests check against.
