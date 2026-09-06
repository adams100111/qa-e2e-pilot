# Verification — {{target}}

**Run:** `{{run-id}}`  ·  **Checked:** {{n-passes}} passes  ·  **Planned criteria:** {{n-planned}}

## Out-of-plan acts
{{ one of: "None — every acted criterion was in the frozen plan." | a bullet list of offending
criterion ids, each: "`<id>` — acted but absent from checklist.json (process violation)." }}

## Deterministic re-verification (authoritative source: the engine's report.md)
{{ one of:
  - "VERIFIED — the engine's qa-verify.sh re-checked every recorded pass; no `verifierVerdict`
     differed from its `inRunVerdict`."
  - "OVERRIDDEN — the out-of-agent authority overrode these (see report.md for the authoritative
     record):" + a list, each: "`<criterionId>`[@`<persona>`] — `<inRunVerdict>` → `<verifierVerdict>`;
     reason: <reason>."
  - "NOT VERIFIED — no verification.json for this run; verdicts reflect the in-run agent's self-report
     only. Re-run under an engine that emits verification.json for an independent re-check." }}

## Confidence downgrades
{{ "None." | per-criterion: "`<criterionId>` → confidence low; reason: <reason>." }}

## Verdict
{{ "clean — no out-of-plan acts, no overrides." | "attention — <n> out-of-plan act(s), <m> override(s); see above." }}

Next: `/qa-status "{{target}}"`.
