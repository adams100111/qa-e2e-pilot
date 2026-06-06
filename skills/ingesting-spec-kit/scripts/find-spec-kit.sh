#!/usr/bin/env bash
# find-spec-kit.sh — locate spec-kit artifacts across configured repos and cwd.
#
# Outputs one line per artifact found:
#   <absolute-path> | <artifact-type> | <title>
#
# artifact-type: constitution | spec | tasks
# title:         the first ATX heading (# ...) or first non-empty line.
#
# Exit 0 always — absence of artifacts is not an error.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extract the first heading or first non-empty line from a file.
title_of() {
  local f="$1"
  # First ATX heading
  local heading
  heading=$(grep -m1 '^#' "$f" 2>/dev/null | sed 's/^#\+[[:space:]]*//' || true)
  if [ -n "$heading" ]; then
    printf '%s' "$heading"
    return
  fi
  # Fallback: first non-empty line
  grep -m1 '.' "$f" 2>/dev/null | head -c 120 || true
}

# Print one result line, normalising the path.
emit() {
  local path="$1" atype="$2"
  local abs_path
  abs_path="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  local title
  title="$(title_of "$abs_path")"
  printf '%s | %s | %s\n' "$abs_path" "$atype" "${title:-<no title>}"
}

# Map a filename to an artifact type (returns empty string if not a spec-kit file).
artifact_type_of() {
  local name
  name="$(basename "$1" | tr '[:upper:]' '[:lower:]')"
  case "$name" in
    constitution.md) printf 'constitution' ;;
    spec.md)         printf 'spec'         ;;
    tasks.md)        printf 'tasks'        ;;
    *)               printf ''             ;;
  esac
}

# Search one directory (non-recursive) for the three spec-kit filenames.
search_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  for fname in constitution.md spec.md tasks.md; do
    local candidate="$dir/$fname"
    if [ -f "$candidate" ]; then
      local atype
      atype="$(artifact_type_of "$candidate")"
      emit "$candidate" "$atype"
    fi
  done
}

# Recursive search under a directory (for specs/, docs/, .specify/ subdirs).
search_dir_recursive() {
  local base="$1"
  [ -d "$base" ] || return 0
  # Use find with -maxdepth to avoid scanning too deep; 4 levels is enough.
  find "$base" -maxdepth 4 \
    \( -name 'constitution.md' -o -name 'spec.md' -o -name 'tasks.md' \) \
    -type f 2>/dev/null | sort | while IFS= read -r f; do
      local atype
      atype="$(artifact_type_of "$f")"
      emit "$f" "$atype"
    done
}

# ---------------------------------------------------------------------------
# Collect search roots from .qa/config.json (repos by role) + cwd.
# ---------------------------------------------------------------------------

# Start with current working directory.
SEARCH_ROOTS=("$(pwd)")

CONFIG_FILE=".qa/config.json"

if [ -f "$CONFIG_FILE" ]; then
  # Try jq first (preferred).
  if command -v jq >/dev/null 2>&1; then
    # Extract .repos[].path values (repos may use "path" or "root" key).
    while IFS= read -r repo_path; do
      [ -n "$repo_path" ] && SEARCH_ROOTS+=("$repo_path")
    done < <(jq -r '(.repos // [])[] | .path // .root // empty' "$CONFIG_FILE" 2>/dev/null || true)
  else
    # Fallback: node if available.
    if command -v node >/dev/null 2>&1; then
      while IFS= read -r repo_path; do
        [ -n "$repo_path" ] && SEARCH_ROOTS+=("$repo_path")
      done < <(node -e "
        try {
          const cfg = JSON.parse(require('fs').readFileSync('$CONFIG_FILE','utf8'));
          (cfg.repos||[]).forEach(r => { if (r.path||r.root) process.stdout.write((r.path||r.root)+'\n'); });
        } catch(e) {}
      " 2>/dev/null || true)
    else
      # Last resort: grep for quoted path/root values (best-effort, may over-match).
      while IFS= read -r repo_path; do
        [ -n "$repo_path" ] && SEARCH_ROOTS+=("$repo_path")
      done < <( \
        if printf 'x' | grep -qoP 'x' 2>/dev/null; then \
          grep -oP '"(?:path|root)"\s*:\s*"\K[^"]+' "$CONFIG_FILE" 2>/dev/null; \
        else \
          PAT='"(?:path|root)"\s*:\s*"\K[^"]+' perl -ne 'print "$&\n" while /$ENV{PAT}/g' "$CONFIG_FILE" 2>/dev/null; \
        fi || true)
    fi
  fi
fi

# De-duplicate roots (preserve order).
declare -A _seen_roots=()
UNIQUE_ROOTS=()
for r in "${SEARCH_ROOTS[@]}"; do
  if [ -z "${_seen_roots[$r]+_}" ]; then
    _seen_roots[$r]=1
    UNIQUE_ROOTS+=("$r")
  fi
done

# ---------------------------------------------------------------------------
# Per-root: search root dir + well-known subdirectories.
# ---------------------------------------------------------------------------

FOUND=0

for root in "${UNIQUE_ROOTS[@]}"; do
  # Root itself (non-recursive — catches repo-root placements).
  while IFS= read -r line; do
    [ -n "$line" ] && { FOUND=1; printf '%s\n' "$line"; }
  done < <(search_dir "$root" 2>/dev/null || true)

  # Well-known subdirectories (recursive within each).
  for subdir in .specify specs docs; do
    while IFS= read -r line; do
      [ -n "$line" ] && { FOUND=1; printf '%s\n' "$line"; }
    done < <(search_dir_recursive "$root/$subdir" 2>/dev/null || true)
  done
done

# ---------------------------------------------------------------------------
# Summary line (to stderr so stdout stays machine-parseable).
# ---------------------------------------------------------------------------

if [ "$FOUND" -eq 0 ]; then
  printf 'No spec-kit artifacts found. Proceeding with hand-authored or auto-generated checklist.\n' >&2
else
  printf 'Spec-kit artifact discovery complete.\n' >&2
fi

exit 0
