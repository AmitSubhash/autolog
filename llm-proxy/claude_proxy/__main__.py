"""CLI entry points for ``python -m claude_proxy`` and ``claude-proxy``."""

from __future__ import annotations

import argparse
from collections.abc import Sequence

from claude_proxy.server import DEFAULT_PORT, main


def main_cli(argv: Sequence[str] | None = None) -> None:
    """Parse CLI args and start the proxy server."""
    parser = argparse.ArgumentParser(description="Claude -p LLM proxy server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Listen port")
    args = parser.parse_args(list(argv) if argv is not None else None)
    main(port=args.port)


if __name__ == "__main__":
    main_cli()
