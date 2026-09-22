import { ADDRESS_INDEX, generateXyoBaseWalletFromPhrase } from '@xyo-network/xl1-sdk'

import { getWalletMnemonic } from './getWalletMnemonic.ts'

/** Derive the account the service signs with. */
const derive = async () => {
  const wallet = await generateXyoBaseWalletFromPhrase(getWalletMnemonic())
  return wallet.derivePath(ADDRESS_INDEX.XYO)
}

// Inferred from the SDK rather than annotated with an imported
// AccountInstance. The reason has changed and the shape of the answer has not:
// it used to be that @xyo-network/account-model -- a standalone package, now
// retired into @xyo-network/sdk-protocol -- carried a narrower AccountInstance
// than the one the SDK built against, so the two would not unify. Naming any
// version of that type here reintroduces the same class of mismatch the moment
// the two halves of the stack move apart again. Letting it flow from the SDK
// keeps them the same type by construction, whatever either is called.
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
