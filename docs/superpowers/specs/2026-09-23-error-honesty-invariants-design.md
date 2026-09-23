# Error-honesty invariants — design

**Status:** approved 2026-09-23. Supersedes nothing; extends ADR-0010, ADR-0018, ADR-0020, ADR-0021.
**Companion decision record:** `docs/adr/0026-engine-invariants-outrank-frozen-plan.md` — to be
authored as the first task of the implementation plan, not yet present in the tree.

## 1. The incident this exists because of

A QA run against a Laravel app (`innovation`, spec `evaluation-counters`, run
`eval-counters-20260922b`) verified four merged bug fixes. One criterion, `EC10`, was authored with
this pinned expectation:

```json
"expect": {
  "path": "page.rendersWithoutServerError",
  "value": "false",
  "tolerance": 0,
  "oracleSource": "human"
}
```

The page under test returned **HTTP 500** — an unhandled `ValueError` from an enum cast rejecting a
legacy database value, taking down the whole gates surface for an authorized admin. The run observed
exactly that, and its `recompute.json` recorded:

```json
{ "oracle": false, "observed": false, "match": true }
```

The comparison **succeeded**. The run then logged it as `BUG-1` with `severity: "low"` and
`fix: "Deferred by design … Not actionable within this QA pass's scope"`, and `/qa-analyze` filed it
under *Risk gaps* as "Known live defect acknowledged" while reporting **oracle gaps: 0**.

Nothing malfunctioned. Every component did what it was told. The plan said a crash was the correct
answer, so a crash was graded correct.

### 1.1 What was NOT the problem

Capture. `skills/driving-browser-qa/scripts/observe.js` already installs read-only interceptors on
`console.error`/`warn`, `window.onerror`, `unhandledrejection`, `fetch` and `XMLHttpRequest`, and
returns `{round, domDigest, console[], network[], ux[], axe}` with every request carrying
`{method, url, status, ok}`. The 500 was captured, screenshotted, read back from the database and
written to the bug log.

The doctrine was not missing either. `skills/driving-browser-qa/SKILL.md:10` already says to treat
console exceptions and unexpected HTTP errors "as findings, not noise", `:178` repeats it
"regardless of whether the DOM digest looks clean", `:222` says "5xx = likely a server bug. Both are
findings", and `skills/analyzing-feature-ui/SKILL.md:75` says to "confirm an error state **is
rendered**, not a blank screen."

**Capture is mechanical. Disposition was discretionary.** The payload was handed to an agent, and the
agent decided what it meant. That is the entire defect.

### 1.2 The second, quieter failure

That run produced **no `toolstream.jsonl` at all**. `.qa/config.json` declared
`enforcement.captureHook: true`, but the hook is only live if `scripts/capture-hook.sh` is registered
as a PostToolUse hook in the harness settings — and **nothing in the repo checks that it is**
(`scripts/check-prereqs.sh` contains no reference to `settings.json` or `PostToolUse`).

So enforcement was configured, reported as enabled, and inert. Its only consequence was a per-pass
`confidence: low` stamp — and the run still presented as **10 pass / 1 fail**, which was read, by
both the report's author and its reader, as a successful verification.

An enforcement layer that can be silently absent is not an enforcement layer.

## 2. Principle

**Take disposition away from the agent.**

This repo already has the pattern. `scripts/qa-verify.sh` is an out-of-agent, deterministic authority
that re-checks every recorded `pass` against the capture-hook toolstream — a trust domain the run's
agent never writes to — and overrides a forged one. It never trusts a row's own `requiredKinds`; it
re-derives them with `required-kinds.sh`.

We extend that pattern. We do not build parallel machinery.

## 3. Invariants

| | Invariant | Enforced by |
|---|---|---|
| **I1** | No observed error is dropped, whether or not it relates to the criterion under test | `qa-verify.sh` recomputes the finding set from `toolstream.jsonl` and overrides a run whose journal omits one |
| **I1a** | Capture is proven live, not merely configured | new pre-flight canary assertion; `enforcement.captureHook: true` is a claim, a written toolstream line is evidence |
| **I1b** | Without independent capture, a run may not present as clean | run-level status `UNVERIFIED — no independent capture`, replacing the per-pass `confidence: low` as the headline consequence |
| **I2** | Disposition is deterministic | new `scripts/classify-finding.sh` — request origin vs `baseUrl`, plus a git-tracked allowlist; fail-closed |
| **I3** | A criterion may never assert that the application failed | `validate-checklist-json.sh` rejects it structurally, with assisted migration |
| **I4** | A known defect cannot be presented as green | `known-defects.json` + `scripts/known-defects.sh`: ticket, expiry and severity floor all required |

I1 is load-bearing. `scripts/capture-hook.sh` appends `{tool, args, resultDigest, responseBody}` and
records `browser_*` tool responses **in full** (only `Bash` args and output are redacted). The
`browser_evaluate` result carrying each `__qaObserve` payload therefore lands verbatim in the
toolstream, so the finding set is **independently recomputable from a domain the agent cannot
forge**. That is a guarantee rather than a reminder.

## 4. The line between a working app and a failing one

The rule cannot be "no criterion may expect an error status". Legitimate criteria do expect them:
`EC9` and `EC11` in the originating spec both assert an authorization refusal, which this app
implements as a **302 redirect** to the persona's own dashboard (`UserTypeMiddleware` does not
abort). A validator that rejected those would be useless, and a useless validator gets switched off.

The line:

> **A 3xx or 4xx can be correct behaviour. A 5xx, an unhandled exception, or a page crash never can.**

An authorization refusal, a validation rejection, a 404 on a deleted record — these are the
application *working*, and a criterion may assert them. A 500, an unhandled exception page, or a
load-time crash is the application *failing*, and no criterion may assert it as correct. This
matches the engine's existing doctrine: an error state that **renders** is a feature; a stack trace
is not.

### 4.1 Detection (two layers)

**Structural — a reserved health namespace.** These `expect.path` values describe whole-page or
transport health rather than a domain value, and may not be pinned to a failing value:

| `expect.path` | Rejected when |
|---|---|
| `page.rendersWithoutServerError` | `value` is `false` |
| `page.crashed` | `value` is `true` |
| `http.status` | `value` >= 500 |
| `console.hasError` | `value` is `true` |

A `http.status` in the 3xx/4xx range stays legal — that is the carve-out of §4. Paths outside this
namespace are untouched; a domain assertion like `counts.evaluators = 2` is unaffected.

**Prose.** A criterion whose `action` text or oracle line contains `expected to fail`,
`does not render`, `known defect`, `deferred by design`, or `not a regression` is rejected with a
pointer to `known-defects.json`. This is a secondary net for the case where an author reaches for a
path outside the reserved namespace to say the same thing.

Both layers emit the validator's existing one-line-per-violation form
(`ERROR: entry[<i>].<field>: …`), naming the offending entry index and field.

## 5. Components

### 5.1 Findings ledger — a projection, not a file format

A finding is **a journal event**, not a new artifact. `skills/checkpointing-qa-memory/scripts/journal.sh
append <run-id> <event-json>` is already append-only, `seq`-stamped, time-stamped and atomically
written (ADR-0017). Event shape:

```json
{
  "event": "finding_observed",
  "findingId": "F1",
  "criterionId": "EC6",
  "round": 3,
  "source": "network",
  "method": "GET",
  "url": "https://innovation.ddev.site/admin/evaluations/challenges/1?tab=gates",
  "status": 500,
  "class": "in-scope",
  "classifiedBy": "classify-finding.sh"
}
```

`criterionId` records *when* the finding was seen, never *whose fault* it is — a finding observed
during `EC6` that belongs to an unrelated surface is still a finding. There is no field by which a
finding can be dismissed as unrelated.

`findings.json` is rendered **from** the journal for the report and is never a source of truth. This
is what makes "nothing can be deleted, only classified" structural: the substrate is append-only, so
a later classification is a new event, and the original observation remains.

### 5.2 `scripts/classify-finding.sh` (new, deterministic, no LLM)

```
classify-finding.sh <config-path> <url> <status>
  → prints exactly one of: in-scope | third-party | benign
```

| Condition | Class |
|---|---|
| URL origin equals the effective `baseUrl` origin | `in-scope` |
| URL origin differs from the `baseUrl` origin | `third-party` |
| URL path matches a `findings.benign[]` regex from `.qa/config.json` | `benign` |
| Anything else — unparseable URL, missing `baseUrl`, relative URL of unknown origin | **`in-scope`** |

The last row is the design: **fail-closed**. An input the classifier cannot reason about is treated
as the application's own failure, never waved through. The allowlist lives in `.qa/config.json`
(written by `skills/bootstrapping-qa-config/scripts/init-config.sh` alongside the existing
`enforcement` block), so every waiver is human-authored, git-tracked and reviewable in a diff.

Only `in-scope` findings fail a run. `third-party` and `benign` are recorded, reported and counted —
never discarded.

### 5.3 `scripts/known-defects.sh` + `.qa/known-defects.json` (new)

```
known-defects.sh validate <path>          # schema + severity floor + required fields
known-defects.sh status <path> <today>    # per entry: outstanding | expired | cleared
```

Entry schema, every field required:

```json
{
  "id": "KD-1",
  "title": "stage_gate_reviews.status='completed' rejected by StageGateReviewStatus",
  "ticket": "z8tvbhteuc",
  "expiry": "2026-10-07",
  "severity": "high",
  "surface": "/admin/evaluations/challenges/{challenge}?tab=gates",
  "observedBehaviour": "HTTP 500, unhandled ValueError"
}
```

- **`ticket` and `expiry` cannot be auto-filled.** `migrate-inverted-criterion.sh` deliberately exits
  non-zero after writing the entry, demanding both from a human. A known defect with no owner and no
  deadline is the "deferred by design" disposition under a new name.
- **Severity floor.** A defect whose `observedBehaviour` indicates a non-rendering surface
  (5xx / unhandled exception / crash) may not be recorded below `high`. This is the check that would
  have rejected `severity: "low"` on the originating incident.
- **Never a verdict.** A known defect is not a criterion. It has no `pass`/`fail`, contributes
  nothing to the tally, and cannot be counted as verification of anything.
- **Run status.** While an entry is `outstanding`, the run's top line reads
  `GREEN with N known defects`. Past `expiry`, the entry is `expired` and **blocks** the run.
- **Auto-clear.** If the run drives the entry's `surface` and observes no matching finding, the entry
  is reported `cleared` — the defect stops reproducing without anyone editing a file, so a stale
  waiver cannot keep a fixed defect on the books.

### 5.4 `scripts/qa-verify.sh` (extended)

Three additions, in the existing out-of-agent, jq/python3-only style:

1. **Ledger completeness (I1).** Re-scan `toolstream.jsonl` for every recorded `browser_evaluate`
   response containing an `__qaObserve` payload; extract each `console[]` error and each `network[]`
   entry with `ok: false`; recompute the expected finding set; compare against
   `finding_observed` events in the journal. A finding present in the toolstream and absent from the
   journal is a dropped-error signal → **override the run**. This is the mechanism that makes I1
   unforgeable, and it deliberately mirrors step 1's existing dropped-kind re-derivation.
2. **Classification re-check (I2).** Re-run `classify-finding.sh` over each journaled finding and
   override any classification that does not match the deterministic result. The agent cannot
   mis-class a 500 even by writing a journal event that says otherwise.
3. **Known-defect gate (I4).** Run `known-defects.sh status`; any `expired` entry fails the run,
   and any entry below its severity floor fails validation.

`qa-verify.sh` currently re-checks only records whose `verdict == "pass"`. That is precisely why
`EC10`, recorded `fail`, was never re-examined by anything. The three checks above are **run-scoped**,
not pass-scoped, and run regardless of any criterion's verdict.

### 5.5 Pre-flight capture canary (I1a) and run status (I1b)

At run start: issue one innocuous observed tool call, then assert a corresponding line appeared in
`.qa/runs/<run-id>/toolstream.jsonl`.

- **Line appears** → capture is live. Normal enforcement.
- **No line, but `session-preflight.sh` can resolve a `--save-session` log** → capture is
  reconstructable (the existing non-Claude path). Normal enforcement after reconstruction.
- **Neither** → the run proceeds, but its report's top line becomes
  `UNVERIFIED — no independent capture`, with the tally printed beneath that banner and a stated
  reason. Findings fall back to in-agent journaling, and the report must say that findings are
  self-reported.

The run stays useful. It loses the ability to present itself as clean. Per-criterion
`confidence: low` remains as-is; it simply stops being the *headline* consequence, because we have
direct evidence it was too quiet to be read.

### 5.6 `qa-kit/scripts/migrate-inverted-criterion.sh` (new)

```
migrate-inverted-criterion.sh <checklist.json> <criterion-id> [--known-defects <path>]
```

Removes the criterion from `checklist.json`, writes a corresponding `known-defects.json` entry with
`ticket` and `expiry` left empty, prints what a human must supply, and **exits non-zero**. Past run
artifacts under `.qa/runs/` are never rewritten — history stays as it was recorded, including the
original `match: true`.

### 5.7 qa-kit process changes

- **`/qa-analyze` gains a `plan-defect` category.** Its five existing categories
  (coverage / role / oracle / risk / data) had nowhere to put an inverted oracle, so it landed under
  *Risk gaps* and was **blessed**. Plan defects print **above** the verdict line, and the
  "advisory only — the run is not blocked" charter is explicitly carved out for this class.
- **`/qa-spec` and `/qa-scenarios`** learn to emit a `known-defects.json` entry where they would
  previously have authored a criterion expecting a failure.

## 6. Data flow

```
observe.js (in-page)
  └─ {console[], network[]}  ──► agent's observe round
                                   │
                                   ├─► classify-finding.sh (deterministic)
                                   │      └─ in-scope | third-party | benign
                                   └─► journal.sh append  (finding_observed, append-only)
                                          │
  capture-hook.sh ──► toolstream.jsonl ───┼──► qa-verify.sh  (independent recomputation)
     (PostToolUse, full browser_* response)│        ├─ ledger completeness   → override
                                           │        ├─ classification re-check → override
                                           │        └─ known-defect status    → fail
                                           └──► findings.json (projection, for the report)
```

## 7. Error handling

The new scripts follow the repo's split precedent:

- `capture-hook.sh`'s **record** contract is fail-open by design — it must never break the tool call
  it observes. Unchanged.
- `classify-finding.sh`, `known-defects.sh`, `validate-checklist-json.sh` and the `qa-verify.sh`
  additions are **gates**, and are fail-closed. An unparseable input is a failure, never a pass.
- One correctness note carried over from field use: `qa-kit/scripts/data-baseline.sh validate`
  currently **exits 0 while printing errors**, which hid a malformed baseline during the originating
  incident. The new scripts must exit non-zero on every reported error, and that existing bug is
  fixed in the same pass.

## 8. Testing — the guarantee is a test, not a paragraph

New suites, in the established `tests/<suite>/run.sh` shape:

| Suite | Covers |
|---|---|
| `tests/classify-finding/` | origin match, origin mismatch, allowlist hit, and every fail-closed path (bad URL, absent `baseUrl`, relative URL) |
| `tests/findings-ledger/` | journal append shape; `findings.json` projection; a classification event never mutating the original observation |
| `tests/known-defects/` | schema validation; missing `ticket`/`expiry` rejected; severity floor; `outstanding`/`expired`/`cleared` transitions |

Extended suites:

| Suite | Added case |
|---|---|
| `tests/validate-checklist-json/` | each reserved-namespace rejection; each prose trigger; **and** a positive case proving a 302/403 authorization criterion still validates |
| `tests/qa-verify/` | ledger-completeness override; classification override; expired-known-defect failure |

**Two suites are built from this incident verbatim, and are the actual guarantee:**

1. A fixture reproducing `EC10` exactly — `page.rendersWithoutServerError: false`,
   `oracleSource: "human"` — must be **rejected** by `validate-checklist-json.sh`.
2. A run fixture whose `toolstream.jsonl` contains a 500 while its journal omits the corresponding
   `finding_observed` must be **overridden** by `qa-verify.sh`.

The first lands as a new case in the already-enrolled `tests/validate-checklist-json/` suite; the
second as a new case in the already-enrolled `tests/qa-verify/` suite. The three brand-new suites
(`classify-finding`, `findings-ledger`, `known-defects`) must each be **added** to
`scripts/run-engine-ci.sh`'s `SUITES` array, and any qa-kit-side suite to
`qa-kit/scripts/run-qakit-ci.sh`'s own `SUITES` array — that file is a separate list, so enrolling in
one does not enrol in the other. Enrolment is what makes the incident permanently un-repeatable
rather than merely documented.

## 9. Out of scope (YAGNI)

- **Rewriting past run artifacts.** History is read-only, including the original `match: true`.
- **Tracker integration.** `ticket` is a validated non-empty string, not an API call.
- **Fixing any application under test.** The originating 500 is `innovation`'s bug, tracked
  separately.
- **A pixel/visual regression baseline.** Already out of scope per ADR-0019 §12.
- **Changing what `observe.js` captures.** It already captures everything needed; only disposition
  changes.

## 10. Migration

`validate-checklist-json.sh`'s new rejections are **hard from day one** — no warning mode, no
grandfathering, no deprecation window. A warning is exactly what `/qa-analyze` produced for `EC10`,
and it was read as a blessing.

Existing specs containing an inverted criterion fail validation and are migrated with
`migrate-inverted-criterion.sh`, which requires a human to supply the ticket and expiry. The known
in-tree case is `innovation`'s `evaluation-counters` spec, `EC10`.
