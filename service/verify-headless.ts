/**
 * Prove the anchoring path end to end, from a seed phrase, with no browser.
 *
 *   npx tsx verify-headless.ts
 *
 * THIS SPENDS REAL GAS. One transaction per run, on whatever XL1_NETWORK says.
 * It is deliberately NOT in scripts/ci-local.sh: a gate that costs money every
 * time somebody edits a stylesheet is a gate people route around.
 *
 * WHY IT EXISTS. Every fault of 2026-09-18 lived in the band between "the
 * transaction succeeded" and "the site says so": an arrival anchored and filed
 * while the page still offered the button, a monthly standing thrown away in a
 * mapping function, a viewer cast that would have reported every transaction
 * as absent. Nothing in the suite crosses that band, because the suite has no
 * chain. This does.
 *
 * IT CALLS THE SERVICE'S OWN FUNCTION. `anchorRecord` is the same code the
 * /anchor route runs -- same payloads, same schemas, same bytes. A verifier
 * that rebuilt the payloads itself would prove only that the verifier works,
 * which is the failure mode the XL1 headless-verification pattern warns about.
 *
 * WHERE TO RUN IT. On a Pi, where /etc/xl1-anchor.env already holds the
 * attestation mnemonic and it never has to travel:
 *
 *   sudo -E env $(sudo cat /etc/xl1-anchor.env | xargs) npx tsx verify-headless.ts
 *
 * Or locally with a gitignored .env holding XYO_WALLET_MNEMONIC. The phrase is
 * never printed, never logged, and never sent anywhere but the gateway.
 */
import 'dotenv/config'

import { getGateway } from './src/getGateway.ts'
import { getSignerAccount } from './src/getSignerAccount.ts'
import { anchorRecord } from './src/anchorRecord.ts'

const NETWORK = process.env.XL1_NETWORK ?? 'sequence'

let failures = 0
const ok = (what: string, cond: boolean, detail = '') => {
  if (cond) { console.log(`  ok    ${what}${detail ? ` -- ${detail}` : ''}`); return }
  failures += 1
  console.log(`  FAIL  ${what}${detail ? ` -- ${detail}` : ''}`)
}

const run = async () => {
  // MAINNET COSTS REAL MONEY. Sequence is the default and mainnet needs to be
  // asked for out loud, twice -- once in the network, once in the flag.
  if (NETWORK === 'mainnet' && !process.argv.includes('--yes-mainnet')) {
    console.error('Refusing mainnet without --yes-mainnet. This spends real XL1.')
    process.exit(2)
  }
  if (!process.env.XYO_WALLET_MNEMONIC) {
    console.error('XYO_WALLET_MNEMONIC is not set. Nothing was attempted.')
    process.exit(2)
  }

  console.log(`\n== the signer, derived the canonical way ==`)
  const account = await getSignerAccount()
  // The ADDRESS is public and is the whole point of checking; the phrase is not.
  console.log(`  address ${account.address}`)

  console.log(`\n== anchoring one record on ${NETWORK} ==`)
  // getGateway reads XL1_NETWORK itself and wires the datalake endpoint for
  // that network -- which is what files the off-chain bytes. Same function
  // the operator tools use, so this cannot drift from them.
  const gateway = await getGateway()
  const stamp = new Date().toISOString()
  const done = await anchorRecord(
    gateway, NETWORK, 'headless verification', `run at ${stamp}`)
  console.log(`  tx      ${done.txHash}`)
  ok('the gateway returned a transaction hash', Boolean(done.txHash))
  ok('and it confirmed inside the window', done.confirmed === true,
    done.confirmed ? '' : 'not fatal: the backend verifies inclusion itself')

  console.log(`\n== READ IT BACK THROUGH THE VIEWER, not through our own memory ==`)
  const viewer = gateway.connection.viewer
  if (!viewer) { ok('the connection has a viewer', false); return finish() }

  const tx = await viewer.transaction.byHash(
    done.txHash as Parameters<typeof viewer.transaction.byHash>[0])
  const first = Array.isArray(tx) ? tx[0] : tx
  ok('the chain has the transaction', Boolean(first),
    first ? '' : 'submitted but not readable back')

  // THE BAND WHERE THE BUGS LIVE. A hash on chain with no payload behind it is
  // a digest nobody can resolve -- see the note in anchorRecord.
  const hydrated = JSON.stringify(tx ?? {})
  ok('AND THE OFF-CHAIN PAYLOAD CAME BACK WITH IT',
    hydrated.includes(done.contentHash),
    hydrated.includes(done.contentHash) ? '' : 'the bytes were never filed')
  ok('and the record round-trips to what we sent',
    hydrated.includes('headless verification'),
    'the salt must carry our own title back')

  console.log(`\n== the watermarks, before blaming "sequence is slow" ==`)
  const head = await viewer.finalization?.headNumber?.()
  const headNum = typeof head === 'bigint' ? Number(head) : Number(head)
  ok('finalization reports a head', Number.isFinite(headNum) && headNum > 0,
    Number.isFinite(headNum) ? `head ${headNum}` : 'no finalization on this gateway')

  finish()
}

const finish = () => {
  console.log(`\n${failures === 0 ? 'ALL GOOD -- the chain side works end to end'
    : `${failures} FAILED`}\n`)
  process.exit(failures === 0 ? 0 : 1)
}

run().catch((e) => {
  // Never let a stack trace carry the phrase. Message only.
  console.error(`\nverification threw: ${e instanceof Error ? e.message : String(e)}\n`)
  process.exit(1)
})
