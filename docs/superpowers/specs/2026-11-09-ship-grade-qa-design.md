# Ship-grade QA: coverage census, trusted verdicts, compiled regression, non-screen channels

Status: draft for approval · 2026-11-09 · applies to qa-e2e-pilot (engine) + qa-kit (process shell)

## Why

The plugin's core already matches what 2026 research says works for agentic QA: a pass is judged
from persisted state and an independent oracle, not from what the screen looks like (see the
Microsoft Research / Browserbase verifier paper, arXiv 2604.06240: bundled screen-judging verifiers
had 30%+ false-positive rates; state-checking verifiers cut that to 1–8%). Keep that.

What it does not yet deliver is **ship confidence for a whole module**: the confidence that when a
human tester or a customer goes through the product, the mainstream journeys are complete and work
for every role, with no coding bugs left in them. Evidence from the first real module-scale use
(a 186-criterion, 13-role lifecycle QA of a hackathons module, Oct–Nov 2026) shows where it falls short:

1. **Nothing repeatable is produced.** Every run is a one-off agent pass. After 51 fixes landed,
   there was no way to re-verify them except another full agent run (~a day).
2. **Unconfirmed expected values produced verdicts.** 106 model-suggested oracle values were never
   confirmed by a human; 109 verdicts ended `confidence: low`.
3. **No proof of coverage.** Nothing showed which pages, tabs, actions and roles were never touched.
   Scheduled jobs, in-app notifications, team withdrawal, auto-accept, etc. were simply absent.
4. **UI/UX detection existed but was off.** The UX detectors, axe, the generative critic and
   `responsiveMatrix` (ADR-0007/0008/0019) were never enabled; the constitution's `uiux` gate is a
   placeholder that does nothing. No mobile, dark mode, or full RTL pass happened.
5. **Non-screen channels untested.** Email only spot-checked; no in-app notification, scheduler,
   queue, or concurrency (race) coverage.
6. **Permission negatives thin.** 14 hand-written deny checks against a 15-role authz matrix.

(The wrong-logged-in-identity failures from that run are already fixed by ADR-0029.)

## Goal and success measure

The plugin is **general** — any web app, any stack. Stack-specific knowledge lives behind adapters.

A module "passes ship QA" when the plugin can state, with evidence:

- **Census coverage = 100% of in-scope surfaces**: every discovered route/page/tab/action, per role
  that can reach it, has ≥1 criterion or an explicit, reasoned exclusion.
- **Every mainstream journey** (the end-to-end flows the spec marks P1) passes end to end, on the
  build that will ship, with `confidence: high`.
- **Zero open fails of layer `route|service|migration|DB`** (coding bugs) on P1 journeys. FE/UX
  fails and advisory items may remain, listed.
- **A committed regression suite** reproduces every high-confidence pass deterministically and is
  green twice in a row.

Target the user stated: a real tester going through the product after this should find, at most,
UX polish or unanticipated logic edge cases — not missing journeys or coding bugs. Practically:
≥80–90% of what a careful human would find on the mainstream journeys is found first.

**Acceptance test for this work:** a full ship-profile run of the hackathons module on its release
build (innovation project) that meets the bar above, plus its compiled regression suite running green.

## Non-goals

- Replacing human exploratory QA or the human sign-off. The plugin produces the evidence; a human signs.
- Testing AI agents / LLM output quality.
- Native mobile apps.
- Load/performance testing (the `perf` gate stays future).
- Paid SaaS QA services or sending app data to third-party clouds.

## Anti-goals (a failure even if it "works")

- More passes by loosening gates. No change may weaken ADR-0010/0015/0018/0026/0029 enforcement.
- A sixth verdict. Verdicts stay `pass|fail|blocked|deferred|error`; confidence stays `high|low`.
- A healer that edits assertions or expected values so a red test turns green.
- Generated tests that only check the screen (toast/text) — a compiled test without its bake step is invalid.
- Anything hard-coded to Laravel, Inertia, or the innovation project.
- Breaking the multi-harness build (ADR-0017/0024) or the qa-kit "engine untouched" rule — where the
  engine must change, it changes in the engine with its own ADR, not via qa-kit reaching in.

## Constraints

- Respect every invariant in the repo's CLAUDE.md (verdicts, layers, oracle ≠ backend formula,
  run state in `.qa/runs/`, sequential-by-default with opt-in parallel, read-only probing unless
  `allowApiWrites` + disposable marker, secrets never printed, UI-only act path).
- Scripts stay dual-engine (jq | python3) where the engine's existing scripts are; generated test
  code is TypeScript for `@playwright/test`.
- Every new script gets a `tests/<suite>/run.sh` and is registered with the suite-coverage gate.
- New decisions get ADRs (next numbers from 0030).
- Release per the repo's tag rules (engine + qa-kit versions bumped in all sites).

## The design

Four increments. 1 and 2 first (they make the next real run stricter), then 3, then 4.
Each is releasable alone.

### Increment 1 — Coverage census + ship profile

**1a. Surface census (new engine skill `taking-surface-census`).**
Builds `.qa/census.json`: the inventory of what the app exposes, per role.

- Sources, in order of authority: (1) a **stack adapter** that reads the app's own route/page
  registry; (2) static scan of front-end page/route files; (3) a crawl — for each confirmed role's
  session, breadth-first over in-app links, tabs, menus and dialogs-openers (read-only, no submits),
  recording each reachable surface and the actions (buttons/forms) on it.
- Each census entry: `surfaceId`, url pattern, kind (`page|tab|dialog|sheet|action|endpoint|job|notification|mail`),
  roles that can reach it (observed by crawl) vs roles that should (from authz matrix), source(s).
- Diffs are findings: a surface the adapter lists but no role can reach (dead feature / missing nav);
  a surface a role reaches that the authz matrix says it should not (permission bug candidate →
  generated deny criterion).
- **Stack adapter contract** (`adapters/<stack>/census.sh` → JSON on stdout). Ship with: Laravel
  (`php artisan route:list --json` + Inertia/Livewire page dirs), Next.js (app/ and pages/ dirs),
  Rails (`rails routes`), Django (URL resolver dump), Express/Fastify (best-effort static), and a
  generic fallback (crawl only). Adapter chosen from the existing `stack-profile.json`. How the
  adapter is invoked (directly / through docker / ddev / devenv) comes from `.qa/config.json`, never
  assumed.
- Non-UI surfaces in the census: scheduled jobs/commands, queued jobs, mail templates, notification
  classes — from the adapter where the stack exposes them (Laravel: schedule:list, app Mail/Notification
  classes). These feed Increment 4.

**1b. Coverage gate (qa-kit `/qa-analyze`, made blocking for the ship profile).**
Maps every checklist criterion to census `surfaceId`s. Reports per role × surface: covered /
excluded-with-reason / uncovered. Under the ship profile, any uncovered in-scope surface blocks the
run until a criterion is added or an exclusion with a reason is recorded. `/qa-scenarios` gains a
"fill gaps" pass that drafts criteria for uncovered surfaces.

**1c. Journeys as first-class.** The spec declares **journeys**: named, ordered chains of criteria
across roles (e.g. *admin creates hackathon → adds path group → adds paths → attaches challenges →
opens registration → participant registers → team forms → mentor assigned → idea submitted → judges
score → winners announced → public results*). Each journey has a priority; P1 journeys are the
"mainstream" bar. The report shows each journey as a strip of step verdicts; a journey passes only
if all its criteria pass. Journey state hand-off (ids created in step N used in N+1) is recorded in
the run so a resumed run continues the chain.

**1d. Ship profile.** A named run profile (`profile: "ship"` in run-config) that turns on, by default:
- `responsiveMatrix`: desktop 1440×900 + mobile 390×844 for every surface's UX criterion, and the
  P1 journeys run once at mobile too;
- color schemes: light + dark (via the driver's emulate-media capability) for UX criteria;
- locales: every locale the app ships (from the stack adapter / i18n catalog), with RTL locales
  getting the RTL detector family; P1 journeys run once per locale;
- all objective UX detector families + axe + the generative critic (advisory unless corroborated,
  per ADR-0019);
- the generated deny matrix (1e);
- the Increment 4 channel checks;
- coverage gate blocking; oracle-confirmation gate blocking (Increment 2).
This makes the constitution's `uiux` (and the census-driven part of `security`) gates real instead
of placeholders. Other profiles: `smoke` (P1 journeys, desktop, default locale) and `full` (= current behavior).

**1e. Generated deny matrix.** From `authz-matrix.json` × census: for each role × protected surface
or endpoint the role must not reach, generate a read-only deny criterion (direct URL navigation and,
for endpoints, an API probe) expecting the app's refusal (403/404/redirect to login — accepted forms
declared once in config). Cheap, deterministic, high value; also compiled in Increment 3.

### Increment 2 — Trusted verdicts

**2a. Oracle confirmation gate.** Every criterion of kind `computed-logic|business-rule` and every
journey step whose expected value was model-suggested carries `oracleSource`. Before the run,
`/qa-analyze` lists unconfirmed expected values in a compact table for one human confirmation pass
(accept / correct / mark unknown). `checkpoint.sh` refuses `pass` + `confidence: high` when
`oracleSource != human|spec` (today this is an agent-followed authoring rule — make it enforced).
Under `autonomousSetup`, unconfirmed values stay low-confidence and the report counts them prominently.

**2b. State-grounded pass.** A `pass` on any mutating criterion requires at least one evidence item
of kind `bake` (persisted read-back) or `network` (captured response) bound to the act; screenshot/text
evidence alone is rejected at record time. Read-only criteria may pass on DOM evidence. (Extends the
ADR-0010 evidence gate; record-time, fail-fast per ADR-0027.)

**2c. Independent re-adjudication of low-confidence passes.** After the run, a separate verifier
agent with a fresh context and only the evidence bundle (not the runner's reasoning) re-judges every
`pass` with `confidence: low` and every UX promotion. Disagreement downgrades to `blocked` with
reason `verifier-disagrees` for human review. Never upgrades. (Pattern from the Universal Verifier
paper: judge from state, separate judge from actor.)

**2d. Ship readiness summary.** The report opens with the ship verdict computed from the Goal's bar:
census coverage %, P1 journeys pass/fail, open coding-layer fails, regression-suite status,
low-confidence count, flaky count. Rendered deterministically (ADR-0028 renderer).

### Increment 3 — Compiled regression suite

**3a. Compile (new engine skill `compiling-regression-suite` + script).** After a run, every criterion
with `pass` + `confidence: high` and a complete evidence trail compiles to a `@playwright/test` spec
in the target project (default `tests/qa-regression/<target>/`, configurable). The compiler works
from the recorded act trace (the captured human-path tool calls and the locators the agent actually
used), not from prose, so the spec repeats what was verified.

Each compiled spec contains:
- the role's login via a per-role `storageState` setup project (credentials from the existing
  credentials source, never inlined);
- pinned fixture data from the spec's data baseline;
- the UI act with resilient locators (role/label/test-id first; text with locale awareness);
- the **bake step**: a call to the project's **read-back adapter** — a command or endpoint declared
  in `.qa/config.json` (`regression.readBack`) that returns entity state as JSON — asserting the
  pinned expected values;
- for UX criteria under the ship profile: a `toHaveScreenshot` baseline per viewport × scheme × locale
  plus the objective detectors re-run (axe via `@axe-core/playwright`);
- a header comment linking criterion id, run id and evidence.
Criteria that cannot compile (no stable locator, a read-back the adapter can't express) are listed,
not silently dropped.

Journeys compile into serial `test.describe` blocks sharing created ids.

**3b. Run & flake detection (`/qa-regress`).** Runs the suite against a target (the env must be
reset to the data baseline first via the existing seed/auto-seed path — disposable env only for writes).
Runs with `--repeat-each=2`, `retries=0`. A test that passes once and fails once is **flaky**: recorded
as `fail` with a `flaky` tag (no new verdict), quarantined into a list that the ship summary reports.
Output: JUnit (existing `report-to-junit.sh` path) + the run record, so CI and the report read it the same way.

**3c. Locator-only healer.** When a compiled test fails, a healer classifies the failure:
locator/timing drift vs behavior change. For drift it may propose a locator/wait fix as a diff/PR;
it may never edit an assertion, expected value, bake step or screenshot baseline. Behavior changes
become a regular `fail` with suspected layer, and re-enter the agent run as a criterion to re-verify.
Baseline updates are a separate explicit human command.

**3d. Agent run ↔ suite loop.** On the next agent run, criteria already covered by a green compiled
test are skipped by default (cheap regression), and the agent's time goes to new/changed/uncovered
surfaces. This is what makes repeat runs fast.

### Increment 4 — Non-screen channels and concurrency

**4a. Mail.** A mail-capture adapter (Mailpit API first; MailHog and a generic "read the app's mail
log" fallback). Criteria can assert: a mail was sent to recipient X within T, subject/body contain the
expected values, rendered in the recipient's locale, no raw translation keys, links resolve. The census's
mail-template list must each be covered or excluded under the ship profile.

**4b. In-app notifications.** Asserted through the UI (bell/inbox) of the receiving role's session,
plus read-back via the read-back adapter.

**4c. Time-dependent behavior.** For scheduled jobs and date-driven transitions: a **clock adapter**
declared in config (e.g. a command that sets app time, or a command that runs the scheduler for a
given timestamp) on disposable envs only. Without a clock adapter these criteria are `blocked` with
reason, never faked.

**4d. Queues.** Criteria that trigger async work wait for the queue to drain via a declared
`queueDrain` command/endpoint, with a timeout → `fail@service` on timeout.

**4e. Race criteria.** A template for deliberate concurrency tests (ADR-0003 already allows them):
N sessions of the same or different roles perform a conflicting act simultaneously (last slot,
double submit, accept-while-cancel); expectation is the domain invariant checked by bake (e.g. team
size ≤ max). `/qa-scenarios` proposes race criteria for any entity with a capacity, uniqueness or
state-machine rule found in the spec.

## Decided

- Stay general; stack specifics only in adapters, chosen by the existing stack profile. Laravel is the
  first-class adapter (needed for the acceptance test); others ship at "best-effort + tested on a fixture app" level.
- Generated tests are Playwright Test TypeScript, committed in the project under test.
- Healing is locator/timing only, proposed not applied; assertions and baselines are never auto-edited.
- Flakiness is a tag on `fail`, not a verdict.
- No third-party SaaS; everything runs on the user's machines/runners.
- Order: 1 → 2 → 3 → 4; hackathons ship re-run uses 1+2 at minimum.

## Settled after builder review (author's calls, open to override)

1. **Who should reach a surface.** `authz-matrix.json` stays entity-keyed and unchanged. A new
   artifact, `.qa/surface-access.json` (surfaceId → roles allowed), is *derived* from the stack
   adapter (route middleware / policy / permission names where the stack exposes them) plus crawl
   observations, then confirmed by a human once in `/qa-constitution` as an extra round (auto-accepted
   with `assumption:true` under `autonomousSetup`). The generic adapter has no permissions column, so
   generic-stack deny coverage comes only from the confirmed artifact. Deny criteria (1e) and the
   should/does diff (1a) read this artifact.
2. **Suite results inside a run.** When `/qa-regress` covers a criterion, its result is imported into
   the run as an ordinary checkpointed verdict (`pass`/`fail`) with `probe` evidence bound to the
   JUnit case + compiled-spec hash; ADR-0029 supersession applies; `qa-verify.sh` checks the binding.
   No new verdict. Suite-only passes count toward census coverage and the ship summary, labelled
   "via regression". A criterion whose compiled spec changed since its last agent pass is not skipped.
3. **Oracle gate scope.** Enforced by `checkpoint.sh` only when a criterion carries `oracleSource`
   (qa-kit) or the run profile is `ship`. Plain `/qa-run` without those is unchanged. `oracleSource`
   gains `spec`, allowed only when the value is quoted from an ingested spec with a file:line citation
   that `check-fixtures.sh` validates; model-suggested values stay `llm-suggested`.
4. **Target-project footprint.** The compiler scaffolds a self-contained folder
   (default `tests/qa-regression/`) with its own `package.json`, lockfile, `playwright.config.ts`
   (per-role setup projects) and baselines. It never edits the app's root dependencies or config.
   First scaffold is shown to the user before it is written.
5. **Deny matrix scope.** Navigation and GET probes everywhere. Mutating-method deny probes only when
   `allowApiWrites` + the disposable marker are set; otherwise they are listed as `deferred` with
   reason, and the ship summary says permission negatives are read-only.
6. **Harnesses.** Compile/regress ship for Claude Code first; other harnesses later with an honest
   capability banner. To compile without depending on MCP `ref`s or `--save-session`, the act phase
   records a stable locator (role+name / label / test-id / text) alongside each act call in the evidence
   at record time; that is the compiler's input.
7. **Journeys in the engine.** Journeys enter the engine's checklist schema (engine ADR), because the
   report and the compiler both need them; qa-kit authors them. Engine and qa-kit release together,
   qa-kit pinning `qa-e2e-pilot ~<new minor>`.
8. Evidence kind for network responses is the existing `probe` (no new kind).

## Settled in the grilling session (2026-11-09, user accepted all recommendations)

**Additions to Increment 1**
- **Crawl safety:** the census crawl follows links, tabs and menu/dialog openers only, cancels any
  dialog it opens, and never clicks an action button not classified safe — on any environment.
  Surfaces it cannot open safely are reported as "unexplored".
- **Matrix strategy:** each journey's writes run once (desktop, primary locale). Every surface the
  journey touched is then revisited read-only per other viewport × locale × color scheme (screenshots,
  UX detectors, RTL). Exactly one P1 journey also runs fully at mobile in the RTL/secondary locale.
- **Error sweep:** every census surface × role must load with no 5xx and no in-scope console error
  (auto-generated criteria, fed by the crawl).
- **Input edge cases:** for every form in the census, generated criteria for required-empty, max
  length, oversized numbers, non-Latin/special characters, invalid/past dates — expecting a validation
  message, never a 5xx.
- **Data isolation:** same-role, other-owner record access (read-only GET / navigation) from the
  entity-ownership chains in `authz-matrix.json`.
- **Data policy:** a general `dataPolicy` config — market/locale, forbidden markers (e.g. test, QA,
  bot, agent), email domain, date window, cleanup mode (list|delete). Enforced at record time: data
  containing a forbidden marker is refused. Created records are tracked by id for cleanup.
- **Parallel lanes in the ship profile:** read-only work (crawl, error sweep, deny/isolation,
  UX revisits) may run in up to 3 contexts; journeys stay sequential. Budget ≈1 day for a module the
  size of the hackathons module.
- **Journey authoring without a spec:** the agent drafts journeys from census + project docs; the
  human approves them and marks P1 in `/qa-spec`. The plugin never assumes what is mainstream.

**Additions to Increment 2**
- **Confirmation page:** `/qa-analyze` renders one confirmation table grouped by business rule
  (accept / edit / unknown); saving writes `oracleSource: human`.
- **Bug export:** a tracker-neutral bug export (one markdown/JSON item per finding, plain business
  language, deduplicated against `known-defects.json`). Tracker adapters (e.g. ClickUp) are optional
  add-ons outside the core.

**Measuring the goal (exit check for Increments 1+2)**
- Recall benchmark on real bugs: run the ship profile against the hackathons module's pre-fix build
  (`cdc3441cf`) in a disposable copy and count how many of the 53 known defects are found unprompted.
  Target ≥85% recall at ≥90% precision. Repeat after each plugin release, alongside the existing
  `tools/accuracy-harness` fixture.

**Acceptance and rollout**
- Acceptance run = the plan's final milestone: a disposable local copy of the innovation project on
  its release build (writes, clock adapter, Mailpit), then one read-only smoke run on staging.
- Not blocked on this work: a hackathons re-run starts now on the installed 0.11.0 with a v3 plan
  (v2 ids kept + criteria for the fixes' new UI and stage-gate steps + the P1 journeys + mobile/Arabic
  revisits + UX detection on), with expected values confirmed via a manual markdown table first.
  That run and its bug routing live in the innovation project, not in this plugin.
- Work split: one plan per increment (plan-lite format, executed via sdd-lanes in worktrees).
  Increments 1 and 2 start together; 3 waits on 1's journey schema; 4 follows.

## Left to the builder

- Exact census JSON schema and crawl limits (depth, budget), as long as the crawl is read-only and
  bounded.
- How journeys are expressed in the spec format (new section vs criterion field), keeping qa-kit's
  frozen-plan model.
- The compiler's internal representation and locator-ranking heuristic.
- Which skills vs scripts vs qa-kit commands hold each piece, within the engine/qa-kit split rules.
- Screenshot-diff thresholds and masking of dynamic regions.
- ADR split (one per increment is fine).
- The innovation project's own adapter config (read-back command, clock command, queue drain) is set
  up during the acceptance run, not in the plugin.
