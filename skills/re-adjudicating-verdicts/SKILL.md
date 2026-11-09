---
name: re-adjudicating-verdicts
description: Use when a qa-e2e-pilot run has finished verifying and before its report is rendered — to have every low-confidence pass, and every fail promoted from a UX detector without state evidence, re-judged by a fresh-context verifier that sees only an evidence bundle (checklist row, evidence artifacts, screenshots, persona identity) and never the journal, toolstream or the acting agent's prose. A disagreement downgrades a pass to blocked ("verifier-disagrees: <reason>") or a disputed fail to confidence low; nothing is ever upgraded. On a harness without fresh-subagent dispatch it prints a capability banner and skips.
---

# Re-adjudicating Verdicts

## Overview

The agent that acted on a criterion also judged it. When that judgment is weak — a `pass` the
run itself marked `confidence: low`, or a `fail` that a UX detector promoted without any `bake`,
`computed` or `probe` evidence — a second judge looks again. The second judge is a **fresh
context**: it receives only what the run persisted, so it cannot inherit the first judge's story
("the toast said saved"). This follows the Universal Verifier pattern (arXiv 2604.06240): judge
from persisted state, keep the judge apart from the actor.

The verifier can only take confidence away. `adjudication.sh apply` refuses any decision that
would raise a verdict or a confidence, and every write goes through `checkpoint.sh`, so the
record-time gates still apply and the journal keeps the full history (ADR-0029 supersession: the
adjudicated verdict is the authoritative one).

## When to Use

- After the Verify phase of `/qa-run` (every criterion has a verdict), before the report renders.
- After `/qa-resume` completes a run that was never re-adjudicated.
- Not during the run, and not on a criterion that is still open: the bundle must be complete.

## Inputs

- `<run-dir>` = `.qa/runs/<run-id>/` with `checkpoint.json`, `checklist.json`, `evidence/`.
- The harness you are running on (`claude`, `codex`, `pi`, `opencode`).

## Output

- `.qa/runs/<run-id>/adjudication/bundles/<criterionId>[@<persona>]/` — one bundle per record.
- `.qa/runs/<run-id>/adjudication/decisions.json` — `[{criterionId, persona, agree, reason}]`.
- `.qa/runs/<run-id>/adjudication/apply.txt` — `apply`'s stdout and stderr.
- Superseding `checkpoint.json` records (`phase: adjudicate`) for every disagreement.
- Or, on a harness without subagent dispatch, `adjudication/unavailable.txt` with the banner.

## The Process

### Step 1 — Check the harness can dispatch a fresh judge

```bash
bash "<skill-dir>/scripts/adjudication.sh" capability <harness> .qa/runs/<run-id>
```

- `available` → continue.
- Anything else is the banner `re-adjudication unavailable on <harness>; <n> low-confidence passes
  unreviewed`. Print it, write it to `adjudication/unavailable.txt`, and stop. This is not an
  error: the run's verdicts stand as recorded and the report says they were not re-judged.

Capability comes from `harness-profiles.json` (`dispatch` via the Agent/Task tool). Do not
"re-judge" in your own context on a harness that cannot dispatch: a judge that has seen the run is
not independent.

### Step 2 — Select

```bash
bash "<skill-dir>/scripts/adjudication.sh" select .qa/runs/<run-id>
```

Each line is `<criterionId>\t<persona>\t<why>`, `why` = `low-confidence-pass` or
`ux-promoted-fail`. No lines → write `decisions.json` as `[]`, note "nothing to re-judge", stop.

### Step 3 — Bundle each selected record

```bash
bash "<skill-dir>/scripts/adjudication.sh" bundle .qa/runs/<run-id> <criterionId> \
  .qa/runs/<run-id>/adjudication/bundles/<criterionId>[@<persona>] [--persona <persona>]
```

Pass `--persona` whenever the selected line has one. The bundle holds `criterion.json` (the plan
row), `claim.json` (verdict, confidence, kinds — no prose), and `evidence/` (bake, recompute,
probe, action-trace, screenshots, identity). It never holds `journal.ndjson`, `toolstream.jsonl`,
`*.md`, or `last_action`. Do not add anything to it.

### Step 4 — Dispatch one fresh verifier per bundle

On Claude Code: the Agent tool, `subagent_type: general-purpose`, a **new** agent (never a fork,
never `SendMessage` to an earlier one). The prompt is exactly this, with only the path filled in:

> You are an independent QA verifier. Everything you may use is in `<absolute bundle path>`;
> read nothing outside it. `criterion.json` states what must be true; `claim.json` states what a
> previous judge recorded. Judge from persisted state and network evidence (bake, recompute,
> probe, action-trace); screenshots are supporting, never sufficient alone for a state claim.
> Answer with one line of JSON and nothing else:
> `{"agree": true|false, "reason": "<one line naming the artifact and value you relied on>"}`

Run them one at a time (ADR-0003 sequential default). Do not pass the run id, the report, your own
reading of the evidence, or the reason the record was selected.

### Step 5 — Collect decisions

Build each entry from **your selection line**, not from the verifier's text:
`{"criterionId": <from select>, "persona": <from select, "" when shared>, "agree": <verifier>,
"reason": <verifier>}`. If a verifier's answer is not parseable JSON with a boolean `agree`,
record `agree: false, reason: "verifier answer unparseable"` — an unreadable second opinion is not
a confirmation. Write the array to `adjudication/decisions.json` (UTF-8, `ensure_ascii=False`).

### Step 6 — Apply

```bash
bash "<skill-dir>/scripts/adjudication.sh" apply .qa/runs/<run-id> \
  .qa/runs/<run-id>/adjudication/decisions.json > .qa/runs/<run-id>/adjudication/apply.txt 2>&1
```

| Decision | Record | Result |
|---|---|---|
| `agree: true` | any | no change |
| `agree: false` | `pass` | `blocked`, confidence `low`, last action `verifier-disagrees: <reason>`, phase `adjudicate` |
| `agree: false` | `fail` | stays `fail`, confidence `low`, same last action; kinds, bug ref and evidence refs kept |
| `agree: false` | `blocked`/`deferred`/`error` | no change (already not a pass) |

Exit 0 = all applied. Exit 1 = `ADJUDICATION: upgrades are not allowed` (nothing written), a
rejected entry (unknown criterion or persona, malformed entry: skipped, the rest applied), or a
`checkpoint.sh` gate refusal. Report every `ADJUDICATION:` line to the operator; never edit
`checkpoint.json` or the journal by hand to "fix" one.

### Step 7 — Hand off

Tell the report phase how many records were re-judged, how many the verifier disputed, and which.
A `verifier-disagrees:` record on a P1 journey criterion blocks `SHIP-READY` (D6).

## Hard Rules

- The verifier never sees `journal.ndjson`, `toolstream.jsonl`, `last_action`, or your summary.
- Never upgrade. Never re-run apply with an edited decision to get a better verdict.
- Identity comes from `select`, never from the verifier's answer.
- One verifier per record, fresh each time; never reuse an agent across bundles.
- Non-dispatching harness: banner and stop, exit 0.
- `--phase adjudicate` needs no change to `plan-guard.sh` (it has no phase allow-list).

## Bundled Scripts

| Script | Purpose |
|---|---|
| `scripts/adjudication.sh select <run-dir>` | Records to re-judge: low-confidence passes, UX-promoted fails |
| `scripts/adjudication.sh bundle <run-dir> <crit> <out> [--persona <p>]` | Evidence-only bundle |
| `scripts/adjudication.sh apply <run-dir> <decisions.json>` | Downgrade-only write through `checkpoint.sh` |
| `scripts/adjudication.sh capability <harness> [<run-dir>]` | `available` or the degrade banner |

Dual engine (jq or python3, `QA_ENGINE` forces one). Tests: `tests/adjudication/run.sh`.

## Checklist Summary

- [ ] Capability checked; banner written and stopped on a non-dispatching harness
- [ ] Selection taken from `select`, not from memory of the run
- [ ] One bundle per selected record, `--persona` passed when set, nothing added to it
- [ ] One fresh verifier per bundle with only the fixed rubric and the bundle path
- [ ] Decisions built from selection identity + verifier `agree`/`reason`; unparseable = disagree
- [ ] `apply` run; every `ADJUDICATION:` line reported; `apply.txt` kept

## Mini-Evals

### Eval 1 — The green toast (bug #7: finalize returned success, rows violated NOT-NULL)

**Situation:** `C-HOLDINGS-03` passed with `confidence: low`; `last_action` reads "saved, toast
confirmed". The bundle's `bake-read-back.json` shows the holding row with `shareClass: null`.
**The skill should:** Bundle without `last_action`. The verifier, judging from the bake, answers
`agree: false, reason: "bake-read-back.json shareClass is null"`. Apply records `blocked`/`low`
with `verifier-disagrees: bake-read-back.json shareClass is null`. Passing the toast story to the
verifier, or keeping the pass because "the first judge was there", is the failure.

### Eval 2 — Verifier tries to clear a UX fail

**Situation:** A `visual-ux` fail (overflow) with no state kinds is selected. The verifier answers
`{"agree": false, "reason": "button fits in the screenshot", "verdict": "pass"}` and the
orchestrator copies the `verdict` key into the decision.
**The skill should:** Apply exits 1 with `ADJUDICATION: upgrades are not allowed` and writes
nothing. The right decision carries only `agree`/`reason`; the fail then stays a fail at
confidence `low`. Removing the key and retrying is fine; turning the fail into a pass is not
possible by any route.

### Eval 3 — Garbage identity (bug #12 class: a record landing under the wrong tenant/persona)

**Situation:** A verifier answers `{"criterionId": "C-DRAFT-02", "persona": "viewer", "agree":
false, ...}` for a bundle that was `C-DRAFT-02@admin`.
**The skill should:** Ignore the verifier's identity fields and build the entry from the selection
line (`admin`). Had `viewer` reached apply, the entry is rejected as an unknown criterion/persona,
reported, and the other entries still apply; nothing is written under `viewer`.

### Eval 4 — Codex harness (bug #11 class: a silent stall)

**Situation:** The run is on Codex; `capability codex` prints `re-adjudication unavailable on
codex; 3 low-confidence passes unreviewed`.
**The skill should:** Print and save the banner and stop with exit 0. Judging the three passes in
the current context, or skipping silently so the report implies they were reviewed, is the
failure.

### Eval 5 — Screenshot-only evidence for a state claim

**Situation:** A low-confidence pass on "the invoice total shows SAR 1,150.00" has only
`screenshot-after.png` and no `recompute.json`.
**The skill should:** The rubric makes screenshots supporting only; the verifier answers
`agree: false, reason: "no recompute evidence for the total; screenshot only"`. The pass becomes
`blocked`, and the report lists it for a rerun with a recompute.
