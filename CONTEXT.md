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
The **authority of last resort** a result is judged correct against — ground truth. Here the oracle is the spec/domain rule, carried in the checklist; on the UI/UX plane a **definite** oracle may also be a standard (WCAG), the i18n catalog, a design token, or the content rule that `undefined`/`NaN`/a raw key is never valid. Never the backend implementation, and never the app's own self-consistency (a uniformly-buggy app is self-consistent). Only a definite oracle can ground a **verdict**.
_Avoid_: source of truth (reserve "backend source of truth" for *what the backend computed/stored*, which reconciliation localizes against, not the correctness oracle); calling an **expectation heuristic** an oracle.

**Expectation heuristic**:
A *non-authoritative* source of what "should" happen — the app's own conventions (self-consistency), cross-state comparison (en/ar, viewport, before/after), convention priors (Nielsen/HIG), or the multimodal generative critic. Yields a **suspicion**, never a standalone verdict; it becomes a verdict only when a definite **Oracle** corroborates it or a human confirms it in a HITL round — otherwise it stays advisory. Keeps detection from circular reasoning.
_Avoid_: oracle (a heuristic is not ground truth), rule.

**Suspicion**:
A candidate finding emitted by a detector before adjudication — `{family, selector, evidence}`, no verdict. Promoted to a verdict only by **adjudication** against a definite **Oracle** (or HITL); otherwise reported as advisory.
_Avoid_: finding (reserve for an adjudicated result), bug (not yet confirmed).

**Adjudication**:
The deliberate-vs-bug determination: localize a **suspicion** to its source (component, style rule, i18n key, data field) and judge it against the **Oracle**. Confirms a real defect *or* clears an intentional design (e.g. an Arabic-catalog value intentionally in Latin script). Reading the code only *localizes and adjudicates* — it is never itself the oracle.
_Avoid_: verification (reserve for the layer-agreement of a criterion), review.

**Oracle grade**:
The strength of the expectation source backing a **suspicion**, one of `definite-dom | definite-catalog | standards | heuristic` (strongest to weakest). `definite-dom`/`definite-catalog` findings are backed by a definite **Oracle** and may become a `fail` verdict at **Confidence** `high`; `standards` may become a `fail` at `low`; `heuristic` never grounds a verdict on its own — it stays advisory unless a definite-grade finding corroborates it. An internal classification input the adjudicator computes per finding — never itself a **Verdict**, and never the same field as **Confidence** (grade decides verdict-vs-advisory and feeds the high/low split; it is not the attribute reported on the finding).
_Avoid_: confidence (a verdict attribute the grade merely informs), verdict (grade is an input to one, never a value of one).

**Capture-hook / Toolstream**:
The **capture-hook** is a plugin-bundled `PostToolUse` hook that records every browser/Bash call (+ bounded read bodies; `Bash` args/response secret-redacted, `browser_*` recorded in full — a documented residual) to an **append-only** `toolstream.jsonl` — the **agent-unauthored**, tamper-*evident* record (+ the `--save-session` log) that **qa-verify** reconciles evidence against. No hash-chain (an agent could recompute it — false assurance); its trust comes from qa-verify's independent re-check, not the file.
_Avoid_: log (unqualified), trace (reserve "action-trace" for the agent's self-report), hash-chain (cut).

**Block-hook**:
A plugin-bundled `PreToolUse` hook that **denies before running** the *phase-independent absolutes* it can classify from the call alone — a mutating `browser_evaluate` and `browser_run_code_unsafe` (shipped, Plan H2). It sees tool calls, not the agent-supplied phase, so it never gates phase-dependent cases (a `browser_navigate` URL-skip is record-only → **qa-verify**); it also does not block `browser_route` — an originally-scoped absolute (ADR-0018) not carried into the shipped hook, left to **qa-verify**/the in-run gate. Fail-open on any internal error. Distinct from the in-run **checkpoint** gate and from **qa-verify**.
_Avoid_: gate (reserve for the checkpoint enforcement), block (unqualified).

**Provenance binding**:
The rule that every evidence artifact must correspond to a **Capture**-hook call that produced it — a bake read-back to a captured backend read (a **containment** check: the value/key found inside some captured response body, or an explicit `--source-ref`); an act step to a captured tool call of the matching class. Evidence with no corresponding captured call is `unbound` — the AC-1 forgery signal — never silently accepted.
_Avoid_: signature, checksum.

**qa-verify**:
The **out-of-agent** authoritative verifier — a standalone process (local or CI), `scripts/qa-verify.sh`, whose core is deterministic code (no LLM): it re-derives required-kinds, re-validates evidence, and binds provenance against a Run's **Toolstream**, overriding a forged `pass`. Its verdict overrides the in-run report; a Run is "verified" only when every pass survives it. The **independent LLM re-drive/re-bake** of high-stakes criteria (a fresh operator-invoked agent re-driving a read-only probe, or re-baking a mutating human-action pass) is a **pluggable, documented stub** (`QA_VERIFY_REDRIVE_CMD`) — invoked but its result is logged only, not yet wired into the verdict (Plan H3).
_Avoid_: gate (the in-run `checkpoint.sh` is the gate; `qa-verify` is the out-of-agent re-verification), CI.

**Assurance tier**:
The enforcement strength actually achieved on a harness — how tamper-resistant the live gate is (Codex managed-config = agent-proof; Claude plugin-bundled / opencode root-managed; Pi cooperative). Printed in the report; the universal floor is **qa-verify**. A best-effort tier prints an honest banner rather than claiming a guarantee.
_Avoid_: level, mode.

**Persona identity**:
The session's actually-observed identity for a **persona**, captured via `record-evidence.sh identity` (`evidence/<persona>/identity.json {persona, capturedSubject, method}`) and bound by **qa-verify** to every persona-scoped, high-stakes pass (recorded kinds include `human-action`, or the criterion is tagged `cross-tenant`/`cross-role-fk-chain`). A mismatch overrides the verdict to `fail` only when `.qa/config.json`'s `personas[].expectedSubject` supplies operator-configured ground truth for that persona; without it, an unverifiable or non-matching captured identity degrades **Confidence** to `low` instead of a false override — a persona id is a scoping label the agent supplies, never by itself proof of who acted.
_Avoid_: whoami (the probe technique, not the artifact/check), persona (the confirmed role being played — identity is what the session actually turned out to be, checked against it).

**Clock advisory**:
A best-effort, non-gating flag (`advisory:"clock-control"`) the **Capture-hook** stamps on a toolstream event whose args match a known time-control signal (`setTestNow`, fake-timers, a `Date.now` override, a clock-control route like `/__clock`). Paired with a doctrine ban on mocking the clock to force a time-dependent assertion to pass. Never blocks, never changes a verdict, and never affects the hook's exit code — a suspect signal worth a second look during review, not proof of a violation on its own.
_Avoid_: gate (it never gates anything), block (see **Block-hook**, a distinct, actually-blocking mechanism).

**Named exception**:
One of the five tag-required carve-outs that loosen the act-phase `browser_navigate` fail-closed default: `deep-link`, `auth-boundary`, `persona-switch`, `out-of-band` (each requires an explicit `carveout:"<name>"` tag on the step, checked by Set membership) plus the structurally-exempt arrange-phase entry navigate. An unrecognized `carveout` value is never treated as a named exception — the step stays a rejected workaround (fail-closed).
_Avoid_: carve-out (acceptable as a gloss for one member; this term is the canonical name for the full five-member set), workaround (the opposite outcome: an untagged or unrecognized-tag navigate).

**autonomousSetup**:
A `.qa/config.json` `humanInteraction.autonomousSetup` flag (default `false`) letting an operator declare a headless/CI/`/loop` run: when `true`, `confirming-discovered-roles` proactively auto-accepts its pre-run setup rounds (tagging each accepted item `assumption:true`) instead of prompting a human. Setup-only, by design — it never touches the Verify loop, which already never interrupts a criterion once verification starts.
_Avoid_: autonomous (unqualified — this flag scopes only the pre-run setup rounds, never Verify).

**Required-kinds**:
The gate's own independently re-derived required evidence-kind set for a criterion — computed by `required-kinds.sh derive` from the criterion's declared `kind`/`tags`/action shape (a subset of `bake | computed | probe | human-action`), reusing the mutation classifier for the mutates→human-action rule. Read off a **Checklist**'s `checklist.json` row but never trusted from that row's own `requiredKinds` field; `checkpoint.sh`'s pass-gate rejects a `pass` unless the recorded `--kinds` is a superset. In-script, best-effort: catches a *dropped* kind, not a dishonestly-declared `kind`/`tags` shape — the sound form of this check is **qa-verify**.
_Avoid_: requiredKinds (the agent's advisory field on a `checklist.json` row — not the gate's own derivation, which this term names).

**Asserted state / fingerprint-target**:
The persisted-state key a mutating criterion's act is expected to touch, declared per-criterion as `assertedState {entity, readBackPath, expectChange}` on a `checklist.json` row and threaded into `action-trace.json` as `fingerprintTarget`. Check 3 (`check-action-trace.js`) requires the act phase's before/after state fingerprint to *cover* `readBackPath` and, per `expectChange`, show it changed or unchanged — a coverage check, not equality, and not proof the fingerprint's own values are real.
_Avoid_: fingerprint (unqualified — reserve for the general before/after state capture; fingerprint-target is the one asserted key within it that Check 3 enforces).

**Journal**:
The append-only `journal.ndjson` in `.qa/runs/<run-id>/` — one event per line (`criterion_started`, `act_intent`, `criterion_verdict`, …) — and the **single source of truth** for a Run's resume state. The **Checkpoint** and **Cursor** are *derived projections* of it (see **Fold**); the journal wins on any disagreement. `run-manifest`, `bug-log`, and `traceability` stay separate, agent-authored artifacts — the journal records their triggering events but is never folded into them. Written append-then-flush; the derived files are written atomically (temp→rename→dir-fsync).
_Avoid_: log (unqualified — the **Toolstream** is a different append-only file), checkpoint (that is one derived projection, not the journal itself).

**Fold**:
The pure function that replays the **Journal** to compute current Run state — "where am I" = `fold(journal)`, never the agent's memory (context compaction is a silent partial restart, so folded state is the only reliable position). Fold is also the crash-recovery pass: a torn last journal line is discarded on fold, and out-of-order or malformed lines are recorded as **fold-anomalies** rather than aborting the replay.
_Avoid_: reduce, replay (acceptable as a gloss), restore.

**Fold-anomalies**:
The Run-level record of lines the **Fold** could not apply cleanly while replaying the **Journal** — a torn last line, or an event that breaks the expected sequence. An anomaly is recorded, never a fold abort; replay continues from the last valid line.
_Avoid_: error log (a structured per-line record, not free-text).

**Scenario**:
One role's ordered storyline of criteria in a Run — the unit a single persona plays. A Run has one scenario per confirmed role; the **current scenario** always has exactly one current role. Cross-tenant isolation and two-actor races are individual **criteria** inside a role's scenario, not multi-actor scenarios. The atomic resumable unit is the `(scenario, criterion)` tuple.
_Avoid_: journey (a criterion may be a multi-step flow), test suite, multi-actor scenario (not modeled).

**Idempotency probe**:
A read-only check a **mutating** criterion declares — entity + natural key — used on resume to decide whether its act already landed, so a crash mid-act never double-creates. Paired with a deterministic key `runId:scenarioId:criterionId` and the `act_intent`/`act_committed` journal events; an unresolved probe on resume yields `blocked`, never a blind retry. Reuses the bake read-back.
_Avoid_: idempotency key (that is the identifier; the probe is the check), dedup.

**Statechart**:
The Run's phase and per-criterion sub-state machine, declared as **data** in `state-machine.json` (`skills/checkpointing-qa-memory/references/`) — phases, **sub-states**, legal edges, guards, and the per-phase tool surface (**phase surface**). **Fold**, **qa-verify**, and the **transition guard** all read this one file and hold only the generic edge-check procedure; editing it changes behavior in all three with no code change (ADR-0021).
_Avoid_: state machine (acceptable as a gloss), enforcement engine (the statechart is the contract; fold/qa-verify/the guard are the engines that read it).

**Sub-state**:
One of a criterion's six internal machine states — `pending, arranging, acting, baking, reconciling, verdict` — inferred by **Fold** from journal events already emitted (`plan_frozen`/`criterion_started`/`act_intent`/`act_committed`/`criterion_verdict`), never agent-emitted through any CLI. Exposed as `cursor.json`'s `subState` field. Internal machine state, never a **Verdict**.
_Avoid_: verdict (a sub-state is machine-internal, not an outcome), phase (a **phase** is a stage of the whole Run; a sub-state is per-criterion, inside Verify).

**Transition guard**:
A cooperative, best-effort precondition on a sub-state edge that `journal-emit.sh` checks before appending an `act_intent`/`act_committed` event — e.g. `acting → baking` requires an observed `act_committed`; `arranging → acting` requires `mutates`. An illegal edge is **declined** (nothing appended, non-zero exit; `--force` bypasses it, logged). This guards what gets *recorded*, not what the agent can do with other tools — it is not itself the authority (that's **qa-verify**, via **phase surface**); absent `state-machine.json`, the guard skips rather than blocking.
_Avoid_: gate (reserve for the pass/honesty enforcement), cage (this is explicitly not one).

**Phase surface**:
The set of tool classes sanctioned during a given Run phase (`state-machine.json`'s `phaseToolSurface`), enforced **record-only** by **qa-verify**: it temporally correlates **Toolstream** calls against the journal's phase timeline and criteria's acting windows, flagging a call outside its sanctioned surface as a `confidence:low` finding — never a hard override of a verdict, never a live block.
_Avoid_: sandbox, block (see **Block-hook**, a distinct, actually-blocking but phase-independent mechanism).

**Illegal-edge**:
A **fold-anomaly** (`{rule:"illegal-edge", tuple, from, to, guard}`) recorded when a criterion's observed **sub-state** transition is not a member of `state-machine.json`'s `legalSubStateEdges` — e.g. an `act_committed` with no prior `act_intent`. Recorded in `fold-anomalies.json`; never a fold abort.
_Avoid_: error (a structured per-tuple record, not free text).

**Frozen plan**:
The criterion set + order (+ personas/scenarios) recorded once at Run start (`plan_frozen`) and replayed on resume — never re-derived from the running app, which may have drifted. A criterion added mid-Run is an explicit `plan_amended` event, never a silent re-derivation.
_Avoid_: checklist (the frozen plan is the checklist *pinned at a moment*), replan.

**Memory-spec**:
The typed schema for a Run's resumable artifacts — run-manifest, checkpoint, bug-log, traceability. These are *run artifacts* belonging to the run, not durable facts in the agent's personal memory system.
_Avoid_: notes, memory (unqualified — it is not the global agent memory).

**Checkpoint**:
The per-criterion resume record — phase, verdict, evidence refs, last action — written after every criterion so a Run survives context compaction and can skip completed criteria on resume.
_Avoid_: snapshot, save.

**Cursor**:
The `cursor.json` artifact folded from the **Journal** — the Run-level resume position (current phase, criteria done/total, personas, scenarios, and the current `(scenario, criterion)` tuple). Distinct from **Checkpoint** (the per-criterion record) and from the agent-authored `run-manifest` (identity/status) — Cursor is *where* the Run currently stands, computed by **Fold**, never hand-maintained.
_Avoid_: checkpoint (that is the per-criterion record; cursor is the run-level position), resume point (acceptable as a gloss).

**Checklist**:
The set of criteria for a Run, each carrying its expected values/rules (the oracle). Hand-authored in v1; auto-generated from a surface map in v1.1; may also ingest a supplied spec.
_Avoid_: test plan, spec (a spec may be an *input* to a checklist, not the checklist itself).

**Verdict**:
A criterion's outcome — exactly one of: **pass** (matched the oracle), **fail** (diverged → bug-log entry), **blocked** (a precondition outside the criterion was unmet — env down, auth missing, prerequisite criterion failed; re-runnable), **deferred** (deliberately not verified this run, with a stated reason), **error** (the tool/harness itself broke mid-criterion).
_Avoid_: skipped, n/a, partial. "blocked" = the environment stopped us; "error" = our tooling broke; "deferred" = we chose not to.

**Confidence**:
An orthogonal attribute on a pass/fail verdict — **low** when the expectation is **not grounded in a spec/domain oracle**, **high** when it is. One definition, two instances: a value derivable only from backend code (computed-logic), *and* a bare standards threshold with no spec reconciliation (WCAG contrast/target-size, and other UX). Not a verdict value.
_Avoid_: certainty, weight; two separate definitions (the backend-code case and the standards-threshold case are the same "no spec/domain oracle" rule).

**Suspected layer**:
The layer a **fail** is localized to — exactly one of: **FE** (frontend render/format/wiring), **route** (wrong/missing endpoint or path), **service** (the computed formula or business-rule predicate), **migration** (schema/column precision/constraints definition), **DB** (the stored row or runtime constraint violation). The deliverable of a fail: it tells the fixer where to look and is the value the report's suspected-layer field and the bug-log carry. Reconciliation produces it.
_Avoid_: backend (too coarse — pick service / migration / DB), backend-routing / backend-validation / state-machine (use the five canonical values).

**Probing**:
Going underneath a lying UI to get the truth — reading the network response body, or doing an API read-back with the session's cookies. **Read-only by default.** Direct API *writes* (seeding) are an opt-in gated behind a config flag and a disposable/seedable env marker; cross-origin capability is detected at preflight, never assumed.
_Avoid_: seeding (that is the gated write path, not probing itself).

**Stack-profile**:
The detected, reviewable description of the target's stack for a Run — per component: language, framework, packages, ORM model/migration paths, auth scheme, and frontend routing model. Produced by `detecting-stack-profile` (dual-source) as the first action of Analyze and written to `.qa/runs/<run-id>/stack-profile.json`. Every later phase adapts to it.
_Avoid_: stack, config (the profile is detected facts, not the user's `.qa/config.json`).

**Playbook**:
A per-stack executable recipe (`references/playbooks/<id>.md`) the agent walks to enumerate routes, bake, and probe for that framework. Selected by the profile's `playbook` field. Data lives in `stack-signatures.json`; procedure lives in the playbook; the profile is the resolved instance joining them.
_Avoid_: driver (a Driver is a browser provider), strategy.

**Signal**:
How sure *detection* is about the stack — `strong | weak`. **Distinct from Confidence** (a verdict attribute). One-way mapping only: a `weak` signal, or a missing shape-oracle, *causes* a dependent criterion's verdict **Confidence** to be `low`; never the reverse, never the same field.
_Avoid_: confidence (that is the verdict attribute), certainty.

**Runtime fingerprint / code-based detection**:
The two detection sources. *Runtime fingerprint* = read-only GETs to `baseUrl` (headers, cookies, HTML markers, OpenAPI probe) describing the running app — the only source against a bare production target. *Code-based* = reading local manifests from `repos[]`, authoritative for the shape oracle. Merged: runtime wins on live identity, code wins on the shape oracle; disagreement is recorded as drift.
_Avoid_: scan (the fingerprint is a tiny allowlist, never a path scan).

## Flagged ambiguities

- **"backend"** previously named two things: the app under test, and a browser-MCP pool entry. Resolved: **Backend** = app under test only; a pool entry is a **Driver**, and the browser context it spawns is a **Session**.

## Example dialogue

> **Dev:** The list-shows-zero criterion keeps failing.
> **QA expert:** Because it isn't independent — it asserts the empty state, so it's only true before any create criterion runs. Keep it sequential; don't fan it out to a second driver.
> **Dev:** So when *do* we use a second driver?
> **QA expert:** For criteria you've tagged read-only, or a deliberate race — two sessions hitting the same backend entity at once. Everything that writes shared backend state stays on one driver, in order.
