#!/usr/bin/env python3
"""Generate a practical daily pattern report from AutoLog data."""

from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from statistics import median
from typing import Iterable

from obsidian_helpers import compute_fragmentation_metrics, detect_artifacts


DB_PATH = Path.home() / "Library/Application Support/ContextD/contextd.sqlite"
CLAUDE_SESSIONS_DB = Path.home() / ".claude" / "homunculus" / "sessions.db"
CLAUDE_INSTINCTS_DIR = Path.home() / ".claude" / "homunculus" / "instincts" / "personal"
CLAUDE_PROJECTS_DIR = Path.home() / ".claude" / "homunculus" / "projects"
VAULT_PATH = Path.home() / "Documents" / "autolog-vault"
DEFAULT_OUTPUT_DIR = VAULT_PATH / "Reports" / "Daily"
DEFAULT_REPOS = [
    Path.home() / "contextd",
    Path.home() / "Projects" / "3brown1blue",
    Path.home() / "autofocus",
    Path.home() / "iu-hpc-agent",
    Path.home() / "NeuroDOT_py_repo",
    Path.home() / "adhd_app",
]

BROWSER_APPS = {"Safari", "Brave Browser", "Google Chrome", "Chrome", "Claude"}
COMM_APPS = {"Microsoft Teams", "Slack", "Messages", "Mail", "Outlook"}
MEETING_APPS = {"Microsoft Teams", "Zoom", "Google Meet"}
MAKER_APPS = {
    "Terminal",
    "Emacs",
    "Code",
    "MATLAB",
    "python3.12",
    "Python",
    "MRIcroGL",
    "Windows App",
    "ThinLinc Client",
}


@dataclass
class Session:
    start_ts: float
    end_ts: float
    app_name: str
    window_titles: list[str]
    document_paths: list[str]
    browser_urls: list[str]

    @property
    def duration(self) -> float:
        return max(0.0, self.end_ts - self.start_ts)

    @property
    def start_iso(self) -> str:
        return datetime.fromtimestamp(self.start_ts).isoformat(timespec="seconds")

    @property
    def end_iso(self) -> str:
        return datetime.fromtimestamp(self.end_ts).isoformat(timespec="seconds")

    def as_helper_dict(self) -> dict:
        return {
            "app_name": self.app_name,
            "start_timestamp": self.start_iso,
            "end_timestamp": self.end_iso,
            "window_titles": self.window_titles,
            "document_paths": self.document_paths,
            "browser_urls": self.browser_urls,
        }


@dataclass
class Activity:
    activity_id: int
    name: str
    description: str
    start_ts: float
    end_ts: float
    key_topics: list[str]
    document_paths: list[str]
    browser_urls: list[str]

    def as_helper_dict(self) -> dict:
        return {
            "id": self.activity_id,
            "name": self.name,
            "description": self.description,
            "key_topics": self.key_topics,
            "document_paths": self.document_paths,
            "browser_urls": self.browser_urls,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a daily AutoLog pattern report.")
    parser.add_argument("--date", default=datetime.now().strftime("%Y-%m-%d"))
    parser.add_argument("--output", default="")
    return parser.parse_args()


def decode_json_list(value: str | None) -> list[str]:
    if not value:
        return []
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []
    return [str(item) for item in parsed]


def start_end_for_date(date_str: str) -> tuple[datetime, datetime]:
    start = datetime.strptime(date_str, "%Y-%m-%d")
    end = start + timedelta(days=1)
    return start, end


def fetch_sessions(conn: sqlite3.Connection, start: datetime, end: datetime) -> list[Session]:
    rows = conn.execute(
        """
        SELECT startTimestamp, endTimestamp, appName, windowTitles, documentPaths, browserURLs
        FROM app_sessions
        WHERE endTimestamp >= ? AND startTimestamp < ?
        ORDER BY startTimestamp ASC
        """,
        (start.timestamp(), end.timestamp()),
    ).fetchall()
    return [
        Session(
            start_ts=row[0],
            end_ts=row[1],
            app_name=row[2],
            window_titles=decode_json_list(row[3]),
            document_paths=decode_json_list(row[4]),
            browser_urls=decode_json_list(row[5]),
        )
        for row in rows
    ]


def fetch_activities(conn: sqlite3.Connection, start: datetime, end: datetime) -> list[Activity]:
    rows = conn.execute(
        """
        SELECT id, name, COALESCE(description, ''), startTimestamp, endTimestamp,
               keyTopics, documentPaths, browserURLs
        FROM activities
        WHERE endTimestamp >= ? AND startTimestamp < ?
        ORDER BY startTimestamp ASC
        """,
        (start.timestamp(), end.timestamp()),
    ).fetchall()
    return [
        Activity(
            activity_id=row[0],
            name=row[1],
            description=row[2],
            start_ts=row[3],
            end_ts=row[4],
            key_topics=decode_json_list(row[5]),
            document_paths=decode_json_list(row[6]),
            browser_urls=decode_json_list(row[7]),
        )
        for row in rows
    ]


def category_for_app(app_name: str) -> str:
    if app_name in MAKER_APPS:
        return "maker"
    if app_name in COMM_APPS:
        return "communication"
    if app_name in BROWSER_APPS:
        return "browser"
    return "other"


def category_hours(sessions: list[Session]) -> dict[str, float]:
    totals: dict[str, float] = defaultdict(float)
    for session in sessions:
        totals[category_for_app(session.app_name)] += session.duration / 3600.0
    return totals


def first_times(sessions: list[Session]) -> tuple[datetime | None, datetime | None, datetime | None]:
    first_browser = None
    first_comm = None
    first_maker = None
    for session in sessions:
        start = datetime.fromtimestamp(session.start_ts)
        category = category_for_app(session.app_name)
        if category == "browser" and first_browser is None:
            first_browser = start
        if category == "communication" and first_comm is None:
            first_comm = start
        if category == "maker" and first_maker is None:
            first_maker = start
    return first_browser, first_comm, first_maker


def restart_latencies(sessions: list[Session]) -> list[float]:
    latencies: list[float] = []
    for index, session in enumerate(sessions):
        if category_for_app(session.app_name) not in {"browser", "communication"}:
            continue
        if session.duration < 10 * 60:
            continue
        for later in sessions[index + 1 :]:
            if category_for_app(later.app_name) == "maker":
                gap = max(0.0, later.start_ts - session.end_ts) / 60.0
                latencies.append(gap)
                break
    return latencies


def meeting_hangover_latencies(sessions: list[Session]) -> list[float]:
    latencies: list[float] = []
    for index, session in enumerate(sessions):
        if session.app_name not in MEETING_APPS:
            continue
        if session.duration < 5 * 60:
            continue
        for later in sessions[index + 1 :]:
            if category_for_app(later.app_name) == "maker":
                gap = max(0.0, later.start_ts - session.end_ts) / 60.0
                latencies.append(gap)
                break
    return latencies


def top_topics(activities: list[Activity], limit: int = 8) -> list[tuple[str, int]]:
    counts: Counter[str] = Counter()
    for activity in activities:
        counts.update(activity.key_topics)
    return counts.most_common(limit)


def top_apps(sessions: list[Session], limit: int = 8) -> list[tuple[str, float]]:
    totals: dict[str, float] = defaultdict(float)
    for session in sessions:
        totals[session.app_name] += session.duration / 3600.0
    return sorted(totals.items(), key=lambda item: item[1], reverse=True)[:limit]


def activity_artifacts(activities: list[Activity], sessions: list[Session]) -> list[str]:
    labels: list[str] = []
    for activity in activities:
        overlap = [
            session.as_helper_dict()
            for session in sessions
            if session.end_ts >= activity.start_ts and session.start_ts <= activity.end_ts
        ]
        for artifact in detect_artifacts(activity.as_helper_dict(), overlap):
            if artifact not in labels:
                labels.append(artifact)
    return labels


def activity_artifact_counter(activities: list[Activity], sessions: list[Session]) -> Counter[str]:
    counter: Counter[str] = Counter()
    for activity in activities:
        overlap = [
            session.as_helper_dict()
            for session in sessions
            if session.end_ts >= activity.start_ts and session.start_ts <= activity.end_ts
        ]
        counter.update(detect_artifacts(activity.as_helper_dict(), overlap))
    return counter


def git_commit_signals(date_str: str) -> list[str]:
    try:
        author = subprocess.check_output(
            ["git", "config", "--global", "user.email"], text=True
        ).strip()
    except subprocess.CalledProcessError:
        return []

    start = f"{date_str} 00:00"
    signals: list[str] = []
    for repo in DEFAULT_REPOS:
        if not (repo / ".git").exists():
            continue
        try:
            output = subprocess.check_output(
                [
                    "git",
                    "-C",
                    str(repo),
                    "log",
                    f"--since={start}",
                    f"--author={author}",
                    "--date=short",
                    "--format=%ad %s",
                ],
                text=True,
            ).strip()
        except subprocess.CalledProcessError:
            continue
        if not output:
            continue
        commits = output.splitlines()
        signals.append(f"{repo.name}: {len(commits)} commits")
        for line in commits[:3]:
            signals.append(f"  {line}")
    return signals


def git_commit_signals_range(start_date: str, end_date: str) -> list[str]:
    try:
        author = subprocess.check_output(
            ["git", "config", "--global", "user.email"], text=True
        ).strip()
    except subprocess.CalledProcessError:
        return []

    start = f"{start_date} 00:00"
    end = f"{end_date} 23:59"
    signals: list[str] = []
    for repo in DEFAULT_REPOS:
        if not (repo / ".git").exists():
            continue
        try:
            output = subprocess.check_output(
                [
                    "git",
                    "-C",
                    str(repo),
                    "log",
                    f"--since={start}",
                    f"--until={end}",
                    f"--author={author}",
                    "--date=short",
                    "--format=%ad %s",
                ],
                text=True,
            ).strip()
        except subprocess.CalledProcessError:
            continue
        if not output:
            continue
        commits = output.splitlines()
        signals.append(f"{repo.name}: {len(commits)} commits")
        for line in commits[:3]:
            signals.append(f"  {line}")
    return signals


def linked_activity_examples(conn: sqlite3.Connection, start: datetime, end: datetime) -> list[str]:
    rows = conn.execute(
        """
        SELECT a1.name, a2.name, l.linkType, l.sharedEntity
        FROM activity_links l
        JOIN activities a1 ON a1.id = l.sourceActivityId
        JOIN activities a2 ON a2.id = l.targetActivityId
        WHERE a1.endTimestamp >= ? AND a1.startTimestamp < ?
          AND a2.endTimestamp >= ? AND a2.startTimestamp < ?
        ORDER BY l.id DESC
        LIMIT 8
        """,
        (start.timestamp(), end.timestamp(), start.timestamp(), end.timestamp()),
    ).fetchall()
    return [
        f"{row[0]} -> {row[1]} via {row[2]} ({str(row[3])[:80]})"
        for row in rows
    ]


@dataclass
class ClaudeCodeIntel:
    session_count: int
    total_messages: int
    projects: list[str]
    instinct_count: int
    avg_confidence: float
    new_instincts_today: list[str]
    top_search_snippets: list[str]


def claude_code_intelligence(date_str: str) -> ClaudeCodeIntel | None:
    """Query Claude Code session DB and instincts for daily intelligence.

    Parameters
    ----------
    date_str : str
        Date in YYYY-MM-DD format.

    Returns
    -------
    ClaudeCodeIntel | None
        Intelligence summary, or None if the DB is unavailable.
    """
    if not CLAUDE_SESSIONS_DB.exists():
        return None

    try:
        db = sqlite3.connect(str(CLAUDE_SESSIONS_DB))
        db.execute("PRAGMA query_only = ON")
    except sqlite3.Error:
        return None

    try:
        # Sessions created today
        rows = db.execute(
            """SELECT project, message_count
               FROM sessions
               WHERE created_at LIKE ? || '%'""",
            (date_str,),
        ).fetchall()

        session_count = len(rows)
        total_messages = sum(r[1] for r in rows)
        project_counts: Counter[str] = Counter()
        for proj, msgs in rows:
            short = proj.replace("-Users-amit-", "").replace("-Users-amit", "HOME")
            if short == "-":
                short = "contextd-proxy"
            project_counts[short] += msgs
        projects = [
            f"{p} ({m}msg)" for p, m in project_counts.most_common(8)
        ]

        # Sample top content snippets from today's sessions (skip XML noise)
        top_snippets: list[str] = []
        snippet_rows = db.execute(
            """SELECT snippet(sessions_fts, 1, '', '', '...', 20) as snip
               FROM sessions_fts f
               JOIN sessions s ON s.id = f.session_id
               WHERE s.created_at LIKE ? || '%' AND s.message_count > 5
               LIMIT 20""",
            (date_str,),
        ).fetchall()
        for (snip,) in snippet_rows:
            if snip:
                clean = snip.replace("\n", " ").strip()[:120]
                # Skip XML task notifications and system-reminder noise
                if clean and "<task-" not in clean and "<system-" not in clean:
                    top_snippets.append(clean)
                    if len(top_snippets) >= 5:
                        break

    finally:
        db.close()

    # Instincts: count and average confidence
    instinct_files: list[Path] = []
    confidences: list[float] = []
    new_today: list[str] = []

    for search_dir in [CLAUDE_INSTINCTS_DIR]:
        if not search_dir.exists():
            continue
        for f in search_dir.iterdir():
            if f.suffix in (".yaml", ".yml", ".md") and f.is_file():
                instinct_files.append(f)

    # Also scan project instinct dirs
    if CLAUDE_PROJECTS_DIR.exists():
        for proj_dir in CLAUDE_PROJECTS_DIR.iterdir():
            personal = proj_dir / "instincts" / "personal"
            if personal.exists():
                for f in personal.iterdir():
                    if f.suffix in (".yaml", ".yml", ".md") and f.is_file():
                        instinct_files.append(f)

    import re

    for f in instinct_files:
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        m = re.search(r"confidence:\s*([\d.]+)", text)
        if m:
            confidences.append(float(m.group(1)))
        # Check if modified today
        mtime = datetime.fromtimestamp(f.stat().st_mtime)
        if mtime.strftime("%Y-%m-%d") == date_str:
            id_m = re.search(r"^id:\s*(.+)$", text, re.MULTILINE)
            name = id_m.group(1).strip() if id_m else f.stem
            new_today.append(name)

    avg_conf = sum(confidences) / len(confidences) if confidences else 0.0

    return ClaudeCodeIntel(
        session_count=session_count,
        total_messages=total_messages,
        projects=projects,
        instinct_count=len(instinct_files),
        avg_confidence=avg_conf,
        new_instincts_today=new_today,
        top_search_snippets=top_snippets,
    )


def build_report(date_str: str, sessions: list[Session], activities: list[Activity], conn: sqlite3.Connection) -> str:
    session_dicts = [session.as_helper_dict() for session in sessions]
    activity_dicts = [activity.as_helper_dict() for activity in activities]
    fragmentation = compute_fragmentation_metrics(session_dicts, activity_dicts)
    cat_hours = category_hours(sessions)
    first_browser, first_comm, first_maker = first_times(sessions)
    restart = restart_latencies(sessions)
    meeting = meeting_hangover_latencies(sessions)
    artifacts = activity_artifacts(activities, sessions)
    artifact_counter = activity_artifact_counter(activities, sessions)
    commits = git_commit_signals(date_str)
    topics = top_topics(activities)
    apps = top_apps(sessions)
    start, end = start_end_for_date(date_str)
    links = linked_activity_examples(conn, start, end)

    browser_before_maker = None
    if first_browser and first_maker and first_browser < first_maker:
        browser_before_maker = (first_maker - first_browser).total_seconds() / 60.0

    lines = [
        f"# Daily Pattern Report - {date_str}",
        "",
        "## Summary",
        f"- Sessions: {len(sessions)}",
        f"- Activities: {len(activities)}",
        f"- Fragmentation: {fragmentation['score']}/100 ({fragmentation['label']})",
        f"- Browser hours: {cat_hours.get('browser', 0.0):.2f}",
        f"- Communication hours: {cat_hours.get('communication', 0.0):.2f}",
        f"- Maker hours: {cat_hours.get('maker', 0.0):.2f}",
    ]

    if first_maker:
        lines.append(f"- First maker session: {first_maker.strftime('%H:%M')}")
    if browser_before_maker is not None:
        lines.append(f"- Browser-before-maker delay: {browser_before_maker:.0f} min")
    if first_comm:
        lines.append(f"- First communication session: {first_comm.strftime('%H:%M')}")
    if meeting:
        lines.append(f"- Median meeting recovery latency: {median(meeting):.1f} min")

    lines.extend([
        "",
        "## Top Apps",
    ])
    for app, hours in apps:
        lines.append(f"- {app}: {hours:.2f}h")

    lines.extend([
        "",
        "## Topic Signals",
    ])
    if topics:
        for topic, count in topics:
            lines.append(f"- {topic}: {count}")
    else:
        lines.append("- No strong topics detected.")

    lines.extend([
        "",
        "## Launch Pattern",
    ])
    if first_maker and (first_browser is None or first_maker <= first_browser):
        lines.append("- Maker session started before browser-heavy work.")
    elif browser_before_maker is not None:
        lines.append(f"- Browser-heavy work started {browser_before_maker:.0f} min before the first maker session.")
    else:
        lines.append("- No clear browser-before-maker pattern detected.")

    lines.extend([
        "",
        "## Restart Speed",
    ])
    if restart:
        lines.append(f"- Recovery events: {len(restart)}")
        lines.append(f"- Median restart latency: {median(restart):.1f} min")
        lines.append(f"- Average restart latency: {sum(restart) / len(restart):.1f} min")
    else:
        lines.append("- No qualifying browser/communication recovery events detected.")

    lines.extend([
        "",
        "## Meeting Hangover",
    ])
    if meeting:
        lines.append(f"- Recovery events: {len(meeting)}")
        lines.append(f"- Median meeting recovery latency: {median(meeting):.1f} min")
        lines.append(f"- Average meeting recovery latency: {sum(meeting) / len(meeting):.1f} min")
    else:
        lines.append("- No qualifying meeting-to-maker recovery events detected.")

    lines.extend([
        "",
        "## Artifact Signals",
    ])
    if artifacts:
        for artifact in artifacts:
            lines.append(f"- {artifact}")
    else:
        lines.append("- No clear artifact labels detected from activity text.")
    if artifact_counter:
        lines.append("- Scoreboard:")
        for name, count in artifact_counter.most_common():
            lines.append(f"  - {name}: {count}")

    if commits:
        lines.extend([
            "",
            "## Git Signals",
        ])
        for line in commits:
            lines.append(f"- {line}" if not line.startswith("  ") else line)

    lines.extend([
        "",
        "## Knowledge Graph Links",
    ])
    if links:
        for link in links:
            lines.append(f"- {link}")
    else:
        lines.append("- No same-day linked activity pairs found.")

    # Claude Code Intelligence section
    claude_intel = claude_code_intelligence(date_str)
    if claude_intel and claude_intel.session_count > 0:
        lines.extend([
            "",
            "## Claude Code Intelligence",
            f"- Sessions today: {claude_intel.session_count} ({claude_intel.total_messages} messages)",
        ])
        if claude_intel.projects:
            lines.append(f"- Projects: {', '.join(claude_intel.projects)}")
        lines.append(
            f"- Active instincts: {claude_intel.instinct_count} "
            f"(avg confidence: {claude_intel.avg_confidence:.2f})"
        )
        if claude_intel.new_instincts_today:
            lines.append(f"- New instincts today: {', '.join(claude_intel.new_instincts_today)}")
        if claude_intel.top_search_snippets:
            lines.append("- Session highlights:")
            for snip in claude_intel.top_search_snippets[:3]:
                lines.append(f"  - {snip}")

    lines.extend([
        "",
        "## Recommendations",
    ])
    if browser_before_maker and browser_before_maker > 30:
        lines.append("- Start the day with one maker action before opening browser-heavy loops.")
    if fragmentation["score"] >= 50:
        lines.append("- Fragmentation is high. Restrict the day to one main build thread and one admin thread.")
    if meeting and median(meeting) > 20:
        lines.append("- Meeting hangover is visible. Put a small maker action immediately after calls.")
    if cat_hours.get("communication", 0.0) > cat_hours.get("maker", 0.0):
        lines.append("- Communication dominated maker time. Use a post-meeting maker block immediately after calls.")
    if not artifacts and not commits:
        lines.append("- Low artifact signal. Define one concrete output earlier in the day.")
    if claude_intel:
        if claude_intel.session_count > 100:
            lines.append(
                f"- Heavy Claude Code day ({claude_intel.session_count} sessions). "
                "Check if sessions could be consolidated."
            )
        if len(claude_intel.projects) > 3:
            lines.append(
                f"- Context-switched across {len(claude_intel.projects)} projects in Claude Code."
            )
    if len(lines) <= 25:
        lines.append("- Pattern signals are light today. Let the report accumulate over several days before drawing hard conclusions.")

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    start, end = start_end_for_date(args.date)
    conn = sqlite3.connect(DB_PATH)
    try:
        sessions = fetch_sessions(conn, start, end)
        activities = fetch_activities(conn, start, end)
        report = build_report(args.date, sessions, activities, conn)
    finally:
        conn.close()

    output_path = (
        Path(args.output).expanduser()
        if args.output
        else DEFAULT_OUTPUT_DIR / f"pattern-report-{args.date}.md"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report, encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
