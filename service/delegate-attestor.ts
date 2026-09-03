/**
 * Bind an attestation key to this producer, once, on chain.
 *
 * The node attests its own readings so a stranger can check they have not been
 * edited. That check answers "this payload is the one that was anchored" and
 * "this address anchored it" -- but not "that address speaks for the producer".
 * Without the last step an attestation proves only that SOMEONE anchored a
 * reading, which is not worth much.
 *
 * The obvious fix is to attest with the producer's own key. That would mean
 * putting the key controlling a block producer into a service with an HTTP
 * endpoint, which this project has deliberately avoided: the compose file says
 * so, and /health reports signing: false because of it.
 *
 * So the producer signs ONE statement instead -- "this attestation address
 * speaks for me" -- and the routine anchoring is done by a separate key worth
 * nothing. A verifier follows attestation -> delegation -> producer. The
 * producer key is used here, by a person, once, and never by a service.
 *
 * Run it on the Pi, where the key already lives:
 *
 *   # see exactly what would be anchored, spending nothing
 *   npx tsx delegate-attestor.ts --attestor <address> [--account <n>]
 *
 *   # actually anchor it
 *   npx tsx delegate-attestor.ts --attestor <address> --anchor
 *
 * --account is which address of the phrase this node produces as. It defaults
 * to the first, and a node whose role preset names another must say so.
 *
 * The phrase is read from stdin or XL1_PRODUCER_MNEMONIC. Never from an
 * argument: anything on a command line is visible in `ps` and lands in shell
 * history. It is not echoed, not logged, and goes nowhere except the local
 * derivation below.
 */
import { createInterface } from 'node:readline'

import { PayloadBuilder } from '@xyo-network/payload-builder'
import { asSchema } from '@xyo-network/payload-model'
import { HashSchema, type HashPayload } from '@xyo-network/xl1-protocol'
import { ADDRESS_INDEX, GatewayBuilder, generateXyoBaseWalletFromPhrase } from '@xyo-network/xl1-sdk'
import { NetworkDataLakeUrls } from '@xyo-network/xl1-protocol'

const RPC: Record<string, string | undefined> = {
  sequence: process.env.XL1_SEQUENCE_RPC_URL ?? 'https://beta.api.chain.xyo.network/rpc',
  mainnet: process.env.XL1_MAINNET_RPC_URL ?? 'https://api.chain.xyo.network/rpc',
}

const arg = (name: string): string | undefined => {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}
const flag = (name: string): boolean => process.argv.includes(`--${name}`)

const die = (message: string): never => {
  console.error(`\n  ${message}\n`)
  process.exit(2)
}

/** Read the phrase without putting it on a command line or echoing it back. */
const readPhrase = async (): Promise<string> => {
  const fromEnv = process.env.XL1_PRODUCER_MNEMONIC?.trim()
  if (fromEnv) return fromEnv
  if (process.stdin.isTTY) {
    process.stdout.write('  producer mnemonic (not echoed): ')
  }
  const rl = createInterface({ input: process.stdin, terminal: false })
  for await (const line of rl) {
    rl.close()
    if (process.stdin.isTTY) process.stdout.write('\n')
    return line.trim()
  }
  return ''
}

const main = async () => {
  const attestor = arg('attestor')?.toLowerCase().replace(/^0x/, '')
  const network = arg('network') ?? 'sequence'
  const expected = arg('producer')?.toLowerCase().replace(/^0x/, '')
  const doAnchor = flag('anchor')

  if (!attestor || !/^[0-9a-f]{40}$/.test(attestor)) {
    die('--attestor <address> is required (40 hex characters)')
  }
  const rpcUrl = RPC[network]
  if (!rpcUrl) die(`unknown network: ${network}`)

  const phrase = await readPhrase()
  if (!phrase) die('no mnemonic supplied')

  // Its own try, because this is the only call holding the phrase, and an
  // error thrown from inside it can quote what it was given. Nothing from that
  // error is printed -- the only useful fact is that the phrase did not work,
  // and the only unsafe thing available is the phrase itself.
  let wallet
  try {
    wallet = await generateXyoBaseWalletFromPhrase(phrase)
  } catch {
    die('that phrase could not be read as a mnemonic (24 words, space separated)')
  }
  // WHICH ACCOUNT OF THE PHRASE, and it is not always the first.
  //
  // One phrase derives many addresses. A node's role preset carries an
  // accountPath, and a second machine sharing a phrase is given a different
  // one so the two do not produce as the same identity. This derived index 0
  // unconditionally, so on any node NOT using account 0 it computed an address
  // that machine does not sign with -- and then either anchored a delegation
  // naming it, or (once --producer arrived) refused to anchor at all.
  //
  // Seen on a Pi running account 1: the phrase was right, the index was not,
  // and the message said the phrase derived the wrong address -- which reads
  // as "wrong wallet" and is not what happened.
  const index = arg('account') ?? ADDRESS_INDEX.XYO
  if (!/^\d{1,3}$/.test(index)) {
    die(`--account must be a whole number, not ${JSON.stringify(index)}`)
  }
  // Awaited: derivePath returns a promise. getSignerAccount.ts appears not to
  // await it only because its async wrapper flattens the return value.
  const account = await wallet.derivePath(index)
  const producer = account.address.toLowerCase()

  // The check worth having. Anchoring a delegation from the wrong key produces
  // a statement that looks right, verifies as internally consistent, and binds
  // nothing -- and it costs gas to discover. If the operator says which
  // producer this should be, refuse to proceed when the phrase disagrees.
  if (expected && producer !== expected) {
    die(`account ${index} of that phrase derives ${producer}, not the ${expected} `
      + `you named -- refusing.\n`
      + `      If this node produces as a different account of the same phrase, `
      + `pass --account <n>.`)
  }
  if (!expected) {
    console.log('  NOTE: no --producer given, so nothing checked the phrase is the')
    console.log('        right one. Pass it to have this refuse a mismatch.\n')
  }

  const record = {
    app: 'xl1-node-attestation',
    v: 1,
    kind: 'delegation',
    network,
    producer,
    attestor,
    // Said plainly, because a person may read this on an explorer years from
    // now with no other context for what it is claiming.
    statement: `${attestor} may attest readings on behalf of producer ${producer}`,
    issuedAt: new Date().toISOString(),
  }
  const payload = { schema: asSchema('network.xyo.id', true), salt: JSON.stringify(record) }
  const contentHash = await PayloadBuilder.hash(payload)

  console.log('  producer (derived) :', producer, `(account ${index})`)
  console.log('  attestor           :', attestor)
  console.log('  network            :', network)
  console.log('  content hash       :', contentHash)
  console.log('\n  payload (publish verbatim; a verifier must hash these bytes):')
  console.log(`  ${JSON.stringify(payload)}`)

  if (!doAnchor) {
    console.log('\n  Dry run. Nothing was signed and no gas was spent.')
    console.log('  Re-run with --anchor to put this on chain.\n')
    return
  }

  console.log('\n  anchoring...')
  const gateway = await new GatewayBuilder()
    .name(network)
    .rpcUrl(rpcUrl)
    .dataLakeEndpoint(NetworkDataLakeUrls[network as keyof typeof NetworkDataLakeUrls])
    .account(account)
    .buildRunner()

  const hashPayload: HashPayload = { schema: HashSchema, hash: contentHash }
  const [txHash] = await gateway.addPayloadsToChain([hashPayload], [payload])
  await gateway.confirmSubmittedTransaction(txHash, { logger: console })

  console.log('\n  anchored')
  console.log('  tx hash            :', txHash)
  console.log('  signed by          :', producer)
  console.log('\n  Publish the payload above alongside this tx hash. A verifier')
  console.log('  hashes the payload, finds that hash on chain, and checks the')
  console.log('  transaction was signed by the producer -- which is the whole')
  console.log('  of what makes the attestation key trustworthy.\n')
}

main().catch((e) => {
  // By this point the phrase has already been converted to a wallet, and the
  // calls that could quote it have their own handler above. What reaches here
  // is network and chain failure, where the message is the useful part.
  //
  // An earlier version relied on this alone, with a comment admitting the
  // message could carry the phrase -- which made printing it the leak the
  // comment warned about.
  console.error('\n  failed:', e instanceof Error ? e.message : 'unknown error')
  process.exit(1)
})
