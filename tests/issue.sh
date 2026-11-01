#!/usr/bin/env bash
# Runs the Node tests for the issue renderers and GitHub logic (needs Node 20+ for node --test).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --test "$root/tests/issue.test.mjs"
