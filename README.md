# LapTracker (Assetto Corsa CSP Lua App)

LapTracker is a Lua app for Assetto Corsa (Custom Shaders Patch) that tracks lap times of selected drivers and sends results to Google Sheets through a Google Apps Script webhook.

## Quick Start

1. Copy this folder to `assettocorsa/apps/lua/LapTracker`.
2. Open `LapTracker.lua` and set `DEFAULT_WEBHOOK_URL` to your current Apps Script Web App URL (`.../exec`).
3. Optional: set `DEFAULT_SHEET_URL` to your Google Sheet URL.
4. Open `scripts.google`, copy it into a new Apps Script project, and deploy it as a Web App.
5. Use the deployed `/exec` URL in `DEFAULT_WEBHOOK_URL`.
6. Start the game, enable the Lua app, add tracked players, keep app state `ON`.
7. Drive a lap and verify a new row appears in Google Sheets.

## Features

- Track specific players in multiplayer sessions
- Send completed lap times to Google Sheets
- Open target Google Sheet directly from the app UI
- ON/OFF toggle in the app (quick enable/disable)
- In-app activity log with send status

## Requirements

- Assetto Corsa
- Custom Shaders Patch (CSP) with `web.post` support
- A deployed Google Apps Script Web App URL (`.../exec`)

## Files

- `LapTracker.lua`: main app logic and UI
- `manifest.ini`: app window registration and behavior
- `scripts.google`: Google Apps Script webhook code

## Installation

1. Copy this app folder to:
	- `assettocorsa/apps/lua/LapTracker`
2. Make sure CSP is installed and updated.
3. Launch Assetto Corsa and enable the Lua app in-game.

## Webhook Setup (Google Apps Script)

1. Create a new Apps Script project at `https://script.google.com`.
2. Replace project code with contents of `scripts.google`.
3. Set `SPREADSHEET_ID` to your Google Sheet ID in the script.
4. Deploy as Web App:
	- Execute as: `Me`
	- Access: `Anyone`
5. Copy the Web App URL that ends with `/exec`.
6. Paste it into `DEFAULT_WEBHOOK_URL` in `LapTracker.lua`.

Important:
- If you get HTTP `404`, your deployment URL is invalid/old.
- After each Apps Script change, redeploy and use the latest `/exec` URL.

## Configuration

Edit these constants in `LapTracker.lua`:

- `DEFAULT_WEBHOOK_URL`: Google Apps Script Web App endpoint
- `DEFAULT_SHEET_URL`: optional Google Sheets URL for the "Open Sheet" button

## Usage

1. Open the app in-game.
2. Add drivers to tracking (from session list or manually).
3. Keep app state as `ON`.
4. Drive laps: tracked players' completed lap times are sent automatically.
5. Use "Open Sheet" to jump to the target Google Sheet.

## Data Format Sent to Webhook

The app sends JSON payloads like:

```json
{
  "nickname": "DriverName",
  "car": "car_id",
  "laptime": "1:48.234",
  "track": "monza"
}
```

## Troubleshooting

### "The URL does not use a recognized protocol"

Use a full URL starting with `https://`.

### "error sending (empty response)" or non-200 status

- Check Apps Script deployment access settings.
- Confirm the endpoint is exactly the `/exec` URL.
- Open the URL in browser to verify it exists.
- Check Apps Script `Executions` logs for runtime errors.

### Data not appearing in sheet

- Verify sheet ID/name in Apps Script.
- Confirm webhook receives POST and parses JSON.
- Ensure app is `ON` and the driver is in tracked list.

## Google Sheet Output

The webhook script writes lap rows with these columns:

- `Date`
- `Recorded At`
- `Nickname`
- `Car`
- `Lap Time`
- `Track`

It also builds a leaderboard block with best laps per track and deltas to the next driver.

## Security (Do Not Leak Keys)

- This repository is configured to keep `DEFAULT_WEBHOOK_URL` empty by default.
- Put real webhook URLs only in your local working copy.
- Do not commit files with real webhook URLs.
- `.gitignore` includes common local-secret file names and build artifacts.

## GitHub Auto Build (ZIP Artifact)

This repo contains a GitHub Actions workflow at `.github/workflows/build.yml`.

What it does:

- Runs on push/PR/manual trigger
- Fails if a hardcoded Google Apps Script webhook URL is detected in `LapTracker.lua`
- Builds a distributable ZIP (`LapTracker.zip`)
- Uploads it as a workflow artifact

How to use it:

1. Push your branch to GitHub.
2. Open Actions tab and run/inspect `Build LapTracker`.
3. Download the `LapTracker` artifact from the workflow run.

## Notes

- Player list and app state are stored persistently using `ac.storage`.
- The app is independent from any optional helper files; only the webhook endpoint is required for sending.
