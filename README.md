# Twitch Monitor

[![Lint](https://github.com/simple-mind-dotcom/monitor/actions/workflows/lint.yml/badge.svg)](https://github.com/simple-mind-dotcom/monitor/actions/workflows/lint.yml)

A Windows tray application that watches your favourite Twitch channels and automatically records their
livestreams with [yt-dlp](https://github.com/yt-dlp/yt-dlp). Also supports one-off video (mp4) and music (mp3)
downloads by URL. Built with Windows PowerShell 5.1 — no runtime dependencies beyond yt-dlp and FFmpeg.

**Deutsch:** [README.de.md](README.de.md)

## Features
- **Automatic recording** of configured channels: recording starts shortly after the stream goes live and
  is stopped and remuxed to `.mp4` when it ends.
- **Tray icon** with live status per channel (grey = watching, red = recording, orange = paused) and a
  context menu with full control — live status is even shown for disabled channels. Each channel entry
  expands directly to its controls: a "Überwachen" toggle (start/stop monitoring) and
  "Anschauen" (open the live stream in your player — playback is tray-only).
- **Modern GUI** (light/dark aware WinForms): channels with live status, downloads, a settings editor
  (writes `configs/config.json`; includes channels, folders and programmes, `pollInterval`,
  `minFreeDiskSpaceGB`, `logLevel` and the Twitch credentials), yt-dlp config pages and a log viewer.
- **Single downloads**: video (mp4) or music (mp3) from any URL via tray menu or GUI; running downloads
  can be cancelled.
- **Stream playback** via [streamlink](https://streamlink.github.io/) without recording: expand a channel
  in the tray menu and pick "Anschauen" to open the live stream in your player — with quality selection
  (best, 1080p60, …, worst, audio only).
- **Robust Twitch API handling**: token caching, exponential backoff on rate limits (HTTP 429), server
  errors and network problems (`Retry-After` is honoured) — recovers on its own, no restart needed.
- **Disk space guard**: no new recordings when free space on the target drive drops below
  `minFreeDiskSpaceGB`; the GUI shows the remaining space colour-coded.
- **Clean logging** (`logs/monitor.log`, per-channel logs): only relevant events by default, routine
  details available with `"logLevel": "DEBUG"`; empty yt-dlp logs of clean runs are removed automatically.
- **yt-dlp age check**: warns at startup when the installed yt-dlp is older than 30 days. The tray menu item
  "yt-dlp aktualisieren" runs `scoop update yt-dlp` in the background with one click and re-checks the
  version afterwards.
- **Stream playback details**: playback is non-blocking; a failed playback (e.g. channel offline) is
  reported via notification. Playback keeps running after "Beenden (App)" — like recordings — and can be
  stopped any time from the same menu.
- **Single instance** per session and autostart via Windows Task Scheduler.

## Requirements
- Windows 10/11 (only tested on Windows 11)
- Windows PowerShell 5.1 (built into Windows)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) and FFmpeg on the `PATH`, e.g. via
  [scoop](https://scoop.sh): `scoop install yt-dlp ffmpeg`
- Optional for stream playback: [streamlink](https://streamlink.github.io/) on the `PATH`
  (`scoop install streamlink`). It opens the stream in its default/configured player (e.g. VLC) —
  or set `playback.playerPath` in `configs/config.json` to your preferred player.

## Setup
1. Clone or download this repository.
2. Copy `configs/config.example.json` to `configs/config.json` (the real file is intentionally not in
   the repository).
3. Create a free Twitch API application at https://dev.twitch.tv/console
   (OAuth redirect URL: `http://localhost`, category e.g. "Application Integration") and enter
   `twitchClientId` / `twitchClientSecret` in `configs/config.json`.
4. Check `channels`, `pollInterval` (minimum 15 s), `twitchConfigPath` and `outputDirectory` in
   `configs/config.json`. The yt-dlp configs for recordings and downloads ship as examples in `configs/`.

## Start
Run `TwitchMonitor_starten.vbs` (create a shortcut if you like), or start it manually:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1
```

The app lives in the system tray; double-click the icon (or use `-ShowWindow`) to open the main window.

## Autostart (Task Scheduler)
Register autostart for the current user:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1 -InstallAutoStart
```
Remove it again:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1 -RemoveAutoStart
```

## Configuration (`configs/config.json`)

| Key | Meaning | Default |
|---|---|---|
| `channels` | Twitch channel names (a–z, 0–9, `_`), one entry per channel | – |
| `pollInterval` | Polling interval in seconds (15–3600) | 60 |
| `twitchConfigPath` | yt-dlp config used for recordings | `~/scoop/apps/yt-dlp/twitch.conf` |
| `outputDirectory` | Folder for recordings (one subfolder per channel) | `~/Videos/twitch` |
| `ytDlpPath` | Path or command name of yt-dlp | `yt-dlp` |
| `ffmpegPath` | Path or command name of ffmpeg (remux, mp3 conversion) | `ffmpeg` |
| `twitchClientId` / `twitchClientSecret` | Twitch API access (https://dev.twitch.tv/console) | – |
| `minFreeDiskSpaceGB` | Minimum free disk space for starting new recordings (0 = check off) | 5 |
| `logLevel` | `INFO` (relevant events only) or `DEBUG` (adds routine details) | `INFO` |
| `downloads.videoConfigPath` / `musicConfigPath` | yt-dlp configs for single downloads | `configs/download_*.conf` |
| `downloads.videoDirectory` / `musicDirectory` | Target folders for single downloads | `~/Videos/downloads` resp. `~/Music/downloads` |
| `playback.streamlinkPath` | Path or command name of streamlink (stream playback) | `streamlink` |
| `playback.playerPath` | Player for stream playback; empty = streamlink's own default/configured player | – |
| `playback.quality` | Default quality for stream playback (e.g. `best`, `1080p60`, `worst`, `audio_only`) | `best` |

Relative paths are resolved from the project folder, `~` points to the user profile.

## Known limitations
- With `--hls-use-mpegts` (twitch.conf), stopping via Ctrl+C leaves a `.part` file (MPEG-TS). The monitor
  then remuxes it with `ffmpeg -c copy` to `.mp4` (see `ffmpegPath` in `configs/config.json`). Such files
  lack embedded metadata/thumbnails; if the stream ends normally, yt-dlp handles everything itself.
- `--cookies-from-browser firefox` (twitch.conf) can fail while Firefox is running or the profile is
  locked. In that case check the yt-dlp error in `<channel>.ytdlp.err.log`.

## Development & tests
- Pester tests (pure helper functions): `Invoke-Pester -Path ./tests`
- CI (GitHub Actions): PSScriptAnalyzer + Pester on every push/PR

## License
[MIT](LICENSE) — © 2026 simple-mind-dotcom
