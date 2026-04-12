# AutoLog Manual Smoke Checklist

Use this after UI, onboarding, focus workflow, or packaging changes.

## Launch

1. Launch the app bundle normally.
2. Prefer `make install-app` or `make run-bundle`, not the raw executable.
3. Confirm it reaches the menu bar without crashing.
4. Confirm repeated relaunches do not produce a new crash report.

## Permissions

1. Reset permissions if needed.
2. Launch the bundled app and verify it appears in Screen Recording and Accessibility.
3. Use the onboarding Grant buttons once the onboarding window is visible.
4. Confirm Screen Recording and Accessibility rows both resolve to granted.
5. Confirm a real capture succeeds after onboarding.

## Onboarding and Settings

1. Open onboarding on a clean install or reset environment.
2. Verify the onboarding window renders and can be completed.
3. Open Settings from the menu action.
4. Switch across tabs and resize the window.
5. Close and reopen Settings.

## Panels and Debug Windows

1. Open the enrichment panel and type into it.
2. Open the debug timeline window.
3. Open the side panel and leave it visible for at least 30 seconds.
4. Resize or move windows where applicable and confirm no layout crash occurs.

## Focus Workflow

1. Run `python3 scripts/focus_state.py today --force`.
2. Run `python3 scripts/focus_state.py start ...`.
3. Run `python3 scripts/focus_state.py stop --next-step ...`.
4. Confirm `~/.config/autolog/focus-blocks.jsonl` contains `next_step`.
5. Confirm `~/org/today.org` exists with the lightweight template.

## API and Summaries

1. Hit `/v1/focus/current` and `/v1/focus/blocks`.
2. Hit `/v1/focus/blocks/:id/report` for a recent completed block.
3. Confirm completed blocks return `next_step` and the report returns `covered_concepts`.
4. Confirm summary and activity payloads include `focus_block_id` for a live block.
5. Check capture, summary, and recent-activity cards in the menu UI.

## Verification Commands

```bash
swift test
python3 -m py_compile scripts/focus_state.py
bash -n scripts/dev.sh
```
