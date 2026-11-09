# Ship QA Increment 1 — Coverage Census + Ship Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use sdd-lanes:sdd-lanes to implement this plan lane-by-lane. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a run prove what it covered: a per-role census of every surface, generated ship criteria (load-clean sweep, deny matrix, ownership isolation, input edge cases, UX revisits), journeys as first-class, a `ship` profile, and a data policy.

**Architecture:** Stack adapters (shell, one per stack) emit raw surfaces; a read-only crawl skill adds what each role actually reaches; `census.sh` merges both into `.qa/census.json`. qa-kit generators turn census + access rules into checklist rows and a blocking coverage gate. `profile.sh` resolves `ship|smoke|full` into the run's `effective-config.json`, which the agent reads.

**Tech Stack:** bash + jq|python3 dual engine (existing convention), browser JS for the crawl safety classifier, Markdown skills.

**Spec:** `docs/superpowers/specs/2026-11-09-ship-grade-qa-design.md` (read the "Settled" sections — they override the body).

## Global Constraints

- Verdicts stay exactly `pass|fail|blocked|deferred|error`; confidence `high|low`; suspected layer `FE|route|service|migration|DB`. No new verdict, no new evidence kind.
- Engine scripts are dual-engine (jq | python3) with byte-parity tests; every `json.dumps` uses `ensure_ascii=False` (Arabic data is a first-class case).
- Every new script has `tests/<suite>/run.sh` in the existing skeleton (`check()`, `run_engine jq|python3`, parity block, `echo "<suite>: PASS=$pass FAIL=$fail"`).
- qa-kit never modifies engine files (ADR-0022); engine files are edited only by engine-lane tasks.
- The crawl never clicks an action not classified safe, on any environment.
- Nothing is hard-coded to Laravel/Inertia/innovation; stack specifics live in `adapters/census/<stack>.sh`.
- Generated data must pass `data-policy.sh check` (Task 10).
- Commit messages: Conventional Commits; no AI/Claude attribution trailers.
- Skill frontmatter rules (CLAUDE.md "Skill conventions"): `name` = dir, gerund, "Use when …", body < 500 lines, ≥3 mini-evals.

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Checklist rows gain optional `surfaceId` (string or string[]), `priority` (`P1|P2|P3`), `journey` (`{id, step}`), `variant` (`{viewport, locale, colorScheme}`). Kind enum gains `load-clean`, `deny`, `input-validation`. Same-role isolation reuses kind `cross-tenant` with tag `ownership-isolation`. | spec 1c/1e + Settled |
| D2 | Journey metadata lives in `journeys.json` (spec dir, copied into the run dir): `[{id, title, priority, roles[], steps:[criterionId…]}]`. Rows point back via `journey`. | Settled #7 |
| D3 | `surface-access.json`: `{version, surfaces:{<surfaceId>:{allowed:[personaId…], source:"adapter"|"crawl"|"human", confirmed:bool}}}`. `authz-matrix.json` unchanged. | Settled #1 |
| D4 | Exec wrapper: new config key `exec.prefix` (string, default `""`), prepended to every adapter command (e.g. `"ddev exec"`, `"devenv shell --"`, `"docker compose exec -T app"`). | builder review |
| D5 | Profiles: `ship|smoke|full`; `full` = today's behaviour and the default when no profile is set. | spec 1d |
| D6 | Mutating-method deny probes only when `allowApiWrites` + non-empty `seedableEnvMarker`; otherwise generated as `deferred`-intended rows tagged `deny-write-deferred`. | Settled #5 |
| D7 | Ship profile parallel lanes reuse fanning-out: generated read-only rows carry tags `independent` + `read-only`; `maxParallel` resolves to 3. Journeys never get `independent`. | grilling |

## File Structure

```
adapters/census/{laravel,nextjs,rails,django,express,generic}.sh   stack adapters → raw census JSON on stdout
adapters/census/README.md                                          adapter contract
scripts/census.sh                                                  merge adapter + crawl → .qa/census.json; diffs
scripts/profile.sh                                                 resolve ship|smoke|full → effective-config.json
scripts/journeys.sh                                                validate / status / expand-variant
scripts/data-policy.sh                                             check text/json against dataPolicy; record created ids
skills/taking-surface-census/SKILL.md                              crawl protocol (+ scripts/crawl-safety.js, scripts/form-inventory.js)
skills/generating-qa-checklist/scripts/validate-checklist-json.sh  schema additions (D1)
skills/generating-qa-checklist/references/checklist-json-schema.md doc of D1
qa-kit/scripts/surface-access.sh                                   derive / validate / confirm-table
qa-kit/scripts/generate-ship-criteria.sh                           census → load-clean/deny/isolation/input/ux-revisit rows
qa-kit/scripts/coverage.sh                                         per role×surface coverage + gate
qa-kit/commands/{qa-constitution,qa-spec,qa-scenarios,qa-analyze}.md   wiring
qa-kit/templates/{journeys-template.json,qa-analyze-template.md,constitution-template.md}
tests/{census-adapters,census-merge,profile,journeys,data-policy,checklist-ship-schema,crawl-safety}/run.sh
tests/{surface-access,ship-criteria,coverage-gate}/run.sh
core/persona-body.md, agents/qa-e2e-pilot.md (regenerated), harness-profiles.json, .qa/config.json.example,
scripts/{run-engine-ci.sh,skills.json}, qa-kit/scripts/run-qakit-ci.sh, CLAUDE.md, README.md, CHANGELOG.md,
skills/{detecting-visual-ux,fanning-out-criteria}/SKILL.md, docs/adr/0030-*.md, docs/adr/0031-*.md
```

## Lanes

| Wave | Lane | Tasks | Owns files | Consumes (from) |
|---|---|---|---|---|
| 1 | A (engine schema/profile) | 1, 2, 3 | validate-checklist-json.sh, checklist-json-schema.md, journeys.sh, profile.sh, their tests | — |
| 1 | B (census) | 4, 5, 6, 7 | adapters/census/*, census.sh, skills/taking-surface-census/*, their tests | — |
| 1 | C (data policy) | 10 | data-policy.sh, tests/data-policy | — |
| 2 | D (qa-kit generators) | 8, 9, 11 | qa-kit/scripts/{surface-access,generate-ship-criteria,coverage}.sh, qa-kit commands + templates, their tests | A1, A2, B6, B7 |
| 3 | E (integration) | 12 | persona-body, agents/, harness-profiles.json, config example, SUITES arrays, skills.json, CLAUDE.md, README, CHANGELOG, ADRs, detecting-visual-ux + fanning-out SKILL.md | all |

---

### Task 1: Checklist schema additions   (Lane A, risk: high)

**Files:** Modify `skills/generating-qa-checklist/scripts/validate-checklist-json.sh` (both engines), `skills/generating-qa-checklist/references/checklist-json-schema.md`. Test `tests/checklist-ship-schema/run.sh`.
**Interfaces:** Produces the D1 fields; consumed by Tasks 2, 8, 9 and Increment 2.
**Exact values:** kinds added: `load-clean`, `deny`, `input-validation`. `priority` ∈ `P1|P2|P3`. `variant.colorScheme` ∈ `light|dark`. Tag `ownership-isolation`, `ux-revisit`, `deny-write-deferred`.
**Behaviour:**
- Old checklists without new fields validate exactly as before (byte-identical output).
- `surfaceId` must be a non-empty string or non-empty array of non-empty strings.
- `journey` must have string `id` and integer `step ≥ 1`.
- `variant` keys optional individually; unknown `colorScheme` rejected.
- Invalid values fail with the existing error format naming row id and field.
**Tests (write first):**
- `legacy_rows_unchanged` — v2-style fixture → exit 0, output identical to pre-change golden.
- `new_kinds_accepted` — one row each of the 3 new kinds → exit 0.
- `bad_priority_rejected` — `priority:"P0"` → exit 1, message names the row id.
- `journey_step_zero_rejected` — `step:0` → exit 1.
- `variant_dark_ok_sepia_rejected`.
- `arabic_text_parity` — Arabic `action` text → jq and python3 outputs byte-identical.
**Task gate:** `bash tests/checklist-ship-schema/run.sh`

### Task 2: journeys.sh   (Lane A, risk: normal)

**Files:** Create `scripts/journeys.sh`. Test `tests/journeys/run.sh`.
**Interfaces:** Consumes D1/D2. Produces:
- `journeys.sh validate <journeys.json> <checklist.json>` → exit 0/1, errors on stdout as JSON `{ok, errors:[{journeyId, reason}]}`.
- `journeys.sh status <run-dir>` → `[{id, priority, verdict: pass|fail|incomplete, steps:[{criterionId, verdict}]}]` from `checkpoint.json` (after supersession); a journey passes only if every step is `pass`.
- `journeys.sh expand-variant <journeys.json> <checklist.json> --journey <id> --viewport <WxH> --locale <code> [--color-scheme light|dark]` → new checklist on stdout with duplicated rows, ids suffixed `@<viewport>-<locale>[-<scheme>]`, `variant` set, `journey.id` suffixed the same.
**Behaviour:**
- validate: every step id exists in checklist; each row's `journey.step` matches its index; no step id in two journeys of the same id; priority ∈ P1|P2|P3.
- status: missing verdict for any step → `incomplete`; any `fail|error` → `fail`.
- expand-variant refuses an unknown journey id (exit 1).
**Tests:** `validate_ok`, `validate_missing_step`, `status_all_pass`, `status_one_fail`, `status_incomplete`, `expand_variant_ids_and_fields`, parity block.
**Task gate:** `bash tests/journeys/run.sh`

### Task 3: profile.sh   (Lane A, risk: high)

**Files:** Create `scripts/profile.sh`. Test `tests/profile/run.sh`.
**Interfaces:** Produces `profile.sh resolve <config.json> [--run-config <run-config.json>] [--stack-profile <stack-profile.json>] [--profile ship|smoke|full]` → effective config JSON on stdout. Profile precedence: `--profile` flag > `run-config.profile` > `config.profile` > `full`.
**Exact values (ship defaults, applied only for keys the user did not set):**
- `responsiveMatrix`: `[{"id":"desktop","width":1440,"height":900},{"id":"mobile","width":390,"height":844}]`
- `colorSchemes`: `["light","dark"]`
- `locales`: stack-profile `primary.frontend` component `i18n.locales` (fallback: backend component; fallback `["<default>"]`)
- `detection.ux`: `{"objective":true,"advisoryAesthetics":true,"critic":true,"axe":true}`
- `gates`: `{"coverage":"block","oracle":"enforce","dataPolicy":"enforce"}`
- `maxParallel`: `3`
- smoke: `responsiveMatrix` desktop only, `colorSchemes ["light"]`, `locales` first only, `gates.coverage "advise"`; full: no defaults added.
**Behaviour:**
- Output always contains `profile` and `profileSources` (`{<key>: "user"|"profile-default"}`) so the report can say what the profile turned on.
- Explicit user values win, including explicit empty arrays.
- Unknown profile → exit 1 `unknown profile: <x>`.
**Tests:** `default_is_full`, `ship_fills_defaults`, `user_value_wins`, `explicit_empty_matrix_kept`, `locales_from_stack_profile`, `unknown_profile_rejected`, parity.
**Task gate:** `bash tests/profile/run.sh`

### Task 4: Adapter contract + Laravel adapter   (Lane B, risk: high)

**Files:** Create `adapters/census/README.md`, `adapters/census/laravel.sh`. Test `tests/census-adapters/run.sh` (shared by Task 5) with a fake `php` on `PATH` returning fixture JSON.
**Interfaces:** Every adapter: `adapters/census/<stack>.sh --repo <path> [--exec-prefix "<prefix>"]` → stdout:
`{"adapter":"<stack>","ok":true,"surfaces":[{"surfaceId","kind","pattern","method","permissionHints":[...],"source":"adapter"}],"jobs":[{"id","schedule"}],"mails":[{"id"}],"notifications":[{"id"}],"locales":[...],"warnings":[...]}`.
On failure: `{"adapter":"<stack>","ok":false,"error":"<message>"}` and exit 3.
**Exact values:** `surfaceId` = `<METHOD> <pattern>` for endpoints (e.g. `GET /admin/hackathons/{hackathon}`), `page:<component>` for front-end pages. Laravel commands: `php artisan route:list --json`, `php artisan schedule:list` (text). Page dirs scanned: `resources/js/pages`, `resources/js/Pages`, `Modules/*/resources/js/pages`. Mail/notification classes: `app/Mail`, `app/Notifications`, `Modules/*/app/{Mail,Notifications}`. Permission hints from route middleware entries matching `can:*`, `permission:*`, `role:*`, `license.feature:*`.
**Behaviour:**
- Every artisan call is `<exec.prefix> php artisan …` run from `--repo`.
- Missing php / non-zero artisan → `ok:false` (never an empty success).
- Vendor/framework routes (`_ignition`, `telescope`, `horizon`, `sanctum/csrf-cookie`) are skipped and listed in `warnings`.
**Tests:** `laravel_routes_to_surfaces`, `laravel_middleware_permission_hints`, `laravel_pages_scanned_incl_modules`, `laravel_artisan_failure_is_ok_false_exit3`, `exec_prefix_applied` (fake prefix script records argv).
**Task gate:** `bash tests/census-adapters/run.sh`

### Task 5: Other adapters   (Lane B, risk: normal)

**Files:** Create `adapters/census/{nextjs,rails,django,express,generic}.sh`. Extend `tests/census-adapters/run.sh` with fixture repos under `tests/census-adapters/fixtures/`.
**Interfaces:** Same contract as Task 4.
**Exact values:** nextjs scans `app/**/page.{tsx,jsx,ts,js}` and `pages/**/*.{tsx,jsx}` (excluding `_app`, `_document`, `api/`), `app/api/**/route.*`; rails parses `bin/rails routes` output; django runs `python manage.py show_urls` if available else static-scans `urls.py` `path(`/`re_path(`; express static-scans `app|router.(get|post|put|patch|delete)(`; generic returns `{"adapter":"generic","ok":true,"surfaces":[],"warnings":["crawl-only census"]}`.
**Behaviour:** Static scanners mark `"confidence":"static"` per surface; dynamic segments normalized to `{param}`.
**Tests:** one fixture per stack asserting surface ids; `django_without_show_urls_falls_back_static`; `generic_is_crawl_only`.
**Task gate:** `bash tests/census-adapters/run.sh`

### Task 6: census.sh merge + diffs   (Lane B, risk: high)

**Files:** Create `scripts/census.sh`. Test `tests/census-merge/run.sh`.
**Interfaces:** Consumes adapter JSON (Task 4/5) and crawl JSON (Task 7 shape). Produces `census.sh build --adapter <adapter.json> --crawl <crawl-dir> [--access <surface-access.json>] --out <census.json>`:
`{version:1, adapter, surfaces:[{surfaceId, kind, pattern, sources:[...], reachedBy:[personaId], allowed:[personaId]|null, forms:[...]}], jobs, mails, notifications, diffs:{unreachable:[surfaceId], overreach:[{surfaceId, personaId}], crawlOnly:[surfaceId]}}`.
Crawl dir holds one `crawl-<personaId>.json` per role: `{personaId, visits:[{url, routeMatch?, kind, status, findings:[...], forms:[...]}], unexplored:[{url, reason}]}`.
**Behaviour:**
- Crawl URLs map to adapter patterns by segment matching (`/h/abc` → `/h/{slug}`); unmatched → `crawlOnly`.
- `unreachable` = adapter page/GET surfaces no persona reached (dead feature / missing nav). Non-GET endpoints are never "unreachable" by crawl.
- `overreach` computed only when `--access` given: persona reached a surface whose `allowed` excludes it.
- Adapter `ok:false` → census still built from crawl, top-level `warnings` contains the adapter error (no silent empty).
**Tests:** `merge_maps_params` (includes a two-param route `/admin/hackathons/{hackathon}/paths/{path}`), `unreachable_detected`, `overreach_detected`, `crawl_only_listed`, `adapter_failure_degrades_with_warning`, `arabic_urls_parity`.
**Task gate:** `bash tests/census-merge/run.sh`

### Task 7: taking-surface-census skill + crawl safety   (Lane B, risk: high)

**Files:** Create `skills/taking-surface-census/SKILL.md`, `skills/taking-surface-census/scripts/crawl-safety.js`, `skills/taking-surface-census/scripts/form-inventory.js`. Test `tests/crawl-safety/run.sh` (node + jsdom-free DOM fixtures as HTML strings via a tiny in-script parser, or `node --test` with linkedom if already vendored — otherwise plain-object element fixtures).
**Interfaces:** `crawl-safety.js` is browser code returning `[{selector, label, safe:bool, reason}]` for every interactive element on the page. `form-inventory.js` returns `[{formId, action, method, fields:[{name, type, required, maxLength, min, max, pattern}]}]`. SKILL writes `crawl-<personaId>.json` (Task 6 shape).
**Exact values:**
- Safe: `a[href]` (same origin, not matching `crawlDenyPatterns`, not `download`), `[role=tab]`, `[aria-haspopup]`, `[aria-expanded]`, `summary`, buttons whose accessible name matches `/^(open|view|details|show|more|edit|filter|sort|next|previous|expand|menu)\b/i` or Arabic `عرض|تفاصيل|المزيد|فتح|تعديل|تصفية|القائمة|التالي|السابق`.
- Always unsafe: name matches `/(delete|remove|destroy|archive|approve|reject|accept|decline|send|submit|save|publish|cancel|confirm|revoke|disband|withdraw|announce|transition|advance|reset|logout|sign out)/i` or Arabic `حذف|إزالة|أرشفة|اعتماد|موافقة|رفض|قبول|إرسال|حفظ|نشر|إلغاء|تأكيد|سحب|إعلان|تسجيل الخروج`; `type=submit`; any element inside a `form` whose submission is not GET.
- Unsafe wins over safe when both match.
- Edit-openers that navigate are safe; a dialog opened by the crawl is always closed via Escape / its cancel control, never its primary action.
**Behaviour (SKILL):** per confirmed persona: breadth-first from the role's landing page, budget `census.maxVisits` (default 300) and depth 4; per visit run the existing observe round and `classify-finding.sh`, storing findings in the visit's `findings[]` (the crawl runs before a run exists, so nothing goes to a journal; the generated `load-clean` rows re-verify each pair inside the run, where the existing findings ledger applies), then `form-inventory.js`, `crawl-safety.js`; record unexplored elements with reason; never fills or submits a form.
**Tests:** `arabic_delete_unsafe` (text and `aria-label`-only icon variants), `english_save_unsafe`, `tab_safe`, `view_details_safe`, `unsafe_wins_on_conflict` ("View and delete"), `submit_in_post_form_unsafe`, `form_inventory_reads_constraints`.
**Task gate:** `bash tests/crawl-safety/run.sh`

### Task 8: surface-access + ship criteria generator   (Lane D, risk: high)

**Files:** Create `qa-kit/scripts/surface-access.sh`, `qa-kit/scripts/generate-ship-criteria.sh`. Tests `tests/surface-access/run.sh`, `tests/ship-criteria/run.sh`.
**Interfaces:**
- `surface-access.sh derive <census.json> <personas.json>` → D3 JSON (`allowed` from permission hints matched against persona roles + crawl `reachedBy`; `confirmed:false`).
- `surface-access.sh confirm-table <surface-access.json>` → Markdown table grouped by permission hint for one human pass; `surface-access.sh apply <surface-access.json> <decisions.json>` sets `confirmed:true`, `source:"human"`.
- `generate-ship-criteria.sh --census <c> --access <a> --matrix <authz-matrix.json> --personas <p> --config <effective-config.json> [--journeys <j> --checklist <existing>]` → checklist rows JSON array (append-ready).
**Exact values (row ids):** `load-clean:<surfaceId>:<persona>`, `deny:<surfaceId>:<persona>`, `iso:<entity>:<persona>`, `input:<formId>:<field>:<case>`, `ux:<surfaceId>:<persona>@<viewport>-<locale>-<scheme>`.
Input cases per field type: required → `empty`; text with maxLength → `maxlen+1` (string of `maxLength+1` Arabic letters `ب`); text without maxLength → `long-5000`; number → `huge` (`99999999999`), `negative` (`-1`) when `min ≥ 0`; date → `past` (`2000-01-01`), `invalid` (`2026-02-30`); email → `malformed` (`name@`); all text → `special` (`<b>"'&;--</b>`). Expected for every input row: validation message visible, no 5xx, no persisted change (bake multiplicity unchanged).
**Behaviour:**
- `load-clean`: one per surface × persona that reached it; tags `independent`, `read-only`; expect no in-scope fatal finding.
- `deny`: one per persona × surface where `allowed` excludes persona and surface is GET/page; non-GET → tag `deny-write-deferred` unless config `allowApiWrites` and `seedableEnvMarker` non-empty, then tag `api-write`. Expected refusal statuses from config `ship.denyStatuses` (default `[401,403,404,302]`).
- `iso`: from `authz-matrix.json` rows where a persona is `owns`: same persona, another owner's record id (read-only GET); tag `ownership-isolation`.
- `ux` revisits: for every surface referenced by a P1 journey step, each variant combo except the primary (first viewport, first locale, `light`); tags `ux-revisit`, `read-only`, `independent`, `variant` set.
- Rows carry `surfaceId`; never duplicates an id already in `--checklist`.
- Output passes Task 1 validation.
**Tests:** `derive_from_hints_and_crawl`, `confirm_apply_marks_human`, `load_clean_per_reached_pair`, `deny_get_only_without_writes`, `deny_write_tagged_api_write_when_allowed`, `iso_rows_from_matrix`, `input_cases_by_type` (assert exact values above), `ux_revisits_skip_primary`, `no_duplicate_ids`, `output_validates` (pipes into validate-checklist-json.sh), `budget_overflow_reported_not_dropped` (generator ignores `criteriaBudget`; it is a run-time cost lever, so all rows are emitted and the count is reported on stderr).
**Task gate:** `bash tests/surface-access/run.sh && bash tests/ship-criteria/run.sh`

### Task 9: Coverage gate   (Lane D, risk: high)

**Files:** Create `qa-kit/scripts/coverage.sh`. Test `tests/coverage-gate/run.sh`.
**Interfaces:** `coverage.sh <census.json> <checklist.json> [--exclusions <exclusions.json>] [--mode block|advise]` → `coverage.json` on stdout: `{total, covered, excluded, uncovered, percent, rows:[{surfaceId, personaId, state:"covered"|"excluded"|"uncovered", criteria:[ids], reason?}]}`; exit 1 iff `--mode block` and `uncovered > 0`. Exclusions: `[{surfaceId, personaId|"*", reason}]` — reason required, non-empty.
**Behaviour:** pairs = census surfaces × personas in `reachedBy ∪ allowed`; a pair is covered when any row's `surfaceId` includes it and its persona matches (or row has no persona and surface matches); jobs/mails/notifications counted as surfaces with persona `"*"` (they become coverable in Increment 4; until then default-excluded with reason `channel checks arrive in increment 4` only when the user passes `--defer-channels`).
Census `warnings` are copied into `coverage.json.warnings`; under `--mode block` a census built with a failed adapter also exits 1 unless `--accept-crawl-only` is passed.
**Tests:** `all_covered_exit0`, `uncovered_blocks`, `uncovered_advise_exit0`, `exclusion_without_reason_rejected`, `wildcard_persona_exclusion`, `percent_rounding_one_decimal`, `adapter_warning_surfaces_in_coverage`.
**Task gate:** `bash tests/coverage-gate/run.sh`

### Task 10: data-policy.sh   (Lane C, risk: normal)

**Files:** Create `scripts/data-policy.sh`. Test `tests/data-policy/run.sh`.
**Interfaces:** Config key `dataPolicy`: `{market, forbiddenMarkers:[...], emailDomain, dateWindow:{from,to}, cleanup:"list"|"delete"}`.
- `data-policy.sh check <config.json> <text|@file.json>` → `{ok, violations:[{rule, value, match}]}`; exit 0 ok, 1 violation, 2 usage.
- `data-policy.sh record <run-dir> <entity> <id>` appends to `<run-dir>/created-records.json` `[{entity, id, at}]`; `data-policy.sh list <run-dir>`.
**Exact values:** default `forbiddenMarkers` when unset: `["test","testing","qa","bot","agent","dummy","fake","lorem ipsum","automated","playwright","claude"]`. Matching: case-insensitive, whole word for Latin (`\b…\b`), substring for Arabic entries. Emails must end with `@<emailDomain>` when set. Dates (ISO `YYYY-MM-DD` found in values) must fall within `dateWindow` when set.
**Behaviour:** absent `dataPolicy` → `check` returns ok with `{"policy":"none"}` (no enforcement); JSON input is walked recursively over string values; secrets are never echoed — values longer than 80 chars are truncated in `value`.
**Tests:** `contest_not_flagged`, `qa_word_flagged`, `arabic_marker_flagged`, `email_domain_enforced`, `date_window_enforced`, `no_policy_noop`, `record_and_list`, parity.
**Task gate:** `bash tests/data-policy/run.sh`

### Task 11: qa-kit command wiring (constitution, spec, scenarios, analyze)   (Lane D, risk: normal)

**Files:** Modify `qa-kit/commands/{qa-constitution,qa-spec,qa-scenarios,qa-analyze}.md`, `qa-kit/templates/{constitution-template.md,qa-analyze-template.md}`; create `qa-kit/templates/journeys-template.json`. Test: extend `tests/qa-kit-phases/run.sh` with assertions on command text (the suite already greps command files).
**Interfaces:** Consumes Tasks 2, 3, 6, 7, 8, 9.
**Behaviour:**
- `/qa-constitution`: replaces the "Enabled optional gates" placeholder rows with real `profile` default + gate rows read by `profile.sh` (`uiux` → `detection.ux`, `security` → deny/iso generation on); adds the surface-access confirmation round (`surface-access.sh confirm-table` → human → `apply`; auto-accept with `assumption:true` under `autonomousSetup`).
- `/qa-spec`: writes `journeys.json` from the template; agent drafts journeys from census + docs; human marks P1; `journeys.sh validate` must pass; `run-config.json` may set `profile`.
- `/qa-scenarios`: after normal scenario generation, runs `taking-surface-census` (if no fresh census), `generate-ship-criteria.sh`, then a "fill gaps" pass drafting criteria for `coverage.sh` uncovered pairs.
- `/qa-analyze`: runs `coverage.sh` with mode from effective config; Coverage section lists uncovered pairs; under `ship`, the Verdict is `BLOCKED` until uncovered = 0 (this is the one blocking analyze check).
**Tests:** `constitution_has_profile_rows`, `spec_mentions_journeys_validate`, `scenarios_runs_generator`, `analyze_blocks_on_uncovered_under_ship`.
**Task gate:** `bash tests/qa-kit-phases/run.sh`

### Task 12: Integration, docs, ADRs, release prep   (Lane E, risk: normal)

**Files:** Modify `core/persona-body.md` then regenerate `agents/qa-e2e-pilot.md` + `commands/*.md` via `scripts/build-adapter.sh claude` (byte-oracle); `harness-profiles.json` (add capability `emulate_media` → Playwright `browser_emulate_media`); `.qa/config.json.example` (keys `profile`, `exec.prefix`, `dataPolicy`, `census.maxVisits`, `ship.denyStatuses`, `colorSchemes`, `locales`); `skills/detecting-visual-ux/SKILL.md` (apply `variant.colorScheme` via emulate-media, `variant.locale` via the app's locale switch); `skills/fanning-out-criteria/SKILL.md` (ship profile lanes = D7); `scripts/run-engine-ci.sh` SUITES (`census-adapters census-merge profile journeys data-policy checklist-ship-schema crawl-safety`); `qa-kit/scripts/run-qakit-ci.sh` SUITES (`surface-access ship-criteria coverage-gate`); `scripts/skills.json`; `CLAUDE.md` (skill count 18, invariants: crawl safety, profiles); `README.md`; `CHANGELOG.md`; create `docs/adr/0030-surface-census-and-ship-profile.md`, `docs/adr/0031-journeys-in-checklist-schema.md`.
**Behaviour:**
- Persona phase 0 runs `profile.sh resolve` and writes `.qa/runs/<run>/effective-config.json`; every later phase reads it instead of raw config.
- Persona: ship-profile P1 journeys run sequentially at the primary variant; generated read-only rows fan out per D7; exactly one P1 journey (the first listed) is expanded via `journeys.sh expand-variant` to mobile + the first RTL locale.
- No version bump here (Increment 2's final task releases both).
**Tests:** `bash scripts/validate-adapters.sh` (byte-oracle), `bash scripts/check-suite-coverage.sh`, `bash tests/skill-gate-consistency/run.sh`.
**Task gate:** `bash scripts/run-engine-ci.sh && bash qa-kit/scripts/run-qakit-ci.sh`

---

## Review Focus

1. **Arabic-only destructive labels** (`حذف`, `اعتماد`) on icon buttons with `aria-label` only → must classify unsafe; pinned in Task 7 `arabic_delete_unsafe` (add an `aria-label`-only variant).
2. **Adapter cannot run** (php not on PATH, needs `exec.prefix`) → census still builds from crawl with a visible warning, never an empty "all covered"; pinned in Task 6 `adapter_failure_degrades_with_warning` and Task 9 `adapter_warning_surfaces_in_coverage` (add: coverage.json carries `warnings` from census).
3. **Parameterized routes** (`/h/{slug}`, nested `{hackathon}/{path}`) visited with many concrete ids → must collapse to one surface, not N; pinned in Task 6 `merge_maps_params` (add a two-param case).
4. **Huge census** (hundreds of routes × 15 roles) → generator must not silently truncate under `criteriaBudget`; overflow reported as uncovered; pin in Task 8 `budget_overflow_reported_not_dropped`.
5. **Non-ASCII through every script** (Arabic titles/URLs) → byte parity jq vs python3; pinned by each suite's parity block (Tasks 1, 2, 3, 6, 10).
