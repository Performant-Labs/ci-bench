#!/usr/bin/env bash
# Preflight unit tests. No real gh call, no probe, no network beyond an optional registry check.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export CI_BENCH_HOME="$root"

# --- 1. A fake check list: exit 1, and every failure appears in the output.
cat >"$work/fake-list.sh" <<FAKE
. "$root/lib/common.sh"
. "$root/lib/preflight.sh"
check_fake_ok() { echo "fine"; }
check_fake_gh_auth() { echo "gh is not logged in; run: gh auth login"; return 1; }
check_fake_fio() { echo "fio is not installed; run benchmark:install"; return 1; }
pf_run check_fake_ok check_fake_gh_auth check_fake_fio
echo "rc=\$? failures=\$PF_FAILURES" >&2
FAKE
out="$(bash "$work/fake-list.sh" 2>&1)"
echo "$out" | grep -q '^ok    fake_ok' || fail "fake list: passing check missing"
echo "$out" | grep -q '^fail  fake_gh_auth.*gh auth login' || fail "fake list: gh failure missing"
echo "$out" | grep -q '^fail  fake_fio' || fail "fake list: fio failure missing (runner stopped early?)"
echo "$out" | grep -q 'rc=1 failures=2' || fail "fake list: expected rc=1 with 2 failures, got: $(echo "$out" | tail -1)"

# --- 2. The real command with a fake gh (not logged in) and a fake fio (broken).
mkdir -p "$work/fake"
cat >"$work/fake/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_LOG"
exit 1
GH
printf '#!/usr/bin/env bash\nexit 1\n' >"$work/fake/fio"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/fake/sudo"
chmod +x "$work/fake/"*
export FAKE_LOG="$work/calls.log"; : >"$FAKE_LOG"
rc=0
out="$(env -u GH_TOKEN -u GITHUB_TOKEN PATH="$work/fake:$PATH" "$root/bin/benchmark:preflight" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "preflight with gh auth and fio broken: expected exit 1, got $rc"
echo "$out" | grep -q '^fail  gh_auth.*gh auth login' || fail "preflight: gh auth failure not reported"
echo "$out" | grep -q '^fail  fio' || fail "preflight: fio failure not reported"
echo "$out" | grep -q 'preflight failed' || fail "preflight: no summary line"
echo "$out" | grep -q 'warn  CI_BENCH_PROVIDER' || fail "preflight: unset label should warn"

# --- 3. GH_TOKEN login: stored via --with-token, token never printed.
cat >"$work/fake/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  "auth status") [ -e "$FAKE_STATE" ] && exit 0 || exit 1 ;;
  "auth login --with-token") cat >/dev/null; touch "$FAKE_STATE"; exit 0 ;;
esac
exit 1
GH
export FAKE_STATE="$work/logged-in"
rc=0
out="$(PATH="$work/fake:$PATH" GH_TOKEN=s3cr3t-token-value "$root/bin/benchmark:preflight" --for init 2>&1)" || rc=$?
echo "$out" | grep -q '^ok    gh_auth' || fail "GH_TOKEN login: gh_auth should pass after --with-token"
echo "$out" | grep -q 's3cr3t-token-value' && fail "GH_TOKEN login: the token was printed"
[ -e "$FAKE_STATE" ] || fail "GH_TOKEN login: --with-token was not used"

# --- 4. Issue references.
# shellcheck source=lib/common.sh
. "$root/lib/common.sh"
CI_BENCH_REPO=""; unset CI_BENCH_REPO
[ "$(ci_parse_issue_ref 12)" = 12 ] || fail "issue ref: bare number"
[ "$(ci_parse_issue_ref https://github.com/Performant-Labs/ci-bench/issues/34)" = 34 ] || fail "issue ref: URL"
[ "$(ci_parse_issue_ref https://github.com/performant-labs/CI-bench/issues/34/)" = 34 ] || fail "issue ref: URL is case-insensitive"
rc=0; ci_parse_issue_ref https://github.com/other/repo/issues/3 >/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "issue ref: other repo should return 2, got $rc"
rc=0; ci_parse_issue_ref nonsense >/dev/null || rc=$?
[ "$rc" -eq 1 ] || fail "issue ref: garbage should return 1, got $rc"
echo "preflight: ok"
