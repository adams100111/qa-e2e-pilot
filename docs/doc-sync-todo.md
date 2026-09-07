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

### `CONTEXT.md` (glossary — domain-modeling discipline) — DONE (PR #65)
- [x] Added glossary entries: **Auto-seed (qa-kit)**, **Seed command (qa-kit)**, **Co-install (qa-kit, non-Claude)**.
- [x] Confirmed 6a terms already have their own entries (Data-baseline, Origin, Fixture, Pinned
      expectation / oracleSource, plus Drift / Run-config / Out-of-plan act) — no additions needed.

### Memory (not a repo doc) — DONE
- [x] `…/memory/qa-kit-plugin-packaging-facts.md` updated: the "non-Claude build deferred" line now records the
      increment-7 landing (ADR-0024) — generator, per-harness skill-ref rendering, co-install contract, engine
      untouched. (Lives outside the repo, so not in any PR.)

### qa-kit Claude marketplace payload — dev-only scripts still ship (audit-2 W3-7b, design-risk, logged not fixed)
- [ ] **`build-qakit-adapter.sh` now excludes `run-qakit-ci.sh`/`build-qakit-adapter.sh`/`validate-qakit-adapters.sh`
      from `qa-kit/dist/<h>/scripts/`** (fixed this session — covers the codex/pi/opencode install path, which
      copies from `dist/`). The **Claude** install is different: per ADR-0024 Claude ships as the
      dependencies-model plugin straight from `marketplace.json`'s `"source": "./qa-kit"`, i.e. the **entire**
      `qa-kit/` directory (including `qa-kit/scripts/run-qakit-ci.sh`, `build-qakit-adapter.sh`,
      `validate-qakit-adapters.sh`, and `qa-kit/harnesses/`) becomes the installed Claude plugin payload — there is
      no plugin-level ignore/allow-list mechanism (checked: no `.claudeignore` or equivalent). `run-qakit-ci.sh`
      hard-references `$ROOT/tests/...`, which does not exist in an installed user project, so it would be a
      broken/dead command there (harmless — nothing invokes it — but shipped dead weight, and a nonzero find/audit
      hit). **Not fixed this session:** genuinely separating "repo-dev tooling" from "plugin payload" for the
      Claude path needs either (a) a real plugin-packaging exclude mechanism, or (b) relocating dev-only scripts
      out of `qa-kit/scripts/` into a repo-root `tools/`-style directory referenced by CI instead — both are
      structural decisions beyond a verify-then-fix script tweak. Revisit alongside any future plugin-packaging
      work.

### Relative multiplicity fixtures have no script-level validation (audit-2 W3-7b, design-risk, logged not fixed)
- [ ] **Verified true:** `check-fixtures.sh` only gates the **computed** `fixture.expect` shape
      (`{path,value,tolerance,oracleSource}`) — the header explicitly says multiplicity/empty-state
      criteria "derive `bake`, not `computed`... are NOT gated here." Their shape
      (`{path:"count",baselineOf:{entity,scope},delta}`) is entirely operator-authored with no script
      checking `baselineOf.entity`/`scope` reference a real `data-baseline.json` row or that `delta` is
      a sane integer — a malformed one is only caught late, at run resolution
      (`data-baseline.sh expected-count`), not at authoring time. **Not fixed this session:** this is a
      real gate gap, but closing it is a new validation feature (a second check-fixtures-style script
      pass, or extending `check-fixtures.sh`'s scope to multiplicity rows) rather than a verify-then-fix
      minor. `qa-kit/core/commands/qa-scenarios.md` now documents the gap explicitly at the point the
      shape is introduced, so at least it is no longer a silent gap. Revisit as its own increment if
      malformed multiplicity fixtures turn out to be a recurring authoring mistake in practice.

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
