# Documentation sync — TODO (post 6b / increment-7 / review-fixes)

> Created 2026-09-05 after landing: qa-kit **6b** (opt-in auto-seed, ADR-0023 update), the multi-harness
> **increment 7** (ADR-0024), and the code-review follow-ups (PRs #55–#61). Most docs were updated inline
> as those changes landed; this list captures what an audit found **still stale or missing**, plus the one
> gate gap. Grounded in file:line — verify each before ticking.

## 🔴 Pending — do these

### CI / gate (config, but the highest-value gap)
- [ ] **`.github/workflows/adapters.yml` only runs `scripts/validate-adapters.sh`** (the engine byte-oracle).
      It runs **no qa-kit test suite and not `validate-qakit-adapters.sh`** — so ALL of 6a/6b/7 is **ungated in
      CI**. Add steps to run `bash qa-kit/scripts/validate-qakit-adapters.sh` and each
      `tests/{constitution,spec-snapshot,qa-kit-enforcement,runconfig-merge,data-baseline,check-fixtures,detect-seed,auto-seed,qa-kit-phases,qakit-adapters}/run.sh`.
      (Consider a tiny `for d in tests/*/run.sh; do bash "$d"; done` loop so new suites auto-enroll.)

### Root `README.md`
- [ ] **Line ~239:** "v1 is **Claude-only**; non-Claude builds are deferred." — **contradicts increment 7**
      (ADR-0024). Flip to: qa-kit now generates Codex/Pi/opencode adapters from `qa-kit/core/`; engine untouched.
- [ ] **Line ~53:** "`docs/adr/  0001–0022`" → **`0001–0024`** (0023 TDQA data layer, 0024 multi-harness added).
- [ ] **Line ~47:** "`skills/  16 skills`" disagrees with `CLAUDE.md:62` ("**17 skills**"). Reconcile to one
      number (pre-existing discrepancy, not caused by 6b/7 — confirm the true count and fix whichever is wrong).
- [ ] (Optional) The qa-kit paragraph (lines ~235–243) doesn't mention the **TDQA data layer** (6a/6b) or
      **multi-harness** (7). Add a sentence + links to ADR-0023 / ADR-0024 if you want README to reflect them.

### `CONTEXT.md` (glossary — domain-modeling discipline)
- [ ] Add/confirm glossary entries for the terms 6b introduced: **auto-seed** (opt-in, disposable-env-only
      write path), **seed command / detect-seed** (the proposed stack seed command; a *proposal*, human-confirmed),
      and the **co-install contract** (7). The *multiplicity* entry (line 36) already notes the seeded baseline.
- [ ] Confirm 6a terms have their own entries (not just inline mentions): **data-baseline**, **origin**
      (seeded|created), **fixture**, **oracleSource** (human|llm-suggested), **pinned expectation**. Add any missing.

### Memory (not a repo doc, but stale)
- [ ] `…/memory/qa-kit-plugin-packaging-facts.md` describes only the Claude dependencies-model packaging. Add a
      line noting qa-kit is now **multi-harness** (ADR-0024): Codex/Pi/opencode generated from `qa-kit/core/` into
      git-ignored `qa-kit/dist/<h>/`, co-install contract, engine still untouched.

## 🟡 Optional / lower priority
- [ ] `docs/harness-adapters.md` — the per-harness engine READMEs say "Runs the same **16 skills**" (matches the
      README's 16, not CLAUDE's 17) — fold into the skills-count reconciliation above.
- [ ] Consider a short **"qa-kit manual accuracy run"** procedure in `docs/harness-adapters.md` (mirrors the
      engine's), since increment 7's honest boundary points at it but doesn't spell out the qa-kit-specific steps.

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
