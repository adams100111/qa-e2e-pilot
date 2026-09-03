# Honesty Fast-Follows (Plan H3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the honesty-hardening fast-follows that ride on top of the merged WS-1 (H1) + WS-3 sound core (H2): **persona-identity binding (#6)**, **clock/time-travel doctrine + advisory capture-flag (#7)**, the **WS-2 doctrine** completion (the 5 named arrange/probe exceptions + first-class phase-tag validation [C], and `--save-session` default-on [B]), and the **`humanInteraction.autonomousSetup` flag [T-14]** for headless/CI/`/loop` runs.

**Scope note — this is Plan H3 of the honesty-hardening effort (spec `docs/specs/2026-09-02-qa-honesty-hardening-design.md`, ADR-0018).** H1 shipped WS-1 #2/#4; H2 shipped the WS-3 sound core (capture-hook, block-hook, provenance, `qa-verify`). Plan H3 finishes the honesty program's fast-follows **except the Codex/opencode/Pi live-hook adapters (T-13)**, which are a separate documented port (each needs per-harness hook wiring + a manual enforcement run; the spec frames them as "documented fast-follows, not a 4× v1"). All Plan H3 logic lands in `scripts/`/`skills/` (copied verbatim into all four `dist/<h>/` trees by `build-adapter.sh`) — so it applies to every harness with no per-harness hook work; the clock-flag extends the already-wired Claude capture-hook.

**The honest tiers carry forward (per H1/H2):** the persona-identity check is best-effort (an opaque token/no-whoami app → `confidence: low` + "identity unverified" banner, per §5.5 — NOT blocked); the clock-flag is advisory (never gates; generic detection is infeasible — §7); the named exceptions LOOSEN the act-gate and so each is a documented, tag-required carve-out, not a blanket allow. `qa-verify` remains the authority.

**Architecture:** Persona-identity: an `evidence/<persona>/identity.json {persona, capturedSubject, method}` recorded via `record-evidence.sh identity`; `qa-verify` compares `capturedSubject` to the criterion's persona for persona-scoped/cross-tenant criteria → mismatch = **override to fail/blocked** (acting as the wrong user), absent = **degrade to `confidence: low`** + reason (the report's existing confidence:low plumbing renders it). Clock-flag: `capture-hook.sh` gains a deterministic pattern scan that stamps an `advisory:"clock-control"` field on a toolstream event whose args match known time-control signals (`setTestNow`, `/clock` routes, `fakeTimers`, `Date`-override in an evaluate) — advisory only, capture-hook still always exit 0. WS-2: add `persona-switch` + `out-of-band` to `check-action-trace.js`'s `NAV_CARVEOUTS`, validate the per-step `phase`/`carveout` against an enum (unknown value → fail-closed), and document all 5 named exceptions in `interaction-discipline.md`. Config: flip `humanInteraction.saveSession` default → true and add `humanInteraction.autonomousSetup` (both in `init-config.sh` + the example); `confirming-discovered-roles` reads `autonomousSetup` to proactively auto-accept setup rounds via `frontier.js recommendedDefault` (tagging `assumption:true`).

**Tech Stack:** Bash (`set -uo pipefail`), `jq`/`python3` fallback, dependency-free Node (`check-action-trace.js`, `frontier.js`), reusing H1/H2's `qa-verify.sh`/`capture-hook.sh`/`report-to-junit.sh`/`check-action-trace.js`/`record-evidence.sh`/`init-config.sh`/`confirming-discovered-roles`.

## Global Constraints

- **`jq`/`python3`/`die`; no new hard `node` dep;** reuse the existing dependency-free Node (`check-action-trace.js`, `frontier.js`). Honor `QA_ENGINE`. No `grep -P`/`perl`.
- **Persona-identity is a DEGRADE, not a hard fail, when identity is unverifiable** (opaque token / no whoami — §5.5): `confidence: low` + "identity unverified" reason, NOT blocked. A CAPTURED identity that MISMATCHES the persona → override to `fail`/`blocked` (acting as the wrong user is a real defect). Only persona-scoped / `cross-tenant` / `cross-role-fk-chain` criteria are identity-checked; `__shared__`/read-only are exempt.
- **Clock-flag is ADVISORY, never gates** (§7): the capture-hook stamps an advisory field; nothing blocks or fails on it; capture-hook still ALWAYS exit 0. Plus a doctrine ban line (agent must not time-travel). Graded "doctrine + best-effort flag," said plainly.
- **Named exceptions LOOSEN the gate — each is tag-required + documented, never a blanket allow.** Adding `persona-switch`/`out-of-band` to `NAV_CARVEOUTS` means an act-phase `browser_navigate` is allowed ONLY when the step is explicitly tagged with that carve-out; an untagged act-phase navigate stays fail-closed (the H1/H2 nav-fail-closed behavior). Validate the `phase`/`carveout` fields against an enum: an UNKNOWN `carveout` value → treat as NOT carved-out (fail-closed), never silently allow.
- **`--save-session` default flip is honest:** flipping `humanInteraction.saveSession` → true enables Check-0 reconciliation *when a session log is present*; Check-0 already degrades gracefully when it's absent (H1/H2). Claude still needs the operator to add `--save-session` to their own Playwright MCP (Claude has no bundled `mcp.snippet`) — document this plainly; do NOT claim Claude auto-captures the session log.
- **`autonomousSetup` respects operator-interruption discipline (decision #8):** it auto-accepts ONLY the pre-run SETUP rounds (`confirming-discovered-roles`), tagging each accepted item `assumption:true`; it NEVER affects the Verify loop (which already never interrupts). Default off (interactive).
- **Reuse the existing confidence:low/banner rendering** (`report-to-junit.sh` + `writing-qa-reports` templates) — Plan H3 only PRODUCES the identity/clock reasons; it does not rebuild the report surface.
- **Portability + byte-oracle:** logic under `scripts/`/`skills/` is copied verbatim; `core/persona-body.md` edits are byte-oracled (regenerate `agents/qa-e2e-pilot.md`). After edits: dist regen, `validate-adapters.sh` exit 0, `tests/portability/run.sh` `FAIL=0`. `dist/` git-ignored.
- **Commit messages: NO Claude/Anthropic attribution, NO `Co-Authored-By`.**

## Self-grilled decisions (my recommendations, applied)

- **Q1 persona-identity** → `record-evidence.sh identity` writes `evidence/<persona>/identity.json`; `qa-verify` compares to the criterion's persona (mismatch=override, absent=degrade confidence:low); doctrine instructs the whoami probe. Only persona-scoped/cross-tenant criteria checked.
- **Q2 clock-flag** → extend `capture-hook.sh` with a deterministic time-control pattern scan → `advisory:"clock-control"` on the event (advisory, exit 0) + doctrine ban.
- **Q3 named exceptions** → add `persona-switch`+`out-of-band` carve-outs to `check-action-trace.js`; validate `phase`/`carveout` enum (unknown → fail-closed); document all 5 in `interaction-discipline.md`.
- **Q4 save-session** → flip `saveSession` default true (config + init-config); honest Claude-operator note; Check-0 degrades when absent.
- **Q5 autonomousSetup** → `humanInteraction.autonomousSetup` bool → `confirming-discovered-roles` proactively auto-accepts setup rounds (recommendedDefault, assumption:true); default off; setup-only (decision #8).

---

### Task 1: Persona-identity binding (#6) — capture, check, degrade

Record a persona's captured identity and have `qa-verify` bind it to `--persona`: mismatch → override; absent → confidence:low.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/record-evidence.sh` — add an `identity` subcommand: `record-evidence.sh <run> <crit> identity --persona <id> --subject <captured-subject> --method <whoami|storageState|none>` → writes `evidence/<persona>/identity.json {persona, capturedSubject, method, recorded_at}`.
- Modify: `skills/checkpointing-qa-memory/scripts/qa-verify.sh` — for a `pass` on a persona-scoped criterion whose criterion is `human-action`/`cross-tenant`/`cross-role-fk-chain` (from the checklist row): read `evidence/<persona>/identity.json`; if present and `capturedSubject` does NOT equal the persona's expected identity → override to `fail` (reason "acting identity <subject> ≠ persona <id>"); if absent/`method:none` → keep the verdict but `confidence: low` + reason "persona identity unverified". `__shared__`/read-only → skip.
- Modify: `core/persona-body.md` (byte-oracle) + `skills/confirming-discovered-roles/SKILL.md` — a doctrine line: at persona login, probe a read-only `whoami`/profile (or decode the `storageState` subject) and record it via `record-evidence.sh identity`; when the app exposes none, record `--method none` (→ the degrade).
- Create: `tests/persona-identity/run.sh`

**Interfaces:**
- `record-evidence.sh … identity --persona admin --subject "admin@x" --method whoami` → `identity.json`.
- `qa-verify.sh`: identity mismatch on a persona-scoped human-action/cross-tenant pass → override fail; identity absent → confidence:low; matching identity → verified.

- [ ] **Step 1** — tests: `record-evidence.sh identity` writes the artifact; `qa-verify` on a run where a cross-tenant `pass` has `identity.json {capturedSubject:"bob"}` but the persona is `alice` → override to fail with the identity reason, exit non-zero; matching subject → verified; `method:none`/absent identity → confidence:low (not override), exit 0; a `__shared__`/read-only pass → identity not checked. Dual-engine. → run to fail.
- [ ] **Step 2** — implement the `identity` subcommand + the qa-verify identity check (reuse the checklist-row read for the criterion's kind/tags; the persona's expected identity comes from the persona's `auth` descriptor or the `--subject` recorded at a verified login — for v1, "expected" = the `--persona` id or a config `personas[].expectedSubject` if present; document the mapping).
- [ ] **Step 3** — doctrine lines (persona-body regen + confirming-roles). Tests green both engines + no regression (qa-verify 77, checkpoint 265) + byte-oracle (persona-body edit reflected). dist + validate-adapters + portability. Commit: `feat(enforcement): persona-identity binding (#6) — record + qa-verify check, mismatch overrides, unverified degrades`.

---

### Task 2: Clock/time-travel doctrine + advisory capture-flag (#7)

The capture-hook flags known time-control calls as advisory; a doctrine ban forbids time-travel.

**Files:**
- Modify: `scripts/capture-hook.sh` — after extracting `tool_name`/`args`, scan for time-control signals (a `browser_evaluate` whose payload contains `setTestNow`/`Date.now =`/`__defineGetter__.*Date`/`sinon.useFakeTimers`/`fakeTimers`, or a `Bash`/`browser_navigate` hitting a known clock route like `/__clock`/`/test/clock`/`?now=`). If matched → add `advisory:"clock-control"` to the emitted toolstream event. ADVISORY ONLY — still exit 0, never blocks.
- Modify: `skills/driving-browser-qa/references/interaction-discipline.md` — a doctrine ban: the act must use real time; a QA run must not `setTestNow`/mock the clock to force an assertion; any such call is flagged advisory by the capture and is a suspect signal.
- Modify: `tests/capture-hook/run.sh` — add clock-flag cases.

**Interfaces:**
- `capture-hook.sh` fed a `browser_evaluate` with `sinon.useFakeTimers()` → the toolstream event carries `advisory:"clock-control"`; a normal call → no advisory. Advisory never changes exit code.

- [ ] **Step 1** — tests: a captured evaluate with `setTestNow(`/`useFakeTimers(`/`Date.now =` → the toolstream line has `advisory:"clock-control"`; a navigate to `/__clock?now=...` → flagged; a normal browser_click → no advisory; the hook still exits 0 in all cases. Dual-engine. → run to fail.
- [ ] **Step 2** — implement the pattern scan in capture-hook.sh (ERE, `grep -Ei`/python re — NO `grep -P`); the doctrine ban line.
- [ ] **Step 3** — tests green + no regression (capture-hook, toolstream) + capture-hook still always exit 0. dist + validate-adapters + portability. Commit: `feat(enforcement): clock doctrine ban + advisory capture-flag for time-control calls (#7)`.

---

### Task 3: WS-2 named exceptions + phase-tag validation (C)

Complete the 5 named act-phase carve-outs and validate the phase/carveout enum fail-closed.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/check-action-trace.js` — add `persona-switch`, `out-of-band` to `NAV_CARVEOUTS` (now all 5: `deep-link`, `auth-boundary`, `persona-switch`, `out-of-band`, plus `arrange` handled by phase-filtering). Validate the per-step `phase` ∈ `{arrange, act, assert}` and `carveout` ∈ the named set (or null) — an UNKNOWN `carveout` value on an act-phase navigate → treated as NOT carved-out (fail-closed, the step is a workaround), never silently allowed. Keep all existing Check 0/1/2/3 behavior.
- Modify: `skills/driving-browser-qa/references/interaction-discipline.md` — document all 5 named exceptions (persona-switch = re-login as another role; out-of-band = Mailpit/email/webhook fetch; deep-link; auth-boundary-typed-URL; arrange-phase entry) with when each is legitimate. Note each LOOSENS the act-gate → tag-required.
- Modify: `tests/action-trace/run.sh` — add carve-out + enum cases.

**Interfaces:**
- Check 3: an act-phase `browser_navigate` tagged `carveout:"persona-switch"` → allowed; tagged `carveout:"bogus"` → fail-closed (workaround); untagged → fail-closed (existing).

- [ ] **Step 1** — tests: act-phase navigate with `carveout:"persona-switch"` → not a workaround (pass); `carveout:"out-of-band"` → pass; `carveout:"bogus"` (unknown) → fail-closed (rejected); `phase:"weird"` (unknown phase) → the step is still checked (not silently treated as non-act) — decide + assert: an unknown phase is treated as `act` (fail-closed) so a mutation can't hide behind a bogus phase label. Existing 68 cases green. → run to fail.
- [ ] **Step 2** — implement the carve-out additions + enum validation (fail-closed on unknown) in check-action-trace.js; the interaction-discipline doc.
- [ ] **Step 3** — tests green + checkpoint 265 (Check 3 via the gate) green; `node --check`. dist + validate-adapters + portability. Commit: `feat(enforcement): WS-2 named nav carve-outs (persona-switch, out-of-band) + fail-closed phase/carveout enum (C)`.

---

### Task 4: `--save-session` default + `autonomousSetup` flag

Config fast-follows: enable session-log reconciliation by default, and add the headless/CI setup auto-accept flag.

**Files:**
- Modify: `.qa/config.json.example` — `humanInteraction.saveSession` → `true`; add `humanInteraction.autonomousSetup` (default `false`) with a doc line.
- Modify: `skills/bootstrapping-qa-config/scripts/init-config.sh` — write `saveSession: true` and `autonomousSetup: false` in the `humanInteraction` block.
- Modify: `skills/confirming-discovered-roles/SKILL.md` — read `humanInteraction.autonomousSetup`; when `true`, PROACTIVELY auto-accept every setup round via `frontier.js recommendedDefault` (tag `assumption:true`), skipping the human prompt — setup phases ONLY (decision #8; never the Verify loop). When `false` (default) → today's interactive 3-round behavior.
- Modify: `scripts/tests/test-sessionlogdir.sh` (or a new test) — assert `saveSession` defaults `true` + `autonomousSetup` present.

**Interfaces:**
- `init-config.sh` output: `humanInteraction.saveSession==true`, `humanInteraction.autonomousSetup==false`.
- `confirming-discovered-roles`: `autonomousSetup:true` → auto-accept setup rounds (assumption-tagged); honest that this is an operator-declared headless mode.

- [ ] **Step 1** — tests: `init-config.sh` produces `saveSession:true` + `autonomousSetup:false`; the config example is valid JSON with both. → run to fail (if the test asserts the new defaults).
- [ ] **Step 2** — flip the defaults in init-config + example; add the `autonomousSetup` read + proactive-auto-accept doctrine to confirming-roles SKILL (prose — the skill is agent-followed; the flag gates the prompt-vs-default choice).
- [ ] **Step 3** — tests green + no regression (init-config test, any confirming-roles test); config valid JSON. dist + validate-adapters + portability. Commit: `feat(config): --save-session default-on + humanInteraction.autonomousSetup flag (headless/CI setup auto-accept)`.

---

### Task 5: Document the fast-follows + ADR amendments

Record #6/#7/C/B/T-14 + the honest tiers; wire the identity/clock reasons into the report/CONTEXT.

**Files:**
- Modify: `skills/checkpointing-qa-memory/SKILL.md` (or the relevant skill) — document persona-identity (#6, degrade), the clock advisory (#7), the named exceptions, save-session default, autonomousSetup. The `record-evidence.sh identity` subcommand in the Scripts Reference; `identity.json` in the Run Directory Layout. Body < 500 lines.
- Modify: `docs/adr/0015-human-interaction-discipline.md` — amend: the 5 named exceptions now first-class + fail-closed enum (narrows R4's ambiguity; the arrange-mislabel residual honestly recorded as still-open → `qa-verify` territory).
- Modify: `docs/adr/0018-out-of-agent-evidence-enforcement.md` — note #6 persona-identity + #7 clock landed (in-script/advisory tiers); the other-3 hook adapters (T-13) remain the last fast-follow.
- Modify: `CONTEXT.md` — add `persona identity`, `clock advisory`, `named exception`, `autonomousSetup` glossary terms (accurate to the implementation).

- [ ] **Step 1** — SKILL.md edits + the honest tier notes; `awk` < 500.
- [ ] **Step 2** — ADR-0015 + ADR-0018 amendments + CONTEXT terms.
- [ ] **Step 3** — dist regen; validate-adapters exit 0; commit: `docs(honesty): document persona-identity/clock/named-exceptions/save-session/autonomousSetup fast-follows`.

---

## Self-Review

**1. Spec coverage** (§5.5, §7, §5A/WS-2 C+B, T-14, AC-5):
- #6 persona-identity capture + check + degrade → Task 1. AC-5 (absence-probe recorded as one identity while captured identity is another → rejected, or confidence:low when unverifiable) → Task 1. ✅
- #7 clock doctrine ban + advisory capture-flag → Task 2. ✅
- WS-2 C (5 named exceptions + first-class phase tags) → Task 3. ✅
- WS-2 B (`--save-session` default-on) → Task 4. ✅
- T-14 autonomousSetup → Task 4. ✅
- **Deferred:** T-13 (Codex/opencode/Pi live-hook adapters + per-harness manual enforcement run) — a separate documented port; the qa-verify universal floor already runs everywhere. Stated in the header. ✅

**2. Grounding-gap alignment (from exploration):**
- `--persona` is an unverified scoping token → Task 1 records + qa-verify-checks the captured identity. ✅
- No clock handling → Task 2 extends the (already-wired) capture-hook + doctrine. ✅
- Only `deep-link`/`auth-boundary` carve-outs, no phase enum → Task 3 adds `persona-switch`/`out-of-band` + fail-closed enum. ✅
- `saveSession` defaults false, no autonomousSetup → Task 4. ✅
- confidence:low/banner rendering exists (report-to-junit + templates) → Task 1/2 only produce the reasons (constraint). ✅
- All logic under scripts/skills → no per-harness hook work; clock-flag rides the wired capture-hook (constraint + header). ✅

**3. Placeholder scan:** none — each task names exact files, subcommand signatures, the identity/advisory artifact shapes, the carve-out set, config keys, test assertions, and commit messages.

**4. Type consistency:** `identity.json {persona, capturedSubject, method, recorded_at}` is identical across `record-evidence.sh` and `qa-verify.sh`. The carve-out set (`deep-link, auth-boundary, persona-switch, out-of-band`) is identical in `check-action-trace.js` and `interaction-discipline.md`. Config keys (`humanInteraction.saveSession`, `humanInteraction.autonomousSetup`) match across `.qa/config.json.example`, `init-config.sh`, `confirming-discovered-roles`. The advisory field `advisory:"clock-control"` is the same in `capture-hook.sh` and its tests. Reuses H1/H2's `qa-verify.sh`/`capture-hook.sh`/`check-action-trace.js`/`report-to-junit.sh` confidence:low plumbing verbatim. Verdicts/confidence/layer vocab unchanged.
