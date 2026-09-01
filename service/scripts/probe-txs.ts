/** Does the chain itself give us this wallet's transactions, with hashes?
 *
 * The panels list anchors out of our own database -- what this site RECORDED
 * doing. That is not the same claim as what the wallet actually did, and for a
 * feature whose whole point is tamper-evidence the difference matters.
 *
 * accountBalanceHistory returns [block, transaction, transfer] per entry, and
 * the transaction carries its own hash. If those hashes match the ones we
 * stored, the list can be served from the chain instead of from us.
 */
import { GatewayBuilder, NetworkDataLakeUrls } from '@xyo-network/xl1-sdk'

const RPC = process.env.XL1_SEQUENCE_RPC_URL ?? 'https://beta.api.chain.xyo.network/rpc'
const ADDRESS = (process.argv[2] ?? '').replace(/^0x/i, '')
if (!/^[0-9a-fA-F]{40}$/.test(ADDRESS)) {
  console.error('usage: tsx scripts/probe-txs.ts <address>')
  process.exit(2)
}

const gateway = await new GatewayBuilder().name('sequence').rpcUrl(RPC)
  .dataLakeEndpoint(NetworkDataLakeUrls.sequence).build()
const viewer = gateway.connection.viewer as never as {
  accountBalanceHistory: (a: string) => Promise<unknown[]>
}

const history = await viewer.accountBalanceHistory(ADDRESS)
console.log(`entries: ${history.length}\n`)

for (const e of history) {
  const entry = e as unknown[]
  const block = entry[0] as { block?: number, _hash?: string }
  const tx = entry[1] as { _hash?: string, from?: string, fees?: Record<string, string> } | null
  const transfer = entry[2] as { from?: string, transfers?: Record<string, string> }
  const out = Object.values(transfer?.transfers ?? {})
    .reduce((t, h) => t + BigInt('0x' + String(h).replace(/^0x/i, '')), 0n)
  console.log([
    `block ${block?.block}`,
    `tx ${tx?._hash ?? '(none - minted)'}`,
    `out ${out}`,
  ].join('  '))
}
process.exit(0)
