import { isDefined } from '@xylabs/typeof'
import {
  GatewayBuilder,
  NetworkDataLakeUrls, SimpleXyoGatewayRunner,
} from '@xyo-network/xl1-sdk'

import { getRpcUrl } from './getRpcUrl.ts'
import { getSignerAccount } from './getSignerAccount.ts'

let gateway: SimpleXyoGatewayRunner | undefined

/**
 * A write-capable gateway for the configured RPC URL.
 *
 * Built through GatewayBuilder, the canonical entry point: it hides the
 * locator, provider-factory and transport wiring that callers previously
 * assembled by hand.
 */
export const getGateway = async () => {
  if (isDefined(gateway)) return gateway

  const network = process.env.XL1_NETWORK ?? 'sequence'
  const dataLake = NetworkDataLakeUrls[network as keyof typeof NetworkDataLakeUrls]
  const builder = new GatewayBuilder().name(network).rpcUrl(getRpcUrl())
  // 5.x: the signing identity goes on the builder and buildRunner() produces
  // the transacting gateway. build(signer) is the 4.x shape -- it takes no
  // argument here, so it would have returned a read-only gateway.
  gateway = await (dataLake ? builder.dataLakeEndpoint(dataLake) : builder)
    .account(await getSignerAccount())
    .buildRunner() as SimpleXyoGatewayRunner
  return gateway
}
