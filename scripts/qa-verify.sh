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

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED_KINDS_SH="$HERE/../skills/checkpointing-qa-memory/scripts/required-kinds.sh"
CHECK_ACTION_TRACE_JS="$HERE/../skills/checkpointing-qa-memory/scripts/check-action-trace.js"
PROVENANCE_SH="$HERE/provenance.sh"

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
  for r in "${rec_arr[@]}"; do
    r="$(trim "$r")"
    [[ -n "$r" ]] && rec_trimmed+=("$r")
  done

  local rk item found
  for rk in "${req_arr[@]}"; do
    rk="$(trim "$rk")"
    [[ -z "$rk" ]] && continue
    found=""
    for item in "${rec_trimmed[@]}"; do
      [[ "$item" == "$rk" ]] && { found="yes"; break; }
    done
    [[ -z "$found" ]] && missing+=("$rk")
  done

  (IFS=,; echo "${missing[*]}")
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
  for kind in "${kinds_arr[@]}"; do
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
          node_out="$(node "$CHECK_ACTION_TRACE_JS" "$full_path" "${allow[@]}" 2>&1)"
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
    case ",${kinds_csv}," in
      *,human-action,*) high_stakes=1 ;;
    esac
    if [[ "$high_stakes" -eq 0 ]] && row_has_high_stakes_tag "$row"; then
      high_stakes=1
    fi

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
  reasons_json="$(json_array_from_args "${reasons[@]}")"

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
  local pass_rec crit_id persona confidence nonui_reason kinds_csv rec_json verdict
  local fields_out
  while IFS= read -r pass_rec; do
    [[ -z "$pass_rec" ]] && continue
    fields_out="$(read_pass_record "$pass_rec")"
    mapfile -t _qv_fields <<< "$fields_out"
    crit_id="${_qv_fields[0]:-}"
    persona="${_qv_fields[1]:-}"
    confidence="${_qv_fields[2]:-}"
    nonui_reason="${_qv_fields[3]:-}"
    kinds_csv="${_qv_fields[4]:-}"
    [[ -z "$crit_id" ]] && continue

    rec_json="$(process_criterion "$run_id" "$crit_id" "$persona" "$confidence" "$nonui_reason" "$kinds_csv")"
    echo "$rec_json" >> "$results_tmp"
    checked=$((checked + 1))
    verdict="$(rec_verdict "$rec_json")"
    [[ "$verdict" != "pass" ]] && run_failed=1
  done < <(list_pass_records "$run_id")

  local out_file
  out_file="$(verification_file "$run_id")"
  if has_jq; then
    jq -s '.' "$results_tmp" > "$out_file"
  else
    python3 -c '
import json, sys
lines = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            lines.append(json.loads(line))
with open(sys.argv[2], "w") as out:
    json.dump(lines, out, indent=2)
' "$results_tmp" "$out_file"
  fi

  echo "qa-verify: run=${run_id} passes_checked=${checked} overridden=$( [[ "$run_failed" -eq 1 ]] && echo yes || echo no ) -> ${out_file}" >&2

  [[ "$run_failed" -eq 0 ]]
}

main "$@"
