# AutoLog

Your screen, understood.

```bash
brew tap AmitSubhash/tap
brew install autolog
```

AutoLog is a macOS menu bar app that watches what you do on your computer and builds a searchable activity knowledge graph from it. It captures your screen via OCR, infers what you're working on using an LLM, connects related activities across apps, and syncs everything to an Obsidian vault as linked notes.

Think of it as ambient memory for your workday -- not a surveillance tool, but a personal context engine that remembers what you were doing, in which apps, with which files, so you never lose track.

## What it captures

Every few seconds, AutoLog takes a screenshot, runs full-screen OCR, and extracts:

- **Screen text** -- everything visible, not just the active window
- **App metadata** -- which app is frontmost, its window title, document path, browser URL
- **All visible windows** -- every app with a window open, via Accessibility API
- **Focused element** -- what UI element has keyboard focus (text field, web area, etc.)

This raw data flows through a pipeline:

```
screenshot --> OCR --> capture record --> summarization (Haiku) --> activity inference --> Obsidian sync
                                              |                          |
                                         app sessions              knowledge graph
                                       (time per app)          (cross-activity links)
```

## The knowledge graph

AutoLog doesn't just store flat summaries. It builds structure:

**App Sessions** -- contiguous stretches of using one app, with aggregated metadata (all window titles, document paths, URLs seen during the session).

**Activities** -- LLM-inferred tasks that span one or more app sessions. "Debugging the capture pipeline" might involve Terminal (building), Safari (reading docs), and Xcode (editing code) -- AutoLog groups these into one coherent activity.

**Cross-activity links** -- activities connected by shared files, URLs, or topics. If you edited `CaptureEngine.swift` in two different sessions hours apart, AutoLog links those activities.

**Entities** -- files, URLs, and topics extracted from activities, queryable independently ("show me everything involving this file").

## Obsidian integration

AutoLog syncs to an Obsidian vault with `[[wikilinks]]` so you can explore your work history in Obsidian's graph view:

- **Activity notes** -- named by what you did, not when. Each note includes the apps used, files touched, URLs visited, and related activities.
- **App notes** -- per-app usage stats, recent windows, files, and activities.
- **Topic notes** -- every extracted topic links back to the activities where it appeared.
- **Daily notes** -- app usage table + activity list for the day.

## Architecture

| Component | What it does |
|-----------|-------------|
| `ScreenCapture.swift` | Screenshots via `/usr/sbin/screencapture` CLI (avoids macOS Sequoia permission re-prompts) |
| `OCRProcessor.swift` | Full-screen text recognition via Apple Vision framework |
| `AccessibilityReader.swift` | Window titles and app metadata via AXUIElement + NSWorkspace |
| `AppMetadataReader.swift` | Document paths, URLs, focused element role via Accessibility API |
| `AppSessionDetector.swift` | Real-time app session boundary detection (actor) |
| `SummarizationEngine.swift` | 5-min chunk summarization via Haiku LLM (activity type, files, URLs, topics) |
| `ActivityInferenceEngine.swift` | Batched LLM inference to group sessions into named activities |
| `ActivityGraphBuilder.swift` | Entity extraction and cross-activity link discovery |
| `obsidian-sync.py` | Vault sync with rich activity/app/topic/daily notes |

### Database

SQLite via GRDB with 10 migrations, FTS5 full-text search:

| Table | Purpose |
|-------|---------|
| `captures` | Raw OCR text + metadata per screenshot |
| `summaries` | LLM-generated summaries with activity type, files, URLs |
| `app_sessions` | Contiguous app usage stretches |
| `activities` | LLM-inferred named tasks |
| `activity_sessions` | M:N link between activities and sessions |
| `activity_entities` | Files, URLs, topics per activity |
| `activity_links` | Cross-activity connections |

### API

Local HTTP API on port 21890:

```
GET  /v1/summaries          -- recent summaries
GET  /v1/sessions           -- app sessions with metadata
GET  /v1/app-usage          -- time-per-app breakdown
GET  /v1/activities         -- inferred activities
GET  /v1/activities/:id/sessions  -- sessions for an activity
GET  /v1/activities/:id/related   -- related activities via links
GET  /v1/graph              -- full activity graph (nodes + edges)
GET  /v1/entities           -- query by entity type/value
POST /v1/search             -- full-text search across summaries
POST /v1/semantic-search    -- TF-IDF similarity search
```

## Setup

### Requirements

- macOS 14+ (Sonoma or later)
- Swift 6.0+
- Accessibility permission (for window titles)
- A `claude -p` proxy running locally for LLM calls (or OpenRouter API key)

### Build and run

```bash
# Build
swift build

# Create app bundle with icon
make bundle

# Launch
open .build/ContextD.app
```

Grant Accessibility permission when prompted. Screen Recording permission is handled automatically via the system `screencapture` CLI.

### Obsidian sync

```bash
# Sync last 4 hours to vault
python3 scripts/obsidian-sync.py 4
```

Set up as a launchd agent for automatic sync (plist templates in `launchd/`).

### Configuration

AutoLog uses `UserDefaults` for configuration. Key settings:

| Setting | Default | What it controls |
|---------|---------|-----------------|
| `llmEndpointURL` | -- | LLM proxy URL (e.g., `http://127.0.0.1:11434/v1/chat/completions`) |
| `captureSpeed` | `medium` | Capture frequency: `fast` (5s), `medium` (10s), `slow` (30s) |
| `adaptiveIntervalEnabled` | `true` | Back off capture rate when screen is idle |
| `apiServerPort` | `21890` | Local API server port |

## Cost

LLM calls go through a local `claude -p` proxy using Haiku:

- **Summarization**: ~$0.002/call, ~12 calls/hour = ~$0.58/day
- **Activity inference**: ~$0.002/call, ~4 calls/hour = ~$0.19/day
- **Total**: ~$0.77/day at typical usage

## Privacy

- All data stays local (SQLite database in `~/Library/Application Support/ContextD/`)
- Password managers and System Settings are excluded from capture by default
- AutoLog's own windows are excluded from screenshots
- LLM calls go through your local proxy, not to a third-party API
- Captures are pruned after 72 hours; summaries persist indefinitely
- No telemetry, no analytics, no network calls except to your LLM proxy

## Credits

Forked from [thesophiaxu/contextd](https://github.com/thesophiaxu/contextd). Activity knowledge graph, enhanced OCR, Obsidian integration, and ScreenCaptureKit migration by [Amit Subhash](https://github.com/AmitSubhash).

## License

MIT
