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
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { writeFileSync } from 'node:fs'

import { walkLedger, readAnchor, verifyLedgerDay, BATCH_MAX, BATCH_SCHEMA, RECEIPT_SCHEMA, buildBatchDocument, filedReceipt, stripMeta, verifyBatchDocument, batchLeaf, batchRoot, bytesToHex, checkBlock, checkDeed, checkReceipt, dataHash, describeDeed, keccak256, recoverAddresses, signedBy, verifyBatchProof, verifyReceipt } from './witness.js'

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

// ---------------------------------------------------------------------------------------------- the pet ledger: a day's batch

const ledger = json('batch-document.json')
const served = (map) => async (h) => map[h] ?? null          // a data layer, as a saved copy
const fromFixture = served(ledger.payloads)
const routeFixture = json('route-receipts.json')
const allReceipts = [...routeFixture.a.receipts, ...routeFixture.b.receipts]

await test('a batch: both parts of the fixture verify, against the hash the chain would have committed', async () => {
  for (const { document, hash } of ledger.documents) {
    const r = await verifyBatchDocument(document, fromFixture, { expectedHash: hash })
    assert.equal(r.ok, true, r.why)
    assert.equal(r.summary.hash, hash)
    assert.equal(r.summary.count, document.receipts.length)
  }
  assert.equal(ledger.documents[1].document.previous, ledger.documents[0].hash, 'part 2 names part 1')
  assert.equal(ledger.documents[0].document.previous, null)
})

await test('a batch: built the same whatever order the receipts come in, listed in order of their hash, each once, with a payload to file for each', async () => {
  const forward = await buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: allReceipts })
  const backward = await buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: [...allReceipts].reverse() })
  assert.equal(await dataHash(forward.document), await dataHash(backward.document))
  assert.equal(Object.keys(forward.payloads).length, allReceipts.length, 'one filed receipt for each')
  for (const p of Object.values(forward.payloads)) assert.equal(p.schema, RECEIPT_SCHEMA)
  assert.equal((await verifyBatchDocument(forward.document, served(forward.payloads))).ok, true)
  await assert.rejects(() => buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: [allReceipts[0], allReceipts[0]] }), /twice/)
  await assert.rejects(() => buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: [] }), /at least one/)
  await assert.rejects(() => buildBatchDocument({ network: 'nowhere', day: '2026-10-20', receipts: allReceipts }), /network/)
  await assert.rejects(() => buildBatchDocument({ network: 'mainnet', day: '20 Oct', receipts: allReceipts }), /day/)
  await assert.rejects(() => buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: Array(BATCH_MAX + 1).fill(allReceipts[0]) }), /at most/)
})

await test('a batch: payloads as a data layer returns them, with its own _hash fields, verify the same', async () => {
  const withMeta = async (h) => {
    const p = ledger.payloads[h]
    return p ? { ...p, _hash: h, _dataHash: h, _sequence: '000001a15be927c0000000016fb1733a' } : null
  }
  for (const { document, hash } of ledger.documents) {
    const r = await verifyBatchDocument({ ...document, _hash: hash }, withMeta, { expectedHash: hash })
    assert.equal(r.ok, true, r.why)
  }
  assert.deepEqual(stripMeta({ a: 1, _b: 2, $c: 3 }), { a: 1, $c: 3 })
  assert.equal(stripMeta(null), null)
})

await test('a batch: any change to the manifest is refused, by name', async () => {
  const { document, hash } = ledger.documents[0]
  const refused = async (mutate, why) => {
    const d = clone(document); mutate(d)
    const r = await verifyBatchDocument(d, fromFixture)
    assert.equal(r.ok, false, `should be refused: ${why}`)
  }
  await refused((d) => { d.receipts.pop() }, 'a receipt removed (count and root no longer agree)')
  await refused((d) => { d.receipts.reverse() }, 'receipts out of order')
  await refused((d) => { d.receipts.push(d.receipts[0]) }, 'a receipt twice')
  await refused((d) => { d.receipts[0] = 'ab'.repeat(32) }, 'a receipt that is not theirs')
  await refused((d) => { d.receipts[0] = 'zz' }, 'a receipt that is not a hash')
  await refused((d) => { d.root = 'ab'.repeat(32) }, 'a root that is not theirs')
  await refused((d) => { d.count = 9 }, 'a count that is not the number')
  await refused((d) => { d.day = '2026-13-01' }, 'a day that is not a day')
  await refused((d) => { d.network = 'sequence' }, 'receipts for another network')
  await refused((d) => { d.extra = 1 }, 'a field a batch does not have')
  await refused((d) => { delete d.final }, 'a field missing')
  await refused((d) => { d.previous = 'zz' }, 'a previous that is not a hash')
  await refused((d) => { d.v = 2 }, 'a version it does not know')
  await refused((d) => { d.schema = 'com.example.other' }, 'another schema')
  for (const bad of [null, 'x', 5, [], {}]) assert.equal((await verifyBatchDocument(bad, fromFixture)).ok, false)
  const other = clone(document); other.part = 3
  const r = await verifyBatchDocument(other, fromFixture, { expectedHash: hash })
  assert.equal(r.ok, false)
  assert.match(r.why, /not the one the chain committed/)
})

await test('a batch: a data layer that is missing a receipt, hands back another, or one with a byte changed, is refused', async () => {
  const { document } = ledger.documents[0]
  const [first, second] = document.receipts
  const layer = (swap) => async (h) => (h in swap ? swap[h] : ledger.payloads[h] ?? null)
  assert.match((await verifyBatchDocument(document, layer({ [first]: null }))).why, /missing/)
  assert.match((await verifyBatchDocument(document, layer({ [first]: ledger.payloads[second] }))).why, /something else/)
  const alteredBlock = clone(ledger.payloads[first]); alteredBlock.payload.block += 1
  assert.match((await verifyBatchDocument(document, layer({ [first]: alteredBlock }))).why, /something else/)
  // the pet's signature is inside the bytes the address is the hash of, so replacing it changes the address
  const resigned = clone(ledger.payloads[first]); resigned.bw.$signatures[0] = '0'.repeat(128)
  assert.notEqual(await dataHash(resigned), first)
  assert.match((await verifyBatchDocument(document, layer({ [first]: resigned }))).why, /something else/)
  const extra = clone(ledger.payloads[first]); extra.note = 'x'
  assert.match((await verifyBatchDocument(document, layer({ [first]: extra }))).why, /something else/)
  assert.deepEqual(Object.keys(ledger.payloads[first]).sort(), ['bw', 'payload', 'schema', 'v'])
})

await test('a batch: a receipt that was forged BEFORE it was filed is refused by its signature, though its address is its own', async () => {
  const forgedBw = clone(allReceipts[0].bw); forgedBw.$signatures[0] = '0'.repeat(128)
  const built = await buildBatchDocument({ network: 'mainnet', day: '2026-10-20', receipts: [{ bw: forgedBw, payload: allReceipts[0].payload }] })
  const r = await verifyBatchDocument(built.document, served(built.payloads))
  assert.equal(r.ok, false)
  assert.match(r.why, /does not check out/)
  // and a filed receipt that is not shaped as one
  const odd = filedReceipt({ bw: allReceipts[1].bw, payload: allReceipts[1].payload }); odd.v = 2
  const oddHash = await dataHash(odd)
  const manifest = { ...ledger.documents[0].document, receipts: [oddHash], count: 1, root: await batchRoot([await dataHash(allReceipts[1].bw)]) }
  assert.match((await verifyBatchDocument(manifest, served({ [oddHash]: odd }))).why, /pet receipt wrapping/)
})

await test('a batch: a change to the manifest moves its hash, so the chain\'s commitment pins it', async () => {
  const { document, hash } = ledger.documents[0]
  assert.equal(await dataHash(document), hash)
  const moved = clone(document); moved.final = !moved.final
  assert.notEqual(await dataHash(moved), hash)
  assert.equal(BATCH_SCHEMA, 'com.jimtheexplorer.pet.batch')
})

const anchorFx = json('anchor-mainnet.json')
const anchorLayer = (extra = {}) => async (h) => { const p = extra[h] !== undefined ? extra[h] : anchorFx.payloads[h]; return p ? clone(p) : null }
const anchorBlocks = (blocks = anchorFx.blocks) => async (n) => blocks[String(n)] ?? null

await test('an anchor: the first real mainnet day reads back from the data layer and the block that lists it', async () => {
  const r = await readAnchor(anchorFx.tx, anchorLayer(), anchorBlocks())
  assert.equal(r.ok, true, r.why)
  assert.equal(r.block, 1846124)
  assert.equal(r.kind, 'root')
  assert.equal(r.record.period, '2026-10-20')
  assert.equal(r.record.digest, 'cf8fcd2917ce858bdd3368936ec75fb45691a21a1d70e10ce0ce56fd988d576e')
  const day = await verifyLedgerDay(anchorFx.tx, anchorLayer(), anchorBlocks())
  assert.equal(day.ok, true); assert.equal(day.batch, null)
})

await test('an anchor: every way of tampering with what is read is refused', async () => {
  const t = clone(anchorFx.payloads[anchorFx.tx]); t.nbf = 1
  assert.match((await readAnchor(anchorFx.tx, anchorLayer({ [anchorFx.tx]: t }), anchorBlocks())).why, /something else/)
  const idHash = '4a4b74935cdec1ca2a1361db2b0beb29ac8866d6b5c5c31ae29307e7d28063e3'
  const id = clone(anchorFx.payloads[idHash]); id.salt = id.salt.replace('cf8fcd', 'cf8fce')
  assert.match((await readAnchor(anchorFx.tx, anchorLayer({ [idHash]: id }), anchorBlocks())).why, /something else/)
  assert.match((await readAnchor(anchorFx.tx, async () => null, anchorBlocks())).why, /no such transaction/)
  assert.match((await readAnchor('zz', anchorLayer(), anchorBlocks())).why, /64-character/)
  assert.match((await readAnchor(anchorFx.tx, anchorLayer(), anchorBlocks({}))).why, /no block/)
  const forged = JSON.parse(anchorFx.blocks['1846124']); forged[0].$signatures[0] = '0'.repeat(128)
  assert.match((await readAnchor(anchorFx.tx, anchorLayer(), anchorBlocks({ 1846124: JSON.stringify(forged) }))).why, /does not check out/)
  const other = JSON.parse(anchorFx.blocks['1846124']); other[0].payload_hashes = other[0].payload_hashes.filter((h) => h !== anchorFx.tx)
  assert.match((await readAnchor(anchorFx.tx, anchorLayer(), anchorBlocks({ 1846124: JSON.stringify(other) }))).why, /no block/)
})

await test('the ledger: walked back by its previous links, whole, with a gap named and a swapped or misordered manifest refused', async () => {
  const [one, two] = ledger.documents
  const docs = { [one.hash]: one.document, [two.hash]: two.document }
  const whole = await walkLedger(two.hash, served(docs))
  assert.equal(whole.ok, true); assert.equal(whole.complete, true)
  assert.deepEqual(whole.chain.map((c) => [c.day, c.part, c.final]), [['2026-10-20', 2, true], ['2026-10-20', 1, false]])
  const gap = await walkLedger(two.hash, served({ [two.hash]: two.document }))
  assert.equal(gap.ok, true); assert.equal(gap.complete, false); assert.equal(gap.gapAt, one.hash)
  assert.match(gap.why, /not on the data layer/)
  const swapped = await walkLedger(two.hash, served({ [two.hash]: two.document, [one.hash]: { ...one.document, count: 99 } }))
  assert.equal(swapped.ok, false); assert.match(swapped.why, /something else/)
  const skewed = clone(one.document); skewed.final = true
  const skewHash = await dataHash(skewed)
  const after = { ...two.document, previous: skewHash }
  const afterHash = await dataHash(after)
  const bad = await walkLedger(afterHash, served({ [afterHash]: after, [skewHash]: skewed }))
  assert.equal(bad.ok, false); assert.match(bad.why, /do not follow/)
  assert.equal((await walkLedger('zz', served({}))).ok, false)
})

await test('verify-day.mjs: the saved real day passes offline (exit 0), and a tampered copy fails (exit 1), and a bad file is a 2', async () => {
  const run = (...a) => spawnSync(process.execPath, [join(dirname(fileURLToPath(import.meta.url)), 'verify-day.mjs'), ...a], { encoding: 'utf8' })
  const good = run('--saved', join(dir, 'anchor-mainnet.json'))
  assert.equal(good.status, 0, good.stdout + good.stderr)
  assert.match(good.stdout, /block 1846124/)
  const bad = clone(anchorFx); bad.payloads[anchorFx.tx].nbf = 1
  const f = join(tmpdir(), `bad-day-${process.pid}.json`)
  writeFileSync(f, JSON.stringify(bad))
  assert.equal(run('--saved', f).status, 1)
  writeFileSync(f, '{"tx":1}')
  assert.equal(run('--saved', f).status, 2)
  assert.equal(run('nonsense').status, 2)
})

if (failures) {
  console.error(`\n${failures} check(s) failed.`)
  process.exit(1)
}
console.log('\nThe verifier agrees with the SDK and the chain.')
