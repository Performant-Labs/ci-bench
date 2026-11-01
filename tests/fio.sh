#!/usr/bin/env bash
# Disk probes with a fake fio and fake df: parsing, exact flags, refusal on tmpfs or low space,
# and cleanup of the test files on success and on failure. No real fio runs.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=tests/lib-home.sh
. "$root/tests/lib-home.sh"
make_home "$work/home" fio
export CI_BENCH_HOME="$work/home" STUB_DIR="$work"
export PATH="$work/home/bin:$PATH"
# shellcheck source=lib/common.sh
. "$root/lib/common.sh"
# shellcheck source=lib/fio.sh
. "$root/lib/fio.sh"

# --- parsing real fio output
got="$(fio_parse <"$root/tests/fixtures/fio-gtod.json")" || fail "gtod fixture should parse"
jq -e '.read.iops > 100000 and .read.lat_mean_ns == null and .read.lat_p99_ns == null and .write.bw_bytes_per_sec > 0' <<<"$got" >/dev/null || fail "gtod fixture: $got"
got="$(fio_parse <"$root/tests/fixtures/fio-lat.json")" || fail "lat fixture should parse"
jq -e '.read.lat_mean_ns > 0 and .read.lat_p99_ns == 790528 and .write.lat_p99_ns == 798720' <<<"$got" >/dev/null || fail "lat fixture: $got"
if echo "not json" | fio_parse >/dev/null 2>&1; then fail "garbage should not parse"; fi

# --- fakes
mkdir -p "$work/fake"
cat >"$work/fake/fio" <<FAKE
#!/usr/bin/env bash
echo "\$*" >>"$work/fio.calls"
ls "$work/fiodir"/job.* >/dev/null 2>&1 && echo "job dir existed" >>"$work/fio.seen"
case " \$* " in *" --name=ci-io "*) touch "\$(printf '%s\n' "\$@" | sed -n 's/^--filename=//p')";; esac
[ "\${FAKE_FIO_FAIL:-0}" = 1 ] && { echo "fio: boom" >&2; exit 1; }
echo "fio-3.41 warning line before the JSON"
cat "$root/tests/fixtures/fio-lat.json"
FAKE
cat >"$work/fake/df" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *fstype*) printf 'Type\n%s\n' "${FAKE_FSTYPE:-ext4}" ;;
  *avail*) printf 'Avail\n%s\n' "${FAKE_AVAIL:-999999999999}" ;;
esac
FAKE
chmod +x "$work/fake/"*
export PATH="$work/fake:$PATH" CI_BENCH_FIO_DIR="$work/fiodir"

size=2G; [ "$(uname -m)" = x86_64 ] || size=512M

# --- YABS profile: four runs with the exact flags
: >"$work/fio.calls"
out="$(probe_fio_yabs)" || fail "probe_fio_yabs failed"
[ "$(wc -l <"$work/fio.calls")" -eq 4 ] || fail "expected 4 fio runs, got $(wc -l <"$work/fio.calls")"
for bs in 4k 64k 512k 1m; do
  line="$(grep -- "--name=rand_rw_$bs " "$work/fio.calls")" || fail "no run for $bs"
  for flag in --ioengine=libaio --rw=randrw --rwmixread=50 "--bs=$bs" --iodepth=64 --numjobs=2 "--size=$size" \
      --runtime=30 --gtod_reduce=1 --direct=1 --group_reporting --output-format=json; do
    case " $line " in *" $flag "*) ;; *) fail "$bs run lacks $flag: $line" ;; esac
  done
done
jq -e 'keys == ["1m","4k","512k","64k"] and (.["4k"].read.iops > 0) and (.["1m"].write.bw_bytes_per_sec > 0)' <<<"$out" >/dev/null || fail "yabs json: $out"
[ -z "$(ls -A "$work/fiodir")" ] || fail "yabs left files behind: $(ls -A "$work/fiodir")"

# --- CI profile: one run with the exact flags
: >"$work/fio.calls"
out="$(probe_fio_ci)" || fail "probe_fio_ci failed"
[ "$(wc -l <"$work/fio.calls")" -eq 1 ] || fail "expected 1 CI fio run"
line="$(cat "$work/fio.calls")"
for flag in --name=ci-io --rw=randrw --rwmixread=70 --bs=16k --iodepth=8 --numjobs=4 --runtime=60 --time_based=1 --group_reporting --direct=1 --size=2G; do
  case " $line " in *" $flag "*) ;; *) fail "CI run lacks $flag: $line" ;; esac
done
jq -e '.read.iops > 0 and .write.iops > 0' <<<"$out" >/dev/null || fail "ci json: $out"
[ -z "$(ls -A "$work/fiodir")" ] || fail "ci profile left files behind"

# --- tmpfs and low free space: skipped with a message, no fio started
: >"$work/fio.calls"
if FAKE_FSTYPE=tmpfs probe_fio_yabs >/dev/null 2>"$work/err"; then fail "tmpfs should fail the yabs probe"; fi
grep -q tmpfs "$work/err" || fail "tmpfs message missing"
if FAKE_AVAIL=1000 probe_fio_ci >/dev/null 2>"$work/err"; then fail "low space should fail the ci probe"; fi
grep -q 'need' "$work/err" || fail "low space message missing"
[ ! -s "$work/fio.calls" ] || fail "fio must not start on tmpfs or low space"

# --- fio failure: probe fails, files are removed
if FAKE_FIO_FAIL=1 probe_fio_ci >/dev/null 2>"$work/err"; then fail "fio failure should fail the probe"; fi
grep -q 'boom' "$work/err" || fail "fio error text missing"
[ -z "$(ls -A "$work/fiodir")" ] || fail "failed run left files behind"

# --- through benchmark:run: errors recorded, JSON still emitted
doc="$(FAKE_FSTYPE=tmpfs "$root/bin/benchmark:run" --issue 1 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] || fail "run on tmpfs should exit 1, got $rc"
jq -e '.fio_yabs == {} and .fio_ci == {} and ([.errors[].probe] | index("fio_yabs")) != null and ([.errors[].probe] | index("fio_ci")) != null' <<<"$doc" >/dev/null || fail "tmpfs run doc: $doc"
echo "fio: ok"
