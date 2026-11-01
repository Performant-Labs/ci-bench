#!/usr/bin/env bash
# benchmark:compare against the checked-in fixtures. No sysbench, fio or Docker needed.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmp="$root/bin/benchmark:compare"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok="$root/examples/result-ok.json"
failed="$root/examples/result-failed-probe.json"

# Complete table, exit 0, even though the second host's probes failed.
out="$("$cmp" "$ok" "$failed")" || fail "compare exited non-zero on valid fixtures"
printf '%s\n' "$out" | head -1 | grep -q 'Contabo / Core' || fail "header should use provider / plan"
printf '%s\n' "$out" | head -1 | grep -q 'cx32-example' || fail "header should fall back to hostname"
for row in cores RAM 'root disk rotational' 'CPU steal' 'sysbench 1-thread' 'sysbench all-core' \
  'fio YABS 4k read IOPS' 'fio YABS 1m write bandwidth' 'fio CI 16k read IOPS' 'fio CI 16k write bandwidth' \
  'compile median' 'Docker cold median' 'Docker cached'; do
  printf '%s\n' "$out" | grep -q "^$row" || fail "missing row: $row"
done
printf '%s\n' "$out" | grep '^Docker cold median' | grep -q '—' || fail "failed Docker probe should print a dash"
printf '%s\n' "$out" | grep '^Docker cold median' | grep -q '88.7 s' || fail "good Docker probe should print its value"
printf '%s\n' "$out" | grep '^fio CI 16k read IOPS' | grep -q '15000' || fail "good fio value missing"
[ "$(printf '%s\n' "$out" | wc -l)" -eq 31 ] || fail "expected 31 lines (header, rule, 29 rows)"

# Three hosts work.
"$cmp" "$ok" "$failed" "$ok" >/dev/null || fail "three-host compare failed"

# Bad inputs exit non-zero.
jq '.schema_version = "99"' "$ok" >"$work/badver.json"
if "$cmp" "$ok" "$work/badver.json" >/dev/null 2>&1; then fail "unknown schema_version should fail"; fi
jq 'del(.docker)' "$ok" >"$work/nodocker.json"
if "$cmp" "$ok" "$work/nodocker.json" >/dev/null 2>&1; then fail "missing required field should fail"; fi
if "$cmp" "$ok" >/dev/null 2>&1; then fail "single file should be a usage error"; fi
if "$cmp" "$ok" "$work/missing.json" >/dev/null 2>&1; then fail "unreadable file should fail"; fi
echo "compare: ok"
