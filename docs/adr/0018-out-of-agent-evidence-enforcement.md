# ADR-0018 — Out-of-agent evidence enforcement

## Status

Partially landed (2026-09-03, Plan H2 — "WS-3 sound core", Claude-first). Implements
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

**What's still fast-follow (Plan H3), not built by this ADR's "landed" claim:** the block-hook does
**not** deny `browser_route` (item 2 below describes the original full design intent; the shipped
hook is narrower — only the mutating-`browser_evaluate` + `browser_run_code_unsafe` pair). Also
deferred: **persona-identity binding** (item 6), the **independent LLM re-drive/re-bake** of
high-stakes criteria (`qa-verify`'s `QA_VERIFY_REDRIVE_CMD` is a pluggable, documented stub whose
result is logged but not wired into the verdict — item 3's "hybrid" second half), and the
**Codex/opencode/Pi hook adapters** (capture/block hooks exist on Claude only today; the other
three harnesses fall back to `qa-verify`'s deterministic checks with no toolstream to corroborate
against, degrading high-stakes passes to `confidence: low` by default).

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
