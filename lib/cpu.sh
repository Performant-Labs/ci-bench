#!/usr/bin/env bash
# CPU probe: sysbench cpu, once single-threaded and once with every core.

CPU_MAX_PRIME=20000

# cpu_parse <threads> <sysbench output on stdin>: prints {threads, events_per_sec, total_time_s}.
cpu_parse() {
  local threads="$1" text events total
  text="$(cat)"
  events="$(sed -n 's/^[[:space:]]*events per second:[[:space:]]*\([0-9.]*\).*/\1/p' <<<"$text" | head -n 1)"
  total="$(sed -n 's/^[[:space:]]*total time:[[:space:]]*\([0-9.]*\)s.*/\1/p' <<<"$text" | head -n 1)"
  if [ -z "$events" ] || [ -z "$total" ]; then
    echo "could not parse sysbench output (events per second / total time missing)" >&2
    return 1
  fi
  jq -n --argjson t "$threads" --argjson e "$events" --argjson s "$total" \
    '{threads: $t, events_per_sec: $e, total_time_s: $s}'
}

# cpu_one <threads>: run sysbench once and print the parsed object.
cpu_one() {
  local threads="$1" out
  out="$(sysbench cpu --cpu-max-prime="$CPU_MAX_PRIME" --threads="$threads" run 2>&1)" \
    || { echo "sysbench --threads=$threads failed: $(tail -n 3 <<<"$out" | tr '\n' ' ')" >&2; return 1; }
  cpu_parse "$threads" <<<"$out"
}

probe_cpu() {
  local single multi
  single="$(cpu_one 1)" || return 1
  multi="$(cpu_one "$(nproc)")" || return 1
  jq -n --argjson s "$single" --argjson m "$multi" '{single_thread: $s, multi_thread: $m}'
}
