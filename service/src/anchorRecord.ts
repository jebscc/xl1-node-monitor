/**
 * Putting one record on the chain, as a function anything can call.
 *
 * WHY IT TAKES A GATEWAY. It used to fetch its own from the module-level
 * cache, which meant the only way to exercise it was to start the server and
 * make an HTTP request. The XL1 headless-verification pattern asks the
 * opposite: domain functions take a runner as a parameter so the same code
 * runs in the browser, in the service, and in a Node script driving it from a
 * seed phrase. Same function, same payloads, same bytes on chain -- which is
 * the whole point of verifying headlessly. A script that rebuilt the payloads
 * itself would be testing the script.
 *
 * THE CHAIN GETS THE HASH; THE DATALAKE GETS THE BYTES. `addPayloadsToChain`
 * takes them separately for that reason: the first array is anchored, the
 * second is filed off-chain where the hash can resolve to something. An anchor
 * whose payload was never filed is a digest nobody can ever read.
 */
import { PayloadBuilder } from '@xyo-network/payload-builder'
import { asSchema } from '@xyo-network/payload-model'
import type { HashPayload } from '@xyo-network/xl1-protocol'
import { HashSchema } from '@xyo-network/xl1-protocol'
import type { SimpleXyoGatewayRunner } from '@xyo-network/xl1-sdk'

import { confirmAnchored } from './confirmAnchored.ts'

/** What went on the chain, and what it says. */
export interface AnchoredRecord {
  txHash: string
  confirmed: boolean
  contentHash: string
  record: { app: string, title: string, summary: string, ts: string }
  idPayload: { schema: string, salt: string }
}

export const anchorRecord = async (
  gateway: SimpleXyoGatewayRunner,
  net: string,
  title: string,
  summary: string,
): Promise<AnchoredRecord> => {
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
  const confirmed = await confirmAnchored(gateway, net, txHash)

  return { txHash, confirmed, contentHash, record, idPayload }
}
