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
# confidence: low is noted in the message but does not change pass/fail — UNLESS qa-verify
# (scripts/qa-verify.sh, Plan H2 Task 4) has independently overridden the criterion (see below).
#
# VERIFICATION-AWARE (Plan H2 Task 5): when a sibling `.qa/runs/<run-id>/verification.json` exists
# (written by scripts/qa-verify.sh — the out-of-agent, deterministic authority), each criterion is
# looked up in it by (criterionId, persona):
#   - verifierVerdict != "pass" for a recorded `pass`  -> the JUnit testcase renders as a
#     <failure> (regardless of the in-run verdict), message + body carry the verifier's reasons.
#     This is an OVERRIDE: qa-verify's verdict wins (see qa-verify.sh's header "RECONCILIATION").
#   - verifierVerdict == "pass" but confidence == "low" -> the testcase stays a pass, but its
#     confidence is surfaced prominently: `(confidence: low)` in the name (existing behavior) PLUS
#     a <system-out> carrying the verifier's reason (e.g. the no-toolstream degrade — capture-hook
#     is opt-in, so a run with no toolstream.jsonl still verifies structurally but can't have its
#     provenance corroborated). This surfacing is NOT limited to verifier-sourced confidence: ANY
#     confidence:low pass (even with no verification.json at all) now gets the same <system-out>
#     treatment, not just the name suffix — flagged in the Task 4 review as something the report
#     must not bury.
#   - no verification.json at all -> BACK-COMPAT: today's behavior, unchanged. The testsuite gets
#     an additional <properties><property name="qa.assuranceTier" .../></properties> block (see
#     below) noting qa-verify was not run for this report, but no verdict/count changes.
#
# ASSURANCE TIER (spec §6 / docs/harness-adapters.md): a <properties> block on the <testsuite>
# element (and a matching stderr line) states, honestly, whether this report reflects an
# independently-verified run or only the in-run agent's self-report. See
# docs/harness-adapters.md's "Claude assurance tier" note and docs/running-in-ci.md's
# QA_VERIFY_STRICT section for what "authoritative" does and does not guarantee.
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
# Exit: 0 if the suite has no fail/error testcases (a qa-verify OVERRIDE counts as a failure
# here), 1 if it does (so CI fails the build).
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

# --- optional verification.json (Plan H2 Task 5) ---------------------------
# Sibling file next to the checkpoint, written by scripts/qa-verify.sh — the
# out-of-agent, deterministic authority. Its ABSENCE is a normal, back-compat
# no-op (today's behavior, unchanged); its PRESENCE means every recorded pass
# was independently re-checked, and a verifierVerdict != "pass" wins over the
# in-run verdict (see the file-header comment above).
def load_verification_records(checkpoint_file):
    ver_path = os.path.join(os.path.dirname(checkpoint_file) or ".", "verification.json")
    if not os.path.isfile(ver_path):
        return None  # None = "qa-verify did not run for this report" (distinct from [] = ran, nothing to check)
    try:
        with open(ver_path) as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(raw, list):
        return None
    return [r for r in raw if isinstance(r, dict)]

verification_records = load_verification_records(checkpoint_path)
verification_by_key = {}
if verification_records is not None:
    for rec in verification_records:
        key = (rec.get("criterionId", ""), rec.get("persona") or "")
        verification_by_key[key] = rec

# How many recorded passes did qa-verify override? (used for both the header
# failure count and the assurance-tier note below.)
verify_overrides = 0
if verification_records is not None:
    for c in criteria:
        if c.get("verdict") == "pass":
            key = (c.get("criterion_id", ""), c.get("persona") or "")
            rec = verification_by_key.get(key)
            if rec and rec.get("verifierVerdict") != "pass":
                verify_overrides += 1

# Honest, per-report assurance-tier note (spec §6 / docs/harness-adapters.md).
# qa-verify is the universal, deterministic floor — the live Claude hooks
# (PostToolUse capture + PreToolUse block) are best-effort/tamper-evident,
# never the sole authority. See docs/running-in-ci.md for QA_VERIFY_STRICT.
_TIER_NOTE = ("Claude Tier A: PostToolUse/PreToolUse capture+block hooks are best-effort and "
              "tamper-evident (an agent with Bash could edit the hook scripts or the toolstream "
              "on an unhardened install); qa-verify is the deterministic, out-of-agent floor and "
              "authoritative verdict. Other 3 harness adapters (Codex/Pi/opencode) have no live "
              "hooks yet (Plan H3).")
if verification_records is None:
    assurance_tier = ("qa-verify: NOT RUN for this report -- these verdicts reflect the in-run "
                       f"agent's own self-report only, UNVERIFIED. Run `bash scripts/qa-verify.sh {run_id}` "
                       "(or let scripts/qa-ci.sh's turnkey chain run it) before trusting a pass. "
                       + _TIER_NOTE)
elif verify_overrides:
    assurance_tier = (f"qa-verify: ran, authoritative -- {verify_overrides} recorded pass(es) "
                       "OVERRIDDEN below (see each testcase's <failure> for the verifier's "
                       "reason). " + _TIER_NOTE)
else:
    assurance_tier = ("qa-verify: ran, authoritative -- every recorded pass independently "
                       "verified. " + _TIER_NOTE)

tests = len(criteria) + len(advisory_items)
failures = counts["fail"] + verify_overrides
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
lines.append('    <properties>')
lines.append(
    f'      <property name="qa.assuranceTier" value={quoteattr(assurance_tier)}/>'
)
lines.append(
    f'      <property name="qa.verified" value={quoteattr("true" if verification_records is not None else "false")}/>'
)
lines.append('    </properties>')

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

    # qa-verify override lookup (Plan H2 Task 5). Only ever meaningful for an
    # in-run `pass` — qa-verify only checks recorded passes (see qa-verify.sh).
    # verifierVerdict, when present, is AUTHORITATIVE: it wins over the in-run
    # verdict/confidence below.
    verify_rec = verification_by_key.get((cid, persona)) if verdict == "pass" else None
    verify_override = bool(verify_rec and verify_rec.get("verifierVerdict") != "pass")
    if verify_rec:
        confidence = verify_rec.get("confidence", confidence)

    # name is ALWAYS the raw criterion_id — never decorated with "@persona".
    # persona is carried solely by the `persona` attribute below, so a
    # criterion_id containing a literal '@' can't collide with a display
    # encoding and conflate two distinct rows.
    name = cid
    if confidence == "low":
        name = f"{name} (confidence: low)"
    if verify_override:
        name = f"{name} (qa-verify OVERRIDE)"

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
    if verify_override:
        # qa-verify's verdict wins (RECONCILIATION, qa-verify.sh header): a
        # recorded `pass` whose evidence/provenance didn't survive independent
        # re-checking renders as a JUnit failure here, regardless of the
        # in-run verdict — the whole point of an out-of-agent authority.
        verifier_verdict = verify_rec.get("verifierVerdict", "fail")
        reasons = verify_rec.get("reasons") or []
        reason_text = "; ".join(str(r) for r in reasons) or \
            "qa-verify overrode this pass with no reason recorded"
        lines.append(tc)
        lines.append(
            f'      <failure message={quoteattr(f"qa-verify OVERRIDE: pass -> {verifier_verdict}")}>'
            f'{escape(reason_text)}</failure>'
        )
        lines.append('    </testcase>')
    elif verdict == "pass":
        if confidence == "low":
            # confidence:low surfaced prominently, not just in the name suffix
            # (Task 4 review requirement) — a no-toolstream degrade lands
            # here even when qa-verify did NOT override the pass.
            reasons = (verify_rec.get("reasons") or []) if verify_rec else []
            reason_text = "; ".join(str(r) for r in reasons)
            msg = "confidence: low" + (f" -- {reason_text}" if reason_text else
                  " -- expected value could only come from backend code, or provenance could not be independently corroborated")
            lines.append(tc)
            lines.append(f'      <system-out>{escape(msg)}</system-out>')
            lines.append('    </testcase>')
        else:
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

# Assurance tier — always to stderr (even when the XML itself goes to stdout)
# so it's never silently missed. See docs/harness-adapters.md.
sys.stderr.write(f"assurance tier: {assurance_tier}\n")

# Non-zero exit if the suite has real failures/errors so CI fails the build.
# Advisory items never affect this — they carry no verdict.
sys.exit(1 if (failures or errors) else 0)
PYEOF