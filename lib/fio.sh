#!/usr/bin/env bash
# Disk probes: the YABS-compatible fio profile and the CI profile. Source lib/common.sh first.

FIO_YABS_BLOCK_SIZES=(4k 64k 512k 1m)
FIO_CI_FILE_BYTES=$((2 * 1024 * 1024 * 1024))
FIO_JOB_DIR=""

# fio_parse <fio --output-format=json on stdin>: {read: {...}, write: {...}}.
# Latencies are null when fio did not record them (gtod_reduce=1 turns them off).
fio_parse() {
  jq -e '
    def dir($d): {
      iops: ($d.iops // 0),
      bw_bytes_per_sec: ($d.bw_bytes // (($d.bw // 0) * 1024)),
      lat_mean_ns: (if ($d.lat_ns.N // 0) > 0 then $d.lat_ns.mean else null end),
      lat_p99_ns: ($d.clat_ns.percentile["99.000000"] // null)
    };
    .jobs[0] as $j | {read: dir($j.read), write: dir($j.write)}' 2>/dev/null \
    || { echo "could not parse fio JSON output" >&2; return 1; }
}

fio_cleanup() {
  if [ -n "$FIO_JOB_DIR" ] && [ -d "$FIO_JOB_DIR" ]; then rm -rf "$FIO_JOB_DIR"; fi
  FIO_JOB_DIR=""
}

# fio_prepare <file bytes>: create a private job directory under CI_BENCH_FIO_DIR on a real
# filesystem with enough free space. Sets FIO_JOB_DIR; message on stderr and return 1 otherwise.
fio_prepare() {
  local need="$1" fstype avail
  mkdir -p "$CI_BENCH_FIO_DIR" 2>/dev/null || { echo "cannot create $CI_BENCH_FIO_DIR" >&2; return 1; }
  fstype="$(df --output=fstype "$CI_BENCH_FIO_DIR" 2>/dev/null | tail -n 1 | tr -d ' ')"
  case "$fstype" in
    tmpfs|ramfs) echo "$CI_BENCH_FIO_DIR is on $fstype, which would measure RAM; set CI_BENCH_FIO_DIR to a real filesystem" >&2; return 1 ;;
  esac
  avail="$(df --output=avail -B1 "$CI_BENCH_FIO_DIR" 2>/dev/null | tail -n 1 | tr -d ' ')"
  [[ "$avail" =~ ^[0-9]+$ ]] || { echo "cannot read free space of $CI_BENCH_FIO_DIR" >&2; return 1; }
  if [ "$avail" -lt "$need" ]; then
    echo "only $((avail / 1048576)) MiB free in $CI_BENCH_FIO_DIR, need $((need / 1048576)) MiB" >&2
    return 1
  fi
  FIO_JOB_DIR="$(mktemp -d "$CI_BENCH_FIO_DIR/job.XXXXXX")" || { echo "cannot create a job directory in $CI_BENCH_FIO_DIR" >&2; return 1; }
}

# fio_exec <name> <fio args...>: run fio in FIO_JOB_DIR on one shared file and print the parsed result.
fio_exec() {
  local name="$1" out; shift
  out="$(fio --name="$name" --filename="$FIO_JOB_DIR/testfile" --output-format=json "$@" 2>&1)" \
    || { echo "fio $name failed: $(tail -n 3 <<<"$out" | tr '\n' ' ')" >&2; return 1; }
  # fio can print warnings before the JSON object; start at the first line that opens it.
  fio_parse < <(sed -n '/^{/,$p' <<<"$out")
}

fio_file_size_arg() {
  if [ "$(uname -m)" = x86_64 ]; then echo 2G; else echo 512M; fi
}

probe_fio_yabs() {
  local bs result size json='{}'
  size="$(fio_file_size_arg)"
  trap fio_cleanup EXIT INT TERM
  fio_prepare "$(ci_fio_file_bytes)" || return 1
  for bs in "${FIO_YABS_BLOCK_SIZES[@]}"; do
    result="$(fio_exec "rand_rw_$bs" --ioengine=libaio --rw=randrw --rwmixread=50 --bs="$bs" \
      --iodepth=64 --numjobs=2 --size="$size" --runtime=30 --gtod_reduce=1 --direct=1 --group_reporting)" \
      || { fio_cleanup; return 1; }
    json="$(jq -c --arg bs "$bs" --argjson r "$result" '. + {($bs): $r}' <<<"$json")"
    rm -f "$FIO_JOB_DIR/testfile"
  done
  fio_cleanup
  printf '%s\n' "$json"
}

probe_fio_ci() {
  local result
  trap fio_cleanup EXIT INT TERM
  fio_prepare "$FIO_CI_FILE_BYTES" || return 1
  result="$(fio_exec ci-io --ioengine=libaio --rw=randrw --rwmixread=70 --bs=16k --iodepth=8 --numjobs=4 \
    --runtime=60 --time_based=1 --group_reporting --direct=1 --size=2G)" \
    || { fio_cleanup; return 1; }
  fio_cleanup
  printf '%s\n' "$result"
}
