# Running qa-e2e-pilot in CI (unattended) + JUnit-XML export

> Status: **later-phase** capability. The interactive `/qa-run` flow is the primary path; this doc covers driving a run non-interactively and surfacing results in a CI dashboard.

## JUnit-XML export

Every run writes its resumable state to `.qa/runs/<run-id>/checkpoint.json`. Convert it to JUnit XML — the format GitHub Actions, GitLab CI, Jenkins, CircleCI, etc. render natively:

```bash
bash scripts/report-to-junit.sh <run-id> qa-results.xml
# or pipe to stdout:
bash scripts/report-to-junit.sh <run-id> > qa-results.xml
# or point at any checkpoint file:
bash scripts/report-to-junit.sh --file path/to/checkpoint.json qa-results.xml
```

Verdict → JUnit mapping:

| qa-e2e-pilot verdict | JUnit | Notes |
|---|---|---|
| `pass` | `<testcase/>` | — |
| `fail` | `<failure>` | message carries the action + bug-ref |
| `error` | `<error>` | our tooling broke mid-criterion |
| `blocked` | `<skipped>` | environment stopped us (re-runnable) |
| `deferred` | `<skipped>` | we chose not to verify (reason carried) |
| `confidence: low` | annotated in the testcase name **+** a `<system-out>` carrying the reason | does **not** change pass/fail by itself |

**`confidence: low` is surfaced prominently, not buried.** Every low-confidence `pass` gets both the `(confidence: low)` name suffix *and* a `<system-out>` element with the reason — most commonly "the expected value could only come from backend code" (a checkpoint-recorded low confidence) or, when a `.qa/runs/<run-id>/verification.json` exists (see "qa-verify" below), the no-toolstream degrade reason from the verifier itself. Don't rely on eyeballing the name column in a wide CI dashboard — grep the XML for `confidence: low` if you need every occurrence.

**Exit code:** `report-to-junit.sh` exits `1` if the suite has any `fail` or `error` testcase, `0` otherwise — so a CI step can fail the build directly on its exit code. (`blocked`/`deferred` do **not** fail the build; they're skips.) A [`qa-verify`](#qa-verify-the-out-of-agent-authority) override also counts as a failure here (see below) — `report-to-junit.sh` reads `verification.json` itself, so this is true whether or not you're going through `qa-ci.sh`.

## `qa-verify`: the out-of-agent authority

`scripts/qa-verify.sh <run-id>` is the deterministic, out-of-agent re-check (Plan H2 / spec §5.3). It reads a completed run's `checkpoint.json`, and for every criterion the run's own agent recorded as `pass`, independently:

1. re-derives the required evidence kinds from `checklist.json` (never trusting the agent's own `kinds` field),
2. re-validates every evidence artifact's structure and values,
3. binds provenance — the evidence's read-back value/key must appear in some call the capture-hook actually recorded in `.qa/runs/<run-id>/toolstream.jsonl` — and
4. writes `.qa/runs/<run-id>/verification.json`: one `{criterionId, persona, inRunVerdict, verifierVerdict, confidence, reasons}` record per checked criterion.

**The verifier's verdict wins.** A `pass` that fails any of the checks above is overridden to `verifierVerdict: fail` (confidence `high`) — `report-to-junit.sh` then renders that testcase as a JUnit `<failure>` carrying the verifier's reason, *even though the run's own `checkpoint.json` still says `pass`*. Exit code: `0` iff every checked `pass` survived; non-zero iff at least one was overridden.

**Why this matters for CI:** a run's own agent self-reports its verdicts. `qa-verify` is the check that a run isn't merely *reported* clean but is *actually* clean, run outside the trust domain the agent controls. A run is "verified" in the honest sense only once `qa-verify` has passed — see the assurance-tier note below.

**`QA_VERIFY_STRICT`** (opt-in, unset by default): without it, a `human-action`/cross-tenant `pass` with no captured toolstream degrades to `confidence: low` rather than failing outright (capture-hook is opt-in, so most runs today have no toolstream at all — hard-failing all of them would break normal usage). That default has a known residual: an adversary can fabricate evidence *and* delete `toolstream.jsonl` to land on that same degrade path. Setting `QA_VERIFY_STRICT=1` closes that hole for the high-stakes subset (`human-action`, or a checklist row tagged `cross-tenant`/`cross-role-fk-chain`) by overriding those to `fail` instead of degrading — at the cost of also failing legitimate no-capture-hook runs in that mode. Turn it on in CI once your project has the capture-hook enabled; leave it off for a project that hasn't adopted the hooks yet. See `scripts/qa-verify.sh`'s header comment for the full residual writeup.

### Wiring `qa-verify` into `qa-ci.sh`

`qa-ci.sh` (below) runs `qa-verify` automatically as part of its turnkey chain, between locating the run and exporting JUnit, so the JUnit export already reflects any override. Relevant env:

| env | default | purpose |
|---|---|---|
| `QA_VERIFY_CMD` | `scripts/qa-verify.sh` | script to run for the out-of-agent re-check, invoked as `bash "$QA_VERIFY_CMD" "$RUN_ID"` |
| `QA_SKIP_VERIFY` | `0` | set `1` to skip `qa-verify` entirely — **always logged**, never silent; a skipped run is reported as unverified, not "verified clean" |
| `QA_VERIFY_STRICT` | unset | forwarded to `qa-verify.sh` via ordinary env inheritance (see above) |

A `qa-verify` override makes `qa-ci.sh`'s **final exit code non-zero** — independently of whatever `report-to-junit.sh`'s own exit code would have been — unless you explicitly opted out with `QA_SKIP_VERIFY=1`. Skipping it is always visible in the job log (`qa-verify SKIPPED (QA_SKIP_VERIFY=1) ... UNVERIFIED`); it is never a quiet no-op.

### The assurance tier — what "verified" actually means today

`report-to-junit.sh` writes a `<properties>` block on the `<testsuite>` element (and mirrors it to stderr) stating, honestly, whether the report you're looking at was independently verified:

- **No `verification.json` at all** (`qa-verify` never ran against this run) → `qa.verified="false"`, and the property text says so explicitly: these are the in-run agent's own self-reported verdicts, unverified.
- **`verification.json` present, 0 overrides** → `qa.verified="true"`, every recorded pass survived independent re-checking.
- **`verification.json` present, N overrides** → `qa.verified="true"` but the property names the override count; check each overridden testcase's `<failure>` for the specific reason.

On Claude Code today this sits at what the project calls **assurance Tier A**: the `PostToolUse`/`PreToolUse` capture and block hooks are **best-effort and tamper-evident**, not tamper-*proof* — an agent with `Bash` access could, in principle, edit the hook scripts or the toolstream on an unhardened install. `qa-verify` is the piece that's actually authoritative: it runs out-of-agent (by the operator or CI, not by the run's own agent process) and its verdict wins on any disagreement. See [`docs/harness-adapters.md`](./harness-adapters.md#the-claude-assurance-tier) for the full tier writeup, including why the other three harness adapters (Codex/Pi/opencode) don't have live hooks yet.

## Unattended runs

For CI, use the **managed** driver (zero-config, headless-capable) — attended CDP needs a real logged-in Chrome and is for local use. Capture a `storageState` once (an authenticated session) and commit it as a CI secret, then point `auth.storageState` at it.

Keep verification **sequential** (the default) in CI — most criteria are order-dependent against a shared backend. Drive a run by invoking the agent non-interactively with a checklist that already exists in the repo (no human-in-the-loop checklist review).

## Honest status: what actually runs in CI today

Be precise about this, because it's easy to overclaim: **this repository's own CI does not run a full QA pass against anything.** The only workflow that exists here, [`.github/workflows/adapters.yml`](../.github/workflows/adapters.yml), runs `scripts/validate-adapters.sh` — it validates that the four generated harness adapters (Claude/Codex/Pi/opencode) build correctly and stay byte-identical where required. It does not drive a browser, does not check out a target application, and does not invoke `qa-ci.sh` or `qa-verify.sh` at all.

`qa-ci.sh` (and, within it, `qa-verify.sh`) is a **turnkey chain you or your project's own CI invokes** against *your* target application — it is documented and tested (see `tests/qa-ci-verify/`), but nothing in this repo calls it automatically today. If you want `qa-verify` enforced on every PR, wire the "Example — GitHub Actions" step below into your own project's workflow; don't assume it already runs anywhere by default.

## Example — GitHub Actions

```yaml
name: e2e-qa
on: [pull_request]
jobs:
  qa:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Start the app under test
        run: |          # bring up the app at the baseUrl your .qa/config.json points to
          npm ci && npm run build && npm run start &
          npx wait-on http://localhost:3000
      - name: Restore auth storageState
        run: |
          mkdir -p .qa/auth
          echo "$QA_STORAGE_STATE" > .qa/auth/storageState.json
        env:
          QA_STORAGE_STATE: ${{ secrets.QA_STORAGE_STATE }}
      - name: Run qa-e2e-pilot (pre-flight -> agent -> qa-verify -> JUnit)
        run: bash scripts/qa-ci.sh "founders flow" .qa/checklist.md
        env:
          QA_VERIFY_STRICT: "1"   # once the capture-hook is enabled on this project; omit otherwise
      - name: Publish results
        if: always()
        uses: mikepenz/action-junit-report@v4
        with:
          report_paths: qa-results.xml
```

`qa-ci.sh` runs pre-flight, drives the agent, independently re-checks the result with `qa-verify`, and exports `qa-results.xml`, failing the job on any `fail`/`error` **or** on a `qa-verify` override. The publish step uses `if: always()` so results show up even when the QA step fails the build — and the assurance-tier `<properties>` in the XML (see above) tell you whether that pass/fail was independently verified or is only the agent's self-report.

## Caveats

- This is documented, not yet a turnkey product: the non-interactive `claude -p` invocation depends on your Claude Code CI setup, and `wait-on`/app-start are app-specific.
- No workflow in *this* repository runs the above — see "Honest status" above. Copy it into your own project's CI.
- `qa-verify`'s live-hook corroboration (the capture/block hooks) is Claude-only and best-effort/tamper-evident today (assurance Tier A); the other three harness adapters have no live hooks yet (Plan H3) — `qa-verify`'s deterministic checks still run everywhere, but without toolstream corroboration on non-Claude harnesses, more passes will land on the `confidence: low` degrade path (or, under `QA_VERIFY_STRICT`, the hard-fail path for high-stakes criteria).
- CLI/artisan verification stays out of browser scope; cover those backend bugs via the API-probing path.
- See also [extending-drivers.md](./extending-drivers.md) for swapping the browser MCP or the memory backend.
