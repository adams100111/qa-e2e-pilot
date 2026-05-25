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
| `confidence: low` | annotated in the testcase name | does **not** change pass/fail |

**Exit code:** `report-to-junit.sh` exits `1` if the suite has any `fail` or `error` testcase, `0` otherwise — so a CI step can fail the build directly on its exit code. (`blocked`/`deferred` do **not** fail the build; they're skips.)

## Unattended runs

For CI, use the **managed** driver (zero-config, headless-capable) — attended CDP needs a real logged-in Chrome and is for local use. Capture a `storageState` once (an authenticated session) and commit it as a CI secret, then point `auth.storageState` at it.

Keep verification **sequential** (the default) in CI — most criteria are order-dependent against a shared backend. Drive a run by invoking the agent non-interactively with a checklist that already exists in the repo (no human-in-the-loop checklist review).

## Turnkey wrapper: `scripts/qa-ci.sh`

`qa-ci.sh` chains the whole thing — pre-flight → drive the agent headless → export JUnit XML → exit with the right code:

```bash
bash scripts/qa-ci.sh "founders flow" .qa/checklist.md
```

It's overridable via env so it fits any Claude Code CI setup (and is testable with a mock):

| env | default | purpose |
|---|---|---|
| `QA_AGENT_CMD` | `claude -p "/qa-run \"$QA_TARGET\" $QA_CHECKLIST"` | how to drive the agent headless (`QA_TARGET`/`QA_CHECKLIST` are exported) |
| `QA_PREFLIGHT_CMD` | the bundled `preflight.sh` | how to run pre-flight |
| `QA_SKIP_PREFLIGHT` | `0` | set `1` if CI already guarantees app/auth liveness |
| `QA_JUNIT_OUT` | `qa-results.xml` | JUnit output path |

It exits non-zero if pre-flight fails, the agent command fails, no run is produced, or the run has any `fail`/`error` criterion — so the job fails the build automatically.

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
      - name: Run qa-e2e-pilot (pre-flight -> agent -> JUnit)
        run: bash scripts/qa-ci.sh "founders flow" .qa/checklist.md
      - name: Publish results
        if: always()
        uses: mikepenz/action-junit-report@v4
        with:
          report_paths: qa-results.xml
```

`qa-ci.sh` runs pre-flight, drives the agent, and exports `qa-results.xml`, failing the job on any `fail`/`error`. The publish step uses `if: always()` so results show up even when the QA step fails the build.

## Caveats

- This is documented, not yet a turnkey product: the non-interactive `claude -p` invocation depends on your Claude Code CI setup, and `wait-on`/app-start are app-specific.
- CLI/artisan verification stays out of browser scope; cover those backend bugs via the API-probing path.
- See also [extending-drivers.md](./extending-drivers.md) for swapping the browser MCP or the memory backend.
