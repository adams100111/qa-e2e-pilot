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
# RUN-LEVEL `UNVERIFIED` (plan 2026-09-23-error-honesty-invariants Task 10 / spec §5.7): the word
# `UNVERIFIED` already appeared in the assurance-tier property below, and a <properties> block is
# UNREACHABLE from this script's exit code (`sys.exit(1 if (failures or errors) else 0)` at the
# bottom) — so a run that could not be verified still exited 0 and read as a clean build. A run is
# now `UNVERIFIED` when ANY of:
#   - the run's ONE `capture_probed` journal event (checkpoint.sh's once-per-run canary) records a
#     `channel` that is not an actual capture channel — `none`, an unrecognized value, or the event
#     (or the journal) absent entirely. An absent canary is treated IDENTICALLY to `none`: it is
#     what a run aborted before any verdict looks like, and such a run must not read as clean.
#   - `QA_SKIP_VERIFY=1` is set in the environment (the same literal-`1` test qa-ci.sh branches on,
#     so a hand-rolled CI that calls this exporter directly cannot lose the status either).
#   - the sibling `fold-anomalies.json` reports `unparseable-line` or `seq-gap`. ONLY those two:
#     both mean the run's own RECORD is damaged, so its verdicts cannot be trusted. Every other
#     anomaly (`illegal-edge`, `cross-child-duplicate`, `duplicate-plan-frozen`,
#     `verdict-without-started`, `finding-url-oversize`, `finding-detail-missing`, …) is surfaced as
#     a COUNT ONLY on the `qa.foldAnomalies` property and NEVER marks a run unverified — a
#     data-quality problem in one finding is not damage to the record.
# `UNVERIFIED` SYNTHESIZES a `<testcase name="__run-verified__">` carrying a `<failure>` whose
# message is `UNVERIFIED — <reason>`; it is counted in tests/failures, so it reaches the exit code.
# That is the only route that works when qa-verify did not run at all — which is exactly the
# `UNVERIFIED` case — so routing it through qa-verify.sh's own failure path would be unreachable
# precisely when it is needed. `qa.verified` / `qa.assuranceTier` and the per-criterion
# `confidence: low` semantics are UNCHANGED; low confidence simply stops being the headline.
#
# COST TELEMETRY (audit-2 W4-3): when a sibling run-manifest.json carries a non-null `cost`
# object (checkpointing-qa-memory writes it from scripts/cost-summary.sh's output), ONE
# additional <property name="qa.cost" .../> line is emitted on the <testsuite>, e.g.
# `tool-calls=210 criteria=48 criteriaBudget=48/60 budgetWarn=true tokens=189234` (the `tokens`
# segment only appears when cost.tokens is non-null). Absence of run-manifest.json or a still-null
# `cost` field is a normal no-op — no property is fabricated.
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

# `or` (not a get-default): fold.sh writes run_id as JSON null when the journal
# never carried a run_started event — i.e. on an aborted run, which is exactly
# an UNVERIFIED run. quoteattr(None) raises, and a traceback writes no XML at
# all, so the UNVERIFIED reason would be lost in the one case it matters most.
run_id = data.get("run_id") or "qa-e2e-pilot"
updated_at = data.get("updated_at") or ""
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

# --- optional cost telemetry (audit-2 W4-3) ---------------------------------
# Sibling run-manifest.json's `cost` object, written by checkpointing-qa-memory
# from scripts/cost-summary.sh's output (see that script's own header for the
# full field contract). Absence (no run-manifest.json, or its `cost` field
# still null because cost-summary.sh was never run this Run) is a normal,
# back-compat no-op — no qa.cost property is emitted at all rather than a
# fabricated one.
def load_cost_summary(checkpoint_file):
    manifest_path = os.path.join(os.path.dirname(checkpoint_file) or ".", "run-manifest.json")
    if not os.path.isfile(manifest_path):
        return None
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    cost = manifest.get("cost")
    return cost if isinstance(cost, dict) else None

cost_summary = load_cost_summary(checkpoint_path)

# --- run-level UNVERIFIED (Task 10 / spec §5.7) ----------------------------
# An actual, independent capture channel. `none` is not an error at the
# canary (checkpoint.sh never dies on it) — it is the honest input to this
# status. Anything NOT in this tuple fails CLOSED, including an unrecognized
# channel value: a value this script does not understand is not evidence
# that a capture exists.
CAPTURE_CHANNELS = ("toolstream", "driver-log")

# The only two anomalies that mean the run's own RECORD is damaged. This
# tuple is a RULING, deliberately narrow — see the header. Widening it lets
# one bad finding invalidate an otherwise clean run.
RECORD_DAMAGE_ANOMALIES = ("unparseable-line", "seq-gap")


def load_capture_channel(checkpoint_file):
    """The `channel` of this run's ONE capture_probed journal event, or None
    when the event is absent entirely (no journal, an unreadable journal, or
    a journal that never carried the canary). None and "none" are treated
    identically by the caller."""
    journal_path = os.path.join(os.path.dirname(checkpoint_file) or ".", "journal.ndjson")
    if not os.path.isfile(journal_path):
        return None
    try:
        with open(journal_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    # A torn/malformed line is the fold's `unparseable-line`
                    # anomaly to report, never this scan's to abort on.
                    continue
                if isinstance(obj, dict) and obj.get("event") == "capture_probed":
                    channel = obj.get("channel")
                    return channel if isinstance(channel, str) else ""
    except OSError:
        return None
    return None


def load_fold_anomaly_counts(checkpoint_file):
    """{rule: count} from the sibling fold-anomalies.json. Absent or
    malformed -> {} : unreadable JSON must never INVENT damage (and must
    never crash the export), same posture as the other optional siblings."""
    path = os.path.join(os.path.dirname(checkpoint_file) or ".", "fold-anomalies.json")
    if not os.path.isfile(path):
        return {}
    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    items = raw.get("anomalies") if isinstance(raw, dict) else raw
    if not isinstance(items, list):
        return {}
    out = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        rule = item.get("rule")
        if isinstance(rule, str) and rule:
            out[rule] = out.get(rule, 0) + 1
    return out


capture_channel = load_capture_channel(checkpoint_path)
anomaly_counts = load_fold_anomaly_counts(checkpoint_path)
# The SAME literal-`1` test qa-ci.sh's own QA_SKIP_VERIFY branch uses — any
# other value (0, true, yes, "1 ") leaves verification running, so it must
# not mark the run unverified either.
skip_verify = os.environ.get("QA_SKIP_VERIFY") == "1"

unverified_reasons = []
if capture_channel not in CAPTURE_CHANNELS:
    unverified_reasons.append("no independent capture")
if skip_verify:
    unverified_reasons.append("verification skipped (QA_SKIP_VERIFY)")
damaging = [r for r in RECORD_DAMAGE_ANOMALIES if anomaly_counts.get(r)]
if damaging:
    unverified_reasons.append("run record damaged (%s)" % ", ".join(damaging))
# Fixed reason order (capture, skip, damage) so the headline and the failure
# message are deterministic for a run with more than one reason.
unverified = bool(unverified_reasons)
unverified_message = "UNVERIFIED — " + "; ".join(unverified_reasons)

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

# The synthetic __run-verified__ case counts as a test AND a failure — that
# is the whole mechanism: `failures` is what the exit code at the bottom
# reads, and a run-level row that is not counted is a <properties> block
# with extra steps.
tests = len(criteria) + len(advisory_items) + (1 if unverified else 0)
failures = counts["fail"] + verify_overrides + (1 if unverified else 0)
errors = counts["error"]
skipped = counts["blocked"] + counts["deferred"] + len(advisory_items)

lines = []
lines.append('<?xml version="1.0" encoding="UTF-8"?>')
lines.append(
    f'<testsuites tests="{tests}" failures="{failures}" errors="{errors}" skipped="{skipped}">'
)
lines.append(
    f'  <testsuite name={quoteattr(run_id)} tests="{tests}" failures="{failures}" '
    f'errors="{errors}" skipped="{skipped}" timestamp={quoteattr(updated_at)}>'
)
lines.append('    <properties>')
lines.append(
    f'      <property name="qa.assuranceTier" value={quoteattr(assurance_tier)}/>'
)
lines.append(
    f'      <property name="qa.verified" value={quoteattr("true" if verification_records is not None else "false")}/>'
)

# Phase-surface finding (Appendix A: __phase-surface__ omission). qa-verify's
# phase-surface pass writes AT MOST one synthetic run-level record with
# criterionId "__phase-surface__" (see qa-verify.sh's header) — it is
# deliberately NOT a criterion (no checkpoint.json row has that id), so the
# per-criterion loop below never looks it up and the finding was previously
# dropped on the floor with no rendering anywhere. It never overrides a
# verdict (record-only -> authority, confidence:low always) so it MUST NOT
# affect tests/failures/errors counts here either — surfaced as an
# informational property only, same posture as qa.assuranceTier.
phase_surface_rec = verification_by_key.get(("__phase-surface__", ""))
if phase_surface_rec:
    ps_reasons = phase_surface_rec.get("reasons") or []
    ps_text = "; ".join(str(r) for r in ps_reasons) or "phase-surface finding recorded with no reason text"
    lines.append(
        f'      <property name="qa.phaseSurfaceFindings" value={quoteattr(ps_text)}/>'
    )

# Run-level UNVERIFIED (Task 10): the reason is ALSO surfaced as a property,
# for the same reason qa.assuranceTier is — but the property is the echo, not
# the signal. The signal is the synthesized <testcase> below, which is the
# only thing the exit code can see.
if unverified:
    lines.append(
        f'      <property name="qa.unverifiedReason" value={quoteattr(unverified_message)}/>'
    )

# Fold anomalies: a COUNT ONLY, for every rule including the two that mark
# the run unverified (those are named in qa.unverifiedReason as well). This
# property NEVER affects tests/failures/errors — same posture as
# qa.phaseSurfaceFindings.
if anomaly_counts:
    anomaly_text = " ".join(
        f"{rule}={anomaly_counts[rule]}" for rule in sorted(anomaly_counts)
    )
    lines.append(
        f'      <property name="qa.foldAnomalies" value={quoteattr(anomaly_text)}/>'
    )

# Cost telemetry (audit-2 W4-3): ONE properties line, honest tool-calls-as-proxy
# label (spec W4-3's grill-Q7 decision) plus tokens only when the manifest's
# cost.tokens is non-null (the Claude harness fills it when usage is exposed;
# other harnesses leave it null rather than fabricate a count).
if cost_summary is not None:
    tc = cost_summary.get("toolCalls")
    crit = cost_summary.get("criteria")
    budget = cost_summary.get("criteriaBudget")
    done = cost_summary.get("criteriaDone")
    warn = cost_summary.get("budgetWarn")
    tokens = cost_summary.get("tokens")
    parts = [f"tool-calls={tc}", f"criteria={crit}"]
    if done is not None and budget is not None:
        parts.append(f"criteriaBudget={done}/{budget}")
    if warn is True:
        parts.append("budgetWarn=true")
    elif warn is False:
        parts.append("budgetWarn=false")
    if tokens is not None:
        parts.append(f"tokens={tokens}")
    cost_text = " ".join(parts)
    lines.append(
        f'      <property name="qa.cost" value={quoteattr(cost_text)}/>'
    )
lines.append('    </properties>')

# The synthesized run-level case (Task 10 / spec §5.7). Emitted FIRST, before
# any criterion, because it qualifies every verdict beneath it: this run could
# not be independently verified, so its passes are a self-report and not a
# verification result. It is a <failure> (never a <skipped>, never a property)
# so `sys.exit(1 if (failures or errors) else 0)` at the bottom sees it —
# `__phase-surface__` is the precedent for a run-level row that deliberately
# never fails; this one is the opposite by design.
if unverified:
    detail_lines = [
        "This run could not be independently verified, so its verdicts are the in-run "
        "agent's self-report, not a verification result.",
    ]
    if "no independent capture" in unverified_reasons:
        detail_lines.append(
            "no independent capture: the run's capture_probed canary recorded "
            + (("channel=" + capture_channel) if isinstance(capture_channel, str)
               else "no capture_probed event at all (an aborted run reads the same as an uncaptured one)")
            + " -- no toolstream and no resolvable driver-log session, so nothing in this run "
              "can be reconciled against an independent record."
        )
    if "verification skipped (QA_SKIP_VERIFY)" in unverified_reasons:
        detail_lines.append(
            "verification skipped (QA_SKIP_VERIFY): QA_SKIP_VERIFY=1 was set, so qa-verify never "
            "re-checked this run. Skipping verification is allowed; reporting the result as "
            "verified is not."
        )
    for reason in unverified_reasons:
        if reason.startswith("run record damaged"):
            detail_lines.append(
                reason + ": the fold reported that this run's own journal is damaged, so the "
                "event record its verdicts were derived from is incomplete. See "
                "fold-anomalies.json."
            )
    lines.append(
        f'    <testcase name="__run-verified__" classname={quoteattr(run_id)}>'
    )
    lines.append(
        f'      <failure message={quoteattr(unverified_message)}>'
        f'{escape(" ".join(detail_lines))}</failure>'
    )
    lines.append('    </testcase>')

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

# The report's HEADLINE (Task 10 / spec §5.7): `UNVERIFIED — <reason>` with
# the tally printed BENEATH it, on stderr in both output modes (same channel
# as the assurance tier, so the XML stream stays pure XML).
tally = (f"{tests} tests, {failures} failures, {errors} errors, "
         f"{skipped} skipped ({len(advisory_items)} advisory)")
if unverified:
    sys.stderr.write(unverified_message + "\n")

if out_path:
    with open(out_path, "w") as f:
        f.write(xml)
    sys.stderr.write(f"wrote {out_path}: {tally}\n")
else:
    sys.stdout.write(xml)
    if unverified:
        # The XML-to-stdout mode has never printed a tally; print one only
        # under UNVERIFIED so the headline is not left without its numbers.
        sys.stderr.write(f"tally: {tally}\n")

# Assurance tier — always to stderr (even when the XML itself goes to stdout)
# so it's never silently missed. See docs/harness-adapters.md.
sys.stderr.write(f"assurance tier: {assurance_tier}\n")

# Non-zero exit if the suite has real failures/errors so CI fails the build.
# Advisory items never affect this — they carry no verdict.
sys.exit(1 if (failures or errors) else 0)
PYEOF