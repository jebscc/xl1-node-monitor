/**
 * Which day an instant belongs to, in somebody's actual timezone.
 *
 * WHY IT IS NOT `toISOString().slice(0, 10)`, which is what it used to be.
 * That is a UTC date. UTC is the right default for a chain and the wrong
 * answer for an operator: a UTC day begins at 7pm the previous evening in
 * New York, so "today" on the panel counted from last night and never agreed
 * with the clock on the wall. Jim asked for a day that runs from his
 * midnight, and this is the only place that can give him one -- the
 * timestamps are here, and a per-day total cannot be re-cut downstream.
 *
 * IN ITS OWN FILE BECAUSE `server.ts` LISTENS ON IMPORT. Anything that wants
 * to test this by importing the server starts a web server on a Raspberry
 * Pi's port instead, so the logic that decides what a day IS lives where a
 * test can reach it without one.
 *
 * @module dayKey
 */

/* `en-CA` because its short date format IS `YYYY-MM-DD` -- the key shape
 * every existing caller already reads -- and `Intl` because it knows about
 * summer time. A fixed offset in minutes would be right for half the year
 * and silently wrong for the other half, and a thirty-day scan regularly
 * spans the change.
 *
 * Cached: constructing a formatter costs roughly what formatting a thousand
 * dates costs, and this runs once per block across ninety thousand of them. */
const cache: Record<string, Intl.DateTimeFormat> = {}

const build = (tz: string) => new Intl.DateTimeFormat('en-CA', {
  timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
})

/**
 * A formatter giving `YYYY-MM-DD` in `tz`.
 *
 * AN UNKNOWN ZONE FALLS BACK TO UTC RATHER THAN THROWING. This is reached
 * from a query string, and a typo in one must not be able to stop a node
 * mid-scan.
 */
export function dayKeyFor(tz: string): Intl.DateTimeFormat {
  const want = tz || 'UTC'
  if (!cache[want]) {
    try {
      cache[want] = build(want)
    } catch {
      console.warn(`[dayKey] unknown timezone ${want}; counting days in UTC`)
      cache[want] = build('UTC')
    }
  }
  return cache[want]
}

/**
 * The first instant of the day that `at` falls in, in the formatter's zone.
 *
 * WALKED, NOT CALCULATED. Subtracting an offset is wrong across a summer-time
 * change and wrong again in the zones that are not whole hours from UTC. This
 * asks the formatter which day each instant reads as and steps back until it
 * changes, which is right everywhere by construction.
 *
 * Twenty-six hours of stepping covers the longest day any zone has -- the
 * hour a fall-back repeats included.
 *
 * THE MINUTE PASS IS NOT ONLY FOR THE FRACTIONAL ZONES, which is what this
 * note used to claim. `at` is an arbitrary instant: stepping back in whole
 * hours from 19:30 lands on 00:30 local and stops, in New York exactly as in
 * Kolkata. Removing it fails six of the cases below, not the two half-hour
 * ones -- which is how the claim was found to be wrong.
 *
 * It runs once per request, not once per block.
 */
export function startOfDayIn(fmt: Intl.DateTimeFormat, at: number): number {
  const want = fmt.format(new Date(at))
  let t = at
  for (let i = 0; i < 26 && fmt.format(new Date(t - 3_600_000)) === want; i++) {
    t -= 3_600_000
  }
  for (let m = 0; m < 60 && fmt.format(new Date(t - 60_000)) === want; m++) {
    t -= 60_000
  }
  return t
}

/**
 * How many hours of rolling window a request asked for, or zero for none.
 *
 * IT WAS WRITTEN AS A CLAMP AND BEHAVED AS A DEFAULT:
 *
 *     Math.min(168, Math.max(1, Number(q) || 0))
 *
 * Absent comes out as ONE, so every caller of /field-days became a one-hour
 * rolling window -- the standings day and the thirty-day climb chart
 * together, the whole portal drawing an hour of chain. It reached the Pi
 * before anybody noticed.
 *
 * The clamp belongs INSIDE the branch that has already decided a value was
 * asked for. Applied to the default it invents one.
 *
 * Here rather than inline in the route so the test drives the function the
 * server actually calls, instead of a second copy of it that can agree with
 * the comment while the route disagrees with both.
 */
export function rollingHours(raw: unknown): number {
  const n = Number(raw)
  if (!Number.isFinite(n) || n <= 0) return 0
  return Math.min(168, Math.floor(n))
}
