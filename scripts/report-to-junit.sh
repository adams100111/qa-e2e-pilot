#!/usr/bin/env bash
# report-to-junit.sh — convert a qa-e2e-pilot run's checkpoint into JUnit XML for CI.
#
# Maps each criterion's verdict onto JUnit semantics so CI dashboards (GitHub Actions,
# GitLab, Jenkins, etc.) render the run as a test suite:
#   pass      -> testcase (no child)
#   fail      -> <failure>
#   error     -> <error>
#   blocked   -> <skipped> (environment stopped us — re-runnable)
#   deferred  -> <skipped> (we chose not to verify — reason carried)
# confidence: low is noted in the message but does not change pass/fail.
#
# USAGE:
#   report-to-junit.sh <run-id> [output.xml]      # reads .qa/runs/<run-id>/checkpoint.json
#   report-to-junit.sh --file <checkpoint.json> [output.xml]
#   (no output path -> writes XML to stdout)
#
# Exit: 0 if the suite has no fail/error testcases, 1 if it does (so CI fails the build).
# DEPENDENCIES: bash + python3 (used for robust JSON parse and XML escaping).
set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "report-to-junit.sh requires python3" >&2; exit 2; }

CHECKPOINT=""
OUT=""

if [[ "${1:-}" == "--file" ]]; then
  CHECKPOINT="${2:-}"; OUT="${3:-}"
  [[ -n "$CHECKPOINT" ]] || { echo "--file requires a path" >&2; exit 2; }
else
  RUN_ID="${1:-}"
  [[ -n "$RUN_ID" ]] || { echo "Usage: report-to-junit.sh <run-id> [output.xml]" >&2; exit 2; }
  CHECKPOINT=".qa/runs/${RUN_ID}/checkpoint.json"
  OUT="${2:-}"
fi

[[ -f "$CHECKPOINT" ]] || { echo "checkpoint not found: $CHECKPOINT" >&2; exit 2; }

python3 - "$CHECKPOINT" "$OUT" <<'PYEOF'
import json, sys
from xml.sax.saxutils import escape, quoteattr

checkpoint_path, out_path = sys.argv[1], sys.argv[2]
with open(checkpoint_path) as f:
    data = json.load(f)

run_id = data.get("run_id", "qa-e2e-pilot")
criteria = data.get("criteria", [])

counts = {"pass": 0, "fail": 0, "error": 0, "blocked": 0, "deferred": 0}
for c in criteria:
    v = c.get("verdict", "error")
    counts[v] = counts.get(v, 0) + 1

tests = len(criteria)
failures = counts["fail"]
errors = counts["error"]
skipped = counts["blocked"] + counts["deferred"]

lines = []
lines.append('<?xml version="1.0" encoding="UTF-8"?>')
lines.append(
    f'<testsuites tests="{tests}" failures="{failures}" errors="{errors}" skipped="{skipped}">'
)
lines.append(
    f'  <testsuite name={quoteattr(run_id)} tests="{tests}" failures="{failures}" '
    f'errors="{errors}" skipped="{skipped}" timestamp={quoteattr(str(data.get("updated_at","")))}>'
)

for c in criteria:
    cid = c.get("criterion_id", "?")
    verdict = c.get("verdict", "error")
    confidence = c.get("confidence", "high")
    last_action = c.get("last_action", "") or ""
    bug_ref = c.get("bug_ref") or ""
    name = cid
    if confidence == "low":
        name = f"{cid} (confidence: low)"
    detail = last_action
    if bug_ref:
        detail = (detail + f" [bug: {bug_ref}]").strip()
    tc = f'    <testcase name={quoteattr(name)} classname={quoteattr(run_id)}>'
    if verdict == "pass":
        lines.append(f'    <testcase name={quoteattr(name)} classname={quoteattr(run_id)}/>')
    elif verdict == "fail":
        lines.append(tc)
        lines.append(f'      <failure message={quoteattr("fail: " + detail)}>{escape(detail)}</failure>')
        lines.append('    </testcase>')
    elif verdict == "error":
        lines.append(tc)
        lines.append(f'      <error message={quoteattr("error: " + detail)}>{escape(detail)}</error>')
        lines.append('    </testcase>')
    else:  # blocked | deferred
        lines.append(tc)
        lines.append(f'      <skipped message={quoteattr(verdict + ": " + detail)}/>')
        lines.append('    </testcase>')

lines.append('  </testsuite>')
lines.append('</testsuites>')
xml = "\n".join(lines) + "\n"

if out_path:
    with open(out_path, "w") as f:
        f.write(xml)
    sys.stderr.write(f"wrote {out_path}: {tests} tests, {failures} failures, {errors} errors, {skipped} skipped\n")
else:
    sys.stdout.write(xml)

# Non-zero exit if the suite has real failures/errors so CI fails the build.
sys.exit(1 if (failures or errors) else 0)
PYEOF