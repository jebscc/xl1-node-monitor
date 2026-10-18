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

import { bytesToHex, checkBlock, checkReceipt, dataHash, keccak256, recoverAddresses, signedBy } from './witness.js'

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

if (failures) {
  console.error(`\n${failures} check(s) failed.`)
  process.exit(1)
}
console.log('\nThe verifier agrees with the SDK and the chain.')
