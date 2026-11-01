#!/usr/bin/env bash
# CPU probe parsing against captured sysbench output; probe failure handling with a fake sysbench.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=tests/lib-home.sh
. "$root/tests/lib-home.sh"
make_home "$work/home" cpu
export CI_BENCH_HOME="$work/home"
# shellcheck source=lib/cpu.sh
. "$root/lib/cpu.sh"

got="$(cpu_parse 1 <"$root/tests/fixtures/sysbench-cpu-1.txt")" || fail "fixture should parse"
jq -e '.threads == 1 and .events_per_sec == 1712.48 and .total_time_s == 10.0002' <<<"$got" >/dev/null || fail "fixture parsed wrongly: $got"
if echo "garbage" | cpu_parse 1 >/dev/null 2>&1; then fail "garbage should not parse"; fi

# The command line sysbench is given: both runs, prime limit 20000, 1 then nproc threads.
mkdir -p "$work/fake"
cat >"$work/fake/sysbench" <<FAKE
#!/usr/bin/env bash
echo "\$*" >>"$work/calls"
[ "\${FAKE_FAIL:-0}" = 1 ] && { echo "boom" >&2; exit 1; }
cat "$root/tests/fixtures/sysbench-cpu-1.txt"
FAKE
chmod +x "$work/fake/sysbench"
out="$(PATH="$work/fake:$PATH" probe_cpu)" || fail "probe_cpu with fake sysbench failed"
[ "$(wc -l <"$work/calls")" -eq 2 ] || fail "sysbench should run exactly twice"
sed -n 1p "$work/calls" | grep -qx "cpu --cpu-max-prime=20000 --threads=1 run" || fail "first call: $(sed -n 1p "$work/calls")"
sed -n 2p "$work/calls" | grep -qx "cpu --cpu-max-prime=20000 --threads=$(nproc) run" || fail "second call: $(sed -n 2p "$work/calls")"
jq -e --argjson n "$(nproc)" '.single_thread.threads == 1 and .multi_thread.threads == $n' <<<"$out" >/dev/null || fail "probe JSON wrong: $out"

# A sysbench failure fails the probe, and benchmark:run records an error and still emits a document.
doc="$(PATH="$work/fake:$PATH" FAKE_FAIL=1 "$root/bin/benchmark:run" 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] || fail "run with failing sysbench should exit 1, got $rc"
jq -e '.cpu == {} and (.errors | map(.probe) | index("cpu")) != null and (.host.hostname | length > 0)' <<<"$doc" >/dev/null || fail "failed probe should leave cpu {} and an error: $doc"
echo "cpu: ok"
