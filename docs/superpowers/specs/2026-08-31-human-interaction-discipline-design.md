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
- **Honest trust model (stated, not hidden):** the gate validates the agent's *recorded* trace; the **agentic rules** (skill prose) make the agent record honestly; an optional reviewer/adversarial pass spot-checks. Belt-and-suspenders, not a cryptographic guarantee.

### 2C. Reconciliations of shipped workarounds
- `react-set-input.js` → **demoted to read-only** (reads a field's value back; never sets the value the action depends on). Act-path value entry uses `browser_type`/`browser_fill_form`.
- `click-by-text.js` → finds an element by RTL/label text (read); **acts via `browser_click`** on the resolved selector, not in-evaluate `.click()`.
- **F4 / out-of-range numeric** → treated as a genuine **tool limitation** (`browser_type` transiently coerces `-500` on `type=number`; a human types it fine): use the **logged opt-out** — enter via evaluate-set WITH `nonUiActionReason: "tool: browser_type coerces -500 on type=number"`, confidence `low`, reason in the report. F4 stays catchable and honest.

### 2D. Per-run role/scenario selection wiring (closes 2B.5-adjacent gap)
Orchestrator pre-run invokes the round engine (§2F): pick which discovered **personas** run this pass, confirm each role's **scenario** (its role-sensitive criteria + cross-role pairs), choose **lens + viewport**. Defaults: all discovered personas / `skeptical-auditor` / `1440×900`. Each persona then runs its scenario **under the discipline**, persona-keyed (existing).

### 2E. Opt-out + config
- Per-criterion `nonUiActionReason: "<why the human-path is a tool limit, not an app bug>"` → gate permits the workaround for that criterion, forces confidence `low`, prints the reason. Absent → workarounds gate-rejected.
- `.qa/config.json` `"humanInteraction": {"enforce": true}` (default true; audit-only fallback for migration, never silently off).

### 2F. Hardened round-engine (C — turns the grilling pattern from prose into a proven unit)
Today `references/hitl-rounds.md` describes the pattern; nothing verifies it. Make it a small **testable frontier-state unit**:
- A `frontier` module (dependency-free) over three sets — `settled`, `frontier` (decisions whose prerequisites are settled), `deferred` (blocked on an open decision) — with operations: `computeFrontier(tree, settled)`, `apply(answer) → recompute`, `budgetExceeded()`.
- The role-confirmation flow (`confirming-discovered-roles`) drives it: each round renders `frontier` as numbered items **each with a recommended default**, applies answers, recomputes.
- **Tests** (fixture-level): (a) a dependent decision (credentials) surfaces ONLY after its prerequisite (roles) is settled; (b) every frontier item carries a recommended default; (c) editing an answer recomputes the frontier; (d) past the round budget it logs assumptions and proceeds (never blocks).
- **Independent review** of `hitl-rounds.md` + `confirming-discovered-roles` as part of this work (they shipped review-free in the loop).

### 2G. ADR-0015
Records: act-through-UI-only + UI-impossible=fail; the No-Workaround Gate (`human-action` kind + action-trace + trust model); the react-set-input/click-by-text/F4 reconciliations; the logged opt-out; the hardened round-engine; and the per-run role-selection wiring.

---

## 3. Data flow
`criterion → arrange(setup) → act(UI-only; each step appended to action-trace with phase) → assert(observe/bake/recompute/detect) → record-evidence(bake|computed|probe + action-trace) → checkpoint … pass --kinds …,human-action [--persona P]` → **gate: every act-phase step ∈ human-path tools OR nonUiActionReason present, else reject.**

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
Suggested task order for writing-plans: (1) ADR-0015; (2) `frontier` module + tests (2F); (3) action-trace + `human-action` gate in `checkpoint.sh` + tests; (4) `generating-qa-checklist` derives `human-action`; (5) `interaction-discipline.md` + `driving-browser-qa` rules + reconciliations (2C) + the driver-optimization rules (§9); (6) opt-out + config (2E) + the isolation/origin config (§9); (7) orchestrator per-run selection wiring (2D) consuming the frontier module; (8) fixture cases + re-measure (§5); (9) review pass over the round-engine + confirming-discovered-roles.

---

## 9. Driver optimization (Playwright + Playwright-MCP) — citation-backed, folded from research

No contradictions with what's built; read-only `browser_evaluate` for observation stays sanctioned; per-persona isolation is confirmed as the right direction. Adopt:

- **9.1 Per-persona isolation (governance).** Run each persona in an **isolated context with its own `storageState`** — Playwright-MCP `--isolated` (in-memory profile) or a per-persona `--user-data-dir` — so personas in one run never bleed session/storage/auth state. *(playwright-mcp README/error-handling.)* Wire into 2D + `.qa/config.json` `drivers[]`/`personas[]`. Do **NOT** use `--shared-browser-context` for fan-out (trades away the isolation the cross-role tests depend on).
- **9.2 Origin lists are not a security boundary (governance).** `--allowed-origins`/`--blocked-origins` are routing convenience only and don't gate writes or redirects. State in the spec + config that **`allowApiWrites` + the disposable-env marker remain the ONLY write gate** — never treat an origin list as write-prevention. *(playwright-mcp CLI reference.)*
- **9.3 Formalize the locator fallback order (accuracy).** Make the Playwright-documented priority an explicit ordered rule in `driving-browser-qa`: **`data-testid` → ARIA role → user-facing label/text → CSS (last resort)**. *(playwright.dev class-locator.)* Reduces "matched the wrong element" false results; we already do this by prose — pin it.
- **9.4 `browser_route` is a GOVERNED capability, and a new workaround vector (accuracy + governance).** Network interception may stub **only non-under-test third-party/CDN dependencies** to reduce flakiness; **stubbing/mocking the backend-under-test is a forbidden workaround** (it manufactures a pass and violates oracle-independence). Add `browser_route` to the workaround-detection set (see algorithms A1) — a route that intercepts the tested backend is treated exactly like an evaluate-write. Not in the allowlist by default; opt-in per §2E with a reason.
- **9.5 Evidence under governance.** Playwright trace/HAR need `run_code_unsafe` (banned) → out of reach; that's an accepted tradeoff, not a gap. `browser_network_request(s)` bodies + screenshots remain the MCP-native evidence primitives we already use.
- **9.6 Web-first waiting.** Our `browser_wait_for` + re-observe is the correct MCP analog of Playwright's auto-retrying `expect()`; keep it (no manual `isVisible()`-style one-shot reads on the act path).
