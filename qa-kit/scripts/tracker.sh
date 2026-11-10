#!/usr/bin/env bash
# QA tracker entry point. bash 3.2 safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1 \
   || ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
  echo "tracker.sh: python3 3.9 or newer is required" >&2
  exit 1
fi
exec python3 "$DIR/trackers/cli.py" "$@"
