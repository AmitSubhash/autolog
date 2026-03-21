"""Audit the contextd pipeline by capturing one full cycle's artifacts.

Saves intermediate outputs from each stage to process/ folder:
  1_screenshot.png        - Raw screen capture
  2_diff_info.txt         - Pixel diff result (vs previous frame)
  3_ocr_raw.txt           - Raw OCR text from Vision
  4_ocr_regions.json      - OCR regions with bounding boxes + confidence
  5_metadata.json         - Accessibility metadata (app, window, doc path, URL, role)
  6_capture_record.json   - What gets stored in the DB
  7_chunk_input.txt       - Formatted text sent to Haiku for summarization
  8_haiku_response.json   - Raw Haiku LLM response
  9_summary_record.json   - Final summary stored in DB
  10_session_record.json  - App session record (if finalized)

Run: python3 process/audit_pipeline.py
Requires: contextd running on port 21890
"""
from __future__ import annotations

import json
import subprocess
import sqlite3
import time
from datetime import datetime, timedelta
from pathlib import Path

DB_PATH = Path.home() / "Library/Application Support/ContextD/contextd.sqlite"
PROCESS_DIR = Path(__file__).parent
API_BASE = "http://127.0.0.1:21890"


def query_db(sql: str, params: tuple = ()) -> list[dict]:
    """Query SQLite and return list of dicts."""
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(sql, params).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def save_json(data: object, filename: str) -> Path:
    """Save data as formatted JSON."""
    path = PROCESS_DIR / filename
    path.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")
    print(f"  Saved: {path.name}")
    return path


def save_text(text: str, filename: str) -> Path:
    """Save text to file."""
    path = PROCESS_DIR / filename
    path.write_text(text, encoding="utf-8")
    print(f"  Saved: {path.name}")
    return path


def take_screenshot() -> Path:
    """Take a screenshot using screencapture (same as what contextd sees)."""
    path = PROCESS_DIR / "1_screenshot.png"
    subprocess.run(
        ["screencapture", "-x", "-C", str(path)],
        check=True, capture_output=True,
    )
    print(f"  Saved: {path.name}")
    return path


def wait_for_new_capture(after_id: int, timeout: int = 30) -> dict | None:
    """Wait for a new capture to appear in the DB after the given ID."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows = query_db(
            "SELECT * FROM captures WHERE id > ? ORDER BY id DESC LIMIT 1",
            (after_id,),
        )
        if rows:
            return rows[0]
        time.sleep(1)
    return None


def get_latest_summary(after_ts: float, timeout: int = 180) -> dict | None:
    """Wait for a summary covering captures after the given timestamp."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        rows = query_db(
            "SELECT * FROM summaries WHERE startTimestamp >= ? ORDER BY id DESC LIMIT 1",
            (after_ts,),
        )
        if rows:
            return rows[0]
        time.sleep(5)
    return None


def get_latest_session(after_ts: float) -> dict | None:
    """Get most recent app session."""
    rows = query_db(
        "SELECT * FROM app_sessions WHERE startTimestamp >= ? ORDER BY id DESC LIMIT 1",
        (after_ts,),
    )
    return rows[0] if rows else None


def main() -> None:
    """Run the full pipeline audit."""
    print("=" * 60)
    print("contextd Pipeline Audit")
    print(f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    # Get current max capture ID
    rows = query_db("SELECT COALESCE(MAX(id), 0) as max_id FROM captures")
    start_id = rows[0]["max_id"]
    start_ts = time.time()
    print(f"\nStarting after capture #{start_id}")

    # Stage 1: Screenshot (what the screen looks like right now)
    print("\n--- Stage 1: Screenshot ---")
    take_screenshot()

    # Stage 2-4: Wait for contextd to capture + OCR
    print("\n--- Stage 2-4: Waiting for new capture (OCR + metadata)... ---")
    capture = wait_for_new_capture(start_id, timeout=60)
    if not capture:
        print("  ERROR: No new capture appeared in 60s. Is contextd running?")
        return

    cap_id = capture["id"]
    print(f"  Got capture #{cap_id} ({capture['frameType']})")

    # Stage 2: Diff info
    diff_info = {
        "capture_id": cap_id,
        "frame_type": capture["frameType"],
        "change_percentage": capture["changePercentage"],
        "keyframe_id": capture["keyframeId"],
        "note": (
            "keyframe = full screen OCR (no diff)"
            if capture["frameType"] == "keyframe"
            else f"delta = {capture['changePercentage']*100:.0f}% of screen changed"
        ),
    }
    save_json(diff_info, "2_diff_info.json")

    # Stage 3: Raw OCR text
    save_text(capture["fullOcrText"] or "(empty)", "3_ocr_raw.txt")
    save_text(capture["ocrText"] or "(empty)", "3b_ocr_delta_only.txt")

    # Stage 4: Nothing to show for regions (not stored in DB -- see TODO in code)

    # Stage 5: Accessibility metadata
    metadata = {
        "capture_id": cap_id,
        "timestamp": datetime.fromtimestamp(capture["timestamp"]).isoformat(),
        "app_name": capture["appName"],
        "app_bundle_id": capture["appBundleID"],
        "window_title": capture["windowTitle"],
        "document_path": capture["documentPath"],
        "browser_url": capture["browserURL"],
        "focused_element_role": capture["focusedElementRole"],
        "visible_windows": (
            json.loads(capture["visibleWindows"])
            if capture["visibleWindows"]
            else []
        ),
    }
    save_json(metadata, "5_metadata.json")

    # Stage 6: Full capture record as stored in DB
    save_json(capture, "6_capture_record.json")

    # Stage 7-9: Wait for summarization (takes ~15 min + 70s LLM call)
    print("\n--- Stage 7-9: Summarization ---")
    print("  Summaries run every ~2 min on captures older than 15 min.")
    print("  Checking for any recent summary...")

    summary = get_latest_summary(start_ts - 3600, timeout=10)  # check last hour
    if summary:
        print(f"  Found summary #{summary['id']}")

        # Stage 7: What gets sent to Haiku (reconstruct from captures in chunk)
        capture_ids = json.loads(summary["captureIds"])
        if capture_ids:
            placeholders = ",".join("?" * len(capture_ids))
            chunk_captures = query_db(
                f"SELECT id, datetime(timestamp, 'unixepoch', 'localtime') as time, "
                f"appName, windowTitle, frameType, "
                f"substr(fullOcrText, 1, 500) as text_preview, "
                f"documentPath, browserURL "
                f"FROM captures WHERE id IN ({placeholders})",
                tuple(capture_ids),
            )
            if chunk_captures:
                chunk_text = ""
                for c in chunk_captures:
                    chunk_text += (
                        f"--- {c['frameType'].upper()} ({c['time']}) "
                        f"[{c['appName']} - {c['windowTitle']}] ---\n"
                        f"Doc: {c['documentPath'] or 'None'}\n"
                        f"URL: {c['browserURL'] or 'None'}\n"
                        f"{c['text_preview']}\n\n"
                    )
                save_text(chunk_text, "7_chunk_input.txt")
            else:
                save_text(
                    "(source captures already pruned)", "7_chunk_input.txt"
                )
        else:
            save_text("(no capture IDs in summary)", "7_chunk_input.txt")

        # Stage 8: Haiku response (we can't replay it, but show what was stored)
        haiku_output = {
            "summary": summary["summary"],
            "key_topics": json.loads(summary["keyTopics"] or "[]"),
            "app_names": json.loads(summary["appNames"] or "[]"),
            "document_paths": (
                json.loads(summary["documentPaths"])
                if summary.get("documentPaths")
                else []
            ),
            "browser_urls": (
                json.loads(summary["browserURLs"])
                if summary.get("browserURLs")
                else []
            ),
            "activity_type": summary.get("activityType"),
        }
        save_json(haiku_output, "8_haiku_response.json")

        # Stage 9: Full summary record
        save_json(summary, "9_summary_record.json")
    else:
        save_text(
            "No summary yet -- captures need to be 15+ min old.\n"
            "Run this script again after 15-20 minutes to see stages 7-9.",
            "7_chunk_input.txt",
        )
        print("  No summary yet (captures need to age 15 min).")

    # Stage 10: App session
    print("\n--- Stage 10: App Session ---")
    session = get_latest_session(start_ts - 3600)
    if session:
        save_json(session, "10_session_record.json")
        print(f"  Found session #{session['id']} ({session['appName']})")
    else:
        save_text("No session finalized yet (need app switch).", "10_session_record.txt")
        print("  No session yet (need an app switch to finalize).")

    # Stage 11: Activities
    print("\n--- Stage 11: Activities ---")
    activities = query_db(
        "SELECT * FROM activities ORDER BY id DESC LIMIT 3"
    )
    if activities:
        save_json(activities, "11_activities.json")
    else:
        save_text("No activities inferred yet.", "11_activities.txt")

    # Summary
    print("\n" + "=" * 60)
    print("Pipeline Audit Complete")
    print(f"Output folder: {PROCESS_DIR}")
    print(f"Files generated:")
    for f in sorted(PROCESS_DIR.glob("[0-9]*")):
        size = f.stat().st_size
        print(f"  {f.name:35s} {size:>6,} bytes")
    print("=" * 60)


if __name__ == "__main__":
    main()
