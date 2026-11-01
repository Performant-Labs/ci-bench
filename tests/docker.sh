#!/usr/bin/env bash
# Docker probe with a fake sudo/docker and a fake hyperfine: command shapes, the cold/cached split,
# failure handling, and the Dockerfile's digest pin. No Docker needed.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export CI_BENCH_HOME="$root"

# --- the Dockerfile pins its base image by digest and builds the pinned source
grep -Eq '^FROM [a-z0-9./_-]+@sha256:[0-9a-f]{64}$' "$root/Dockerfile" || fail "Dockerfile must pin its base image by digest"
grep -q 'ARG SOURCE_FILE' "$root/Dockerfile" || fail "Dockerfile should take SOURCE_FILE"
# shellcheck disable=SC2016
grep -q 'make -C /src/tree -j"$(nproc)"' "$root/Dockerfile" || fail "Dockerfile should run make -j\$(nproc) like the compile probe"

# --- fixtures: pin + tarball
mkdir -p "$work/cache" "$work/fake"
echo "tarball" >"$work/cache/proj-1.0.tar.gz"
sha="$(sha256sum "$work/cache/proj-1.0.tar.gz" | cut -d' ' -f1)"
printf 'SOURCE_NAME=proj\nSOURCE_VERSION=1.0\nSOURCE_FILE=proj-1.0.tar.gz\nSOURCE_SHA256=%s\n' "$sha" >"$work/pin.env"
export CI_BENCH_PIN="$work/pin.env" CI_BENCH_CACHE_DIR="$work/cache" CI_BENCH_DOCKER_ROOT="$work/ctx"
# shellcheck source=lib/common.sh
. "$root/lib/common.sh"
# shellcheck source=lib/docker.sh
. "$root/lib/docker.sh"

# --- fakes
cat >"$work/fake/sudo" <<FAKE
#!/usr/bin/env bash
echo "\$*" >>"$work/sudo.log"
[ "\$1" = "-n" ] && shift
case "\$*" in
  "docker info") exit 0 ;;
  "docker image inspect"*) echo "sha256:fakeimageid" ;;
  "docker build"*) [ "\${FAKE_BUILD_FAIL:-0}" = 1 ] && { echo "build exploded" >&2; exit 1; }; exit 0 ;;
esac
exit 0
FAKE
cat >"$work/fake/hyperfine" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$work/hf.args"
while [ "\$#" -gt 0 ]; do case "\$1" in --export-json) cp "$root/tests/fixtures/hyperfine.json" "\$2"; shift 2 ;; *) shift ;; esac; done
[ "\${FAKE_HF_FAIL:-0}" = 1 ] && { echo "hyperfine: command failed" >&2; exit 1; }
exit 0
FAKE
chmod +x "$work/fake/"*
export PATH="$work/fake:$PATH"

: >"$work/sudo.log"
out="$(probe_docker)" || fail "probe_docker failed"
args="$(cat "$work/hf.args")"
printf '%s\n' "$args" | grep -qx -- '--runs' || fail "hyperfine needs --runs"
printf '%s\n' "$args" | grep -A1 -x -- '--runs' | tail -1 | grep -qx 3 || fail "three cold runs"
printf '%s\n' "$args" | grep -A1 -x -- '--prepare' | tail -1 | grep -q 'sudo -n docker builder prune -af' || fail "prepare must prune the builder cache with sudo docker"
printf '%s\n' "$args" | grep -q 'sudo -n docker build .*--no-cache' || fail "cold command must use --no-cache: $args"
# The cached rebuild is the only build outside hyperfine: no --no-cache, no prune before it.
cached_line="$(grep '^-n docker build\|^docker build' "$work/sudo.log" | tail -1)"
[ -n "$cached_line" ] || fail "no cached build recorded: $(cat "$work/sudo.log")"
case "$cached_line" in *--no-cache*) fail "cached build must not use --no-cache" ;; esac
! grep -q 'builder prune' "$work/sudo.log" || fail "prune must only happen in hyperfine's prepare: $(cat "$work/sudo.log")"
jq -e --arg sha "$sha" '.cold.runs == 3 and (.cold.median_s > 0) and (.cached_s >= 0) and .image_id == "sha256:fakeimageid" and .source.sha256 == $sha and (.cold | has("min_s") and has("max_s"))' <<<"$out" >/dev/null || fail "probe json: $out"
[ -z "$(ls -A "$work/ctx")" ] || fail "build context left behind"
grep -q 'image rm -f ci-bench:src' "$work/sudo.log" || fail "probe image should be removed afterwards"

# --- failures: probe fails with a message, context removed
if FAKE_HF_FAIL=1 probe_docker >/dev/null 2>"$work/err"; then fail "failing cold build should fail the probe"; fi
grep -q 'cold docker build failed' "$work/err" || fail "cold failure message missing"
[ -z "$(ls -A "$work/ctx")" ] || fail "context left after cold failure"
if FAKE_BUILD_FAIL=1 probe_docker >/dev/null 2>"$work/err"; then fail "failing cached build should fail the probe"; fi
grep -q 'cached docker build failed' "$work/err" || fail "cached failure message missing"
echo corrupt >"$work/cache/proj-1.0.tar.gz"
if probe_docker >/dev/null 2>"$work/err"; then fail "checksum mismatch should fail"; fi
grep -q checksum "$work/err" || fail "checksum message missing"
echo "docker: ok"
