/**
 * Self-test for the pet witness verifier, against vectors it did not make.
 *
 *   node test.mjs
 *
 * Needs Node 20 or newer and nothing else. No network: every block here is a saved copy of a real mainnet block
 * from XL1's public files, and every signature and receipt was made by the XYO SDK (Account, BoundWitnessBuilder),
 * not by this code. So a pass means the verifier agrees with the SDK and with the chain, not with itself.
 *
 * If you write your own pet that witnesses, or your own verifier, run it against fixtures/: a receipt your code
 * makes must pass checkReceipt, and your verifier must give these verdicts.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join, dirname } from 'node:path'

import { BATCH_MAX, BATCH_SCHEMA, buildBatchDocument, verifyBatchDocument, batchLeaf, batchRoot, bytesToHex, checkBlock, checkDeed, checkReceipt, dataHash, describeDeed, keccak256, recoverAddresses, signedBy, verifyBatchProof, verifyReceipt } from './witness.js'

const dir = join(dirname(fileURLToPath(import.meta.url)), 'fixtures')
const load = (n) => readFileSync(join(dir, n), 'utf8')
const json = (n) => JSON.parse(load(n))
const clone = (x) => JSON.parse(JSON.stringify(x))

let failures = 0
const test = async (name, fn) => {
  try { await fn(); console.log(`  ok   ${name}`) } catch (e) { failures++; console.error(`  FAIL ${name}\n       ${e.message.split('\n')[0]}`) }
}

console.log('The pet witness verifier, against the SDK and the chain:')

await test('keccak-256 matches the reference at every block boundary', () => {
  const k = (n) => bytesToHex(keccak256(new TextEncoder().encode('a'.repeat(n))))
  assert.equal(bytesToHex(keccak256(new Uint8Array())), 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470')
  assert.equal(k(135), '34367dc248bbd832f4e3e69dfaac2f92638bd0bbd18f2912ba4ef454919cf446')
  assert.equal(k(136), 'a6c4d403279fe3e0af03729caada8374b5ca54d8065329a3ebcaeb4b60aa386e')
})

await test('every SDK signature is attributed to the SDK\'s address, and to no other', () => {
  const vectors = json('vectors.json')
  assert.ok(vectors.length >= 12)
  for (const v of vectors) {
    assert.ok(recoverAddresses(v.hash, v.sig).includes(v.address), v.sig.slice(0, 12))
    assert.equal(signedBy(vectors[0].address === v.address ? vectors[4].address : vectors[0].address, v.hash, v.sig), false)
  }
})

await test('every real mainnet block hashes to the hash the chain states', async () => {
  for (const n of [1, 1000, 500000, 1292166, 1825700]) {
    const bw = JSON.parse(load(`mainnet-${n}.json`))[0]
    assert.equal(await dataHash(bw), bw._dataHash, `block ${n}`)
  }
})

const route = json('route-receipts.json')
const [A0, A1] = route.a.receipts
const B0 = route.b.receipts[0]

await test('receipts the SDK made are sound, and chain to the pet\'s previous one', async () => {
  for (const r of [A0, A1, B0, ...json('sdk-receipts.json').receipts]) assert.equal((await checkReceipt(r.bw, r.payload)).ok, true)
  assert.equal((await checkReceipt(A1.bw, A1.payload)).summary.previous, (await checkReceipt(A0.bw, A0.payload)).summary.receiptHash)
  assert.equal((await checkReceipt(A0.bw, A0.payload)).summary.address, route.a.address)
})

await test('a receipt with anything changed is refused', async () => {
  const cases = [['payload', 'block', 1001], ['payload', 'blockHash', 'ab'.repeat(32)], ['payload', 'seenAt', 1], ['payload', 'pet', 'dragon'],
    ['payload', 'network', 'elsewhere'], ['payload', 'verified', []], ['bw', 'addresses', ['00'.repeat(20)]], ['bw', 'previous_hashes', ['cd'.repeat(32)]]]
  for (const [where, field, value] of cases) {
    const r = clone(A0)
    r[where][field] = value
    assert.equal((await checkReceipt(r.bw, r.payload)).ok, false, `${where}.${field}`)
  }
  const stolen = clone(A0)
  stolen.bw.$signatures = clone(B0.bw.$signatures)
  assert.equal((await checkReceipt(stolen.bw, stolen.payload)).ok, false, 'another pet\'s signature')
})

await test('the block a receipt names passes, and nothing else does', async () => {
  assert.equal((await checkBlock(load('mainnet-1000.json'), 1000, A0.payload.blockHash)).ok, true)
  assert.equal((await checkBlock(load('mainnet-1825700.json'), 1825700, A1.payload.blockHash)).ok, true)
  assert.equal((await checkBlock(load('mainnet-1825700.json'), 1825700, A0.payload.blockHash)).ok, false, 'another block\'s hash')
  assert.equal((await checkBlock(load('mainnet-1000.json'), 1001, A0.payload.blockHash)).ok, false, 'the wrong number')
  const bw = JSON.parse(load('mainnet-1000.json'))[0]
  const flipped = load('mainnet-1000.json').replace(bw.$signatures[0], [...bw.$signatures[0]].reverse().join(''))
  assert.equal((await checkBlock(flipped, 1000, bw._dataHash)).ok, false, 'a changed signature')
})

await test('a proof pack checks offline from the command line, and a changed block fails it', async () => {
  const { spawnSync } = await import('node:child_process')
  const { mkdtempSync, writeFileSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const tmp = mkdtempSync(join(tmpdir(), 'pack-'))
  const run = (pack) => {
    const f = join(tmp, 'pack.json')
    writeFileSync(f, JSON.stringify(pack))
    return spawnSync(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), 'verify.mjs'), f], { encoding: 'utf8' }).status
  }
  const pack = { receipt: { bw: clone(A0.bw), payload: clone(A0.payload) }, block: json('mainnet-1000.json') }
  assert.equal(run(pack), 0, 'a whole pack')
  const bad = clone(pack)
  bad.block[0].$signatures[0] = bad.block[0].$signatures[0].split('').reverse().join('')
  assert.equal(run(bad), 1, 'a changed block')
  assert.equal(run({ ...clone(pack), block: json('mainnet-500000.json') }), 1, 'another block')
})

await test('deeds the SDK made are sound, say what they say, and are not receipts', async () => {
  const deeds = json('deed-receipts.json')
  assert.equal(deeds.receipts.length, 5)
  for (const d of deeds.receipts) {
    const r = await checkDeed(d.bw, d.payload)
    assert.equal(r.ok, true, d.payload.kind)
    assert.equal(r.summary.address, deeds.address)
    assert.equal((await checkReceipt(d.bw, d.payload)).ok, false, 'a deed is not a block receipt')
    const v = await verifyReceipt(d, () => { throw new Error('a deed needs no network') })
    assert.equal(v.ok, true, 'verifyReceipt reads a deed with no network')
  }
  assert.equal(describeDeed((await checkDeed(deeds.receipts[0].bw, deeds.receipts[0].payload)).summary), 'Bought kite for 40 marks.')
  assert.equal((await checkDeed(A0.bw, A0.payload)).ok, false, 'a block receipt is not a deed')
})

await test('a deed with anything changed is refused', async () => {
  const [bought, , gift, , week] = json('deed-receipts.json').receipts
  const cases = [[bought, 'payload', 'price', 1], [bought, 'payload', 'item', 'hoodie'], [bought, 'payload', 'seenAt', 5], [bought, 'payload', 'kind', 'milestone'],
    [gift, 'payload', 'to', 'ab'.repeat(19)], [week, 'payload', 'root', 'zz'], [week, 'payload', 'week', '2026-W54'], [week, 'bw', 'addresses', ['00'.repeat(20)]], [bought, 'bw', 'previous_hashes', ['cd'.repeat(32)]]]
  for (const [d, where, field, value] of cases) {
    const r = clone(d)
    r[where][field] = value
    assert.equal((await checkDeed(r.bw, r.payload)).ok, false, `${where}.${field}`)
  }
  const extra = clone(bought); extra.payload.extra = 'x'
  assert.equal((await checkDeed(extra.bw, extra.payload)).ok, false, 'an extra field')
  const stolen = clone(bought); stolen.bw.$signatures = clone(gift.bw.$signatures)
  assert.equal((await checkDeed(stolen.bw, stolen.payload)).ok, false, 'a different deed signature')
})

await test('a deed checks from the command line with no network, and a changed one fails', async () => {
  const { spawnSync } = await import('node:child_process')
  const { mkdtempSync, writeFileSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const tmp = mkdtempSync(join(tmpdir(), 'deed-'))
  const run = (d) => {
    const f = join(tmp, 'deed.json')
    writeFileSync(f, JSON.stringify(d))
    return spawnSync(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), 'verify.mjs'), f], { encoding: 'utf8' })
  }
  const good = json('deed-receipts.json').receipts[0]
  const ok = run(good)
  assert.equal(ok.status, 0)
  assert.match(ok.stdout, /Bought kite for 40 marks/)
  const bad = clone(good); bad.payload.price = 1
  assert.equal(run(bad).status, 1)
})

await test('sentinel batches: the roots and proofs agree with the vectors made by the server code', async () => {
  const v = json('batch-vectors.json')
  assert.equal(v.cases.length, 9)
  for (const c of v.cases) {
    assert.equal(await batchRoot(c.leaves), c.root)
    for (const [leaf, steps] of Object.entries(c.proofs)) assert.equal(await verifyBatchProof(leaf, steps, c.root), true, leaf)
  }
})

await test('sentinel batches: one receipt is its own leaf, and two are hashed together by hand', async () => {
  const sha = async (b) => new Uint8Array(await globalThis.crypto.subtle.digest('SHA-256', b))
  const a = '11'.repeat(32), b = '22'.repeat(32)
  assert.equal(await batchRoot([a]), bytesToHex(await sha(Uint8Array.from([0, ...Buffer.from(a, 'hex')]))))
  const la = await sha(Uint8Array.from([0, ...Buffer.from(a, 'hex')])), lb = await sha(Uint8Array.from([0, ...Buffer.from(b, 'hex')]))
  assert.equal(await batchRoot([b, a, a]), bytesToHex(await sha(Uint8Array.from([1, ...la, ...lb]))), 'any order, each once')
  assert.notEqual(bytesToHex(await batchLeaf(a)), bytesToHex(await sha(Buffer.from(a, 'hex'))), 'a leaf is not a bare hash')
})

await test('sentinel batches: a proof that has been touched, or is for another receipt or another root, is refused', async () => {
  const c = json('batch-vectors.json').cases[8]
  const [leaf, other] = Object.keys(c.proofs)
  const steps = c.proofs[leaf]
  assert.equal(await verifyBatchProof(leaf, steps, c.root), true)
  assert.equal(await verifyBatchProof(other, steps, c.root), false, "somebody else's proof")
  const flipped = clone(steps); flipped[0].hash = flipped[0].hash.slice(0, -1) + (flipped[0].hash.endsWith('0') ? '1' : '0')
  assert.equal(await verifyBatchProof(leaf, flipped, c.root), false, 'a digit changed')
  const swapped = clone(steps); swapped[0].side = swapped[0].side === 'L' ? 'R' : 'L'
  assert.equal(await verifyBatchProof(leaf, swapped, c.root), false, 'a step on the wrong side')
  assert.equal(await verifyBatchProof(leaf, steps.slice(1), c.root), false, 'a step missing')
  assert.equal(await verifyBatchProof(leaf, steps, json('batch-vectors.json').cases[7].root), false, "another batch's root")
})

await test('sentinel batches: anything that is not a proof is refused and never throws', async () => {
  const c = json('batch-vectors.json').cases[2]
  const leaf = c.leaves[0]
  for (const bad of [null, 'x', 5, {}, [null], [{}], [{ side: 'X', hash: leaf }], [{ side: 'L', hash: 'zz' }], [{ side: 'L' }], Array(100).fill({ side: 'L', hash: leaf })]) {
    assert.equal(await verifyBatchProof(leaf, bad, c.root), false)
  }
  assert.equal(await verifyBatchProof('nope', [], c.root), false)
  assert.equal(await verifyBatchProof(leaf, [], 'nope'), false)
  await assert.rejects(() => batchRoot([]))
  await assert.rejects(() => batchLeaf(leaf.toUpperCase()))
})

// ---------------------------------------------------------------------------------------------- the pet ledger: a day's batch, whole

const ledger = json('batch-document.json').documents
const routeFixture = json('route-receipts.json')
const allReceipts = [...routeFixture.a.receipts, ...routeFixture.b.receipts]

await test('a batch document: both parts of the fixture verify, against the hash the chain would have committed', async () => {
  for (const { document, hash } of ledger) {
    const r = await verifyBatchDocument(document, { expectedHash: hash })
    assert.equal(r.ok, true, r.why)
    assert.equal(r.summary.hash, hash)
    assert.equal(r.summary.count, document.receipts.length)
  }
  assert.equal(ledger[1].document.previous, ledger[0].hash, 'part 2 names part 1')
  assert.equal(ledger[0].document.previous, null)
})

await test('a batch document: built the same whatever order the receipts come in, in order of their hash, each once', async () => {
  const forward = await buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: allReceipts })
  const backward = await buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: [...allReceipts].reverse() })
  assert.equal(await dataHash(forward), await dataHash(backward))
  await assert.rejects(() => buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: [allReceipts[0], allReceipts[0]] }), /twice/)
  await assert.rejects(() => buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: [] }), /at least one/)
  await assert.rejects(() => buildBatchDocument({ network: 'nowhere', day: '2026-10-20', receipts: allReceipts }), /network/)
  await assert.rejects(() => buildBatchDocument({ network: 'mainnet', day: '20 Oct', receipts: allReceipts }), /day/)
  await assert.rejects(() => buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: Array(BATCH_MAX + 1).fill(allReceipts[0]) }), /at most/)
})

await test('a batch document: any change to it is refused, by name', async () => {
  const { document, hash } = ledger[0]
  const refused = async (mutate, why) => {
    const d = clone(document); mutate(d)
    const r = await verifyBatchDocument(d)
    assert.equal(r.ok, false, `should be refused: ${why}`)
    return r.why
  }
  await refused((d) => { d.receipts[0].payload.block += 1 }, 'a receipt altered')
  await refused((d) => { d.receipts[0].bw.$signatures[0] = '0'.repeat(128) }, 'a signature replaced')
  await refused((d) => { d.receipts.pop() }, 'a receipt removed (count and root no longer agree)')
  await refused((d) => { d.receipts.reverse() }, 'receipts out of order')
  await refused((d) => { d.receipts.push(clone(d.receipts[0])) }, 'a receipt twice')
  await refused((d) => { d.root = 'ab'.repeat(32) }, 'a root that is not theirs')
  await refused((d) => { d.count = 9 }, 'a count that is not the number')
  await refused((d) => { d.day = '2026-13-01' }, 'a day that is not a day')
  await refused((d) => { d.network = 'sequence' }, 'receipts for another network')
  await refused((d) => { d.extra = 1 }, 'a field a batch does not have')
  await refused((d) => { delete d.final }, 'a field missing')
  await refused((d) => { d.previous = 'zz' }, 'a previous that is not a hash')
  await refused((d) => { d.v = 2 }, 'a version it does not know')
  await refused((d) => { d.schema = 'com.example.other' }, 'another schema')
  await refused((d) => { d.receipts[0].extra = 1 }, 'a receipt with a field it should not have')
  for (const bad of [null, 'x', 5, [], {}]) assert.equal((await verifyBatchDocument(bad)).ok, false)
  // the same document, but not the one the chain committed: refused though every receipt in it is fine
  const other = clone(document); other.part = 3
  const r = await verifyBatchDocument(other, { expectedHash: hash })
  assert.equal(r.ok, false)
  assert.match(r.why, /not the one the chain committed/)
})

await test('a batch document: a change to the document moves its hash, so the chain\'s commitment pins every byte', async () => {
  const { document, hash } = ledger[0]
  assert.equal(await dataHash(document), hash)
  const moved = clone(document); moved.final = !moved.final
  assert.notEqual(await dataHash(moved), hash)
  const sig = clone(document); sig.receipts[0].bw.$signatures[0] = sig.receipts[0].bw.$signatures[0].replace(/.$/, (c) => (c === '0' ? '1' : '0'))
  assert.notEqual(await dataHash(sig), hash, 'a nested signature is inside the hash too')
  assert.equal(BATCH_SCHEMA, 'com.jimtheexplorer.pet.batch')
})

if (failures) {
  console.error(`\n${failures} check(s) failed.`)
  process.exit(1)
}
console.log('\nThe verifier agrees with the SDK and the chain.')
