#!/usr/bin/env bash
# Test helper: make_home <dir> <real lib names...>. Builds a CI_BENCH_HOME whose lib/ holds the
# real common.sh and host.sh, the named real probe libraries, and inert stubs for the other
# probes, so a test of one probe can never start another probe (or Docker). It also gets a stub
# issue.mjs (no GitHub) and a fake benchmark:preflight in $dir/bin; put that on PATH.
#   FAKE_PREFLIGHT_RC   exit status of the fake preflight (default 0)
#   STUB_DIR            where the fakes log: preflight.log, issue-create.args, issue-append.json
make_home() {
  local dir="$1" root lib name; shift
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mkdir -p "$dir/lib"
  cp "$root/lib/common.sh" "$root/lib/host.sh" "$dir/lib/"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/benchmark:preflight" <<'PF'
#!/usr/bin/env bash
echo "$*" >>"${STUB_DIR:?}/preflight.log"
exit "${FAKE_PREFLIGHT_RC:-0}"
PF
  chmod +x "$dir/bin/benchmark:preflight"
  cat >"$dir/lib/issue.mjs" <<'STUB'
import { writeFileSync, readFileSync } from "node:fs";
const dir = process.env.STUB_DIR;
const [, , cmd, ...args] = process.argv;
const stdin = readFileSync(0, "utf8");
if (cmd === "create") {
  writeFileSync(`${dir}/issue-create.args`, args.join("\n") + "\n");
  writeFileSync(`${dir}/issue-create.json`, stdin);
  console.log(JSON.stringify({ number: 77, url: "https://example.test/issues/77" }));
} else if (cmd === "append") {
  writeFileSync(`${dir}/issue-append.args`, args.join(" ") + "\n");
  writeFileSync(`${dir}/issue-append.json`, stdin);
} else process.exit(2);
STUB
  for lib in cpu fio compile docker; do
    if [[ " $* " == *" $lib "* ]]; then
      cp "$root/lib/$lib.sh" "$dir/lib/$lib.sh"
    else
      case "$lib" in fio) name="probe_fio_yabs probe_fio_ci" ;; *) name="probe_$lib" ;; esac
      : >"$dir/lib/$lib.sh"
      for fn in $name; do printf '%s() { echo "{}"; }\n' "$fn" >>"$dir/lib/$lib.sh"; done
    fi
  done
}
