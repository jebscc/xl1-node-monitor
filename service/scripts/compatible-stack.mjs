/**
 * The newest versions of the XYO stack that FIT TOGETHER.
 *
 *   node scripts/compatible-stack.mjs [path/to/package.json]
 *
 * Prints `name=version` for every stack package named in package.json, one per line, and explains its
 * reasoning on stderr. Used by `bump-xyo-stack.sh --compatible`; reads the registry and writes nothing.
 *
 * WHY THIS EXISTS. `bump-xyo-stack.sh` takes the newest published version of EVERY package and then
 * refuses when they disagree. That is the right gate and the wrong plan: the stack's packages do not
 * all move to a new major on the same day. Twice (2026-11-20, then again with 5.10.0) @xyo-network/sdk
 * 9 was published while xl1-sdk and xl1-protocol still asked for sdk 7 or 8, and the peer audit
 * correctly stopped a bump that nothing could satisfy -- leaving the operator with no way to take the
 * parts that DO fit.
 *
 * THE RULE. Start every package at its newest release. Then, for every requirement one stack package
 * makes of another, if the version chosen for the other does not satisfy it, move the OTHER package
 * down to the newest version that does -- the one asked for is the one that gives way, because the
 * packages the service imports (xl1-sdk, xl1-protocol) are the ones that decide which sdk they work
 * with. Repeat until nothing is violated. A package is NEVER taken below what is pinned today: if the
 * only fix would be a downgrade it is held where it is, and the peer audit that follows says so.
 *
 * SEMVER, THE PART OF IT PEER RANGES USE: `||`, space-joined comparators, ^ ~ >= > <= < =, bare and
 * x-ranges. Stable releases only. peer-audit.mjs deliberately does not carry a full copy of semver and
 * neither does this; it carries the cases a peerDependency actually writes, and is tested for them.
 */
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const STACK = ['@xyo-network', '@xylabs', '@ariestools'];
export const inStack = (name) => STACK.some((s) => name.startsWith(`${s}/`));

// ---- the bit of semver peer ranges use ---------------------------------------------------------

export const parse = (v) => {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
};
export const cmp = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];

/** One comparator, e.g. `^4.6`, `>=1.2.3`, `8`, `1.x`. True when [v] (a triple) satisfies it. */
const ok = (v, comp) => {
  const m = /^(\^|~|>=|<=|>|<|=)?\s*v?(\d+|[xX*])(?:\.(\d+|[xX*]))?(?:\.(\d+|[xX*]))?$/.exec(comp.trim());
  if (!m) return false;
  const op = m[1] || '=';
  const wild = (s) => s === undefined || /^[xX*]$/.test(s);
  const maj = wild(m[2]) ? null : Number(m[2]);
  const min = wild(m[3]) ? null : Number(m[3]);
  const pat = wild(m[4]) ? null : Number(m[4]);
  if (maj === null) return true;                                   // `*`
  const lo = [maj, min ?? 0, pat ?? 0];
  if (op === '=') return v[0] === maj && (min === null || v[1] === min) && (pat === null || v[2] === pat);
  if (op === '>=') return cmp(v, lo) >= 0;
  if (op === '>') return min === null ? v[0] > maj : pat === null ? cmp(v, [maj, min + 1, 0]) >= 0 : cmp(v, lo) > 0;
  if (op === '<') return cmp(v, lo) < 0;
  if (op === '<=') return min === null ? v[0] <= maj : pat === null ? cmp(v, [maj, min + 1, 0]) < 0 : cmp(v, lo) <= 0;
  if (op === '~') return cmp(v, lo) >= 0 && (min === null ? v[0] === maj : v[0] === maj && v[1] === min);
  // ^ : nothing above the first non-zero part
  if (cmp(v, lo) < 0) return false;
  if (maj > 0 || min === null) return v[0] === maj;
  if (min > 0 || pat === null) return v[0] === 0 && v[1] === min;
  return v[0] === 0 && v[1] === 0 && v[2] === pat;
};

/** Whether version string [version] satisfies [range] (alternatives joined by `||`, comparators by spaces). */
export const satisfies = (version, range) => {
  const v = parse(version);
  if (!v) return false;
  return String(range).split('||').some((alt) => {
    const parts = alt.trim().split(/\s+/).filter(Boolean);
    // glue `>= 1.2` style (operator then space then version) back together
    const joined = [];
    for (const p of parts) { if (joined.length && /^(\^|~|>=|<=|>|<|=)$/.test(joined[joined.length - 1])) joined[joined.length - 1] += p; else joined.push(p); }
    return joined.length > 0 && joined.every((c) => ok(v, c));
  });
};

// ---- the resolution ----------------------------------------------------------------------------

/**
 * [meta] maps package name -> { versions: [stable version strings, oldest to newest], peers: { version: { peerName: range } } }.
 * [pinned] maps name -> the version in package.json today. Returns { chosen, notes }.
 */
export function resolve(meta, pinned) {
  const names = Object.keys(pinned).filter((n) => meta[n]);
  const chosen = {};
  const notes = [];
  for (const n of names) chosen[n] = meta[n].versions[meta[n].versions.length - 1];
  const floor = (n) => parse(pinned[n]) || [0, 0, 0];
  const held = new Set();

  for (let guard = 0; guard < 500; guard++) {
    let moved = false;
    for (const a of names) {
      const peers = (meta[a].peers[chosen[a]] || {});
      for (const [p, range] of Object.entries(peers)) {
        if (!names.includes(p) || !inStack(p) || satisfies(chosen[p], range)) continue;
        // the one asked for gives way: the newest version of it at or below what is chosen that fits
        const fit = meta[p].versions.filter((v) => cmp(parse(v), parse(chosen[p])) < 0 && satisfies(v, range) && cmp(parse(v), floor(p)) >= 0);
        if (fit.length) {
          notes.push(`${p} held at ${fit[fit.length - 1]} (not ${chosen[p]}): ${a}@${chosen[a]} asks for ${p} ${range}`);
          chosen[p] = fit[fit.length - 1];
          moved = true;
          continue;
        }
        // no version of it fits without a downgrade: the asker gives way instead, one release at a time
        const older = meta[a].versions.filter((v) => cmp(parse(v), parse(chosen[a])) < 0 && cmp(parse(v), floor(a)) >= 0);
        if (older.length) {
          notes.push(`${a} held at ${older[older.length - 1]} (not ${chosen[a]}): it asks for ${p} ${range}, and nothing at or above the pinned ${p} ${pinned[p]} fits`);
          chosen[a] = older[older.length - 1];
          moved = true;
        } else if (!held.has(a + p)) {
          held.add(a + p);
          notes.push(`${a}@${chosen[a]} asks for ${p} ${range} and ${p}@${chosen[p]} does not meet it; nothing newer than the pinned versions fits, so the peer audit will say so`);
        }
      }
    }
    if (!moved) break;
  }
  return { chosen, notes };
}

// ---- the registry ------------------------------------------------------------------------------

async function fetchMeta(name) {
  const res = await fetch(`https://registry.npmjs.org/${name.replace('/', '%2f')}`, { headers: { accept: 'application/vnd.npm.install-v1+json' }, signal: AbortSignal.timeout(30000) });
  if (!res.ok) throw new Error(`${name}: registry answered ${res.status}`);
  const doc = await res.json();
  const versions = Object.keys(doc.versions || {}).filter((v) => parse(v)).sort((x, y) => cmp(parse(x), parse(y)));
  const peers = {};
  for (const v of versions) peers[v] = doc.versions[v].peerDependencies || {};
  return { versions, peers };
}

async function main() {
  const file = process.argv[2] || 'package.json';
  const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
  const pinned = {};
  for (const sect of ['dependencies', 'devDependencies']) {
    for (const [n, v] of Object.entries(pkg[sect] || {})) if (inStack(n)) pinned[n] = String(v).replace(/^[\^~]/, '');
  }
  const meta = {};
  for (const n of Object.keys(pinned)) meta[n] = await fetchMeta(n);
  const { chosen, notes } = resolve(meta, pinned);
  for (const n of notes) console.error(`compatible-stack: ${n}`);
  for (const n of Object.keys(chosen).sort()) console.log(`${n}=${chosen[n]}`);
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  main().catch((e) => { console.error(`compatible-stack: ${e.message}`); process.exit(1); });
}
