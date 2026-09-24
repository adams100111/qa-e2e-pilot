#!/usr/bin/env bash
# qa-verify.sh — the OUT-OF-AGENT, DETERMINISTIC authority (Plan H2 Task 4,
# spec §5.3). Re-checks every `pass` recorded in a completed run's
# checkpoint.json against a trust domain the run's agent never wrote to (the
# capture-hook's toolstream) and OVERRIDES a forged pass. No LLM in this
# script's core — every check below is jq/python3/node (the SAME node
# check-action-trace.js the live gate uses, reused verbatim).
#
# USAGE:
#   qa-verify.sh <run-id>
#
# For each record in .qa/runs/<run-id>/checkpoint.json's `criteria[]` whose
# `verdict == "pass"` (identity is the (criterion_id, persona) pair — a
# separate record per persona, exactly as checkpoint.sh writes them):
#
#   1. RE-DERIVE REQUIRED KINDS — reads the matching .qa/runs/<run-id>/
#      checklist.json row (by `id`) and re-derives its required evidence
#      kinds via required-kinds.sh (reused verbatim, from the row's shape —
#      NEVER the agent's own requiredKinds field). If the recorded `kinds`
#      is not a superset of the re-derivation, that's a dropped-kind
#      forgery signal -> OVERRIDE.
#
#   2. RE-VALIDATE EACH EVIDENCE ARTIFACT — for every kind in the recorded
#      `kinds`, the canonical artifact under evidence/<crit>/ (or, when the
#      record carries a `persona`, evidence/<persona>/<crit>/ — mirrors
#      checkpoint.sh's gate_pass exactly, never trusting the agent-supplied
#      evidence_refs path) must exist, be non-empty, parse as JSON, carry
#      its required keys, and pass its value-level check: computed.match
#      must be true, bake.readBack must be non-null unless multiplicity is
#      "0", probe.ok must be true, and human-action is delegated to
#      check-action-trace.js (reused verbatim, same as checkpoint.sh). Any
#      miss -> OVERRIDE.
#
#   3. BIND PROVENANCE — for bake/probe/human-action evidence (never
#      `computed` — a computed value is independently recomputed against
#      the spec oracle, never checked against a backend response; see
#      CLAUDE.md's "oracle is the spec/domain rule, never the backend's own
#      formula" invariant), calls provenance.sh check (reused verbatim)
#      against the SAME artifact file. `unbound` -> OVERRIDE (the AC-1
#      forgery signal: a pass whose evidence corresponds to no captured
#      toolstream call). `no-toolstream` -> NOT an override — a run with no
#      capture-hook toolstream (capture is opt-in) still verifies its
#      non-provenance checks; only confidence is downgraded to `low`, once
#      per criterion. `bound` -> no change.
#
#   3.5. PERSONA-IDENTITY BINDING (Plan H3 Task 1, gap #6; H3 fast-follow
#      fix for the false-override on opaque subjects) — for a
#      PERSONA-SCOPED HIGH-STAKES pass only (persona non-empty and not the
#      "__shared__" sentinel, AND either the recorded `kinds` contains
#      `human-action` or the checklist.json row is tagged `cross-tenant` /
#      `cross-role-fk-chain` — the SAME is_high_stakes() definition the
#      QA_VERIFY_STRICT residual below already uses): read
#      evidence/<persona>/identity.json (recorded via `record-evidence.sh
#      identity`, never trusted from any agent-authored checkpoint field).
#        - Absent, OR present with method:none -> confidence: low, reason
#          recorded. NEVER an override.
#        - Present, method != none, AND `.qa/config.json`'s
#          `personas[].expectedSubject` IS configured for this persona ->
#          compare capturedSubject to expectedSubject (operator-provided
#          ground truth). Match -> verified. Mismatch -> OVERRIDE to fail
#          ("acting identity ... != expected identity ..." — the operator
#          told us who this should be, so a mismatch is a real defect).
#          THIS IS THE ONLY OVERRIDE PATH.
#        - Present, method != none, NO expectedSubject configured -> a bare
#          persona-id-vs-captured-subject comparison is inherently
#          unreliable (an id like `admin` vs a subject like `42` / a short
#          hash / a JWT `sub` claim is indistinguishable from a legitimate
#          numeric account id vs a genuine impersonation without ground
#          truth). capturedSubject contains the persona id as a
#          case-insensitive substring -> verified (best-effort). Otherwise
#          (ANY non-match — a bare numeric id, a short hash, a UUID, or a
#          genuinely different username, ALL treated alike) -> confidence:
#          low, reason "persona identity unverified (no expectedSubject
#          configured; captured subject '<s>' could not be confidently
#          matched to persona '<id>')". NEVER an override — spec §5.5:
#          identity is best-effort and DEGRADES when unverifiable; a hard
#          verdict override requires operator-supplied ground truth.
#          Operators who want a genuine impersonation to HARD-FAIL rather
#          than degrade must configure `personas[].expectedSubject` for
#          that persona in `.qa/config.json`.
#      __shared__/empty-persona/non-high-stakes (read-only) passes are
#      exempt — never checked.
#
#   4. WRITE .qa/runs/<run-id>/verification.json — a JSON array, one record
#      per checked criterion:
#        {criterionId, persona, inRunVerdict, verifierVerdict, confidence,
#         reasons: [...]}
#      Every override carries at least one human-readable reason. Exit
#      non-zero iff ANY checked criterion's verifierVerdict != "pass";
#      exit 0 iff every in-run `pass` was independently verified. A run
#      with no `pass` criteria at all trivially verifies (verification.json
#      == [], exit 0).
#
# RECONCILIATION: the verifier's verdict WINS. An overridden criterion's
# verifierVerdict is always "fail" (the deterministic checks above are
# proof of a structural/provenance defect, not ambiguity) with
# confidence "high" (we are confident there IS a problem). A criterion that
# survives every check keeps its recorded confidence, downgraded to "low"
# only by the no-toolstream degrade (never upgraded).
#
# THE RE-DRIVE STUB (documented, NOT unit-tested — spec §5.3's second half):
# when the QA_VERIFY_REDRIVE_CMD environment variable is set, qa-verify
# invokes it, once, per HIGH-STAKES criterion (kinds contains "human-action"
# or "probe" — a mutating act or a cross-tenant/backend probe), as:
#   "$QA_VERIFY_REDRIVE_CMD" <run-id> <criterion-id> <persona>
# The intent (spec §5.3) is a FRESH operator/CI-driven agent session
# independently re-driving (read-only criteria) or re-baking (mutating
# criteria) the criterion from scratch, out-of-band from the original run's
# agent — the genuinely independent half of verification an in-process
# deterministic script cannot itself perform (it would need an LLM to
# re-interpret the criterion and drive the browser again). Its exit code
# and output are logged to stderr as a NOTE but are DELIBERATELY NOT
# incorporated into verifierVerdict/confidence here — wiring a real,
# LLM-driven re-drive result into the reconciliation logic is Plan H3 work.
# Default-absent QA_VERIFY_REDRIVE_CMD -> this call is skipped entirely;
# qa-verify's core stays 100% deterministic (jq/python3/node only).
#
# DEPENDENCIES: bash, coreutils, EITHER jq OR python3 (jq preferred; python3
# fallback; QA_ENGINE overrides the auto-detect, same contract as
# toolstream.sh/provenance.sh), and `node` ONLY for check-action-trace.js
# (the same node dependency checkpoint.sh's gate_value_check already has —
# no NEW hard node dependency is introduced here). No `grep -P`/`perl`.
#
# REUSE, NOT REBUILD: required-kinds.sh, provenance.sh, and
# check-action-trace.js are invoked exactly as checkpoint.sh/provenance.sh
# already invoke them — this script never reimplements their logic, only
# the structural/value gate checks themselves are duplicated inline
# (mirroring checkpoint.sh's kind_artifact/kind_required_keys/
# json_is_valid/json_has_key/json_value_is_true/json_bake_value_ok), matching
# this codebase's documented convention of small self-contained helpers
# repeated per script rather than shared via `source` (see checkpoint.sh's
# write_latest comment for the precedent/rationale — checkpoint.sh's own
# `main "$@"` tail makes it unsafe to `source`).
#
# NOTE: all paths are relative to the current working directory (project
# root), matching checkpoint.sh/provenance.sh's convention.
#
# QA_VERIFY_STRICT (opt-in, default UNSET): TOOLSTREAM-SUPPRESSION RESIDUAL.
# Today, a human-action `pass` with NO toolstream.jsonl for the run degrades
# to confidence:low + exit 0 (see the no-toolstream branch above) rather
# than failing outright, because capture-hook is opt-in-off on most runs and
# hard-failing every no-toolstream run would break real usage. But that
# means an adversary who fabricates action-trace.json can ALSO
# `rm .qa/runs/<run>/toolstream.jsonl` to land on the exact same
# pass/confidence:low/exit-0 outcome as a genuinely-captured run — the
# degrade path is exit-code-indistinguishable from real verification.
# Setting QA_VERIFY_STRICT to any non-empty value (e.g. `=1`/`=true`) closes
# that hole for the HIGH-STAKES subset: a `pass` whose criterion requires
# `human-action`, OR whose checklist.json row is tagged `cross-tenant` /
# `cross-role-fk-chain`, AND has no-toolstream provenance is OVERRIDDEN to
# verifierVerdict:fail (confidence:high), and qa-verify's exit code goes
# non-zero. Non-high-stakes passes (read-only/computed evidence) with
# no-toolstream STILL degrade to confidence:low even under strict mode —
# they are not over-punished for a kind of evidence provenance.sh never
# checks anyway. HONEST RESIDUAL: strict mode still cannot distinguish "no
# capture-hook configured" from "capture-hook configured but its output was
# deleted" — both look like a missing toolstream.jsonl file to this script.
# It closes the exit-code ambiguity for CI/hardened callers who opt in, at
# the cost of also failing legitimate no-capture human-action runs in that
# mode. The fully-sound answer is the hardened tier (a managed/sandboxed
# capture path the run's own agent cannot `rm`) — out of scope here.
#
# PHASE-SURFACE PASS (Run FSM Enforcement Task 3, plan
# docs/superpowers/plans/2026-09-03-run-fsm-enforcement.md): a SEPARATE,
# ADDITIONAL pass — independent of the per-criterion pass-record loop above
# — that makes qa-verify the phase-surface AUTHORITY: it temporally
# correlates every toolstream.jsonl (H2) call to the phase/acting-window
# active at that moment (from journal.ndjson's `phase_entered`/`act_intent`/
# `act_committed` timeline, Plan A/B) and flags a tool used outside its
# sanctioned surface (`state-machine.json`'s `phaseToolSurface`, Task 1).
# Toolstream events carry NO phase tag, so correlation is by wall-clock `ts`
# (journal `t` / toolstream `ts`, both ISO-8601 UTC seconds — lexical string
# comparison is chronological comparison for this format, no date parsing
# needed): the ACTIVE PHASE at a call's `ts` is the last `phase_entered`
# whose `t` <= that `ts`; a criterion's ACTING WINDOW is [act_intent.t,
# act_committed.t] for the same `key` (an unmatched act_intent's window is
# treated as open-ended, i.e. never flags a false positive for a still-open
# act — fold's own `illegal-edge` anomaly already covers that case).
#
# A violation is either (a) a MUTATING browser tool (per parse-session-
# log.js's `mutates()`, reused via node — the toolClass `browser-mutation`
# for human-path acts, or `browser-evaluate-mutating` for a mutating
# `browser_evaluate`) whose `ts` falls OUTSIDE every acting window, or (b) a
# tool whose class is in the ACTIVE PHASE's `phaseToolSurface.
# forbiddenToolClasses` (e.g. `browser-navigate` during `Report`).
#
# RECORD-ONLY -> AUTHORITY (never a live block, spec resolution): every
# phase-surface finding is written to verification.json as confidence:"low"
# with a reason naming the phase/tool/ts, on a SYNTHETIC run-level record
# (criterionId "__phase-surface__" — a stray tool call cannot be pinned to
# one specific criterion) — it NEVER sets verifierVerdict to "fail" and
# NEVER flips qa-verify's exit code. This is a deliberate, documented
# residual: the spec allows "a hard override ONLY for an unambiguous
# mutating-act-outside-Verify", but this codebase has no reliable way to
# distinguish "unambiguous" from "merely undeterminable" using only
# second-resolution wall-clock timestamps and a best-effort tool-class
# classifier, and the binding constraint ("ambiguous/undeterminable ->
# confidence:low, NEVER a false override") dominates whenever that's in
# doubt — so EVERY finding here degrades rather than overrides. An
# undeterminable phase window (the call's `ts` precedes every `phase_entered`
# in the journal, or the journal has no timeline at all) degrades the SAME
# way (confidence:low, reason says so), never a false override.
#
# DEGRADE, NEVER FAIL: this pass runs ONLY when BOTH toolstream.jsonl AND a
# non-empty, parseable journal.ndjson exist for the run; either missing ->
# the pass is SKIPPED ENTIRELY (no record added, no effect on exit code) —
# same "opt-in capture, no punishment for its absence" posture as the
# no-toolstream provenance degrade above. This also preserves every EXISTING
# qa-verify fixture (none of which write journal.ndjson) byte-for-byte.
#
# DATA-DRIVEN: the phase -> allowed/forbidden toolClass map is read from
# `state-machine.json`'s `phaseToolSurface` (Task 1) at run time — never
# hardcoded here. Only the TOOL-NAME -> toolClass mapping itself is a fixed
# case statement (classify_tool, below) — there is no data file mapping
# concrete MCP tool identifiers to the abstract classes state-machine.json
# declares, matching this script's existing convention of small
# self-contained classifiers (e.g. capture-hook.sh's clock-advisory scan).

# RUN-SCOPED CHECKS PASS (plan 2026-09-23-error-honesty-invariants Task 8,
# spec §5.5): a THIRD pass, independent of BOTH the per-criterion pass-record
# loop and the phase-surface pass, adding four checks that are RUN-SCOPED —
# evaluated regardless of any criterion's recorded verdict.
#
# WHY RUN-SCOPED IS THE WHOLE POINT. Everything above this line re-checks only
# records whose `verdict == "pass"` (list_pass_records). In the incident this
# plan exists because of, the criterion that observed a 500 was recorded
# `fail`, so it was never re-examined by anything, and the run still shipped
# as a verified result. A check that only ever looks at passes cannot see a
# dropped error; these four look at the run.
#
#   1. LEDGER COMPLETENESS (I1). Recomputes the expected finding set from the
#      two independent channels — the driver network log (authoritative for
#      REQUESTS, including the navigating document request) and the
#      `__qaObserve` payloads recoverable from the toolstream (authoritative
#      for CONSOLE errors, which no network log can see) — and compares it
#      against the run's `finding_observed` journal events. An observation
#      that is REQUIRED to be journaled and is not OVERRIDES the run.
#      Required means classify-finding.sh returning in-scope + fatal for a
#      network observation, or an `error`-level console entry. A third-party
#      or benign 5xx is not required (that is what the classifier decides),
#      and an in-scope 3xx/4xx is recorded but never required (R1).
#   2. CLASSIFICATION RE-CHECK (I2). Re-runs classify-finding.sh over every
#      journaled finding and OVERRIDES the run on any disagreement. An agent
#      must not be able to mis-class a 500 by writing a journal event that
#      says otherwise.
#   3. LOAD-WINDOW COVERAGE (I5/R9). Fails a run in which a
#      `browser_navigate` is not followed by a `browser_network_requests`
#      before the next navigation. It reads ONLY the `tool` field, never
#      `responseBody` — capture-hook.sh:308 truncates responseBody at 4000
#      bytes and session-to-toolstream.js:119 writes it as `null` on three of
#      the four harnesses, so a check reading it would be unreliable; the
#      `tool` sequence is not. This is the check that closes the blind spot
#      where a navigation-time 500 lives: such a 500 IS the document request,
#      not a fetch/XHR, and no script runs on a 500 page, so `__qaObserve` is
#      structurally blind to it (spec §5.4, §11.3).
#   4. KNOWN-DEFECT GATE (I4). Any `expired` registry entry fails the run, as
#      does any entry that known-defects.sh validate rejects. The evidence
#      handed to `known-defects.sh status` is the ratified shape
#      {navigations:[{url,status}], findings:[{url,statusClass,status}]},
#      produced verbatim and never a local variant.
#
# NO EVIDENCE IS NOT CONTRADICTED EVIDENCE. When neither channel is available
# the checks do not fail the run: the absence is recorded (`channel: "none"`,
# a reason naming it, confidence degraded to "low") and Task 10 turns it into
# a run-level UNVERIFIED. Failing a run for having no capture would punish
# the wrong thing — the same "opt-in capture, no punishment for its absence"
# posture as the no-toolstream provenance degrade above.
#
# THE RECORD, AND THE ONE WAY IT DIFFERS FROM `__phase-surface__`: results are
# written to verification.json as a synthetic run-level record
# (criterionId "__run-checks__") carrying
#   runChecks: {ledgerComplete, classificationsAgree, loadWindowCovered,
#               knownDefectsOk}
# plus `channel` and the registry's per-entry states. Unlike the
# phase-surface record, this one DOES flip qa-verify's exit code: its checks
# are structural proofs about the run's own record rather than best-effort
# wall-clock correlation, and ADR-0026 settles that an engine invariant
# outranks a criterion's own pinned expectation. The record is emitted when
# any check is false OR when the run carried findings evidence at all; a run
# with none gains no record, which is both honest and what keeps every
# pre-existing fixture in tests/qa-verify/run.sh unchanged.

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED_KINDS_SH="$HERE/../skills/checkpointing-qa-memory/scripts/required-kinds.sh"
CHECK_ACTION_TRACE_JS="$HERE/../skills/checkpointing-qa-memory/scripts/check-action-trace.js"
PROVENANCE_SH="$HERE/provenance.sh"
TOOLSTREAM_SH="$HERE/toolstream.sh"
STATE_MACHINE_JSON="$HERE/../skills/checkpointing-qa-memory/references/state-machine.json"
PARSE_SESSION_LOG_JS="$HERE/../skills/driving-browser-qa/scripts/parse-session-log.js"
CLASSIFY_FINDING_SH="$HERE/classify-finding.sh"
KNOWN_DEFECTS_SH="$HERE/known-defects.sh"

# Script-global (NOT `local` to main) so the EXIT trap registered in main —
# which fires AFTER main returns, i.e. back at global scope — can still see
# it. A `local results_tmp` here would go out of scope the instant main()
# returns, making the EXIT trap's "$results_tmp" reference an unbound
# variable under `set -u` (silently skipping the `rm -f` and leaking the
# mktemp file every single invocation). Initialized empty; main() assigns
# the real mktemp path before registering the trap.
results_tmp=""

die() { echo "ERROR: $*" >&2; exit 1; }

# QA_ENGINE honored exactly like toolstream.sh/provenance.sh.
has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

[[ -f "$REQUIRED_KINDS_SH" ]] || die "qa-verify.sh: cannot find required-kinds.sh at ${REQUIRED_KINDS_SH}."
[[ -f "$CHECK_ACTION_TRACE_JS" ]] || die "qa-verify.sh: cannot find check-action-trace.js at ${CHECK_ACTION_TRACE_JS}."
[[ -f "$PROVENANCE_SH" ]] || die "qa-verify.sh: cannot find provenance.sh at ${PROVENANCE_SH}."
[[ -f "$TOOLSTREAM_SH" ]] || die "qa-verify.sh: cannot find toolstream.sh at ${TOOLSTREAM_SH}."
[[ -f "$STATE_MACHINE_JSON" ]] || die "qa-verify.sh: cannot find state-machine.json at ${STATE_MACHINE_JSON}."
[[ -f "$PARSE_SESSION_LOG_JS" ]] || die "qa-verify.sh: cannot find parse-session-log.js at ${PARSE_SESSION_LOG_JS}."
[[ -f "$CLASSIFY_FINDING_SH" ]] || die "qa-verify.sh: cannot find classify-finding.sh at ${CLASSIFY_FINDING_SH}."
[[ -f "$KNOWN_DEFECTS_SH" ]] || die "qa-verify.sh: cannot find known-defects.sh at ${KNOWN_DEFECTS_SH}."

# ---------------------------------------------------------------------------
# validate_run_id — mirrors provenance.sh/checkpoint.sh's Fix 28 path-
# traversal guard.
# ---------------------------------------------------------------------------
validate_run_id() {
  local value="$1"
  [[ -z "$value" ]] && die "run-id must not be empty."
  case "$value" in
    */*|*\\*) die "run-id '${value}' contains a path separator — must be a simple token." ;;
  esac
  case "$value" in
    *..*) die "run-id '${value}' contains '..' — must be a simple token." ;;
  esac
  if [[ "$value" =~ ^\.+$ ]]; then
    die "run-id '${value}' is '.' or consists only of dots — must be a simple token."
  fi
  case "$value" in
    -*) die "run-id '${value}' starts with '-' — must be a simple token." ;;
  esac
  return 0
}

run_dir() { echo "${QA_BASE}/$1"; }
checkpoint_file() { echo "$(run_dir "$1")/checkpoint.json"; }
checklist_file() { echo "$(run_dir "$1")/checklist.json"; }
verification_file() { echo "$(run_dir "$1")/verification.json"; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

# true (exit 0) iff $1 is syntactically valid JSON.
json_is_valid() {
  local file="$1"
  if has_jq; then
    jq -e . "$file" >/dev/null 2>&1
  else
    python3 -c "import json,sys
json.load(open(sys.argv[1]))" "$file" >/dev/null 2>&1
  fi
}

# true (exit 0) iff $1 is a JSON object containing key $2.
json_has_key() {
  local file="$1" key="$2"
  if has_jq; then
    [[ "$(jq -r --arg k "$key" 'if type == "object" then (has($k) | tostring) else "false" end' "$file" 2>/dev/null)" == "true" ]]
  else
    python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if isinstance(d, dict) and sys.argv[2] in d else 1)
except Exception:
    sys.exit(1)" "$file" "$key" >/dev/null 2>&1
  fi
}

# true (exit 0) iff the JSON value at key $2 in file $1 is the JSON boolean true.
json_value_is_true() {
  local file="$1" key="$2"
  if has_jq; then
    jq -e --arg k "$key" '(.[$k] // false) == true' "$file" >/dev/null 2>&1
  else
    python3 -c "import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get(sys.argv[2]) is True else 1)" "$file" "$key" >/dev/null 2>&1
  fi
}

# true (exit 0) iff bake evidence is internally consistent: readBack must be
# non-null whenever multiplicity != "0".
json_bake_value_ok() {
  local file="$1" mult
  if has_jq; then
    mult="$(jq -r '.multiplicity // ""' "$file" 2>/dev/null)"
  else
    mult="$(python3 -c "import json,sys
d = json.load(open(sys.argv[1]))
print(d.get('multiplicity', ''))" "$file" 2>/dev/null)"
  fi
  [[ "$mult" == "0" ]] && return 0
  if has_jq; then
    jq -e '.readBack != null' "$file" >/dev/null 2>&1
  else
    python3 -c "import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get('readBack') is not None else 1)" "$file" >/dev/null 2>&1
  fi
}

# true (exit 0) iff checklist row JSON $1 carries a `cross-tenant` or
# `cross-role-fk-chain` tag — the high-stakes tags QA_VERIFY_STRICT also
# treats as requiring corroborated provenance, alongside human-action.
# Mirrors required-kinds.sh's own tag-membership check (rule 4) for
# `cross-tenant`/`cross-role-fk-chain`, but NOT `probe-needed` — a bare
# probe-needed criterion isn't itself the mutating/cross-tenant risk this
# residual targets. Never dies — an absent/malformed row means "no tag".
row_has_high_stakes_tag() {
  local row="$1"
  [[ -z "$row" ]] && return 1
  if has_jq; then
    jq -e '
      (.tags // []) as $t
      | ($t | type) == "array"
      and (($t | map(tostring)) as $ts | ($ts | index("cross-tenant")) != null or ($ts | index("cross-role-fk-chain")) != null)
    ' <<< "$row" >/dev/null 2>&1
  else
    python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
tags = d.get("tags") if isinstance(d, dict) else None
if not isinstance(tags, list):
    sys.exit(1)
tags = [str(t) for t in tags]
sys.exit(0 if ("cross-tenant" in tags or "cross-role-fk-chain" in tags) else 1)
' "$row" >/dev/null 2>&1
  fi
}

# is_high_stakes <kinds-csv> <checklist-row-json> — true (exit 0) iff the
# recorded kinds contain `human-action`, OR the checklist row is tagged
# `cross-tenant`/`cross-role-fk-chain` (row_has_high_stakes_tag, above).
# This is the SAME "high-stakes" definition the QA_VERIFY_STRICT
# no-toolstream residual already used inline (now factored out here) and
# the gate for the persona-identity check below (Plan H3 Task 1) — a
# read-only/non-high-stakes criterion is never identity-checked.
is_high_stakes() {
  local kinds_csv="$1" row="$2"
  case ",${kinds_csv}," in
    *,human-action,*) return 0 ;;
  esac
  row_has_high_stakes_tag "$row"
}

# to_lower <str> -> <str> lowercased (plain coreutils tr, no locale surprises
# for the ASCII subject/persona ids this codebase deals with).
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# str_contains <haystack> <needle> -> true (exit 0) iff <haystack> contains
# <needle> as a substring. Both args are expected pre-lowercased by the
# caller — this is a plain shell glob match, not a regex engine.
str_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# json_field <file> <key> -> the string value of <key> in the top-level JSON
# object <file>, or "" if the file is missing/unparseable/non-object, or the
# key is absent/null. Never dies.
json_field() {
  local file="$1" key="$2"
  if has_jq; then
    jq -r --arg k "$key" 'if type == "object" then ((.[$k] // "") | tostring) else "" end' "$file" 2>/dev/null
  else
    python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    v = d.get(sys.argv[2]) if isinstance(d, dict) else None
    print(v if v is not None else '')
except Exception:
    print('')" "$file" "$key" 2>/dev/null
  fi
}

# config_expected_subject_for <persona-id> -> `.qa/config.json`'s
# `personas[].expectedSubject` for that persona id (Plan H3 Task 1's v1
# expected-identity mapping), or "" if `.qa/config.json` is absent/invalid,
# the persona isn't listed, or it has no `expectedSubject`. NEVER dies — an
# absent/malformed config just falls back (caller) to comparing against the
# persona id itself.
config_expected_subject_for() {
  local persona="$1" file=".qa/config.json"
  [[ -f "$file" ]] || return 0
  json_is_valid "$file" || return 0
  if has_jq; then
    jq -r --arg p "$persona" '(.personas // []) | map(select(type == "object" and .id == $p)) | (.[0].expectedSubject // "")' "$file" 2>/dev/null
  else
    python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    for p in (d.get('personas') or []):
        if isinstance(p, dict) and p.get('id') == sys.argv[2]:
            v = p.get('expectedSubject')
            print(v if v else '')
            break
    else:
        print('')
except Exception:
    print('')" "$file" "$persona" 2>/dev/null
  fi
}

# config_persona_count -> stdout the number of entries in `.qa/config.json`'s
# `personas[]` array, or "0" if the file is absent/invalid/has none. NEVER
# dies (same posture as config_expected_subject_for) — used only to decide
# whether persona-identity binding should have applied at all (Appendix A:
# "missing --persona bypasses identity binding").
config_persona_count() {
  local file=".qa/config.json"
  [[ -f "$file" ]] || { echo 0; return 0; }
  json_is_valid "$file" || { echo 0; return 0; }
  if has_jq; then
    jq -r '(.personas // []) | length' "$file" 2>/dev/null || echo 0
  else
    python3 -c "import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get('personas') or []))
except Exception:
    print(0)" "$file" 2>/dev/null || echo 0
  fi
}

# artifact filename for a given kind — mirrors checkpoint.sh's kind_artifact.
kind_artifact() {
  case "$1" in
    bake)     echo "bake-read-back.json" ;;
    computed) echo "recompute.json" ;;
    probe)    echo "network-response.json" ;;
    human-action) echo "action-trace.json" ;;
    *) return 1 ;;
  esac
}

# space-separated required keys for a given kind — mirrors checkpoint.sh's
# kind_required_keys.
kind_required_keys() {
  case "$1" in
    bake)     echo "readBack multiplicity" ;;
    computed) echo "oracle observed match" ;;
    probe)    echo "status shape ok" ;;
    human-action) echo "steps" ;;
    *)        return 1 ;;
  esac
}

# checklist_row_for <run-id> <crit-id> — mirrors checkpoint.sh's
# checklist_row_for exactly: prints the checklist.json row whose "id" ==
# <crit-id>, or nothing when checklist.json is absent/malformed/no match.
# NEVER dies — "no row found" must be indistinguishable from "no
# checklist.json at all" (both mean: skip the required-kinds re-derivation
# for this criterion).
checklist_row_for() {
  local run_id="$1" crit_id="$2" file
  file="$(checklist_file "$run_id")"
  [[ -f "$file" ]] || return 0
  json_is_valid "$file" || return 0

  if has_jq; then
    jq -c --arg id "$crit_id" '
      if type == "array" then
        (([ .[] | select(type == "object" and .id == $id) ] | .[0]) // empty)
      else
        empty
      end
    ' "$file" 2>/dev/null || true
  elif has_py; then
    python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
for row in data:
    if isinstance(row, dict) and row.get("id") == sys.argv[2]:
        print(json.dumps(row))
        sys.exit(0)
' "$file" "$crit_id" || true
  fi
  return 0
}

# missing_required_kinds <recorded-csv> <required-csv> — mirrors
# checkpoint.sh's missing_required_kinds exactly.
missing_required_kinds() {
  local recorded_csv="$1" required_csv="$2"
  local -a req_arr rec_arr rec_trimmed=() missing=()
  IFS=',' read -ra req_arr <<< "$required_csv"
  IFS=',' read -ra rec_arr <<< "$recorded_csv"

  local r
  for r in ${rec_arr[@]+"${rec_arr[@]}"}; do
    r="$(trim "$r")"
    [[ -n "$r" ]] && rec_trimmed+=("$r")
  done

  local rk item found
  for rk in ${req_arr[@]+"${req_arr[@]}"}; do
    rk="$(trim "$rk")"
    [[ -z "$rk" ]] && continue
    found=""
    for item in ${rec_trimmed[@]+"${rec_trimmed[@]}"}; do
      [[ "$item" == "$rk" ]] && { found="yes"; break; }
    done
    [[ -z "$found" ]] && missing+=("$rk")
  done

  (IFS=,; echo "${missing[*]-}")
}

# json_array_from_args <str> [<str> ...] -> a JSON array of the given strings
# (each a COMPLETE element — no CSV splitting, so a reason sentence
# containing a comma is never mis-split). Empty arg list -> "[]".
json_array_from_args() {
  if [[ $# -eq 0 ]]; then echo "[]"; return 0; fi
  if has_jq; then
    jq -cn --args '$ARGS.positional' -- "$@"
  else
    python3 -c '
import json, sys
print(json.dumps(sys.argv[1:]))
' "$@"
  fi
}

# ---------------------------------------------------------------------------
# PHASE-SURFACE PASS helpers (Run FSM Enforcement Task 3). See the header
# comment's "PHASE-SURFACE PASS" section for the full design rationale.
# ---------------------------------------------------------------------------

journal_file() { echo "$(run_dir "$1")/journal.ndjson"; }
toolstream_file_for() { echo "$(run_dir "$1")/toolstream.jsonl"; }

# has_toolstream <run-id> — exit 0 iff a non-empty toolstream.jsonl exists.
has_toolstream() { [[ -s "$(toolstream_file_for "$1")" ]]; }

# has_journal_timeline <run-id> — exit 0 iff journal.ndjson exists, is
# non-empty, and contains at least one line that parses as a JSON object
# (a torn last line alone does not count). This is the pass's SKIP guard:
# absent -> the phase-surface pass never runs for this run (degrade, no
# finding, no effect on exit code) — see the header comment.
has_journal_timeline() {
  local f line
  f="$(journal_file "$1")"
  [[ -s "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if has_jq; then
      jq -e 'type == "object"' >/dev/null 2>&1 <<< "$line" && return 0
    else
      python3 -c "import json,sys
json.loads(sys.argv[1])" "$line" >/dev/null 2>&1 && return 0
    fi
  done < "$f"
  return 1
}

# json_line_field <json-line> <key> -> the string value of <key>, or "" if
# absent/non-string/unparseable. Never dies.
json_line_field() {
  local line="$1" key="$2"
  if has_jq; then
    jq -r --arg k "$key" '(.[$k] // "") | if type == "string" then . else "" end' <<< "$line" 2>/dev/null
  else
    python3 -c "import json,sys
try:
    d = json.loads(sys.argv[1])
    v = d.get(sys.argv[2])
    print(v if isinstance(v, str) else '')
except Exception:
    print('')" "$line" "$key" 2>/dev/null
  fi
}

# json_line_args <json-line> -> compact JSON of .args (or {} if absent/
# unparseable). Never dies.
json_line_args() {
  local line="$1"
  if has_jq; then
    jq -c '(.args // {})' <<< "$line" 2>/dev/null || echo "{}"
  else
    python3 -c "import json,sys
try:
    d = json.loads(sys.argv[1])
    print(json.dumps(d.get('args') or {}, separators=(',', ':')))
except Exception:
    print('{}')" "$line" 2>/dev/null || echo "{}"
  fi
}

# classify_tool <tool-name> -> a state-machine.json `toolClasses` value, the
# sentinel "__evaluate__" (a browser_evaluate call — resolved to
# browser-evaluate-{mutating,readonly} by the caller via evaluate_mutates,
# below), or "" for an unrecognized tool (never flagged — conservative:
# an unknown tool is never treated as a phase-surface signal either way).
# Matches on a TRAILING pattern (`*browser_click` etc.) so both a bare tool
# name and an MCP-prefixed one (e.g.
# "mcp__plugin_playwright_playwright__browser_click") classify identically.
classify_tool() {
  case "$1" in
    *browser_navigate_back) echo "browser-navigate" ;;
    *browser_navigate) echo "browser-navigate" ;;
    *browser_snapshot) echo "browser-snapshot" ;;
    *browser_click|*browser_type|*browser_fill_form|*browser_press_key|*browser_select_option|*browser_drag|*browser_drop|*browser_file_upload|*browser_handle_dialog)
      echo "browser-mutation" ;;
    *browser_hover|*browser_wait_for|*browser_tabs|*browser_resize|*browser_console_messages|*browser_take_screenshot|*browser_close)
      echo "browser-interaction" ;;
    *browser_evaluate|*browser_run_code_unsafe) echo "__evaluate__" ;;
    *browser_network_request|*browser_network_requests) echo "probe" ;;
    Bash) echo "bash" ;;
    *) echo "" ;;
  esac
}

# evaluate_mutates <args-json> -> "true"|"false" — classifies a
# browser_evaluate call's payload (.function and/or .code) via
# parse-session-log.js's `mutates()`, REUSED VERBATIM (the same single
# source of truth check-action-trace.js's Check 2 and capture-hook.sh's
# session-log parsing already rely on) — never reimplemented here. Uses
# `node` (an existing dependency of this script via check-action-trace.js,
# not a new one). Never dies: a node failure (missing binary, malformed
# args) degrades to "false" (not-mutating) rather than aborting qa-verify —
# the phase-surface pass is a best-effort record-only pass, never a hard
# dependency.
evaluate_mutates() {
  local args="$1"
  node -e '
const { mutates } = require(process.argv[2]);
let args = {};
try { args = JSON.parse(process.argv[1] || "{}"); } catch (e) { args = {}; }
const fn = typeof args.function === "string" ? args.function : "";
const code = typeof args.code === "string" ? args.code : "";
process.stdout.write(mutates(fn + "\n" + code) ? "true" : "false");
' "$args" "$PARSE_SESSION_LOG_JS" 2>/dev/null || echo "false"
}

# build_classified_events <run-id> -> stdout a compact JSON array of
# {tool, ts, toolClass, mutating} — one per toolstream.jsonl line whose tool
# classifies to a known class (classify_tool). Unrecognized tools are
# dropped (never a phase-surface signal — see classify_tool's comment).
build_classified_events() {
  local run_id="$1" line tool ts args cls mutating
  local -a objs=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    tool="$(json_line_field "$line" "tool")"
    ts="$(json_line_field "$line" "ts")"
    [[ -z "$tool" || -z "$ts" ]] && continue
    cls="$(classify_tool "$tool")"
    [[ -z "$cls" ]] && continue
    if [[ "$cls" == "__evaluate__" ]]; then
      args="$(json_line_args "$line")"
      if [[ "$(evaluate_mutates "$args")" == "true" ]]; then
        cls="browser-evaluate-mutating"
      else
        cls="browser-evaluate-readonly"
      fi
    fi
    mutating="false"
    [[ "$cls" == "browser-mutation" || "$cls" == "browser-evaluate-mutating" ]] && mutating="true"
    if has_jq; then
      objs+=("$(jq -cn --arg tool "$tool" --arg ts "$ts" --arg cls "$cls" --argjson mutating "$mutating" \
        '{tool: $tool, ts: $ts, toolClass: $cls, mutating: $mutating}')")
    else
      objs+=("$(python3 -c "import json,sys
print(json.dumps({'tool': sys.argv[1], 'ts': sys.argv[2], 'toolClass': sys.argv[3], 'mutating': sys.argv[4] == 'true'}))" \
        "$tool" "$ts" "$cls" "$mutating")")
    fi
  done < <(bash "$TOOLSTREAM_SH" read "$run_id" 2>/dev/null)
  if [[ ${#objs[@]} -eq 0 ]]; then
    echo "[]"
  else
    (IFS=,; echo "[${objs[*]}]")
  fi
}

# build_phase_timeline <run-id> -> stdout a compact JSON array of
# {t, phase}, one per `phase_entered` journal event, sorted ascending by t.
build_phase_timeline() {
  local f; f="$(journal_file "$1")"
  [[ -s "$f" ]] || { echo "[]"; return 0; }
  if has_jq; then
    jq -c -R -s '
      [ split("\n")[] | select(length > 0) | (try fromjson catch empty) ]
      | map(select(type == "object" and .event == "phase_entered" and (.t | type == "string") and (.phase | type == "string")))
      | map({t: .t, phase: .phase})
      | sort_by(.t)
    ' "$f" 2>/dev/null || echo "[]"
  else
    python3 -c "
import json, sys
out = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get('event') == 'phase_entered' and isinstance(obj.get('t'), str) and isinstance(obj.get('phase'), str):
            out.append({'t': obj['t'], 'phase': obj['phase']})
out.sort(key=lambda x: x['t'])
print(json.dumps(out))
" "$f" 2>/dev/null || echo "[]"
  fi
}

# build_acting_windows <run-id> -> stdout a compact JSON array of
# {key, intentT, committedT} (committedT is null for an unmatched/still-open
# act_intent — treated as an open-ended window so an in-flight act is never
# a false phase-surface positive; fold's own illegal-edge anomaly already
# covers an orphaned act_intent). An act_committed with no matching
# act_intent contributes nothing (no window; that mismatch is fold's
# illegal-edge concern, not this pass's).
build_acting_windows() {
  local f; f="$(journal_file "$1")"
  [[ -s "$f" ]] || { echo "[]"; return 0; }
  if has_jq; then
    jq -c -R -s '
      [ split("\n")[] | select(length > 0) | (try fromjson catch empty) ]
      | map(select(type == "object"))
      | (reduce .[] as $e ({};
          if $e.event == "act_intent" and ($e.key | type == "string") then
            .[$e.key] = ((.[$e.key] // {}) + {key: $e.key, intentT: $e.t})
          elif $e.event == "act_committed" and ($e.key | type == "string") then
            .[$e.key] = ((.[$e.key] // {key: $e.key}) + {committedT: $e.t})
          else . end
        )) as $m
      | [ $m[] | select(has("intentT")) | {key: .key, intentT: .intentT, committedT: (.committedT // null)} ]
    ' "$f" 2>/dev/null || echo "[]"
  else
    python3 -c "
import json, sys
m = {}
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if not isinstance(e, dict):
            continue
        key = e.get('key')
        if e.get('event') == 'act_intent' and isinstance(key, str):
            m.setdefault(key, {'key': key})['intentT'] = e.get('t')
        elif e.get('event') == 'act_committed' and isinstance(key, str):
            m.setdefault(key, {'key': key})['committedT'] = e.get('t')
out = [{'key': v['key'], 'intentT': v.get('intentT'), 'committedT': v.get('committedT')} for v in m.values() if 'intentT' in v]
print(json.dumps(out))
" "$f" 2>/dev/null || echo "[]"
  fi
}

# phase_surface_reasons <events-json> <phases-json> <windows-json>
# <windows-active> -> stdout a compact JSON array of human-readable reason
# strings, one per violating toolstream event — the pure temporal-
# correlation function. Reads state-machine.json's phaseToolSurface
# (data-driven; never hardcoded). Phase names are matched CASE-
# INSENSITIVELY against phaseToolSurface's keys (the plan's Global
# Constraints: "the statechart phase names... matched case-insensitively to
# the free-text --phase values" — checkpoint.sh's 3-arg CLI defaults
# `--phase` to lowercase "verify", not state-machine.json's "Verify").
#
# <windows-active> ("true"|"false"): whether this RUN recorded ANY acting
# window at all (i.e. build_acting_windows returned a non-empty array).
# When "false" (a run that never used journal-emit.sh's act-intent/
# act-commit CLI — e.g. every run built only via checkpoint.sh's plain
# 3-arg CLI, which never emits act_intent/act_committed), the
# mutating-outside-window rule is a NON-SIGNAL — "outside every window"
# is vacuously true when zero windows were ever recorded, and would
# otherwise flag EVERY legitimate mutating browser call in EVERY such run
# (a systemic false-positive, not a real signal that this specific call
# was misplaced). So that rule is DISABLED for the whole run in that case;
# only the phase-forbidden-list check (which needs only phase_entered
# events, always emitted by checkpoint.sh) still applies.
# Deliberately uses NO apostrophes in generated reason text so the strings
# never need escaping inside either engine's quoting.
phase_surface_reasons() {
  local events="$1" phases="$2" windows="$3" windows_active="$4"
  if has_jq; then
    jq -n -c \
      --argjson events "$events" --argjson phases "$phases" --argjson windows "$windows" \
      --argjson windowsActive "$windows_active" \
      --slurpfile smArr "$STATE_MACHINE_JSON" '
      ($smArr[0].phaseToolSurface // {}) as $surface
      | def activePhase(ts):
          ([ $phases[] | select(.t <= ts) ] | sort_by(.t) | last) as $p
          | if $p == null then null else $p.phase end;
        def inWindow(ts):
          ([ $windows[] | select(.intentT <= ts and ((.committedT == null) or (ts <= .committedT))) ]) | length > 0;
        def forbiddenFor(phase):
          ($surface | to_entries[] | select(.key | ascii_downcase == (phase | ascii_downcase)) | .value.forbiddenToolClasses) // [];
        [ $events[] |
          . as $e
          | (activePhase($e.ts)) as $phase
          | (inWindow($e.ts)) as $win
          | if ($e.mutating == true) and $windowsActive and ($win | not) then
              (if $phase == null then
                 "mutating tool " + $e.tool + " (class " + $e.toolClass + ") at ts=" + $e.ts + " fell outside any acting window; active phase undeterminable (no phase_entered recorded before this call)"
               else
                 "mutating tool " + $e.tool + " (class " + $e.toolClass + ") at ts=" + $e.ts + " fell outside any acting window while the active phase was " + $phase
               end)
            elif ($phase != null) and (forbiddenFor($phase) | index($e.toolClass) != null) then
              "tool " + $e.tool + " (class " + $e.toolClass + ") used during phase " + $phase + ", which forbids toolClass " + $e.toolClass + " per state-machine.json phaseToolSurface"
            else empty
            end
        ]
      ' 2>/dev/null || echo "[]"
  else
    python3 -c '
import json, sys
events = json.loads(sys.argv[1])
phases = json.loads(sys.argv[2])
windows = json.loads(sys.argv[3])
windows_active = sys.argv[4] == "true"
sm = json.load(open(sys.argv[5]))
surface = sm.get("phaseToolSurface") or {}
surface_lower = {k.lower(): v for k, v in surface.items() if isinstance(v, dict)}
phases_sorted = sorted(phases, key=lambda p: p["t"])

def active_phase(ts):
    cur = None
    for p in phases_sorted:
        if p["t"] <= ts:
            cur = p["phase"]
        else:
            break
    return cur

def in_window(ts):
    for w in windows:
        if w.get("intentT") is not None and w["intentT"] <= ts and (w.get("committedT") is None or ts <= w["committedT"]):
            return True
    return False

def forbidden_for(phase):
    return (surface_lower.get(phase.lower(), {}) or {}).get("forbiddenToolClasses") or []

reasons = []
for e in events:
    ts = e.get("ts")
    phase = active_phase(ts)
    win = in_window(ts)
    if e.get("mutating") and windows_active and not win:
        if phase is None:
            reasons.append("mutating tool " + str(e.get("tool")) + " (class " + str(e.get("toolClass")) + ") at ts=" + str(ts) + " fell outside any acting window; active phase undeterminable (no phase_entered recorded before this call)")
        else:
            reasons.append("mutating tool " + str(e.get("tool")) + " (class " + str(e.get("toolClass")) + ") at ts=" + str(ts) + " fell outside any acting window while the active phase was " + str(phase))
    elif phase is not None and e.get("toolClass") in forbidden_for(phase):
        reasons.append("tool " + str(e.get("tool")) + " (class " + str(e.get("toolClass")) + ") used during phase " + str(phase) + ", which forbids toolClass " + str(e.get("toolClass")) + " per state-machine.json phaseToolSurface")
print(json.dumps(reasons))
' "$events" "$phases" "$windows" "$windows_active" "$STATE_MACHINE_JSON" 2>/dev/null || echo "[]"
  fi
}

# run_phase_surface_pass <run-id> -> stdout ONE compact JSON verification
# record (the "__phase-surface__" synthetic run-level finding) iff at least
# one violation was found, else prints nothing. Skips entirely (prints
# nothing) unless BOTH toolstream.jsonl and a parseable journal.ndjson exist
# — see has_toolstream/has_journal_timeline above and the header comment.
run_phase_surface_pass() {
  local run_id="$1"
  has_toolstream "$run_id" || return 0
  has_journal_timeline "$run_id" || return 0

  local events phases windows windows_active reasons
  events="$(build_classified_events "$run_id")"
  phases="$(build_phase_timeline "$run_id")"
  windows="$(build_acting_windows "$run_id")"
  windows_active="false"
  [[ -n "$windows" && "$windows" != "[]" && "$windows" != "null" ]] && windows_active="true"
  reasons="$(phase_surface_reasons "$events" "$phases" "$windows" "$windows_active")"

  [[ -z "$reasons" || "$reasons" == "[]" || "$reasons" == "null" ]] && return 0

  if has_jq; then
    jq -cn --argjson reasons "$reasons" \
      '{criterionId: "__phase-surface__", persona: "", inRunVerdict: "n/a", verifierVerdict: "pass", confidence: "low", reasons: $reasons}'
  else
    python3 -c '
import json, sys
print(json.dumps({
    "criterionId": "__phase-surface__", "persona": "", "inRunVerdict": "n/a",
    "verifierVerdict": "pass", "confidence": "low", "reasons": json.loads(sys.argv[1])
}))
' "$reasons"
  fi
}

# ---------------------------------------------------------------------------
# list_pass_records <run-id> — one compact JSON object (NDJSON) per
# checkpoint.json criteria[] entry whose verdict == "pass", printed verbatim.
# NOTE: deliberately NDJSON, not TSV. bash's `IFS=$'\t' read` COLLAPSES runs
# of tab (tab is one of the "IFS whitespace" characters even when IFS is set
# to just a tab, exactly like space/newline are) and strips leading/trailing
# tabs — so a TSV row with an empty leading/interior field (persona=""
# and/or nonUiActionReason="", the COMMON case) silently shifts every column
# left. Caught by this suite's own fixtures (a "" persona column made
# `read` assign `confidence`'s value into `persona`). NDJSON + a `jq -r`
# multi-line extraction per record (read_pass_record, below, mirrors
# required-kinds.sh's own read_criterion idiom) sidesteps the whole class of
# bug: newline is only special to `mapfile`'s line splitting, never
# collapsed/stripped.
# ---------------------------------------------------------------------------
list_pass_records() {
  local run_id="$1" file
  file="$(checkpoint_file "$run_id")"
  if has_jq; then
    jq -c '.criteria[]? | select(.verdict == "pass")' "$file" 2>/dev/null
  else
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for c in d.get("criteria", []) or []:
    if c.get("verdict") == "pass":
        print(json.dumps(c))
' "$file" 2>/dev/null
  fi
}

# read_pass_record <rec-json> -> stdout 5 lines: criterion_id, persona,
# confidence, nonUiActionReason, kinds(csv). Mirrors required-kinds.sh's
# read_criterion multi-line-output idiom (see list_pass_records' comment for
# why this replaces a TSV+`read` approach).
read_pass_record() {
  local rec="$1"
  if has_jq; then
    jq -r '
      .criterion_id,
      (.persona // ""),
      (.confidence // "high"),
      (.nonUiActionReason // ""),
      ((.kinds // []) | join(","))
    ' <<< "$rec"
  else
    python3 -c '
import json, sys
c = json.loads(sys.argv[1])
kinds = c.get("kinds") or []
print(c.get("criterion_id", ""))
print(c.get("persona") or "")
print(c.get("confidence") or "high")
print(c.get("nonUiActionReason") or "")
print(",".join(kinds))
' "$rec"
  fi
}

# ---------------------------------------------------------------------------
# maybe_redrive <run-id> <crit-id> <persona> <kinds-csv> — the pluggable,
# UN-unit-tested QA_VERIFY_REDRIVE_CMD hook. See the header comment for the
# full rationale. A no-op unless the env var is set AND the criterion is
# high-stakes (kinds contains human-action or probe). Never affects
# verifierVerdict/confidence; never lets the sub-command's failure abort
# qa-verify itself.
# ---------------------------------------------------------------------------
maybe_redrive() {
  local run_id="$1" crit_id="$2" persona="$3" kinds_csv="$4"
  [[ -z "${QA_VERIFY_REDRIVE_CMD:-}" ]] && return 0
  case ",${kinds_csv}," in
    *,human-action,*|*,probe,*) ;;
    *) return 0 ;;
  esac
  echo "NOTE: QA_VERIFY_REDRIVE_CMD set — invoking pluggable independent re-drive for '${crit_id}' (persona='${persona}'). This is a documented stub (spec §5.3 second half): its result is logged, NOT incorporated into verifierVerdict/confidence here." >&2
  "${QA_VERIFY_REDRIVE_CMD}" "$run_id" "$crit_id" "$persona" >&2 \
    || echo "NOTE: QA_VERIFY_REDRIVE_CMD exited non-zero for '${crit_id}' (ignored by design — the re-drive result is not wired into reconciliation here)." >&2
  return 0
}

# ---------------------------------------------------------------------------
# process_criterion <run-id> <crit-id> <persona> <in-confidence> <nonui-reason>
# <kinds-csv> -> stdout: one compact JSON object (the verification.json
# record for this criterion). NOTE: this function is always invoked via
# command substitution ("$(process_criterion ...)"), which runs it in a
# SUBSHELL — any variable it sets is invisible to the caller once it
# returns. The caller therefore determines pass/fail by reading
# `.verifierVerdict` back OUT of the printed JSON (see rec_verdict below),
# never via a side-channel global.
# ---------------------------------------------------------------------------
process_criterion() {
  local run_id="$1" crit_id="$2" persona="$3" confidence="$4" nonui_reason="$5" kinds_csv="$6"
  local -a reasons=()
  local override=0 no_toolstream_seen=0

  # --- Step 1: re-derive required kinds from checklist.json (never the
  # agent's own requiredKinds field) and check the recorded kinds are a
  # superset. ---------------------------------------------------------------
  local row required_csv=""
  row="$(checklist_row_for "$run_id" "$crit_id")"
  if [[ -n "$row" ]]; then
    local rk_ext_path rk_eng
    rk_ext_path="${PATH}:${BASH%/*}"
    rk_eng="python3"; has_jq && rk_eng="jq"
    required_csv="$(QA_ENGINE="$rk_eng" PATH="$rk_ext_path" "$BASH" "$REQUIRED_KINDS_SH" derive "$row")" \
      || die "qa-verify.sh: required-kinds.sh derive failed for criterion '${crit_id}' (row: ${row})."
    if [[ -n "$required_csv" ]]; then
      local missing_csv
      missing_csv="$(missing_required_kinds "$kinds_csv" "$required_csv")"
      if [[ -n "$missing_csv" ]]; then
        reasons+=("required evidence kind(s) '${missing_csv}' are missing — independently re-derived from the checklist.json row via required-kinds.sh (full required set: ${required_csv}; recorded kinds: ${kinds_csv:-<none>})")
        override=1
      fi
    fi
  fi

  # --- Steps 2+3: per recorded kind, re-validate structure/value, then bind
  # provenance (bake/probe/human-action only). ------------------------------
  local -a kinds_arr=()
  IFS=',' read -ra kinds_arr <<< "$kinds_csv"
  local kind artifact rel_path full_path structural_ok key required_keys
  for kind in ${kinds_arr[@]+"${kinds_arr[@]}"}; do
    kind="$(trim "$kind")"
    [[ -z "$kind" ]] && continue

    case "$kind" in
      bake|computed|probe|human-action) ;;
      *)
        reasons+=("recorded kind '${kind}' is not a valid evidence kind (must be one of: bake|computed|probe|human-action)")
        override=1
        continue
        ;;
    esac

    artifact="$(kind_artifact "$kind")"
    if [[ -n "$persona" ]]; then
      rel_path="evidence/${persona}/${crit_id}/${artifact}"
    else
      rel_path="evidence/${crit_id}/${artifact}"
    fi
    full_path="$(run_dir "$run_id")/${rel_path}"

    structural_ok=1
    if [[ ! -f "$full_path" ]]; then
      reasons+=("evidence artifact '${rel_path}' (kind ${kind}) is missing")
      structural_ok=0; override=1
    elif [[ ! -s "$full_path" ]]; then
      reasons+=("evidence artifact '${rel_path}' (kind ${kind}) is empty")
      structural_ok=0; override=1
    elif ! json_is_valid "$full_path"; then
      reasons+=("evidence artifact '${rel_path}' (kind ${kind}) is not valid JSON")
      structural_ok=0; override=1
    else
      required_keys="$(kind_required_keys "$kind")"
      for key in $required_keys; do
        if ! json_has_key "$full_path" "$key"; then
          reasons+=("evidence artifact '${rel_path}' (kind ${kind}) is missing required key '${key}'")
          structural_ok=0; override=1
        fi
      done
    fi

    if [[ "$structural_ok" -eq 1 ]]; then
      case "$kind" in
        computed)
          if ! json_value_is_true "$full_path" "match"; then
            reasons+=("evidence artifact '${rel_path}' shows match:false — the independent recompute diverged from the observed value")
            override=1
          fi
          ;;
        bake)
          if ! json_bake_value_ok "$full_path"; then
            reasons+=("evidence artifact '${rel_path}' shows readBack:null with non-zero multiplicity — nothing was actually persisted")
            override=1
          fi
          ;;
        probe)
          if ! json_value_is_true "$full_path" "ok"; then
            reasons+=("evidence artifact '${rel_path}' shows ok:false or missing — the probe did not confirm its expectation")
            override=1
          fi
          ;;
        human-action)
          local allow=() node_out node_rc
          [[ -n "$nonui_reason" ]] && allow=(--allow-nonui)
          node_out="$(node "$CHECK_ACTION_TRACE_JS" "$full_path" ${allow[@]+"${allow[@]}"} 2>&1)"
          node_rc=$?
          if [[ "$node_rc" -ne 0 ]]; then
            local first_line="${node_out%%$'\n'*}"
            reasons+=("human-action gate rejected '${rel_path}': ${first_line}")
            structural_ok=0
            override=1
          fi
          ;;
      esac
    fi

    # Provenance binding — bake/probe/human-action only (never computed, see
    # header comment). Only meaningful once the file is at least valid JSON
    # (json_is_valid passed) — provenance.sh expects a real artifact.
    if [[ "$kind" != "computed" ]] && [[ -f "$full_path" ]] && [[ -s "$full_path" ]] && json_is_valid "$full_path"; then
      local prov
      prov="$(bash "$PROVENANCE_SH" check "$run_id" "$full_path")"
      case "$prov" in
        unbound)
          reasons+=("provenance UNBOUND: '${rel_path}' corresponds to no captured toolstream call — forgery signal (AC-1)")
          override=1
          ;;
        no-toolstream)
          no_toolstream_seen=1
          ;;
        bound) : ;;
        *)
          reasons+=("provenance.sh returned an unexpected result '${prov}' for '${rel_path}'")
          override=1
          ;;
      esac
    fi
  done

  # --- Step 3.5: persona-identity binding (Plan H3 Task 1, gap #6). See the
  # header comment's numbered walkthrough for the full rationale. Only a
  # PERSONA-SCOPED (non-empty, not the "__shared__" sentinel) HIGH-STAKES
  # criterion is checked; __shared__/empty-persona/read-only criteria are
  # exempt — skipped entirely, no reason recorded, override/confidence
  # untouched.
  #
  # Appendix A tighten ("missing --persona bypasses identity binding"): the
  # exemption above is legitimate for a genuinely single-persona/no-role-
  # sensitivity project (persona is ALWAYS "" there — checking would be
  # meaningless noise). But when the project's OWN config declares MORE
  # THAN ONE persona (`.qa/config.json`'s personas[] — i.e. role-sensitivity
  # is real for this target) and a HIGH-STAKES pass was checkpointed with NO
  # persona at all, that is not "shared/read-only", it is "acted as nobody
  # verifiable" — the identity-binding check was silently bypassed by simply
  # omitting `--persona` on the checkpoint.sh call. DEGRADE (never a hard
  # override — no evidence of WRONG identity exists here, only of identity
  # never having been captured at all; same "ambiguous -> confidence:low"
  # doctrine as every other degrade in this function). ----------------------
  if [[ -n "$persona" ]] && [[ "$persona" != "__shared__" ]] && is_high_stakes "$kinds_csv" "$row"; then
    local identity_rel identity_full
    identity_rel="evidence/${persona}/identity.json"
    identity_full="$(run_dir "$run_id")/${identity_rel}"

    if [[ ! -f "$identity_full" ]] || [[ ! -s "$identity_full" ]] || ! json_is_valid "$identity_full"; then
      confidence="low"
      reasons+=("persona identity unverified: no ${identity_rel} recorded for this run — persona-identity binding degrades rather than blocks on an unverifiable identity (spec §5.5)")
    else
      local id_method id_subject
      id_method="$(json_field "$identity_full" "method")"
      id_subject="$(json_field "$identity_full" "capturedSubject")"

      if [[ -z "$id_method" ]] || [[ "$id_method" == "none" ]]; then
        confidence="low"
        reasons+=("persona identity unverified: ${identity_rel} recorded method:none (the app exposes no probeable identity) — degrading confidence, not blocking (spec §5.5)")
      else
        local expected="" cs_lower expected_lower persona_lower matched=0
        expected="$(config_expected_subject_for "$persona")"
        cs_lower="$(to_lower "$id_subject")"

        if [[ -n "$expected" ]]; then
          # Operator-provided ground truth is configured — this is the ONLY
          # path allowed to OVERRIDE. Comparing a bare persona id to an
          # opaque captured subject is never confident enough on its own
          # (see the header comment's H3 fast-follow note); expectedSubject
          # removes that ambiguity.
          expected_lower="$(to_lower "$expected")"
          if str_contains "$cs_lower" "$expected_lower" || str_contains "$expected_lower" "$cs_lower"; then
            matched=1
          fi

          if [[ "$matched" -eq 1 ]]; then
            : # verified — captured identity matches the operator-configured expectedSubject.
          else
            override=1
            reasons+=("acting identity '${id_subject}' != expected identity '${expected}' for persona '${persona}' (${identity_rel}, from .qa/config.json's personas[].expectedSubject) — this pass was performed as the wrong user")
          fi
        else
          # No ground truth configured — a persona-id-vs-captured-subject
          # comparison is inherently unreliable (a legitimate numeric id, a
          # short hash, or a JWT `sub` claim is indistinguishable from a
          # genuine impersonation by this heuristic alone). Substring match
          # verifies; anything else DEGRADES — it must NEVER override,
          # because an override here has no operator-confirmed ground truth
          # behind it (that was the false-override bug: `admin` vs a
          # legitimate `42` used to hard-fail every such run).
          persona_lower="$(to_lower "$persona")"
          if str_contains "$cs_lower" "$persona_lower" || str_contains "$persona_lower" "$cs_lower"; then
            matched=1
          fi

          if [[ "$matched" -eq 1 ]]; then
            : # verified — best-effort substring match against the persona id.
          else
            confidence="low"
            reasons+=("persona identity unverified (no expectedSubject configured; captured subject '${id_subject}' could not be confidently matched to persona '${persona}')")
          fi
        fi
      fi
    fi
  elif { [[ -z "$persona" ]] || [[ "$persona" == "__shared__" ]]; } && is_high_stakes "$kinds_csv" "$row"; then
    local persona_count
    persona_count="$(config_persona_count)"
    if [[ "$persona_count" =~ ^[0-9]+$ ]] && [[ "$persona_count" -gt 1 ]]; then
      confidence="low"
      reasons+=("persona identity unverified: this run's .qa/config.json declares ${persona_count} personas (role-sensitivity is real for this target), but this high-stakes pass was checkpointed with NO --persona at all — identity-binding was never checked, not exempted (Appendix A tighten)")
    fi
  fi

  # --- Step 4 (part): reconcile verdict/confidence. -------------------------
  local verifier_verdict="pass"
  if [[ "$override" -eq 1 ]]; then
    verifier_verdict="fail"
    confidence="high"
  elif [[ "$no_toolstream_seen" -eq 1 ]]; then
    # QA_VERIFY_STRICT (opt-in, default unset — see header comment): a
    # high-stakes pass (requires human-action, or the checklist row is
    # tagged cross-tenant/cross-role-fk-chain) with no-toolstream provenance
    # is a toolstream-suppression risk (fabricate action-trace.json + rm the
    # toolstream -> lands on this exact degrade path). Under strict mode
    # that risk is OVERRIDDEN to fail instead of silently degraded. A
    # non-high-stakes no-toolstream pass (read-only/computed) is never
    # over-punished — it degrades in strict mode exactly as in default mode.
    local high_stakes=0
    is_high_stakes "$kinds_csv" "$row" && high_stakes=1

    if [[ -n "${QA_VERIFY_STRICT:-}" && "$high_stakes" -eq 1 ]]; then
      verifier_verdict="fail"
      confidence="high"
      reasons+=("strict mode: a human-action/cross-tenant pass with no captured toolstream cannot be corroborated (toolstream suppression risk) — QA_VERIFY_STRICT overriding to fail (.qa/runs/${run_id}/toolstream.jsonl absent)")
    else
      confidence="low"
      reasons+=("no toolstream captured for this run (.qa/runs/${run_id}/toolstream.jsonl absent) — capture-hook is opt-in; provenance could not be independently verified, so confidence is degraded (this is NOT an override — the run's other checks still verified)")
    fi
  fi

  # The pluggable re-drive stub — deliberately after reconciliation so it can
  # never influence verifier_verdict/confidence (see header comment).
  maybe_redrive "$run_id" "$crit_id" "$persona" "$kinds_csv"

  local reasons_json
  reasons_json="$(json_array_from_args ${reasons[@]+"${reasons[@]}"})"

  if has_jq; then
    jq -cn \
      --arg critId "$crit_id" --arg persona "$persona" \
      --arg inV "pass" --arg verV "$verifier_verdict" --arg conf "$confidence" \
      --argjson reasons "$reasons_json" \
      '{criterionId: $critId, persona: $persona, inRunVerdict: $inV, verifierVerdict: $verV, confidence: $conf, reasons: $reasons}'
  else
    python3 -c '
import json, sys
critId, persona, inV, verV, conf, reasonsJson = sys.argv[1:7]
print(json.dumps({
    "criterionId": critId, "persona": persona, "inRunVerdict": inV,
    "verifierVerdict": verV, "confidence": conf, "reasons": json.loads(reasonsJson)
}))
' "$crit_id" "$persona" "pass" "$verifier_verdict" "$confidence" "$reasons_json"
  fi
}

# rec_verdict <rec-json> -> stdout the record's .verifierVerdict field.
rec_verdict() {
  local rec="$1"
  if has_jq; then
    jq -r '.verifierVerdict' <<< "$rec"
  else
    python3 -c 'import json,sys; print(json.loads(sys.argv[1])["verifierVerdict"])' "$rec"
  fi
}

# build_error_record <crit-id> <persona> <detail> -> stdout ONE compact JSON
# verification record with verifierVerdict "error" (Appendix A: die()-in-
# subshell criterion loss). process_criterion is invoked inside a
# `rec_json="$(process_criterion ...)"` command substitution — a `die()`
# anywhere in its call chain (e.g. required-kinds.sh derive failing) only
# exits THAT SUBSHELL (this script runs under `set -uo pipefail`, no `-e`),
# so the assignment silently succeeds with an EMPTY rec_json and the
# criterion was previously dropped from verification.json with no trace —
# a run could report a false-clean exit even though one of its passes was
# never actually re-checked. Recording it as verifierVerdict "error" instead
# (a) makes it visible (report-to-junit.sh renders any non-"pass"
# verifierVerdict as a <failure>) and (b) flips qa-verify's own exit code,
# same as every other override — a lost criterion must never look like a
# clean run.
build_error_record() {
  local crit_id="$1" persona="$2" detail="$3"
  local reasons_json
  reasons_json="$(json_array_from_args "qa-verify internal error while re-checking this criterion: ${detail} — recorded as error rather than silently dropped")"
  if has_jq; then
    jq -cn \
      --arg critId "$crit_id" --arg persona "$persona" \
      --arg inV "pass" --arg verV "error" --arg conf "high" \
      --argjson reasons "$reasons_json" \
      '{criterionId: $critId, persona: $persona, inRunVerdict: $inV, verifierVerdict: $verV, confidence: $conf, reasons: $reasons}'
  else
    python3 -c '
import json, sys
critId, persona, inV, verV, conf, reasonsJson = sys.argv[1:7]
print(json.dumps({
    "criterionId": critId, "persona": persona, "inRunVerdict": inV,
    "verifierVerdict": verV, "confidence": conf, "reasons": json.loads(reasonsJson)
}))
' "$crit_id" "$persona" "pass" "error" "high" "$reasons_json"
  fi
}

# ---------------------------------------------------------------------------
# RUN-SCOPED CHECKS PASS (plan 2026-09-23-error-honesty-invariants Task 8,
# spec §5.5). A THIRD pass, independent of both the per-criterion pass-record
# loop and the phase-surface pass. See the header comment's "RUN-SCOPED
# CHECKS PASS" section for the full rationale.
# ---------------------------------------------------------------------------

known_defects_file() { echo ".qa/known-defects.json"; }
qa_config_file() { echo ".qa/config.json"; }

to_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# nmsg_bash <text> -> the message normalization the findings ledger's
# `nmsg` performs (fold.jq:85 / fold.py mirror): runs of ASCII whitespace
# collapse to one space, one leading and one trailing space are trimmed, the
# result is cut to 200 characters and re-trimmed. Implemented ONCE, in bash,
# deliberately: both sides of this pass's comparison (a journaled
# `finding_observed` message and a console entry recomputed from the
# toolstream) go through THIS function, so the two can never disagree with
# each other, whatever either JSON engine would have done.
nmsg_bash() {
  local s
  s="$(printf '%s' "$1" | tr '\t\n\r\013\014' '     ' | tr -s ' ')"
  s="${s# }"; s="${s% }"
  s="${s:0:200}"
  s="${s# }"; s="${s% }"
  printf '%s' "$s"
}

# net_ident <method> <url> <url-len> <status> -> the run-scoped identity of
# one network observation, in the findings ledger's own key space MINUS its
# `criterionId` component:
#     net|<METHOD>|<url capped at 1024>[#<full length>]|<status>
#
# THE TWO DELIBERATE DIFFERENCES FROM fold.jq's finding_key, both of which
# only ever make this check MORE conservative (fewer overrides, never more):
#
#   1. `criterionId` IS EXCLUDED. Neither independent channel records which
#      criterion was under test when a request was issued — a HAR row and a
#      __qaObserve payload carry no criterion at all — so a key including it
#      could never be recomputed. Excluding it means a finding journaled
#      against the WRONG criterion still counts as journaled. That is the
#      right trade: a mis-attributed finding is visible in the report, while
#      a DROPPED one is exactly the failure this plan exists to remove, and
#      attributing an observation to a criterion would need an act/phase
#      correlation this pass does not have.
#   2. `method` is UPPERCASED. HTTP methods are case-insensitive; a HAR
#      records `GET` while observe.js records whatever `init.method` held,
#      which may be `get`. Comparing them verbatim would manufacture a
#      missing finding out of a letter case.
#
# Everything else is the ledger's contract verbatim, and relied upon rather
# than re-derived: the url is capped at 1024 characters and, WHEN AND ONLY
# WHEN its full length exceeds that cap, "#<full length>" is appended. The
# full length prefers an emitter-supplied `urlLen`, which is what makes the
# identity CAPPING-INVARIANT — the driver log carries the untruncated url,
# the journal carries the capped url plus `urlLen`, and both land on the
# same string.
net_ident() {
  local method="$1" url="$2" ulen="$3" status="$4" capped
  case "$ulen" in
    ''|*[!0-9]*) ulen="${#url}" ;;
  esac
  capped="${url:0:1024}"
  if [[ "$ulen" -gt 1024 ]]; then
    printf 'net|%s|%s#%s|%s' "$(to_upper "$method")" "$capped" "$ulen" "$status"
  else
    printf 'net|%s|%s|%s' "$(to_upper "$method")" "$capped" "$status"
  fi
}

# net_prefix <method> <url> <status> -> a SECONDARY, coarser identity keyed
# on the url's first 300 characters.
#
# WHY IT EXISTS: observe.js:109/126 slices every recorded url to 300
# characters and supplies NO `urlLen`, so an IN-PAGE observation of a
# 500-byte url is genuinely shorter than the driver log's record of the same
# request, and net_ident's capping-invariance — which relies on `urlLen` —
# has nothing to work with. Without this fallback, one request seen by both
# channels and journaled ONCE would be reported as a dropped finding, a
# false override.
#
# IT IS DELIBERATELY NARROW, and the narrowness is load-bearing. The
# fallback is consulted ONLY for an observation from the TOOLSTREAM channel
# whose recorded url is at least 300 characters long — i.e. only where
# observe.js could actually have sliced it. Applied to DRIVER-LOG rows it
# would swallow net_ident entirely: a driver url is never sliced, so the
# journal's capped form and the log's full form always share their first 300
# characters, and a coarse prefix match would then absorb every divergence
# net_ident exists to catch (including two distinct >1024-character urls
# that differ only after the cap). A survived mutation found exactly that:
# with the fallback unscoped, ignoring `urlLen` altogether changed nothing
# any test could see. Scoping it restores the distinction.
#
# UPSTREAM RESIDUAL, not fixable here: two distinct urls of >=300 characters
# that share their first 300, seen only IN-PAGE, are indistinguishable in
# observe.js's own payload — it records neither the remainder nor a length.
# Journalling one of them therefore absorbs the other. Closing that needs
# `urlLen` from observe.js, not a different comparison in this script.
net_prefix() {
  printf 'net|%s|%s|%s' "$(to_upper "$1")" "${2:0:300}" "$3"
}

# console_ident <text> -> the identity of one console finding. The ledger
# keys a console finding on its normalized message (fold.jq's finding_key:
# `source == "console"` sets method/url to "" and the url component carries
# nmsg(message)), so the same normalization is all that is needed here.
console_ident() { printf 'console|%s' "$(nmsg_bash "$1")"; }

# set_contains <newline-delimited-set> <member> -> exit 0 iff present.
# grep -F -x -- so a member containing regex metacharacters, a leading `-`,
# or a `|` is matched literally and in full. An EMPTY member is never a
# member (a bare `grep -Fxq ""` matches every line).
set_contains() {
  [[ -n "$2" ]] || return 1
  printf '%s\n' "$1" | grep -Fxq -- "$2"
}

# ---------------------------------------------------------------------------
# network_log_file <run-id> -> stdout the resolved driver network log path,
# or nothing. MIRRORS session-preflight.sh's resolve_session_log contract:
# QA_NETWORK_LOG wins when it names an existing file and, being an explicit
# setting, NEVER falls back; otherwise the run's own
# .qa/runs/<run-id>/network-log.json; otherwise any *.har under
# .playwright-mcp/ (the --output-dir every harness profile already uses).
# Resolution tests for EXISTENCE, not for non-emptiness: a zero-byte log is
# a resolved channel that happens to carry nothing, which is a different
# fact from no channel at all, and this pass has to keep the two apart.
# Pure-bash globbing (no ls/head) so it stays honest under a restricted PATH.
# ---------------------------------------------------------------------------
network_log_file() {
  local run_id="$1" candidate
  if [[ -n "${QA_NETWORK_LOG:-}" ]]; then
    [[ -f "$QA_NETWORK_LOG" ]] && echo "$QA_NETWORK_LOG"
    return 0
  fi
  candidate="$(run_dir "$run_id")/network-log.json"
  if [[ -f "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi
  for candidate in .playwright-mcp/*.har; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# driver_rows <log-file> -> stdout: a FIRST line that is either `usable` or
# `unusable`, then SIX LINES PER ROW: kind("net"), method, url, status,
# text(""), type.
#
# Accepts two container shapes and nothing else: a flat JSON array of
# {method,url,status[,type]} request records, or a HAR
# ({log:{entries:[{request:{method,url},response:{status}}]}}). Any other
# container — a JSON object that is not a HAR, `null`, `false`, a number, a
# string, concatenated JSON documents, an empty file, or text that is not
# JSON at all — is `unusable`: NO ROWS, no reasons that could fail the run,
# and the absence is recorded rather than punished (spec §5.5: distinguish
# no evidence from contradicted evidence). A row is DROPPED unless its url
# is a NON-EMPTY string and its status is an integer — a type check alone
# ("url is a string") let an empty url through in a Wave-1 Critical.
#
# SIX LINES PER ROW, never a delimited single line: `IFS=$'\t' read`
# collapses runs of tab and strips leading/trailing ones, so a row with an
# empty field silently shifts every column left (see list_pass_records'
# comment for the same bug caught in this suite before). Line framing is
# safe because the extractor replaces LF and CR in every emitted string
# with a space — done by split/join and str.replace rather than a regex, so
# the two engines cannot diverge on a character class.
# ---------------------------------------------------------------------------
driver_rows() {
  local f="$1"
  if has_jq; then
    jq -n -r --rawfile raw "$f" '
      def sane: if type == "string" then ((. / "\n") | join(" ")) | ((. / "\r") | join(" ")) else "" end;
      def istr($v): ($v | type) == "string" and ($v | length) > 0;
      def inum($v): ($v | type) == "number" and ($v == ($v | floor))
                    and $v > -1000000000000000 and $v < 1000000000000000;
      def row($m; $u; $s; $ty): "net", ($m | sane), ($u | sane), ($s | floor | tostring), "", ($ty | sane);
      ($raw | try fromjson catch null) as $d
      | if ($d | type) == "array" then
          "usable",
          ( $d[]
            | select((type) == "object")
            | select(istr(.url) and inum(.status))
            | row(.method; .url; .status; (.type // ._resourceType // .resourceType // "")) )
        elif ($d | type) == "object" and (($d.log | type) == "object")
             and (($d.log.entries | type) == "array") then
          "usable",
          ( $d.log.entries[]
            | select((type) == "object" and ((.request | type) == "object") and ((.response | type) == "object"))
            | select(istr(.request.url) and inum(.response.status))
            | row(.request.method; .request.url; .response.status; (._resourceType // .resourceType // "")) )
        else "unusable" end
    ' 2>/dev/null || echo "unusable"
  else
    python3 -c '
import json, sys

def sane(v):
    if not isinstance(v, str):
        return ""
    return v.replace("\n", " ").replace("\r", " ")

def istr(v):
    return isinstance(v, str) and len(v) > 0

def inum(v):
    return isinstance(v, int) and not isinstance(v, bool) and -1000000000000000 < v < 1000000000000000

def fnum(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return False
    return v == int(v) and -1000000000000000 < v < 1000000000000000

out = []
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    print("unusable")
    sys.exit(0)

def row(m, u, s, ty):
    out.extend(["net", sane(m), sane(u), str(int(s)), "", sane(ty)])

if isinstance(d, list):
    for e in d:
        if not isinstance(e, dict):
            continue
        if not (istr(e.get("url")) and fnum(e.get("status"))):
            continue
        ty = e.get("type")
        if not isinstance(ty, str):
            ty = e.get("_resourceType")
        if not isinstance(ty, str):
            ty = e.get("resourceType")
        row(e.get("method"), e.get("url"), e.get("status"), ty)
elif isinstance(d, dict) and isinstance(d.get("log"), dict) and isinstance(d["log"].get("entries"), list):
    for e in d["log"]["entries"]:
        if not isinstance(e, dict) or not isinstance(e.get("request"), dict) or not isinstance(e.get("response"), dict):
            continue
        if not (istr(e["request"].get("url")) and fnum(e["response"].get("status"))):
            continue
        ty = e.get("_resourceType")
        if not isinstance(ty, str):
            ty = e.get("resourceType")
        row(e["request"].get("method"), e["request"].get("url"), e["response"].get("status"), ty)
else:
    print("unusable")
    sys.exit(0)

print("usable")
for line in out:
    print(line)
' "$f" 2>/dev/null || echo "unusable"
  fi
}

# ---------------------------------------------------------------------------
# observe_rows <run-id> -> stdout SIX LINES PER ROW, same framing as
# driver_rows: kind("net"|"console"), method, url, status, text, type("").
#
# Channel 1, in-page interception. Reads each toolstream line's
# `responseBody`; when that string itself parses as a JSON object carrying
# `network[]` / `console[]` it is an __qaObserve payload, and when it parses
# as a JSON ARRAY of request records it is a browser_network_requests
# result. Anything else is ignored — including a responseBody truncated by
# capture-hook.sh's 4000-byte cap, which simply fails to parse and
# contributes nothing. That loss is the cap's documented, accepted cost
# (spec §11.1) and it can only ever HIDE a required finding, never invent
# one, so it degrades this check rather than breaking it.
#
# Only `level == "error"` console entries are emitted. observe.js buffers
# `error` and `warn`; a warning is not an observed error, and invariant I1
# is about errors.
# ---------------------------------------------------------------------------
observe_rows() {
  local f
  f="$(toolstream_file_for "$1")"
  [[ -f "$f" ]] || return 0
  if has_jq; then
    jq -R -r '
      def sane: if type == "string" then ((. / "\n") | join(" ")) | ((. / "\r") | join(" ")) else "" end;
      def istr($v): ($v | type) == "string" and ($v | length) > 0;
      def inum($v): ($v | type) == "number" and ($v == ($v | floor))
                    and $v > -1000000000000000 and $v < 1000000000000000;
      def netrow: "net", (.method | sane), (.url | sane), (.status | floor | tostring), "", "";
      def conrow: "console", "", "", "", (.text | sane), "";
      (try fromjson catch null) as $o
      | if ($o | type) != "object" then empty
        else
          ( if ($o.responseBody | type) == "string"
            then ($o.responseBody | try fromjson catch null)
            else null end ) as $b
          | if ($b | type) == "object" then
              ( ( if ($b.network | type) == "array" then $b.network[] else empty end )
                | select((type) == "object") | select(istr(.url) and inum(.status)) | netrow ),
              ( ( if ($b.console | type) == "array" then $b.console[] else empty end )
                | select((type) == "object") | select(.level == "error") | select(istr(.text)) | conrow )
            elif ($b | type) == "array" then
              ( $b[] | select((type) == "object") | select(istr(.url) and inum(.status)) | netrow )
            else empty end
        end
    ' "$f" 2>/dev/null || true
  else
    python3 -c '
import json, sys

def sane(v):
    if not isinstance(v, str):
        return ""
    return v.replace("\n", " ").replace("\r", " ")

def istr(v):
    return isinstance(v, str) and len(v) > 0

def fnum(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return False
    return v == int(v) and -1000000000000000 < v < 1000000000000000

out = []

def netrow(e):
    out.extend(["net", sane(e.get("method")), sane(e.get("url")), str(int(e["status"])), "", ""])

def conrow(e):
    out.extend(["console", "", "", "", sane(e.get("text")), ""])

with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        rb = o.get("responseBody")
        b = None
        if isinstance(rb, str):
            try:
                b = json.loads(rb)
            except Exception:
                b = None
        if isinstance(b, dict):
            net = b.get("network")
            if isinstance(net, list):
                for e in net:
                    if isinstance(e, dict) and istr(e.get("url")) and fnum(e.get("status")):
                        netrow(e)
            con = b.get("console")
            if isinstance(con, list):
                for e in con:
                    if isinstance(e, dict) and e.get("level") == "error" and istr(e.get("text")):
                        conrow(e)
        elif isinstance(b, list):
            for e in b:
                if isinstance(e, dict) and istr(e.get("url")) and fnum(e.get("status")):
                    netrow(e)

for line in out:
    print(line)
' "$f" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# journal_finding_rows <run-id> -> stdout EIGHT LINES PER `finding_observed`
# event: source, method, url, urlLen(decimal or ""), status, originClass,
# statusClass, message.
#
# The agent's LEDGER CLAIM, read straight off journal.ndjson. Every field
# goes through the ledger's own `kstr` projection (string as-is; an integral
# number within +/-1e15 as its decimal form; anything else — null, absent,
# boolean, non-integral number, object, array — as ""), so a
# non-string/non-number field can never travel into an identity or a reason.
# A torn or unparseable line is skipped, exactly as fold.sh skips it; the
# events AFTER it are still read (a torn write must not hide the findings
# that follow it).
# ---------------------------------------------------------------------------
journal_finding_rows() {
  local f
  f="$(journal_file "$1")"
  [[ -f "$f" ]] || return 0
  if has_jq; then
    jq -R -r '
      def sane: if type == "string" then ((. / "\n") | join(" ")) | ((. / "\r") | join(" ")) else "" end;
      def kstr($v): if ($v | type) == "string" then $v
                    elif ($v | type) == "number" and ($v == ($v | floor))
                         and $v > -1000000000000000 and $v < 1000000000000000
                      then ($v | floor | tostring)
                    else "" end;
      (try fromjson catch null) as $o
      | if ($o | type) == "object" and ($o.event == "finding_observed") then
          (kstr($o.source) | sane),
          (kstr($o.method) | sane),
          (kstr($o.url) | sane),
          ( if ($o.urlLen | type) == "number" and ($o.urlLen == ($o.urlLen | floor))
               and ($o.urlLen) >= 0 and ($o.urlLen) < 1000000000000000
            then ($o.urlLen | floor | tostring) else "" end ),
          (kstr($o.status) | sane),
          (kstr($o.originClass) | sane),
          (kstr($o.statusClass) | sane),
          (kstr($o.message) | sane)
        else empty end
    ' "$f" 2>/dev/null || true
  else
    python3 -c '
import json, sys

def sane(v):
    return v.replace("\n", " ").replace("\r", " ")

def kstr(v):
    if isinstance(v, str):
        return v
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return ""
    if v != int(v) or not (-1000000000000000 < v < 1000000000000000):
        return ""
    return str(int(v))

def ulen(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return ""
    if v != int(v) or not (0 <= v < 1000000000000000):
        return ""
    return str(int(v))

out = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict) or o.get("event") != "finding_observed":
            continue
        out.extend([
            sane(kstr(o.get("source"))),
            sane(kstr(o.get("method"))),
            sane(kstr(o.get("url"))),
            ulen(o.get("urlLen")),
            sane(kstr(o.get("status"))),
            sane(kstr(o.get("originClass"))),
            sane(kstr(o.get("statusClass"))),
            sane(kstr(o.get("message"))),
        ])
for line in out:
    print(line)
' "$f" 2>/dev/null || true
  fi
}

# tool_sequence <run-id> -> stdout the ORDERED `tool` value of every
# toolstream line, one per line. The load-window check needs nothing else:
# `responseBody` is truncated at 4000 bytes by capture-hook.sh:308 and
# written as `null` unconditionally by session-to-toolstream.js:119 on three
# of the four harnesses, so a check that read it would be unreliable on most
# runs; the `tool` sequence is not (spec §11.1/§11.4).
tool_sequence() {
  local f
  f="$(toolstream_file_for "$1")"
  [[ -f "$f" ]] || return 0
  if has_jq; then
    jq -R -r '
      (try fromjson catch null) as $o
      | if ($o | type) == "object" and (($o.tool | type) == "string")
        then ($o.tool | ((. / "\n") | join(" ")) | ((. / "\r") | join(" ")))
        else empty end
    ' "$f" 2>/dev/null || true
  else
    python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if isinstance(o, dict) and isinstance(o.get("tool"), str):
            print(o["tool"].replace("\n", " ").replace("\r", " "))
' "$f" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# load_window_reasons <run-id> -> one reason line per UNCOVERED navigation.
#
# CHECK 3 (I5/R9). A `browser_navigate` must be followed by a
# `browser_network_requests` before the next navigation. This is the check
# that closes the blind spot where a navigation-time 500 lives: that 500 IS
# the document request, issued by the browser's navigation machinery rather
# than by fetch/XHR, and no script runs on a 500 page — so `__qaObserve` can
# never see it, structurally, and only the driver-backed
# browser_network_requests can (spec §5.4, §11.3).
#
# The trailing navigation counts: a run whose LAST navigation was never read
# back has exactly the blind spot this check exists to close, so end-of-
# stream is not a free pass.
#
# `*browser_navigate` as a case pattern matches a bare tool name and an
# MCP-prefixed one alike, and does NOT match `browser_navigate_back`
# (the string does not end in `browser_navigate`). DOCUMENTED RESIDUAL:
# browser_navigate_back is neither required to be read back nor treated as a
# window boundary. It replays history rather than driving a fresh
# navigation, and the driver's own network log is cumulative, so counting it
# would add false failures without closing a hole.
# ---------------------------------------------------------------------------
load_window_reasons() {
  local run_id="$1" i j n covered t
  local -a tools=()
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    tools[${#tools[@]}]="$t"
  done < <(tool_sequence "$run_id")
  n=${#tools[@]}
  i=0
  while [[ "$i" -lt "$n" ]]; do
    case "${tools[$i]}" in
      *browser_navigate)
        covered=0
        j=$((i + 1))
        while [[ "$j" -lt "$n" ]]; do
          case "${tools[$j]}" in
            *browser_navigate) break ;;
            *browser_network_requests) covered=1; break ;;
          esac
          j=$((j + 1))
        done
        if [[ "$covered" -eq 0 ]]; then
          echo "load-window coverage: the browser_navigate at toolstream position $((i + 1)) is not followed by a browser_network_requests before the next navigation (or before the end of the run) — the load window in which a navigation-time 5xx lives was never read back"
        fi
        ;;
    esac
    i=$((i + 1))
  done
}

# classify_one <config> <url> <status> -> sets CF_ORIGIN / CF_STATUS from
# classify-finding.sh, reused verbatim. Exit non-zero when the script could
# not be run at all or printed neither line.
CF_ORIGIN=""; CF_STATUS=""
classify_one() {
  local out line
  CF_ORIGIN=""; CF_STATUS=""
  out="$(bash "$CLASSIFY_FINDING_SH" "$1" "$2" "$3" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in
      originClass=*) CF_ORIGIN="${line#originClass=}" ;;
      statusClass=*) CF_STATUS="${line#statusClass=}" ;;
    esac
  done <<< "$out"
  [[ -n "$CF_ORIGIN" && -n "$CF_STATUS" ]]
}

# enc_nav <url> <status-digits> / enc_finding <url> <statusClass>
# <status-digits-or-empty> -> ONE compact JSON object for the known-defects
# evidence document. The exact ratified evidence shape (known-defects.sh's
# "EVIDENCE SHAPE" block) is
#   {navigations:[{url,status}], findings:[{url,statusClass,status}]}
# and it is produced here verbatim — never a locally invented variant.
# `--argjson` is fed ONLY a bash-validated run of digits, never the output
# of a jq filter that could emit more than one document.
enc_nav() {
  if has_jq; then
    jq -cn --arg u "$1" --argjson s "$2" '{url: $u, status: $s}'
  else
    python3 -c '
import json, sys
print(json.dumps({"url": sys.argv[1], "status": int(sys.argv[2])}, separators=(",", ":")))
' "$1" "$2"
  fi
}
enc_finding() {
  if [[ -n "$3" ]]; then
    if has_jq; then
      jq -cn --arg u "$1" --arg c "$2" --argjson s "$3" '{url: $u, statusClass: $c, status: $s}'
    else
      python3 -c '
import json, sys
print(json.dumps({"url": sys.argv[1], "statusClass": sys.argv[2], "status": int(sys.argv[3])}, separators=(",", ":")))
' "$1" "$2" "$3"
    fi
  else
    if has_jq; then
      jq -cn --arg u "$1" --arg c "$2" '{url: $u, statusClass: $c}'
    else
      python3 -c '
import json, sys
print(json.dumps({"url": sys.argv[1], "statusClass": sys.argv[2]}, separators=(",", ":")))
' "$1" "$2"
    fi
  fi
}

# REASON_CAP / reason_add — the run-scoped pass appends one reason per finding
# it has something to say about, and a run can legitimately observe hundreds.
# TWO things break at that scale, and the cap closes both: verification.json
# grows unboundedly, and `json_array_from_args` passes every reason as a
# POSITIONAL ARGUMENT to jq/python3, so a long enough list exceeds ARG_MAX,
# the builder fails, and the whole record is lost. The booleans, not the
# prose, are what this pass is authoritative about, so the prose is what
# gets bounded. reason_add relies on bash dynamic scoping to append to its
# caller's `reasons` array (bash 3.2-safe; no nameref).
REASON_CAP=100
reason_add() {
  if [[ "${#reasons[@]}" -lt "$REASON_CAP" ]]; then
    reasons[${#reasons[@]}]="$1"
  elif [[ "${#reasons[@]}" -eq "$REASON_CAP" ]]; then
    reasons[${#reasons[@]}]="run-scoped checks: reason list truncated at ${REASON_CAP} entries — further reasons were suppressed to keep verification.json and this pass's own argument list bounded; the runChecks booleans are unaffected and remain authoritative"
  fi
}

# compact_one_json <text> -> the text re-serialized as EXACTLY ONE compact
# JSON document, or nothing when it is not exactly one. The `--argjson` trap:
# three separate lanes of this plan broke on feeding `--argjson` a value that
# could be more than one document, so every value that reaches `--argjson`
# below is gated through here (or built from bash-validated digits) first.
compact_one_json() {
  if has_jq; then
    jq -c -s -e 'if length == 1 then .[0] else error("not exactly one document") end' <<< "$1" 2>/dev/null
  else
    python3 -c '
import json, sys
print(json.dumps(json.loads(sys.argv[1]), separators=(",", ":")))
' "$1" 2>/dev/null
  fi
}

# kd_expired_ids <status-json> -> stdout one id per `expired` entry.
kd_expired_ids() {
  if has_jq; then
    jq -r 'if type == "array" then (.[] | select((type) == "object" and .state == "expired") | (.id | tostring)) else empty end' <<< "$1" 2>/dev/null || true
  else
    python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if isinstance(d, list):
    for e in d:
        if isinstance(e, dict) and e.get("state") == "expired":
            print(str(e.get("id")))
' "$1" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# run_run_checks_pass <run-id> -> stdout ONE compact JSON verification
# record (the synthetic "__run-checks__" run-level record), or nothing.
#
# Unlike "__phase-surface__", this record DOES flip qa-verify's exit code:
# its four checks are structural proofs about the run's own record, not
# best-effort temporal correlation, and the incident this plan exists
# because of is precisely a run that exited 0 while its record said 500.
#
# WHEN THE RECORD IS EMITTED: whenever any of the four checks is false, OR
# whenever the run carried FINDINGS EVIDENCE to evaluate at all (a resolved
# driver network log, a parsed __qaObserve payload, a journaled
# finding_observed event, or a known-defect registry). A run with none of
# those gains NO record — which is what keeps every pre-existing qa-verify
# fixture byte-identical, and is honest: there is nothing to report about
# checks that had nothing to check.
# ---------------------------------------------------------------------------
run_run_checks_pass() {
  local run_id="$1"
  local ledger_ok="true" class_ok="true" window_ok="true" kd_ok="true"
  local -a reasons=()
  local channel_driver=0 channel_toolstream=0 has_evidence=0
  local cfg cfg_tmp="" netlog="" today
  local jidents="" jprefixes="" seen_required=""
  local line

  # --- the config classify-finding.sh classifies against. An absent
  # .qa/config.json is not an error: classify-finding is fail-closed for an
  # unknowable origin, and `{}` yields exactly that (no baseUrl -> in-scope),
  # so a run with no config over-reports rather than under-reports. ---
  cfg="$(qa_config_file)"
  if [[ ! -f "$cfg" ]]; then
    cfg_tmp="$(mktemp)" || cfg_tmp=""
    if [[ -n "$cfg_tmp" ]]; then
      printf '%s' '{}' > "$cfg_tmp"
      cfg="$cfg_tmp"
    fi
  fi

  # --- CHECK 3: load-window coverage. Evaluated first because it needs
  # neither channel — only the ordered `tool` sequence. ---
  if has_toolstream "$run_id"; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      window_ok="false"
      reason_add "$line"
    done < <(load_window_reasons "$run_id")
  fi

  # --- the agent's ledger claim ---
  local j_source j_method j_url j_ulen j_status j_origin j_statusclass j_message
  local j_ident j_prefix j_count=0
  while IFS= read -r j_source; do
    IFS= read -r j_method   || break
    IFS= read -r j_url      || break
    IFS= read -r j_ulen     || break
    IFS= read -r j_status   || break
    IFS= read -r j_origin   || break
    IFS= read -r j_statusclass || break
    IFS= read -r j_message  || break
    j_count=$((j_count + 1))

    if [[ "$j_source" == "console" ]]; then
      j_ident="$(console_ident "$j_message")"
      j_prefix=""
    else
      j_ident="$(net_ident "$j_method" "$j_url" "$j_ulen" "$j_status")"
      j_prefix="$(net_prefix "$j_method" "$j_url" "$j_status")"
    fi
    jidents="${jidents}${j_ident}
"
    [[ -n "$j_prefix" ]] && jprefixes="${jprefixes}${j_prefix}
"

    # --- CHECK 2: classification re-check. An agent must not be able to
    # mis-class a 500 by writing a journal event that says otherwise. Only a
    # CLAIMED class can be contradicted: an event carrying neither
    # originClass nor statusClass claims nothing, so there is nothing to
    # re-check, and silence is never an override. ---
    if [[ -n "$j_origin" || -n "$j_statusclass" ]]; then
      if classify_one "$cfg" "$j_url" "$j_status"; then
        # A url whose FULL length exceeded the ledger's 1024-character cap
        # cannot be re-classified faithfully — its path, and therefore the
        # findings.benign match, may have been cut off. The absence of a
        # trustworthy input is recorded; statusClass, which depends on the
        # status alone, is still re-checked.
        local origin_checkable=1
        case "$j_ulen" in
          ''|*[!0-9]*) : ;;
          *) [[ "$j_ulen" -gt 1024 ]] && origin_checkable=0 ;;
        esac
        if [[ "$origin_checkable" -eq 0 ]]; then
          reason_add "classification re-check: finding ${j_ident} carries a url truncated at the ledger cap (urlLen=${j_ulen}), so its originClass could not be independently recomputed — recorded, not overridden"
        elif [[ -n "$j_origin" && "$j_origin" != "$CF_ORIGIN" ]]; then
          class_ok="false"
          reason_add "classification re-check: finding ${j_ident} was journaled as originClass=${j_origin} but classify-finding.sh recomputes originClass=${CF_ORIGIN}"
        fi
        if [[ -n "$j_statusclass" && "$j_statusclass" != "$CF_STATUS" ]]; then
          class_ok="false"
          reason_add "classification re-check: finding ${j_ident} was journaled as statusClass=${j_statusclass} but classify-finding.sh recomputes statusClass=${CF_STATUS}"
        fi
      else
        reason_add "classification re-check: classify-finding.sh could not classify finding ${j_ident} — recorded, not overridden (no recomputed class to compare against)"
      fi
    fi
  done < <(journal_finding_rows "$run_id")
  [[ "$j_count" -gt 0 ]] && has_evidence=1

  # --- the independent channels ---
  netlog="$(network_log_file "$run_id")"
  local -a obs_kind=() obs_method=() obs_url=() obs_status=() obs_text=() obs_type=() obs_chan=()
  local r_kind r_method r_url r_status r_text r_type

  if [[ -n "$netlog" ]]; then
    has_evidence=1
    local first_line="" got_first=0
    while IFS= read -r r_kind; do
      if [[ "$got_first" -eq 0 ]]; then
        first_line="$r_kind"; got_first=1
        [[ "$first_line" == "usable" ]] || break
        continue
      fi
      IFS= read -r r_method || break
      IFS= read -r r_url    || break
      IFS= read -r r_status || break
      IFS= read -r r_text   || break
      IFS= read -r r_type   || break
      obs_kind[${#obs_kind[@]}]="$r_kind"
      obs_method[${#obs_method[@]}]="$r_method"
      obs_url[${#obs_url[@]}]="$r_url"
      obs_status[${#obs_status[@]}]="$r_status"
      obs_text[${#obs_text[@]}]="$r_text"
      obs_type[${#obs_type[@]}]="$r_type"
      obs_chan[${#obs_chan[@]}]="driver-log"
    done < <(driver_rows "$netlog")
    if [[ "$first_line" == "usable" ]]; then
      channel_driver=1
    else
      reason_add "ledger completeness: the driver network log ${netlog} is not a usable request record (expected a JSON array of request objects or a HAR) — recorded as an absent channel, never an override"
    fi
  fi

  local driver_count=${#obs_kind[@]}
  while IFS= read -r r_kind; do
    IFS= read -r r_method || break
    IFS= read -r r_url    || break
    IFS= read -r r_status || break
    IFS= read -r r_text   || break
    IFS= read -r r_type   || break
    obs_kind[${#obs_kind[@]}]="$r_kind"
    obs_method[${#obs_method[@]}]="$r_method"
    obs_url[${#obs_url[@]}]="$r_url"
    obs_status[${#obs_status[@]}]="$r_status"
    obs_text[${#obs_text[@]}]="$r_text"
    obs_type[${#obs_type[@]}]="$r_type"
    obs_chan[${#obs_chan[@]}]="toolstream"
  done < <(observe_rows "$run_id")
  if [[ ${#obs_kind[@]} -gt "$driver_count" ]]; then
    channel_toolstream=1
    has_evidence=1
  fi

  # --- CHECK 1: ledger completeness. An observation that is REQUIRED to be
  # journaled and is not is a dropped-error signal -> override the run.
  #
  # REQUIRED means, for a network observation, classify-finding.sh returning
  # originClass=in-scope AND statusClass=fatal, and for a console
  # observation, an `error`-level entry. A third-party or benign 5xx is NOT
  # required (that is what the classifier is for — failing a run on
  # analytics/CDN/extension noise is the false-positive class this design
  # exists to avoid), and an in-scope 3xx/4xx is recorded but never required
  # (decision R1: observe.js's isOkStatus is 2xx-only, so requiring every
  # non-2xx would fail the spec's own authz criteria).
  #
  # The `status >= 500` pre-filter below is an OPTIMIZATION ONLY, and a
  # superset-preserving one: classify-finding.sh calls nothing else fatal
  # for a numeric status, so filtering cannot drop a required finding. The
  # classifier remains the authority for every row that survives it. ---
  local idx=0 total=${#obs_kind[@]} k m u s tx ch ident prefix
  while [[ "$idx" -lt "$total" ]]; do
    k="${obs_kind[$idx]}"; m="${obs_method[$idx]}"; u="${obs_url[$idx]}"
    s="${obs_status[$idx]}"; tx="${obs_text[$idx]}"; ch="${obs_chan[$idx]}"
    idx=$((idx + 1))
    if [[ "$k" == "console" ]]; then
      [[ -z "$tx" ]] && continue
      ident="$(console_ident "$tx")"
      set_contains "$seen_required" "$ident" && continue
      seen_required="${seen_required}${ident}
"
      if ! set_contains "$jidents" "$ident"; then
        ledger_ok="false"
        reason_add "ledger completeness: a console error observed in the toolstream is absent from the findings journal — \"$(nmsg_bash "$tx")\" (identity ${ident})"
      fi
      continue
    fi
    case "$s" in
      ''|*[!0-9]*) continue ;;
    esac
    [[ "$s" -lt 500 ]] && continue
    ident="$(net_ident "$m" "$u" "" "$s")"
    prefix="$(net_prefix "$m" "$u" "$s")"
    set_contains "$seen_required" "$ident" && continue
    seen_required="${seen_required}${ident}
"
    if classify_one "$cfg" "$u" "$s"; then
      :
    else
      CF_ORIGIN="in-scope"; CF_STATUS="fatal"
      reason_add "ledger completeness: classify-finding.sh could not classify the observed ${m} ${u} status=${s} — failing closed to originClass=in-scope statusClass=fatal"
    fi
    [[ "$CF_ORIGIN" == "in-scope" && "$CF_STATUS" == "fatal" ]] || continue
    if set_contains "$jidents" "$ident"; then continue; fi
    # The coarse 300-character fallback, ONLY for an in-page observation long
    # enough to have been sliced by observe.js. See net_prefix.
    if [[ "$ch" == "toolstream" && "${#u}" -ge 300 ]] && set_contains "$jprefixes" "$prefix"; then
      continue
    fi
    ledger_ok="false"
    reason_add "ledger completeness: an observed finding is absent from the findings journal — ${m} ${u} status=${s} (originClass=${CF_ORIGIN} statusClass=${CF_STATUS}); identity ${ident}"
  done

  # --- channel -------------------------------------------------------------
  local channel="none"
  if [[ "$channel_driver" -eq 1 && "$channel_toolstream" -eq 1 ]]; then
    channel="both"
  elif [[ "$channel_driver" -eq 1 ]]; then
    channel="driver-log"
  elif [[ "$channel_toolstream" -eq 1 ]]; then
    channel="toolstream"
  fi
  if [[ "$channel" == "none" ]]; then
    reason_add "ledger completeness: no independent findings channel is available for this run (no usable driver network log resolved and no __qaObserve payload recoverable from the toolstream) — the ledger could be neither confirmed nor contradicted, so the absence is recorded and the run is NOT failed for it (spec §5.5; Task 10 turns the absence into UNVERIFIED)"
  fi

  # --- CHECK 4: known-defect gate -----------------------------------------
  local reg kd_json="[]"
  reg="$(known_defects_file)"
  if [[ -f "$reg" ]]; then
    has_evidence=1
    today="$(date -u +%Y-%m-%d)"

    local vout vrc
    vout="$(bash "$KNOWN_DEFECTS_SH" validate "$reg" "$today" 2>&1 >/dev/null)"; vrc=$?
    if [[ "$vrc" -ne 0 ]]; then
      kd_ok="false"
      if [[ -n "$vout" ]]; then
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          reason_add "known-defect registry: ${line}"
        done <<< "$vout"
      else
        reason_add "known-defect registry: known-defects.sh validate exited ${vrc} for ${reg} with no diagnostic output"
      fi
    fi

    # Evidence, in the ratified shape. `navigations` are DOCUMENT requests
    # only: a log that records no resource type contributes no navigations,
    # so nothing clears — the same burden-of-proof direction decision R4
    # already mandates (absence of a finding never clears anything).
    local navs="" finds="" obj
    idx=0
    while [[ "$idx" -lt "$total" ]]; do
      if [[ "${obs_kind[$idx]}" == "net" && "${obs_type[$idx]}" == "document" && -n "${obs_url[$idx]}" ]]; then
        case "${obs_status[$idx]}" in
          ''|*[!0-9]*) ;;
          *)
            obj="$(enc_nav "${obs_url[$idx]}" "${obs_status[$idx]}")"
            [[ -n "$obj" ]] && { [[ -n "$navs" ]] && navs="${navs},"; navs="${navs}${obj}"; }
            ;;
        esac
      fi
      idx=$((idx + 1))
    done
    while IFS= read -r j_source; do
      IFS= read -r j_method   || break
      IFS= read -r j_url      || break
      IFS= read -r j_ulen     || break
      IFS= read -r j_status   || break
      IFS= read -r j_origin   || break
      IFS= read -r j_statusclass || break
      IFS= read -r j_message  || break
      [[ -n "$j_url" ]] || continue
      case "$j_status" in
        ''|*[!0-9]*) obj="$(enc_finding "$j_url" "$j_statusclass" "")" ;;
        *)           obj="$(enc_finding "$j_url" "$j_statusclass" "$j_status")" ;;
      esac
      [[ -n "$obj" ]] && { [[ -n "$finds" ]] && finds="${finds},"; finds="${finds}${obj}"; }
    done < <(journal_finding_rows "$run_id")

    local ev_tmp sout srrc
    ev_tmp="$(mktemp)" || ev_tmp=""
    if [[ -n "$ev_tmp" ]]; then
      printf '{"navigations":[%s],"findings":[%s]}' "$navs" "$finds" > "$ev_tmp"
      sout="$(bash "$KNOWN_DEFECTS_SH" status "$reg" "$today" --evidence "$ev_tmp" 2>/dev/null)"; srrc=$?
      rm -f "$ev_tmp"
    else
      sout=""; srrc=1
    fi
    if [[ "$srrc" -ne 0 || -z "$sout" ]]; then
      kd_ok="false"
      reason_add "known-defect registry: known-defects.sh status exited ${srrc} for ${reg} — the registry could not be evaluated, which is not a pass"
    else
      kd_json="$(compact_one_json "$sout")"
      if [[ -z "$kd_json" ]]; then
        kd_ok="false"
        kd_json="[]"
        reason_add "known-defect registry: known-defects.sh status did not print exactly one JSON document for ${reg} — the registry could not be evaluated, which is not a pass"
      fi
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        kd_ok="false"
        reason_add "known-defect registry: entry ${line} is EXPIRED — a known defect past its deadline fails the run until it is fixed or its expiry is deliberately renewed (decision R2)"
      done < <(kd_expired_ids "$sout")
    fi
  fi

  [[ -n "$cfg_tmp" ]] && rm -f "$cfg_tmp"

  # --- emit ---------------------------------------------------------------
  local any_false=0
  [[ "$ledger_ok" == "false" || "$class_ok" == "false" || "$window_ok" == "false" || "$kd_ok" == "false" ]] && any_false=1
  if [[ "$any_false" -eq 0 && "$has_evidence" -eq 0 ]]; then
    return 0
  fi

  local verdict="pass" conf="high"
  if [[ "$any_false" -eq 1 ]]; then
    verdict="fail"
  elif [[ "$channel" == "none" ]]; then
    conf="low"
  fi

  local reasons_json
  if [[ ${#reasons[@]} -eq 0 ]]; then
    reasons_json="$(json_array_from_args "run-scoped checks: ledger completeness, classification re-check, load-window coverage and the known-defect gate all passed")"
  else
    reasons_json="$(json_array_from_args "${reasons[@]}")"
  fi

  if has_jq; then
    jq -cn \
      --arg verV "$verdict" --arg conf "$conf" --arg channel "$channel" \
      --argjson reasons "$reasons_json" --argjson kd "$kd_json" \
      --argjson ledger "$ledger_ok" --argjson class "$class_ok" \
      --argjson window "$window_ok" --argjson kdok "$kd_ok" \
      '{criterionId: "__run-checks__", persona: "", inRunVerdict: "n/a",
        verifierVerdict: $verV, confidence: $conf, reasons: $reasons,
        channel: $channel, knownDefects: $kd,
        runChecks: {ledgerComplete: $ledger, classificationsAgree: $class,
                    loadWindowCovered: $window, knownDefectsOk: $kdok}}'
  else
    python3 -c '
import json, sys
verV, conf, channel, reasons, kd, ledger, klass, window, kdok = sys.argv[1:10]
print(json.dumps({
    "criterionId": "__run-checks__", "persona": "", "inRunVerdict": "n/a",
    "verifierVerdict": verV, "confidence": conf, "reasons": json.loads(reasons),
    "channel": channel, "knownDefects": json.loads(kd),
    "runChecks": {
        "ledgerComplete": json.loads(ledger),
        "classificationsAgree": json.loads(klass),
        "loadWindowCovered": json.loads(window),
        "knownDefectsOk": json.loads(kdok),
    },
}, separators=(",", ":")))
' "$verdict" "$conf" "$channel" "$reasons_json" "$kd_json" "$ledger_ok" "$class_ok" "$window_ok" "$kd_ok"
  fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && die "Usage: qa-verify.sh <run-id>"
  local run_id="$1"
  validate_run_id "$run_id"

  if ! has_jq && ! has_py; then
    die "qa-verify.sh needs either 'jq' or 'python3' on PATH."
  fi

  local ckpt
  ckpt="$(checkpoint_file "$run_id")"
  [[ -f "$ckpt" ]] || die "No checkpoint found for run '${run_id}': ${ckpt}"
  json_is_valid "$ckpt" || die "checkpoint.json for run '${run_id}' is not valid JSON: ${ckpt}"

  results_tmp="$(mktemp)"
  trap 'rm -f "$results_tmp"' EXIT

  local run_failed=0 checked=0
  local pass_rec crit_id persona confidence nonui_reason kinds_csv rec_json verdict pc_rc
  local fields_out
  while IFS= read -r pass_rec; do
    [[ -z "$pass_rec" ]] && continue
    fields_out="$(read_pass_record "$pass_rec")"
    _qv_fields=()
    while IFS= read -r _qv_line; do _qv_fields+=("$_qv_line"); done <<< "$fields_out"
    crit_id="${_qv_fields[0]:-}"
    persona="${_qv_fields[1]:-}"
    confidence="${_qv_fields[2]:-}"
    nonui_reason="${_qv_fields[3]:-}"
    kinds_csv="${_qv_fields[4]:-}"
    [[ -z "$crit_id" ]] && continue

    # Appendix A: die()-in-subshell criterion loss. process_criterion runs
    # inside this command substitution — a die() anywhere in its call chain
    # only exits the SUBSHELL (no `set -e` here), leaving rec_json empty
    # with the assignment itself reporting success. Detect BOTH signals
    # (nonzero exit code from the substitution AND/OR empty output) and
    # synthesize an "error" record rather than silently dropping the
    # criterion — see build_error_record's header comment.
    rec_json="$(process_criterion "$run_id" "$crit_id" "$persona" "$confidence" "$nonui_reason" "$kinds_csv")"
    pc_rc=$?
    if [[ "$pc_rc" -ne 0 || -z "$rec_json" ]]; then
      rec_json="$(build_error_record "$crit_id" "$persona" "process_criterion exited ${pc_rc} or produced no output (see qa-verify's own stderr above for the underlying failure)")"
    fi
    echo "$rec_json" >> "$results_tmp"
    checked=$((checked + 1))
    verdict="$(rec_verdict "$rec_json")"
    [[ "$verdict" != "pass" ]] && run_failed=1
  done < <(list_pass_records "$run_id")

  # --- Phase-surface pass (Run FSM Enforcement Task 3) — a SEPARATE,
  # additional pass, independent of the pass-record loop above. Adds AT
  # MOST one synthetic "__phase-surface__" record; deliberately does NOT
  # touch run_failed (record-only authority — see the header comment). ---
  local ps_rec
  ps_rec="$(run_phase_surface_pass "$run_id")"
  [[ -n "$ps_rec" ]] && echo "$ps_rec" >> "$results_tmp"

  # --- Run-scoped checks pass (Task 8) — a THIRD, independent pass. Adds AT
  # MOST one synthetic "__run-checks__" record and, unlike the phase-surface
  # record above, DOES set run_failed (see the header comment). ---
  # Appendix A, applied to this pass too: run_run_checks_pass is invoked
  # inside a command substitution, so a crash anywhere in its call chain
  # would leave rc_rec EMPTY with the assignment itself reporting success —
  # and an empty rc_rec is ALSO the legitimate "nothing to report" result.
  # The exit code is therefore the only signal that separates the two, and a
  # non-zero one synthesizes an error record rather than silently dropping
  # the run-scoped authority (a lost gate must never look like a clean run).
  local rc_rec rc_rc
  rc_rec="$(run_run_checks_pass "$run_id")"
  rc_rc=$?
  if [[ "$rc_rc" -ne 0 ]]; then
    rc_rec="$(build_error_record "__run-checks__" "" "run_run_checks_pass exited ${rc_rc} (see qa-verify's own stderr above for the underlying failure) — the four run-scoped checks did not complete")"
  fi
  if [[ -n "$rc_rec" ]]; then
    echo "$rc_rec" >> "$results_tmp"
    [[ "$(rec_verdict "$rc_rec")" != "pass" ]] && run_failed=1
  fi

  # Atomic write (Appendix A: verification.json non-atomic write): write to a
  # temp file in the SAME directory as the destination, then rename over it.
  # Temp-in-same-dir + rename is POSIX-atomic w.r.t. concurrent readers (e.g.
  # report-to-junit.sh reading verification.json mid-run) on a single
  # filesystem — matches the write_latest/atomic_write idiom used elsewhere
  # in this codebase (checkpoint.sh, journal.sh). Trap-cleaned on failure so
  # a `.tmp.$$` is never left behind.
  local out_file out_tmp
  out_file="$(verification_file "$run_id")"
  out_tmp="${out_file}.tmp.$$"
  if has_jq; then
    if ! jq -s '.' "$results_tmp" > "$out_tmp"; then
      rm -f "$out_tmp"
      echo "qa-verify: FATAL — failed to render verification.json for run ${run_id}" >&2
      exit 1
    fi
  else
    if ! python3 -c '
import json, sys
lines = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            lines.append(json.loads(line))
with open(sys.argv[2], "w") as out:
    json.dump(lines, out, indent=2)
' "$results_tmp" "$out_tmp"; then
      rm -f "$out_tmp"
      echo "qa-verify: FATAL — failed to render verification.json for run ${run_id}" >&2
      exit 1
    fi
  fi
  if ! mv -f "$out_tmp" "$out_file"; then
    rm -f "$out_tmp"
    echo "qa-verify: FATAL — failed to atomically install verification.json for run ${run_id}" >&2
    exit 1
  fi

  echo "qa-verify: run=${run_id} passes_checked=${checked} overridden=$( [[ "$run_failed" -eq 1 ]] && echo yes || echo no ) -> ${out_file}" >&2

  [[ "$run_failed" -eq 0 ]]
}

main "$@"
