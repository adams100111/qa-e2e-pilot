#!/usr/bin/env bash
# record-evidence.sh — write a structured, content-checkable evidence artifact
# for one criterion of a qa-e2e-pilot Run, so checkpoint.sh's evidence gate can
# be CONTENT-aware (not filename-theater).
#
# USAGE:
#   record-evidence.sh <run-id> <criterion-id> bake     [--persona <id>] --read-back <json-or-text> --multiplicity <0|1|N> [--source-ref <selector>]
#   record-evidence.sh <run-id> <criterion-id> computed [--persona <id>] --oracle <val> --observed <val> --match <true|false>
#   record-evidence.sh <run-id> <criterion-id> probe    [--persona <id>] --status <code> --shape <json-or-text> --ok <true|false> [--source-ref <selector>]
#   record-evidence.sh <run-id> <criterion-id> action-trace [--persona <id>] --steps <json-array> [--session-log <session.md> --session-from <N> | --session-calls <json-array>] [--action <desc>] [--source-ref <selector>]
#   record-evidence.sh <run-id> <criterion-id> identity --persona <id> --subject <captured-subject> --method <whoami|storageState|none>
#   record-evidence.sh <run-id> <criterion-id> screenshot [--persona <id>] --phase <before|after> [--label <token>] [--file <path>] [--source-ref seq:<N>]
#     kind 'screenshot' (0.10.0, ADR-0028) — see cmd_screenshot below: copies
#       the image the driver saved into the criterion's evidence dir, writes a
#       sidecar binding it to the captured browser_take_screenshot call, and
#       REFUSES anything that could never bind. Prints the image's path.
#     --session-log + --session-from  DERIVE sessionCalls from the REAL session.md
#       (independent ground truth) by running parse-session-log.js and slicing from
#       N. This OVERRIDES --session-calls and is the tamper-evident path; prefer it.
#     --source-ref <selector>  (bake/probe/action-trace ONLY, Plan H2 Task 3, spec
#       §5.4) — OPTIONAL. The agent's claim of WHICH captured toolstream call
#       (scripts/toolstream.sh's .qa/runs/<run>/toolstream.jsonl) produced this
#       evidence, e.g. "seq:7" (or bare "7") referencing that event's `seq`.
#       Recorded as `provenance: {sourceRef, boundAt}` (boundAt stamped here;
#       a bare "7" is normalized to "seq:7"). scripts/provenance.sh's `check`
#       resolves it against the real toolstream — a dangling/fabricated
#       sourceRef resolves to "unbound" (a forgery signal), it is NOT taken on
#       faith. VALIDATED AT RECORD TIME (0.9.0): anything that is not
#       `seq:<N>`/`<N>` (a description such as "tinker:Model::find(1)") is
#       REFUSED, and so is a seq that names no event in an existing
#       toolstream — exit 1, nothing written, a message saying what to pass.
#       Omitting --source-ref produces no `provenance` key at all —
#       scripts/provenance.sh then binds by containment instead.
#     --session-calls (action-trace) is VALIDATED AT RECORD TIME (0.9.0): it
#       must be a non-empty JSON array of objects each naming a `class` or a
#       `tool`; strings, {tool: count} maps, null and [] are refused (none can
#       ever bind). With neither --session-calls nor --session-log, NO
#       sessionCalls key is written (0.8.1 wrote [], a guaranteed AC-1), so the
#       act-phase --steps are bound against the captured toolstream instead.
#     kind 'identity' (Plan H3 Task 1, gap #6) — REQUIRES --persona (identity is
#       a property of the acting persona for this run, not of one criterion).
#       Records what identity the browser session was ACTUALLY observed to be
#       acting as (a read-only whoami/profile probe result, or the subject
#       decoded from a captured storageState) alongside the persona id it was
#       supposed to be. `--method none` means the app exposes no probeable
#       identity at all — record it anyway so qa-verify can distinguish "checked,
#       unverifiable" from "never checked". Written to
#       evidence/<persona>/identity.json (persona-scoped, NOT nested under
#       <criterion-id> like the other four kinds — one identity capture covers
#       every criterion run as that persona in this run). qa-verify.sh reads it
#       back for every persona-scoped high-stakes (human-action /
#       cross-tenant / cross-role-fk-chain) `pass`: a captured subject that
#       confidently mismatches the persona overrides the pass to fail (acting
#       as the wrong user); an absent/unverifiable identity degrades
#       confidence to low instead (spec §5.5 — never blocks).
#
# kind -> artifact:
#   bake     -> bake-read-back.json   { readBack, multiplicity, [provenance], ... }
#   computed -> recompute.json        { oracle, observed, match, ... }
#   probe    -> network-response.json { status, shape, ok, [provenance], ... }
#   action-trace -> action-trace.json { actionUnderTest, steps, sessionCalls, [provenance] }
#   identity -> identity.json         { persona, capturedSubject, method, recorded_at }
#     (written to evidence/<persona>/identity.json — see the identity note above;
#     this is the ONE kind whose artifact path is NOT evidence/<persona>/<criterion-id>/...)
#
# `--ok` on kind 'probe' is the agent's own judgment that the probe CONFIRMED
# its expectation — it is NOT a raw status-code check. A cross-role ABSENCE
# probe that correctly gets 403/404 sets --ok true; checkpoint.sh's evidence
# gate requires `.ok == true` on a `pass`, deliberately never inspecting the
# raw status/range itself (that would reject legitimate 403/404 absence
# probes).
#
# Written under .qa/runs/<run-id>/evidence/<criterion-id>/ by default. When
# --persona <id> is given, written under
# .qa/runs/<run-id>/evidence/<persona>/<criterion-id>/ instead, so two
# personas' bakes for the same criterion never collide. Omitting --persona is
# back-compat: the no-persona path is byte-identical to today's.
#
# On success, prints ONE line to stdout: the artifact path RELATIVE TO THE RUN
# DIR (e.g. "evidence/C1/bake-read-back.json", or with --persona admin:
# "evidence/admin/C1/bake-read-back.json") — the exact shape checkpointing-
# qa-memory's `evidence_refs` (and checkpoint.sh's `--persona`-aware gate)
# expect, so the caller can pipe it straight in:
#   checkpoint.sh ... --persona <id> --evidence-refs "$(record-evidence.sh ... --persona <id> ...)"
#
# DEPENDENCIES: bash, coreutils (date, mkdir), and EITHER jq OR python3 for
#               safe JSON writing (jq preferred; python3 used as fallback).
#
# SECRETS: values passed via --key are written into the run dir's evidence
#          file but are NEVER echoed to stdout/stderr — only the artifact path
#          is printed on success; error paths never echo option values either.
#
# NOTE: All paths are relative to the current working directory (project root),
#       matching checkpoint.sh's convention.

set -euo pipefail

QA_BASE=".qa/runs"

# ---------------------------------------------------------------------------
# helpers (mirrors checkpoint.sh's idiom)
# ---------------------------------------------------------------------------

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() { command -v jq >/dev/null 2>&1; }

has_py() { command -v python3 >/dev/null 2>&1; }

# build_provenance_json <source-ref> -> {"sourceRef": "<source-ref>", "boundAt": "<ts>"}
# Only called when --source-ref was given (Plan H2 Task 3) — the caller
# embeds this JSON object verbatim as the artifact's `provenance` field via
# write_jq's generic fromjson-embedding (or a dedicated python3 smart()
# parse), never as a raw string. Absent --source-ref -> this is never
# called -> no `provenance` key is ever added -> today's shape, byte-for-byte.
build_provenance_json() {
  local source_ref="$1"
  # Normalize the accepted bare-integer shorthand to the canonical selector,
  # so what is recorded is exactly what provenance.sh resolves.
  [[ "$source_ref" =~ ^[0-9]+$ ]] && source_ref="seq:${source_ref}"
  if has_jq; then
    jq -cn --arg sourceRef "$source_ref" --arg boundAt "$(ts)" '{sourceRef: $sourceRef, boundAt: $boundAt}'
  elif has_py; then
    python3 -c 'import json,sys; print(json.dumps({"sourceRef": sys.argv[1], "boundAt": sys.argv[2]}))' "$source_ref" "$(ts)"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to build --source-ref provenance."
  fi
}

# ---------------------------------------------------------------------------
# RECORD-TIME VALIDATION (0.9.0). Evidence cannot be corrected after it is
# recorded — qa-verify rightly treats a post-hoc edit as tampering — so a
# value that is GUARANTEED to fail verification must be refused here, at the
# moment the agent can still fix it, never accepted and discovered at verify
# time (two real runs lost 27 genuine passes to this).
#
# validate_source_ref <run-id> <ref>
#   The ONLY accepted selector is `seq:<N>` (or the bare-integer shorthand
#   `<N>`), naming the `seq` of an event the capture hook actually wrote to
#   .qa/runs/<run-id>/toolstream.jsonl. Anything else — a description
#   ("tinker:Model::find(1)", "browser_network_requests") — is refused with a
#   message saying what to pass instead. When the toolstream exists, the seq
#   must exist in it (a dangling pointer is refused, not recorded). When no
#   toolstream exists yet (capture off / non-Claude harness), the shape is
#   still enforced and the existence check is skipped with a NOTE.
# ---------------------------------------------------------------------------
SOURCE_REF_HELP="pass --source-ref seq:<N> naming the toolstream event (its \"seq\" in .qa/runs/<run-id>/toolstream.jsonl) that produced this evidence, or OMIT --source-ref so qa-verify binds the evidence by containment against every captured response (a description such as 'tinker:Model::find(1)' or 'browser_network_requests' is not a pointer)"

toolstream_has_seq() {
  local tsf="$1" n="$2"
  if has_jq; then
    jq -R -e --argjson n "$n" 'try (fromjson | select(type == "object" and .seq == $n)) catch empty' "$tsf" 2>/dev/null | grep -q .
  else
    python3 - "$tsf" "$n" <<'PYEOF'
import json, sys
n = int(sys.argv[2])
with open(sys.argv[1]) as fh:
    for line in fh:
        try:
            o = json.loads(line)
        except Exception:
            continue
        if isinstance(o, dict) and o.get("seq") == n and not isinstance(o.get("seq"), bool):
            sys.exit(0)
sys.exit(1)
PYEOF
  fi
}

validate_source_ref() {
  local run_id="$1" ref="$2" num
  [[ -n "$ref" ]] || die "--source-ref must not be empty — ${SOURCE_REF_HELP}."
  if [[ "$ref" =~ ^seq:([0-9]+)$ ]]; then
    num="${BASH_REMATCH[1]}"
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    num="$ref"
  else
    die "--source-ref '${ref}' is not a toolstream pointer — ${SOURCE_REF_HELP}. Nothing was recorded."
  fi
  local tsf
  tsf="$(run_dir "$run_id")/toolstream.jsonl"
  if [[ ! -s "$tsf" ]]; then
    echo "NOTE: --source-ref seq:${num} recorded unchecked — no toolstream exists yet for run '${run_id}' (capture hook off?); qa-verify degrades to no-toolstream." >&2
    return 0
  fi
  toolstream_has_seq "$tsf" "$num" \
    || die "--source-ref seq:${num} names no event in ${tsf} — a dangling pointer is recorded as a forgery signal (AC-1) at verify time. Look up the seq of the call that produced this evidence (e.g. the last line of toolstream.jsonl right after that call), or omit --source-ref to bind by containment. Nothing was recorded."
}

# validate_session_calls <json>
#   --session-calls must be a NON-EMPTY JSON array of OBJECTS, each naming the
#   call by `class` (human-path | evaluate | route | other, as
#   parse-session-log.js emits) or by `tool` (e.g. "browser_click"). A plain
#   string, a list of strings, a {tool: count} map, null, or `[]` can never
#   bind at verify time (provenance.sh matches only class/tool objects, and an
#   explicit empty list is the AC-1 forged-trace signal), so each is refused.
validate_session_calls() {
  local sc="$1" verdict
  local help="--session-calls must be a non-empty JSON array of objects like [{\"class\":\"human-path\"}] or [{\"tool\":\"browser_click\"}] — or omit it (and --session-log) so the act-phase --steps are bound against the captured toolstream instead"
  if has_jq; then
    verdict="$(jq -r '
      if type != "array" then "not-array"
      elif length == 0 then "empty"
      elif all(.[]; type == "object" and (((.class // null) | type) == "string" and (.class | length) > 0 or ((.tool // null) | type) == "string" and (.tool | length) > 0)) then "ok"
      else "bad-element" end' <<< "$sc" 2>/dev/null)" || verdict="not-json"
    [[ -z "$verdict" ]] && verdict="not-json"
  else
    verdict="$(python3 -c '
import json, sys
try:
    v = json.loads(sys.argv[1])
except Exception:
    print("not-json"); sys.exit(0)
def named(e):
    if not isinstance(e, dict):
        return False
    for k in ("class", "tool"):
        x = e.get(k)
        if isinstance(x, str) and x:
            return True
    return False
if not isinstance(v, list):
    print("not-array")
elif not v:
    print("empty")
elif all(named(e) for e in v):
    print("ok")
else:
    print("bad-element")
' "$sc" 2>/dev/null)"
    [[ -z "$verdict" ]] && verdict="not-json"
  fi
  case "$verdict" in
    ok) return 0 ;;
    empty) die "--session-calls is an empty list — an explicit empty independent trace is the AC-1 forged-trace signal and can never verify. ${help}. Nothing was recorded." ;;
    not-json) die "--session-calls is not valid JSON. ${help}. Nothing was recorded." ;;
    not-array) die "--session-calls is not a JSON array. ${help}. Nothing was recorded." ;;
    *) die "--session-calls has an element that is not an object with a non-empty \"class\" or \"tool\" (plain strings such as \"click Save\" cannot bind). ${help}. Nothing was recorded." ;;
  esac
}

# ---------------------------------------------------------------------------
# Fix 28 — reject any run-id / criterion-id / persona value that could
# escape .qa/runs/<run-id>/evidence/... when interpolated into a path (e.g.
# --persona '../../../evil'). Mirrors checkpoint.sh's validate_token exactly
# — a persona/criterion/run id must be a simple token: no '/' or '\', no
# '..' anywhere in the value, and no leading '-'. Dies with a clear message
# BEFORE the value is ever used to build a path — this must run before
# evidence_dir()/evidence_dir_rel() see the value.
# ---------------------------------------------------------------------------
validate_token() {
  local value="$1" label="$2"
  [[ -z "$value" ]] && die "${label} must not be empty."
  case "$value" in
    */*|*\\*) die "${label} '${value}' contains a path separator ('/' or '\\') — must be a simple token." ;;
  esac
  case "$value" in
    *..*) die "${label} '${value}' contains '..' — must be a simple token." ;;
  esac
  # Fix 2728: a bare '.' (or an all-dots value not already caught by the
  # '..'-substring check above, e.g. a hypothetical future single-dot
  # variant) normalizes away when interpolated into a path — 'evidence/./
  # <crit>/...' collapses to 'evidence/<crit>/...' (the NO-persona path),
  # and '.qa/runs/.' collapses to '.qa/runs/' — silently escaping the
  # per-identity/per-run directory this token is supposed to scope. Reject
  # it here, before any path is built from it.
  if [[ "$value" =~ ^\.+$ ]]; then
    die "${label} '${value}' is '.' or consists only of dots — must be a simple token."
  fi
  case "$value" in
    -*) die "${label} '${value}' starts with '-' — must be a simple token." ;;
  esac
  return 0
}

run_dir() {
  local run_id="$1"
  echo "${QA_BASE}/${run_id}"
}

# $3 (persona) is OPTIONAL. Empty/omitted -> today's path, byte-identical:
#   evidence/<crit_id>
# Non-empty -> persona-scoped path (mirrors checkpoint.sh's gate lookup):
#   evidence/<persona>/<crit_id>
evidence_dir() {
  local run_id="$1" crit_id="$2" persona="${3:-}"
  if [[ -n "$persona" ]]; then
    echo "$(run_dir "$run_id")/evidence/${persona}/${crit_id}"
  else
    echo "$(run_dir "$run_id")/evidence/${crit_id}"
  fi
}

# relative-to-run-dir counterpart of evidence_dir(), used to build the
# stdout path and mirrors checkpoint.sh gate_pass's rel_path construction.
evidence_dir_rel() {
  local crit_id="$1" persona="${2:-}"
  if [[ -n "$persona" ]]; then
    echo "evidence/${persona}/${crit_id}"
  else
    echo "evidence/${crit_id}"
  fi
}

ensure_evidence_dir() {
  local run_id="$1" crit_id="$2" persona="${3:-}"
  mkdir -p "$(evidence_dir "$run_id" "$crit_id" "$persona")"
}

# artifact filename for a given kind
artifact_for_kind() {
  case "$1" in
    bake)     echo "bake-read-back.json" ;;
    computed) echo "recompute.json" ;;
    probe)    echo "network-response.json" ;;
    action-trace) echo "action-trace.json" ;;
    identity) echo "identity.json" ;;
    screenshot) echo "screenshot-<phase>.json" ;;
    *)        die "Unknown kind '$1'. Must be one of: bake | computed | probe | action-trace | identity | screenshot" ;;
  esac
}

# ---------------------------------------------------------------------------
# write artifact using jq (preferred) — each value is stored as parsed JSON
# when it looks like JSON, otherwise as a raw string. Values are passed via
# --arg (never interpolated into the filter), so nothing is echoed or shelled.
# ---------------------------------------------------------------------------

write_jq() {
  local file="$1" run_id="$2" crit_id="$3" kind="$4"
  shift 4
  # remaining args: field_name value field_name value ...
  local jq_args=()
  local filter_fields=""
  while [[ $# -gt 0 ]]; do
    local field="$1" value="$2"
    shift 2
    jq_args+=(--arg "raw_${field}" "$value")
    if [[ -n "$filter_fields" ]]; then filter_fields+=", "; fi
    filter_fields+="${field}: (\$raw_${field} | try fromjson catch \$raw_${field})"
  done

  jq -n \
     --arg criterion_id "$crit_id" \
     --arg run_id "$run_id" \
     --arg kind "$kind" \
     --arg recorded_at "$(ts)" \
     "${jq_args[@]}" \
     "{criterion_id: \$criterion_id, run_id: \$run_id, kind: \$kind, recorded_at: \$recorded_at, ${filter_fields}}" \
     > "$file"
}

# multiplicity is always stored as a plain string (it's an enum 0|1|N, not a
# value to type-infer), so it gets its own jq/python writer path.
# $6 (source_ref, OPTIONAL, Plan H2 Task 3) — empty/omitted -> today's shape,
# byte-identical (no `provenance` key at all). Non-empty -> a `provenance`
# object is added.
write_jq_bake() {
  local file="$1" run_id="$2" crit_id="$3" read_back="$4" multiplicity="$5" source_ref="${6:-}"
  if [[ -n "$source_ref" ]]; then
    jq -n \
       --arg criterion_id "$crit_id" \
       --arg run_id "$run_id" \
       --arg kind "bake" \
       --arg recorded_at "$(ts)" \
       --arg read_back_raw "$read_back" \
       --arg multiplicity "$multiplicity" \
       --arg source_ref "$source_ref" \
       --arg bound_at "$(ts)" \
       '{criterion_id: $criterion_id, run_id: $run_id, kind: $kind, recorded_at: $recorded_at,
         readBack: ($read_back_raw | try fromjson catch $read_back_raw),
         multiplicity: $multiplicity,
         provenance: {sourceRef: $source_ref, boundAt: $bound_at}}' \
       > "$file"
  else
    jq -n \
       --arg criterion_id "$crit_id" \
       --arg run_id "$run_id" \
       --arg kind "bake" \
       --arg recorded_at "$(ts)" \
       --arg read_back_raw "$read_back" \
       --arg multiplicity "$multiplicity" \
       '{criterion_id: $criterion_id, run_id: $run_id, kind: $kind, recorded_at: $recorded_at,
         readBack: ($read_back_raw | try fromjson catch $read_back_raw),
         multiplicity: $multiplicity}' \
       > "$file"
  fi
}

# ---------------------------------------------------------------------------
# write artifact using python3 (fallback, no jq)
# ---------------------------------------------------------------------------

write_py_bake() {
  local file="$1" run_id="$2" crit_id="$3" read_back="$4" multiplicity="$5" provenance_json="${6:-}"
  python3 - "$file" "$run_id" "$crit_id" "$read_back" "$multiplicity" "$(ts)" "$provenance_json" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, read_back, multiplicity, now, provenance_json = sys.argv[1:8]
def smart(v):
    try:
        return json.loads(v)
    except (json.JSONDecodeError, ValueError):
        return v
data = {
    "criterion_id": crit_id,
    "run_id": run_id,
    "kind": "bake",
    "recorded_at": now,
    "readBack": smart(read_back),
    "multiplicity": multiplicity,
}
if provenance_json:
    data["provenance"] = smart(provenance_json)
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

write_py_computed() {
  local file="$1" run_id="$2" crit_id="$3" oracle="$4" observed="$5" match="$6"
  python3 - "$file" "$run_id" "$crit_id" "$oracle" "$observed" "$match" "$(ts)" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, oracle, observed, match, now = sys.argv[1:8]
def smart(v):
    try:
        return json.loads(v)
    except (json.JSONDecodeError, ValueError):
        return v
data = {
    "criterion_id": crit_id,
    "run_id": run_id,
    "kind": "computed",
    "recorded_at": now,
    "oracle": smart(oracle),
    "observed": smart(observed),
    "match": smart(match),
}
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

write_py_probe() {
  local file="$1" run_id="$2" crit_id="$3" status="$4" shape="$5" ok="$6" provenance_json="${7:-}"
  python3 - "$file" "$run_id" "$crit_id" "$status" "$shape" "$ok" "$(ts)" "$provenance_json" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, status, shape, ok, now, provenance_json = sys.argv[1:9]
def smart(v):
    try:
        return json.loads(v)
    except (json.JSONDecodeError, ValueError):
        return v
data = {
    "criterion_id": crit_id,
    "run_id": run_id,
    "kind": "probe",
    "recorded_at": now,
    "status": smart(status),
    "shape": smart(shape),
    "ok": smart(ok),
}
if provenance_json:
    data["provenance"] = smart(provenance_json)
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# action-trace stores steps/sessionCalls as parsed JSON arrays and
# actionUnderTest as a plain string — mirrors write_py_bake/_computed/_probe's
# smart() dance so the python3 fallback path produces JSON byte-identical (up
# to key order, which json.dump preserves the same as the jq writer's field
# order) to the jq path (Fix #27 parity discipline).
write_py_action_trace() {
  local file="$1" run_id="$2" crit_id="$3" action="$4" steps="$5" session_calls="$6" fingerprints="${7:-}" fp_target="${8:-}" provenance_json="${9:-}"
  python3 - "$file" "$run_id" "$crit_id" "$action" "$steps" "$session_calls" "$(ts)" "$fingerprints" "$fp_target" "$provenance_json" <<'PYEOF'
import json, sys
file_path, run_id, crit_id, action, steps, session_calls, now, fingerprints, fp_target, provenance_json = sys.argv[1:11]
def smart(v):
    try:
        return json.loads(v)
    except (json.JSONDecodeError, ValueError):
        return v
data = {
    "criterion_id": crit_id,
    "run_id": run_id,
    "kind": "action-trace",
    "recorded_at": now,
    "actionUnderTest": smart(action),
    "steps": smart(steps),
}
# "" = neither --session-calls nor --session-log was given: no sessionCalls
# key at all (provenance.sh then binds the act-phase steps), never an
# explicit [] (which is the AC-1 forged-trace signal).
if session_calls != "":
    data["sessionCalls"] = smart(session_calls)
if fingerprints:
    data["fingerprints"] = smart(fingerprints)
if fp_target:
    data["fingerprintTarget"] = smart(fp_target)
if provenance_json:
    data["provenance"] = smart(provenance_json)
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ---------------------------------------------------------------------------
# per-kind dispatch
# ---------------------------------------------------------------------------

cmd_bake() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local read_back="" multiplicity="" have_read_back=0 have_multiplicity=0
  local source_ref=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --read-back)    read_back="$2";    have_read_back=1;    shift 2 ;;
      --multiplicity) multiplicity="$2"; have_multiplicity=1; shift 2 ;;
      --source-ref)   source_ref="$2";   shift 2 ;;
      *) die "Unknown option for kind 'bake': $1" ;;
    esac
  done
  [[ "$have_read_back" -eq 1 ]]    || die "kind 'bake' requires --read-back <json-or-text>"
  [[ "$have_multiplicity" -eq 1 ]] || die "kind 'bake' requires --multiplicity <0|1|N>"
  [[ -n "$source_ref" ]] && validate_source_ref "$run_id" "$source_ref"
  [[ "$source_ref" =~ ^[0-9]+$ ]] && source_ref="seq:${source_ref}"

  ensure_evidence_dir "$run_id" "$crit_id" "$persona"
  local file
  file="$(evidence_dir "$run_id" "$crit_id" "$persona")/bake-read-back.json"

  if has_jq; then
    write_jq_bake "$file" "$run_id" "$crit_id" "$read_back" "$multiplicity" "$source_ref"
  elif has_py; then
    local provenance_json=""
    [[ -n "$source_ref" ]] && provenance_json="$(build_provenance_json "$source_ref")"
    write_py_bake "$file" "$run_id" "$crit_id" "$read_back" "$multiplicity" "$provenance_json"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/bake-read-back.json"
}

cmd_computed() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local oracle="" observed="" match=""
  local have_oracle=0 have_observed=0 have_match=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --oracle)   oracle="$2";   have_oracle=1;   shift 2 ;;
      --observed) observed="$2"; have_observed=1; shift 2 ;;
      --match)    match="$2";    have_match=1;    shift 2 ;;
      *) die "Unknown option for kind 'computed': $1" ;;
    esac
  done
  [[ "$have_oracle" -eq 1 ]]   || die "kind 'computed' requires --oracle <val>"
  [[ "$have_observed" -eq 1 ]] || die "kind 'computed' requires --observed <val>"
  [[ "$have_match" -eq 1 ]]    || die "kind 'computed' requires --match <true|false>"

  ensure_evidence_dir "$run_id" "$crit_id" "$persona"
  local file
  file="$(evidence_dir "$run_id" "$crit_id" "$persona")/recompute.json"

  if has_jq; then
    write_jq "$file" "$run_id" "$crit_id" "computed" oracle "$oracle" observed "$observed" match "$match"
  elif has_py; then
    write_py_computed "$file" "$run_id" "$crit_id" "$oracle" "$observed" "$match"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/recompute.json"
}

cmd_probe() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local status="" shape="" ok="" have_status=0 have_shape=0 have_ok=0
  local source_ref=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) status="$2"; have_status=1; shift 2 ;;
      --shape)  shape="$2";  have_shape=1;  shift 2 ;;
      --ok)     ok="$2";     have_ok=1;     shift 2 ;;
      --source-ref) source_ref="$2"; shift 2 ;;
      *) die "Unknown option for kind 'probe': $1" ;;
    esac
  done
  [[ "$have_status" -eq 1 ]] || die "kind 'probe' requires --status <code>"
  [[ "$have_shape" -eq 1 ]]  || die "kind 'probe' requires --shape <json-or-text>"
  [[ "$have_ok" -eq 1 ]]     || die "kind 'probe' requires --ok <true|false> — your judgment that the probe CONFIRMED its expectation (e.g. an absence probe expecting 403/404 passes --ok true when it gets 403/404; do not infer this from the raw status code alone)"
  [[ -n "$source_ref" ]] && validate_source_ref "$run_id" "$source_ref"

  ensure_evidence_dir "$run_id" "$crit_id" "$persona"
  local file
  file="$(evidence_dir "$run_id" "$crit_id" "$persona")/network-response.json"

  local provenance_json=""
  [[ -n "$source_ref" ]] && provenance_json="$(build_provenance_json "$source_ref")"

  if has_jq; then
    if [[ -n "$provenance_json" ]]; then
      write_jq "$file" "$run_id" "$crit_id" "probe" status "$status" shape "$shape" ok "$ok" provenance "$provenance_json"
    else
      write_jq "$file" "$run_id" "$crit_id" "probe" status "$status" shape "$shape" ok "$ok"
    fi
  elif has_py; then
    write_py_probe "$file" "$run_id" "$crit_id" "$status" "$shape" "$ok" "$provenance_json"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/network-response.json"
}

cmd_action_trace() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local steps="" session_calls="" have_session_calls=0 action="" have_steps=0
  local session_log="" session_from="0"
  local fp_before="" fp_after="" have_fp=0
  local fp_target="" have_target=0
  local source_ref=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --steps)              steps="$2";         have_steps=1; shift 2 ;;
      --session-calls)      session_calls="$2"; have_session_calls=1; shift 2 ;;
      --session-log)        session_log="$2";   shift 2 ;;
      --session-from)       session_from="$2";  shift 2 ;;
      --fingerprint-before) fp_before="$2";     have_fp=1; shift 2 ;;
      --fingerprint-after)  fp_after="$2";      have_fp=1; shift 2 ;;
      --fingerprint-target) fp_target="$2";     have_target=1; shift 2 ;;
      --action)             action="$2";        shift 2 ;;
      --source-ref)         source_ref="$2";    shift 2 ;;
      *) die "Unknown option for kind 'action-trace': $1" ;;
    esac
  done
  [[ "$have_steps" -eq 1 ]] || die "kind 'action-trace' requires --steps <json-array>"
  [[ -n "$source_ref" ]] && validate_source_ref "$run_id" "$source_ref"
  # An agent-supplied --session-calls is validated only when it is the value
  # that will be written; --session-log (the tamper-evident path) overrides it.
  if [[ "$have_session_calls" -eq 1 && -z "$session_log" ]]; then
    validate_session_calls "$session_calls"
  fi

  # Optional before/after persisted-state fingerprints for Check 3 (the
  # tool-agnostic net that catches arbitrary non-UI mutators). Built into a
  # {before, after} object stored as `fingerprints`. Values are stored as parsed
  # JSON when they look like JSON, else as raw strings (same idiom as the rest).
  # --fingerprint-target is threaded separately below as `fingerprintTarget`
  # (Plan H1 #4) — the criterion's declared assertedState the fingerprint must
  # cover; stored verbatim (parsed as JSON when it looks like JSON).
  local fingerprints=""
  if [[ "$have_fp" -eq 1 ]]; then
    if has_jq; then
      fingerprints="$(jq -cn --arg b "$fp_before" --arg a "$fp_after" \
        '{before: ($b | try fromjson catch $b), after: ($a | try fromjson catch $a)}')"
    else
      fingerprints="$(FP_B="$fp_before" FP_A="$fp_after" python3 -c "import json,os
def smart(v):
    try: return json.loads(v)
    except Exception: return v
print(json.dumps({'before': smart(os.environ['FP_B']), 'after': smart(os.environ['FP_A'])}))")"
    fi
  fi

  # TAMPER-EVIDENCE: when --session-log is given, DERIVE sessionCalls by running
  # parse-session-log.js on the REAL server-written session.md and slicing from
  # --session-from N (the per-criterion delta boundary the driver recorded). This
  # is the independent ground truth — it overrides any agent-supplied
  # --session-calls, so an agent cannot pass by simply omitting a mutating call
  # from a hand-written JSON array (final-review finding #2).
  if [[ -n "$session_log" ]]; then
    [[ -f "$session_log" ]] || die "--session-log file not found: $session_log"
    [[ "$session_from" =~ ^[0-9]+$ ]] || die "--session-from must be a non-negative integer"
    local parse_js all
    parse_js="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../driving-browser-qa/scripts" && pwd)/parse-session-log.js"
    [[ -f "$parse_js" ]] || die "parse-session-log.js not found at $parse_js"
    all="$(node "$parse_js" "$session_log")" || die "parse-session-log.js failed on $session_log"
    # N1: bound --session-from against the ACTUAL parsed length. An agent-supplied
    # N past the end would silently yield an empty slice, neutralizing the whole
    # tamper-evidence (a concealed call would never be derived). Refuse it.
    local total
    if has_jq; then total="$(printf '%s' "$all" | jq 'length')"; else total="$(printf '%s' "$all" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")"; fi
    [[ "$session_from" -le "$total" ]] || die "--session-from ($session_from) exceeds the session.md call count ($total) — refusing to derive an empty (tamper-hiding) slice"
    if has_jq; then
      session_calls="$(printf '%s' "$all" | jq -c ".[${session_from}:]")" || die "failed to slice session calls from $session_from"
    else
      session_calls="$(printf '%s' "$all" | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)[${session_from}:]))")" || die "failed to slice session calls from $session_from"
    fi
  fi

  ensure_evidence_dir "$run_id" "$crit_id" "$persona"
  local file
  file="$(evidence_dir "$run_id" "$crit_id" "$persona")/action-trace.json"

  # --fingerprint-target <json> ({entity, readBackPath, expectChange}) is the
  # criterion's declared asserted state (Plan H1 #4) — the persisted-state key
  # the before/after fingerprint must COVER, threaded through verbatim as
  # `fingerprintTarget` for check-action-trace.js's Check 3 to enforce.
  local extra_fields=()
  if [[ -n "$fingerprints" ]]; then
    extra_fields+=(fingerprints "$fingerprints")
  fi
  if [[ "$have_target" -eq 1 ]]; then
    extra_fields+=(fingerprintTarget "$fp_target")
  fi
  local provenance_json=""
  if [[ -n "$source_ref" ]]; then
    provenance_json="$(build_provenance_json "$source_ref")"
    extra_fields+=(provenance "$provenance_json")
  fi

  # sessionCalls is written only when it was supplied (--session-calls) or
  # derived (--session-log). Absent both, the key is OMITTED: 0.8.1 wrote an
  # explicit [] here, which provenance.sh rightly reads as the AC-1
  # forged-trace signal, so every such trace was guaranteed unbound.
  local sc_fields=()
  if [[ -n "$session_log" || "$have_session_calls" -eq 1 ]]; then
    sc_fields=(sessionCalls "$session_calls")
  else
    session_calls=""
  fi

  if has_jq; then
    write_jq "$file" "$run_id" "$crit_id" "action-trace" actionUnderTest "$action" steps "$steps" ${sc_fields[@]+"${sc_fields[@]}"} ${extra_fields[@]+"${extra_fields[@]}"}
  elif has_py; then
    write_py_action_trace "$file" "$run_id" "$crit_id" "$action" "$steps" "$session_calls" "$fingerprints" "$fp_target" "$provenance_json"
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/action-trace.json"
}

# cmd_identity — Plan H3 Task 1 (gap #6). Records what identity a browser
# session was OBSERVED to be acting as while running as persona <persona>,
# so qa-verify.sh can later bind it: a captured subject that mismatches the
# persona overrides a persona-scoped high-stakes pass to fail; an
# absent/unverifiable identity degrades confidence instead of blocking
# (spec §5.5). $3 (persona) is REQUIRED here — unlike the other four kinds,
# identity has no no-persona back-compat path, because an identity capture
# is meaningless without saying WHICH persona it was captured for.
#
# Deliberately written to evidence/<persona>/identity.json — NOT
# evidence/<persona>/<crit_id>/identity.json like the other kinds — because
# one identity capture (typically taken once, at that persona's login)
# covers every criterion this run executes as that persona; $crit_id is
# still accepted positionally (main()'s dispatch is uniform across all
# kinds) but is not part of the written path.
cmd_identity() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  # shellcheck disable=SC2034 -- crit_id/run_id accepted for a uniform call
  # shape across kinds; not part of the written path (see comment above).
  local subject="" method="" have_subject=0 have_method=0

  [[ -n "$persona" ]] || die "kind 'identity' requires --persona <id> (identity is recorded per-persona, not per-criterion — see the header comment)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subject) subject="$2"; have_subject=1; shift 2 ;;
      --method)  method="$2";  have_method=1;  shift 2 ;;
      *) die "Unknown option for kind 'identity': $1" ;;
    esac
  done
  [[ "$have_subject" -eq 1 ]] || die "kind 'identity' requires --subject <captured-subject>"
  [[ "$have_method" -eq 1 ]]  || die "kind 'identity' requires --method <whoami|storageState|none>"
  case "$method" in
    whoami|storageState|none) ;;
    *) die "kind 'identity' --method must be one of: whoami | storageState | none (got '${method}')" ;;
  esac

  local dir file
  dir="$(run_dir "$run_id")/evidence/${persona}"
  mkdir -p "$dir"
  file="${dir}/identity.json"

  if has_jq; then
    jq -n \
       --arg persona "$persona" \
       --arg capturedSubject "$subject" \
       --arg method "$method" \
       --arg recorded_at "$(ts)" \
       '{persona: $persona, capturedSubject: $capturedSubject, method: $method, recorded_at: $recorded_at}' \
       > "$file"
  elif has_py; then
    python3 - "$persona" "$subject" "$method" "$(ts)" "$file" <<'PYEOF'
import json, sys
persona, subject, method, now, file_path = sys.argv[1:6]
data = {"persona": persona, "capturedSubject": subject, "method": method, "recorded_at": now}
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "evidence/${persona}/identity.json"
}

# Scan the remaining args ($@, after run-id/criterion-id/kind) for an
# optional `--persona <id>` pair anywhere in the list, removing it and
# leaving the rest untouched (order-preserving) for the per-kind parsers.
# Sets globals PERSONA and STRIPPED_ARGS (an array) — a plain "return via
# echo" can't carry an array safely here, and this file has no other
# argument-stripping precedent to match, so a pair of globals scoped to this
# one call site is the simplest correct option.
PERSONA=""
STRIPPED_ARGS=()
strip_persona() {
  PERSONA=""
  STRIPPED_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --persona)
        [[ $# -ge 2 ]] || die "--persona requires <id>"
        PERSONA="$2"
        shift 2
        ;;
      *)
        STRIPPED_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# cmd_screenshot — 0.10.0, ADR-0028. Records ONE screenshot of a criterion as
# an image + sidecar pair in its evidence dir, bound at record time to the
# browser_take_screenshot call the capture hook captured:
#
#   record-evidence.sh <run> <crit> screenshot --phase <before|after> [--label <token>]
#                      [--file <path>] [--source-ref seq:<N>] [--persona <id>]
#
# Which captured call: --source-ref seq:<N> when given; otherwise the newest
# captured browser_take_screenshot that produced --file (same sha256 the hook
# took of the saved file, or — on a toolstream without that hash — the same
# file name) and that no other sidecar of this run already claims; with no
# --file either, simply the newest unclaimed one. Which file: --file when
# given; otherwise the path the capture hook resolved for that call, else its
# `filename` (tried as given, against $PWD, $CLAUDE_PROJECT_DIR and
# $PLAYWRIGHT_MCP_OUTPUT_DIR).
#
# REFUSED (exit 1, nothing written) — every one of these can never verify:
#   - a file that is not a PNG/JPEG/WebP (by magic bytes) or is > 25 MB;
#   - a --source-ref that is not seq:<N>, names no event, or names a call that
#     is not browser_take_screenshot;
#   - a file that is not what that call saved (sha256 differs from the hook's
#     hash; or, without one, a different file name);
#   - a captured call another sidecar of this run already claims (one capture
#     can evidence one screenshot, not every criterion's);
#   - with a toolstream present: no captured browser_take_screenshot at all.
# With no toolstream (capture hook off / non-Claude harness) the image is
# recorded with binding "unchecked" and a NOTE; qa-verify degrades it.
#
# Writes evidence/[<persona>/]<crit>/screenshot-<phase>[-<label>].<ext> (a
# copy, unless the driver already saved it there) and the .json sidecar next
# to it; prints the IMAGE path relative to the run dir.
# ---------------------------------------------------------------------------
# Resolved without `dirname` (pure parameter expansion): this line runs on
# EVERY invocation, including the restricted-PATH python3-fallback suites.
_RE_DIR="${BASH_SOURCE[0]%/*}"; [[ "$_RE_DIR" == "${BASH_SOURCE[0]}" ]] && _RE_DIR="."
SCREENSHOT_SH="${_RE_DIR}/screenshot-evidence.sh"

# shot_event <toolstream> <n> -> 8 lines for the event with seq n (empty when
# none): tool, screenshot.sha256, screenshot.path, screenshot.file,
# args.filename, args.fullPage (true|false|""), element/target, seq.
shot_event() {
  local tsf="$1" n="$2"
  if has_jq; then
    jq -R -r --argjson n "$n" '
      try (fromjson | select(type == "object" and .seq == $n)
        | ((.screenshot // {}) | if type == "object" then . else {} end) as $s
        | ((.args // {}) | if type == "object" then . else {} end) as $a
        | (.tool // "" | tostring),
          ($s.sha256 // "" | tostring), ($s.path // "" | tostring), ($s.file // "" | tostring),
          ($a.filename // "" | tostring),
          (if $a.fullPage == true then "true" elif $a.fullPage == false then "false" else "" end),
          ($a.element // $a.target // "" | tostring),
          (.seq | tostring)) catch empty' "$tsf" 2>/dev/null | head -n 8
  else
    python3 - "$tsf" "$n" <<'PYEOF'
import json, sys
n = int(sys.argv[2])
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if not isinstance(e, dict) or e.get("seq") != n or isinstance(e.get("seq"), bool):
        continue
    s = e.get("screenshot") if isinstance(e.get("screenshot"), dict) else {}
    a = e.get("args") if isinstance(e.get("args"), dict) else {}
    fp = a.get("fullPage")
    for v in (e.get("tool") or "", s.get("sha256") or "", s.get("path") or "", s.get("file") or "",
              a.get("filename") or "", "true" if fp is True else ("false" if fp is False else ""),
              a.get("element") or a.get("target") or "", e.get("seq")):
        print(v if isinstance(v, str) else json.dumps(v))
    break
PYEOF
  fi
}

# newest_shot_seq <toolstream> <sha-or-""> <basename-or-""> <claimed-seqs-csv>
# -> the seq of the newest captured browser_take_screenshot not in claimed
# that matches (hash when the event carries one, else file name); with both
# sha and basename empty, the newest unclaimed one. Prints nothing if none.
newest_shot_seq() {
  local tsf="$1" sha="$2" base="$3" claimed="$4"
  if has_jq; then
    jq -R -s -r --arg sha "$sha" --arg base "$base" --arg claimed ",$claimed," '
      def bn: tostring | split("/") | last;
      [ split("\n")[] | select(length > 0) | (try fromjson catch null)
        | select(type == "object" and ((.tool // "") | tostring | endswith("browser_take_screenshot")))
        | (.seq | tostring) as $sq
        | select(($claimed | contains("," + $sq + ",")) | not)
        | ((.screenshot // {}) | if type == "object" then . else {} end) as $s
        | ((.args // {}) | if type == "object" then . else {} end) as $a
        | select(
            if ($sha == "" and $base == "") then true
            elif (($s.sha256 // "") | length) > 0 then $s.sha256 == $sha
            else ([$a.filename, $s.file] | map(select(type == "string" and length > 0) | bn) | index($base)) != null
            end)
        | .seq ] | last // empty' "$tsf" 2>/dev/null
  else
    python3 - "$tsf" "$sha" "$base" ",$claimed," <<'PYEOF'
import json, sys
tsf, sha, base, claimed = sys.argv[1:5]
best = None
for line in open(tsf):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if not isinstance(e, dict) or not str(e.get("tool") or "").endswith("browser_take_screenshot"):
        continue
    if ("," + json.dumps(e.get("seq")) + ",") in claimed:
        continue
    s = e.get("screenshot") if isinstance(e.get("screenshot"), dict) else {}
    a = e.get("args") if isinstance(e.get("args"), dict) else {}
    if not (sha == "" and base == ""):
        if s.get("sha256"):
            if s.get("sha256") != sha:
                continue
        else:
            names = [str(x).split("/")[-1] for x in (a.get("filename"), s.get("file")) if isinstance(x, str) and x]
            if base not in names:
                continue
    best = e.get("seq")
if best is not None:
    print(best)
PYEOF
  fi
}

# claimed_seqs <run-id> [<exclude-sidecar>] -> CSV of the seq numbers every
# OTHER screenshot sidecar in the run already claims.
claimed_seqs() {
  local run_id="$1" exclude="${2:-}" sc ref out=""
  while IFS= read -r sc; do
    [[ -n "$sc" && "$sc" != "$exclude" ]] || continue
    if has_jq; then
      ref="$(jq -r '.provenance.sourceRef? // empty' "$sc" 2>/dev/null)"
    else
      ref="$(python3 -c 'import json,sys
try:
    p = json.load(open(sys.argv[1])).get("provenance") or {}
    print(p.get("sourceRef") or "")
except Exception:
    pass' "$sc" 2>/dev/null)"
    fi
    ref="${ref#seq:}"
    [[ "$ref" =~ ^[0-9]+$ ]] && out+="${out:+,}${ref}"
  done < <(find "$(run_dir "$run_id")/evidence" -type f -name 'screenshot-*.json' 2>/dev/null)
  printf '%s' "$out"
}

# resolve_shot_path <candidate> -> first existing file among the candidate as
# given and joined onto $PWD, $CLAUDE_PROJECT_DIR, $PLAYWRIGHT_MCP_OUTPUT_DIR.
resolve_shot_path() {
  local p="$1" base
  [[ -n "$p" ]] || return 1
  if [[ "$p" == /* ]]; then [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }; return 1; fi
  for base in "$PWD" "${CLAUDE_PROJECT_DIR:-}" "${PLAYWRIGHT_MCP_OUTPUT_DIR:-}"; do
    [[ -n "$base" && -f "${base}/${p#./}" ]] && { printf '%s' "${base}/${p#./}"; return 0; }
  done
  return 1
}

abs_path() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }

cmd_screenshot() {
  local run_id="$1" crit_id="$2" persona="$3"
  shift 3
  local phase="" label="" file="" source_ref=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)      phase="$2";      shift 2 ;;
      --label)      label="$2";      shift 2 ;;
      --file)       file="$2";       shift 2 ;;
      --source-ref) source_ref="$2"; shift 2 ;;
      *) die "Unknown option for kind 'screenshot': $1" ;;
    esac
  done
  case "$phase" in
    before|after) ;;
    *) die "kind 'screenshot' requires --phase before|after (before = the UI state the act starts from; after = the state the assertion reads)" ;;
  esac
  if [[ -n "$label" ]]; then
    [[ "$label" =~ ^[A-Za-z0-9_-]{1,40}$ ]] || die "--label must be 1-40 characters of [A-Za-z0-9_-] (it becomes part of the file name)"
  fi
  [[ -f "$SCREENSHOT_SH" ]] || die "screenshot-evidence.sh not found next to record-evidence.sh"

  local tsf has_ts=0 n="" ev="" ev_tool="" ev_sha="" ev_path="" ev_file="" ev_fname="" ev_full="" ev_elem=""
  tsf="$(run_dir "$run_id")/toolstream.jsonl"
  [[ -s "$tsf" ]] && has_ts=1

  if [[ -n "$source_ref" ]]; then
    if [[ "$source_ref" =~ ^seq:([0-9]+)$ ]]; then n="${BASH_REMATCH[1]}"
    elif [[ "$source_ref" =~ ^[0-9]+$ ]]; then n="$source_ref"
    else die "--source-ref '${source_ref}' is not a toolstream pointer — pass seq:<N> of the captured browser_take_screenshot call, or omit it to bind the newest matching capture. Nothing was recorded."
    fi
  fi

  load_event() {
    ev="$(shot_event "$tsf" "$1")"
    [[ -n "$ev" ]] || return 1
    ev_tool="$(sed -n 1p <<< "$ev")"; ev_sha="$(sed -n 2p <<< "$ev")"; ev_path="$(sed -n 3p <<< "$ev")"
    ev_file="$(sed -n 4p <<< "$ev")"; ev_fname="$(sed -n 5p <<< "$ev")"; ev_full="$(sed -n 6p <<< "$ev")"
    ev_elem="$(sed -n 7p <<< "$ev")"
  }

  local dest_dir stem
  dest_dir="$(evidence_dir "$run_id" "$crit_id" "$persona")"
  stem="screenshot-${phase}${label:+-${label}}"
  local own_sidecar="${dest_dir}/${stem}.json"
  local claimed=""
  [[ "$has_ts" -eq 1 ]] && claimed="$(claimed_seqs "$run_id" "$own_sidecar")"

  if [[ -n "$n" && "$has_ts" -eq 1 ]]; then
    load_event "$n" || die "--source-ref seq:${n} names no event in ${tsf}. Nothing was recorded."
    [[ "$ev_tool" == *browser_take_screenshot ]] \
      || die "--source-ref seq:${n} is a '${ev_tool}' call, not browser_take_screenshot — a screenshot binds only to the capture call that saved it. Nothing was recorded."
    [[ ",${claimed}," == *",${n},"* ]] \
      && die "captured call seq:${n} is already claimed by another screenshot of this run — take a fresh browser_take_screenshot for this criterion. Nothing was recorded."
  elif [[ -z "$file" && "$has_ts" -eq 1 ]]; then
    n="$(newest_shot_seq "$tsf" "" "" "$claimed")"
    [[ -n "$n" ]] || die "no unclaimed browser_take_screenshot call is captured in ${tsf} — take the screenshot with browser_take_screenshot (filename: .qa/runs/${run_id}/$(evidence_dir_rel "$crit_id" "$persona")/${stem}.png) first. Nothing was recorded."
    load_event "$n"
  fi

  # Resolve the source file.
  local src=""
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || die "--file not found: ${file}"
    src="$file"
  elif [[ -n "$ev" ]]; then
    src="$(resolve_shot_path "$ev_path" || resolve_shot_path "$ev_fname" || resolve_shot_path "$ev_file")" \
      || die "cannot find the file captured call seq:${n} saved ('${ev_fname:-$ev_file}') — pass --file <path> to where the driver wrote it. Nothing was recorded."
  else
    die "kind 'screenshot' needs --file <path> when the run has no toolstream (capture hook off)."
  fi

  local info ext mime bytes sha
  info="$(bash "$SCREENSHOT_SH" inspect "$src")" || exit 1
  read -r ext mime bytes sha <<< "$info"

  local binding="unchecked"
  if [[ "$has_ts" -eq 1 ]]; then
    if [[ -z "$ev" ]]; then
      n="$(newest_shot_seq "$tsf" "$sha" "$(basename "$src")" "$claimed")"
      [[ -n "$n" ]] || die "no captured, unclaimed browser_take_screenshot call produced ${src} (neither its sha256 nor its file name matches one in ${tsf}) — take the screenshot with browser_take_screenshot so the capture hook sees it, then record it. Nothing was recorded."
      load_event "$n"
    fi
    if [[ -n "$ev_sha" ]]; then
      [[ "$ev_sha" == "$sha" ]] || die "${src} is not the image captured call seq:${n} saved (its sha256 differs from the one the capture hook took) — record the file that call wrote. Nothing was recorded."
      binding="sha256"
    else
      local want=""
      [[ -n "$ev_fname" ]] && want="${ev_fname##*/}"
      [[ -z "$want" && -n "$ev_file" ]] && want="${ev_file##*/}"
      [[ -n "$want" && "$want" == "$(basename "$src")" ]] \
        || die "${src} is not the file captured call seq:${n} saved ('${want:-<no file name captured>}') — record the file that call wrote. Nothing was recorded."
      binding="filename"
    fi
  else
    [[ -n "$source_ref" ]] && echo "NOTE: --source-ref seq:${n} recorded unchecked — no toolstream exists yet for run '${run_id}' (capture hook off?); qa-verify degrades to no-toolstream." >&2
    echo "NOTE: screenshot recorded without a toolstream — it cannot be bound to a captured call; qa-verify degrades confidence for it." >&2
  fi

  mkdir -p "$dest_dir"
  local image="${stem}.${ext}" dest
  dest="${dest_dir}/${image}"
  local old
  for old in png jpg webp; do
    [[ "$old" != "$ext" ]] && rm -f "${dest_dir}/${stem}.${old}"
  done
  if [[ "$(abs_path "$src")" != "$(abs_path "$dest")" ]]; then
    cp "$src" "$dest" || die "failed to copy ${src} into ${dest}"
  fi

  local source_ref_out=""
  [[ -n "$n" ]] && source_ref_out="seq:${n}"
  local now; now="$(ts)"
  if has_jq; then
    jq -n --arg criterion_id "$crit_id" --arg run_id "$run_id" --arg recorded_at "$now" \
      --arg phase "$phase" --arg label "$label" --arg image "$image" --arg mime "$mime" \
      --argjson bytes "$bytes" --arg sha256 "$sha" --arg full "$ev_full" --arg element "$ev_elem" \
      --arg sourceFile "$src" --arg binding "$binding" --arg sourceRef "$source_ref_out" \
      '{criterion_id: $criterion_id, run_id: $run_id, kind: "screenshot", recorded_at: $recorded_at,
        phase: $phase}
       + (if $label != "" then {label: $label} else {} end)
       + {image: $image, mime: $mime, bytes: $bytes, sha256: $sha256,
          fullPage: (if $full == "true" then true elif $full == "false" then false else null end)}
       + (if $element != "" then {element: $element} else {} end)
       + {sourceFile: $sourceFile, binding: $binding}
       + (if $sourceRef != "" then {provenance: {sourceRef: $sourceRef, boundAt: $recorded_at}} else {} end)' \
      > "$own_sidecar" || die "failed to write ${own_sidecar}"
  elif has_py; then
    python3 - "$own_sidecar" "$crit_id" "$run_id" "$now" "$phase" "$label" "$image" "$mime" "$bytes" "$sha" "$ev_full" "$ev_elem" "$src" "$binding" "$source_ref_out" <<'PYEOF' || die "failed to write ${own_sidecar}"
import json, sys
(out, crit, run, now, phase, label, image, mime, nbytes, sha, full, element, src, binding, ref) = sys.argv[1:16]
d = {"criterion_id": crit, "run_id": run, "kind": "screenshot", "recorded_at": now, "phase": phase}
if label:
    d["label"] = label
d.update({"image": image, "mime": mime, "bytes": int(nbytes), "sha256": sha,
          "fullPage": True if full == "true" else (False if full == "false" else None)})
if element:
    d["element"] = element
d.update({"sourceFile": src, "binding": binding})
if ref:
    d["provenance"] = {"sourceRef": ref, "boundAt": now}
with open(out, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
  else
    die "record-evidence.sh needs either 'jq' or 'python3' to write JSON safely; neither was found on PATH."
  fi

  echo "$(evidence_dir_rel "$crit_id" "$persona")/${image}"
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -ge 3 ]] || die "Usage: record-evidence.sh <run-id> <criterion-id> <kind> [--persona <id>] [--key val ...]\n       kind: bake | computed | probe | action-trace | identity | screenshot"

  local run_id="$1" crit_id="$2" kind="$3"
  shift 3

  # Fix 28: reject a path-traversal run-id/criterion-id BEFORE it can reach
  # evidence_dir()'s path building.
  validate_token "$run_id" "run-id"
  validate_token "$crit_id" "criterion-id"

  # Validate kind up front (also used to name the artifact for error text).
  artifact_for_kind "$kind" >/dev/null

  strip_persona "$@"
  set -- "${STRIPPED_ARGS[@]}"

  # Fix 28: reject a path-traversal persona BEFORE it can reach
  # evidence_dir()'s persona-scoped path building. Empty persona
  # ("" / omitted) is fine — that's the back-compat no-persona case.
  [[ -n "$PERSONA" ]] && validate_token "$PERSONA" "--persona"

  case "$kind" in
    bake)     cmd_bake "$run_id" "$crit_id" "$PERSONA" "$@" ;;
    computed) cmd_computed "$run_id" "$crit_id" "$PERSONA" "$@" ;;
    probe)    cmd_probe "$run_id" "$crit_id" "$PERSONA" "$@" ;;
    action-trace) cmd_action_trace "$run_id" "$crit_id" "$PERSONA" "$@" ;;
    identity) cmd_identity "$run_id" "$crit_id" "$PERSONA" "$@" ;;
    screenshot) cmd_screenshot "$run_id" "$crit_id" "$PERSONA" "$@" ;;
  esac
}

main "$@"
