#!/usr/bin/env node
/**
 * Read a day of the pet ledger back from XL1, from the command line, with nothing taken on trust.
 *
 *   node verify-day.mjs <transaction-hash>          reads the transaction and the block that lists it from XL1 itself
 *                                                   (the data layer and the chain's public block files), and -- for a day written as
 *                                                   a manifest -- the manifest and every receipt in it, then walks the ledger back
 *   node verify-day.mjs --saved day.json            the same against a saved copy ({"tx", "payloads", "blocks"}, see
 *                                                   fixtures/anchor-mainnet.json), with no network at all
 *
 * The transaction hash is the only thing you need to be told; the site's batch list (/api/sentinel/batches, `check_tx`) is where to find it.
 *
 * Exit status: 0 every check held; 1 a check failed (the data is not what it says); 2 a check could not be run (XL1 could not be reached,
 * or the input could not be read). 2 is never a verdict on the day.
 *
 * Needs Node 20 or newer and nothing else. The checking is witness.js (readAnchor, verifyLedgerDay, walkLedger); SPEC.md describes it.
 */
import { readFileSync } from 'node:fs'

import { blockUrl, verifyLedgerDay, walkLedger } from './witness.js'

const args = process.argv.slice(2)
const savedAt = args.indexOf('--saved')
const savedFile = savedAt >= 0 ? args[savedAt + 1] : null
const tx = savedFile ? null : args[0]
if (!savedFile && !(tx && /^[0-9a-f]{64}$/.test(tx))) {
  console.error('usage: node verify-day.mjs <64-character transaction hash> | --saved day.json')
  process.exit(2)
}

class Unreachable extends Error {}
let txHash = tx
let fetchPayload
let fetchBlock
let network = 'mainnet'
if (savedFile) {
  let saved
  try { saved = JSON.parse(readFileSync(savedFile, 'utf8')) } catch (e) { console.error(`Could not read ${savedFile}: ${e.message}`); process.exit(2) }
  if (!saved?.tx || !saved.payloads || !saved.blocks) { console.error('that is not a saved day: it needs "tx", "payloads" and "blocks"'); process.exit(2) }
  txHash = saved.tx
  network = saved.network || 'mainnet'
  fetchPayload = async (h) => saved.payloads[h] ?? null
  fetchBlock = async (n) => saved.blocks[String(n)] ?? null
} else {
  const get = async (url) => {
    try { return await fetch(url) } catch { throw new Unreachable(url) }
  }
  fetchPayload = async (h) => {
    const r = await get(`https://api.archivist.xyo.network/dataLake/get/${h}`)
    if (r.status === 404) return null
    if (!r.ok) throw new Unreachable(`the data layer answered ${r.status}`)
    return r.json()
  }
  fetchBlock = async (n) => {
    const r = await get(blockUrl(network, n))
    return r.ok ? r.text() : null
  }
}

let day
try {
  day = await verifyLedgerDay(txHash, fetchPayload, fetchBlock)
  if (day.ok && day.kind === 'manifest') day.walk = await walkLedger(day.record.digest, fetchPayload)
} catch (e) {
  console.error(`Could not confirm: ${e.message}. That is not a failed check.`)
  process.exit(2)
}

if (!day.ok) {
  console.log(`A check FAILED: ${day.why}`)
  process.exit(1)
}
console.log(`ok   The transaction is signed by ${day.signer}, and block ${day.block} (signed by ${day.blockSigners.join(', ')}) lists it`)
console.log(`ok   Its record is for ${day.record.period} on ${day.record.network}, app ${day.record.app}`)
if (day.batch) {
  console.log(`ok   The manifest the chain committed is on the data layer, and all ${day.batch.count} receipt(s) in it check out`)
  if (day.walk.ok && day.walk.complete) console.log(`ok   The ledger runs back ${day.walk.chain.length} manifest(s) to its start, with no gap`)
  else if (!day.walk.ok) { console.log(`A check FAILED: ${day.walk.why}`); process.exit(1) }
  else console.log(`--   The ledger behind it: ${day.walk.why}`)
} else {
  console.log('--   This day was written as a bare root, so its receipts are not on the data layer and only the anchor can be shown')
}
console.log('\nEvery check that could be run holds.')
