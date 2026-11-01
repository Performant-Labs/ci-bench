#!/usr/bin/env bash
# Test helper: make_home <dir> <real lib names...>. Builds a CI_BENCH_HOME whose lib/ holds the
# real common.sh and host.sh, the named real probe libraries, and inert stubs for the other
# probes, so a test of one probe can never start another probe (or Docker).
make_home() {
  local dir="$1" root lib name; shift
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  mkdir -p "$dir/lib"
  cp "$root/lib/common.sh" "$root/lib/host.sh" "$dir/lib/"
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
