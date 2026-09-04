# qa-kit increment 6b — opt-in auto-seed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.
>
> Design: `docs/superpowers/specs/2026-09-04-qa-kit-tdqa-data-layer-design.md` §4/§7/§11 + ADR-0023.
> Builds on **6a** (landed): `data-baseline.json` (`origin: seeded|created`) + declare-and-verify. 6b adds
> the OPT-IN write path: apply the declared `seeded` rows via the stack's seeding mechanism, on a disposable
> env only.

**Goal:** Let qa-kit **auto-establish** the seeded baseline on a disposable env — detect (propose) the stack's
seed mechanism, gate the write behind `allowApiWrites` + the disposable-env marker, run it, then reuse 6a's
declare-and-verify read-back — with the qa-e2e-pilot **engine byte-for-byte unchanged**.

**Architecture:** Two new pure dual-engine scripts — `detect-seed.sh` (reads the engine-emitted
`stack-profile.json` + `repos[]` and PROPOSES `{mechanism, command, cwd}`) and `auto-seed.sh decide` (the pure
gate: may-we-seed given config + env). The actual command execution is a **guarded step in `/qa-spec`'s
data-baseline flow / the run pre-flight** (a `Bash` exec, not inside a pure script), so the deterministic logic
stays unit-testable and the exec stays explicit + gated. **No engine skill is modified** — critically,
`detecting-stack-profile` is READ, never edited.

**Tech Stack:** Bash + `jq`/`python3` (repo idiom); dual-engine tests mirroring `tests/data-baseline/run.sh`.

## Global Constraints

- **Engine untouched — including `detecting-stack-profile`.** The design's §7 "extend `detecting-stack-profile`
  to emit `seed:{}`" is **superseded**: that is an engine skill, and 6b must NOT modify it. Instead a
  qa-kit-owned `detect-seed.sh` READS the engine's `stack-profile.json` (already emitted; `orm`/framework
  fields) + `.qa/config.json` `repos[]` and derives the seed proposal. No change to `core/`/`skills/`/root
  `scripts/`/`qa-verify`.
- **The write is doubly-gated + human-confirmed.** Auto-seed runs ONLY when `allowApiWrites == true` AND the
  `seedableEnvMarker` env var (default `QA_DISPOSABLE_ENV`) is set AND the operator confirms. Any gate unmet →
  fall back to 6a **declare-and-verify (writes nothing)**. This mirrors the engine's sole write gate
  (`allowApiWrites` + disposable marker) — origin lists are never a write boundary (see `config.json.example`).
- **Detection is a PROPOSAL, never blind execution.** `detect-seed.sh` proposes a command; the human confirms
  or edits it (or declares `seedCommand` directly). qa-kit never runs an unconfirmed/auto-guessed command.
- **Reuse 6a for verification.** After seeding, the baseline is confirmed via the same 6a read-back
  (`data-baseline.sh` + the run's scoped measured count) — 6b adds the write, not a second verifier.
- Deterministic + dual-engine (`jq`/`python3`, honor `QA_ENGINE`, die-if-neither); no `grep -P`/`perl`/`node`;
  no attribution / `Co-Authored-By`; never commit `dist/`.
- **Docs are a first-class step in every task.**
- **Honest test boundary:** the pure logic (`detect-seed` proposal, the `auto-seed decide` gate) is fully
  unit-tested; the actual `db:seed` **exec** writes to a real app and is NOT headlessly unit-tested — it is a
  guarded command step + a manual smoke-test note (like the live accuracy run).

## File Structure

- `qa-kit/scripts/detect-seed.sh` **(new)** — `propose <stack-profile.json> [<config.json>]` → `{mechanism,
  command, cwd}` or `{mechanism:null}`. Pure.
- `tests/detect-seed/run.sh` **(new)** — dual-engine tests.
- `qa-kit/scripts/auto-seed.sh` **(new)** — `decide <config.json>` → `{seed:bool, reason}` (reads
  `allowApiWrites` + the `seedableEnvMarker` env var). Pure (no exec).
- `tests/auto-seed/run.sh` **(new)** — dual-engine tests.
- `qa-kit/commands/qa-spec.md` **(modify)** — capture/confirm `seedCommand`; document the gated exec + fallback.
- `tests/qa-kit-phases/run.sh` **(modify)** — extend with detect-seed proposals + gate decisions.
- `docs/adr/0023-qa-kit-tdqa-data-layer.md` **(modify)** — record the 6b landing + the §7-superseded note;
  `docs/superpowers/specs/2026-09-04-qa-kit-tdqa-data-layer-design.md` **(modify)** — §7 correction;
  `qa-kit/README.md`, `CLAUDE.md`, roadmap status **(modify)**; `.qa/config.json.example` **(modify)** — a
  documented `_autoSeedDoc` note (the gate reuses `allowApiWrites` + `seedableEnvMarker`).

## Task 1: `detect-seed.sh` — propose the stack's seed command (reads stack-profile.json)

**Files:** Create `qa-kit/scripts/detect-seed.sh`, `tests/detect-seed/run.sh`.

**Interfaces:**
- `detect-seed.sh propose <stack-profile.json> [<config.json>]` → prints `{mechanism, command, cwd}` where
  `mechanism ∈ {laravel, prisma, rails, django, null}`, `command` the proposed seed command (or null), `cwd`
  the repo dir to run it in (from `config.json` `repos[]` matching role `backend`, else `.`). Derivation from
  `stack-profile.json` (READ ONLY — the engine emits it): a `laravel` framework/`php` → `php artisan db:seed`;
  a `prisma` orm → `npx prisma db seed`; `rails` → `bin/rails db:seed`; `django` → `python manage.py migrate`;
  otherwise `{mechanism:null, command:null}`. Deterministic; cross-engine byte-identical.

- [ ] **Step 1: Write the failing tests** (`tests/detect-seed/run.sh`, dual-engine — mirror
  `tests/data-baseline/run.sh` structure incl. a cross-engine block):

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/detect-seed.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '%s' '{"framework":"laravel","language":"php"}' > "$T/laravel.json"
  check "$E laravel -> artisan" "$(QA_ENGINE=$E bash "$SH" propose "$T/laravel.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["command"])')" "php artisan db:seed"
  printf '%s' '{"framework":"express","orm":"prisma"}' > "$T/prisma.json"
  check "$E prisma -> prisma db seed" "$(QA_ENGINE=$E bash "$SH" propose "$T/prisma.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["command"])')" "npx prisma db seed"
  printf '%s' '{"framework":"unknown"}' > "$T/unk.json"
  check "$E unknown -> null mechanism" "$(QA_ENGINE=$E bash "$SH" propose "$T/unk.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mechanism"] is None)')" "True"
  # cwd from config repos[] role=backend
  printf '%s' '{"repos":[{"role":"backend","path":"/srv/api"}]}' > "$T/cfg.json"
  check "$E cwd from backend repo" "$(QA_ENGINE=$E bash "$SH" propose "$T/laravel.json" "$T/cfg.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cwd"])')" "/srv/api"
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
if command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  X="$(mktemp -d)"; printf '%s' '{"framework":"laravel","language":"php"}' > "$X/s.json"
  vj="$(QA_ENGINE=jq bash "$SH" propose "$X/s.json")"; vp="$(QA_ENGINE=python3 bash "$SH" propose "$X/s.json")"
  check "cross-engine proposal identical" "$([ "$vj" = "$vp" ] && echo same || echo diff)" "same"; rm -rf "$X"
fi
echo "detect-seed: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL** (script missing).
- [ ] **Step 3: Implement `qa-kit/scripts/detect-seed.sh`** — header/`die`/`has_jq`/`has_py`/`QA_ENGINE` idiom
  from `qa-kit/scripts/data-baseline.sh`. Read `stack-profile.json`; map framework/orm → mechanism+command per
  the interface table; read `cwd` from the optional `config.json` `repos[]` entry whose `role=="backend"` (else
  `"."`). Emit compact sorted JSON (jq `-Sc` / python `sort_keys=True, separators=(",",":")` — the 6a byte-
  identity idiom). Never execute anything.
- [ ] **Step 4: Run → `FAIL=0`**; `bash -n`.
- [ ] **Step 5: Commit** `feat(qa-kit): detect-seed.sh — propose the stack's seed command from stack-profile.json (reads, never modifies detecting-stack-profile)`

## Task 2: `auto-seed.sh decide` — the pure write gate

**Files:** Create `qa-kit/scripts/auto-seed.sh`, `tests/auto-seed/run.sh`.

**Interfaces:**
- `auto-seed.sh decide <config.json>` → prints `{seed:<bool>, reason:<string>}`. `seed:true` iff
  `config.allowApiWrites == true` AND the env var named by `config.seedableEnvMarker` (default
  `QA_DISPOSABLE_ENV`) is set to a non-empty value. Else `seed:false` with a reason
  (`allowApiWrites:false` | `disposable-env marker '<name>' not set`). Exit 0 always (a decision, not a gate
  failure). NEVER executes a seed command — it only decides.

- [ ] **Step 1: Write the failing tests** (`tests/auto-seed/run.sh`, dual-engine):

```bash
#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/../../qa-kit/scripts/auto-seed.sh"
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
run_engine() {
  local E="$1" T; T="$(mktemp -d)"
  printf '%s' '{"allowApiWrites":true,"seedableEnvMarker":"QA_DISPOSABLE_ENV"}' > "$T/c.json"
  local seed
  seed="$(QA_DISPOSABLE_ENV=1 QA_ENGINE=$E bash "$SH" decide "$T/c.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])')"
  check "$E writes+marker -> seed true" "$seed" "True"
  seed="$(env -u QA_DISPOSABLE_ENV QA_ENGINE=$E bash "$SH" decide "$T/c.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])')"
  check "$E marker unset -> seed false" "$seed" "False"
  printf '%s' '{"allowApiWrites":false,"seedableEnvMarker":"QA_DISPOSABLE_ENV"}' > "$T/c2.json"
  seed="$(QA_DISPOSABLE_ENV=1 QA_ENGINE=$E bash "$SH" decide "$T/c2.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seed"])')"
  check "$E writes false -> seed false" "$seed" "False"
  rm -rf "$T"
}
command -v jq >/dev/null 2>&1 && run_engine jq
command -v python3 >/dev/null 2>&1 && run_engine python3
echo "auto-seed: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL**.
- [ ] **Step 3: Implement `qa-kit/scripts/auto-seed.sh`** — read `allowApiWrites` (bool) + `seedableEnvMarker`
  (string, default `QA_DISPOSABLE_ENV`) from `config.json`; check the named env var via
  `printenv "$marker"` / `os.environ.get`. Emit `{seed, reason}` compact-sorted. Exit 0. No exec.
- [ ] **Step 4: Run → `FAIL=0`**; `bash -n`.
- [ ] **Step 5: Commit** `feat(qa-kit): auto-seed.sh decide — pure write gate (allowApiWrites + disposable marker), no exec`

## Task 3: `/qa-spec` — capture seedCommand + the gated exec + fallback

**Files:** Modify `qa-kit/commands/qa-spec.md`.

- [ ] **Step 1** — extend the data-baseline step: after authoring `data-baseline.json`, optionally propose a
  seed command with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/detect-seed.sh" propose .qa/stack-profile.json .qa/config.json`
  (needs the engine's `detecting-stack-profile` to have run — reuse `/qa-e2e-pilot:detecting-stack-profile`).
  Show the proposal; the operator confirms or edits it into a `seedCommand` recorded in `qa-spec.md`'s Data
  baseline section (+ a machine `.qa/specs/<target>/seed.json = {command, cwd}`). A `null` proposal → no
  auto-seed available; declare-and-verify only.
- [ ] **Step 2** — document the run-time gated exec (this is guidance the run follows, not a change to the run
  engine): at pre-flight the run calls
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/auto-seed.sh" decide .qa/config.json`; iff `seed:true` AND a confirmed
  `seed.json` exists, it runs `command` in `cwd` (a `Bash` exec — the write), then the 6a read-back verify.
  Iff `seed:false` → the 6a declare-and-verify path (writes nothing), printing the `reason`. State plainly that
  the exec only ever runs on a disposable env with writes allowed + human confirmation.
- [ ] **Step 3: Docs + Gate + Commit** — `build-adapter.sh claude` + `validate-adapters.sh` exit 0;
  `tests/detect-seed/run.sh` + `tests/auto-seed/run.sh` green.
  `feat(qa-kit): /qa-spec proposes+confirms seedCommand + documents the gated auto-seed exec (disposable env only)`

## Task 4: extend the phase integration test

**Files:** Modify `tests/qa-kit-phases/run.sh`.

- [ ] **Step 1** — append (reuse its `check`/tmp pattern, add `DS`/`AS` path vars): `detect-seed propose` on a
  laravel profile → `php artisan db:seed`; on unknown → null mechanism; `auto-seed decide` with the marker set +
  `allowApiWrites:true` → `seed:true`, with the marker unset → `seed:false`, with `allowApiWrites:false` →
  `seed:false`. (The actual seed exec is NOT run here — honest boundary.)
- [ ] **Step 2: Run → green**.
- [ ] **Step 3: Commit** `test(qa-kit): phase integration — detect-seed proposals + auto-seed gate decisions`

## Task 5: docs — ADR-0023 6b note + §7 correction + README/CLAUDE/config + status

**Files:** Modify `docs/adr/0023-qa-kit-tdqa-data-layer.md`, the design spec §7, `qa-kit/README.md`, `CLAUDE.md`,
`.qa/config.json.example`, the roadmap.

- [ ] **Step 1: ADR-0023 + design §7** — record 6b landed; **correct §7**: stack-seed detection is a
  qa-kit-owned `detect-seed.sh` that READS `stack-profile.json`; `detecting-stack-profile` is NOT modified
  (engine-untouched preserved). State the doubly-gated + human-confirmed write path.
- [ ] **Step 2: README/CLAUDE** — qa-kit/README Data section: add the opt-in auto-seed (disposable env only,
  proposal→confirm→gated exec→6a verify). CLAUDE.md qa-kit-TDQA invariant: note 6b adds the gated write path,
  detection reads stack-profile.json, engine still untouched.
- [ ] **Step 3: config.json.example** — add an `_autoSeedDoc` note: auto-seed reuses the `allowApiWrites` +
  `seedableEnvMarker` write gate; `seedCommand` is per-spec (`.qa/specs/<t>/seed.json`), human-confirmed.
- [ ] **Step 4: Status** — roadmap + design status: 6b landed; qa-kit v1 data layer complete on Claude.
- [ ] **Step 5: Gate + Commit** — build/validate exit 0; all qa-kit suites green.
  `docs(qa-kit): ADR-0023 6b + §7 correction (detect-seed reads stack-profile) + README/CLAUDE/config + status`

## Self-Review

**1. Spec coverage:** opt-in auto-seed (design §4 step 1) → Tasks 2/3; stack-seed detection (§7, corrected to
qa-kit-owned) → Task 1; disposable-env gating → Task 2 + constraints; reuse 6a verify → Task 3 step 2; docs →
every task + Task 5. ✅ The §7 engine-untouched tension is explicitly resolved (Task 1 + Task 5 step 1).

**2. Placeholder scan:** full test code for Tasks 1/2/4; the exec path is deliberately a guarded command step
with an explicit honest "not headlessly testable" boundary (not a hidden TODO). Implementation steps give the
exact mapping table + gate rule + the sibling idiom to copy.

**3. Type consistency:** `detect-seed propose` → `{mechanism,command,cwd}`; `auto-seed decide` → `{seed,reason}`;
`seed.json` = `{command,cwd}`; gate reuses `allowApiWrites` + `seedableEnvMarker` (the engine's existing write
gate, verbatim). Compact-sorted JSON for cross-engine byte-identity (6a idiom).

## Execution Handoff

SDD in a **fresh session with the subagent budget available** (this session's was exhausted at 200/200).
**Depends on 6a** (`data-baseline.json` + declare-and-verify). Tasks 1–2 (pure scripts + tests) are the
low-risk core and the right place to start; Task 3 is the guarded exec-path command prose; 4 the integration
test; 5 the docs. The actual `db:seed` exec against a live disposable env is the manual smoke-test, not a
headless unit test — do not fake it.
