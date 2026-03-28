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
