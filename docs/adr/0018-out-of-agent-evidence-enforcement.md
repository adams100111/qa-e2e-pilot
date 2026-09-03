# ADR-0018 — Out-of-agent evidence enforcement

## Status

Partially landed (2026-09-03, Plan H2 — "WS-3 sound core", Claude-first; extended 2026-09-03,
Plan H3 — persona-identity binding (#6) + clock advisory (#7)). Implements
`docs/specs/2026-09-02-qa-honesty-hardening-design.md`. Amends ADR-0015 (narrows residual R4).
Builds on ADR-0017 (merged) and ADR-0010 (evidence gate).

**What's landed (Plan H2, Claude only):** the **capture-hook** (`scripts/capture-hook.sh`,
`PostToolUse`) appending redacted `Bash`/`browser_*` calls to append-only
`.qa/runs/<run-id>/toolstream.jsonl`; the **block-hook** (`scripts/block-hook.sh`, `PreToolUse`)
denying a mutating `browser_evaluate` and `browser_run_code_unsafe` (fail-open); **provenance
binding** (`scripts/provenance.sh check`, a containment check against the toolstream, returning
`bound`/`unbound`/`no-toolstream`); and `qa-verify`'s **deterministic core**
(`scripts/qa-verify.sh` — independent required-kinds re-derivation, evidence re-validation,
provenance binding, `verification.json`, wired into `scripts/qa-ci.sh` +
`scripts/report-to-junit.sh`'s honest assurance-tier reporting). See
`skills/checkpointing-qa-memory/SKILL.md`'s "Out-of-Agent Enforcement" section for the full
mechanics and honest residuals, and `docs/harness-adapters.md#the-claude-assurance-tier` /
`docs/running-in-ci.md#qa-verify-the-out-of-agent-authority` for the operational writeup.

**What's since landed (Plan H3 fast-follows):** **persona-identity binding (item 6)** —
`record-evidence.sh identity` records a persona's observed identity to
`evidence/<persona>/identity.json`; `qa-verify`'s Step 3.5 binds it for every persona-scoped,
high-stakes `pass`. The override-to-`fail` path requires operator-configured
`personas[].expectedSubject` ground truth for that persona; without it, an opaque or
non-matching captured subject **degrades to `confidence: low`** rather than a false override —
the honest tier spec §5.5 calls for: impersonation degrades, it does not silently hard-fail, when
there is no ground truth to judge it against. Also landed: the **clock/time-travel advisory
(item 7, spec §7)** — `capture-hook.sh`'s deterministic pattern scan stamps
`advisory:"clock-control"` on a toolstream event matching a known time-control signal; advisory
only, it never gates a verdict and the hook still always exits 0. See
`skills/checkpointing-qa-memory/SKILL.md`'s "Plan H3 Fast-Follows" section for the full mechanics.

**What's still fast-follow (Plan H3), not built by this ADR's "landed" claim:** the block-hook does
**not** deny `browser_route` (item 2 below describes the original full design intent; the shipped
hook is narrower — only the mutating-`browser_evaluate` + `browser_run_code_unsafe` pair). Also
deferred: the **independent LLM re-drive/re-bake** of high-stakes criteria (`qa-verify`'s
`QA_VERIFY_REDRIVE_CMD` is a pluggable, documented stub whose result is logged but not wired into
the verdict — item 3's "hybrid" second half). **T-13 (the last fast-follow) is now addressed as
below.**

**T-13 addressed (2026-09-03, portable-enforcement H4).** Before this, the Codex/opencode/Pi
adapters had no capture mechanism at all — every `human-action`/cross-tenant `pass` on those three
harnesses degraded to `confidence: low` by default, because `qa-verify`'s provenance binding
(item 4) had no toolstream to check against. That gap is now closed **without a live hook**:

- `skills/driving-browser-qa/scripts/session-to-toolstream.js` converts the `session.md` that
  `@playwright/mcp --save-session` already writes on every harness (Codex, opencode, and Pi all
  ship `--save-session` in their `mcp.snippet`, per `docs/harness-adapters.md`) into the same
  `{tool, args, resultDigest, responseBody}` event shape the capture-hook produces, reusing
  `parse-session-log.js` as the single source of truth for session parsing/classification.
- `scripts/session-preflight.sh <run-id>` runs that converter and pipes its output through
  `toolstream.sh append` to materialize `.qa/runs/<run-id>/toolstream.jsonl` **before**
  `qa-verify` runs. It is **idempotent and non-destructive**: a no-op if a toolstream already
  exists (never overwrites a live-hook capture) and a no-op if no session log is resolvable
  (the honest no-toolstream degrade still applies — this is not an error path). Wired **non-fatally**
  into `scripts/qa-ci.sh` (a preflight failure logs and falls through to `qa-verify` as before,
  skippable via `QA_SKIP_SESSION_PREFLIGHT=1`).
- Net effect: `qa-verify`'s provenance binding (item 4) now has a toolstream to check on every
  harness that ran with `--save-session`, so `human-action`/cross-tenant passes on Codex/opencode/Pi
  bind at **high confidence** the same way Claude's live-hook-captured runs do — not just Claude
  anymore.

**What T-13 did *not* do — the live capture/block hooks stay Claude's tier.** This task ships a
converter, not a hook port. The Codex/opencode/Pi live-hook adapters (real-time capture as the run
happens, and a live pre-run block) now exist as **documented recipes** — `harnesses/<h>/hooks.md`
for each of the three — describing the mechanism (`PreToolUse`/`PostToolUse`-equivalent wiring
against the `playwright-qa` MCP server) using `capture-hook.sh`/`block-hook.sh` unchanged, framed
as **optional hardening on top of the automatic floor above, verify-on-build**: nothing in this repo
runtime-exercises them (no access to a live Codex/opencode/Pi runtime here), so each recipe carries
its own honesty banner pointing the operator at their own pinned version's hook docs before relying
on it.

**Honest residuals of the T-13 fix (stated plainly, not buried):**
- The converted toolstream is **`browser_*` only.** `session.md` is a Playwright MCP artifact — it
  has no visibility into `Bash` calls. The live capture-hook on Claude remains the only source that
  captures `Bash` into the toolstream; a Codex/opencode/Pi run's toolstream will never corroborate a
  `Bash`-evidenced artifact, converter or not.
- The live **block** (pre-run deny of a mutating `browser_evaluate`/`browser_run_code_unsafe`)
  **stays Claude-only** unless an operator wires the optional recipe. On Codex/opencode/Pi without
  that recipe, a mutating call is never denied *before* it runs — `qa-verify`'s post-hoc override
  (a captured mutating call with no artifact accounting for it fails the gate after the fact) is the
  only backstop there, same authority, later in the loop.
- The saved session log is **agent-side** — written by the same Playwright MCP process the run's
  own agent drives, not a hardened out-of-agent capture. This is **the same trust level as the
  capture-hook's toolstream** on an unhardened install (see the Consequences section's
  tamper-*evident*-not-tamper-*proof* note) — the fix does not claim a new, stronger trust tier, it
  only extends the existing one to harnesses that had none.

`qa-verify` remains the universal authority throughout — this task adds an input to its existing
provenance check, it does not change `qa-verify.sh` itself, and a run's authoritative verdict is
still `qa-verify`'s, never the presence of a toolstream (converted or live-captured) by itself.

## Context

ADR-0015's human-action gate and ADR-0010's evidence gate are enforced by `checkpoint.sh` / `check-action-trace.js`, which the **agent runs** and which read **evidence the agent authored** at **paths the agent controls**. A source-grounded audit confirmed the gate is, for a motivated agent, advisory:

- Evidence files are agent-writable at fixed canonical paths; the gate does zero provenance/freshness/authorship checks (`checkpoint.sh:684–711`). A hand-written `action-trace.json` with `sessionCalls:[]`, equal fingerprints, and fabricated human-path steps passes every check with zero browser activity.
- `--kinds` is agent-supplied at checkpoint and unbound to any derived required-kinds source (none exists — the checklist is prose); omitting `human-action` skips the strongest gate (`checkpoint.sh:763,801–806`).
- The mutation classifier is uppercase/quote-only, so `method:'post'`, `` `POST` ``, `page.request.post()` classify as read-only (`parse-session-log.js:21`, empirically confirmed).
- Check-0 independent reconciliation is off by default (no `--save-session`).
- `--persona` is an unverified label; the acting session's real identity is never checked.

The invariant (ADR-0015): *the agent must not manufacture a pass.* The residual R4 openly conceded phase-framing is agent-supplied and backstopped only by human spot-check.

**The hard constraint:** a referee the agent is allowed to *run* cannot be made fully sound in-process — an agent with `Write`+`Bash` can forge inputs, edit the gate, or skip it. True adversarial-resistance requires enforcement in a trust domain the agent does not control, fed a record the agent did not author.

## Decision

Move enforcement out of the agent, in three layers, plus provenance binding, across all four harnesses via native hook primitives (per `docs/specs/harness-capability-matrix.md`).

1. **Capture-hook (Layer 1 — record; `PostToolUse`).** A **plugin-bundled** post-tool-call hook (native primitive per harness: `PostToolUse` / `tool.execute.before`+`.after` / `tool_result`) appends every `browser_*` and `Bash` call — plus **bounded response bodies** for backend reads — to an **append-only** `.qa/runs/<run>/toolstream.jsonl`; `@playwright/mcp --save-session` supplies browser-code ground truth. `Bash` args are **redacted** before writing. **No hash-chain:** on an unhardened install the agent can overwrite the file, so a recomputable chain is false assurance; trust comes from Layer 3, not the file. Tamper-*evident at best* off the hardened tier.

2. **Block-hook (Layer 2 — deny before running; `PreToolUse`).** A pre-tool-call hook **hard-blocks the phase-independent absolutes** — a mutating `browser_evaluate` (never sanctioned on *any* phase), `browser_run_code_unsafe`, and `browser_route` on the tested origin — which need **no phase knowledge** (phase is agent-supplied, not in the tool call). The one phase-dependent case, `browser_navigate`, cannot be live-blocked without breaking legit navigation, so it and all other nuanced checks are **record-only → Layer 3**. Keeps live-block false-positives near-zero.

3. **`qa-verify` (Layer 3 — authoritative; out-of-agent).** A standalone process, runnable **locally and in CI**, in a trust domain the agent never wrote to; core is **deterministic code** (needs no trust), re-drive is an **operator-invoked fresh agent** (never the run's agent). **Hybrid:** a deterministic re-check of evidence + toolstream + independently re-derived required-kinds, plus independent corroboration of high-stakes criteria — a fresh agent **re-drives** read-only isolation probes, while **mutating** `human-action` passes are **re-baked** (persisted state read again), never re-performed (side effects). Writes `verification.json`; its verdict is authoritative; a run is "verified" only when every `pass` survives. Un-reverified human-action/cross-tenant passes are `confidence: low` + banner.

4. **Provenance binding.** Every evidence artifact must reference the captured-stream call that produced it (a bake read-back → a captured XHR, the navigation response that returned the DOM, or a captured `Bash` read). The match is a **containment check** (the value/key appears in *some* captured response/DOM for that entity), corroborated by re-bake. The gate rejects an artifact with no corresponding captured read, or a mutating stream call no artifact accounts for.

5. **Required-kinds, independently re-derived.** `generating-qa-checklist` emits `checklist.json` (per criterion: `id`, `requiredKinds`, tags), but that is the agent's *proposal*. The trusted verifier **re-derives `requiredKinds` itself** from deterministic rules over the criterion's shape and enforces recorded kinds ⊇ its *own* derivation — never the agent's file (else the adversary just weakens `checklist.json`). A dropped derived kind fails.

6. **Persona-identity binding.** Capture the session's real authenticated identity at login and check it equals `--persona`; degrade to `confidence: low` + banner (not `blocked`) when identity is unverifiable.

**Assurance tiers, printed in the report:** Codex `A+` (managed `requirements.toml` = agent-proof); Claude/opencode `A` (plugin-bundled / root-managed hooks); Pi `B→A` (cooperative + optional container). The universal floor is `qa-verify`. Default posture: strongest-out-of-box per harness + documented opt-in hardening.

**Scope:** Claude-first core, portable by construction; Codex/opencode/Pi hook adapters are fast-follows.

**WS-1 remainder landed in-script (Plan H1, `docs/superpowers/plans/2026-09-03-honesty-ws1-remainder.md`).** Two of item 5's pieces — the independent required-kinds re-derivation, and a fingerprint-target coverage check for item 4's provenance intent — now ship inside `checkpointing-qa-memory`'s existing in-agent gate, ahead of `qa-verify`:

- **#2 (required-kinds binding).** `generating-qa-checklist` emits `checklist.json` (the agent's *proposal*: per-criterion `kind`/`tags`/`action`/`requiredKinds`/`assertedState`). `checkpoint.sh`'s pass-gate reads a criterion's row and re-derives its required evidence kinds itself via `required-kinds.sh derive` — from the row's structural `kind`/`tags`/action shape only, reusing `mutation-flag.sh`'s mutation classifier — and rejects a `pass` unless the recorded `--kinds` is a superset. The row's own `requiredKinds` field is never read for enforcement.
- **#4 (fingerprint-target).** A criterion's `assertedState {entity, readBackPath, expectChange}` is threaded into `action-trace.json.fingerprintTarget`; `check-action-trace.js` Check 3 requires the before/after state fingerprint to cover `readBackPath` and, per `expectChange`, show it changed or unchanged.

**This is explicitly the best-effort tier, not item 5's sound form.** Both checks re-derive from the criterion's *declared* shape (`checklist.json`'s `kind`/`tags`/`assertedState`) — they catch "drop a required kind at checkpoint time" and "fingerprint an irrelevant field," not "the declared shape itself was dishonest" or "the fingerprint's values were fabricated." The **sound** tier this ADR describes — independent re-derivation from the captured **toolstream** (Layer 1) plus provenance binding, in a trust domain the agent does not control — is `qa-verify`'s **deterministic core**, now landed (Plan H2, see the Status section above); the re-bake/re-drive half of Layer 3 (an independent fresh-agent session) remains a pluggable, un-wired stub. A run whose passes depend on #2/#4 alone, with no `qa-verify` run against it yet, should carry `confidence: low` with an "authoritative verdict pending `qa-verify`" framing, per this ADR's Layer 3 description above — that framing no longer applies once `qa-verify.sh` has actually run and the pass survived. WS-1's #3 (semantic mutation classifier) and A (nav fail-closed) shipped earlier in PR#31; #8 (squash) in PR#32; #2/#4 close the remainder of WS-1 that PR#31/#32 left open. See `skills/checkpointing-qa-memory/SKILL.md`'s "Evidence-Kind Gate (#2) and Fingerprint-Target (#4)" section for the full mechanics and the honest-tier note, including the `read-only`/probe-tag residual left to `qa-verify`.

## Consequences

- The gate stops grading the agent's homework: forged evidence, classifier evasions, dropped kinds, unlabeled act-navigates, and mispersona'd isolation probes are caught at a layer the agent doesn't control (or, where capture isn't hardened, corroborated by independent re-drive).
- **Cost rises** (capture on every call; sampled re-drive). Bounded by the run-level cost ceiling with a logged drop-order; functional/honesty/cross-tenant checks are never dropped.
- **Honest residual (not hidden):** without OS-sandbox/managed-config hardening, in-run capture is tamper-*evident*, not tamper-*proof* — plugin-bundling stops the hook *config* being disabled, but the hook's *script files* are user-writable on a normal install, so a determined agent's `Bash` could neuter them. The guarantee is therefore `qa-verify`'s deterministic re-check (required-kinds + evidence + provenance, landed) plus the `confidence: low` banner on un-reverified high-stakes passes — not the live hook, and not yet the independent re-drive/re-bake either (still a pluggable, un-wired stub). Fully agent-proof only under Codex-managed / hardened setups.
- Vocabulary unchanged: no sixth verdict; `human-action` stays an evidence kind; layer stays `FE|route|service|migration|DB`.
- **Reversibility:** the capture hook + `qa-verify` are additive; removing them reverts to the ADR-0015 in-agent gate. The hard-to-reverse call is making an out-of-agent verifier authoritative over the in-run report — hence this ADR.
