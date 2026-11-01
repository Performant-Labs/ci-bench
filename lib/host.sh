#!/usr/bin/env bash
# Host facts and CPU steal. Source lib/common.sh first.

host_hostname() { hostname 2>/dev/null || uname -n; }

host_distro() {
  # shellcheck source=/dev/null
  ( . "${CI_BENCH_OS_RELEASE:-/etc/os-release}" 2>/dev/null && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}" ) || printf 'unknown'
}

host_virtualization() {
  local v=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    v="$(systemd-detect-virt 2>/dev/null || true)"
  fi
  printf '%s' "${v:-unknown}"
}

host_cpu_model() {
  local m=""
  if command -v lscpu >/dev/null 2>&1; then
    m="$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)"
  fi
  if [ -z "$m" ] && [ -r /proc/cpuinfo ]; then
    m="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)"
  fi
  printf '%s' "${m:-unknown}"
}

host_ram_bytes() {
  awk '/^MemTotal:/ { printf "%d", $2 * 1024 }' /proc/meminfo
}

# The whole disk backing /, as a device name such as "sda" or "nvme0n1"; empty if unknown.
host_root_disk() {
  local src disk
  src="$(findmnt -no SOURCE / 2>/dev/null | head -n 1)"
  case "$src" in /dev/*) ;; *) return 0 ;; esac
  disk="$(lsblk -snro NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1; exit }')"
  printf '%s' "$disk"
}

# Prints "<rota> <model>" where rota is 0 or 1 as lsblk reports it, model may be empty.
host_disk_facts() {
  local disk rota model
  disk="$(host_root_disk)"
  [ -n "$disk" ] || return 0
  rota="$(lsblk -dn -o ROTA "/dev/$disk" 2>/dev/null | tr -d ' ' | head -n 1)"
  model="$(lsblk -dn -o MODEL "/dev/$disk" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n 1)"
  printf '%s %s' "$rota" "$model"
}

# Sample the aggregate cpu line of /proc/stat: prints "<total jiffies> <steal jiffies>".
# Total is the sum of user..steal; guest time is already inside user and nice.
host_steal_sample() {
  awk '/^cpu / { total = 0; for (i = 2; i <= 9; i++) total += $i; print total, $9; exit }' "${CI_BENCH_PROC_STAT:-/proc/stat}"
}

# host_steal_percent "<total0> <steal0>" "<total1> <steal1>": percent over the window,
# or "null" when the window is empty or a sample is missing.
host_steal_percent() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, s0, " "); split(b, s1, " ")
    if (s0[1] == "" || s1[1] == "" || s1[1] <= s0[1]) { print "null"; exit }
    printf "%.2f", (s1[2] - s0[2]) * 100 / (s1[1] - s0[1])
  }'
}

# host_json <steal_percent or null>: the schema "host" object.
host_json() {
  local steal="$1" facts rota model rota_json model_json
  facts="$(host_disk_facts)"
  rota="${facts%% *}"; model="${facts#* }"
  [ "$facts" = "$rota" ] && model=""
  case "$rota" in 0) rota_json=false ;; 1) rota_json=true ;; *) rota_json=null ;; esac
  if [ -n "$model" ]; then model_json="$(jq -Rn --arg m "$model" '$m')"; else model_json=null; fi
  jq -n \
    --arg hostname "$(host_hostname)" --arg distro "$(host_distro)" --arg kernel "$(uname -r)" \
    --arg arch "$(uname -m)" --arg virt "$(host_virtualization)" --arg cpu "$(host_cpu_model)" \
    --argjson cores "$(nproc)" --argjson ram "$(host_ram_bytes)" \
    --argjson model "$model_json" --argjson rota "$rota_json" --argjson steal "$steal" \
    '{hostname: $hostname, distro: $distro, kernel: $kernel, arch: $arch, virtualization: $virt,
      cpu_model: $cpu, cores: $cores, ram_bytes: $ram, disk_model: $model, disk_rotational: $rota,
      cpu_steal_percent: $steal}'
}

labels_json() {
  jq -n --arg provider "${CI_BENCH_PROVIDER:-}" --arg plan "${CI_BENCH_PLAN:-}" '{provider: $provider, plan: $plan}'
}
