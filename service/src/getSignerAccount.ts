import { ADDRESS_INDEX, generateXyoBaseWalletFromPhrase } from '@xyo-network/xl1-sdk'

import { getWalletMnemonic } from './getWalletMnemonic.ts'

/** Derive the account the service signs with. */
const derive = async () => {
  const wallet = await generateXyoBaseWalletFromPhrase(getWalletMnemonic())
  return wallet.derivePath(ADDRESS_INDEX.XYO)
}

// Inferred from the SDK rather than annotated with AccountInstance from
// @xyo-network/account-model: the SDK builds against sdk-protocol-core's
// AccountInstance, which carries members the standalone package's version does
// not, so the two do not unify. Letting the type flow from the SDK keeps them
// the same type by construction.
let signerAccount: Awaited<ReturnType<typeof derive>> | undefined

/**
 * Retrieves the signer account derived from the configured mnemonic.
 * @returns The derived account
 */
export const getSignerAccount = async () => {
  if (signerAccount) return signerAccount
  signerAccount = await derive()
  console.log('Using signer account:', signerAccount.address)
  return signerAccount
}
