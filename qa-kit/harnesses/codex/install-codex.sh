#!/usr/bin/env bash
# qa-kit Codex adapter installer — thin wrapper; all logic + install dirs live in ../_install-common.sh.
HARNESS=codex
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_install-common.sh"
