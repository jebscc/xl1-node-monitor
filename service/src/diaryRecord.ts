import { asSchema } from '@xyo-network/sdk-protocol/payload-model'

/**
 * A pet's monthly diary, a day or month of its witness receipts, or a week of its signed deeds, committed by a hash
 * alone.
 *
 * `kind` is what the hash is a hash OF -- 'diary' (the default, and all this ever was), 'witness', or 'deed'. They are
 * recorded under different app names so a month of one can never be read as a period of another.
 *
 * The phone keeps the period's line ("2026-09|blocks|xl1|bestDay|hours|est", "2026-09-18|count|hash,hash,..." or
 * "2026-W38|count|hash,hash,...") and sends only its sha256. Nothing about the period is published by anchoring it:
 * the person who holds the line can prove, later, that it said exactly this and was not rewritten after it ended.
 * Returns null for a malformed request, because whatever this builds is about to be written to a chain.
 *
 * It lives in a module of its own so a test can build one without starting a server.
 */

export type DiaryKind = 'diary' | 'witness' | 'deed' | 'batch'

/** The kinds that are recorded by hash alone, rather than as a reading. */
export const isDiaryKind = (kind: unknown): kind is DiaryKind =>
  kind === 'diary' || kind === 'witness' || kind === 'deed' || kind === 'batch'

const MONTH = /^\d{4}-(0[1-9]|1[0-2])$/
const DAY = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/
const MONTH_OR_DAY = /^\d{4}-(0[1-9]|1[0-2])(-(0[1-9]|[12]\d|3[01]))?$/

export const buildDiaryRecord = (body: Record<string, unknown>, net: string) => {
  const month = typeof body.month === 'string' ? body.month : ''
  const digest = typeof body.digest === 'string' ? body.digest : ''
  const producer = typeof body.producer === 'string' ? body.producer.slice(0, 42) : null
  const witness = body.kind === 'witness'
  const deed = body.kind === 'deed'
  const batch = body.kind === 'batch'
  // A pet's witnessing is recorded by the DAY ("2026-09-18") or the month; a diary only by the month; a week of deeds
  // by the week's last day, and a day is the only thing that will do.
  const okPeriod = witness ? MONTH_OR_DAY.test(month) : (deed || batch) ? DAY.test(month) : MONTH.test(month)
  if (!okPeriod) return null
  if (!/^[0-9a-f]{64}$/.test(digest)) return null
  // v1 named a month; a witness record is v2 and a deed ledger v1, and both name their `period`.
  const record = witness
    ? { app: 'xl1-pet-witness', v: 2, network: net, producer, period: month, digest }
    : deed
      ? { app: 'xl1-pet-deed', v: 1, network: net, producer, period: month, digest }
      : batch
        // the Merkle root of a UTC day's sentinel receipts (witness/SPEC.md), named by that day
        ? { app: 'xl1-pet-batch', v: 1, network: net, producer, period: month, digest }
        : { app: 'xl1-pet-diary', v: 1, network: net, producer, month, digest }
  const idPayload = { schema: asSchema('network.xyo.id', true), salt: JSON.stringify(record) }
  return { record, idPayload }
}
