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
  cat >"$SPINUP_ALIASES_FILE" <<'ALIASES'
# spinup shell aliases — managed by bootstrap.sh
alias lzd="lazydocker"
alias lzg="lazygit"

alias c="clear"
command -v fdfind &>/dev/null && alias fd="fdfind"

declare -A docker_cmds=(
    ["d"]="docker"
    ["dc"]="docker compose"
)

for prefix in "${!docker_cmds[@]}"; do
    cmd="${docker_cmds[$prefix]}"
    alias "$prefix=$cmd"

    eval "
    ${prefix}E() { $cmd exec -it \"\$@\"; }
    ${prefix}P() { $cmd ps -a \"\$@\"; }
    ${prefix}L() { $cmd logs -f \"\$@\"; }
    "
done
ALIASES

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

  # --- .tmux.conf ---
  cat >"${home}/.tmux.conf" <<'TMUXCONF'
# spinup tmux config — managed by bootstrap.sh
set -g default-terminal "tmux-256color"
set -sg escape-time 10
set -g mouse on
set -g pane-border-status off
set -g pane-border-format "#{?pane_active,#[fg=#fe8019] ❯ ,#[fg=colour240] ❯ }#(echo #{pane_current_path} | sed \"s|$HOME|~|\")"
set-hook -g window-layout-changed 'if-shell -F "#{>:#{window_panes},1}" "set pane-border-status top" "set pane-border-status off"'
set -g pane-active-border-style "fg=#fe8019"
set -g pane-border-style "fg=colour240"

bind v split-window -h -c "#{pane_current_path}"
bind s split-window -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

# vim-like pane switch with repeat
bind k select-pane -U
bind j select-pane -D
bind h select-pane -L
bind l select-pane -R
bind / copy-mode \; command-prompt -T search -p "(search down)" "send-keys -X search-forward '%%'"
bind ? copy-mode \; command-prompt -T search -p "(search up)" "send-keys -X search-backward '%%'"
bind r source-file ~/.tmux.conf \; display-message "  Tmux config reloaded"
bind i display-message "   System Uptime: #(uptime | cut -d',' -f1)"

set-window-option -g visual-bell on
set-window-option -g bell-action other

# ─── GRUVBOX DARK POWERLINE THEME ───────────────────────────────────────

# Status bar base
set -g status-style "bg=#282828,fg=#ebdbb2"
set -g status-left-length 100
set -g status-right-length 150

# Window status
set -g window-status-separator ""
set -g window-status-format "#[fg=#83a598,bg=#282828] #I:#W "
set -g window-status-current-format "#[fg=#282828,bg=#fe8019,bold] #I:#W #[fg=#fe8019,bg=#282828]"

# ─── PREFIX + STATUSLINE: auto-detect environment ─────────────────────
unbind-key C-b
unbind-key C-p
if-shell 'test -f /.dockerenv || test -f /run/.containerenv' \
  'source-file ~/.tmux/statusline-container.conf' \
  'if-shell "test -n \"$SSH_CONNECTION\"" \
    "source-file ~/.tmux/statusline-remote.conf" \
    "source-file ~/.tmux/statusline-local.conf"'
TMUXCONF

  # --- statusline-container.conf ---
  cat >"${tmux_dir}/statusline-container.conf" <<'CONTAINER'
# ─── CONTAINER PROFILE ─────────────────────────────────────────────────
# Prefix: C-f | Left: magenta | Right: [GPU] → CPU → time

set-option -g prefix C-f
bind-key C-f send-prefix

# Left: prefix badge (dark) → magenta Powerline
set -g status-left "#[fg=#ebdbb2,bg=#504945,bold] #(tmux show-option -gv prefix) #[fg=#504945,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold]  CONTAINER: #(whoami)@#H #[fg=#d3869b,bg=#282828]"

# Right: with GPU → CPU → time, or just CPU → time
if-shell 'command -v nvidia-smi >/dev/null 2>&1' {
  set -g status-right "\
#[fg=#282828,bg=#fabd2f]#[fg=#282828,bg=#fabd2f,bold] 󰢮 #(nvidia-smi --query-gpu=name --format=csv,noheader | awk '{print \$3\$4}') #(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)%% [#(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{printf \"%.1f\", \$1 / 1024}')G/#(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{printf \"%.0f\", \$1 / 1024}')G] \
#[fg=#fabd2f,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold] 󰘚 #(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%%* id.*/\\1/' | awk '{printf \"%.0f\", 100 - \$1}')%% #(free -g | grep Mem | awk '{print \$3 \"G/\" \$2 \"G\"}') \
#[fg=#d3869b,bg=#8ec07c]#[fg=#282828,bg=#8ec07c,bold] 󰥔 %b %d %l:%M%p "
} {
  set -g status-right "\
#[fg=#282828,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold] 󰘚 #(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%%* id.*/\\1/' | awk '{printf \"%.0f\", 100 - \$1}')%% #(free -g | grep Mem | awk '{print \$3 \"G/\" \$2 \"G\"}') \
#[fg=#d3869b,bg=#8ec07c]#[fg=#282828,bg=#8ec07c,bold] 󰥔 %b %d %l:%M%p "
}
CONTAINER

  # --- statusline-remote.conf ---
  cat >"${tmux_dir}/statusline-remote.conf" <<'REMOTE'
# ─── REMOTE / SSH PROFILE ─────────────────────────────────────────────
# Prefix: C-s | Left: blue | Right: [GPU] → CPU → time

set-option -g prefix C-s
bind-key C-s send-prefix

# Left: prefix badge (dark) → blue Powerline
set -g status-left "#[fg=#ebdbb2,bg=#504945,bold] #(tmux show-option -gv prefix) #[fg=#504945,bg=#83a598]#[fg=#282828,bg=#83a598,bold] 󰌘 REMOTE: #(whoami)@#H #[fg=#83a598,bg=#282828]"

# Right: with GPU → CPU → time, or just CPU → time
if-shell 'command -v nvidia-smi >/dev/null 2>&1' {
  set -g status-right "\
#[fg=#282828,bg=#fabd2f]#[fg=#282828,bg=#fabd2f,bold] 󰢮 #(nvidia-smi --query-gpu=name --format=csv,noheader | awk '{print \$3\$4}') #(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)%% [#(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{printf \"%.1f\", \$1 / 1024}')G/#(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{printf \"%.0f\", \$1 / 1024}')G] \
#[fg=#fabd2f,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold] 󰘚 #(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%%* id.*/\\1/' | awk '{printf \"%.0f\", 100 - \$1}')%% #(free -g | grep Mem | awk '{print \$3 \"G/\" \$2 \"G\"}') \
#[fg=#d3869b,bg=#8ec07c]#[fg=#282828,bg=#8ec07c,bold] 󰥔 %b %d %l:%M%p "
} {
  set -g status-right "\
#[fg=#282828,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold] 󰘚 #(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%%* id.*/\\1/' | awk '{printf \"%.0f\", 100 - \$1}')%% #(free -g | grep Mem | awk '{print \$3 \"G/\" \$2 \"G\"}') \
#[fg=#d3869b,bg=#8ec07c]#[fg=#282828,bg=#8ec07c,bold] 󰥔 %b %d %l:%M%p "
}
REMOTE

  # --- statusline-local.conf ---
  cat >"${tmux_dir}/statusline-local.conf" <<'LOCAL'
# ─── LOCAL / HOST PROFILE ──────────────────────────────────────────────
# Prefix: C-a | Left: green | Right: [GPU] → CPU → time

set-option -g prefix C-a
bind-key C-a send-prefix

# Left: prefix badge (dark) → green Powerline
set -g status-left "#[fg=#ebdbb2,bg=#504945,bold] #(tmux show-option -gv prefix) #[fg=#504945,bg=#b8bb26]#[fg=#282828,bg=#b8bb26,bold] 󰟀 #(whoami)@#H #[fg=#b8bb26,bg=#282828]"

# Right: with GPU → CPU → time, or just CPU → time
if-shell 'command -v nvidia-smi >/dev/null 2>&1' {
  set -g status-right "\
#[fg=#282828,bg=#fabd2f]#[fg=#282828,bg=#fabd2f,bold] 󰢮 #(nvidia-smi --query-gpu=name --format=csv,noheader | awk '{print \$3\$4}') #(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)%% [#(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{printf \"%.1f\", \$1 / 1024}')G/#(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{printf \"%.0f\", \$1 / 1024}')G] \
#[fg=#fabd2f,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold] 󰘚 #(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%%* id.*/\\1/' | awk '{printf \"%.0f\", 100 - \$1}')%% #(free -g | grep Mem | awk '{print \$3 \"G/\" \$2 \"G\"}') \
#[fg=#d3869b,bg=#8ec07c]#[fg=#282828,bg=#8ec07c,bold] 󰥔 %b %d %l:%M%p "
} {
  set -g status-right "\
#[fg=#282828,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold] 󰘚 #(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%%* id.*/\\1/' | awk '{printf \"%.0f\", 100 - \$1}')%% #(free -g | grep Mem | awk '{print \$3 \"G/\" \$2 \"G\"}') \
#[fg=#d3869b,bg=#8ec07c]#[fg=#282828,bg=#8ec07c,bold] 󰥔 %b %d %l:%M%p "
}
LOCAL

  # --- gpu-segment.sh ---
  cat >"${tmux_dir}/gpu-segment.sh" <<'GPUSEG'
#!/usr/bin/env bash
# GPU info helper for tmux statusline
# Outputs "MODEL UTIL% [USED_G/TOTAL_G]" or nothing if nvidia-smi is unavailable
# Can be used standalone: #(~/.tmux/gpu-segment.sh)

if ! command -v nvidia-smi >/dev/null 2>&1; then
  exit 0
fi

model=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | awk '{print $3$4}')
util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null)
vram_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{printf "%.1f", $1 / 1024}')
vram_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{printf "%.0f", $1 / 1024}')

if [ -z "$model" ]; then
  exit 0
fi

printf "󰢮 %s %s%%%% [%sG/%sG]" "$model" "$util" "$vram_used" "$vram_total"
GPUSEG
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
    # shellcheck source=lib/custom.sh
    source "$(dirname "$0")/lib/custom.sh"
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
