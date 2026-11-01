#!/usr/bin/env bash
# Preflight check runner and the real checks. Source lib/common.sh first.
#
# A check is a function that prints a short reason on stdout and returns 0 (ok) or
# non-zero (fail). pf_run executes every check it is given, prints one line each,
# never stops at the first failure, and returns 1 if any failed.

PF_FAILURES=0

pf_report() { printf '%s\n' "$*" >&2; }

pf_run() {
  local check status reason
  PF_FAILURES=0
  for check in "$@"; do
    status=0
    reason="$("$check" 2>&1)" || status=$?
    reason="${reason//$'\n'/ }"
    if [ "$status" -eq 0 ]; then
      pf_report "ok    ${check#check_}${reason:+ - $reason}"
    else
      pf_report "fail  ${check#check_}${reason:+ - $reason}"
      PF_FAILURES=$((PF_FAILURES + 1))
    fi
  done
  [ "$PF_FAILURES" -eq 0 ]
}

# ---- init set -------------------------------------------------------------

check_gh_installed() {
  command -v gh >/dev/null 2>&1 || { echo "gh is not on PATH; run install.sh"; return 1; }
}

check_gh_auth() {
  command -v gh >/dev/null 2>&1 || { echo "gh is not on PATH"; return 1; }
  if gh auth status >/dev/null 2>&1; then return 0; fi
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -n "$token" ]; then
    # gh refuses to store a login while GH_TOKEN is set in its environment.
    printf '%s' "$token" | env -u GH_TOKEN -u GITHUB_TOKEN gh auth login --with-token >/dev/null 2>&1 || true
    if env -u GH_TOKEN -u GITHUB_TOKEN gh auth status >/dev/null 2>&1; then
      echo "logged in from GH_TOKEN/GITHUB_TOKEN"
      return 0
    fi
  fi
  echo "gh is not logged in; run: gh auth login"
  return 1
}

check_gh_token() {
  command -v gh >/dev/null 2>&1 || { echo "gh is not on PATH"; return 1; }
  [ -n "$(gh auth token 2>/dev/null)" ] || { echo "gh auth token returned nothing; run: gh auth login"; return 1; }
}

check_gh_user() {
  local login
  login="$(gh api user --jq .login 2>/dev/null)" || login=""
  [ -n "$login" ] || { echo "gh api user failed; run: gh auth login"; return 1; }
  echo "$login"
}

check_repo_issues() {
  local repo has
  repo="$(ci_repo)"
  has="$(gh api "repos/$repo" --jq .has_issues 2>/dev/null)" || has=""
  if [ "$has" != true ]; then
    echo "$repo is unreachable or has issues disabled"
    return 1
  fi
  echo "$repo"
}

check_host_readers() {
  local missing=()
  command -v lscpu >/dev/null 2>&1 || [ -r /proc/cpuinfo ] || missing+=("lscpu or /proc/cpuinfo")
  command -v free >/dev/null 2>&1 || missing+=(free)
  command -v lsblk >/dev/null 2>&1 || missing+=(lsblk)
  if [ "${#missing[@]}" -gt 0 ]; then echo "missing: ${missing[*]}"; return 1; fi
}

# ---- run set --------------------------------------------------------------

check_sudo() {
  sudo -n true 2>/dev/null && return 0
  sudo -v >/dev/null 2>&1 && return 0
  echo "sudo -n true failed and sudo -v did not help; run: sudo -v"
  return 1
}

# pf_tool_check <command> <args...>: the tool runs.
pf_tool_check() {
  local name="$1"; shift
  command -v "$name" >/dev/null 2>&1 || { echo "$name is not installed; run benchmark:install"; return 1; }
  "$name" "$@" >/dev/null 2>&1 || { echo "$name $* failed"; return 1; }
}
check_sysbench() { pf_tool_check sysbench --version; }
check_fio() { pf_tool_check fio --version; }
check_gcc() { pf_tool_check gcc --version; }
check_make() { pf_tool_check make --version; }
check_hyperfine() { pf_tool_check hyperfine --version; }
check_node() {
  command -v node >/dev/null 2>&1 || { echo "node is not installed; run install.sh"; return 1; }
  node -v
}

check_octokit() {
  local entry="$CI_BENCH_HOME/node_modules/@octokit/rest/dist-src/index.js"
  command -v node >/dev/null 2>&1 || { echo "node is not installed"; return 1; }
  [ -r "$entry" ] || { echo "@octokit/rest is not installed under $CI_BENCH_HOME; run install.sh"; return 1; }
  node --input-type=module -e "const m = await import(process.argv[1]); if (typeof m.Octokit !== 'function') process.exit(1)" "$entry" \
    >/dev/null 2>&1 || { echo "@octokit/rest does not load"; return 1; }
}

check_docker() {
  sudo -n docker info >/dev/null 2>&1 || { echo "sudo -n docker info failed; run benchmark:install"; return 1; }
}

check_source_cache() {
  local pin="${CI_BENCH_PIN:-$CI_BENCH_HOME/pin.env}" file
  [ -r "$pin" ] || { echo "cannot read $pin"; return 1; }
  # shellcheck source=/dev/null
  . "$pin"
  file="$CI_BENCH_CACHE_DIR/$SOURCE_FILE"
  [ -f "$file" ] || { echo "$file is missing; run benchmark:install"; return 1; }
  [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$SOURCE_SHA256" ] \
    || { echo "$file does not match the pinned checksum; run benchmark:install"; return 1; }
  echo "$SOURCE_NAME $SOURCE_VERSION"
}

# Nearest existing directory at or above the fio directory.
pf_fio_anchor() {
  local d="$CI_BENCH_FIO_DIR"
  while [ ! -d "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done
  printf '%s' "$d"
}

check_fio_dir_not_tmpfs() {
  local anchor fstype
  anchor="$(pf_fio_anchor)"
  fstype="$(df --output=fstype "$anchor" 2>/dev/null | tail -n 1 | tr -d ' ')"
  case "$fstype" in
    tmpfs|ramfs) echo "$CI_BENCH_FIO_DIR is on $fstype; set CI_BENCH_FIO_DIR to a real filesystem"; return 1 ;;
    '') echo "cannot determine the filesystem of $CI_BENCH_FIO_DIR"; return 1 ;;
  esac
  echo "$fstype"
}

check_free_space() {
  local anchor avail need
  anchor="$(pf_fio_anchor)"
  avail="$(df --output=avail -B1 "$anchor" 2>/dev/null | tail -n 1 | tr -d ' ')"
  need=$(($(ci_fio_file_bytes) + 4 * 1024 * 1024 * 1024))
  [[ "$avail" =~ ^[0-9]+$ ]] || { echo "cannot read free space of $anchor"; return 1; }
  if [ "$avail" -lt "$need" ]; then
    echo "$((avail / 1048576)) MiB free on $anchor, need $((need / 1048576)) MiB"
    return 1
  fi
  echo "$((avail / 1048576)) MiB free"
}

check_docker_registry() {
  local code
  code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' https://registry-1.docker.io/v2/ 2>/dev/null)" || code=000
  case "$code" in
    200|401) ;;
    *) echo "registry-1.docker.io did not answer within 10 s (HTTP $code)"; return 1 ;;
  esac
}

# ---- issue check ----------------------------------------------------------

# PF_ISSUE is set by the caller (number or URL).
check_issue() {
  local repo num rc=0 json state is_pr author login perm
  repo="$(ci_repo)"
  num="$(ci_parse_issue_ref "$PF_ISSUE")" || rc=$?
  if [ "$rc" -eq 2 ]; then echo "$PF_ISSUE belongs to a different repo than $repo"; return 1; fi
  if [ "$rc" -ne 0 ] || [ -z "$num" ]; then echo "'$PF_ISSUE' is not an issue number or issue URL"; return 1; fi
  json="$(gh api "repos/$repo/issues/$num" 2>/dev/null)" || { echo "issue #$num not found in $repo"; return 1; }
  state="$(jq -r .state <<<"$json")"
  is_pr="$(jq -r 'has("pull_request")' <<<"$json")"
  [ "$state" = open ] || { echo "issue #$num is $state"; return 1; }
  [ "$is_pr" = false ] || { echo "#$num is a pull request, not an issue"; return 1; }
  author="$(jq -r .user.login <<<"$json")"
  login="$(gh api user --jq .login 2>/dev/null)" || login=""
  perm="$(gh api "repos/$repo" --jq '.permissions | if .admin or .push then "yes" else "no" end' 2>/dev/null)" || perm=no
  if [ "$login" != "$author" ] && [ "$perm" != yes ]; then
    echo "$login is not the author of #$num and has no push access to $repo, so the summary table cannot be updated"
    return 1
  fi
  echo "#$num is open in $repo"
}

pf_warn_labels() {
  [ -n "${CI_BENCH_PROVIDER:-}" ] || pf_report "warn  CI_BENCH_PROVIDER is not set; results will have an empty provider"
  [ -n "${CI_BENCH_PLAN:-}" ] || pf_report "warn  CI_BENCH_PLAN is not set; results will have an empty plan"
}

pf_init_checks() { echo check_gh_installed check_gh_auth check_gh_token check_gh_user check_repo_issues check_host_readers; }
pf_run_checks() {
  pf_init_checks
  echo check_sudo check_sysbench check_fio check_gcc check_make check_hyperfine check_node check_octokit \
    check_docker check_source_cache check_fio_dir_not_tmpfs check_free_space check_docker_registry
}
