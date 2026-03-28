#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SPINUP_ALIASES_FILE="$HOME/.spinup_aliases"
INSTALL_DIR="/usr/local/bin"
SPINUP_LOG="/tmp/spinup.log"
VIEWPORT_HEIGHT=10

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
DIM='\033[2m'
BOLD='\033[1m'
YELLOW='\033[0;33m'
NC='\033[0m'

TOOLS_BASE=(docker lazydocker aliases tmux)
TOOLS_DEV=(fd ripgrep lazygit)

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_arch() {
  case "$(uname -m)" in
  x86_64) echo "x86_64" ;;
  aarch64) echo "arm64" ;;
  armv7l) echo "armv7" ;;
  *)
    printf '  %b[FAIL]%b Unsupported architecture: %s\n' "$RED" "$NC" "$(uname -m)" >&2
    exit 1
    ;;
  esac
}

get_real_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    echo "$SUDO_USER"
  else
    whoami
  fi
}

show_usage() {
  cat >&2 <<'EOF'
Usage: bootstrap.sh [--dev | --custom]

Tiers:
  (default)       Docker, Docker Compose, lazydocker, shell aliases, tmux config
  --dev           Everything in base + fd, ripgrep, lazygit
  --custom        Base + user-defined tools from ~/.config/spinup/spinup.yaml

Examples:
  curl -sSL .../bootstrap.sh | bash
  curl -sSL .../bootstrap.sh | bash -s -- --dev
EOF
}

# ---------------------------------------------------------------------------
# Viewport — shows last N lines of output in-place, clears when done
# ---------------------------------------------------------------------------
viewport() {
  local max=$VIEWPORT_HEIGHT
  local -a buf=()
  local shown=0
  local width
  width=$(tput cols 2>/dev/null || echo 80)
  local max_text=$((width - 5))

  while IFS= read -r line; do
    echo "$line" >>"$SPINUP_LOG"

    # Truncate long lines
    if ((${#line} > max_text)); then
      line="${line:0:$max_text}"
    fi

    # Erase previous viewport
    for ((i = 0; i < shown; i++)); do
      printf '\033[A\033[2K' >&2
    done

    # Update ring buffer
    buf+=("$line")
    if ((${#buf[@]} > max)); then
      buf=("${buf[@]:1}")
    fi

    # Redraw viewport
    shown=${#buf[@]}
    for ((i = 0; i < shown; i++)); do
      local sym="├"
      ((i == shown - 1)) && sym="└"
      printf '  %b%s %s%b\n' "$DIM" "$sym" "${buf[$i]}" "$NC" >&2
    done
  done

}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
is_installed() {
  case "$1" in
  docker) has_cmd docker ;;
  lazydocker) has_cmd lazydocker ;;
  aliases) [[ -f "$SPINUP_ALIASES_FILE" ]] ;;
  tmux) [[ -f "$HOME/.tmux.conf" ]] && grep -q "spinup" "$HOME/.tmux.conf" 2>/dev/null ;;
  fd) has_cmd fdfind || has_cmd fd ;;
  ripgrep) has_cmd rg ;;
  lazygit) has_cmd lazygit ;;
  esac
}

action_word() {
  case "$1" in
  aliases | tmux) echo "configure" ;;
  *) echo "install" ;;
  esac
}

action_ing() {
  case "$1" in
  aliases | tmux) echo "Configuring" ;;
  *) echo "Installing" ;;
  esac
}

action_past() {
  case "$1" in
  aliases | tmux) echo "configured" ;;
  *) echo "installed" ;;
  esac
}

# ---------------------------------------------------------------------------
# Generic GitHub release installer
# ---------------------------------------------------------------------------
install_github_release() {
  local repo="$1"
  local bin_name="$2"
  local os_name="$3"
  local arch="$4"

  echo "Fetching latest version..."
  local version
  version=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" |
    grep -Po '"tag_name":\s*"v?\K[^"]*')

  local tarball="${bin_name}_${version}_${os_name}_${arch}.tar.gz"
  local url="https://github.com/${repo}/releases/download/v${version}/${tarball}"

  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  echo "Downloading ${bin_name} v${version}..."
  curl -fsSL "$url" -o "${tmpdir}/${tarball}"
  echo "Extracting..."
  tar xzf "${tmpdir}/${tarball}" -C "$tmpdir"
  sudo install -m 0755 "${tmpdir}/${bin_name}" "${INSTALL_DIR}/${bin_name}"
}

# ---------------------------------------------------------------------------
# Tool installers
# ---------------------------------------------------------------------------
install_docker() {
  sudo apt-get update
  sudo apt-get install --no-install-recommends -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install --no-install-recommends -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

install_lazydocker() {
  install_github_release "jesseduffield/lazydocker" "lazydocker" "Linux" "$(detect_arch)"
}

install_fd() {
  sudo apt-get install --no-install-recommends -y fd-find
}

install_rg() {
  sudo apt-get install --no-install-recommends -y ripgrep
}

install_lazygit() {
  install_github_release "jesseduffield/lazygit" "lazygit" "linux" "$(detect_arch)"
}

setup_aliases() {
  # __INJECT_HEREDOC:assets/spinup_aliases:ALIASES:$SPINUP_ALIASES_FILE__

  local bashrc="$HOME/.bashrc"
  local source_line='[ -f ~/.spinup_aliases ] && source ~/.spinup_aliases'
  if ! grep -qF ".spinup_aliases" "$bashrc" 2>/dev/null; then
    printf '\n# spinup aliases\n%s\n' "$source_line" >>"$bashrc"
  fi
}

setup_tmux() {
  local home
  home=$(eval echo "~$(get_real_user)")
  local tmux_dir="${home}/.tmux"
  mkdir -p "$tmux_dir"

  # __INJECT_HEREDOC:assets/tmux/tmux.conf:TMUXCONF:${home}/.tmux.conf__
  # __INJECT_HEREDOC:assets/tmux/statusline-container.conf:CONTAINER:${tmux_dir}/statusline-container.conf__
  # __INJECT_HEREDOC:assets/tmux/statusline-remote.conf:REMOTE:${tmux_dir}/statusline-remote.conf__
  # __INJECT_HEREDOC:assets/tmux/statusline-local.conf:LOCAL:${tmux_dir}/statusline-local.conf__
  # __INJECT_HEREDOC:assets/tmux/ccstatusline-tmux.py:CCSTMUX:${tmux_dir}/ccstatusline-tmux.py__
  # __INJECT_HEREDOC:assets/tmux/ccstatusline.py:CCSTLINE:${tmux_dir}/ccstatusline.py__
  # __INJECT_HEREDOC:assets/tmux/gpu-segment.sh:GPUSEG:${tmux_dir}/gpu-segment.sh__
  chmod +x "${tmux_dir}/gpu-segment.sh"

  echo "Wrote ~/.tmux.conf and ~/.tmux/ statusline configs"
}

run_install() {
  case "$1" in
  docker) install_docker ;;
  lazydocker) install_lazydocker ;;
  aliases) setup_aliases ;;
  tmux) setup_tmux ;;
  fd) install_fd ;;
  ripgrep) install_rg ;;
  lazygit) install_lazygit ;;
  esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  TIER="base"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dev)
      TIER="dev"
      shift
      ;;
    --custom)
      TIER="custom"
      shift
      ;;
    -h | --help)
      show_usage
      exit 0
      ;;
    *)
      printf '  %b[FAIL]%b Unknown argument: %s\n' "$RED" "$NC" "$1" >&2
      show_usage
      exit 1
      ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Summary — printed on failure so the user can see what succeeded
# ---------------------------------------------------------------------------
print_summary() {
  printf '\n  %b── Summary ─────────────────────%b\n' "$BOLD" "$NC" >&2
  for entry in "$@"; do
    local status="${entry%%:*}"
    local tool="${entry#*:}"
    if [[ "$status" == "OK" ]]; then
      printf '    %-14s %b✓ OK%b\n' "$tool" "$GREEN" "$NC" >&2
    else
      printf '    %-14s %b✗ FAIL%b  ← see %s\n' "$tool" "$RED" "$NC" "$SPINUP_LOG" >&2
    fi
  done
  printf '\n' >&2
}

# ---------------------------------------------------------------------------
# Custom tier — injected from lib/custom.sh at assembly time
# ---------------------------------------------------------------------------
# __INJECT_SOURCE:lib/custom.sh__

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  : >"$SPINUP_LOG" # truncate log

  local tools=("${TOOLS_BASE[@]}")
  if [[ "$TIER" == "dev" ]]; then
    tools+=("${TOOLS_DEV[@]}")
  fi

  # --- Pre-flight scan ---
  local -a pending=()
  printf '\n%bspinup%b bootstrap — tier: %s\n\n' "$BOLD" "$NC" "$TIER" >&2
  for tool in "${tools[@]}"; do
    if is_installed "$tool"; then
      printf '  %-14s %b✓ installed%b\n' "$tool" "$GREEN" "$NC" >&2
    else
      local action
      action=$(action_word "$tool")
      printf '  %-14s → %s\n' "$tool" "$action" >&2
      pending+=("$tool")
    fi
  done

  # Early exit if nothing to do
  if [[ ${#pending[@]} -eq 0 ]]; then
    printf '%b✓%b Everything already installed!\n' "$GREEN" "$NC" >&2
    ensure_docker_group
    return 0
  fi

  # --- Install pending tools ---
  local total=${#pending[@]}
  local step=0
  local -a results=()
  for tool in "${pending[@]}"; do
    ((++step))
    local action
    action=$(action_word "$tool")
    local action_label
    action_label=$(action_ing "$tool")
    printf '\n%b[%d/%d]%b %s %s...\n' "$BLUE" "$step" "$total" "$NC" "$action_label" "$tool" >&2

    set +e
    (
      set -e
      run_install "$tool"
    ) 2>&1 | viewport
    local rc=${PIPESTATUS[0]}
    set -e

    if ((rc == 0)); then
      local past
      past=$(action_past "$tool")
      printf '  %b[ OK ]%b %s %s\n' "$GREEN" "$NC" "$tool" "$past" >&2
      results+=("OK:$tool")
    else
      results+=("FAIL:$tool")
      print_summary "${results[@]}"
      exit "$rc"
    fi
  done

  # --- Custom tier ---
  if [[ "$TIER" == "custom" ]]; then
    run_custom
  fi

  ensure_docker_group

  printf '\n%b✓%b spinup bootstrap complete!\n\n' "$GREEN" "$NC" >&2

  local cmd="newgrp docker"
  local msg="Run ${cmd} or re-login for docker group + aliases to take effect."
  local inner_width=$(( ${#msg} + 2 ))
  local border
  border=$(printf '─%.0s' $(seq 1 "$inner_width"))

  printf '  ┌%s┐\n' "$border" >&2
  printf '  │ Run %b%s%b or re-login for docker group + aliases to take effect. │\n' "$BOLD$YELLOW" "$cmd" "$NC" >&2
  printf '  └%s┘\n' "$border" >&2
}

ensure_docker_group() {
  if has_cmd docker; then
    local real_user
    real_user=$(get_real_user)
    sudo groupadd -f docker
    sudo usermod -aG docker "$real_user"
  fi
}

main "$@"
