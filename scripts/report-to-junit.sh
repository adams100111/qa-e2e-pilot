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
# Each <testcase> ADDITIONALLY carries (attributes only — no reordering of the
# existing elements, so older consumers that just read name/classname/verdict
# child keep working unchanged):
#   persona="<id>"   only when the criterion was checkpointed with --persona (ADR-0012).
#                     The testcase `name` is ALWAYS the raw criterion_id (never decorated
#                     with "@<persona>") — a criterion_id containing a literal '@' would
#                     otherwise collide with that display encoding and conflate two
#                     distinct rows. persona lives ONLY in this separate attribute, mirroring
#                     checkpoint.sh --list's own persona column, so two personas of the same
#                     criterion are still distinguishable without any name-string encoding.
#   kinds="a,b"      only when non-empty — the evidence kinds (bake/computed/probe)
#                     this pass's gate required (ADR-0010).
#   evidence="..."   complete | ungated | n/a — same computation checkpoint.sh's
#                     --resume/--list already do (pass+kinds=complete, pass+no
#                     kinds=ungated un-gated back-compat pass, non-pass=n/a).
#
# Advisory-stream items (ADR-0007 subjective aesthetics — never a verdict, never
# gated) are read from an OPTIONAL sibling `advisory.json` next to the checkpoint,
# if present, and each rendered as its own <testcase classname="<run_id>.advisory">
# with a <skipped> child (never <failure>/<error>) and the message in
# <system-out>. No producer writes this file yet in this repo; the shape is
# `{"items":[{"criterion_id"|"surface":str, "message":str, "selector":str?}]}`
# or a bare list of such items. Absence is a normal no-op — this is additive.
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
import json, os, sys
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

# --- optional advisory stream (ADR-0007) -----------------------------------
# Sibling file next to the checkpoint; no producer writes it yet in this repo
# — reading it is purely additive and a no-op when absent.
def load_advisory_items(checkpoint_file):
    adv_path = os.path.join(os.path.dirname(checkpoint_file) or ".", "advisory.json")
    if not os.path.isfile(adv_path):
        return []
    try:
        with open(adv_path) as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    items = raw.get("items", []) if isinstance(raw, dict) else raw
    return [i for i in items if isinstance(i, dict)]

advisory_items = load_advisory_items(checkpoint_path)

tests = len(criteria) + len(advisory_items)
failures = counts["fail"]
errors = counts["error"]
skipped = counts["blocked"] + counts["deferred"] + len(advisory_items)

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
    persona = c.get("persona") or ""
    kinds = c.get("kinds") or []
    kinds_str = ",".join(kinds)
    if verdict == "pass":
        evidence_status = "complete" if kinds else "ungated"
    else:
        evidence_status = "n/a"

    # name is ALWAYS the raw criterion_id — never decorated with "@persona".
    # persona is carried solely by the `persona` attribute below, so a
    # criterion_id containing a literal '@' can't collide with a display
    # encoding and conflate two distinct rows.
    name = cid
    if confidence == "low":
        name = f"{name} (confidence: low)"

    detail = last_action
    if bug_ref:
        detail = (detail + f" [bug: {bug_ref}]").strip()

    attrs = f'name={quoteattr(name)} classname={quoteattr(run_id)}'
    if persona:
        attrs += f' persona={quoteattr(persona)}'
    if kinds_str:
        attrs += f' kinds={quoteattr(kinds_str)}'
    attrs += f' evidence={quoteattr(evidence_status)}'

    tc = f'    <testcase {attrs}>'
    if verdict == "pass":
        lines.append(f'    <testcase {attrs}/>')
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

# Advisory items: always <skipped> + <system-out>, NEVER <failure>/<error> —
# these are subjective aesthetic observations (ADR-0007), not verdicts.
for i, item in enumerate(advisory_items):
    ref = item.get("criterion_id") or item.get("surface") or f"advisory-{i+1}"
    message = str(item.get("message", "")).strip()
    selector = item.get("selector") or ""
    name = f"advisory: {ref}"
    classname = f"{run_id}.advisory"
    lines.append(f'    <testcase name={quoteattr(name)} classname={quoteattr(classname)}>')
    lines.append(f'      <skipped message={quoteattr("advisory (aesthetics) — not gated, not a verdict")}/>')
    out_text = message + (f" (selector: {selector})" if selector else "")
    lines.append(f'      <system-out>{escape(out_text)}</system-out>')
    lines.append('    </testcase>')

lines.append('  </testsuite>')
lines.append('</testsuites>')
xml = "\n".join(lines) + "\n"

if out_path:
    with open(out_path, "w") as f:
        f.write(xml)
    sys.stderr.write(
        f"wrote {out_path}: {tests} tests, {failures} failures, {errors} errors, "
        f"{skipped} skipped ({len(advisory_items)} advisory)\n"
    )
else:
    sys.stdout.write(xml)

# Non-zero exit if the suite has real failures/errors so CI fails the build.
# Advisory items never affect this — they carry no verdict.
sys.exit(1 if (failures or errors) else 0)
PYEOF