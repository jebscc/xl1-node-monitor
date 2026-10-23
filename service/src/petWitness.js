/** Checking a pet's witness receipt, in the reader's own browser or on their own command line, with nothing taken on trust.
 *
 * A receipt is a signed statement that a pet looked at a block of the XL1 chain, recomputed its hash from the
 * block's own content, and checked that the block's signature comes from the address it lists (the format is in
 * witness/SPEC.md in the public repo). This file is the reader's side: it re-does every one of those checks
 * here, reading the block from XL1's own public files, so a page arguing that a pet witnessed something does
 * not have to be believed about it.
 *
 * No dependencies beyond the browser's hashing: no XYO SDK, no crypto library. That is deliberate and it is
 * the same reasoning as lib/attestation.js -- you need neither their code nor ours to check the claim. The
 * price is that the curve arithmetic is written out here, so it is held to the SDK's own output byte for byte
 * (witness.test.js uses signatures and bound witnesses the SDK made, and real mainnet blocks), and
 * xl1-service runs the same file against the SDK in CI (test-witness-oracle.mjs).
 *
 * Not constant-time (BigInt), which is fine: this only ever VERIFIES. There is no private key anywhere in it.
 */
// The two helpers this needs, written out here rather than imported, so this file stands alone: the site, the
// command-line verifier and the tests all load exactly this file, and nothing else has to come with it.
/** Canonical JSON: sorted keys at every level, no whitespace. What PayloadBuilder.hash serialises before hashing. */
const canonical = (v) => {
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
};

const sha256Hex = async (text) => {
  const buf = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
};

export const SCHEMA = "com.jimtheexplorer.pet.witness";
export const DEED_SCHEMA = "com.jimtheexplorer.pet.deed";
export const BW_SCHEMA = "network.xyo.boundwitness";
export const VERIFIED = ["content-hash", "producer-signature"];
/** What a CO-WITNESS receipt lists: the same two checks, and that the pet also checked another pet's receipt for the same block. */
export const COVERIFIED = ["content-hash", "producer-signature", "peer-receipt"];
export const HOSTS = { mainnet: "mainnet.xyo.space", sequence: "sequence.xyo.space" };

// ------------------------------------------------------------------ hashing

/** XYO's data hash: SHA-256 of the canonical JSON with the TOP level's `_` and `$` keys left out (measured against the SDK). */
export const dataHash = async (obj) =>
  sha256Hex(canonical(Object.fromEntries(Object.entries(obj).filter(([k]) => !k.startsWith("_") && !k.startsWith("$")))));

/** XYO's full hash, the one a transaction is listed by in a block: the same, but with the top level's `$` keys (the signatures) KEPT. */
export const fullHash = async (obj) =>
  sha256Hex(canonical(Object.fromEntries(Object.entries(obj).filter(([k]) => !k.startsWith("_")))));

// ------------------------------------------------------------------ keccak-256 (the original padding, not NIST SHA-3's)

const M64 = (1n << 64n) - 1n;
const RC = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
];
const ROT = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44];
const PI = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1];
const rotl = (x, n) => ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64;

const permute = (a) => {
  const c = new Array(5);
  for (let round = 0; round < 24; round++) {
    for (let x = 0; x < 5; x++) c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
    for (let x = 0; x < 5; x++) {
      const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) a[y + x] ^= d;
    }
    let t = a[1];
    for (let i = 0; i < 24; i++) {
      const j = PI[i];
      const b = a[j];
      a[j] = rotl(t, ROT[i]);
      t = b;
    }
    for (let y = 0; y < 25; y += 5) {
      for (let x = 0; x < 5; x++) c[x] = a[y + x];
      for (let x = 0; x < 5; x++) a[y + x] = c[x] ^ ((~c[(x + 1) % 5] & M64) & c[(x + 2) % 5]);
    }
    a[0] ^= RC[round];
  }
};

/** Keccak-256 of bytes, as a Uint8Array of 32. */
export const keccak256 = (input) => {
  const rate = 136;
  const padded = new Uint8Array((Math.floor(input.length / rate) + 1) * rate);
  padded.set(input);
  padded[input.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const state = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      state[i] ^= lane;
    }
    permute(state);
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 4; i++) for (let b = 0; b < 8; b++) out[i * 8 + b] = Number((state[i] >> BigInt(8 * b)) & 0xffn);
  return out;
};

// ------------------------------------------------------------------ secp256k1: recover who signed

const P = 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2fn;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const GX = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n;
const GY = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n;

const mod = (a, m = P) => ((a % m) + m) % m;
const pow = (b, e, m) => {
  let r = 1n;
  let x = mod(b, m);
  for (let k = e; k > 0n; k >>= 1n) {
    if (k & 1n) r = (r * x) % m;
    x = (x * x) % m;
  }
  return r;
};
// extended Euclid: a modular inverse in a few hundred steps, where exponentiation would take hundreds of thousands
const inv = (a, m = P) => {
  let [r0, r1] = [m, mod(a, m)];
  let [t0, t1] = [0n, 1n];
  while (r1 !== 0n) {
    const q = r0 / r1;
    [r0, r1] = [r1, r0 - q * r1];
    [t0, t1] = [t1, t0 - q * t1];
  }
  return mod(t0, m);
};

// affine points; null is infinity
const add = (a, b) => {
  if (!a) return b;
  if (!b) return a;
  let lam;
  if (a.x === b.x) {
    if (mod(a.y + b.y) === 0n) return null;
    lam = mod(3n * a.x * a.x * inv(2n * a.y));
  } else {
    lam = mod((b.y - a.y) * inv(b.x - a.x));
  }
  const x = mod(lam * lam - a.x - b.x);
  return { x, y: mod(lam * (a.x - x) - a.y) };
};
const mul = (k, p) => {
  let r = null;
  let q = p;
  for (let e = k; e > 0n; e >>= 1n) {
    if (e & 1n) r = add(r, q);
    q = add(q, q);
  }
  return r;
};
const G = { x: GX, y: GY };

export const hexToBytes = (hex) => {
  if (typeof hex !== "string" || hex.length % 2 || /[^0-9a-f]/i.test(hex)) throw new Error("not hex");
  return Uint8Array.from(hex.match(/../g) ?? [], (b) => parseInt(b, 16));
};
export const bytesToHex = (b) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
const big = (hex) => BigInt(`0x${hex || "0"}`);
const h32 = (v) => v.toString(16).padStart(64, "0");

/** The addresses a 64-byte signature over a 32-byte hash could have come from (two, one per curve parity). */
export const recoverAddresses = (hashHex, sigHex) => {
  if (!/^[0-9a-f]{64}$/i.test(hashHex) || !/^[0-9a-f]{128}$/i.test(sigHex)) return [];
  const r = big(sigHex.slice(0, 64));
  const s = big(sigHex.slice(64));
  if (r <= 0n || r >= N || s <= 0n || s >= N) return [];
  const ySq = mod(r ** 3n + 7n);
  const y0 = pow(ySq, (P + 1n) / 4n, P);
  if (mod(y0 * y0) !== ySq) return [];
  const z = big(hashHex);
  const rInv = inv(r, N);
  const out = [];
  for (const parity of [0n, 1n]) {
    const y = (y0 & 1n) === parity ? y0 : P - y0;
    const sR = mul(s, { x: r, y });
    const zG = mul(mod(z, N), G);
    const q = mul(rInv, add(sR, zG && { x: zG.x, y: mod(-zG.y) }));
    if (q) out.push(bytesToHex(keccak256(hexToBytes(h32(q.x) + h32(q.y)))).slice(24));
  }
  return out;
};

/** Did the holder of [address] sign [hashHex]? */
export const signedBy = (address, hashHex, sigHex) =>
  typeof address === "string" && recoverAddresses(hashHex, sigHex).includes(address.toLowerCase());

// ------------------------------------------------------------------ the receipt

const HEX64 = /^[0-9a-f]{64}$/;
const HEX40 = /^[0-9a-f]{40}$/;
const isInt = (v) => Number.isSafeInteger(v);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/** The fields every receipt has. A receipt may carry one set of extras (below) and nothing else. */
const PL_KEYS = ["block", "blockHash", "network", "pet", "schema", "seenAt", "v", "verified"];
/**
 * The four kinds of receipt, by the fields they add to PL_KEYS:
 *   plain      none: one pet looked at a block
 *   cowitness  of, peer: a second pet checked another pet's receipt for the same block
 *   call       day, low, high, middle: the Diviner's call of the day's blocks, signed against the newest block when it was made
 *   result     of, day, low, high, actual, outcome: how that call turned out, naming the call by its hash
 *   status     mood, stage, level, days, bond, tricks, rank, field, blocks, hats, items, marks: how a pet is, as numbers and words from fixed lists
 * Every kind is still a receipt for a block (the block it was signed against), so a batch, a bundle and a ledger hold any of them the same way.
 */
const EXTRAS = {
  cowitness: ["of", "peer"],
  call: ["day", "high", "low", "middle"],
  result: ["actual", "day", "high", "low", "of", "outcome"],
  status: ["blocks", "bond", "days", "field", "hats", "items", "level", "marks", "mood", "rank", "stage", "tricks"],
};
export const MOODS = ["happy", "neutral", "worried", "sad", "unknown"];
/** The age stages and the days witnessed each begins at (the app's PetGrowth.Stage). A status's stage must be the one its days make. */
export const STAGES = [["hatchling", 0], ["young", 7], ["grown", 30], ["veteran", 100], ["elder", 300]];
export const stageOfDays = (days) => STAGES.filter(([, from]) => days >= from).pop()[0];
const STATUS_MAX = { days: 100000, bond: 4, tricks: 20, rank: 100000, field: 100000, blocks: 1000000, hats: 1000, items: 1000, marks: 10000000 };
const receiptKind = (payload) => {
  const extra = Object.keys(payload).filter((k) => !PL_KEYS.includes(k)).sort();
  if (!extra.length) return "plain";
  // a status may also carry `watch`, a commitment to the producer its pet watches (see watchCommitment); no other kind may
  const bare = extra.filter((k) => k !== "watch");
  if (bare.length !== extra.length) return same(bare, EXTRAS.status) ? "status" : null;
  return Object.keys(EXTRAS).find((k) => same(extra, EXTRAS[k])) ?? null;
};
const FORECAST_DAY = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;
const FORECAST_MAX = 10_000_000;
/** What a forecast came to: below its range, above it, or inside. */
export const forecastOutcome = (actual, low, high) => (actual < low ? "below" : actual > high ? "above" : "inside");

/**
 * The commitment a status can carry to the producer its pet watches: sha256 of "pet-watch:v1|<salt>|<producer address, lower case>". The salt is a random
 * secret the owner's phone keeps; without it the commitment says nothing about which producer, and with it (and the address) the owner can prove it.
 */
export const watchCommitment = (salt, producer) => sha256Hex(`pet-watch:v1|${String(salt)}|${String(producer).toLowerCase()}`);
/** Does this salt and producer open this commitment? Only the owner, who holds the salt, can show it. */
export const checkWatch = async (commitment, salt, producer) =>
  typeof commitment === "string" && HEX64.test(commitment) && typeof salt === "string" && salt.length >= 16 && (await watchCommitment(salt, producer)) === commitment;

/** Is this a sound receipt? { ok, why, summary }. Fails closed on anything it does not expect. */
export const checkReceipt = async (bw, payload) => {
  const fail = (why) => ({ ok: false, why });
  if (!bw || typeof bw !== "object" || !payload || typeof payload !== "object") return fail("a receipt is a bound witness and a payload");
  const bwKeys = ["$signatures", "addresses", "payload_hashes", "payload_schemas", "previous_hashes", "schema"];
  const kind = receiptKind(payload);
  if (!same(Object.keys(bw).sort(), bwKeys)) return fail("the bound witness has fields a receipt does not");
  if (!kind) return fail("the payload has fields a receipt does not");
  if (bw.schema !== BW_SCHEMA) return fail("not a bound witness");
  for (const f of ["addresses", "payload_hashes", "payload_schemas", "previous_hashes", "$signatures"]) {
    if (!Array.isArray(bw[f]) || bw[f].length !== 1) return fail("one pet, one payload");
  }
  const [address] = bw.addresses;
  if (typeof address !== "string" || !HEX40.test(address)) return fail("bad address");
  if (bw.payload_schemas[0] !== SCHEMA || payload.schema !== SCHEMA) return fail("not a pet witness");
  if (payload.v !== 1) return fail("unknown version");
  if (!HOSTS[payload.network]) return fail("unknown network");
  if (!isInt(payload.block) || payload.block < 0) return fail("no block");
  if (typeof payload.blockHash !== "string" || !HEX64.test(payload.blockHash)) return fail("bad block hash");
  if (!isInt(payload.seenAt) || payload.seenAt <= 0) return fail("no time");
  if (typeof payload.pet !== "string" || !/^[a-z0-9]{1,16}$/.test(payload.pet)) return fail("bad pet");
  if (!same(payload.verified, kind === "cowitness" ? COVERIFIED : VERIFIED)) return fail("the checks are not the ones a witness makes");
  const count = (v) => isInt(v) && v >= 0 && v <= FORECAST_MAX;
  if (kind === "cowitness") {
    if (typeof payload.of !== "string" || !HEX64.test(payload.of)) return fail("bad receipt checked");
    if (typeof payload.peer !== "string" || !HEX40.test(payload.peer)) return fail("bad peer");
    if (payload.peer === address) return fail("a pet cannot co-witness its own receipt");
  }
  if (kind === "call" || kind === "result") {
    if (typeof payload.day !== "string" || !FORECAST_DAY.test(payload.day)) return fail("bad day");
    if (!count(payload.low) || !count(payload.high) || payload.low > payload.high) return fail("bad range");
  }
  if (kind === "status") {
    if (!MOODS.includes(payload.mood)) return fail("bad mood");
    if (!isInt(payload.level) || payload.level < 1 || payload.level > 30) return fail("bad level");
    for (const [k, max] of Object.entries(STATUS_MAX)) if (!isInt(payload[k]) || payload[k] < 0 || payload[k] > max) return fail(`bad ${k}`);
    if (payload.stage !== stageOfDays(payload.days)) return fail("the stage is not the one those days make");
    if (payload.rank > 0 && payload.field < payload.rank) return fail("a rank cannot be below the last place");
    if ("watch" in payload && !(typeof payload.watch === "string" && HEX64.test(payload.watch))) return fail("bad watch");
  }
  if (kind === "call") {
    if (!count(payload.middle) || payload.middle < payload.low || payload.middle > payload.high) return fail("the middle is outside the range");
  }
  if (kind === "result") {
    if (typeof payload.of !== "string" || !HEX64.test(payload.of)) return fail("bad call");
    if (!count(payload.actual)) return fail("bad result");
    if (payload.outcome !== forecastOutcome(payload.actual, payload.low, payload.high)) return fail("the outcome is not what the range and the result say");
  }
  const prev = bw.previous_hashes[0];
  if (prev !== null && !(typeof prev === "string" && HEX64.test(prev))) return fail("bad previous hash");
  if (bw.payload_hashes[0] !== (await dataHash(payload))) return fail("the payload is not the one signed");
  const sig = bw.$signatures[0];
  if (typeof sig !== "string" || !/^[0-9a-f]{128}$/.test(sig)) return fail("bad signature");
  const receiptHash = await dataHash(bw);
  if (!signedBy(address, receiptHash, sig)) return fail("the signature is not the pet's");
  return {
    ok: true,
    summary: { network: payload.network, block: payload.block, blockHash: payload.blockHash, seenAt: payload.seenAt, pet: payload.pet, address, receiptHash, previous: prev,
      ...(kind === "plain" ? {} : { kind, ...Object.fromEntries(EXTRAS[kind].map((k) => [k, payload[k]])) }),
      ...(kind === "status" && "watch" in payload ? { watch: payload.watch } : {}) },
  };
};

/**
 * Does [co] really co-witness [peer]? Both must be sound receipts; [co] must be a co-witness, signed by someone other than the pet whose receipt it
 * checked; it must name exactly that receipt (by hash) and that pet; and it must be about the same block, with the same hash, on the same network.
 * What this shows: a second key looked at the same block and agreed with the first. It does not show the two keys are two people.
 */
export const checkCowitness = async (co, peer) => {
  const fail = (why) => ({ ok: false, why });
  const a = await checkReceipt(co?.bw, co?.payload);
  if (!a.ok) return fail(`the co-witness is not sound: ${a.why}`);
  const b = await checkReceipt(peer?.bw, peer?.payload);
  if (!b.ok) return fail(`the receipt it names is not sound: ${b.why}`);
  if (a.summary.kind !== "cowitness") return fail("that receipt does not co-witness anything");
  if (b.summary.kind) return fail("only an ordinary receipt is co-witnessed");
  if (a.summary.of !== b.summary.receiptHash) return fail("it names a different receipt");
  if (a.summary.peer !== b.summary.address) return fail("it names a different pet");
  if (a.summary.address === b.summary.address) return fail("a pet cannot co-witness its own receipt");
  if (a.summary.network !== b.summary.network || a.summary.block !== b.summary.block || a.summary.blockHash !== b.summary.blockHash) return fail("it is about a different block");
  return { ok: true, summary: { block: a.summary.block, network: a.summary.network, witness: b.summary.address, cowitness: a.summary.address } };
};

// ------------------------------------------------------------------ the deed

const DEED_FIELDS = {
  bought: ["item", "price"],
  milestone: ["stamp", "value"],
  gift: ["item", "to"],
  received: ["item", "from", "gift"],
  week: ["week", "receipts", "blocks", "sealed", "anchored", "root"],
  growth: ["pet", "first", "level", "days", "receipts", "bond"],
  submission: ["receipts", "root"],
};
/** A Sentinel's submission names at most this many receipts: one bundle is one phone's hour or two of work, not a firehose. */
export const SUBMISSION_MAX = 20;
const SLUG = /^[a-z0-9_]{1,40}$/;
const WEEK_ID = /^\d{4}-W(0[1-9]|[1-4]\d|5[0-3])$/;
const COUNT = (v) => isInt(v) && v >= 0;

/** Is this a sound deed? { ok, why, summary }. A deed is signed by the Archivist's key: see SPEC.md. Fails closed. */
export const checkDeed = async (bw, payload) => {
  const fail = (why) => ({ ok: false, why });
  if (!bw || typeof bw !== "object" || !payload || typeof payload !== "object") return fail("a deed is a bound witness and a payload");
  const bwKeys = ["$signatures", "addresses", "payload_hashes", "payload_schemas", "previous_hashes", "schema"];
  if (!same(Object.keys(bw).sort(), bwKeys)) return fail("the bound witness has fields a deed does not");
  if (bw.schema !== BW_SCHEMA) return fail("not a bound witness");
  for (const f of ["addresses", "payload_hashes", "payload_schemas", "previous_hashes", "$signatures"]) {
    if (!Array.isArray(bw[f]) || bw[f].length !== 1) return fail("one signer, one payload");
  }
  const [address] = bw.addresses;
  if (typeof address !== "string" || !HEX40.test(address)) return fail("bad address");
  if (bw.payload_schemas[0] !== DEED_SCHEMA || payload.schema !== DEED_SCHEMA) return fail("not a deed");
  if (payload.v !== 1) return fail("unknown version");
  const fields = DEED_FIELDS[payload.kind];
  if (!fields) return fail("unknown kind of deed");
  if (!same(Object.keys(payload).sort(), ["kind", "schema", "seenAt", "v", ...fields].sort())) return fail(`the fields are not the ones a ${payload.kind} deed has`);
  if (!isInt(payload.seenAt) || payload.seenAt <= 0) return fail("no time");
  const addr = (v) => typeof v === "string" && HEX40.test(v);
  const bad = {
    bought: () => !SLUG.test(payload.item) || !isInt(payload.price) || payload.price < 1,
    milestone: () => !SLUG.test(payload.stamp) || !isInt(payload.value) || payload.value < 1,
    gift: () => !SLUG.test(payload.item) || !addr(payload.to),
    received: () => !SLUG.test(payload.item) || !addr(payload.from) || !(typeof payload.gift === "string" && HEX64.test(payload.gift)),
    week: () => !(typeof payload.week === "string" && WEEK_ID.test(payload.week)) || !["receipts", "blocks", "sealed", "anchored"].every((k) => COUNT(payload[k])) || !(typeof payload.root === "string" && HEX64.test(payload.root)),
    submission: () => !isInt(payload.receipts) || payload.receipts < 1 || payload.receipts > SUBMISSION_MAX || !(typeof payload.root === "string" && HEX64.test(payload.root)),
    growth: () => !addr(payload.pet) || !(typeof payload.first === "string" && DAY.test(payload.first)) || !["level", "days", "receipts", "bond"].every((k) => COUNT(payload[k])) || payload.level > 30 || payload.days < 1,
  }[payload.kind]();
  if (bad) return fail(`bad ${payload.kind} deed`);
  const prev = bw.previous_hashes[0];
  if (prev !== null && !(typeof prev === "string" && HEX64.test(prev))) return fail("bad previous hash");
  if (bw.payload_hashes[0] !== (await dataHash(payload))) return fail("the payload is not the one signed");
  const sig = bw.$signatures[0];
  if (typeof sig !== "string" || !/^[0-9a-f]{128}$/.test(sig)) return fail("bad signature");
  const receiptHash = await dataHash(bw);
  if (!signedBy(address, receiptHash, sig)) return fail("the signature is not the keeper's");
  const { schema, v, ...rest } = payload;
  return { ok: true, summary: { ...rest, address, receiptHash, previous: prev } };
};

const nice = (slug) => String(slug).replace(/_/g, " ");

/**
 * Does [result] really settle [call]? Both sound; one a call and the other a result, by the same pet (the Diviner's key); the result names the call by
 * its hash, for the same day and range; and it was signed at or after the call, against a block no earlier. The result's `actual` is the pet's own count
 * of that day's blocks: this shows the call was made before the day was counted and scored as it says, not that the count is right.
 */
export const checkForecast = async (result, call) => {
  const fail = (why) => ({ ok: false, why });
  const r = await checkReceipt(result?.bw, result?.payload);
  if (!r.ok) return fail(`the result is not sound: ${r.why}`);
  const c = await checkReceipt(call?.bw, call?.payload);
  if (!c.ok) return fail(`the call is not sound: ${c.why}`);
  if (r.summary.kind !== "result") return fail("that receipt is not a result");
  if (c.summary.kind !== "call") return fail("the receipt it names is not a call");
  if (r.summary.of !== c.summary.receiptHash) return fail("it settles a different call");
  if (r.summary.address !== c.summary.address) return fail("a call is settled by the pet that made it");
  if (r.summary.day !== c.summary.day || r.summary.low !== c.summary.low || r.summary.high !== c.summary.high) return fail("it is for another day or another range");
  if (r.summary.network !== c.summary.network || r.summary.block < c.summary.block || r.summary.seenAt < c.summary.seenAt) return fail("it was signed before the call");
  return { ok: true, summary: { day: r.summary.day, low: r.summary.low, high: r.summary.high, actual: r.summary.actual, outcome: r.summary.outcome, pet: r.summary.address } };
};

/**
 * Does the submission deed [deed] really name [receipts]? The deed must be sound and be a `submission`; the receipts must be sound, at most
 * SUBMISSION_MAX of them, each once; and their Merkle root (the sentinel-batch rule, over each receipt's own hash) and count must be the ones the deed
 * signed. What it shows: the key that signed the deed put its name to exactly these receipts. It shows no more about who that key is.
 */
export const checkSubmission = async (deed, receipts) => {
  const fail = (why) => ({ ok: false, why });
  const d = await checkDeed(deed?.bw, deed?.payload);
  if (!d.ok) return fail(`the submission is not sound: ${d.why}`);
  if (d.summary.kind !== "submission") return fail("that deed is not a submission");
  if (!Array.isArray(receipts) || receipts.length < 1 || receipts.length > SUBMISSION_MAX) return fail("a submission names between one and " + SUBMISSION_MAX + " receipts");
  const hashes = [];
  for (const r of receipts) {
    const c = await checkReceipt(r?.bw, r?.payload);
    if (!c.ok) return fail(`a receipt in it is not sound: ${c.why}`);
    hashes.push(c.summary.receiptHash);
  }
  if (new Set(hashes).size !== hashes.length) return fail("the same receipt twice");
  if (d.summary.receipts !== hashes.length) return fail("the count is not the number of receipts");
  if (d.summary.root !== (await batchRoot(hashes))) return fail("the root is not the root of those receipts");
  return { ok: true, summary: { submitter: d.summary.address, receipts: hashes.length, root: d.summary.root } };
};

/** A deed as one plain sentence, saying only what it says. */
export const describeDeed = (d) => {
  switch (d.kind) {
    case "bought": return `Bought ${nice(d.item)} for ${d.price} marks.`;
    case "milestone": return `Reached the stamp "${nice(d.stamp)}" with ${d.value}.`;
    case "gift": return `Gave ${nice(d.item)} to the pet at ${d.to}.`;
    case "received": return `Received ${nice(d.item)} from the pet at ${d.from}, in answer to the gift ${d.gift}.`;
    case "week": return `Week ${d.week}: ${d.receipts} receipt${d.receipts === 1 ? "" : "s"} for ${d.blocks} block${d.blocks === 1 ? "" : "s"}, ${d.sealed} day${d.sealed === 1 ? "" : "s"} sealed, ${d.anchored} on the chain. Its fingerprint is ${d.root}.`;
    case "submission": return `The Sentinel at ${d.address} submitted ${d.receipts} receipt${d.receipts === 1 ? "" : "s"}, under the root ${d.root}.`;
    case "growth": return `The pet at ${d.pet} reached level ${d.level}: ${d.days} day${d.days === 1 ? "" : "s"} witnessed since ${d.first}, ${d.receipts} receipt${d.receipts === 1 ? "" : "s"}, ${d.bond} bond point${d.bond === 1 ? "" : "s"}. The keeper's own count.`;
    default: return "A deed.";
  }
};

// ------------------------------------------------------------------ the block it names

/** Is [text] block [number], hashing to [expectedHash], signed by each address it lists? { ok, why, signers }. */
export const checkBlock = async (text, number, expectedHash) => {
  const fail = (why) => ({ ok: false, why });
  let parsed;
  try { parsed = JSON.parse(text); } catch { return fail("not readable"); }
  const bw = Array.isArray(parsed) ? parsed.find((x) => x && x.schema === BW_SCHEMA) : parsed;
  if (!bw || bw.schema !== BW_SCHEMA) return fail("no bound witness in it");
  if (bw.block !== number) return fail(`that is not block ${number}`);
  const { addresses, $signatures: sigs } = bw;
  if (!Array.isArray(addresses) || !Array.isArray(sigs) || !addresses.length || addresses.length !== sigs.length) return fail("addresses and signatures do not pair up");
  const hash = await dataHash(bw);
  if (hash !== expectedHash) return fail("its hash is not the one the receipt names");
  if (typeof bw._dataHash === "string" && bw._dataHash.toLowerCase() !== hash) return fail("the hash does not match the content");
  for (let i = 0; i < addresses.length; i++) {
    if (typeof sigs[i] !== "string") return fail("a signature is missing");
    if (!signedBy(addresses[i], hash, sigs[i])) return fail("a signature is not from the address beside it");
  }
  return { ok: true, signers: addresses };
};

export const blockUrl = (network, number) => (HOSTS[network] ? `https://blocks.${HOSTS[network]}/block/number/${number}.json` : null);

/** Reads a block from XL1's own public files. [fetchFn] is injectable for tests. */
export const readBlock = async (network, number, fetchFn = fetch) => {
  const url = blockUrl(network, number);
  if (!url) return { state: "missing" };
  try {
    const r = await fetchFn(url);
    if (r.status === 404 || r.status === 403) return { state: "missing" };
    if (!r.ok) return { state: "unavailable" };
    return { state: "ok", text: await r.text() };
  } catch {
    return { state: "unavailable" };
  }
};

/**
 * Every check, one at a time, for showing the reader. Each step says what was checked, whether it held, and --
 * for the ones that cannot be run -- that they could not be, which is NOT the same as failing.
 *
 * Returns { steps: [{id, label, status: "pass"|"fail"|"skipped"|"unavailable", detail}], ok }, where ok is true
 * only if every step passed.
 */
export const verifyReceipt = async (receipt, fetchFn = fetch) => {
  const steps = [];
  const push = (id, label, status, detail) => steps.push({ id, label, status, detail });
  if (receipt?.payload?.schema === DEED_SCHEMA) {
    // a deed names no block, so there is nothing to read from the chain: the one check is its signature, and it needs no network
    const d = await checkDeed(receipt.bw, receipt.payload);
    push("deed", "The deed is sound and the keeper's signature is the keeper's", d.ok ? "pass" : "fail", d.ok ? `Signed by ${d.summary.address}.` : d.why);
    return d.ok ? { steps, ok: true, deed: d.summary } : { steps, ok: false };
  }
  const r = await checkReceipt(receipt?.bw, receipt?.payload);
  if (!r.ok) {
    push("receipt", "The receipt is sound and the pet's signature is the pet's", "fail", r.why);
    return { steps, ok: false };
  }
  push("receipt", "The receipt is sound and the pet's signature is the pet's", "pass", `Signed by ${r.summary.address}.`);
  const { network, block, blockHash } = r.summary;
  const got = await readBlock(network, block, fetchFn);
  if (got.state === "unavailable") {
    push("read", "The block is read from XL1's own public files", "unavailable", "They could not be reached just now, so the block could not be checked. That is not a failure of the receipt.");
    return { steps, ok: false, summary: r.summary };
  }
  if (got.state === "missing") {
    push("read", "The block is read from XL1's own public files", "fail", `There is no block ${block} on ${network}.`);
    return { steps, ok: false, summary: r.summary };
  }
  push("read", "The block is read from XL1's own public files", "pass", `Block ${block} on ${network}.`);
  const b = await checkBlock(got.text, block, blockHash);
  push("block", "The block's hash, recomputed from its own content, is the one the receipt names, and its signature is from the address it lists", b.ok ? "pass" : "fail", b.ok ? `Hash ${blockHash}.` : b.why);
  return { steps, ok: b.ok, summary: r.summary, signers: b.signers };
};

/* ------------------------------------------------------------------------------------------------ sentinel batches */
/*
 * Pets with no account of their own send their receipts to one server, which folds a day's receipt hashes into a
 * Merkle root that a crew node writes on the chain. A pet can then check, with no part of that server, that its receipt
 * is under the root. The rules (witness/SPEC.md, "Sentinel batches"):
 *
 *   leaf  = SHA-256(0x00 || receiptHash)         receiptHash is 64 hex characters (32 bytes)
 *   node  = SHA-256(0x01 || left || right)
 *   tree  = the sorted, de-duplicated leaves, paired left to right level by level; an odd one out is carried up
 *   proof = [{ side: "L" | "R", hash }, ...] from the leaf up: the sibling, and which side it stands on
 */
const sha256Bytes = async (bytes) => new Uint8Array(await globalThis.crypto.subtle.digest("SHA-256", bytes));
const concatBytes = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
};

/** The leaf for one receipt hash. Throws for anything that is not 64 lower-case hex characters. */
export const batchLeaf = async (receiptHash) => {
  if (typeof receiptHash !== "string" || !HEX64.test(receiptHash)) throw new Error("a receipt hash is 64 lower-case hex characters");
  return sha256Bytes(concatBytes(Uint8Array.of(0), hexToBytes(receiptHash)));
};

const batchNode = async (left, right) => sha256Bytes(concatBytes(Uint8Array.of(1), left, right));

/** The Merkle root (64 hex) of a set of receipt hashes: sorted, each once. Throws if there are none or one is malformed. */
export const batchRoot = async (receiptHashes) => {
  const sorted = [...new Set(receiptHashes)].sort();
  if (!sorted.length) throw new Error("no receipts, no batch");
  let level = await Promise.all(sorted.map(batchLeaf));
  while (level.length > 1) {
    const next = [];
    for (let i = 0; i < level.length; i += 2) next.push(i + 1 < level.length ? await batchNode(level[i], level[i + 1]) : level[i]);
    level = next;
  }
  return bytesToHex(level[0]);
};

/** Whether [receiptHash] is under [rootHex] by way of [steps]. False for anything malformed; never throws. */
export const verifyBatchProof = async (receiptHash, steps, rootHex) => {
  try {
    if (!Array.isArray(steps) || steps.length > 64 || typeof rootHex !== "string" || !HEX64.test(rootHex)) return false;
    let h = await batchLeaf(receiptHash);
    for (const s of steps) {
      if (!s || (s.side !== "L" && s.side !== "R") || typeof s.hash !== "string" || !HEX64.test(s.hash)) return false;
      const sib = hexToBytes(s.hash);
      h = s.side === "L" ? await batchNode(sib, h) : await batchNode(h, sib);
    }
    return bytesToHex(h) === rootHex;
  } catch {
    return false;
  }
};

// ------------------------------------------------------------------ the pet ledger: a day's batch

/*
 * THE BATCH. A day's receipts as XL1's own structure: each receipt is filed to the data layer as a payload of its own, and ONE small
 * manifest lists those payloads by hash. The chain commits the manifest's hash; from it a reader fetches every receipt by hash and
 * checks every signature themselves, so there is no proof to be handed and nothing to take on a server's word.
 *
 * Measured against the mainnet data layer on 2026-10-21, and why it is built this way: it refuses a single payload that holds an array
 * of payload-like objects (so the receipts are not nested in the manifest), and it drops the top-level `$signatures` of a bound witness
 * filed on its own (so a receipt cannot be filed as the bare bound witness, which would lose the pet's signature). It keeps an object-valued
 * field exactly, nested signatures and all, so a receipt is filed as a payload that WRAPS its bound witness and its witness payload:
 * the signature is inside the bytes the address is the hash of, and a changed byte anywhere changes the address.
 *
 * The rules are in SPEC.md ("The pet ledger on XL1"). This is the only code that decides what a valid batch is, besides the service that writes them.
 */
export const BATCH_SCHEMA = "com.jimtheexplorer.pet.batch";
export const RECEIPT_SCHEMA = "com.jimtheexplorer.pet.receipt";
/** The most receipts one manifest lists. A bigger day is more parts, each naming the one before. */
export const BATCH_MAX = 1000;
const DAY = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;
const BATCH_KEYS = ["count", "day", "final", "network", "part", "previous", "receipts", "root", "schema", "v"];
const FILED_KEYS = ["bw", "payload", "schema", "v"];

/** A payload as the data layer returns it, without the `_`-prefixed fields it adds (`_hash`, `_dataHash`, `_sequence`): those are the layer's, not the payload's. */
export const stripMeta = (payload) =>
  payload && typeof payload === "object" && !Array.isArray(payload) ? Object.fromEntries(Object.entries(payload).filter(([k]) => !k.startsWith("_"))) : payload;

/** A receipt as it is filed: the payload that wraps its bound witness and its witness payload. */
export const filedReceipt = ({ bw, payload }) => ({ schema: RECEIPT_SCHEMA, v: 1, bw, payload });

/**
 * One part of a day, built to the rules. Returns { document, payloads }: the manifest (the filed receipts listed by data hash, in
 * ascending order, each once; the Merkle root of the receipt hashes; the count) and every payload to be filed beside it, by its hash.
 * Throws if the rules cannot be met.
 */
export const buildBatchDocument = async ({ network, day, part = 1, final = true, previous = null, receipts }) => {
  if (!HOSTS[network]) throw new Error("unknown network");
  if (!DAY.test(day)) throw new Error("a day is YYYY-MM-DD");
  if (!Array.isArray(receipts) || receipts.length === 0) throw new Error("a batch holds at least one receipt");
  if (receipts.length > BATCH_MAX) throw new Error(`a batch holds at most ${BATCH_MAX} receipts; make another part`);
  const keyed = await Promise.all(receipts.map(async (r) => {
    const filed = filedReceipt(r);
    return { filed, h: await dataHash(filed), receiptHash: await dataHash(r.bw) };
  }));
  keyed.sort((a, b) => (a.h < b.h ? -1 : a.h > b.h ? 1 : 0));
  for (let i = 1; i < keyed.length; i += 1) if (keyed[i].h === keyed[i - 1].h) throw new Error("the same receipt twice");
  if (new Set(keyed.map((k) => k.receiptHash)).size !== keyed.length) throw new Error("the same receipt twice");
  const payloads = {};
  for (const k of keyed) payloads[k.h] = k.filed;
  return {
    document: {
      schema: BATCH_SCHEMA, v: 1, network, day, part, final, previous,
      root: await batchRoot(keyed.map((k) => k.receiptHash)), count: keyed.length, receipts: keyed.map((k) => k.h),
    },
    payloads,
  };
};

/**
 * Is this a sound batch? { ok, why, summary }. [document] is the manifest; [fetchPayload(hash)] fetches a payload from the data layer
 * (or from a saved copy) and answers null for one it does not have; [expectedHash] is the hash the chain's transaction committed, and
 * when given the manifest must hash to it. Every payload fetched is checked against the hash it was asked for, so a data layer cannot
 * hand back something else, and every receipt inside is checked as it would be on its own. The whole batch is refused at the first failure.
 */
export const verifyBatchDocument = async (document, fetchPayload, { expectedHash } = {}) => {
  const fail = (why) => ({ ok: false, why });
  const getPayload = async (h) => stripMeta(await fetchPayload(h));
  const doc = stripMeta(document);
  if (!doc || typeof doc !== "object" || Array.isArray(doc)) return fail("a batch is an object");
  if (!same(Object.keys(doc).sort(), BATCH_KEYS)) return fail("the batch has fields a batch does not, or lacks one");
  if (doc.schema !== BATCH_SCHEMA) return fail("not a pet batch");
  if (doc.v !== 1) return fail("unknown version");
  if (!HOSTS[doc.network]) return fail("unknown network");
  if (typeof doc.day !== "string" || !DAY.test(doc.day)) return fail("bad day");
  if (!isInt(doc.part) || doc.part < 1) return fail("bad part");
  if (typeof doc.final !== "boolean") return fail("bad final");
  if (doc.previous !== null && !(typeof doc.previous === "string" && HEX64.test(doc.previous))) return fail("bad previous");
  if (typeof doc.root !== "string" || !HEX64.test(doc.root)) return fail("bad root");
  if (!Array.isArray(doc.receipts) || !doc.receipts.length) return fail("a batch lists at least one receipt");
  if (doc.receipts.length > BATCH_MAX) return fail("too many receipts for one batch");
  if (doc.count !== doc.receipts.length) return fail("the count is not the number of receipts");
  for (const h of doc.receipts) if (typeof h !== "string" || !HEX64.test(h)) return fail("a receipt is listed by its 64-character hash");
  for (let i = 1; i < doc.receipts.length; i += 1) {
    if (doc.receipts[i] === doc.receipts[i - 1]) return fail("the same receipt twice");
    if (doc.receipts[i] < doc.receipts[i - 1]) return fail("the receipts are not in order of their hash");
  }
  const hash = await dataHash(doc);
  if (expectedHash !== undefined && hash !== expectedHash) return fail("the manifest is not the one the chain committed");
  const receiptHashes = [];
  for (const h of doc.receipts) {
    const filed = await getPayload(h);
    if (!filed) return fail(`a receipt is missing from the data layer (${h.slice(0, 12)}…)`);
    if (typeof filed !== "object" || Array.isArray(filed) || (await dataHash(filed)) !== h) return fail("the data layer returned something else than the receipt asked for");
    if (!same(Object.keys(filed).sort(), FILED_KEYS) || filed.schema !== RECEIPT_SCHEMA || filed.v !== 1) return fail("a filed receipt is a pet receipt wrapping a bound witness and a payload");
    const checked = await checkReceipt(filed.bw, filed.payload);
    if (!checked.ok) return fail(`a receipt does not check out: ${checked.why}`);
    if (checked.summary.network !== doc.network) return fail("a receipt is for another network than the batch");
    receiptHashes.push(checked.summary.receiptHash);
  }
  if (new Set(receiptHashes).size !== receiptHashes.length) return fail("the same receipt twice");
  if ((await batchRoot(receiptHashes)) !== doc.root) return fail("the root is not the root of these receipts");
  return { ok: true, summary: { hash, network: doc.network, day: doc.day, part: doc.part, final: doc.final, previous: doc.previous, root: doc.root, count: doc.count, receiptHashes } };
};

/**
 * READING A DAY OF THE LEDGER BACK FROM THE CHAIN.
 *
 * The anchor is one transaction: a bound witness, signed by the node's anchor wallet, that lists two payloads -- a hash payload naming the
 * id payload, and the id payload whose `salt` is the record (`{app, v, network, producer, period, digest}`). The digest is the manifest's
 * hash (app `xl1-pet-ledger`) or, for the first day, which was written before manifests existed, the Merkle root (app `xl1-pet-batch`).
 * A block of the chain lists the transaction by its hash, and that block is signed by its producer.
 *
 * [fetchPayload(hash)] reads a payload from the data layer (null if it has none); [fetchBlock(number)] answers the text of a block's static
 * file (null if there is none). Both are injectable, so the same code runs in a browser, on a command line, and against saved copies.
 * Like the rest of this file it only VERIFIES. What it cannot show is that the block is the one the network finalised: it shows the block is
 * signed by the address it names and lists this transaction, which is the same standing a receipt's block has.
 */
export const LEDGER_APPS = { "xl1-pet-ledger": "manifest", "xl1-pet-batch": "root" };

export const readAnchor = async (txHash, fetchPayload, fetchBlock) => {
  const fail = (why) => ({ ok: false, why });
  if (typeof txHash !== "string" || !HEX64.test(txHash)) return fail("a transaction is named by its 64-character hash");
  const tx = stripMeta(await fetchPayload(txHash));
  if (!tx || typeof tx !== "object" || tx.schema !== BW_SCHEMA) return fail("the data layer has no such transaction");
  if ((await fullHash(tx)) !== txHash) return fail("the data layer returned something else than the transaction asked for");
  const signed = await dataHash(tx);
  const { addresses, $signatures: sigs } = tx;
  if (!Array.isArray(addresses) || !Array.isArray(sigs) || !addresses.length || addresses.length !== sigs.length) return fail("the transaction's addresses and signatures do not pair up");
  for (let i = 0; i < addresses.length; i += 1) {
    if (typeof sigs[i] !== "string" || !signedBy(addresses[i], signed, sigs[i])) return fail("the transaction is not signed by the address it names");
  }
  const ids = [];
  const listed = Array.isArray(tx.payload_hashes) ? tx.payload_hashes : [];
  for (let i = 0; i < listed.length; i += 1) {
    if (tx.payload_schemas?.[i] !== "network.xyo.id") continue;
    const p = stripMeta(await fetchPayload(listed[i]));
    if (!p || (await dataHash(p)) !== listed[i]) return fail("the data layer returned something else than the record asked for");
    ids.push(p);
  }
  if (ids.length !== 1) return fail("the transaction carries one record");
  let record;
  try { record = JSON.parse(ids[0].salt); } catch { return fail("the record is not readable"); }
  if (!record || typeof record !== "object" || !LEDGER_APPS[record.app] || record.v !== 1) return fail("not a pet ledger record");
  if (!HOSTS[record.network] || !DAY.test(record.period) || !HEX64.test(record.digest)) return fail("the record is malformed");
  const lo = tx.nbf, hi = tx.exp;
  if (!isInt(lo) || !isInt(hi) || hi < lo || hi - lo > 1000) return fail("the transaction has no usable window");
  for (let n = lo; n <= hi + 1; n += 1) {
    const text = await fetchBlock(n);
    if (!text) continue;
    let parsed;
    try { parsed = JSON.parse(text); } catch { continue; }
    const bw = Array.isArray(parsed) ? parsed.find((x) => x && x.schema === BW_SCHEMA) : parsed;
    if (!bw || bw.block !== n || !(bw.payload_hashes || []).includes(txHash)) continue;
    const seen = await checkBlock(text, n, await dataHash(bw));
    if (!seen.ok) return fail(`the block that lists it does not check out: ${seen.why}`);
    return { ok: true, txHash, signer: addresses[0], block: n, blockSigners: seen.signers, record, kind: LEDGER_APPS[record.app] };
  }
  return fail("no block in its window lists it (yet)");
};

/**
 * A whole day: the anchor, then -- for a manifest -- the manifest read back from the data layer by the hash the chain committed, and every
 * receipt in it checked. A root-only day is reported as such: its receipts are not on the data layer, so only the anchor can be shown.
 */
export const verifyLedgerDay = async (txHash, fetchPayload, fetchBlock) => {
  const anchor = await readAnchor(txHash, fetchPayload, fetchBlock);
  if (!anchor.ok) return anchor;
  if (anchor.kind === "root") return { ...anchor, batch: null };
  const manifest = await fetchPayload(anchor.record.digest);
  if (!manifest) return { ok: false, why: "the manifest the chain committed is not on the data layer", anchor };
  const batch = await verifyBatchDocument(manifest, fetchPayload, { expectedHash: anchor.record.digest });
  if (!batch.ok) return { ok: false, why: batch.why, anchor };
  if (batch.summary.day !== anchor.record.period || batch.summary.network !== anchor.record.network) return { ok: false, why: "the manifest is for another day or network than the record says", anchor };
  return { ...anchor, batch: batch.summary };
};

/**
 * Walks the ledger back from a manifest, by the `previous` each one names, and says what it found: { ok, chain, complete, why }.
 * [chain] is newest first, each { digest, day, part, final }. [complete] is true only when the walk reached a manifest that names nothing
 * before it -- the start. A manifest that is named but not on the data layer is a GAP, and the walk stops there saying so (`why`, `gapAt`):
 * a missing day, or a data layer that lost one. Each manifest is checked against the hash that named it, so none can be swapped, and the
 * order is checked: a part follows the part before it of the same day, and a day's first part follows an earlier day's (whose last part
 * need not be marked final: a day written in windows can end on a part written before the day ended). Receipts are not
 * re-checked here (verifyBatchDocument does that, for one manifest); this is the shape of the whole ledger.
 */
export const walkLedger = async (digest, fetchPayload, { limit = 400 } = {}) => {
  const chain = [];
  let want = digest;
  let later = null;
  for (let i = 0; i < limit && want; i += 1) {
    if (typeof want !== "string" || !HEX64.test(want)) return { ok: false, chain, complete: false, why: "a manifest is named by its 64-character hash" };
    const got = stripMeta(await fetchPayload(want));
    if (!got) return { ok: true, chain, complete: false, gapAt: want, why: later ? `the manifest for the day before ${later.day} is not on the data layer` : "the newest manifest is not on the data layer" };
    if (!got || got.schema !== BATCH_SCHEMA || (await dataHash(got)) !== want) return { ok: false, chain, complete: false, why: "the data layer returned something else than the manifest asked for" };
    if (!DAY.test(got.day) || !isInt(got.part) || typeof got.final !== "boolean") return { ok: false, chain, complete: false, why: "a manifest in the chain is malformed" };
    if (later) {
      const sameDay = got.day === later.day;
      if (sameDay && !(later.part === got.part + 1 && got.final === false)) return { ok: false, chain, complete: false, why: `the parts of ${got.day} do not follow one another` };
      if (!sameDay && !(got.day < later.day && later.part === 1)) return { ok: false, chain, complete: false, why: `${later.day} does not follow ${got.day}` };
    }
    chain.push({ digest: want, day: got.day, part: got.part, final: got.final });
    later = got;
    want = got.previous;
  }
  return { ok: true, chain, complete: !want, ...(want ? { why: "stopped at the limit" } : {}) };
};
