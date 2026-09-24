/**
 * One run at a time per key.
 *
 * WHY THIS EXISTS. The field-days scan walks up to 90,000 blocks off the
 * chain, sequentially, on a Raspberry Pi whose actual job is producing them.
 * A cached answer costs nothing, so the only moment that matters is the one
 * where the cache has just expired and two callers arrive together: without
 * this they each start a full walk of the same ninety thousand blocks, and
 * the Pi pays twice for one answer. The deeper the scan, the wider that
 * window -- raising the ceiling from 25,000 to 90,000 made a ~25s collision
 * window into a ~90s one.
 *
 * NOTHING ELSE WOULD NOTICE IT FAILING. A broken dedupe returns exactly the
 * right answer to every caller; it just does the work more than once. No
 * error, no wrong figure, no failed request -- only a producer quietly
 * building fewer blocks while it serves a chart. That is why the behaviour
 * lives in a module of its own rather than inline in the handler: so it can
 * be driven directly, and so a sabotage of it fails something.
 *
 * The map is passed in rather than owned here, because the caller's cache
 * and its in-flight table have to be keyed the same way to mean anything.
 *
 * @module singleFlight
 */

/** What a caller got back: the promise, and whether it started the work. */
export type Flight<T> = { run: Promise<T>, joined: boolean }

/**
 * Run `make` under `key`, or join the run already under it.
 *
 * The entry is removed once the promise settles, whichever way it settles.
 * Left in place after a rejection it would hand the same failure to every
 * later caller for as long as the process lived, and nothing would retry.
 *
 * @param inFlight shared table of runs, keyed exactly as the cache is
 * @param key      the work being done
 * @param make     starts the work; called only when nothing is in flight
 */
export function singleFlight<T>(
  inFlight: Record<string, Promise<T>>,
  key: string,
  make: () => Promise<T>,
): Flight<T> {
  const joined = inFlight[key]
  if (joined) return { run: joined, joined: true }

  const run = make()
  inFlight[key] = run
  // Attached here rather than left to the caller: a caller that returns early
  // or throws would otherwise leave the key occupied for ever. Both arms are
  // the same clean-up, and attaching a rejection handler here also means a
  // failed run is never an unhandled rejection.
  const clear = () => { if (inFlight[key] === run) delete inFlight[key] }
  run.then(clear, clear)
  return { run, joined: false }
}

export default singleFlight
