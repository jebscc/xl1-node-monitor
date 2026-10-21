/** Types for petWitness.js, which is witness/witness.js copied byte for byte (test-batch-document.ts fails if it drifts). Only what this service uses. */
export const BATCH_SCHEMA: string
export const RECEIPT_SCHEMA: string
export const BATCH_MAX: number
export const dataHash: (obj: unknown) => Promise<string>
export const stripMeta: <T>(payload: T) => T
export const verifyBatchDocument: (
  document: unknown,
  fetchPayload: (hash: string) => Promise<unknown>,
  options?: { expectedHash?: string },
) => Promise<{ ok: boolean, why?: string, summary?: { hash: string, network: string, day: string, part: number, final: boolean, previous: string | null, root: string, count: number, receiptHashes: string[] } }>
