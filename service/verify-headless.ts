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

import { GatewayBuilder, NetworkDataLakeUrls } from '@xyo-network/xl1-sdk'
import type { SimpleXyoGatewayRunner } from '@xyo-network/xl1-sdk'
import { createRestDataLakeViewer } from '@xyo-network/xl1-sdk/providers'
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
  /* BUILT THE WAY THE SERVICE BUILDS IT, which took a failed run to learn.
   *
   * The first version called src/getGateway.ts, which resolves its RPC from
   * XYO_CHAIN_RPC_URL and falls back to http://localhost:8080/rpc. Nothing
   * listens there on a Pi, so the run died on "xyoViewer_currentBlock: fetch
   * failed" while the service beside it was anchoring happily -- because the
   * /anchor route uses a different builder, keyed on the network:
   * XL1_SEQUENCE_RPC_URL. A verifier reaching a different chain endpoint from
   * the thing it is verifying proves nothing about the thing.
   *
   * The datalake endpoint is what files the off-chain bytes; without it the
   * hash would anchor with nothing behind it. */
  const rpcUrl = process.env[`XL1_${NETWORK.toUpperCase()}_RPC_URL`]
    ?? process.env.XYO_CHAIN_RPC_URL
  if (!rpcUrl) {
    console.error(`No RPC URL for ${NETWORK}. Set XL1_${NETWORK.toUpperCase()}_RPC_URL.`)
    process.exit(2)
  }
  const dataLake = NetworkDataLakeUrls[NETWORK as keyof typeof NetworkDataLakeUrls]
  const builder = new GatewayBuilder().name(NETWORK).rpcUrl(rpcUrl)
  const gateway = await (dataLake ? builder.dataLakeEndpoint(dataLake) : builder)
    .account(account)
    .buildRunner() as SimpleXyoGatewayRunner
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

  /* THE BOUND WITNESS SITS BESIDE AN ARRAY OF THE PAYLOADS IT WITNESSES, so a
   * shallow read finds the witness and misses everything else -- the same
   * nesting server.ts flattens before it counts mints. */
  const flat = (x: unknown): unknown[] => (Array.isArray(x) ? x.flatMap(flat) : [x])
  const parts = flat(tx) as Record<string, unknown>[]
  const bw = parts.find(p => p?.schema === 'network.xyo.boundwitness')
  ok('the chain has the transaction', Boolean(bw),
    bw ? '' : 'submitted but not readable back')

  /* AND THE OFF-CHAIN PAYLOAD IS NOT IN THERE, which took a run to learn.
   *
   * byHash returns the witness and the ON-CHAIN payload -- here the
   * network.xyo.hash -- and nothing else. The network.xyo.id payload carrying
   * the record is named in payload_schemas and must be fetched from the
   * datalake by its hash.
   *
   * The first version of this check looked for the contentHash anywhere in the
   * response and passed. The on-chain hash payload IS the content hash, so the
   * assertion was satisfied by the one thing that says nothing about whether
   * the bytes were filed. A green check for the wrong reason is worse than a
   * red one, and it is the failure this whole script exists to catch. */
  const schemas = (bw?.payload_schemas ?? []) as string[]
  const hashes = (bw?.payload_hashes ?? []) as string[]
  const idAt = schemas.indexOf('network.xyo.id')
  ok('the transaction names the off-chain payload', idAt >= 0,
    `payload_schemas ${JSON.stringify(schemas)}`)

  const lakeUrl = NetworkDataLakeUrls[NETWORK as keyof typeof NetworkDataLakeUrls]
  if (idAt >= 0 && lakeUrl) {
    const lake = await createRestDataLakeViewer(lakeUrl)
    // BY HASH, never .next(): a remote datalake is a content-addressed blob
    // store and does not paginate.
    const got = await lake.get([hashes[idAt] as never])
    const filed = flat(got).find(
      (x): x is Record<string, unknown> =>
        Boolean(x) && (x as Record<string, unknown>).schema === 'network.xyo.id')
    ok('AND THE DATALAKE HAS THE BYTES BEHIND IT', Boolean(filed),
      filed ? '' : 'the hash is anchored with nothing to resolve to')
    const salt = String(filed?.salt ?? '')
    ok('and the record round-trips to what we sent',
      salt.includes('headless verification'),
      salt ? `salt ${salt.slice(0, 50)}...` : 'no salt came back')
  }

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
