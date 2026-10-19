#!/usr/bin/env node
/**
 * Check a pet witness receipt from the command line, with nothing taken on trust.
 *
 *   node verify.mjs receipt.json            check a receipt file, reading the block from XL1's public files
 *   cat receipt.json | node verify.mjs -    the same, from standard input
 *   node verify.mjs receipt.json --block block.json
 *                                           check against a block you already hold, with no network at all
 *   node verify.mjs pack.json               a proof pack ({"receipt": ..., "block": ...}): the receipt and its block
 *                                           in one file, checked with no network at all
 *
 * The input may be the receipt alone ({"bw": ..., "payload": ...}) or any text that contains it, such as a
 * message a pet's owner shared: everything before the first "{" is ignored.
 *
 * Exit status: 0 every check held; 1 a check failed (the receipt or the block is not what it says); 2 a check
 * could not be run (the chain's files could not be reached, or the input could not be read). 2 is never a
 * verdict on the receipt.
 *
 * Needs Node 20 or newer and nothing else: no packages, no XYO SDK. The checking is witness.js, the one file
 * the site's verify page also uses; SPEC.md describes what it checks.
 */
import { readFileSync } from 'node:fs'

import { DEED_SCHEMA, checkBlock, checkReceipt, describeDeed, verifyReceipt } from './witness.js'

const args = process.argv.slice(2)
const blockFlag = args.indexOf('--block')
const blockFile = blockFlag >= 0 ? args[blockFlag + 1] : null
// the receipt is the first argument that is not the flag or the flag's value (-1 matches no index)
const flagValueAt = blockFlag >= 0 ? blockFlag + 1 : -1
const input = args.find((a, i) => i !== flagValueAt && a !== '--block')

if (!input) {
  console.error('usage: node verify.mjs <receipt.json | -> [--block block.json]')
  process.exit(2)
}

let receipt
let packBlock = null
try {
  const text = input === '-' ? readFileSync(0, 'utf8') : readFileSync(input, 'utf8')
  const parsed = JSON.parse(text.slice(text.indexOf('{')))
  // a proof pack holds the receipt and its block side by side
  const r = parsed?.receipt && parsed?.block ? parsed.receipt : parsed
  if (!r?.bw || !r?.payload) throw new Error('that is not a receipt: it needs a "bw" and a "payload"')
  receipt = { bw: r.bw, payload: r.payload }
  if (r !== parsed) packBlock = JSON.stringify(parsed.block)
} catch (e) {
  console.error(`Could not read a receipt: ${e.message}`)
  process.exit(2)
}

const mark = { pass: 'ok  ', fail: 'FAIL', unavailable: '??  ', skipped: '--  ' }
const show = (steps) => {
  for (const s of steps) console.log(`  ${mark[s.status] ?? '??  '} ${s.label}\n       ${s.detail}`)
}

let steps
let ok
let deed = null
const isDeed = receipt.payload.schema === DEED_SCHEMA
if ((blockFile || packBlock) && !isDeed) {
  // a block you already hold: check the receipt, then check that block against it, offline
  const r = await checkReceipt(receipt.bw, receipt.payload)
  steps = [{ id: 'receipt', label: 'The receipt is sound and the pet\'s signature is the pet\'s', status: r.ok ? 'pass' : 'fail', detail: r.ok ? `Signed by ${r.summary.address}.` : r.why }]
  ok = r.ok
  if (r.ok) {
    const b = await checkBlock(blockFile ? readFileSync(blockFile, 'utf8') : packBlock, r.summary.block, r.summary.blockHash)
    steps.push({ id: 'block', label: 'The block\'s hash, recomputed from its own content, is the one the receipt names, and its signature is from the address it lists', status: b.ok ? 'pass' : 'fail', detail: b.ok ? `Block ${r.summary.block}, hash ${r.summary.blockHash}.` : b.why })
    ok = b.ok
  }
} else {
  const v = await verifyReceipt(receipt)
  steps = v.steps
  ok = v.ok
  deed = v.deed ?? null
}

console.log(isDeed ? 'A deed signed by a pet\'s Archivist:' : 'A pet\'s witness receipt:')
show(steps)
if (deed) console.log(`
  ${describeDeed(deed)}`)
const failed = steps.some((s) => s.status === 'fail')
console.log(ok ? '\nEvery check holds.' : failed ? '\nA check FAILED: this receipt is not what it claims.' : '\nCould not be confirmed (a check could not be run). That is not a verdict on the receipt.')
process.exit(ok ? 0 : failed ? 1 : 2)
