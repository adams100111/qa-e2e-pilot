# Durable Run Substrate (Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a QA Run's position **durable and computed** — an append-only `journal.ndjson` becomes the single source of truth, a deterministic `fold(journal)` regenerates today's `checkpoint.json` (and a `run-manifest`/`bug-log` projection) canonically, `checkpoint.sh`'s existing 3-arg CLI is preserved byte-for-byte while its internals become append-event + fold, the fold exposes a `(scenario, criterion)` cursor (with the `__shared__` synthetic scenario for shared criteria), a **derived** (never agent-declared) mutation flag, and fan-out writes per-child sub-journals merged under a lock.

**Scope note — this is Plan A (the substrate) of a two-plan split.** It ships D-1, D-2, D-3, D-4, D-8 from the spec's ticket cut and depends on nothing unbuilt. **Plan B** (idempotency reconciliation via a *new* write-set re-bake primitive, `/qa-resume` + `.qa/runs/latest` + `plan_frozen`/`plan_amended` resume, per-harness resume tests — D-5/D-6/D-7) is a follow-up. This plan therefore **defines** the `act_intent`/`act_committed`/`plan_frozen` event *types* (so the journal schema is complete and forward-compatible) and journals+folds them into cursor state, but the **reconciliation/resume behaviour** that consumes them is Plan B. Where this plan surfaces an open act, it exposes it in the fold (`openActs[]`) without acting on it.

**Architecture:** Additive new scripts under `skills/checkpointing-qa-memory/scripts/` (`journal.sh` = append + atomic/canonical write helpers; `fold.jq` + `fold.py` = the two fold engines; `fold.sh` = the jq-OR-python3 dispatcher; `mutation-flag.sh` = the derived-mutation rules; `journal-merge.sh` = fan-out sub-journal merge under `flock`). `checkpoint.sh` is refactored so its upsert path appends a `criterion_verdict` event then folds — the 3-arg CLI, all options, and the emitted `checkpoint.json` shape stay byte-identical (pinned by the existing characterization suite `tests/checkpoint/run.sh`, which must stay green). All new scripts follow the repo's `has_jq`/`has_py` dual-implementation precedent and error clearly when neither is present. Because `build-adapter.sh` copies `skills/` verbatim into `dist/<harness>/`, every source edit is followed by a `dist/` regeneration + `validate-adapters.sh` static sweep (there is **no** byte-oracle for `skills/` files — only `agent/` + `commands/` are oracled — so no `.md` rendering is involved, but the static `bash -n`/`node --check`/JSON-parse sweep must stay green).

**Tech Stack:** Bash (`set -uo pipefail`), `jq` (preferred) with a `python3` fallback for every state read/write (CLAUDE.md contract), `flock` (util-linux; degrade documented for absence), POSIX `find`/`mktemp`. Tests are bash runners at `tests/<name>/run.sh` using the repo-standard `check`/`get` helpers + `mktemp -d` isolation + a `fakebin` PATH shim to force the python3 path.

## Global Constraints

- **`jq` OR `python3`, error if neither.** Every new state script prefers `jq`, falls back to `python3`, and dies clearly if both are absent — matching `checkpoint.sh:69-71` (`has_jq`/`has_py`) and CLAUDE.md "Bundled scripts depend on jq OR python3". **Do not require `node`** for any fold/journal/state path (node is only for the human-action gate `check-action-trace.js`, which this plan does not touch).
- **The 3-arg CLI is preserved byte-for-byte.** `checkpoint.sh <run> <crit> <verdict>` plus every option (`--confidence`/`--phase`/`--last-action`/`--evidence-refs`/`--bug-ref`/`--kinds`/`--persona`/`--nonui-reason`) and the two flag forms (`--resume <run>`, `--list <run>`) keep their exact behaviour and output. The `checkpoint.json` per-criterion record keeps its exact keys (`criterion_id, verdict, confidence, phase, last_action, evidence_refs, bug_ref, kinds, persona, nonUiActionReason, checkpointed_at`) and root (`{run_id, updated_at, criteria:[]}`). **`tests/checkpoint/run.sh` is the oracle — it must pass unmodified against the refactored script** (it is a characterization test; extend it only by *adding* cases, never editing existing assertions).
- **Fold is a total function over malformed events.** Every event line is independently parsed; a line that fails to parse (including a torn last line) is skipped and recorded in `fold-anomalies`, never aborting the fold. The three named malformed classes get explicit rules: `criterion_verdict` with no preceding `criterion_started` → **record-the-verdict + flag** (losing a verdict is worse than a stray note); duplicate `plan_frozen` → **last-wins**; `act_committed` with no `act_intent` → **skip-with-warning**. Unknown/absent `event` type → skip + flag. Duplicate `criterion_verdict` for the same `(scenario, criterion, persona)` → **last-wins by `seq`**.
- **Equivalence is SEMANTIC, not byte.** Fold output is compared by canonicalized JSON (sorted keys, whitespace-normalized), never `cmp`/byte-diff — jq and python3 serialize differently. The canonical serializer sorts object keys and sources every timestamp from a journal event (never `date` at fold time), so a fold is deterministic given a journal.
- **Atomic + durable writes, degrading honestly.** Derived files are written temp-in-same-dir → (python3 `os.fsync` on the file) → `rename` → (python3 `os.fsync` on the parent dir). On a **jq-only** box (no python3) the fsync steps are skipped: the write is still POSIX-atomic (temp→rename) but **not** crash-fsync-durable, and a one-line note is appended to `fold-anomalies` (`{"rule":"fsync-unavailable"}`) so the reduced durability is recorded, never silent. The journal itself is append + `>>` (atomic for `O_APPEND` writes under the size limits here).
- **Scenario cursor.** `scenarioId == personaId` when a persona is set; a criterion with `persona:""`/absent maps to the synthetic scenario id `__shared__`. The atomic resumable unit is `(scenarioId, criterionId)`. This reconciles ADR-0012's existing `(criterion_id, persona="")` records (empty persona ⇒ `__shared__`).
- **Mutation flag is DERIVED, never agent-declared.** `mutation-flag.sh` decides whether a criterion mutates from its action shape (verb/HTTP-method/kinds) by deterministic rules; an agent-authored boolean is never trusted. A capture-hook cross-check is an **optional** extension point that no-ops when no toolstream file is present (the capture-hook is unbuilt — Plan B / honesty-hardening territory) — so the derive path is the guarantee today and its absence-tolerance is explicit.
- **Portability — regenerate `dist/` + static sweep after every source edit.** `scripts/build-adapter.sh` does `cp -R skills scripts docs …` into `dist/<harness>/`, so every new/edited `skills/checkpointing-qa-memory/scripts/*` is copied into all four adapters. There is **no** byte-oracle for these files, but `scripts/validate-adapters.sh` runs a static sweep (`bash -n` / `node --check` / `json.load`) over `skills scripts harnesses tools tests`; it must exit 0. `dist/` is **git-ignored and never committed**. Each task ends by regenerating dist + running `validate-adapters.sh` (and `tests/portability/run.sh` — it greps for `grep -P`/`perl`; the new scripts must use neither, so it stays green) as a CI-parity gate.
- **Tests are bash runners at `tests/<name>/run.sh`** using `set -uo pipefail`, `HERE="$(cd "$(dirname "$0")" && pwd)"`, `check`/`get` helpers, `mktemp -d` + `cd "$WORK"` isolation, and `echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]`. Fault-inject the python3 path with a `fakebin` PATH shim that masks `jq` (see `tests/checkpoint/run.sh:88-100`). `tests/` is **not** copied into `dist/`.
- **Validate before every commit:** `bash -n` every edited/created `*.sh`; `node --check` any `*.js` (none expected); `python3 -c "import json;json.load(open(f))"` any `*.json` created; `python3 -c "import ast"`-equivalent syntax check for `fold.py` (`python3 -m py_compile fold.py`); `jq -n -f fold.jq </dev/null` or `jq 'empty' -f fold.jq` to syntax-check the jq program; the task's `tests/<name>/run.sh` prints `FAIL=0` and exits 0; `tests/checkpoint/run.sh` prints `FAIL=0`; `bash scripts/validate-adapters.sh` exits 0; `bash tests/portability/run.sh` prints `FAIL=0`.
- **Commit messages contain no Claude/Anthropic attribution and no `Co-Authored-By` trailer.** (User global rule.)

---

### Task 1: Journal event schema + append + atomic/canonical write helpers

Create `journal.sh`: the append-only writer and the shared atomic-write + canonical-serialize helpers every later task reuses. Define the complete event schema as a documented contract. No fold yet — this task ships the substrate everything else stands on.

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/journal.sh`
- Create: `tests/journal/run.sh`

**Interfaces:**
- Produces (sourced or shelled by later tasks + `checkpoint.sh`):
  - `journal_file <run-id> → stdout path` — `.qa/runs/<run-id>/journal.ndjson` (honors `QA_BASE`, default `.qa/runs`, exactly like `checkpoint.sh:59`).
  - `journal_append <run-id> <event-json>` — validates `<event-json>` is a single JSON object with a non-empty string `event` field, stamps `seq` (current max seq in the file + 1, or 1) and `t` (`date -u +%Y-%m-%dT%H:%M:%SZ` — **the only place a wall-clock time enters the system**; fold never calls `date`), and appends exactly one line (compact, newline-terminated) via `>>`. Errors (non-zero + message) on malformed input.
  - `atomic_write <dest-path>` — reads JSON from stdin, writes to `<dest>.tmp.$$` in the same dir, fsyncs (python3) the file, `rename`s over `<dest>`, fsyncs (python3) the parent dir; on a jq-only box skips the two fsyncs (still temp→rename) and echoes the token `FSYNC_UNAVAILABLE` on fd 3 (callers that maintain `fold-anomalies` capture it). Never leaves a `.tmp` behind on failure (trap-cleanup like `checkpoint.sh:220-228`).
  - `canonical <json>` (stdin→stdout) — emits canonical JSON: recursively **sorted object keys**, compact separators. jq: `jq -S -c .`. python3: `json.dumps(obj, sort_keys=True, separators=(",",":"))`.
- **Event schema (the contract — document it as a comment block at the top of `journal.sh`):** one JSON object per line, always carrying `seq` (int, monotonic ≥1) and `t` (ISO-8601 Z). `event` ∈:
  `run_started{runId, baseUrl?, mode?}` · `phase_entered{phase}` · `phase_exited{phase}` · `plan_frozen{criteria:[{criterionId,scenarioId,personaId,mutates,writeSet?}],order:[criterionId]}` · `plan_amended{criterionId,scenarioId,personaId,mutates}` · `scenario_started{scenarioId,personaId}` · `criterion_started{scenarioId,criterionId,personaId}` · `act_intent{key,writeSet}` · `act_committed{key,outcome}` · `criterion_verdict{scenarioId,criterionId,personaId,verdict,confidence,layer?,evidenceRefs,kinds,bugRef?,lastAction?,nonUiActionReason?}` · `bug_logged{bugId,criterionId,title,suspectedLayer,expected,actual,axis?}` · `run_ended{}`. (Plan A journals+folds these; `act_*`/`plan_*` reconciliation/resume is Plan B.)

- [ ] **Step 1: Write the failing tests**

Create `tests/journal/run.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
J="$HERE/../../skills/checkpointing-qa-memory/scripts/journal.sh"
PASS=0; FAIL=0
get() { jq -r "$2" "$1" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; PASS=$((PASS+1)); else echo "FAIL - $1 (got '$2' want '$3')"; FAIL=$((FAIL+1)); fi; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# append two events → two lines, seq 1 then 2, both parse, event field preserved
( cd "$WORK" && bash "$J" append r1 '{"event":"run_started","runId":"r1"}' >/dev/null )
( cd "$WORK" && bash "$J" append r1 '{"event":"phase_entered","phase":"verify"}' >/dev/null )
JF="$WORK/.qa/runs/r1/journal.ndjson"
check "two lines"      "$(wc -l < "$JF" | tr -d ' ')"            "2"
check "seq1"           "$(sed -n 1p "$JF" | jq -r '.seq')"       "1"
check "seq2"           "$(sed -n 2p "$JF" | jq -r '.seq')"       "2"
check "event1"         "$(sed -n 1p "$JF" | jq -r '.event')"     "run_started"
check "has ts"         "$(sed -n 1p "$JF" | jq -r '.t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))" "true"
check "each line json" "$(while read -r l; do echo "$l" | jq -e . >/dev/null || { echo bad; break; }; done < "$JF"; echo ok)" "ok"

# malformed append (no event field) → non-zero, no line written
( cd "$WORK" && bash "$J" append r2 '{"foo":1}' >/dev/null 2>&1 ); rc=$?
check "reject no-event rc"  "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
check "reject no-event file" "$([[ -f "$WORK/.qa/runs/r2/journal.ndjson" ]] && echo exists || echo none)" "none"

# atomic_write produces canonical sorted-key output and leaves no tmp
echo '{"b":2,"a":1}' | ( cd "$WORK" && bash "$J" atomic_write "$WORK/out.json" )
check "atomic keys sorted" "$(cat "$WORK/out.json")" '{"a":1,"b":2}'
check "no tmp left"        "$(ls "$WORK"/out.json.tmp.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# canonical helper sorts nested keys
check "canonical nested" "$(echo '{"z":{"y":1,"x":2},"a":3}' | ( cd "$WORK" && bash "$J" canonical ))" '{"a":3,"z":{"x":2,"y":1}}'

echo "---"; echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/journal/run.sh`
Expected: every case FAILs (script `journal.sh` does not exist → `bash: .../journal.sh: No such file`), final `FAIL>0`, exit non-zero.

- [ ] **Step 3: Implement `journal.sh`**

Create `skills/checkpointing-qa-memory/scripts/journal.sh` with: the schema comment block (all event types above); `has_jq`/`has_py`/`die` helpers copied from `checkpoint.sh:69-71`; `QA_BASE="${QA_BASE:-.qa/runs}"`; `journal_file`; a `next_seq` (grep-count existing lines' max `.seq`, jq or python3, default 0 → +1); `journal_append` (validate object + non-empty string `event` via jq/py; inject `seq`+`t`; append compact line); `atomic_write` (temp in `dirname`, python3 `os.fsync` on file+dir when `has_py`, else set the `FSYNC_UNAVAILABLE` signal on fd 3; `mv` for the rename; `trap`-clean the tmp); `canonical` (`jq -S -c .` or python `json.dumps(...,sort_keys=True,separators=(",",":"))`); and a dispatch (`case "$1" in append) …; atomic_write) …; canonical) …; *) die "usage: journal.sh {append|atomic_write|canonical} …";; esac`). Time is stamped **only** in `journal_append`.

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/journal/run.sh`
Expected: every `ok - …`, `PASS=11 FAIL=0`, exit 0.

- [ ] **Step 5: Force the python3 fallback and re-run**

Add a `fakebin` shim to `tests/journal/run.sh` (a second pass) that masks `jq` on PATH so the python3 branch runs, then re-asserts the four representative cases (`two lines`, `atomic keys sorted`, `canonical nested`, `reject no-event rc`). Model it on `tests/checkpoint/run.sh:88-100`. Run `bash tests/journal/run.sh`; expected: python-path cases also `ok`, `FAIL=0`.

- [ ] **Step 6: Validate + regenerate dist + commit**

```bash
bash -n skills/checkpointing-qa-memory/scripts/journal.sh
bash tests/journal/run.sh
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh
bash tests/portability/run.sh
git add skills/checkpointing-qa-memory/scripts/journal.sh tests/journal/run.sh
git commit -m "feat(checkpointing): journal.ndjson append + atomic/canonical write helpers (dual jq/python3)"
```
Expected: all green (`FAIL=0`, `validate-adapters: OK`).

---

### Task 2: `fold(journal)` — total, canonical, anomaly-recording

Create the two fold engines (`fold.jq`, `fold.py`) and the `fold.sh` dispatcher. `fold(journal)` reads `journal.ndjson`, skips unparseable lines (recording anomalies), applies the malformed-class rules, and emits `checkpoint.json` (today's exact shape) canonically, plus a sibling `fold-anomalies.json`. This is the AC-1/AC-2 core.

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/fold.jq`
- Create: `skills/checkpointing-qa-memory/scripts/fold.py`
- Create: `skills/checkpointing-qa-memory/scripts/fold.sh`
- Create: `tests/fold/run.sh`
- Create: `tests/fold/fixtures/basic.ndjson`
- Create: `tests/fold/fixtures/torn.ndjson`
- Create: `tests/fold/fixtures/malformed-classes.ndjson`

**Interfaces:**
- Consumes: a `journal.ndjson` path; the event schema (Task 1); `journal.sh`'s `atomic_write`/`canonical` (sourced).
- Produces:
  - `fold.sh <run-id>` — folds `.qa/runs/<run-id>/journal.ndjson`, `atomic_write`s the derived `checkpoint.json` and `fold-anomalies.json` into `.qa/runs/<run-id>/`, and echoes the checkpoint JSON to stdout.
  - `fold.jq` / `fold.py` — pure reducers: **stdin = the pre-validated valid events as a JSON array** (the bash wrapper does the per-line parse/skip so neither engine has to survive a torn line), plus the list of skipped-line anomalies passed in; **stdout = `{checkpoint:{…}, anomalies:[…]}`**. Splitting parse-and-skip (bash) from reduce (jq/py) keeps both engines simple and identical in behaviour.
- **Reduce rules (identical in both engines):** group events by `(scenarioId, criterionId, personaId)`; the last `criterion_verdict` (max `seq`) per group becomes one `criteria[]` record in today's shape (`criterion_id, verdict, confidence, phase, last_action, evidence_refs, bug_ref, kinds, persona, nonUiActionReason, checkpointed_at` ← the verdict event's `t`). `scenarioId` derives `persona` back to the record's `persona` (`__shared__` ⇒ `""`). `run_id` from `run_started`; `updated_at` = max event `t`. Anomalies: `verdict-without-started` (verdict group has no `criterion_started`) → keep record + push anomaly; `duplicate-plan-frozen` → keep last, push anomaly; `act-committed-no-intent` → drop that event, push anomaly; `unknown-event` → dropped by the wrapper's schema check + anomaly. `openActs[]` (act_intent keys with no matching act_committed) go into the anomalies/cursor side channel (consumed in Plan B), not into `checkpoint.json`.

- [ ] **Step 1: Create the fixtures**

`tests/fold/fixtures/basic.ndjson` (three criteria, one a shared/`__shared__`, one persona `alice`, one with a superseding duplicate verdict):
```
{"seq":1,"t":"2026-09-01T10:00:00Z","event":"run_started","runId":"authz-run"}
{"seq":2,"t":"2026-09-01T10:00:01Z","event":"phase_entered","phase":"verify"}
{"seq":3,"t":"2026-09-01T10:00:02Z","event":"criterion_started","scenarioId":"__shared__","criterionId":"C3","personaId":""}
{"seq":4,"t":"2026-09-01T10:00:03Z","event":"criterion_verdict","scenarioId":"__shared__","criterionId":"C3","personaId":"","verdict":"pass","confidence":"high","layer":null,"evidenceRefs":["evidence/C3/recompute.json"],"kinds":["computed"],"bugRef":null,"lastAction":"checked","nonUiActionReason":null}
{"seq":5,"t":"2026-09-01T10:00:04Z","event":"criterion_started","scenarioId":"alice","criterionId":"C1","personaId":"alice"}
{"seq":6,"t":"2026-09-01T10:00:05Z","event":"criterion_verdict","scenarioId":"alice","criterionId":"C1","personaId":"alice","verdict":"fail","confidence":"high","layer":"service","evidenceRefs":["evidence/alice/C1/probe.json"],"kinds":["probe"],"bugRef":"B1","lastAction":"probed","nonUiActionReason":null}
{"seq":7,"t":"2026-09-01T10:00:06Z","event":"criterion_verdict","scenarioId":"alice","criterionId":"C1","personaId":"alice","verdict":"pass","confidence":"high","layer":null,"evidenceRefs":["evidence/alice/C1/probe2.json"],"kinds":["probe"],"bugRef":null,"lastAction":"reprobed","nonUiActionReason":null}
```
`tests/fold/fixtures/torn.ndjson` = `basic.ndjson`'s first 6 lines plus a **truncated** 7th line (valid-looking prefix, no closing brace):
```
{"seq":7,"t":"2026-09-01T10:00:06Z","event":"criterion_verdict","scenarioId":"alice","criterionId":"C1","personaId":"alice","verdict":"pass"
```
`tests/fold/fixtures/malformed-classes.ndjson` (one of each named class):
```
{"seq":1,"t":"2026-09-01T10:00:00Z","event":"run_started","runId":"m"}
{"seq":2,"t":"2026-09-01T10:00:01Z","event":"criterion_verdict","scenarioId":"__shared__","criterionId":"CX","personaId":"","verdict":"pass","confidence":"high","evidenceRefs":[],"kinds":[]}
{"seq":3,"t":"2026-09-01T10:00:02Z","event":"plan_frozen","criteria":[],"order":[]}
{"seq":4,"t":"2026-09-01T10:00:03Z","event":"plan_frozen","criteria":[],"order":["CX"]}
{"seq":5,"t":"2026-09-01T10:00:04Z","event":"act_committed","key":"m:__shared__:CY","outcome":"ok"}
{"seq":6,"t":"2026-09-01T10:00:05Z","event":"totally_unknown","foo":1}
```

- [ ] **Step 2: Write the failing tests**

Create `tests/fold/run.sh` (asserts, using `check`/`get` on the emitted checkpoint + anomalies):
- `basic`: `fold.sh` on `basic.ndjson` → `checkpoint.json` has `.run_id=="authz-run"`, `[.criteria[].criterion_id]` == `["C3","C1"]` (first-seen order), C1's verdict is `pass` (seq-7 last-wins, not the seq-6 `fail`), C3's `persona==""`, `.updated_at=="2026-09-01T10:00:06Z"`.
- `torn`: fold on `torn.ndjson` → does **not** error (exit 0), C1 has **no** verdict record (its only verdict line was torn/skipped) so `[.criteria[].criterion_id]==["C3"]`, and `fold-anomalies.json` contains a `{"rule":"unparseable-line"}` entry.
- `malformed`: fold on `malformed-classes.ndjson` → exit 0; anomalies include `verdict-without-started` (CX), `duplicate-plan-frozen`, `act-committed-no-intent` (m:__shared__:CY), `unknown-event`; CX's verdict record **is** present (record-the-verdict rule).
- `dual-equiv`: fold `basic.ndjson` under jq, then again with `jq` masked (fakebin → python3), canonicalize both `checkpoint.json` outputs (`journal.sh canonical`), assert **string-equal** (semantic equivalence across engines).
- `regenerate`: `fold.sh` on `basic`, delete `checkpoint.json`, `fold.sh` again → canonically-equal to the first (AC-1).

Run: `bash tests/fold/run.sh` → all FAIL (`fold.sh` absent). Exit non-zero.

- [ ] **Step 3: Implement `fold.jq`**

Pure jq reducer over the input `{events:[…valid…], skipped:[…anomalies…]}`: implement the grouping + last-verdict-wins + shape-mapping + anomaly rules above; output `{checkpoint:{run_id,updated_at,criteria:[…]}, anomalies:[…]}`. Keep `criteria` in first-`criterion_started`-or-first-verdict-seen order (a `reduce` preserving insertion order keyed by `scenarioId+" "+criterionId+" "+personaId`).

- [ ] **Step 4: Implement `fold.py`**

Byte-for-behaviour-identical python3 reducer (same input/output contract, same rules, `OrderedDict` for insertion order). Both engines must produce the same *semantic* result (canonically equal) — this is asserted by `dual-equiv`.

- [ ] **Step 5: Implement `fold.sh`**

Dispatcher: read the journal path for `<run-id>`; **line-loop** each line, `jq -e .`/`python -c json.loads` validate → collect valid events into a JSON array, collect `{"rule":"unparseable-line","line":N}` for each failure and `{"rule":"unknown-event",...}` for a parsed line whose `event` isn't in the schema set; pipe `{events,skipped}` to `fold.jq` (has_jq) or `fold.py` (has_py); split the engine's `{checkpoint,anomalies}`; `atomic_write` `checkpoint.json` and `fold-anomalies.json` (append the `FSYNC_UNAVAILABLE` anomaly if `atomic_write` signalled it); echo checkpoint to stdout. `die` if neither jq nor python3.

- [ ] **Step 6: Run to verify pass (both engines) + validate + dist + commit**

```bash
python3 -m py_compile skills/checkpointing-qa-memory/scripts/fold.py
jq 'empty' -f skills/checkpointing-qa-memory/scripts/fold.jq </dev/null 2>&1 | head -1   # syntax
bash -n skills/checkpointing-qa-memory/scripts/fold.sh
bash tests/fold/run.sh                    # PASS all, FAIL=0
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh
bash tests/portability/run.sh
git add skills/checkpointing-qa-memory/scripts/fold.jq skills/checkpointing-qa-memory/scripts/fold.py \
        skills/checkpointing-qa-memory/scripts/fold.sh tests/fold/
git commit -m "feat(checkpointing): fold(journal) total reducer (dual jq/python3), canonical output + fold-anomalies"
```

---

### Task 3: Refactor `checkpoint.sh` to write via append-event + fold (CLI preserved)

Rewire `checkpoint.sh`'s upsert path so it appends a `criterion_verdict` event to the journal then folds to regenerate `checkpoint.json`, instead of mutating `checkpoint.json` in place. The 3-arg CLI, every option, `--resume`, `--list`, and the emitted `checkpoint.json` shape stay byte-identical. **The existing characterization suite is the gate.**

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` — replace the in-place `upsert_jq`/`upsert_py` write with: build the `criterion_verdict` event from the parsed args/options → `journal.sh append` → `fold.sh` → the resulting `checkpoint.json` is the write. `cmd_resume`/`cmd_list` continue to read `checkpoint.json` (now a fold projection) unchanged.
- Modify: `tests/checkpoint/run.sh` — **add** cases (do not edit existing assertions): after an upsert, a `journal.ndjson` exists with a matching `criterion_verdict`; deleting `checkpoint.json` and folding regenerates the identical record; the `(criterion_id, persona="")` match/replace semantics still hold through the journal (a second upsert of the same `(crit,persona)` yields last-wins, one record).

**Interfaces:**
- Consumes: `journal.sh` (`append`), `fold.sh` (both from Task 1/2), sourced or shelled by absolute path relative to `$(dirname "$0")`.
- Produces: unchanged public surface. Internally, `checkpoint.json` is now `fold(journal)` output; the journal is the source of truth.

- [ ] **Step 1: Run the existing characterization suite (baseline, must already pass)**

Run: `bash tests/checkpoint/run.sh` → note the `PASS=N FAIL=0`. This is the invariant the refactor must preserve.

- [ ] **Step 2: Write the new (failing) journal-backing assertions**

Add to `tests/checkpoint/run.sh` (a new block after the existing cases, before the summary): assert `journal.ndjson` exists after an upsert and its last line is a `criterion_verdict` with the right `criterionId`/`verdict`/`personaId`; assert deleting `checkpoint.json` then `bash fold.sh <run>` reproduces the same `.criteria[0]` record (canonically). Run: `bash tests/checkpoint/run.sh` → the **new** cases FAIL (journal not written yet), existing cases still `ok`.

- [ ] **Step 3: Rewire the upsert path**

In `checkpoint.sh`'s `cmd_upsert` (the code around `upsert_jq`/`upsert_py`, `:147-292`): after option parsing, assemble the `criterion_verdict` event object (map `--persona`→`personaId` with `""`→`personaId:""`; `--evidence-refs`→`evidenceRefs`; `--kinds`→`kinds`; `--bug-ref`→`bugRef`; `--confidence`/`--phase`/`--last-action`/`--nonui-reason`; `scenarioId` = persona or `__shared__`; `criterionId`) → `journal.sh append "$run" "$event"` → `fold.sh "$run" >/dev/null` (which writes `checkpoint.json`). Remove the direct in-place `checkpoint.json` mutation. Keep all validation/error messages. The record shape is now produced by the fold's mapping (Task 2) — confirm it matches the old keys exactly.

- [ ] **Step 4: Run both suites to green**

Run: `bash tests/checkpoint/run.sh` (existing + new cases all `ok`, `FAIL=0`) and `bash tests/fold/run.sh` + `bash tests/journal/run.sh` (still green). If any *existing* characterization assertion regresses, the record mapping drifted — fix the fold mapping, not the test.

- [ ] **Step 5: Force python3 path**

The suite's existing `fakebin` jq-mask pass must also stay green (checkpoint via python3 fold). Run and confirm `FAIL=0`.

- [ ] **Step 6: Validate + dist + commit**

```bash
bash -n skills/checkpointing-qa-memory/scripts/checkpoint.sh
bash tests/checkpoint/run.sh && bash tests/fold/run.sh && bash tests/journal/run.sh
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh && bash tests/portability/run.sh
git add skills/checkpointing-qa-memory/scripts/checkpoint.sh tests/checkpoint/run.sh
git commit -m "refactor(checkpointing): checkpoint.sh writes via append-event + fold; 3-arg CLI + checkpoint.json shape preserved"
```

---

### Task 4: Scenario/persona fold mapping + `(scenario, criterion)` cursor

Extend the fold to expose the resumable **cursor** — current phase, current `(scenario, criterion)`, and the per-tuple done/pending state — with the `__shared__` synthetic scenario and ADR-0012 `(criterion_id, persona="")` back-compat. Emitted as a `run-manifest` projection (the first machine writer for it), reconciling the documented template/reality drift by writing the **superset** real shape.

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/fold.jq` and `fold.py` — add a `manifest` block to the engine output: `{phase, criteria_total, criteria_done, personas:[…], scenarios:[…], cursor:{scenarioId,criterionId}}` where `cursor` = the first `(scenario, criterion)` that has a `criterion_started`/`plan_frozen` entry but **no** `criterion_verdict` (else `null` = run complete). `phase` = last `phase_entered` not yet `phase_exited`.
- Modify: `skills/checkpointing-qa-memory/scripts/fold.sh` — also `atomic_write` `run-manifest.json` from the engine's `manifest` block.
- Modify: `tests/fold/run.sh` — add cursor/scenario cases.
- Create: `tests/fold/fixtures/cursor.ndjson`

**Interfaces:**
- Consumes: the journal + Task 2's engine output shape (extend, don't replace).
- Produces: `run-manifest.json` with `{run_id, phase, criteria_total, criteria_done, personas, scenarios, cursor}`; `cursor` is the Plan-B resume entry point (`(scenarioId, criterionId)` or `null`). Shared criteria (`persona:""`) appear under scenario `__shared__`.

- [ ] **Step 1: Create `tests/fold/fixtures/cursor.ndjson`**

A run with: `phase_entered verify`; two personas (`admin`, `user`) each starting a criterion, `admin`'s `C1` gets a verdict, `user`'s `C2` does **not**; a `__shared__` `C0` started + verdict. Expected cursor = `{scenarioId:"user",criterionId:"C2"}` (first started-without-verdict in seq order). Include exact lines.

- [ ] **Step 2: Write failing cursor tests**

Add to `tests/fold/run.sh`: fold `cursor.ndjson` → `run-manifest.json` has `.phase=="verify"`, `.cursor.scenarioId=="user"`, `.cursor.criterionId=="C2"`, `.criteria_done==2` (C0 + C1), `.scenarios | index("__shared__") != null`, `.personas | sort == ["admin","user"]`. Also: a journal whose only records are legacy `persona:""` verdicts folds them under scenario `__shared__` (`.scenarios==["__shared__"]`). Run → FAIL (manifest not emitted yet).

- [ ] **Step 3: Extend `fold.jq` + `fold.py` with the manifest block**

Add the cursor/manifest computation to both engines (phase from `phase_entered`/`phase_exited` pairing; done = count of tuples with a verdict; total = distinct started/frozen tuples; personas/scenarios distinct + sorted; cursor = first started-no-verdict by seq). Keep the two engines semantically equal (extend the `dual-equiv` test to cover the manifest).

- [ ] **Step 4: Emit `run-manifest.json` from `fold.sh`**

`atomic_write` the manifest block alongside `checkpoint.json`. Run: `bash tests/fold/run.sh` → all `ok`, `FAIL=0`; extend `dual-equiv` to canonically compare `run-manifest.json` across engines.

- [ ] **Step 5: Validate + dist + commit**

```bash
python3 -m py_compile skills/checkpointing-qa-memory/scripts/fold.py
jq 'empty' -f skills/checkpointing-qa-memory/scripts/fold.jq </dev/null
bash tests/fold/run.sh && bash tests/checkpoint/run.sh
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh && bash tests/portability/run.sh
git add skills/checkpointing-qa-memory/scripts/fold.jq skills/checkpointing-qa-memory/scripts/fold.py \
        skills/checkpointing-qa-memory/scripts/fold.sh tests/fold/
git commit -m "feat(checkpointing): fold exposes (scenario,criterion) cursor + run-manifest projection (__shared__, ADR-0012 back-compat)"
```

---

### Task 5: Derived mutation flag (`mutation-flag.sh`)

Add the deterministic, agent-untrusted mutation-flag rules. A criterion mutates iff its **action shape** does (verb / HTTP method / kinds), never an agent boolean. A capture-hook cross-check is an optional extension point that no-ops when no toolstream file exists.

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/mutation-flag.sh`
- Create: `tests/mutation-flag/run.sh`

**Interfaces:**
- Produces:
  - `mutation-flag.sh derive <criterion-json>` → prints `true`/`false`. Rules (first match wins): `kinds` contains `human-action` → `true`; an `httpMethod` field ∈ `{POST,PUT,PATCH,DELETE}` (case-insensitive) → `true`; an `action`/`title` string matching a mutating verb (`\b(create|add|new|update|edit|change|delete|remove|submit|save|assign|transfer|approve|reject|invite|revoke|upload|toggle|set)\b`, case-insensitive) → `true`; else → `false`. A read-only verb (`view|list|show|read|filter|sort|search|open|see|display`) with no mutating signal → `false`.
  - `mutation-flag.sh reconcile <criterion-json> <toolstream-path?>` → derives, then if `<toolstream-path>` **exists and is non-empty**, and it shows a mutating tool during a criterion the derive marked `false`, prints `true` + a `{"rule":"mutation-observed-in-readonly"}` note on fd 3; when the path is absent/empty, returns the derive result unchanged (the documented degrade). Uses the existing `parse-session-log.js mutates()` classifier **only if `node` is present**; when node is absent, `reconcile` == `derive` (never a hard dependency).

- [ ] **Step 1: Write failing tests**

`tests/mutation-flag/run.sh`: `derive` returns `true` for `{"kinds":["human-action"],"action":"view page"}` (kinds win over read verb), `{"httpMethod":"delete"}`, `{"action":"Create a new founder"}`, `{"title":"Submit the cap-table form"}`; `false` for `{"action":"View the dashboard","kinds":["bake"]}`, `{"action":"Filter deliverables by status"}`, `{"httpMethod":"GET"}`. `reconcile` with a missing toolstream path returns the derive result; `reconcile` with a toolstream file containing a mutating call during a `false`-derived criterion returns `true` (only asserted when `node` is available — guard the case with `command -v node`). Run → FAIL (script absent).

- [ ] **Step 2: Implement `mutation-flag.sh`**

`has_jq`/`has_py`/`die` header; `derive` (jq/py to read fields, bash regex for the verb match — use `grep -Ei`, **not** `grep -P`, to keep `tests/portability/run.sh` green); `reconcile` (derive, then optional node cross-check guarded by `command -v node` and a non-empty file test). Document at top: "the flag is derived, never trusted from an agent; the cross-check is best-effort and absent-tolerant."

- [ ] **Step 3: Pass + force python3**

Run `bash tests/mutation-flag/run.sh` → `FAIL=0`. Add a jq-masked pass for `derive`; confirm green.

- [ ] **Step 4: Validate + dist + commit**

```bash
bash -n skills/checkpointing-qa-memory/scripts/mutation-flag.sh
bash tests/mutation-flag/run.sh
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh && bash tests/portability/run.sh
git add skills/checkpointing-qa-memory/scripts/mutation-flag.sh tests/mutation-flag/run.sh
git commit -m "feat(checkpointing): derived mutation-flag rules (agent-untrusted) with absent-tolerant capture-hook cross-check"
```

---

### Task 6: Fan-out sub-journals + lock + sequence-gap detection (`journal-merge.sh`)

Support the opt-in parallel path (ADR-0003) without corrupting the shared journal: each fan-out child writes its own `journal.<child>.ndjson`; a parent merge appends child events into the main `journal.ndjson` under an advisory `flock` with a monotonic global `seq`, and the fold detects a `seq` gap as an anomaly.

**Files:**
- Create: `skills/checkpointing-qa-memory/scripts/journal-merge.sh`
- Modify: `skills/checkpointing-qa-memory/scripts/journal.sh` — `journal_append` accepts an optional `--child <name>` writing `journal.<name>.ndjson` (per-child seq) instead of the main journal.
- Modify: `skills/checkpointing-qa-memory/scripts/fold.jq` + `fold.py` — add a `seq-gap` anomaly when the sorted `seq` list of folded events has a hole.
- Create: `tests/journal-merge/run.sh`

**Interfaces:**
- Produces:
  - `journal.sh append --child <name> <run> <event>` — appends to `.qa/runs/<run>/journal.<name>.ndjson` with a per-child seq.
  - `journal-merge.sh <run>` — under `flock .qa/runs/<run>/.journal.lock`, reads every `journal.<*>.ndjson`, orders their events (by child name then per-child seq — a total, deterministic order), **re-stamps a monotonic global `seq`** continuing from the main journal's current max, appends them to `journal.ndjson`, and removes the merged child files. Degrade: if `flock` is absent (`command -v flock` fails), fall back to a `mkdir`-based lock (`.journal.lock.d`) and note it.
  - fold: a discontinuous `seq` in the main journal → `{"rule":"seq-gap","after":N}` anomaly (does not abort).

- [ ] **Step 1: Write failing tests**

`tests/journal-merge/run.sh`: two children each append two events (`--child a`, `--child b`) → two `journal.a.ndjson`/`journal.b.ndjson`, main journal absent; `journal-merge.sh <run>` → main `journal.ndjson` has 4 lines with **contiguous** global seq `1..4`, child files removed; folding the merged journal yields both children's verdicts with **no** `seq-gap` anomaly. Then a hand-crafted main journal with seqs `1,2,4` folds with a `seq-gap` anomaly. Run → FAIL.

- [ ] **Step 2: Implement `--child` in `journal.sh`**

Add the `--child <name>` option to `journal_append` (target file + per-child `next_seq`). Keep the default (no `--child`) behaviour byte-identical (Task 1 tests still green).

- [ ] **Step 3: Implement `journal-merge.sh`**

`flock` (or `mkdir`-lock degrade) around: collect `journal.*.ndjson` (sorted), re-stamp global seq from the main journal's max, append, `rm` children. Deterministic child order (lexicographic name). Time is **not** re-stamped (preserve each event's original `t`).

- [ ] **Step 4: Add `seq-gap` detection to both fold engines**

In `fold.jq`/`fold.py`: after collecting valid events, if the ascending distinct `seq` list has a hole, push `{"rule":"seq-gap","after":<lastContiguous>}`. Extend `dual-equiv`.

- [ ] **Step 5: Pass + validate + dist + commit**

```bash
bash -n skills/checkpointing-qa-memory/scripts/journal-merge.sh skills/checkpointing-qa-memory/scripts/journal.sh
python3 -m py_compile skills/checkpointing-qa-memory/scripts/fold.py
jq 'empty' -f skills/checkpointing-qa-memory/scripts/fold.jq </dev/null
bash tests/journal-merge/run.sh && bash tests/journal/run.sh && bash tests/fold/run.sh && bash tests/checkpoint/run.sh
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh && bash tests/portability/run.sh
git add skills/checkpointing-qa-memory/scripts/journal-merge.sh skills/checkpointing-qa-memory/scripts/journal.sh \
        skills/checkpointing-qa-memory/scripts/fold.jq skills/checkpointing-qa-memory/scripts/fold.py tests/journal-merge/
git commit -m "feat(checkpointing): fan-out sub-journals merged under flock with monotonic seq; fold seq-gap detection"
```

---

### Task 7: Document the substrate (SKILL.md + CONTEXT + ADR pointer)

Record the journal/fold substrate where the skill and glossary are documented. Documentation only — no script change. (The design ADR-0020 + CONTEXT terms `journal`/`fold`/`scenario`/`frozen plan` already exist from the design commit; this task wires the *implemented* scripts into the skill's Scripts Reference + Run Directory Layout and notes the Plan-A/Plan-B boundary.)

**Files:**
- Modify: `skills/checkpointing-qa-memory/SKILL.md` — add `journal.ndjson` + `fold-anomalies.json` to the Run Directory Layout tree; add `journal.sh`/`fold.sh`/`mutation-flag.sh`/`journal-merge.sh` to the Scripts Reference with one-line each; add a sentence to the ADR-0002 boundary section that "position = `fold(journal)`, never agent memory"; a mini-eval for torn-tail resume-position. Keep body < 500 lines (currently 230).
- Modify: `CONTEXT.md` — confirm `journal`/`fold`/`scenario` entries match the implemented behaviour; add `fold-anomalies` if not present (one line).

**Interfaces:** none (prose).

- [ ] **Step 1: Update SKILL.md**

Add the two files to the layout tree, the four scripts to the Scripts Reference (each: name — one-line purpose), the position-is-fold sentence, and mini-eval #6 (torn journal tail → fold still lands on the right `(scenario, criterion)` cursor, no half-written derived file). Confirm `awk 'END{print NR}'` < 500.

- [ ] **Step 2: Update CONTEXT.md**

Ensure `journal`, `fold`, `scenario`, `fold-anomalies` glossary lines are present and accurate to the implementation (add/adjust minimally; do not restate implementation detail — CONTEXT is a glossary).

- [ ] **Step 3: Validate + dist + commit**

```bash
awk 'END{print NR}' skills/checkpointing-qa-memory/SKILL.md   # < 500
python3 -c "import json,sys" # (no JSON changed; sanity)
for h in claude codex pi opencode; do bash scripts/build-adapter.sh "$h"; done
bash scripts/validate-adapters.sh
git add skills/checkpointing-qa-memory/SKILL.md CONTEXT.md
git commit -m "docs(checkpointing): document journal/fold substrate + scripts; note Plan-A/Plan-B boundary"
```

---

## Self-Review

**1. Spec coverage** (ADR-0020 §3/§4/§5-flag/§8 + ticket cut D-1/2/3/4/8):
- D-1 journal schema + total fold + atomic + canonical serializer → Tasks 1 (append/atomic/canonical) + 2 (total fold, anomalies, canonical, AC-1/AC-2). ✅
- D-2 `checkpoint.sh` append-event + fold, 3-arg CLI preserved → Task 3, gated by the unmodified characterization suite. ✅
- D-3 scenario/persona fold (`__shared__`, ADR-0012 `persona=""` back-compat), `(scenario,criterion)` cursor → Task 4. ✅
- D-4 derived mutation flag (agent-untrusted), absent-tolerant capture-hook cross-check → Task 5. ✅
- D-8 fan-out sub-journals + lock + seq-gap → Task 6. ✅
- AC-1 (delete checkpoint.json → canonically-equal regen) → Task 2 `regenerate` + Task 3 Step 2. AC-2 (torn tail + malformed classes) → Task 2 `torn`/`malformed`. Semantic (not byte) equivalence → `dual-equiv` across every fold task. ✅
- **Deferred to Plan B (explicitly out of scope, event *types* defined but not reconciled):** D-5 idempotency re-bake/reconciliation, D-6 `/qa-resume`+`latest`+`plan_frozen` resume, D-7 per-harness resume tests. Stated in the header + Task-1 schema note. ✅

**2. Grill-fix / exploration-gap alignment:**
- "reuses ADR-0018 re-bake" has nothing to reuse → re-bake/reconciliation moved to Plan B; Plan A only journals `act_*` events + exposes `openActs`. ✅
- run-manifest/bug-log are agent-prose today → Task 4 builds the first machine writer (manifest), reconciling to the real superset shape; bug-log projection folds `bug_logged` (kept minimal — full bug-log projection can extend in Plan B without touching the schema). ✅
- capture-hook unbuilt → Task 5 cross-check no-ops without a toolstream; node never required. ✅
- fsync-from-bash → `atomic_write` uses python3 fsync, degrades to atomic-temp→rename on jq-only with a recorded `fsync-unavailable` anomaly (honors jq-OR-python3). ✅
- no byte-oracle for `skills/` files → each task runs the static sweep + portability grep gate instead; `dist/` never committed. ✅

**3. Placeholder scan:** none — every task gives exact file paths, exact fixture bytes, exact assertions, exact interfaces (function names, arg forms, return values), and exact commit commands. The two large reducers (`fold.jq`/`fold.py`) are specified by a complete rule table + fixtures + cross-engine equivalence test rather than a pasted implementation, because the TDD fixtures pin exact behaviour and hand-authored complex reducer code in a plan is higher-risk than test-pinned implementation; every rule and output key is named.

**4. Type consistency:** event keys (`seq,t,event,scenarioId,criterionId,personaId,verdict,confidence,layer,evidenceRefs,kinds,bugRef,lastAction,nonUiActionReason`) are identical across Task 1's schema, Task 2's reducer mapping, Task 3's `checkpoint_verdict` assembly, and every fixture. The **derived** `checkpoint.json` record keys (`criterion_id,verdict,confidence,phase,last_action,evidence_refs,bug_ref,kinds,persona,nonUiActionReason,checkpointed_at`) match `checkpoint.sh`'s current output exactly (the characterization suite enforces it). `scenarioId==personaId` / `""→__shared__` / `__shared__→persona:""` is applied identically in Tasks 2, 3, 4. `has_jq`/`has_py`/`die`/`atomic_write`/`canonical`/`journal_append`/`fold.sh`/`mutation-flag.sh` signatures are used identically everywhere they appear.
