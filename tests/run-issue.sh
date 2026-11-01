#!/usr/bin/env bash
# benchmark:run and benchmark:init-run issue handling: gating, preflight order, prompt, titles.
# Uses a stub issue.mjs and a fake preflight; no GitHub, no probes (all probes are inert stubs).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=tests/lib-home.sh
. "$root/tests/lib-home.sh"
make_home "$work/home"
export CI_BENCH_HOME="$work/home" STUB_DIR="$work"
mkdir -p "$work/forbidden"
for t in sudo docker sysbench fio hyperfine; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/forbidden.log"\nexit 1\n' "$t" "$work" >"$work/forbidden/$t"; chmod +x "$work/forbidden/$t"
done
export PATH="$work/forbidden:$work/home/bin:$PATH"
run="$root/bin/benchmark:run"; init="$root/bin/benchmark:init-run"
reset() { rm -f "$work"/preflight.log "$work"/issue-*; }

# 1. No --issue and no TTY: exit 1 with the message, preflight ran, nothing created or posted.
reset
out="$("$run" </dev/null 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 1 ] || fail "no issue, no TTY: expected exit 1, got $rc"
case "$out" in *"--issue <n>"*"benchmark:init-run"*) ;; *) fail "message should name --issue and init-run: $out" ;; esac
case "$out" in *"Create a new issue?"*) fail "must not prompt without a TTY" ;; esac
[ "$(cat "$work/preflight.log")" = "" ] || fail "run preflight takes no arguments without --issue: '$(cat "$work/preflight.log")'"
[ ! -e "$work/issue-create.args" ] || fail "no issue may be created"
[ ! -e "$work/issue-append.json" ] || fail "no issue may be updated"

# 2. Preflight fails: exit 1 before the prompt, before anything else.
reset
FAKE_PREFLIGHT_RC=1 "$run" --issue 5 >"$work/stdout" 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] || fail "preflight failure: expected exit 1, got $rc"
[ ! -s "$work/stdout" ] || fail "no result document may be printed when preflight fails"
[ ! -e "$work/issue-append.json" ] || fail "no issue update when preflight fails"

# 3. --issue N and --issue URL: preflight gets the reference, the run is appended to that issue.
for ref in 5 https://github.com/Performant-Labs/ci-bench/issues/5; do
  reset
  "$run" --issue "$ref" >"$work/stdout" 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] || fail "--issue $ref: expected exit 0, got $rc"
  [ "$(cat "$work/preflight.log")" = "--issue $ref" ] || fail "preflight should receive --issue $ref, got '$(cat "$work/preflight.log")'"
  [ "$(cat "$work/issue-append.args")" = "--issue 5" ] || fail "append should target #5: $(cat "$work/issue-append.args")"
  jq -S . "$work/stdout" >"$work/a.json"; jq -S . "$work/issue-append.json" >"$work/b.json"
  cmp -s "$work/a.json" "$work/b.json" || fail "the appended document must equal the printed one"
done
reset
if "$run" --issue https://github.com/other/repo/issues/5 >/dev/null 2>&1; then fail "an issue of another repo must be refused"; fi
[ ! -e "$work/issue-append.json" ] || fail "nothing may be appended for another repo"

# 4. Failing probe or failing issue update: the document is still printed, exit is non-zero.
reset
sed -i 's/probe_cpu() { echo "{}"; }/probe_cpu() { echo "cpu exploded" >\&2; return 1; }/' "$work/home/lib/cpu.sh"
"$run" --issue 5 >"$work/stdout" 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] || fail "probe error: expected exit 1, got $rc"
jq -e '[.errors[].probe] | index("cpu") != null' "$work/stdout" >/dev/null || fail "probe error not in the document"
[ -s "$work/issue-append.json" ] || fail "the run must still be posted when a probe failed"
sed -i 's/probe_cpu() {.*/probe_cpu() { echo "{}"; }/' "$work/home/lib/cpu.sh"

# 5. Prompt on a TTY (via script): Enter creates nothing; y creates the issue and runs against it.
if command -v script >/dev/null 2>&1; then
  reset
  printf '\n' | script -qec "$run" /dev/null >"$work/tty.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] || fail "Enter at the prompt: expected exit 1, got $rc"
  grep -q 'Create a new issue?' "$work/tty.out" || fail "the prompt text is missing: $(cat "$work/tty.out")"
  [ ! -e "$work/issue-create.args" ] || fail "Enter must not create an issue"
  [ ! -e "$work/issue-append.json" ] || fail "Enter must not run probes or post"
  reset
  printf 'yes\n' | script -qec "$run" /dev/null >"$work/tty.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "yes at the prompt: expected exit 0, got $rc: $(cat "$work/tty.out")"
  [ -e "$work/issue-create.args" ] || fail "yes must create the issue"
  [ "$(cat "$work/issue-append.args")" = "--issue 77" ] || fail "the run must go to the new issue #77"
fi

# 6. init-run: preflight --for init, title without empty segments, number and URL on stdout.
reset
out="$(CI_BENCH_PROVIDER=Contabo CI_BENCH_PLAN="" "$init" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "init-run: expected exit 0, got $rc"
[ "$out" = "#77 https://example.test/issues/77" ] || fail "init-run output: '$out'"
[ "$(cat "$work/preflight.log")" = "--for init" ] || fail "init-run must run preflight --for init"
title="$(sed -n 2p "$work/issue-create.args")"
[ "$title" = "ci-bench: Contabo $(hostname)" ] || fail "title with empty plan: '$title'"
jq -e '.host.hostname != null and .labels.provider == "Contabo" and .labels.plan == ""' "$work/issue-create.json" >/dev/null || fail "create input: $(cat "$work/issue-create.json")"
reset
FAKE_PREFLIGHT_RC=1 "$init" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "init-run with failing preflight: expected exit 1, got $rc"
[ ! -e "$work/issue-create.args" ] || fail "init-run must not create an issue when preflight fails"

[ ! -s "$work/forbidden.log" ] || fail "a benchmark tool was started: $(cat "$work/forbidden.log")"
echo "run-issue: ok"
