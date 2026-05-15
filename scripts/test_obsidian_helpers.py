"""Unit tests for fragmentation scoring heuristics."""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path
import sys
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from obsidian_helpers import compute_fragmentation_metrics


BASE_TIME = datetime(2026, 4, 23, 9, 0, 0)


def make_session(start_minute: float, duration_minutes: float, app_name: str) -> dict[str, str]:
    """Build a minimal session payload for scoring tests."""
    start = BASE_TIME + timedelta(minutes=start_minute)
    end = start + timedelta(minutes=duration_minutes)
    return {
        "app_name": app_name,
        "start_timestamp": start.isoformat(),
        "end_timestamp": end.isoformat(),
    }


def make_activity(*topics: str) -> dict[str, list[str]]:
    """Build a minimal activity payload for scoring tests."""
    return {"key_topics": list(topics)}


class FragmentationMetricsTests(unittest.TestCase):
    def test_allows_normal_multi_tool_work(self) -> None:
        sessions = [
            make_session(0, 45, "Terminal"),
            make_session(45, 15, "Brave Browser"),
            make_session(60, 50, "Microsoft PowerPoint"),
            make_session(110, 10, "Brave Browser"),
            make_session(120, 45, "Windows App"),
            make_session(165, 10, "Brave Browser"),
        ]
        activities = [
            make_activity("PigBET", "Neuroimaging"),
            make_activity("PigBET"),
            make_activity("Neuroimaging"),
        ]

        metrics = compute_fragmentation_metrics(sessions, activities)

        self.assertLess(metrics["score"], 25)
        self.assertEqual(metrics["label"], "Low")

    def test_discounts_tiny_interruptions(self) -> None:
        sessions = [
            make_session(0, 35, "Terminal"),
            make_session(35.0, 0.5, "Finder"),
            make_session(35.5, 0.5, "Safari"),
            make_session(36.0, 32, "Microsoft PowerPoint"),
            make_session(68.0, 0.5, "Preview"),
            make_session(68.5, 0.5, "Safari"),
            make_session(69.0, 30, "Windows App"),
            make_session(99.0, 0.5, "Finder"),
            make_session(99.5, 0.5, "Safari"),
            make_session(100.0, 28, "Microsoft PowerPoint"),
            make_session(128.0, 0.5, "Preview"),
            make_session(128.5, 0.5, "Finder"),
            make_session(129.0, 25, "Terminal"),
        ]
        activities = [
            make_activity("PigBET", "Slides"),
            make_activity("PigBET"),
            make_activity("Slides"),
            make_activity("PigBET"),
        ]

        metrics = compute_fragmentation_metrics(sessions, activities)

        self.assertLess(metrics["score"], 35)
        self.assertLess(metrics["meaningful_app_count"], metrics["app_count"])
        self.assertEqual(metrics["meaningful_app_count"], 3)

    def test_flags_true_context_churn(self) -> None:
        app_cycle = [
            "Brave Browser",
            "Safari",
            "Slack",
            "Mail",
            "Terminal",
            "Finder",
            "Preview",
            "Microsoft Teams",
        ]
        topic_cycle = [
            "PigBET",
            "Dashboard",
            "Job Search",
            "Tableau",
            "Diffusion",
            "Neuroimaging",
            "Admin",
            "Email",
        ]

        sessions: list[dict[str, str]] = []
        start = 0.0
        for index in range(24):
            duration = 0.75 if index % 2 == 0 else 2.0
            sessions.append(make_session(start, duration, app_cycle[index % len(app_cycle)]))
            start += duration

        activities = [
            make_activity(topic_cycle[index % len(topic_cycle)])
            for index in range(24)
        ]

        metrics = compute_fragmentation_metrics(sessions, activities)

        self.assertGreaterEqual(metrics["score"], 50)
        self.assertEqual(metrics["label"], "High")


if __name__ == "__main__":
    unittest.main()
