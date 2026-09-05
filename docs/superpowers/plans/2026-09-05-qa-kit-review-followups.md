# qa-kit review-follow-ups — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (or executing-plans).
> Steps use checkbox (`- [ ]`) syntax.
>
> Design: `docs/superpowers/specs/2026-09-05-qa-kit-review-followups-design.md` (grill-hardened).

**Goal:** Resolve the judgement-call review findings — de-duplicate the 3 qa-kit installers (S1/SP2), make
`field()` fail loud (S2), single-source the qa-kit CI list (SP1) — plus a qa-kit doc note (D5). **Engine
byte-for-byte untouched; qa-kit byte-oracle + all suites stay green; no new qa-kit behaviour.**

**Architecture:** Extract the whole install flow into `qa-kit/harnesses/_install-common.sh` (sourced by 3 thin
wrappers, parameterised by `HARNESS` + profile fields, env-overridable `QAKIT_PROFILE` for testing). Move the
qa-kit CI suite list into `qa-kit/scripts/run-qakit-ci.sh`; `adapters.yml` calls it.

**Tech Stack:** Bash + `python3` (repo idiom); GitHub Actions YAML.

## Global Constraints

- **Engine untouched.** No change to root `core/`/`commands/`/`skills/`/`scripts/`/`harness-profiles.json`/
  `build-adapter.sh`/`validate-adapters.sh`/`qa-verify`, **nor engine adapter files** (`harnesses/<h>/*` — the
  engine's; the "16 skills" README fix is explicitly NOT in this plan, per design D5). Verify with
  `git diff --name-only` after each task.
- **Claude byte-oracle stays green** — this plan touches only install wrappers + a CI runner + one qa-kit doc;
  never `qa-kit/core/` or generator output. Re-run `qa-kit/scripts/validate-qakit-adapters.sh` after each task.
- **No destructive git** (the repo rule): negative tests use temp copies + `QAKIT_PROFILE`, never edit-then-
  `git checkout` a tracked file.
- No attribution / `Co-Authored-By`; `python3`/`jq` only, no `grep -P`/`perl`/`node`.

## File Structure

```
qa-kit/harnesses/_install-common.sh          NEW  — the whole install flow, parameterised by HARNESS + profile
qa-kit/harnesses/pi/install-pi.sh            REWRITE → ~3-line wrapper
qa-kit/harnesses/codex/install-codex.sh      REWRITE → ~3-line wrapper
qa-kit/harnesses/opencode/install-opencode.sh REWRITE → ~3-line wrapper
qa-kit/scripts/run-qakit-ci.sh               NEW  — validate + the qa-kit suite list (single source)
.github/workflows/adapters.yml               MODIFY — qa-kit job calls run-qakit-ci.sh
tests/qakit-install/run.sh                   NEW  — install smoke (positive/abort/missing-field) for all 3
docs/harness-adapters.md                     MODIFY — qa-kit manual-accuracy note (D5)
docs/doc-sync-todo.md                        MODIFY — tick the resolved items
```

---

## Task 1: `_install-common.sh` + thin wrappers + fail-loud `field()` (D1/D2)

**Files:** Create `qa-kit/harnesses/_install-common.sh`; rewrite the 3 `install-<h>.sh`; create `tests/qakit-install/run.sh`.

**Interfaces:**
- Wrapper contract: `install-<h>.sh <project-dir>` sets `HARNESS=<h>` then sources `_install-common.sh`.
- `_install-common.sh` reads `HARNESS` (required) + `QAKIT_PROFILE` (optional, default committed profile), then
  runs guard → build → mkdir → copy. `field <name>` prints `harnesses.<HARNESS>.<name>` or exits non-zero with a
  stderr error.

- [ ] **Step 1: Write the failing test** `tests/qakit-install/run.sh` (dual — positive, abort, missing-field):

```bash
#!/usr/bin/env bash
# Install-wrapper tests: positive placement, co-install abort, and D2 fail-loud on a missing profile field.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$DIR/../.."
pass=0; fail=0
check(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi; }
skdir(){ case "$1" in pi) echo .pi/agents/skills;; codex) echo .agents/skills;; opencode) echo .opencode/skills;; esac; }
for h in pi codex opencode; do
  SK="$(skdir "$h")"; ext=md; [ "$h" = codex ] && ext=toml
  # positive: fake engine skills present -> files land
  T="$(mktemp -d)"; mkdir -p "$T/$SK/detecting-stack-profile"
  bash "$REPO/qa-kit/harnesses/$h/install-$h.sh" "$T" >/dev/null 2>&1
  agentdir="$(python3 -c "import json;print(json.load(open('$REPO/qa-kit/harness-profiles.qakit.json'))['harnesses']['$h']['agentDir'])")"
  cmddir="$(python3 -c "import json;print(json.load(open('$REPO/qa-kit/harness-profiles.qakit.json'))['harnesses']['$h']['cmdDir'])")"
  check "$h positive: agent placed" "$([ -f "$T/$agentdir/qa-kit.$ext" ] && echo y)" "y"
  check "$h positive: 5 commands"   "$(ls "$T/$cmddir" 2>/dev/null | wc -l | tr -d ' ')" "5"
  rm -rf "$T"
  # abort: no engine skills -> non-zero
  T2="$(mktemp -d)"; bash "$REPO/qa-kit/harnesses/$h/install-$h.sh" "$T2" >/dev/null 2>&1; check "$h abort guard" "$?" "1"; rm -rf "$T2"
  # D2 fail-loud: profile missing agentDir -> non-zero + stderr names the field (QAKIT_PROFILE override, temp copy)
  T3="$(mktemp -d)"; mkdir -p "$T3/$SK/detecting-stack-profile"
  P="$(mktemp)"; python3 -c "import json;d=json.load(open('$REPO/qa-kit/harness-profiles.qakit.json'));d['harnesses']['$h'].pop('agentDir',None);json.dump(d,open('$P','w'))"
  err="$(QAKIT_PROFILE="$P" bash "$REPO/qa-kit/harnesses/$h/install-$h.sh" "$T3" 2>&1 >/dev/null)"; rc=$?
  check "$h missing-field exits non-zero" "$rc" "1"
  check "$h missing-field names field" "$(printf '%s' "$err" | grep -c "agentDir")" "1"
  rm -rf "$T3" "$P"
done
echo "qakit-install: PASS=$pass FAIL=$fail"; [ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run → FAIL** (wrappers still hardcode; no `QAKIT_PROFILE`; missing-field not yet loud).
- [ ] **Step 3: Write `qa-kit/harnesses/_install-common.sh`:**

```bash
#!/usr/bin/env bash
# Shared qa-kit install flow. SOURCED by qa-kit/harnesses/<h>/install-<h>.sh, which sets HARNESS first.
# All install locations are READ from the profile (QAKIT_PROFILE overrides the committed default, for tests),
# so they cannot drift from the {{PLUGIN_ROOT}}/agent/command dirs the generator rendered.
set -euo pipefail
: "${HARNESS:?_install-common.sh: caller must set HARNESS}"
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # qa-kit/harnesses
QAKIT="$(cd "$COMMON_DIR/.." && pwd)"                            # qa-kit
ROOT="$(cd "$QAKIT/.." && pwd)"                                  # repo root
PROFILE="${QAKIT_PROFILE:-$QAKIT/harness-profiles.qakit.json}"
PROJ="${1:?usage: $0 <project-dir>}"                             # $0 = the wrapper (source keeps it)

field() {
  python3 -c "
import json,sys
try:
    print(json.load(open('$PROFILE'))['harnesses']['$HARNESS']['$1'])
except KeyError:
    sys.stderr.write('ERROR: missing harnesses.$HARNESS.$1 in $PROFILE\n'); sys.exit(1)"
}
AGENT_DIR="$(field agentDir)"       || exit 1
CMD_DIR="$(field cmdDir)"           || exit 1
PLUGIN_ROOT="$(field pluginRoot)"   || exit 1
SKILLS_DIR="$(field engineSkillsDir)" || exit 1
AGENT_EXT="$(field agentExt)"       || exit 1

[ -d "$PROJ/$SKILLS_DIR/detecting-stack-profile" ] || {
  echo "ERROR: engine $HARNESS adapter not installed in $PROJ ($SKILLS_DIR absent) — run harnesses/$HARNESS/install-$HARNESS.sh first" >&2
  echo "       (qa-kit reuses the engine's skills; it never vendors them)" >&2
  exit 1; }

bash "$QAKIT/scripts/build-qakit-adapter.sh" "$HARNESS"
mkdir -p "$PROJ/$AGENT_DIR" "$PROJ/$CMD_DIR" "$PROJ/$PLUGIN_ROOT/scripts" "$PROJ/$PLUGIN_ROOT/templates"
cp "$QAKIT/dist/$HARNESS/agent/qa-kit.$AGENT_EXT" "$PROJ/$AGENT_DIR/"
cp "$QAKIT/dist/$HARNESS/commands/"*.md "$PROJ/$CMD_DIR/"
cp -R "$QAKIT/dist/$HARNESS/scripts/." "$PROJ/$PLUGIN_ROOT/scripts/"
cp -R "$QAKIT/dist/$HARNESS/templates/." "$PROJ/$PLUGIN_ROOT/templates/" 2>/dev/null || true
V="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo unknown)"
echo "Installed qa-kit $HARNESS adapter ($V) into $PROJ."
echo "  agent -> $AGENT_DIR/qa-kit.$AGENT_EXT ; step commands -> $CMD_DIR/ ; qa-kit scripts -> $PLUGIN_ROOT/ ({{PLUGIN_ROOT}})."
[ "$HARNESS" = opencode ] && echo "  REQUIRES the 'opencode-skills' plugin enabled in opencode.json (else skills_<name> tools are inert)."
echo "  Skill refs resolve to the engine's $SKILLS_DIR/. Verify with a manual accuracy run (see README)."
```

- [ ] **Step 4: Rewrite each `qa-kit/harnesses/<h>/install-<h>.sh` to the wrapper** (pi shown; codex/opencode
  identical but `HARNESS=codex`/`HARNESS=opencode`):

```bash
#!/usr/bin/env bash
# qa-kit Pi adapter installer — thin wrapper; all logic + install dirs live in ../_install-common.sh.
HARNESS=pi
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_install-common.sh"
```

- [ ] **Step 5: Run → `FAIL=0`.** `bash tests/qakit-install/run.sh`. Also `bash -n` the common file + 3 wrappers.
- [ ] **Step 6: Byte-oracle + adapters test unaffected.** `bash qa-kit/scripts/validate-qakit-adapters.sh` (OK);
  `bash tests/qakit-adapters/run.sh` (FAIL=0).
- [ ] **Step 7: Commit** `refactor(qa-kit): extract _install-common.sh (thin per-harness wrappers) + fail-loud field()`

---

## Task 2: `run-qakit-ci.sh` single-source + `adapters.yml` rewire (D3/SP1)

**Files:** Create `qa-kit/scripts/run-qakit-ci.sh`; modify `.github/workflows/adapters.yml`.

- [ ] **Step 1: Write `qa-kit/scripts/run-qakit-ci.sh`** — the single home for the qa-kit gate (validate + the
  suite list) + a local convenience runner:

```bash
#!/usr/bin/env bash
# One command to gate qa-kit: the multi-harness byte-oracle + every qa-kit dual-engine suite.
# THIS list is the single source of truth — CI (.github/workflows/adapters.yml) calls this script, so adding
# a qa-kit suite here enrolls it in CI automatically. (A blanket tests/*/run.sh glob is deliberately NOT used:
# the full corpus includes slow/engine suites that hang without a live app — see docs/doc-sync-todo.md.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITES=(constitution spec-snapshot qa-kit-enforcement runconfig-merge data-baseline
        check-fixtures detect-seed auto-seed qa-kit-phases qakit-adapters qakit-install)
bash "$ROOT/qa-kit/scripts/validate-qakit-adapters.sh"
for d in "${SUITES[@]}"; do
  echo "== tests/$d =="
  bash "$ROOT/tests/$d/run.sh"
done
echo "run-qakit-ci: all green"
```

- [ ] **Step 2: Rewire the `qa-kit` job in `.github/workflows/adapters.yml`** — replace its two inline steps
  with a single call:

```yaml
  qa-kit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - name: qa-kit byte-oracle + all qa-kit suites
        run: bash qa-kit/scripts/run-qakit-ci.sh
```

- [ ] **Step 3: Run locally → all green.** `bash qa-kit/scripts/run-qakit-ci.sh`. `bash -n` it; confirm YAML parses.
- [ ] **Step 4: Commit** `ci(qa-kit): single-source the qa-kit gate in run-qakit-ci.sh; adapters.yml calls it`

---

## Task 3: qa-kit manual-accuracy doc note + todo tidy (D5)

**Files:** Modify `docs/harness-adapters.md`, `docs/doc-sync-todo.md`.

- [ ] **Step 1: Add a "qa-kit manual accuracy run" note** to the qa-kit section of `docs/harness-adapters.md`:
  after installing the engine + qa-kit adapters for a harness, drive one real spec through
  `/qa-constitution → /qa-spec → /qa-scenarios → /qa-analyze → /qa-run`, confirm each step's prompts resolve
  their engine skills (via the co-install contract) and its `{{PLUGIN_ROOT}}` scripts run, then score as the
  engine's accuracy procedure does. State plainly this is the load-bearing unverified path (no headless test).
- [ ] **Step 2: Tick the resolved items** in `docs/doc-sync-todo.md` (S1/S2/SP1 done; note the engine-README
  "16 skills" remains a separate engine-doc item; the broader-corpus CI stays deferred with its measured reason).
- [ ] **Step 3: Final gate + commit.**

```bash
bash qa-kit/scripts/run-qakit-ci.sh                      # all green (incl. qakit-install)
bash scripts/validate-adapters.sh                        # engine byte-oracle still OK
git diff --name-only <base>..HEAD | grep -E '^(core/|commands/|skills/|scripts/build-adapter|scripts/validate-adapters|harness-profiles\.json|qa-verify|harnesses/(pi|codex|opencode)/(README|manifest|install-(pi|codex|opencode))\.)' \
  && echo "!!! ENGINE/ENGINE-ADAPTER TOUCHED" || echo "engine + engine-adapters untouched OK"
git add docs/harness-adapters.md docs/doc-sync-todo.md && git commit -m "docs(qa-kit): manual-accuracy run note + doc-sync todo tidy"
```

---

## Self-Review

**1. Spec coverage:** D1 (`_install-common.sh` + wrappers) → Task 1; D2 (fail-loud `field()` + missing-field
test) → Task 1 (Step 3 `field()`, Step 1 test); D3/SP1 (single-source CI) → Task 2; D4 (deferred) → not a task,
recorded in Task 2's script comment + Task 3 todo; D5 (doc note, qa-kit-owned only) → Task 3. ✅

**2. Placeholder scan:** full `_install-common.sh`, full wrapper, full `field()`, full test, full `run-qakit-ci.sh`,
full YAML job. The grill's `source` semantics (`$0`, common's own `BASH_SOURCE`, caller-checks-nonzero,
`QAKIT_PROFILE`) are encoded in the actual code, not hand-waved.

**3. Type consistency:** `field <name>` used identically in common + test; profile fields
(`agentDir`/`cmdDir`/`pluginRoot`/`engineSkillsDir`/`agentExt`) match `harness-profiles.qakit.json`; the CI job
name (`qa-kit`) and script path (`qa-kit/scripts/run-qakit-ci.sh`) consistent across Task 2.

## Execution Handoff

SDD or inline. Task 1 is the substantive one (get its tests green — especially the missing-field negative via
`QAKIT_PROFILE`, no real-file edits). Tasks 2–3 are small. Engine + engine-adapters stay untouched throughout;
the live per-harness qa-kit run remains the manual accuracy run (D5 note), not closed here.
