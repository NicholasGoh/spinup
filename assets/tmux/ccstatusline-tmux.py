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
