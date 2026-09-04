# CLAUDE.md — working in qa-e2e-pilot

This repo is a **Claude Code plugin**, not an app. It ships an agent, a command, and ten skills that perform full-stack browser QA. There is no build step and no runtime test suite; "tests" here means static validation + functional smoke-tests of the bundled scripts.

**Two plugins live here.** `qa-e2e-pilot` (repo root) is the **verification engine**. `qa-kit/` is an optional, step-gated **process shell** built on it — a *second* plugin with its own manifest, commands, scripts, and agent that declares `dependencies: ["qa-e2e-pilot"]` and reuses the engine's skills by qualified slug (`/qa-e2e-pilot:<skill>`). **The engine must stay byte-for-byte unchanged when working on qa-kit** (`core/`, root `commands/`/`skills/`/`scripts/`, `qa-verify.sh`, the byte-oracle) — qa-kit is purely additive. qa-kit is Claude-only in v1; see [ADR-0022](./docs/adr/0022-qa-kit-process-shell.md), [`qa-kit/README.md`](./qa-kit/README.md), and the `qa-kit-plugin-packaging-facts` memory (per-plugin `${CLAUDE_PLUGIN_ROOT}`; no symlinks; `commands` is a dir not an array).

## Read these first

- **[CONTEXT.md](./CONTEXT.md)** — the ubiquitous language. Use these words exactly: *criterion/step/run*, *baking*, *multiplicity*, *oracle*, *reconciliation*, *verdict*, *confidence*, *suspected layer*, *driver/session*, *probing*, *memory-spec*, *checkpoint*. Don't invent synonyms.
- **[docs/adr/](./docs/adr/)** — the hard-to-reverse decisions: 0001 reimplement opslane patterns (don't fork/vendor), 0002 run state in `.qa/runs/` not agent memory, 0003 sequential verification (narrow parallel pool), 0004 per-project `.qa/config.json`, 0017 multi-harness portability (shared core + generated adapters, Claude byte-oracle), 0022 qa-kit process shell (2nd plugin, dependencies model, `qa-verify` untouched, regenerate-wholesale constitution).

## Invariants (do not break)

- **Verdicts are exactly** `pass | fail | blocked | deferred | error`. **Confidence** is orthogonal: `high | low` (low when the expected value could only come from backend code). Never add a sixth verdict (`skip`/`warn`/`partial`).
- **Suspected layer** is exactly one of `FE | route | service | migration | DB`. Recorded on a `fail`; flows into the report and bug-log.
- **The oracle is the spec/domain rule, never the backend's own formula.** `verifying-computed-logic` recomputes independently; reading backend code only *localizes* a divergence.
- **Run state lives in `.qa/runs/<run-id>/`** as plain files — never the agent's personal memory / `MEMORY.md` (ADR-0002).
- **Verification is sequential by default** (ADR-0003). Parallel fan-out is opt-in, only for tagged independent/read-only criteria + deliberate race tests, capped at `maxParallel`.
- **Probing is read-only** unless `allowApiWrites` *and* the disposable-env marker are set. **Secrets never printed.**
- **Browser tools are called by capability**, naming the Playwright MCP tool in parens (e.g. `browser_snapshot`). New drivers drop in via config, not code.
- **The action-under-test is performed through real UI affordances only** (ADR-0015). `human-action` is an evidence **kind**, never a verdict. The act phase uses human-path tools (click/type/…); a mutating `browser_evaluate`/`route`/direct write on the act path is a workaround the gate rejects. A UI-impossible action is `fail@FE` (confidence high); a genuine tool limitation is a logged `--nonui-reason` opt-out (confidence low). Never weaken the gate to force a `pass` through.
- **qa-kit never modifies the engine** (ADR-0022). The `qa-kit/` process shell is additive: it reuses the engine's skills by qualified slug and bundles its own scripts under `qa-kit/scripts/` (per-plugin `${CLAUDE_PLUGIN_ROOT}` — it cannot reference the engine's files). `qa-verify` stays untouched; qa-kit's out-of-plan-act enforcement is a *separate* `qa-kit/scripts/verify-plan.sh` run beside it. The constitution regenerates roles **wholesale** (ADR-0011) + an informational diff; per-role customization is a per-spec concern, never the constitution.

## Layout

```
.claude-plugin/{plugin.json,marketplace.json}   plugin metadata (name, MIT, keywords)
agents/qa-e2e-pilot.md                           the 6-phase orchestrator
commands/qa-run.md                               /qa-run <target> [checklist|spec]
skills/<gerund-name>/SKILL.md                    one skill each (+ scripts/ and templates/)
scripts/{install.sh,skills.json}                 manual + npx install paths
.qa/config.json.example                          per-project config template
harness-profiles.json                            per-harness naming/model/dispatch/server-key table (ADR-0017)
core/                                             shared tokenized persona + command sources (Codex/Pi/opencode render from these)
harnesses/<codex|pi|opencode>/                    per-harness manifest.tmpl + mcp.snippet + install-<h>.sh + README.md
scripts/build-adapter.sh                          generator: assembles git-ignored dist/<h>/ from core + harness-profiles.json + harnesses/<h>/
scripts/validate-adapters.sh                      CI gate: builds all 4 adapters, enforces the Claude byte-oracle, checks for residual {{tokens}}
qa-kit/                                          the 2nd plugin (process shell): .claude-plugin/plugin.json (dependencies:[qa-e2e-pilot]),
                                                 commands/{qa-constitution,qa-spec,qa-scenarios,qa-analyze,qa-status}.md, scripts/{constitution,
                                                 spec-snapshot,verify-plan,runconfig-merge}.sh, templates/, agents/qa-kit.md, README.md
tests/{constitution,spec-snapshot,qa-kit-enforcement,runconfig-merge,qa-kit-phases}/run.sh   qa-kit's dual-engine tests
```

**Multi-harness note (ADR-0017):** `agents/qa-e2e-pilot.md`, `commands/qa-run.md`, and
`commands/qa-roles.md` are **generated-and-committed** — their content originates from `core/` +
`harnesses/claude/manifest.tmpl` via `scripts/build-adapter.sh claude`, and must stay byte-identical to
that generator's output (`validate-adapters.sh` enforces this diff in CI). Edit `core/persona-body.md`
or `core/commands/*.md`, not the repo-root files directly, then regenerate. `dist/` is build output and
is git-ignored — never commit it. See `docs/harness-adapters.md` for per-harness install + the manual
accuracy-run procedure.

## Skill conventions (when adding/editing a skill)

- Frontmatter has **only** `name` + `description`. `name` **must equal the directory name**, be lowercase-hyphen, gerund, ≤64 chars, and not contain "claude".
- `description` is third-person, ≤1024 chars, starts with "Use when …", and states WHAT + WHEN.
- Body **< 500 lines**, imperative, checklist-structured (plan → validate → execute). References one level deep.
- Bundle **scripts** (executed) and **templates** (copied) — don't inline large artifacts into the body.
- Include **≥3 mini-evals** drawn from the 14 real session bugs (see the plan / the existing skills for the bug list).

There are **17 skills**: the 10 core verification skills + `fanning-out-criteria` + spec-kit `ingesting-spec-kit` + role discovery (`discovering-user-roles`, `confirming-discovered-roles`) + `detecting-stack-profile` + `detecting-visual-ux` + `detecting-interaction-ux` + `bootstrapping-qa-config`. Top-level `scripts/` (not skills): `report-to-junit.sh` (CI export), `qa-ci.sh` (turnkey CI: preflight→agent→junit, pluggable via `QA_AGENT_CMD`/`QA_PREFLIGHT_CMD`), `memory-sync.sh` (gated Mem0/vector write-through of durable artifacts only). Drivers map to tools via `skills/driving-browser-qa/references/driver-capabilities.md`. Docs `running-in-ci.md` and `extending-drivers.md` cover later-phase capabilities. `install.sh` globs `skills/*/`, so new skills are picked up automatically.

**Human-interaction discipline (ADR-0015).** State-mutating criteria are tagged `human-action`; their `pass` is gated by `checkpoint.sh` via an act-phase workaround lint + mandatory before/after state fingerprints (`check-action-trace.js`), and — when the Playwright MCP is run with `--save-session` (opt-in; not the default managed instance) — an additional reconciliation of the recorded act against that independent log (`parse-session-log.js`), which closes the self-report hole. Without `--save-session` the gate runs the lint+fingerprint checks and flags that independent verification was unavailable. The act phase is UI-only; a UI-impossible action is `fail@FE` (confidence high), not a workaround; a genuine tool limitation is a logged low-confidence `--nonui-reason` opt-out. See `skills/driving-browser-qa/references/interaction-discipline.md`.

## Bundled scripts depend on jq OR python3

`checkpoint.sh` and `preflight.sh` prefer `jq`, fall back to `python3`, and error clearly if neither is present; `report-to-junit.sh`, `memory-sync.sh`, and `find-spec-kit.sh` use `python3`/`jq` similarly (`memory-sync.sh` also needs `curl` for a real send). Browser-context JS (`react-set-input.js`, `click-by-text.js`, `backend-probe.js`) is injected via the evaluate tool — write it as dependency-free browser code (`document`/`window`/`fetch`).

## Validate before committing

```
# frontmatter limits, body length, JSON validity
for f in $(find . -name '*.json' -not -path './.git/*'); do python3 -c "import json;json.load(open('$f'))"; done
for f in $(find . -name '*.sh'); do bash -n "$f"; done
for f in $(find . -name '*.js'); do node --check "$f"; done
# functional smoke: checkpoint.sh insert/upsert/resume/list -> valid JSON; preflight.sh aborts on a dead app
```

End commit messages with the required `Co-Authored-By` trailer. Only push when asked.
