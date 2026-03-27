"""Focus block state management for AutoLog.

This module provides a small file-based contract between Emacs and AutoLog.
Emacs owns the user's declared intent and writes the current block to
``~/.config/autolog/focus-state.json``. Completed blocks are appended to
``~/.config/autolog/focus-blocks.jsonl`` so the app and vault sync can bind
captured activity back to a declared task.
"""
from __future__ import annotations

import argparse
import json
import sys
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

FOCUS_DIR = Path.home() / ".config" / "autolog"
CURRENT_STATE_PATH = FOCUS_DIR / "focus-state.json"
BLOCKS_LOG_PATH = FOCUS_DIR / "focus-blocks.jsonl"
DEFAULT_SCORECARD_PATH = Path.home() / "org" / "autolog-scorecard.org"


def _ensure_focus_dir() -> None:
    FOCUS_DIR.mkdir(parents=True, exist_ok=True)


def _now_iso() -> str:
    return datetime.now().replace(microsecond=0).isoformat()


def _parse_iso(timestamp: str | None) -> datetime | None:
    if not timestamp:
        return None
    try:
        return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return None


def _slugify(text: str) -> str:
    chars = []
    prev_dash = False
    for char in text.lower().strip():
        if char.isalnum():
            chars.append(char)
            prev_dash = False
        elif not prev_dash:
            chars.append("-")
            prev_dash = True
    return "".join(chars).strip("-") or "focus-block"


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    _ensure_focus_dir()
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def load_current_focus_state() -> dict[str, Any] | None:
    """Read the current focus state from disk."""
    return _read_json(CURRENT_STATE_PATH)


def load_focus_blocks(include_open: bool = False) -> list[dict[str, Any]]:
    """Read completed focus blocks from disk.

    Parameters
    ----------
    include_open : bool, optional
        When true, include the currently open block as an in-progress block.
    """
    blocks: list[dict[str, Any]] = []
    try:
        lines = BLOCKS_LOG_PATH.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []

    for line in lines:
        if not line.strip():
            continue
        try:
            block = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(block, dict):
            blocks.append(block)

    if include_open:
        current = load_current_focus_state()
        if current:
            open_block = dict(current)
            open_block.setdefault("status", "active")
            open_block.setdefault("ended_at", None)
            blocks.append(open_block)

    return sorted(blocks, key=lambda item: item.get("started_at", ""), reverse=True)


def best_matching_focus_block(
    start_timestamp: str,
    end_timestamp: str,
    blocks: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """Return the focus block with the greatest time overlap."""
    act_start = _parse_iso(start_timestamp)
    act_end = _parse_iso(end_timestamp)
    if not act_start or not act_end:
        return None

    best_block: dict[str, Any] | None = None
    best_overlap = 0.0
    for block in blocks:
        block_start = _parse_iso(block.get("started_at"))
        block_end = _parse_iso(block.get("ended_at")) or datetime.now()
        if not block_start:
            continue
        overlap_start = max(act_start, block_start)
        overlap_end = min(act_end, block_end)
        overlap_seconds = (overlap_end - overlap_start).total_seconds()
        if overlap_seconds > best_overlap:
            best_overlap = overlap_seconds
            best_block = block
    return best_block if best_overlap > 0 else None


def focus_block_note_name(block: dict[str, Any]) -> str:
    """Build a stable note name for a focus block."""
    started = (_parse_iso(block.get("started_at")) or datetime.now()).strftime("%Y-%m-%d_%H-%M")
    slug = block.get("task_slug") or _slugify(block.get("task", "focus-block"))
    return f"{started}_{slug}"


def block_duration_minutes(block: dict[str, Any]) -> int:
    """Return rounded duration in minutes for a block."""
    started = _parse_iso(block.get("started_at"))
    ended = _parse_iso(block.get("ended_at")) or datetime.now()
    if not started:
        return 0
    return max(0, int(round((ended - started).total_seconds() / 60)))


def _format_minutes(total_minutes: int) -> str:
    hours, minutes = divmod(max(0, total_minutes), 60)
    return f"{hours}h {minutes:02d}m" if hours else f"{minutes}m"


def _truncate(text: str, width: int) -> str:
    if len(text) <= width:
        return text
    if width <= 1:
        return text[:width]
    return text[: width - 1] + "…"


def _ensure_scorecard_file(path: Path) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#+title: AutoLog Scorecard\n\n* Inbox Reviews\n", encoding="utf-8")


def append_scorecard_entry(block: dict[str, Any]) -> Path:
    """Append a compact Org review entry for a completed block."""
    target = Path(block.get("scorecard_path") or DEFAULT_SCORECARD_PATH).expanduser()
    _ensure_scorecard_file(target)

    started = _parse_iso(block.get("started_at")) or datetime.now()
    ended = _parse_iso(block.get("ended_at")) or datetime.now()
    duration_minutes = block_duration_minutes(block)
    title = started.strftime("%Y-%m-%d %H:%M")
    notes = block.get("notes", "").strip()
    artifact_goal = block.get("artifact_goal", "").strip()
    artifact = block.get("artifact", "").strip()
    done_when = block.get("done_when", "").strip()
    score = block.get("score")

    entry_lines = [
        "",
        f"** [{title}] {block.get('task', 'Focus Block')}",
        f"- Status :: {block.get('status', 'completed')}",
        f"- Started :: {started.isoformat(timespec='seconds')}",
        f"- Ended :: {ended.isoformat(timespec='seconds')}",
        f"- Duration :: {_format_minutes(duration_minutes)}",
    ]
    if done_when:
        entry_lines.append(f"- Done when :: {done_when}")
    if artifact_goal:
        entry_lines.append(f"- Planned artifact :: {artifact_goal}")
    entry_lines.append(f"- Actual artifact :: {artifact or '-'}")
    entry_lines.append(f"- Focus score /10 :: {score if score is not None else '-'}")
    entry_lines.append(f"- Notes :: {notes or '-'}")
    target.write_text(target.read_text(encoding="utf-8") + "\n".join(entry_lines) + "\n", encoding="utf-8")
    return target


def render_recent_blocks(limit: int = 12, include_open: bool = True) -> str:
    """Render a readable list of recent focus blocks."""
    blocks = load_focus_blocks(include_open=include_open)[: max(1, limit)]
    lines = ["Recent Focus Blocks", ""]
    if not blocks:
        lines.append("No focus blocks yet.")
        return "\n".join(lines)

    header = f"{'Status':<12} {'Start':<16} {'Min':>5} {'Score':>5}  Task"
    lines.append(header)
    lines.append("-" * len(header))
    for block in blocks:
        started = _parse_iso(block.get("started_at"))
        start_label = started.strftime("%m-%d %H:%M") if started else "unknown"
        score = "-" if block.get("score") is None else str(block["score"])
        lines.append(
            f"{_truncate(str(block.get('status', 'completed')), 12):<12} "
            f"{start_label:<16} "
            f"{block_duration_minutes(block):>5} "
            f"{score:>5}  "
            f"{_truncate(str(block.get('task', 'Focus Block')), 70)}"
        )
    return "\n".join(lines)


def _compute_streak(dates: set[str]) -> int:
    streak = 0
    cursor = datetime.now().date()
    while cursor.isoformat() in dates:
        streak += 1
        cursor -= timedelta(days=1)
    return streak


def compute_productivity_summary(days: int = 7) -> dict[str, Any]:
    """Compute simple productivity metrics from recent focus blocks."""
    cutoff = datetime.now() - timedelta(days=max(1, days))
    blocks = [
        block
        for block in load_focus_blocks(include_open=False)
        if (_parse_iso(block.get("started_at")) or datetime.min) >= cutoff
    ]
    completed = [block for block in blocks if block.get("status") == "completed"]
    interrupted = [block for block in blocks if block.get("status") == "interrupted"]
    abandoned = [block for block in blocks if block.get("status") == "abandoned"]
    total_minutes = sum(block_duration_minutes(block) for block in blocks)
    completed_minutes = sum(block_duration_minutes(block) for block in completed)
    scored = [int(block["score"]) for block in blocks if isinstance(block.get("score"), int)]
    artifacts = [block for block in blocks if str(block.get("artifact", "")).strip()]
    deep_blocks = [block for block in completed if block_duration_minutes(block) >= 60]

    per_day: dict[str, dict[str, Any]] = {}
    completed_days: set[str] = set()
    for block in blocks:
        started = _parse_iso(block.get("started_at"))
        if not started:
            continue
        date_key = started.date().isoformat()
        entry = per_day.setdefault(
            date_key,
            {"blocks": 0, "completed": 0, "minutes": 0, "scores": []},
        )
        entry["blocks"] += 1
        entry["minutes"] += block_duration_minutes(block)
        if block.get("status") == "completed":
            entry["completed"] += 1
            completed_days.add(date_key)
        if isinstance(block.get("score"), int):
            entry["scores"].append(int(block["score"]))

    daily_breakdown = []
    for date_key in sorted(per_day.keys(), reverse=True):
        entry = per_day[date_key]
        scores = entry.pop("scores")
        entry["date"] = date_key
        entry["avg_score"] = round(sum(scores) / len(scores), 1) if scores else None
        daily_breakdown.append(entry)

    total_blocks = len(blocks)
    completion_rate = round((len(completed) / total_blocks) * 100, 1) if total_blocks else 0.0
    artifact_rate = round((len(artifacts) / total_blocks) * 100, 1) if total_blocks else 0.0
    average_score = round(sum(scored) / len(scored), 1) if scored else None
    average_block_minutes = round(total_minutes / total_blocks, 1) if total_blocks else 0.0
    return {
        "days": max(1, days),
        "total_blocks": total_blocks,
        "completed_blocks": len(completed),
        "interrupted_blocks": len(interrupted),
        "abandoned_blocks": len(abandoned),
        "completion_rate": completion_rate,
        "artifact_rate": artifact_rate,
        "total_minutes": total_minutes,
        "completed_minutes": completed_minutes,
        "average_block_minutes": average_block_minutes,
        "average_score": average_score,
        "deep_blocks": len(deep_blocks),
        "streak_days": _compute_streak(completed_days),
        "daily_breakdown": daily_breakdown,
    }


def render_productivity_summary(days: int = 7) -> str:
    """Render a readable productivity summary."""
    summary = compute_productivity_summary(days=days)
    lines = [
        f"Productivity Summary ({summary['days']}d)",
        "",
        (
            f"Blocks: {summary['total_blocks']} total | "
            f"{summary['completed_blocks']} completed | "
            f"{summary['interrupted_blocks']} interrupted | "
            f"{summary['abandoned_blocks']} abandoned"
        ),
        f"Completion rate: {summary['completion_rate']}%",
        f"Artifact rate: {summary['artifact_rate']}%",
        (
            f"Focus time: {_format_minutes(summary['total_minutes'])} total | "
            f"{_format_minutes(summary['completed_minutes'])} completed"
        ),
        f"Average block: {_format_minutes(int(round(summary['average_block_minutes'])))}",
        f"Deep blocks (>=60m): {summary['deep_blocks']}",
        (
            "Average self-score: "
            f"{summary['average_score']}/10" if summary["average_score"] is not None else
            "Average self-score: -"
        ),
        f"Completed-day streak: {summary['streak_days']}",
        "",
        "Daily breakdown",
    ]
    if not summary["daily_breakdown"]:
        lines.append("No completed focus history yet.")
        return "\n".join(lines)

    for entry in summary["daily_breakdown"]:
        score = "-" if entry["avg_score"] is None else f"{entry['avg_score']}/10"
        lines.append(
            f"{entry['date']}  "
            f"{entry['blocks']} blocks  "
            f"{entry['completed']} completed  "
            f"{_format_minutes(entry['minutes'])}  "
            f"avg {score}"
        )
    return "\n".join(lines)


def start_focus_block(
    task: str,
    done_when: str = "",
    artifact_goal: str = "",
    drift_budget_minutes: int = 10,
    source: str = "emacs-org",
    scorecard_path: str = "",
) -> dict[str, Any]:
    """Create or replace the current focus block state."""
    task = task.strip()
    if not task:
        raise ValueError("task must be non-empty")

    current = load_current_focus_state()
    if current:
        stop_focus_block(status="interrupted")

    payload = {
        "id": f"{datetime.now().strftime('%Y%m%dT%H%M%S')}_{uuid.uuid4().hex[:8]}",
        "task": task,
        "task_slug": _slugify(task),
        "started_at": _now_iso(),
        "done_when": done_when.strip(),
        "artifact_goal": artifact_goal.strip(),
        "artifact": "",
        "drift_budget_minutes": max(1, drift_budget_minutes),
        "source": source,
        "scorecard_path": scorecard_path.strip() or str(DEFAULT_SCORECARD_PATH),
        "status": "active",
    }
    _write_json(CURRENT_STATE_PATH, payload)
    return payload


def stop_focus_block(
    artifact: str = "",
    score: int | None = None,
    notes: str = "",
    status: str = "completed",
) -> dict[str, Any] | None:
    """Finalize the current focus block and append it to the log."""
    current = load_current_focus_state()
    if not current:
        return None

    ended = dict(current)
    ended["ended_at"] = _now_iso()
    ended["artifact"] = artifact.strip() or current.get("artifact", "")
    ended["score"] = score
    ended["notes"] = notes.strip()
    ended["status"] = status

    _ensure_focus_dir()
    with BLOCKS_LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(ended, sort_keys=True) + "\n")
    append_scorecard_entry(ended)

    try:
        CURRENT_STATE_PATH.unlink()
    except OSError:
        pass
    return ended


def build_scorecard_template(date_str: str | None = None) -> str:
    """Return a compact Org-mode scorecard template."""
    date_str = date_str or datetime.now().strftime("%Y-%m-%d")
    return (
        f"* {date_str}\n"
        ":PROPERTIES:\n"
        f":CREATED: {_now_iso()}\n"
        ":END:\n\n"
        "** Block Review\n"
        "- Planned task :: \n"
        "- Actual artifact :: \n"
        "- Drift minutes :: \n"
        "- Focus score /10 :: \n"
        "- What caused drift :: \n"
        "- What to repeat tomorrow :: \n"
    )


def write_scorecard(path: str = "", date_str: str | None = None) -> Path:
    """Create today's scorecard file if it does not already exist."""
    target = Path(path).expanduser() if path else DEFAULT_SCORECARD_PATH
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        target.write_text(build_scorecard_template(date_str), encoding="utf-8")
    return target


def _cmd_start(args: argparse.Namespace) -> int:
    payload = start_focus_block(
        task=args.task,
        done_when=args.done_when,
        artifact_goal=args.artifact_goal,
        drift_budget_minutes=args.drift_budget,
        source=args.source,
        scorecard_path=args.scorecard_path,
    )
    print(json.dumps(payload, indent=2))
    return 0


def _cmd_stop(args: argparse.Namespace) -> int:
    payload = stop_focus_block(
        artifact=args.artifact,
        score=args.score,
        notes=args.notes,
        status=args.status,
    )
    if payload is None:
        print("No active focus block.", file=sys.stderr)
        return 1
    print(json.dumps(payload, indent=2))
    return 0


def _cmd_status(_: argparse.Namespace) -> int:
    payload = load_current_focus_state()
    if payload is None:
        print("{}")
        return 0
    print(json.dumps(payload, indent=2))
    return 0


def _cmd_scorecard(args: argparse.Namespace) -> int:
    path = write_scorecard(path=args.path, date_str=args.date)
    print(str(path))
    return 0


def _cmd_list(args: argparse.Namespace) -> int:
    print(render_recent_blocks(limit=args.limit, include_open=args.include_open))
    return 0


def _cmd_productivity(args: argparse.Namespace) -> int:
    print(render_productivity_summary(days=args.days))
    return 0


def build_parser() -> argparse.ArgumentParser:
    """Create the CLI parser."""
    parser = argparse.ArgumentParser(description="Manage AutoLog focus blocks.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    start = subparsers.add_parser("start", help="Start a new focus block.")
    start.add_argument("--task", required=True)
    start.add_argument("--done-when", default="")
    start.add_argument("--artifact-goal", default="")
    start.add_argument("--drift-budget", type=int, default=10)
    start.add_argument("--source", default="emacs-org")
    start.add_argument("--scorecard-path", default="")
    start.set_defaults(func=_cmd_start)

    stop = subparsers.add_parser("stop", help="Stop the current focus block.")
    stop.add_argument("--artifact", default="")
    stop.add_argument("--score", type=int)
    stop.add_argument("--notes", default="")
    stop.add_argument(
        "--status",
        choices=["completed", "interrupted", "abandoned"],
        default="completed",
    )
    stop.set_defaults(func=_cmd_stop)

    status = subparsers.add_parser("status", help="Print the current focus block.")
    status.set_defaults(func=_cmd_status)

    scorecard = subparsers.add_parser("scorecard", help="Create today's scorecard file.")
    scorecard.add_argument("--path", default="")
    scorecard.add_argument("--date", default="")
    scorecard.set_defaults(func=_cmd_scorecard)

    list_cmd = subparsers.add_parser("list", help="Show recent focus blocks.")
    list_cmd.add_argument("--limit", type=int, default=12)
    list_cmd.add_argument("--include-open", action="store_true")
    list_cmd.set_defaults(func=_cmd_list)

    productivity = subparsers.add_parser("productivity", help="Show recent productivity summary.")
    productivity.add_argument("--days", type=int, default=7)
    productivity.set_defaults(func=_cmd_productivity)

    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point for the focus-state CLI."""
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
