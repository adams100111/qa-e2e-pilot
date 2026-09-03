# Portable Enforcement (H4 / T-13) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise the non-Claude harnesses (Codex, opencode, Pi) from "`qa-verify` degrades to `confidence:low` (no toolstream)" to **high-confidence `qa-verify` provenance binding** — by converting the `--save-session` session log those harnesses ALREADY produce into the canonical `toolstream.jsonl` that `qa-verify` consumes, run as a preflight step. This closes ADR-0018's last fast-follow (T-13) with a **verifiable** capability, and documents the per-harness live-hook recipes as optional hardening — without shipping unverifiable live-hook config as if it were authoritative.

**Architecture:** Every harness's bundled Playwright MCP already runs `--save-session --output-dir .playwright-mcp`, so a session log exists on all four. `skills/driving-browser-qa/scripts/parse-session-log.js` already parses that exact format (verified against `@playwright/mcp@0.0.79`) into ordered classified calls. A new **`session-to-toolstream.js`** reuses that parser to emit `toolstream.jsonl` events (the `{tool, args, resultDigest, responseBody, seq, ts}` shape `provenance.sh`/`qa-verify` bind against). A preflight step (in `qa-ci.sh` / a documented pre-`qa-verify` command) runs the converter when a session log exists and no live-hook toolstream is present — so on Codex/opencode/Pi, `qa-verify` gets a real browser-interaction toolstream and binds provenance at high confidence. **`qa-verify.sh` itself is NOT modified** (it stays the untouched authority; it just reads whatever `toolstream.jsonl` exists — live-hook on Claude, converter-produced on the others). The live capture/block hooks remain Claude's tier; the other harnesses' live-hook adapters ship as **documented optional hardening** (each labeled "verify the hooks fire on your build" — the manual enforcement run).

**Tech Stack:** Dependency-free Node (`session-to-toolstream.js`, reusing `parse-session-log.js`'s `parse`) + bash preflight glue + `jq`/`python3` where a shell JSON step is needed. No new runtime dependency. The converter has a testable contract (session.md fixture → toolstream events → provenance binds); the live-hook recipes are docs.

## Global Constraints

- **This is H4 (T-13) of the honesty-hardening effort** (ADR-0018, spec `2026-09-02-qa-honesty-hardening-design.md`). H1/H2/H3 shipped (PR #38/#39/#40). `qa-verify` is the **universal deterministic floor** and stays that — this plan gives the non-Claude harnesses a toolstream to raise that floor from degraded to high-confidence, and documents the live-hook tier honestly.
- **Do NOT modify `qa-verify.sh`.** It is the trusted out-of-agent authority (H2/H3 hardened it against forgery). This plan feeds it a toolstream via a SEPARATE preflight converter; qa-verify's own logic is untouched. Any change to qa-verify would re-open its adversarial review surface — out of scope here.
- **Never ship unverified config as authoritative.** The Codex/opencode/Pi live-hook adapters (capture/block wired into each harness's native mechanism) CANNOT be runtime-verified in this environment (no access to those harnesses; the capability matrix flags several primitives "verify/version-dependent/unconfirmed"). Ship them as **documented recipes + a manual-enforcement-run procedure**, each explicitly labeled that the operator must verify the hooks fire on their build. The spec frames T-13 exactly this way ("documented fast-follows, not a 4× v1").
- **The converter is honest about coverage.** The `--save-session` log captures **browser_\* (Playwright MCP) calls only**, NOT `Bash` calls (Bash is a harness tool, not routed through the MCP session). So the converted toolstream covers the human-path browser interactions `qa-verify`/`provenance` bind against — but a Bash-mutation is not in it. State this plainly; it does not regress anything (today those harnesses have NO toolstream at all), and the live capture-hook (Claude) remains the only source that also captures Bash.
- **Forgery boundary unchanged.** The converter reads the agent's own saved session log — the same trust level as the capture-hook's toolstream (both are agent-side). `qa-verify`'s provenance binding + required-kinds re-check are still the authority; the converter just supplies the toolstream input. No new trust claim.
- **jq-preferred/python3-fallback/die** for any shell JSON; honor `QA_ENGINE`; no `grep -P`/`perl`; reuse the existing `parse-session-log.js` (the ONLY `node` dependency, already present) — no NEW node dependency. Dual-engine byte-identical where a shell step emits JSON.
- **Portability:** the converter + preflight glue are **core** (copied into every `dist/<h>/`); the live-hook recipes live under `harnesses/<h>/` + `docs/`. `validate-adapters.sh` byte-oracle + the portability test stay green. `tools/`/`scripts/` ship verbatim.
- **Verdicts/confidence/layer vocab unchanged.** No sixth verdict.
- **No Claude/Anthropic attribution** in any commit; no `Co-Authored-By` trailer. Never commit `dist/`.

## Self-grilled decisions (my own recommended answers applied)

1. **Live-hook config vs. session-log converter** → **the converter.** It's verifiable (testable against the real session format `parse-session-log.js` already handles), needs no harness access, and delivers the actual value (high-confidence `qa-verify` on all four harnesses). Live-hook config would be unverified-by-me — shipped as docs only. *Applied.*
2. **Modify qa-verify vs. a separate preflight** → **separate preflight.** Keep the hardened authority untouched; the converter produces `toolstream.jsonl` BEFORE qa-verify runs, exactly as the capture-hook does on Claude. Safer + cleaner. *Applied (Task 2).*
3. **Toolstream event shape from the session log** → map each parsed call `{class, mutating, code}` → `{tool, args, resultDigest, responseBody, seq, ts}`: `tool` derived from class (human-path → the interaction verb; evaluate → `browser_evaluate`; route → `browser_route`-ish; other → `browser_navigate`/wait), `args` = the parsed `code`, `responseBody` = the session Result body, `seq` monotonic, `ts` absent→null (the session log has ordering, not always timestamps). Shape it to what `provenance.sh` binds against — verify with a round-trip test. *Applied (Task 1).*
4. **Bash-call gap** → honestly documented: the session log has browser_\* only; Bash mutations aren't in the converted toolstream. No regression (non-Claude had none). Claude's live capture-hook stays the only Bash-capturing source. *Applied (constraint + Task 4).*
5. **Live-hook recipes** → documented per-harness (Codex `requirements.toml`/config hooks, opencode `tool.execute.before/after` plugin, Pi extension `tool_call`/`tool_result`) as OPTIONAL hardening, each labeled "verify on your build" + the manual-enforcement-run steps. Not shipped as working config. *Applied (Task 3).*
6. **Assurance tiers** → document the resulting per-harness tier: Claude = live hooks (capture+block) + qa-verify; Codex/opencode/Pi = `--save-session`→toolstream + qa-verify (high-confidence provenance, post-hoc) + optional documented live-hook hardening; the live *block* stays Claude-only (qa-verify's post-hoc override covers the narrow deny on the others). qa-verify is the universal authority everywhere. *Applied (Task 4).*

---

## File Structure

- `skills/driving-browser-qa/scripts/session-to-toolstream.js` **(new)** — reuses `parse-session-log.js`'s `parse`; emits `toolstream.jsonl` events for a run from its `--save-session` log. Dependency-free (requires only the sibling parser).
- `tests/session-to-toolstream/run.sh` **(new)** — session.md fixture → expected toolstream events; + a provenance round-trip (a converted human-path event binds an action-trace entry via `provenance.sh`).
- `scripts/session-preflight.sh` **(new)** — the preflight: for a run, if `.qa/runs/<run>/toolstream.jsonl` is absent AND a `--save-session` log exists (`.playwright-mcp/…` or a `QA_SESSION_LOG` path), run the converter to produce `toolstream.jsonl`. Idempotent (never overwrites a live-hook toolstream). jq/py/die.
- `tests/session-preflight/run.sh` **(new)** — preflight produces a toolstream from a session log; skips when a toolstream already exists; no-session → no-op.
- `scripts/qa-ci.sh` **(modify)** — run `session-preflight.sh` before `qa-verify` (so CI on any harness gets the toolstream). Guarded/optional; documented.
- `harnesses/codex/hooks.md`, `harnesses/opencode/hooks.md`, `harnesses/pi/hooks.md` **(new)** — the per-harness live-hook recipes (optional hardening) + the manual-enforcement-run steps, each labeled "verify on your build."
- `harnesses/<h>/install-<h>.sh` **(modify)** — print a one-line pointer to `hooks.md` (optional hardening) + note the `--save-session`→toolstream floor is automatic.
- `docs/adr/0018-out-of-agent-evidence-enforcement.md` **(modify)** — note T-13 addressed: the session→toolstream converter gives all four harnesses high-confidence qa-verify; live-hook adapters documented as optional hardening; the honest Bash-gap + verify-on-build caveats.
- `docs/harness-adapters.md` **(modify)** — the per-harness assurance tier + the manual-enforcement-run procedure + the automatic `--save-session`→toolstream floor.
- `docs/specs/harness-capability-matrix.md` **(modify)** — mark the enforcement rows: the session→toolstream floor shipped; the live-hook rows are documented-recipe + verify-on-build.

---

## Task 1: The session-log → toolstream converter

**Files:**
- Create: `skills/driving-browser-qa/scripts/session-to-toolstream.js`
- Test: `tests/session-to-toolstream/run.sh`

**Interfaces:**
- Consumes: a `--save-session` session.md (the format `parse-session-log.js` parses) + the run-id.
- Produces: `toolstream.jsonl` lines `{tool, args, resultDigest, responseBody, seq, ts}` — the shape `provenance.sh`/`qa-verify` consume. Exports `sessionToEvents(md) -> [event]` for testing; CLI `session-to-toolstream.js <session.md>` prints the ndjson.

- [ ] **Step 1: Write the failing tests** (`tests/session-to-toolstream/run.sh`) — a small inline session.md fixture with a human-path click, a read-only evaluate, and a navigate → `sessionToEvents` yields 3 events with the right `tool`/`args`; the human-path event's shape is what `provenance.sh` binds (assert via a round-trip: write the events to a temp `toolstream.jsonl`, write a matching action-trace entry, run `provenance.sh check` → bound). Reuse the real `parse-session-log.js` (require it). Run → FAIL.
- [ ] **Step 2: Implement `session-to-toolstream.js`** — `require('./parse-session-log.js').parse(md)` → for each `{class, mutating, code}`, build an event: `tool` from class (`human-path`→`browser_click`/derive the verb from the code, `evaluate`→`browser_evaluate`, `route`→`browser_route`, `other`→`browser_navigate`), `args` = `{code}` (or the derived selector), `resultDigest` = a short hash of the code, `responseBody` = the Result body if present else null, `seq` = the 1-based index, `ts` = null (session logs aren't reliably timestamped — provenance binds on containment, not ts). Emit ndjson. Match the exact field names `provenance.sh` reads (READ `provenance.sh` first to pin the shape).
- [ ] **Step 3: Run tests** — `bash tests/session-to-toolstream/run.sh` → `FAIL=0`; `node --check`. Confirm the provenance round-trip binds.
- [ ] **Step 4: Commit**
```bash
git add skills/driving-browser-qa/scripts/session-to-toolstream.js tests/session-to-toolstream/run.sh
git commit -m "feat(honesty): session-log -> toolstream converter (reuses parse-session-log; feeds qa-verify a toolstream on any --save-session harness)"
```

---

## Task 2: The preflight that produces a toolstream before qa-verify

**Files:**
- Create: `scripts/session-preflight.sh`
- Test: `tests/session-preflight/run.sh`
- Modify: `scripts/qa-ci.sh`

**Interfaces:**
- `session-preflight.sh <run-id>` → if `.qa/runs/<run-id>/toolstream.jsonl` is ABSENT and a session log is resolvable (a `QA_SESSION_LOG` path, else the newest `*.md` under `.playwright-mcp/`), run `session-to-toolstream.js` → write `.qa/runs/<run-id>/toolstream.jsonl`. If a toolstream already exists (live hook) → NO-OP (never overwrite). No session log → NO-OP (qa-verify's honest no-toolstream degrade still applies). Prints what it did.
- Feeds `qa-verify` (unmodified): it then finds a toolstream and binds provenance at high confidence.

- [ ] **Step 1: Failing tests** (`tests/session-preflight/run.sh`): a run with a session log + no toolstream → preflight creates `toolstream.jsonl` (non-empty, valid ndjson); a run with an EXISTING toolstream → preflight NO-OP (file byte-unchanged — never clobbers the live-hook capture); a run with no session log → NO-OP (exit 0, no file). Run → FAIL.
- [ ] **Step 2: Implement `session-preflight.sh`** — jq/py/die not strictly needed (it orchestrates the node converter), but validate the run-id token (mirror `journal-emit.sh`'s `validate_token`); resolve the session log; call the converter; atomic write. Idempotent (existing toolstream → skip).
- [ ] **Step 3: Wire `qa-ci.sh`** — add a step that runs `session-preflight.sh "$RUN_ID"` BEFORE the `qa-verify` step (guarded so a Claude run with a live toolstream is a no-op). Keep it pluggable/documented; don't break the existing `qa-ci.sh` flow (run its existing smoke path to confirm).
- [ ] **Step 4: Run tests + no-regression** — `bash tests/session-preflight/run.sh` → `FAIL=0`; re-run the existing `qa-ci`/`qa-verify` tests → still green; `bash -n` both scripts.
- [ ] **Step 5: Commit**
```bash
git add scripts/session-preflight.sh tests/session-preflight/run.sh scripts/qa-ci.sh
git commit -m "feat(honesty): session preflight produces toolstream before qa-verify (idempotent; never clobbers a live-hook capture)"
```

---

## Task 3: Documented per-harness live-hook recipes (optional hardening)

**Files:**
- Create: `harnesses/codex/hooks.md`, `harnesses/opencode/hooks.md`, `harnesses/pi/hooks.md`
- Modify: `harnesses/codex/install-codex.sh`, `harnesses/opencode/install-opencode.sh`, `harnesses/pi/install-pi.sh`

**Interfaces:** none (docs + a one-line install pointer).

- [ ] **Step 1: Write each `hooks.md`** — per the capability matrix, document how to wire `capture-hook.sh` (record) + `block-hook.sh` (deny) into that harness's native mechanism, as OPTIONAL hardening ON TOP of the automatic `--save-session`→toolstream floor:
  - **Codex** (`harnesses/codex/hooks.md`): the `requirements.toml`/managed-hook wiring for `PreToolUse`/`PostToolUse` on `playwright-qa__browser_*`; the caveat that some Codex builds restrict hooks to Bash-only → **verify they fire on your build** (the manual-enforcement run: drive a mutating `browser_evaluate` and confirm block-hook denies it / capture-hook records it).
  - **opencode** (`harnesses/opencode/hooks.md`): the `tool.execute.before` (throw to block) / `tool.execute.after` (record) plugin wiring; the `deny task` note; verify-on-build + the manual run.
  - **Pi** (`harnesses/pi/hooks.md`): the extension-factory `tool_call`→`{block:true}` / `tool_result` wiring; cooperative caveat; verify-on-build + the manual run.
  Each MUST state plainly: this is optional; the automatic floor is `--save-session`→toolstream + `qa-verify`; the exact hook syntax is per the harness's own docs and **not runtime-verified here** — confirm on your build.
- [ ] **Step 2: Install-script pointers** — each `install-<h>.sh` prints one line: "Automatic enforcement floor: --save-session → session-preflight → qa-verify (high-confidence). Optional live-hook hardening: see harnesses/<h>/hooks.md (verify on your build)."
- [ ] **Step 3: Validate + commit** — `bash -n` the install scripts; the `hooks.md` are docs (no lint). 
```bash
git add harnesses/codex/hooks.md harnesses/opencode/hooks.md harnesses/pi/hooks.md harnesses/codex/install-codex.sh harnesses/opencode/install-opencode.sh harnesses/pi/install-pi.sh
git commit -m "docs(honesty): per-harness live-hook recipes as optional hardening (verify-on-build) + install pointers"
```

---

## Task 4: ADR-0018 + harness-adapters + matrix — T-13 addressed

**Files:**
- Modify: `docs/adr/0018-out-of-agent-evidence-enforcement.md`
- Modify: `docs/harness-adapters.md`
- Modify: `docs/specs/harness-capability-matrix.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: ADR-0018 note** — **T-13 addressed** (dated): the `session-to-toolstream` converter + `session-preflight` give ALL FOUR harnesses a `toolstream.jsonl` from the already-present `--save-session` log, so `qa-verify` binds provenance at **high confidence** everywhere (no longer degraded-to-low on the non-Claude harnesses). The live capture/block hooks stay Claude's tier; the other harnesses' live-hook adapters are **documented recipes (optional hardening), verify-on-build**. Honest residuals: the converted toolstream is **browser_\* only** (no Bash); the live *block* (pre-run deny) stays Claude-only — qa-verify's post-hoc override covers the narrow deny on the others; and the session log is agent-side (same trust as the capture-hook). qa-verify remains the universal authority.
- [ ] **Step 2: harness-adapters.md** — the per-harness assurance tier: Claude (live hooks + qa-verify), Codex/opencode/Pi (`--save-session`→toolstream→qa-verify high-confidence + optional documented live-hook hardening); the automatic floor; the manual-enforcement-run procedure (from the `hooks.md`).
- [ ] **Step 3: matrix** — mark the enforcement rows: the session→toolstream floor SHIPPED (all harnesses); the live-hook rows are documented-recipe + verify-on-build (keep the per-harness caveats).
- [ ] **Step 4: Gates + commit** — `bash scripts/build-adapter.sh claude >/dev/null && bash scripts/validate-adapters.sh` (0).
```bash
git add docs/adr/0018-out-of-agent-evidence-enforcement.md docs/harness-adapters.md docs/specs/harness-capability-matrix.md
git commit -m "docs(honesty): ADR-0018 T-13 addressed — session->toolstream floor (all harnesses high-confidence qa-verify) + documented live-hook hardening"
```

---

## Self-Review

**1. Spec coverage (T-13 / ADR-0018).**
- The non-Claude harnesses gain high-confidence `qa-verify` (a toolstream to bind provenance) → Tasks 1–2 (converter + preflight). ✅
- Live-hook adapters for Codex/opencode/Pi → Task 3 (documented recipes + manual-run, honestly labeled verify-on-build). ✅
- `qa-verify` stays the universal authority, unmodified → constraint + Task 2 (separate preflight). ✅
- Honest residuals (browser-only toolstream, block stays Claude-only, agent-side trust) → constraints + Task 4 docs. ✅
- **Deliberately NOT done:** shipping runtime-verified live hooks for the other 3 harnesses (impossible here — no harness access) — shipped as documented hardening instead, matching the spec's "documented fast-follows" framing.

**2. Placeholder scan.** None — exact files, the converter's event-shape mapping (tied to `provenance.sh`'s actual fields, pinned in Task 1 Step 2), the preflight's idempotent contract, the per-harness recipe mechanisms (from the matrix), and the commit messages. The exact per-harness hook SYNTAX is deliberately deferred to each harness's own docs (labeled verify-on-build) rather than invented — honesty over false precision.

**3. Type consistency.** `sessionToEvents` emits exactly the `{tool, args, resultDigest, responseBody, seq, ts}` shape `provenance.sh`/`qa-verify` read (pinned by the Task 1 round-trip test). `session-preflight.sh` writes that ndjson to the same `.qa/runs/<run>/toolstream.jsonl` path the capture-hook uses, so `qa-verify` reads it identically regardless of source. Reuses `parse-session-log.js`'s `parse` (the single source of truth for the session format). Verdict/confidence/layer vocab unchanged.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-09-03-portable-enforcement-h4.md`. Execution: **Subagent-Driven Development** (fresh implementer per task + task-scoped review + fix loop; final whole-branch review on the most capable model), per the autonomous `/loop` directive. **Note:** Task 1's event shape MUST match `provenance.sh`'s binding contract (pin it by reading `provenance.sh` + the round-trip test) — this is the integration-risk task; the whole-branch review should confirm the converted toolstream actually binds provenance and that `qa-verify.sh` was not modified.
