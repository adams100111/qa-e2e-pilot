# QA Constitution

This is **this project's** QA policy — the roles it tests as, the optional gates it turns on, and
where the oracle stops. It does **not** restate the plugin-universal invariants (verdict vocabulary,
suspected-layer taxonomy, human-interaction discipline, evidence enforcement) — those live in
[`CONTEXT.md`](../CONTEXT.md) and [ADR-0015](../docs/adr/0015-human-interaction-discipline.md) /
[ADR-0018](../docs/adr/0018-out-of-agent-evidence-enforcement.md), and every run obeys them
regardless of what this file says. Copying them here would only let this file drift out of sync
with them — reference them instead.

<!-- Adjust the two `../` path prefixes above if this file is not read from `.qa/constitution.md`
     relative to the repo root. -->

> **Regeneration note:** `/qa-constitution` re-renders this entire file from
> `core/qa-kit/constitution-template.md` every time it runs (only `{{ROLES_TABLE}}`, `{{VERSION}}`,
> and `{{TIMESTAMP}}` below are machine-filled — everything else, including your edits to "Enabled
> optional gates" and "Oracle notes" below, is plain template text that gets reset on a re-render).
> `.qa/` is git-ignored, so there is no VCS safety net either. If you've customized the sections
> below, save a copy or re-apply your edits after re-running `/qa-constitution`.

---

## Roles

The authoritative role state is `.qa/config.json`'s `personas[]` + `.qa/authz-matrix.json` —
this table is a human-readable summary of it, regenerated wholesale by `/qa-constitution`
(never hand-edited; see ADR-0011). Per-role customizations for a specific run belong in that
run's spec, not here.

{{ROLES_TABLE}}

---

## Enabled optional gates

Which of qa-kit's optional gates this project turns on for its runs. Each gate reads the
completed run's evidence under `.qa/runs/<run-id>/` — none of them re-drive the browser. This is a
plain human-edited table, not a render placeholder — fill in "yes"/"no" (and any project-specific
notes, e.g. a perf budget or a security scope exclusion) directly.

| Gate | Enabled | Notes |
|------|---------|-------|
| `/qa-sanitize` | no | |
| `/qa-assure` | no | |
| `/qa-perf` | no | |
| `/qa-security` | no | |
| `/qa-uiux` | no | |

---

## Oracle notes / out-of-scope

Project-specific notes on where the spec/domain oracle lives for this project, and anything this
project's QA runs deliberately do not attempt to verify (e.g. a third-party integration only
smoke-tested, a legacy area frozen for rewrite, a computation intentionally left to a downstream
gate). This is guidance for whoever authors a spec against this constitution — it is not itself
machine-enforced.

_(fill in — plain human-edited prose, not a render placeholder)_

---

## Version

{{VERSION}} @ {{TIMESTAMP}}

<!-- This line is a human-readable pointer only. The authoritative machine state — the exact
     role set this version hashes — lives in the sibling `.qa/constitution.state.json`, written
     by `constitution.sh state`. Never parse this file to recover the version; read that one. -->
