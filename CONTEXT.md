# QA E2E Pilot

The ubiquitous language for a browser-driven end-to-end QA tool that verifies a feature's full stack — not just what the screen renders, but what the backend computed, stored, and constrained.

## Language

**Criterion**:
The unit of QA work: one end-to-end behavior verified *across layers*, yielding exactly **one verdict** — e.g. "creating a founder persists a 1-of-N shareholder with the right ownership %." Driving the UI, baking, computed-logic, and downstream tracing are its **steps**, not separate criteria; it passes only if every layer agrees, and a failure records the **suspected layer**. The pipeline verifies, evidences, and checkpoints one criterion at a time, sequentially by default; only criteria tagged independent/read-only, or deliberate concurrency tests, may run in parallel.
_Avoid_: test case, check, assertion. Use "acceptance criterion" only for an ingested spec input, which may expand into several criteria.

**Step**:
One layer of verification inside a criterion — drive UI, bake, recompute/reconcile, probe, trace downstream. Steps don't get their own verdict; they roll up into the criterion's single verdict and identify the suspected layer on failure.
_Avoid_: phase (a phase is a stage of the whole Run pipeline, not a within-criterion step).

**Run**:
One invocation of the pipeline against a target feature, producing one report directory and one resumable memory trail.
_Avoid_: pass, campaign, session (session means something else here).

**Backend**:
The application server and data layer under test — its endpoints, services, source-of-truth formulas, and database. The thing whose persisted and computed state a criterion is checked against.
_Avoid_: server, API (an API is one surface of the backend). Never use "backend" for a browser-MCP server — that is a **Driver**.

**Driver**:
A configured browser provider in the pool that supplies sessions. **Default = a managed Playwright-MCP browser** (zero-config, any OS). **Attended CDP** — attaching to your own logged-in Chrome — is an opt-in driver chosen by a **platform preset** (`managed` | `windows+wsl` | `windows` | `wsl` | `linux` | `mac`) that resolves the CDP endpoint/host. Enumerated and pinged at pre-flight.
_Avoid_: backend, browser (one driver can host many sessions).

**Session**:
One isolated browser context a single criterion runs in, spawned by a Driver. Persisted via storageState so auth survives.
_Avoid_: tab, window, run.

**Baking**:
Reading persisted state back out of the backend after a UI write, to confirm it actually saved with the right shape and multiplicity. "A green toast is not a pass." Read-back is via a list/detail view or a direct API read.
_Avoid_: persistence check (acceptable as a gloss), save verification.

**Multiplicity**:
The count a persisted entity is checked at — 0 (empty state), 1 (single), N (many) — forced deliberately on repeatable entities. An ordered property: the 0-state criterion is only true before any create criterion runs.
_Avoid_: cardinality, count.

**Computed-logic verification**:
Independently recomputing a feature's calculations, reports/aggregations, and business-rule outcomes from the **spec/domain rule** (the oracle) and comparing to the UI/API within tolerance — then tracing downstream impact onto dependent entities. Backend code is read only to **localize** a divergence, never as the oracle. A value whose expectation can only be derived from backend code is flagged lower-confidence: it can catch precision/propagation bugs but not a wrong formula.
_Avoid_: recompute-against-backend (that is a mirror, not a verification).

**Reconciliation**:
Comparing the *same* quantity across layers — recomputed-expected vs FE display vs API response vs DB row/migration — to localize which layer a divergence lives in.
_Avoid_: comparison, diffing.

**Oracle**:
The authority a result is judged correct against. Here the oracle is the spec/domain rule, carried in the checklist — not the backend implementation.
_Avoid_: source of truth (reserve "backend source of truth" for *what the backend computed/stored*, which reconciliation localizes against, not the correctness oracle).

**Memory-spec**:
The typed schema for a Run's resumable artifacts — run-manifest, checkpoint, bug-log, traceability. These are *run artifacts* belonging to the run, not durable facts in the agent's personal memory system.
_Avoid_: notes, memory (unqualified — it is not the global agent memory).

**Checkpoint**:
The per-criterion resume cursor — phase, verdict, evidence refs, last action — written after every criterion so a Run survives context compaction and can skip completed criteria on resume.
_Avoid_: snapshot, save.

**Checklist**:
The set of criteria for a Run, each carrying its expected values/rules (the oracle). Hand-authored in v1; auto-generated from a surface map in v1.1; may also ingest a supplied spec.
_Avoid_: test plan, spec (a spec may be an *input* to a checklist, not the checklist itself).

**Verdict**:
A criterion's outcome — exactly one of: **pass** (matched the oracle), **fail** (diverged → bug-log entry), **blocked** (a precondition outside the criterion was unmet — env down, auth missing, prerequisite criterion failed; re-runnable), **deferred** (deliberately not verified this run, with a stated reason), **error** (the tool/harness itself broke mid-criterion).
_Avoid_: skipped, n/a, partial. "blocked" = the environment stopped us; "error" = our tooling broke; "deferred" = we chose not to.

**Confidence**:
An orthogonal attribute on a pass/fail verdict — **low** when the expected value could only be derived from backend code (no spec/domain oracle), **high** otherwise. Not a verdict value.
_Avoid_: certainty, weight.

**Suspected layer**:
The layer a **fail** is localized to — exactly one of: **FE** (frontend render/format/wiring), **route** (wrong/missing endpoint or path), **service** (the computed formula or business-rule predicate), **migration** (schema/column precision/constraints definition), **DB** (the stored row or runtime constraint violation). The deliverable of a fail: it tells the fixer where to look and is the value the report's suspected-layer field and the bug-log carry. Reconciliation produces it.
_Avoid_: backend (too coarse — pick service / migration / DB), backend-routing / backend-validation / state-machine (use the five canonical values).

**Probing**:
Going underneath a lying UI to get the truth — reading the network response body, or doing an API read-back with the session's cookies. **Read-only by default.** Direct API *writes* (seeding) are an opt-in gated behind a config flag and a disposable/seedable env marker; cross-origin capability is detected at preflight, never assumed.
_Avoid_: seeding (that is the gated write path, not probing itself).

## Flagged ambiguities

- **"backend"** previously named two things: the app under test, and a browser-MCP pool entry. Resolved: **Backend** = app under test only; a pool entry is a **Driver**, and the browser context it spawns is a **Session**.

## Example dialogue

> **Dev:** The list-shows-zero criterion keeps failing.
> **QA expert:** Because it isn't independent — it asserts the empty state, so it's only true before any create criterion runs. Keep it sequential; don't fan it out to a second driver.
> **Dev:** So when *do* we use a second driver?
> **QA expert:** For criteria you've tagged read-only, or a deliberate race — two sessions hitting the same backend entity at once. Everything that writes shared backend state stays on one driver, in order.
