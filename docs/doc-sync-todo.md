# Documentation sync — TODO (post 6b / increment-7 / review-fixes)

> Created 2026-09-05 after landing: qa-kit **6b** (opt-in auto-seed, ADR-0023 update), the multi-harness
> **increment 7** (ADR-0024), and the code-review follow-ups (PRs #55–#61). Most docs were updated inline
> as those changes landed; this list captures what an audit found **still stale or missing**, plus the one
> gate gap. Grounded in file:line — verify each before ticking.

## 🔴 Pending — do these

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
