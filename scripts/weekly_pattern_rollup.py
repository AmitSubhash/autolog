#!/usr/bin/env python3
"""Generate a 7-day pattern rollup from AutoLog session and activity data."""

from __future__ import annotations

import argparse
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from statistics import mean, median

import daily_pattern_report as dpr


DB_PATH = Path.home() / "Library/Application Support/ContextD/contextd.sqlite"
VAULT_PATH = Path.home() / "Documents" / "autolog-vault"
DEFAULT_OUTPUT_DIR = VAULT_PATH / "Reports" / "Weekly"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a weekly AutoLog pattern rollup.")
    parser.add_argument("--end-date", default=datetime.now().strftime("%Y-%m-%d"))
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--output", default="")
    return parser.parse_args()


def evaluate_health(
    avg_fragmentation: float,
    maker_hours: float,
    browser_hours: float,
    median_restart: float | None,
    maker_first_days: int,
    total_days: int,
) -> tuple[str, list[str]]:
    reasons: list[str] = []
    score = 0

    if avg_fragmentation >= 60:
        score += 2
        reasons.append("high fragmentation across the week")
    elif avg_fragmentation >= 40:
        score += 1
        reasons.append("moderate fragmentation")

    if browser_hours > maker_hours * 1.5:
        score += 2
        reasons.append("browser time outweighed maker time")
    elif browser_hours > maker_hours:
        score += 1
        reasons.append("browser time slightly exceeded maker time")

    if median_restart is not None and median_restart > 45:
        score += 2
        reasons.append("slow recovery after drift or meetings")
    elif median_restart is not None and median_restart > 20:
        score += 1
        reasons.append("some recovery lag after drift")

    if total_days and maker_first_days / total_days >= 0.5:
        score -= 1
        reasons.append("maker-first starts showed up on multiple days")

    if score <= 1:
        return "Healthy enough", reasons
    if score <= 3:
        return "Watch", reasons
    return "Unhealthy pattern", reasons


def build_rollup(end_date: str, days: int) -> str:
    end = datetime.strptime(end_date, "%Y-%m-%d")
    conn = sqlite3.connect(DB_PATH)
    try:
        day_rows: list[dict] = []
        all_restart: list[float] = []
        all_meeting: list[float] = []
        total_maker = 0.0
        total_browser = 0.0
        total_comm = 0.0
        fragmentation_scores: list[int] = []
        maker_first_days = 0

        for offset in range(days):
            day = end - timedelta(days=offset)
            date_str = day.strftime("%Y-%m-%d")
            start, stop = dpr.start_end_for_date(date_str)
            sessions = dpr.fetch_sessions(conn, start, stop)
            activities = dpr.fetch_activities(conn, start, stop)

            if not sessions and not activities:
                continue

            cat_hours = dpr.category_hours(sessions)
            fragmentation = dpr.compute_fragmentation_metrics(
                [session.as_helper_dict() for session in sessions],
                [activity.as_helper_dict() for activity in activities],
            )
            first_browser, first_comm, first_maker = dpr.first_times(sessions)
            restart = dpr.restart_latencies(sessions)
            meeting = dpr.meeting_hangover_latencies(sessions)
            artifacts = dpr.activity_artifact_counter(activities, sessions)

            total_maker += cat_hours.get("maker", 0.0)
            total_browser += cat_hours.get("browser", 0.0)
            total_comm += cat_hours.get("communication", 0.0)
            fragmentation_scores.append(int(fragmentation["score"]))
            all_restart.extend(restart)
            all_meeting.extend(meeting)

            if first_maker and (first_browser is None or first_maker <= first_browser):
                maker_first_days += 1

            day_rows.append(
                {
                    "date": date_str,
                    "maker": cat_hours.get("maker", 0.0),
                    "browser": cat_hours.get("browser", 0.0),
                    "communication": cat_hours.get("communication", 0.0),
                    "fragmentation": fragmentation["score"],
                    "activities": len(activities),
                    "sessions": len(sessions),
                    "artifacts": ", ".join(f"{k}×{v}" for k, v in artifacts.items()) or "-",
                    "first_maker": first_maker.strftime("%H:%M") if first_maker else "-",
                }
            )

        topics = dpr.top_topics(
            [activity for offset in range(days)
             for activity in dpr.fetch_activities(conn, *(dpr.start_end_for_date((end - timedelta(days=offset)).strftime("%Y-%m-%d"))))]
        )
        links = dpr.linked_activity_examples(
            conn,
            end - timedelta(days=days - 1),
            end + timedelta(days=1),
        )
        commits = dpr.git_commit_signals_range(
            (end - timedelta(days=days - 1)).strftime("%Y-%m-%d"),
            end.strftime("%Y-%m-%d"),
        )
    finally:
        conn.close()

    avg_fragmentation = mean(fragmentation_scores) if fragmentation_scores else 0.0
    median_restart = median(all_restart) if all_restart else None
    median_meeting = median(all_meeting) if all_meeting else None
    health, reasons = evaluate_health(
        avg_fragmentation,
        total_maker,
        total_browser,
        median_restart,
        maker_first_days,
        len(day_rows),
    )

    lines = [
        f"# Weekly Pattern Rollup - ending {end_date}",
        "",
        "## Health",
        f"- Verdict: {health}",
        f"- Avg fragmentation: {avg_fragmentation:.1f}/100",
        f"- Total maker hours: {total_maker:.2f}",
        f"- Total browser hours: {total_browser:.2f}",
        f"- Total communication hours: {total_comm:.2f}",
        f"- Maker-first days: {maker_first_days}/{max(1, len(day_rows))}",
    ]

    if median_restart is not None:
        lines.append(f"- Median restart latency: {median_restart:.1f} min")
    if median_meeting is not None:
        lines.append(f"- Median meeting recovery latency: {median_meeting:.1f} min")
    if reasons:
        lines.append(f"- Why: {', '.join(reasons)}")

    lines.extend(["", "## Daily Breakdown"])
    for row in sorted(day_rows, key=lambda item: item["date"], reverse=True):
        lines.append(
            f"- {row['date']}: maker {row['maker']:.2f}h, browser {row['browser']:.2f}h, "
            f"comm {row['communication']:.2f}h, fragmentation {row['fragmentation']}/100, "
            f"sessions {row['sessions']}, activities {row['activities']}, first maker {row['first_maker']}, artifacts {row['artifacts']}"
        )

    lines.extend(["", "## Top Topics"])
    for topic, count in topics[:10]:
        lines.append(f"- {topic}: {count}")

    if commits:
        lines.extend(["", "## Git Signals"])
        for line in commits:
            lines.append(f"- {line}" if not line.startswith("  ") else line)

    if links:
        lines.extend(["", "## Cross-Day Knowledge Links"])
        for link in links[:10]:
            lines.append(f"- {link}")

    lines.extend(["", "## Recommendations"])
    if total_browser > total_maker:
        lines.append("- Browser time beat maker time this week. Protect a first maker block before research or inbox.")
    if avg_fragmentation >= 50:
        lines.append("- Keep no more than two active threads per day. Your captured usage still shows too much context spread.")
    if median_meeting is not None and median_meeting > 20:
        lines.append("- Schedule a forced post-meeting maker block. Meetings are likely bleeding into drift.")
    if median_restart is not None and median_restart > 30:
        lines.append("- Your restart latency is too high. Use a smaller recovery ritual after browser or communication spirals.")

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    report = build_rollup(args.end_date, args.days)
    output_path = (
        Path(args.output).expanduser()
        if args.output
        else DEFAULT_OUTPUT_DIR / f"weekly-pattern-rollup-{args.end_date}.md"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report, encoding="utf-8")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
