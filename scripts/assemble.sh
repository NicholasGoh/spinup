#!/usr/bin/env bash
# scripts/assemble.sh — assembles bootstrap.sh from template + assets
#
# Processes two marker types in bootstrap-template.sh:
#   # __INJECT_HEREDOC:source:tag:dest__  →  cat >"dest" <<'TAG' ... TAG
#   # __INJECT_SOURCE:source__            →  raw file contents (inline)
#
# Usage: bash scripts/assemble.sh > bootstrap.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/bootstrap-template.sh"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: $TEMPLATE not found" >&2
  exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do

  # __INJECT_HEREDOC:source:tag:dest__
  if [[ "$line" =~ ^([[:space:]]*)#[[:space:]]__INJECT_HEREDOC:([^:]+):([^:]+):(.+)__[[:space:]]*$ ]]; then
    indent="${BASH_REMATCH[1]}"
    src="${BASH_REMATCH[2]}"
    tag="${BASH_REMATCH[3]}"
    dest="${BASH_REMATCH[4]}"
    src_file="$ROOT/$src"

    if [[ ! -f "$src_file" ]]; then
      echo "ERROR: source file not found: $src_file" >&2
      exit 1
    fi

    # Emit: <indent>cat >"dest" <<'TAG'
    printf '%scat >"%s" <<'"'"'%s'"'"'\n' "$indent" "$dest" "$tag"
    cat "$src_file"
    printf '%s\n' "$tag"

  # __INJECT_SOURCE:source__
  elif [[ "$line" =~ ^([[:space:]]*)#[[:space:]]__INJECT_SOURCE:(.+)__[[:space:]]*$ ]]; then
    src="${BASH_REMATCH[2]}"
    src_file="$ROOT/$src"

    if [[ ! -f "$src_file" ]]; then
      echo "ERROR: source file not found: $src_file" >&2
      exit 1
    fi

    cat "$src_file"

  # Pass through
  else
    printf '%s\n' "$line"
  fi

done < "$TEMPLATE"
