#!/usr/bin/env bash
# Compile probe. A tiny tarball stands in for Redis. Uses real hyperfine when installed, a fake otherwise.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export CI_BENCH_HOME="$root"

# --- ci_hyperfine_summary on a real hyperfine export
# shellcheck source=lib/common.sh
. "$root/lib/common.sh"
s="$(ci_hyperfine_summary "$root/tests/fixtures/hyperfine.json")" || fail "fixture should summarize"
jq -e '.runs == 3 and .median_s > 0.2 and .min_s <= .median_s and .median_s <= .max_s' <<<"$s" >/dev/null || fail "summary: $s"

# --- a tiny pinned project
mkdir -p "$work/proj-1.0" "$work/cache"
printf 'all:\n\techo built >> "%s/builds.log"\n\ttouch objfile\n' "$work" >"$work/proj-1.0/Makefile"
tar -czf "$work/cache/proj-1.0.tar.gz" -C "$work" proj-1.0
sha="$(sha256sum "$work/cache/proj-1.0.tar.gz" | cut -d' ' -f1)"
cat >"$work/pin.env" <<PIN
SOURCE_NAME=proj
SOURCE_VERSION=1.0
SOURCE_FILE=proj-1.0.tar.gz
SOURCE_SHA256=$sha
PIN
export CI_BENCH_PIN="$work/pin.env" CI_BENCH_CACHE_DIR="$work/cache" CI_BENCH_COMPILE_ROOT="$work/build"
# shellcheck source=lib/compile.sh
. "$root/lib/compile.sh"

# --- flags, with a fake hyperfine
mkdir -p "$work/fake"
cat >"$work/fake/hyperfine" <<FAKE
#!/usr/bin/env bash
echo "\$*" >"$work/hf.args"
while [ "\$#" -gt 0 ]; do case "\$1" in --export-json) cp "$root/tests/fixtures/hyperfine.json" "\$2"; shift 2 ;; *) shift ;; esac; done
FAKE
chmod +x "$work/fake/hyperfine"
out="$(PATH="$work/fake:$PATH" probe_compile)" || fail "probe_compile with fake hyperfine failed"
args="$(cat "$work/hf.args")"
case "$args" in *"--runs 3"*) ;; *) fail "needs --runs 3: $args" ;; esac
case "$args" in *"--warmup 1"*) ;; *) fail "needs --warmup 1: $args" ;; esac
case "$args" in *"--prepare"*"tar -xzf"*) ;; *) fail "needs a --prepare that unpacks the tarball: $args" ;; esac
case "$args" in *"make -C"*"-j$(nproc)"*) ;; *) fail "needs make -j\$(nproc): $args" ;; esac
jq -e --arg sha "$sha" '.runs == 3 and .warmup == 1 and .source == {name: "proj", version: "1.0", sha256: $sha} and (.median_s > 0)' <<<"$out" >/dev/null || fail "probe json: $out"
[ -z "$(ls -A "$work/build")" ] || fail "build directory left behind"

# --- real hyperfine: one warmup + three measured builds, each from a fresh tree
if command -v hyperfine >/dev/null 2>&1; then
  : >"$work/builds.log"
  out="$(probe_compile)" || fail "probe_compile with real hyperfine failed"
  [ "$(wc -l <"$work/builds.log")" -eq 4 ] || fail "expected 4 builds (1 warmup + 3), got $(wc -l <"$work/builds.log") - an object tree was reused or a run was skipped"
  jq -e '.runs == 3 and .warmup == 1' <<<"$out" >/dev/null || fail "real hyperfine json: $out"
  [ -z "$(ls -A "$work/build")" ] || fail "real run left a build directory behind"
  # A failing build fails the probe and cleans up.
  printf 'all:\n\tfalse\n' >"$work/proj-1.0/Makefile"
  tar -czf "$work/cache/proj-1.0.tar.gz" -C "$work" proj-1.0
  sed -i "s/^SOURCE_SHA256=.*/SOURCE_SHA256=$(sha256sum "$work/cache/proj-1.0.tar.gz" | cut -d' ' -f1)/" "$work/pin.env"
  if probe_compile >/dev/null 2>"$work/err"; then fail "failing make should fail the probe"; fi
  grep -q 'failed' "$work/err" || fail "failure message missing"
  [ -z "$(ls -A "$work/build")" ] || fail "failed run left a build directory behind"
fi

# --- missing and mismatched tarball
rm -f "$work/cache/proj-1.0.tar.gz"
if probe_compile >/dev/null 2>"$work/err"; then fail "missing tarball should fail"; fi
grep -q 'benchmark:install' "$work/err" || fail "missing tarball should point at benchmark:install"
echo corrupt >"$work/cache/proj-1.0.tar.gz"
if probe_compile >/dev/null 2>"$work/err"; then fail "bad checksum should fail"; fi
grep -q 'checksum' "$work/err" || fail "checksum message missing"
echo "compile: ok"
