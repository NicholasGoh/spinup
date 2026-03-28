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
