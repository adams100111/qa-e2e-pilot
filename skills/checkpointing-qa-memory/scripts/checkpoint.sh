#!/usr/bin/env bash
# checkpoint.sh — manage per-criterion checkpoint records for a qa-e2e-pilot Run.
#
# USAGE:
#   checkpoint.sh <run-id> <criterion-id> <verdict>
#       Upsert a checkpoint entry for one criterion.
#       verdict: pass | fail | blocked | deferred | error
#
#   checkpoint.sh --resume <run-id>
#       Print the last completed criterion + verdict for resume.
#       Exit 0 if at least one checkpoint exists; exit 1 if none (fresh run).
#
#   checkpoint.sh --list <run-id>
#       Print all checkpointed criteria and their verdicts (tsv: id verdict confidence).
#
# OPTIONS (upsert mode only):
#   --confidence <high|low>     Default: high
#   --phase <phase-label>       Default: verify
#   --last-action <text>        One-line description of the final action taken
#   --evidence-refs <a,b,c>     Comma-separated relative paths under .qa/runs/<run-id>/
#   --bug-ref <bug-id>          Bug log entry id if verdict is fail|error
#   --persona <id>              OPTIONAL. When role-sensitive criteria are run
#                               per persona (e.g. super-admin vs participant),
#                               the record's IDENTITY becomes the PAIR
#                               (criterion-id, persona) — a pass for C1 under
#                               persona A and any verdict for C1 under persona
#                               B are TWO SEPARATE records; upserting one never
#                               replaces the other. Omitting --persona keeps
#                               today's behavior exactly: identity is
#                               criterion-id alone (persona stored as "").
#                               --resume/--list surface the persona so a
#                               resumed run never reads one persona's pass as
#                               covering another persona's untested case.
#   --kinds <bake,computed,probe>
#                               CSV subset of evidence kinds this criterion is
#                               backed by. Stored on the record. On a `pass`
#                               verdict, EACH kind's canonical artifact under
#                               .qa/runs/<run-id>/evidence/<criterion-id>/ (or,
#                               when --persona is set, under
#                               evidence/<persona>/<criterion-id>/) is
#                               required to exist, be non-empty, parse as
#                               JSON, and contain that kind's required keys
#                               (see record-evidence.sh) — "a green toast is
#                               not a pass". Any miss REJECTS the upsert
#                               (non-zero exit, nothing written) before the
#                               record is touched. Non-`pass` verdicts skip
#                               this gate entirely. Omitting --kinds on a
#                               `pass` is back-compat for untagged criteria —
#                               no evidence is required, but a stderr note
#                               flags the pass as un-gated.
#
# DEPENDENCIES: bash, coreutils (date, mkdir, mv, cat), and EITHER jq OR python3
#               for safe JSON updates (jq preferred; python3 used as fallback).
#
# NOTE: All paths are relative to the current working directory (project root).

set -euo pipefail

QA_BASE=".qa/runs"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() { command -v jq >/dev/null 2>&1; }

has_py() { command -v python3 >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Fix 28 — reject any run-id / criterion-id / persona value that could
# escape .qa/runs/<run-id>/ when interpolated into a path (e.g.
# --persona '../../../evil'). A persona/criterion/run id must be a simple
# token: no '/' or '\', no '..' anywhere in the value, and no leading '-'
# (which could be misread as another flag). Dies with a clear message
# BEFORE the value is ever used to build a path — this must run before
# run_dir()/evidence_dir() see the value.
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

checkpoint_file() {
  local run_id="$1"
  echo "$(run_dir "$run_id")/checkpoint.json"
}

ensure_run_dir() {
  local run_id="$1"
  local dir
  dir="$(run_dir "$run_id")"
  mkdir -p "$dir"
}

# ---------------------------------------------------------------------------
# init an empty checkpoint file if absent
# ---------------------------------------------------------------------------

init_checkpoint() {
  local run_id="$1"
  local file
  file="$(checkpoint_file "$run_id")"
  if [[ ! -f "$file" ]]; then
    cat > "$file" <<EOF
{
  "run_id": "${run_id}",
  "updated_at": "$(ts)",
  "criteria": []
}
EOF
  fi
}

# ---------------------------------------------------------------------------
# upsert one criterion using jq (preferred)
# ---------------------------------------------------------------------------

upsert_jq() {
  local file="$1" crit_id="$2" verdict="$3" confidence="$4" phase="$5"
  local last_action="$6" evidence_refs_json="$7" bug_ref="$8" kinds_json="$9"
  local persona="${10}"
  local now
  now="$(ts)"

  local tmp
  tmp="${file}.tmp.$$"

  # Fix 27 (temp-file leak): a `trap ... RETURN` does NOT fire when `set -e`
  # unwinds out of this function on jq's failure (verified — RETURN/EXIT
  # traps set on a local scope do not survive an errexit-triggered abort out
  # of that scope), so cleanup must be explicit: run jq inside `if ! ...`
  # (which suspends errexit for the check) and rm the tmp file ourselves
  # before dying, rather than let a bare `cmd1 && cmd2` fail out from under
  # `set -e` with the tmp file left behind.
  #
  # Identity for matching an existing record is the PAIR (criterion_id,
  # persona). persona defaults to "" (back-compat: identity is criterion_id
  # alone, exactly today's behavior) — compare via `(.persona // "")` so
  # records written before this field existed (none should exist within a
  # single run created by this script, but this keeps the filter total) are
  # treated as persona "".
  if ! jq --arg cid "$crit_id" \
     --arg verdict "$verdict" \
     --arg confidence "$confidence" \
     --arg phase "$phase" \
     --arg last_action "$last_action" \
     --argjson evidence_refs "$evidence_refs_json" \
     --arg bug_ref "$bug_ref" \
     --argjson kinds "$kinds_json" \
     --arg persona "$persona" \
     --arg now "$now" \
  '
    .updated_at = $now |
    if any(.criteria[]; .criterion_id == $cid and ((.persona // "") == $persona)) then
      .criteria = [
        .criteria[] |
        if .criterion_id == $cid and ((.persona // "") == $persona) then
          .verdict        = $verdict        |
          .confidence     = $confidence     |
          .phase          = $phase          |
          .last_action    = $last_action    |
          .evidence_refs  = $evidence_refs  |
          .bug_ref        = (if $bug_ref == "" then null else $bug_ref end) |
          .kinds          = $kinds          |
          .persona        = $persona        |
          .checkpointed_at = $now
        else . end
      ]
    else
      .criteria += [{
        "criterion_id":   $cid,
        "verdict":        $verdict,
        "confidence":     $confidence,
        "phase":          $phase,
        "last_action":    $last_action,
        "evidence_refs":  $evidence_refs,
        "bug_ref":        (if $bug_ref == "" then null else $bug_ref end),
        "kinds":          $kinds,
        "persona":        $persona,
        "checkpointed_at": $now
      }]
    end
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    die "jq failed to build the updated checkpoint record (malformed --kinds/--evidence-refs JSON or a jq processing error) — nothing written."
  fi

  # Fix 2728 (temp-file leak, part 2): jq succeeding does not guarantee the
  # subsequent mv succeeds (disk full, permission error, etc). Guard it the
  # same way as the jq step above — suspend errexit via `if ! ...`, clean up
  # the temp file ourselves, and die with a clear message — rather than let
  # `set -e` abort out from under a bare `mv` with the tmp file left behind.
  if ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    die "Failed to move the updated checkpoint into place (mv \"${tmp}\" -> \"${file}\" failed — disk full or permission error?) — cleaned up the temp file, nothing changed."
  fi
}

# ---------------------------------------------------------------------------
# upsert one criterion using python3 (fallback, no jq — robust JSON handling)
# ---------------------------------------------------------------------------

upsert_py() {
  local file="$1" crit_id="$2" verdict="$3" confidence="$4" phase="$5"
  local last_action="$6" evidence_refs_json="$7" bug_ref="$8" kinds_json="$9"
  local persona="${10}"
  local now
  now="$(ts)"

  python3 - "$file" "$crit_id" "$verdict" "$confidence" "$phase" \
            "$last_action" "$evidence_refs_json" "$bug_ref" "$kinds_json" "$persona" "$now" <<'PYEOF'
import json, sys

def parse_json_or_die(raw, label):
    # Fix 27: the python3 fallback must NOT silently substitute [] on a
    # JSON decode error — that is exactly the divergence the audit found
    # (jq hard-fails via --argjson on malformed JSON; python3 must fail the
    # same way, not succeed-with-[] and report a false pass).
    if not raw:
        return []
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"ERROR: {label} value is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)

(file_path, cid, verdict, confidence, phase,
 last_action, evidence_refs_json, bug_ref, kinds_json, persona, now) = sys.argv[1:12]
evidence_refs = parse_json_or_die(evidence_refs_json, "evidence_refs")
kinds = parse_json_or_die(kinds_json, "kinds")
with open(file_path) as f:
    data = json.load(f)
entry = {
    "criterion_id":    cid,
    "verdict":         verdict,
    "confidence":      confidence,
    "phase":           phase,
    "last_action":     last_action,
    "evidence_refs":   evidence_refs,
    "bug_ref":         bug_ref or None,
    "kinds":           kinds,
    "persona":         persona,
    "checkpointed_at": now,
}
data["updated_at"] = now
criteria = data.setdefault("criteria", [])
# Identity for matching an existing record is the PAIR (criterion_id,
# persona). persona defaults to "" (back-compat: identity is criterion_id
# alone, exactly today's behavior).
for i, c in enumerate(criteria):
    if c.get("criterion_id") == cid and (c.get("persona") or "") == persona:
        criteria[i] = entry
        break
else:
    criteria.append(entry)
with open(file_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ---------------------------------------------------------------------------
# --resume: print last completed criterion
# ---------------------------------------------------------------------------

cmd_resume() {
  local run_id="$1"
  validate_token "$run_id" "run-id"
  local file
  file="$(checkpoint_file "$run_id")"
  [[ -f "$file" ]] || { echo "No checkpoint file found for run: ${run_id}" >&2; exit 1; }

  if has_jq; then
    local count
    count=$(jq '.criteria | length' "$file")
    if [[ "$count" -eq 0 ]]; then
      echo "RESUME: no criteria checkpointed yet — start from the beginning."
      exit 1
    fi
    jq -r '
      .criteria |
      last |
      . as $c |
      ($c.kinds // []) as $kinds |
      (if ($kinds | length) > 0 then ($kinds | join(",")) else "-" end) as $kinds_str |
      (if $c.verdict == "pass" then (if ($kinds | length) > 0 then "complete" else "ungated" end) else "n/a" end) as $evidence |
      (($c.persona // "") | if . == "" then "(none)" else . end) as $persona_str |
      "RESUME cursor:\n  criterion_id:  \($c.criterion_id)\n  verdict:       \($c.verdict)\n  confidence:    \($c.confidence)\n  phase:         \($c.phase)\n  last_action:   \($c.last_action)\n  checkpointed:  \($c.checkpointed_at)\n  persona:       \($persona_str)\n  kinds:         \($kinds_str)\n  evidence:      \($evidence)"
    ' "$file"
    echo ""
    echo "Skip all criteria up to and including: $(jq -r '.criteria | last | .criterion_id' "$file")"
  elif has_py; then
    python3 - "$file" <<'PYEOF' || exit 1
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
criteria = data.get("criteria", [])
if not criteria:
    print("RESUME: no criteria checkpointed yet — start from the beginning.")
    sys.exit(1)
c = criteria[-1]
print("RESUME cursor:")
for k in ("criterion_id", "verdict", "confidence", "phase", "last_action", "checkpointed_at"):
    print(f"  {k}: {c.get(k)}")
kinds = c.get("kinds") or []
kinds_str = ",".join(kinds) if kinds else "-"
if c.get("verdict") == "pass":
    evidence = "complete" if kinds else "ungated"
else:
    evidence = "n/a"
persona_str = c.get("persona") or "(none)"
print(f"  persona: {persona_str}")
print(f"  kinds: {kinds_str}")
print(f"  evidence: {evidence}")
print()
print(f"Skip all criteria up to and including: {c.get('criterion_id')}")
PYEOF
  else
    die "checkpoint.sh --resume needs either 'jq' or 'python3'."
  fi
}

# ---------------------------------------------------------------------------
# --list: print all checkpointed criteria
# ---------------------------------------------------------------------------

cmd_list() {
  local run_id="$1"
  validate_token "$run_id" "run-id"
  local file
  file="$(checkpoint_file "$run_id")"
  [[ -f "$file" ]] || { echo "No checkpoint file found for run: ${run_id}" >&2; exit 1; }

  # NOTE on `persona`: persona is its OWN trailing TSV column, appended after
  # `evidence` — the existing 6 columns keep their positions unchanged, so
  # any consumer reading columns 1-6 positionally is unaffected. Previously
  # persona was folded into the criterion_id CELL as "<criterion_id>@<persona>",
  # which meant a criterion_id containing a literal '@' would collide with
  # that display encoding and conflate two distinct rows/identities. The
  # criterion_id column is now ALWAYS the raw criterion_id, never decorated.
  # persona == "" (back-compat / no --persona) renders the trailing column
  # as an empty string.
  if has_jq; then
    echo "criterion_id	verdict	confidence	checkpointed_at	kinds	evidence	persona"
    jq -r '
      .criteria[] |
      . as $c |
      ($c.kinds // []) as $kinds |
      (if ($kinds | length) > 0 then ($kinds | join(",")) else "-" end) as $kinds_str |
      (if $c.verdict == "pass" then (if ($kinds | length) > 0 then "complete" else "ungated" end) else "n/a" end) as $evidence |
      (($c.persona // "")) as $persona |
      [$c.criterion_id, $c.verdict, $c.confidence, $c.checkpointed_at, $kinds_str, $evidence, $persona] | @tsv
    ' "$file"
  elif has_py; then
    python3 - "$file" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print("criterion_id\tverdict\tconfidence\tcheckpointed_at\tkinds\tevidence\tpersona")
for c in data.get("criteria", []):
    kinds = c.get("kinds") or []
    kinds_str = ",".join(kinds) if kinds else "-"
    if c.get("verdict") == "pass":
        evidence = "complete" if kinds else "ungated"
    else:
        evidence = "n/a"
    persona = c.get("persona") or ""
    cid = c.get("criterion_id", "")
    row = [cid] + [str(c.get(k, "")) for k in ("verdict", "confidence", "checkpointed_at")]
    row += [kinds_str, evidence, persona]
    print("\t".join(row))
PYEOF
  else
    die "checkpoint.sh --list needs either 'jq' or 'python3'."
  fi
}

# ---------------------------------------------------------------------------
# evidence gate — on a `pass` upsert, require each --kinds entry's canonical
# artifact to exist, be non-empty, parse as JSON, and contain its required
# keys. "A green toast is not a pass": this is what makes that a machine fact.
# ---------------------------------------------------------------------------

# trim leading/trailing whitespace using pure bash parameter expansion (no
# `tr`/`awk` dependency — checkpoint.sh's documented deps are bash, coreutils,
# and jq-or-python3 only).
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

# convert a CSV string ("a, b,c") into a JSON array string (["a","b","c"]),
# using a PROPER JSON encoder — not string concatenation (Fix 27). The old
# implementation built `"\"${item}\""` by hand, which produced INVALID JSON
# for any value containing a `"` or `\` (e.g. --kinds 'bake"evil'); jq's
# --argjson then hard-failed while the python3 fallback silently swallowed
# the parse error and substituted `[]`, so a `pass` recorded on a
# python3-only host lost its evidence trail with no error at all. Here,
# every item — including one with embedded quotes/backslashes/newlines —
# round-trips as data, identically whichever engine builds it: jq via
# `--args`/$ARGS.positional (jq does the escaping), python3 via
# json.dumps() (same guarantee). Whichever engine is actually available is
# also the engine that will process the array downstream (upsert_jq /
# upsert_py), so this never introduces an encode/decode engine mismatch.
csv_to_json_array() {
  local csv="$1"
  local -a arr items=()
  IFS=',' read -ra arr <<< "$csv"
  local item trimmed
  for item in "${arr[@]}"; do
    trimmed="$(trim "$item")"
    [[ -z "$trimmed" ]] && continue
    items+=("$trimmed")
  done

  if [[ "${#items[@]}" -eq 0 ]]; then
    echo "[]"
    return 0
  fi

  if has_jq; then
    jq -cn --args '$ARGS.positional' -- "${items[@]}" \
      || die "Failed to JSON-encode CSV value(s) via jq: ${csv}"
  elif has_py; then
    python3 -c '
import json, sys
print(json.dumps(sys.argv[1:]))
' "${items[@]}" \
      || die "Failed to JSON-encode CSV value(s) via python3: ${csv}"
  else
    die "csv_to_json_array needs either 'jq' or 'python3' to safely encode JSON."
  fi
}

# validate that $1 is syntactically valid JSON (used for the raw-JSON-array
# passthrough form of --evidence-refs, e.g. '["a","b"]') — dies with a clear
# message naming $2 (the option name) BEFORE the value ever reaches
# upsert_jq/upsert_py, so a malformed passthrough value fails the SAME way
# (non-zero, nothing written) regardless of which JSON engine is on PATH —
# closing the other half of Fix 27 (the jq/python3 divergence was not only
# in the CSV builder, but in trusting an unvalidated raw value).
validate_json_string() {
  local json_str="$1" opt_name="$2"
  if has_jq; then
    jq -e . >/dev/null 2>&1 <<< "$json_str" \
      || die "${opt_name} value is not valid JSON: ${json_str}"
  elif has_py; then
    python3 -c 'import json, sys
json.loads(sys.argv[1])' "$json_str" >/dev/null 2>&1 \
      || die "${opt_name} value is not valid JSON: ${json_str}"
  else
    die "checkpoint.sh needs either 'jq' or 'python3' to validate JSON."
  fi
}

# artifact filename for a given kind (mirrors record-evidence.sh's mapping)
kind_artifact() {
  case "$1" in
    bake)     echo "bake-read-back.json" ;;
    computed) echo "recompute.json" ;;
    probe)    echo "network-response.json" ;;
    *) die "Invalid kind '$1' in --kinds. Must be a CSV subset of: bake | computed | probe" ;;
  esac
}

# space-separated required keys for a given kind (key PRESENCE only — no
# value/type comparisons here; VALUE is checked separately by
# gate_value_check below, since record-evidence.sh writes e.g. `status` as a
# JSON number and `multiplicity` as a string like "N").
kind_required_keys() {
  case "$1" in
    bake)     echo "readBack multiplicity" ;;
    computed) echo "oracle observed match" ;;
    probe)    echo "status shape ok" ;;
    *)        return 1 ;;
  esac
}

# true (exit 0) iff $1 is a syntactically valid JSON document.
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

# print the reject message for one kind/artifact/reason to stderr.
gate_reject() {
  local crit_id="$1" kind="$2" rel_path="$3" reason="$4"
  echo "EVIDENCE GATE: pass rejected for criterion '${crit_id}' — kind '${kind}' artifact '${rel_path}' is ${reason}. Supply the evidence (record-evidence.sh) or record \`blocked\`." >&2
}

# ---------------------------------------------------------------------------
# value-aware gate — beyond key PRESENCE (above), this rejects a `pass` whose
# evidence VALUE itself proves a fail: computed.match:false (recompute
# diverged), probe.ok:false-or-missing (the probe did NOT confirm its
# expectation — note this deliberately never inspects the raw HTTP status
# code/range, since a cross-role ABSENCE probe legitimately expects
# 403/404), or bake.readBack:null while multiplicity != "0" (nothing
# persisted, except a legitimate empty 0-multiplicity state). This is the
# fix for the exact false-green the presence-only gate let through.
# ---------------------------------------------------------------------------

# print the value-contradiction reject message for one kind/artifact/reason.
gate_reject_value() {
  local crit_id="$1" kind="$2" rel_path="$3" reason="$4"
  echo "EVIDENCE GATE: pass rejected for ${crit_id} — ${kind} evidence ${reason}; record 'fail' or supply corrected evidence." >&2
}

# true (exit 0) iff the JSON value at key $2 in file $1 is the JSON boolean
# `true` (not the string "true", not merely truthy).
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
# non-null whenever multiplicity != "0" (a legitimate empty-state
# 0-multiplicity criterion may have null/empty readBack).
json_bake_value_ok() {
  local file="$1"
  local mult
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

# Validate the evidence VALUE (not just key presence) for one kind. Returns 0
# if consistent with a `pass`; returns 1 (having already printed a
# gate_reject_value message) otherwise.
gate_value_check() {
  local crit_id="$1" kind="$2" rel_path="$3" full_path="$4"
  case "$kind" in
    computed)
      if ! json_value_is_true "$full_path" "match"; then
        gate_reject_value "$crit_id" "computed" "$rel_path" "shows match:false (recompute diverged)"
        return 1
      fi
      ;;
    bake)
      if ! json_bake_value_ok "$full_path"; then
        gate_reject_value "$crit_id" "bake" "$rel_path" "shows readBack:null with non-zero multiplicity (nothing persisted)"
        return 1
      fi
      ;;
    probe)
      if ! json_value_is_true "$full_path" "ok"; then
        gate_reject_value "$crit_id" "probe" "$rel_path" "shows ok:false or missing (the probe did not confirm its expectation)"
        return 1
      fi
      ;;
  esac
  return 0
}

# Validate every kind in the CSV `$3` for criterion `$2` under run `$1`.
# Optional `$4` is the persona: when set, the gate looks for each artifact
# under the persona-scoped path evidence/<persona>/<crit>/<artifact>.json
# (matching record-evidence.sh's --persona-scoped write path) instead of the
# default evidence/<crit>/<artifact>.json — so two personas' bakes never
# collide or satisfy each other's gate.
# Returns 0 if all pass the gate; returns 1 (having already printed a
# gate_reject message) on the FIRST failure — called before any record is
# written, so a rejected pass mutates nothing.
gate_pass() {
  local run_id="$1" crit_id="$2" kinds_csv="$3" persona="${4:-}"
  local kind artifact rel_path full_path required_keys key

  local -a kinds_arr
  IFS=',' read -ra kinds_arr <<< "$kinds_csv"

  for kind in "${kinds_arr[@]}"; do
    kind="$(trim "$kind")"
    [[ -z "$kind" ]] && continue

    # Detect an unknown kind name explicitly, here, before calling
    # kind_artifact(). kind_artifact's own `die` runs inside a command
    # substitution (`artifact="$(kind_artifact "$kind")"`); since gate_pass is
    # invoked as `gate_pass ... || exit 1`, errexit is suspended for its
    # entire call tree, so that `die`'s `exit 1` would only end the
    # subshell — the assignment would silently continue with an empty
    # $artifact, producing a second, fabricated "missing" reject message.
    # Fail fast here instead, with exactly one message.
    case "$kind" in
      bake|computed|probe) ;;
      *)
        echo "EVIDENCE GATE: unknown kind '${kind}' in --kinds (allowed: bake|computed|probe)." >&2
        return 1
        ;;
    esac

    artifact="$(kind_artifact "$kind")"
    if [[ -n "$persona" ]]; then
      rel_path="evidence/${persona}/${crit_id}/${artifact}"
    else
      rel_path="evidence/${crit_id}/${artifact}"
    fi
    full_path="$(run_dir "$run_id")/${rel_path}"

    if [[ ! -f "$full_path" ]]; then
      gate_reject "$crit_id" "$kind" "$rel_path" "missing"
      return 1
    fi
    if [[ ! -s "$full_path" ]]; then
      gate_reject "$crit_id" "$kind" "$rel_path" "empty"
      return 1
    fi
    if ! json_is_valid "$full_path"; then
      gate_reject "$crit_id" "$kind" "$rel_path" "not valid JSON"
      return 1
    fi

    required_keys="$(kind_required_keys "$kind")"
    for key in $required_keys; do
      if ! json_has_key "$full_path" "$key"; then
        gate_reject "$crit_id" "$kind" "$rel_path" "missing required key '${key}'"
        return 1
      fi
    done

    # value-aware check: reject a `pass` whose evidence VALUE contradicts it
    # (e.g. computed.match:false, probe.ok:false, bake.readBack:null with
    # non-zero multiplicity) — presence alone is not enough.
    gate_value_check "$crit_id" "$kind" "$rel_path" "$full_path" || return 1
  done

  return 0
}

# ---------------------------------------------------------------------------
# upsert mode
# ---------------------------------------------------------------------------

cmd_upsert() {
  local run_id="$1" crit_id="$2" verdict="$3"
  shift 3

  # Fix 28: reject a path-traversal run-id/criterion-id BEFORE it can reach
  # run_dir()/gate_pass()'s path building.
  validate_token "$run_id" "run-id"
  validate_token "$crit_id" "criterion-id"

  local confidence="high"
  local phase="verify"
  local last_action=""
  local evidence_refs="[]"
  local bug_ref=""
  local kinds_csv=""
  local persona=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --confidence)   confidence="$2";    shift 2 ;;
      --phase)        phase="$2";         shift 2 ;;
      --last-action)  last_action="$2";   shift 2 ;;
      --evidence-refs)
        # Accept comma-separated paths or a raw JSON array. Both paths now
        # go through a PROPER encoder/validator (Fix 27) instead of the old
        # hand-rolled awk string-concat, which produced invalid JSON (and a
        # silent jq/python3 divergence) on any value containing a `"`/`\`.
        if [[ "$2" == \[* ]]; then
          validate_json_string "$2" "--evidence-refs"
          evidence_refs="$2"
        else
          evidence_refs="$(csv_to_json_array "$2")"
        fi
        shift 2 ;;
      --bug-ref)      bug_ref="$2";       shift 2 ;;
      --kinds)        kinds_csv="$2";     shift 2 ;;
      --persona)      persona="$2";       shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  # Fix 28: reject a path-traversal persona BEFORE it can reach gate_pass()'s
  # persona-scoped path building. Empty persona ("" / omitted) is fine —
  # that's the back-compat no-persona case.
  [[ -n "$persona" ]] && validate_token "$persona" "--persona"

  # Validate verdict
  case "$verdict" in
    pass|fail|blocked|deferred|error) ;;
    *) die "Invalid verdict '${verdict}'. Must be: pass | fail | blocked | deferred | error" ;;
  esac

  # Validate confidence
  case "$confidence" in
    high|low) ;;
    *) die "Invalid confidence '${confidence}'. Must be: high | low" ;;
  esac

  local kinds_json="[]"
  if [[ -n "$kinds_csv" ]]; then
    kinds_json="$(csv_to_json_array "$kinds_csv")"
  fi

  # The evidence gate: only `pass` is gated; non-pass verdicts (fail|blocked|
  # deferred|error) are exempt regardless of --kinds. Absent --kinds on a
  # pass is back-compat (untagged criteria) but un-gated — note it and move on.
  if [[ "$verdict" == "pass" ]]; then
    if [[ -z "$kinds_csv" ]]; then
      echo "NOTE: pass recorded for criterion '${crit_id}' with no --kinds specified — evidence gate not enforced (un-gated)." >&2
    else
      gate_pass "$run_id" "$crit_id" "$kinds_csv" "$persona" || exit 1
    fi
  fi

  ensure_run_dir "$run_id"
  init_checkpoint "$run_id"

  local file
  file="$(checkpoint_file "$run_id")"

  if has_jq; then
    upsert_jq "$file" "$crit_id" "$verdict" "$confidence" "$phase" \
              "$last_action" "$evidence_refs" "$bug_ref" "$kinds_json" "$persona"
  elif has_py; then
    upsert_py "$file" "$crit_id" "$verdict" "$confidence" "$phase" \
              "$last_action" "$evidence_refs" "$bug_ref" "$kinds_json" "$persona"
  else
    die "checkpoint.sh needs either 'jq' or 'python3' to update JSON safely; neither was found on PATH."
  fi

  if [[ -n "$persona" ]]; then
    echo "Checkpointed: run=${run_id} criterion=${crit_id} persona=${persona} verdict=${verdict} confidence=${confidence}"
  else
    echo "Checkpointed: run=${run_id} criterion=${crit_id} verdict=${verdict} confidence=${confidence}"
  fi
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -lt 1 ]] && die "Usage: checkpoint.sh <run-id> <criterion-id> <verdict> [options]\n       checkpoint.sh --resume <run-id>\n       checkpoint.sh --list <run-id>"

  case "$1" in
    --resume)
      [[ $# -lt 2 ]] && die "--resume requires <run-id>"
      cmd_resume "$2"
      ;;
    --list)
      [[ $# -lt 2 ]] && die "--list requires <run-id>"
      cmd_list "$2"
      ;;
    -*)
      die "Unknown flag: $1"
      ;;
    *)
      [[ $# -lt 3 ]] && die "Upsert mode requires: <run-id> <criterion-id> <verdict>"
      cmd_upsert "$@"
      ;;
  esac
}

main "$@"
