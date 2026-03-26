"""Legacy fallback sync using the /v1/summaries endpoint.

Used when the new /v1/activities endpoint is unavailable or returns
no data. Produces the older 15-minute window activity notes.
"""
from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta
from pathlib import Path

from obsidian_helpers import sanitize_name

logger = logging.getLogger("obsidian-sync")

VAULT_PATH = Path.home() / "Documents" / "autolog-vault"


def _parse_ts(ts: str) -> datetime | None:
    """Parse ISO 8601 timestamp, tolerating common formats."""
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(ts, fmt)
        except ValueError:
            continue
    return None


def _round_to_window(dt: datetime) -> datetime:
    """Round datetime down to the nearest 15-minute boundary."""
    return dt.replace(
        minute=(dt.minute // 15) * 15, second=0, microsecond=0
    )


def run_legacy_sync(summaries: list[dict]) -> None:
    """Write time-block activity notes from legacy summaries.

    Parameters
    ----------
    summaries : list[dict]
        Raw summary dicts from GET /v1/summaries.
    """
    if not summaries:
        logger.warning("Legacy sync: no summaries returned")
        return

    logger.info("Legacy fallback: syncing %d summaries", len(summaries))

    windows: dict[datetime, list[dict]] = {}
    for summary in summaries:
        ts_key = summary.get("start_timestamp", summary.get("timestamp", ""))
        dt = _parse_ts(ts_key)
        if dt:
            windows.setdefault(_round_to_window(dt), []).append(summary)

    for window_start, window_summaries in sorted(windows.items()):
        fname = window_start.strftime("%Y-%m-%d_%H-%M")
        fpath = VAULT_PATH / "Activities" / f"{fname}.md"
        if fpath.exists():
            continue

        start_str = window_start.strftime("%H:%M")
        end_str = (window_start + timedelta(minutes=15)).strftime("%H:%M")
        all_apps: list[str] = []
        all_topics: list[str] = []
        texts: list[str] = []

        for summary in window_summaries:
            apps = [sanitize_name(a) for a in summary.get("app_names", [])]
            topics = [
                sanitize_name(t) for t in summary.get("key_topics", [])
            ]
            all_apps.extend(apps)
            all_topics.extend(topics)
            text = summary.get("summary", "").strip()
            if text:
                for name in apps + topics:
                    text = re.compile(re.escape(name), re.IGNORECASE).sub(
                        f"[[{name}]]", text, count=1
                    )
                texts.append(text)

        apps = list(dict.fromkeys(all_apps))
        topics = list(dict.fromkeys(all_topics))
        lines = [
            "---",
            f"date: {window_start.strftime('%Y-%m-%dT%H:%M:%S')}",
            f"apps: [{', '.join(apps)}]",
            f"topics: [{', '.join(topics)}]",
            "---",
            "",
            f"# {start_str} - {end_str}",
            "",
        ]
        if texts:
            lines.extend(texts + [""])
        if apps:
            lines.extend(["## Apps"] + [f"- [[{a}]]" for a in apps] + [""])
        if topics:
            lines.extend(
                ["## Topics"] + [f"- [[{t}]]" for t in topics] + [""]
            )
        fpath.write_text("\n".join(lines), encoding="utf-8")

    logger.info("Legacy sync complete")
