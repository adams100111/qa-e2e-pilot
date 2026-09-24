# Error-honesty invariants — design

**Status:** approved 2026-09-23, revised the same day after an adversarial review that overturned the
first version's central mechanism. See §11 for what changed and why.
**Extends:** ADR-0010, ADR-0017, ADR-0018, ADR-0020, ADR-0021, ADR-0024.
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

The comparison **succeeded**. The run logged it as `BUG-1` with `severity: "low"` and
`fix: "Deferred by design … Not actionable within this QA pass's scope"`, and `/qa-analyze` filed it
under *Risk gaps* as "Known live defect acknowledged" while reporting **oracle gaps: 0**.

Nothing malfunctioned. Every component did what it was told. The plan said a crash was the correct
answer, so a crash was graded correct.

### 1.1 What was NOT the problem

**Capture.** `skills/driving-browser-qa/scripts/observe.js` installs read-only interceptors on
`console.error`/`warn`, `window.onerror`, `unhandledrejection`, `fetch` and `XMLHttpRequest`.

**Doctrine.** `skills/driving-browser-qa/SKILL.md:10` already says to treat console exceptions and
unexpected HTTP errors "as findings, not noise"; `:178` repeats it "regardless of whether the DOM
digest looks clean"; `:222` says "5xx = likely a server bug. Both are findings";
`skills/analyzing-feature-ui/SKILL.md:75` says to "confirm an error state **is rendered**, not a
blank screen"; and `SKILL.md:157-166` already *requires* a driver-backed follow-up call after every
navigation, calling it "the source of truth for the load window".

Four separate pieces of correct doctrine existed. All were prose. **Capture is mechanical;
disposition was discretionary.** The payload went to an agent, and the agent decided what it meant.

### 1.2 The second, quieter failure

That run produced **no `toolstream.jsonl` at all**. `.qa/config.json` declared
`enforcement.captureHook: true`, but the hook only runs if `scripts/capture-hook.sh` is registered as
a PostToolUse hook in the harness settings — and **nothing checks that it is**
(`scripts/check-prereqs.sh` has no reference to `settings.json` or `PostToolUse`).

Enforcement was configured, reported as enabled, and inert. Its only consequence was a per-pass
`confidence: low` stamp, and the run still presented as **10 pass / 1 fail** — read by both the
report's author and its reader as a successful verification.

An enforcement layer that can be silently absent is not an enforcement layer. That pattern —
*configured, reported, absent* — recurs throughout this design, and §5.8 fixes a third instance of it.

## 2. Principle

**Take disposition away from the agent, and put enforcement in the only trust domains that cannot be
lossy or forged.**

The repo already has the pattern: `scripts/qa-verify.sh` is an out-of-agent, deterministic authority
that re-checks recorded passes and overrides forgeries, never trusting a row's own `requiredKinds`
but re-deriving them with `required-kinds.sh`. We extend that pattern; we do not build parallel
machinery.

## 3. Invariants

| | Invariant | Enforced by |
|---|---|---|
| **I1** | No observed error is dropped, whether or not it relates to the criterion under test | findings journaled as keyed events; `qa-verify.sh` recomputes from `browser_network_requests` results and `__qaObserve` payloads in the toolstream (a file-based driver log is also read, but nothing writes one yet — §5.4) |
| **I1a** | Capture is proven live, not merely configured | `capture_probed` once-guard (§5.6); `enforcement.captureHook: true` is a claim, a written line is evidence |
| **I1b** | Without independent capture, a run may not present as clean | run-level `UNVERIFIED`, threaded to the CI exit code (§5.7) |
| **I2** | Disposition is deterministic | `scripts/classify-finding.sh` — origin vs `baseUrl` plus a git-tracked allowlist; fail-closed |
| **I3** | A criterion may not assert application failure **through the reserved health namespace** (§4.1) | `validate-checklist-json.sh` rejects it structurally, with assisted migration |
| **I4** | A known defect cannot be presented as green | `known-defects.json` + `known-defects.sh`: ticket, capped expiry, severity floor |
| **I5** | The load window is never unobserved | `qa-verify.sh` fails a run that navigates without the mandated follow-up call (§5.5) |

## 4. Two axes: who owns the error, and what turns the run red

These are separate questions, and the first version of this spec conflated them.

**Axis A — origin** (`classify-finding.sh`, §5.2): `in-scope` | `third-party` | `benign`.

**Axis B — status class**, which decides red/green:

> **A 3xx or 4xx can be correct behaviour. A 5xx, an unhandled exception, or a page crash never can.**

An authorization refusal, a validation rejection, a 404 on a deleted record — the application
*working*. A 500, an unhandled exception page, or a load-time crash — the application *failing*.

**Only a 5xx, an unhandled exception, or a page crash fails a run.** 3xx and 4xx findings are
recorded, classified and accounted for in the report, and never auto-fail.

This is not a softening. `observe.js`'s `isOkStatus` is `status >= 200 && status < 300`, so **a 302
is `ok: false`**. The originating spec's own `EC9` deliberately triggers three same-origin redirects
and `EC11` one more. Failing on any in-scope non-2xx would fail the very criteria §4 exists to
protect — and a gate with that false-positive rate gets switched off, which is a worse outcome than
the bug it was built for.

A stricter variant (a criterion declaring its expected non-2xx requests, with any unreconciled
in-scope non-2xx failing) is a clean later addition; the ledger already records the data it needs.
It is deliberately not in this version.

### 4.1 Detecting a criterion that asserts failure

**Structural — a reserved health namespace.** These `expect.path` values describe whole-page or
transport health rather than a domain value, and may not be pinned to a failing value:

| `expect.path` | Rejected when |
|---|---|
| `page.rendersWithoutServerError` | `value` is `false` |
| `page.crashed` | `value` is `true` |
| `http.status` | `value` >= 500 |
| `console.hasError` | `value` is `true` |

An `http.status` in the 3xx/4xx range stays legal — that is §4's carve-out. Paths outside this
namespace are untouched; a domain assertion like `counts.evaluators = 2` is unaffected.

**Prose, deliberately narrow.** Hard-reject only **`deferred by design`**, and only in the
**oracle/expect fields — never in `action`**. `action` is where an author legitimately explains
context ("this list does not render until the challenge reaches Judging" is a good description, and
an over-broad net would reject it).

The governing principle, adopted after review found the first draft over-broad:

> **Reject process language. Never reject behaviour language.**

"Deferred by design" describes a decision about the team's backlog and has no business in an oracle.
"Expected to fail" describes the *application*, and is frequently correct — *"the save is expected to
fail with a validation error"* is a sound oracle for an `error-state` criterion, because a 4xx
validation rejection is the application **working**, which §4 explicitly permits. An earlier draft
hard-rejected that phrase in the oracle field, which is precisely where its legitimate use lives;
that would have produced exactly the false-positive class that makes authors disable a validator.

`expected to fail`, `known defect` and `not a regression` are therefore `/qa-analyze` **plan-defect**
flags instead (§5.9), which print above the verdict line and so cannot be quietly blessed.

Both layers use the validator's existing one-line-per-violation form
(`ERROR: entry[<i>].<field>: …`).

## 5. Components

### 5.1 Findings ledger — keyed journal events

A finding is **a journal event**, not a new artifact. `skills/checkpointing-qa-memory/scripts/journal.sh`
is already append-only, `seq`-stamped and atomically written (ADR-0017).

```json
{
  "event": "finding_observed",
  "findingKey": "EC6|network|GET|https://app.test/admin/evaluations/challenges/1?tab=gates|500",
  "criterionId": "EC6",
  "source": "network",
  "channel": "driver-log",
  "method": "GET",
  "url": "https://app.test/admin/evaluations/challenges/1?tab=gates",
  "status": 500,
  "originClass": "in-scope",
  "statusClass": "fatal",
  "message": "<= 200 chars, truncated",
  "detailRef": "evidence/EC6/findings/f1.json"
}
```

Four constraints, each forced by the substrate:

- **Identity, not accumulation.** The journal has **no dedup**. Today's idempotency comes from
  *last-wins on a tuple key* (`fold.jq:117`), which suits one-row-per-key events and is exactly wrong
  for a ledger: on resume, re-observed errors would append again and count twice. So findings adopt
  the one existing "duplicate line is harmless" pattern — `openActs`' **keyed-set** semantics
  (`fold.jq:56-63`). `findingKey` is `(criterionId, source, method, url, status)`, reproducible from
  the observation itself with no counter. Console findings key on a normalized, length-capped
  message instead of a URL. The same 500 under two criteria is deliberately two findings: breadth is
  signal.
- **Size.** `journal.sh:79-93` documents a PIPE_BUF boundary — an event above **4,096 bytes is not
  guaranteed to land torn-free**, and the recovery path (fold drops a torn line, appender retries) is
  itself a duplicate-append path. So `message` is capped at ~200 chars and any stack trace or
  response body goes to `evidence/<criterion>/findings/`, referenced by `detailRef`.
- **Registration.** A new event type must be added to `fold.sh:59`'s `KNOWN_EVENTS_JSON` **and** the
  duplicated Python set at `:102-105`. `journal.sh` accepts any non-empty `event` string
  (`:266`), so an unregistered event appends successfully and is then **silently invisible** to
  `fold`, `checkpoint.json` and `cursor.json` — recorded as an `unknown-event` anomaly and discarded.
- **Reserved names.** `event`, `seq`, `t`, `childId`, `childSeq` are the substrate's. The event must
  never carry a caller-supplied `seq` (`journal.sh:46-48`).

The projection is rendered **from** the journal and is never a source of truth. That is what makes
"nothing can be deleted, only classified" structural: the substrate is append-only, so a later
classification is a new event and the original observation remains.

**Correction (2026-09-24):** earlier drafts of this section named a `findings.json` artifact. **No
such file exists.** The projection lands as `checkpoint.json`'s `findings` array (`fold.py:496-558`,
`fold.jq:375-401`), and **no report reads it** — neither `render-report.py` nor `report-to-junit.sh`
references it. Surfacing findings in the human report is an unshipped follow-up, not a shipped
feature.

### 5.2 `scripts/classify-finding.sh` (new, deterministic, no LLM)

```
classify-finding.sh <config-path> <url> <status>
  → originClass: in-scope | third-party | benign
  → statusClass: fatal | non-fatal
```

| Condition | `originClass` |
|---|---|
| URL origin equals the effective `baseUrl` origin | `in-scope` |
| URL origin differs from the `baseUrl` origin | `third-party` |
| URL path matches a `findings.benign[]` regex from `.qa/config.json`, **and** `baseUrl` parsed | `benign` |
| Anything else — unparseable URL, missing `baseUrl`, relative URL of unknown origin | **`in-scope`** |

`statusClass` is `fatal` for `status >= 500`, for an unhandled exception, and for a page crash;
`non-fatal` otherwise.

The last origin row is the design: **fail-closed**. An input the classifier cannot reason about is
treated as the application's own failure, never waved through. A run fails on
`originClass: in-scope` **and** `statusClass: fatal` — both axes, per §4.

The allowlist lives in `.qa/config.json`, so every waiver is human-authored, git-tracked and
reviewable in a diff.

### 5.3 `scripts/known-defects.sh` + `.qa/known-defects.json` (new)

```
known-defects.sh validate <path>          # schema, expiry cap, severity floor
known-defects.sh status <path> <today>    # per entry: outstanding | expired | cleared
```

Project-level, not per-spec: a defect is a property of the **application**, not of a QA target. Two
targets touching the broken surface share one entry, one ticket, one expiry. Per-spec copies would
drift out of sync, and whichever copy was most convenient would get renewed — which is how a waiver
becomes permanent.

```json
{
  "id": "KD-1",
  "title": "stage_gate_reviews.status='completed' rejected by StageGateReviewStatus",
  "ticket": "z8tvbhteuc",
  "expiry": "2026-10-07",
  "severity": "high",
  "observedClass": "non-rendering",
  "observedStatus": 500,
  "surface": "/admin/evaluations/challenges/{challenge}?tab=gates",
  "observedBehaviour": "HTTP 500, unhandled ValueError from the status enum cast"
}
```

- **`ticket` and `expiry` cannot be auto-filled.** `migrate-inverted-criterion.sh` writes the entry
  then exits non-zero, demanding both from a human. A known defect with no owner and no deadline is
  "deferred by design" under a new name.
- **`expiry` is capped at 90 days.** Without a cap, `2099-01-01` makes I4 a paper rule. Renewal
  requires an explicit new date — a deliberate act, visible in a git diff and reviewable in a PR.
- **The severity floor gates on structure, not prose.** `observedClass` is an enum
  (`non-rendering | wrong-value | degraded`); `observedClass: non-rendering` forces a floor of
  `high`. `observedBehaviour` is human prose carrying no enforcement weight. A gate that greps prose
  is defeated by rewording, deliberately or not. This is the check that rejects the originating
  incident's `severity: "low"`.
- **Never a verdict.** A known defect is not a criterion. It has no `pass`/`fail`, contributes
  nothing to the tally, and cannot be counted as verification of anything.
- **Run status.** Past `expiry` the entry is `expired` and **blocks** the run. **Correction
  (2026-09-24):** an earlier draft said the run's top line reads `GREEN with N known defects`. **No
  code writes that string.** Per-entry states reach `verification.json`'s `__run-checks__` only;
  `render-report.py` has no known-defect handling at all. The human-report headline is an unshipped
  follow-up.
- **Clearing requires positive evidence.** An entry is `cleared` only when the journal holds a
  successful (2xx) navigation to its `surface` **and** no fatal finding on it. Absence of a finding
  never clears anything — that is the same error as grading a crash correct, since a run that never
  reached the surface produces exactly the same silence. An entry not provably exercised stays
  `outstanding`. **Correction (2026-09-24):** an earlier draft added "and the report says it was not
  exercised this run" — nothing writes that either.

### 5.4 Where findings actually come from (two channels)

The first version of this spec claimed `qa-verify.sh` could recompute the finding set from
`toolstream.jsonl` because browser responses are "recorded in full". **That is false**, in five ways
(§11). The corrected design uses two complementary channels, because neither covers the other's
error class.

**Channel 1 — in-page interception, for console errors.** `observe.js`'s `console[]` catches JS
exceptions, `window.onerror` and unhandled rejections. A network log cannot see these.

Required fix: `observe.js:160-166` currently serializes `console[]` and `network[]` **last**, after
the bulky `domDigest` (`liveText` up to 1500 chars, `interactive` up to 80 elements whose `testid`
and `href` are **not length-capped at all**). `capture-hook.sh:308` then truncates the recorded
`responseBody` at 4,000 bytes with `head -c`. So today the cap destroys the error arrays first,
past roughly 25–30 interactive elements on realistic markup. **Move `console[]` and `network[]` to
the front of the payload and length-cap `testid`/`href`**, so the cap truncates the least important
field instead of the most.

The 4,000-byte cap itself stays. It exists for stated reasons (toolstream size, exposure surface),
`provenance.sh:60-69` already reasons about it as accepted evidence loss, and after the reorder it
is no longer harmful. If measurement later shows findings still overflowing, a tool-scoped raise is
the narrow fix — reorder and measure first.

**Channel 2 — the driver's network log, for requests.** A **navigation-time 500 is invisible to
`__qaObserve`, structurally**: the 500 *is* the document request, issued by the browser's navigation
machinery, not by `fetch` or XHR, and no script runs on a 500 page to be intercepted. No in-page
mechanism can ever see it. Only the driver-backed `browser_network_requests` does —
`SKILL.md:160` names "the navigating document request" as what that call, and only that call, sees.

The driver-backed request record is therefore the **preferred** source for requests, and it reaches
`qa-verify.sh` two ways — only the first of which has a producer today:

1. **`browser_network_requests` results in the toolstream** — the path that works **today**.
   `qa-verify.sh`'s `observe_rows` parses each `responseBody` that is a JSON array of request
   records, so the mandated post-navigation call (I5) is what carries a navigation-time 500 into the
   finding set. It inherits the 4,000-byte cap, so a long request list truncates and simply fails to
   parse — which can only ever *hide* a required finding, never invent one.
2. **A file-based driver log** — `QA_NETWORK_LOG`, else `.qa/runs/<run-id>/network-log.json`, else
   `.playwright-mcp/*.har`. Immune to the cap and portable across harnesses, and therefore the
   preferred source. **Correction (2026-09-24): nothing in this repo writes such a file yet**, so
   this source is inert on real runs until a producer exists. An earlier draft of this section
   described it as simply "authoritative", which overstated what ships. Wiring a HAR producer is the
   top follow-up; until then path 1 plus I5's enforced follow-up call is what closes the nav-500
   blind spot, and I5 needs only the `tool` field, so neither the cap nor the `responseBody: null`
   harnesses can defeat it.

**Harnesses and drivers that can satisfy neither channel are `UNVERIFIED`** (§5.7). This is not an
edge case: `session-to-toolstream.js:119` writes `responseBody: null` **always**, so Codex, Pi and
opencode have nothing to recompute from via the toolstream, and the PostToolUse matcher hard-codes
`mcp__plugin_playwright_playwright__browser_.*`, so any other driver produces no events at all. For
those harnesses the driver log is not a fallback — it is the primary channel.

### 5.5 `scripts/qa-verify.sh` (extended)

Four additions, in the existing out-of-agent, jq/python3-only style. All are **run-scoped**, not
pass-scoped — `qa-verify.sh` today re-checks only records whose `verdict == "pass"`, which is
exactly why `EC10`, recorded `fail`, was never re-examined by anything.

1. **Ledger completeness (I1).** Recompute the expected finding set from the driver network log and
   from `__qaObserve` payloads in the toolstream; compare against `finding_observed` events. A
   finding present in either channel and absent from the journal is a dropped-error signal →
   **override the run**. Mirrors step 1's existing dropped-kind re-derivation.
2. **Classification re-check (I2).** Re-run `classify-finding.sh` over each journaled finding and
   override any classification that does not match the deterministic result. An agent cannot
   mis-class a 500 by writing a journal event that says otherwise.
3. **Load-window coverage (I5).** Fail a run in which a `browser_navigate` event is not followed by
   a `browser_network_requests` event before the next navigation. `SKILL.md:157-166` already
   *requires* this and calls it the source of truth for the load window — but it is prose, the same
   kind of prose that already failed us. The check needs only the `tool` field, never
   `responseBody`, so the 4KB cap and the `responseBody: null` harnesses are both irrelevant to it.
   This is the highest-value single check in the design: it closes the blind spot where the
   nav-time 500 lives.
4. **Known-defect gate (I4).** Run `known-defects.sh status`; any `expired` entry fails the run, and
   any entry below its severity floor fails validation.

### 5.6 Capture canary (I1a)

Emitted as a `capture_probed` event behind the codebase's existing **once-per-run guard keyed on
journal emptiness** (`checkpoint.sh:1141-1148`; the scan-for-existing-event variant is
`journal-emit.sh`'s `plan_frozen_exists()`). Both idioms are resume-safe by construction.

It must **not** live in the agent's Phase 0 pre-flight: `commands/qa-resume.md` dispatches a resumed
run to "resume in that phase, **not from Pre-flight**", so a Phase-0 assertion would be silently
skipped on every resumed run — the same silent-inertness this spec exists to remove.

The probe asserts that the capture path is actually *producing* lines: a hook-written toolstream
entry, or a resolvable driver log. `enforcement.captureHook: true` is a claim; a written line is
evidence.

### 5.7 Run-level `UNVERIFIED` (I1b), threaded to the exit code

`UNVERIFIED` already exists as a word: `report-to-junit.sh:197-200` emits `qa.verified="false"` with
that literal text when `qa-verify` did not run. It lives in `<properties>`, which is **unreachable
from the exit code** (`:395` exits on `failures or errors` only), and `__phase-surface__`
(`qa-verify.sh:940`) is an explicit precedent for a run-level row that deliberately never fails.

The run is announced as `UNVERIFIED — no independent capture` on `report-to-junit.sh`'s **stderr**
and in its `qa.unverifiedReason` property — **not** in `report.md`/`report.html`, which contain no
`UNVERIFIED` string (an unshipped follow-up). Critically, **`report-to-junit.sh` synthesizes a `<testcase>` + `<failure>`** so it reaches the
exit code. The JUnit route is the only one that works when `qa-verify` did not run at all — routing
through `qa-verify.sh`'s `run_failed` (`:1409`) would be unreachable exactly when needed.

**`QA_SKIP_VERIFY=1` itself produces `UNVERIFIED`.** Today it skips verification and is logged
without failing the build (`qa-ci.sh:118-119`) — an env var that silently switches the whole
guarantee off. You may skip verification; the run must then say it is unverified rather than look
clean.

Per-criterion `confidence: low` is unchanged. It simply stops being the *headline* consequence,
because we have direct evidence it was too quiet to be read.

### 5.8 Config persistence (a live data-loss bug, fixed here)

`init-config.sh` renders `.qa/config.json` fresh and `mv -f`s it over the destination (`:137`,
`:151`). There is **no schema and no validation anywhere** in the tree, so an unknown top-level key
is rejected nowhere, read by nothing, and **silently erased on the next bootstrap**.

This already destroys six keys that `.qa/config.json.example` documents but the writer never emits:
`viewport`, `responsiveMatrix`, `persona`, `detection`, `passGate`, `fixtures`.

Two changes: add `findings` to the writer, **and** make `init-config.sh` preserve unknown top-level
keys on re-render. `docs/superpowers/specs/2026-09-07-deep-audit-remediation-design.md:201` already
records "never delete unknown keys" as a principle, scoped to installers; this extends it to the
config writer. It is in scope because it is the same failure mode as everything else here: a
configured thing that quietly is not there.

### 5.9 qa-kit process changes

- **`/qa-analyze` gains a `plan-defect` category.** Its five categories
  (coverage / role / oracle / risk / data) had nowhere to put an inverted oracle, so it landed under
  *Risk gaps* and was **blessed**. Plan defects print **above** the verdict line, and the
  "advisory only — the run is not blocked" charter is explicitly carved out for this class. The
  demoted prose signals from §4.1 — `expected to fail`, `known defect`, `not a regression` — surface
  here. (All **three**: an earlier draft of this line named only two, omitting `expected to fail`,
  which §4.1 demotes for the reason recorded there.)
- **`/qa-spec` and `/qa-scenarios`** emit a `known-defects.json` entry where they would previously
  have authored a criterion expecting a failure.
- **`qa-kit/scripts/migrate-inverted-criterion.sh`** removes the criterion from `checklist.json`,
  writes a `known-defects.json` entry with `ticket` and `expiry` empty, prints what a human must
  supply, and exits non-zero. Past run artifacts under `.qa/runs/` are never rewritten — history
  stays as recorded, including the original `match: true`.

### 5.10 Fold anomalies (minimal wiring)

`fold-anomalies.json` computes `seq-gap`, `illegal-edge`, `cross-child-duplicate`,
`duplicate-plan-frozen`, `verdict-without-started` and `unparseable-line` — and **no production
script reads it**; `CONTEXT.md:160` notes it is "never a fold abort". That is this spec's own theme:
errors detected and then ignored.

Minimal fix: surface the anomaly count in the report, and let **`unparseable-line` and `seq-gap`
contribute to `UNVERIFIED`** — both mean the run's own record is damaged, so its verdicts cannot be
trusted, which is precisely what `UNVERIFIED` says.

Every **other** anomaly stays reported-only — `illegal-edge`, `cross-child-duplicate`,
`duplicate-plan-frozen`, `verdict-without-started`, plus the two this spec's own §5.1 adds,
`finding-url-oversize` and `finding-detail-missing`. **Six, not four:** an earlier draft said "the
other four" and was written before §5.1 introduced the last two. The two new ones describe a
data-quality problem in one finding, not damage to the run's record, which is why they do not
trigger `UNVERIFIED`. Anything larger is separate work.

## 6. Data flow

```
driver network log (HAR / --save-session)  ──┐   authoritative for REQUESTS
                                             │   (sees the navigating document request)
observe.js console[] (in-page interceptors) ─┤   authoritative for CONSOLE
                                             │   (JS exceptions; a HAR cannot see these)
                                             ▼
                                  classify-finding.sh  (deterministic, fail-closed)
                                     originClass × statusClass
                                             │
                                             ▼
                          journal.sh append  (finding_observed, keyed-set)
                                             │
  capture-hook.sh ──► toolstream.jsonl ──────┼──► qa-verify.sh   (run-scoped, out-of-agent)
     (PostToolUse; responseBody capped 4KB)  │       ├─ ledger completeness    → override
                                             │       ├─ classification re-check → override
                                             │       ├─ load-window coverage    → fail
                                             │       └─ known-defect status     → fail
                                             └──► findings.json (projection, report only)
```

## 7. Error handling

- `capture-hook.sh`'s **record** contract stays fail-open — it must never break the tool call it
  observes. Unchanged.
- `classify-finding.sh`, `known-defects.sh`, `validate-checklist-json.sh` and the `qa-verify.sh`
  additions are **gates**, and are fail-closed. An unparseable input is a failure, never a pass.
- **Correction (2026-09-23):** an earlier draft of this section claimed
  `qa-kit/scripts/data-baseline.sh validate` "exits 0 while printing errors". **That is false.**
  Verified against the pre-change code: a malformed `scope` yields
  `{"errors":["row[0].scope: must be an object or null"]}` with **rc=1**, and `git blame` shows it
  has behaved correctly since its first commit (`6e430fb`). The claim came from a misremembered
  session, not from the code. Task 12 therefore adds regression tests locking the existing
  exit-code contract in place, and changes no behaviour.

## 8. Testing — the guarantee is a test, not a paragraph

New suites, in the established `tests/<suite>/run.sh` shape:

| Suite | Covers |
|---|---|
| `tests/classify-finding/` | origin match, mismatch, allowlist hit, `statusClass` boundaries, and every fail-closed path (bad URL, absent `baseUrl`, relative URL) |
| `tests/findings-ledger/` | keyed-set dedup across a simulated resume; event size under the PIPE_BUF boundary; `KNOWN_EVENTS_JSON` registration in **both** fold engines; `findings.json` projection; a classification event never mutating the original observation |
| `tests/known-defects/` | schema; missing `ticket`/`expiry` rejected; 90-day expiry cap; severity floor via `observedClass`; `outstanding`/`expired`/`cleared`; **clearing refused without a recorded 2xx navigation** |

Extended suites:

| Suite | Added case |
|---|---|
| `tests/validate-checklist-json/` | each reserved-namespace rejection; both prose triggers; **and** a positive case proving a 302/403 authorization criterion still validates |
| `tests/qa-verify/` | ledger-completeness override; classification override; **load-window coverage failure**; expired-known-defect failure |
| `tests/qa-ci-verify/` | `UNVERIFIED` reaches a non-zero exit code; `QA_SKIP_VERIFY=1` yields `UNVERIFIED` rather than green |
| `tests/init-config/` | unknown top-level keys survive a re-render |
| `tests/capture-hook/` | with the reordered payload, `console[]`/`network[]` survive the 4,000-byte cap at 80 interactive elements |

**Three cases are built from this incident verbatim, and are the actual guarantee:**

1. A fixture reproducing `EC10` exactly — `page.rendersWithoutServerError: false`,
   `oracleSource: "human"` — must be **rejected** by `validate-checklist-json.sh`.
2. A run fixture whose driver log contains a navigation 500 while its journal omits the
   corresponding `finding_observed` must be **overridden** by `qa-verify.sh`.
3. A run fixture that navigates without the mandated `browser_network_requests` follow-up must
   **fail** — the blind spot the originating 500 lived in.

Cases 1 and 2 land in the already-enrolled `tests/validate-checklist-json/` and `tests/qa-verify/`
suites. The three brand-new suites must each be **added** to `scripts/run-engine-ci.sh`'s `SUITES`
array, and any qa-kit-side suite to `qa-kit/scripts/run-qakit-ci.sh`'s own `SUITES` array — separate
lists, so enrolling in one does not enrol in the other.

## 9. Out of scope (YAGNI)

- **Rewriting past run artifacts.** History is read-only, including the original `match: true`.
- **Tracker integration.** `ticket` is a validated non-empty string, not an API call.
- **Fixing any application under test.** The originating 500 is `innovation`'s bug, tracked
  separately.
- **Declared-expectation reconciliation for 4xx** (§4's stricter variant). Later, if 4xx bugs prove
  to slip.
- **Parallel fan-out behaviour.** The fan-out journal path is tested but **unwired** — no production
  script calls `journal.sh append --child`. The findings event is made forward-compatible (registered
  in both fold engines, no reserved-name collisions, never depends on `seq`), but no fan-out
  behaviour is built or tested. Recorded for whoever wires it: in fan-out mode `seq` order is *not*
  chronological (children merge in lexicographic filename order) and `t` is second-resolution only,
  so ledger chronology is approximate there; and `cross-child-duplicate` is hardcoded to
  `criterion_verdict`, so a new event type gets no race detection for free.
- **A pixel/visual regression baseline.** Already out of scope per ADR-0019 §12.

## 10. Migration

`validate-checklist-json.sh`'s new rejections are **hard from day one** — no warning mode, no
grandfathering, no deprecation window. A warning is exactly what `/qa-analyze` produced for `EC10`,
and it was read as a blessing.

Existing specs containing an inverted criterion fail validation and are migrated with
`migrate-inverted-criterion.sh`, which requires a human to supply the ticket and expiry. The known
in-tree case is `innovation`'s `evaluation-counters` spec, `EC10`.

## 11. What the adversarial review overturned

The first version of this spec (commit `8bfa7ad`) asserted that `qa-verify.sh` could independently
recompute the finding set from `toolstream.jsonl`, because `capture-hook.sh` "records `browser_*`
tool responses **in full** … That is a guarantee rather than a reminder." **That claim was false**,
and the review found five independent reasons:

1. **`responseBody` is hard-capped at 4,000 bytes** — `capture-hook.sh:308`, `head -c`, applied
   unconditionally to every browser tool, asserted by `tests/capture-hook/run.sh:69`.
   `provenance.sh:60-69` already documents the cap as deliberately accepted evidence loss.
2. **`observe.js:160-166` serializes `console[]`/`network[]` last**, after the bulky `domDigest`, so
   the error arrays are the *first* thing the cap destroys — past roughly 25–30 interactive
   elements.
3. **A navigation-time 500 is invisible to `__qaObserve`, structurally.** It is the document
   request, not a `fetch`/XHR call, and no script runs on a 500 page. Scoping recomputation to
   `browser_evaluate` payloads would have systematically missed the exact error class the spec is
   about.
4. **`session-to-toolstream.js:119` writes `responseBody: null`, always** — on Codex, Pi and
   opencode there is nothing to recompute from.
5. **The PostToolUse matcher hard-codes `mcp__plugin_playwright_playwright__browser_.*`** — any
   other driver produces no toolstream events at all.

Two further claims in the review were flagged as inferred rather than source-verified and are not
relied upon here: the MCP envelope's JSON-escaping amplification of the cap, and `browser_navigate`'s
exact result schema.

Four more corrections came from a second review, of how the design would interact with existing
subsystems: the journal has **no dedup** and an accumulating ledger would double-count on resume
(§5.1); a Phase-0 canary is **silently skipped on every resumed run** (§5.6); `UNVERIFIED` exists
already but lives in `<properties>`, **unreachable from the exit code** (§5.7); and `init-config.sh`
would have **silently erased** the new config key, as it already erases six documented ones (§5.8).

The lesson is the spec's own: the first version trusted a documented behaviour without checking the
code, which is the same error as trusting a criterion's pinned oracle without asking whether it
describes the application working or failing.
