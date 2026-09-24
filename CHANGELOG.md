# Changelog

Two plugins are versioned independently in this repo: **qa-e2e-pilot** (the verification engine)
and **qa-kit** (the step-gated process shell). Releases are git tags `{plugin-name}--v{version}`
(see CLAUDE.md § Releasing); marketplace installs track `main`.

---

## qa-e2e-pilot (engine)

### v0.8.0 — 2026-09-24 · "A run that cannot verify says so"

Feature release, and the first one that can turn a previously-green pipeline **red**. It exists
because a real QA run recorded a full-page HTTP 500 as a *verified* result: a criterion was authored
asserting `page.rendersWithoutServerError = false`, the page 500'd, the comparison "matched", and it
shipped as `10 pass / 1 fail` with a `severity: low` "deferred by design" note. Nothing
malfunctioned — the plan said a crash was the correct answer, so a crash was graded correct.

#### Can turn a green pipeline red

- **Load-window coverage is a new hard failure on unchanged agent behaviour.** A run where a
  `browser_navigate` is not followed by a `browser_network_requests` before the next navigation — or
  before the end of the run — now fails. This was already mandated prose in
  `skills/driving-browser-qa/SKILL.md`; it is now a gate. **This is the item most likely to redden
  an existing project on upgrade.** It matters because a navigation-time 500 is *structurally*
  invisible to in-page interception: it is the document request, not a `fetch`/XHR, and no script
  runs on a 500 page. `browser_navigate_back` is an exception.
- **`UNVERIFIED` now fails the build.** It synthesizes a JUnit `<testcase name="__run-verified__">`
  carrying a `<failure>`, counted in `failures`, so it reaches the exit code — it previously lived
  in `<properties>`, which `sys.exit` cannot see. Triggers: the capture channel is not
  `toolstream`/`driver-log`, the `capture_probed` canary is **absent entirely** (so any aborted
  run), `runChecks.findingsChannel == "none"`, `QA_SKIP_VERIFY=1`, a `seq-gap`/`unparseable-line`
  fold anomaly, or a **corrupt-but-present** `fold-anomalies.json`. An absent anomalies file stays
  benign — absence is a normal older run, corruption is not.
- **`QA_SKIP_VERIFY=1` no longer buys a green build.** It is itself an `UNVERIFIED` trigger. You may
  skip verification; the run must then say it is unverified rather than look clean. Only the literal `1`.
- **`validate-checklist-json.sh` rejects criteria that used to be legal**, hard from day one with no
  warning mode: `page.rendersWithoutServerError: false`, `page.crashed: true`,
  `console.hasError: true`, `http.status >= 500` — in `fixture.expect` **and** a top-level `expect`,
  with `"false"`, `" FALSE "` and `0` all normalised — plus the prose phrase `deferred by design` in
  the oracle/expect fields. A 3xx or 4xx stays legal: that is the application *working*, and an
  authorization refusal or a validation rejection is a legitimate thing to assert. The governing
  rule is **reject process language, never behaviour language**. Migrate an existing criterion with
  `qa-kit/scripts/migrate-inverted-criterion.sh`, whose **exit 2 is its success path** and exit 1
  its failure.
- **`init-config.sh` refuses an unreadable existing `.qa/config.json` with exit 3** instead of
  silently overwriting it. An operator with a root-owned config now gets an error where they
  previously got a green re-bootstrap. Destroying a config *because* it could not be read was the
  bug.
- **An expired known defect fails the run.** With the 90-day cap this means every registry entry
  reddens the build on its deadline. See the limitation below before adopting the registry.

#### New

- **Findings ledger.** Every observed error — console exception or non-2xx request — is journaled as
  a keyed `finding_observed` event with keyed-set dedup, so a resumed run cannot double-count it.
  `qa-verify.sh` then **recomputes the finding set independently** from the toolstream and overrides
  a run whose journal omits one.
- **Deterministic disposition.** `scripts/classify-finding.sh` decides `originClass`
  (`in-scope`/`third-party`/`benign`) and `statusClass` (`fatal`/`non-fatal`) with no agent
  discretion and no LLM. Fail-closed: an *unknowable* origin is `in-scope`; a *known foreign* origin
  is `third-party`. Only an in-scope **fatal** finding fails a run, so third-party noise is recorded
  and classified rather than discarded — and rather than reddening your build.
- **Known-defect registry** (`.qa/known-defects.json`, project-level): required `ticket` and
  `expiry`, a 90-day expiry cap, and a severity floor gating on a structured `observedClass` enum
  rather than prose. Clearing requires a **recorded 2xx navigation** to the surface; absence of a
  finding never clears anything, because a run that never reached the surface produces exactly the
  same silence as a fixed defect.
- **Capture canary** (`capture_probed`), emitted once per run behind a resume-safe guard.
  `enforcement.captureHook: true` was a *claim*; a written line is evidence. It reports `driver-log`
  only when a log the verifier could actually resolve exists, or a session log that converts to at
  least one event.
- Four run-scoped checks in `qa-verify.sh` — ledger completeness, classification re-check,
  load-window coverage, known-defect gate — reported as a `__run-checks__` record that **does** flip
  the exit code. They run regardless of any criterion's verdict, which is why the originating
  criterion, recorded `fail`, was never re-examined by anything before.
- `observe.js` now serializes `console[]` and `network[]` **before** `domDigest`, so
  `capture-hook.sh`'s 4000-byte truncation sacrifices the DOM digest instead of the error arrays. It
  previously destroyed them on any page with roughly 30+ interactive elements.
- Two new journal events registered in both fold engines; `unparseable-line` and `seq-gap` now feed
  `UNVERIFIED`; other fold anomalies surface as a count in a new `qa.foldAnomalies` property.

#### Fixed

- **`init-config.sh` no longer erases unknown *top-level* keys on re-render** — it previously
  destroyed the six keys `.qa/config.json.example` documents but the writer never emits (`viewport`,
  `responsiveMatrix`, `persona`, `detection`, `passGate`, `fixtures`) plus `personas[]`. Note
  *top-level*: `memory.mem0` is still erased, since the merge is shallow. It also now survives a
  JSON-stream config instead of aborting with raw `jq` noise.
- `findings.benign` is seed-if-absent / preserve-if-present, so a hand-added waiver is no longer
  reset by a re-bootstrap.
- `.qa/known-defects.json` is **tracked** rather than gitignored, which is what makes a renewal
  visible in review. A project that bootstrapped before this release keeps an untracked registry
  until `init-config.sh` runs again.
- `scripts/skills.json` was stale at `0.7.0`; all five version sites now move together.

#### Known limitations, stated rather than implied

- **The file-based driver network log has no producer.** `qa-verify.sh` reads `QA_NETWORK_LOG`,
  `.qa/runs/<id>/network-log.json` and `.playwright-mcp/*.har`, but nothing in this repo writes one.
  The request channel that *ships* is `browser_network_requests` results parsed out of the
  toolstream, which is what carries a navigation-time 500. Wiring a HAR producer is the top
  follow-up.
- **A known defect cannot currently clear itself**, because clearing evidence is derived from a
  document navigation and the reliable source for that is the log above. Until then, renewal is the
  only exit from the registry.
- **`cleared` is reported, never acted upon.** Nothing consumes it and no code removes an entry.
  Removing one stays a human act — deliberately symmetric with renewal being visible in a diff.
- **The findings projection is not in the human report.** It lands as `checkpoint.json`'s `findings`
  array; neither `render-report.py` nor `report-to-junit.sh` reads it. The `UNVERIFIED` headline is
  on stderr and a JUnit property, not in `report.md`/`report.html`.
- **`known-defects.sh` has no portable invocation from qa-kit** (a plugin cannot address a sibling
  plugin root, ADR-0022). You do not need one: `qa-verify.sh` validates the registry on every run
  and fails the run on a malformed or expired entry.
- `scripts/run-engine-ci.sh` aborts at the first failing suite, so on a host with any pre-existing
  failure it hides the state of every suite after it.

### v0.7.1 — 2026-09-14 · "Reports that actually render"

Bug-fix release. Two harness-interaction defects that only bite on real (subagent-dispatched,
long) runs — both surfaced QA'ing a production Laravel app.

- **report.html/report.md now render under the subagent dispatch.** The Report phase wrote both
  files with the **Write tool**, but under the usual `/qa-run` dispatch the engine runs as a
  subagent, where the harness blocks the Write tool from creating report files — so `report.html`
  was silently never produced (findings came back only as agent text). Added
  `scripts/render-report.py`: a deterministic renderer that fills `templates/report.{md,html}`
  from `run-manifest.json` + `checkpoint.json` + `bug-log.json` + `stack-profile.json` (tally,
  per-criterion verdict cards with the checklist's oracle/label, deferred cards, low-confidence
  callout, bug appendix, evidence links + screenshot slots) and writes via the filesystem, not
  the Write tool. `writing-qa-reports` now prefers it (step 0); the manual template fill remains
  the main-agent fallback.
- **`provenance.sh` no longer dies with `Argument list too long` on long runs.** Both the jq and
  python legs passed the entire slurped toolstream (easily &gt;128KB — Linux `MAX_ARG_STRLEN`) as a
  single `--argjson` / `sys.argv` value, so `qa-verify.sh`'s out-of-agent authority check failed
  **every** criterion on any sufficiently long run — defeating the gate exactly when it matters.
  Events are now routed through a temp file (`--slurpfile` for jq, file-read for python); no argv
  size limit.

---

### v0.7.0 — 2026-09-07 · "Product credibility"

The headline release: the engine now tells the truth about its own accuracy.

- **Second measured accuracy number, published honestly.** A generator-untuned fixture
  (`tools/accuracy-harness/fixture2/`, invoicing — authored under a firewall so the checklist
  generator never shaped it) was measured with a truly-blind run: **70% functional / 64% overall
  recall at 90% precision — GATE FAIL, published as-is** with a per-seed gap analysis. The prior
  85% is now labeled *same-fixture, post-tuning*. Both numbers appear side by side in
  `tools/accuracy-harness/README.md` and the README's usage-boundary section.
- **"When NOT to use this"** README section: per-commit regression gating (no), shared staging
  (degraded), intermittent/timing bugs (out of scope), and what a green run actually means.
- **Per-run cost telemetry**: wall-clock + per-criterion tool-call counts derived agent-untrusted
  from the toolstream (`cost-summary.sh`, dual-engine); cost block in `report.md`/`report.html`
  and the JUnit export; 80% `criteriaBudget` warning.
- **Accuracy gates in CI**: the headless UX measured gate + a scorer-regression gate over the
  committed blind reference run on every PR.
- **Non-Claude honesty**: accuracy-unvalidated banners on the Codex/Pi/opencode installers and
  READMEs; measured-reference vs enforced-threshold wording corrected; first live Pi measurement
  (partial, gate-fail) published with operational field notes in `docs/harness-adapters.md`.

### v0.6.5 — 2026-09-07 · "Skills/gates reconciliation"

- UX detectors: `broken-image` and `modal-behind-backdrop` restored to definite-oracle grades
  (fail@FE/high) with an emitted-id completeness test; interaction-ux dead-end check no longer
  false-fails cleanly-closed flows (base-context descriptor, invisible to the other invariants).
- Skill docs reconciled to their enforcement gates — mandatory fingerprint capture documented in
  driving-browser-qa; 4-kind checklist vocabulary; `recompute.json` evidence links; ADR-0015
  evals; a new drift-proof `skill-gate-consistency` suite re-derives expectations from the gate
  scripts at test time.
- `write-persona-config.sh`: `--allow-empty` degrade path; operator `expectedSubject` survives
  wholesale persona regeneration.
- Runtime stack fingerprint implemented (HTML markers + bounded openapi/`fingerprintPaths`
  probes; multi-owner paths score weak); `index-routes.sh` node fallback fixed (config role
  resolution without jq).
- 9 orphaned `scripts/tests/*.sh` enrolled in CI; the coverage meta-gate now inventories them;
  ~45 verified minor fixes across engine/qa-kit/docs, remainder logged in `docs/doc-sync-todo.md`.

### v0.6.4 — 2026-09-07 · "Installed-user path"

- `/qa-resume` ships on every install path (manual, npx, all three harness installers) and
  resolves its scripts per harness via `{{ENGINE_SKILLS_DIR}}` — including
  `${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/skills` on Claude.
- Pi installer merges `.pi/mcp.json` (dual-engine, per-key replace, backup) instead of
  overwriting foreign MCP servers.
- opencode `/qa-run` + `/qa-resume` bind the qa-e2e-pilot agent via generated frontmatter;
  circular non-Claude dispatch strings rewritten.
- New `tests/installers` suite (hermetic, all install paths).

### v0.6.3 — 2026-09-07 · "Enforcement correctness"

- Verdict-gating scripts are bash-3.2-safe (macOS stock bash no longer fails open verifying
  nothing); structural `bash32-safety` suite guards regressions.
- Act-lint sanctions `browser_handle_dialog`/`browser_drop` (parity with provenance's tool set,
  enforced by test).
- Provenance jq leg tolerates torn toolstream lines identically to the python3 leg (no more
  false forgery signals); journal-merge's fallback lock installs its cleanup trap only after
  acquisition (no more waiter-deletes-holder race).
- `seedableEnvMarker` defaults empty; the historical bootstrap sentinel is treated as
  never-opted-in — restoring the two-key disposable-env write gate.

---

## qa-kit (process shell)

### v0.2.0 — 2026-09-24 · "A defect is not a verdict"

Companion to engine `v0.8.0`. A known-but-unfixed application defect used to be smuggled into a
checklist as a criterion that **expects** the crash — which grades the crash correct. This release
gives it somewhere honest to live.

- **New `.qa/known-defects.json` registry**, project-level rather than per-spec: a defect is a
  property of the application, so one defect has one ticket and one expiry. Per-spec copies drift,
  and whichever copy is most convenient is the one that gets renewed.
- **New `qa-kit/scripts/migrate-inverted-criterion.sh`** lifts an inverted criterion out of a
  checklist and files it in the registry with `ticket` and `expiry` **empty**, then **exits 2** —
  its success code — so validation deliberately fails until a human supplies an owner and a
  deadline. An entry with neither is "deferred by design" under a new name. A caller treating any
  non-zero exit as failure will silently lose the migration.
  The criterion is removed **only after** its entry has been read back from the registry on disk,
  keyed by criterion *and* checklist, so two checklists reusing a criterion id each file their own
  entry instead of one deleting a criterion that nothing gates.
- **`/qa-analyze` gains a sixth gap category, `plan-defect`**, printed **above** the verdict line and
  pre-printed in the template. Its five existing categories had nowhere to put a criterion that
  asserts the application failed, so the originating incident landed under *Risk gaps* and was
  **blessed** — while the same document reported "oracle gaps: 0".
- `/qa-spec` and `/qa-scenarios` now direct an author to the registry instead of an inverted
  criterion, and document the required fields, the 90-day expiry cap, the severity floor and the
  positive-evidence clearing rule.
- `data-baseline.sh validate`'s exit-code contract is now locked in by regression tests. (The
  reported bug did not exist — it has returned non-zero on a non-empty `errors` array since its
  first commit — and the tests keep it that way.)

### v0.1.4 — 2026-09-07

- Cross-links the engine's new usage-boundary documentation. (Ships alongside engine v0.7.0.)

### v0.1.3 — 2026-09-07

- Verified minors batch: `detect-seed.sh` cross-engine cwd byte-parity; atomic `spec-snapshot`
  create + override parity; `data-baseline` integer validation; suites die (never vacuously pass)
  when both JSON engines are absent; `run-qakit-ci.sh` excluded from install payloads; spine docs
  updated for the shipped `/qa-verify` step; constitution template's nonexistent gate commands
  corrected.

### v0.1.2 — 2026-09-07

- `/qa-verify` polices the spec's **frozen** checklist (run-copy divergence is a reported
  finding; spec-less runs banner the weaker run-local mode) — closes the out-of-plan laundering
  hole.
- Persona skill-invocation instruction renders per harness dialect (`{{SKILL_REF_GENERIC}}`) —
  no Claude-only qualified slugs leak into Pi/Codex/opencode agents.

### v0.1.1 — 2026-09-07

- `auto-seed.sh decide` treats the historical bootstrap sentinel marker as not-opted-in
  (mirrors the engine's disposable-env write gate). (Ships alongside engine v0.6.3.)
