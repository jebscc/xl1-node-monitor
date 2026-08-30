import { timingSafeEqual } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import express from 'express'
import { PayloadBuilder } from '@xyo-network/payload-builder'
import { asSchema } from '@xyo-network/payload-model'
import { ExplorerLinks, MainNetwork, SequenceNetwork, toXL1BlockNumber } from '@xyo-network/xl1-protocol'
import type { NetworkId } from '@xyo-network/xl1-protocol'
import {
  DefaultNetworks,
  defaultRewardRatio,
  GatewayBuilder,
  HashSchema,
  type HashPayload,
  NetworkDataLakeUrls,
  SimpleBlockRewardViewer,
  SimpleXyoGateway,
  SimpleXyoGatewayRunner,
  XYO_STEP_REWARD_ADDRESS,
} from '@xyo-network/xl1-sdk'

import { getSignerAccount } from './getSignerAccount.ts'

const PORT = Number(process.env.XL1_SERVICE_PORT ?? 8090)

// Loopback by default. This listened on every interface, and the only thing
// keeping it off the network was a 127.0.0.1 mapping in docker-compose -- so
// anyone following the README's `pnpm start` was serving it to their LAN,
// including /anchor, which signs. A safe default should not depend on how the
// process happens to be launched.
//
// Set XL1_SERVICE_HOST=0.0.0.0 to bind everything on purpose.
const HOST = process.env.XL1_SERVICE_HOST ?? '127.0.0.1'

// Required before /anchor will sign, and only meaningful when a mnemonic is
// configured: the read routes need no secret and are unaffected. Compared with
// timingSafeEqual because a plain === leaks the answer one character at a time.
const ANCHOR_TOKEN = process.env.XL1_ANCHOR_TOKEN?.trim() ?? ''
const SIGNING_CONFIGURED = Boolean(process.env.XYO_WALLET_MNEMONIC?.trim())

const tokenOk = (given: string): boolean => {
  const a = Buffer.from(given)
  const b = Buffer.from(ANCHOR_TOKEN)
  // timingSafeEqual throws on a length mismatch, which is itself a leak, so the
  // lengths are folded into the comparison rather than checked before it.
  return a.length === b.length && timingSafeEqual(a, b)
}
const DEFAULT_NETWORK = process.env.XL1_NETWORK ?? 'sequence'

// Explorer URLs come from the SDK, never string concatenation. The paths are
// the explorer's to change, and ours had already drifted: we built /tx/<hash>
// where the SDK builds /transaction/<hash>.
const EXPLORER_ORIGIN = process.env.XL1_EXPLORER_URL ?? 'https://explore.xyo.network'

// evmRpcUrl is the chain's BACKING EVM, which is where staking lives -- not
// somewhere on XL1. `chain.id` doubles as the staking contract's address there,
// so the two networks resolve to Sepolia and Ethereum mainnet respectively.
// Optional: without it /standing reports a balance and no stake, exactly as
// before, rather than failing.
interface NetCfg { rpcUrl?: string; label: string; evmRpcUrl?: string }
const NETWORKS: Record<string, NetCfg> = {
  sequence: {
    rpcUrl: process.env.XL1_SEQUENCE_RPC_URL,
    evmRpcUrl: process.env.XL1_SEQUENCE_EVM_RPC_URL,
    label: 'Sequence Testnet',
  },
  mainnet: {
    rpcUrl: process.env.XL1_MAINNET_RPC_URL,
    evmRpcUrl: process.env.XL1_MAINNET_EVM_RPC_URL,
    label: 'XL1 Mainnet',
  },
}

const explorerLinks: Record<string, ExplorerLinks> = {}

/** Link builder for one network, cached. */
const explorerFor = (network: string): ExplorerLinks => {
  // NetworkId is a branded union of the known ids. Every caller here has
  // already been checked against NETWORKS, so the id is one of them.
  explorerLinks[network] ??= new ExplorerLinks(EXPLORER_ORIGIN, network as NetworkId)
  return explorerLinks[network]
}

const gateways: Record<string, SimpleXyoGatewayRunner> = {}

const getGateway = async (network: string): Promise<SimpleXyoGatewayRunner> => {
  const cfg = NETWORKS[network]
  if (!cfg) throw new Error(`Unknown XL1 network: ${network}`)
  if (!cfg.rpcUrl) throw new Error(`RPC URL not configured for network: ${network}`)
  if (gateways[network]) return gateways[network]
  const account = await getSignerAccount()
  // 5.x: the signing identity is configured on the builder and buildRunner()
  // produces the transacting gateway. build(signer) was the 4.x shape.
  const gw = await buildGateway(network).account(account).buildRunner() as SimpleXyoGatewayRunner
  gateways[network] = gw
  return gw
}

const anchor = async (title: string, summary: string, network?: string) => {
  const net = network && NETWORKS[network] ? network : DEFAULT_NETWORK
  const cfg = NETWORKS[net]
  const gateway = await getGateway(net)

  // Off-chain payload (validated 'network.xyo.id' schema, per XYO sample); the
  // adventure record is embedded as salt. On-chain we anchor only its hash.
  const record = {
    app: 'the-living-frontier',
    title: String(title ?? '').slice(0, 160),
    summary: String(summary ?? '').slice(0, 500),
    ts: new Date().toISOString(),
  }
  const idPayload = { schema: asSchema('network.xyo.id', true), salt: JSON.stringify(record) }
  const contentHash = await PayloadBuilder.hash(idPayload)
  const hashPayload: HashPayload = { schema: HashSchema, hash: contentHash }

  const [txHash] = await gateway.addPayloadsToChain([hashPayload], [idPayload])
  await gateway.confirmSubmittedTransaction(txHash, { logger: console })

  const account = await getSignerAccount()
  return {
    txHash,
    explorerUrl: explorerFor(net).transaction(txHash),
    network: net,
    networkLabel: cfg.label,
    contentHash,
    address: account.address,
  }
}

// Read-only gateways for chain queries. Separate from the signing gateways
// above: reading block height needs no wallet, so this works even when no
// mnemonic is configured.
const readGateways: Record<string, SimpleXyoGateway> = {}

// GatewayBuilder is the canonical entry point; it hides the locator, provider
// factory and transport wiring the previous SDK made callers assemble by hand.
const buildGateway = (network: string) => {
  const cfg = NETWORKS[network]
  if (!cfg) throw new Error(`Unknown XL1 network: ${network}`)
  if (!cfg.rpcUrl) throw new Error(`RPC URL not configured for network: ${network}`)
  const builder = new GatewayBuilder().name(network).rpcUrl(cfg.rpcUrl)
  const dataLake = NetworkDataLakeUrls[network as keyof typeof NetworkDataLakeUrls]
  return dataLake ? builder.dataLakeEndpoint(dataLake) : builder
}

const getReadGateway = async (network: string): Promise<SimpleXyoGateway> => {
  if (readGateways[network]) return readGateways[network]
  const gw = await buildGateway(network).build() as SimpleXyoGateway
  readGateways[network] = gw
  return gw
}

/** The finalized head, and whether it was genuinely read.
 *
 * Falling back to latest keeps the scan working against a gateway without
 * finalization, but counting unfinalized blocks into a durable total lets a
 * reorg drift it permanently. The caller is told which it got rather than
 * having to guess, so the drift cannot happen silently.
 */
async function finalizedBound(
  // headNumber returns Promisable<XL1BlockNumber> -- a branded Number that
  // may or may not be wrapped in a promise. Typing it as Promise<unknown>
  // rejected the real viewer outright, so the parameter takes `unknown` and
  // the await below handles either form.
  viewer: { finalization?: { headNumber?: () => unknown } },
  latest: number,
): Promise<{ height: number; finalized: boolean }> {
  try {
    const raw = await viewer.finalization?.headNumber?.()
    // headNumber may hand back a bigint or a decimal string depending on
    // transport; Number.isInteger alone rejects both and would silently
    // downgrade every scan to unfinalized.
    const head = typeof raw === 'bigint' ? Number(raw) : Number(raw)
    if (Number.isFinite(head) && head > 0) return { height: head, finalized: true }
  } catch {
    // Fall through: reported, not swallowed.
  }
  return { height: latest, finalized: false }
}

// Short cache: the chain produces a block roughly every 10s, and the dashboard
// polls far more often than that across all its viewers.
const HEIGHT_CACHE_MS = 5000
const heightCache: Record<string, { value: number; at: number }> = {}

const currentBlockHeight = async (network: string): Promise<number> => {
  const cached = heightCache[network]
  const now = Date.now()
  if (cached && now - cached.at < HEIGHT_CACHE_MS) return cached.value
  const gateway = await getReadGateway(network)
  const value = await gateway.connection.viewer.block.currentBlockNumber()
  heightCache[network] = { value, at: now }
  return value
}

// Producer activity. Deliberately returns NO balance and never echoes the
// address back: this feeds a public web page, and an address is enough to look
// up a balance on any explorer. Only counts leave this endpoint.
const PRODUCER_CACHE_MS = 300_000
const producerCache: Record<string, { value: unknown; at: number }> = {}

const normalizeAddress = (value: string) => value.toLowerCase().replace(/^0x/, '')

// blocksByNumber(start, count) fetches a whole range in one RPC call, which is
// ~100x cheaper than reading blocks individually: measured 0.61 ms/block at a
// batch of 2000 against 65 ms/block one at a time.
//
// 2000 rather than 5000 deliberately -- 5000 was faster per block but spiked
// 67MB of heap, and this runs on a 3.8GB Raspberry Pi alongside a block
// producer. 2000 costs ~12MB.
const BATCH_SIZE = 2000

// Cap per request. At 0.61 ms/block this is ~30s of work, so an idle agent
// catches up quickly without issuing one unbounded burst at a public gateway.
const MAX_CATCHUP = 50_000

// The lowest block this indexer will ever read. Required, never defaulted:
// an implicit 0 means an unbounded backward walk that nobody chose. This is an
// unbounded indexer -- it counts a producer's whole history -- so 0 is the
// right value here, but it has to be stated rather than assumed.
const FLOOR_BLOCK_RAW = process.env.XL1_INDEXER_FLOOR_BLOCK

const indexerFloor = (): number | undefined => {
  if (FLOOR_BLOCK_RAW === undefined || FLOOR_BLOCK_RAW.trim() === '') return undefined
  const parsed = Number(FLOOR_BLOCK_RAW)
  if (!Number.isInteger(parsed) || parsed < 0) return undefined
  return parsed
}

// Block payloads nest: the top-level bound witness sits beside an ARRAY of
// the payloads it witnesses, and the transfers are in there. A shallow read
// finds the bound witness and silently misses every mint, which is the kind of
// bug that shows as "earned nothing" rather than as an error.
const flattenPayloads = (x: unknown): unknown[] => (Array.isArray(x) ? x.flatMap(flattenPayloads) : [x])

// Rewards are minted: they arrive in a transfer whose `from` is the zero
// address, which no ordinary transfer does.
const MINT_FROM = '0'.repeat(40)
const STEP_REWARD_ADDR = String(XYO_STEP_REWARD_ADDRESS).replace(/^0x/i, '').toLowerCase()

/** Atto minted TO `target` in one block, excluding the protocol's own cut. */
const mintedToInBlock = (parts: unknown[], target: string): bigint => {
  let total = 0n
  for (const part of parts) {
    const p = part as { schema?: string, from?: string, transfers?: Record<string, string> }
    if (p?.schema !== 'network.xyo.transfer') continue
    if (String(p.from ?? '').replace(/^0x/i, '').toLowerCase() !== MINT_FROM) continue
    for (const [addr, hex] of Object.entries(p.transfers ?? {})) {
      const to = addr.replace(/^0x/i, '').toLowerCase()
      if (to === STEP_REWARD_ADDR || to !== target) continue
      total += BigInt('0x' + String(hex).replace(/^0x/i, ''))
    }
  }
  return total
}

const producerStats = async (
  network: string, address: string, window: number, since?: number,
  range?: { from: number; to: number }, floor = 0,
) => {
  const key = `${network}:${normalizeAddress(address)}:${window}:`
    + (range ? `r${range.from}-${range.to}` : (since ?? 'window'))
  const cached = producerCache[key]
  const now = Date.now()
  if (cached && now - cached.at < PRODUCER_CACHE_MS) return cached.value

  const gateway = await getReadGateway(network)
  const viewer = gateway.connection.viewer

  // Count against the FINALIZED head, not the latest block. produced_total is
  // durable derived state meant to hold for years: a block counted before it
  // finalizes can be reorged away, and the cursor never returns to correct it,
  // so the total would drift permanently with nothing to detect it.
  //
  // The cost is latency -- a block is counted slightly later. The benefit is
  // that the number cannot silently become wrong.
  const latest = await viewer.block.currentBlockNumber()
  const bound = await finalizedBound(viewer, latest)
  const height = bound.height
  const target = normalizeAddress(address)

  // Two modes. With `since` we scan only what is new, which is ~15 blocks per
  // 15 minutes at a 60s block time -- far cheaper than re-reading a window
  // every cycle, and it accumulates into a lifetime total. Without it we read
  // a trailing window, used to seed the first run.
  const explicit = range !== undefined
  const incremental = !explicit && since !== undefined && Number.isFinite(since)
  let fromBlock: number
  let toBlock: number
  if (explicit) {
    // Backfill walks downward toward the floor; the caller names the range.
    fromBlock = Math.max(floor, range.from)
    toBlock = Math.min(height, range.to)
    if (toBlock - fromBlock + 1 > MAX_CATCHUP) fromBlock = toBlock - MAX_CATCHUP + 1
  } else if (incremental) {
    fromBlock = Math.max(floor, (since as number) + 1)
    toBlock = Math.min(height, (since as number) + MAX_CATCHUP)
  } else {
    fromBlock = Math.max(floor, height - window + 1)
    toBlock = height
  }

  let produced = 0
  let inspected = 0
  let lastProducedBlock: number | undefined
  let latestEpoch: number | undefined
  // Earnings per UTC day, in atto. Kept as bigint through the scan because a
  // month of rewards summed as floats drifts, and this is the figure the panel
  // reports as money.
  const mintedByDay = new Map<string, bigint>()
  let mintedTotal = 0n

  // Fetch in batches rather than block by block. Each batch is processed and
  // released before the next is requested, so peak memory stays flat however
  // large the range is.
  //
  // blocksByNumber(start, count) returns count blocks DESCENDING from start,
  // i.e. [start, start-1, ... start-count+1]. Walking the range downward from
  // the top matches that, and is the direction backfill wants anyway.
  for (let top = toBlock; top >= fromBlock; top -= BATCH_SIZE) {
    const count = Math.min(BATCH_SIZE, top - fromBlock + 1)
    // Block numbers are branded; toXL1BlockNumber validates and brands in one
    // step rather than casting the brand away.
    const batch = await viewer.block.blocksByNumber(toXL1BlockNumber(top, { name: 'scan start block' }), count)
    for (const blk of (Array.isArray(batch) ? batch : [batch])) {
      const parts = Array.isArray(blk) ? blk : [blk]
      const bw = parts.find((p: { schema?: string }) => p?.schema === 'network.xyo.boundwitness') as
        { addresses?: string[]; $epoch?: number; block?: number } | undefined
      if (!bw) continue

      // Mints are nested below the top level, so this needs the deep read that
      // finding the bound witness does not.
      if (typeof bw.$epoch === 'number') {
        const wei = mintedToInBlock(flattenPayloads(blk), target)
        if (wei > 0n) {
          const day = new Date(bw.$epoch).toISOString().slice(0, 10)
          mintedByDay.set(day, (mintedByDay.get(day) ?? 0n) + wei)
          mintedTotal += wei
        }
      }
      inspected++
      // Read the height from the block itself rather than inferring it from
      // position, so a short or reordered batch cannot misattribute a block.
      const blockNumber = typeof bw.block === 'number' ? bw.block : undefined
      if (blockNumber !== undefined && blockNumber >= toBlock && typeof bw.$epoch === 'number') {
        latestEpoch = bw.$epoch
      }
      if ((bw.addresses ?? []).map(normalizeAddress).includes(target)) {
        produced++
        if (blockNumber !== undefined
            && (lastProducedBlock === undefined || blockNumber > lastProducedBlock)) {
          lastProducedBlock = blockNumber
        }
      }
    }
  }

  let pendingTransactions: number | undefined
  let pendingBlocks: number | undefined
  try {
    pendingTransactions = (await viewer.mempool.pendingTransactions())?.length
    pendingBlocks = (await viewer.mempool.pendingBlocks())?.length
  } catch {
    // Mempool is optional context; its absence must not fail the request.
  }

  const value = {
    network, height, latest, floor,
    // Whether the bound above is genuinely the finalized head. Previously
    // inferred from height !== latest, which reads false whenever the
    // finalized head legitimately equals latest -- ambiguous in exactly the
    // case a consumer needs to distinguish.
    finalized: bound.finalized,
    mode: explicit ? 'range' : (incremental ? 'incremental' : 'window'),
    fromBlock, toBlock, inspected, produced,
    caughtUp: toBlock >= height,
    lastProducedBlock,
    blocksSinceProduced: lastProducedBlock === undefined ? undefined : height - lastProducedBlock,
    latestEpoch, pendingTransactions, pendingBlocks,
    // What this address was actually MINTED over the scanned range, by UTC day.
    // Atto as strings: these are summed into a lifetime total, and a float
    // cannot hold 1e22 without losing the low digits.
    //
    // Reported for the range the caller asked for, so it inherits the
    // consume-once discipline the block count already has -- the backend
    // accepts a range once and only as an exact continuation of its cursor.
    mintedByDay: Object.fromEntries([...mintedByDay].map(([d, w]) => [d, w.toString()])),
    mintedTotalRaw: mintedTotal.toString(),
    explorer: {
      network: explorerFor(network).network(),
      lastProducedBlock: lastProducedBlock === undefined
        ? undefined
        : explorerFor(network).blockByNumber(lastProducedBlock),
    },
    at: new Date().toISOString(),
  }
  producerCache[key] = { value, at: now }
  return value
}

const app = express()
app.use(express.json({ limit: '256kb' }))

// Liveness for the read path, which is all this deployment has. It must NOT
// require a signer: the Pi runs this with no mnemonic on purpose, so a health
// check that derived an account reported 500 forever on a perfectly healthy
// container. Nothing consumed it, which is why that went unnoticed -- wire a
// supervisor to it and it would have restarted a working service in a loop.
app.get('/health', async (_req, res) => {
  try {
    // getReadGateway, not getGateway: the latter derives a signer.
    const { connection: { viewer } } = await getReadGateway(DEFAULT_NETWORK)
    const latest = await viewer.block.currentBlockNumber()
    const bound = await finalizedBound(viewer, latest)
    res.json({
      ok: true,
      network: DEFAULT_NETWORK,
      latest,
      finalizedHead: bound.finalized ? bound.height : undefined,
      // A gateway without finalization still serves reads, but durable totals
      // counted against it can drift on a reorg. Surfaced, never inferred.
      finalization: bound.finalized,
      floor: indexerFloor(),
      // Signing is a separate capability, absent here by design. Reported
      // from the environment rather than by deriving an account, so asking
      // whether this service can sign never requires that it can.
      signing: Boolean(process.env.XYO_WALLET_MNEMONIC?.trim()),
    })
  } catch (e) {
    res.status(503).json({ ok: false, error: e instanceof Error ? e.message : String(e) })
  }
})

// Current chain height. Read through the SDK viewer -- never raw JSON-RPC.
/** Native token decimals. The CLI uses `DECIMALS = 10n ** 18n`. */
const XL1_DECIMALS = 18n
// The asset the chain's native balance is denominated in. Reported rather than
// assumed by the dashboard: neither the SDK nor the explorer exposes a ticker,
// and a number on an operator panel with no unit beside it is not a balance,
// it is a number.
const XL1_SYMBOL = 'XL1'

/** The producer's balance, or null if this gateway will not answer.
 *
 * Read defensively for the same reason finalizedBound is: the viewer surface
 * is not typed here, and a shape change should degrade to "unknown" rather
 * than take out an endpoint the monitoring depends on.
 */
async function accountBalance(
  viewer: { accountBalance?: (address: string) => unknown },
  address: string,
): Promise<bigint | null> {
  try {
    const raw = await viewer.accountBalance?.(address)
    if (typeof raw === 'bigint') return raw
    if (typeof raw === 'number' || typeof raw === 'string') return BigInt(raw)
  } catch { /* fall through to null */ }
  return null
}

/**
 * Whether this producer is *able* to produce, as distinct from whether it is
 * producing.
 *
 * The node gates redeclaring its intent on validateCurrentBalance(): a balance
 * of zero stops the redeclaration, which stops it being scheduled, which stops
 * blocks -- while the container stays up and healthy the whole time. Watching
 * output alone cannot distinguish that from a quiet slot.
 *
 * Stake is the other half of the gate and is deliberately absent here. The
 * producer reads it through ChainContractViewer, which this repo's role preset
 * binds to `default-evm-rpc` -- it lives on the EVM chain, not on XL1, and the
 * XL1 gateway returns an empty list for it. Reporting that empty list as "no
 * stake" would be a false alarm about the most alarming thing there is.
 */
// Stake, read from the backing EVM.
//
// It is not on XL1 and the XL1 gateway cannot answer for it: GatewayBuilder
// configures the XL1 transport and the data lake, and the SDK's stake viewers
// bind to an EVM connection that a client builder never sees. Reading the
// contract is therefore the available path, and the correct one -- this is a
// real EVM contract on a real EVM chain, not XL1 being treated as one.
//
// The contract address is not hardcoded. `chain.id` IS the staking contract on
// the backing EVM, so it comes from the SDK's own network bootstrap and cannot
// drift from whatever the SDK believes the network to be.
const STAKE_CONTRACTS: Record<string, string> = {
  [SequenceNetwork.id]: SequenceNetwork.chain,
  [MainNetwork.id]: MainNetwork.chain,
}

// Selectors are the first four bytes of keccak256(signature). Written out
// rather than derived so this needs no hashing dependency; each was verified
// against the deployed contract before being pinned here.
const STAKE_SELECTORS = {
  activeByAddressStaked: '0x424d2b8c', // activeByAddressStaked(address)
  minStake: '0x375b3c0a',              // minStake()
} as const
// No pending figure: pendingFor(address) reverts on this contract. It appears
// in the SDK's bundled ABIs, which cover several contracts, so being in the ABI
// is not evidence of being on THIS one -- each selector here was called against
// the deployed contract before being kept.

const evmCall = async (url: string, to: string, data: string): Promise<bigint | null> => {
  const body = JSON.stringify({
    jsonrpc: '2.0', id: 1, method: 'eth_call',
    params: [{ to, data }, 'latest'],
  })
  const resp = await fetch(url, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body,
    signal: AbortSignal.timeout(15_000),
  })
  if (!resp.ok) return null
  const json = await resp.json() as { result?: string, error?: unknown }
  if (json.error || typeof json.result !== 'string' || json.result === '0x') return null
  return BigInt(json.result)
}

/**
 * Stake held against a producer address, or null when it cannot be read.
 *
 * Null rather than zero on every failure path. Zero stake is a claim with
 * consequences -- it is the thing that stops a producer being scheduled -- and
 * an unreachable RPC must never be reported as it.
 */
const readStake = async (network: string, address: string) => {
  const rpc = NETWORKS[network]?.evmRpcUrl
  const contract = STAKE_CONTRACTS[network]
  if (!rpc || !contract) return null
  const to = contract.startsWith('0x') ? contract : `0x${contract}`
  const padded = address.replace(/^0x/i, '').toLowerCase().padStart(64, '0')
  try {
    const [active, minimum] = await Promise.all([
      evmCall(rpc, to, STAKE_SELECTORS.activeByAddressStaked + padded),
      evmCall(rpc, to, STAKE_SELECTORS.minStake),
    ])
    if (active === null) return null
    return {
      contract: to,
      activeRaw: active.toString(),
      // Reported raw, and compared raw. The contract returns small round
      // numbers for minStake (1 on sequence) while balances are 18-decimal, so
      // which unit the minimum is denominated in is genuinely unclear from the
      // ABI alone. Both values are published so a reader can judge; the
      // comparison assumes they share units, which is the natural reading and
      // is unambiguous at zero either way.
      minStakeRaw: minimum === null ? null : minimum.toString(),
      meetsMinimum: minimum === null ? null : active >= minimum,
    }
  } catch {
    return null
  }
}

app.get('/standing', async (req, res) => {
  const address = typeof req.query.address === 'string' ? req.query.address : ''
  // Case-insensitive prefix: 0X is as valid a hex marker as 0x, and rejecting
  // it would be a 422 on an address that is perfectly well formed.
  if (!/^(0x)?[0-9a-fA-F]{40}$/i.test(address)) {
    return res.status(422).json({ error: 'valid 20-byte address required' })
  }
  const network = typeof req.query.network === 'string' ? req.query.network : DEFAULT_NETWORK
  try {
    const { connection: { viewer } } = await getReadGateway(network)
    // Strip the 0x. The regex above accepts either form, and the agent reads
    // this address out of the node's own environment, where it carries the
    // prefix -- while the viewer answers null for a prefixed address instead
    // of throwing. Passing it through unchanged produced a null balance that
    // looked exactly like a gateway that would not answer.
    const raw = await accountBalance(viewer as never, address.replace(/^0x/i, ''))
    const unit = 10n ** XL1_DECIMALS
    res.json({
      network,
      address,
      // Raw as a string: 23603033681900000000000 exceeds what JSON numbers
      // hold exactly, and a balance that gates eligibility should not be
      // rounded on the way to a dashboard.
      balanceRaw: raw === null ? null : raw.toString(),
      balance: raw === null ? null : Number(raw) / Number(unit),
      // Named for what it measures, which is a balance above zero -- the gate
      // the node applies before it will redeclare its intent.
      //
      // It is NOT eligibility, and the difference is about to matter.
      // isProducerEligible in the SDK wants a live intent declaration, seasoned
      // stake at or above minStake, and seasoned self-bond at or above
      // minSelfBond. Only the intent half exists on sequence today --
      // stakesByStaked answers empty for every producer -- so a positive
      // balance currently coincides with being schedulable and will stop
      // coinciding without warning.
      fundedForProduction: raw === null ? null : raw > 0n,
      decimals: Number(XL1_DECIMALS),
      symbol: XL1_SYMBOL,
      // Read from the backing EVM when one is configured; null when it is
      // not, or when the read failed. Never zero on failure -- see readStake.
      stake: await readStake(network, address),
      at: new Date().toISOString(),
    })
  } catch (e) {
    res.status(502).json({ error: e instanceof Error ? e.message : String(e) })
  }
})

// What this address EARNED by producing, as distinct from what it holds.
//
// /standing reports the balance, and the panel derived earnings from the
// day-over-day change in it. That answers "what reached the account", which is
// not the same question: money sent in to fund the node, and any transfer out,
// move the balance exactly as a block reward does.
//
// Rewards are minted -- they arrive in a network.xyo.transfer whose `from` is
// the zero address, which no ordinary transfer does -- and every mint is split
// between XYO_STEP_REWARD_ADDRESS and the producer. The producer share is a
// fixed amount, so a balance built only from rewards is an exact multiple of
// it. Dividing gives the blocks rewarded and the earnings; the remainder is
// everything that cannot be a reward.
//
// Two gateway calls, so it is cheap enough to sit behind the agent slow
// cadence. It needs no block count from us and no chain scan: the balance
// carries the whole history, which is what makes this a LIFETIME figure rather
// than one starting the day monitoring did.
//
// The reward is measured from the chain and cross-checked against the SDK own
// schedule (SimpleBlockRewardViewer.allowedRewardForBlock, which the gateway
// does not implement, so it is built here from the published constants). The
// chain wins where they differ, being what was actually paid, but the
// disagreement is reported: schedule and chain DO diverge historically, and
// the day that starts happening at the head is a day to look rather than to
// keep serving a number.
const rewardViewerFor = async (network: string) => {
  const gateway = await getReadGateway(network)
  // The schedule constants are baked into this class in xl1-sdk 5.x, so it
  // takes the context and nothing else. Verified against the same call in
  // xl1-protocol-sdk, which does accept them explicitly: both answer 500 XL1
  // below block 1000000 and 428.6875 at 3000000.
  //
  // The cast is for a gap in the SDK types, not a guess: XyoConnection does
  // not declare `context` although every connection carries one, and this is
  // the only handle a provider can be created from.
  const context = (gateway.connection as unknown as { context: never }).context
  return SimpleBlockRewardViewer.create({ context })
}

// Atto to a display float, without losing the low digits.
//
// Number(wei) / Number(unit) looks equivalent and is not: 37950 XL1 is 3.795e22
// atto, past the 2^53 where a double stops counting integers exactly, and it
// came out as 37949.99999999999. Scaling by the wanted precision FIRST keeps
// the division inside bigint and lands the result well under that ceiling.
// The raw string is still the authority; this is the convenience beside it.
const XL1_PLACES = 1000000000n
const toXL1 = (wei: bigint): number => Number((wei * XL1_PLACES) / (10n ** XL1_DECIMALS)) / Number(XL1_PLACES)

/** What a block minted, split into the protocol cut and the producer cut.
 *
 * The producer share is identified by excluding the step reward address rather
 * than by taking the smaller credit: the split has been 5% and is now 10%, and
 * nothing guarantees the producer half stays the smaller one.
 */
const mintedAt = async (
  viewer: { block?: { blocksByNumber?: (h: number, n: number) => unknown } },
  height: number,
): Promise<{ toStep: bigint, toProducer: bigint, total: bigint } | null> => {
  try {
    const batch = await viewer.block?.blocksByNumber?.(height, 1)
    let toStep = 0n
    let toProducer = 0n
    let found = false
    for (const part of flattenPayloads(batch)) {
      const p = part as { schema?: string, from?: string, transfers?: Record<string, string> }
      if (p?.schema !== 'network.xyo.transfer') continue
      if (String(p.from ?? '').replace(/^0x/i, '').toLowerCase() !== MINT_FROM) continue
      for (const [addr, hex] of Object.entries(p.transfers ?? {})) {
        found = true
        const wei = BigInt('0x' + String(hex).replace(/^0x/i, ''))
        if (addr.replace(/^0x/i, '').toLowerCase() === STEP_REWARD_ADDR) toStep += wei
        else toProducer += wei
      }
    }
    return found ? { toStep, toProducer, total: toStep + toProducer } : null
  } catch { return null }
}

app.get('/earnings', async (req, res) => {
  const address = typeof req.query.address === 'string' ? req.query.address : ''
  if (!/^(0x)?[0-9a-fA-F]{40}$/i.test(address)) {
    return res.status(422).json({ error: 'valid 20-byte address required' })
  }
  const network = typeof req.query.network === 'string' ? req.query.network : DEFAULT_NETWORK
  try {
    const { connection: { viewer } } = await getReadGateway(network)
    const bare = address.replace(/^0x/i, '')
    const height = await currentBlockHeight(network)
    const minted = await mintedAt(viewer as never, height)
    const balance = await accountBalance(viewer as never, bare)
    if (minted === null || minted.toProducer === 0n || balance === null) {
      // Not an error. A reader that cannot answer says so rather than serving
      // a figure it guessed at; the agent reports it as a degraded reader.
      return res.json({
        network,
        address,
        height,
        earned: null,
        rewardPerBlock: null,
        at: new Date().toISOString(),
      })
    }
    const reward = minted.toProducer
    const rewarded = balance / reward
    const remainder = balance % reward

    let sdkTotal: bigint | null = null
    try {
      const rv = await rewardViewerFor(network)
      sdkTotal = BigInt((await rv.allowedRewardForBlock(toXL1BlockNumber(height))).toString())
    } catch { sdkTotal = null }
    const SCALE = 1000000n
    const sdkProducer = sdkTotal === null
      ? null
      : (sdkTotal * BigInt(Math.round(defaultRewardRatio * Number(SCALE)))) / SCALE

    res.json({
      network,
      address,
      height,
      // Raw strings beside the floats for the reason /standing carries them:
      // these exceed exact JSON number range, and a figure the operator
      // reconciles against the chain should not be rounded on the way out.
      rewardPerBlock: toXL1(reward),
      rewardPerBlockRaw: reward.toString(),
      blockMintTotal: toXL1(minted.total),
      blocksRewarded: Number(rewarded),
      earned: toXL1(rewarded * reward),
      earnedRaw: (rewarded * reward).toString(),
      // Everything in the balance that cannot be a whole block reward: fee
      // shares, and anything sent to this account. A ceiling on "not earned".
      nonReward: toXL1(remainder),
      nonRewardRaw: remainder.toString(),
      balance: toXL1(balance),
      balanceRaw: balance.toString(),
      sdkRewardPerBlock: sdkProducer === null ? null : toXL1(sdkProducer),
      sdkAgrees: sdkProducer === null ? null : sdkProducer === reward,
      decimals: Number(XL1_DECIMALS),
      symbol: XL1_SYMBOL,
      at: new Date().toISOString(),
    })
  } catch (e) {
    res.status(502).json({ error: e instanceof Error ? e.message : String(e) })
  }
})

// Which @xyo-network packages this process actually loaded.
//
// The node container reports its CLI version and the panel flags a mismatch;
// nothing did the same for the SDK this service reads the chain with, and that
// is the more consequential of the two. This service decodes blocks, payloads
// and mint transfers -- a protocol change met by a library too old to
// understand it does not raise an error, it returns a plausible wrong number
// onto an earnings panel.
//
// Reported over HTTP rather than read by `docker exec` from the agent. The
// agent deliberately kept exec down to a single call because exec is what
// makes Docker socket access dangerous, and a version string is not worth
// spending that on. A process is also the authority on what it actually
// resolved at runtime, which is not always what package.json asked for.
const VERSIONED_PACKAGES = [
  '@xyo-network/xl1-sdk',
  '@xyo-network/xl1-protocol',
  '@xyo-network/payload-builder',
  '@xyo-network/payload-model',
] as const

const requirePackage = createRequire(import.meta.url)

const packageVersion = (name: string): string | undefined => {
  // Exported subpath first; many packages publish ./package.json, and this
  // resolves through whatever the loader actually used.
  try {
    return requirePackage(`${name}/package.json`).version as string
  } catch {
    // Packages with a restrictive "exports" map refuse the subpath. Fall back
    // to the install layout, which is where pnpm links them under WORKDIR.
    try {
      const raw = readFileSync(join(process.cwd(), 'node_modules', name, 'package.json'), 'utf8')
      return JSON.parse(raw).version as string
    } catch {
      return undefined
    }
  }
}

app.get('/versions', (_req, res) => {
  const packages: Record<string, string> = {}
  for (const name of VERSIONED_PACKAGES) {
    const v = packageVersion(name)
    // Omitted rather than nulled: absent means "could not be established",
    // and a null in a version field reads like a version.
    if (v) packages[name] = v
  }
  res.json({ packages, node: process.versions.node })
})

app.get('/block-height', async (req, res) => {
  const network = typeof req.query.network === 'string' ? req.query.network : DEFAULT_NETWORK
  try {
    const height = await currentBlockHeight(network)
    const cfg = NETWORKS[network]
    res.json({
      network, networkLabel: cfg?.label ?? network, height, at: new Date().toISOString(),
    })
  } catch (e) {
    res.status(502).json({ error: e instanceof Error ? e.message : String(e) })
  }
})

// Explorer link for a block number, built by the SDK.
//
// The producer scan reports a link only for blocks it actually saw, which is
// no use once a node stops producing: the panel keeps showing the last block
// from months ago and the scan never sees it again. The caller asks for the
// block it is displaying instead.
app.get('/explorer/block/:number', (req, res) => {
  const network = typeof req.query.network === 'string' ? req.query.network : DEFAULT_NETWORK
  if (!NETWORKS[network]) return res.status(422).json({ error: 'unknown network' })
  const block = Number(req.params.number)
  if (!Number.isInteger(block) || block < 0) {
    return res.status(422).json({ error: 'block number required' })
  }
  res.json({ network, block, url: explorerFor(network).blockByNumber(block) })
})

// Producer activity for one address. Counts only -- no balance, no echo of
// the address, because the response reaches a public page.
// Peer context. A block count alone cannot tell you whether a quiet day is
// your fault: the same number means "healthy" against three other producers
// and "broken" against ten. What makes it readable is your share of the field
// and whether that share moved.
//
// Balances are returned too, but deliberately NOT as a predicted share.
// Measured over 1000 blocks on 2026-08-27:
//
//   280419 -> 316 blocks    138444 -> 221 blocks
//   280410 -> 316 blocks     27053 -> 147 blocks
//
// A 10.4x spread in balance produces a 2.15x spread in blocks, so scheduling
// is far flatter than stake-weighting would give. An earlier 40-block sample
// looked proportional and was noise. Whatever the real weighting is, it is not
// this, and a tile reporting "expected share" from balance would be inventing
// a model rather than measuring one. The share and the field are measured; the
// prediction is left out.
//
// One RPC call. blocksByNumber batches to 2000, so a 1000-block window (about
// five hours at the current rate) is a single request plus one balance lookup
// per producer found.
const peerCache: Record<string, { value: unknown; at: number }> = {}
const PEER_CACHE_MS = 10 * 60 * 1000

app.get('/peers', async (req, res) => {
  const network = typeof req.query.network === 'string' ? req.query.network : DEFAULT_NETWORK
  const requested = Number(req.query.window)
  const window = Math.min(2000, Math.max(50, Number.isFinite(requested) ? requested : 1000))
  const key = `${network}:${window}`

  const cached = peerCache[key]
  if (cached && Date.now() - cached.at < PEER_CACHE_MS) return res.json(cached.value)

  try {
    const { connection: { viewer } } = await getReadGateway(network)
    const head = Number(await viewer.block.currentBlockNumber())
    const count = Math.min(window, head + 1)
    const batch = await viewer.block.blocksByNumber(
      toXL1BlockNumber(head, { name: 'peer scan start block' }), count)

    const blocks: Record<string, number> = {}
    let inspected = 0
    for (const blk of (Array.isArray(batch) ? batch : [batch])) {
      const parts = Array.isArray(blk) ? blk : [blk]
      const bw = parts.find((p: { schema?: string }) => p?.schema === 'network.xyo.boundwitness') as
        { addresses?: string[] } | undefined
      if (!bw) continue
      inspected++
      // A block can carry several signers; each is credited once per block.
      for (const a of new Set((bw.addresses ?? []).map(normalizeAddress))) {
        blocks[a] = (blocks[a] ?? 0) + 1
      }
    }

    // Balances decide the expected share, so they are read for every producer
    // found rather than only for ours -- a share is meaningless without the
    // denominator.
    const producers = await Promise.all(Object.entries(blocks).map(async ([address, n]) => {
      let balance: number | null = null
      try {
        const raw = await accountBalance(viewer as never, address)
        balance = raw === null ? null : Number(raw) / Number(10n ** XL1_DECIMALS)
      } catch { /* one unreadable balance must not lose the whole answer */ }
      return { address, blocks: n, balance }
    }))
    producers.sort((a, b) => b.blocks - a.blocks)

    const value = {
      network,
      window: count,
      blocksInspected: inspected,
      head,
      producers,
      totalBlocks: producers.reduce((t, p) => t + p.blocks, 0),
      // Null balances are excluded rather than counted as zero, which would
      // inflate everyone else's expected share.
      totalBalance: producers.reduce((t, p) => t + (p.balance ?? 0), 0),
      balancesRead: producers.filter((p) => p.balance !== null).length,
      at: new Date().toISOString(),
    }
    peerCache[key] = { value, at: Date.now() }
    res.json(value)
  } catch (e) {
    res.status(502).json({ error: e instanceof Error ? e.message : String(e) })
  }
})

app.get('/producer', async (req, res) => {
  const address = typeof req.query.address === 'string' ? req.query.address : ''
  if (!/^(0x)?[0-9a-fA-F]{40}$/.test(address)) {
    return res.status(422).json({ error: 'valid 20-byte address required' })
  }
  const network = typeof req.query.network === 'string' ? req.query.network : DEFAULT_NETWORK
  const requested = Number(req.query.window)
  // Seed window, used only on the first run. Sized for a small share: a node
  // taking 2% of blocks would most likely show zero across 20, which reads as
  // broken rather than quiet.
  const window = Math.min(500, Math.max(1, Number.isFinite(requested) ? requested : 200))
  const sinceRaw = Number(req.query.since)
  const since = Number.isFinite(sinceRaw) && sinceRaw >= 0 ? Math.floor(sinceRaw) : undefined

  const fromRaw = Number(req.query.from)
  const toRaw = Number(req.query.to)
  const hasRange = Number.isFinite(fromRaw) && Number.isFinite(toRaw)
  if (hasRange && toRaw < fromRaw) {
    return res.status(422).json({ error: 'to must be >= from' })
  }
  const range = hasRange
    ? { from: Math.max(0, Math.floor(fromRaw)), to: Math.floor(toRaw) }
    : undefined

  // Fail closed rather than walking to an implicit 0 nobody chose.
  const floor = indexerFloor()
  if (floor === undefined) {
    return res.status(503).json({
      error: 'XL1_INDEXER_FLOOR_BLOCK is not set. This indexer is unbounded, so '
        + 'set it to 0 explicitly; it is never defaulted.',
    })
  }
  try {
    res.json(await producerStats(network, address, window, since, range, floor))
  } catch (e) {
    res.status(502).json({ error: e instanceof Error ? e.message : String(e) })
  }
})

// Compute the canonical XYO hash of a payload (no wallet/signer needed).
app.post('/hash', async (req, res) => {
  try {
    const payload = (req.body ?? {}).payload
    if (!payload || typeof payload !== 'object') {
      return res.status(422).json({ error: 'payload object required' })
    }
    const hash = await PayloadBuilder.hash(payload)
    res.json({ hash })
  } catch (e) {
    res.status(502).json({ error: e instanceof Error ? e.message : String(e) })
  }
})

/**
 * Attest this node's own readings to the chain.
 *
 * The public card can already point at blocks this producer signed, because
 * those are on chain and a stranger can check them. The hardware readings
 * cannot be checked by anyone: CPU, temperature and memory are the machine
 * describing itself, and nothing stops that description being edited later.
 *
 * Anchoring fixes the second half. Only a hash goes on chain, so no telemetry
 * is published by anchoring it, but the reading becomes tamper-evident: change
 * one digit afterwards and the hash no longer matches what the chain recorded
 * at that time.
 *
 * The hash is deliberately something anyone can reproduce. PayloadBuilder.hash
 * is sha256 over canonical JSON with sorted keys -- verified, not assumed --
 * so a sceptic needs sha256 and a JSON serialiser, not the XYO SDK:
 *
 *   echo -n '<payload>' | sha256sum
 *
 * `payload` is returned verbatim for exactly that reason. A verifier must hash
 * the bytes that were hashed here, not a re-serialisation of them, and the
 * difference is invisible until a key order or a float format disagrees.
 */
// Where an anchored attestation is written before the caller is answered.
//
// The anchor happens here, but until now only the caller persisted, and the
// payload existed solely in the HTTP response. A response lost to a broken
// pipe, a timeout or a restart mid-request therefore spent gas and destroyed
// the only copy of what the transaction committed to -- twice, in practice.
// The chain keeps a hash and the gateway will not serve the payload back, so
// nothing can reconstruct it afterwards.
//
// The party that anchors is the party that must not lose it. Empty by default;
// point it at a mounted directory to enable, or the archive lives inside the
// container and dies with it.
const ATTEST_ARCHIVE = process.env.XL1_ATTEST_ARCHIVE ?? ''

/** Keep a copy on disk. Never throws: the anchor already happened. */
const archiveAttestation = (record: Record<string, unknown>, contentHash: string) => {
  if (!ATTEST_ARCHIVE) return
  try {
    mkdirSync(ATTEST_ARCHIVE, { recursive: true })
    writeFileSync(`${ATTEST_ARCHIVE}/${contentHash}.json`,
                  JSON.stringify(record), { encoding: 'utf8', mode: 0o644 })
  } catch (e) {
    // Loud, because this is the copy that exists precisely for when the other
    // one does not. The anchor is already on chain either way.
    console.error('[xl1] ANCHORED BUT NOT ARCHIVED:', contentHash,
                  e instanceof Error ? e.message : String(e))
  }
}

const buildAttestation = (body: Record<string, unknown>, net: string) => {
  const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null)
  const str = (v: unknown, max: number) => (typeof v === 'string' ? v.slice(0, max) : null)
  // Fixed shape and fixed key order. Sorted-key canonicalisation makes literal
  // order irrelevant to the hash, but a stable shape keeps the published
  // payload readable by a human deciding whether to trust it.
  const record = {
    app: 'xl1-node-attestation',
    v: 1,
    network: net,
    producer: str(body.producer, 42),
    observedAt: str(body.observedAt, 40) ?? new Date().toISOString(),
    // No producedTotal: that figure is accumulated by the receiving end over
    // time, not observed here, and an attestation carrying it would be this
    // node vouching for arithmetic done elsewhere.
    chain: {
      height: num(body.height),
      lastProducedBlock: num(body.lastProducedBlock),
    },
    // The half that is otherwise unverifiable, which is the reason this exists.
    machine: {
      cpuPercent: num(body.cpuPercent),
      memUsedMb: num(body.memUsedMb),
      temperatureC: num(body.temperatureC),
      uptimeSeconds: num(body.uptimeSeconds),
    },
  }
  const idPayload = { schema: asSchema('network.xyo.id', true), salt: JSON.stringify(record) }
  return { record, idPayload }
}

app.post('/attest', async (req, res) => {
  if (SIGNING_CONFIGURED) {
    if (!ANCHOR_TOKEN) {
      return res.status(503).json({
        error: 'Signing is configured but unprotected. Set XL1_ANCHOR_TOKEN to enable /attest.',
      })
    }
    if (!tokenOk(String(req.get('x-anchor-token') ?? ''))) {
      return res.status(401).json({ error: 'invalid anchor token' })
    }
  }
  const body = (req.body ?? {}) as Record<string, unknown>
  const net = typeof body.network === 'string' && NETWORKS[body.network]
    ? body.network : DEFAULT_NETWORK
  const { record, idPayload } = buildAttestation(body, net)
  try {
    const contentHash = await PayloadBuilder.hash(idPayload)
    // Without a key this still answers, and answering is the point: the hash
    // and the payload are the whole of what a verifier checks, so the format
    // can be exercised, published and reviewed before anything is signed or
    // any gas is spent. `anchored` says plainly which of the two happened.
    if (!SIGNING_CONFIGURED) {
      return res.json({
        anchored: false,
        reason: 'no signing key configured; payload and hash only',
        network: net, contentHash, record, payload: idPayload,
      })
    }
    const gateway = await getGateway(net)
    const hashPayload: HashPayload = { schema: HashSchema, hash: contentHash }
    const [txHash] = await gateway.addPayloadsToChain([hashPayload], [idPayload])
    await gateway.confirmSubmittedTransaction(txHash, { logger: console })
    const account = await getSignerAccount()
    const answer = {
      anchored: true,
      network: net, contentHash, record, payload: idPayload,
      txHash,
      explorerUrl: explorerFor(net).transaction(txHash),
      attestedBy: account.address,
    }
    // Archived before the caller is answered, deliberately. Everything after
    // this point can fail -- the connection, the caller, the process -- and the
    // payload still exists somewhere other than in a response nobody received.
    archiveAttestation(answer, contentHash)
    res.json(answer)
  } catch (e) {
    console.error('[xl1] attest failed:', e)
    res.status(502).json({ error: e instanceof Error ? e.message : String(e) })
  }
})

app.post('/anchor', async (req, res) => {
  // Signing is the one thing here that spends something. A read route giving
  // away chain data that is already public is a different proposition from a
  // route that will put this wallet's name on anything it is handed.
  if (SIGNING_CONFIGURED) {
    if (!ANCHOR_TOKEN) {
      console.error('[xl1] refusing to anchor: XYO_WALLET_MNEMONIC is set but XL1_ANCHOR_TOKEN is not')
      return res.status(503).json({
        error: 'Signing is configured but unprotected. Set XL1_ANCHOR_TOKEN to enable /anchor.',
      })
    }
    const given = String(req.get('x-anchor-token') ?? '')
    if (!tokenOk(given)) return res.status(401).json({ error: 'invalid anchor token' })
  }
  const { title, summary, network } = (req.body ?? {}) as { title?: string; summary?: string; network?: string }
  try {
    const result = await anchor(title ?? '', summary ?? '', network)
    res.json(result)
  } catch (e) {
    console.error('[xl1] anchor failed:', e)
    res.status(502).json({ error: e instanceof Error ? e.message : String(e) })
  }
})

app.listen(PORT, HOST, () => {
  console.log(`[xl1] anchor service on ${HOST}:${PORT} (default network: ${DEFAULT_NETWORK})`)
  if (HOST === '0.0.0.0') {
    console.warn('[xl1] listening on every interface — reachable from your network')
  }
  if (SIGNING_CONFIGURED && !ANCHOR_TOKEN) {
    console.warn('[xl1] XYO_WALLET_MNEMONIC is set without XL1_ANCHOR_TOKEN; /anchor will refuse to sign')
  }
})
