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
export const BW_SCHEMA = "network.xyo.boundwitness";
export const VERIFIED = ["content-hash", "producer-signature"];
export const HOSTS = { mainnet: "mainnet.xyo.space", sequence: "sequence.xyo.space" };

// ------------------------------------------------------------------ hashing

/** XYO's data hash: SHA-256 of the canonical JSON with the TOP level's `_` and `$` keys left out (measured against the SDK). */
export const dataHash = async (obj) =>
  sha256Hex(canonical(Object.fromEntries(Object.entries(obj).filter(([k]) => !k.startsWith("_") && !k.startsWith("$")))));

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

/** Is this a sound receipt? { ok, why, summary }. Fails closed on anything it does not expect. */
export const checkReceipt = async (bw, payload) => {
  const fail = (why) => ({ ok: false, why });
  if (!bw || typeof bw !== "object" || !payload || typeof payload !== "object") return fail("a receipt is a bound witness and a payload");
  const bwKeys = ["$signatures", "addresses", "payload_hashes", "payload_schemas", "previous_hashes", "schema"];
  const plKeys = ["block", "blockHash", "network", "pet", "schema", "seenAt", "v", "verified"];
  if (!same(Object.keys(bw).sort(), bwKeys)) return fail("the bound witness has fields a receipt does not");
  if (!same(Object.keys(payload).sort(), plKeys)) return fail("the payload has fields a receipt does not");
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
  if (!same(payload.verified, VERIFIED)) return fail("the checks are not the ones a witness makes");
  const prev = bw.previous_hashes[0];
  if (prev !== null && !(typeof prev === "string" && HEX64.test(prev))) return fail("bad previous hash");
  if (bw.payload_hashes[0] !== (await dataHash(payload))) return fail("the payload is not the one signed");
  const sig = bw.$signatures[0];
  if (typeof sig !== "string" || !/^[0-9a-f]{128}$/.test(sig)) return fail("bad signature");
  const receiptHash = await dataHash(bw);
  if (!signedBy(address, receiptHash, sig)) return fail("the signature is not the pet's");
  return {
    ok: true,
    summary: { network: payload.network, block: payload.block, blockHash: payload.blockHash, seenAt: payload.seenAt, pet: payload.pet, address, receiptHash, previous: prev },
  };
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
