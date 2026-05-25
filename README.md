# qa-e2e-pilot

**Browser-driven end-to-end QA that verifies a feature's full stack — not just what the screen renders, but what the backend computed, stored, and constrained.**

> A green toast is not a pass.

`qa-e2e-pilot` is a Claude Code plugin. It drives a real browser through a feature, then does the three things UI-only QA tools skip: it **bakes** (reads persisted state back out of the backend at multiplicity 0/1/N), it **recomputes the feature's logic independently** from the spec (vesting, ownership %, `amount = shares × price`, …) and reconciles it across FE / API / DB, and it **checkpoints a resumable memory trail** so a long campaign survives context compaction. When the UI lies, it **probes** the backend for the real error.

It was distilled from a manual, browser-driven QA session of a cap-table governance module that caught **14 real bugs** pure API/unit tests missed — including a sub-cent precision bug (`4,000,000 × $0.001` truncated to the wrong total by a `decimal(_,2)` column) that only an *independent recompute reconciled against the migration* would catch.

---

## Why this exists (the gap)

The 2026 toolbox already covers a lot, so this plugin deliberately does **not** rebuild it:

| Prior art | What it does | The gap it leaves |
|---|---|---|
| [`opslane/verify`](https://github.com/opslane/verify) (MIT) | acceptance-criteria → Playwright-MCP browser per-AC → single-file HTML report | UI/visual **only — no backend/DB persistence checks**; one-shot (no resumable memory); managed Playwright only |
| Playwright Test Agents (planner/generator/healer) | author & maintain `.spec.ts` | authoring, not exploratory verify-and-report |
| spec-kit | constitution → specify → plan → tasks → implement | **no runtime verification agent** (acknowledged gap) |

The un-filled gap is exactly this plugin's core:

1. **Backend baking** — after a UI write, read the data back and confirm it persisted + at the right multiplicity (0/1/N).
2. **Computed-logic verification** — independently recompute the feature's calculations, reports, and business-rule outcomes *from the spec/domain oracle* (never the backend's own formula), reconcile across layers, and trace downstream impact (action → dependent entities).
3. **Persistent, resumable QA memory** — typed run artifacts on disk so a long run survives compaction.
4. **Direct backend probing** for masked errors (read the network body / call the API with the page's cookies).
5. **Attended CDP** to your own logged-in Chrome (incl. Windows-Chrome-from-WSL) — *opt-in*; the default is a zero-config managed browser.

Browser **mechanics** are delegated to the Playwright/CDP MCP — not rebuilt.

---

## What's in the box

```
.claude-plugin/   plugin.json + marketplace.json
agents/           qa-e2e-pilot.md      — the 6-phase orchestrator
commands/         qa-run.md            — /qa-run <target> [checklist|spec]
skills/           9 skills (see below)
scripts/          install.sh + skills.json (manual + npx install)
.qa/              config.json.example + per-run output
docs/adr/         0001–0004 architecture decisions
CONTEXT.md        the ubiquitous language (read this first)
```

**The 6-phase pipeline** (the agent orchestrates these skills in order):

| Phase | Skill | Does |
|---|---|---|
| 0 Pre-flight | `driving-browser-qa` (`preflight.sh`) | app live? auth present? enumerate+ping drivers; record build/deploy id |
| 1 Analyze *(v1.1)* | `analyzing-feature-ui` | build `surface-map.json`: routes, elements, per-surface states; cross-map to backend |
| 2 Generate *(v1.1)* | `generating-qa-checklist` | derive a human-editable checklist (or ingest one), each criterion carrying its oracle |
| 3 Verify | `driving-browser-qa`, `verifying-backend-persistence`, `verifying-computed-logic`, `walking-multistep-flows`, `probing-apis-through-browser` | drive → bake → recompute/reconcile → probe → one verdict + confidence |
| 4 Report | `writing-qa-reports` | `report.md` + single-file `report.html` + per-criterion evidence; honest DEFERRED |
| 5 Remember | `checkpointing-qa-memory` | typed, resumable run artifacts in `.qa/runs/<run-id>/` |

Every skill carries ≥3 mini-evals drawn from the 14 real bugs.

---

## Install

Pick one. (Details and platform-specific CDP setup in [INSTALL.md](./INSTALL.md).)

**A — Plugin marketplace (recommended):**
```
/plugin marketplace add adams100111/qa-e2e-pilot
/plugin install qa-e2e-pilot
```

**B — npx skills installer:**
```
npx skills@latest add adams100111/qa-e2e-pilot
```

**C — Manual (symlink into ~/.claude):**
```
git clone https://github.com/adams100111/qa-e2e-pilot
bash qa-e2e-pilot/scripts/install.sh
```

Then restart Claude Code (or run `/agents`) to pick up the agent, the `/qa-run` command, and the skills.

---

## Use

1. In the project you want to QA, copy the config and edit it:
   ```
   mkdir -p .qa && cp <plugin>/.qa/config.json.example .qa/config.json
   ```
   Set `baseUrl`, your `auth.storageState` path, and (optionally) `repos` by role and an attended-CDP driver.
2. Run a pass:
   ```
   /qa-run governance wizard                          # auto-plan (v1.1) or prompt for a checklist
   /qa-run "governance wizard" .qa/checklist.md       # ingest a hand-authored checklist (v1)
   ```
3. Read the result: `.qa/runs/<run-id>/report.html` (+ `report.md` + per-criterion `evidence/`). The run is resumable — re-run the same target and it skips completed criteria.

### Configuration (`.qa/config.json`)

- `baseUrl`, optional `apiOrigin` (set only for a cross-origin backend), `auth.storageState`.
- `drivers[]` — each carries a **platform preset** (`managed` | `windows+wsl` | `windows` | `wsl` | `linux` | `mac`) that resolves its endpoint. Default = the managed Playwright browser; attended CDP is opt-in.
- `repos[]` — `{role: frontend|backend|reference, path}`, all optional (single-repo works); skills read them by role.
- `maxParallel` — cap on the narrow parallel path (most verification is **sequential by default** — see [ADR-0003](./docs/adr/0003-sequential-verification-narrow-pool.md)).
- `allowApiWrites` (default **off**) + `seedableEnvMarker` — gate any direct API write/seed behind both.

---

## Scope

- **v1 (now):** the verify/report/memory skills, pre-flight, hand-authored-checklist ingest, single managed driver (attended CDP opt-in), sequential.
- **v1.1:** `analyzing-feature-ui` + `generating-qa-checklist` (auto-plan incl. cross-tenant + concurrency cases), narrow parallel multi-driver fan-out.
- **Later (out of v1 scope):** spec-kit artifact ingestion + traceability matrix; Mem0/vector memory backend; CI/unattended + JUnit-XML; additional browser MCPs (Stagehand, browser-use). CLI/artisan verification stays out of browser scope (covered indirectly via API-probing).

---

## Prior art & inspiration

This plugin **reimplements** (does not fork or vendor) the genuinely reusable patterns from **[`opslane/verify`](https://github.com/opslane/verify)** (MIT) — the pure-bash pre-flight, the route/selector indexer, and the single-file HTML report — as our own code, because our differentiators (backend baking, independent recompute, persistent run memory, attended-CDP) cut across its per-AC loop. Credit and thanks to opslane/verify. See [ADR-0001](./docs/adr/0001-reimplement-opslane-patterns-not-fork-or-vendor.md).

### Research basis

Anthropic *Skill authoring best practices* (gerund names ≤64 chars, third-person `description` ≤1024 chars, bodies <500 lines, references one level deep, bundled scripts/templates, plan→validate→execute checklists, fully-qualified `Server:tool`); local Claude Code plugin conventions (`.claude-plugin/plugin.json` + `marketplace.json`, `skills/<name>/SKILL.md`, `agents/<name>.md`); the `npx skills` installer convention; 2026 Playwright-MCP guidance (accessibility refs over screenshots, session persistence, iteration caps, secrets out of the tool loop); and the prior art above.

## License

MIT — see [LICENSE](./LICENSE).
