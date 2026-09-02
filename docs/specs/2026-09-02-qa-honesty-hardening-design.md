# QA honesty hardening — adversarial evidence integrity — design

**Status:** design (awaiting review) · **Date:** 2026-09-02 · **Topic:** make the pass/human-action gate resistant to an agent that would manufacture a `pass`, and move enforcement to where the agent cannot forge it — across all four harnesses (ADR-0017, now **merged**).

Companion effort (separate spec): comprehensive human-eye UX detection (`2026-09-02-human-eye-ux-detection-design.md`). That one stops the agent *faking a fail*; this one stops it *faking a pass*. Shared harness grounding: `harness-capability-matrix.md`. New decision record: **ADR-0018**.

---

## 0. Goal

The plugin's promise is *"a green toast is not a pass."* ADR-0015 built a human-action gate to enforce it. A source-grounded audit (§3) found the gate is, in practice, **advisory** for a motivated agent: every check reads evidence the agent itself authored, at paths it controls, and the strongest reconciliation (Check 0) is off by default. Goal: **raise the gate from "grades the agent's homework" to "grades an independent record the agent could not write,"** degrading *honestly* where a harness cannot enforce it.

## 1. Threat model (and the one limit we will not hide)

- **Honest-but-fallible agent** — follows the rules but errs (writes `method:'post'` lowercase, fingerprints the wrong field, drops a `--kind`). Today's gate misses several of these (§3: #2, #3, #4).
- **Adversarial agent** — will forge evidence for green. Today's gate cannot stop this (§3: #1, #5, #6): it reads JSON the agent wrote with `Write`.

**The hard limit (documented, never hidden):** a referee the player is allowed to *run* cannot be made fully sound — an agent with `Write`+`Bash` that invokes the gate itself can forge its inputs, edit the gate, or skip it. Real adversarial-resistance requires enforcement in a trust domain the agent does not control: the **harness** (hooks) and an **out-of-agent verifier**, fed a **tool stream the agent did not author**. Where a harness supports neither at agent-proof strength, the in-run gate is best-effort and the out-of-agent verifier is authoritative — an *assurance tier*, stated per harness (§6), not a silent gap.

"Maximum / production-ready" = the enforcement layers of §5 + provenance binding (§5.4), **not** a bigger pile of in-script checks.

## 2. What already holds (do not rebuild)
- Mutating `browser_evaluate` on the act path → gate-rejected (`check-action-trace.js:40`, Checks 1/2 `:58–64`).
- `browser_run_code_unsafe`, `browser_route`, `browser_drag`, `browser_drop` absent from the agent allow-list (`agents/qa-e2e-pilot.md:10`).
- Concealed mutating session-log calls with no disclosing step → rejected (Check 0 `:87–97`) **when `--save-session` is on**.
- Before/after fingerprint net (Check 3 `:114–128`); content-match disclosure (`:79–97`).
- Probing read-only unless `allowApiWrites` + disposable marker; secrets never printed to output.

## 3. The validated gap inventory (11)

`A/B/C` = original interaction-fidelity findings; `#1–#8` = adversarial audit. *Model* = which threat model; *Ack* = pre-existing ADR-0015 residual.

| # | Gap | Anchor | Model | Ack |
|---|---|---|---|---|
| A | Act-phase `browser_navigate` URL-skip is prose-only; `navigate` is in `HUMAN_PATH_TOOLS` | `check-action-trace.js:31,39,124` | honest+adv | R4 |
| B | Managed Playwright ships without `--save-session` → Check 0 no-ops (`sessionCalls=[]`) | `agents/qa-e2e-pilot.md:36`; `record-evidence.sh:401,408` | both | R5 |
| C | Named Arrange/probe exceptions (persona-switch, out-of-band/Mailpit, deep-link, auth-boundary-typed-URL) unwritten | `spec:62–63,83` | honest | no |
| 1 | Evidence files agent-writable at fixed paths; gate binds nothing to a real session | `checkpoint.sh:690–692`; `check-action-trace.js:51,71,109` | **adv** | partial |
| 2 | `--kinds` at checkpoint agent-supplied, unbound to derived Kinds → drop `human-action` and it never fires | `checkpoint.sh:763,801–806` | **honest+adv** | no |
| 3 | `MUTATION_RE` uppercase/quote-only → `method:'post'`, `` `POST` ``, `page.request.post()`, `axios.post`, XHR classify read-only | `parse-session-log.js:21` (empirically confirmed) | **honest+adv** | abstract |
| 4 | Check 3 fingerprints agent-authored AND agent picks *which* state → fingerprint unchanged field → N2 skipped | `check-action-trace.js:114,117,123–127` | **adv** | no |
| 5 | bake/computed/probe evidence 100% self-authored; gate checks only internal consistency | `checkpoint.sh:615,621,627` | **adv** | partial |
| 6 | `--persona` unverified label; acting-session identity never checked | `checkpoint.sh:772`; `record-evidence.sh:533` | **adv** | no |
| 7 | Clock/time-travel ungated | (absent) | both | no |
| 8 | `squash()` collapses brackets → decoy can cover a different concealed call | `check-action-trace.js:79,93` | adv | no |

Repo facts that shape fixes: there is **no machine-readable required-Kinds source** (checklist is prose; `checkpoint.json.kinds` echoes the agent's `--kinds`); the gate does **zero provenance/freshness checks** on evidence files; bake stores **no source reference**; **no secret redaction** on-disk today; only a `SessionStart` hook exists (`plugin.json`), everything else is greenfield.

## 4. Workstreams (portability is now MERGED, so these build on top, not around)

ADR-0017 landed: `agents/qa-e2e-pilot.md`, `commands/*.md` are **generated-and-committed** from `core/` + `harnesses/claude/manifest.tmpl`; `validate-adapters.sh` byte-oracle guards the diff; core scripts copy verbatim into `dist/<h>/`. Edit the source, regenerate.

| WS | Contents | Source of truth |
|---|---|---|
| **WS-1 · Gate-integrity** | A (nav fail-closed), #3 (semantic mutation), #2 (`--kinds` binding), #4 (fingerprint-target), #8 (squash) | `skills/**/scripts/*.{js,sh}` (core, copied verbatim) |
| **WS-2 · Doctrine + config** | C (named exceptions), phase-first-class, B (save-session default), #6 (persona-identity), #7 (clock) | `core/persona-body.md` → regen; `docs/adr/0015*`; `init-config.sh`; `harnesses/*/mcp.snippet` |
| **WS-3 · Out-of-agent enforcement** | #1 (provenance), #5 (bake ground-truth), capture hook, gate-as-hook, `qa-verify` | new `core/enforcement/*` + `harnesses/<h>/` hook adapters + `qa-verify` |

**Scope (Q5):** **Claude-first core, portable by construction; other-3 adapters as fast-follows.** The core (gate scripts, capture schema, `qa-verify`) is harness-neutral and rides the merged generator; validate end-to-end on Claude, then ship + accuracy-run the Codex/opencode/Pi adapters as fast-follows — mirroring ADR-0017's "Pi validated first, others documented." Not a 4× v1.

## 5. Enforcement architecture (WS-3)

**Shape (Q7):** the QA-integrity logic — capture schema, act-path checks, provenance binding, verdict — is written **once** in `core/enforcement/`; each harness adds a thin adapter binding its **native** per-call hook to that core and wiring its native block. Same shared-core + thin-adapter pattern as ADR-0017. Native primitives per harness are catalogued in `harness-capability-matrix.md`: `PostToolUse` (Claude), `Pre/PostToolUse` (Codex), `tool.execute.before` (opencode), `tool_call`/`tool_result` (Pi).

### 5.1 Capture-hook (Layer 1 — record; `PostToolUse`)
A plugin-bundled **`PostToolUse`** hook (fires after each call, sees the result) appends every `browser_*` and `Bash` call `{tool, args, ts, result-digest}` to an **append-only** `.qa/runs/<run>/toolstream.jsonl` — the plugin hook is the sole writer by convention; `@playwright/mcp --save-session` supplies the browser-code ground truth. **Secrets:** the hook **redacts** `Bash` args against a secret-pattern list + config-declared credentials before writing (full args for `browser_*`); the toolstream inherits the "secrets never printed" invariant. **No hash-chain (honesty):** on an unhardened install the agent can overwrite this file, so a cryptographic chain it can recompute is false assurance — dropped. The toolstream is tamper-*evident at best*; its trust comes from `qa-verify` corroborating it independently (§5.3), not from the file itself. Real tamper-*resistance* needs the hardened tier (§6).

### 5.2 Block-hook (Layer 2 — deny before running; `PreToolUse`)
A plugin-bundled **`PreToolUse`** hook (sees args, runs before the call) hard-blocks the **phase-independent absolutes** — a mutating `browser_evaluate` (never sanctioned on *any* phase: arrange seeds via gated API writes / `browser_type`, observe is read-only), `browser_run_code_unsafe`, and a `browser_route` intercepting the tested origin. These need **no phase knowledge** — which the hook doesn't have, since phase is agent-supplied and not in the tool call. The one genuinely phase-dependent case, `browser_navigate` (arrange-entry legit, act URL-skip not), **cannot** be live-blocked without breaking legit navigation, so it is **record-only → `qa-verify`** (which has the recorded phase tags + re-drive). All other nuanced checks (provenance, fingerprint-target, persona-identity, `--kinds`) are likewise record-only → `qa-verify`. Live-block false-positives stay near-zero. The hook runs the §3-#3 semantic mutation classifier on the evaluate payload at call time. (Per harness: Claude `PreToolUse`; Codex Pre-deny; opencode `throw` in `.before`; Pi `{block:true}`.)

### 5.3 `qa-verify` (Layer 3 — authoritative; out-of-agent)
A standalone process — runnable **locally by the operator and in CI** — re-verifies a run in a trust domain the run's agent never wrote to. **Trust model:** its core is **deterministic code** (no LLM), so it needs no trust of its own; its re-drive is an **operator-invoked fresh agent session**, never the run's agent. It is **hybrid**:
- **Deterministic re-check** — evidence structure, provenance binding, independently re-derived required-kinds (§5A #2), classifier, fingerprint-target — all in code against the toolstream. Cheap.
- **Independent re-drive / re-bake of high-stakes criteria:** for **read-only** cases (cross-tenant/isolation absence-probes) a fresh minimally-scoped agent **re-drives** the probe; for **mutating** `human-action` passes, `qa-verify` **does not re-perform the mutation** (side effects / multiplicity pollution) — it **re-bakes** (independently reads the persisted state again) and re-checks provenance. Full re-drive for read-only; re-bake-only for mutating.

**Reconciliation (Q3-round1):** `qa-verify` writes `verification.json` per criterion; a run is "verified" only when every `pass` survives. On disagreement the report shows the **verifier's** verdict (pass→`fail`/`blocked`), both stamped, and the run banner reads "unverified" until `qa-verify` passes. **Un-reverified human-action/cross-tenant passes are `confidence: low` + banner (Q4-round1).**

### 5.4 Provenance binding (closes #1 & #5)
Every evidence artifact references the captured-stream call that produced it. **What counts as the captured "call" for a bake:** (a) a captured network XHR, (b) the **navigation response** that returned the DOM the read-back came from, or (c) a captured `Bash` psql/curl read. To make the match possible the capture-hook stores **bounded response bodies** for backend reads (truncated at a configured cap, hashed beyond). The match is a **containment check** — the read-back value or its entity key appears in *some* captured response/DOM for that entity (formatted-in-DOM ≠ stored value, so exact equality is wrong) — corroborated by `qa-verify`'s **re-bake** as the strong check. Rule: a read-back must correspond to *some* captured backend read; one with none → rejected. A forged `action-trace.json` with `sessionCalls:[]` behind a claimed UI act fails (stream shows activity the evidence ignores, or none behind a `pass`).

### 5.5 Persona-identity binding (closes #6)
At persona login, a read-only `whoami`/profile probe (or decoded `storageState` subject) records the session's real identity; the gate checks it equals `--persona`. **Degrade (Q11-round2):** when the app exposes no `whoami` and the token is opaque, the `cross-tenant`/`role-sensitive` criterion degrades to `confidence: low` + "identity unverified" banner — **not** `blocked`.

## 5A. WS-1 gate-integrity (in-script)
- **A — nav fail-closed:** split `browser_navigate` from blanket human-path acceptance; act-phase navigate is a workaround unless the criterion is tagged `deep-link`/`auth-boundary` or the step is phase-tagged `arrange`. (Following a real link is a `browser_click` side effect, never a `browser_navigate` call.)
- **#3 — semantic mutation classifier:** replace `MUTATION_RE` with case-insensitive, template-literal-aware detection of `fetch(...,{method:<write>})`, `axios.{post,…}`, `page.request.*`, XHR `open(<write>)`, `sendBeacon`, + existing DOM/storage writes; ship the §3-#3 evasion test matrix.
- **#2 — `--kinds` binding (independently re-derived, not trusted):** `generating-qa-checklist` emits `checklist.json` (per criterion: `id`, `requiredKinds`, tags — the pipeline's first checklist schema), but that file is the agent's **proposal**. The trusted verifier **re-derives `requiredKinds` itself** from deterministic rules over the criterion's shape (action mutates state → `human-action`; asserts cross-tenant → `cross-tenant`+`probe`; …) and enforces recorded kinds ⊇ its *own* derivation — never the agent's file. Closes the regress (else the adversary just weakens `checklist.json`). A dropped `human-action`/`cross-tenant`/`bake` fails.
- **#4 — fingerprint-target:** the criterion declares the persisted state its act asserts; the gate requires the fingerprint to cover it. `changed=false` on the asserted state when the oracle expects a change → reject.
- **#8 — squash hardening:** normalize whitespace + string literals only; stop collapsing structural brackets so distinct snippets can't alias.

## 6. Per-harness assurance tiers
See `harness-capability-matrix.md` for the full matrix. Enforcement summary:

| Harness | Live capture | Live block | Tamper-resistance | Tier |
|---|---|---|---|---|
| Claude Code | PostToolUse + `--save-session` | PreToolUse deny | plugin-bundled hook **config** (undisable-able via settings); **script-integrity needs the hardened tier** | A |
| Codex | Pre/PostToolUse + `--save-session` | Pre-deny + Stop | **managed `requirements.toml`** (agent-proof, enterprise) | A+ |
| opencode | `tool.execute.before` + `--save-session` | throw + `session.idle` gate | root `/etc/opencode` + `deny task` | A |
| Pi | `tool_call`/`tool_result` (via `pi-mcp-adapter`) | `{block}` | cooperative + `path`-deny + OS container | B→A |

**Universal floor = the out-of-agent `qa-verify`** (all four support "agent produces artifacts → external step verifies → blocks"). Native hooks are the live tier layered on top, strongest-per-harness. **Honest caveat:** on an unhardened install, plugin-bundling protects the hook *config* from being disabled, but the hook's *script files* are user-writable, so a determined agent's `Bash` could neuter them — true script-integrity comes only from the hardened tier (sandbox/managed), and the guarantee everywhere is `qa-verify`, not the live hook. The report prints the *actual* tier achieved and, on best-effort tiers, the "authoritative verdict is `qa-verify`" banner. **Default posture (Q12-round2):** strongest-out-of-box per harness + documented opt-in hardening (Codex managed / opencode `/etc` / Pi container); agent-proof-by-default would break "works on install."

## 7. Clock/time-travel (#7 — honestly down-scoped, Q5-round1)
Not a hard gate (generic detection is infeasible). Ship: (a) a doctrine ban, (b) the capture **flags** any call to a known time-control route / `setTestNow` / clock change as an **advisory** finding. Graded "doctrine + best-effort flag," said plainly.

## 8. Cost ceiling (Q8-thisround)
A run-level cost ceiling with an explicit, logged **drop-order**: advisory items → sampled re-drives → non-critical viewports → … . **Functional, honesty-gate, and cross-tenant checks are never dropped.** No silent truncation — log what was skipped.

## 9. New ADRs
- **ADR-0018 — Out-of-agent evidence enforcement.** Capture hook, gate-as-hook, `qa-verify` (hybrid re-check + re-drive), provenance binding, per-harness assurance tiers, `checklist.json` required-kinds. The hard-to-reverse decision.
- **ADR-0015 amendment** — narrow R4 via nav-fail-closed + first-class phase tags; residual recorded honestly.

## 10. Acceptance criteria (accuracy-harness fixture + adversarial fixtures)
1. Forged `action-trace.json` (`sessionCalls:[]`, equal fingerprints, fabricated steps) with no matching capture → rejected (Layer 2 + `qa-verify`).
2. Each §3-#3 payload on the act path → workaround-rejected; a read-only `fetch` GET → not flagged.
3. State-mutating criterion checkpointed `--kinds bake` (dropping derived `human-action`) → rejected via `checklist.json`.
4. Act-phase `browser_navigate` with no carve-out tag → rejected; tagged `deep-link`/`auth-boundary`/`arrange` → allowed.
5. Absence-probe recorded as `participant` while captured identity is `super-admin` → rejected (or `confidence:low` when identity unverifiable).
6. Fingerprint covering an unchanged unrelated field while the asserted state changed → rejected.
7. `qa-verify` re-drives a cross-tenant criterion independently and overrides a forged in-run pass.
8. Honest degradation: hook-less harness → Layers 1–2 downgrade, Tier-B banner printed, `qa-verify` still gates. No silent pass.
9. No recall regression on the gated fixture, or explicit logged recategorization.

## 11. Out of scope (YAGNI)
- Hardware-backed signing / remote attestation — hash-chain + out-of-agent `qa-verify` (re-check + sampled re-drive) is the soundness boundary.
- Gating non-QA Bash (capture records all Bash; the gate reasons only about writes relevant to a criterion's asserted state).
- Retrofitting provenance onto historical runs.

## 12. Delivery — the "sound core" first (Q6-round1)
WS-1 (all gate-integrity fixes) + the Layer-1 capture hook + the local `qa-verify` form a self-sufficient, adversarially-meaningful slice that lands on a branch off `main` with no dependency on further portability work. Persona-identity (#6), clock (#7), and the Codex/opencode/Pi hook adapters are fast-follows.

## 13. Decisions locked
1. Threat model **adversarial**, in-agent soundness limit documented (§1).
2. Enforcement out-of-agent: **capture-hook** (`PostToolUse`) + **block-hook** (`PreToolUse`, phase-independent absolutes only) + **`qa-verify`** (deterministic re-check + read-only re-drive / mutating re-bake) + provenance binding (§5); ADR-0018. No hash-chain (false assurance, cut).
3. Shared-core gate + thin per-harness adapter, native primitives (§5, matrix).
4. Live-block only the unambiguous workarounds; nuanced checks defer to `qa-verify` (§5.2).
5. `qa-verify` = re-check all + re-drive high-stakes; authoritative; local & CI (§5.3).
6. Claude-first core, portable by construction; other-3 fast-follows (§4).
7. Vocabulary unchanged; no sixth verdict; `human-action` stays an evidence kind.
8. **Operator-interruption discipline:** human confirmation is allowed **only in setup phases** (pre-flight/analyze/generate — e.g. `confirming-discovered-roles`); the **Verify** loop runs with **no user interruption**, and `qa-verify` is an out-of-band step the operator *invokes*, never a mid-run prompt.

## Appendix — ticket-sized cut (for the tracker)
- **T-1 (WS-1):** semantic mutation classifier + evasion tests *(#3)*
- **T-2 (WS-1):** nav fail-closed + carve-out tags *(A)*
- **T-3 (WS-1):** `checklist.json` required-kinds + `--kinds` binding *(#2)*
- **T-4 (WS-1):** fingerprint-target enforcement *(#4)*
- **T-5 (WS-1):** squash hardening *(#8)*
- **T-6 (WS-2):** named exceptions + first-class phase tags in `core/persona-body.md` + `interaction-discipline.md`; regen *(C, narrows R4)*
- **T-7 (WS-2):** `--save-session` default-on via `humanInteraction.sessionLogDir` *(B)*
- **T-8 (WS-3):** plugin-bundled **capture-hook** (`PostToolUse`) → append-only `toolstream.jsonl` (+ bounded response bodies) + secret redaction; **block-hook** (`PreToolUse`) for phase-independent absolutes *(Layers 1–2)*
- **T-9 (WS-3):** provenance binding in gate + `qa-verify` *(#1, #5)*
- **T-10 (WS-3):** persona-identity capture + check + degrade *(#6)*
- **T-11 (WS-3):** `qa-verify` (re-check + sampled re-drive) + reconciliation *(Layers 2–3)*
- **T-12 (WS-2):** clock doctrine ban + best-effort capture-flag *(#7)*
- **T-13:** Codex/opencode/Pi hook adapters (fast-follow) + per-harness manual enforcement run
- **T-14 (optional fast-follow):** `humanInteraction.autonomousSetup` flag — intentional auto-accept of pre-run setup rounds (`confirming-discovered-roles`) for clean headless/CI runs (operator-interruption discipline, decision #8)
- **ADR-0018** + ADR-0015 amendment
