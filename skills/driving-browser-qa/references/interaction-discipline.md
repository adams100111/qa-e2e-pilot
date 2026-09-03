# Interaction Discipline (ADR-0015)

The agent is a **human look-and-feel QA tester, never an AI that works around the UI to
pass**. If the action-under-test cannot be done through the real UI, that **is a bug** —
never something forced via `browser_evaluate`, the Playwright API, the terminal, or direct
state. This document is the human-readable discipline; the machine gate that enforces it
lives in `checkpointing-qa-memory`'s `checkpoint.sh` / `check-action-trace.js`.

## 1. Core invariant — "Act like a human, observe like a machine"

Every criterion runs **Arrange → Act → Assert**, each with distinct tool rights.

| Phase | What it is | Tool rights |
|---|---|---|
| **Arrange** | reach the precondition (login as persona, seed disposable env, navigate to the feature) — NOT the action under test | UI or seeded creds/storageState; API/DB writes ONLY in a disposable env (`allowApiWrites`+marker), never the action under test |
| **Act** | perform the **action-under-test** | **UI-ONLY**: `browser_click/type/fill_form/press_key/select_option/hover/drag/file_upload` on genuine affordances; real link/button navigation. **Forbidden:** `browser_evaluate` that sets `.value`/clicks/calls app fns/dispatches events; `browser_run_code_unsafe`; direct API/DB/localStorage write; URL-skip of a gated step |
| **Assert / Observe** | bake, recompute, detect | read-only anything: `browser_evaluate`-read (getComputedStyle, localStorage read, DOM query, UX detectors, observe-round), console/network reads, screenshot, read-only probe fetch |

**UI-impossible = `fail @ FE`** (confidence `high`), never `blocked`, never a workaround.
The **oracle** remains the arbiter: a control that *correctly* rejects an invalid input
(per the spec) is a `pass` reached through the human path; a missing/disabled/broken
affordance for a spec'd action is a `fail`.

A recorded `browser_evaluate` is read XOR mutate — never both. A read-only evaluate
(`getComputedStyle`, `*.getItem`, `querySelector*` reads, `return <expr>`) is OBSERVE and
always allowed, on any phase. A mutating evaluate (assignment to `.value`/`.checked`/
`.innerHTML`, a call to `.click()`/`.submit()`/`.dispatchEvent(`, a storage/network write)
found on the **act** path is a workaround and gate-rejected, regardless of intent.

## 1a. Durable act bracket (resumability)

A **mutating** criterion's Act phase is also bracketed in the Run journal, independent of
the UI-only discipline above — this is what makes a crash mid-act detectable on resume.
`checkpointing-qa-memory`'s `mutation-flag.sh derive <criterion-json>` (the same
agent-untrusted classifier §1's gate relies on) decides whether a criterion mutates;
`journal-emit.sh` brackets its act accordingly:

- **Before** the act (the human-path UI interaction itself): `journal-emit.sh act-intent
  <run-id> <scenarioId> <criterionId> <personaId> --criterion <criterion-json> --write-set
  <json>`. Derive-gated — a non-mutating criterion's call is a no-op (nothing journaled,
  prints `SKIP non-mutating`, exit 0). When mutating, it journals
  `act_intent{key:"<runId>:<scenarioId>:<criterionId>",writeSet}`.
- **Immediately after** the act completes: `journal-emit.sh act-commit <run-id>
  <scenarioId> <criterionId> <personaId> --outcome <landed|failed|unknown>`, journaling
  `act_committed{key,outcome}` for the SAME key.

The key is always `runId:scenarioId:criterionId` — never per-attempt, so a retried act
after resume reconciles against the same tuple rather than opening a new one. An
`act_intent` with no matching `act_committed` is an **open act**
(`fold.sh`'s `fold-anomalies.json.openActs`) — the exact signal a crash mid-act leaves
behind, and what resume reconciliation (write-set re-bake) consumes. This bracket is
purely an emission concern: it records that a mutating act happened and its outcome, it
does not weaken or replace the UI-only act-phase gate above — the act itself is still
performed exclusively via `browser_click`/`type`/`fill_form`/etc. on genuine affordances.

## 2. UI-impossible decision procedure

To perform action `A` needing affordance-spec `⟨role, label|testid, expected-effect⟩`:

```
E = visible interactive elements (from observe-round domDigest.interactive)
a = match(E, affordance-spec)
if a == ∅                              → UI-IMPOSSIBLE(missing)        → fail @ FE (high)
if a.disabled and no human unlock here → UI-IMPOSSIBLE(disabled)       → fail @ FE (high)
perform A via ACT_UI on a
if interaction throws / no-ops AND spec expects an effect
                                       → BROKEN-HANDLER (console err)  → fail @ FE (high)
if state changed (A completed):
       oracle_satisfied(observed) ?   → pass  :  fail @ localized-layer
if control REJECTED the input:
       spec_expects_rejection ?        → pass (correct-rejection) : fail @ FE (should-accept)
```

Every leaf is a verdict. The **oracle** distinguishes *UI-impossible* (bug) from
*correct-rejection* (pass) — the agent never decides that itself. Evidence for a
missing/disabled/broken affordance: screenshot + the enumerated affordances from
`domDigest.interactive` + any console error.

## 3. Reconciliations of shipped workarounds

- **`react-set-input.js`** → demoted to **read-only**. It reads a field's current
  `.value`/validity back for assertion; it never sets the value the action depends on.
  Act-path value entry uses `browser_type`/`browser_fill_form`.
- **`click-by-text.js`** → demoted to **resolve-only**. It finds an element by
  RTL/label text and returns its selector/metadata (or the existing
  `{ambiguous, count, candidates}` shape when several elements match); it never calls
  `.click()` in-evaluate. The act itself uses `browser_click` on the resolved selector.
- **F4 / out-of-range numeric** (e.g. `-500` on `type="number"`) → treated as a genuine
  **tool limitation**, not an app bug: `browser_type` can transiently coerce the value
  mid-entry (a human typing it does not hit this). Use the **logged opt-out**: enter via
  evaluate-set WITH `nonUiActionReason: "tool: browser_type coerces -500 on type=number"`,
  which forces confidence `low` and prints the reason in the report. F4 stays catchable
  and honest — it is not silently swept under a workaround.

## 4. Driver-optimization rules (§9)

- **Locator fallback order (accuracy).** Resolve elements in this priority, matching
  Playwright's own guidance: **`data-testid` → ARIA role → user-facing label/text →
  CSS (last resort)**. Reduces "matched the wrong element" false results.
- **`browser_route` is governed, not banned.** Network interception may stub only
  **non-under-test third-party/CDN dependencies** to reduce flakiness. **Stubbing/mocking
  the backend-under-test is a forbidden workaround** — it manufactures a pass and
  violates oracle-independence. A `browser_route` that intercepts the tested backend is
  treated exactly like an evaluate-write and is gate-rejected on the act path; it is not
  in the allowlist by default and requires a `nonUiActionReason` to opt in.
- **Origin lists are NOT a write gate.** `--allowed-origins`/`--blocked-origins` are
  routing convenience only — they do not gate writes or redirects. `allowApiWrites` +
  the disposable-env marker remain the ONLY write gate; never treat an origin list as
  write-prevention.
- **Web-first waiting.** `browser_wait_for` + re-observe is the correct MCP analog of
  Playwright's auto-retrying `expect()`. Never do a manual one-shot `isVisible()`-style
  read on the act path — wait, then re-observe.
- **Session-scoped isolation.** The isolation boundary is the **(identity, session)**,
  not the criterion and not the data: one context per session, reused across that
  session's criteria (never torn down per criterion). Isolation is required only where
  the test is about cross-session visibility (cross-role/authz negatives, same-identity
  concurrency/race) — elsewhere it's a default, overridable when a scenario models one
  continuous session. Under sequential-by-default (ADR-0003) ≈1 context is open at a
  time; parallel fan-out holds ≤ `maxParallel`, guarded by `maxOpenContexts`.

## 5. Clock / time-travel discipline (#7)

The act must run against **real wall-clock time**. A QA run must **never** mock, freeze, or
fast-forward the clock (`setTestNow`, `sinon.useFakeTimers`/`jest.useFakeTimers`, a
`Date.now =` override, `__defineGetter__` on `Date`, `mockdate`/`timekeeper`, or navigating
a clock-control route like `/__clock`/`/test/clock`/`?now=`) to force a time-dependent
assertion to pass. Forcing the clock manufactures a pass the same way stubbing the
backend-under-test does (§4) — it proves nothing about the real system, so it is banned by
doctrine exactly like an evaluate-write on the act path. This is a **doctrine ban, not a
hard gate**: generic time-travel detection is infeasible, so `capture-hook.sh` runs a
deterministic, best-effort pattern scan over every captured call and stamps
`advisory:"clock-control"` on a toolstream event that matches a known signal —
**advisory only**, it never blocks the call and never changes the hook's exit code. Treat
an `advisory:"clock-control"` line in the toolstream as a suspect signal worth a second
look during review, not proof of a violation on its own (a legitimate in-app feature under
test, e.g. an admin "set server time" tool, can trip the same pattern).

## 6. See also

- `../SKILL.md` — driver selection, the observe-round, the driver launch + delta-slice
  rule, and the React/RTL mechanics these helpers now support in a read-only/resolve-only
  role.
- `docs/adr/0015-human-interaction-discipline.md` — the accepted decision record.
