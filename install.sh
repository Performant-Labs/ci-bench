#!/usr/bin/env bash
# ci-bench installer. Debian and Ubuntu only.
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Performant-Labs/ci-bench/main/install.sh)"
#
# Environment overrides (for testing and forks):
#   CI_BENCH_SRC   local checkout to install from instead of downloading
#   CI_BENCH_OS_RELEASE  os-release file to read (tests only)

# The first action is sudo. Nothing runs before this line: no OS probe, no download, no disk.
# Passwordless sudo is accepted as is: sudo-rs refuses `sudo -v` without a terminal even then.
if ! command -v sudo >/dev/null 2>&1 || ! { sudo -n true 2>/dev/null || sudo -v; }; then
  echo "ci-bench: sudo is required and must succeed; run this as a user with sudo." >&2
  exit 1
fi

set -euo pipefail

BIN_DIR=/usr/local/bin
LIB_DIR=/usr/local/lib/ci-bench
NODE_MIN_MAJOR=18
OS_RELEASE="${CI_BENCH_OS_RELEASE:-/etc/os-release}"
RAW_BASE="https://raw.githubusercontent.com/Performant-Labs/ci-bench/main"

log() { printf 'ci-bench: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

# Keep the sudo credential alive for the rest of the install.
(
  while sleep 50; do
    kill -0 "$$" 2>/dev/null || exit 0
    sudo -n true 2>/dev/null || exit 0
  done
) &
REFRESH_PID=$!
TMP_DIR="$(mktemp -d)"
cleanup() {
  kill "$REFRESH_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Debian and Ubuntu only. Derivatives that declare it in ID_LIKE count.
detect_os() {
  [ -r "$OS_RELEASE" ] || die "v1 supports Debian and Ubuntu only (no $OS_RELEASE)."
  local id id_like
  # shellcheck source=/dev/null
  id="$(. "$OS_RELEASE" && printf '%s' "${ID:-}")"
  # shellcheck source=/dev/null
  id_like="$(. "$OS_RELEASE" && printf '%s' "${ID_LIKE:-}")"
  case " $id $id_like " in
    *" debian "*|*" ubuntu "*) ;;
    *) die "v1 supports Debian and Ubuntu only (found: ${id:-unknown})." ;;
  esac
}

apt_install() {
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

fetch() { # fetch <relative path> <dest>
  if [ -n "${CI_BENCH_SRC:-}" ]; then
    cp "${CI_BENCH_SRC}/$1" "$2"
  else
    curl -fsSL "${RAW_BASE}/$1" -o "$2"
  fi
}

install_files() {
  local stage="$TMP_DIR/stage" kind path
  mkdir -p "$stage"
  fetch manifest.txt "$stage/manifest.txt"
  sudo -n install -d -m 0755 "$BIN_DIR" "$LIB_DIR"
  while read -r kind path; do
    case "$kind" in ''|'#'*) continue ;; esac
    mkdir -p "$stage/$(dirname "$path")"
    fetch "$path" "$stage/$path"
    case "$kind" in
      bin) sudo -n install -m 0755 "$stage/$path" "$BIN_DIR/$(basename "$path")" ;;
      lib)
        sudo -n install -d -m 0755 "$LIB_DIR/$(dirname "$path")"
        sudo -n install -m 0644 "$stage/$path" "$LIB_DIR/$path" ;;
      *) die "bad manifest entry: $kind $path" ;;
    esac
  done < "$stage/manifest.txt"
}

install_gh() {
  if command -v gh >/dev/null 2>&1; then return 0; fi
  log "installing the GitHub CLI"
  sudo -n install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo -n tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo -n chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" | sudo -n tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo -n apt-get update -qq
  apt_install gh
}

node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

install_node() {
  if ! command -v node >/dev/null 2>&1; then
    log "installing nodejs and npm"
    apt_install nodejs npm
  fi
  command -v npm >/dev/null 2>&1 || apt_install npm
  local major
  major="$(node_major)"
  [ "$major" -ge "$NODE_MIN_MAJOR" ] \
    || die "node $(node -v) is too old; ci-bench needs Node ${NODE_MIN_MAJOR}+ (this distro's nodejs package is older)."
}

install_octokit() {
  local want have
  want="$(node -p 'require("'"$LIB_DIR"'/package.json").dependencies["@octokit/rest"]')"
  have="$(node -p 'require("'"$LIB_DIR"'/node_modules/@octokit/rest/package.json").version' 2>/dev/null || true)"
  if [ "$have" = "$want" ]; then
    log "@octokit/rest $want already installed"
    return 0
  fi
  log "installing @octokit/rest $want"
  sudo -n npm install --omit=dev --no-audit --no-fund --no-progress --prefix "$LIB_DIR" >/dev/null
}

main() {
  detect_os
  sudo -n apt-get update -qq
  apt_install ca-certificates curl
  install_gh
  install_node
  install_files
  install_octokit
  log "done. Next: gh auth login, then benchmark:preflight"
}

main "$@"

unused_var=$(echo $HOME)
