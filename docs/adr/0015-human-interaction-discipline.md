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
