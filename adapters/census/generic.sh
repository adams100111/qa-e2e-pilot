#!/usr/bin/env bash
# generic.sh — census stack adapter for stacks with no adapter of their own. Declares nothing, so the
# census is crawl-only: scripts/census.sh builds it from the per-role crawl and the warning below says so.
# Contract: adapters/census/README.md.
#
# USAGE:  generic.sh [--repo <path>] [--exec-prefix "<prefix>"]   (both accepted, neither used)
# OUTPUT: {"adapter":"generic","ok":true,"surfaces":[],"warnings":["crawl-only census"]}
# EXIT:   0; 1 on an unknown flag (stderr only).
set -uo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--exec-prefix) [ "$#" -ge 2 ] || { echo "usage: generic.sh [--repo <path>] [--exec-prefix \"<prefix>\"]" >&2; exit 1; }; shift 2 ;;
    *) echo "generic.sh: unknown argument: $1" >&2; echo "usage: generic.sh [--repo <path>] [--exec-prefix \"<prefix>\"]" >&2; exit 1 ;;
  esac
done
printf '%s\n' '{"adapter":"generic","ok":true,"surfaces":[],"warnings":["crawl-only census"]}'
