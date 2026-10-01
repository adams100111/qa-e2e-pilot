#!/usr/bin/env bash
# screenshot-evidence.sh — the ONE implementation of screenshot-evidence
# integrity, shared by record-evidence.sh (record time), checkpoint.sh (the
# pass/fail gate), qa-verify.sh (the out-of-agent re-check) and capture-hook.sh
# (hashing the file the driver just wrote). Engine 0.10.0, ADR-0028.
#
# A screenshot is recorded as TWO files in the criterion's evidence dir:
#   evidence/[<persona>/]<crit>/screenshot-<phase>[-<label>].<png|jpg|webp>   the image
#   evidence/[<persona>/]<crit>/screenshot-<phase>[-<label>].json             its sidecar
# The sidecar ({kind:"screenshot", phase, image, sha256, bytes, mime,
# provenance:{sourceRef}, ...}) is what binds the image to the captured
# browser_take_screenshot call; an image with no sidecar is unbound.
#
# USAGE:
#   screenshot-evidence.sh inspect <file>
#       Prints "<ext> <mime> <bytes> <sha256>" for a PNG / JPEG / WebP file
#       (decided by its magic bytes, never its name). Exit 1 + a message when
#       the file is missing, empty, larger than 25 MB, or not one of those.
#
#   screenshot-evidence.sh sha256 <file>
#       Prints the file's sha256 (sha256sum | shasum | python3 | openssl).
#
#   screenshot-evidence.sh required
#       Prints "true" or "false": whether a pass/fail criterion must carry a
#       screenshot. QA_REQUIRE_SCREENSHOTS (true|false|1|0) wins; otherwise
#       .qa/config.json's report.requireScreenshots; otherwise true.
#
#   screenshot-evidence.sh status <run-id> <criterion-id> [<persona>] [--no-provenance]
#       One JSON object describing the criterion's screenshot evidence:
#         {sidecars, valid, bound, noToolstream, problems:[{file, problem, detail}]}
#       valid   = sidecars whose image exists and still hashes to the sidecar's
#                 sha256 (integrity);
#       bound   = valid sidecars that provenance.sh binds to a captured
#                 browser_take_screenshot call (skipped with --no-provenance,
#                 where bound == valid);
#       problems: invalid (sidecar not JSON / missing keys), missing-image,
#                 tampered (image no longer matches the recorded sha256),
#                 unbound (no captured call produced it), duplicate (another
#                 sidecar in the run claims the same captured call).
#       noToolstream is true when the run has no toolstream.jsonl at all (the
#       provenance check could not run — a degrade, never a problem).
#
# DEPENDENCIES: bash, coreutils (od, head, wc), EITHER jq OR python3
# (QA_ENGINE honored, same contract as toolstream.sh/provenance.sh), and one
# sha256 tool. No node. Paths are relative to the project root (cwd).

set -uo pipefail

QA_BASE="${QA_BASE:-.qa/runs}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVENANCE_SH="${PROVENANCE_SH:-$HERE/../../../scripts/provenance.sh}"
MAX_BYTES=$((25 * 1024 * 1024))

die() { echo "ERROR: $*" >&2; exit 1; }

has_jq() {
  case "${QA_ENGINE:-}" in
    python3) return 1 ;;
    jq) return 0 ;;
    *) command -v jq >/dev/null 2>&1 ;;
  esac
}
has_py() { command -v python3 >/dev/null 2>&1; }

file_sha256() {
  local f="$1" out=""
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum < "$f" 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 < "$f" 2>/dev/null | awk '{print $1}')"
  elif has_py; then
    out="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f" 2>/dev/null)"
  elif command -v openssl >/dev/null 2>&1; then
    out="$(openssl dgst -sha256 < "$f" 2>/dev/null | awk '{print $NF}')"
  fi
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$out"
}

file_bytes() { wc -c < "$1" | tr -d ' '; }

# magic <file> -> "png image/png" | "jpg image/jpeg" | "webp image/webp" | nothing
magic() {
  local hex
  hex="$(head -c 12 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  case "$hex" in
    89504e470d0a1a0a*) echo "png image/png" ;;
    ffd8ff*) echo "jpg image/jpeg" ;;
    52494646????????57454250*) echo "webp image/webp" ;;
    *) return 1 ;;
  esac
}

cmd_inspect() {
  local f="$1"
  [[ -f "$f" ]] || die "screenshot file not found: $f"
  [[ -s "$f" ]] || die "screenshot file is empty: $f"
  local bytes kind sha
  bytes="$(file_bytes "$f")"
  [[ "$bytes" -le "$MAX_BYTES" ]] || die "screenshot file is ${bytes} bytes (> 25 MB cap): $f"
  kind="$(magic "$f")" || die "not a PNG/JPEG/WebP image (by its magic bytes): $f"
  sha="$(file_sha256 "$f")" || die "no sha256 tool available (sha256sum, shasum, python3 or openssl)"
  printf '%s %s %s\n' "$kind" "$bytes" "$sha"
}

cmd_required() {
  local v="${QA_REQUIRE_SCREENSHOTS:-}"
  case "$v" in
    true|1|yes) echo true; return 0 ;;
    false|0|no) echo false; return 0 ;;
  esac
  local cfg=".qa/config.json" out=""
  if [[ -f "$cfg" ]]; then
    if has_jq; then
      out="$(jq -r '(.report.requireScreenshots) as $v | if $v == false then "false" else "true" end' "$cfg" 2>/dev/null)"
    elif has_py; then
      out="$(python3 -c '
import json, sys
try:
    v = (json.load(open(sys.argv[1])).get("report") or {}).get("requireScreenshots", True)
except Exception:
    v = True
print("false" if v is False else "true")
' "$cfg" 2>/dev/null)"
    fi
  fi
  [[ "$out" == "false" ]] && echo false || echo true
}

# sidecar_fields <sidecar> -> 3 lines: image, sha256, sourceRef ("" when absent).
# Exit 1 when the sidecar is not a JSON object.
sidecar_fields() {
  local f="$1"
  if has_jq; then
    jq -er 'if type == "object" then ((.image // "" | tostring), (.sha256 // "" | tostring), (.provenance.sourceRef? // "" | tostring)) else error("x") end' "$f" 2>/dev/null
  else
    python3 - "$f" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict):
    sys.exit(1)
p = d.get("provenance") if isinstance(d.get("provenance"), dict) else {}
for v in (d.get("image") or "", d.get("sha256") or "", p.get("sourceRef") or ""):
    print(v if isinstance(v, str) else json.dumps(v))
PYEOF
  fi
}

# all_claims <run-id> -> "<sourceRef>\t<sidecar path>" for every screenshot
# sidecar in the run (any persona/criterion) that names a sourceRef.
all_claims() {
  local run_dir="${QA_BASE}/$1" sc ref
  [[ -d "$run_dir/evidence" ]] || return 0
  while IFS= read -r sc; do
    [[ -n "$sc" ]] || continue
    ref="$(sidecar_fields "$sc" 2>/dev/null | sed -n 3p)"
    ref="${ref#seq:}"
    [[ -n "$ref" ]] && printf 'seq:%s\t%s\n' "$ref" "$sc"
  done < <(find "$run_dir/evidence" -type f -name 'screenshot-*.json' 2>/dev/null | LC_ALL=C sort)
}

json_problems() { # reads "file\tproblem\tdetail" lines on stdin -> JSON array
  if has_jq; then
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {file: .[0], problem: .[1], detail: (.[2] // "")})'
  else
    python3 -c '
import json, sys
out = []
for line in sys.stdin.read().split("\n"):
    if not line:
        continue
    p = line.split("\t")
    out.append({"file": p[0], "problem": p[1], "detail": p[2] if len(p) > 2 else ""})
print(json.dumps(out, separators=(",", ":")))
'
  fi
}

cmd_status() {
  local run_id="$1" crit_id="$2" persona="${3:-}" with_prov="${4:-1}"
  local run_dir="${QA_BASE}/${run_id}" rel_dir
  if [[ -n "$persona" ]]; then rel_dir="evidence/${persona}/${crit_id}"; else rel_dir="evidence/${crit_id}"; fi
  local dir="${run_dir}/${rel_dir}"
  local no_ts="false"
  [[ -f "${run_dir}/toolstream.jsonl" ]] || no_ts="true"

  local sidecars=0 valid=0 bound=0 problems="" claims=""
  [[ "$with_prov" -eq 1 ]] && claims="$(all_claims "$run_id")"

  local sc rel fields image sha ref img_path actual prov other
  while IFS= read -r sc; do
    [[ -n "$sc" ]] || continue
    sidecars=$((sidecars + 1))
    rel="${rel_dir}/${sc##*/}"
    if ! fields="$(sidecar_fields "$sc")"; then
      problems+="${rel}"$'\t'"invalid"$'\t'"sidecar is not a JSON object"$'\n'; continue
    fi
    image="$(sed -n 1p <<< "$fields")"; sha="$(sed -n 2p <<< "$fields")"; ref="$(sed -n 3p <<< "$fields")"
    if [[ -z "$image" || -z "$sha" ]]; then
      problems+="${rel}"$'\t'"invalid"$'\t'"sidecar lacks image/sha256"$'\n'; continue
    fi
    case "$image" in */*|*\\*|*..*) problems+="${rel}"$'\t'"invalid"$'\t'"image '${image}' is not a file in the criterion's evidence dir"$'\n'; continue ;; esac
    img_path="${dir}/${image}"
    if [[ ! -s "$img_path" ]]; then
      problems+="${rel}"$'\t'"missing-image"$'\t'"${rel_dir}/${image} is missing or empty"$'\n'; continue
    fi
    actual="$(file_sha256 "$img_path")" || actual=""
    if [[ "$actual" != "$sha" ]]; then
      problems+="${rel}"$'\t'"tampered"$'\t'"${rel_dir}/${image} no longer matches the sha256 recorded with it"$'\n'; continue
    fi
    valid=$((valid + 1))
    if [[ "$with_prov" -ne 1 ]]; then bound=$((bound + 1)); continue; fi
    if [[ -n "$ref" ]]; then
      local norm="seq:${ref#seq:}"
      other="$(awk -F'\t' -v r="$norm" -v me="$sc" '$1 == r && $2 != me {print $2; exit}' <<< "$claims")"
      if [[ -n "$other" ]]; then
        problems+="${rel}"$'\t'"duplicate"$'\t'"captured call ${norm} is also claimed by ${other#"${run_dir}/"}"$'\n'; continue
      fi
    fi
    [[ "$no_ts" == "true" ]] && continue
    prov="$(bash "$PROVENANCE_SH" check "$run_id" "$sc" 2>/dev/null)"
    if [[ "$prov" == "bound" ]]; then
      bound=$((bound + 1))
    else
      problems+="${rel}"$'\t'"unbound"$'\t'"no captured browser_take_screenshot call produced this image (provenance: ${prov:-error})"$'\n'
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name 'screenshot-*.json' 2>/dev/null | LC_ALL=C sort)

  local pj
  pj="$(printf '%s' "$problems" | json_problems)"
  [[ -n "$pj" ]] || pj="[]"
  printf '{"sidecars":%s,"valid":%s,"bound":%s,"noToolstream":%s,"problems":%s}\n' \
    "$sidecars" "$valid" "$bound" "$no_ts" "$pj"
}

validate_token() {
  local value="$1" label="$2"
  [[ -n "$value" ]] || die "${label} must not be empty."
  case "$value" in */*|*\\*|*..*|-*) die "${label} '${value}' must be a simple token." ;; esac
  [[ "$value" =~ ^\.+$ ]] && die "${label} '${value}' must be a simple token."
  return 0
}

main() {
  [[ $# -ge 1 ]] || die "usage: screenshot-evidence.sh inspect <file> | sha256 <file> | required | status <run-id> <crit-id> [<persona>] [--no-provenance]"
  local cmd="$1"; shift
  case "$cmd" in
    inspect) [[ $# -ge 1 ]] || die "inspect requires <file>"; cmd_inspect "$1" ;;
    sha256) [[ $# -ge 1 ]] || die "sha256 requires <file>"; file_sha256 "$1" || die "cannot hash $1" ;;
    required) cmd_required ;;
    status)
      local args=() with_prov=1 a
      for a in "$@"; do
        if [[ "$a" == "--no-provenance" ]]; then with_prov=0; else args+=("$a"); fi
      done
      [[ ${#args[@]} -ge 2 ]] || die "status requires <run-id> <crit-id> [<persona>]"
      validate_token "${args[0]}" "run-id"
      validate_token "${args[1]}" "criterion-id"
      [[ -n "${args[2]:-}" ]] && validate_token "${args[2]}" "persona"
      has_jq || has_py || die "screenshot-evidence.sh needs either 'jq' or 'python3'."
      cmd_status "${args[0]}" "${args[1]}" "${args[2]:-}" "$with_prov"
      ;;
    *) die "unknown command '${cmd}'" ;;
  esac
}

main "$@"
