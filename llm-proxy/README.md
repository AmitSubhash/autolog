# Claude Proxy: Your Personal Claude API

Turn `claude -p` (Claude Code's headless mode) into a full OpenAI-compatible HTTP API. Any tool, script, or app that speaks the OpenAI chat completions format can now use Claude -- no API key management, no billing dashboard, just your existing Claude Code subscription.

## Why

Claude Code includes `claude -p`, a CLI that takes a prompt on stdin and returns a response. It's powerful but awkward to integrate -- it's a subprocess, not an API. This proxy wraps it in a proper HTTP server with:

- OpenAI-compatible `/v1/chat/completions` endpoint
- Priority queue (Sonnet/Opus requests skip ahead of Haiku)
- Response caching (identical requests return instantly)
- Concurrent request handling (5 parallel `claude -p` processes)
- Usage tracking and stats
- Graceful shutdown

## Quick Start

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Python 3.10+

### Run it

```bash
cd llm-proxy
python3 claude_proxy.py --port 21891
```

That's it. The proxy is now listening on `http://127.0.0.1:21891`.

### Test it

```bash
curl -X POST http://127.0.0.1:21891/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "anthropic/claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}]
  }'
```

## API Reference

### POST /v1/chat/completions

OpenAI-compatible chat completions. Translates your request to a `claude -p` subprocess call and returns the response in OpenAI format.

**Request body:**

```json
{
  "model": "anthropic/claude-sonnet-4-6",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Explain quantum computing."}
  ],
  "max_turns": 1
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `model` | string | `anthropic/claude-sonnet-4-6` | Model to use (see table below) |
| `messages` | array | required | OpenAI-format message array |
| `max_turns` | int | `1` | Max agentic turns. Increase for multi-step tasks |

**Available models:**

| Request model | Claude CLI alias | Best for |
|---------------|-----------------|----------|
| `anthropic/claude-haiku-4-5` | haiku | Fast, cheap tasks (summarization, classification) |
| `anthropic/claude-sonnet-4-6` | sonnet | Coding, analysis, general use |
| `anthropic/claude-opus-4-5` | opus | Deep reasoning, complex architecture |

**Response:**

```json
{
  "id": "chatcmpl-e02aee86d66c45b4a94afdb0",
  "object": "chat.completion",
  "created": 1774478850,
  "model": "anthropic/claude-sonnet-4-6",
  "choices": [{
    "index": 0,
    "message": {"role": "assistant", "content": "..."},
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 42,
    "completion_tokens": 128,
    "total_tokens": 170
  }
}
```

### GET /health

Returns `{"status": "ok"}` if the server is running.

### GET /stats

Returns usage statistics:

```json
{
  "today": {"requests": 47, "estimated_tokens": 52340},
  "cache_hits": 12,
  "cache_size": 35,
  "uptime_seconds": 3600.5
}
```

## Usage Examples

### Python

```python
import requests

response = requests.post("http://127.0.0.1:21891/v1/chat/completions", json={
    "model": "anthropic/claude-sonnet-4-6",
    "messages": [
        {"role": "system", "content": "You are a concise assistant."},
        {"role": "user", "content": "What is diffuse optical tomography?"}
    ],
})
print(response.json()["choices"][0]["message"]["content"])
```

### Python (OpenAI SDK -- drop-in replacement)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:21891/v1",
    api_key="not-needed",  # proxy doesn't check keys
)

response = client.chat.completions.create(
    model="anthropic/claude-sonnet-4-6",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(response.choices[0].message.content)
```

### JavaScript / Node.js

```javascript
const response = await fetch("http://127.0.0.1:21891/v1/chat/completions", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    model: "anthropic/claude-sonnet-4-6",
    messages: [{ role: "user", content: "Hello from Node!" }],
  }),
});
const data = await response.json();
console.log(data.choices[0].message.content);
```

### curl (one-liner)

```bash
curl -s http://127.0.0.1:21891/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"anthropic/claude-haiku-4-5","messages":[{"role":"user","content":"Say hi"}]}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])"
```

### From a remote machine (SSH tunnel)

If you want to access the proxy from a remote server (e.g., an HPC cluster):

```bash
# On the remote machine, create a tunnel to your laptop
ssh -L 21891:localhost:21891 your-laptop-hostname

# Now requests on the remote machine hit your laptop's proxy
curl http://localhost:21891/health
```

### From other devices on your network

The proxy binds to `0.0.0.0`, so any device on your local network can reach it. Find your IP:

```bash
ipconfig getifaddr en0   # macOS
```

Then from any device:

```bash
curl http://YOUR_IP:21891/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"anthropic/claude-haiku-4-5","messages":[{"role":"user","content":"Hello from my phone!"}]}'
```

## Running as a Background Service (macOS)

### Install as a launchd agent

```bash
# Create the plist
cat > ~/Library/LaunchAgents/com.autolog.llm-proxy.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.autolog.llm-proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/llm-proxy/run.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/path/to/llm-proxy</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/tmp/claude-proxy.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-proxy.err</string>
</dict>
</plist>
EOF

# Load it
launchctl load ~/Library/LaunchAgents/com.autolog.llm-proxy.plist
```

### The run.sh wrapper (critical for launchd)

launchd does NOT load your shell profile, so Homebrew binaries and `~/.local/bin` tools (including `claude`) are invisible. The `run.sh` script must set PATH explicitly:

```bash
#!/bin/bash
set -euo pipefail

# launchd doesn't load shell profile -- add ALL custom paths
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/opt/python@3.11/libexec/bin:/usr/local/bin:$PATH"

cd "$(dirname "$0")"
exec python3 claude_proxy.py --port 21891
```

Without this, the proxy will start but every request will fail with "claude CLI not found on PATH" -- the health check passes but nothing works. This is the #1 gotcha.

### Managing the service

```bash
# Restart
launchctl kickstart -k gui/$(id -u)/com.autolog.llm-proxy

# Stop
launchctl bootout gui/$(id -u)/com.autolog.llm-proxy

# Check status
launchctl list com.autolog.llm-proxy

# View logs
tail -f /tmp/claude-proxy.log
```

## Architecture

```
Your app/script
     |
     | POST /v1/chat/completions (OpenAI format)
     v
+------------------+
| Claude Proxy     |
| (Python HTTP)    |
|                  |
| - Parse request  |
| - Check cache    |
| - Priority queue |
| - Rate limit     |
+------------------+
     |
     | stdin/stdout (JSON)
     v
+------------------+
| claude -p        |
| (subprocess)     |
|                  |
| Uses your Claude |
| Code subscription|
+------------------+
     |
     | Anthropic API
     v
   Claude
```

### Priority Queue

Requests are routed to two priority tiers:

- **High priority**: Sonnet and Opus requests (interactive/enrichment use)
- **Low priority**: Haiku requests (background summarization)

High-priority requests always drain first, so your interactive Sonnet queries never get stuck behind a batch of Haiku summarization calls.

### Caching

Identical requests (same model + system prompt + user text) return cached responses instantly. The cache is in-memory and resets on restart. Cache hits show in `/stats`.

### Concurrency

Up to 5 `claude -p` subprocesses run in parallel. Each has a 5-minute timeout. The priority queue ensures fair scheduling across concurrent requests.

## Configuration

Edit `claude_proxy/server.py` to change defaults:

| Setting | Default | Description |
|---------|---------|-------------|
| `HOST` | `0.0.0.0` | Bind address. Use `127.0.0.1` to restrict to localhost |
| `DEFAULT_PORT` | `11434` | Listen port (overrideable with `--port`) |
| `SUBPROCESS_TIMEOUT` | `300` | Max seconds per `claude -p` call |
| `MAX_CONCURRENT` | `5` | Max parallel subprocess calls |

## Cost

This uses your Claude Code subscription (Claude Max or pay-as-you-go). There is no additional cost beyond your existing plan. The proxy tracks estimated token usage via `/stats` so you can monitor consumption.

## Limitations

- No streaming (responses are returned complete, not streamed)
- Token counts are estimates (based on char count / 4), not exact
- No function calling / tool use pass-through (single-turn text only)
- Cache is in-memory only (lost on restart)
- No authentication on the proxy itself (secure via network/firewall)

## License

MIT
