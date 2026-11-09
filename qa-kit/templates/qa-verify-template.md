# Verification — {{target}}

**Run:** `{{run-id}}`  ·  **Checked:** {{n-passes}} passes  ·  **Planned criteria:** {{n-planned}}

## Out-of-plan acts
{{ one of: "None — every acted criterion was in the frozen plan." | a bullet list of offending
criterion ids, each: "`<id>` — acted but absent from checklist.json (process violation)." }}

## Plan drift (run copy vs the frozen spec plan)
{{ one of: "None — the run's checklist.json matches the frozen plan on every trust-bearing field." |
"NOT CHECKED — no frozen spec plan resolved for this run." | a bullet list, each:
"`<id>`.`<field>`: `<frozen>` → `<run>` — the gates ran against a weaker plan than the one approved."
plus "`<id>` — added in-run, absent from the frozen plan." and "`<id>` — in the frozen plan, missing
from the run copy." }}

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

## Independent re-adjudication (authoritative source: the engine's adjudication/ folder)
{{ one of:
  - "Re-judged <n> record(s); the second judge agreed with <a>." + when it disagreed, a list of
     verifier overrides, each: "`<criterionId>`[@`<persona>`] — now <verdict>/<confidence>; reason:
     <reason after `verifier-disagrees:`>." (a disputed pass is now `blocked`, a disputed fail is now
     confidence `low`; nothing is ever upgraded) + every `ADJUDICATION:` line from
     `adjudication/apply.txt`, quoted.
  - "Nothing to re-judge — no low-confidence passes and no UX-promoted fails."
  - "UNAVAILABLE — " + the banner from `adjudication/unavailable.txt`, quoted verbatim. Those passes
     were not re-judged.
  - "DID NOT RUN — <n> low-confidence passes unreviewed; run `/qa-e2e-pilot:re-adjudicating-verdicts`
     before relying on them." }}

## Verdict
{{ "clean — no out-of-plan acts, no plan drift, no overrides, no verifier overrides." | "attention — <n> out-of-plan act(s), <d> plan-drift finding(s), <m> override(s), <k> verifier override(s); see above." }}

Next: `/qa-status "{{target}}"`.
