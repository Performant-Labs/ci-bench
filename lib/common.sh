#!/usr/bin/env bash
# Shared helpers for the benchmark:* commands. Source this file; do not execute it.

CI_BENCH_HOME="${CI_BENCH_HOME:-/usr/local/lib/ci-bench}"
CI_BENCH_DEFAULT_REPO="Performant-Labs/ci-bench"
CI_BENCH_FIO_DIR="${CI_BENCH_FIO_DIR:-/var/tmp/ci-bench/fio}"
CI_BENCH_CACHE_DIR="${CI_BENCH_CACHE_DIR:-/var/lib/ci-bench/src}"

ci_repo() { printf '%s' "${CI_BENCH_REPO:-$CI_BENCH_DEFAULT_REPO}"; }

# Issue reference: "12" or "https://github.com/<owner>/<name>/issues/12".
# Prints the issue number. Returns 1 for anything else, 2 for another repo.
ci_parse_issue_ref() {
  local ref="$1" repo url_repo
  repo="$(ci_repo)"
  case "$ref" in
    ''|*[!0-9]*)
      url_repo="$(printf '%s' "$ref" | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/issues/[0-9]+/?$#\1#p')"
      [ -n "$url_repo" ] || return 1
      if [ "$(printf '%s' "$url_repo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]; then
        return 2
      fi
      printf '%s' "$ref" | sed -nE 's#.*/issues/([0-9]+)/?$#\1#p'
      ;;
    *) printf '%s' "$ref" ;;
  esac
}

# Size of the fio test file in bytes: 2 GiB on x86_64, 512 MiB elsewhere.
ci_fio_file_bytes() {
  if [ "$(uname -m)" = x86_64 ]; then echo $((2 * 1024 * 1024 * 1024)); else echo $((512 * 1024 * 1024)); fi
}
