#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Custom tier — parses ~/.config/spinup/spinup.yaml and installs user-defined
# packages, GitHub releases, aliases, and post-install scripts.
#
# Sourced by bootstrap.sh when --custom is passed. Expects bootstrap.sh
# functions to be available: has_cmd, install_github_release, detect_arch,
# viewport, color constants.
# ---------------------------------------------------------------------------

SPINUP_CONFIG="${SPINUP_CONFIG:-$HOME/.config/spinup/spinup.yaml}"

# ---------------------------------------------------------------------------
# yq — installed on demand, only for --custom
# ---------------------------------------------------------------------------
install_yq() {
  install_github_release "mikefarah/yq" "yq" "linux" "$(detect_arch)"
}

ensure_yq() {
  if has_cmd yq; then
    return 0
  fi

  printf '\n%b[yq]%b Installing YAML parser...\n' "$BLUE" "$NC" >&2
  set +e
  (
    set -e
    install_yq
  ) 2>&1 | viewport
  local rc=${PIPESTATUS[0]}
  set -e

  if ((rc != 0)); then
    printf '  %b[FAIL]%b yq install failed — see %s\n' "$RED" "$NC" "$SPINUP_LOG" >&2
    exit "$rc"
  fi
  printf '  %b[ OK ]%b yq installed\n' "$GREEN" "$NC" >&2
}

# ---------------------------------------------------------------------------
# Section handlers
# ---------------------------------------------------------------------------
custom_packages() {
  local -a pkgs=()
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if has_cmd "$pkg"; then
      printf '  %-14s %b✓ installed%b\n' "$pkg" "$GREEN" "$NC" >&2
    else
      pkgs+=("$pkg")
    fi
  done < <(yq '.packages // empty | .[]' "$SPINUP_CONFIG" 2>/dev/null)

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    return 0
  fi

  printf '\n%b[custom]%b Installing packages: %s\n' "$BLUE" "$NC" "${pkgs[*]}" >&2
  set +e
  (
    set -e
    sudo apt-get update -qq
    sudo apt-get install --no-install-recommends -y "${pkgs[@]}"
  ) 2>&1 | viewport
  local rc=${PIPESTATUS[0]}
  set -e

  if ((rc != 0)); then
    printf '  %b[FAIL]%b apt packages failed — see %s\n' "$RED" "$NC" "$SPINUP_LOG" >&2
    exit "$rc"
  fi
  printf '  %b[ OK ]%b packages installed\n' "$GREEN" "$NC" >&2
}

custom_github_releases() {
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local repo binary
    repo=$(echo "$entry" | cut -d' ' -f1)
    binary=$(echo "$entry" | cut -d' ' -f2)

    if has_cmd "$binary"; then
      printf '  %-14s %b✓ installed%b\n' "$binary" "$GREEN" "$NC" >&2
      continue
    fi

    printf '\n%b[custom]%b Installing %s...\n' "$BLUE" "$NC" "$binary" >&2
    set +e
    (
      set -e
      install_github_release "$repo" "$binary" "linux" "$(detect_arch)"
    ) 2>&1 | viewport
    local rc=${PIPESTATUS[0]}
    set -e

    if ((rc != 0)); then
      printf '  %b[FAIL]%b %s failed — see %s\n' "$RED" "$NC" "$binary" "$SPINUP_LOG" >&2
      exit "$rc"
    fi
    printf '  %b[ OK ]%b %s installed\n' "$GREEN" "$NC" "$binary" >&2
  done < <(yq '.github_releases // empty | .[] | .repo + " " + .binary' "$SPINUP_CONFIG" 2>/dev/null)
}

custom_aliases() {
  local has_aliases
  has_aliases=$(yq '.aliases // empty | length' "$SPINUP_CONFIG" 2>/dev/null)
  if [[ -z "$has_aliases" || "$has_aliases" == "0" ]]; then
    return 0
  fi

  printf '\n%b[custom]%b Configuring custom aliases...\n' "$BLUE" "$NC" >&2

  # Remove existing custom section before re-adding (idempotent)
  if [[ -f "$SPINUP_ALIASES_FILE" ]]; then
    sed -i '/^# custom aliases — from spinup.yaml$/,$d' "$SPINUP_ALIASES_FILE"
  fi

  # Append custom aliases to the shared aliases file
  printf '\n# custom aliases — from spinup.yaml\n' >>"$SPINUP_ALIASES_FILE"
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    printf 'alias %s="%s"\n' "$key" "$value" >>"$SPINUP_ALIASES_FILE"
  done < <(yq '.aliases | to_entries[] | .key + "=" + .value' "$SPINUP_CONFIG" 2>/dev/null)

  printf '  %b[ OK ]%b custom aliases added to %s\n' "$GREEN" "$NC" "$SPINUP_ALIASES_FILE" >&2
}

custom_post_install() {
  local has_scripts
  has_scripts=$(yq '.post_install // empty | length' "$SPINUP_CONFIG" 2>/dev/null)
  if [[ -z "$has_scripts" || "$has_scripts" == "0" ]]; then
    return 0
  fi

  printf '\n%b[custom]%b Running post-install scripts...\n' "$BLUE" "$NC" >&2
  local step=0
  while IFS= read -r script; do
    [[ -z "$script" ]] && continue
    ((++step))

    printf '  %b[%d]%b %s\n' "$DIM" "$step" "$NC" "$script" >&2
    set +e
    (
      set -e
      bash -c "$script"
    ) 2>&1 | viewport
    local rc=${PIPESTATUS[0]}
    set -e

    if ((rc != 0)); then
      printf '  %b[FAIL]%b post-install script %d failed — see %s\n' "$RED" "$NC" "$step" "$SPINUP_LOG" >&2
      exit "$rc"
    fi
  done < <(yq '.post_install // empty | .[]' "$SPINUP_CONFIG" 2>/dev/null)

  printf '  %b[ OK ]%b post-install scripts complete\n' "$GREEN" "$NC" >&2
}

# ---------------------------------------------------------------------------
# Entry point — called from bootstrap.sh
# ---------------------------------------------------------------------------
run_custom() {
  if [[ ! -f "$SPINUP_CONFIG" ]]; then
    printf '  %b[FAIL]%b Config not found: %s\n' "$RED" "$NC" "$SPINUP_CONFIG" >&2
    printf '         Create a spinup.yaml config file and try again.\n' >&2
    exit 1
  fi

  ensure_yq

  custom_packages
  custom_github_releases
  custom_aliases
  custom_post_install
}
