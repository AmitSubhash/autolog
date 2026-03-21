"""Sync contextd activity data to an Obsidian vault with wikilinks.

Fetches from the contextd API (activities, sessions, app-usage, graph)
and writes Activity/App/Topic/Daily notes with [[wikilinks]] so that
Obsidian's graph view visualizes the connections.

Falls back to the legacy /v1/summaries endpoint if new endpoints fail.
"""
from __future__ import annotations

import json
import logging
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

from obsidian_helpers import (
    build_activity_note,
    build_app_note,
    build_daily_note,
    build_topic_note,
    sanitize_name,
    slugify,
)
from obsidian_legacy import run_legacy_sync

CONTEXTD_URL = "http://127.0.0.1:21890"
AUTH_TOKEN_PATH = Path.home() / ".config" / "contextd" / "auth_token"
VAULT_PATH = Path.home() / "Documents" / "contextd-vault"
HTTP_TIMEOUT = 15
DEFAULT_HOURS = 2
MAX_FILENAME_LEN = 80

logger = logging.getLogger("obsidian-sync")
logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


def read_auth_token() -> str:
    """Read contextd bearer token from ~/.config/contextd/auth_token."""
    try:
        return AUTH_TOKEN_PATH.read_text(encoding="utf-8").strip()
    except (OSError, FileNotFoundError) as exc:
        logger.error("Cannot read auth token: %s", exc)
        return ""


# ---------------------------------------------------------------------------
# API fetchers
# ---------------------------------------------------------------------------


def _api_get(token: str, path: str) -> dict | list | None:
    """GET from the contextd API. Returns None on any error."""
    url = f"{CONTEXTD_URL}{path}"
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        logger.warning("API GET %s failed: %s", path, exc)
        return None


def fetch_activities(token: str, hours: int) -> list[dict]:
    """Fetch inferred activities from GET /v1/activities."""
    data = _api_get(token, f"/v1/activities?minutes={hours * 60}&limit=200")
    if isinstance(data, dict):
        return data.get("activities", [])
    return []


def fetch_activity_sessions(token: str, activity_id: int) -> list[dict]:
    """Fetch sessions for a specific activity."""
    data = _api_get(token, f"/v1/activities/{activity_id}/sessions")
    return data.get("sessions", []) if isinstance(data, dict) else []


def fetch_related(token: str, activity_id: int) -> list[dict]:
    """Fetch related activities for a specific activity."""
    data = _api_get(token, f"/v1/activities/{activity_id}/related?limit=5")
    return data.get("activities", []) if isinstance(data, dict) else []


def fetch_app_usage(token: str, hours: int) -> list[dict]:
    """Fetch app usage summary from GET /v1/app-usage."""
    data = _api_get(token, f"/v1/app-usage?minutes={hours * 60}")
    return data.get("usage", []) if isinstance(data, dict) else []


def fetch_summaries_legacy(token: str, hours: int) -> list[dict]:
    """Fetch summaries from the legacy GET /v1/summaries endpoint."""
    data = _api_get(token, f"/v1/summaries?minutes={hours * 60}&limit=200")
    if isinstance(data, dict):
        return data.get("summaries", data.get("data", []))
    return data if isinstance(data, list) else []


# ---------------------------------------------------------------------------
# Note writers
# ---------------------------------------------------------------------------


def _activity_filename(name: str) -> str:
    """Build filename from activity name only (no date prefix)."""
    slug = slugify(name, max_length=MAX_FILENAME_LEN - 3)
    return f"{slug}.md"


def write_activity_notes(
    token: str,
    activities: list[dict],
) -> tuple[int, dict[str, list[str]], dict[str, dict]]:
    """Write Activity notes; return (count, topic_map, app_data_map)."""
    topic_map: dict[str, list[str]] = {}
    app_data: dict[str, dict] = {}
    written = 0

    for activity in activities:
        activity_id = activity.get("id", 0)
        name = activity.get("name", "Unknown Activity")
        confidence = activity.get("confidence", 0.0)

        # Skip low-confidence fallback activities
        if confidence < 0.6:
            logger.debug("Skipping low-confidence activity: %s (%.2f)", name, confidence)
            continue

        sessions = fetch_activity_sessions(token, activity_id)
        related = fetch_related(token, activity_id)

        fname = _activity_filename(name)
        fpath = VAULT_PATH / "Activities" / fname
        content = build_activity_note(activity, sessions, related)
        fpath.write_text(content, encoding="utf-8")
        written += 1

        # Track topic -> activity names
        for topic in activity.get("key_topics", []):
            clean = sanitize_name(topic)
            topic_map.setdefault(clean, []).append(name)

        # Track app -> activity names, files, and window titles
        for session in sessions:
            app_name = session.get("app_name", "Unknown")
            entry = app_data.setdefault(
                app_name, {"activities": [], "files": [], "window_titles": []}
            )
            if name not in entry["activities"]:
                entry["activities"].append(name)
            for path in session.get("document_paths", []):
                if path not in entry["files"]:
                    entry["files"].append(path)
            for title in session.get("window_titles", []):
                if title and title not in entry["window_titles"]:
                    entry["window_titles"].append(title)

    return written, topic_map, app_data


def write_app_notes(
    app_usage: list[dict],
    app_data: dict[str, dict],
) -> int:
    """Write or update App notes. Returns count written."""
    written = 0
    for entry in app_usage:
        app_name = entry.get("app_name", "Unknown")
        extra = app_data.get(app_name, {"activities": [], "files": [], "window_titles": []})
        content = build_app_note(
            app_name=app_name,
            total_seconds=entry.get("total_seconds", 0),
            session_count=entry.get("session_count", 0),
            recent_files=extra.get("files", []),
            recent_activities=extra.get("activities", []),
            window_titles=extra.get("window_titles", []),
        )
        fpath = VAULT_PATH / "Apps" / f"{sanitize_name(app_name)}.md"
        fpath.write_text(content, encoding="utf-8")
        written += 1
    return written


def write_topic_notes(topic_map: dict[str, list[str]]) -> int:
    """Write or update Topic notes. Returns count written."""
    written = 0
    for topic_name, act_names in topic_map.items():
        content = build_topic_note(topic_name, act_names)
        fpath = VAULT_PATH / "Topics" / f"{topic_name}.md"
        fpath.write_text(content, encoding="utf-8")
        written += 1
    return written


def write_daily_notes(
    activities: list[dict], app_usage: list[dict],
) -> int:
    """Write Daily notes grouped by date. Returns count written."""
    by_date: dict[str, list[dict]] = {}
    for act in activities:
        date_key = act.get("start_timestamp", "")[:10]
        if date_key:
            by_date.setdefault(date_key, []).append(act)

    written = 0
    for date_str, day_acts in by_date.items():
        try:
            date_obj = datetime.strptime(date_str, "%Y-%m-%d")
        except ValueError:
            continue
        content = build_daily_note(date_obj, app_usage, day_acts)
        fpath = VAULT_PATH / "Daily" / f"{date_str}.md"
        fpath.write_text(content, encoding="utf-8")
        written += 1
    return written


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    """Run the Obsidian sync pipeline."""
    hours = DEFAULT_HOURS
    if len(sys.argv) > 1:
        try:
            hours = int(sys.argv[1])
        except ValueError:
            pass

    logger.info("Syncing last %d hours to %s", hours, VAULT_PATH)
    for sub in ("Activities", "Apps", "Topics", "Daily", ".obsidian"):
        (VAULT_PATH / sub).mkdir(parents=True, exist_ok=True)

    token = read_auth_token()
    if not token:
        logger.error("No auth token found, aborting")
        sys.exit(1)

    # Try new activities endpoint; fall back to legacy summaries
    activities = fetch_activities(token, hours)
    if not activities:
        logger.warning("New API returned no activities, trying legacy sync")
        summaries = fetch_summaries_legacy(token, hours)
        run_legacy_sync(summaries)
        return

    logger.info("Fetched %d activities", len(activities))

    act_count, topic_map, app_data = write_activity_notes(token, activities)
    app_usage = fetch_app_usage(token, hours)
    app_count = write_app_notes(app_usage, app_data)
    topic_count = write_topic_notes(topic_map)
    daily_count = write_daily_notes(activities, app_usage)

    logger.info(
        "Done: %d activities, %d apps, %d topics, %d daily notes",
        act_count, app_count, topic_count, daily_count,
    )


if __name__ == "__main__":
    main()
