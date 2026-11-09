# Changelog

Two plugins are versioned independently in this repo: **qa-e2e-pilot** (the verification engine)
and **qa-kit** (the step-gated process shell). Releases are git tags `{plugin-name}--v{version}`
(see CLAUDE.md § Releasing); marketplace installs track `main`.

---

## qa-e2e-pilot (engine)

### v0.12.0 — 2026-11-09 · "Prove what was covered, then trust what passed"

Ship QA increments 1 and 2, released together with qa-kit `v0.3.0` (which pins `~0.12.0`). See
[ADR-0030](./docs/adr/0030-surface-census-and-ship-profile.md),
[ADR-0031](./docs/adr/0031-journeys-in-checklist-schema.md),
[ADR-0032](./docs/adr/0032-trusted-verdict-gates.md) and
[ADR-0033](./docs/adr/0033-independent-re-adjudication.md).

**Behaviour changes vs 0.11.0**

- **The state gate applies in every profile.** A `pass` on a mutating row now needs `bake` or `probe`
  evidence, also on a plain `full` run. A rejected write (an error-state row that "adds a duplicate to
  trigger a validation error") that used to pass on `human-action` alone is refused at record time
  and overridden by `qa-verify`; record a bake at multiplicity 0 instead.
- **Generated rows.** A ship run's checklist now carries generated load-clean, deny,
  ownership-isolation, input-validation and UX-revisit rows (from qa-kit), with new kinds
  `load-clean`, `deny`, `input-validation`; `input-validation` always requires `bake`.
- **Profiles.** `profile` (`ship|smoke|full`) resolves into `effective-config.json` at pre-flight and
  every later phase reads that file. `full` is the default and adds nothing; `ship` turns on the
  oracle and data-policy gates, the coverage census, variants and parallel read-only lanes.
- `"responsiveMatrix": []` is gone from the config example: an explicit empty matrix is a user value
  and turns a ship run's mobile pass off.

**Increment 2 · trusted verdicts**

- **ORACLE GATE** in `checkpoint.sh`: a `confidence: high` pass on a row with
  `fixture.expect.oracleSource`, or under `ship` on any `computed-logic`/`business-rule` row, needs
  `oracleSource` `human` or `spec`; `llm-suggested` or missing is refused, `confidence: low` is always
  allowed. A row with a control character in its kind or source is refused as malformed.
- **STATE GATE**: a mutating pass (per `mutation-flag.sh`) needs `bake` or `probe` in `--kinds`;
  `--nonui-reason` does not bypass it.
- **DATA POLICY GATE**: under `gates.dataPolicy: enforce`, the typed values in a mutating row's
  `action-trace.json` must pass `data-policy.sh check` (password-like fields skipped, values passed as
  a mode-600 `@file` that is removed on exit or interrupt; `input-validation` rows skip date window
  and email domain).
- **`qa-verify.sh` mirrors the three gates** (checks 3.6–3.8, reasons `oracle-ungrounded`,
  `no-state-evidence`, `data-policy-violation`; rule names only, never the typed values). It fails
  closed on any in-run confidence other than `low` and overrides a confidence outside `high|low`
  (`invalid-confidence`). New run check `effectiveConfigMissing`: a config or spec run-config naming
  `ship` or `dataPolicy: enforce` with no `effective-config.json` in the run fails the run.
- **Re-adjudication.** New skill `re-adjudicating-verdicts` (19 skills) with `adjudication.sh
  select|bundle|apply|capability`. After Verify, every low-confidence pass and every UX-promoted fail
  goes to one fresh-context verifier per evidence bundle (an allow-list of persisted evidence; never
  the journal, toolstream or agent prose; `action-trace.json` is a redacted copy in which values typed into
  password/passwd/secret/token/otp/pin-labelled or `type: password` fields read `[redacted]`). A disputed pass becomes `blocked` with
  `verifier-disagrees: <reason>`, a disputed fail drops to `confidence: low`, kinds and evidence refs
  are kept, and any upgrade is refused (`ADJUDICATION: upgrades are not allowed`). Capability is the
  new boolean `subagentDispatch` in `harness-profiles.json` (claude only); other harnesses print
  `re-adjudication unavailable on <harness>; <n> low-confidence passes unreviewed`. On Claude, `/qa-run`
  runs it after the dispatched agent returns, then re-runs `qa-verify`, the bug export and the renderer.
- **Ship readiness.** `render-report.js` opens the report with `SHIP-READY` / `NOT SHIP-READY` and
  every failing condition (uncovered census pairs, P1 journeys not passing, coding-layer fails on P1,
  verifier overrides on P1), plus low-confidence, flaky and regression lines. It fails closed on
  missing coverage, journeys or verification and on an out-of-date verification; runs without those
  inputs render byte for byte as before.
  A P1 criterion the re-adjudicator disputed (`verifier-disagrees:`) blocks on its own, journey step or not; a
  **Re-adjudication** line reports re-judged / disputed counts, the unavailable banner or `did not run`, and a P1
  low-confidence pass nobody re-judged blocks. A decision counts as re-judged only when `adjudication/apply.txt` shows it
  applied or a no-op; one `apply` rejected or `checkpoint.sh` refused stays unreviewed and the line says `N not applied`. A **Needs re-check** row counts `bugs/needs-recheck.json` when the
  run has a bug export (informational, never blocking); a `needs-recheck.json` older than the run's
  `verification.json` is a previous export's and is ignored.
- **Bug export.** `scripts/bug-export.sh <run-dir> --out <dir> [--known-defects <registry>]` writes `bugs.json` and one plain-language `<id>.md` per new bug from `bug-log.json` and from verifier overrides that show a contradiction (`match:false`, `readBack:null`, a probe artifact that really holds `ok: false`, or an acting identity that differs from the expected one), matched on the exact reason prefixes `qa-verify` emits; its "shows ok:false or missing" reason on a probe artifact with no `ok` is an evidence gap. Overrides that only show missing or ungrounded evidence (oracle-ungrounded, no-state-evidence, unbound, no toolstream, identity unverified, missing artifacts) are not bugs: they go to `needs-recheck.json` (always written, `[]` when empty) and the summary line carries `needsRecheck`. A re-export removes only the stale `<id>.md` files the previous `bugs.json` listed; unknown files and symlinks stay. A bug without evidence falls back to the latest record's evidence refs, then to the criterion's `evidence/` folder, and a missing journey id comes from `journeys.json`. Bugs are deduplicated against outstanding known defects, secrets are redacted and both engines are byte-identical.
- **Agent.** The Verify phase names the three gates and what to record to pass them; the Report phase runs
  `qa-verify` → re-adjudication (selection uses the verification-adjusted confidence) → `qa-verify` again → bug export →
  render (so the **Needs re-check** row reflects this run). `/qa-resume` re-adjudicates too when the agent could not. `gates.oracle` is informational: enforcement
  keys on `oracleSource` and the `ship` profile.
- **Suites.** `gate-oracle`, `gate-state`, `gate-data-policy`, `verify-ship-gates`, `ship-summary`,
  `bug-export`, `adjudication` enrolled (65 engine suites); `missing_required_kinds` is bash 3.2 safe.

**Increment 1 · prove what was covered**

- **Surface census.** New skill `taking-surface-census`: a read-only, breadth-first
  crawl per confirmed persona (`census.maxVisits`, default 300; depth 4) that writes
  `.qa/census/crawl/crawl-<persona>.json` with each visit's status, findings, forms and an
  `unexplored` list with reasons. `crawl-safety.js` classifies every control before a click: English
  and Arabic destructive labels (normalised for tashkeel, tatweel and alef/yaa/taa variants) are
  unsafe in any name source, unsafe always wins, a safe verb must lead the name and name an allowlisted
  object, and anything else is not clicked. The crawl answers native dialogs `accept:false`, stops
  clicking after any observed non-GET request, and is skipped on production unless
  `allowBlackboxCrawl`. `form-inventory.js` records each form's field constraints.
- **Stack adapters** under `adapters/census/` (laravel, nextjs, rails, django, express, generic) with
  a README contract. Each prints the app's own surfaces (routes, pages, jobs, mails, notifications,
  permission hints, locales) or `ok:false` + exit 3. New config key `exec.prefix` wraps adapter
  commands (`ddev exec`, `docker compose exec -T app`).
- **`scripts/census.sh build`** merges adapter + crawl into `.qa/census.json`: parameterised routes
  collapse to one surface, `routeMatch` (Inertia `data-page` / Next `__NEXT_DATA__`) reaches page
  surfaces, and the diffs list `unreachable`, `overreach` and `crawlOnly`. A failed adapter degrades
  to crawl-only with an `adapter-failed:` warning and `adapterOk:false`.
- **Run profiles.** `scripts/profile.sh resolve` turns `ship|smoke|full` (flag > run-config > config >
  `full`) into the run's `effective-config.json` with `profileSources`. `ship` fills desktop + mobile,
  light + dark, every app locale, all UX detectors + axe + the critic, blocking coverage/oracle/data
  gates and `maxParallel` 3, only for keys the user did not set. `full` adds nothing.
- **Journeys.** `scripts/journeys.sh validate|status|expand-variant`; checklist rows gain optional
  `surfaceId`, `priority`, `journey {id, step}` and `variant {viewport, locale, colorScheme}`, and the
  kind enum gains `load-clean`, `deny`, `input-validation` (`validate-checklist-json.sh` now also
  honours `QA_ENGINE`).
- **`required-kinds.sh`:** `input-validation` always requires `bake` (a rejected value must leave
  persisted state unchanged, even on a `read-only` row); `load-clean` and `deny` add nothing on their
  own, and a `deny` row tagged `api-write` still derives `probe`.
- **`scripts/data-policy.sh check|record|list`**: forbidden markers (whole-word for ASCII, substring
  for Arabic), email domain and date window on generated data; created-record ids for cleanup.
- **Agent.** Phase 0 resolves the profile into `effective-config.json`, which later phases read. Under
  `ship`: P1 journeys run sequentially at the primary variant; generated read-only rows fan out across
  up to 3 contexts; exactly one P1 journey is repeated at mobile in the first RTL locale via
  `journeys.sh expand-variant`; dark mode uses the new `emulate_media` capability (Playwright
  `browser_emulate_media`, now in `harness-profiles.json` and the agent's tool list).
- **Config example.** New keys `profile`, `exec.prefix`, `census.maxVisits`, `ship.denyStatuses`,
  `dataPolicy`, with `colorSchemes`/`locales` documented in `_profileDoc`. `"responsiveMatrix": []`
  is removed: an explicit empty matrix is a user value and turns a ship run's mobile pass off.
- **Census details.** Every surface carries `sampleUrls` per persona (the first reached URL, query
  kept), and the rows open that URL, never a `{param}` pattern. Tabs, dialogs and sheets the crawl
  opened become `<parent>#<kind>:<subKey>` surfaces. Next.js and Rails catch-all segments read
  `{x*}` / `{x*?}`. Next/Previous/التالي/السابق buttons are never clicked. Forms are collected only
  from visits that reached the surface, and `--access` is read with `--slurpfile`.
- **Smaller fixes.** `profile.sh` resolves undetectable locales to `[]`, never a placeholder;
  `journeys.sh expand-variant --viewport-id <id>` names variants by matrix id (`@mobile-ar`);
  `data-policy.sh check --kind input-validation` skips date window and email domain, masks
  credential-like fields, and rejects a non-array `forbiddenMarkers` (exit 2) in both engines;
  `write-persona-config.sh` keeps a persona's `permissions`; `isolation.maxOpenContexts` defaults to 3
  in the config example and caps ship lanes.
- **Suites.** `census-adapters`, `census-merge`, `profile`, `journeys`, `data-policy`,
  `checklist-ship-schema`, `crawl-safety` enrolled.

### v0.11.0 — 2026-10-01 · "Count each criterion once"

Fix-and-feature release from a real 0.10.0 run (`register-choose-later`, 61 criteria, one resume)
whose `checkpoint.json` ended with 100 rows for 61 criteria and a report tallying `deferred=39
total=100`. See [ADR-0029](./docs/adr/0029-criterion-level-supersession-and-record-time-identity.md).

- **Resume no longer duplicates rows.** Both fold engines now supersede a persona-less (shared) row
  when the same criterion later gets a verdict under a persona: the placeholder moves from
  `criteria[]` to a new `checkpoint.superseded[]` (with what replaced it) and a `superseded-row`
  fold anomaly. Persona-scoped rows are never superseded. The journal is untouched.
- **Reports and qa-verify count per criterion.** `render-report` tallies the latest authoritative
  verdict per criterion — also on a checkpoint folded by an older engine — lists superseded rows and
  rows outside the frozen plan under "Process anomalies" instead of counting them, and its summary
  line gains `criteria= superseded= out_of_plan=`. `qa-verify` skips superseded passes and prints
  `criteria=<n> superseded=<n>`.
- **Identity is refused at record time** (new `plan-guard.sh`, called by `checkpoint.sh` before any
  gate and by `journal-emit.sh started`): a criterion id with whitespace (a loop that joined ids);
  once a plan is frozen, an id or a persona the plan does not name for that criterion (use
  `journal-emit.sh amend`); a `started` whose scenarioId is not the persona (or `__shared__` with
  `""`); a verdict under a different identity than the criterion's open start. Each message gives
  the call to make instead.
- **Resume retries deferred work under its own identity.** The briefing's `skip` no longer lists
  `deferred` tuples; they are in a new `retry` list.
- **Phase windows end on their own.** qa-verify opens Verify at `plan_frozen`/`criterion_started`
  and ends a window at the next `phase_entered`, so no `phase_exited` is ever required; new
  `journal-emit.sh phase <run> <phase>` writes the closing event itself. Human-path clicks/typing
  while Verify is open (logins between personas, opening sheets) are no longer flagged by
  `__phase-surface__`; a mutating `browser_evaluate` outside every acting window still is.
- **Unjournaled findings are called out live.** The capture hook names an in-scope 5xx or console
  error that still has no `finding_observed` N captured calls after it was observed
  (`enforcement.findingNudgeAfter`, default 3, again at 2N and 3N; 0 turns it off), with the
  `journal.sh append` to make.
- **`personas[].expectedSubjects`** — a list of subjects or globs (`qa.rcl.p*@innovation.test`) for a
  persona that maps to several accounts; any match binds the identity, none overrides like
  `expectedSubject`. Preserved across role regeneration.
- Tests: new `resume-supersession` suite (both engines) built from a sanitized excerpt of the real
  run's journal, its 0.10.0 checkpoint and its toolstream; `persona-identity` gains
  `expectedSubjects` cases; `bash32-safety` gates `plan-guard.sh`.

### v0.10.0 — 2026-10-01 · "Show it"

Feature release. A real 0.8.1 run produced a 32-criterion report with no picture in it — no
image under `evidence/`, no `<img>` in `report.html` — because nothing asked for a screenshot and the
report was filled in by hand. See
[ADR-0028](./docs/adr/0028-mandatory-bound-screenshots-and-rendered-reports.md).

- **Screenshots are mandatory evidence.** `driving-browser-qa` now has the agent take
  `browser_take_screenshot` at the assertion moment (`screenshot-after.png`, `fullPage` when the
  asserted content is below the fold) and right before a UI act (`screenshot-before.png`), on pass,
  fail and blocked rows alike, and record each with the new
  `record-evidence.sh <run> <crit> screenshot --phase before|after`.
- **Screenshots are bound like any other evidence.** The capture hook hashes the file each
  `browser_take_screenshot` saved, at the moment it is saved, into the toolstream event
  (`screenshot: {file, path, sha256, bytes}`). `record-evidence.sh screenshot` copies the image into
  the criterion's evidence dir with a sidecar pointing at that call, and refuses at record time a file
  whose hash differs, a pointer at another tool, a capture another criterion already claimed, a
  description instead of `seq:<N>`, or a non-image. `provenance.sh` gains the `screenshot` kind.
- **`checkpoint.sh` refuses a `pass` or `fail` without a screenshot** when the run's toolstream shows
  a browser was driven. The message says which call to make. `blocked` rows and runs without a
  browser capture get a NOTE instead.
- **qa-verify checks them.** A screenshot altered after recording, reused across criteria or bound to
  no captured call overrides the pass to `fail`. A pass with no screenshot is **degraded to
  `confidence: low`, never overridden**; fail rows without one are listed in a record-only
  `__screenshots__` record that does not change the exit code. So a run recorded before 0.10.0 still
  re-verifies: its passes come back `low` with a reason, not overridden.
- **`report.requireScreenshots`** (default `true`; env `QA_REQUIRE_SCREENSHOTS`) turns the requirement
  off for a driver that cannot take screenshots. The forgery checks stay on.
- **The report is rendered, not written.** `scripts/render-report.sh <run-dir|run-id> [--embed]`
  (over the dependency-free `render-report.js`) builds `report.html` and `report.md` from the run's
  record: verdict summary with the verifier's overrides, verification status, screenshot coverage,
  one card per criterion with a thumbnail grid, a full-screen viewer (Esc or a click outside closes;
  arrow keys step through the criterion's screenshots), an "All screenshots" gallery and a verdict
  filter. Inline CSS and JS only, relative image paths, works offline from `file://`; `--embed` makes
  one portable file. It re-renders any existing run (older loose images are marked "not
  provenance-bound"). `python3 scripts/render-report.py` still works and delegates to it.
- Tests: new `screenshots` (both engines) and `render-report` suites, with a committed fixture run of
  small PNGs; capture-hook cases for the screenshot hash. Suites whose fixtures predate the
  requirement run with `QA_REQUIRE_SCREENSHOTS=false`.

### v0.9.0 — 2026-10-01 · "Fail where it can still be fixed"

Feature release, driven by two real runs against one Laravel app that matched the oracle on
nearly every criterion and still verified badly: 27 genuine passes overridden as forgery, 20
criteria `blocked`, and `__run-checks__` failing in both. Every cause was tooling, and each one
recurred although the second agent was told to avoid it. See
[ADR-0027](./docs/adr/0027-fail-fast-record-time-and-real-driver-shapes.md).

- **Evidence that can never verify is refused when it is recorded.** `record-evidence.sh` now
  accepts `--source-ref` only as `seq:<N>` (or `<N>`), and the seq must exist in the run's
  toolstream. A description such as `tinker:HackathonRegistration::find(454)` is refused with a
  message saying what to pass; before, it was recorded, and `qa-verify` then read it as a dangling
  pointer and called the pass forgery (AC-1). `--session-calls` must be a non-empty array of
  objects naming a `class` or `tool`; plain strings, a `{tool: count}` map and `[]` are refused.
  With neither `--session-calls` nor `--session-log`, no `sessionCalls` key is written at all.
  0.8.1 wrote an explicit `[]` there, which is the forged-trace signal, so every such trace was
  guaranteed unbound. A recorded artifact still cannot be corrected afterwards (that is
  tampering); it is simply never accepted in a shape that cannot verify.
- **A descriptive `sourceRef` is no claim.** `provenance.sh` treats only a well-formed pointer as
  authoritative. Anything else falls back to containment, exactly as if it had been omitted, so
  artifacts recorded by 0.8.1 stay verifiable. A well-formed pointer that dangles is still
  `unbound`.
- **Read-only criteria are classified from their structure.** `mutation-flag.sh` now decides
  from the row's structured fields first. `kinds` containing `human-action` and a mutating
  `httpMethod` always mean mutating. Next, an explicit `"mutates": true|false` or the `read-only`
  tag decides, then `humanAction: true`. Prose verbs are only a fallback, and that fallback
  ignores negated clauses ("Do NOT submit"), URL paths (`/hackathons/create`) and the bare noun
  "set". The six real false positives — "compare rows as a **set**", "**edit**
  form", "**change** marker", a quoted "**Edit** my registration" button — no longer demand
  `human-action` evidence. `validate-checklist-json.sh` validates `mutates` and rejects
  `mutates: false` beside a human-action requirement.
- **The findings channel works against the real driver.** Its root cause: qa-verify parsed
  `responseBody` as the raw observe object, but the Playwright MCP wraps every result in a content
  array with markdown. The 4000-byte cap cuts that wrapper mid-string, so it never parsed, and
  `browser_network_requests` returns a markdown list, not JSON. A run that injected `observe.js`
  verbatim still verified `findingsChannel: "none"`. The capture hook now extracts the
  console/network rows from the **full** response into an `observed` field. qa-verify reads it
  through one shared reader (`toolstream.sh extract-observed` / `observed-rows`), which also
  unwraps pre-0.9.0 toolstreams.
- **Live self-checks.** The capture hook now tells the agent at the call, as PostToolUse
  `additionalContext` that never blocks:
  - the first observe round or request list that captured no findings;
  - after every navigation, that `browser_network_requests` comes next;
  - once, at the third browser call, that no `--save-session` log is being written.
- **Load-window gaps are closed during the run.** The block-hook denies the next
  `browser_navigate` of a live run while the previous navigation has not been followed by
  `browser_network_requests`. The fix is that one call. `enforcement.loadWindowGate: false` opts
  out; the verify-time check is unchanged.
- **Missing `--save-session` is reported up front.** `preflight.sh` prints
  `save-session: detected` or warns `save-session: absent`, with how to enable it
  (`PLAYWRIGHT_MCP_SAVE_SESSION=true` + `PLAYWRIGHT_MCP_OUTPUT_DIR`) or accept the degrade
  (`humanInteraction.saveSession: false`).
- **Drag and drop.** `browser_drag` and `browser_drop` are in the agent's tool list. The gates
  already treated them as human-path tools.
- **API-only criteria have one sanctioned, recorded write.** On a disposable env, the block-hook
  admits exactly one mutating `browser_evaluate` shape: `backend-probe.js` verbatim plus one
  `probe(<strict JSON>)` call with a same-origin relative url. It does so only when
  `allowApiWrites`, a disposable `seedableEnvMarker` and `environment != production` all hold, and
  never on production. A row tagged `api-write` proves its act with `probe` evidence instead of
  `human-action`. qa-verify overrides it unless that evidence is bound by `--source-ref seq:<N>`
  to the captured write and the config still allows writes. `backend-probe.js` gains
  `csrf: "laravel-xsrf" | "meta"`.
- **Shared criteria bind to their role's identity capture.** On a multi-persona project, a
  persona-less high-stakes pass (a shared criterion, ADR-0012) was always downgraded to `low`.
  It is now bound to `evidence/<row role>/identity.json` with the persona-scoped rules. Without
  that capture it still degrades, and the reason names the command that records one.
- **Classifier hardening.** `mutates()` now recognises a quoted method key
  (`{"method":"POST"}`), which previously slipped past the block-hook and the act-phase lint.
- **Test portability.** Restricted-PATH fallbacks also include `/usr/bin:/bin`, because on macOS
  `${BASH%/*}` is Homebrew's bin, which has no coreutils. The `skillopt-pilot` suite no longer
  depends on a developer's home directory or a `codex` binary; it had kept CI red since
  2026-09-15. A new `tests/preflight` suite runs `preflight.sh` against a throwaway local app.

#### Behaviour changes

- Now fails fast:
  - `record-evidence.sh` exits 1 on a descriptive or dangling `--source-ref` and on a malformed
    or empty `--session-calls`;
  - the block-hook denies a `browser_navigate` while the previous navigation's load window is
    unread (live runs only — a toolstream untouched for 120 minutes is not gated).
- Re-verifying an existing run can now find findings that were invisible before. For example,
  in-scope 5xx responses sitting in a `browser_network_requests` list that the run never
  journaled. Such a run fails ledger completeness instead of reading `findingsChannel: "none"`.
- A read-only row should be tagged `read-only` (or carry `"mutates": false`). Prose alone still
  classifies as before, minus negations, paths and the noun "set".
- `humanAction: true` on a row that is not tagged `read-only` now requires the `human-action`
  trace, even when the prose verb ("withdraw", "remind", "advance") is not one the classifier
  knows. 0.8.1 ignored the field, and passes for such rows were accepted without the trace.
- A JSON-quoted `method` key in an evaluate payload is now a write. Only the sanctioned probe
  shape is admitted, and only on a disposable env.

### v0.8.1 — 2026-09-27 · "The observer is not the actor"

Bug-fix release. Two defects found on a real QA run of 0.8.0 against another project.

- **The block-hook no longer denies the engine's own observe round.** `scripts/block-hook.sh`
  reuses `parse-session-log.js`'s `mutates()`, and `mutates(observe.js)` was `true`: the
  sanctioned read-only observe payload was denied, the run had no findings channel,
  `loadWindowCovered` went false and the run verified **UNVERIFIED** even though every tool call
  was captured. Two constructs tripped the `window\.\w+\s*=` alternative. First, the `===`
  comparisons (`typeof window.__qaObserve === 'function'`): every `x = ...` alternative also
  matched `==`/`===`, so any read-only probe comparing a value was denied too. Assignment tails
  now require `=(?!=)`, and they now also catch compound assignments (`el.value += 'x'` used to
  slip through). Second, observe's own instrumentation: `window.__qaObserveInstalled`,
  `window.__qaObserve`, and a pass-through `window.fetch = function (...)` wrapper. A regex cannot
  tell a pass-through fetch wrapper from one that forges responses, so this allowance is
  **content-addressed**. The shipped `observe.js` is read from disk, and any occurrence of it in a
  payload is cut out before classification. The comparison ignores whitespace, so the
  `() => { … }` wrapper and re-indentation do not matter. A tampered copy is still denied. So is
  observe with a write appended, and so is a payload that only *names* observe.
  `classify()` now also decodes the quoted `page.evaluate('…')` argument in session-log code. That
  keeps the live hook, `check-action-trace.js`, `mutation-flag.sh` and `qa-verify.sh`'s
  record-only phase-surface re-check in agreement. Pass `observe.js` **verbatim**; an edited or
  comment-stripped copy gets no allowance.
- **Secrets typed into the browser are no longer recorded.** Up to 0.8.0, `browser_type` and
  `browser_fill_form` args were stored in full in `toolstream.jsonl`, and a real run stored a
  shared login password there six times. The new `toolstream.sh redact-browser` handles fields
  whose descriptors (element / name / selector / ref / type) name a password, passcode, secret,
  token, API key, credential, OTP, PIN or CVV. That list is built in, and it is extended by any
  field that the effective `enforcement.secretPatterns` match. Such a field keeps its descriptor
  and records `<redacted>` as its value. Every other typed value goes through the same
  `redactedKeys` + `secretPatterns` pass as Bash args. The same values are masked in the recorded
  `responseBody`, which echoes the generated `.fill('<value>')` code. Masking covers the value's
  JSON- and JS-escaped spellings and runs on the full response, before the 4 KB truncation. A
  redaction failure withholds the args or body rather than writing them unredacted, and the hook
  still never fails or blocks the call.

#### Behaviour changes

- A read-only `browser_evaluate` that compares values (`===`, `==`) is now allowed. One that uses a
  compound assignment on a watched target (`el.value += …`, `window.x ??= …`) is now denied.
- `"secretPatterns": []` does **not** switch off the built-in secret-*field* set. That opt-out
  still governs pattern redaction of free text. A value typed into a password field is never
  recorded.
- Evaluate payloads, URLs and every other `browser_*` call are still recorded in full, because
  `qa-verify` re-classifies evaluate payloads and they must not be pattern-mangled. If an agent
  types a credential into a URL itself, `redactedKeys` is not applied there.

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

### v0.3.0 — 2026-11-09 · "Confirm the oracle"

Ships with engine `v0.12.0`, increments 1 and 2. The dependency is now pinned:
`{ "name": "qa-e2e-pilot", "version": "~0.12.0" }` (it resolves against the `qa-e2e-pilot--v0.12.x`
release tags).

**Increment 2 · trusted verdicts**

- **Oracle confirmation page.** New `oracle-confirm.sh render|apply` and
  `templates/oracle-confirm.html`: `/qa-analyze` step 4c renders an offline page (works from
  `file://`, no network) listing every unconfirmed expected value, grouped by business rule, with
  accept / edit / unknown per row or per group. Saving downloads `oracle-decisions.json`; `apply`
  writes accepted and edited values back as `oracleSource: "human"` (backup `checklist.json.bak`),
  leaves unknown rows alone and lists unmatched ids. Under `autonomousSetup` the page is skipped and
  the unconfirmed count reported.
- **`spec` oracle source.** `check-fixtures.sh` accepts `oracleSource: "spec"` with a `citation`
  `<path>:<line>` that resolves inside the checklist dir or the git root (no absolute paths, no `..`,
  symlinks resolved and contained; outside git, the checklist dir only); `sources` counts `spec`.
  Only `human` and `spec` can ground a high-confidence pass under the engine's ORACLE GATE.
- **Plan drift check.** `/qa-verify` runs `verify-plan.sh --drift <run-checklist> <frozen-checklist>`, which compares by id the
  trust-bearing fields (`kind`, `tags`, `mutates`, `humanAction`, `priority`, `journey`, `fixture.expect.{oracleSource,citation,value}`)
  and the run's `journeys.json` against the spec's (`priority`, ordered `steps`, journey ids), and fails on any drift, row or
  journey added in-run or frozen row or journey missing. `check-fixtures.sh` names the unresolved citation in its missing reason, and the
  constitution marks `gates.oracle` informational.
- **`/qa-verify`** restates the engine's re-adjudication outcome (re-judged, verifier overrides,
  unavailable banner or did not run); the `verification.md` template gains that section.
- **Suites.** `oracle-confirm` enrolled (15 qa-kit suites).

**Increment 1 · prove what was covered**

- **`surface-access.sh derive|confirm-table|apply`** writes `.qa/surface-access.json` (who SHOULD
  reach each surface) from adapter permission hints and crawl reach. Crawl reach without a matching
  hint goes to `reachedWithoutEvidence`, never `allowed`, until a human confirms it in the new
  `/qa-constitution` surface-access round (auto-accepted with `assumption: true` under
  `autonomousSetup`).
- **`generate-ship-criteria.sh`** turns census + access + authz matrix into rows: a load-clean sweep per
  surface × persona, deny rows only where permission evidence exists (mutating ones `api-write` on a
  disposable env, else `deny-write-deferred`; unconfirmed overreach tagged `needs-confirmation`),
  same-role ownership isolation, form input edge cases, and P1 UX revisits per viewport × locale ×
  color scheme. Overflow past `criteriaBudget` is reported, never dropped.
- **`coverage.sh`** reports role × surface coverage (covered / excluded with a reason / uncovered,
  plus `covered-unscoped`) and, in `--mode block`, exits 1 on any uncovered pair, an empty census, or a
  failed adapter without `--accept-crawl-only`.
- **Commands.** `/qa-constitution` gains profile/gate rows and the surface-access round; `/qa-spec`
  authors `journeys.json` (validated by `journeys.sh`) and a run-config `profile`; `/qa-scenarios`
  builds the census, generates ship rows and fills coverage gaps; `/qa-analyze` runs the coverage gate,
  its one blocking check under `ship`.
- **Ship gate fixes.** Generated ids are token-safe (`<prefix>-<slug>-<h8>`, old id kept as `title`)
  and accepted by the engine's `checkpoint.sh`. `surface-access.sh apply --assume` replaces the
  autonomous deny-everything path and never denies; permissions match exactly, `*` or `prefix.*`;
  `surface-access.sh personas` writes `.qa/specs/<target>/personas-for-generation.json`. `coverage.sh`
  counts sweep rows apart (`covered-sweep`) and takes `--scope`, `--roles` and exclusion globs.
  `/qa-analyze` is BLOCKED under ship on a missing census or a failed engine script, and `/qa-status`
  and the agent refuse to hand off to `/qa-run` while it is. Input rows skip GET forms, accept either a
  validation message or an escaped, intact value where both are correct, and open the form from a
  sampled URL.
- **Suites.** `surface-access`, `ship-criteria`, `coverage-gate` enrolled.

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
