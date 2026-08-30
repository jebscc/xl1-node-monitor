// How much of an address's balance was EARNED by producing blocks?
//
//   node scripts/earnings-breakdown.mjs <address> [--since <block>]
//                                        [--scan <floor-block>] [--json]
//
// Why this exists. The panel's earnings figure is the day-over-day change in
// balance. That is honest about what reached the account and cannot answer
// "what did the node actually earn", because a transfer in or out moves it
// exactly the same way.
//
// WHAT THE SDK PROVIDES, AND WHAT IT DOES NOT. XL1 does have a first-class
// block-reward API: BlockRewardViewer.allowedRewardForBlock(block), with
// SimpleBlockRewardViewer implementing it from the published schedule
// (XL1_REWARDS_STARTING_REWARD, _BLOCKS_PER_STEP, _STEP_FACTOR_*,
// _MIN_BLOCK_REWARD). This script uses it. Three limits make it insufficient
// on its own, each checked against this network rather than assumed:
//
//   1. It is not on the gateway. gateway.connection.viewer exposes no reward
//      provider, and the address-level RPCs (networkStakeStepRewardAddress-
//      History, ...ClaimedByAddress) answer "Method not implemented". The
//      viewer has to be built locally from the constants.
//   2. It returns the TOTAL minted per block, not the producer's cut. The
//      total is split between XYO_STEP_REWARD_ADDRESS and the producer, and
//      the producer's fraction is not part of allowedRewardForBlock.
//   3. It is a schedule, not a record. It describes what the current constants
//      say, not what the chain paid. On sequence the two disagree: at blocks
//      100000 and 200000 the chain minted 1000 XL1 where the schedule says
//      500, and the producer's fraction moved from 5% to 10% at block
//      528118/528119 while defaultRewardRatio reports only today's 0.1.
//
// So the earnings figure is MEASURED from the chain and CROSS-CHECKED against
// the SDK schedule. Agreement is reported, and so is disagreement -- the point
// of the check is to fail loudly the day the network changes underneath it.
//
// The method. Block rewards are minted: they arrive in a network.xyo.transfer
// whose `from` is the zero address, which no ordinary transfer does. Of the two
// credits in a mint, the one to XYO_STEP_REWARD_ADDRESS is the protocol's and
// the other is the producer's. The reward is a fixed amount, so a balance built
// only from rewards is an exact multiple of it: divide, and the REMAINDER is
// everything that cannot be a block reward.
//
// That decomposition covers all time, which is the point of doing it this way.
// accountBalanceHistory returns a fixed recent window -- it takes no range
// argument, and both (addr, 500) and (addr, 0, 500) are rejected -- so anything
// derived from the window alone describes an hour, not a lifetime.
//
// --since <first-block> verifies the producer share held across the address's
// whole history and refuses to decompose when it did not. The remainder is a
// CEILING on non-earned money, because fee shares land in it too; --scan
// <floor> walks every block and sums the real credits, turning the ceiling
// into a figure. Set <floor> below the first block the address ever produced.
//
// A scan normally ends a block or two short of what the balance implies,
// because the balance moves while it runs. That does not disturb the answer: a
// missing whole reward changes the balance by exactly one reward and so leaves
// balance % reward untouched. Only the fee total is short. A LARGE shortfall
// means the floor is above the first produced block, so the two are reported
// differently.
import {
  defaultRewardRatio,
  GatewayBuilder,
  SimpleBlockRewardViewer,
  XL1_REWARDS_BLOCKS_PER_STEP,
  XL1_REWARDS_CREATOR_REWARD,
  XL1_REWARDS_MIN_BLOCK_REWARD,
  XL1_REWARDS_STARTING_REWARD,
  XL1_REWARDS_STEP_FACTOR_DENOMINATOR,
  XL1_REWARDS_STEP_FACTOR_NUMERATOR,
  XYO_STEP_REWARD_ADDRESS,
} from '@xyo-network/xl1-sdk'

const ZERO = '0'.repeat(40)
const DECIMALS = 10n ** 18n
const STEP_REWARD_ADDR = String(XYO_STEP_REWARD_ADDRESS).replace(/^0x/i, '').toLowerCase()
// Blocks the scan may trail the balance by before it means the floor is wrong
// rather than that the chain moved underneath the read.
const HEAD_LAG_TOLERANCE = 5
const SCAN_WINDOW = 2000

const raw = process.argv[2]
if (!raw || !/^(0x)?[0-9a-fA-F]{40}$/.test(raw)) {
  console.error('usage: node scripts/earnings-breakdown.mjs <address> [--since <block>] [--scan <floor>] [--json]')
  process.exit(2)
}
const ADDR = raw.replace(/^0x/i, '').toLowerCase()
const AS_JSON = process.argv.includes('--json')
const argNum = (flag) => {
  const i = process.argv.indexOf(flag)
  return i > 0 ? Number(process.argv[i + 1]) : null
}
const SINCE = argNum('--since')
const SCAN_FLOOR = argNum('--scan')

const gw = await new GatewayBuilder().name(process.env.XL1_NETWORK ?? 'sequence')
  .rpcUrl(process.env.XL1_SEQUENCE_RPC_URL ?? 'https://beta.api.chain.xyo.network/rpc')
  .build()
const v = gw.connection.viewer

const flat = (x) => (Array.isArray(x) ? x.flatMap(flat) : [x])
const amount = (hex) => (hex == null ? 0n : BigInt('0x' + String(hex).replace(/^0x/i, '')))
const xl1 = (wei) => Number(wei) / Number(DECIMALS)

// The gateway does not implement the reward viewer, so build the SDK's own
// implementation locally from the published constants.
const rewardViewer = await SimpleBlockRewardViewer.create({
  context: gw.connection.context,
  creatorReward: XL1_REWARDS_CREATOR_REWARD,
  initialReward: XL1_REWARDS_STARTING_REWARD,
  minRewardPerBlock: XL1_REWARDS_MIN_BLOCK_REWARD,
  stepFactorDenominator: XL1_REWARDS_STEP_FACTOR_DENOMINATOR,
  stepFactorNumerator: XL1_REWARDS_STEP_FACTOR_NUMERATOR,
  stepSize: XL1_REWARDS_BLOCKS_PER_STEP,
})

/** What a block actually minted, split into the protocol's cut and the producer's.
 *
 * Identifying the producer's share by excluding XYO_STEP_REWARD_ADDRESS beats
 * taking the smaller of the two credits: the split has been 5% and is now 10%,
 * and nothing guarantees the producer's share stays the smaller one.
 */
async function mintedAt(height) {
  const batch = await v.block.blocksByNumber(height, 1)
  for (const blk of (Array.isArray(batch) ? batch : [batch])) {
    let toStep = 0n, toProducer = 0n, found = false
    for (const p of flat(blk)) {
      if (p?.schema !== 'network.xyo.transfer') continue
      if (String(p.from ?? '').replace(/^0x/i, '').toLowerCase() !== ZERO) continue
      for (const [a, hex] of Object.entries(p.transfers ?? {})) {
        found = true
        if (a.replace(/^0x/i, '').toLowerCase() === STEP_REWARD_ADDR) toStep += amount(hex)
        else toProducer += amount(hex)
      }
    }
    if (found) return { toStep, toProducer, total: toStep + toProducer }
  }
  return null
}

const head = Number(await v.block.currentBlockNumber())
const balance = BigInt((await v.accountBalance(ADDR)).toString())

const atHead = await mintedAt(head)
if (!atHead || atHead.toProducer === 0n) {
  console.error('could not read the producer reward at head; cannot decompose')
  process.exit(1)
}
const reward = atHead.toProducer

// Cross-check the measurement against the SDK's published schedule.
const officialTotal = BigInt((await rewardViewer.allowedRewardForBlock(head)).toString())
const RATIO_SCALE = 1000000n
const expectedProducer = officialTotal * BigInt(Math.round(defaultRewardRatio * Number(RATIO_SCALE))) / RATIO_SCALE
const totalAgrees = officialTotal === atHead.total
const shareAgrees = expectedProducer === reward

// Did the producer's share hold for this address's whole production history?
let rateAtStart = null
let rateStable = null
if (SINCE != null) {
  const atStart = await mintedAt(SINCE)
  rateAtStart = atStart?.toProducer ?? null
  rateStable = rateAtStart != null && rateAtStart === reward
}

const rewardCount = balance / reward
const remainder = balance % reward

/** Every credit to and from ADDR between `floor` and the head. */
async function scanRange(floor) {
  let mintTotal = 0n, mintCount = 0, feeTotal = 0n, feeCount = 0, sentOut = 0n
  let signed = 0, short = 0, biggestFee = 0n
  const found = {}
  for (let h = head; h > floor; h -= SCAN_WINDOW) {
    const batch = await v.block.blocksByNumber(h, SCAN_WINDOW)
    let seen = 0
    for (const blk of (Array.isArray(batch) ? batch : [batch])) {
      const parts = flat(blk)
      const top = parts.find((p) => p?.schema === 'network.xyo.boundwitness' && p?.block != null)
      if (!top) continue
      seen++
      if ((top.addresses ?? []).map((a) => String(a).replace(/^0x/i, '').toLowerCase()).includes(ADDR)) signed++
      for (const p of parts) {
        if (p?.schema !== 'network.xyo.transfer') continue
        const from = String(p.from ?? '').replace(/^0x/i, '').toLowerCase()
        if (from === ADDR) {
          for (const [a, hex] of Object.entries(p.transfers ?? {})) {
            if (a.replace(/^0x/i, '').toLowerCase() !== ADDR) sentOut += amount(hex)
          }
        }
        const got = amount(p.transfers?.[ADDR])
        if (got === 0n) continue
        if (from === ZERO) { mintTotal += got; mintCount++ }
        else {
          feeTotal += got; feeCount++
          found[from] = (found[from] ?? 0n) + got
          if (got > biggestFee) biggestFee = got
        }
      }
    }
    if (seen < SCAN_WINDOW) short++
  }
  return { mintTotal, mintCount, feeTotal, feeCount, sentOut, signed, short, biggestFee, senders: found }
}

const scan = SCAN_FLOOR == null ? null : await scanRange(SCAN_FLOOR)

// The history window names the non-reward senders, which is what distinguishes
// fee shares from the operator's own transfers. It covers about an hour.
const history = (await v.accountBalanceHistory(ADDR)) ?? []
let windowMinted = 0n
let windowMintCount = 0
const senders = {}
const senderCounts = {}
for (const entry of history) {
  for (const p of (Array.isArray(entry) ? entry : [entry])) {
    if (p?.schema !== 'network.xyo.transfer') continue
    const from = String(p.from ?? '').replace(/^0x/i, '').toLowerCase()
    const credited = amount(p.transfers?.[ADDR])
    if (credited === 0n) continue
    if (from === ZERO) { windowMinted += credited; windowMintCount++ }
    else {
      senders[from] = (senders[from] ?? 0n) + credited
      senderCounts[from] = (senderCounts[from] ?? 0) + 1
    }
  }
}

if (AS_JSON) {
  console.log(JSON.stringify({
    address: ADDR,
    head,
    balance: xl1(balance),
    measured: {
      blockTotal: xl1(atHead.total),
      toStepRewardAddress: xl1(atHead.toStep),
      toProducer: xl1(reward),
    },
    sdk: {
      allowedRewardForBlock: xl1(officialTotal),
      defaultRewardRatio,
      expectedProducer: xl1(expectedProducer),
      totalAgrees,
      shareAgrees,
    },
    wholeRewards: Number(rewardCount),
    earned: xl1(rewardCount * reward),
    remainder: xl1(remainder),
    rateStable,
    rateAtStart: rateAtStart == null ? null : xl1(rateAtStart),
    windowMintCount,
    windowMinted: xl1(windowMinted),
    scan: scan == null ? null : {
      floor: SCAN_FLOOR,
      blocksSigned: scan.signed,
      mintCount: scan.mintCount,
      minted: xl1(scan.mintTotal),
      feeCount: scan.feeCount,
      fees: xl1(scan.feeTotal),
      sentOut: xl1(scan.sentOut),
      shortfall: Number(rewardCount) - scan.mintCount,
      covered: Number(rewardCount) - scan.mintCount <= HEAD_LAG_TOLERANCE,
      notEarned: xl1(remainder) - xl1(scan.feeTotal),
    },
  }, null, 2))
} else {
  const pad = (s) => String(s).padStart(16)
  console.log('address           ' + ADDR)
  console.log('chain head        ' + head)
  console.log('balance           ' + pad(xl1(balance).toFixed(6)) + ' XL1')
  console.log('')
  console.log('Block ' + head + ', measured from the chain:')
  console.log('  minted in total       ' + pad(xl1(atHead.total).toFixed(6)) + ' XL1')
  console.log('  to step reward addr   ' + pad(xl1(atHead.toStep).toFixed(6)) + ' XL1   (' + STEP_REWARD_ADDR.slice(0, 12) + '...)')
  console.log('  to the producer       ' + pad(xl1(reward).toFixed(6)) + ' XL1')
  console.log('')
  console.log('Cross-check against the SDK schedule (SimpleBlockRewardViewer):')
  console.log('  allowedRewardForBlock ' + pad(xl1(officialTotal).toFixed(6)) + ' XL1   '
    + (totalAgrees ? 'AGREES with the chain' : 'DISAGREES with the chain'))
  console.log('  x defaultRewardRatio  ' + pad(xl1(expectedProducer).toFixed(6)) + ' XL1   '
    + (shareAgrees ? 'AGREES with the chain' : 'DISAGREES with the chain'))
  if (!totalAgrees || !shareAgrees) {
    console.log('')
    console.log('  WARNING: the schedule and the chain disagree at this height. The')
    console.log('  figures below follow the CHAIN, which is what was actually paid.')
    console.log('  Worth investigating: the published constants may have moved.')
  }
  console.log('')
  if (SINCE != null && !rateStable) {
    console.log('REFUSING to decompose: the producer share was '
      + (rateAtStart == null ? 'unreadable' : xl1(rateAtStart).toFixed(4))
      + ' XL1 at block ' + SINCE + ' and is ' + xl1(reward).toFixed(4) + ' now.')
    console.log('A single rate cannot describe a balance built across a rate change.')
    console.log('Sum the minted credits per era instead.')
  } else {
    console.log('  whole block rewards   ' + pad(rewardCount))
    console.log('  earned                ' + pad(xl1(rewardCount * reward).toFixed(6)) + ' XL1')
    console.log('  remainder             ' + pad(xl1(remainder).toFixed(9)) + ' XL1')
    console.log('')
    console.log('  The remainder is everything that CANNOT be a block reward, so it')
    console.log('  bounds any test transfer sitting in this balance: '
      + (Number(remainder) / Number(balance) * 100).toFixed(4) + '% of the total.')
    if (SINCE != null) console.log('  Producer share unchanged from block ' + SINCE + ' to ' + head + '.')
    else console.log('  Pass --since <first produced block> to verify no rate change.')
  }
  if (scan) {
    const shortfall = Number(rewardCount) - scan.mintCount
    const covered = shortfall <= HEAD_LAG_TOLERANCE
    console.log('')
    console.log('Full scan from block ' + SCAN_FLOOR + ' to ' + head + ':')
    console.log('  blocks signed         ' + pad(scan.signed))
    console.log('  minted credits        ' + pad(scan.mintCount) + '   ' + xl1(scan.mintTotal).toFixed(6) + ' XL1')
    console.log('  fee credits           ' + pad(scan.feeCount) + '   ' + xl1(scan.feeTotal).toFixed(9) + ' XL1')
    console.log('  largest single fee    ' + pad(xl1(scan.biggestFee).toFixed(9)) + ' XL1')
    console.log('  sent out              ' + pad(xl1(scan.sentOut).toFixed(9)) + ' XL1')
    if (scan.short) console.log('  WARNING: ' + scan.short + ' window(s) returned short; counts may be low.')
    console.log('')
    if (covered) {
      if (shortfall > 0) {
        console.log('  Scan trails the balance by ' + shortfall + ' reward(s): the chain moved while it ran.')
        console.log('  Harmless -- a whole reward does not change balance % reward, so the figure')
        console.log('  below is off only by the fees of those blocks (~'
          + (shortfall * xl1(scan.biggestFee)).toFixed(9) + ' XL1).')
      } else {
        console.log('  Scan mints (' + scan.mintCount + ') match the decomposition (' + rewardCount + ').')
      }
      console.log('')
      console.log('  NOT EARNED            ' + pad((xl1(remainder) - xl1(scan.feeTotal)).toFixed(9)) + ' XL1')
      console.log('  That is the remainder minus the fees actually observed --')
      console.log('  money that reached this account some way other than producing.')
    } else {
      console.log('  INCOMPLETE: scan found ' + scan.mintCount + ' mints but the balance holds '
        + rewardCount + ' rewards -- ' + shortfall + ' unaccounted, past the ' + HEAD_LAG_TOLERANCE
        + ' a moving head explains.')
      console.log('  Lower --scan below the first block this address produced.')
    }
  }
  console.log('')
  console.log('Corroboration from the history window (recent, ~1 hour, NOT lifetime):')
  console.log('  minted credits        ' + pad(windowMintCount) + '   ' + xl1(windowMinted).toFixed(4) + ' XL1')
  const rows = Object.entries(senders).sort((a, b) => Number(b[1] - a[1]))
  if (!rows.length) console.log('  non-reward senders    ' + pad('none'))
  else {
    console.log('  non-reward senders:')
    for (const [a, w] of rows) {
      console.log('    ' + a + '  ' + String(senderCounts[a]).padStart(4) + ' x  '
        + xl1(w).toFixed(8) + ' XL1' + (a === ADDR ? '   <-- SELF' : ''))
    }
  }
}
