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
set -g pane-border-format "#{?pane_active, ❯ #{pane_current_path} , ○ }"
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
# Prefix: C-a | Left: green | Right: Claude → ngrok → [GPU] → CPU → time

set-option -g prefix C-a
bind-key C-a send-prefix

# Left: prefix badge (dark) → green Powerline
set -g status-left "#[fg=#ebdbb2,bg=#504945,bold] #(tmux show-option -gv prefix) #[fg=#504945,bg=#b8bb26]#[fg=#282828,bg=#b8bb26,bold] 󰟀 #(whoami)@#H #[fg=#b8bb26,bg=#282828]"

# Right: with GPU (nvidia-smi present at config load)
#   Claude → ngrok(#83a598) → GPU(#fabd2f) → CPU(#d3869b) → time(#8ec07c)
if-shell 'command -v nvidia-smi >/dev/null 2>&1' {
  set -g status-right "\
#(python3 ~/.tmux/ccstatusline-tmux.py)\
#[fg=#282828,bg=#83a598]#[fg=#282828,bg=#83a598,bold] #(port=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | grep -oP '\"addr\":\"[^\"]*:\\K[0-9]+' | head -1); if [ -n \"\$port\" ]; then echo \"󰛶 :\$port\"; else echo \"󰛵 off\"; fi) \
#[fg=#83a598,bg=#fabd2f]#[fg=#282828,bg=#fabd2f,bold] 󰢮 #(nvidia-smi --query-gpu=name --format=csv,noheader | awk '{print \$3\$4}') #(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits)%% [#(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{printf \"%.1f\", \$1 / 1024}')G/#(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{printf \"%.0f\", \$1 / 1024}')G] \
#[fg=#fabd2f,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold] 󰘚 #(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%%* id.*/\\1/' | awk '{printf \"%.0f\", 100 - \$1}')%% #(free -g | grep Mem | awk '{print \$3 \"G/\" \$2 \"G\"}') \
#[fg=#d3869b,bg=#8ec07c]#[fg=#282828,bg=#8ec07c,bold] 󰥔 %b %d %l:%M%p "
} {
  set -g status-right "\
#(python3 ~/.tmux/ccstatusline-tmux.py)\
#[fg=#282828,bg=#83a598]#[fg=#282828,bg=#83a598,bold] #(port=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | grep -oP '\"addr\":\"[^\"]*:\\K[0-9]+' | head -1); if [ -n \"\$port\" ]; then echo \"󰛶 :\$port\"; else echo \"󰛵 off\"; fi) \
#[fg=#83a598,bg=#d3869b]#[fg=#282828,bg=#d3869b,bold] 󰘚 #(top -bn1 | grep 'Cpu(s)' | sed 's/.*, *\\([0-9.]*\\)%%* id.*/\\1/' | awk '{printf \"%.0f\", 100 - \$1}')%% #(free -g | grep Mem | awk '{print \$3 \"G/\" \$2 \"G\"}') \
#[fg=#d3869b,bg=#8ec07c]#[fg=#282828,bg=#8ec07c,bold] 󰥔 %b %d %l:%M%p "
}
LOCAL

  # --- ccstatusline-tmux.py (tmux status-right segment for Claude usage) ---
  cat >"${tmux_dir}/ccstatusline-tmux.py" <<'CCSTMUX'
#!/usr/bin/env python3
"""Tmux status-right segment for Claude Code rate limits.

Outputs a compact tmux-formatted string with 5-hour and 7-day usage
percentages with mini block bars, colored by threshold. Reuses the same
OAuth credential and file cache as ccstatusline.py.
"""

import json
import os
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

CACHE_FILE = "/tmp/claude-statusline-usage-cache.json"
CACHE_MAX_AGE = 300

# Tmux colors
BG = "#282828"
FG = "#c4956a"
DIM = "#665c54"
GREEN = "#00a000"
YELLOW = "#e6c800"
RED = "#cc241d"

BAR_WIDTH = 5
FILLED = "\u25b0"
EMPTY = "\u25b1"


def threshold_color(pct):
    if pct >= 75:
        return RED
    if pct >= 50:
        return YELLOW
    return GREEN


def mini_bar(pct, color):
    filled = round(pct * BAR_WIDTH / 100)
    empty = BAR_WIDTH - filled
    return (
        f"#[fg={color},bg={BG}]{FILLED * filled}"
        f"#[fg={DIM},bg={BG}]{EMPTY * empty}"
    )


def fetch_usage():
    """Return (usage_data, is_stale) using a file cache to avoid hammering the API."""
    usage_data = None
    is_stale = False
    needs_refresh = True

    if os.path.exists(CACHE_FILE):
        age = time.time() - os.path.getmtime(CACHE_FILE)
        if age < CACHE_MAX_AGE:
            needs_refresh = False
            try:
                with open(CACHE_FILE) as f:
                    usage_data = json.load(f)
            except Exception:
                needs_refresh = True

    if needs_refresh:
        try:
            creds_path = Path.home() / ".claude" / ".credentials.json"
            if creds_path.exists():
                creds = json.loads(creds_path.read_text())
                token = creds.get("claudeAiOauth", {}).get("accessToken", "")
                if token:
                    req = urllib.request.Request(
                        "https://api.anthropic.com/api/oauth/usage",
                        headers={
                            "Accept": "application/json",
                            "Content-Type": "application/json",
                            "Authorization": f"Bearer {token}",
                            "anthropic-beta": "oauth-2025-04-20",
                            "User-Agent": "claude-code/2.1.34",
                        },
                    )
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        usage_data = json.loads(resp.read())
                    with open(CACHE_FILE, "w") as f:
                        json.dump(usage_data, f)
        except Exception:
            is_stale = True
            if os.path.exists(CACHE_FILE):
                try:
                    with open(CACHE_FILE) as f:
                        usage_data = json.load(f)
                except Exception:
                    pass

    return usage_data, is_stale


def fmt_countdown(resets_at):
    """Format time remaining until reset as compact countdown."""
    if not resets_at:
        return "?"
    try:
        expires = datetime.fromisoformat(resets_at)
        remaining = expires - datetime.now(timezone.utc)
        secs = int(remaining.total_seconds())
        if secs <= 0:
            return "0m"
        days, secs = divmod(secs, 86400)
        hours, secs = divmod(secs, 3600)
        mins = secs // 60
        if days > 0:
            return f"{days}d{hours}h"
        if hours > 0:
            return f"{hours}h{mins}m"
        return f"{mins}m"
    except Exception:
        return "?"


def format_window(label, pct):
    color = threshold_color(pct)
    bar = mini_bar(pct, color)
    return f"#[fg={FG},bg={BG}]{label} {bar} #[fg={color},bg={BG}]{pct}%"


def main():
    try:
        usage, is_stale = fetch_usage()
        if not usage:
            print(" --", end="")
            return

        fh = usage.get("five_hour") or {}
        fh_pct = round(float(fh.get("utilization") or 0))
        fh_cd = fmt_countdown(fh.get("resets_at"))

        sd = usage.get("seven_day") or {}
        sd_pct = round(float(sd.get("utilization") or 0))
        sd_cd = fmt_countdown(sd.get("resets_at"))

        sep = f" #[fg={DIM},bg={BG}]│ "
        stale = f" #[fg={RED},bg={BG}][stale]" if is_stale else ""

        output = format_window(fh_cd, fh_pct) + sep + format_window(sd_cd, sd_pct) + stale
        print(f"#[fg={FG},bg={BG}] {output} #[default]", end="")

    except Exception:
        print(" --", end="")


if __name__ == "__main__":
    main()
CCSTMUX

  # --- ccstatusline.py (Claude Code in-terminal statusline) ---
  cat >"${tmux_dir}/ccstatusline.py" <<'CCSTLINE'
#!/usr/bin/env python3

import json
import os
import re
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ANSI colors
E = "\033"
BLACK = f"{E}[38;2;0;0;0m"
BLUE = f"{E}[38;2;0;153;255m"
ORANGE = f"{E}[38;2;255;176;85m"
GREEN = f"{E}[38;2;0;160;0m"
CYAN = f"{E}[38;2;100;200;200m"
RED = f"{E}[38;2;255;85;85m"
YELLOW = f"{E}[38;2;230;200;0m"
WHITE = f"{E}[38;2;220;220;220m"
GRAY = f"{E}[38;2;180;180;180m"
PURPLE = f"{E}[38;2;167;107;206m"
PEACH = f"{E}[38;2;253;202;162m"
PEACH2 = f"{E}[38;2;252;169;133m"
DKPEACH = f"{E}[38;2;189;127;100m"
DKGREEN = f"{E}[38;2;0;120;0m"
MUSTARD = f"{E}[38;2;255;219;88m"
DKYELLOW = f"{E}[38;2;80;80;0m"
DKRED = f"{E}[38;2;180;50;50m"
BG_RED = f"{E}[48;2;150;0;0m"
BG_YELLOW = f"{E}[48;2;225;225;0m"
BG_AZURE = f"{E}[48;2;0;128;255m"
DIM = f"{E}[2m"
RST = f"{E}[0m"
SEP = f" {DIM}|{RST} "

RAINBOW = [
    f"{E}[38;2;255;85;85m",
    f"{E}[38;2;255;176;85m",
    f"{E}[38;2;230;200;0m",
    f"{E}[38;2;0;200;0m",
    f"{E}[38;2;46;149;153m",
    f"{E}[38;2;0;153;255m",
    f"{E}[38;2;180;100;255m",
]

SGT = timezone(timedelta(hours=8))


def rainbow(text):
    return (
        "".join(RAINBOW[i % len(RAINBOW)] + c for i, c in enumerate(text)) + RST
    )


def format_tokens(num):
    if num >= 1_000_000:
        return f"{num / 1_000_000:.1f}m"
    if num >= 1_000:
        return f"{round(num / 1000)}k"
    return str(num)


def build_bar(pct, width=10):
    pct = max(0, min(100, pct))
    filled = round(pct * width / 100)
    empty = width - filled
    if pct >= 75:
        c = RED
    elif pct >= 50:
        c = YELLOW
    else:
        c = GREEN
    fill = "\u25cf" * filled
    empty_dots = "\u25cb" * empty
    return f"{c}{fill}{DIM}{empty_dots}{RST}"


def pad(text, visible_len, col_width):
    gap = col_width - visible_len
    return text + " " * gap if gap > 0 else text


def vlen(s):
    return len(re.sub(r"\033\[[^m]*m", "", s))


def format_reset(iso, style="time"):
    if not iso:
        return ""
    try:
        utc = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        local = utc.astimezone(SGT)
        if style == "time":
            return local.strftime("%-I:%M%p").lower()
        if style == "datetime":
            return local.strftime("%b %-d, %-I:%M%p").lower()
        return local.strftime("%b %-d").lower()
    except Exception:
        return ""


def fetch_usage():
    """Return (usage_data, is_stale) using a file cache to avoid hammering the API."""
    cache_file = "/tmp/claude-statusline-usage-cache.json"
    cache_max_age = 300

    usage_data = None
    is_stale = False
    needs_refresh = True

    if os.path.exists(cache_file):
        age = time.time() - os.path.getmtime(cache_file)
        if age < cache_max_age:
            needs_refresh = False
            try:
                with open(cache_file) as f:
                    usage_data = json.load(f)
            except Exception:
                needs_refresh = True

    if needs_refresh:
        try:
            creds_path = Path.home() / ".claude" / ".credentials.json"
            if creds_path.exists():
                creds = json.loads(creds_path.read_text())
                token = creds.get("claudeAiOauth", {}).get("accessToken", "")
                if token:
                    req = urllib.request.Request(
                        "https://api.anthropic.com/api/oauth/usage",
                        headers={
                            "Accept": "application/json",
                            "Content-Type": "application/json",
                            "Authorization": f"Bearer {token}",
                            "anthropic-beta": "oauth-2025-04-20",
                            "User-Agent": "claude-code/2.1.34",
                        },
                    )
                    with urllib.request.urlopen(req, timeout=5) as resp:
                        usage_data = json.loads(resp.read())
                    with open(cache_file, "w") as f:
                        json.dump(usage_data, f)
        except Exception:
            is_stale = True
            if os.path.exists(cache_file):
                try:
                    with open(cache_file) as f:
                        usage_data = json.load(f)
                except Exception:
                    pass

    return usage_data, is_stale


def main():
    try:
        input_text = sys.stdin.read().strip()
        if not input_text:
            sys.stdout.write("Claude")
            return

        data = json.loads(input_text)

        # --- Model name ---
        model_name = (data.get("model") or {}).get("display_name") or "Claude"

        # --- Token calculations ---
        cw = data.get("context_window") or {}
        size = int(cw.get("context_window_size") or 0) or 200_000
        usage = cw.get("current_usage") or {}
        current = (
            int(usage.get("input_tokens") or 0)
            + int(usage.get("cache_creation_input_tokens") or 0)
            + int(usage.get("cache_read_input_tokens") or 0)
        )
        pct_used = round((current / size) * 100) if size else 0
        pct_remain = 100 - pct_used

        # --- Thinking status & effort level ---
        thinking_on = False
        effort_level = ""
        settings_path = Path.home() / ".claude" / "settings.json"
        if settings_path.exists():
            try:
                settings = json.loads(settings_path.read_text())
                thinking_on = (
                    settings.get("alwaysThinkingEnabled", False) is True
                )
                effort_level = settings.get("effortLevel", "")
            except Exception:
                pass

        # Column widths (shared between all lines)
        bw = 15  # bar width
        c1w = 30  # column 1 visible width
        c2w = 30  # column 2 visible width

        # ===== LINE 1 =====
        thinking_str = (
            rainbow("ultrathink") if thinking_on else f"{DKRED}dumb{RST}"
        )
        ctx_bar = build_bar(pct_used, bw)
        l1_c1_vis = f"context: {'x' * bw} {pct_used}%"
        l1_c1 = f"{WHITE}context:{RST} {ctx_bar} {CYAN}{pct_used}%{RST}"
        l1_c1 = pad(l1_c1, len(l1_c1_vis), c1w)
        l1_left = l1_c1 + SEP + f"{PURPLE}{size - current:,} left{RST}"
        l1_right = f"{BLUE}{model_name}{RST} {thinking_str}"
        model_col = c1w + 3 + 16 + 5  # col1 + sep + max datetime + gap
        gap = model_col - vlen(l1_left)
        line1 = l1_left + " " * max(gap, 1) + l1_right

        # ===== LINES 2 & 3 — usage limits =====
        usage_data, is_stale = fetch_usage()
        stale_str = f" {DKRED}[stale]{RST}" if is_stale and usage_data else ""
        line2 = ""
        line3 = ""

        if usage_data:

            # --- 5-hour (current) ---
            fh = usage_data.get("five_hour") or {}
            fh_pct = round(float(fh.get("utilization") or 0))
            fh_reset = format_reset(fh.get("resets_at"), "time")
            fh_bar = build_bar(fh_pct, bw)

            # --- 5-hour (current) — line 2 ---
            fh_c1_vis = f"current: {'x' * bw} {fh_pct}%"
            fh_c1 = f"{WHITE}current:{RST} {fh_bar} {CYAN}{fh_pct}%{RST}"
            fh_c1 = pad(fh_c1, len(fh_c1_vis), c1w)
            fh_c2 = f"{GRAY}{fh_reset}{RST}"

            # --- 7-day (weekly) — line 3 ---
            sd = usage_data.get("seven_day") or {}
            sd_pct = round(float(sd.get("utilization") or 0))
            sd_reset = format_reset(sd.get("resets_at"), "datetime")
            sd_bar = build_bar(sd_pct, bw)

            sd_c1_vis = f"weekly:  {'x' * bw} {sd_pct}%"
            sd_c1 = f"{WHITE}weekly:{RST}  {sd_bar} {CYAN}{sd_pct}%{RST}"
            sd_c1 = pad(sd_c1, len(sd_c1_vis), c1w)
            sd_c2 = f"{GRAY}{sd_reset}{RST}"

            # --- Extra usage (appended to line 3) ---
            extra_str = ""
            extra = usage_data.get("extra_usage") or {}
            if extra.get("is_enabled"):
                ex_pct = round(float(extra.get("utilization") or 0))
                ex_used = round(float(extra.get("used_credits") or 0) / 100, 2)
                ex_limit = round(
                    float(extra.get("monthly_limit") or 0) / 100, 2
                )
                ex_bar = build_bar(ex_pct, bw)
                extra_str = (
                    SEP
                    + f"{WHITE}extra:{RST} {ex_bar} {CYAN}${ex_used}/${ex_limit}{RST}"
                )

            l2_left = fh_c1 + SEP + fh_c2
            effort_c = {"high": DKGREEN, "medium": DKYELLOW, "low": DKRED}.get(
                effort_level, GRAY
            )
            effort_str = (
                f"{effort_c}{effort_level} effort{RST}" if effort_level else ""
            )
            gap2 = model_col - vlen(l2_left)
            line2 = l2_left + " " * max(gap2, 1) + effort_str
            l3_left = sd_c1 + SEP + sd_c2 + extra_str + stale_str
            line3 = l3_left

        # ===== Last line — current path =====
        cwd = data.get("cwd") or ""

        sys.stdout.write(line1)
        if line2:
            sys.stdout.write(f"\n{line2}")
        if line3:
            sys.stdout.write(f"\n{line3}")
        if cwd:
            sys.stdout.write(f"\n{DKPEACH}{cwd}{RST}")

    except Exception as e:
        sys.stdout.write(f"Claude | Error: {e}")


if __name__ == "__main__":
    main()
CCSTLINE

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
