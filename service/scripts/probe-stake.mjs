// What the public gateway can and cannot tell us about stake.
//
// Run:  node scripts/probe-stake.mjs
//
// Background. The node's eligibility to produce has two halves: balance, which
// is read and shown on the panel, and stake, which is not. That looked like a
// blind spot worth closing -- a node whose stake fell short would stop being
// scheduled while every reading stayed green.
//
// It is not closeable from here, and this script is the evidence. Run against
// the sequence network on 2026-08-27:
//
//   stakesByStaked and stakesByStaker ARE callable on the public gateway --
//   the earlier note that they were absent was wrong -- but they return an
//   empty array for EVERY active producer, not only ours. Four producers had
//   signed the previous 40 blocks; all four returned zero positions while
//   producing normally. Stake records live on the EVM chain, and this
//   network's view does not carry them.
//
// So a stake figure read here would be zero for everyone forever: not a
// signal, just a tile that cries wolf. The node's own "insufficient stake"
// log line, which read_blocked_reason already watches, remains the only
// honest source for that fault.
//
// Worth re-running if XYO changes the gateway: the day this stops returning
// empty is the day the tile becomes worth building.
//
// One trap it also documents: addresses must be passed UNPREFIXED. The
// prefixed form fails validation on every one of these calls, including
// accountBalance -- which is the bug that once made a working balance look
// like an unavailable one.

// Is stakesByStaked empty for THIS producer, or for every producer on this
// network? That decides whether stake is worth reading at all: a figure that
// reads zero for everyone is not a signal, it is a tile that cries wolf.
import { GatewayBuilder } from '@xyo-network/xl1-sdk'

const RPC = process.env.XL1_SEQUENCE_RPC_URL ?? 'https://beta.api.chain.xyo.network/rpc'
const gw = await new GatewayBuilder().name('sequence').rpcUrl(RPC).build()
const v = gw.connection.viewer

const head = Number(await v.block.currentBlockNumber())
console.log('head:', head)

// Same access the production scan uses: a descending range in one call, with
// signers carried on each block's bound witness.
const batch = await v.block.blocksByNumber(head, 40)
const producers = new Map()
for (const blk of (Array.isArray(batch) ? batch : [batch])) {
  const parts = Array.isArray(blk) ? blk : [blk]
  const bw = parts.find((p) => p?.schema === 'network.xyo.boundwitness')
  if (!bw) continue
  for (const a of (bw.addresses ?? [])) {
    const k = String(a).replace(/^0x/i, '').toLowerCase()
    producers.set(k, (producers.get(k) ?? 0) + 1)
  }
}
console.log('distinct signers in the last 40 blocks:', producers.size)
console.log('')

for (const [p, seen] of [...producers.entries()].slice(0, 8)) {
  try {
    const staked = await v.stakesByStaked(p)
    const staker = await v.stakesByStaker(p)
    const bal = await v.accountBalance(p)
    console.log(`  ${p.slice(0, 14)}..  blocks=${String(seen).padStart(2)}  stakesByStaked=${Array.isArray(staked) ? staked.length : '?'}  stakesByStaker=${Array.isArray(staker) ? staker.length : '?'}  balance=${bal ? (Number(bal) / 1e18).toFixed(0) : 'null'}`)
  } catch (e) {
    console.log(`  ${p.slice(0, 14)}..  !! ${String(e?.message ?? e).slice(0, 70)}`)
  }
}
