#!/bin/bash
set -euo pipefail

# Ensure Homebrew paths are available (launchd doesn't load shell profile)
export PATH="/Users/amit/.local/bin:/opt/homebrew/bin:/opt/homebrew/opt/python@3.11/libexec/bin:/usr/local/bin:$PATH"

cd "$(dirname "$0")"
exec python3 claude_proxy.py --port 11434
