/**
 * Waiting for a transaction to be included, without letting the wait undo it.
 *
 * Its own module so it can be tested: importing server.ts starts a listening
 * server, which is not a thing a test should have to do to find out how long
 * this waits.
 */
import type { SimpleXyoGatewayRunner } from '@xyo-network/xl1-sdk'

/* HOW LONG TO WAIT FOR INCLUSION, PER NETWORK.
 *
 * The SDK's defaults are sized for a fast chain. Sequence produces a block
 * about every 52 seconds and has run five times slower than that for a day at
 * a stretch, so the default window can expire while the transaction is doing
 * nothing whatever wrong. xl1-patterns/headless-verification.md prescribes
 * {attempts: 30, delay: 10_000} for exactly this.
 */
export const CONFIRM_OPTS: Record<string, { attempts: number, delay: number }> = {
  sequence: { attempts: 30, delay: 10_000 },   // five minutes
  mainnet: { attempts: 20, delay: 5_000 },     // 100s; blocks are ~15s there
}

/**
 * Wait for a transaction to be included, and never let the waiting undo it.
 *
 * THE GAS IS ALREADY SPENT BY THE TIME THIS IS CALLED. The transaction is
 * broadcast, it is on a public chain, and nothing that happens while we wait
 * can take it back. This used to be an unguarded `await` in the middle of the
 * anchor path, so a confirmation that timed out threw out of `anchor()` and
 * the caller recorded a FAILED attestation for a transaction that was fine --
 * the same "plausible and wrong" shape as a link to a page that cannot resolve.
 *
 * Nothing is lost by not waiting: the backend checks the chain itself and
 * writes `chain_found` / `chain_block` against every attestation, so inclusion
 * is established by a party that was not involved in submitting it. This wait
 * is a convenience, and a convenience must not be able to fail an anchor.
 *
 * Returns whether it confirmed, so the answer can say so rather than implying
 * it.
 */
type ConfirmableHash = Parameters<
  SimpleXyoGatewayRunner['confirmSubmittedTransaction']
>[0]

export const confirmAnchored = async (
  gateway: SimpleXyoGatewayRunner, net: string, txHash: ConfirmableHash,
): Promise<boolean> => {
  try {
    await gateway.confirmSubmittedTransaction(txHash, {
      logger: console, ...(CONFIRM_OPTS[net] ?? {}),
    })
    return true
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e)
    console.warn(`[anchor] ${txHash} on ${net} not confirmed while waiting: ${why}`)
    return false
  }
}
