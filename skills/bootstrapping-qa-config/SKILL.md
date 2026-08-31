---
name: bootstrapping-qa-config
description: Use at the start of a Run when `.qa/config.json` is missing — instead of aborting with "create it from the example", interactively bootstrap it. Infers sensible defaults (DDEV/localhost baseUrl, single-repo, detected stack) via init-config.sh --suggest, asks the user only the gaps (base URL, environment, how to authenticate, whether writes are allowed), then WRITES a valid config deterministically with the script (never hand-authored JSON). Optionally captures a logged-in storageState. Git-ignores `.qa/` automatically.
---

# Bootstrapping the QA Config

## Overview

A first Run in a new project has no `.qa/config.json`. Rather than telling the
user to copy a template by hand, **ask them the few things that can't be inferred
and write the config for them**. The JSON is always produced by
`scripts/init-config.sh` — never hand-authored — so it is guaranteed valid.

## When to Use

- The `/qa-run` command or the agent's pre-flight finds **no `.qa/config.json`**.
- The user explicitly asks to (re)configure qa-e2e-pilot for a project.

## The Process

### Step 1 — Infer defaults (silent)

```
bash skills/bootstrapping-qa-config/scripts/init-config.sh --suggest
```

Returns `{ "baseUrl": "<guess>", "repos": ".", "stack": "<framework>" }`. The
guess comes from `.ddev/config.yaml` (→ `https://<name>.ddev.site`), else an
`artisan`/`package.json` localhost default; `stack` comes from the detector.

### Step 2 — Ask only the gaps (use the host's question UI)

Ask these, each **pre-filled** with the inference from Step 1. In Claude Code use
`AskUserQuestion`; elsewhere ask in plain text:

1. **Base URL** — where the app is served. Default = the inferred guess.
2. **Environment** — `auto` (infer), `disposable` (safe to write/seed), or
   `production` (writes hard-off, conservative). Default `auto`.
3. **Authentication** — one of:
   - **Capture now** — drive a browser login and save a `storageState`.
   - **Use existing** — a path to a Playwright `storageState.json`.
   - **None** — public pages only.
4. **Allow API writes?** — default **no**. If environment resolves to
   `production`, do not offer this — writes stay off.

Do not ask about drivers (default = managed Playwright) or the stack (detected).

The 4 questions above are independent, so one flat batch is correct here. For
tree-shaped HITL confirmation instead (e.g. role/persona confirmation, where
confirming/editing one decision changes the options for a later one), use
[references/hitl-rounds.md](./references/hitl-rounds.md) instead of this flat
form.

### Step 2b — Know the viewport/persona/detection keys (defaults, not asked)

`init-config.sh` doesn't write these — they ship with sensible defaults in
`.qa/config.json.example` and a first-time bootstrap can leave them alone.
Know them so you never overwrite or contradict them when hand-editing is
requested:

| Key | Default | Meaning |
|---|---|---|
| `viewport` | `{"width":1440,"height":900}` | Desktop size Pre-flight applies via `browser_resize` (ADR-0008). |
| `responsiveMatrix` | `[]` | Opt-in extra viewports (e.g. `[{"id":"mobile","width":390,"height":844}]`). Empty = off; only viewport-sensitive UX criteria re-run per listed viewport. |
| `persona.lens` | `"skeptical-auditor"` | The review-lens axis of `persona = role x lens`. This is additive on top of the **role** axis (`personas[]`/`.qa/authz-matrix.json`) that `confirming-discovered-roles` writes — never regenerate roles from here. |
| `detection.ux.objective` / `.advisoryAesthetics` | `true` / `true` | Which UX detector streams run: objective yields a real `fail@FE` verdict; advisoryAesthetics is reported only, never gated (ADR-0007). |
| `passGate.enforce` | `true` | Whether `checkpoint.sh`'s evidence gate (ADR-0010) rejects an unevidenced `pass`. Leave on. |
| `criteriaBudget` | `60` | Soft cap on criteria per pass — a cost lever, not a coverage cut. |

These are **not** part of the Step 2 gap-filling batch — they don't need a
human answer to get a safe default. Only surface them if the user explicitly
asks to tune viewport/persona/detection behavior.

### Step 2c — Per-run persona/lens/viewport subset (a grilling frontier question, not a silent read)

Once `personas[]` exists (written by `confirming-discovered-roles`, which
this skill does not duplicate or re-grill), **every run** — not just the
first bootstrap — faces one further decision: *which of the confirmed
personas, at which lens(es), at which viewport(s), does THIS run exercise?*
Per [hitl-rounds.md](./references/hitl-rounds.md), this is a single-round
grilling frontier question (`dependsOn: []` — it depends on `personas[]`
already being settled, not on anything decided in this round), never a
silent config read and never re-litigated as roles→credentials→scope:

- **Facts** (plugin discovers, never asks): the confirmed `personas[]` list,
  the configured `persona.lens` default, and `responsiveMatrix` (if set).
- **Recommended default** (per the master plan, Decision 11): run **all
  discovered personas**, at the **default viewport only** — the responsive
  matrix stays opt-in per-run even when configured, because multiplying
  every persona across every viewport is a cost decision, not a recall one.
- **Round:** present the full persona list + the lens + the viewport
  set as one numbered batch; the human confirms, drops a persona for this
  run, edits the lens, or opts into the responsive matrix. One round — no
  downstream decision depends on this answer, so there is nothing to
  recompute afterward.
- **Budget-exhausted fallback:** same as any frontier round — auto-accept
  the recommended default and proceed, never block the run from starting.

This question belongs at the **start of a run** (Verify, before the first
persona-tagged criterion) — not inside this skill's Step 2, and not as a
one-time answer baked into `.qa/config.json` at bootstrap time. Wiring the
orchestrator to actually render this round each run is later-phase scope;
until then, treat "config says `persona.lens: X`" as the recommended
default for this round, never as a silent substitute for asking it.

### Step 3 — Write the config (deterministic)

```
bash skills/bootstrapping-qa-config/scripts/init-config.sh \
  --base-url "<answer>" --environment "<answer>" --repos "." \
  --storage-state ".qa/auth/storageState.json" \
  [--allow-writes true]
```

This writes `.qa/config.json`, creates `.qa/auth` and `.qa/runs`, and appends
`.qa/` to `.gitignore`. **Never write the JSON yourself** — always call the script.

### Step 4 — Capture auth if requested

If the user chose **Capture now**: use **driving-browser-qa** to open the login
page, let the user (or supplied credentials) sign in, then save the browser
context's `storageState` to the path above. Never print credentials or cookies.
If they chose **Use existing**, pass that path to `--storage-state` in Step 3.

### Step 5 — Hand off

Confirm the written `.qa/config.json` back to the user in one line, then continue
the Run (pre-flight → detect-stack → analyze → …).

## Guardrails

- **JSON is script-generated, never hand-authored.** Malformed config is a class
  of bug this skill exists to prevent.
- **Never enable `allowApiWrites` on a production or unknown environment.**
- **Secrets stay in the browser** — auth persists via `storageState`, never
  echoed to output, the config, or the report.
- `.qa/` (config, auth, runs) is git-ignored automatically — never commit it.

## Mini-Evals (given → outcome)

1. **DDEV project, no config.** *Given* a repo with `.ddev/config.yaml`
   `name: mayocrm` and no `.qa/config.json`. *Outcome* `--suggest` returns
   `baseUrl: https://mayocrm.ddev.site`; the user confirms; a valid
   `.qa/config.json` is written and `.qa/` is git-ignored — the Run proceeds
   without any manual file editing.
2. **Production target, writes refused.** *Given* the user sets environment
   `production` (or a non-localhost baseUrl with no seed marker). *Outcome* the
   "allow writes?" question is not offered and `allowApiWrites` stays `false`;
   pre-flight later warns it is a real environment.
3. **Malformed-config prevention.** *Given* answers containing characters that
   would break naive hand-authored JSON. *Outcome* `init-config.sh` emits valid
   JSON via `jq`, so the config always parses (the bug class of a hand-edited
   trailing comma never occurs).
