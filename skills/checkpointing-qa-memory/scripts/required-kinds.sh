#!/usr/bin/env bash
# required-kinds.sh — deterministic, agent-untrusted required-evidence-kinds
# deriver.
#
# THE REQUIRED SET IS DERIVED, NEVER TRUSTED FROM AN AGENT-AUTHORED FIELD.
# Which evidence kinds a criterion MUST carry is decided ONLY from the
# criterion's shape — its `kind`, its `tags`, and (via `mutation-flag.sh`)
# its action-shape (`kinds`/`httpMethod`/`action`/`title`). This script does
# not read, and must never read, the agent's own `requiredKinds` field —
# that is precisely the field the honesty gate (checkpoint.sh, Task 3 of
# Plan H1) uses this deriver to police. Trusting it here would defeat the
# purpose.
#
# VOCABULARY: the output is always a subset of the FOUR-kind evidence
# vocabulary `bake | computed | human-action | probe`. No fifth kind exists
# in this codebase — do not invent one here or anywhere downstream.
#
# USAGE:
#   required-kinds.sh derive <criterion-json>
#       Prints a sorted, deduplicated CSV of required kinds (empty string,
#       exit 0, if none are required). Rules, ALL THAT MATCH (union, not
#       first-match-wins):
#         1. `mutation-flag.sh derive <criterion-json>` is `true`
#              -> add `human-action`
#            (A state-mutating act must leave a human-action trace. This
#            reuses mutation-flag.sh's own agent-untrusted classifier
#            verbatim — required-kinds.sh never re-implements or
#            second-guesses it.)
#         2. `kind` is `computed-logic` or `business-rule` (case-insensitive)
#              -> add `computed`
#         3. `kind` is one of `multiplicity-0`, `multiplicity-1`,
#            `multiplicity-N`, `happy-path`, `downstream-cascade`,
#            `empty-state` (case-insensitive) AND the criterion is NOT
#            tagged `read-only`
#              -> add `bake`
#            DESIGN NOTE on "asserts persisted state": this codebase has no
#            dedicated boolean field for that (Plan H1 Task 2/4 later adds
#            `assertedState`, consumed by the *fingerprint-target* check —
#            a different, narrower thing). For Task 1, "asserts persisted
#            state" is approximated deterministically from the criterion's
#            *shape* alone: the kind-enum above is treated as the complete
#            set of kinds that, by construction, assert persisted state
#            (a happy-path/multiplicity/cascade/empty-state check always
#            reads state back). A `read-only` tag can suppress `bake` even
#            for one of these kinds (an explicit author override); no other
#            kind implicitly adds `bake` — `computed-logic`/`business-rule`
#            in particular do NOT imply `bake` on their own (they assert a
#            computed value, not persisted state; see mini-eval below).
#         4. `tags` contains `cross-tenant`, `cross-role-fk-chain`, or
#            `probe-needed`
#              -> add `probe`
#         A purely read-only/observational criterion (tag `read-only`, no
#         mutating action, a kind like `loading-state`/`error-state`, no
#         cross-tenant/probe tag) matches none of the above and correctly
#         derives the EMPTY set — that is a valid, intentional result.
#
# DEPENDENCIES: bash, coreutils (grep, sort), and EITHER jq OR python3 (jq
# preferred; python3 fallback) to read the criterion JSON fields. No `node`.
# QA_ENGINE is not read directly here — has_jq()/has_py() probe the live
# PATH exactly like mutation-flag.sh, so masking `jq` from PATH forces the
# python3 fallback in both this script and the mutation-flag.sh it shells
# out to.
#
# Verb/kind matching uses `grep -Ei`, NEVER `grep -P`/PCRE — the
# portability suite (tests/portability/run.sh) forbids `grep -P`/`perl` in
# bundled scripts.

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() { command -v jq >/dev/null 2>&1; }

has_py() { command -v python3 >/dev/null 2>&1; }

# mutation-flag.sh lives alongside this script.
SCRIPT_DIR="$(dirname "$0")"
MUTATION_FLAG="${SCRIPT_DIR}/mutation-flag.sh"

# kind-enum regexes, anchored, case-insensitive (see rules 2 and 3 above).
COMPUTED_KIND_RE='^(computed-logic|business-rule)$'
BAKE_KIND_RE='^(multiplicity-0|multiplicity-1|multiplicity-N|happy-path|downstream-cascade|empty-state)$'

# ---------------------------------------------------------------------------
# read_criterion <criterion-json>
#
# Validates <criterion-json> is a single JSON object, then prints two lines
# to stdout: kind (string, "" if absent/non-string), tags (comma-joined,
# "" if absent/non-array). Dies on invalid JSON or a non-object top-level
# value. Deliberately does NOT read `requiredKinds` (or anything else) —
# only the two structural fields this deriver's own rules consume.
# ---------------------------------------------------------------------------

read_criterion() {
  local json="$1"

  if has_jq; then
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$json" \
      || die "<criterion-json> must be a single JSON object: ${json}"
    jq -r '
      ((.kind // "") | tostring),
      (if (.tags | type) == "array" then (.tags | map(tostring) | join(",")) else "" end)
    ' <<< "$json" || die "jq failed to read fields from <criterion-json>: ${json}"
  elif has_py; then
    local pyout
    pyout="$(python3 -c '
import json, sys
try:
    obj = json.loads(sys.argv[1])
except json.JSONDecodeError:
    print("__REQUIRED_KINDS_PARSE_ERROR__")
    sys.exit(0)
if not isinstance(obj, dict):
    print("__REQUIRED_KINDS_PARSE_ERROR__")
    sys.exit(0)
tags = obj.get("tags")
if not isinstance(tags, list):
    tags = []
print(str(obj.get("kind") or ""))
print(",".join(str(t) for t in tags))
' "$json" 2>/dev/null)" || die "python3 failed to read fields from <criterion-json>: ${json}"
    if [[ "${pyout%%$'\n'*}" == "__REQUIRED_KINDS_PARSE_ERROR__" ]]; then
      die "<criterion-json> must be a single JSON object: ${json}"
    fi
    printf '%s\n' "$pyout"
  else
    die "required-kinds.sh needs either 'jq' or 'python3' to read the criterion JSON."
  fi
}

# ---------------------------------------------------------------------------
# derive <criterion-json> → stdout: sorted, deduped CSV (possibly empty)
# ---------------------------------------------------------------------------

derive() {
  local json="$1"
  [[ -z "${json:-}" ]] && die "derive requires: <criterion-json>"

  [[ -f "$MUTATION_FLAG" ]] \
    || die "required-kinds.sh: cannot find mutation-flag.sh at ${MUTATION_FLAG} (expected alongside this script)"

  local out kind tags_csv
  out="$(read_criterion "$json")" || exit 1
  mapfile -t _rk_lines <<< "$out"
  kind="${_rk_lines[0]:-}"
  tags_csv="${_rk_lines[1]:-}"

  local -a kinds=()

  # Rule 1: reuse mutation-flag.sh's own agent-untrusted classifier verbatim.
  local mutates
  mutates="$(bash "$MUTATION_FLAG" derive "$json")" || die "mutation-flag.sh derive failed on: ${json}"
  [[ "$mutates" == "true" ]] && kinds+=("human-action")

  # Rule 2: kind is computed-logic/business-rule -> computed.
  if grep -Eiq "$COMPUTED_KIND_RE" <<< "$kind"; then
    kinds+=("computed")
  fi

  # Rule 3: kind is a bake-kind AND not tagged read-only -> bake.
  if grep -Eiq "$BAKE_KIND_RE" <<< "$kind" && [[ ",${tags_csv}," != *,read-only,* ]]; then
    kinds+=("bake")
  fi

  # Rule 4: tags contain a probe-triggering tag -> probe.
  if [[ ",${tags_csv}," == *,cross-tenant,* \
     || ",${tags_csv}," == *,cross-role-fk-chain,* \
     || ",${tags_csv}," == *,probe-needed,* ]]; then
    kinds+=("probe")
  fi

  local -a sorted=()
  if [[ ${#kinds[@]} -gt 0 ]]; then
    mapfile -t sorted < <(printf '%s\n' "${kinds[@]}" | sort -u)
  fi

  (IFS=,; echo "${sorted[*]}")
}

# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

main() {
  [[ $# -lt 1 ]] && die "Usage: required-kinds.sh derive <criterion-json>"

  case "$1" in
    derive)
      [[ $# -lt 2 ]] && die "derive requires: <criterion-json>"
      derive "$2"
      ;;
    *)
      die "usage: required-kinds.sh derive <criterion-json>"
      ;;
  esac
}

main "$@"
