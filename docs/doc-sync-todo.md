# Documentation sync — TODO (post 6b / increment-7 / review-fixes)

> Created 2026-09-05 after landing: qa-kit **6b** (opt-in auto-seed, ADR-0023 update), the multi-harness
> **increment 7** (ADR-0024), and the code-review follow-ups (PRs #55–#61). Most docs were updated inline
> as those changes landed; this list captures what an audit found **still stale or missing**, plus the one
> gate gap. Grounded in file:line — verify each before ticking.

## 🔴 Pending — do these

### `preflight.sh` cross-origin detection uses raw string comparison (audit-2 W3-7a, design-risk)
- [ ] `skills/driving-browser-qa/scripts/preflight.sh`'s cross-origin detector (`[[ "$API_ORIGIN" !=
      "$BASE_URL" ]]`) compares `apiOrigin` against the FULL `baseUrl` string, including any path —
      not a genuine origin-level (scheme+host+port) comparison the way `probing-apis-through-browser`
      SKILL.md's Step 1 correctly describes it (`window.location.origin`). A `baseUrl` with a path
      (e.g. `https://app.example.com/dashboard`) and an `apiOrigin` set to the bare origin
      (`https://app.example.com`) would false-positive as "cross-origin" even though they're the same
      origin. **Confirmed but low-severity:** this detection is purely INFORMATIONAL (`preflight.sh`
      never aborts on it — only prints a "verify CORS allows credentials" note), so the impact is a
      possibly-inaccurate log line, never a false pass/fail. A real fix needs portable URL-origin
      parsing (strip path/query, normalize scheme+host+port) in bash — a dual-engine
      python3/node helper, not a one-line change — out of scope for this batch.

### `ensure_ascii=False` sweep (audit-2 W3-7a, journal.sh instance fixed inline)
- [ ] **Confirmed systemic dual-engine byte-parity gap:** `skills/checkpointing-qa-memory/scripts/journal.sh`'s
      4 `json.dumps(...)` calls (paired with `jq -c`/`jq -S -c`, no `-a`/`--ascii-output`) lacked
      `ensure_ascii=False` — python3's default escapes non-ASCII to `\uXXXX` while jq emits raw UTF-8, so any
      run with non-ASCII action/title text (this repo explicitly supports Arabic/RTL — see
      `driving-browser-qa`'s SKILL) produced byte-DIFFERENT `journal.ndjson`/canonical output depending on
      engine. **Fixed inline** (audit-2 W3-7a, `tests/journal/run.sh`'s new "ensure_ascii" sub-case proves
      byte parity + no `\u` escaping under both engines) — this was the one Appendix A named explicitly.
      **Broader finding (out of this batch's scope):** the SAME missing-`ensure_ascii=False` pattern is
      present in `json.dumps` calls across most other engine scripts that pair with a bare `jq -c`/`jq -S -c`
      leg — at minimum `checkpoint.sh`, `record-evidence.sh`, `journal-emit.sh`, `qa-reconcile.sh`, `fold.sh`,
      `rebake.sh`, `toolstream.sh`, `provenance.sh`, `qa-verify.sh`, `memory-sync.sh` all have one or more
      unaudited occurrences. A dedicated pass should (a) grep every `json.dumps(` in the repo, (b) for each,
      confirm whether its paired jq leg lacks `-a`, and (c) add `ensure_ascii=False` + a byte-parity test case
      (Arabic/emoji fixture) per file — this is a real, repo-wide correctness gap, not a per-file curiosity,
      but is too large a surface to land safely inside a "verified minors" batch commit.

### Design-risk items verified but NOT fixed (audit-2 W3-7a batch — logged per the verify-then-fix rule)
- [ ] **`legalPhaseEdges` validated-but-unconsumed:** `state-machine.json`'s `legalPhaseEdges` (phase-level
      sequence, e.g. `["Pre-flight","Analyze"]`) is schema-validated by
      `skills/checkpointing-qa-memory/scripts/validate-state-machine.sh` but has NO runtime consumer anywhere
      (confirmed by grep: only the schema doc, the FSM-enforcement doc, and the validator itself reference it
      — unlike its sibling `legalSubStateEdges`, which `journal-emit.sh`'s `guard_transition`/
      `legal_predecessors_for` actually enforces at append time). A declared-but-toothless field: nothing
      currently rejects an illegal PHASE transition the way sub-state transitions are guarded. Implementing
      phase-level enforcement (mirroring `guard_transition`'s pattern one level up) is a real feature, not a
      minor fix — out of scope for this batch.
- [ ] **`state-machine.json` `toolClasses` vs `qa-verify.sh`'s `classify_tool` — re-verified, core mapping is
      actually consistent:** all 8 declared `toolClasses` (`browser-navigate`, `browser-snapshot`,
      `browser-interaction`, `browser-evaluate-readonly`, `browser-evaluate-mutating`, `browser-mutation`,
      `probe`, `bash`) are reachable via `classify_tool`'s case arms (the two `browser-evaluate-*` classes via
      its `__evaluate__` sentinel + `evaluate_mutates`), for every tool named in
      `skills/driving-browser-qa/references/driver-capabilities.md`. One real gap found instead: the Playwright
      MCP's `browser_find` tool (a semantic-locator search) is not in `classify_tool`'s case statement AND is
      absent from `driver-capabilities.md` entirely — it silently classifies to "" (unrecognized, never
      flagged as a phase-surface violation either way). This is a "new tool onboarding" gap broader than the
      audit's toolClasses claim; deciding its class + updating `driver-capabilities.md` consistently is a
      separate task.
- [ ] **`toolstream.sh`'s `next_seq` mints without a file lock:** `next_seq` (max existing `.seq` + 1) is a
      read-then-write over `toolstream.jsonl` with no `flock`/lock file — two concurrent appends (only
      reachable via ADR-0003's narrow opt-in parallel fan-out, not the sequential-by-default path) could read
      the same max-seq and mint a DUPLICATE seq value. Confirmed real (same TOCTOU class as the already-fixed
      W1-4 journal-merge lock), but a portable (macOS/Linux, bash-3.2) lock implementation + a deterministic
      concurrency test is more than a minor fix — out of scope for this batch.

### README/INSTALL perl/grep-P claim — VERIFIED TRUE, not stale (audit-2 W3-7a)
Re-checked against HEAD: `skills/analyzing-feature-ui/scripts/index-routes.sh` and
`skills/ingesting-spec-kit/scripts/find-spec-kit.sh` both genuinely detect `grep -oP` support at runtime and
fall back to `perl` when it's unavailable (macOS/BSD grep) — `tests/portability/run.sh` asserts byte-parity
between the two paths for every PCRE pattern either script uses. README.md:197 / INSTALL.md:121,124's claim
that "scripts fall back to perl where macOS/BSD grep lacks -P" is accurate. No fix needed — logged here only
so this claim isn't re-flagged as stale without re-verification.

### Detection/config skills — design-risk items verified but NOT fixed (audit-2 W3-7a)
- [ ] **`detecting-stack-profile`'s `source-drift` mode is never produced:** `detect-stack.sh`'s
      `mode` field only ever takes two values — `black-box` (default) or `local-matched` (local code
      present) — confirmed by grep: no code path assigns `mode="source-drift"` anywhere. The doc
      (`SKILL.md:62`) and `writing-qa-reports/SKILL.md:43` both describe/consume a third mode meaning
      "static code analysis and the live runtime fingerprint DISAGREE," but nothing ever computes
      that comparison. Implementing genuine source-vs-runtime drift detection is a real feature
      (comparable in scope to the already-landed W3-5c runtime-fingerprint work), not a minor fix.
- [ ] **`rails-yml`/`gettext-po` i18n mechanisms are unreachable:** `stack-signatures.json` declares
      `rails -> rails-yml` (`config/locales`, YAML) and `django -> gettext-po` (`locale`, `.po`) as
      real i18n mechanisms, but `detect-stack.sh`'s `detect_i18n` only ever locates/parses `php` and
      `json`-format catalogs (confirmed by the detector's own fallback message: "no locale-named
      php/json catalog found (e.g. **unsupported yml/po**, or non-locale filenames)"). A Rails or
      Django project's i18n detection will ALWAYS degrade to `i18n_absent`, even with real locale
      catalogs on disk — the `i18n-raw-key`/`i18n-script-mismatch` UX detectors can never reach
      `oracleSource` for those two stacks. Adding YAML + gettext `.po` catalog parsers (portable,
      dual-engine) is a real feature addition, not a minor fix.
- [ ] **`budgetExceeded` is structurally unreachable in `confirming-discovered-roles`' own 3-round
      flow:** `frontier.js`'s `budgetExceeded(rounds, budget) { return rounds > budget; }` is called
      as `budgetExceeded(roundsCompleted, 3)` (SKILL.md:286) for a flow the SKILL itself documents as
      "IS 3 rounds, so the budget is exactly used up by design" (SKILL.md:284). Since the flow has
      only 3 rounds total, `roundsCompleted` can never exceed 3, so `roundsCompleted > 3` can never be
      true for THIS call site — the auto-accept-on-budget-exhaustion path it guards is dead code as
      written, even though the unit-level function (`tests/frontier/run.sh`) is itself correct and
      tested. Whether the fix is `>=` instead of `>`, a genuinely lower budget for THIS call site, or
      a different `roundsCompleted` semantic (e.g. counting failed/abandoned attempts rather than
      round index) needs a deliberate design decision, not a blind operator flip — changing it wrong
      risks auto-accepting assumptions while a host is still legitimately mid-flow.

### CI / gate (config, but the highest-value gap)
- [x] **`.github/workflows/adapters.yml` only ran `scripts/validate-adapters.sh`** (engine byte-oracle) — no
      qa-kit gate. **DONE (PR #63):** added a dedicated `qa-kit` job running `validate-qakit-adapters.sh` + the
      10 qa-kit dual-engine suites.
- [ ] **Broader finding (out of this session's scope):** the **entire `tests/` corpus (44 suites)** — including
      all the *engine* tests — is likewise **ungated in CI** (adapters.yml never ran them). The new `qa-kit` job
      covers the qa-kit subset; wiring the engine suites (some need node) is a separate maintainer decision — a
      blanket `for d in tests/*/run.sh` loop is the obvious move but needs each suite confirmed green in a clean
      CI image first.

### Root `README.md` — DONE (PR #64)
- [x] **~239:** "v1 Claude-only" flipped to: TDQA data layer (ADR-0023) + all-four-harnesses (ADR-0024).
- [x] **~53:** ADR range `0001–0022` → `0001–0024` (0023/0024 named).
- [x] **~47:** `16 skills` → `17 skills` (confirmed 17 dirs under `skills/`; CLAUDE.md was right).
- [x] qa-kit paragraph now mentions the TDQA data layer + multi-harness with ADR links.

### `CONTEXT.md` (glossary — domain-modeling discipline) — DONE (PR #65)
- [x] Added glossary entries: **Auto-seed (qa-kit)**, **Seed command (qa-kit)**, **Co-install (qa-kit, non-Claude)**.
- [x] Confirmed 6a terms already have their own entries (Data-baseline, Origin, Fixture, Pinned
      expectation / oracleSource, plus Drift / Run-config / Out-of-plan act) — no additions needed.

### Memory (not a repo doc) — DONE
- [x] `…/memory/qa-kit-plugin-packaging-facts.md` updated: the "non-Claude build deferred" line now records the
      increment-7 landing (ADR-0024) — generator, per-harness skill-ref rendering, co-install contract, engine
      untouched. (Lives outside the repo, so not in any PR.)

## 🟡 Optional / lower priority
- [x] **DONE (2026-09-06, audit-remediation C3):** the per-harness *engine* adapter READMEs
      (`harnesses/{pi,codex,opencode}/README.md`) + `docs/harness-adapters.md` now say "17 skills"
      (was 16). Done as an **engine** change in its own increment (not qa-kit), so engine-untouched
      is preserved. Root README + CLAUDE.md were already 17.
- [x] **DONE (PR #68):** added the **"qa-kit manual accuracy run"** procedure to `docs/harness-adapters.md`
      (co-install order → drive the spine → confirm skill/`{{PLUGIN_ROOT}}` resolution → score).

## 🧹 Code-review follow-ups (from the two inline reviews) — DONE (PR #68)
- [x] S1/SP2 — de-duplicated the 3 installers into `qa-kit/harnesses/_install-common.sh` + thin wrappers.
- [x] S2 — `field()` fails loud on a missing profile key (was a silent `''`).
- [x] SP1 — single-sourced the qa-kit CI suite list in `qa-kit/scripts/run-qakit-ci.sh`; `adapters.yml` calls it.
- [x] **Engine suites now gated (2026-09-06):** `scripts/run-engine-ci.sh` enrolls **all 35** self-contained
      engine suites (probed green under `timeout 90`); `adapters.yml` runs it as the `engine` job. `qa-reconcile`
      + `rebake` were **RED on main@147e5a9** (their `act_intent`/`act_committed` emissions predated the FSM
      guard's `criterion_started` requirement — a latent bug the ungated corpus was hiding) — **fixed** in
      `fix/reconcile-rebake-fsm-guard` and now enrolled. A blanket `tests/*/run.sh` glob is still avoided
      (some suites need a live app / hang).

## ✅ Already updated inline this session (for traceability — verify, don't redo)
- ADR-0023 — 6b landing + §7 correction (detect-seed reads `stack-profile.json`).
- ADR-0024 — new (multi-harness decision + grill-2 reversal logged).
- ADR-0022 — superseded-note pointing at ADR-0024.
- `docs/harness-adapters.md` — "Installing qa-kit" flipped from Claude-only to all-four + co-install contract.
- `docs/superpowers/specs/2026-09-04-qa-kit-tdqa-data-layer-design.md` §7 + status; the increment-7 design spec (×2 grill).
- `qa-kit/README.md` — TDQA "Data" section + "Running on other harnesses" section.
- `CLAUDE.md` — TDQA invariant + multi-harness note + qa-kit layout block (new scripts/dirs).
- `.qa/config.json.example` — `_autoSeedDoc` note.
- Command bodies: `qa-kit/commands/qa-spec.md` (6b seed proposal + gated exec) — and via `qa-kit/core/` for all harnesses.
