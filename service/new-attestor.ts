/**
 * Create the key that will anchor this node's attestations.
 *
 * Deliberately worth nothing. It anchors hashes and holds a little gas; it
 * controls no producer, no stake and no balance you would miss. That is the
 * point of the delegated design -- the producer signs one statement binding
 * this key, and this key does the routine work, so the key that matters never
 * goes near a service with an HTTP endpoint.
 *
 * Losing it is a nuisance, not a loss: generate another, delegate again.
 *
 *   npx tsx new-attestor.ts                 # writes attestor.key, prints the address
 *   npx tsx new-attestor.ts --out /path/to  # somewhere of your choosing
 *   npx tsx new-attestor.ts --show          # print the phrase instead of writing it
 *
 * Written to a file rather than printed by default, because a terminal keeps
 * scrollback and shells keep history, and the phrase would otherwise sit in
 * both. It is requested 0600 and refuses to overwrite -- silently replacing a
 * key that has already been delegated would leave a delegation pointing at an
 * address nobody can sign for any more. The mode the filesystem actually gave
 * it is read back and printed, because Windows largely ignores the request and
 * claiming 0600 over a world-readable file would be the one lie this must not
 * tell.
 *
 * Derived on the same path the service signs with, so the address printed here
 * is the address that will actually appear on attestations.
 */
import { statSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { HDWallet } from '@xyo-network/sdk'
import { ADDRESS_INDEX, generateXyoBaseWalletFromPhrase } from '@xyo-network/xl1-sdk'

const arg = (name: string): string | undefined => {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}
const flag = (name: string): boolean => process.argv.includes(`--${name}`)

const main = async () => {
  const show = flag('show')
  const out = resolve(arg('out') ?? 'attestor.key')

  const phrase = String(await HDWallet.generateMnemonic()).trim()
  const wallet = await generateXyoBaseWalletFromPhrase(phrase)
  const account = await wallet.derivePath(ADDRESS_INDEX.XYO)
  const address = account.address.toLowerCase()

  // The address is announced only once the phrase is somewhere durable.
  // Printing it first reads as success, and a key whose phrase was never
  // written is unrecoverable -- an operator who then funds or delegates that
  // address is spending on something nobody can ever sign for. That is not
  // hypothetical: it happened on the first real run, against a directory the
  // container could not write.
  if (show) {
    console.log('\n  attestation address :', address)
    console.log('  mnemonic            :', phrase)
    console.log('\n  That phrase is now in your terminal scrollback. Move it')
    console.log('  somewhere deliberate and clear the buffer.')
  } else {
    try {
      // wx: fail if it exists. flush the phrase to disk before it is anywhere else.
      writeFileSync(out, `${phrase}\n`, { encoding: 'utf8', mode: 0o600, flag: 'wx' })
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code
      if (code === 'EEXIST') {
        console.error(`\n  ${out} already exists -- refusing to overwrite it.`)
        console.error('  If a key there has already been delegated, replacing it would')
        console.error('  leave that delegation pointing at an address nobody can sign')
        console.error('  for. Move the old file aside first, or pass --out elsewhere.\n')
        process.exit(2)
      }
      console.error(`
  Could not write the phrase: ${(e as Error).message}`)
      console.error('  NO KEY WAS KEPT. The one just generated is gone -- never fund')
      console.error('  or delegate an address printed by a failed run.')
      if (code === 'EACCES') {
        console.error('\n  Permission denied usually means the mounted directory is not')
        console.error('  writable by the uid the container runs as:')
        console.error('    sudo chown 1000:1000 <the directory you mounted>')
      }
      console.error('  Fix the path and run again for a fresh key.\n')
      process.exit(2)
    }
    // Report the mode the filesystem actually applied rather than the one
    // requested. Windows largely ignores it, and a script that prints "0600"
    // over a world-readable file tells a comfortable lie about the one thing
    // it exists to get right.
    let mode = ''
    try {
      mode = (statSync(out).mode & 0o777).toString(8).padStart(3, '0')
    } catch { /* reporting only */ }
    console.log('\n  attestation address :', address)
    console.log('  mnemonic written to :', out)
    if (mode) {
      console.log('  file mode           :', mode,
        mode === '600' ? '' : '<- NOT 0600; tighten it yourself (chmod 600)')
    }
  }

  console.log('\n  next:')
  console.log('    1. send this address a little gas so it can anchor')
  console.log('    2. bind it to the producer, once:')
  console.log(`         npx tsx delegate-attestor.ts --attestor ${address} \\`)
  console.log('           --producer <your producer address>')
  console.log('       (dry run first -- it spends nothing and shows what would be anchored)')
  console.log('    3. give the service this phrase as XYO_WALLET_MNEMONIC, with')
  console.log('       XL1_ANCHOR_TOKEN set, so /attest will sign\n')
}

main().catch((e) => {
  // e.message only: a wallet error can carry the phrase, and this runs on a
  // terminal that remembers.
  console.error('\n  failed:', e instanceof Error ? e.message : 'unknown error')
  process.exit(1)
})
