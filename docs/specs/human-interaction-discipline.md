# Spec — Human-Interaction Discipline (the QA agent behaves like a human tester, never an AI that works around the UI)

**Status:** Proposed (2026-08-31). Pairs with a new ADR-0015 and a granular implementation plan.

---

## 0. Goal (verbatim intent — the north star this spec serves)

> Each project has **defined roles**, and in each run we **select the roles used and what each role does with a proper scenario**. Each testing agent is a **human look-and-feel QA tester, not an AI agent trying any workarounds / non-actual-UI ways to pass** — for example, if something could **not** be done using the actual UI, it does **not** use the Playwright API or the terminal to force it; it **flags that as a bug**. It also **identifies UI/UX bugs a real human eye would catch**, and it **exercises real user journeys**.

Most of that goal already ships (see §2). This spec adds the **one missing, load-bearing piece**: the *Human-Interaction Discipline* — the agent may only accomplish the **action under test** through genuine, human-usable UI affordances. Anything the UI genuinely cannot do is a **finding**, never a thing to route around with `browser_evaluate`, the Playwright API, the terminal, the DB, or direct state mutation.

**One-line invariant:** *Act like a human, observe like a machine.* The **act** path is UI-only; the **observe** path may read anything (read-only).

---

## 1. Why (the problem this closes)

A false-green has two shapes. Phase 1 killed the first (declaring `pass` without evidence). This spec kills the second:

**Verification laundering** — the agent *establishes or performs the state under test through a non-UI path*, so a broken/absent UI still "passes." Concretely, the plugin does this today:
- `skills/driving-browser-qa/scripts/react-set-input.js` **sets an input's `.value`** via `browser_evaluate` (native setter + dispatched events) — used generally for React inputs and specifically to force out-of-range values like `-500` (see `driving-browser-qa/SKILL.md` §"Out-of-Range / Negative Numeric Inputs"). A human never sets `.value` programmatically; they type.
- `skills/driving-browser-qa/scripts/click-by-text.js` can invoke `.click()` on a resolved element via `browser_evaluate` — a programmatic click, not a real one.
- `browser_evaluate` is available for the act step (`driving-browser-qa` step 2: *"Click… or inject a script (browser_evaluate, e.g. react-set-input.js)"*).

Each is a legitimate *tool convenience* that becomes **cheating** when it accomplishes the user's action instead of the user's affordance. If a form field won't accept `-500` by keyboard, forcing `-500` via `.value` tests the *server* while **hiding that the UI itself blocks (or fails to block) the input a human would attempt**. The human-QA answer is the opposite: try it as a person, and if the person can't do the thing the spec says they should be able to do, **that is the bug**.

---

## 2. What already ships (so this spec is scoped to the gap, not a rebuild)

| Goal clause | Status | Where |
|---|---|---|
| Defined roles per project | ✅ built | `discovering-user-roles` (two-plane discovery) |
| Per-run role selection + scenarios per role | ⚠️ mechanism built, **per-run selection documented as a grilling round but not wired into the orchestrator**, and never measured against a live multi-role app (2B.5 deferred) | `confirming-discovered-roles`, ADR-0011/0012, `references/hitl-rounds.md` |
| Cross-role "role B must not see role A's data" | ✅ built (relational-FK) | `generating-qa-checklist` Step 6, ADR-0012 |
| Human window look-and-feel (viewport) | ✅ built | `viewport` config + `browser_resize` (ADR-0008) |
| UI/UX human-eye bugs | ✅ built + measured (U1/U3/U4) | `detecting-visual-ux` (ADR-0007) |
| Real journeys | ✅ built + measured (100% broken-journey recall) | `walking-multistep-flows`, coverage catalog |
| **Act-through-UI-only / no workarounds / UI-impossible = bug** | ❌ **not built — THIS SPEC** | new invariant + ADR-0015 |

This spec **also** requires closing the two role-related gaps above (per-run selection wiring; a measured authz run) so the *whole* goal is real, but its center of gravity is the new interaction invariant.

---

## 3. Ubiquitous language (add to CONTEXT.md)

- **Action-under-test** — the specific user action a criterion verifies (e.g., "add a founder with 0 shares", "finalize the round", "enter -500 in Shares"). Distinct from setup and from observation.
- **Affordance** — a visible, human-operable UI control (button, link, input, select, drag handle, file picker) with which a person performs the action-under-test.
- **Human-path interaction** — accomplishing the action-under-test only through affordances, using genuine input capabilities: `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_select_option`, `browser_hover`, `browser_file_upload`, `browser_drag` (+ real navigation via a link/button, not a typed URL that skips a gate).
- **Workaround** — accomplishing the action-under-test through a non-affordance path: `browser_evaluate`/`browser_run_code_unsafe` that sets values, calls app functions, dispatches synthetic events, or invokes `.click()`; a direct localStorage/DB/API write; a URL jump past a gated step; any injected state. **Forbidden on the act path.**
- **Observation** — reading state to form/verify a verdict: read-only `browser_evaluate` (getComputedStyle, `localStorage.getItem`, DOM queries, the UX detectors), `browser_console_messages`, `browser_network_request(s)`, `browser_take_screenshot`, `browser_snapshot`, an authenticated **read-only** fetch (`probing-apis-through-browser`). **Always allowed; never mutates.**
- **UI-impossible** — the action-under-test cannot be completed through any human-path affordance (control missing, disabled with no unlock path, broken handler, unreachable step). Under the spec this is a **`fail`**, not a `blocked`.

---

## 4. The invariant, as Arrange–Act–Assert

Every criterion runs in three phases with **different tool rights**:

### 4.1 Arrange (reach the precondition)
Getting to the starting state that isn't itself under test — logging in as a persona, seeding a disposable env, navigating to the feature.
- **May** use seeded credentials / storageState / disposable-env seeding / real navigation. May use API/DB **only** in a disposable env with `allowApiWrites` + the disposable marker (existing rule) and **only for setup that is not the action-under-test**.
- **Must** record what was arranged (so a later reader can tell setup from act).

### 4.2 Act (perform the action-under-test) — **UI-ONLY, no exceptions without an explicit, logged opt-out**
- **Must** use only human-path interactions on real affordances.
- **Must NOT** use `browser_evaluate`/`run_code_unsafe` to set values, click, call functions, dispatch events, or mutate state; must not write via API/DB/terminal/localStorage; must not URL-skip a gated step.
- If the affordance needed to perform the action **does not exist, is disabled with no human unlock, or its handler is broken** → the action is **UI-impossible** → record a **`fail`** (see §6). Do **not** switch to a workaround to "complete" it.
- **Entering values is a keystroke action**: use `browser_type`/`browser_fill_form`/`browser_press_key`. If genuine typing does not land the value, that is either (a) a real UI/app defect a human would hit → a finding, or (b) a driver limitation → see the §7 reconciliation — it is **not** license to `.value`-force.

### 4.3 Assert / Observe (form the verdict) — read-only, anything goes
- Bake (read persisted state back), independently recompute against the oracle, run the visual-UX detectors, read console/network, screenshot. All read-only. This is where the existing Phase-1 evidence gate applies unchanged.

---

## 5. Allowed / forbidden tool matrix

| Capability | Arrange | **Act (action-under-test)** | Assert / Observe |
|---|---|---|---|
| `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_select_option`, `browser_hover`, `browser_file_upload`, `browser_drag` | ✅ | ✅ **(the only way to act)** | n/a |
| `browser_navigate` to a link/button destination reached via UI | ✅ | ✅ (following a real link) | n/a |
| `browser_navigate` typed-URL that **skips a gated step** | ⚠️ arrange only, never to reach the tested state | ❌ | n/a |
| `browser_evaluate` **read-only** (getComputedStyle, localStorage read, DOM query, UX detectors, observe-round) | ✅ | ❌ for acting | ✅ |
| `browser_evaluate` **that sets `.value` / clicks / calls app fns / dispatches events** (react-set-input, click-by-text `.click()`) | ❌ | ❌ **(the banned workaround)** | n/a |
| `browser_run_code_unsafe` | ❌ (already out of allowlist) | ❌ | ❌ |
| Direct API/DB/localStorage **write** | ⚠️ disposable-env setup only (`allowApiWrites`+marker), never the action-under-test | ❌ | ❌ |
| Read-only API fetch / network body / probe | ✅ | n/a | ✅ (diagnose when UI lies — never to perform) |
| `browser_take_screenshot`, `browser_snapshot`, `browser_console_messages` | ✅ | n/a | ✅ |

**click-by-text / RTL targeting**: allowed to *find* the element (read), then act via `browser_click` on the resolved selector — **not** by calling `.click()` inside evaluate.

---

## 6. "UI-impossible = bug" — verdict & layer mapping

When the action-under-test cannot be completed by a human-path interaction:

- **Verdict `fail`** (never `blocked` — `blocked` is for environment/precondition gaps, e.g. the app is down or creds are missing; a missing/broken affordance for a **spec'd** action is a product defect).
- **Suspected layer**: `FE` when the affordance is absent/disabled/misrendered or its handler throws; `route` when the control points to the wrong place; `service`/`DB` only when the affordance works, the action is performed, and the failure is downstream (established via observation/bake).
- **Confidence `high`** (it is directly observable — the human simply could not do it).
- **Evidence**: a screenshot of the surface + the enumerated affordances (from the observe-round `domDigest.interactive`) showing the required control is missing/disabled/broken, plus (for a broken handler) the console error.

**Boundary case — the affordance *correctly* prevents an invalid action** (e.g. a number field that refuses letters): that is *not* a bug; it is expected. The distinction is **spec-relative**: `fail` only when the spec/oracle says the user *should* be able to perform the action and cannot. If the spec says the input should be rejected and the UI rejects it → `pass` (observed the rejection through the human path). This is why the oracle stays the arbiter (unchanged invariant).

---

## 7. Reconciliations (the hard, already-shipped cases this spec must fix)

### 7.1 `react-set-input.js` (evaluate-set) — the primary offender
- **New rule:** the act path uses `browser_type`/`browser_fill_form` (Playwright's fill *does* dispatch the input/change events React needs — the historical "React discards typed values" claim is largely a fill-vs-type nuance, not a reason to `.value`-force).
- `react-set-input.js` is **demoted to observation/diagnostic only** — it may be injected to *read back* a field's value, never to *set* the value that the action-under-test depends on.
- The one legacy legitimate use (a genuinely un-typeable field due to a *tool* bug, not an app bug) requires the explicit, logged opt-out in §9; otherwise a field a human cannot type into is itself a finding.

### 7.2 Out-of-range / negative numeric entry (the F4 case) — reframed honestly
Old behavior forced `-500` via `.value` to test server validation, which **hid the UI's own behavior**. New behavior:
1. Attempt entry **as a human**: `browser_type` `-500` (and, if a person plausibly would, paste via clipboard/`browser_press_key`).
2. **Read the field back** (observation) to see what the human input actually produced.
3. Judge against the oracle **on the human-observed value**:
   - Field holds `-500` and the app accepts it → `fail @ service` (missing validation) — as before, but now *honestly reached through the UI*.
   - Field coerces/blocks `-500` on keystroke → the UI **prevented** negative entry. If the spec wanted server-side rejection tested and the UI makes negatives unreachable, record it as **`deferred` with the reason "not reachable via human input; server-side negative validation untestable through the UI"** OR a `fail @ FE` if the spec expects the field to accept-then-reject — the oracle decides. **Do not `.value`-force to manufacture a verdict.**
- Net: F4 may become *harder* to auto-detect via pure UI — that is correct. The seed/fixture may need an affordance a human *can* use to submit a negative (so the test is human-reachable), which is itself a truer test.

### 7.3 `click-by-text.js` — find via evaluate, act via `browser_click`
Keep it for locating an element by RTL/label text (read), but the click must be `browser_click` on the resolved selector, not an in-evaluate `.click()`.

---

## 8. Enforcement — the No-Workaround Gate (extends the Phase-1 evidence gate)

The invariant is worthless if unenforced. Make it machine-checkable, reusing the Phase-1 chokepoint (`checkpoint.sh`):

- Each **action-bearing** criterion records an **action-trace** evidence artifact: `evidence/[<persona>/]<crit>/action-trace.json` = the ordered tool calls that performed the action-under-test, each `{tool, target, phase: "arrange"|"act"|"assert"}`.
- A new evidence **kind `human-action`** (derived by `generating-qa-checklist` for any criterion whose action mutates state or drives a control): a `pass` requires the `action-trace` to show the **act-phase** steps used only human-path tools. If any act-phase step used `browser_evaluate`(setting)/`run_code_unsafe`/a direct write, the gate **rejects the pass** with: *"act performed via workaround `<tool>`; perform through the UI or record the UI-impossibility as a fail."*
- The observe-round already distinguishes observe vs act; extend it to **tag each act call's phase** so the trace is producible without new instrumentation cost.
- Advisory/observation-only tools never appear in the act phase, so read-only `evaluate` is unaffected.

This is additive to Phase 1: `human-action` joins `bake|computed|probe` in the Kind→kinds mapping; no new verdict; no change to `pass|fail|blocked|deferred|error`.

---

## 9. Config & the (rare, logged) opt-out

- **Strict by default.** No global switch to disable the discipline.
- Per-criterion escape hatch mirroring `allowApiWrites`: a criterion may carry `nonUiActionReason: "<why a human-path is genuinely impossible AND this is a tool limitation, not an app defect>"`. When set, the gate permits a workaround **for that criterion only**, records the reason in the report, and marks the criterion's confidence `low`. Absent a reason, workarounds on the act path are gate-rejected. This keeps an honest release valve without letting it become the default.
- `.qa/config.json`: `"humanInteraction": { "enforce": true }` (default true) so a team can audit-only during migration, never silently off.

---

## 10. Ties to the rest of the goal (roles + human look-and-feel)

- **Per-run role selection + scenarios (close the 2B gap):** wire the documented grilling round (`references/hitl-rounds.md`) into the orchestrator's pre-run — the operator picks *which discovered personas run this pass* and confirms *each role's scenario* (the role-sensitive criteria + cross-role pairs). Default: all discovered personas, default lens, default viewport. Each persona then runs its scenario **under this same human-interaction discipline**, as that persona (persona-keyed checkpoint already exists).
- **Human look-and-feel:** the discipline *is* the "human feel" — real viewport (shipped), natural reading/interaction order, genuine input, no fake timing. The review **lens** (skeptical-auditor / first-time-user / a11y-user) shapes *what the human notices*; the discipline governs *how the human acts*.
- **UX human-eye + real journeys:** unchanged (shipped); the discipline ensures the journey is walked the way a user walks it.

---

## 11. Acceptance criteria (how "done" is proven — all on the fixture unless noted)

1. **Workaround is gate-rejected:** a criterion whose act-phase used `react-set-input` (evaluate-set) to accomplish the action-under-test → `checkpoint.sh … pass` is **rejected**; the run must either perform it via the UI or record a UI-impossibility `fail`.
2. **UI-impossible → fail, not blocked:** seed a fixture surface where a spec'd action has a *missing/disabled/broken* affordance; the agent records `fail @ FE` (high confidence) with the missing-affordance evidence — and does **not** evaluate-around it.
3. **Correct-rejection → pass:** a field that correctly rejects an invalid human input (per the oracle) yields `pass`, reached through the human path.
4. **F4 reconciled:** the negative-shares criterion is judged on the human-observed field value (typed/pasted + read-back), never on an evaluate-forced value; the verdict matches §7.2.
5. **No recall regression:** the full gated fixture re-measurement stays at its current level (functional 100% / overall 92%) **or** any drop is an honest "now correctly unreachable via UI" recategorization, explicitly logged — not a silent loss.
6. **Read-only observation unaffected:** baking (localStorage read), the observe-round, and the UX detectors (read-only evaluate) still work and are never gate-flagged.
7. **Per-run role selection wired:** a run prompts (grilling round) for the personas/lens/viewport to use, defaults sensibly, and runs each persona's scenario under the discipline. (Measuring authz recall against `innovation` remains the separate 2B.5 follow-on.)

---

## 12. Out of scope / follow-ons
- Measuring role/authz recall against the live `innovation` app (2B.5) — needs that app stood up.
- A multi-role synthetic authz fixture (for deterministic authz recall) — optional, could make #7 measurable without `innovation`.
- Clipboard/paste emulation depth (if a "human would paste" path is needed for some inputs).

## 13. Invariant traceability (nothing existing is broken)
- Verdicts stay `pass|fail|blocked|deferred|error`; `human-action` is an evidence **kind**, not a verdict.
- Oracle stays the spec/domain rule and remains the arbiter of correct-rejection vs bug.
- The gate **extends** `checkpoint.sh` (adds `human-action` kind + action-trace); ADR-0002 file-state and ADR-0003 sequential default unchanged.
- Read-only `browser_evaluate` and probing remain allowed (observation); only the **act path** is constrained.
- New ADR-0015 records: act-through-UI-only, UI-impossible=fail, the no-workaround gate, the react-set-input/click-by-text/F4 reconciliations, and the logged per-criterion opt-out.
