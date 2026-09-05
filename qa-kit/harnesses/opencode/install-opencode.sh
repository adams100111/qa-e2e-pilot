#!/usr/bin/env bash
# qa-kit opencode adapter installer — thin wrapper; all logic + install dirs live in ../_install-common.sh.
# (The 'opencode-skills' plugin prerequisite echo is emitted by the common file's HARNESS=opencode branch.)
HARNESS=opencode
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_install-common.sh"
