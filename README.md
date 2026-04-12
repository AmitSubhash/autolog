# AutoLog

Your screen, understood.

```bash
brew install --cask AmitSubhash/tap/autolog
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

## Focus workflow

AutoLog can also track declared focus blocks, not just passive activity. The model is simple:

- **Emacs/Org owns intent** -- what you said you were trying to do
- **AutoLog owns evidence** -- what apps, sessions, and artifacts actually happened

This creates a useful separation: planning lives in Org, but productivity and drift are judged from captured behavior.

AutoLog now binds focus blocks directly into runtime data:

- captures record the active `focus_block_id`
- app sessions split when the focus block changes
- summaries and inferred activities carry `focus_block_id`
- summaries and activities also carry `focus_alignment` (`on_task`, `task_adjacent`, `off_task`, `recovered`)
- study-oriented summaries and activities carry `study_coverage` (resource, sections, concepts)

That means newer focus blocks are linked directly in the database, while older blocks still fall back to time-overlap matching for reports and vault sync.

### File contract

Focus blocks are stored as small local files:

- `~/.config/autolog/focus-state.json` -- the current active block
- `~/.config/autolog/focus-blocks.jsonl` -- completed/interrupted block history
- `~/org/today.org` -- lightweight todo list + warm-start note

When you start a block, Emacs writes the declared task, done condition, artifact goal, and drift budget. When you stop a block, AutoLog appends the finalized block to the log and optionally records a short `tomorrow starts with` note to preserve momentum.

### Emacs commands

The helper script lives at `scripts/autolog-focus.el` and is intended to be loaded from your Doom config. The default keybindings are:

```text
SPC n z s  start focus block
SPC n z e  stop focus block
SPC n z t  show current active block
SPC n z l  show recent blocks
SPC n z p  show productivity summary
SPC n z d  open today dashboard
```

Starting a block prompts for:

- task
- artifact goal
- drift budget in minutes
- optional done condition

Stopping a block prompts for:

- actual artifact
- tomorrow's first step
- optional notes on drift or execution

### Productivity metrics

Recent productivity is computed directly from focus-block history. The report currently tracks:

- total blocks
- completed vs interrupted vs abandoned
- completion rate
- artifact rate
- total focus time
- completed focus time
- average block length
- deep blocks (`>=60m`)
- completed-day streak
- daily breakdown

This is meant to answer two different questions:

- `recent blocks` -- am I actually finishing blocks?
- `productivity summary` -- is the week producing real artifacts or just motion?

## Architecture

| Component | What it does |
|-----------|-------------|
| `ScreenCapture.swift` | Screenshots via `CGDisplayCreateImage` with Screen Recording permission |
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
GET  /v1/focus/current      -- active focus block + drift snapshot
GET  /v1/focus/blocks       -- recent focus block history
GET  /v1/focus/blocks/:id/report -- block-level coverage, drift, app usage, resume hint
POST /v1/search             -- full-text search across summaries
POST /v1/semantic-search    -- TF-IDF similarity search
```

Focus-aware summary and activity payloads now include:

- `focus_block_id`
- `focus_alignment`
- `study_coverage`

## Setup

### Requirements

- macOS 14+ (Sonoma or later)
- Swift 6.0+
- Accessibility permission (for window titles)
- A `claude -p` proxy running locally for LLM calls (or OpenRouter API key)

### Build and run

```bash
# Install the app bundle to /Applications and launch it
make install-app

# Or build a local app bundle and launch it without installing
make run-bundle
```

Grant Screen Recording and Accessibility when prompted. For reliable Screen Recording registration on macOS, launch the bundled app with `make install-app` or `make run-bundle`, not the raw executable.

### Obsidian sync

```bash
# Sync last 4 hours to vault
python3 scripts/obsidian-sync.py 4
```

Set up as a launchd agent for automatic sync (plist templates in `launchd/`).

### Launchd app agent

Install the bundled AutoLog login agent with:

```bash
./scripts/install-launchd.sh
```

The app agent is configured to wait on the app process, restart it after
crashes, and write logs to:

- `~/Library/Logs/autolog-app.log`
- `~/Library/Logs/autolog-app.err`

Check its state with:

```bash
launchctl print gui/$(id -u)/com.autolog.app
```

### Focus block CLI

```bash
# Start a block
python3 scripts/focus_state.py start --task "Write preprocessing note" \
  --done-when "one final draft exists" \
  --artifact-goal "saved note" \
  --drift-budget 10

# Show current block
python3 scripts/focus_state.py status

# Show recent blocks
python3 scripts/focus_state.py list --include-open --limit 10

# Show 7-day productivity summary
python3 scripts/focus_state.py productivity --days 7

# Create today's lightweight todo file
python3 scripts/focus_state.py today
```

### Configuration

AutoLog uses `UserDefaults` for configuration. Key settings:

| Setting | Default | What it controls |
|---------|---------|-----------------|
| `llmEndpointURL` | -- | LLM proxy URL (e.g., `http://127.0.0.1:11434/v1/chat/completions`) |
| `captureSpeed` | `medium` | Capture frequency floor: `fast` (8s), `medium` (15s), `slow` (30s) |
| `adaptiveIntervalEnabled` | `true` | Back off capture rate when screen is idle |
| `apiServerPort` | `21890` | Local API server port |
| `summarizedCaptureRetentionHours` | `24` | Delete raw captures this many hours after they are summarized |

### Focus Reports

For any completed focus block, AutoLog can now build a report that combines:

- overlapping summaries
- overlapping sessions
- inferred activities
- app usage during the block
- covered sections and concepts
- drift segments
- a resume hint

This works best for blocks created after direct `focus_block_id` linkage was added, but older blocks are still supported through time-overlap fallback.

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
- Summarized captures are pruned after 24 hours by default; summaries persist indefinitely
- No telemetry, no analytics, no network calls except to your LLM proxy

## Credits

Forked from [thesophiaxu/contextd](https://github.com/thesophiaxu/contextd). Activity knowledge graph, enhanced OCR, Obsidian integration, and ScreenCaptureKit migration by [Amit Subhash](https://github.com/AmitSubhash).

## License

MIT
