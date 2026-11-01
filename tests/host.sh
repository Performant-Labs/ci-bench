#!/usr/bin/env bash
# Host facts, CPU steal and labels. Needs jq; schema validation needs python3 jsonschema.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export CI_BENCH_HOME="$root"
# shellcheck source=lib/common.sh
. "$root/lib/common.sh"
# shellcheck source=lib/host.sh
. "$root/lib/host.sh"

# Steal arithmetic.
[ "$(host_steal_percent "1000 10" "2000 60")" = "5.00" ] || fail "steal: expected 5.00"
[ "$(host_steal_percent "1000 10" "1000 10")" = null ] || fail "steal: empty window should be null"
[ "$(host_steal_percent "" "2000 60")" = null ] || fail "steal: missing sample should be null"

# /proc/stat parsing: user nice system idle iowait irq softirq steal (guest columns ignored).
printf 'cpu  100 0 50 800 10 0 5 20 7 3\ncpu0 1 1 1 1 1 1 1 1 1 1\n' >"$work/stat"
[ "$(CI_BENCH_PROC_STAT="$work/stat" host_steal_sample)" = "985 20" ] || fail "steal sample: got '$(CI_BENCH_PROC_STAT="$work/stat" host_steal_sample)'"

# A whole run on this machine: host and labels filled, labels unchanged, document validates.
doc="$work/run.json"
CI_BENCH_PROVIDER='Con"tabo & co' CI_BENCH_PLAN='Core 4' "$root/bin/benchmark:run" -o "$doc" >"$work/stdout.json" 2>"$work/stderr.txt" || true
cmp -s "$doc" "$work/stdout.json" || fail "-o file should equal stdout"
[ "$(jq -r .labels.provider "$doc")" = 'Con"tabo & co' ] || fail "provider label not recorded unchanged"
[ "$(jq -r .labels.plan "$doc")" = 'Core 4' ] || fail "plan label not recorded unchanged"
env -u CI_BENCH_PROVIDER -u CI_BENCH_PLAN "$root/bin/benchmark:run" 2>/dev/null | jq -e '.labels == {provider: "", plan: ""}' >/dev/null || fail "unset labels should be empty strings"
jq -e '.host | (.cores >= 1) and (.ram_bytes > 0) and (.hostname | length > 0) and (.distro | length > 0) and (.kernel | length > 0) and (.arch | length > 0)' "$doc" >/dev/null || fail "host facts incomplete"
grep -q 'ci-bench result' "$work/stderr.txt" || fail "human summary missing on stderr"
if python3 -I -c 'import jsonschema' 2>/dev/null; then
  python3 -I "$root/tests/validate_schema.py" "$doc" >/dev/null || fail "run document does not validate"
fi

# A failing -o target is an error.
if "$root/bin/benchmark:run" -o /nonexistent-dir/x.json >/dev/null 2>&1; then fail "unwritable -o should exit non-zero"; fi
echo "host: ok"
