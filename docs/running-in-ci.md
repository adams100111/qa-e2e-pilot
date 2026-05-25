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
      - name: Run qa-e2e-pilot
        run: |          # drive the agent headless with a committed checklist
          claude -p "/qa-run \"$FEATURE\" .qa/checklist.md"
        env:
          FEATURE: "founders flow"
      - name: Export JUnit XML
        if: always()
        run: bash scripts/report-to-junit.sh "$(ls -t .qa/runs | head -1)" qa-results.xml
      - name: Publish results
        if: always()
        uses: mikepenz/action-junit-report@v4
        with:
          report_paths: qa-results.xml
```

The last two steps run `if: always()` so results publish even when the QA step fails the build. `report-to-junit.sh`'s exit code already failed the job on a real `fail`/`error`.

## Caveats

- This is documented, not yet a turnkey product: the non-interactive `claude -p` invocation depends on your Claude Code CI setup, and `wait-on`/app-start are app-specific.
- CLI/artisan verification stays out of browser scope; cover those backend bugs via the API-probing path.
- See also [extending-drivers.md](./extending-drivers.md) for swapping the browser MCP or the memory backend.
