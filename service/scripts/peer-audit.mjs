/**
 * Are the XYO stack's peer requirements actually met by the tree on disk?
 *
 *   node scripts/peer-audit.mjs [service-dir]
 *
 * Exit 0 when every requirement INSIDE the stack is satisfied. Exit 1 when one
 * is not, naming each.
 *
 * WHY THIS IS NOT COVERED BY ANYTHING ELSE. `pnpm install --frozen-lockfile`
 * -- what both CI and the Dockerfile run -- installs an unmet peer in silence;
 * the warnings only appear on a resolving install. And `tsc --noEmit` passes,
 * because types come from whatever version is on disk, so a typecheck
 * describes the tree it was given rather than the tree the packages asked for.
 * Measured on PR #33, where @xyo-network/sdk 8.0.0 sat above sdk-protocol
 * 7.3.2 with a green install and a green typecheck.
 *
 * TWO CLASSES, AND ONLY ONE IS FATAL.
 *
 *   inside the stack   @xyo-network, @xylabs and @ariestools asking for each
 *                      other. These release together and a mismatch here is
 *                      ours to fix, by choosing versions that agree.
 *   outside it         a stack package asking for somebody else's, e.g.
 *                      @noble/post-quantum ^0.6.1 against the 0.7.1 upstream
 *                      ships today. Real, reported, and not something a
 *                      version choice here can resolve -- failing the build on
 *                      it would stop every deploy over a decision made in
 *                      another repository.
 *
 * MAJOR VERSIONS, AND MINOR TOO BELOW 1.0. A full semver implementation here
 * would be a second and worse copy of one. But ^0.6.1 does NOT admit 0.7.1 --
 * under 1.0 the minor is the breaking axis -- and reading only the major
 * missed exactly that, while pnpm reported it. The narrow rule is wrong in a
 * way that matters, so it is not the rule.
 */
import fs from 'node:fs';
import path from 'node:path';

const STACK = ['@xyo-network', '@xylabs', '@ariestools'];
const svc = process.argv[2] || '.';
const store = path.join(svc, 'node_modules', '.pnpm');

if (!fs.existsSync(store)) {
  console.error(`peer-audit: no pnpm store under ${svc}; run pnpm install first`);
  process.exit(2);
}

const inStack = (name) => STACK.some((s) => name.startsWith(`${s}/`));

/** name -> version, for the copy that is this package's OWN store entry. */
const installed = new Map();
/** {from, peer, want} for every declaration made by a stack package. */
const declares = [];

for (const dir of fs.readdirSync(store)) {
  const nm = path.join(store, dir, 'node_modules');
  if (!fs.existsSync(nm)) continue;

  // EVERY PACKAGE, NOT ONLY THE SCOPED ONES. Skipping unscoped entries meant
  // zod, ethers and ajv were never recorded as installed, and forty
  // requirements naming them came back ABSENT while they sat in the tree.
  // Forty false alarms bury the four findings that matter.
  const rels = [];
  for (const entry of fs.readdirSync(nm)) {
    if (entry.startsWith('@')) {
      for (const name of fs.readdirSync(path.join(nm, entry))) rels.push(path.join(entry, name));
    } else rels.push(entry);
  }

  for (const rel of rels) {
    const pj = path.join(nm, rel, 'package.json');
    if (!fs.existsSync(pj)) continue;
    let p;
    try { p = JSON.parse(fs.readFileSync(pj, 'utf8')); } catch { continue; }
    if (!p.name || !p.version) continue;
    // The copy under its own store entry is the installed one; a copy under
    // another package's entry is that package's private resolution.
    if (dir.startsWith(`${p.name.replace('/', '+')}@`)) installed.set(p.name, p.version);
    if (inStack(p.name) && p.peerDependencies) {
      for (const [peer, want] of Object.entries(p.peerDependencies)) {
        declares.push({ from: `${p.name}@${p.version}`, peer, want });
      }
    }
  }
}

/** [major, minor] of a concrete version, or null. */
const parts = (v) => {
  const m = /^(\d+)\.(\d+)/.exec(String(v));
  return m ? [Number(m[1]), Number(m[2])] : null;
};

/** Does `got` satisfy `range`, to the precision described at the top? */
const satisfies = (range, got) => {
  const g = parts(got);
  if (!g) return null;
  for (const alt of String(range).split('||')) {
    const w = parts(alt.trim().replace(/^[\^~>=\s]*/, ''));
    if (!w) return null;
    if (w[0] !== g[0]) continue;
    // Below 1.0 the minor carries the break: ^0.6.1 does not admit 0.7.1.
    if (w[0] === 0 && w[1] !== g[1]) continue;
    return true;
  }
  return false;
};

let fatal = 0;
let advisory = 0;
let unparsed = 0;
const seen = new Set();

for (const d of declares.sort((a, b) => a.from.localeCompare(b.from))) {
  const key = `${d.from}|${d.peer}`;
  if (seen.has(key)) continue;
  seen.add(key);

  const got = installed.get(d.peer);
  const scope = inStack(d.peer) ? 'STACK' : 'OUTSIDE';
  if (!got) {
    // Absent and outside the stack is ordinary: a peer nothing needed is a
    // peer nothing installed, and an optional one looks the same from here.
    if (scope === 'STACK') { console.log(`UNMET    ${d.from} wants ${d.peer} ${d.want}, nothing resolved`); fatal++; }
    continue;
  }
  const okay = satisfies(d.want, got);
  if (okay === null) { console.log(`UNPARSED ${d.from} wants ${d.peer} ${d.want}, got ${got}`); unparsed++; continue; }
  if (okay) continue;
  if (scope === 'STACK') { console.log(`UNMET    ${d.from} wants ${d.peer} ${d.want}, got ${got}`); fatal++; }
  else { console.log(`NOTE     ${d.from} wants ${d.peer} ${d.want}, got ${got}  (outside the stack)`); advisory++; }
}

console.log(`SUMMARY ${fatal} unmet in-stack, ${advisory} noted outside, ${unparsed} unparsed, ${seen.size} checked`);
process.exit(fatal > 0 ? 1 : 0);
