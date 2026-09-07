# Audit-2 Wave 1 — Enforcement Correctness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the five confirmed enforcement-correctness defects from the 2026-09-06 multi-agent
audit (spec: `docs/superpowers/specs/2026-09-07-deep-audit-remediation-design.md`, items W1-1…W1-5)
so no gate fails open, no gate rejects sanctioned work, and the dual engines agree.

**Architecture:** Seven tasks on one branch (`fix/audit2-w1-enforcement`). Task 1 is a fail-closed
hotfix + spec/plan commit; Task 2 removes the hotfix by making the gating scripts bash-3.2-safe;
Tasks 3–6 are independent single-defect fixes (parallelizable across worktree subagents — they
touch disjoint files); Task 7 is the wave gate + version bump + PR.

**Tech Stack:** Bash (dual-engine: jq preferred, python3 fallback, byte-identical output), Node
(dependency-free, core modules only), the repo's `tests/<name>/run.sh` suite convention
(`check() { got vs want }`, `mktemp -d` + trap cleanup, `PASS/FAIL` counters, non-zero exit on any
FAIL).

## Global Constraints

- Verdicts exactly `pass|fail|blocked|deferred|error`; confidence `high|low`; suspected layer
  `FE|route|service|migration|DB`. Never weaken a gate — over-strict gates get a sanctioned path
  plus a negative test proving the unsanctioned case still rejects.
- Dual-engine idiom in every touched script: jq preferred, python3 fallback, byte-identical output
  (`jq -Sc` ⇔ `json.dumps(sort_keys=True, separators=(",",":"))`); no `grep -P`/perl in bash.
- **Bash-3.2 floor (new, this wave):** no `mapfile`/`readarray`/`declare -A` on any verdict-gating
  path after Task 2.
- All five tasks are engine-scoped except Task 6's `auto-seed.sh` sub-step (qa-kit-scoped, its own
  commit). No task edits generated-and-committed files (`agents/`, root `commands/`) — none of these
  fixes touch them.
- New/changed test suites must be enrolled in `scripts/run-engine-ci.sh`'s `SUITES` list;
  `bash scripts/check-suite-coverage.sh` must stay green (each suite counted exactly once).
- Validation before every commit: `bash -n` on touched .sh, `node --check` on touched .js,
  `python3 -c "import json;json.load(open(...))"` on touched .json.
- **No destructive git** (no reset --hard/checkout --/clean/stash drop/force-push) — ever, without
  the user's explicit per-action confirmation. Commit per task. Push only at Task 7.
- Commit messages: conventional (`fix(scope): …`), **no Claude/Anthropic attribution and no
  Co-Authored-By trailer** (user rule overrides the repo CLAUDE.md trailer line).

---

## File Structure

- Modify: `scripts/qa-verify.sh` (T1 gate, T2 rewrite),
  `skills/checkpointing-qa-memory/scripts/required-kinds.sh` (T1, T2),
  `skills/checkpointing-qa-memory/scripts/mutation-flag.sh` (T1, T2),
  `skills/checkpointing-qa-memory/scripts/check-action-trace.js` (T3),
  `scripts/provenance.sh` (T4),
  `skills/checkpointing-qa-memory/scripts/journal-merge.sh` (T5),
  `skills/bootstrapping-qa-config/scripts/init-config.sh` (T6),
  `skills/detecting-stack-profile/scripts/detect-stack.sh` (T6),
  `skills/driving-browser-qa/scripts/preflight.sh` (T6),
  `.qa/config.json.example` (T6), `qa-kit/scripts/auto-seed.sh` (T6),
  `README.md` + `INSTALL.md` (T1 note, T2 revert),
  `scripts/run-engine-ci.sh` (T2 enrolment),
  `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` + `scripts/skills.json` (T7 bump)
- Create: `tests/bash32-safety/run.sh` (T2)
- Test (modify): `tests/action-trace/run.sh` (T3), `tests/provenance/run.sh` (T4),
  `tests/journal-merge/run.sh` (T5), `tests/init-config/run.sh`, `tests/detect-stack/run.sh`,
  `tests/auto-seed/run.sh` (T6)

---

### Task 1: Branch, commit spec+plan, fail-closed bash-version hotfix (W1-1 step 1)

**Files:**
- Modify: `scripts/qa-verify.sh`, `skills/checkpointing-qa-memory/scripts/required-kinds.sh`,
  `skills/checkpointing-qa-memory/scripts/mutation-flag.sh`, `README.md`, `INSTALL.md`
- Commit (already written): `docs/superpowers/specs/2026-09-07-deep-audit-remediation-design.md`,
  `docs/superpowers/plans/2026-09-07-audit2-wave1-enforcement.md`

**Interfaces:**
- Produces: exit code 90 = "bash too old, refused fail-closed" (Task 2 removes this).

- [ ] **Step 1: Create the branch and commit the spec + this plan**

```bash
cd /home/dev/repos/qa-e2e-pilot
git checkout -b fix/audit2-w1-enforcement
git add docs/superpowers/specs/2026-09-07-deep-audit-remediation-design.md \
        docs/superpowers/plans/2026-09-07-audit2-wave1-enforcement.md
git commit -m "docs(spec,plan): audit-2 deep-audit remediation design + wave-1 plan"
```

- [ ] **Step 2: Add the version gate to all three gating scripts**

Insert immediately after the `set -uo pipefail` line of each of `scripts/qa-verify.sh`,
`skills/checkpointing-qa-memory/scripts/required-kinds.sh`,
`skills/checkpointing-qa-memory/scripts/mutation-flag.sh` (adjust the script name in the message):

```bash
# TEMPORARY fail-closed gate (audit-2 W1-1 step 1; removed by the 3.2-safe
# rewrite in the same wave): on bash <4 this script's mapfile calls silently
# yield empty fields and the gate verifies nothing while exiting 0 (fail
# open). Refuse instead.
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "FATAL: qa-verify.sh requires bash >= 4 (found ${BASH_VERSION:-unknown}) — refusing to run rather than fail open. On macOS: brew install bash." >&2
  exit 90
fi
```

- [ ] **Step 3: Note the temporary requirement in README.md and INSTALL.md**

In each file's platform/prerequisites section, next to the existing macOS wording, add:

```markdown
> **macOS note (temporary):** the verification gates currently require bash ≥ 4
> (`brew install bash`); stock /bin/bash 3.2 is refused fail-closed. Being removed
> by the in-progress bash-3.2-safe rewrite.
```

- [ ] **Step 4: Validate and confirm existing suites still pass (bash 5 here — gate must not trip)**

```bash
for f in scripts/qa-verify.sh skills/checkpointing-qa-memory/scripts/required-kinds.sh skills/checkpointing-qa-memory/scripts/mutation-flag.sh; do bash -n "$f"; done
bash tests/qa-verify/run.sh && bash tests/required-kinds/run.sh && bash tests/mutation-flag/run.sh
```
Expected: all `ok`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/qa-verify.sh skills/checkpointing-qa-memory/scripts/required-kinds.sh \
        skills/checkpointing-qa-memory/scripts/mutation-flag.sh README.md INSTALL.md
git commit -m "fix(gates): fail closed on bash <4 (mapfile fail-open hotfix, audit-2 W1-1)"
```

---

### Task 2: bash-3.2-safe rewrite + `tests/bash32-safety` suite; remove the hotfix (W1-1 step 2)

**Files:**
- Modify: the three gating scripts (remove gate, replace bash-4isms), `README.md`, `INSTALL.md`
  (revert Task 1 note), `scripts/run-engine-ci.sh` (enrol suite)
- Create: `tests/bash32-safety/run.sh`

**Interfaces:**
- Produces: the grep-enforced invariant "no `mapfile|readarray|declare -A` in gating scripts",
  consumed by CI from this task on.

- [ ] **Step 1: Write the failing test suite**

Create `tests/bash32-safety/run.sh` (mode 755):

```bash
#!/usr/bin/env bash
# Audit-2 W1-1: the verdict-gating scripts must be bash-3.2-safe — macOS stock
# /bin/bash has no mapfile/readarray/declare -A, and under 3.2 those paths
# silently verified nothing (fail open). This suite is the structural gate:
# no bash-4-only builtin may appear on a gating path. (True 3.2 execution is
# not testable on this CI's bash 5; the grep gate + unchanged behavior on the
# functional suites is the enforced proxy.)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }

GATING="scripts/qa-verify.sh
skills/checkpointing-qa-memory/scripts/required-kinds.sh
skills/checkpointing-qa-memory/scripts/mutation-flag.sh"

while IFS= read -r f; do
  n="$(grep -cE '^[^#]*\b(mapfile|readarray|declare -A)\b' "$HERE/../../$f" || true)"
  check "no bash-4 builtins in $f" "$n" "0"
  g="$(grep -cE 'BASH_VERSINFO' "$HERE/../../$f" || true)"
  check "temporary version gate removed from $f" "$g" "0"
done <<< "$GATING"

echo "---"; echo "bash32-safety: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
```

- [ ] **Step 2: Run it to verify it fails** (gates + mapfile still present)

```bash
bash tests/bash32-safety/run.sh
```
Expected: FAIL lines for all three scripts, exit 1.

- [ ] **Step 3: Replace the mapfile sites with a 3.2-safe line-splitter**

`scripts/qa-verify.sh:1308` — replace `mapfile -t _qv_fields <<< "$fields_out"` with:

```bash
    _qv_fields=()
    while IFS= read -r _qv_line; do _qv_fields+=("$_qv_line"); done <<< "$fields_out"
```

`required-kinds.sh:144` — replace `mapfile -t _rk_lines <<< "$out"` with:

```bash
  _rk_lines=()
  while IFS= read -r _rk_line; do _rk_lines+=("$_rk_line"); done <<< "$out"
```

`required-kinds.sh:174` — replace `mapfile -t sorted < <(printf '%s\n' "${kinds[@]}" | sort -u)`
with:

```bash
    while IFS= read -r _rk_s; do sorted+=("$_rk_s"); done < <(printf '%s\n' "${kinds[@]}" | sort -u)
```

`mutation-flag.sh:134` — replace `mapfile -t _mf_lines <<< "$out"` with:

```bash
  _mf_lines=()
  while IFS= read -r _mf_line; do _mf_lines+=("$_mf_line"); done <<< "$out"
```

- [ ] **Step 4: Guard empty-array expansions against bash-3.2 `set -u`**

Bash < 4.4 errors on `"${arr[@]}"` when the array is empty under `set -u`. Sweep the three scripts:

```bash
grep -n '\[@\]\|\[\*\]' scripts/qa-verify.sh skills/checkpointing-qa-memory/scripts/required-kinds.sh skills/checkpointing-qa-memory/scripts/mutation-flag.sh
```

For every expansion where the array can be empty at that point (known sites: `qa-verify.sh:528`
`"${rec_arr[@]}"`, `:534` `"${req_arr[@]}"`, `:1052` `"${kinds_arr[@]}"`; `required-kinds.sh`'s
final `(IFS=,; echo "${sorted[*]}")`), apply the guard idiom — for-loops:

```bash
for r in ${rec_arr[@]+"${rec_arr[@]}"}; do
```

and the `[*]` join:

```bash
  (IFS=,; echo "${sorted[*]-}")
```

Expansions provably non-empty at their site (guarded by a `[[ ${#a[@]} -gt 0 ]]` check) may stay.

- [ ] **Step 5: Remove the Task 1 version gates and the README/INSTALL temporary note**

Delete the `TEMPORARY fail-closed gate` block from all three scripts; revert the
`**macOS note (temporary)**` blocks in README.md and INSTALL.md (restore the prior wording exactly).

- [ ] **Step 6: Enrol the suite in CI**

In `scripts/run-engine-ci.sh`, add `bash32-safety` to the `SUITES` list (alphabetical position,
lines 14–16).

- [ ] **Step 7: Run the new suite and every functional suite for the touched scripts**

```bash
bash tests/bash32-safety/run.sh
bash tests/qa-verify/run.sh && bash tests/required-kinds/run.sh && bash tests/mutation-flag/run.sh \
  && bash tests/checkpoint/run.sh && bash tests/qa-verify-phase/run.sh
bash scripts/check-suite-coverage.sh
```
Expected: all PASS (behavior identical under bash 5; the rewrite is mechanical).

- [ ] **Step 8: Commit**

```bash
git add scripts/qa-verify.sh skills/checkpointing-qa-memory/scripts/required-kinds.sh \
        skills/checkpointing-qa-memory/scripts/mutation-flag.sh tests/bash32-safety/run.sh \
        scripts/run-engine-ci.sh README.md INSTALL.md
git commit -m "fix(gates): bash-3.2-safe gating paths + bash32-safety suite; drop temporary version gate"
```

---

### Task 3: Sanction `browser_handle_dialog`/`browser_drop` in the act-lint (W1-2)

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/check-action-trace.js:31`
- Test: `tests/action-trace/run.sh`

**Interfaces:**
- Consumes: `provenance.sh`'s `human_interaction_tools` list (line ~266) as the reference set.
- Produces: `HUMAN_PATH_TOOLS` == provenance's 10-tool set, enforced by a consistency test.

- [ ] **Step 1: Write the failing tests**

Append to `tests/action-trace/run.sh` before the final summary block (mirror the invocation form
the file's neighboring `check-action-trace` cases use — same exit-code/message accessor):

```bash
# --- audit-2 W1-2: dialog/drop are sanctioned human-path act tools ----------
cat > "$WORK/at-dialog.json" <<'JSON'
{"actionUnderTest":"delete founder (confirm dialog)","steps":[{"tool":"browser_click","target":"#delete","phase":"act"},{"tool":"browser_handle_dialog","target":"accept","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#delete').click();"}],"fingerprints":{"before":0,"after":1}}
JSON
cat > "$WORK/at-drop.json" <<'JSON'
{"actionUnderTest":"reorder via drag-drop","steps":[{"tool":"browser_drag","target":"#row1","phase":"act"},{"tool":"browser_drop","target":"#slot2","phase":"act"}],"sessionCalls":[{"class":"human-path","mutating":true,"code":"await page.locator('#row1').dragTo(page.locator('#slot2'));"}],"fingerprints":{"before":"a","after":"b"}}
JSON
node "$CHECK" "$WORK/at-dialog.json" 2>/dev/null; check "check: dialog act accepted (not a workaround)" "$?" "0"
node "$CHECK" "$WORK/at-drop.json"   2>/dev/null; check "check: drop act accepted (not a workaround)"   "$?" "0"

# Cross-authority consistency: act-lint and provenance must sanction the SAME set.
CAT_TOOLS="$(grep -m1 'HUMAN_PATH_TOOLS' "$CHECK" | grep -o 'browser_[a-z_]*' | sort | tr '\n' ',')"
PROV_TOOLS="$(grep -m1 'def human_interaction_tools' "$HERE/../../scripts/provenance.sh" | grep -o 'browser_[a-z_]*' | sort | tr '\n' ',')"
check "act-lint tool set == provenance human_interaction_tools" "$CAT_TOOLS" "$PROV_TOOLS"

# Negative control (gate NOT weakened): an unknown tool on the act path still rejects.
cat > "$WORK/at-unknown.json" <<'JSON'
{"actionUnderTest":"add via unknown tool","steps":[{"tool":"browser_run_code_unsafe","target":"x","phase":"act"}],"sessionCalls":[],"fingerprints":{"before":0,"after":1}}
JSON
node "$CHECK" "$WORK/at-unknown.json" 2>/dev/null; check "check: unknown act tool still rejected" "$?" "1"
```

- [ ] **Step 2: Run to verify the new cases fail**

```bash
bash tests/action-trace/run.sh
```
Expected: the dialog/drop cases and the consistency case FAIL; everything pre-existing still `ok`.

- [ ] **Step 3: Fix the set**

`check-action-trace.js:31`:

```js
const HUMAN_PATH_TOOLS = new Set(['browser_click','browser_type','browser_fill_form','browser_press_key','browser_select_option','browser_hover','browser_drag','browser_drop','browser_file_upload','browser_handle_dialog']);
```

- [ ] **Step 4: Run to verify all pass**

```bash
node --check skills/checkpointing-qa-memory/scripts/check-action-trace.js
bash tests/action-trace/run.sh && bash tests/checkpoint/run.sh && bash tests/qa-verify/run.sh
```
Expected: PASS (checkpoint + qa-verify re-run because both invoke the act-lint).

- [ ] **Step 5: Commit**

```bash
git add skills/checkpointing-qa-memory/scripts/check-action-trace.js tests/action-trace/run.sh
git commit -m "fix(act-lint): sanction browser_handle_dialog/browser_drop; enforce parity with provenance tool set"
```

---

### Task 4: Torn-toolstream tolerance in provenance's jq leg (W1-3)

**Files:**
- Modify: `scripts/provenance.sh` (cmd_check, lines ~509–531)
- Test: `tests/provenance/run.sh`

**Interfaces:**
- Produces: both engine legs skip unparseable toolstream lines identically and WARN with the
  skipped count on stderr; JSON stdout unchanged in shape.

- [ ] **Step 1: Write the failing test**

Append to `tests/provenance/run.sh` (after the existing r1 fixtures; reuse `$BAKE_BOUND`; read the
binding with the same accessor the suite's existing bound/unbound assertions use):

```bash
# --- audit-2 W1-3: one torn line must not blank the whole toolstream --------
# The suite's existing `run_check <engine> <run> <artifact>` helper returns the
# binding string and its engine loop is `for ENGINE in "" python3` ("" = jq
# default) — reuse both, plus a full-JSON byte-parity capture:
printf '%s' '{"tool":"Bash","args"' >> "$WORK/.qa/runs/r1/toolstream.jsonl"   # torn, no newline term
for ENGINE in "" python3; do
  LABEL="${ENGINE:-jq(default)}"
  check "[$LABEL] torn line: genuine bake still binds" \
    "$(run_check "$ENGINE" "r1" "$BAKE_BOUND")" "bound"
done
TORN_J="$( cd "$WORK" && QA_ENGINE=""      bash "$PROV" check r1 "$BAKE_BOUND" 2>"$WORK/torn-j.err" )"
TORN_P="$( cd "$WORK" && QA_ENGINE=python3 bash "$PROV" check r1 "$BAKE_BOUND" 2>"$WORK/torn-p.err" )"
check "torn line: engines byte-identical" "$TORN_J" "$TORN_P"
check "torn line: jq leg warns with skipped count" \
  "$(grep -c 'skipped 1 unparseable' "$WORK/torn-j.err" || true)" "1"
check "torn line: python leg warns with skipped count" \
  "$(grep -c 'skipped 1 unparseable' "$WORK/torn-p.err" || true)" "1"
```

- [ ] **Step 2: Run to verify it fails**

```bash
bash tests/provenance/run.sh
```
Expected: "jq leg still binds" FAILs (jq leg returns unbound today); python cases may fail only on
the missing WARN.

- [ ] **Step 3: Fix cmd_check**

Replace the jq slurp (line ~514):

```bash
    events_json="$(printf '%s\n' "$raw_events" | jq -Rn -c '[inputs | fromjson?]' 2>/dev/null)"
    [[ -z "$events_json" ]] && events_json="[]"
```

Then, in BOTH branches after `events_json` is computed and before `check_jq`/`check_py`, add the
shared skipped-line WARN (jq branch uses jq, python branch uses python3 for the length):

```bash
  local raw_count parsed_count
  raw_count="$(printf '%s\n' "$raw_events" | grep -c . || true)"
```

jq branch:

```bash
    parsed_count="$(jq -r 'length' <<< "$events_json")"
    if (( raw_count > parsed_count )); then
      echo "WARN: provenance.sh skipped $((raw_count - parsed_count)) unparseable toolstream line(s) (torn write?) for run '${run_id}'." >&2
    fi
```

python branch (same block, with):

```bash
    parsed_count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<< "$events_json")"
```

- [ ] **Step 4: Run to verify all pass (both engines)**

```bash
bash -n scripts/provenance.sh
bash tests/provenance/run.sh
```
Expected: all `ok` including every pre-existing dual-engine case.

- [ ] **Step 5: Commit**

```bash
git add scripts/provenance.sh tests/provenance/run.sh
git commit -m "fix(provenance): jq leg tolerates torn toolstream lines (dual-engine parity + WARN)"
```

---

### Task 5: journal-merge mkdir-lock — trap only after acquisition (W1-4)

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/journal-merge.sh` (lines ~386–402)
- Test: `tests/journal-merge/run.sh`

**Interfaces:**
- Produces: env seam `JM_LOCK_TIMEOUT_ITERS` (default 150 ≈ 30s) so the timeout is testable.

- [ ] **Step 1: Write the failing test**

Append to `tests/journal-merge/run.sh` (mask `flock` from PATH via the suite's restricted-PATH /
fakebin idiom — same technique as tests/checkpoint's jq-masking; symlink every needed binary EXCEPT
flock into a fakebin dir):

```bash
# --- audit-2 W1-4: a timed-out waiter must NOT delete the holder's lock -----
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
for b in bash sh mkdir rm rmdir sleep dirname basename cat mv cp date grep sed sort mktemp jq python3 node printf; do
  p="$(command -v "$b" 2>/dev/null)" && ln -s "$p" "$FAKEBIN/$b" 2>/dev/null
done
LRUN="$WORK/.qa/runs/rlock"; mkdir -p "$LRUN"
LOCK_DIR="$LRUN/.journal.lock.d"      # journal-merge.sh:374 — mkdir_lock="${run_dir}/.journal.lock.d"
mkdir -p "$LOCK_DIR"                  # simulate a live holder
OUT="$(cd "$WORK" && PATH="$FAKEBIN" JM_LOCK_TIMEOUT_ITERS=3 bash "$MERGE" rlock 2>&1; echo "rc=$?")"
check "waiter times out (die, not hang)" "$(grep -c 'timed out waiting' <<< "$OUT")" "1"
check "holder's lock dir survives the waiter's death" "$([[ -d "$LOCK_DIR" ]] && echo alive || echo gone)" "alive"
rmdir "$LOCK_DIR"
```

(CLI verified: `journal-merge.sh <run-id>` — line 369; the lock name above is the script's real
`mkdir_lock` at line 374. `$MERGE` = the suite's existing variable for the script path — reuse it.)

- [ ] **Step 2: Run to verify it fails**

```bash
bash tests/journal-merge/run.sh
```
Expected: "lock dir survives" FAILs (today the waiter's EXIT trap removes it); the timeout case
also currently takes 30s — the seam doesn't exist yet.

- [ ] **Step 3: Fix the lock sequence**

Replace the fallback block (lines ~386–402) so acquisition precedes the trap, and add the seam:

```bash
    echo "NOTE: 'flock' not found on PATH — falling back to a mkdir-based lock (${mkdir_lock})." >&2
    local waited=0 max_iters="${JM_LOCK_TIMEOUT_ITERS:-150}"
    until mkdir "$mkdir_lock" 2>/dev/null; do
      sleep 0.2
      waited=$((waited + 1))
      if (( waited > max_iters )); then
        # No trap installed yet: dying here must NOT touch the holder's lock.
        die "journal-merge.sh: timed out waiting for mkdir-lock ${mkdir_lock}."
      fi
    done
    # ONLY the acquirer cleans up — the trap is installed strictly AFTER
    # acquisition so a timed-out/killed waiter can never rm the holder's
    # live lock (audit-2 W1-4). rm -rf, not rmdir: see original rationale.
    trap 'rm -rf "'"$mkdir_lock"'" 2>/dev/null || true' EXIT
```

- [ ] **Step 4: Run to verify all pass**

```bash
bash -n skills/checkpointing-qa-memory/scripts/journal-merge.sh
bash tests/journal-merge/run.sh && bash tests/journal/run.sh && bash tests/fold/run.sh
```
Expected: PASS; the new timeout case completes in ~1s via the seam.

- [ ] **Step 5: Commit**

```bash
git add skills/checkpointing-qa-memory/scripts/journal-merge.sh tests/journal-merge/run.sh
git commit -m "fix(journal-merge): install mkdir-lock cleanup trap only after acquisition; add JM_LOCK_TIMEOUT_ITERS seam"
```

---

### Task 6: seedableEnvMarker — empty default + sentinel migration (W1-5)

**Files:**
- Modify: `skills/bootstrapping-qa-config/scripts/init-config.sh:21`,
  `.qa/config.json.example:28`, `skills/detecting-stack-profile/scripts/detect-stack.sh:307`,
  `skills/driving-browser-qa/scripts/preflight.sh:206`, `qa-kit/scripts/auto-seed.sh`
- Test: `tests/init-config/run.sh`, `tests/detect-stack/run.sh`, `tests/auto-seed/run.sh`

**Interfaces:**
- Produces: the semantic "empty marker = NOT disposable; the literal `QA_DISPOSABLE_ENV` sentinel =
  never-deliberately-opted-in (treated as empty + loud WARN)". The existing `--seedable-marker`
  flag becomes the only way to get a non-empty marker from bootstrap.

- [ ] **Step 1: Write the failing tests**

`tests/init-config/run.sh` — append (mirror the suite's existing invocation of `$INIT`):

```bash
# --- audit-2 W1-5: marker defaults EMPTY; only explicit opt-in writes one ---
# ($GEN is the suite's existing variable for init-config.sh)
bash "$GEN" --base-url http://localhost:3000 --out "$WORK/c-default.json" >/dev/null
check "default seedableEnvMarker is empty" "$(jq -r '.seedableEnvMarker' "$WORK/c-default.json")" ""
bash "$GEN" --base-url http://localhost:3000 --environment production --out "$WORK/c-prod.json" >/dev/null
check "production bootstrap: marker stays empty" "$(jq -r '.seedableEnvMarker' "$WORK/c-prod.json")" ""
bash "$GEN" --base-url http://localhost:3000 --seedable-marker MY_DISPOSABLE --out "$WORK/c-opt.json" >/dev/null
check "explicit --seedable-marker is honored" "$(jq -r '.seedableEnvMarker' "$WORK/c-opt.json")" "MY_DISPOSABLE"
```

`tests/detect-stack/run.sh` — append (mirror the suite's config-fixture pattern for env inference):

```bash
# --- audit-2 W1-5: the verbatim bootstrap sentinel never marks disposable ---
# remote baseUrl + environment auto + marker == the old default sentinel -> production
```
then a case building a `.qa/config.json` with
`{"baseUrl":"https://app.example.com","environment":"auto","seedableEnvMarker":"QA_DISPOSABLE_ENV"}`
and asserting the emitted stack-profile's environment field is `production`, plus a sibling case
with `"seedableEnvMarker":"MY_DISPOSABLE"` asserting `disposable` (custom markers still work).

`tests/auto-seed/run.sh` — append a `decide` case: config with `allowApiWrites:true`,
`environment` non-production, `seedableEnvMarker:"QA_DISPOSABLE_ENV"` → expect `seed:false`
(sentinel is not an opt-in), and the same with `"MY_DISPOSABLE"` → existing `seed:true` behavior.

- [ ] **Step 2: Run all three to verify the new cases fail**

```bash
bash tests/init-config/run.sh; bash tests/detect-stack/run.sh; bash tests/auto-seed/run.sh
```
Expected: new cases FAIL, pre-existing `ok`.

- [ ] **Step 3: Implement**

`init-config.sh:21`: `SEEDABLE_MARKER=""` (keep the `--seedable-marker` flag as the only opt-in).

`.qa/config.json.example:28`: `"seedableEnvMarker": "",` and add beside it:

```json
  "_seedableDoc": "Disposable-environment opt-in. EMPTY (the default) = not disposable: under environment 'auto' a non-localhost baseUrl is treated as production and writes stay off. Set any custom non-empty string (echoed by your env, e.g. MY_DISPOSABLE) as a deliberate opt-in. The historical bootstrap default 'QA_DISPOSABLE_ENV' is recognized as never-deliberately-set and treated as empty, with a warning.",
```

`detect-stack.sh:307` — replace the marker check:

```bash
      *) { _m="$(cfg '.seedableEnvMarker' '')"; [[ -z "$_m" || "$_m" == "QA_DISPOSABLE_ENV" ]] && env="production"; } ;;
```

`preflight.sh` — after `SEED_MARKER=$(jq_get '.seedableEnvMarker' '')` (line ~206):

```bash
if [[ "$SEED_MARKER" == "QA_DISPOSABLE_ENV" ]]; then
  warn "seedableEnvMarker is the historical bootstrap default sentinel 'QA_DISPOSABLE_ENV' — treated as NOT disposable (it was never a deliberate opt-in). Set a custom marker string to mark this environment disposable."
  SEED_MARKER=""
fi
```

`qa-kit/scripts/auto-seed.sh` — in `decide`'s marker leg (both engines, keeping byte parity), treat
the literal `QA_DISPOSABLE_ENV` exactly like empty (gate result `seed:false`, with the blocking
reason naming the sentinel). **Separate commit — this file is qa-kit-scoped.**

- [ ] **Step 4: Run to verify all pass**

```bash
for f in skills/bootstrapping-qa-config/scripts/init-config.sh skills/detecting-stack-profile/scripts/detect-stack.sh skills/driving-browser-qa/scripts/preflight.sh qa-kit/scripts/auto-seed.sh; do bash -n "$f"; done
python3 -c "import json;json.load(open('.qa/config.json.example'))"
bash tests/init-config/run.sh && bash tests/detect-stack/run.sh && bash tests/auto-seed/run.sh
```
Expected: all PASS.

- [ ] **Step 5: Commit (two commits — engine, then qa-kit)**

```bash
git add skills/bootstrapping-qa-config/scripts/init-config.sh .qa/config.json.example \
        skills/detecting-stack-profile/scripts/detect-stack.sh skills/driving-browser-qa/scripts/preflight.sh \
        tests/init-config/run.sh tests/detect-stack/run.sh
git commit -m "fix(write-gate): seedableEnvMarker defaults empty; verbatim bootstrap sentinel treated as not-opted-in (audit-2 W1-5)"
git add qa-kit/scripts/auto-seed.sh tests/auto-seed/run.sh
git commit -m "fix(qa-kit/auto-seed): decide treats the bootstrap sentinel marker as not-opted-in (mirrors engine gate)"
```

---

### Task 7: Wave gate, version bump, PR

**Files:**
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `scripts/skills.json`
  (version → `0.6.3` in all three; structural single-sourcing is W3 scope per the spec)

- [ ] **Step 1: Full wave gate**

```bash
bash scripts/run-engine-ci.sh
bash qa-kit/scripts/run-qakit-ci.sh
bash scripts/validate-adapters.sh
bash qa-kit/scripts/validate-qakit-adapters.sh
bash scripts/check-suite-coverage.sh
for f in $(find . -name '*.json' -not -path './.git/*' -not -path './dist/*' -not -path './qa-kit/dist/*'); do python3 -c "import json;json.load(open('$f'))" || echo "BAD $f"; done
```
Expected: every command exits 0; no `BAD` lines.

- [ ] **Step 2: Bump versions and commit**

Verified current state: engine `plugin.json` 0.6.2, `marketplace.json` carries 0.6.2 twice (top
level + engine entry) and 0.1.0 for qa-kit, qa-kit `plugin.json` 0.1.0, `skills.json` 0.5.0
(stale — the audit's drift finding). Bump: engine → **0.6.3** everywhere it appears (including the
stale skills.json, hand-synced this once; the structural single-sourcing is W3 scope), qa-kit →
**0.1.1** (its `auto-seed.sh` changed in this wave) in both qa-kit `plugin.json` and its
marketplace entry.

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json scripts/skills.json qa-kit/.claude-plugin/plugin.json
git commit -m "chore(release): engine 0.6.3, qa-kit 0.1.1 — audit-2 wave 1 (enforcement correctness)"
```

- [ ] **Step 3: Push + PR + merge (the user's default finish flow)**

```bash
git push -u origin fix/audit2-w1-enforcement
gh pr create --title "Audit-2 Wave 1: enforcement correctness (W1-1..W1-5)" \
  --body "Fixes the five confirmed enforcement defects from the 2026-09-06 multi-agent audit per docs/superpowers/specs/2026-09-07-deep-audit-remediation-design.md: bash-3.2 fail-open (gate + rewrite), act-lint dialog/drop sanction, provenance torn-line dual-engine parity, journal-merge lock trap ordering, seedableEnvMarker empty default + sentinel migration. All engine+qa-kit suites, both byte-oracles, and the coverage meta-gate are green."
gh pr merge --merge --delete-branch
```

---

## Self-review notes (spec coverage)

- W1-1 → Tasks 1–2 (both decision steps: fail-closed hotfix, then 3.2-safe rewrite; README/INSTALL
  round-trip). W1-2 → Task 3 (incl. cross-authority parity test + negative control). W1-3 → Task 4
  (line-tolerant jq leg, WARN in both engines, byte-parity assertion). W1-4 → Task 5 (trap after
  acquisition + testable timeout seam). W1-5 → Task 6 (default, example, detect-stack, preflight,
  auto-seed sentinel migration — grill Q2 decision included). Versioning per grill Q9 → Task 7.
- Deliberate deviations from bite-size purity: Task 2's Step 4 sweep names the known sites but
  instructs a grep-verified sweep (the guard idiom is given verbatim); Task 5/6 test steps tell the
  implementer to mirror the suite's existing invocation shape where the CLI signature lives in the
  suite file itself — the assertions (the contract) are spelled out in full.
- Parallel dispatch: Tasks 3, 4, 5, 6 are file-disjoint and may run as concurrent worktree
  subagents after Task 2 merges into the branch; Tasks 1→2 are strictly sequential; Task 7 last.
