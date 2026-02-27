#!/usr/bin/env bash

set -euo pipefail

REPO_RAW_BASE="https://rpc.nano.to/install"
TMP_DIR="$(mktemp -d)"
TARGET="/usr/local/bin/nano-pow"
WORKER_BINARY=""

script_dir() {
  local script_path
  script_path="${BASH_SOURCE[0]}"
  cd -- "$(dirname -- "$script_path")" >/dev/null 2>&1 && pwd -P
}

can_use_sudo() {
  command -v sudo >/dev/null 2>&1 && [[ -t 0 ]]
}

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() { printf "[nano-pow] %s\n" "$*"; }

with_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif can_use_sudo; then
    sudo "$@"
  else
    return 1
  fi
}

resolve_target_path() {
  if [[ -w "/usr/local/bin" ]]; then
    TARGET="/usr/local/bin/nano-pow"
    return
  fi

  if can_use_sudo; then
    TARGET="/usr/local/bin/nano-pow"
    return
  fi

  mkdir -p "$HOME/.local/bin"
  TARGET="$HOME/.local/bin/nano-pow"
}

ensure_user_path() {
  if [[ "$TARGET" != "$HOME/.local/bin/nano-pow" ]]; then
    return
  fi

  export PATH="$HOME/.local/bin:$PATH"

  case ":$PATH:" in
    *":$HOME/.local/bin:"*)
      # continue: we still want to persist PATH in shell rc files.
      ;;
  esac

  local shell_name rc_file
  shell_name="$(basename "${SHELL:-}")"

  case "$shell_name" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash) rc_file="$HOME/.bashrc" ;;
    *)
      if [[ -f "$HOME/.zshrc" ]]; then
        rc_file="$HOME/.zshrc"
      elif [[ -f "$HOME/.bashrc" ]]; then
        rc_file="$HOME/.bashrc"
      else
        rc_file="$HOME/.profile"
      fi
      ;;
  esac

  if [[ ! -f "$rc_file" ]] || ! grep -q 'nano-pow PATH' "$rc_file"; then
    {
      printf "\n# nano-pow PATH\n"
      printf "export PATH=\"$HOME/.local/bin:$PATH\"\n"
    } >> "$rc_file"
    log "Added $HOME/.local/bin to PATH in $rc_file"
  fi

  if [[ "$rc_file" != "$HOME/.zshrc" ]] && [[ -f "$HOME/.zshrc" ]] && ! grep -q 'nano-pow PATH' "$HOME/.zshrc"; then
    {
      printf "\n# nano-pow PATH\n"
      printf "export PATH=\"$HOME/.local/bin:$PATH\"\n"
    } >> "$HOME/.zshrc"
    log "Also added PATH to $HOME/.zshrc"
  fi

  log "Run: source $rc_file"
}

detect_os() {
  case "$(uname -s)" in
    Darwin) printf "mac" ;;
    Linux) printf "linux" ;;
    MINGW*|MSYS*|CYGWIN*) printf "windows" ;;
    *) printf "unknown" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf "arm64" ;;
    x86_64|amd64) printf "amd64" ;;
    *) printf "unknown" ;;
  esac
}

install_deps_linux() {
  if command -v apt-get >/dev/null 2>&1; then
    with_sudo apt-get update
    with_sudo apt-get install -y curl jq openssh-client autossh git
  elif command -v dnf >/dev/null 2>&1; then
    with_sudo dnf install -y curl jq openssh-clients autossh git
  elif command -v pacman >/dev/null 2>&1; then
    with_sudo pacman -Sy --noconfirm curl jq openssh autossh git
  else
    log "No supported package manager detected; install curl/jq/openssh/autossh/git manually"
  fi
}

install_deps_mac() {
  if ! command -v brew >/dev/null 2>&1; then
    log "Homebrew is required for dependency install: https://brew.sh"
    exit 1
  fi
  brew install jq autossh
}

download_cli() {
  local cli_path="$TMP_DIR/nano-pow"
  curl -fsSL "${REPO_RAW_BASE}/nano-pow" -o "$cli_path"
  chmod +x "$cli_path"
  if ! with_sudo install -m 0755 "$cli_path" "$TARGET"; then
    install -m 0755 "$cli_path" "$TARGET"
  fi
}

prepare_worker_source() {
  local source_base="$HOME/.local/share/nano-pow/source"
  local source_root="$source_base/nano-work-server"
  local work_repo_url="${NANO_POW_WORK_REPO_URL:-https://github.com/nanocurrency/nano-work-server.git}"
  local bundled_source="${NANO_POW_BUNDLED_WORK_SOURCE_DIR:-}"

  if [[ -z "$bundled_source" ]]; then
    local candidate
    candidate="$(script_dir)/../nano-work-server"
    if [[ -f "$candidate/Cargo.toml" ]]; then
      bundled_source="$candidate"
    fi
  fi

  if command -v nano-work-server >/dev/null 2>&1; then
    export NANO_POW_WORKER_BINARY="$(command -v nano-work-server)"
    log "Using existing system worker binary: $NANO_POW_WORKER_BINARY"
    return 0
  fi

  if [[ -f "$source_root/Cargo.toml" ]]; then
    export NANO_POW_SOURCE_DIR="$source_root"
    log "Using existing worker source tree: $source_root"
    return 0
  fi

  mkdir -p "$source_base"

  if [[ -n "$bundled_source" && -f "$bundled_source/Cargo.toml" ]]; then
    rm -rf "$source_root"
    mkdir -p "$source_root"
    cp -R "$bundled_source/." "$source_root/"
    rm -rf "$source_root/.git"
    log "Copied bundled worker source from $bundled_source"
  elif [[ -d "$source_root/.git" ]]; then
    log "Updating worker source from $work_repo_url"
    if ! GIT_TERMINAL_PROMPT=0 git -C "$source_root" pull --ff-only; then
      log "Failed to update worker source from $work_repo_url"
      return 1
    fi
  else
    rm -rf "$source_root"
    log "Cloning worker source from $work_repo_url"
    if ! GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$work_repo_url" "$source_root"; then
      log "Failed to clone worker source from $work_repo_url"
      return 1
    fi
  fi

  export NANO_POW_SOURCE_DIR="$source_root"
  log "Prepared worker source at $NANO_POW_SOURCE_DIR"
}

main() {
  local os
  local arch
  local resolved_api_key
  os="$(detect_os)"
  arch="$(detect_arch)"
  log "Detected OS: ${os}"

  case "$os" in
    linux) install_deps_linux ;;
    mac) install_deps_mac ;;
    windows) log "Run installer in WSL2 for best support" ;;
    *) log "Unsupported OS"; exit 1 ;;
  esac

  resolve_target_path

  log "Installing nano-pow CLI to $TARGET"
  download_cli
  prepare_worker_source
  ensure_user_path

  resolved_api_key="${NANO_POW_API_KEY:-${WORK_API_KEY:-${API_KEY:-}}}"
  if [[ -n "$resolved_api_key" ]]; then
    export NANO_POW_API_KEY="$resolved_api_key"
  fi

  log "Starting one-click provisioning"
  if [[ -n "${NANO_POW_API_KEY:-}" ]]; then
    "$TARGET" one-click --api-key "$NANO_POW_API_KEY"
  else
    "$TARGET" one-click
  fi

  if [[ "$TARGET" == "$HOME/.local/bin/nano-pow" ]]; then
    log "Installed to $TARGET"
  fi
}

main "$@"
