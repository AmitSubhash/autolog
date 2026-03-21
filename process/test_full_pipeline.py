"""Force-run the full pipeline NOW and show every stage output.

Does NOT wait for the 15-min aging window. Grabs recent captures,
formats them exactly as contextd would, calls Haiku, and shows results.
"""
from __future__ import annotations

import json
import sqlite3
import subprocess
import time
from datetime import datetime
from pathlib import Path

DB_PATH = Path.home() / "Library/Application Support/ContextD/contextd.sqlite"
PROCESS_DIR = Path(__file__).parent
PROXY_URL = "http://127.0.0.1:11434/v1/chat/completions"


def query_db(sql: str, params: tuple = ()) -> list[dict]:
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]
    finally:
        conn.close()


def save(data: object, filename: str) -> None:
    path = PROCESS_DIR / filename
    if isinstance(data, str):
        path.write_text(data, encoding="utf-8")
    else:
        path.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")
    print(f"  -> {filename} ({path.stat().st_size:,} bytes)")


def call_haiku(system_prompt: str, user_prompt: str) -> dict:
    """Call Haiku via the claude -p proxy."""
    import urllib.request
    import urllib.error

    body = json.dumps({
        "model": "anthropic/claude-haiku-4-5",
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "max_tokens": 1024,
        "temperature": 0.0,
    }).encode()

    req = urllib.request.Request(
        PROXY_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.URLError as e:
        return {"error": str(e)}


def main() -> None:
    print("=" * 70)
    print("FULL PIPELINE TEST - Forced Haiku Call")
    print(f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 70)

    # Step 1: Screenshot (skip if screencapture not authorized from Terminal)
    print("\n[1] SCREENSHOT")
    try:
        subprocess.run(
            ["screencapture", "-x", "-C", str(PROCESS_DIR / "1_screenshot.png")],
            check=True, capture_output=True,
        )
        save("(see 1_screenshot.png)", "1_screenshot_note.txt")
    except subprocess.CalledProcessError:
        print("  (screencapture not authorized from Terminal -- skipping)")
        print("  contextd captures via its own process, this is fine.")

    # Wait for a couple captures
    print("\n[2] WAITING FOR CAPTURES (20s)...")
    time.sleep(20)

    # Step 3: Get latest captures
    captures = query_db(
        "SELECT * FROM captures ORDER BY timestamp DESC LIMIT 10"
    )
    print(f"\n[3] CAPTURES: {len(captures)} recent")
    if not captures:
        print("  ERROR: No captures found. Is contextd running?")
        return

    for c in captures[:3]:
        ts = datetime.fromtimestamp(c["timestamp"]).strftime("%H:%M:%S")
        print(
            f"  #{c['id']} {ts} {c['appName']} "
            f"({c['frameType']}, {len(c['fullOcrText'] or '')} chars)"
        )

    # Save latest capture details
    latest = captures[0]
    save(latest["fullOcrText"] or "(empty)", "3_ocr_full_screen.txt")

    # Step 4: Metadata
    print("\n[4] METADATA")
    visible = json.loads(latest["visibleWindows"] or "[]")
    metadata = {
        "app": latest["appName"],
        "bundle_id": latest["appBundleID"],
        "window_title": latest["windowTitle"],
        "document_path": latest["documentPath"],
        "browser_url": latest["browserURL"],
        "focused_role": latest["focusedElementRole"],
        "visible_windows": visible,
    }
    save(metadata, "4_metadata.json")
    for w in visible:
        print(f"  {w.get('appName', '?')}: {w.get('windowTitle', '(none)')}")

    # Step 5: Build EXACTLY what gets sent to Haiku
    print("\n[5] BUILDING HAIKU INPUT")

    # Collect data across all captures (simulating a chunk)
    all_ocr = []
    all_doc_paths = set()
    all_urls = set()
    all_windows: dict[str, str] = {}
    for c in captures:
        text = c["fullOcrText"] or ""
        if text:
            ts = datetime.fromtimestamp(c["timestamp"]).strftime("%H:%M:%S")
            all_ocr.append(
                f"--- {c['frameType'].upper()} ({ts}) "
                f"[{c['appName']} - {c['windowTitle'] or 'Unknown'}] ---\n"
                f"{text[:2000]}"
            )
        if c["documentPath"]:
            all_doc_paths.add(c["documentPath"])
        if c["browserURL"]:
            all_urls.add(c["browserURL"])
        for w in json.loads(c["visibleWindows"] or "[]"):
            title = w.get("windowTitle", "")
            if title:
                all_windows[w["appName"]] = title

    ocr_text = "\n\n".join(all_ocr[:5])  # top 5 captures worth
    if len(ocr_text) > 4000:
        ocr_text = ocr_text[:4000] + "\n[...truncated]"

    visible_str = "\n".join(
        f"{k}: {v}" for k, v in sorted(all_windows.items())
    ) or "None"

    first_ts = datetime.fromtimestamp(captures[-1]["timestamp"])
    last_ts = datetime.fromtimestamp(captures[0]["timestamp"])
    duration_s = (last_ts - first_ts).total_seconds()
    duration_str = (
        f"{int(duration_s//60)}m {int(duration_s%60)}s"
        if duration_s >= 60
        else f"{int(duration_s)}s"
    )

    system_prompt = (
        "You summarize computer screen activity captured via OCR. "
        "The screen data includes full-screen OCR text showing everything visible.\n\n"
        "For key_topics, extract ONLY:\n"
        "- Project names, tool/app names (if they are the focus), "
        "concepts being researched, people/organizations, specific technologies\n\n"
        "For activity_type, classify as: coding, research, writing, "
        "communication, design, admin, review, other\n\n"
        "For files_mentioned, extract file paths/names visible on screen.\n"
        "For urls_visited, extract URLs visible on screen.\n\n"
        "Respond ONLY in JSON:\n"
        '{"summary": "...", "key_topics": [...], "activity_type": "...", '
        '"files_mentioned": [...], "urls_visited": [...]}'
    )

    user_prompt = (
        f"Summarize this computer activity segment:\n\n"
        f"Time: {first_ts.strftime('%H:%M:%S')} to {last_ts.strftime('%H:%M:%S')}\n"
        f"Duration: {duration_str}\n"
        f"Focused Application: {latest['appName']}\n"
        f"Window Title: {latest['windowTitle'] or 'Unknown'}\n"
        f"All Visible Windows:\n{visible_str}\n"
        f"Documents Open: {', '.join(sorted(all_doc_paths)) or 'None'}\n"
        f"URLs Visible: {', '.join(sorted(all_urls)) or 'None'}\n\n"
        f"Full screen OCR text (everything visible on screen):\n{ocr_text}"
    )

    save(system_prompt, "5_haiku_system_prompt.txt")
    save(user_prompt, "5_haiku_user_prompt.txt")
    print(f"  System prompt: {len(system_prompt)} chars")
    print(f"  User prompt: {len(user_prompt)} chars")
    print(f"  OCR text in prompt: {len(ocr_text)} chars")

    # Step 6: CALL HAIKU
    print("\n[6] CALLING HAIKU via claude -p proxy...")
    print(f"  Endpoint: {PROXY_URL}")
    start = time.time()
    response = call_haiku(system_prompt, user_prompt)
    elapsed = time.time() - start
    print(f"  Response in {elapsed:.1f}s")

    save(response, "6_haiku_raw_response.json")

    # Extract the text
    if "error" in response:
        print(f"  ERROR: {response['error']}")
        return

    choices = response.get("choices", [])
    if choices:
        text = choices[0].get("message", {}).get("content", "")
        print(f"\n[7] HAIKU OUTPUT ({len(text)} chars):")
        save(text, "7_haiku_output.txt")

        # Try to parse as JSON
        try:
            cleaned = text.strip()
            if cleaned.startswith("```"):
                cleaned = "\n".join(cleaned.split("\n")[1:])
            if cleaned.endswith("```"):
                cleaned = cleaned[:-3]
            parsed = json.loads(cleaned.strip())
            save(parsed, "8_parsed_summary.json")
            print(f"\n  Summary: {parsed.get('summary', '?')}")
            print(f"  Topics: {parsed.get('key_topics', [])}")
            print(f"  Type: {parsed.get('activity_type', '?')}")
            print(f"  Files: {parsed.get('files_mentioned', [])}")
            print(f"  URLs: {parsed.get('urls_visited', [])}")
        except json.JSONDecodeError as e:
            print(f"  JSON parse error: {e}")
            print(f"  Raw: {text[:300]}")
    else:
        print("  No choices in response")

    # Usage stats
    usage = response.get("usage", {})
    if usage:
        inp = usage.get("prompt_tokens", 0)
        out = usage.get("completion_tokens", 0)
        cost = inp / 1e6 * 0.80 + out / 1e6 * 4.00
        print(f"\n  Tokens: {inp} in + {out} out = ${cost:.4f}")

    print("\n" + "=" * 70)
    print(f"All outputs in: {PROCESS_DIR}/")
    for f in sorted(PROCESS_DIR.glob("[0-9]*")):
        print(f"  {f.name}")
    print("=" * 70)


if __name__ == "__main__":
    main()
