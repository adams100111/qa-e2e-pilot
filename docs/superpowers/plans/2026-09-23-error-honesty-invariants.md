# Error-honesty invariants — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use the user skill **`sdd-lanes`** to implement this
> plan (NOT `superpowers:subagent-driven-development` / `executing-plans`, per
> `~/.claude/rules/sdd-lanes.md`). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it structurally impossible for a QA run to ignore an observed error or to grade an
application crash as the correct answer.

**Architecture:** Disposition moves out of the agent into deterministic scripts and out-of-agent
gates. Findings become keyed, append-only journal events sourced from two complementary channels
(the driver network log for requests, in-page interception for console errors). `qa-verify.sh` gains
four run-scoped checks that recompute the finding set independently. Known defects move to a
project-level registry with a capped expiry and a structured severity floor. Every new rule is
enrolled as a CI test suite, including three built from the originating incident verbatim.

**Tech Stack:** bash (3.2-safe), jq with a python3 fallback, node (existing `check-action-trace.js`
pattern only), `tests/<suite>/run.sh` harness enrolled in `scripts/run-engine-ci.sh` and
`qa-kit/scripts/run-qakit-ci.sh`.

**Spec:** `docs/superpowers/specs/2026-09-23-error-honesty-invariants-design.md` (commit `998438b`)

**Branch:** `feat/error-honesty-invariants` (already created, spec committed on it)

## Global Constraints

- **Gates fail closed; the record hook stays fail-open.** `capture-hook.sh` must never break the
  tool call it observes. Every script added here exits non-zero on any reported error.
- **Bash 3.2 compatible.** macOS ships 3.2; `tests/bash32-safety/run.sh` enforces it. No
  associative arrays, no `${var^^}`, no `mapfile`.
- **`jq` preferred, `python3` fallback**, honouring `QA_ENGINE` — the existing dual-engine pattern in
  `toolstream.sh` / `fold.sh`. Any logic added to `fold.jq` must be mirrored in `fold.py`.
- **No secrets in output.** Never print a credential value; cite a constant by name.
- **Commit style:** Conventional Commits. **NEVER** add a `Co-Authored-By: Claude …` trailer, a
  "Generated with Claude Code" line, or any Claude/Anthropic reference to a commit message or PR body.
- **Never run a destructive git/VCS command** — no `stash`, `reset --hard`, `checkout -- <path>`,
  `restore`, `clean -f*`, `branch -D`, and no force-push of any kind.
- **Exact reserved-namespace table** (Task 3), verbatim from spec §4.1:
  `page.rendersWithoutServerError` rejected when `value` is `false`; `page.crashed` when `true`;
  `http.status` when `>= 500`; `console.hasError` when `true`.
- **Exact prose triggers** (Task 3), verbatim from spec §4.1, matched case-insensitively, in the
  **oracle/expect fields only, never in `action`**: `expected to fail`, `deferred by design`.
- **Exact finding key format** (Task 6): `<criterionId>|<source>|<method>|<url>|<status>`.
- **Known-defect expiry cap:** 90 days. **Severity floor:** `observedClass: non-rendering` ⇒
  minimum `high`.
- **Size limits:** findings event `message` capped at 200 characters; the whole serialized event must
  stay under the PIPE_BUF boundary of 4096 bytes (`journal.sh:79-93`). `capture-hook.sh`'s
  `RESPONSE_BODY_CAP` stays at **4000** — do not raise it.
- **A file is owned by exactly one lane.** Do not edit a file outside your lane.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| R1 | Only `5xx` / unhandled exception / page crash fails a run; 3xx and 4xx are recorded, never auto-fail | `observe.js`'s `isOkStatus` is 2xx-only, so a 302 is `ok:false`; failing on any in-scope non-2xx would fail the spec's own `EC9`/`EC11` authz criteria |
| R2 | `expiry` capped at 90 days | Without a cap, `2099-01-01` makes the known-defect gate a paper rule |
| R3 | Severity floor gates on a structured `observedClass` enum, not free text | A gate that greps prose is defeated by rewording |
| R4 | Clearing a known defect requires a recorded 2xx navigation to its surface | A run that never reached the surface produces the same silence as a fixed defect |
| R5 | Prose rejection narrowed to two phrases, oracle/expect fields only | `action` is where authors legitimately describe non-rendering states |
| R6 | Two channels: driver network log (requests) + in-page interception (console) | A HAR has no console channel; in-page interception cannot see the document request |
| R7 | `RESPONSE_BODY_CAP` stays 4000; reorder the payload instead | The cap is documented accepted loss; reordering makes it harmless for findings |
| R8 | Harnesses/drivers with neither channel are `UNVERIFIED` | `session-to-toolstream.js:119` writes `responseBody: null` always |
| R9 | Post-navigation `browser_network_requests` becomes an enforced check | It is already mandated prose; prose is what failed |
| R10 | Finding key = `(criterionId, source, method, url, status)`, keyed-set semantics | The journal has no dedup; an accumulating ledger double-counts on resume |
| R11 | Canary uses the journal-emptiness once-guard | A Phase-0 assertion is silently skipped on every resumed run |
| R12 | Findings events capped well under PIPE_BUF; detail to evidence files | The torn-write recovery path is itself a duplicate-append path |
| R13 | `UNVERIFIED` synthesizes a JUnit failure; `QA_SKIP_VERIFY=1` yields `UNVERIFIED` | `<properties>` is unreachable from the exit code |
| R14 | `init-config.sh` preserves unknown top-level keys | It already silently erases six documented keys |
| R15 | `unparseable-line` + `seq-gap` contribute to `UNVERIFIED` | Both mean the run's own record is damaged |
| R16 | Known defects are project-level | Per-spec copies drift; the convenient copy gets renewed |

## File Structure

| File | Responsibility |
|---|---|
| `docs/adr/0026-engine-invariants-outrank-frozen-plan.md` | Records that ADR-0020's `plan_frozen` scopes *what* is checked, never whether a crash is acceptable |
| `scripts/classify-finding.sh` | Deterministic `originClass` + `statusClass` for one observation |
| `scripts/known-defects.sh` | Validate the registry; compute per-entry status |
| `scripts/qa-verify.sh` | +4 run-scoped checks (ledger completeness, classification, load-window, known-defects) |
| `scripts/report-to-junit.sh` | Synthesize an `UNVERIFIED` failure case so it reaches the exit code |
| `scripts/qa-ci.sh` | `QA_SKIP_VERIFY=1` yields `UNVERIFIED` instead of a silent green |
| `scripts/run-engine-ci.sh` | Enrol the three new engine suites |
| `skills/generating-qa-checklist/scripts/validate-checklist-json.sh` | Reject a criterion asserting application failure |
| `skills/driving-browser-qa/scripts/observe.js` | Reorder payload so the 4KB cap truncates `domDigest`, not findings; cap `testid`/`href` |
| `skills/checkpointing-qa-memory/scripts/fold.sh` | Register `finding_observed` + `capture_probed` in **both** engines |
| `skills/checkpointing-qa-memory/scripts/fold.jq` | Keyed-set reducer for findings |
| `skills/checkpointing-qa-memory/scripts/fold.py` | Mirror of the above |
| `skills/checkpointing-qa-memory/scripts/checkpoint.sh` | Emit `capture_probed` behind the journal-emptiness once-guard |
| `skills/bootstrapping-qa-config/scripts/init-config.sh` | Write `findings`; preserve unknown top-level keys |
| `qa-kit/scripts/migrate-inverted-criterion.sh` | Move an inverted criterion to the registry; exit non-zero pending human input |
| `qa-kit/scripts/data-baseline.sh` | Fix: exits 0 while printing errors |
| `qa-kit/scripts/run-qakit-ci.sh` | Enrol the new qa-kit suite |
| `qa-kit/commands/qa-analyze.md` | Add the `plan-defect` category above the verdict line |
| `qa-kit/commands/qa-spec.md`, `qa-kit/commands/qa-scenarios.md` | Emit a registry entry rather than an inverted criterion |
| `.qa/config.json.example` | Document the `findings` block |

## Lanes

| Wave | Lane | Tasks | Owns files | Consumes (from) |
|---|---|---|---|---|
| 1 | **A — classifier** | 2 | `scripts/classify-finding.sh`, `tests/classify-finding/run.sh` | — |
| 1 | **B — registry** | 4 | `scripts/known-defects.sh`, `tests/known-defects/run.sh` | — |
| 1 | **C — validator** | 3 | `skills/generating-qa-checklist/scripts/validate-checklist-json.sh`, `tests/validate-checklist-json/run.sh` | — |
| 1 | **D — capture payload** | 5 | `skills/driving-browser-qa/scripts/observe.js`, `tests/capture-hook/run.sh` | — |
| 1 | **E — config** | 9 | `skills/bootstrapping-qa-config/scripts/init-config.sh`, `tests/init-config/run.sh`, `.qa/config.json.example` | — |
| 1 | **F — decisions** | 1 | `docs/adr/0026-engine-invariants-outrank-frozen-plan.md` | — |
| 1 | **G — baseline fix** | 12 | `qa-kit/scripts/data-baseline.sh`, `tests/data-baseline/run.sh` | — |
| 2 | **H — ledger** | 6 | `skills/checkpointing-qa-memory/scripts/fold.sh`, `fold.jq`, `fold.py`, `tests/findings-ledger/run.sh` | A (classes), E (`findings` config) |
| 2 | **I — canary** | 7 | `skills/checkpointing-qa-memory/scripts/checkpoint.sh`, `tests/checkpoint/run.sh` | H (event registration) |
| 2 | **J — migration** | 11 | `qa-kit/scripts/migrate-inverted-criterion.sh`, `tests/qa-kit-enforcement/run.sh` | B (schema), C (rejection) |
| 3 | **K — authority** | 8 | `scripts/qa-verify.sh`, `tests/qa-verify/run.sh` | A, B, H |
| 3 | **L — CI surface** | 10 | `scripts/report-to-junit.sh`, `scripts/qa-ci.sh`, `tests/qa-ci-verify/run.sh` | H (anomalies), spec §5.7 contract |
| 4 | **M — process docs** | 13 | `qa-kit/commands/qa-analyze.md`, `qa-kit/commands/qa-spec.md`, `qa-kit/commands/qa-scenarios.md` | B, C, J |
| 4 | **N — enrolment** | 14 | `scripts/run-engine-ci.sh`, `qa-kit/scripts/run-qakit-ci.sh` | all |

**Tiered gates.** Task gate = the task's own targeted suite. Lane gate = every suite the lane owns.
Milestone gate (end of each wave) = `bash scripts/run-engine-ci.sh` plus
`bash qa-kit/scripts/run-qakit-ci.sh`. Do not run the full milestone gate per task.

---

### Task 1: ADR-0026 — engine invariants outrank the frozen plan   (Lane F, risk: normal)

**Files:**
- Create: `docs/adr/0026-engine-invariants-outrank-frozen-plan.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the decision every later task cites when a check overrides a criterion's own expectation.

**Exact values:** Title `Engine invariants outrank the frozen plan`. Status `Accepted`. Date
`2026-09-23`. Must reference ADR-0020 (`plan_frozen`) and ADR-0018 (out-of-agent evidence
enforcement) by number.

**Behaviour:**
- States the decision: `plan_frozen` scopes **what is checked**; it never grants a criterion the
  power to declare an application failure correct.
- Records the context: run `eval-counters-20260922b`, criterion `EC10`, `recompute.json` showing
  `{"oracle": false, "observed": false, "match": true}`.
- Records the consequence: `qa-verify.sh`'s new checks are run-scoped and may override or fail a run
  regardless of any criterion's recorded verdict.
- Follows the numbering and section shape of the existing ADRs in `docs/adr/`.

**Tests (write first):** none — documentation only.

**Task gate:** `test -s docs/adr/0026-engine-invariants-outrank-frozen-plan.md && grep -q "ADR-0020" docs/adr/0026-engine-invariants-outrank-frozen-plan.md`

---

### Task 2: `classify-finding.sh`   (Lane A, risk: high)

**Files:**
- Create: `scripts/classify-finding.sh`
- Test: `tests/classify-finding/run.sh`

**Interfaces:**
- Consumes: `.qa/config.json`'s `baseUrl` and `findings.benign[]`.
- Produces: `classify-finding.sh <config-path> <url> <status>` → two lines on stdout,
  `originClass=<in-scope|third-party|benign>` then `statusClass=<fatal|non-fatal>`; exit 0 on a
  successful classification, non-zero only on unusable arguments (missing config file, missing args).

**Exact values:**
- `originClass` values: `in-scope`, `third-party`, `benign`.
- `statusClass` values: `fatal`, `non-fatal`.
- `statusClass=fatal` iff `status >= 500`, or `status` is the literal `unhandled-exception`, or the
  literal `page-crash`.
- Config key path: `.findings.benign` — an array of POSIX-ERE regexes matched against the URL **path**.

**Behaviour:**
- Origin equal to `baseUrl`'s origin (scheme + host + port, default ports normalized) ⇒ `in-scope`.
- Origin different ⇒ `third-party`.
- Path matching any `findings.benign[]` regex ⇒ `benign` (checked after origin, so a benign rule can
  downgrade an in-scope path).
- **Fail-closed:** unparseable URL, absent `baseUrl`, a relative URL, or an absent `findings` block
  ⇒ `in-scope`. Never `third-party`, never `benign`.
- `jq` preferred with a `python3` fallback, honouring `QA_ENGINE`.
- Bash 3.2 safe.

**Tests (write first):**
- `test_origin_match_is_in_scope` — `baseUrl=https://app.test`, url `https://app.test/x`, 500 → `in-scope` + `fatal`
- `test_origin_mismatch_is_third_party` — url `https://cdn.other.test/beacon`, 403 → `third-party` + `non-fatal`
- `test_benign_allowlist_downgrades` — `findings.benign=["^/favicon\\.ico$"]`, url `https://app.test/favicon.ico`, 404 → `benign`
- `test_default_port_normalized` — `baseUrl=https://app.test`, url `https://app.test:443/x` → `in-scope`
- `test_unparseable_url_fails_closed` — url `not a url` → `in-scope`
- `test_missing_baseurl_fails_closed` — config without `baseUrl` → `in-scope`
- `test_relative_url_fails_closed` — url `/admin/x` → `in-scope`
- `test_absent_findings_block_fails_closed` — config with no `findings` key → `in-scope`
- `test_status_500_is_fatal` / `test_status_302_is_not_fatal` / `test_status_404_is_not_fatal`
- `test_unhandled_exception_literal_is_fatal` — status `unhandled-exception` → `fatal`
- `test_page_crash_literal_is_fatal` — status `page-crash` → `fatal`
- `test_python_engine_matches_jq_engine` — run the whole matrix under `QA_ENGINE=python3` and assert identical output

**Implementation notes:** normalize the origin before comparing — strip a trailing `:443` for
`https` and `:80` for `http`. Do **not** use `grep -P`; the repo's redaction layer is POSIX-ERE only
(`toolstream.sh:116-131`) and the same constraint applies here.

**Task gate:** `bash tests/classify-finding/run.sh`

---

### Task 3: validator rejects a criterion asserting application failure   (Lane C, risk: high)

**Files:**
- Modify: `skills/generating-qa-checklist/scripts/validate-checklist-json.sh`
- Test: `tests/validate-checklist-json/run.sh` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: additional `ERROR: entry[<i>].<field>: …` lines in the script's existing one-line-per-
  violation form; exit code semantics unchanged (0 iff no violations).

**Exact values:** the reserved-namespace table and the two prose phrases, both quoted verbatim in
Global Constraints. Error text for the structural case must name the path and end with the
remediation pointer `— move it to known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)`.

**Behaviour:**
- Reject `fixture.expect.path == "page.rendersWithoutServerError"` with `value` false (boolean
  `false` **or** the string `"false"` — the originating incident used the string).
- Reject `page.crashed` true, `console.hasError` true, and `http.status` with a numeric value `>= 500`.
- **Accept** `http.status` in the 3xx/4xx range — this carve-out has its own positive test and must
  not regress.
- Reject the two prose phrases, case-insensitively, when they appear in the oracle/expect fields.
  **Never** inspect `action` for them.
- All existing validations and their exit-code behaviour are unchanged.

**Tests (write first):**
- `test_rejects_renders_without_server_error_false_boolean`
- `test_rejects_renders_without_server_error_false_string` — the EC10 shape verbatim, including `"oracleSource": "human"` (**incident regression case 1**)
- `test_rejects_page_crashed_true`
- `test_rejects_console_has_error_true`
- `test_rejects_http_status_500`
- `test_accepts_http_status_302` — an authz-refusal criterion still validates
- `test_accepts_http_status_403` — ditto
- `test_rejects_prose_expected_to_fail_in_oracle`
- `test_rejects_prose_deferred_by_design_in_oracle`
- `test_accepts_prose_in_action_field` — `action` containing "does not render until the challenge reaches Judging" validates cleanly
- `test_error_line_names_entry_index_and_field`
- `test_existing_validations_unchanged` — the suite's pre-existing fixtures still pass

**Implementation notes:** the string-vs-boolean `false` case is the one that actually occurred; test
both or the regression case does not bite.

**Task gate:** `bash tests/validate-checklist-json/run.sh`

---

### Task 4: `known-defects.sh`   (Lane B, risk: high)

**Files:**
- Create: `scripts/known-defects.sh`
- Test: `tests/known-defects/run.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `known-defects.sh validate <path>` → exit 0 iff every entry is well-formed; one
    `ERROR: entry[<i>].<field>: …` line per violation otherwise.
  - `known-defects.sh status <path> <today-YYYY-MM-DD>` → JSON array of
    `{"id":…, "state":"outstanding"|"expired"|"cleared"}`; exit 0.

**Exact values:**
- Required fields: `id`, `title`, `ticket`, `expiry`, `severity`, `observedClass`, `surface`,
  `observedBehaviour`. Optional: `observedStatus`.
- `observedClass` enum: `non-rendering`, `wrong-value`, `degraded`.
- `severity` enum: `low`, `medium`, `high`, `critical`.
- Expiry cap: **90 days** from `today`.
- Floor rule: `observedClass == "non-rendering"` ⇒ `severity` must be `high` or `critical`.
- Registry path: `.qa/known-defects.json` (project-level, **not** per-spec).

**Behaviour:**
- `validate` rejects: a missing or empty `ticket`; a missing `expiry`; an `expiry` that is not
  `YYYY-MM-DD`; an `expiry` more than 90 days after `today`; an `observedClass` outside the enum; a
  `severity` below the floor for `non-rendering`; a duplicate `id`.
- `status` marks an entry `expired` when `expiry < today`.
- `status` marks an entry `cleared` **only** when passed evidence that its `surface` was driven with
  a 2xx and produced no fatal finding. **Absence of a finding never clears.** With no evidence
  supplied, the entry stays `outstanding`.
- An empty array `[]` is valid (vacuously).
- Exits non-zero on **every** reported error — never exit 0 while printing errors.

**Tests (write first):**
- `test_valid_entry_passes`
- `test_missing_ticket_rejected` / `test_empty_ticket_rejected`
- `test_missing_expiry_rejected` / `test_malformed_expiry_rejected`
- `test_expiry_beyond_90_days_rejected` — `today` `2026-09-23`, expiry `2026-12-31`
- `test_expiry_at_exactly_90_days_accepted` — boundary
- `test_non_rendering_below_high_rejected` — `observedClass: non-rendering`, `severity: low` (**the originating incident's severity**)
- `test_non_rendering_high_accepted`
- `test_observed_class_outside_enum_rejected`
- `test_duplicate_id_rejected`
- `test_empty_array_valid`
- `test_status_expired_when_past_expiry`
- `test_status_outstanding_when_surface_not_driven` — no evidence → `outstanding`, **not** `cleared`
- `test_status_cleared_requires_2xx_navigation` — evidence of a 2xx to `surface` and no fatal finding → `cleared`
- `test_status_not_cleared_when_navigation_absent_but_no_finding` — the dangerous case: silence ≠ fixed
- `test_validate_exit_code_nonzero_on_error` — guards against the `data-baseline.sh` bug class
- `test_python_engine_matches_jq_engine`

**Implementation notes:** date arithmetic must work on macOS `date` (BSD) and GNU `date`. The repo
has no existing helper; compute day counts in the jq/python3 layer rather than shelling to `date -d`,
which is GNU-only.

**Task gate:** `bash tests/known-defects/run.sh`

---

### Task 5: reorder the observe payload so the 4KB cap stops eating findings   (Lane D, risk: high)

**Files:**
- Modify: `skills/driving-browser-qa/scripts/observe.js` (payload construction at `:160-166`;
  `interactive` element build near `:137`)
- Test: `tests/capture-hook/run.sh` (extend)

**Interfaces:**
- Consumes: nothing.
- Produces: `__qaObserve()` returns the same **keys** in a new **order**:
  `{round, console, network, domDigest, ux, axe}`. Consumers read by key, so no caller changes.

**Exact values:**
- New key order: `round`, `console`, `network`, `domDigest`, `ux`, `axe`.
- `testid` capped at **64** characters; `href` capped at **128** characters. (`label` keeps its
  existing 40-character cap; `liveText` keeps 1500.)
- `capture-hook.sh`'s `RESPONSE_BODY_CAP` stays **4000** — do not change it.

**Behaviour:**
- `console[]` and `network[]` are serialized **before** `domDigest`, so a `head -c 4000` truncation
  loses the DOM digest rather than the findings.
- `interactive[]` entries have `testid` and `href` length-capped (they are uncapped today).
- The `splice(0)` drain semantics and every existing field are otherwise unchanged.
- No change to what is captured — only to serialization order and two length caps.

**Tests (write first):**
- `test_payload_key_order_console_before_domdigest` — parse the emitted JSON text and assert the byte offset of `"console"` is lower than that of `"domDigest"`
- `test_findings_survive_4000_byte_cap_at_80_elements` — build a worst-case payload (80 interactive elements, 1500-char `liveText`, realistic testids/hrefs) plus one console error and one 500; truncate at 4000 bytes as `capture-hook.sh` does; assert both the console error and the 500 are still present
- `test_testid_capped_at_64`
- `test_href_capped_at_128`
- `test_existing_capture_hook_cases_unchanged` — the suite's pre-existing cases still pass, including the 20,000-byte truncation assertion at `tests/capture-hook/run.sh:58-69`

**Implementation notes:** JavaScript object literals preserve insertion order for string keys, and
`JSON.stringify` follows it — so the reorder is purely the order of the properties in the literal at
`:160-166`. Verify with a byte-offset assertion rather than trusting that.

**Task gate:** `bash tests/capture-hook/run.sh`

---

### Task 6: findings ledger — keyed-set journal events   (Lane H, risk: high)

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/fold.sh` (`KNOWN_EVENTS_JSON` at `:59` **and** the
  duplicated Python set at `:102-105`)
- Modify: `skills/checkpointing-qa-memory/scripts/fold.jq`
- Modify: `skills/checkpointing-qa-memory/scripts/fold.py`
- Test: `tests/findings-ledger/run.sh` (create)

**Interfaces:**
- Consumes: `classify-finding.sh`'s `originClass` / `statusClass` values (Task 2).
- Produces: the `finding_observed` event contract, and `checkpoint.json` gaining a `findings` array
  of deduplicated entries in first-seen order.

**Exact values:**
- New event names to register in **both** engines: `finding_observed`, `capture_probed`.
- Event fields: `event`, `findingKey`, `criterionId`, `source` (`network`|`console`), `channel`
  (`driver-log`|`in-page`), `method`, `url`, `status`, `originClass`, `statusClass`, `message`,
  `detailRef`.
- `findingKey` format: `<criterionId>|<source>|<method>|<url>|<status>`.
- `message` cap: **200** characters.
- Reserved names the event must NOT carry: `seq`, `t`, `childId`, `childSeq`.

**Behaviour:**
- Registering the events in both engines is mandatory: `journal.sh` accepts any non-empty `event`
  string (`:266`), so an unregistered event appends successfully and is then silently discarded by
  the fold as an `unknown-event` anomaly.
- The fold reduces findings with **keyed-set** semantics on `findingKey` — the pattern at
  `fold.jq:56-63` (`openActs`), **not** the last-wins tuple pattern at `:117`. A repeated
  `findingKey` collapses; it never accumulates.
- First-seen order is preserved.
- Console findings set `method` and `url` to the empty string and key on a normalized, capped
  `message` instead.
- The same `findingKey` under two different `criterionId`s is two distinct findings — breadth is
  signal, and the key includes `criterionId` for exactly that reason.
- `fold.py` mirrors `fold.jq` exactly; `tests/fold/run.sh`'s dual-engine parity expectation applies.

**Tests (write first):**
- `test_finding_observed_registered_in_jq_engine` — an event is folded, not reported as `unknown-event`
- `test_finding_observed_registered_in_python_engine` — same under `QA_ENGINE=python3`
- `test_capture_probed_registered_in_both_engines`
- `test_duplicate_finding_key_collapses` — the same key appended twice yields **one** entry
- `test_resume_does_not_double_count` — append F1,F2,F3; simulate an interruption; re-append F2,F3 with a fourth F4; assert exactly 4 findings
- `test_same_key_different_criterion_is_two_findings`
- `test_first_seen_order_preserved`
- `test_console_finding_keys_on_message`
- `test_message_capped_at_200_chars`
- `test_event_stays_under_pipe_buf` — serialize a worst-case event and assert `< 4096` bytes
- `test_event_carries_no_reserved_field_names`
- `test_jq_and_python_folds_agree` — identical `findings` array from both engines

**Implementation notes:** `fold.jq:56-63` is the model — it tracks a `seen` set and skips a key
already present. Copy that shape rather than inventing a reducer. Do not add a count field; the set
*is* the answer, and a count would re-introduce the double-counting this task exists to prevent.

**Task gate:** `bash tests/findings-ledger/run.sh && bash tests/fold/run.sh`

---

### Task 7: `capture_probed` once-guard   (Lane I, risk: normal)

**Files:**
- Modify: `skills/checkpointing-qa-memory/scripts/checkpoint.sh` (the journal-emptiness guard at
  `:1024-1031`)
- Test: `tests/checkpoint/run.sh` (extend)

**Interfaces:**
- Consumes: the `capture_probed` event registration (Task 6).
- Produces: exactly one `capture_probed` event per run, carrying
  `{"event":"capture_probed","channel":"toolstream"|"driver-log"|"none"}`.

**Exact values:** `channel` values `toolstream`, `driver-log`, `none`.

**Behaviour:**
- Emitted behind the **same** journal-emptiness guard that emits `run_started`, so it fires exactly
  once per run and **never re-fires on resume**.
- `channel: toolstream` when a toolstream line for this run already exists; `driver-log` when
  `session-preflight.sh` can resolve a session log; `none` when neither.
- `channel: none` is not an error here — it is the input to `UNVERIFIED` (Task 10).
- Must NOT be placed in the agent's Phase 0 pre-flight: `commands/qa-resume.md` dispatches a resumed
  run into its recorded phase, "not from Pre-flight", so a Phase-0 assertion is silently skipped on
  every resume.

**Tests (write first):**
- `test_capture_probed_emitted_once_on_fresh_run`
- `test_capture_probed_not_reemitted_on_resume` — append to a non-empty journal; assert still exactly one
- `test_channel_toolstream_when_toolstream_present`
- `test_channel_driver_log_when_session_log_resolvable`
- `test_channel_none_when_neither` — and assert this is **not** an error exit
- `test_existing_checkpoint_cases_unchanged`

**Task gate:** `bash tests/checkpoint/run.sh`

---

### Task 8: `qa-verify.sh` — four run-scoped checks   (Lane K, risk: high)

**Files:**
- Modify: `scripts/qa-verify.sh`
- Test: `tests/qa-verify/run.sh` (extend)

**Interfaces:**
- Consumes: `classify-finding.sh` (Task 2), `known-defects.sh status` (Task 4), the
  `finding_observed` contract (Task 6).
- Produces: `verification.json` gaining a `runChecks` object
  `{"ledgerComplete":bool,"classificationsAgree":bool,"loadWindowCovered":bool,"knownDefectsOk":bool}`,
  and `run_failed` set when any is false.

**Exact values:** synthetic record id `__run-checks__`, following the existing `__phase-surface__`
precedent (`qa-verify.sh:940`) — but, unlike it, this record **does** flip the exit code.

**Behaviour:**
- **Ledger completeness.** Recompute the expected finding set from the driver network log and from
  `__qaObserve` payloads in the toolstream; a finding present in either channel and absent from the
  journal ⇒ override the run.
- **Classification re-check.** Re-run `classify-finding.sh` per journaled finding; a mismatch ⇒
  override.
- **Load-window coverage (R9).** Fail a run in which a `browser_navigate` event is not followed by a
  `browser_network_requests` event before the next navigation. Uses only the `tool` field — never
  `responseBody` — so the 4000-byte cap and `responseBody: null` harnesses are irrelevant.
- **Known-defect gate.** Any `expired` entry fails the run; any entry failing `known-defects.sh
  validate` fails the run.
- All four are **run-scoped**, evaluated regardless of any criterion's verdict — the existing pass
  re-check loop only visits `verdict == "pass"` records, which is why `EC10` was never re-examined.
- When neither channel is available, the checks do not fail the run; they set `channel: none`, which
  Task 10 turns into `UNVERIFIED`. Distinguish "no evidence" from "contradicted evidence".

**Tests (write first):**
- `test_ledger_complete_passes_when_journal_matches`
- `test_missing_finding_overrides_run` — driver log holds a navigation 500, the journal omits it (**incident regression case 2**)
- `test_misclassified_finding_overrides_run` — journal says `third-party` for a `baseUrl`-origin URL
- `test_navigate_without_followup_fails` — a `browser_navigate` with no `browser_network_requests` before the next navigation (**incident regression case 3**)
- `test_navigate_with_followup_passes`
- `test_two_navigations_each_need_followup`
- `test_expired_known_defect_fails_run`
- `test_outstanding_known_defect_does_not_fail_run`
- `test_run_checks_evaluated_when_all_verdicts_are_fail` — the `EC10` shape: no `pass` records at all, checks still run
- `test_no_channel_does_not_fail_but_marks_none`
- `test_existing_qa_verify_cases_unchanged`

**Implementation notes:** the load-window check needs only the ordered `tool` sequence from
`toolstream.jsonl`. Build it with a single jq pass over `.tool`; do not parse `responseBody` for
this check or it inherits every limitation the spec's §11 documents.

**Task gate:** `bash tests/qa-verify/run.sh`

---

### Task 9: config persistence — write `findings`, preserve unknown keys   (Lane E, risk: data)

**Files:**
- Modify: `skills/bootstrapping-qa-config/scripts/init-config.sh` (the `jq -n` object at `:97-137`;
  the write at `:137`/`:151`)
- Modify: `.qa/config.json.example`
- Test: `tests/init-config/run.sh` (extend)

**Interfaces:**
- Consumes: nothing.
- Produces: `.qa/config.json` gaining `findings: { benign: [] }`, and a re-render that no longer
  destroys unknown top-level keys.

**Exact values:** new block `"findings": { "_doc": "…", "benign": [] }`. `benign` entries are
POSIX-ERE regexes matched against a URL path.

**Behaviour:**
- `findings` is written on a fresh bootstrap with an empty `benign` array (fail-closed: no waivers
  by default).
- **Re-rendering preserves unknown top-level keys.** Today the script renders fresh and `mv -f`s over
  the destination, silently destroying any key it does not itself emit — which already loses the six
  keys `.qa/config.json.example` documents but the writer never emits: `viewport`,
  `responsiveMatrix`, `persona`, `detection`, `passGate`, `fixtures`.
- Keys the script **does** own are still authoritative and overwritten as before.
- The existing fail-closed write path (temp file, `jq -e .` validation, then `mv`) is unchanged.
- `.qa/config.json.example` documents the `findings` block in the same `_doc` style as `enforcement`.

**Tests (write first):**
- `test_fresh_bootstrap_writes_findings_block`
- `test_findings_benign_defaults_empty`
- `test_unknown_top_level_key_survives_rerender` — add `"myCustomKey": {"a":1}`, re-run, assert it is still present
- `test_six_documented_keys_survive_rerender` — `viewport`, `responsiveMatrix`, `persona`, `detection`, `passGate`, `fixtures`
- `test_owned_keys_still_overwritten` — a hand-edited `maxParallel` is reset by a re-run
- `test_personas_key_survives` — written by `write-persona-config.sh`, never by this script
- `test_output_still_valid_json`
- `test_existing_init_config_cases_unchanged`

**Implementation notes:** read the existing file (if any) first and merge the freshly-rendered
object **over** it, rather than replacing it — a shallow `$existing + $new` in jq, which is the same
shape `qa-kit/scripts/runconfig-merge.sh:40-44` already uses for its deltas.

**Task gate:** `bash tests/init-config/run.sh`

---

### Task 10: `UNVERIFIED` reaches the CI exit code   (Lane L, risk: high)

**Files:**
- Modify: `scripts/report-to-junit.sh` (counts at `:209-212`; testsuite properties at `:223-229`)
- Modify: `scripts/qa-ci.sh` (the `QA_SKIP_VERIFY` branch at `:118-119`; the gate at `:152-158`)
- Test: `tests/qa-ci-verify/run.sh` (extend)

**Interfaces:**
- Consumes: `capture_probed`'s `channel` (Task 7), fold anomalies (Task 6).
- Produces: a synthetic JUnit `<testcase name="__run-verified__">` carrying `<failure>` when the run
  is `UNVERIFIED`; `qa.verified="false"` unchanged.

**Exact values:** testcase name `__run-verified__`. Failure message prefix
`UNVERIFIED — `. Reasons: `no independent capture`, `verification skipped (QA_SKIP_VERIFY)`,
`run record damaged (<anomaly>)`.

**Behaviour:**
- A run is `UNVERIFIED` when: `capture_probed.channel == "none"`; **or** `QA_SKIP_VERIFY=1` was set;
  **or** the fold reports `unparseable-line` or `seq-gap`.
- `UNVERIFIED` synthesizes a `<testcase>` + `<failure>`, which reaches
  `sys.exit(1 if (failures or errors) else 0)` at `:395`. The existing `<properties>` route cannot —
  which is why this must not be implemented there.
- `QA_SKIP_VERIFY=1` no longer buys a green build: it is logged **and** marks the run `UNVERIFIED`.
- The report's headline becomes `UNVERIFIED — <reason>` with the tally printed beneath it.
- The other four fold anomalies (`illegal-edge`, `cross-child-duplicate`, `duplicate-plan-frozen`,
  `verdict-without-started`) are surfaced as a count only and do **not** mark the run unverified.
- Per-criterion `confidence: low` semantics are unchanged.

**Tests (write first):**
- `test_unverified_produces_nonzero_exit`
- `test_unverified_synthesizes_junit_failure_case`
- `test_qa_skip_verify_marks_unverified` — `QA_SKIP_VERIFY=1` no longer exits 0
- `test_channel_none_marks_unverified`
- `test_unparseable_line_marks_unverified`
- `test_seq_gap_marks_unverified`
- `test_illegal_edge_does_not_mark_unverified` — counted only
- `test_verified_run_exit_code_unchanged`
- `test_failure_message_names_the_reason`
- `test_existing_qa_ci_cases_unchanged`

**Task gate:** `bash tests/qa-ci-verify/run.sh`

---

### Task 11: `migrate-inverted-criterion.sh`   (Lane J, risk: normal)

**Files:**
- Create: `qa-kit/scripts/migrate-inverted-criterion.sh`
- Test: `tests/qa-kit-enforcement/run.sh` (extend)

**Interfaces:**
- Consumes: the registry schema (Task 4), the validator's rejection (Task 3).
- Produces: `migrate-inverted-criterion.sh <checklist.json> <criterion-id> [--known-defects <path>]`
  → removes the criterion, appends a registry entry, prints required fields, **exits 2**.

**Exact values:** default registry path `.qa/known-defects.json`. Exit code **2** for "written,
human input required". Generated `id` format `KD-<n>` where `<n>` is one past the highest existing.

**Behaviour:**
- Removes the named criterion from `checklist.json` and writes the file atomically.
- Appends an entry with `ticket: ""` and `expiry: ""` and everything else derived from the criterion
  (`title` from the criterion's `action`, `surface` from its `surface`, `observedClass` defaulted to
  `non-rendering` when the expect path is in the reserved health namespace).
- Prints exactly which fields a human must supply, then **exits non-zero** — a known defect with no
  owner and no deadline is "deferred by design" renamed.
- **Never** rewrites anything under `.qa/runs/` — history is read-only.
- Idempotent: re-running for an id already migrated is a no-op that still exits 2.

**Tests (write first):**
- `test_removes_criterion_from_checklist`
- `test_appends_registry_entry_with_empty_ticket_and_expiry`
- `test_exits_nonzero_pending_human_input` — assert exit code 2 exactly
- `test_prints_required_fields`
- `test_derives_observed_class_from_reserved_path`
- `test_generated_id_increments`
- `test_does_not_touch_runs_directory` — snapshot `.qa/runs/` before and after
- `test_rerun_is_idempotent`
- `test_resulting_checklist_passes_validator` — round-trip against Task 3's validator

**Task gate:** `bash tests/qa-kit-enforcement/run.sh`

---

### Task 12: fix `data-baseline.sh` exiting 0 while printing errors   (Lane G, risk: normal)

**Files:**
- Modify: `qa-kit/scripts/data-baseline.sh`
- Test: `tests/data-baseline/run.sh` (extend)

**Interfaces:**
- Consumes: nothing.
- Produces: `data-baseline.sh validate <path>` exit code now reflects the reported errors.

**Exact values:** none beyond the existing `{errors:[…]}` output shape.

**Behaviour:**
- `validate` exits non-zero whenever its `errors` array is non-empty. It currently exits 0 while
  printing them, which hid a malformed baseline during the originating incident.
- The printed JSON shape is unchanged — only the exit code changes.
- Every existing caller that relied on exit 0 must be checked; `/qa-spec`'s step 6 already documents
  "abort and surface `{errors:[…]}` on nonzero", so the documented contract is what this restores.

**Tests (write first):**
- `test_validate_exits_nonzero_when_errors_present`
- `test_validate_exits_zero_when_clean`
- `test_error_json_shape_unchanged`
- `test_scope_object_requirement_still_enforced` — the existing rule that `scope` must be an object
- `test_existing_data_baseline_cases_unchanged`

**Task gate:** `bash tests/data-baseline/run.sh`

---

### Task 13: qa-kit process changes   (Lane M, risk: normal)

**Files:**
- Modify: `qa-kit/commands/qa-analyze.md`
- Modify: `qa-kit/commands/qa-spec.md`
- Modify: `qa-kit/commands/qa-scenarios.md`

**Interfaces:**
- Consumes: the registry (Task 4), the validator (Task 3), the migration script (Task 11).
- Produces: no script interface — process documentation only.

**Exact values:** new gap category name `plan-defect`. The demoted prose signals it surfaces:
`known defect`, `not a regression`.

**Behaviour:**
- `/qa-analyze` gains a sixth category, `plan-defect`, printed **above** the verdict line — not
  inside it. Its existing five categories (coverage / role / oracle / risk / data) had nowhere to put
  an inverted oracle, so `EC10` landed under *Risk gaps* and was blessed while the same document
  reported "oracle gaps: 0".
- The "advisory only — the run is not blocked" charter is explicitly carved out for `plan-defect`.
- `/qa-spec` and `/qa-scenarios` instruct the author to write a `known-defects.json` entry where they
  would previously have authored a criterion expecting a failure, and to run
  `migrate-inverted-criterion.sh` for an existing one.
- Each file keeps its existing structure and voice; these are additions, not rewrites.

**Tests (write first):** none — documentation. Verified by Task 14's skill-gate consistency suite.

**Task gate:** `bash tests/skill-gate-consistency/run.sh`

---

### Task 14: CI enrolment   (Lane N, risk: normal)

**Files:**
- Modify: `scripts/run-engine-ci.sh` (`SUITES` array)
- Modify: `qa-kit/scripts/run-qakit-ci.sh` (`SUITES` array)

**Interfaces:**
- Consumes: every suite created or extended above.
- Produces: the milestone gate.

**Exact values:** add to `scripts/run-engine-ci.sh`'s `SUITES`: `classify-finding`,
`findings-ledger`, `known-defects`. The extended suites (`validate-checklist-json`, `qa-verify`,
`qa-ci-verify`, `init-config`, `capture-hook`, `checkpoint`, `fold`, `skill-gate-consistency`) are
**already enrolled** — do not add duplicates. `qa-kit/scripts/run-qakit-ci.sh` already enrols
`data-baseline` and `qa-kit-enforcement`; confirm rather than re-add.

**Behaviour:**
- The two `SUITES` arrays are **separate lists**; enrolling in one does not enrol in the other.
- Every new suite finishes standalone well inside the existing `timeout 120` backstop.
- After enrolment both CI runners are green.

**Tests (write first):**
- `test_new_suites_present_in_engine_ci` — grep each of the three names in `run-engine-ci.sh`
- `test_no_duplicate_suite_entries` — each name appears exactly once across both arrays

**Task gate:** `bash scripts/run-engine-ci.sh && bash qa-kit/scripts/run-qakit-ci.sh`

---

## Self-review

**Spec coverage.** §3 I1→Tasks 6+8; I1a→7; I1b→10; I2→2; I3→3; I4→4; I5→8. §4 two-axis rule→2
(`statusClass`) + 8. §4.1→3. §5.1→6. §5.2→2. §5.3→4. §5.4 channel 1→5, channel 2→8, R8→10.
§5.5→8. §5.6→7. §5.7→10. §5.8→9. §5.9→11+13. §5.10→10. §7 `data-baseline.sh`→12. §8→every task's
Tests block, with the three incident cases in Tasks 3, 8, 8. §10 migration→11. ADR→1. No spec
section is unimplemented.

**Interface-name consistency.** `originClass`/`statusClass` (Task 2) are consumed by Tasks 6 and 8
under those exact names. `findingKey` (Task 6) is used by Task 8. `channel` (Task 7) is consumed by
Task 10. `known-defects.sh status`'s `state` values (Task 4) are consumed by Task 8. Registry path
`.qa/known-defects.json` is identical in Tasks 4, 11 and 13.

**Lane ownership.** Every file appears in exactly one lane. `tests/capture-hook/run.sh` is Lane D
only (Task 5); `scripts/capture-hook.sh` itself is modified by **no** task — the cap stays at 4000
per R7, and Task 5 works around it rather than changing it. `fold.sh`/`fold.jq`/`fold.py` are Lane H
only. `scripts/qa-verify.sh` is Lane K only. `scripts/report-to-junit.sh` and `scripts/qa-ci.sh` are
Lane L only.

**Placeholders.** None — every task names exact paths, exact values and a concrete task gate.
