#!/usr/bin/env python3
"""Backfill unsummarized captures in autolog using claude -p.

Reads unsummarized captures from the SQLite DB, chunks them using the same
hybrid algorithm as the Swift app (time windows + app boundaries), calls
claude -p for each chunk, and writes summaries back to the DB.
"""

import json
import sqlite3
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

DB_PATH = Path.home() / "Library/Application Support/ContextD/contextd.sqlite"

# Match SummarizationEngine.swift defaults
CHUNK_DURATION = 300  # 5 min
MIN_CHUNK_DURATION = 60  # 1 min
MAX_SAMPLES_PER_CHUNK = 10
MAX_DELTAS_PER_KEYFRAME = 3
MAX_KEYFRAME_TEXT_LEN = 2000
MAX_DELTA_TEXT_LEN = 500
MAX_INPUT_CHARS_PER_CHUNK = 4000
MAX_TOKENS = 1024
MODEL = "haiku"  # claude -p model flag

# --- Prompts (copied from PromptTemplates.swift) ---

SYSTEM_PROMPT = """\
You summarize computer screen activity captured via OCR. The screen data \
is organized as keyframes (full screen snapshots) and deltas (only text \
that changed between snapshots).

For key_topics, REUSE canonical names from this vocabulary when they match:

Projects: Pigbet, AutoLog, 3Brown1Blue, RAS-Optimize, AutoResearchClaw, \
Reallms, Deep Variance, GlazerAI, Thehuzz
Research: Brain-Computer Interface, Neuroimaging, Image Registration, \
Brain Extraction, Preprocessing, Monte Carlo Photon Transport, Diffuse Optical \
Tomography, Piglet Neuroimaging
Tech: Python, Pytorch, Manim, SwiftUI, Vllm, Slurm, Dipy, Emacs, Obsidian, \
Tableau, Docker, React, Next.js
Infra: Hpc, Bigred200, Gpu, Cuda
Career: Job Search, Cv, Portfolio, Professional, Alumni Employment, Hackathon
Meta: Claude Code, Agent Harness, Browser-Use, Knowledge Graph, \
Cross-Domain Analogy, Pipeline, Dashboard
Business: Startup, India Ai, Presentation

If the activity matches one of the above, use that exact name. Only invent a \
new topic name if nothing above fits. New names should be Title Case, 1-3 words, \
and specific (a noun, not a verb or action).

Extract ONLY:
- Project names visible on screen
- Tool/app names ONLY if they are the focus, not just visible \
(e.g., "Obsidian" if configuring it, NOT "Terminal" just because it was open)
- Concepts being researched (e.g., "Monte Carlo Photon Transport", NOT "research")
- People or organizations mentioned
- Specific technologies being used (e.g., "Pytorch", NOT "code editing")

NEVER include:
- Generic descriptions ("Activity Monitoring", "Screen Capture", "Text Editing")
- Variations of a canonical topic (use the canonical name above instead)
- Obvious container apps (Terminal, Chrome, Finder, Safari) unless they are \
the subject of the work
- Action words as topics ("Debugging", "Browsing", "Coding", "Reading")
- Terminal tab names, usernames, or directory names as topics
- The tool "autolog" itself unless the user is actively developing it

For activity_type, classify as exactly ONE of:
- "coding" (writing, debugging, building, testing code)
- "research" (reading docs, browsing Stack Overflow, searching)
- "writing" (drafting text, notes, emails, papers)
- "communication" (Slack, email, messaging, video calls)
- "design" (Figma, visual design, UI work)
- "admin" (system settings, file management, installations)
- "review" (code review, PR review, reading diffs)
- "other" (anything that does not fit the above)

For files_mentioned, extract file paths or filenames visible on screen.
For urls_visited, extract URLs visible in browser address bars or links.

Constraints:
- Summary: 2-3 sentences maximum, under 100 words
- Topics: 2-5 maximum. Prefer fewer, more specific topics over many vague ones
- files_mentioned: actual file paths/names seen, not guesses. Empty array if none.
- urls_visited: actual URLs seen, not guesses. Empty array if none.
- Exclude passwords, personal messages, financial account numbers, and \
other sensitive data from all fields

Respond ONLY in this JSON format (no markdown, no explanation):
{"summary": "...", "key_topics": ["topic1"], "activity_type": "coding", \
"files_mentioned": ["/path/to/file.swift"], "urls_visited": ["https://..."]}"""

USER_TEMPLATE = """\
Summarize this computer activity segment:

Time: {start_time} to {end_time}
Duration: {duration}
Focused Application: {app_name}
Window Title: {window_title}
All Visible Windows: {visible_windows}
Documents Open: {document_paths}
URLs Visible: {browser_urls}

Full screen OCR text (everything visible on screen):
{ocr_samples}"""


# --- Data structures ---

@dataclass
class Capture:
    id: int
    timestamp: float
    app_name: str
    app_bundle_id: Optional[str]
    window_title: Optional[str]
    ocr_text: str
    full_ocr_text: str
    visible_windows: Optional[str]
    text_hash: str
    is_summarized: bool
    frame_type: str
    keyframe_id: Optional[int]
    change_percentage: float
    document_path: Optional[str]
    browser_url: Optional[str]
    focused_element_role: Optional[str]


@dataclass
class Chunk:
    captures: list[Capture]
    start_time: float
    end_time: float

    @property
    def primary_app(self) -> str:
        counts: dict[str, int] = {}
        for c in self.captures:
            counts[c.app_name] = counts.get(c.app_name, 0) + 1
        return max(sorted(counts.keys()), key=lambda k: counts[k])

    @property
    def app_names(self) -> list[str]:
        return sorted(set(c.app_name for c in self.captures))

    @property
    def primary_window_title(self) -> Optional[str]:
        app = self.primary_app
        titles: dict[str, int] = {}
        for c in self.captures:
            if c.app_name == app and c.window_title:
                titles[c.window_title] = titles.get(c.window_title, 0) + 1
        if not titles:
            app_caps = [c for c in self.captures if c.app_name == app]
            return app_caps[-1].window_title if app_caps else None
        return max(sorted(titles.keys()), key=lambda k: titles[k])

    @property
    def capture_ids(self) -> list[int]:
        return [c.id for c in self.captures]


# --- Chunking (mirrors Chunker.swift) ---

def chunk_by_time(
    captures: list[Capture], window_duration: float = 300
) -> list[Chunk]:
    if not captures:
        return []
    chunks: list[Chunk] = []
    current: list[Capture] = []
    window_start = captures[0].timestamp

    for cap in captures:
        if cap.timestamp - window_start >= window_duration and current:
            chunks.append(
                Chunk(current, window_start, current[-1].timestamp)
            )
            current = [cap]
            window_start = cap.timestamp
        else:
            current.append(cap)

    if current:
        chunks.append(Chunk(current, window_start, current[-1].timestamp))
    return chunks


def chunk_by_app_switch(captures: list[Capture]) -> list[Chunk]:
    if not captures:
        return []
    chunks: list[Chunk] = []
    current: list[Capture] = [captures[0]]
    current_app = captures[0].app_name

    for cap in captures[1:]:
        if cap.app_name != current_app:
            chunks.append(
                Chunk(current, current[0].timestamp, current[-1].timestamp)
            )
            current = [cap]
            current_app = cap.app_name
        else:
            current.append(cap)

    if current:
        chunks.append(
            Chunk(current, current[0].timestamp, current[-1].timestamp)
        )
    return chunks


def merge_short_chunks(
    chunks: list[Chunk], min_duration: float
) -> list[Chunk]:
    if not chunks or min_duration <= 0:
        return chunks
    merged = [chunks[0]]
    for chunk in chunks[1:]:
        duration = chunk.end_time - chunk.start_time
        if duration < min_duration and merged:
            prev = merged[-1]
            merged[-1] = Chunk(
                prev.captures + chunk.captures,
                prev.start_time,
                chunk.end_time,
            )
        else:
            merged.append(chunk)
    return merged


def chunk_hybrid(
    captures: list[Capture],
    window_duration: float = CHUNK_DURATION,
    min_chunk_duration: float = MIN_CHUNK_DURATION,
) -> list[Chunk]:
    time_chunks = chunk_by_time(captures, window_duration)
    result: list[Chunk] = []
    for tc in time_chunks:
        sub = chunk_by_app_switch(tc.captures)
        result.extend(merge_short_chunks(sub, min_chunk_duration))
    return result


# --- Formatting (mirrors CaptureFormatter.swift) ---

def evenly_spaced_indices(count: int, max_samples: int) -> list[int]:
    if count <= max_samples:
        return list(range(count))
    step = (count - 1) / (max_samples - 1)
    return [int(i * step) for i in range(max_samples)]


def format_hierarchical(captures: list[Capture]) -> str:
    """Format captures into hierarchical keyframe+delta text."""
    sorted_caps = sorted(captures, key=lambda c: c.timestamp)
    if not sorted_caps:
        return ""

    # Group into keyframe groups
    groups: list[tuple[Capture, list[Capture]]] = []
    current_kf: Optional[Capture] = None
    current_deltas: list[Capture] = []

    for cap in sorted_caps:
        if cap.frame_type == "keyframe":
            if current_kf is not None:
                groups.append((current_kf, current_deltas))
            current_kf = cap
            current_deltas = []
        else:
            if current_kf is not None:
                current_deltas.append(cap)
            else:
                groups.append((cap, []))

    if current_kf is not None:
        groups.append((current_kf, current_deltas))

    # Sample keyframe groups
    if len(groups) > MAX_SAMPLES_PER_CHUNK:
        indices = evenly_spaced_indices(len(groups), MAX_SAMPLES_PER_CHUNK)
        groups = [groups[i] for i in indices]

    sections: list[str] = []
    for kf, deltas in groups:
        ts = datetime.fromtimestamp(kf.timestamp).strftime("%H:%M:%S")
        app = kf.app_name
        window = kf.window_title or "Unknown"
        text = kf.ocr_text[:MAX_KEYFRAME_TEXT_LEN]
        if len(kf.ocr_text) > MAX_KEYFRAME_TEXT_LEN:
            text += "..."
        sections.append(f"--- Keyframe ({ts}) [{app} - {window}] ---\n{text}")

        if not deltas:
            continue
        if len(deltas) > MAX_DELTAS_PER_KEYFRAME:
            indices = evenly_spaced_indices(
                len(deltas), MAX_DELTAS_PER_KEYFRAME
            )
            deltas = [deltas[i] for i in indices]

        for d in deltas:
            dts = datetime.fromtimestamp(d.timestamp).strftime("%H:%M:%S")
            pct = int(d.change_percentage * 100)
            dtxt = d.ocr_text[:MAX_DELTA_TEXT_LEN]
            if len(d.ocr_text) > MAX_DELTA_TEXT_LEN:
                dtxt += "..."
            if dtxt:
                sections.append(
                    f"--- Delta ({dts}) [{pct}% changed] ---\n{dtxt}"
                )

    return "\n\n".join(sections)


# --- Visible windows decoding ---

def decode_visible_windows(json_str: Optional[str]) -> list[dict]:
    if not json_str:
        return []
    try:
        return json.loads(json_str)
    except (json.JSONDecodeError, TypeError):
        return []


# --- LLM call via claude -p ---

def call_claude_p(system_prompt: str, user_prompt: str) -> str:
    """Call claude -p (pipe mode) and return the response text."""
    full_prompt = f"{user_prompt}"
    result = subprocess.run(
        [
            "claude", "-p",
            "--model", MODEL,
            "--system-prompt", system_prompt,
            "--max-turns", "1",
        ],
        input=full_prompt,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"claude -p failed (rc={result.returncode}): {result.stderr[:500]}"
        )
    return result.stdout.strip()


def parse_summary_response(response: str) -> dict:
    """Parse LLM JSON response, stripping code fences if present."""
    cleaned = response.strip()
    if cleaned.startswith("```"):
        first_nl = cleaned.find("\n")
        if first_nl >= 0:
            cleaned = cleaned[first_nl + 1:]
    if cleaned.endswith("```"):
        cleaned = cleaned[:-3]
    cleaned = cleaned.strip()

    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        print(f"  WARNING: Failed to parse JSON, using raw text")
        return {
            "summary": response[:200],
            "key_topics": [],
            "activity_type": "other",
            "files_mentioned": [],
            "urls_visited": [],
        }


# --- DB operations ---

def fetch_unsummarized(conn: sqlite3.Connection) -> list[Capture]:
    cur = conn.execute(
        """SELECT id, timestamp, appName, appBundleID, windowTitle,
                  ocrText, fullOcrText, visibleWindows, textHash,
                  isSummarized, frameType, keyframeId, changePercentage,
                  documentPath, browserURL, focusedElementRole
           FROM captures
           WHERE isSummarized = 0
           ORDER BY timestamp ASC"""
    )
    return [
        Capture(
            id=row[0],
            timestamp=row[1],
            app_name=row[2],
            app_bundle_id=row[3],
            window_title=row[4],
            ocr_text=row[5],
            full_ocr_text=row[6],
            visible_windows=row[7],
            text_hash=row[8],
            is_summarized=bool(row[9]),
            frame_type=row[10],
            keyframe_id=row[11],
            change_percentage=row[12],
            document_path=row[13],
            browser_url=row[14],
            focused_element_role=row[15],
        )
        for row in cur.fetchall()
    ]


def insert_summary(
    conn: sqlite3.Connection,
    chunk: Chunk,
    parsed: dict,
) -> int:
    """Insert a summary record and mark captures as summarized."""
    doc_paths_from_caps = list(
        set(c.document_path for c in chunk.captures if c.document_path)
    )
    urls_from_caps = list(
        set(c.browser_url for c in chunk.captures if c.browser_url)
    )
    all_doc_paths = list(
        set(doc_paths_from_caps) | set(parsed.get("files_mentioned", []))
    )
    all_urls = list(
        set(urls_from_caps) | set(parsed.get("urls_visited", []))
    )

    cur = conn.execute(
        """INSERT INTO summaries
           (startTimestamp, endTimestamp, appNames, summary, keyTopics,
            captureIds, documentPaths, browserURLs, activityType)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            chunk.start_time,
            chunk.end_time,
            json.dumps(chunk.app_names),
            parsed.get("summary", ""),
            json.dumps(parsed.get("key_topics", [])),
            json.dumps(chunk.capture_ids),
            json.dumps(all_doc_paths) if all_doc_paths else None,
            json.dumps(all_urls) if all_urls else None,
            parsed.get("activity_type"),
        ),
    )
    summary_id = cur.lastrowid

    # Mark captures as summarized
    placeholders = ",".join("?" for _ in chunk.capture_ids)
    conn.execute(
        f"UPDATE captures SET isSummarized = 1 WHERE id IN ({placeholders})",
        chunk.capture_ids,
    )

    conn.commit()
    return summary_id


# --- Main ---

def main() -> None:
    if not DB_PATH.exists():
        print(f"ERROR: DB not found at {DB_PATH}")
        sys.exit(1)

    conn = sqlite3.connect(str(DB_PATH))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")

    captures = fetch_unsummarized(conn)
    if not captures:
        print("No unsummarized captures found.")
        return

    print(f"Found {len(captures)} unsummarized captures")
    start_dt = datetime.fromtimestamp(captures[0].timestamp)
    end_dt = datetime.fromtimestamp(captures[-1].timestamp)
    print(f"Time range: {start_dt:%H:%M} - {end_dt:%H:%M}")

    chunks = chunk_hybrid(captures)
    print(f"Created {len(chunks)} chunks to summarize")
    print()

    success = 0
    failed = 0

    for i, chunk in enumerate(chunks):
        start_str = datetime.fromtimestamp(chunk.start_time).strftime("%H:%M")
        end_str = datetime.fromtimestamp(chunk.end_time).strftime("%H:%M")
        duration = chunk.end_time - chunk.start_time
        dur_str = (
            f"{int(duration)}s"
            if duration < 60
            else f"{int(duration // 60)}m {int(duration % 60)}s"
        )

        print(
            f"[{i+1}/{len(chunks)}] {start_str}-{end_str} "
            f"({dur_str}, {len(chunk.captures)} caps, {chunk.primary_app})"
        )

        # Format OCR samples
        ocr_samples = format_hierarchical(chunk.captures)
        if len(ocr_samples) > MAX_INPUT_CHARS_PER_CHUNK:
            ocr_samples = ocr_samples[:MAX_INPUT_CHARS_PER_CHUNK] + "\n[...truncated]"

        # Collect visible windows
        all_windows: dict[str, str] = {}
        for cap in chunk.captures:
            for w in decode_visible_windows(cap.visible_windows):
                app = w.get("appName", w.get("app_name", ""))
                title = w.get("windowTitle", w.get("window_title", ""))
                if title:
                    all_windows[app] = title
                elif app not in all_windows:
                    all_windows[app] = "(no title)"
        visible_str = (
            "\n".join(f"{k}: {v}" for k, v in sorted(all_windows.items()))
            if all_windows
            else "None"
        )

        doc_paths = sorted(
            set(c.document_path for c in chunk.captures if c.document_path)
        )
        urls = sorted(
            set(c.browser_url for c in chunk.captures if c.browser_url)
        )

        user_prompt = USER_TEMPLATE.format(
            start_time=datetime.fromtimestamp(chunk.start_time).strftime(
                "%H:%M:%S"
            ),
            end_time=datetime.fromtimestamp(chunk.end_time).strftime(
                "%H:%M:%S"
            ),
            duration=dur_str,
            app_name=chunk.primary_app,
            window_title=chunk.primary_window_title or "Unknown",
            visible_windows=visible_str,
            document_paths=", ".join(doc_paths) if doc_paths else "None",
            browser_urls=", ".join(urls) if urls else "None",
            ocr_samples=ocr_samples,
        )

        try:
            response = call_claude_p(SYSTEM_PROMPT, user_prompt)
            parsed = parse_summary_response(response)
            summary_id = insert_summary(conn, chunk, parsed)
            summary_preview = parsed.get("summary", "")[:80]
            topics = parsed.get("key_topics", [])
            print(f"  -> #{summary_id}: {summary_preview}")
            print(f"     Topics: {topics}")
            success += 1
        except Exception as e:
            print(f"  ERROR: {e}")
            failed += 1

    conn.close()
    print()
    print(f"Done. {success} summarized, {failed} failed.")


if __name__ == "__main__":
    main()
