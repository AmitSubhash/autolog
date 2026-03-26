"""One-time cleanup and reorganization of the autolog Obsidian vault.

Fixes:
1. Topic normalization -- merges near-duplicate topics into canonical names
2. Noise entity filtering -- removes [[amit]], [[stanford_hardi]], etc.
3. Daily note dedup -- regenerates app usage per-day from activity timestamps
4. Collapses Untitled/Session: activities in daily notes
5. Creates missing topic stubs for orphan wikilinks
6. Removes empty stub files at vault root
"""
from __future__ import annotations

import re
import shutil
from collections import defaultdict
from datetime import datetime
from pathlib import Path

VAULT = Path.home() / "Documents" / "autolog-vault"
BACKUP = VAULT.parent / "autolog-vault-backup"

# ── Topic normalization map ────────────────────────────────────────────
# Maps variant names -> canonical name. Built from the actual vault analysis.
# Keys are lowercase for matching; values are the canonical Title Case name.
TOPIC_CANON: dict[str, str] = {
    # BCI cluster
    "brain-computer interfaces": "Brain-Computer Interface",
    "bci": "Brain-Computer Interface",
    "neural interfaces": "Brain-Computer Interface",
    "braingate2": "Brain-Computer Interface",
    # File organization
    "file-organization": "File Organization",
    "file browsing": "File Organization",
    # PDF cluster
    "pdf-files": "Pdf Files",
    "pdfs": "Pdf Files",
    "final_pdfs": "Pdf Files",
    # Development cluster
    "developer tools": "Development Tools",
    "development": "Development Tools",
    "development environment": "Development Tools",
    "macos development": "Development Tools",
    # Email
    "email management": "Email",
    # CV cluster
    "cv review": "Cv",
    "career files": "Cv",
    # Python
    "python development": "Python",
    # Bun
    "bun runtime": "Bun",
    # Professional cluster
    "professional networking": "Professional",
    "professional profile": "Professional",
    "profile viewing": "Professional",
    "personal branding": "Professional",
    # Terminal work
    "terminal_work": "Terminal",
    # Code
    "code editing": "Code",
    "code-search": "Code",
    # Database
    "database debugging": "Database",
    "database enrichment": "Database",
    # AutoLog
    "contextd debugging": "AutoLog",
    "autolog": "AutoLog",
    # Projects
    "personal projects": "Projects",
    # Portfolio
    "github portfolio": "Portfolio",
    # Search
    "web_lookup": "Search",
    # HPC
    "hpc agent project": "Hpc",
    "bigred200 hpc": "Bigred200",
    # Documentation
    "vault documentation": "Documentation",
    # Scripting
    "scripting": "Development Tools",
    # System
    "system utilities": "System",
    "process monitoring": "System",
    # Service
    "service setup": "Environment Setup",
    # Media
    "media preview": "Video Review",
    # JS
    "javascript-typescript": "Javascript Runtime",
    # Manim
    "manim-skill": "Manim",
    # Cross-domain analogy variants
    "cross-domain-analogy": "Cross-Domain Analogy",
}

# ── Noise entities to strip ────────────────────────────────────────────
# These are terminal tab names / directory names, not meaningful topics.
NOISE_ENTITIES: set[str] = {
    "amit",
    "stanford_hardi",
    "stanford hardi",
    "about:blank",
    "unknown",
    "untitled",
    "loginwindow",
}

# Patterns for noise entity detection
NOISE_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-"),  # UUIDs
    re.compile(r"^\d{4}\.\d{2}\.\d{2}"),  # arxiv-style IDs
    re.compile(r"^session: ", re.IGNORECASE),  # Session: Terminal etc.
    re.compile(r"^untitled session$", re.IGNORECASE),
]


def is_noise(name: str) -> bool:
    """Check if a wikilink target is noise that should be removed."""
    lower = name.lower().strip()
    if lower in NOISE_ENTITIES:
        return True
    return any(p.search(lower) for p in NOISE_PATTERNS)


def canonicalize_topic(name: str) -> str | None:
    """Return the canonical topic name, or None if it should be removed."""
    stripped = name.strip()
    if is_noise(stripped):
        return None
    lower = stripped.lower()
    if lower in TOPIC_CANON:
        return TOPIC_CANON[lower]
    return stripped


def rewrite_wikilinks(text: str) -> tuple[str, bool]:
    """Rewrite all [[wikilinks]] in text using the topic canon map.

    Returns (new_text, changed).
    """
    changed = False

    def replacer(match: re.Match[str]) -> str:
        nonlocal changed
        original = match.group(1)
        canonical = canonicalize_topic(original)
        if canonical is None:
            # Remove the wikilink entirely (noise entity)
            changed = True
            return ""
        if canonical != original:
            changed = True
            return f"[[{canonical}]]"
        return match.group(0)

    result = re.sub(r"\[\[([^\]]+)\]\]", replacer, text)
    # Clean up artifacts: empty list items, trailing commas in frontmatter
    result = re.sub(r"^- \s*$\n?", "", result, flags=re.MULTILINE)
    result = re.sub(r"\n{3,}", "\n\n", result)
    return result, changed


def rewrite_frontmatter_topics(text: str) -> str:
    """Rewrite topic lists in YAML frontmatter."""
    def replacer(match: re.Match[str]) -> str:
        prefix = match.group(1)
        topics_str = match.group(2)
        topics = [t.strip() for t in topics_str.split(",")]
        canonical: list[str] = []
        seen: set[str] = set()
        for t in topics:
            c = canonicalize_topic(t)
            if c is not None and c not in seen:
                canonical.append(c)
                seen.add(c)
        return f"{prefix}[{', '.join(canonical)}]"

    return re.sub(r"(topics: )\[([^\]]*)\]", replacer, text)


# ── Main cleanup steps ─────────────────────────────────────────────────


def backup_vault() -> None:
    """Create a backup of the vault before modifications."""
    if BACKUP.exists():
        shutil.rmtree(BACKUP)
    shutil.copytree(VAULT, BACKUP)
    print(f"Backed up vault to {BACKUP}")


def step1_normalize_topics() -> tuple[int, int]:
    """Rewrite wikilinks and frontmatter across all notes."""
    files_changed = 0
    links_changed = 0
    for md_file in VAULT.rglob("*.md"):
        text = md_file.read_text(encoding="utf-8")
        original = text
        text = rewrite_frontmatter_topics(text)
        text, wl_changed = rewrite_wikilinks(text)
        if text != original:
            md_file.write_text(text, encoding="utf-8")
            files_changed += 1
            if wl_changed:
                links_changed += 1
    return files_changed, links_changed


def step2_merge_topic_files() -> int:
    """Merge duplicate topic files into canonical ones."""
    topics_dir = VAULT / "Topics"
    if not topics_dir.exists():
        return 0

    merged = 0
    # Build reverse map: canonical -> list of variant filenames
    canon_variants: dict[str, list[Path]] = defaultdict(list)
    for f in topics_dir.glob("*.md"):
        name = f.stem
        canon = canonicalize_topic(name)
        if canon is None:
            # Noise topic file -- delete it
            f.unlink()
            merged += 1
            continue
        canon_variants[canon].append(f)

    for canon_name, files in canon_variants.items():
        target = topics_dir / f"{canon_name}.md"

        # Collect all activity links from all variant files
        all_activities: list[str] = []
        for f in files:
            text = f.read_text(encoding="utf-8")
            for match in re.finditer(r"\[\[([^\]]+)\]\]", text):
                act = match.group(1)
                if act not in all_activities:
                    all_activities.append(act)

        # Write the canonical file
        count = len(all_activities)
        lines = [
            "---", "type: topic", "---", "",
            f"# {canon_name}", "",
            f"This topic appeared in **{count} "
            f"{'activity' if count == 1 else 'activities'}**.",
            "",
        ]
        if all_activities:
            lines.append("## Activities")
            lines.extend(f"- [[{a}]]" for a in all_activities)
            lines.append("")
        target.write_text("\n".join(lines), encoding="utf-8")

        # Delete variant files that aren't the canonical
        for f in files:
            if f != target and f.exists():
                f.unlink()
                merged += 1

    return merged


def step3_fix_daily_notes() -> int:
    """Regenerate daily notes with per-day app usage from activity data."""
    daily_dir = VAULT / "Daily"
    activities_dir = VAULT / "Activities"
    if not daily_dir.exists():
        return 0

    # Parse all activity notes to build per-day stats
    day_activities: dict[str, list[dict]] = defaultdict(list)
    day_app_usage: dict[str, dict[str, dict]] = defaultdict(
        lambda: defaultdict(lambda: {"total_seconds": 0, "session_count": 0}),
    )

    for f in activities_dir.glob("*.md"):
        text = f.read_text(encoding="utf-8")

        # Extract date from frontmatter or filename
        date_match = re.search(
            r"(?:date: |When:\*\* )(\d{4}-\d{2}-\d{2})", text,
        )
        if not date_match:
            # Try filename for timestamp-named files
            fname_match = re.match(r"(\d{4}-\d{2}-\d{2})", f.stem)
            if fname_match:
                date_match = fname_match
        if not date_match:
            continue

        date_str = date_match.group(1)
        title = f.stem

        # Skip noise activities
        lower_title = title.lower()
        if any(
            x in lower_title
            for x in ["untitled-session", "session-terminal", "session-safari"]
        ):
            continue

        # Extract duration
        dur_match = re.search(r"duration_minutes: (\d+)", text)
        duration = int(dur_match.group(1)) if dur_match else 1

        # Extract apps from frontmatter
        apps_match = re.search(r"apps: \[([^\]]*)\]", text)
        if apps_match and apps_match.group(1).strip():
            apps = [a.strip() for a in apps_match.group(1).split(",") if a.strip()]
        else:
            apps = []

        # Extract human-readable name from H1
        h1_match = re.search(r"^# (.+)$", text, re.MULTILINE)
        display_name = h1_match.group(1) if h1_match else title.replace("-", " ").title()

        day_activities[date_str].append({
            "name": display_name,
            "duration": duration,
            "apps": apps,
        })

        # Accumulate per-app time (distribute duration across apps)
        if apps:
            per_app_secs = (duration * 60) / len(apps)
            for app in apps:
                day_app_usage[date_str][app]["total_seconds"] += per_app_secs
                day_app_usage[date_str][app]["session_count"] += 1

    # Write daily notes
    written = 0
    for date_str in sorted(set(list(day_activities.keys()) + list(day_app_usage.keys()))):
        try:
            date_obj = datetime.strptime(date_str, "%Y-%m-%d")
        except ValueError:
            continue

        title = date_obj.strftime("%B %d, %Y")
        acts = day_activities.get(date_str, [])
        usage = day_app_usage.get(date_str, {})

        lines = ["---", f"date: {date_str}", "---", "", f"# {title}", ""]

        # App usage table (from this day's activities only)
        if usage:
            sorted_usage = sorted(
                usage.items(), key=lambda x: x[1]["total_seconds"], reverse=True,
            )
            lines.extend([
                "## App Usage",
                "| App | Time | Sessions |",
                "|-----|------|----------|",
            ])
            for app_name, stats in sorted_usage:
                total_secs = stats["total_seconds"]
                mins = int(total_secs) // 60
                if mins >= 60:
                    h, m = divmod(mins, 60)
                    dur_str = f"{h}h {m:02d}m" if m else f"{h}h"
                elif mins > 0:
                    dur_str = f"{mins}m"
                else:
                    dur_str = f"{int(total_secs)}s"
                lines.append(
                    f"| {app_name} | {dur_str} | {stats['session_count']} |",
                )
            lines.append("")

        # Activity list (filtered, no untitled/session noise)
        if acts:
            # Sort by duration descending
            acts.sort(key=lambda x: x["duration"], reverse=True)
            lines.append("## Activities")
            for act in acts:
                lines.append(f"- [[{act['name']}]] ({act['duration']} min)")
            lines.append("")

        fpath = daily_dir / f"{date_str}.md"
        fpath.write_text("\n".join(lines), encoding="utf-8")
        written += 1

    return written


def step4_create_missing_topics() -> int:
    """Create stub topic files for orphan wikilinks."""
    topics_dir = VAULT / "Topics"
    topics_dir.mkdir(exist_ok=True)

    # Collect all wikilinks from Activities
    all_links: dict[str, list[str]] = defaultdict(list)
    activities_dir = VAULT / "Activities"
    for f in activities_dir.glob("*.md"):
        text = f.read_text(encoding="utf-8")
        # Only count links from the Topics section
        topics_section = re.search(
            r"## Topics\n((?:- \[\[.+\]\]\n?)+)", text,
        )
        if not topics_section:
            continue
        for match in re.finditer(r"\[\[([^\]]+)\]\]", topics_section.group(1)):
            topic = match.group(1)
            h1_match = re.search(r"^# (.+)$", text, re.MULTILINE)
            act_name = h1_match.group(1) if h1_match else f.stem
            all_links[topic].append(act_name)

    # Create missing topic files
    created = 0
    for topic_name, activities in all_links.items():
        fpath = topics_dir / f"{topic_name}.md"
        if fpath.exists():
            continue
        if is_noise(topic_name):
            continue

        unique_acts = list(dict.fromkeys(activities))
        count = len(unique_acts)
        lines = [
            "---", "type: topic", "---", "",
            f"# {topic_name}", "",
            f"This topic appeared in **{count} "
            f"{'activity' if count == 1 else 'activities'}**.",
            "",
        ]
        if unique_acts:
            lines.append("## Activities")
            lines.extend(f"- [[{a}]]" for a in unique_acts)
            lines.append("")
        fpath.write_text("\n".join(lines), encoding="utf-8")
        created += 1

    return created


def step5_clean_stubs() -> int:
    """Remove empty/stub files at vault root and noise activity files."""
    removed = 0

    # Remove root-level stubs
    for f in VAULT.glob("*.md"):
        text = f.read_text(encoding="utf-8").strip()
        if len(text) < 5:
            f.unlink()
            removed += 1
            print(f"  Removed empty stub: {f.name}")

    # Remove noise activity files (Untitled session, Session: X)
    activities_dir = VAULT / "Activities"
    noise_prefixes = [
        "untitled-session",
        "session-terminal",
        "session-safari",
        "session-finder",
    ]
    for f in activities_dir.glob("*.md"):
        lower = f.stem.lower()
        # Don't remove timestamp-named files
        if re.match(r"\d{4}-\d{2}-\d{2}", lower):
            continue
        if any(lower.startswith(p) or lower == p for p in noise_prefixes):
            f.unlink()
            removed += 1
            print(f"  Removed noise activity: {f.name}")

    return removed


def step6_rebuild_topic_counts() -> int:
    """Rescan all activities and update topic note activity counts."""
    topics_dir = VAULT / "Topics"
    if not topics_dir.exists():
        return 0

    # Collect fresh topic -> activity mapping
    topic_acts: dict[str, list[str]] = defaultdict(list)
    activities_dir = VAULT / "Activities"
    for f in activities_dir.glob("*.md"):
        text = f.read_text(encoding="utf-8")
        topics_section = re.search(
            r"## Topics\n((?:- \[\[.+\]\]\n?)+)", text,
        )
        if not topics_section:
            continue
        h1_match = re.search(r"^# (.+)$", text, re.MULTILINE)
        act_name = h1_match.group(1) if h1_match else f.stem
        for match in re.finditer(r"\[\[([^\]]+)\]\]", topics_section.group(1)):
            topic = match.group(1)
            if act_name not in topic_acts[topic]:
                topic_acts[topic].append(act_name)

    updated = 0
    for f in topics_dir.glob("*.md"):
        topic_name = f.stem
        acts = topic_acts.get(topic_name, [])
        count = len(acts)
        lines = [
            "---", "type: topic", "---", "",
            f"# {topic_name}", "",
            f"This topic appeared in **{count} "
            f"{'activity' if count == 1 else 'activities'}**.",
            "",
        ]
        if acts:
            lines.append("## Activities")
            lines.extend(f"- [[{a}]]" for a in acts)
            lines.append("")
        f.write_text("\n".join(lines), encoding="utf-8")
        updated += 1

    return updated


def main() -> None:
    """Run all cleanup steps."""
    print("=== Obsidian Vault Cleanup ===\n")

    print("Step 0: Backing up vault...")
    backup_vault()

    print("\nStep 1: Normalizing topics and wikilinks...")
    files_changed, links_changed = step1_normalize_topics()
    print(f"  Rewrote {files_changed} files, {links_changed} with link changes")

    print("\nStep 2: Merging duplicate topic files...")
    merged = step2_merge_topic_files()
    print(f"  Merged/removed {merged} duplicate topic files")

    print("\nStep 3: Fixing daily notes (per-day app usage)...")
    daily_count = step3_fix_daily_notes()
    print(f"  Wrote {daily_count} daily notes")

    print("\nStep 4: Creating missing topic stubs...")
    created = step4_create_missing_topics()
    print(f"  Created {created} new topic files")

    print("\nStep 5: Cleaning up stubs and noise files...")
    removed = step5_clean_stubs()
    print(f"  Removed {removed} files")

    print("\nStep 6: Rebuilding topic activity counts...")
    updated = step6_rebuild_topic_counts()
    print(f"  Updated {updated} topic files")

    # Final stats
    print("\n=== Final Vault Stats ===")
    for subdir in ("Activities", "Apps", "Topics", "Daily"):
        d = VAULT / subdir
        if d.exists():
            count = len(list(d.glob("*.md")))
            print(f"  {subdir}: {count} notes")
    root_mds = len(list(VAULT.glob("*.md")))
    print(f"  Root: {root_mds} files")

    print(f"\nBackup at: {BACKUP}")
    print("Done.")


if __name__ == "__main__":
    main()
