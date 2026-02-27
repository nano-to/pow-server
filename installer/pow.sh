#!/usr/bin/env bash

set -euo pipefail

REPO_RAW_BASE="https://rpc.nano.to/install"
TMP_DIR="$(mktemp -d)"
TARGET="/usr/local/bin/nano-pow"
WORKER_BINARY=""

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
    with_sudo apt-get install -y curl jq openssh-client autossh
  elif command -v dnf >/dev/null 2>&1; then
    with_sudo dnf install -y curl jq openssh-clients autossh
  elif command -v pacman >/dev/null 2>&1; then
    with_sudo pacman -Sy --noconfirm curl jq openssh autossh
  else
    log "No supported package manager detected; install curl/jq/openssh/autossh manually"
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

download_worker_if_available() {
  local os="$1"
  local arch="$2"
  if [[ "$os" != "mac" || "$arch" != "arm64" ]]; then
    return
  fi

  local worker_dir="$HOME/.local/share/nano-pow"
  local worker_path="$worker_dir/NanoPoW"
  local bundle_tar="$TMP_DIR/m3-nano-pow_NanoPoW.bundle.tar.gz"
  mkdir -p "$worker_dir"
  if curl -fsSL "${REPO_RAW_BASE}/worker/macos-arm64" -o "$worker_path"; then
    chmod +x "$worker_path"
    if curl -fsSL "${REPO_RAW_BASE}/worker/macos-arm64-bundle" -o "$bundle_tar"; then
      tar -xzf "$bundle_tar" -C "$worker_dir"
      log "Downloaded worker resource bundle to $worker_dir"
    else
      log "Worker resource bundle download unavailable; worker may fail to start"
    fi
    WORKER_BINARY="$worker_path"
    export NANO_POW_WORKER_BINARY="$worker_path"
    log "Downloaded worker runtime to $worker_path"
  else
    rm -f "$worker_path"
    log "Worker runtime download unavailable; setup will try local build"
  fi
}

main() {
  local os
  local arch
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
  download_worker_if_available "$os" "$arch"
  ensure_user_path

  if [[ -n "${WORK_API_KEY:-}" && -z "${NANO_POW_API_KEY:-}" ]]; then
    export NANO_POW_API_KEY="$WORK_API_KEY"
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
