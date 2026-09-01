# 0015. Human-Interaction Discipline — act through the UI only, UI-impossible is a bug

Status: Accepted
Date: 2026-08-31

## Context
The QA agent could pass a criterion by driving the app through non-human paths
(`browser_evaluate` setting `.value`/clicking, `run_code_unsafe`, direct
localStorage/API writes, URL-skipping a gated step). That manufactures greens a
real user could never reach, and hides genuine FE defects (a missing/broken
affordance). The agent must behave like a human tester and never work around the UI.

## Decision
1. Every criterion runs **Arrange → Act → Assert**. The **Act** phase (the
   action-under-test) uses ONLY human-path tools (click/type/fill/press/select/
   hover/drag/file_upload + real link/button nav). **Observe** may read anything
   (read-only `browser_evaluate`, console/network, screenshots, read-only probe).
2. If the action-under-test cannot be done through a real affordance, that IS a
   bug: **`fail @ FE`, confidence `high`** — never `blocked`, never a workaround.
   The **oracle** distinguishes UI-impossible (bug) from a control correctly
   rejecting invalid input (pass).
3. Enforcement is a new evidence **kind `human-action`** on the Phase-1 gate
   (`checkpoint.sh`). Its artifact is `action-trace.json`. The gate reconciles the
   agent's self-reported act steps against Playwright MCP's INDEPENDENT
   `--save-session` `session.md` (parsed to JSON): a mutating call present in the
   session log but absent from the self-reported act trace is a **concealed
   workaround → REJECT**. This closes the self-report hole (the agent cannot grade
   its own homework). Residual trust: phase attribution is still agentic, bounded
   by the independent act-window and an optional reviewer spot-check.
4. A per-criterion **`nonUiActionReason`** logs a genuine tool limitation (e.g.
   `browser_type` coercing `-500` on `type=number`), permitting the workaround for
   that criterion at **confidence `low`**. A run whose opt-out rate exceeds ~20% of
   `human-action` criteria is flagged (opt-out-abuse guard).
5. Isolation boundary is the **(identity, session)**, not the criterion and not the
   data: one context per session, reused across its criteria; handoffs use separate
   sessions over a SHARED backend; ≈1 context open at a time under ADR-0003;
   `maxOpenContexts` caps fan-out.

## Consequences
- `react-set-input.js` and `click-by-text.js` are demoted to read-only helpers;
  act-path value entry/clicks use `browser_type`/`browser_fill_form`/`browser_click`.
- F4 (negative-share entry) uses the logged opt-out (tool limitation), staying
  catchable at confidence `low`.
- `browser_route` intercepting the backend-under-test is a forbidden workaround
  (manufactures a pass, violates oracle-independence).
- Verdict enum, oracle rule, ADR-0002 file-state, and ADR-0003 sequential default
  are unchanged. `human-action` is a kind, not a verdict.

## Gate strength & residual-trust boundary (honest)

**Deployment reality — Check 0 is OPT-IN.** Check 0 needs Playwright MCP's `--save-session`
`session.md`. We could not ship that as a plugin-bundled MCP server: a plugin-bundled
`@playwright/mcp` server connects but its tools do not resolve for the bundled agent
(a Claude Code plugin-MCP limitation with a hyphenated plugin name / duplicate-package
dedup — verified empirically: the agent received zero browser tools). So the agent uses
the standard `playwright` MCP (the official plugin), and `--save-session` is an **opt-in**
the operator enables on that server. When a fresh `session.md` is present the gate runs the
full quartet below; when it is not (the default), the gate runs **Check 1∧2∧3** and the
report flags that independent-log verification (Check 0) was unavailable.

The `pass` predicate for a `human-action` criterion (Check 0 present) is `Check0 ∧ Check1 ∧ Check2 ∧ Check3`:
- **Check 1/2** — no act-phase step is a workaround tool; a `browser_evaluate` on the
  act path is judged by whether its payload mutates (a payload lint covering DOM /
  storage / **network** (fetch/XHR/beacon with a write method) / **framework**
  (dispatch/setState) writes).
- **Check 0** — every mutating `evaluate`/`route` call in the **real** `session.md`
  (`--session-log`, derived by the gate via `parse-session-log.js`, not an
  agent-written array; `--session-from` is bounded against the parsed length) must
  be **content-matched** (squash + inner-source equality) to a recorded step, else
  it is a concealed workaround.
- **Check 3** — before/after persisted-state **fingerprints are MANDATORY**; if state
  changed across the act while **any** non-human-path act step is present, the change
  is unattributed to the UI → reject. This is the tool-agnostic backstop for an
  arbitrary app mutator the payload lint cannot enumerate.

**Residuals (accepted, not hidden):**
- **Phase framing is agent-supplied.** A real mutation disclosed as an `arrange`
  step (with a human-path decoy `act`) is treated as "disclosed" by Check 0 and,
  because the act phase is then all human-path, by Check 3. Reviewer spot-check is
  the backstop. (The gate catches *concealment* and *act-phase* non-UI mutation
  by machine; it does not adjudicate a plausibly-mislabeled phase.)
- **`nonUiActionReason` is an unvalidated escape hatch.** A logged opt-out accepts
  any string and short-circuits Checks 0-3 at `confidence: low`; the only automated
  control is `maxOptOutRate` (a rate flag on the run), by design.
- **`--session-log` path + `--session-from` are agent-supplied.** File-sourcing
  raises the bar decisively over a hand-written JSON array (tampering now requires
  forging the actual `session.md` on disk), but a fully-adversarial agent that
  controls the filesystem could still doctor the file. Check 3's fingerprints, the
  rate-capped opt-out, and the reviewer spot-check are the layered mitigations.

The gate is **tamper-evident by machine for the concealment and act-phase attack
classes**, with the above as the explicitly-scoped residual trust — not a
cryptographic guarantee.

## Decision on the residuals R3/R4/R5 (reviewed, closed-out)

The gate's threat model is an **honest agent taking a shortcut or making a mistake**, not a
deliberately-adversarial agent. Under that model:

- **R3 (unvalidated `nonUiActionReason`) — ACCEPT.** The opt-out is a human-review escape hatch by
  design; `maxOptOutRate` flags abuse. Validating the reason string against a fixed vocabulary of
  "real tool limitations" would be brittle and add no honest-agent value. No change.
- **R5 (agent-supplied `--session-log` path / `--session-from`) — ACCEPT (defer full closure).**
  `--session-from` is already length-bounded (N1). Full independence (the gate reading a
  config-anchored canonical `session.md` location rather than an agent argument) is a follow-up;
  its value is limited today because **Check 0 is opt-in** (`--save-session` is not the default),
  so the path only matters when the operator has deliberately enabled the strongest check anyway.
- **R4 (phase-mislabel: disclose a mutation as `arrange` + a decoy human-path `act`) — ACCEPT,
  with a scoped future closure.** Closing it cleanly needs **act-boundary fingerprints** (state
  captured immediately before AND after the act phase, then Check 3 verifies the act ITSELF caused
  the persisted change — a human-action whose act phase produced no state change while state
  changed during arrange is a mislabel/decoy). That is a moderate addition (action-trace shape +
  agent capture + check logic + tests) defending against a *deliberately-adversarial* agent — out
  of the honest-agent threat model. Deferred as a documented enhancement, not shipped now.

**Net:** the three residuals are reviewed and accepted as the explicit, scoped tamper-evidence
boundary. The gate remains machine-tamper-evident for concealment (Check 0, when enabled) and
act-phase non-UI mutation (Check 1/2/3); phase-framing honesty is the reviewer-spot-check residual.
