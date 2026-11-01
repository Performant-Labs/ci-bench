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

# ci_hyperfine_summary <hyperfine --export-json file>: {median_s, min_s, max_s, runs}.
# runs counts measured runs only; hyperfine's warmup runs are not in "times".
ci_hyperfine_summary() {
  jq -e '.results[0] | {median_s: .median, min_s: .min, max_s: .max, runs: (.times | length)}' "$1" 2>/dev/null \
    || { echo "could not read hyperfine results from $1" >&2; return 1; }
}

# ci_source_id: the pinned source as {name, version, sha256}. Reads CI_BENCH_PIN or pin.env.
ci_source_id() {
  local pin="${CI_BENCH_PIN:-$CI_BENCH_HOME/pin.env}"
  [ -r "$pin" ] || { echo "cannot read $pin" >&2; return 1; }
  # shellcheck source=/dev/null
  ( . "$pin" && jq -n --arg n "$SOURCE_NAME" --arg v "$SOURCE_VERSION" --arg s "$SOURCE_SHA256" '{name: $n, version: $v, sha256: $s}' )
}

# ci_pinned_tarball: prints the path of the cached pinned tarball after verifying its checksum.
ci_pinned_tarball() {
  local pin="${CI_BENCH_PIN:-$CI_BENCH_HOME/pin.env}" file
  [ -r "$pin" ] || { echo "cannot read $pin" >&2; return 1; }
  # shellcheck source=/dev/null
  file="$CI_BENCH_CACHE_DIR/$( . "$pin" && printf '%s' "$SOURCE_FILE" )"
  [ -f "$file" ] || { echo "$file is missing; run benchmark:install" >&2; return 1; }
  # shellcheck source=/dev/null
  [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$( . "$pin" && printf '%s' "$SOURCE_SHA256" )" ] \
    || { echo "$file does not match the pinned checksum; run benchmark:install" >&2; return 1; }
  printf '%s' "$file"
}

# ci_preflight [args]: run the preflight command found on PATH (installed next to the others).
ci_preflight() {
  local p
  p="$(command -v benchmark:preflight)" || { echo "benchmark:preflight is not on PATH; run install.sh" >&2; return 1; }
  "$p" "$@"
}

# ci_issue_title: "ci-bench: <provider> <plan> <hostname>", empty segments dropped.
ci_issue_title() {
  local parts=("ci-bench:") seg
  for seg in "${CI_BENCH_PROVIDER:-}" "${CI_BENCH_PLAN:-}" "$1"; do
    if [ -n "$seg" ]; then parts+=("$seg"); fi
  done
  printf '%s' "${parts[*]}"
}

# ci_issue_create: create the host issue; prints {"number": N, "url": "..."}. Needs lib/host.sh.
ci_issue_create() {
  local host input
  host="$(host_json null)" || return 1
  input="$(jq -n --argjson host "$host" --argjson labels "$(labels_json)" '{host: $host, labels: $labels}')" || return 1
  node "$CI_BENCH_HOME/lib/issue.mjs" create --title "$(ci_issue_title "$(jq -r .hostname <<<"$host")")" <<<"$input"
}
