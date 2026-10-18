/**
 * What one anchor costs, read from what recently left the wallet that pays for it.
 *
 * An anchor costs a near-identical sliver of a token each time. Anything else that leaves the wallet is not an
 * anchor: a sweep to another wallet, a mis-send. The window of history is short, so a median of ALL spends is only
 * safe while such a move is a minority of it, and an operator who tidies up an over-funded wallet in two moves can
 * outnumber the anchors in the window and push the "cost" to hundreds of tokens (it happened: two sweeps and two
 * anchors gave a median halfway between them, and the runway read as nothing measured).
 *
 * So: find the biggest group of spends that sit close together (within [SPREAD] times of the group's smallest) and
 * measure THAT. Everything outside it is set aside, counted and reported, never silently dropped. When two groups tie
 * in size the cheaper one is taken, because a cost is a floor that gas rarely beats and a sweep is never cheaper than
 * the anchors it follows. Pure.
 */
export const SPREAD = 3n

export type AnchorCost = {
  /** The typical anchor: the median of the group. */
  perAnchor: bigint
  /** The spends the figure rests on, smallest first. */
  counted: bigint[]
  /** Spends outside the group, smallest first: not anchors, and not in the figure. */
  setAside: bigint[]
}

const sorted = (xs: bigint[]) => [...xs].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))

const median = (xs: bigint[]): bigint => {
  const mid = xs.length >> 1
  return xs.length % 2 === 1 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2n
}

/** Null when there is nothing to measure from. */
export const anchorCost = (spends: bigint[]): AnchorCost | null => {
  const xs = sorted(spends.filter(s => s > 0n))
  if (xs.length === 0) return null
  let best = { from: 0, to: 0 }
  for (let i = 0; i < xs.length; i++) {
    let j = i
    while (j + 1 < xs.length && xs[j + 1] <= xs[i] * SPREAD) j++
    // strictly bigger wins, so on a tie the earlier (cheaper) group stays
    if (j - i > best.to - best.from) best = { from: i, to: j }
  }
  const counted = xs.slice(best.from, best.to + 1)
  return { perAnchor: median(counted), counted, setAside: [...xs.slice(0, best.from), ...xs.slice(best.to + 1)] }
}
