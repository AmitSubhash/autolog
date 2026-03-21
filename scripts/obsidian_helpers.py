"""Formatting helpers for the contextd Obsidian sync.

Pure functions for slugifying names, formatting durations, and building
Markdown content for Activity, App, Topic, and Daily notes.
"""
from __future__ import annotations

import re
import urllib.parse
from datetime import datetime


def slugify(text: str, max_length: int = 60) -> str:
    """Convert text to a URL/filename-safe lowercase slug."""
    slug = re.sub(r"[^\w\s-]", "", text.lower().strip())
    slug = re.sub(r"[\s_]+", "-", slug)
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    return slug[:max_length] if slug else "unknown-activity"


def sanitize_name(name: str) -> str:
    """Clean a name for use as an Obsidian note title (max 60 chars)."""
    cleaned = re.sub(r"\s+", " ", re.sub(r"[^\w\s\-]", "", name)).strip()
    # Prevent directory traversal via ".." names
    cleaned = cleaned.strip(".")
    return cleaned[:60].title() if cleaned else "Unknown"


def format_duration(total_seconds: float) -> str:
    """Format seconds into a string like '2h 14m', '45m', or '30s'."""
    minutes = int(total_seconds) // 60
    if minutes >= 60:
        hours, remaining = divmod(minutes, 60)
        return f"{hours}h {remaining:02d}m" if remaining else f"{hours}h"
    return f"{minutes}m" if minutes > 0 else f"{int(total_seconds)}s"


def _extract_filename(path: str) -> str:
    """Extract the filename from a file path for wikilinks."""
    return path.replace("\\", "/").rsplit("/", 1)[-1]


def _parse_iso(ts: str) -> datetime | None:
    """Parse an ISO 8601 timestamp, tolerating several formats."""
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            dt = datetime.strptime(ts, fmt)
            if dt.tzinfo is not None:
                dt = dt.astimezone().replace(tzinfo=None)
            return dt
        except ValueError:
            continue
    return None


def _duration_minutes(start_ts: str, end_ts: str) -> int:
    """Compute duration in whole minutes between two ISO timestamps."""
    start, end = _parse_iso(start_ts), _parse_iso(end_ts)
    if start and end:
        return max(1, int((end - start).total_seconds() / 60))
    return 0


def _aggregate_sessions(sessions: list[dict]) -> list[dict]:
    """Aggregate session data by app, sorted by total time descending."""
    by_app: dict[str, dict] = {}
    for session in sessions:
        app = session.get("app_name", "Unknown")
        entry = by_app.setdefault(app, {
            "app_name": app, "total_seconds": 0.0,
            "window_titles": [], "document_paths": [],
        })
        start, end = _parse_iso(session.get("start_timestamp", "")), \
            _parse_iso(session.get("end_timestamp", ""))
        if start and end:
            entry["total_seconds"] += (end - start).total_seconds()
        for title in session.get("window_titles", []):
            if title and title not in entry["window_titles"]:
                entry["window_titles"].append(title)
        for path in session.get("document_paths", []):
            if path and path not in entry["document_paths"]:
                entry["document_paths"].append(path)
    return sorted(by_app.values(), key=lambda x: x["total_seconds"], reverse=True)


def _url_display(url: str) -> str:
    """Extract a short display label from a URL."""
    display = re.sub(r"^https?://", "", url).rstrip("/")
    return display[:57] + "..." if len(display) > 60 else display


def _escape_md_url(url: str) -> str:
    """Escape parentheses in URLs for Markdown link syntax safety."""
    return url.replace("(", "%28").replace(")", "%29")


def _collect_paths(activity: dict, sessions: list[dict]) -> list[str]:
    """Collect unique document paths from activity and its sessions."""
    paths = list(dict.fromkeys(activity.get("document_paths", [])))
    for session in sessions:
        for path in session.get("document_paths", []):
            if path not in paths:
                paths.append(path)
    return paths[:10]


def _collect_urls(activity: dict, sessions: list[dict]) -> list[str]:
    """Collect unique browser URLs from activity and its sessions."""
    urls = list(dict.fromkeys(activity.get("browser_urls", [])))
    for session in sessions:
        for url in session.get("browser_urls", []):
            if url not in urls:
                urls.append(url)
    return urls[:10]


# ---------------------------------------------------------------------------
# Note builders
# ---------------------------------------------------------------------------


def build_activity_note(
    activity: dict, sessions: list[dict], related: list[dict],
) -> str:
    """Build Markdown content for an Activity note."""
    start_ts = activity.get("start_timestamp", "")
    end_ts = activity.get("end_timestamp", "")
    name = activity.get("name", "Unknown Activity")
    description = activity.get("description", "")
    topics = activity.get("key_topics", [])
    confidence = activity.get("confidence", 0.0)
    duration = _duration_minutes(start_ts, end_ts)
    app_sessions = _aggregate_sessions(sessions)
    app_names = [e["app_name"] for e in app_sessions]

    # Parse date for human-readable display
    start_dt = _parse_iso(start_ts)
    end_dt = _parse_iso(end_ts)
    date_display = start_dt.strftime("%B %d, %Y at %H:%M") if start_dt else ""
    time_range = ""
    if start_dt and end_dt:
        time_range = f"{start_dt.strftime('%H:%M')} - {end_dt.strftime('%H:%M')}"

    lines: list[str] = [
        "---",
        f"duration_minutes: {duration}",
        f"apps: [{', '.join(app_names)}]",
        f"topics: [{', '.join(sanitize_name(t) for t in topics)}]",
        f"confidence: {confidence}",
        "---", "",
        f"# {name}", "",
        f"**When:** {date_display}  ",
        f"**Duration:** {format_duration(duration * 60)} ({time_range})  ",
        f"**Apps:** {', '.join(app_names)}",
        "",
    ]
    if description:
        lines.extend([description, ""])

    if app_sessions:
        lines.append("## Sessions")
        for entry in app_sessions:
            dur = format_duration(entry["total_seconds"])
            extras = list(dict.fromkeys(
                entry["window_titles"][:3]
                + [_extract_filename(p) for p in entry["document_paths"][:3]]
            ))
            suffix = f": {', '.join(extras)}" if extras else ""
            lines.append(f"- **{entry['app_name']}** ({dur}){suffix}")
        lines.append("")

    all_files = _collect_paths(activity, sessions)
    if all_files:
        lines.append("## Files")
        lines.extend(f"- [[{_extract_filename(p)}]]" for p in all_files)
        lines.append("")

    all_urls = _collect_urls(activity, sessions)
    if all_urls:
        lines.append("## URLs")
        lines.extend(f"- [{_url_display(u)}]({_escape_md_url(u)})" for u in all_urls)
        lines.append("")

    if related:
        lines.append("## Related Activities")
        lines.extend(f"- [[{r.get('name', 'Unknown')}]]" for r in related[:5])
        lines.append("")

    if topics:
        lines.append("## Topics")
        lines.extend(f"- [[{sanitize_name(t)}]]" for t in topics)
        lines.append("")

    return "\n".join(lines)


def build_app_note(
    app_name: str, total_seconds: float, session_count: int,
    recent_files: list[str], recent_activities: list[str],
    window_titles: list[str] | None = None,
) -> str:
    """Build Markdown content for an App note."""
    lines = [
        "---", "type: app", "---", "",
        f"# {app_name}", "",
        "## Today's Usage",
        f"- **Total time:** {format_duration(total_seconds)}",
        f"- **Sessions:** {session_count}", "",
    ]
    if window_titles:
        lines.append("## Recent Windows")
        for title in list(dict.fromkeys(window_titles))[:8]:
            lines.append(f"- {title}")
        lines.append("")
    if recent_files:
        lines.append("## Recent Files")
        lines.extend(f"- [[{_extract_filename(f)}]]" for f in recent_files[:10])
        lines.append("")
    if recent_activities:
        lines.append("## Recent Activities")
        lines.extend(f"- [[{a}]]" for a in recent_activities[:10])
        lines.append("")
    return "\n".join(lines)


def build_topic_note(
    topic_name: str, recent_activities: list[str],
) -> str:
    """Build Markdown content for a Topic note."""
    clean = sanitize_name(topic_name)
    count = len(recent_activities)
    lines = ["---", "type: topic", "---", "", f"# {clean}", ""]
    lines.append(
        f"This topic appeared in **{count} {'activity' if count == 1 else 'activities'}**."
    )
    lines.append("")
    if recent_activities:
        lines.append("## Activities")
        lines.extend(f"- [[{a}]]" for a in recent_activities[:10])
        lines.append("")
    return "\n".join(lines)


def build_daily_note(
    date: datetime, app_usage: list[dict], activities: list[dict],
) -> str:
    """Build Markdown content for a Daily note."""
    date_str = date.strftime("%Y-%m-%d")
    title = date.strftime("%B %d, %Y")
    lines = ["---", f"date: {date_str}", "---", "", f"# {title}", ""]

    if app_usage:
        sorted_usage = sorted(
            app_usage, key=lambda x: x.get("total_seconds", 0), reverse=True,
        )
        lines.extend(["## App Usage", "| App | Time | Sessions |", "|-----|------|----------|"])
        for entry in sorted_usage:
            app = entry.get("app_name", "Unknown")
            dur = format_duration(entry.get("total_seconds", 0))
            cnt = entry.get("session_count", 0)
            lines.append(f"| {app} | {dur} | {cnt} |")
        lines.append("")

    if activities:
        lines.append("## Activities")
        for act in activities:
            act_name = act.get("name", "Unknown")
            dur = _duration_minutes(
                act.get("start_timestamp", ""), act.get("end_timestamp", ""),
            )
            lines.append(f"- [[{act_name}]] ({dur} min)")
        lines.append("")

    return "\n".join(lines)
