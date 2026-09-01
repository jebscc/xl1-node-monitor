/** Is accountBalance(addr, {head}) inclusive of that block's own transfers?
 *
 * It decides an off-by-one in /anchor-cost: if the head block's spend is
 * already reflected in the balance it returns, the window must count only the
 * spends AFTER it, or the cost comes out low by one anchor in N.
 *
 * Throwaway diagnostic, kept because the answer is not documented anywhere and
 * the next person to touch that window will want to re-run it.
 */
import { GatewayBuilder, NetworkDataLakeUrls } from '@xyo-network/xl1-sdk'

const RPC = process.env.XL1_SEQUENCE_RPC_URL ?? 'https://beta.api.chain.xyo.network/rpc'
const ADDRESS = (process.argv[2] ?? '').replace(/^0x/i, '')
if (!/^[0-9a-fA-F]{40}$/.test(ADDRESS)) {
  console.error('usage: tsx scripts/probe-head.ts <address>')
  process.exit(2)
}

const gateway = await new GatewayBuilder().name('sequence').rpcUrl(RPC)
  .dataLakeEndpoint(NetworkDataLakeUrls.sequence).build()
const viewer = gateway.connection.viewer as never as {
  accountBalance: (a: string, c?: unknown) => Promise<unknown>
  accountBalanceHistory: (a: string) => Promise<unknown[]>
}

const now = BigInt((await viewer.accountBalance(ADDRESS)) as string)
const history = await viewer.accountBalanceHistory(ADDRESS)
console.log(`entries returned: ${history.length}`)

const rows = history.map((e) => {
  const entry = e as unknown[]
  const block = entry[0] as { _hash?: string, block?: number }
  const transfer = entry[2] as { from?: string, transfers?: Record<string, string> }
  const out = Object.values(transfer?.transfers ?? {})
    .reduce((t, h) => t + BigInt('0x' + String(h).replace(/^0x/i, '')), 0n)
  return { height: block?.block, hash: block?._hash, from: transfer?.from, out }
}).sort((a, b) => (a.height ?? 0) - (b.height ?? 0))

console.log(`current balance: ${now}`)
for (const r of rows) {
  const at = BigInt((await viewer.accountBalance(ADDRESS, { head: r.hash })) as string)
  // "delta" is what this block's own transfer moved. If the head read is
  // INCLUSIVE, the balance at this block is already down by it, so
  // (balance at previous block) - (balance here) === out.
  console.log(`block ${r.height}  out=${r.out}  balanceAtHead=${at}  diffFromNow=${at - now}`)
}
process.exit(0)
