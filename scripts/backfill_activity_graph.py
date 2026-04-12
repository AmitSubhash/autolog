#!/usr/bin/env python3
"""Populate activity_entities and activity_links from existing activities."""

from __future__ import annotations

import json
import sqlite3
import time
from pathlib import Path


DB_PATH = Path.home() / "Library/Application Support/ContextD/contextd.sqlite"

NOISE = {
    "amit",
    "atsubhas",
    "stanford_hardi",
    "stanford hardi",
    "about:blank",
    "unknown",
    "untitled",
    "loginwindow",
    "securityagent",
}


def is_noise(value: str) -> bool:
    lower = value.strip().lower()
    if not lower or len(lower) < 2:
        return True
    if lower in NOISE:
        return True
    return False


def is_likely_url(value: str) -> bool:
    lower = value.strip().lower()
    return (
        lower.startswith("http://")
        or lower.startswith("https://")
        or lower.startswith("chrome://")
        or lower.startswith("file://")
        or lower.startswith("about:")
        or lower.startswith("www.")
    )


def decode_json_array(value: str | None) -> list[str]:
    if not value:
        return []
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []
    return [str(item) for item in parsed]


def normalize_entities(
    document_paths: list[str], browser_urls: list[str], topics: list[str]
) -> tuple[list[str], list[str], list[str]]:
    files: set[str] = set()
    urls: set[str] = set()
    clean_topics: set[str] = set()

    for value in document_paths + browser_urls:
        value = value.strip()
        if is_noise(value):
            continue
        if is_likely_url(value):
            urls.add(value)
        else:
            files.add(value)

    for topic in topics:
        topic = topic.strip()
        if is_noise(topic):
            continue
        clean_topics.add(topic)

    return sorted(files), sorted(urls), sorted(clean_topics)


def ensure_unique_indexes(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        DELETE FROM activity_entities
        WHERE id NOT IN (
            SELECT MIN(id)
            FROM activity_entities
            GROUP BY activityId, entityType, entityValue
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_activity_entities_unique
        ON activity_entities(activityId, entityType, entityValue);

        DELETE FROM activity_links
        WHERE id NOT IN (
            SELECT MIN(id)
            FROM activity_links
            GROUP BY sourceActivityId, targetActivityId, linkType, IFNULL(sharedEntity, '')
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_activity_links_unique
        ON activity_links(sourceActivityId, targetActivityId, linkType, IFNULL(sharedEntity, ''));
        """
    )


def backfill(conn: sqlite3.Connection) -> tuple[int, int]:
    rows = conn.execute(
        """
        SELECT id, documentPaths, browserURLs, keyTopics
        FROM activities
        WHERE id IS NOT NULL
        """
    ).fetchall()

    inserted_entities = 0
    for activity_id, document_paths, browser_urls, key_topics in rows:
        files, urls, topics = normalize_entities(
            decode_json_array(document_paths),
            decode_json_array(browser_urls),
            decode_json_array(key_topics),
        )

        for entity_type, values in (
            ("file", files),
            ("url", urls),
            ("topic", topics),
        ):
            for value in values:
                cursor = conn.execute(
                    """
                    INSERT OR IGNORE INTO activity_entities(activityId, entityType, entityValue)
                    VALUES (?, ?, ?)
                    """,
                    (activity_id, entity_type, value),
                )
                inserted_entities += cursor.rowcount

    now = time.time()
    cursor = conn.execute(
        """
        INSERT OR IGNORE INTO activity_links
            (sourceActivityId, targetActivityId, linkType, weight, sharedEntity, createdAt)
        SELECT
            e1.activityId,
            e2.activityId,
            'shared_' || e1.entityType,
            1.0,
            e1.entityValue,
            ?
        FROM activity_entities e1
        JOIN activity_entities e2
          ON e1.entityType = e2.entityType
         AND e1.entityValue = e2.entityValue
         AND e1.activityId < e2.activityId
        """,
        (now,),
    )
    inserted_links = cursor.rowcount
    return inserted_entities, inserted_links


def main() -> int:
    conn = sqlite3.connect(DB_PATH)
    try:
        ensure_unique_indexes(conn)
        entities, links = backfill(conn)
        conn.commit()
        counts = conn.execute(
            """
            SELECT
                (SELECT COUNT(*) FROM activities),
                (SELECT COUNT(*) FROM activity_entities),
                (SELECT COUNT(*) FROM activity_links)
            """
        ).fetchone()
        print(
            json.dumps(
                {
                    "entities_inserted": entities,
                    "links_inserted": links,
                    "activities": counts[0],
                    "activity_entities": counts[1],
                    "activity_links": counts[2],
                },
                indent=2,
            )
        )
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
