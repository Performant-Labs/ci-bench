#!/usr/bin/env bash
# Docker probe: three cold builds timed by hyperfine, then one cached rebuild.
# Every docker command is `sudo -n docker`, so an inactive docker group cannot block it.
# Source lib/common.sh first.

DOCKER_COLD_RUNS=3
DOCKER_ROOT="${CI_BENCH_DOCKER_ROOT:-/var/tmp/ci-bench}"
DOCKER_TAG="ci-bench:src"
DOCKER_CTX=""

docker_cleanup() {
  if [ -n "$DOCKER_CTX" ] && [ -d "$DOCKER_CTX" ]; then rm -rf "$DOCKER_CTX"; fi
  DOCKER_CTX=""
  sudo -n docker image rm -f "$DOCKER_TAG" >/dev/null 2>&1 || true
}

# The FROM reference of the Dockerfile, e.g. debian@sha256:...
docker_base_ref() { sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$1" | head -n 1; }

probe_docker() {
  local dockerfile="$CI_BENCH_HOME/Dockerfile" tarball source_id source_file base prepare rc=0 image_id
  local -a build
  tarball="$(ci_pinned_tarball)" || return 1
  source_id="$(ci_source_id)" || return 1
  source_file="$(basename "$tarball")"
  [ -r "$dockerfile" ] || { echo "cannot read $dockerfile" >&2; return 1; }
  command -v hyperfine >/dev/null 2>&1 || { echo "hyperfine is not installed; run benchmark:install" >&2; return 1; }
  sudo -n docker info >/dev/null 2>&1 || { echo "sudo -n docker info failed; run benchmark:install" >&2; return 1; }
  mkdir -p "$DOCKER_ROOT" 2>/dev/null || { echo "cannot create $DOCKER_ROOT" >&2; return 1; }
  trap docker_cleanup EXIT INT TERM
  DOCKER_CTX="$(mktemp -d "$DOCKER_ROOT/docker.XXXXXX")" || { echo "cannot create a build context in $DOCKER_ROOT" >&2; return 1; }
  cp "$dockerfile" "$DOCKER_CTX/Dockerfile"
  cp "$tarball" "$DOCKER_CTX/$source_file"
  base="$(docker_base_ref "$dockerfile")"

  build=(sudo -n docker build --build-arg "SOURCE_FILE=$source_file" -t "$DOCKER_TAG")
  # Cold: no build cache and no local copy of the base image, so the pull and the package
  # installs are part of the number.
  prepare="sudo -n docker builder prune -af >/dev/null 2>&1; sudo -n docker image rm -f $DOCKER_TAG '$base' >/dev/null 2>&1; true"
  hyperfine --runs "$DOCKER_COLD_RUNS" --warmup 0 --prepare "$prepare" --export-json "$DOCKER_CTX/cold.json" --style none \
    "${build[*]} --no-cache '$DOCKER_CTX'" >/dev/null 2>"$DOCKER_CTX/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "cold docker build failed (exit $rc): $(tail -n 5 "$DOCKER_CTX/err" 2>/dev/null | tr '\n' ' ')" >&2
    docker_cleanup; return 1
  fi
  local cold
  cold="$(ci_hyperfine_summary "$DOCKER_CTX/cold.json")" || { docker_cleanup; return 1; }

  # Cached: one rebuild straight after, without prune and without --no-cache.
  local t0 t1 cached
  t0="$(date +%s.%N)"
  if ! "${build[@]}" "$DOCKER_CTX" >/dev/null 2>"$DOCKER_CTX/err"; then
    echo "cached docker build failed: $(tail -n 5 "$DOCKER_CTX/err" | tr '\n' ' ')" >&2
    docker_cleanup; return 1
  fi
  t1="$(date +%s.%N)"
  cached="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')"
  image_id="$(sudo -n docker image inspect --format '{{.Id}}' "$DOCKER_TAG" 2>/dev/null)" || image_id=""
  docker_cleanup

  jq -n --argjson cold "$cold" --argjson cached "$cached" --arg image "$image_id" --argjson src "$source_id" \
    '{cold: {median_s: $cold.median_s, min_s: $cold.min_s, max_s: $cold.max_s, runs: $cold.runs},
      cached_s: $cached, image_id: $image, source: $src}'
}
