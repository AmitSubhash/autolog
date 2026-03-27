"""Formatting helpers for the autolog Obsidian sync.

Pure functions for slugifying names, formatting durations, and building
Markdown content for Activity, App, Topic, and Daily notes.

Includes topic normalization to merge near-duplicate topic names and
noise filtering to skip terminal metadata entities.
"""
from __future__ import annotations

import re
from datetime import datetime

# ── Topic normalization ────────────────────────────────────────────────
# Maps variant (lowercase) -> canonical Title Case name.
_TOPIC_CANON: dict[str, str] = {
    # BCI
    "brain-computer interfaces": "Brain-Computer Interface",
    "bci": "Brain-Computer Interface",
    "neural interfaces": "Brain-Computer Interface",
    "braingate2": "Brain-Computer Interface",
    # File organization
    "file-organization": "File Organization",
    "file browsing": "File Organization",
    "file management": "File Organization",
    "file_navigation": "File Organization",
    # PDF
    "pdf-files": "Pdf Files",
    "pdfs": "Pdf Files",
    "final_pdfs": "Pdf Files",
    # Development
    "developer tools": "Development Tools",
    "development": "Development Tools",
    "development environment": "Development Tools",
    "macos development": "Development Tools",
    "development planning": "Development Tools",
    "development setup": "Development Tools",
    "development tools setup": "Development Tools",
    "development workflow": "Development Tools",
    # Email
    "email management": "Email",
    # CV
    "cv review": "Cv",
    "career files": "Cv",
    # Python
    "python development": "Python",
    "python automation": "Python",
    "python code review": "Python",
    "python debugging": "Python",
    "python execution": "Python",
    "python implementation": "Python",
    "python setup": "Python",
    "python utilities": "Python",
    "python-tooling": "Python",
    "type hints": "Python",
    # Bun
    "bun runtime": "Bun",
    # Professional
    "professional networking": "Professional",
    "professional profile": "Professional",
    "profile viewing": "Professional",
    "personal branding": "Professional",
    # Terminal
    "terminal_work": "Terminal",
    "terminal commands": "Terminal",
    "terminal_commands": "Terminal",
    "terminal_workflow": "Terminal",
    "terminal-work": "Terminal",
    "terminal work": "Terminal",
    "terminal setup": "Terminal",
    "terminal testing": "Terminal",
    "terminal development": "Terminal",
    "command execution": "Terminal",
    "command-execution": "Terminal",
    "command-line": "Terminal",
    "command-line execution": "Terminal",
    "shell commands": "Terminal",
    "script execution": "Terminal",
    "script_execution": "Terminal",
    # Code
    "code editor": "Code",
    "code quality": "Code",
    "code refactoring": "Code",
    "code editing": "Code",
    "code_editing": "Code",
    "code-search": "Code",
    "coding": "Code",
    "editing": "Code",
    "file editing": "Code",
    "refactoring": "Code",
    # Database
    "database debugging": "Database",
    "database enrichment": "Database",
    # AutoLog
    "contextd debugging": "AutoLog",
    "autolog": "AutoLog",
    "autolog vault": "AutoLog",
    "autolog-vault": "AutoLog",
    "mirrorlog": "AutoLog",
    "activity capture": "AutoLog",
    "activity logging": "AutoLog",
    "screenshot capture": "AutoLog",
    "context capture": "AutoLog",
    "menu bar app": "AutoLog",
    # Projects
    "personal projects": "Projects",
    "project files": "Projects",
    # Portfolio
    "github portfolio": "Portfolio",
    "portfolio development": "Portfolio",
    # Search
    "web_lookup": "Search",
    "web browsing": "Search",
    "web-search": "Search",
    # HPC
    "hpc agent project": "Hpc",
    "hpc cluster": "Hpc",
    "hpc debugging": "Hpc",
    "hpc deployment": "Hpc",
    "hpc_llm module": "Hpc",
    "bigred200 hpc": "Bigred200",
    # GPU
    "gpu access": "Gpu",
    "gpu clusters": "Gpu",
    "gpu cost optimization": "Gpu",
    "gpu hardware": "Gpu",
    "gpu infrastructure": "Gpu",
    "gpu memory optimization": "Gpu",
    "gpu pricing": "Gpu",
    "gpu testing": "Gpu",
    "gpu verification": "Gpu",
    "nvidia a100": "Gpu",
    "nvidia-smi": "Gpu",
    "nvlink topology": "Gpu",
    "a100 gpu": "Gpu",
    # Documentation
    "vault documentation": "Documentation",
    "documentation lookup": "Documentation",
    "toolkit documentation": "Documentation",
    # Scripting
    "scripting": "Development Tools",
    # System
    "system utilities": "System",
    "process monitoring": "System",
    "system monitoring": "System",
    "system overheating troubleshooting": "System",
    "system thermal diagnostics": "System",
    "system thermal management": "System",
    # JS
    "javascript-typescript": "Javascript Runtime",
    # Manim
    "manim-skill": "Manim",
    "manim visualization": "Manim",
    # Cross-domain
    "cross-domain-analogy": "Cross-Domain Analogy",
    "cross-domain analogy discovery": "Cross-Domain Analogy",
    "analogy discovery pipeline": "Cross-Domain Analogy",
    # Github
    "github pr review": "Github",
    "github profile audit": "Github",
    "github repositories": "Github",
    "github repository": "Github",
    "github review": "Github",
    "github sign-in": "Github",
    "repository setup": "Github",
    "repository updates": "Github",
    "git commit": "Github",
    "git initialization": "Github",
    "git staging": "Github",
    "pr review": "Github",
    # Browser-use
    "browser-use framework": "Browser-Use",
    "browser-use setup": "Browser-Use",
    "browser automation": "Browser-Use",
    "browser testing": "Browser-Use",
    "browser verification": "Browser-Use",
    "browser-reference": "Browser-Use",
    "browsing": "Browser-Use",
    # Claude Code
    "claude code integration": "Claude Code",
    "claude code setup": "Claude Code",
    "claude configuration": "Claude Code",
    "claude-code": "Claude Code",
    # CLI
    "cli authentication": "Cli",
    "cli design": "Cli",
    "cli implementation": "Cli",
    "cli interface": "Cli",
    "cli testing": "Cli",
    # Feedback memory
    "feedback-memory": "Feedback Memory",
    "memory setup": "Feedback Memory",
    # Pigbet
    "pigbet brain extraction": "Pigbet",
    "pigbet pipeline": "Pigbet",
    "pigbet-inference-pipeline": "Pigbet",
    "pig brain mri": "Pigbet",
    # Knowledge graph
    "knowledge graphs": "Knowledge Graph",
    "graph analysis": "Knowledge Graph",
    "graph domain matching": "Knowledge Graph",
    "graph motif detection": "Knowledge Graph",
    "semantic matching": "Knowledge Graph",
    # vLLM
    "vllm configuration": "Vllm",
    "vllm server": "Vllm",
    "vllm serving": "Vllm",
    # SLURM
    "slurm job management": "Slurm",
    "slurm job submission": "Slurm",
    "slurm job timeout": "Slurm",
    "job timeout debugging": "Slurm",
    "job dependency failure": "Slurm",
    # PyTorch
    "pytorch inference": "Pytorch",
    "distributed training": "Pytorch",
    # Explainer video
    "explainer videos": "Explainer Video",
    "animated videos": "Explainer Video",
    "educational video": "Explainer Video",
    "educational content generation": "Explainer Video",
    "video rendering": "Explainer Video",
    "video pipeline": "Explainer Video",
    "batch rendering": "Explainer Video",
    # Package management
    "package dependencies": "Package Management",
    "package distribution": "Package Management",
    "package releases": "Package Management",
    "packages": "Package Management",
    "version management": "Package Management",
    # Testing
    "application testing": "Testing",
    "feature testing": "Testing",
    "gui testing": "Testing",
    "local testing": "Testing",
    "unit testing": "Testing",
    "result verification": "Testing",
    "output verification": "Testing",
    # Setup
    "environment setup": "Setup",
    "setup": "Setup",
    "project setup": "Setup",
    "project-setup": "Setup",
    # Security
    "security hardening": "Security",
    "code signing": "Security",
    "macos permissions": "Security",
    # Job search
    "job applications": "Job Search",
    "job board extraction": "Job Search",
    "job description scraping": "Job Search",
    "job-craft": "Job Search",
    "cover letters": "Job Search",
    "resume generation": "Job Search",
    "resume tailoring": "Job Search",
    "resume tool": "Job Search",
    "resume-tailoring": "Job Search",
    # Image registration
    "nifti affine transformations": "Image Registration",
    "nifti processing": "Image Registration",
    "brain image registration": "Image Registration",
    "voxel alignment": "Image Registration",
    "voxel-space registration": "Image Registration",
    "image orientation": "Image Registration",
    "orientation detection": "Image Registration",
    "axis flipping": "Image Registration",
    # India AI
    "india ai": "India Ai",
    "indiaai innovation challenge": "India Ai",
    "indiaai mission": "India Ai",
    "indian ai funding": "India Ai",
    "indian ai startups": "India Ai",
    "ai funding": "India Ai",
    # Startup
    "market opportunity": "Startup",
    "market traction": "Startup",
    "traction metrics": "Startup",
    "monetization": "Startup",
    "budget": "Startup",
    "budget planning": "Startup",
    "budget spreadsheet": "Startup",
    "kpi metrics": "Startup",
    "kpi sheets": "Startup",
    # Dipy
    "dipy algorithms": "Dipy",
    "dipy cleanup": "Dipy",
    "stanford hardi data": "Dipy",
    # Neuroimaging
    "brain imaging analysis": "Neuroimaging",
    "neonatal brain imaging": "Neuroimaging",
    "neuroimaging preprocessing": "Neuroimaging",
    # Preprocessing
    "image preprocessing": "Preprocessing",
    "normalization": "Preprocessing",
    # Dashboard
    "dashboard configuration": "Dashboard",
    "dashboard creation": "Dashboard",
    "dashboard design": "Dashboard",
    "dashboard development": "Dashboard",
    "dashboard visualization": "Dashboard",
    # Pipeline
    "pipeline architecture": "Pipeline",
    "pipeline debugging": "Pipeline",
    "pipeline visualization": "Pipeline",
    "data pipeline": "Pipeline",
    "ml pipeline": "Pipeline",
}

# Terminal tab names and noise entities to filter out of wikilinks.
_NOISE_ENTITIES: set[str] = {
    "amit", "stanford_hardi", "stanford hardi", "about:blank",
    "unknown", "untitled", "loginwindow",
}

_NOISE_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-"),  # UUIDs
    re.compile(r"^\d{4}\.\d{2}\.\d{2}"),  # arxiv-style IDs
]

_BROWSER_APPS: set[str] = {
    "Safari",
    "Google Chrome",
    "Chrome",
    "Brave Browser",
    "Arc",
    "Firefox",
}


def normalize_topic(name: str) -> str:
    """Normalize a topic name to its canonical form.

    Parameters
    ----------
    name : str
        Raw topic name from LLM output.

    Returns
    -------
    str
        Canonical topic name (Title Case).
    """
    lower = name.strip().lower()
    if lower in _TOPIC_CANON:
        return _TOPIC_CANON[lower]
    return sanitize_name(name)


def is_noise_entity(name: str) -> bool:
    """Check if a name is a terminal/metadata noise entity.

    Parameters
    ----------
    name : str
        Candidate entity or file name from wikilinks.

    Returns
    -------
    bool
        True if the name should be excluded from wikilinks.
    """
    lower = name.strip().lower()
    if lower in _NOISE_ENTITIES:
        return True
    return any(p.search(lower) for p in _NOISE_PATTERNS)


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


def compute_fragmentation_metrics(
    sessions: list[dict], activities: list[dict] | None = None,
) -> dict[str, object]:
    """Compute a simple fragmentation score for a block or activity."""
    total_seconds = 0.0
    browser_seconds = 0.0
    apps: set[str] = set()
    for session in sessions:
        app = session.get("app_name", "Unknown")
        apps.add(app)
        start = _parse_iso(session.get("start_timestamp", ""))
        end = _parse_iso(session.get("end_timestamp", ""))
        if start and end:
            duration = max(0.0, (end - start).total_seconds())
            total_seconds += duration
            if app in _BROWSER_APPS:
                browser_seconds += duration

    topic_count = len({
        normalize_topic(topic)
        for activity in (activities or [])
        for topic in activity.get("key_topics", [])
    })
    session_count = len(sessions)
    app_count = len(apps)
    browser_ratio = browser_seconds / total_seconds if total_seconds > 0 else 0.0

    score = 0
    score += max(0, session_count - 4) * 8
    score += max(0, app_count - 2) * 12
    score += int(browser_ratio * 35)
    score += max(0, topic_count - 2) * 10
    score = min(100, score)

    if score < 25:
        label = "Low"
    elif score < 50:
        label = "Moderate"
    else:
        label = "High"

    return {
        "score": score,
        "label": label,
        "session_count": session_count,
        "app_count": app_count,
        "topic_count": topic_count,
        "browser_ratio": browser_ratio,
    }


def detect_artifacts(activity: dict, sessions: list[dict]) -> list[str]:
    """Infer likely shipped artifacts from activity text and metadata."""
    haystacks = [
        activity.get("name", ""),
        activity.get("description", ""),
        " ".join(activity.get("document_paths", [])),
        " ".join(activity.get("browser_urls", [])),
    ]
    for session in sessions:
        haystacks.append(" ".join(session.get("window_titles", [])))
        haystacks.append(" ".join(session.get("document_paths", [])))
        haystacks.append(" ".join(session.get("browser_urls", [])))
    text = " ".join(haystacks).lower()

    artifacts: list[str] = []
    checks = [
        ("Commit", [" git commit", " committed", "staging and reviewing", "pull request"]),
        ("Test Run", ["pytest", "unit test", "test render", "passed validation", "verifying"]),
        ("Render", ["rendered", "rendering", ".mp4", "video output", "concatenated video"]),
        ("Job Submission", ["submitted slurm job", "submitted a gpu job", "squeue", "sbatch"]),
        ("Export", [".pdf", ".png", ".jpg", ".csv", "exported", "final output"]),
    ]
    for label, needles in checks:
        if any(needle in text for needle in needles):
            artifacts.append(label)
    return artifacts


# ---------------------------------------------------------------------------
# Note builders
# ---------------------------------------------------------------------------


def build_activity_note(
    activity: dict,
    sessions: list[dict],
    related: list[dict],
    focus_block: dict | None = None,
    artifacts: list[str] | None = None,
    fragmentation: dict[str, object] | None = None,
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

    # Normalize and deduplicate topics
    norm_topics = list(dict.fromkeys(
        normalize_topic(t) for t in topics
    ))

    lines: list[str] = [
        "---",
        f"duration_minutes: {duration}",
        f"apps: [{', '.join(app_names)}]",
        f"topics: [{', '.join(norm_topics)}]",
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

    if focus_block:
        block_title = focus_block.get("note_name") or focus_block.get("task", "Focus Block")
        lines.append("## Intent")
        lines.append(f"- **Declared task:** {focus_block.get('task', 'Unknown')}")
        lines.append(f"- **Focus block:** [[{block_title}]]")
        if focus_block.get("done_when"):
            lines.append(f"- **Done when:** {focus_block['done_when']}")
        if focus_block.get("artifact_goal"):
            lines.append(f"- **Artifact goal:** {focus_block['artifact_goal']}")
        lines.append("")

    if fragmentation:
        browser_ratio = float(fragmentation.get("browser_ratio", 0.0))
        lines.append("## Focus Signals")
        lines.append(
            "- **Fragmentation:** "
            f"{fragmentation.get('score', 0)}/100 ({fragmentation.get('label', 'Unknown')})"
        )
        lines.append(
            f"- **Sessions:** {fragmentation.get('session_count', 0)}"
            f" across {fragmentation.get('app_count', 0)} apps"
        )
        lines.append(f"- **Browser share:** {browser_ratio:.0%}")
        if artifacts:
            lines.append(f"- **Detected artifacts:** {', '.join(artifacts)}")
        lines.append("")

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
    # Filter out noise entities from file links
    clean_files = [
        p for p in all_files if not is_noise_entity(_extract_filename(p))
    ]
    if clean_files:
        lines.append("## Files")
        lines.extend(f"- [[{_extract_filename(p)}]]" for p in clean_files)
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

    if norm_topics:
        lines.append("## Topics")
        lines.extend(f"- [[{t}]]" for t in norm_topics)
        lines.append("")

    return "\n".join(lines)


def build_block_note(
    block: dict,
    activities: list[dict],
    sessions: list[dict],
    fragmentation: dict[str, object],
    artifacts: list[str],
) -> str:
    """Build Markdown content for a focus block note."""
    start_dt = _parse_iso(block.get("started_at"))
    end_dt = _parse_iso(block.get("ended_at"))
    start_text = start_dt.strftime("%H:%M") if start_dt else "Unknown"
    end_text = end_dt.strftime("%H:%M") if end_dt else "Active"
    block_title = block.get("task", "Focus Block")
    browser_ratio = float(fragmentation.get("browser_ratio", 0.0))

    lines = [
        "---",
        "type: focus_block",
        f'task: "{block_title}"',
        f"date: {(start_dt or datetime.now()).strftime('%Y-%m-%d')}",
        f"fragmentation_score: {fragmentation.get('score', 0)}",
        "---",
        "",
        f"# {start_text} - {end_text}: {block_title}",
        "",
        f"**Declared success:** {block.get('done_when', '') or 'Not specified'}  ",
        f"**Artifact goal:** {block.get('artifact_goal', '') or 'Not specified'}  ",
        f"**Actual artifact:** {block.get('artifact', '') or 'Not recorded'}  ",
        f"**Fragmentation:** {fragmentation.get('score', 0)}/100"
        f" ({fragmentation.get('label', 'Unknown')})",
        "",
        "## Signals",
        f"- **Sessions:** {fragmentation.get('session_count', 0)}",
        f"- **Apps touched:** {fragmentation.get('app_count', 0)}",
        f"- **Topic spread:** {fragmentation.get('topic_count', 0)}",
        f"- **Browser share:** {browser_ratio:.0%}",
        "",
    ]

    if activities:
        lines.append("## Activities")
        for activity in sorted(
            activities, key=lambda item: item.get("start_timestamp", "")
        ):
            duration = _duration_minutes(
                activity.get("start_timestamp", ""),
                activity.get("end_timestamp", ""),
            )
            start_time = _parse_iso(activity.get("start_timestamp", ""))
            prefix = start_time.strftime("%H:%M") if start_time else "--:--"
            lines.append(
                f"- **{prefix}** [[{activity.get('name', 'Unknown Activity')}]] "
                f"({format_duration(duration * 60)})"
            )
        lines.append("")

    app_usage = _aggregate_sessions(sessions)
    if app_usage:
        lines.append("## Apps")
        for entry in app_usage[:8]:
            lines.append(
                f"- **{entry['app_name']}** ({format_duration(entry['total_seconds'])})"
            )
        lines.append("")

    if artifacts:
        lines.append("## Detected Artifacts")
        for artifact in artifacts:
            lines.append(f"- {artifact}")
        lines.append("")

    lines.append("## Review")
    if block.get("score") is not None:
        lines.append(f"- **Score:** {block['score']}/10")
    if block.get("notes"):
        lines.append(f"- **Notes:** {block['notes']}")
    if block.get("status"):
        lines.append(f"- **Status:** {block['status']}")
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
    clean = normalize_topic(topic_name)
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


def _time_block(hour: int) -> str:
    """Return a time-of-day label for grouping activities."""
    if hour < 6:
        return "Late Night"
    if hour < 12:
        return "Morning"
    if hour < 17:
        return "Afternoon"
    if hour < 21:
        return "Evening"
    return "Night"


def _primary_topic(act: dict) -> str:
    """Extract the primary (first) normalized topic from an activity."""
    topics = act.get("key_topics", [])
    if topics:
        return normalize_topic(topics[0])
    return "General"


CONFIDENCE_THRESHOLD = 0.6


def build_daily_note(
    date: datetime,
    app_usage: list[dict],
    activities: list[dict],
    all_sessions: list[dict] | None = None,
    focus_blocks: list[dict] | None = None,
) -> str:
    """Build Markdown content for a Daily note.

    Filters out low-confidence activities, groups by topic, and includes
    descriptions and time ranges for meaningful summaries.

    Parameters
    ----------
    date : datetime
        The date for this daily note.
    app_usage : list[dict]
        Per-day app usage stats (already filtered to this date).
    activities : list[dict]
        Activities that occurred on this date.
    all_sessions : list[dict], optional
        Raw sessions for computing per-day app usage when app_usage
        is not pre-filtered.
    """
    date_str = date.strftime("%Y-%m-%d")
    title = date.strftime("%B %d, %Y")
    lines = ["---", f"date: {date_str}", "---", "", f"# {title}", ""]

    # Compute per-day app usage from sessions if available
    if all_sessions:
        by_app: dict[str, dict] = {}
        for session in all_sessions:
            start = _parse_iso(session.get("start_timestamp", ""))
            if not start or start.strftime("%Y-%m-%d") != date_str:
                continue
            app = session.get("app_name", "Unknown")
            entry = by_app.setdefault(
                app, {"total_seconds": 0.0, "session_count": 0},
            )
            end = _parse_iso(session.get("end_timestamp", ""))
            if start and end:
                entry["total_seconds"] += (end - start).total_seconds()
            entry["session_count"] += 1
        # Always use per-day data when sessions are available, even if
        # empty (avoids leaking global aggregate into the wrong date).
        app_usage = [{"app_name": k, **v} for k, v in by_app.items()]

    # Total tracked time
    total_seconds = sum(e.get("total_seconds", 0) for e in app_usage)
    if total_seconds > 0:
        lines.append(f"*{format_duration(total_seconds)} tracked*")
        lines.append("")

    # App usage table
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

    if not activities:
        return "\n".join(lines)

    # Split activities by confidence
    high_conf = [a for a in activities if a.get("confidence", 0) >= CONFIDENCE_THRESHOLD]
    low_conf = [a for a in activities if a.get("confidence", 0) < CONFIDENCE_THRESHOLD]

    def _act_dur(act: dict) -> int:
        return _duration_minutes(
            act.get("start_timestamp", ""), act.get("end_timestamp", ""),
        )

    # Group high-confidence activities by primary topic
    by_topic: dict[str, list[dict]] = {}
    for act in high_conf:
        topic = _primary_topic(act)
        by_topic.setdefault(topic, []).append(act)

    # Sort topic groups by total duration descending
    topic_order = sorted(
        by_topic.keys(),
        key=lambda t: sum(_act_dur(a) for a in by_topic[t]),
        reverse=True,
    )

    if topic_order:
        lines.append("## Activities")
        lines.append("")
        for topic in topic_order:
            topic_acts = sorted(by_topic[topic], key=_act_dur, reverse=True)
            topic_total = sum(_act_dur(a) for a in topic_acts)
            lines.append(f"### {topic} ({format_duration(topic_total * 60)})")
            lines.append("")
            for act in topic_acts:
                name = act.get("name", "Unknown")
                dur = _act_dur(act)
                desc = act.get("description", "")
                start_dt = _parse_iso(act.get("start_timestamp", ""))
                time_str = start_dt.strftime("%H:%M") if start_dt else ""

                # Activity line with time and duration
                dur_str = format_duration(dur * 60)
                if time_str:
                    lines.append(f"- **{time_str}** [[{name}]] ({dur_str})")
                else:
                    lines.append(f"- [[{name}]] ({dur_str})")

                # Description (first sentence or first 120 chars)
                if desc:
                    short_desc = desc.split(". ")[0]
                    if len(short_desc) > 120:
                        short_desc = short_desc[:120].rsplit(" ", 1)[0] + "..."
                    lines.append(f"  - {short_desc}")

                # Secondary topics as tags
                all_topics = act.get("key_topics", [])
                if len(all_topics) > 1:
                    tags = [normalize_topic(t) for t in all_topics[1:]]
                    tag_links = ", ".join(f"[[{t}]]" for t in tags)
                    lines.append(f"  - Related: {tag_links}")
            lines.append("")

    if focus_blocks:
        lines.append("## Focus Blocks")
        for block in sorted(focus_blocks, key=lambda item: item.get("started_at", "")):
            started = _parse_iso(block.get("started_at"))
            ended = _parse_iso(block.get("ended_at"))
            time_label = (
                f"{started.strftime('%H:%M') if started else '--:--'}"
                f"-{ended.strftime('%H:%M') if ended else 'active'}"
            )
            block_name = block.get("note_name", block.get("task", "Focus Block"))
            score = block.get("fragmentation_score")
            suffix = f" | frag {score}/100" if score is not None else ""
            lines.append(f"- **{time_label}** [[{block_name}]]{suffix}")
        lines.append("")

    # Timeline view
    time_blocks: dict[str, int] = {}
    for act in high_conf:
        start_dt = _parse_iso(act.get("start_timestamp", ""))
        if start_dt:
            block = _time_block(start_dt.hour)
            time_blocks[block] = time_blocks.get(block, 0) + _act_dur(act)

    if time_blocks:
        lines.append("## Timeline")
        block_order = ["Late Night", "Morning", "Afternoon", "Evening", "Night"]
        for block in block_order:
            if block in time_blocks:
                lines.append(f"- **{block}:** {format_duration(time_blocks[block] * 60)}")
        lines.append("")

    # Summary of low-confidence (background) sessions
    if low_conf:
        bg_total = sum(_act_dur(a) for a in low_conf)
        lines.append(
            f"> {len(low_conf)} background sessions "
            f"({format_duration(bg_total * 60)}) not categorized"
        )
        lines.append("")

    # Collect all unique topics for the day as tag links
    all_day_topics = list(dict.fromkeys(
        normalize_topic(t)
        for act in high_conf
        for t in act.get("key_topics", [])
    ))
    if all_day_topics:
        lines.append("## Topics")
        lines.append(" ".join(f"[[{t}]]" for t in all_day_topics))
        lines.append("")

    return "\n".join(lines)
