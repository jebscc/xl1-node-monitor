import { config } from 'dotenv'

// Load environment variables from .env file
config({ quiet: true })

const mnemonic = process.env.XYO_WALLET_MNEMONIC

/**
 * Gets the mnemonic to use for the wallet (must be provided via env).
 * @returns The mnemonic to use for the wallet
 */
export const getWalletMnemonic = (): string => {
  if (!mnemonic || !mnemonic.trim()) {
    throw new Error('XYO_WALLET_MNEMONIC is not configured')
  }
  return mnemonic.trim()
}
