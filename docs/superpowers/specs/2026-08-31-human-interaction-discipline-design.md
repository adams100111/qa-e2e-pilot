# Design — Human-Interaction Discipline + Hardened Round-Engine

**Status:** Approved design (2026-08-31, via superpowers:brainstorming). Next: superpowers:writing-plans.
**Supersedes/consolidates** the earlier freehand draft `docs/specs/human-interaction-discipline.md` (kept for history).
**Scope (user-chosen: COMBINED):** (A) the interaction discipline, (B) wiring per-run role/scenario selection into the orchestrator, and (C) hardening the grilling frontier-rounds into a proven, testable engine.

---

## 0. Goal (north star)

> Each project has **defined roles**; each run **selects which roles run and what each does, with a proper scenario**. Each testing agent is a **human look-and-feel QA tester — never an AI that works around the UI to pass**. If the action-under-test cannot be done through the real UI, that **is a bug** (not something to force via `browser_evaluate`, the Playwright API, the terminal, or direct state). It also catches **UI/UX bugs a human eye would see**, and walks **real journeys**.

The UX-eye detection and real-journey testing already ship and are measured (visual detection catches U1/U3/U4; broken-journey recall = 100%). This design adds the missing enforcement (A), closes the per-run role gap (B), and turns the round pattern from prose into a verified engine (C).

---

## 1. Core invariant — "Act like a human, observe like a machine"

Every criterion runs **Arrange → Act → Assert**, each with distinct tool rights.

| Phase | What it is | Tool rights |
|---|---|---|
| **Arrange** | reach the precondition (login as persona, seed disposable env, navigate to the feature) — NOT the action under test | UI or seeded creds/storageState; API/DB writes ONLY in a disposable env (`allowApiWrites`+marker), never the action under test |
| **Act** | perform the **action-under-test** | **UI-ONLY**: `browser_click/type/fill_form/press_key/select_option/hover/drag/file_upload` on genuine affordances; real link/button navigation. **Forbidden:** `browser_evaluate` that sets `.value`/clicks/calls app fns/dispatches events; `browser_run_code_unsafe`; direct API/DB/localStorage write; URL-skip of a gated step |
| **Assert / Observe** | bake, recompute, detect | read-only anything: `browser_evaluate`-read (getComputedStyle, localStorage read, DOM query, UX detectors, observe-round), console/network reads, screenshot, read-only probe fetch |

**UI-impossible = `fail @ FE`** (confidence `high`), never `blocked`, never a workaround. The **oracle** remains the arbiter: a control that *correctly* rejects an invalid input (per the spec) is a `pass` reached through the human path; a missing/disabled/broken affordance for a spec'd action is a `fail`.

---

## 2. Components (well-bounded units)

### 2A. Interaction rules — `driving-browser-qa` + `references/interaction-discipline.md` (new)
The act/observe split, the tool matrix (above), the UI-impossible→fail rule, and the reconciliations (§3). Referenced one level deep from `driving-browser-qa`.

### 2B. No-Workaround Gate — extends Phase-1 `checkpoint.sh` (machine gate + agentic rules)
- New evidence **kind `human-action`**, derived by `generating-qa-checklist` for any criterion whose action mutates state or drives a control.
- New evidence artifact **`action-trace.json`** (per `[<persona>/]<crit>/`): the ordered tool calls that performed the action-under-test, each `{tool, target, phase: "arrange"|"act"|"assert"}`. The observe-round tags each act call's phase, so producing the trace costs nothing extra.
- Gate rule: a `pass` on a `human-action` criterion is **REJECTED** if any **act-phase** step used a workaround tool (evaluate-set / `.click()` / `run_code_unsafe` / direct write), unless the criterion carries a `nonUiActionReason` (§2E). Message: *"act performed via workaround `<tool>`; perform through the UI or record the UI-impossibility as a fail."*
- **Independent action log closes the self-report hole (machine gate, not trust).** Launch Playwright MCP with **`--save-session`**, which writes an independent server-side **`session.md`** — the agent does not author it and cannot selectively omit from it. **Verified format (`@playwright/mcp@0.0.79`):** `session.md` records the **generated Playwright CODE** of each executed step under `Ran Playwright code` ` ```js ` blocks (`await page.locator(...).click()`, `await page.evaluate(...)`), NOT MCP tool names, and with no phase tags. `parse-session-log.js` classifies each block by code pattern into `{class, mutating}` using the **same mutation lint as A1 Check 2**. At checkpoint time the gate **reconciles the classified `session.md` calls against the agent's recorded steps** over the whole criterion (session.md is phase-less): a **mutating `evaluate`/`route` call in `session.md` with no corresponding recorded step is a concealed workaround → REJECT**. A **read-only** observe `evaluate` (`getComputedStyle`/`getItem`/`querySelector` reads — the sanctioned bake/detector/observe path) is `mutating:false` and is IGNORED, so the gate does not false-reject every real criterion. A **human-path** mutation in `session.md` is the sanctioned act itself and is never treated as concealed.
- **Residual trust (stated, not hidden):** the mutating *occurrence* is now machine-verified via `session.md`; only its **phase framing** remains agentic (a recorded mutation mislabeled "arrange" vs "act"). An optional reviewer/adversarial pass spot-checks phase honesty. Machine-checked where it can be, belt-and-suspenders where it must be.

### 2C. Reconciliations of shipped workarounds
- `react-set-input.js` → **demoted to read-only** (reads a field's value back; never sets the value the action depends on). Act-path value entry uses `browser_type`/`browser_fill_form`.
- `click-by-text.js` → finds an element by RTL/label text (read); **acts via `browser_click`** on the resolved selector, not in-evaluate `.click()`.
- **F4 / out-of-range numeric** → treated as a genuine **tool limitation** (`browser_type` transiently coerces `-500` on `type=number`; a human types it fine): use the **logged opt-out** — enter via evaluate-set WITH `nonUiActionReason: "tool: browser_type coerces -500 on type=number"`, confidence `low`, reason in the report. F4 stays catchable and honest.

### 2D. Per-run role/scenario selection wiring (closes 2B.5-adjacent gap)
Orchestrator pre-run invokes the round engine (§2F): pick which discovered **personas** run this pass, confirm each role's **scenario** (its role-sensitive criteria + cross-role pairs), choose **lens + viewport**. Defaults: all discovered personas / `skeptical-auditor` / `1440×900`. Each persona then runs its scenario **under the discipline**, persona-keyed (existing).

### 2E. Opt-out + config
- Per-criterion `nonUiActionReason: "<why the human-path is a tool limit, not an app bug>"` → gate permits the workaround for that criterion, forces confidence `low`, prints the reason. Absent → workarounds gate-rejected.
- **Opt-out-abuse guard:** the opt-out is per-criterion and cost-carrying (every use forces `confidence: low`), so blanket opt-out visibly tanks the run's confidence. Additionally, the report flags a run whose `nonUiActionReason` rate exceeds a threshold (default **>20%** of `human-action` criteria) as *"discipline largely bypassed — review the opt-out reasons"*, so mass opt-out can't quietly defeat the gate. Not a hard block (a genuinely tool-limited surface may legitimately exceed it), a loud signal.
- `.qa/config.json` `"humanInteraction": {"enforce": true, "saveSession": true}` (both default true; `saveSession` launches the Playwright MCP driver with `--save-session` so the gate has an independent `session.md` to reconcile against — §2B. `enforce` is an audit-only fallback for migration, never silently off. If `saveSession` is false the gate degrades to trace-only with a printed warning that the self-report hole is open — never the silent default).

### 2F. Hardened round-engine (C — turns the grilling pattern from prose into a proven unit)
Today `references/hitl-rounds.md` describes the pattern; nothing verifies it. Make it a small **testable frontier-state unit**:
- A `frontier` module (dependency-free) over three sets — `settled`, `frontier` (decisions whose prerequisites are settled), `deferred` (blocked on an open decision) — with operations: `computeFrontier(tree, settled)`, `apply(answer) → recompute`, `budgetExceeded()`.
- The role-confirmation flow (`confirming-discovered-roles`) drives it: each round renders `frontier` as numbered items **each with a recommended default**, applies answers, recomputes.
- **Tests** (fixture-level): (a) a dependent decision (credentials) surfaces ONLY after its prerequisite (roles) is settled; (b) every frontier item carries a recommended default; (c) editing an answer recomputes the frontier; (d) past the round budget it logs assumptions and proceeds (never blocks).
- **Independent review** of `hitl-rounds.md` + `confirming-discovered-roles` as part of this work (they shipped review-free in the loop).

### 2G. ADR-0015
Records: act-through-UI-only + UI-impossible=fail; the No-Workaround Gate (`human-action` kind + action-trace **reconciled against the independent `--save-session` `session.md` log** + the residual-trust model); the react-set-input/click-by-text/F4 reconciliations; the logged opt-out; the hardened round-engine; and the per-run role-selection wiring.

---

## 3. Data flow
`criterion → arrange(setup) → act(UI-only; each step appended to action-trace with phase) → assert(observe/bake/recompute/detect) → record-evidence(bake|computed|probe + action-trace) → checkpoint … pass --kinds …,human-action [--persona P]` → **gate: (Check 1/2) every act-phase step is a human-path tool or a read-only evaluate, else reject; (Check 0) every mutating `evaluate`/`route` call classified from the independent `session.md` is accounted for by a recorded step, else reject as a concealed workaround — OR `nonUiActionReason` present.**

Session setup: the driver launches Playwright MCP with `--save-session` (see §2E config). `session.md` is a SINGLE per-run file (all criteria's calls append to it), so the driver **delta-slices per criterion**: baseline `N = parse(session.md).length` before the act, `sessionCalls = parse(session.md).slice(N)` after — exact under ADR-0003 sequential execution; a tagged-parallel criterion gets its own `--output-dir` instead. The slice is recorded into the criterion's `action-trace.json`, and `session.md` is copied into the run dir for reviewer audit.

## 4. Error handling
- Missing/disabled/broken affordance for a spec'd action → `fail@FE` + evidence (screenshot + enumerated affordances from `domDigest.interactive` + any console error).
- Genuine tool limitation → `nonUiActionReason` opt-out (confidence `low`, logged).
- Round budget exceeded → log assumptions, proceed (never block).

## 5. Testing (fixture-provable acceptance)
1. evaluate-set on the act path → **gate rejects** the pass.
2. seeded missing-affordance for a spec'd action → `fail@FE`, no evaluate-around.
3. UI *correctly* rejects invalid input (per oracle) → `pass`.
4. F4 via logged opt-out → still caught, confidence `low`, reason logged.
5. **No silent recall regression** — any drop from the current functional 100% / overall 92% is an explicit "now correctly unreachable via UI" recategorization, logged.
6. read-only observation (baking, observe-round, UX detectors) → never gate-flagged.
7. round-engine: the four frontier tests in §2F pass.
8. per-run selection: a run prompts for personas/lens/viewport, defaults sensibly, runs each persona under the discipline.

## 6. Out of scope / follow-ons
- Measuring role/authz recall against a live `innovation` app (2B.5) — needs that app stood up.
- A multi-role synthetic authz fixture (would make role/authz recall deterministically measurable).
- Clipboard/paste emulation depth.

## 7. Invariant traceability (nothing existing breaks)
- Verdicts stay `pass|fail|blocked|deferred|error`; `human-action` is an evidence **kind**, not a verdict.
- Oracle stays the spec/domain rule and arbitrates correct-rejection vs bug.
- The gate **extends** `checkpoint.sh` (adds `human-action` + action-trace); ADR-0002 file-state, ADR-0003 sequential default unchanged.
- Read-only `browser_evaluate`/probing remain allowed (observation); only the **act path** is constrained.
- Persona-keyed checkpoint (Phase 2) and viewport config (Phase 5) are reused, not rebuilt.

## 8. Decomposition for the plan (so it's one coherent build)
Suggested task order for writing-plans: (1) ADR-0015; (2) `frontier` module + tests (2F); (3) action-trace + `session.md` reconciliation (Check 0) + `human-action` gate in `checkpoint.sh` + tests (incl. a concealed-workaround fixture: session.md shows an evaluate-set the trace omits → REJECT); (4) `generating-qa-checklist` derives `human-action`; (5) `interaction-discipline.md` + `driving-browser-qa` rules (launch with `--save-session`, copy `session.md` into the run dir) + reconciliations (2C) + the driver-optimization rules (§9); (6) opt-out + config (2E) + the isolation/origin config (§9); (7) orchestrator per-run selection wiring (2D) consuming the frontier module; (8) fixture cases + re-measure (§5); (9) review pass over the round-engine + confirming-discovered-roles.

---

## 9. Driver optimization (Playwright + Playwright-MCP) — citation-backed, folded from research

No contradictions with what's built; read-only `browser_evaluate` for observation stays sanctioned; per-persona isolation is confirmed as the right direction. Adopt:

- **9.1 Session-scoped isolation (governance) — NOT blanket per-persona, NOT per-criterion.** The isolation boundary is the **authenticated session/identity**, not the criterion and not the data:
  - **One isolated context per (identity, session)** with its own `storageState`, **reused across all that session's criteria** (never torn down per criterion). A single user holding multiple roles (e.g. a `user+evaluator` account) is **one** session = one context.
  - **Handoff / collaborative journeys are supported and expected:** personas act in **separate sessions over a SHARED backend** (participant submits → evaluator reviews → jury scores the *same* entity). Isolating the session never isolates the data — the entity flows across roles through the common DB. So handoffs need distinct sessions, not distinct backends.
  - **Isolation is *required* only where the test is about cross-session visibility** — cross-role/authz negative tests ("B must not see A's data"), and same-identity concurrency/race (two contexts, same auth). Elsewhere it's a default, overridable when a scenario models one continuous session.
  - **Resource discipline (this is why "spawn N contexts" is wrong):** under sequential-by-default (ADR-0003) **≈1 context is open at a time** — the active persona's — created **lazily** when its scenario runs and recycled/torn down on handoff to the next. Parallel fan-out holds **≤ `maxParallel`** contexts. Add a `maxOpenContexts` config guard (default = the effective concurrency). Memory stays bounded no matter how many personas a project has.
  - Mechanism: `--isolated` (in-memory profile) or a per-session `--user-data-dir`; **do NOT** use `--shared-browser-context` for fan-out (it trades away the isolation the cross-role tests depend on). Wire into 2D + `.qa/config.json` (`personas[]` gain a `storageState`; add `maxOpenContexts`). *(playwright-mcp README/error-handling.)*
- **9.2 Origin lists are not a security boundary (governance).** `--allowed-origins`/`--blocked-origins` are routing convenience only and don't gate writes or redirects. State in the spec + config that **`allowApiWrites` + the disposable-env marker remain the ONLY write gate** — never treat an origin list as write-prevention. *(playwright-mcp CLI reference.)*
- **9.3 Formalize the locator fallback order (accuracy).** Make the Playwright-documented priority an explicit ordered rule in `driving-browser-qa`: **`data-testid` → ARIA role → user-facing label/text → CSS (last resort)**. *(playwright.dev class-locator.)* Reduces "matched the wrong element" false results; we already do this by prose — pin it.
- **9.4 `browser_route` is a GOVERNED capability, and a new workaround vector (accuracy + governance).** Network interception may stub **only non-under-test third-party/CDN dependencies** to reduce flakiness; **stubbing/mocking the backend-under-test is a forbidden workaround** (it manufactures a pass and violates oracle-independence). Add `browser_route` to the workaround-detection set (see algorithms A1) — a route that intercepts the tested backend is treated exactly like an evaluate-write. Not in the allowlist by default; opt-in per §2E with a reason.
- **9.5 Evidence under governance.** Playwright trace/HAR need `run_code_unsafe` (banned) → out of reach; that's an accepted tradeoff, not a gap. `browser_network_request(s)` bodies + screenshots remain the MCP-native evidence primitives we already use.
- **9.6 Web-first waiting.** Our `browser_wait_for` + re-observe is the correct MCP analog of Playwright's auto-retrying `expect()`; keep it (no manual `isVisible()`-style one-shot reads on the act path).
