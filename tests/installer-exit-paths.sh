#!/usr/bin/env bash
# install.sh must exit before touching anything when sudo is missing, sudo fails, or the OS is not Debian/Ubuntu.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/nosudo-bin" "$work/fake-bin"
for t in bash env dirname mktemp rm cat; do ln -s "$(command -v $t)" "$work/nosudo-bin/$t"; done

# 1. No sudo on PATH: exit 1, one line, nothing else.
out="$work/o1"; rc=0
PATH="$work/nosudo-bin" bash "$root/install.sh" >"$out" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "missing sudo: expected exit 1, got $rc"
[ "$(wc -l <"$out")" -eq 1 ] || fail "missing sudo: expected one line of output"

# Fake sudo that logs every call.
cat >"$work/fake-bin/sudo" <<SUDO
#!/usr/bin/env bash
echo "\$*" >>"$work/sudo.log"
[ "\${FAKE_SUDO_FAIL:-0}" = 1 ] && exit 1
[ "\$1" = "-n" ] && [ "\$2" = "true" ] && exit 1   # needs a password
[ "\$1" = "-v" ] && exit 0
echo "unexpected sudo call: \$*" >>"$work/violations.log"; exit 99
SUDO
chmod +x "$work/fake-bin/sudo"

# 2. sudo -v fails: exit 1 and nothing but the one sudo -v call.
rc=0; : >"$work/sudo.log"
FAKE_SUDO_FAIL=1 PATH="$work/fake-bin:$PATH" bash "$root/install.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "sudo failure: expected exit 1, got $rc"
[ "$(cat "$work/sudo.log")" = "$(printf -- '-n true\n-v')" ] || fail "sudo failure: sudo was used for more than the credential check"

# 3. Non-Debian distro: exit 1 with the v1 message, no sudo call besides -v.
printf 'ID=fedora\nID_LIKE="rhel"\n' >"$work/os-fedora"
rc=0; : >"$work/sudo.log"
CI_BENCH_OS_RELEASE="$work/os-fedora" PATH="$work/fake-bin:$PATH" bash "$root/install.sh" >"$work/o3" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "fedora: expected exit 1, got $rc"
grep -q 'v1 supports Debian and Ubuntu only' "$work/o3" || fail "fedora: missing v1 message"
[ "$(cat "$work/sudo.log")" = "$(printf -- '-n true\n-v')" ] || fail "fedora: sudo used before the OS check"
[ ! -e "$work/violations.log" ] || fail "fedora: unexpected sudo calls"
echo "installer exit paths: ok"
