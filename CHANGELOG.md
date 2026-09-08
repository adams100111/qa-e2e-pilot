# Changelog

Two plugins are versioned independently in this repo: **qa-e2e-pilot** (the verification engine)
and **qa-kit** (the step-gated process shell). Releases are git tags `{plugin-name}--v{version}`
(see CLAUDE.md § Releasing); marketplace installs track `main`.

---

## qa-e2e-pilot (engine)

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
