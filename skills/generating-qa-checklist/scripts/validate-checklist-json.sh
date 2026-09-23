#!/usr/bin/env bash
# validate-checklist-json.sh — structural validator for checklist.json (see
# ../references/checklist-json-schema.md for the schema this checks).
#
# checklist.json is the agent's PROPOSAL, emitted by generating-qa-checklist
# alongside checklist.md. This script only checks the file is STRUCTURALLY
# well-shaped (right fields, right types, enum membership, no duplicate
# ids) — it does NOT re-derive requiredKinds and does NOT trust the file's
# own `requiredKinds`/`humanAction` fields as ground truth. That semantic
# re-derivation is checkpoint.sh's job (Plan H1 Task 3, required-kinds.sh),
# which reads only `kind`/`tags`/`action` from a validated row and ignores
# everything else. Passing this validator says "the gate CAN read this
# row"; it says nothing about whether the row's own requiredKinds/
# assertedState claims are honest.
#
# USAGE:
#   validate-checklist-json.sh <checklist.json-path>
#     Exits 0 iff the file is valid JSON, its top-level is an array, and
#     every entry matches the schema (see below). Exits non-zero and
#     prints one "ERROR: ..." line per violation to stderr, each naming the
#     offending entry's index and field. An empty array `[]` is valid
#     (vacuously — a Run with no criteria yet).
#
# SCHEMA CHECKED PER ENTRY (all required unless noted "optional"):
#   id             non-empty string
#   surface        string
#   kind           string, one of the 12-value Kind enum (see
#                  templates/checklist.md's Kind field / the schema doc)
#   tags           array of strings
#   action         string
#   requiredKinds  optional; if present (and non-null), array of strings,
#                  each one of: bake | computed | probe | human-action
#   assertedState  optional; if present, either JSON null or an object with
#                  string `entity`, string `readBackPath`, boolean
#                  `expectChange` (all three required when the object is
#                  present)
#   humanAction    optional; if present (and non-null), a boolean
# Duplicate `id` values across entries are rejected.
#
# ERROR-HONESTY INVARIANTS (spec `docs/superpowers/specs/
# 2026-09-23-error-honesty-invariants-design.md` §4.1, ADR-0026): a criterion
# may not be authored so that an APPLICATION FAILURE is the correct answer.
# This is the check that would have caught the originating incident, whose
# `EC10` pinned `page.rendersWithoutServerError` to the STRING "false" and so
# graded an HTTP 500 as a match. Two layers, both emitting the same
# one-line-per-violation `ERROR: entry[<i>].<field>: …` form:
#
#   1. Reserved health namespace on `expect.path` (checked on `fixture.expect`
#      and on a top-level `expect`). These paths describe whole-page or
#      transport health, never a domain value:
#        page.rendersWithoutServerError  rejected when `value` is false
#        page.crashed                    rejected when `value` is true
#        console.hasError                rejected when `value` is true
#        http.status                     rejected when `value` >= 500
#      `value` is matched as a boolean OR its string spelling ("false"/"true"/
#      "500") — the incident used the string form. An `http.status` in the
#      3xx/4xx range is LEGAL and must stay so: an authorization refusal (a
#      302 to login, a 403) is the application WORKING, and several real
#      criteria assert exactly that. Paths outside the namespace are
#      untouched (`counts.evaluators = 2` is unaffected). The structural
#      message ends with the remediation pointer "— move it to
#      known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)".
#
#   2. Reserved prose phrases, matched case-insensitively: `expected to fail`
#      and `deferred by design`. Scanned ONLY in the oracle/expect string
#      fields (`oracle`, `oracleNote`, `expected`, and the string members of
#      `fixture.expect` / `expect`). **`action` is NEVER inspected** — it is
#      where an author legitimately describes a non-rendering state ("this
#      list does not render until the challenge reaches Judging"), and an
#      over-broad net there would make the validator something authors route
#      around. The weaker signals (`known defect`, `not a regression`) are
#      deliberately NOT rejected here; they are /qa-analyze plan-defect flags.
#
# DEPENDENCIES: bash, EITHER jq OR python3 (jq preferred, python3
# fallback). No node. Never grep -P/perl (tests/portability/run.sh forbids
# it in bundled scripts) — this script does no grep-based parsing at all,
# jq/python3 do all JSON handling.

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
has_jq() { command -v jq >/dev/null 2>&1; }
has_py() { command -v python3 >/dev/null 2>&1; }

usage() { die "Usage: validate-checklist-json.sh <checklist.json-path>"; }

# ---------------------------------------------------------------------------
# jq engine
# ---------------------------------------------------------------------------
validate_jq() {
  local path="$1"
  local jq_out jq_rc
  jq_out="$(jq -e -r 'type' "$path" 2>&1)"; jq_rc=$?
  if [[ $jq_rc -ne 0 ]]; then
    die "checklist.json: invalid JSON (${path}): ${jq_out}"
  fi

  local filter
  filter='
def kindEnum: ["happy-path","multiplicity-0","multiplicity-1","multiplicity-N","empty-state","loading-state","error-state","computed-logic","business-rule","downstream-cascade","cross-tenant","race"];
def reqKindEnum: ["bake","computed","probe","human-action"];

# --- error-honesty invariants (spec 2026-09-23 §4.1) -----------------------
def remedy: "— move it to known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)";
def prosePhrases: ["expected to fail","deferred by design"];

# The reserved health namespace: these expect.path values describe whole-page
# or transport health, never a domain value, and may not be pinned to a
# failing value. http.status in the 3xx/4xx range stays legal.
def healthViolations($i; $prefix; $x):
  if ($x|type) != "object" then []
  else
    ($x.path) as $p
    | ($x.value) as $v
    | (if ($v|type) == "string" then ($v|ascii_downcase) else "" end) as $vs
    | (if ($v|type) == "number" then $v
       elif ($v|type) == "string" then (($v|tonumber?) // null)
       else null end) as $n
    | (if $p == "page.rendersWithoutServerError" and (($v == false) or ($vs == "false"))
         then ["entry[\($i)].\($prefix): page.rendersWithoutServerError may not be pinned to false \(remedy)"] else [] end)
    + (if $p == "page.crashed" and (($v == true) or ($vs == "true"))
         then ["entry[\($i)].\($prefix): page.crashed may not be pinned to true \(remedy)"] else [] end)
    + (if $p == "console.hasError" and (($v == true) or ($vs == "true"))
         then ["entry[\($i)].\($prefix): console.hasError may not be pinned to true \(remedy)"] else [] end)
    + (if $p == "http.status" and ($n != null) and ($n >= 500)
         then ["entry[\($i)].\($prefix): http.status may not be pinned to \($n) (a 5xx asserts the application FAILED; 3xx/4xx stay legal) \(remedy)"] else [] end)
  end;

# Prose scan — the oracle/expect fields ONLY. `action` is deliberately never
# inspected: it is where an author legitimately describes a non-rendering
# state ("does not render until the challenge reaches Judging").
def expectProseFields($prefix; $x):
  if ($x|type) != "object" then []
  else [ $x | to_entries[] | select((.value|type) == "string") | {f: ($prefix + "." + .key), t: .value} ]
  end;

def proseViolations($i; $fields):
  [ $fields[] as $fld
    | ($fld.t|ascii_downcase) as $lt
    | prosePhrases[] as $ph
    | select($lt | contains($ph))
    | "entry[\($i)].\($fld.f): reserved phrase \"\($ph)\" may not appear in an oracle/expect field — a criterion may not assert that the application failed"
  ];

def entryViolations($i; $e):
  ( if ($e|type) != "object" then
      ["entry[\($i)]: must be an object"]
    else
      (if (($e|has("id"))|not) or (($e.id|type) != "string") or (($e.id|length) == 0)
         then ["entry[\($i)].id: must be a non-empty string"] else [] end)
      + (if (($e|has("surface"))|not) or (($e.surface|type) != "string")
         then ["entry[\($i)].surface: must be a string"] else [] end)
      + (if (($e|has("kind"))|not) or (($e.kind|type) != "string") or (([$e.kind] - kindEnum)|length != 0)
         then ["entry[\($i)].kind: \($e.kind // null): must be one of the kind enum"] else [] end)
      + (if (($e|has("tags"))|not) or (($e.tags|type) != "array") or (([$e.tags[]?] | map((type) != "string") | any))
         then ["entry[\($i)].tags: must be an array of strings"] else [] end)
      + (if (($e|has("action"))|not) or (($e.action|type) != "string")
         then ["entry[\($i)].action: must be a string"] else [] end)
      + ( if ($e|has("requiredKinds")) and ($e.requiredKinds != null) then
            (if ($e.requiredKinds|type) != "array" or (([$e.requiredKinds[]?] | map((type) != "string") | any))
               then ["entry[\($i)].requiredKinds: must be an array of strings"]
             else
               (($e.requiredKinds - reqKindEnum)) as $bad
               | (if ($bad|length) > 0 then ["entry[\($i)].requiredKinds: invalid kind(s) \($bad|join(","))"] else [] end)
             end)
          else [] end )
      + ( if ($e|has("assertedState")) and ($e.assertedState != null) then
            ( $e.assertedState ) as $as
            | (if ($as|type) != "object" then ["entry[\($i)].assertedState: must be null or an object"]
               else
                 (if (($as|has("entity"))|not) or (($as.entity|type) != "string") then ["entry[\($i)].assertedState.entity: must be a string"] else [] end)
                 + (if (($as|has("readBackPath"))|not) or (($as.readBackPath|type) != "string") then ["entry[\($i)].assertedState.readBackPath: must be a string"] else [] end)
                 + (if (($as|has("expectChange"))|not) or (($as.expectChange|type) != "boolean") then ["entry[\($i)].assertedState.expectChange: must be a boolean"] else [] end)
               end)
          else [] end )
      + ( if ($e|has("humanAction")) and ($e.humanAction != null) and (($e.humanAction|type) != "boolean")
          then ["entry[\($i)].humanAction: must be a boolean"] else [] end )
      + ( ( ($e.fixture) as $fx | if ($fx|type) == "object" then $fx.expect else null end ) as $fex
          | ( $e.expect ) as $tex
          | healthViolations($i; "fixture.expect"; $fex)
            + healthViolations($i; "expect"; $tex)
            + proseViolations($i;
                ( if ($e.oracle|type) == "string" then [{f:"oracle", t:$e.oracle}] else [] end )
                + ( if ($e.oracleNote|type) == "string" then [{f:"oracleNote", t:$e.oracleNote}] else [] end )
                + ( if ($e.expected|type) == "string" then [{f:"expected", t:$e.expected}] else [] end )
                + expectProseFields("fixture.expect"; $fex)
                + expectProseFields("expect"; $tex) ) )
    end
  );

( if (type != "array") then
    ["top-level: must be a JSON array (got \(type))"]
  else
    ( [ range(0; length) as $i | entryViolations($i; .[$i]) ] | add // [] ) as $entryViols
    | ( reduce (.[] | (.id? // null) | select(. != null and type == "string")) as $id ({}; .[$id] = ((.[$id] // 0) + 1))
        | to_entries | map(select(.value > 1)) | map("duplicate id \"\(.key)\": appears \(.value) times")
      ) as $dupViols
    | $entryViols + $dupViols
  end
) as $violations
| $violations[]
'

  local violations
  violations="$(jq -r -f <(printf '%s' "$filter") "$path" 2>&1)" || die "checklist.json: jq validation failed unexpectedly (${path}): ${violations}"

  # jq -r on an array of strings prints one per line; an empty array prints nothing.
  if [[ -z "$violations" ]]; then
    return 0
  fi
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "ERROR: ${line}" >&2
  done <<< "$violations"
  return 1
}

# ---------------------------------------------------------------------------
# python3 engine (fallback)
# ---------------------------------------------------------------------------
validate_py() {
  local path="$1"
  python3 - "$path" <<'PYEOF'
import json, sys

KIND_ENUM = {
    "happy-path", "multiplicity-0", "multiplicity-1", "multiplicity-N",
    "empty-state", "loading-state", "error-state", "computed-logic",
    "business-rule", "downstream-cascade", "cross-tenant", "race",
}
REQ_KIND_ENUM = {"bake", "computed", "probe", "human-action"}

# --- error-honesty invariants (spec 2026-09-23 §4.1) -----------------------
REMEDY = "— move it to known-defects.json (see qa-kit/scripts/migrate-inverted-criterion.sh)"
PROSE_PHRASES = ("expected to fail", "deferred by design")


def _as_number(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    if isinstance(v, str):
        try:
            return float(v)
        except ValueError:
            return None
    return None


def health_violations(i, prefix, x):
    """The reserved health namespace: these expect.path values describe
    whole-page or transport health, never a domain value, and may not be
    pinned to a failing value. http.status in the 3xx/4xx range stays legal."""
    if not isinstance(x, dict):
        return []
    v = []
    p = x.get("path")
    val = x.get("value")
    vs = val.lower() if isinstance(val, str) else ""
    n = _as_number(val)
    if p == "page.rendersWithoutServerError" and (val is False or vs == "false"):
        v.append(f"entry[{i}].{prefix}: page.rendersWithoutServerError may not be pinned to false {REMEDY}")
    if p == "page.crashed" and (val is True or vs == "true"):
        v.append(f"entry[{i}].{prefix}: page.crashed may not be pinned to true {REMEDY}")
    if p == "console.hasError" and (val is True or vs == "true"):
        v.append(f"entry[{i}].{prefix}: console.hasError may not be pinned to true {REMEDY}")
    if p == "http.status" and n is not None and n >= 500:
        shown = int(n) if float(n).is_integer() else n
        v.append(f"entry[{i}].{prefix}: http.status may not be pinned to {shown} "
                 f"(a 5xx asserts the application FAILED; 3xx/4xx stay legal) {REMEDY}")
    return v


def expect_prose_fields(prefix, x):
    if not isinstance(x, dict):
        return []
    return [(f"{prefix}.{k}", val) for k, val in x.items() if isinstance(val, str)]


def prose_violations(i, fields):
    """Prose scan — the oracle/expect fields ONLY. `action` is deliberately
    never inspected: it is where an author legitimately describes a
    non-rendering state ("does not render until the challenge reaches
    Judging")."""
    v = []
    for fname, text in fields:
        lt = text.lower()
        for ph in PROSE_PHRASES:
            if ph in lt:
                v.append(f'entry[{i}].{fname}: reserved phrase "{ph}" may not appear in an '
                         f"oracle/expect field — a criterion may not assert that the application failed")
    return v


def honesty_violations(i, e):
    fx = e.get("fixture")
    fex = fx.get("expect") if isinstance(fx, dict) else None
    tex = e.get("expect")
    v = health_violations(i, "fixture.expect", fex) + health_violations(i, "expect", tex)
    fields = []
    for key in ("oracle", "oracleNote", "expected"):
        if isinstance(e.get(key), str):
            fields.append((key, e[key]))
    fields += expect_prose_fields("fixture.expect", fex)
    fields += expect_prose_fields("expect", tex)
    return v + prose_violations(i, fields)


def entry_violations(i, e):
    v = []
    if not isinstance(e, dict):
        return [f"entry[{i}]: must be an object"]
    if not isinstance(e.get("id"), str) or len(e.get("id")) == 0:
        v.append(f"entry[{i}].id: must be a non-empty string")
    if not isinstance(e.get("surface"), str):
        v.append(f"entry[{i}].surface: must be a string")
    kind = e.get("kind")
    if not isinstance(kind, str) or kind not in KIND_ENUM:
        v.append(f"entry[{i}].kind: {kind}: must be one of the kind enum")
    tags = e.get("tags")
    if not isinstance(tags, list) or any(not isinstance(t, str) for t in tags):
        v.append(f"entry[{i}].tags: must be an array of strings")
    if not isinstance(e.get("action"), str):
        v.append(f"entry[{i}].action: must be a string")
    if "requiredKinds" in e and e["requiredKinds"] is not None:
        rk = e["requiredKinds"]
        if not isinstance(rk, list) or any(not isinstance(k, str) for k in rk):
            v.append(f"entry[{i}].requiredKinds: must be an array of strings")
        else:
            bad = [k for k in rk if k not in REQ_KIND_ENUM]
            if bad:
                v.append(f"entry[{i}].requiredKinds: invalid kind(s) {','.join(bad)}")
    if "assertedState" in e and e["assertedState"] is not None:
        asx = e["assertedState"]
        if not isinstance(asx, dict):
            v.append(f"entry[{i}].assertedState: must be null or an object")
        else:
            if not isinstance(asx.get("entity"), str):
                v.append(f"entry[{i}].assertedState.entity: must be a string")
            if not isinstance(asx.get("readBackPath"), str):
                v.append(f"entry[{i}].assertedState.readBackPath: must be a string")
            if not isinstance(asx.get("expectChange"), bool):
                v.append(f"entry[{i}].assertedState.expectChange: must be a boolean")
    if "humanAction" in e and e["humanAction"] is not None:
        if not isinstance(e["humanAction"], bool):
            v.append(f"entry[{i}].humanAction: must be a boolean")
    v.extend(honesty_violations(i, e))
    return v


def main():
    path = sys.argv[1]
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception as exc:
        print(f"ERROR: checklist.json: invalid JSON ({path}): {exc}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(data, list):
        print(f"ERROR: top-level: must be a JSON array (got {type(data).__name__})", file=sys.stderr)
        sys.exit(1)

    violations = []
    for i, e in enumerate(data):
        violations.extend(entry_violations(i, e))

    counts = {}
    for e in data:
        if isinstance(e, dict) and isinstance(e.get("id"), str):
            counts[e["id"]] = counts.get(e["id"], 0) + 1
    for id_, n in counts.items():
        if n > 1:
            violations.append(f'duplicate id "{id_}": appears {n} times')

    if violations:
        for v in violations:
            print(f"ERROR: {v}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)


main()
PYEOF
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------
main() {
  [[ $# -lt 1 ]] && usage
  local path="$1"
  [[ -f "$path" ]] || die "checklist.json not found: ${path}"

  if has_jq; then
    validate_jq "$path"
  elif has_py; then
    validate_py "$path"
  else
    die "validate-checklist-json.sh needs either 'jq' or 'python3' on PATH."
  fi
}

main "$@"
