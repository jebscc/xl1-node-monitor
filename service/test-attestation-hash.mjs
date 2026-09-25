/**
 * Pinning the anchored hash, so a dependency bump cannot move it quietly.
 *
 * WHY THIS EXISTS. `contentHash` is `PayloadBuilder.hash(idPayload)`, and it
 * is the only thing about an attestation that reaches the chain. Everything
 * else -- the readings, the salt, the record -- stays off it. So if that
 * function ever stops being sha256 over canonical sorted-key JSON, every new
 * attestation anchors a value that `verify-attestation.py` disagrees with,
 * and a stranger checking our proof is told it has been tampered with.
 *
 * NOTHING ELSE CATCHES THAT. The signature is `hash(payload) => string` and
 * stays that way, so `pnpm run typecheck` is green. The service starts, the
 * container is healthy, `/attest` returns 200 and a transaction really does
 * land on chain. The only symptom is that the published verifier says NO,
 * months later, to somebody who is not us.
 *
 * The risk is not theoretical: `@xyo-network/payload-builder` went 5.3.30 ->
 * 7.0.15 in one Dependabot group PR, a major version of the package that owns
 * this function, and the hashes were compared by hand that day because there
 * was nothing to run. This is that comparison, written down.
 *
 * WHAT IS PINNED, AND WHY BOTH HALVES ARE NEEDED:
 *
 *   1. Fixed payloads hash to fixed hex. Catches a change even in the case
 *      where the SDK and the verifier move together -- a check that only
 *      compared the two against each other would call that agreement.
 *   2. The real `verify-attestation.py`, run as a subprocess. Not a
 *      reimplementation of it: the file a stranger downloads is the file
 *      under test, because a copy of its logic can agree with the SDK while
 *      the published one does not.
 *   3. A deliberately wrong hash must be REJECTED. A verifier that returns
 *      "match" for everything would pass 1 and 2 and prove nothing.
 *
 * Run: node test-attestation-hash.mjs   (from xl1-service; CI runs it too)
 */
import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { PayloadBuilder } from '@xyo-network/sdk-protocol/payload-builder'
import { asSchema } from '@xyo-network/sdk-protocol/payload-model'

let failures = 0
const check = (name, actual, expected) => {
  if (actual === expected) {
    console.log(`  ok   ${name}`)
  } else {
    failures++
    console.error(`  FAIL ${name}\n       got: ${actual}\n       want: ${expected}`)
  }
}

// The shape `/attest` actually anchors: one `network.xyo.id` payload whose
// `salt` is the reading, serialised. Built the same way server.ts builds it,
// including asSchema, so this breaks if the schema helper starts decorating
// the value it returns.
const record = {
  producer: '0x7f1c2b3a4d5e6f708192a3b4c5d6e7f809102132',
  network: 'sequence',
  observedAt: '2026-09-14T00:00:00.000Z',
  chain: { blocks: 7124, height: 918273 },
  machine: { cpu: 11.5, tempC: 47.2, memPct: 38 },
}
const idPayload = {
  schema: asSchema('network.xyo.id', true),
  salt: JSON.stringify(record),
}

// Everything canonicalisation can get wrong and no realistic payload exercises:
// keys out of order, an array that must NOT be sorted, an explicit null, a
// nested object, and non-ASCII that a different escaping rule would re-encode.
const torture = {
  schema: asSchema('network.xyo.id', true),
  z: [3, 2, 1],
  a: 1,
  nested: { b: true, a: null },
  unicode: 'café — straße',
}

// Measured 2026-09-14 against @xyo-network/payload-builder 7.0.15, and agreed
// with by verify-attestation.py below. CHANGING THESE CONSTANTS IS THE WHOLE
// DECISION: if a bump moves them, attestations anchored before it and after it
// are no longer checkable by the same rule, and that is a migration, not a
// test update.
const PINNED_ATTESTATION = 'ffd94df972478f0e8261121adab412e6440e57ddffeccfd13c2cd45e13c51fc7'
const PINNED_TORTURE = 'c1874f761a866213452e69627ebcb66e5fb8070c549f7957345a48c456de0fd6'

const attestationHash = await PayloadBuilder.hash(idPayload)
const tortureHash = await PayloadBuilder.hash(torture)

console.log('PayloadBuilder.hash still produces the value that was anchored')
check('an attestation payload', attestationHash, PINNED_ATTESTATION)
check('key order, arrays, null and non-ASCII', tortureHash, PINNED_TORTURE)

// --- and the published verifier must still agree ---------------------------
//
// Python, not a JS reimplementation. If python is genuinely unavailable this
// says so and fails, rather than skipping: a check that quietly does not run
// is the thing this whole file exists to prevent.
const python = (() => {
  for (const exe of ['python3', 'python']) {
    try {
      execFileSync(exe, ['-c', 'pass'], { stdio: 'ignore' })
      return exe
    } catch {
      /* try the next one */
    }
  }
  return null
})()

// WHAT THE PINNED CHECKS ALONE SAID, kept so the verdict at the bottom can
// tell "the hash moved" from "the second opinion could not be had". They are
// different facts and only one of them is about the hash.
const hashFailures = failures

console.log('\nverify-attestation.py agrees, and still rejects a wrong hash')
if (!python) {
  failures++
  console.error('  FAIL no python on PATH -- the verifier half did not run')
} else {
  const dir = mkdtempSync(join(tmpdir(), 'attest-'))
  try {
    const verify = (payload, contentHash) => {
      const file = join(dir, 'attestation.json')
      writeFileSync(file, JSON.stringify({ payload, contentHash }), 'utf8')
      try {
        execFileSync(python, ['verify-attestation.py', file], { stdio: 'pipe' })
        return true
      } catch {
        return false
      }
    }

    check('the attestation payload verifies',
      verify(idPayload, attestationHash), true)
    check('the awkward payload verifies',
      verify(torture, tortureHash), true)

    // Watch it fail. One hex digit of the real hash flipped -- close enough
    // that a verifier comparing lengths, or prefixes, or nothing at all would
    // still say yes.
    const nearly = attestationHash.replace(/.$/, (c) => (c === '7' ? '8' : '7'))
    check('a hash off by one digit is rejected',
      verify(idPayload, nearly), false)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

if (failures) {
  // A VERDICT MAY NOT OUTRUN ITS EVIDENCE. With no python the verifier half
  // does not run, and this said "the anchored hash is not what it was" about
  // a comparison it had never made -- on a Pi, where that is the normal state
  // of the borrowed container, so the sentence was not just wrong but
  // routinely wrong. Still a failure either way; only the claim changes.
  console.error(hashFailures
    ? `\n${failures} failure(s). The anchored hash is not what it was.`
    : `\n${failures} failure(s). The hash itself is unchanged -- what could `
      + `not be shown is that the published verifier still agrees with it.`)
  process.exit(1)
}
console.log('\nThe anchored hash is unchanged, and the public verifier agrees.')
