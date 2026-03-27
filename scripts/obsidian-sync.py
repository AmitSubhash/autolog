"""Sync autolog activity data to an Obsidian vault with wikilinks.

Fetches from the autolog API (activities, sessions, app-usage, graph)
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

from focus_state import (
    best_matching_focus_block,
    focus_block_note_name,
    load_focus_blocks,
)
from obsidian_helpers import (
    CONFIDENCE_THRESHOLD,
    build_activity_note,
    build_app_note,
    build_block_note,
    build_daily_note,
    build_topic_note,
    compute_fragmentation_metrics,
    detect_artifacts,
    normalize_topic,
    sanitize_name,
    slugify,
)
from obsidian_legacy import run_legacy_sync

AUTOLOG_URL = "http://127.0.0.1:21890"
AUTH_TOKEN_PATH = Path.home() / ".config" / "autolog" / "auth_token"
VAULT_PATH = Path.home() / "Documents" / "autolog-vault"
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
    """Read autolog bearer token from ~/.config/autolog/auth_token."""
    try:
        return AUTH_TOKEN_PATH.read_text(encoding="utf-8").strip()
    except (OSError, FileNotFoundError) as exc:
        logger.error("Cannot read auth token: %s", exc)
        return ""


# ---------------------------------------------------------------------------
# API fetchers
# ---------------------------------------------------------------------------


def _api_get(token: str, path: str) -> dict | list | None:
    """GET from the autolog API. Returns None on any error."""
    url = f"{AUTOLOG_URL}{path}"
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
    focus_blocks: list[dict] | None = None,
) -> tuple[int, dict[str, list[str]], dict[str, dict], dict[int, list[dict]], list[dict]]:
    """Write Activity notes and return supporting data for later note generation."""
    topic_map: dict[str, list[str]] = {}
    app_data: dict[str, dict] = {}
    sessions_by_activity: dict[int, list[dict]] = {}
    enriched_activities: list[dict] = []
    written = 0

    for activity in activities:
        activity_id = activity.get("id", 0)
        name = activity.get("name", "Unknown Activity")
        confidence = activity.get("confidence", 0.0)

        # Skip low-confidence fallback activities
        if confidence < CONFIDENCE_THRESHOLD:
            logger.debug("Skipping low-confidence activity: %s (%.2f)", name, confidence)
            continue

        sessions = fetch_activity_sessions(token, activity_id)
        related = fetch_related(token, activity_id)
        sessions_by_activity[activity_id] = sessions

        focus_block = best_matching_focus_block(
            activity.get("start_timestamp", ""),
            activity.get("end_timestamp", ""),
            focus_blocks or [],
        )
        if focus_block:
            focus_block = dict(focus_block)
            focus_block["note_name"] = focus_block_note_name(focus_block)
        artifacts = detect_artifacts(activity, sessions)
        fragmentation = compute_fragmentation_metrics(sessions, [activity])

        enriched_activity = dict(activity)
        if focus_block:
            enriched_activity["focus_block"] = focus_block
        enriched_activity["fragmentation"] = fragmentation
        enriched_activity["artifacts"] = artifacts
        enriched_activities.append(enriched_activity)

        fname = _activity_filename(name)
        fpath = VAULT_PATH / "Activities" / fname
        content = build_activity_note(
            enriched_activity,
            sessions,
            related,
            focus_block=focus_block,
            artifacts=artifacts,
            fragmentation=fragmentation,
        )
        fpath.write_text(content, encoding="utf-8")
        written += 1

        # Track topic -> activity names (normalized)
        for topic in activity.get("key_topics", []):
            clean = normalize_topic(topic)
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

    return written, topic_map, app_data, sessions_by_activity, enriched_activities


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
    activities: list[dict],
    app_usage: list[dict],
    all_sessions: list[dict] | None = None,
    focus_blocks: list[dict] | None = None,
) -> int:
    """Write Daily notes grouped by date. Returns count written.

    Parameters
    ----------
    activities : list[dict]
        All activities in the sync window.
    app_usage : list[dict]
        Global app usage (used as fallback if sessions unavailable).
    all_sessions : list[dict], optional
        All raw sessions, used to compute per-day app usage.
    """
    by_date: dict[str, list[dict]] = {}
    for act in activities:
        date_key = act.get("start_timestamp", "")[:10]
        if date_key:
            by_date.setdefault(date_key, []).append(act)
    blocks_by_date: dict[str, list[dict]] = {}
    for block in focus_blocks or []:
        date_key = str(block.get("started_at", ""))[:10]
        if date_key:
            blocks_by_date.setdefault(date_key, []).append(block)

    # Only attribute global app_usage to the most recent date since
    # session-level data is not available for per-day breakdown.
    latest_date = max(by_date.keys()) if by_date else ""

    written = 0
    for date_str, day_acts in by_date.items():
        try:
            date_obj = datetime.strptime(date_str, "%Y-%m-%d")
        except ValueError:
            continue
        day_app_usage = app_usage if date_str == latest_date else []
        content = build_daily_note(
            date_obj,
            day_app_usage,
            day_acts,
            all_sessions=all_sessions,
            focus_blocks=blocks_by_date.get(date_str, []),
        )
        fpath = VAULT_PATH / "Daily" / f"{date_str}.md"
        fpath.write_text(content, encoding="utf-8")
        written += 1
    return written


def _session_overlaps_block(session: dict, block: dict) -> bool:
    """Return True when a session overlaps a focus block."""
    def _parse(value: str | None) -> datetime | None:
        if not value:
            return None
        try:
            return datetime.fromisoformat(str(value).replace("Z", "+00:00")).replace(tzinfo=None)
        except ValueError:
            return None

    session_start = _parse(session.get("start_timestamp"))
    session_end = _parse(session.get("end_timestamp"))
    block_start = _parse(block.get("started_at"))
    block_end = _parse(block.get("ended_at")) or datetime.now().replace(microsecond=0)
    if not session_start or not session_end or not block_start:
        return False
    return max(session_start, block_start) < min(session_end, block_end)


def write_block_notes(
    focus_blocks: list[dict],
    activities: list[dict],
    sessions_by_activity: dict[int, list[dict]],
) -> int:
    """Write focus block notes for completed and active blocks."""
    if not focus_blocks:
        return 0

    written = 0
    for block in focus_blocks:
        block_copy = dict(block)
        block_copy["note_name"] = focus_block_note_name(block_copy)

        block_activities = [
            activity for activity in activities
            if activity.get("focus_block", {}).get("id") == block_copy.get("id")
        ]
        block_sessions: list[dict] = []
        for activity in block_activities:
            for session in sessions_by_activity.get(activity.get("id", 0), []):
                if _session_overlaps_block(session, block_copy):
                    block_sessions.append(session)

        fragmentation = compute_fragmentation_metrics(block_sessions, block_activities)
        block_copy["fragmentation_score"] = fragmentation.get("score")

        artifact_labels: list[str] = []
        for activity in block_activities:
            for artifact in activity.get("artifacts", []):
                if artifact not in artifact_labels:
                    artifact_labels.append(artifact)

        content = build_block_note(
            block_copy,
            block_activities,
            block_sessions,
            fragmentation,
            artifact_labels,
        )
        fpath = VAULT_PATH / "Blocks" / f"{block_copy['note_name']}.md"
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
    for sub in ("Activities", "Apps", "Topics", "Daily", "Blocks", ".obsidian"):
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

    focus_blocks = load_focus_blocks(include_open=True)
    act_count, topic_map, app_data, sessions_by_activity, enriched_activities = write_activity_notes(
        token,
        activities,
        focus_blocks=focus_blocks,
    )
    app_usage = fetch_app_usage(token, hours)
    app_count = write_app_notes(app_usage, app_data)
    topic_count = write_topic_notes(topic_map)

    # Collect all sessions for per-day app usage in daily notes
    all_sessions: list[dict] = []
    for activity_id, sessions in sessions_by_activity.items():
        for session in sessions:
            session_copy = dict(session)
            session_copy["activity_id"] = activity_id
            all_sessions.append(session_copy)

    block_count = write_block_notes(focus_blocks, enriched_activities, sessions_by_activity)
    daily_count = write_daily_notes(
        enriched_activities,
        app_usage,
        all_sessions,
        focus_blocks=focus_blocks,
    )

    logger.info(
        "Done: %d activities, %d apps, %d topics, %d block notes, %d daily notes",
        act_count, app_count, topic_count, block_count, daily_count,
    )


if __name__ == "__main__":
    main()
