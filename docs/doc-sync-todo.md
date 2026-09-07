# Documentation sync — TODO (post 6b / increment-7 / review-fixes)

> Created 2026-09-05 after landing: qa-kit **6b** (opt-in auto-seed, ADR-0023 update), the multi-harness
> **increment 7** (ADR-0024), and the code-review follow-ups (PRs #55–#61). Most docs were updated inline
> as those changes landed; this list captures what an audit found **still stale or missing**, plus the one
> gate gap. Grounded in file:line — verify each before ticking.

## 🔴 Pending — do these

### CI / gate (config, but the highest-value gap)
- [x] **`.github/workflows/adapters.yml` only ran `scripts/validate-adapters.sh`** (engine byte-oracle) — no
      qa-kit gate. **DONE (PR #63):** added a dedicated `qa-kit` job running `validate-qakit-adapters.sh` + the
      qa-kit dual-engine suites (list lives in `qa-kit/scripts/run-qakit-ci.sh`).
- [x] **RESOLVED — superseded by the "Engine suites now gated" entry below** (was: "the entire `tests/`
      corpus, including engine tests, is likewise ungated in CI"). That is no longer true: `adapters.yml` runs
      four jobs — `validate` (engine byte-oracle), `qa-kit` (`run-qakit-ci.sh`), `engine`
      (`scripts/run-engine-ci.sh`, self-contained engine suites), and `suite-coverage`
      (`scripts/check-suite-coverage.sh`, a meta-gate enforcing every `tests/<suite>/` dir is enrolled in
      exactly one of the two suite lists — currently green). This bullet was left un-ticked after that work
      landed, contradicting the later entry; ticked here to remove the self-contradiction. A blanket
      `tests/*/run.sh` glob is still deliberately avoided (some suites need a live app / hang) — the two
      curated lists plus the coverage meta-gate is the durable answer to that gap, not a future TODO.

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

## 🟠 Wave 3 (audit-2 W3-7c) — tracked debt found during this pass, not fixed here
- [ ] `scripts/run-engine-ci.sh`'s header comment says "All 38 self-contained engine suites are
      enrolled" but the `SUITES=(...)` array currently has **39** entries (confirmed by counting the
      array at HEAD). Out of this task's file scope (`scripts/run-engine-ci.sh` is T7's file, which
      also owns the deferred `bash32-safety`-before-`block-hook` alphabetical-ordering minor); logged
      here rather than edited so T7's own commit doesn't collide with this doc-only one.

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
