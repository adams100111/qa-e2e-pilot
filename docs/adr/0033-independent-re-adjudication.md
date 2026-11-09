# ADR-0033 — Independent re-adjudication of weak verdicts by a fresh-context verifier

## Status

Accepted (2026-11-09). Ship QA increment 2, engine 0.12.0 + qa-kit 0.3.0. Design:
[`docs/superpowers/specs/2026-11-09-ship-grade-qa-design.md`](../superpowers/specs/2026-11-09-ship-grade-qa-design.md)
§2c and "Settled after builder review" #6. Pattern: the Universal Verifier paper,
[arXiv:2604.06240](https://arxiv.org/abs/2604.06240) — judge from persisted state, and keep the judge
apart from the actor. Builds on [ADR-0029](./0029-criterion-level-supersession-and-record-time-identity.md)
(the latest authoritative verdict wins) and [ADR-0017](./0017-multi-harness-portability.md)
(capability per harness). Companion to [ADR-0032](./0032-trusted-verdict-gates.md). Adds no verdict.

## Context

The agent that drives a criterion also judges it. The record-time gates (ADR-0010, ADR-0032) check
that the right evidence exists, not that it supports the verdict. Where the agent itself was unsure —
a `pass` it recorded at `confidence: low`, or a `fail` a UX detector promoted without any `bake`,
`computed` or `probe` evidence — the verdict rests on the actor's own story ("the toast said saved").
Re-reading the run in the same context does not help: that judge has already seen the story.

## Decision

**A. A second judge with a fresh context, after the run.** New engine skill
`re-adjudicating-verdicts` (19 skills) with `scripts/adjudication.sh`:

- `select <run-dir>` lists every `pass` at `confidence: low` and every UX-promoted `fail` (row
  tag/kind/stepType in `visual-ux|interaction-ux|ux-revisit`, kinds holding none of
  `bake|computed|probe`), one `<criterionId>\t<persona>\t<why>` line each.
- `bundle <run-dir> <crit> <out> [--persona p]` copies only persisted evidence, by allow-list: the
  checklist row (`criterion.json`), the claim without prose (`claim.json`: verdict, confidence,
  kinds), `bake-read-back.json`, `recompute.json`, `network-response.json`, `action-trace.json`,
  `identity.json`, screenshots and `findings/`. Never `journal.ndjson`, `toolstream.jsonl`,
  `last_action`, `nonUiActionReason`, notes, symlinks or unknown files.
- The skill dispatches one **new** subagent per bundle (never a fork, never a resumed agent), with a
  fixed rubric: judge from persisted state and network evidence, screenshots support but never
  suffice for a state claim, answer `{"agree": bool, "reason": "<artifact and value>"}`. Identity
  comes from the selection line, never from the verifier's answer; an unparseable answer counts as
  disagreement.
- `apply <run-dir> <decisions.json>` writes through `checkpoint.sh --phase adjudicate`, so the
  record-time gates still apply and the journal keeps the history.

**B. Downgrade only.** A disputed `pass` becomes `blocked`, `confidence: low`, last action
`verifier-disagrees: <reason>`, kinds and evidence refs kept. A disputed `fail` stays `fail` at
`confidence: low`. Agreement, and disagreement on `blocked|deferred|error`, change nothing. Any
decision that would raise a verdict or a confidence makes the whole batch exit 1 with
`ADJUDICATION: upgrades are not allowed` and nothing written. Unknown criteria or personas and
malformed entries are rejected and reported; the rest still apply (exit 1).

**C. Where it runs.** The agent invokes it at the start of its Report phase, before `qa-verify.sh`,
so `verification.json` and the ship summary see the final verdicts. On Claude Code, `/qa-run`
dispatches the agent as a subagent that cannot start agents of its own; it then lists the pending
records and leaves `adjudication/` absent, and the `/qa-run` session runs the skill after the agent
returns, then re-runs `qa-verify.sh`, the renderer and the bug export. qa-kit's `/qa-verify`
restates the outcome and never applies decisions itself.

**D. Capability is declared, not guessed.** `harness-profiles.json` carries a boolean
`subagentDispatch` (claude `true`; codex, pi, opencode `false`). Without it the skill prints
`re-adjudication unavailable on <harness>; <n> low-confidence passes unreviewed`, writes it to
`adjudication/unavailable.txt` and exits 0. It never re-judges in the acting context.

## Consequences

- A low-confidence pass on a P1 criterion that the verifier disputes becomes `blocked`, so its
  journey is not `pass` and the run is `NOT SHIP-READY` until a human looks.
- A refused re-upsert (for example the screenshot gate on a disputed fail) leaves the record
  unchanged; the dispute then shows only in `adjudication/apply.txt`, which the hand-off must quote.
- The second judge costs one subagent per selected record, run sequentially (ADR-0003). High
  confidence passes are not re-judged: the gates are their check.
- Other harnesses keep their recorded verdicts and say so; opencode has a native task tool but no
  dispatch recipe yet, so it stays `false` until one exists.
- Suite: `adjudication`.
