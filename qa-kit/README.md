# qa-kit — a step-gated QA process shell

`qa-kit` is a second plugin in this repo: a spec-kit-style, **step-gated** process shell layered over
the **qa-e2e-pilot** engine. Each step produces one human-reviewable artifact and populates the
engine's existing gate inputs; **qa-e2e-pilot stays the verification engine** (driving, baking, oracle
recomputation, probing, verdicts, evidence). qa-kit adds the *process*, not new verification logic.

## Install (Claude)

Enable the `qa-kit` entry from this repo's marketplace. Its `plugin.json` declares
`"dependencies": [{ "name": "qa-e2e-pilot", "version": "~0.12.0" }]`, so the engine is co-installed
at the highest `qa-e2e-pilot--v0.12.x` git tag (qa-kit 0.3.0 relies on the engine's 0.12 gates,
census and journeys; the constraint resolves only against those release tags). qa-kit reuses the engine's skills by
qualified slug (`/qa-e2e-pilot:<skill>`) and bundles its own scripts under `qa-kit/scripts/`. The engine
installs standalone and unchanged.

## Running on other harnesses (Codex · Pi · opencode)

Since increment 7 ([ADR-0024](../docs/adr/0024-qa-kit-multi-harness.md)) qa-kit runs on all four harnesses.
Claude is the reference build; the others are generated from the shared `qa-kit/core/` (a qa-kit-owned copy of
the engine's ADR-0017 pipeline) into git-ignored `qa-kit/dist/<h>/` and installed per harness. **Install the
engine adapter for that harness FIRST** (the co-install contract — qa-kit's step commands reference the
engine's skills; each installer aborts if the engine's skills dir is absent):

```bash
bash harnesses/pi/install-pi.sh <project>          # engine first  (or codex / opencode)
bash qa-kit/harnesses/pi/install-pi.sh <project>   # then qa-kit
```

Skill references render per harness — Claude `/qa-e2e-pilot:<name>`; **Pi/Codex** a bare `` the `<name>` skill ``
(read from the engine's `.pi/agents/skills/` / `.agents/skills/`); **opencode** the `skills_<name>` tool, which
**requires the community `opencode-skills` plugin** enabled in `opencode.json`. Per-harness details:
`qa-kit/harnesses/<h>/README.md`. Generator + composition are covered by `tests/qakit-adapters/run.sh`; a live
end-to-end run per non-Claude harness is the **manual accuracy run**.

## The spine

| Step | Command | Produces | Notes |
|------|---------|----------|-------|
| 1 | `/qa-constitution` | `.qa/constitution.state.json` (machine) + `.qa/constitution.md` (human) | Roles regenerate **wholesale** (ADR-0011) + a version/hash + an informational diff on re-run. Customization is per-spec, never here. |
| 2 | `/qa-spec <target>` | `.qa/specs/<target>/{qa-spec.md, spec-roles.json, run-config.json}` | Pins an **immutable, version-stamped** role snapshot from the constitution + per-spec overrides + run-config deltas. Surfaces a **drift advisory**. One spec → N runs. |
| 3 | `/qa-scenarios <target>` | `scenarios.md` + `checklist.json` | Compiles the frozen plan (reusing the engine's checklist writer) scoped to the spec's snapshot roles; every scenario role must be in the snapshot. **This `checklist.json` is the enforcement contract.** |
| 4 | `/qa-analyze <target>` | `analysis.md` (+ `oracle-confirm.html` when needed) | Read-only coverage/consistency gate, advisory except the census coverage gate, which **blocks** a `ship` run while any role × surface pair is uncovered. Renders the oracle confirmation page for unconfirmed computed rows (step 4c). |
| 5 | `/qa-e2e-pilot:qa-run "<target>" .qa/specs/<target>/checklist.json` | `.qa/runs/<id>/…` | The engine's existing run — ingests the frozen `checklist.json` (it already accepts a checklist/spec path), freezes it (`plan_frozen`, ADR-0020), drives/bakes/verifies/reports. |
| 6 | `/qa-verify <target> [<run-id>]` | `.qa/specs/<target>/verification.md` | Post-run verification: the out-of-plan-act check (`verify-plan.sh` — the one enforcement seam below) plus a qa-kit-flow-native restatement of the engine's deterministic overrides (`verification.json`). Reports; the script results are the gate. |

`/qa-tracker` sets up ClickUp tracking; `/qa-auto <target>` runs steps 1 to 6 unattended. `/qa-status [<target>]` shows where you are + any constitution drift. For run-level detail (progress, ETA, verdicts, bugs, ship readiness, trends) use the engine's `/qa-dashboard`.

## The one enforcement seam (qa-verify unmodified)

The engine's `qa-verify` verifies recorded passes but does **not** reject an act on a criterion absent
from the plan (increment-4 finding — see ADR-0022). qa-kit closes that with a standalone
`qa-kit/scripts/verify-plan.sh` run **beside** `qa-verify`: it compares the run's acted
`checkpoint.json[].criterion_id` against the frozen `checklist.json[].id` and flags any out-of-plan act.
`qa-verify` itself is never modified.

## Tracking cases, runs and bugs

`/qa-tracker` picks where the QA work is tracked: local files, GitHub or ClickUp. It writes
`docs/agents/qa-tracker.{md,json}`. After that, `qa-kit/scripts/tracker.sh <verb>` keeps the
tracker in step with the catalog and the runs, as a dry run unless you pass `--apply`. The design
is `docs/superpowers/specs/2026-11-10-qa-tracker-design.md`.

## ClickUp tracking per spec and run

A spec can be tracked in ClickUp so the people who follow the QA (admins, testers, the team) see it
without opening the repository. A tracked spec gets one subfolder in the QA folder, a Doc, and one
list per run. Each scenario is a ticket in the list and each check is a subtask. Statuses follow the
run's results. Screenshots are attached to the ticket. The Results page is the run's report.
Decisions and the layout are in [ADR-0034](../docs/adr/0034-clickup-spec-layout.md).

### Set it up

Three levels, nearest wins: the spec, then the project, then the machine.

- **Machine, once:** `/qa-tracker --global` asks for the ClickUp workspace and the name of the
  environment variable that holds your token (default `CLICKUP_API_TOKEN`) and writes them to
  `~/.config/qa-kit/tracker.json`. The token is never asked for and never written.
- **Project, once:** `/qa-tracker` chooses ClickUp, the workspace, space and QA folder, and writes
  `docs/agents/qa-tracker.{md,json}`. It prints the few clicks the ClickUp API cannot do (custom
  fields `Ref`, `Role`, `Needs a person's review`, `Build` and the statuses, added once at folder
  level). Do them, then run `tracker.sh init` again.
- **Spec:** `/qa-tracker --spec <target>` saves `specs.<target>.enabled: true` (or the id of a folder
  or list you paste), shows `tracker.sh spec-init --spec <target>` as a dry run, and builds it after
  your yes. Settings shared by every spec go under `specDefaults`; a spec overrides them under
  `specs.<target>`. Keys: `layout` (`subfolder` or `flat`), `listMode` (`fresh` or `reuse`),
  `evidence` (`standard`, `failures` or `none`), `evidenceCap`, `keepRuns`, `language`, `notify`,
  `reportUrl`, `tokenEnv`.

### What each command does once a spec is tracked

Every step first gives its own result. When its ClickUp step then fails, the command stops, prints
the tracker's one-line error and says ClickUp was not updated. A spec that is not tracked never
contacts ClickUp.

| Command | ClickUp step |
|---|---|
| `/qa-spec` | Creates the spec's subfolder and Overview doc. |
| `/qa-scenarios` | Writes `tracker-cards.json` (the scenarios in plain words for the team), lints it, creates the tickets and subtasks in the run list, writes the Scenarios page. |
| `/qa-analyze` | Comments the coverage note on the Run summary ticket; marks it blocked when the Verdict is `BLOCKED`. |
| `/qa-verify` | Files the run's bugs, moves each ticket to the status its result gives, attaches evidence, writes the Results page and the project Doc. |
| `/qa-status` | Prints the ClickUp links and whether ClickUp is behind. |

A person's change to a ticket's status is left alone and reported. A pass stays in `testing` until a
person confirms it, unless it was recorded and verified at high confidence. Nothing is deleted:
old lists are archived.

### The tracker verbs

Run them as `bash qa-kit/scripts/tracker.sh <verb>`. Every verb is a dry run until `--apply`.

| Verb | Flags | Does |
|---|---|---|
| `lint` | `--spec` | Checks `tracker-cards.json` against the plan and the writing rules. No token. |
| `spec-init` | `--spec` | Creates the subfolder and Overview doc, or binds a pasted folder or list. |
| `push-scenarios` | `--spec` | Writes the scenario tickets and check subtasks. |
| `sync-run` | `--spec`, `--run`, `--retest` | Moves each ticket to its result's status and attaches evidence. `--retest` reuses the newest list. |
| `push-docs` | `--spec`, `--run` | Writes the Overview, Scenarios and Results pages and the project Doc. |
| `spec-note` | `--spec`, `--file`, `--blocked` | Comments the note in the file on the Run summary ticket; `--blocked` also sets it to blocked. |
| `spec-status` | `--spec` | Prints one JSON line: the links and whether ClickUp is behind. |
| `push-bug`, `update-retest` | `--spec`, `--run` | The bug verbs; with `--spec` they use that spec's settings. |

Without `--spec` a spec verb uses the only enabled spec, and stops with an error when it cannot
tell which. The catalog verbs (`init`, `push-plan`, `pull-plan`, `push-run`, `push-results`,
`status`, `validate`, `results`) are unchanged.

### Writing rules

The text is read by people who were in the meeting. `templates/trackers/writing-rules.md` is appended
to `docs/agents/qa-tracker.md` at setup and `lint` enforces what a script can: no emojis, no
forbidden words (AI, agent, automation, Claude, Playwright), no commit hashes, file paths,
criterion ids or code terms, short sentence-case titles, no empty or repeated text, no mention of a
person unless the config's `notify` names one. An item that fails is skipped, never sent in part.
Passwords are masked.

### Before you rely on it

Every ClickUp test uses an in-memory fake. Nothing has run against a real workspace. Do this once, on
a workspace you can spare, before trusting it:

1. Run `spec-init --spec <target> --apply` and check the subfolder appears inside the QA folder.
2. Check the custom fields (`Ref`, `Role`, `Needs a person's review`, `Build`) are read from the folder.
3. Check each run list has its views.
4. Open the links on the Results page and the project Doc: task, list, folder, Doc and page.
5. Set `notify` to your own user id and check the comment mentions you once.
6. Run `push-docs` twice and check the Doc is rewritten, not duplicated.
7. Archive a run list by hand and check the next sync still finds the others.

## The unattended journey: `/qa-auto`

`/qa-auto <target> [--profile ship|smoke|full] [--until <step>] [--max-hours <n>] [--restart]` runs
constitution → spec → scenarios → analyze → run → verify for one target with nobody present. It needs
a `.qa/config.json` and working sign-in for the roles. Run it in the main session. Design:
[ADR-0035](../docs/adr/0035-unattended-journey.md).

- **What it does.** `auto.sh` keeps the journey in `.qa/specs/<target>/auto/` and says what is next;
  the agent does each step by following that step's own command. Every question a step would have asked
  a person is answered from the project's evidence and recorded (`decisions.json`) as an assumption.
  After the spec and scenarios steps a fresh agent looks at those answers and can only hand one to a
  person. A tracked spec is kept current in ClickUp.
- **What it never decides.** A seed command (it never runs one), a coverage exclusion, accepting a
  census built without the stack adapter, a person-confirmed expected value, any safety setting
  (`allowApiWrites`, `seedableEnvMarker`, `environment`, `allowBlackboxCrawl`, `gates`, `profile`,
  `humanInteraction.enforce` and `maxOptOutRate`) and the known-defect registry. An expected value it
  chose is a proposal: the check can pass only at low confidence and goes on the handoff list. It
  does not fix the application. It refuses production.
- **The handoff.** `.qa/specs/<target>/auto/handoff.md` holds the result, the scope chosen, what was
  decided without a person, what still needs one, the records the run created and how to confirm. The
  result is `ready`, `not confirmed`, `not ready`, `verified`, `not verified` or `stopped`, worked out
  from files and never better than what the engine recorded. `/qa-status <target>` shows an open or
  stopped journey.
- **Continue or restart.** Run `/qa-auto <target>` again: an open journey, or one that stopped for
  `time-limit`, `step-failed` or `until`, continues where it stopped, and an interrupted run is
  resumed, not started again. `--restart` abandons the journey and starts a new one; the old one moves
  to `auto/history/`. A finished journey is never continued: starting again opens a new one that keeps
  the spec and scenarios and runs analyze, a new run and verify.
- **The audit and its limits.** `auto.sh audit` runs at the end of every journey and fails it when a
  safety setting, the registry, a seed file, an exclusion, a person-confirmed expected value or a row
  of the starting plan changed, a step has no result, the run was not verified, or ClickUp is behind
  (eighteen codes: `baseline-missing`, `baseline-changed`, `base-url-changed`, `safety-setting-changed:<key>`, `run-config-safety:<key>`, `known-defects-changed`, `human-oracle-added:<id>`, `human-oracle-removed:<id>`, `human-oracle-changed:<id>`, `plan-row-removed:<id>`, `plan-unreadable`, `seed-added`, `exclusion-added`, `forbidden-decision:<id>`, `decisions-unreadable`, `step-without-result:<step>`, `not-verified`, `tracker-behind`). It reads files the agent can also write. It cannot see a change that was changed
  back, a baseline and journey rewritten together, or a fresh baseline taken with `--restart` after a
  change (the new journey says `replacedFrom`). It is a tripwire against drift and mistakes, not
  protection against an agent set on defeating it.

## Bundled helpers (`qa-kit/scripts/`, pure + dual-engine)

- `constitution.sh` — `version` / `diff` / `state` / `render`.
- `spec-snapshot.sh` — `create` (copy+stamp+override) / `drift`.
- `verify-plan.sh` — out-of-plan-act enforcement.
- `runconfig-merge.sh` — effective run config = spec deltas over `.qa/config.json` (per-run, no mutation).
- `data-baseline.sh` — validate `data-baseline.json` (origin/identity/scope) + `expected-count` (measured + delta).
- `check-fixtures.sh` — computing criteria (`kind ∈ {computed-logic, business-rule}`) must carry a well-formed pinned expect.
- `detect-seed.sh` — (6b) propose the stack's seed command by READING the engine's `stack-profile.json` (backend component's `framework`/`orm.name`); never modifies `detecting-stack-profile`.
- `auto-seed.sh` — (6b) `decide` the opt-in write gate: `allowApiWrites` + non-empty `seedableEnvMarker` (excluding the literal bootstrap sentinel `"QA_DISPOSABLE_ENV"`, never a deliberate opt-in) + `environment != production` (mirrors the engine's write gate). Decides only; never execs.
- `migrate-inverted-criterion.sh` — lift a criterion that asserts an application failure into `.qa/known-defects.json`; exits 2 on success until a human fills `ticket`/`expiry`.
- `surface-access.sh` — `derive` / `confirm-table` / `apply [--assume]` / `personas`: who SHOULD reach each census surface (`.qa/surface-access.json`). Crawl reach on a hinted surface without a matching permission hint is never `allowed` until a human confirms it; `--assume` (autonomous setup) marks entries `assumption:true` and never denies.
- `generate-ship-criteria.sh` — census + access + authz matrix → generated rows: load-clean sweep, deny rows only where permission evidence exists, same-role ownership isolation, form input edge cases (with a sampled URL and an action that reaches the form), UX revisits per viewport × locale × color scheme. Token-safe ids; overflow past `criteriaBudget` reported, never dropped.
- `coverage.sh` — role × surface coverage (`covered` / `covered-sweep` / `excluded` / `uncovered`); `--mode block` exits 1 on any uncovered pair, an empty census, or a failed adapter without `--accept-crawl-only`. `--scope` / `--roles` / exclusion globs scope it.
- `tracker.sh` — the QA tracker: catalog verbs plus the spec verbs above; Python under `scripts/trackers/` (`cli.py`, `clickup*.py`, `cards.py`, `spec_runs.py`, `spec_docs.py`, `wording.py`, `core.py`). Never touches the engine.
- `auto.sh` — the state machine of an unattended journey: `start` / `resume` / `stop` / `status` / `next` / `step-start` / `step-done` / `signin` / `decide` / `second` / `note` / `audit` / `handoff`. Writes only under `.qa/specs/<target>/auto/`; calls no engine script.
- `oracle-confirm.sh` — `render <checklist> <out.html>`: an offline page (works from `file://`, no network) grouping unconfirmed expected values by business rule, with accept / edit / unknown per row or per group, saving `oracle-decisions.json`; `apply <checklist> <decisions>`: accepted and edited values become `oracleSource: "human"` (backup `checklist.json.bak`), unknown stays as it was. `check-fixtures.sh` also accepts `oracleSource: "spec"` with a contained `citation` `<path>:<line>`. Only `human`/`spec` can ground a high-confidence pass (the engine's ORACLE GATE, ADR-0032).

All are covered by dual-engine tests under `tests/{constitution,spec-snapshot,qa-kit-enforcement,runconfig-merge,data-baseline,check-fixtures,detect-seed,auto-seed,qa-kit-phases,surface-access,ship-criteria,coverage-gate,oracle-confirm,qa-tracker,qa-auto,qa-auto-decisions,qa-auto-audit,qa-auto-gate,qa-auto-handoff,qa-auto-steps,qa-auto-limits,qa-auto-settings,qa-auto-lock,qa-auto-audit-plan,qa-auto-audit-journey}/run.sh`
(cross-engine byte-identity + malformed-input symmetry). The full **phased ≡ one-shot** verdict
equivalence needs a live browser agent and is the **manual accuracy run**'s job (`docs/harness-adapters.md`),
not a headless test.

## Data (TDQA)

qa-kit is **test-data-driven**: declare the data, pin the expected results, then the run asserts.

- **`/qa-spec`** authors `.qa/specs/<target>/data-baseline.json` — the entities scenarios touch, each
  flagged **`origin: seeded`** (pre-existing baseline; declare a minimal identity to verify it) or
  **`created`** (the run makes it via the UI), optionally tenant/persona-`scope`d.
- **`/qa-scenarios`** pins each criterion's `actionInput` + expected into both the prose oracle (the engine
  reads it natively) and a structured `checklist.json` `fixture` field. For **computed/business-rule**
  criteria a human confirms **both** the tricky input and the expected at the HITL gate (or on
  `/qa-analyze`'s oracle confirmation page) — that, or a `spec` citation, earns `confidence: high`; an
  `llm-suggested` pin runs `confidence: low`. Since engine 0.12.0 this is enforced: `checkpoint.sh`
  refuses a high-confidence pass on a row whose `oracleSource` is not `human`/`spec`.
- **The multiplicity fix:** because the baseline distinguishes seeded from created, empty-state expects the
  **measured seeded baseline** (not 0) and N-create expects `baseline + N` — authored into the fixtures, so
  the engine is untouched.
- **`check-fixtures.sh`** (beside `verify-plan.sh`) flags a computing criterion with no well-formed pinned
  expect; `.qa/config.json` `fixtures.hardBlock` (default false) chooses advisory vs block.

**Establishment: declare-and-verify by default (writes nothing)** — the run reads the baseline back and defers a
criterion whose required seeded precondition is absent. **Opt-in auto-seed (6b)** can first *establish* the
`seeded` baseline, disposable-env only: `/qa-spec` proposes the stack's seed command via `detect-seed.sh` (a
human confirms or edits it into `.qa/specs/<target>/seed.json`), and at pre-flight the run runs it **only** when
`auto-seed.sh decide` returns `seed:true` (writes allowed + disposable + not production) **and** a human
confirms — then falls through to the same declare-and-verify read-back to confirm the baseline landed. On a
non-disposable env qa-kit never writes. See [ADR-0023](../docs/adr/0023-qa-kit-tdqa-data-layer.md).

qa-kit inherits the engine's usage boundary as-is — see [the engine README's "When NOT to use
this"](../README.md#when-not-to-use-this) (per-commit gating: no; shared staging: degraded; a green
run is measured recall, never "verified correct").

## Invariants qa-kit inherits (does not redefine)

Verdicts `pass|fail|blocked|deferred|error`; confidence `high|low`; the oracle is the spec/domain rule,
never the backend's formula; run state lives in `.qa/`; UI-only action-under-test (ADR-0015). See the
repo `CONTEXT.md` + ADR-0015/0018/0020.
