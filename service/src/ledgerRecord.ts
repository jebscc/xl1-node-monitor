import { asSchema } from '@xyo-network/sdk-protocol/payload-model'

import { dataHash, verifyBatchDocument } from './petWitness.js'

/**
 * THE PET LEDGER'S RECORD: what a crew node checks, and what it writes, before a day's batch reaches the chain.
 *
 * `buildLedgerRecord` decides everything that will be written, and refuses anything it cannot verify, because what this builds is
 * about to be filed to a data layer and committed in a transaction paid for in gas, and neither can be taken back. The batch it is
 * handed (the manifest and every receipt filed beside it) is verified HERE, from scratch and with no network: every receipt's
 * signature and shape, the order, the root, and that the manifest hashes to the digest the backend queued. (The block each receipt names
 * was checked against XL1's own files when the server received it, and anyone can check it again.)
 *
 * It lives in a module of its own so a test can build one without starting a server. The rules themselves are in witness/SPEC.md,
 * "The pet ledger on XL1", and the verifier is witness/witness.js, copied here byte for byte (petWitness.js).
 */

const DAY = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/
const HEX64 = /^[0-9a-f]{64}$/

export interface LedgerBody {
  month?: unknown
  digest?: unknown
  producer?: unknown
  document?: unknown
  payloads?: unknown
}

export type LedgerBuilt =
  | { ok: true, record: Record<string, unknown>, idPayload: { schema: ReturnType<typeof asSchema>, salt: string }, document: Record<string, unknown>, payloads: Record<string, unknown>, manifestHash: string }
  | { ok: false, why: string }

/** The one record a ledger anchor commits, named by its day: the same shape as every other anchor's, so the backend reads it the same way. */
export const buildLedgerRecord = async (body: LedgerBody, net: string): Promise<LedgerBuilt> => {
  const day = typeof body.month === 'string' ? body.month : ''
  const digest = typeof body.digest === 'string' ? body.digest : ''
  const producer = typeof body.producer === 'string' ? body.producer.slice(0, 42) : null
  if (!DAY.test(day)) return { ok: false, why: 'a ledger record is named by a day' }
  if (!HEX64.test(digest)) return { ok: false, why: 'a ledger record needs the 64-character hash of its manifest' }
  const document = body.document as Record<string, unknown> | null
  const payloads = body.payloads as Record<string, unknown> | null
  if (!document || typeof document !== 'object' || Array.isArray(document)) return { ok: false, why: 'no manifest' }
  if (!payloads || typeof payloads !== 'object' || Array.isArray(payloads)) return { ok: false, why: 'no receipts to file' }
  if (document.day !== day) return { ok: false, why: 'the manifest is for another day than the one asked for' }
  if (document.network !== net) return { ok: false, why: 'the manifest is for another network than this node writes to' }
  const verdict = await verifyBatchDocument(document, async (h) => payloads[h] ?? null, { expectedHash: digest })
  if (!verdict.ok) return { ok: false, why: `the batch does not verify: ${verdict.why}` }
  // every payload offered is one the manifest lists: nothing is filed that the chain's hash does not cover
  const listed = new Set(document.receipts as string[])
  for (const h of Object.keys(payloads)) if (!listed.has(h)) return { ok: false, why: 'a payload was offered that the manifest does not list' }
  const record = { app: 'xl1-pet-ledger', v: 1, network: net, producer, period: day, digest }
  const idPayload = { schema: asSchema('network.xyo.id', true), salt: JSON.stringify(record) }
  return { ok: true, record, idPayload, document, payloads: payloads as Record<string, unknown>, manifestHash: await dataHash(document) }
}
