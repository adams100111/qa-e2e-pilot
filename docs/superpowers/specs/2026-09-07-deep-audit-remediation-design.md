# Deep-Audit Remediation (2026-09-06 multi-agent audit) — Design

**Status:** approved (grill round 2026-09-07 — all 10 open decisions settled, recorded inline as
**Decision:** lines) · **Date:** 2026-09-07 · **Topic:** close every finding of the
2026-09-06 **multi-agent** deep audit of both plugins (8 domain analysts + adversarial verification;
93 findings, **27 majors independently CONFIRMED against the code, 0 refuted**, 66 minors/unverified),
and close the product-credibility gaps the value assessment identified — in five independently
shippable waves.

**Prior art:** `2026-09-06-audit-remediation-design.md` remediated a *different, earlier* inline audit
(F1–F9: verify-plan wiring, CI breadth, small fixes). Its increments have landed. This spec is the
successor: the 2026-09-06 multi-agent audit ran against HEAD *after* that work, so nothing here
duplicates it.

**Source of truth for findings:** the delivered audit report (`qa-plugins-audit-2026-09-06.md`, 93
findings with per-finding verifier evidence). Every confirmed finding is restated here with enough
detail to implement without the report; minors are listed one-line in Appendix A.

---

## Problem

The audit's one-sentence verdict: *the architecture and honesty discipline are best-in-class, but the
confirmed defects cluster exactly where CI cannot see them* — the installed-user path, the
enforcement gates' failure modes, and skill-docs that drifted from the enforcement scripts they feed.
Concretely:

1. **Enforcement gates fail open or reject legitimate work** (W1): qa-verify verifies 0 passes and
   exits 0 on macOS bash 3.2; the act-lint rejects sanctioned dialog/drop tools; provenance's jq leg
   false-fails whole runs on one torn toolstream line; the no-flock merge lock self-destructs; the
   bootstrapped config defeats the production write-guard by default.
2. **The installed product is broken** (W2): `/qa-resume` is not installed by 5 of 6 install paths
   and cannot resolve its scripts on the 6th; the Pi installer destroys user MCP config; opencode
   never loads the persona; qa-kit's out-of-plan gate polices an agent-writable file.
3. **Skills contradict their own gates** (W3): an agent following `driving-browser-qa` verbatim has
   every human-action pass rejected; two UX detectors never reach their promised definite-oracle
   grade; the checklist skill teaches a 3-kind vocabulary the 4-kind gate rejects; every computed
   criterion's report links a nonexistent `recompute.md`.
4. **Test/CI blind spots + doc drift** (W3/Appendix): 9 of 11 `scripts/tests/*.sh` run nowhere; one
   suite assertion is tautological; ~30 doc-drift items including CLAUDE.md's opener being wrong on
   all four counts.
5. **Product credibility gaps** (W4, from the value assessment): the 85% recall number is
   same-fixture/post-tuning; 3 of 4 harnesses are accuracy-unvalidated yet advertised; zero cost
   telemetry; no stated "when not to use" boundary; accuracy gates not in CI.

## Constraints (binding — copied from repo law, unchanged)

- **Engine invariants:** verdicts exactly `pass|fail|blocked|deferred|error`; confidence `high|low`;
  suspected layer `FE|route|service|migration|DB`. No new verdicts. Oracle is never the backend's
  formula. Run state stays in `.qa/runs/<id>/`.
- **Generated-and-committed discipline:** engine `agents/qa-e2e-pilot.md` + `commands/*.md` and
  qa-kit's Claude command/agent files are build outputs. Edit `core/` / `qa-kit/core/` sources +
  manifests, regenerate (`build-adapter.sh claude`, `build-qakit-adapter.sh claude`), keep both
  byte-oracles green (`validate-adapters.sh`, `validate-qakit-adapters.sh`). Never hand-edit
  committed generated files. `dist/` stays git-ignored.
- **qa-kit never modifies the engine** within qa-kit-scoped tasks; engine fixes are their own tasks.
  qa-kit references engine state only via `.qa/` or qualified slug (per-plugin
  `${CLAUDE_PLUGIN_ROOT}`).
- **Dual-engine idiom** for every touched script: jq preferred, python3 fallback, byte-identical
  output (`jq -Sc` ⇔ `json.dumps(sort_keys=True, separators=(",",":"))`), clear error when neither
  engine exists. No `grep -P`/perl in bash paths.
- **Never weaken a gate to make something pass.** Fixes to over-strict gates must add the sanctioned
  path, not remove the check.
- **Every behavior fix ships with a test** in the existing `tests/<name>/run.sh` pattern, enrolled in
  the suite-coverage gate (`check-suite-coverage.sh` must count it exactly once).
- **No destructive git; commit per task; push only when asked.** Commit messages carry no
  Claude/Anthropic attribution.
- **Bash 3.2 floor** (new, from W1-1): enforcement-path scripts must run correctly on macOS stock
  bash 3.2 — no `mapfile`/`readarray`/`declare -A` on any path that gates verdicts, or an explicit
  bash-version check that **fails closed** with a clear message.

## Wave structure

**"Wave" (term):** an independently shippable batch whose *items run in parallel* (worktree-isolated
subagents) and which lands as one branch/PR. Deliberately distinct from the earlier remediation's
sequential "Increments" — the parallelism is the point.

Waves are independently shippable, ordered by risk. Within a wave, items are parallelizable
(worktree-isolated subagents, one item each; integrator regenerates adapters and runs the full gate
at each wave boundary). Wave gate = all engine + qa-kit suites green, both byte-oracles green,
`bash -n`/`node --check`/JSON validation sweep green.

---

## Wave 1 — enforcement correctness (5 items; nothing ships before these)

### W1-1 `qa-verify.sh` fails open on macOS bash 3.2 — CONFIRMED major
`scripts/qa-verify.sh:1308` uses `mapfile -t _qv_fields`; on bash 3.2 (macOS default, claimed
supported by README:197/INSTALL.md:118) the builtin is missing, `_qv_fields` stays unset, every pass
record is skipped, and qa-verify **exits 0 having verified nothing**. Same failure class in
`required-kinds.sh:144` and `mutation-flag.sh:134` (empty derive → `gate_required_kinds` returns 0 —
the dropped-kind gate silently no-ops). `csv_to_json_array`'s `"${arr[@]}"` under `set -u` also
hard-fails on empty arrays under 3.2.

**Decision (grill Q1):** BOTH, in order. Step 1 (hotfix, first commit of W1): a top-of-script
bash-version gate in all three scripts that dies loudly on bash <4 (fail closed), plus
README/INSTALL noting the temporary `brew install bash` requirement on macOS. Step 2 (same wave):
replace `mapfile`/bash-4isms on all verdict-gating paths with 3.2-safe constructs
(`while IFS= read -r` loops; `${arr[@]+"${arr[@]}"}` guard), remove the version gate, restore the
macOS-native claim.
**Acceptance:** a new `tests/` case runs qa-verify + required-kinds + mutation-flag under
`bash --posix`-flavored 3.2 emulation or asserts zero bash-4 builtins on gating paths
(`grep -nE 'mapfile|readarray|declare -A' scripts/qa-verify.sh …` = empty); a seeded run verified
under the constrained shell yields the same verification.json as under bash 5.

### W1-2 Act-lint rejects sanctioned `browser_handle_dialog` / `browser_drop` — CONFIRMED major
`skills/checkpointing-qa-memory/scripts/check-action-trace.js:31` `HUMAN_PATH_TOOLS` omits both,
while `provenance.sh:266`, qa-verify's `classify_tool`, and `state-machine-schema.md:116` all
sanction them as human-path interaction tools. Any delete-with-confirm flow's legitimate pass dies
with `act performed via workaround "browser_handle_dialog"` (checkpoint gate, qa-verify re-check, and
Check 3 N2 at line 181 all reject).

**Required:** add `browser_handle_dialog` and `browser_drop` to `HUMAN_PATH_TOOLS`; sweep for any
other divergence between the three tool-class authorities (`check-action-trace.js`, `provenance.sh`,
`classify_tool`) and reconcile to one documented list (`state-machine-schema.md` is the doc anchor).
**Acceptance:** `tests/action-trace` gains a delete-with-dialog fixture that passes the gate; a
cross-authority consistency test asserts the three tool sets agree (extract + diff).

### W1-3 Provenance jq leg treats a torn toolstream as empty — false `unbound` overrides — CONFIRMED major
`scripts/provenance.sh:514` `cmd_check` slurps with `jq -s -c '.'`; one unparseable (torn) line —
a crash class `journal.sh`/`toolstream.sh` explicitly document and every other reader tolerates
line-by-line — fails the whole slurp, `events_json` degrades to `[]`, every artifact resolves
`unbound` (the AC-1 forgery signal), and qa-verify **overrides genuine passes to fail@high**. The
python3 leg (518–530) skips bad lines and returns `bound` — a confirmed dual-engine divergence in
the anti-forgery check itself.

**Required:** make the jq leg line-tolerant (per-line `fromjson?` filter, e.g.
`jq -R 'fromjson? // empty'` then slurp) so both engines skip torn lines identically; emit a WARN
counting skipped lines (a torn line is still evidence of a crash).
**Acceptance:** `tests/provenance` gains a torn-last-line fixture asserting byte-identical
bound/unbound output across `QA_ENGINE=jq` and `QA_ENGINE=python3`, plus the WARN line.

### W1-4 `journal-merge.sh` no-flock lock: trap installed before acquisition — CONFIRMED major
`skills/checkpointing-qa-memory/scripts/journal-merge.sh:393` registers
`trap 'rm -rf "$mkdir_lock"' EXIT` **before** the `until mkdir` loop. A waiter that times out (30s
`die`) or dies pre-acquisition removes the *holder's* live lock; a third invocation then acquires and
races the still-running holder → duplicate/overlapping seq in `journal.ndjson` — the exact corruption
the lock exists to prevent. Default path on macOS (no flock binary).

**Required:** install the cleanup trap only after successful `mkdir` acquisition; the pre-acquisition
timeout path must exit without touching the lock dir.
**Acceptance:** `tests/journal-merge` (or the existing journal suite) gains a case: process A holds
the lock, process B times out, assert the lock dir still exists and A's merge completes with
monotonic seq.

### W1-5 Default `seedableEnvMarker` collapses the disposable-env write gate — CONFIRMED major (×2 analysts)
`skills/bootstrapping-qa-config/scripts/init-config.sh:21` unconditionally writes
`seedableEnvMarker: "QA_DISPOSABLE_ENV"` (even with `--environment production`), and
`.qa/config.json.example:28` ships the same. But `detect-stack.sh:307` and `preflight.sh:213` infer
production under `environment:auto` **only when the marker is empty**, and `auto-seed.sh` treats a
non-empty marker as the deliberate "disposable" operator signal. Net: every bootstrapped/example
config pointed at a remote URL is classified disposable; the CLAUDE.md invariant "writes require
`allowApiWrites` AND the disposable-env marker" degrades to `allowApiWrites` alone.

**Required:** default `seedableEnvMarker` to `""` in both `init-config.sh` and the example; write a
non-empty marker **only** on an explicit operator opt-in (new `--seedable-marker <value>` flag /
bootstrap question, asked only when writes were requested). Update the `_seedableDoc` prose to state
that empty = not disposable = production-inferred under `auto`.
**Decision (grill Q2) — installed-base migration:** `preflight.sh` and `detect-stack.sh` treat the
**verbatim default sentinel** `"QA_DISPOSABLE_ENV"` as never-deliberately-opted-in: WARN loudly and
force production-inference for that exact value. A deliberate operator picks any other marker
string. Documented in `_seedableDoc`.
**Acceptance:** `tests/init-config`: default bootstrap → marker empty; `--environment production` →
marker empty regardless of flags; explicit opt-in → the given value. A `detect-stack` case asserts a
remote-URL + `auto` + default-bootstrapped config now infers production.

---

## Wave 2 — the installed-user path (5 items)

### W2-1 `/qa-resume` neither installed nor resolvable outside a dev checkout — CONFIRMED major (×3 findings)
(a) `scripts/install.sh:47` and `scripts/skills.json` list only `qa-run`/`qa-roles` — manual + npx
installs have no `/qa-resume` at all. (b) All three non-Claude installers
(`install-codex.sh:15-16`, `install-pi.sh:15-16`, `install-opencode.sh:16-17`) copy only
qa-run/qa-roles even though `build-adapter.sh:85` renders qa-resume into every `dist/<h>/commands/`
— while `docs/harness-adapters.md:192` claims "Resume is the same portable /qa-resume on every
harness" and ADR-0020 calls it "guaranteed everywhere". (c) `commands/qa-resume.md:17` invokes
`bash skills/checkpointing-qa-memory/scripts/qa-resume.sh` — a repo-root-relative path that resolves
only when the project under test *is* the plugin repo; marketplace installs live under
`~/.claude/plugins/...` and non-Claude installs put skills at `.pi/agents/skills/` /
`.agents/skills/`.

**Required:** (a) add qa-resume (+ any future command) to `install.sh` and `skills.json` — prefer
globbing `commands/*.md` over a hardcoded list; (b) make all three harness installers copy **all**
rendered `dist/<h>/commands/*.md` (the pattern qa-kit's `_install-common.sh` already uses); (c) fix
the source `core/commands/qa-resume.md` to resolve scripts portably: `${CLAUDE_PLUGIN_ROOT}` on
Claude via a harness token, and per-harness skill-dir tokens for the others (extend
`harness-profiles.json` with a `SKILLS_DIR`-style token if absent), then regenerate all adapters.
**Acceptance:** `scripts/tests/test-core-sources.sh` covers qa-resume; a new test asserts every
installer ships every rendered command; grep proves no committed command references a bare
`skills/...` path; byte-oracle green after regeneration.

### W2-2 Pi installer blind-overwrites `.pi/mcp.json` — CONFIRMED major
`harnesses/pi/install-pi.sh:17` `cp`s the snippet over the project's `.pi/mcp.json`, destroying
pre-existing MCP servers — contradicting the Common-ground contract (`docs/harness-adapters.md:179`:
"never overwriting … never colliding") and the blessed coexisting-playwright setup. Codex/opencode
correctly print-and-ask.

**Required:** merge the `playwright-qa` entry into an existing `.pi/mcp.json` (jq/python3
dual-engine merge, back up the original beside it), or fall back to print-and-ask exactly like the
codex/opencode installers when no engine is available. Never delete unknown keys.
**Acceptance:** new test: pre-existing mcp.json with a foreign server → post-install both entries
present, backup file exists; no-preexisting-file case unchanged.

### W2-3 opencode `/qa-run` never binds the qa-e2e-pilot agent — CONFIRMED major
`harness-profiles.json:53` promises `agent: qa-e2e-pilot` binding, but the rendered
`dist/opencode/commands/qa-run.md` has only Claude-style frontmatter — on opencode the command runs
under the **default** agent: persona, guardrails, and tool grants never load. Additionally
`{{DISPATCH}}` renders self-referentially on all non-Claude harnesses (the /qa-run prompt tells the
user to run /qa-run).

**Required:** emit `agent: qa-e2e-pilot` frontmatter in opencode command renders (template or
generator special-case, mirroring however qa-kit solved the same problem if it did); rewrite the
non-Claude `{{DISPATCH}}` profile strings to describe the *actual* mechanism per harness (load
persona X / switch agent) instead of pointing back at the command itself.
**Acceptance:** built `dist/opencode/commands/qa-run.md` contains the `agent:` key;
`scripts/tests/test-opencode.sh` (enrolled per W3-6) asserts it; no rendered command instructs
running itself.

### W2-4 qa-kit `/qa-verify` polices the run's own checklist copy — gate launderable — CONFIRMED major
`qa-kit/commands/qa-verify.md:29` runs
`verify-plan.sh .qa/runs/<id>/checkpoint.json .qa/runs/<id>/checklist.json`. The run-dir checklist is
agent-writable (ingest "expands" criteria; journal-emit supports `plan_amended`), so an agent that
amends its in-run checklist makes every act vacuously in-plan; the only cross-check against the
authored contract silently degrades to the run copy on divergence.

**Required:** verify-plan must compare acted ids against **`.qa/specs/<target>/checklist.json`** (the
frozen contract) when a spec target is resolvable, and treat run-vs-spec checklist divergence as a
finding (out-of-plan additions listed), not a silent fallback. Run-copy comparison remains only for
spec-less engine-solo runs, labeled as the weaker mode in output. Edit the qa-kit **core** command
source + regenerate; `verify-plan.sh` may gain an explicit `--plan <path>` distinction but its
existing CLI contract and suites must stay green.
**Acceptance:** `tests/qa-kit-enforcement` gains: amended run checklist + unchanged spec plan → the
amended act flagged out-of-plan; spec-less run → weaker-mode banner. qa-kit byte-oracle green.

### W2-5 qa-kit persona ships Claude-only slug syntax to all non-Claude harnesses — CONFIRMED major
`qa-kit/core/persona-body.md:24`'s closing instruction — invoke the engine's skill "by its qualified
slug (`/qa-e2e-pilot:<skill>`)" — is plain text, not a token, so `build-qakit-adapter.sh` renders it
verbatim into every non-Claude agent (confirmed in `qa-kit/dist/pi/agent/qa-kit.md:29`,
`dist/codex/agent/qa-kit.toml:27`, `dist/opencode/agent/qa-kit.md:34`). On those harnesses no plugin
namespace exists; the correct forms are bare-name skills (Pi/Codex) or `skills_<name>` tools
(opencode) — the generated agent is told to use an invocation syntax that cannot resolve.

**Required:** introduce a `{{SKILL_REF}}`-style token (or reuse the existing skill-reference token
if `harness-profiles.qakit.json` already carries one for the commands) for this instruction in
`qa-kit/core/persona-body.md`, render per harness, regenerate all four adapters; sweep the qa-kit
core sources for any other untokenized "qualified slug" residue.
**Acceptance:** `tests/qakit-adapters` asserts no `/qa-e2e-pilot:` literal appears in any
non-Claude rendered agent/command, and that each harness's rendered form matches its profile's
skill-invocation idiom; qa-kit byte-oracle green.

---

## Wave 3 — skills/gates reconciliation + test-coverage holes (7 items)

### W3-1 `driving-browser-qa` evidence recipe omits mandatory fingerprints — CONFIRMED major
SKILL.md:87's delta-slice recipe never mentions `--fingerprint-before/--fingerprint-after`, and
"fingerprint" appears nowhere in the skill or `interaction-discipline.md` — but
`check-action-trace.js:172` (Check 3/R1) hard-dies on any human-action pass without a
`{before,after}` fingerprints object. A skill-following agent's every human-action pass is rejected.

**Required:** add the fingerprint capture + arguments to the recipe (steps: capture before-state via
the documented read-only observe path, act, capture after, pass both to `record-evidence.sh`), and a
cross-reference in `interaction-discipline.md`. Body stays <500 lines (move detail to references/ if
needed).
**Acceptance:** grep: `fingerprint-before` present in driving-browser-qa; a doc-consistency test
asserts every flag `check-action-trace.js` requires is named in the skill that owns the recipe.

### W3-2 UX detector ids never match their oracle grades — definite fails degrade to advisory — CONFIRMED major (×2)
`ux-detectors.js:485` emits `asset-broken-image` but `adjudicate.js:16` keys the definite-dom grade
on prefix `broken-image` (prefix match from position 0 → no match → default heuristic).
`ux-detectors.js:525` emits `overlap-modal-behind-backdrop`, which prefix-matches
`['overlap','heuristic']` instead of `['modal-behind-backdrop','definite-dom']`. Both promised
`fail@FE/high` classes silently land in the advisory stream; `tests/ux-adjudicate` tests bare ids
the detectors never emit.

**Required:** align ids (rename detector ids to the graded prefixes, or add explicit
`ORACLE_GRADES` entries for the emitted ids — pick one authority and add a completeness check that
every emitted detector id resolves to its intended grade, not the default). Fix the unit tests to
grade the ids **actually emitted**.
**Acceptance:** a new `tests/ux-detectors`/`ux-adjudicate` case enumerates every id `ux-detectors.js`
can emit and asserts its adjudicated grade against a committed expectation table; broken-img and
modal-behind-backdrop fixtures produce `fail@FE` high, not advisory. Re-run
`tools/accuracy-harness/run-ux-measure.sh` — gate must stay green (the measured 100% relied on these
classes; if the measured file shifts, re-measure honestly, never hand-edit).

### W3-3 Stale kinds vocabulary + dead recompute links + ADR-0015 contradictions — CONFIRMED majors (×3)
(a) `generating-qa-checklist/SKILL.md:244` Step 7 defines Kinds as `bake|computed|probe` (no
`human-action` row; fixed CSV order at :258; template `templates/checklist.md:46`+:25 repeat it) —
but `required-kinds.sh` derives 4 kinds and the schema declares 4; an author following Step 7 writes
checklists the gate then contradicts. (b) `writing-qa-reports/SKILL.md:34` + all three templates link
`evidence/<crit>/recompute.md`; the real artifact is `recompute.json`
(`record-evidence.sh:186`, checkpoint gate) — dead links in every computed-criterion report.
(c) `walking-multistep-flows/SKILL.md:153` Eval 3 instructs "Re-fill using the script" via
`react-set-input.js`, which is read-only post-ADR-0015 — the instruction steers agents into the exact
workaround the gate rejects.

**Required:** (a) rewrite Step 7 + template to the 4-kind vocabulary matching `required-kinds.sh`
exactly; (b) `recompute.md` → `recompute.json` in the SKILL and all three templates; (c) rewrite
Eval 3 to the sanctioned human-path re-fill (browser_type etc.), consistent with driving-browser-qa
Eval 4.
**Acceptance:** greps: no `recompute.md` reference outside changelogs; `human-action` present in
Step 7's derivation table; no skill instructs setting values via react-set-input.js. Existing
checklist/report suites green.

### W3-4 `write-persona-config.sh` breaks its own degrade path and deletes `expectedSubject` — CONFIRMED majors (×2)
(a) Both engine legs hard-require a non-empty authz matrix (jq :71, python :111, exit 4), but
SKILL Eval 2 (:445) mandates writing an **empty** matrix on the single-user/weak-signal degrade path
and claims a conditional that does not exist — the degrade path is impossible via the mandated
script. (b) The wholesale personas regeneration (`.personas = $personas[0]` at :79) silently deletes
operator-configured `personas[].expectedSubject` — the only ground truth that lets qa-verify
(:441) hard-fail an acting-identity mismatch; without it mismatches merely degrade confidence.

**Required:** (a) accept an empty array when an explicit `--allow-empty` (or equivalent
degrade-mode) flag is passed; the SKILL's Eval 2 documents passing it on the weak-signal path only.
(b) preserve `expectedSubject` (and any operator-only keys, via an explicit preserve-list) across
wholesale regeneration — merge per-persona by id, regenerating discovered fields, keeping operator
fields.
**Acceptance:** `tests/write-persona-config`: empty-matrix + flag → writes `[]`, exit 0; empty
without flag → still exit 4; regeneration over a config with `expectedSubject` → key survives; a
persona removed upstream disappears (wholesale semantics otherwise intact, ADR-0011).

### W3-5 Broken/no-op detector + config keys promising unbuilt behavior — CONFIRMED majors (×3)
(a) `overlay-stack.js:56` `checkNoDeadEnd` flags an "interaction-dead-end" whenever the overlay
stack is empty — but `extractOverlayStack` captures only overlay nodes, so a *correctly* fully-closed
flow is indistinguishable from a dead-end → false `fail@FE/low` on every clean close (behavioral
grade = real verdict, not advisory). (b) `index-routes.sh:57` node fallback puts `QA_CFG="$file"`
*after* the command (argv, not env) — with node-but-no-jq, config `repos[]` is silently ignored and
the backend scan skipped (`2>/dev/null || true` swallows it). (c) `.qa/config.json.example:32`
`fingerprintPaths`/`noProbePaths` have **zero consumers**, and detecting-stack-profile's documented
runtime OpenAPI/HTML fingerprint is unimplemented (only a header curl exists;
`stack-signatures.json` html markers + `openapiPaths` never evaluated).

**Required:** (a) capture a base-context descriptor (document body present / main landmark) in
`extractOverlayStack`'s afterClose snapshot so empty-stack+healthy-base returns no suspicion; flag
only empty-stack + missing/inert base. (b) move the env assignment before `node` (`QA_CFG="$f" node
-e '…'`) in both fallbacks; stop suppressing the failure silently (WARN to stderr). (c) either
implement the documented probes (bounded: fetch `fingerprintPaths` minus `noProbePaths`, match
`runtime.html` markers + openapi paths, read-only, honoring `noProbePaths`) **or** delete the two
config keys + the SKILL's claims — no third option of keeping the promise unimplemented. Decision
default: implement — the keys are already designed and prod-safety-scoped.
**Acceptance:** (a) `tests/interaction-ux`: clean-close fixture → no dead-end finding; true dead-end
fixture still caught. (b) `tests/init-config`-adjacent case runs index-routes with jq disabled +
node present → repos resolved. (c) either `tests/detect-stack` covers marker+openapi matching and
`noProbePaths` exclusion, or greps prove the keys/claims are gone everywhere.
**Decision (grill Q3):** implement (not delete) — black-box detection is a differentiator and the
signature data already exists; only the consumer loop is missing.

### W3-6 Orphaned test scripts + tautological assertion — CONFIRMED major + minor
`scripts/tests/`: 9 of 11 (`test-generator.sh`, `test-codex.sh`, `test-pi.sh`, `test-opencode.sh`,
`test-docs.sh`, `test-validate.sh`, `test-qaci-harness.sh`, `test-sessionlogdir.sh`,
`test-humaninteraction-defaults.sh`) are invoked by nothing (`validate-adapters.sh:21` runs only
test-profiles + test-core-sources), and `check-suite-coverage.sh:28` audits only `tests/<name>/run.sh`
so it cannot see them — per-harness adapter render assertions currently run **nowhere**. Also
`tests/qakit-adapters/run.sh:26` compares a grep count to itself (can never fail).

**Required:** enroll all 9 in a gate (either invoked by `validate-adapters.sh` or wrapped as
`tests/<name>/run.sh` suites the coverage meta-check counts); extend `check-suite-coverage.sh` to
also inventory `scripts/tests/*.sh` against an enrollment list so the orphan class is caught
structurally. Fix the qakit-adapters assertion to compare against the independedly-derived expected
count.
**Acceptance:** coverage meta-check fails if any `scripts/tests/*.sh` is unenrolled (proven by
temporarily adding a dummy); all 9 run green in CI; the fixed assertion fails when the slug is
absent (mutation-check it once).

### W3-7 Minor-findings batch — verify-then-fix
The 60+ minors in Appendix A (doc drift, small script bugs, vacuous-test risks) were **not**
adversarially verified. **Decision (grill Q4) — scope:** fix (a) all script-**behavior** minors and
(b) the entire doc-drift cluster (both directly hurt users); the design-risk / nice-to-have
remainder is NOT fixed in this effort — log each to `docs/doc-sync-todo.md` (or
`docs/known-issues/` where user-visible) as triaged debt. Each fix task: first reproduce/confirm
against HEAD (some may already be stale), then fix, one commit per coherent group (per file/area),
skipping any that turn out false with a one-line note in the PR body. Highest-value subgroups called out: the `init-config.sh:85`
truncate-on-invalid-flag bug; `spec-snapshot.sh` non-atomic/divergent `create`;
`detect-seed.sh` cwd cross-engine break (CONFIRMED, fix with byte-parity test); `data-baseline.sh`
`is_int` accepting `1-2`; dual-engine suites passing vacuously when both engines are absent (make
the harness die when neither jq nor python3 exists); the CLAUDE.md/INSTALL.md/README count-drift
cluster; qa-kit spine docs missing the shipped `/qa-verify` step.

---

## Wave 4 — product credibility (5 items, from the value assessment; P0s first)

### W4-1 Second-app accuracy measurement (the credibility anchor)
The headline 85% blind recall is same-fixture and post-tuning: the 62%→85% lift came from fixing
checklist-generation gaps identified from that fixture's own misses (train-on-test;
`tools/accuracy-harness/README.md:151-153`). **Decision (grill Q5):** author ONE fresh seeded
fixture in-repo (reusing the seeds.json schema) under a **firewall discipline written into the
task** — the fixture-author agent must not read the checklist-generator/skill code, and the new
seeds stay sealed from the running agent until its measured run completes; record "plant bugs in a
real OSS app" in the accuracy README as the future gold standard. **Required:** run the full blind
procedure; commit `findings/measured-<newfixture>-run.json`; publish both numbers side by side in
the accuracy README with the current one labeled "same-fixture, post-tuning".
**Acceptance:** the new measured file exists with `"estimated": false`; README table carries both
rows with the labels; no threshold is lowered to make the new number pass — if it gate-fails,
that's the honest published number plus a gap analysis.

### W4-2 Non-Claude accuracy validation + honest advertising
`docs/harness-adapters.md:358` mandates a manual accuracy run per non-Claude harness before trusting
it; `tools/accuracy-harness/findings/` has zero `measured-<harness>` files, yet README:204 advertises
all four harnesses uncaveated. **Decision (grill Q6):** the Pi run is in scope for this effort,
executed on this machine (Pi is provisioned per the portability spec) **after W1–W3 land** — no
point measuring against known-broken gates; banners go up immediately (in W2's installer touches or
first W4 commit, whichever lands first). **Required:** execute the mandated run on **Pi** (named
first in the doc); commit `measured-pi-run.json`. Until Codex/opencode follow, add an explicit
"accuracy-unvalidated — see harness-adapters.md" banner to their installers' output and to
README:204 + each harness README. Also fix the three harness READMEs calling the measured reference
numbers "the 85%/100% gate" (they are not the enforced thresholds).
**Acceptance:** Pi measured file committed; banner grep in both remaining installers + READMEs; the
gate-threshold wording corrected.

### W4-3 Per-run cost telemetry
No token/wall-clock/tool-call cost is recorded anywhere; the buy-decision question is unanswerable
and a runaway run is invisible. **Required:** record per-run `startedAt`/`finishedAt` wall-clock,
per-criterion tool-call counts (derivable from the toolstream — it already logs every call), and
criteria totals into the run-manifest; print a cost summary block in `report.md` (and the JUnit
export); make `criteriaBudget` warn at 80% consumption during the run.
**Decision (grill Q7):** tool-calls-as-proxy is the portable metric (honest "tool-calls" label);
the manifest schema carries an **optional** `tokens` field that the Claude harness fills when usage
is exposed — no per-harness token-API integration blocks this wave.
**Acceptance:** a checkpoint suite case asserts the manifest fields; a report template renders the
block; budget-warn fires in a fixture run at 80%.

### W4-4 The "when NOT to use this" boundary in README
Absent today (README Scope :189-198). **Required:** a README section stating plainly: first-pass
exploratory + periodic deep passes = yes; per-commit regression gating = no (deterministic suites
win); shared-staging = degraded mode (write-gated features off); intermittent/timing bugs =
structurally out of scope; and that a green run means "no divergence found at measured
same-fixture recall", never "verified correct". Link the accuracy README.
**Acceptance:** section exists; the qa-kit README cross-links it; no marketing claim elsewhere
contradicts it (grep sweep for "verified correct"/"guarantees").

### W4-5 Accuracy gates into CI
`run-ux-measure.sh` is headless/deterministic/no-browser — wire it into the adapters workflow now.
For the functional gate, wire `score.js --gate` over the committed reference `measured-*` findings
file as a **scorer-regression** gate (the live agent run stays manual). **Required + acceptance:**
both steps run in `.github/workflows`; a seeded detector regression (mutation test once, locally)
turns CI red; `docs/running-in-ci.md` updated.

---

## Wave 5 — compounding value (DEFERRED — grill Q8)

**Decision (grill Q8):** Wave 5 is **out of scope for this effort**. It is new feature work, not
remediation; the effort ends at W4. Record the deferral + the design sketch below in
`docs/doc-sync-todo.md` so the product move isn't lost.

### W5-1 Failed-criterion → Playwright spec skeleton export
Convert one-shot agent findings into permanent deterministic regression tests: a
`report-to-spec.sh`-style exporter that, for each `fail` criterion with recorded act steps +
selectors in its evidence, emits a `.spec.ts` skeleton (navigate → act → assert the oracle) into
`.qa/runs/<id>/specs/`, clearly marked as human-review-required scaffolding, never auto-committed to
the target repo. Acceptance (when eventually built): exporter covered by a test suite over a
fixture run; README gains the "feeds your deterministic suite" positioning with this as the
mechanism.

---

## Versioning & release (grill Q9)

- **Per-wave patch bump** of both plugins' versions (0.6.3 after W1, 0.6.4 after W2, …), **0.7.0
  when W4's credibility items land**.
- **Single-source the version:** `.claude-plugin/plugin.json` is the authority; every other
  version-carrying file (`scripts/skills.json`, qa-kit's manifest for its own version,
  marketplace.json) is either generated from it or checked against it by a test enrolled in the
  coverage gate — killing the 0.5.0-vs-0.6.2 drift class structurally. The existing
  `skills.json` 0.5.0 staleness (Appendix A) is fixed by this mechanism, not by hand.
- Marketplace metadata updated at each bump; no push/publish without an explicit ask.

## Audit-report placement (grill Q10b)

The full 93-finding audit report is committed to **`docs/audits/2026-09-06-deep-audit.md`** only
**after** W3's adapter-exclusion fix lands (Appendix A: `docs/superpowers/{plans,specs}` currently
bundle into every adapter; `docs/audits/` must be added to the exclusion list in the same change).
Until then it remains a delivered artifact referenced by this spec.

## Execution & orchestration (how subagents run this)

- **One item = one worktree-isolated subagent task** with only its section + Constraints as context;
  the integrator (main session) owns regeneration (`build-adapter.sh`/`build-qakit-adapter.sh`),
  byte-oracle validation, and the wave gate. Subagents are forbidden destructive git and never edit
  committed generated files.
- **Wave gate (blocking):** all `tests/*/run.sh` suites green (46 + any added), both byte-oracles
  green, `bash -n` + `node --check` + JSON sweep green, `check-suite-coverage.sh` green.
- **Branch/PR flow:** one branch per wave (`fix/audit2-w1-enforcement` …), tasks commit
  individually, PR per wave merged via `gh pr merge --merge --delete-branch`.
- **Ordering:** W1 → W2 → W3 strictly (gate fixes before install fixes before doc reconciliation,
  so re-tests run against corrected gates). W4 may start in parallel with W3 (disjoint files) except
  W4-5 (needs W3-2's detector fix before re-measuring). W5 is deferred out of this effort (Q8).
- **Fix-tension rule:** where a fix could be read as weakening a gate (W1-2, W3-4a), the spec's
  wording is binding — add the sanctioned path/flag, keep the rejection for the unsanctioned case,
  and add a negative test proving the gate still rejects it.

## Traceability

| Audit finding cluster | Spec item |
|---|---|
| qa-verify/required-kinds/mutation-flag bash-3.2 fail-open | W1-1 |
| HUMAN_PATH_TOOLS dialog/drop | W1-2 |
| provenance torn-line jq divergence | W1-3 |
| journal-merge lock trap | W1-4 |
| seedableEnvMarker default (×2 analysts) | W1-5 |
| qa-resume install/paths (×3 findings) | W2-1 |
| pi mcp.json overwrite | W2-2 |
| opencode agent binding + {{DISPATCH}} | W2-3 |
| qa-kit verify-plan laundering | W2-4 |
| qa-kit persona untokenized slug | W2-5 |
| fingerprint recipe gap | W3-1 |
| UX detector-id/grade mismatches (×2) | W3-2 |
| kinds vocab, recompute.md links, re-fill eval (×3) | W3-3 |
| persona-config empty-matrix + expectedSubject (×2) | W3-4 |
| dead-end detector, index-routes QA_CFG, fingerprintPaths (×3) | W3-5 |
| orphaned scripts/tests + tautological assert | W3-6 |
| all 60+ minors | W3-7 + Appendix A |
| accuracy single-fixture, harness validation, telemetry, boundary, CI gates | W4-1..5 |
| deterministic-suite handoff | W5-1 |

Every one of the 27 confirmed findings maps to exactly one W-item (qa-kit persona untokenized-slug
→ **W2-5**).

## Appendix A — minor findings (verify-then-fix, grouped)

**Engine scripts:** qa-ci.sh `ls -t` vs `.qa/runs/latest`; journal.sh ensure_ascii byte divergence;
qa-verify verification.json non-atomic write; report-to-junit `__phase-surface__` omission;
legalPhaseEdges validated-but-unconsumed; state-machine-schema toolClasses vs classify_tool drift;
README/INSTALL perl/grep-P claim; qa-reconcile shell-interpolated JSON (Fix-27 class); journal-emit
delimiter-in-id corruption; toolstream unlocked seq mint; memory-sync missing Fix-28 run-id
validation; qa-verify die()-in-subshell criterion loss; missing `--persona` bypasses identity
binding.
**Skills:** react-set-input Eval-5 wording (generating-qa-checklist:366); report Eval-1
'DB/migration' non-canonical layer; driver-preset table vs preflight.sh; browser_run_code_unsafe
recommended but block-hook-denied; cross-origin pre-flight origin comparison; carve-out count
off-by-one; bake/computed skills not naming record-evidence artifacts; CLAUDE.md preflight fallback
claim; browser_network_request replay suggestion (read tool / ungated write).
**Detection/config skills:** source-drift mode never produced; ingest traceability schema conflict;
find-spec-kit duplicate inventory + unimplemented specs-role; init-config truncate-on-invalid-flag;
rails-yml/gettext-po unreachable; budgetExceeded unreachable.
**Adapters:** harness READMEs "85%/100% gate" wording (also W4-2); CLAUDE.md generated-list omits
qa-resume; test-core-sources missing qa-resume (also W2-1); docs/superpowers bundled into adapters
against exclusion intent; validate-adapters JSON sweep scans qa-kit/dist + node_modules; render list
vs oracle list independently hardcoded; core qa-resume script path (also W2-1).
**qa-kit:** spec-snapshot non-atomic + divergent-override create; detect-seed error-blame + cwd
(cwd CONFIRMED → W3-7 priority); data-baseline is_int; run-qakit-ci shipped into user projects;
qa-status stale drift claim + phantom runs.json gate; constitution template's five nonexistent gate
commands; spine docs missing /qa-verify; qakit-adapters tautology (also W3-6); confidence-high
oracleSource rule prose-only; relative multiplicity fixtures unvalidated; vacuous dual-engine skip;
mktemp leaks; memory-sync/install/check-prereqs zero coverage.
**Docs/packaging:** INSTALL "nine skills"; skills.json 0.5.0 vs 0.6.2; running-in-ci honest-status
stale; extending-drivers Mem0 claim; CLAUDE.md opener (four counts wrong); README ADR range +
commands list; run-fsm spec DEFERRED marker stale; doc-sync-todo self-contradiction; hooks-loss on
manual/npx installs undocumented; accuracy README 18-vs-24 seeds; ADR-0023:77 vs ADR-0024
superseded note.
