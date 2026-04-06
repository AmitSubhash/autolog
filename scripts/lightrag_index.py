#!/usr/bin/env python3
"""LightRAG knowledge graph over AutoLog activity data.

Reads summaries, activities, and app sessions from AutoLog's REST API,
builds a LightRAG knowledge graph with entity/relationship extraction,
and provides natural language queries over your screen activity history.

Usage
-----
Build the index (ingests last N days of summaries)::

    python scripts/lightrag_index.py build --days 7

Query your activity::

    python scripts/lightrag_index.py query "What was I working on in Terminal yesterday?"

Interactive mode::

    python scripts/lightrag_index.py interactive

Incremental update (ingest new summaries since last build)::

    python scripts/lightrag_index.py update

Requirements
------------
    pip install lightrag-hku sentence-transformers
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger("lightrag-autolog")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

AUTOLOG_BASE_URL = os.environ.get("AUTOLOG_URL", "http://localhost:21890")
HTTP_TIMEOUT = 15
RAG_DIR = Path.home() / "Library" / "Application Support" / "ContextD" / "lightrag"
STATE_FILE = RAG_DIR / ".last_ingest_ts"

CLAUDE_PATHS = [
    os.path.expanduser("~/.claude/local/claude"),
    "/usr/local/bin/claude",
    "/opt/homebrew/bin/claude",
]


# ---------------------------------------------------------------------------
# AutoLog REST API helpers
# ---------------------------------------------------------------------------

def _auth_token() -> str | None:
    """Read the AutoLog auth token."""
    token_path = Path.home() / ".config" / "autolog" / "auth_token"
    if token_path.exists():
        return token_path.read_text().strip()
    return None


def _api_get(path: str, params: dict[str, Any] | None = None) -> Any:
    """GET from the AutoLog REST API.

    Parameters
    ----------
    path : str
        API path (e.g., ``/v1/summaries``).
    params : dict or None
        Query parameters.

    Returns
    -------
    Any
        Parsed JSON response.
    """
    url = f"{AUTOLOG_BASE_URL}{path}"
    if params:
        qs = "&".join(f"{k}={v}" for k, v in params.items() if v is not None)
        url = f"{url}?{qs}"

    req = urllib.request.Request(url)
    token = _auth_token()
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.URLError as exc:
        logger.error("AutoLog API error (%s): %s", url, exc)
        return None


def _api_post(path: str, body: dict[str, Any]) -> Any:
    """POST to the AutoLog REST API.

    Parameters
    ----------
    path : str
        API path.
    body : dict
        JSON body.

    Returns
    -------
    Any
        Parsed JSON response.
    """
    url = f"{AUTOLOG_BASE_URL}{path}"
    data = json.dumps(body).encode()

    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    token = _auth_token()
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.URLError as exc:
        logger.error("AutoLog API error (%s): %s", url, exc)
        return None


def fetch_summaries(minutes: int = 10080, limit: int = 2000) -> list[dict]:
    """Fetch activity summaries from AutoLog.

    Parameters
    ----------
    minutes : int
        Time window in minutes (default 10080 = 7 days).
    limit : int
        Max summaries to return.

    Returns
    -------
    list[dict]
        Summary objects.
    """
    data = _api_get("/v1/summaries", {"minutes": minutes, "limit": limit})
    if data and isinstance(data, list):
        return data
    if data and isinstance(data, dict):
        return data.get("summaries", [])
    return []


def fetch_activities(minutes: int = 10080, limit: int = 500) -> list[dict]:
    """Fetch inferred activities from AutoLog.

    Parameters
    ----------
    minutes : int
        Time window.
    limit : int
        Max activities to return.

    Returns
    -------
    list[dict]
        Activity objects.
    """
    data = _api_get("/v1/activities", {"minutes": minutes, "limit": limit})
    if data and isinstance(data, list):
        return data
    if data and isinstance(data, dict):
        return data.get("activities", [])
    return []


# ---------------------------------------------------------------------------
# Claude CLI LLM backend
# ---------------------------------------------------------------------------

def _find_claude() -> str | None:
    """Locate the claude binary."""
    for p in CLAUDE_PATHS:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    try:
        result = subprocess.run(
            ["which", "claude"], capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception as exc:
        logger.debug("which claude failed: %s", exc)
    return None


async def claude_complete(
    prompt: str,
    system_prompt: str | None = None,
    history_messages: list[dict[str, str]] | None = None,
    **kwargs: Any,
) -> str:
    """Call ``claude -p`` for LLM completions.

    Parameters
    ----------
    prompt : str
        User prompt.
    system_prompt : str or None
        System prompt.
    history_messages : list or None
        Prior turns (unused for single-shot).

    Returns
    -------
    str
        Model response.
    """
    claude_bin = _find_claude()
    if claude_bin is None:
        raise RuntimeError("claude CLI not found")

    cmd = [claude_bin, "-p", "--output-format", "json"]

    model = kwargs.get("model")
    if model:
        for key, alias in [
            ("haiku", "haiku"), ("sonnet", "sonnet"), ("opus", "opus"),
        ]:
            if key in str(model).lower():
                cmd.extend(["--model", alias])
                break

    full_prompt = ""
    if system_prompt:
        full_prompt += f"[System]\n{system_prompt}\n\n"
    if history_messages:
        for msg in history_messages:
            role = msg.get("role", "user")
            full_prompt += f"[{role.title()}]\n{msg['content']}\n\n"
    full_prompt += prompt

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate(full_prompt.encode())

    if proc.returncode != 0:
        raise RuntimeError(
            f"claude -p failed (exit {proc.returncode}): {stderr.decode().strip()}"
        )

    text = stdout.decode()
    try:
        data = json.loads(text)
        if data.get("is_error"):
            raise RuntimeError(f"claude error: {data.get('result', text)}")
        return data.get("result", text)
    except json.JSONDecodeError:
        return text


# ---------------------------------------------------------------------------
# Embedding function (lightweight, for LightRAG's internal chunking)
# ---------------------------------------------------------------------------

_embed_model = None


async def embed_texts(texts: list[str], **kwargs: Any) -> Any:
    """Embed texts with all-MiniLM-L6-v2.

    Parameters
    ----------
    texts : list[str]
        Texts to embed.

    Returns
    -------
    list[list[float]]
        Embedding vectors.
    """
    global _embed_model
    if _embed_model is None:
        from sentence_transformers import SentenceTransformer
        _embed_model = SentenceTransformer("all-MiniLM-L6-v2")
    import numpy as np
    vecs = _embed_model.encode(texts, show_progress_bar=False, normalize_embeddings=True)
    return np.array(vecs)


# ---------------------------------------------------------------------------
# Document formatting
# ---------------------------------------------------------------------------

def _ts_to_str(ts: float | str) -> str:
    """Convert a Unix timestamp or ISO string to readable format."""
    if isinstance(ts, str):
        return ts
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def format_summary(s: dict) -> str:
    """Format a summary dict as a document for LightRAG ingestion.

    Parameters
    ----------
    s : dict
        Summary from the AutoLog API.

    Returns
    -------
    str
        Formatted document.
    """
    parts = []

    start = s.get("startTimestamp") or s.get("start_timestamp")
    end = s.get("endTimestamp") or s.get("end_timestamp")
    if start:
        parts.append(f"Time: {_ts_to_str(start)} to {_ts_to_str(end or start)}")

    apps = s.get("appNames") or s.get("app_names")
    if apps:
        if isinstance(apps, str):
            try:
                apps = json.loads(apps)
            except json.JSONDecodeError:
                apps = [apps]
        parts.append(f"Applications: {', '.join(apps)}")

    summary_text = s.get("summary", "")
    if summary_text:
        parts.append(f"Summary: {summary_text}")

    topics = s.get("keyTopics") or s.get("key_topics")
    if topics:
        if isinstance(topics, str):
            try:
                topics = json.loads(topics)
            except json.JSONDecodeError:
                topics = [topics]
        parts.append(f"Topics: {', '.join(topics)}")

    activity_type = s.get("activityType") or s.get("activity_type")
    if activity_type:
        parts.append(f"Activity type: {activity_type}")

    urls = s.get("browserURLs") or s.get("browser_urls")
    if urls:
        if isinstance(urls, str):
            try:
                urls = json.loads(urls)
            except json.JSONDecodeError:
                urls = [urls]
        parts.append(f"URLs: {', '.join(urls[:5])}")

    docs = s.get("documentPaths") or s.get("document_paths")
    if docs:
        if isinstance(docs, str):
            try:
                docs = json.loads(docs)
            except json.JSONDecodeError:
                docs = [docs]
        parts.append(f"Files: {', '.join(docs[:5])}")

    return "\n".join(parts)


def format_activity(a: dict) -> str:
    """Format an activity dict as a document for LightRAG.

    Parameters
    ----------
    a : dict
        Activity from the AutoLog API.

    Returns
    -------
    str
        Formatted document.
    """
    parts = [f"Activity: {a.get('name', 'Unknown')}"]

    desc = a.get("description")
    if desc:
        parts.append(f"Description: {desc}")

    start = a.get("startTimestamp") or a.get("start_timestamp")
    end = a.get("endTimestamp") or a.get("end_timestamp")
    if start:
        parts.append(f"Time: {_ts_to_str(start)} to {_ts_to_str(end or start)}")

    topics = a.get("keyTopics") or a.get("key_topics")
    if topics:
        if isinstance(topics, str):
            try:
                topics = json.loads(topics)
            except json.JSONDecodeError:
                topics = [topics]
        parts.append(f"Topics: {', '.join(topics)}")

    conf = a.get("confidence")
    if conf is not None:
        parts.append(f"Confidence: {conf:.2f}")

    return "\n".join(parts)


# ---------------------------------------------------------------------------
# LightRAG wrapper
# ---------------------------------------------------------------------------

async def init_rag() -> Any:
    """Initialize a LightRAG instance backed by claude -p.

    Returns
    -------
    LightRAG
        Initialized instance with storages ready.
    """
    from lightrag import LightRAG
    from lightrag.utils import EmbeddingFunc

    RAG_DIR.mkdir(parents=True, exist_ok=True)

    rag = LightRAG(
        working_dir=str(RAG_DIR),
        llm_model_func=claude_complete,
        embedding_func=EmbeddingFunc(
            embedding_dim=384,  # all-MiniLM-L6-v2 output dimension
            max_token_size=512,
            func=embed_texts,
        ),
        chunk_token_size=1200,
        enable_llm_cache=True,
    )
    await rag.initialize_storages()
    return rag


def _save_last_ts(ts: float) -> None:
    """Persist the last ingested timestamp for incremental updates."""
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(str(ts))


def _load_last_ts() -> float | None:
    """Load the last ingested timestamp."""
    if STATE_FILE.exists():
        try:
            return float(STATE_FILE.read_text().strip())
        except ValueError:
            pass
    return None


def _parse_ts(val: Any) -> float:
    """Parse a timestamp value (ISO string or float) to Unix float."""
    if isinstance(val, (int, float)):
        return float(val)
    if isinstance(val, str):
        try:
            return datetime.fromisoformat(val.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return 0.0
    return 0.0


def _batch_by_hour(
    summaries: list[dict],
    activities: list[dict],
) -> tuple[list[str], list[str]]:
    """Batch summaries and activities into hourly mega-documents.

    Instead of one LightRAG document per summary (= one Claude call each),
    we group everything from the same hour into a single document.
    A full day of ~200 summaries becomes ~10-15 documents.

    Parameters
    ----------
    summaries : list[dict]
        Summary objects from AutoLog API.
    activities : list[dict]
        Activity objects from AutoLog API.

    Returns
    -------
    tuple[list[str], list[str]]
        (documents, doc_ids) ready for LightRAG insertion.
    """
    from collections import defaultdict

    hourly: dict[str, list[str]] = defaultdict(list)

    for s in summaries:
        ts_raw = s.get("startTimestamp") or s.get("start_timestamp") or ""
        ts_val = _parse_ts(ts_raw)
        if ts_val > 0:
            hour_key = datetime.fromtimestamp(ts_val).strftime("%Y-%m-%d_%H")
        else:
            hour_key = str(ts_raw)[:13]  # fallback: first 13 chars of ISO
        hourly[hour_key].append(format_summary(s))

    for a in activities:
        ts_raw = a.get("startTimestamp") or a.get("start_timestamp") or ""
        ts_val = _parse_ts(ts_raw)
        if ts_val > 0:
            hour_key = datetime.fromtimestamp(ts_val).strftime("%Y-%m-%d_%H")
        else:
            hour_key = str(ts_raw)[:13]
        hourly[hour_key].append(format_activity(a))

    documents = []
    doc_ids = []
    for hour_key in sorted(hourly.keys()):
        entries = hourly[hour_key]
        mega_doc = f"=== Activity Log: {hour_key}:00 ===\n\n"
        mega_doc += "\n\n---\n\n".join(entries)
        documents.append(mega_doc)
        doc_ids.append(f"hour_{hour_key}")

    return documents, doc_ids


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

async def cmd_build(args: argparse.Namespace) -> None:
    """Build the knowledge graph from AutoLog data."""
    minutes = args.days * 24 * 60
    logger.info("Fetching summaries (last %d days)...", args.days)

    summaries = fetch_summaries(minutes=minutes, limit=args.limit)
    activities = fetch_activities(minutes=minutes, limit=500)

    if not summaries and not activities:
        logger.error(
            "No data from AutoLog. Is it running? (http://localhost:21890/health)"
        )
        return

    logger.info("Got %d summaries, %d activities", len(summaries), len(activities))

    # Batch into hourly mega-documents to minimize Claude calls
    documents, doc_ids = _batch_by_hour(summaries, activities)

    logger.info(
        "Batched into %d hourly documents (from %d summaries + %d activities)",
        len(documents), len(summaries), len(activities),
    )
    rag = await init_rag()
    try:
        await rag.ainsert(documents, ids=doc_ids)
        logger.info("Knowledge graph built at %s", RAG_DIR)

        # Save watermark for incremental updates
        max_ts = max(
            (_parse_ts(s.get("endTimestamp") or s.get("end_timestamp") or 0)
             for s in summaries),
            default=0.0,
        )
        if max_ts > 0:
            _save_last_ts(max_ts)

        print(f"\nDone. {len(documents)} documents indexed at {RAG_DIR}")
    finally:
        await rag.finalize_storages()


async def cmd_update(args: argparse.Namespace) -> None:
    """Incrementally ingest new summaries since the last build.

    Batches summaries into hourly mega-documents to minimize Claude calls.
    A day of ~200 summaries becomes ~10-15 hourly batches instead of 200
    individual documents, cutting entity extraction calls by ~15x.
    """
    last_ts = _load_last_ts()
    if last_ts is None:
        logger.info("No previous build found, doing a full build")
        args.days = 1
        args.limit = 2000
        await cmd_build(args)
        return

    elapsed_min = int((datetime.now().timestamp() - last_ts) / 60) + 5
    logger.info("Fetching summaries since last ingest (%d minutes ago)", elapsed_min)

    summaries = fetch_summaries(minutes=elapsed_min, limit=2000)
    activities = fetch_activities(minutes=elapsed_min, limit=500)

    if not summaries and not activities:
        print("No new data to ingest.")
        return

    # Batch summaries into hourly mega-documents
    documents, doc_ids = _batch_by_hour(summaries, activities)

    logger.info(
        "Batched %d summaries + %d activities into %d hourly documents",
        len(summaries), len(activities), len(documents),
    )

    rag = await init_rag()
    try:
        await rag.ainsert(documents, ids=doc_ids)

        max_ts = max(
            (_parse_ts(s.get("endTimestamp") or s.get("end_timestamp") or 0)
             for s in summaries),
            default=0,
        )
        if max_ts > 0:
            _save_last_ts(max_ts)

        print(f"Updated: {len(documents)} batched documents ingested.")
    finally:
        await rag.finalize_storages()


async def cmd_query(args: argparse.Namespace) -> None:
    """Run a single query against the knowledge graph."""
    from lightrag import QueryParam

    rag = await init_rag()
    try:
        result = await rag.aquery(
            args.question,
            param=QueryParam(mode=args.mode),
        )
        text = result.content if hasattr(result, "content") else str(result)
        print(f"\n{text}\n")
    finally:
        await rag.finalize_storages()


async def cmd_interactive(args: argparse.Namespace) -> None:
    """Interactive query loop."""
    from lightrag import QueryParam

    rag = await init_rag()
    try:
        mode = args.mode
        print(f"\nAutoLog RAG - Interactive ({mode} mode)")
        print("Commands: 'quit', 'mode <naive|local|global|hybrid>'\n")

        while True:
            try:
                q = input("Q: ").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if not q:
                continue
            if q.lower() == "quit":
                break
            if q.lower().startswith("mode "):
                valid = {"naive", "local", "global", "hybrid"}
                new_mode = q.split(None, 1)[1]
                if new_mode not in valid:
                    print(f"  Unknown mode. Valid: {', '.join(sorted(valid))}\n")
                    continue
                mode = new_mode
                print(f"  -> {mode} mode\n")
                continue

            result = await rag.aquery(q, param=QueryParam(mode=mode))
            text = result.content if hasattr(result, "content") else str(result)
            print(f"\nA: {text}\n")
    finally:
        await rag.finalize_storages()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    parser = argparse.ArgumentParser(
        description="LightRAG knowledge graph over AutoLog activity data"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_build = sub.add_parser("build", help="Build KG from AutoLog summaries")
    p_build.add_argument("--days", type=int, default=7, help="Days of history (default: 7)")
    p_build.add_argument("--limit", type=int, default=2000, help="Max summaries")

    sub.add_parser("update", help="Incremental ingest since last build")

    p_query = sub.add_parser("query", help="Single query")
    p_query.add_argument("question", help="Natural language question")
    p_query.add_argument(
        "--mode", default="hybrid",
        choices=["naive", "local", "global", "hybrid"],
    )

    p_inter = sub.add_parser("interactive", help="Interactive query loop")
    p_inter.add_argument(
        "--mode", default="hybrid",
        choices=["naive", "local", "global", "hybrid"],
    )

    args = parser.parse_args()

    dispatch = {
        "build": cmd_build,
        "update": cmd_update,
        "query": cmd_query,
        "interactive": cmd_interactive,
    }
    asyncio.run(dispatch[args.command](args))


if __name__ == "__main__":
    main()
