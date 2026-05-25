# Reimplement opslane/verify's patterns; don't fork or vendor

opslane/verify is the closest prior art (MIT, browser-driven, UI-only acceptance verification). We reimplement its reusable pieces — the pure-bash pre-flight, the route/selector indexer, and the single-file HTML report — as our own code and credit opslane in the README, rather than forking the repo or vendoring those files verbatim.

## Considered Options

- **Fork** — track upstream and contribute back. Rejected: it imports opslane's managed-Playwright runtime and PM-ticket intake we don't want, and our differentiators (backend baking, independent recompute, persistent run memory, attended CDP) cut across its per-AC loop — we'd rewrite its core skill prose and lose mergeability anyway.
- **Vendor verbatim** (with attribution headers + `THIRD_PARTY_NOTICES.md`). Rejected: every candidate file is modified by our differentiators (pre-flight gains driver enumeration + build-id capture; the indexer gains backend cross-reference by role; the report gains verdict cards, confidence, DEFERRED, baking evidence, traceability), so they are derivative works wearing a "verbatim copy" label.
- **Reimplement + credit** (chosen) — clean ownership, an honest licensing story, no `THIRD_PARTY_NOTICES.md` unless some file ever ships byte-for-byte. MIT does not require copying, and designs/ideas are not copyrightable.

Browser *mechanics* are still delegated to the Playwright/CDP MCP, not rebuilt.
