#!/usr/bin/env bash
# Compile probe: build the pinned source with make -j$(nproc), timed by hyperfine.
# Source lib/common.sh first.

COMPILE_RUNS=3
COMPILE_WARMUP=1
COMPILE_ROOT="${CI_BENCH_COMPILE_ROOT:-/var/tmp/ci-bench}"
COMPILE_DIR=""

compile_cleanup() {
  if [ -n "$COMPILE_DIR" ] && [ -d "$COMPILE_DIR" ]; then rm -rf "$COMPILE_DIR"; fi
  COMPILE_DIR=""
}

probe_compile() {
  local tarball source_id tmp_json jobs prepare rc=0
  tarball="$(ci_pinned_tarball)" || return 1
  source_id="$(ci_source_id)" || return 1
  command -v hyperfine >/dev/null 2>&1 || { echo "hyperfine is not installed; run benchmark:install" >&2; return 1; }
  mkdir -p "$COMPILE_ROOT" 2>/dev/null || { echo "cannot create $COMPILE_ROOT" >&2; return 1; }
  trap compile_cleanup EXIT INT TERM
  COMPILE_DIR="$(mktemp -d "$COMPILE_ROOT/compile.XXXXXX")" || { echo "cannot create a build directory in $COMPILE_ROOT" >&2; return 1; }
  tmp_json="$COMPILE_DIR/hyperfine.json"
  jobs="$(nproc)"
  # hyperfine runs --prepare before the warmup and before each measured run, so every build
  # starts from a freshly unpacked tree and no object files are reused.
  prepare="rm -rf '$COMPILE_DIR/src' && mkdir -p '$COMPILE_DIR/src' && tar -xzf '$tarball' -C '$COMPILE_DIR/src' --strip-components=1"
  hyperfine --runs "$COMPILE_RUNS" --warmup "$COMPILE_WARMUP" --prepare "$prepare" \
    --export-json "$tmp_json" --style none \
    "make -C '$COMPILE_DIR/src' -j$jobs" >/dev/null 2>"$COMPILE_DIR/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "hyperfine/make failed (exit $rc): $(tail -n 5 "$COMPILE_DIR/err" 2>/dev/null | tr '\n' ' ')" >&2
    compile_cleanup
    return 1
  fi
  local summary
  summary="$(ci_hyperfine_summary "$tmp_json")" || { compile_cleanup; return 1; }
  compile_cleanup
  jq -n --argjson s "$summary" --argjson w "$COMPILE_WARMUP" --argjson src "$source_id" \
    '$s + {warmup: $w, source: $src}'
}
