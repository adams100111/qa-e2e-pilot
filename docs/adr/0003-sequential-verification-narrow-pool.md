# Verification is sequential by default; the driver pool is a narrow opt-in

Criteria run sequentially in a single session by default. The configuration supports a pool of drivers, but parallel fan-out is opt-in and reserved for (a) criteria explicitly tagged independent/read-only and (b) deliberate concurrency/race tests where contention is the point.

## Consequences

This is surprising given a driver pool exists — the natural assumption is "fan everything out." But our differentiated criteria are stateful and order-dependent against a **shared** backend: baking reads back what a prior write created, multiplicity (0/1/N) is only true in order (the empty-state check must run before any create), and downstream cascades and multi-step flows are sequential by definition. Fanning these across isolated sessions on one staging backend would corrupt their results (the classic test-isolation problem). Sequential-by-default is therefore the simplest *correct* default; the pool earns its keep only on the two narrow cases above. Easy to revisit later (it is a default, not a structural commitment) — recorded so the narrowness reads as deliberate, not as an unfinished feature.
