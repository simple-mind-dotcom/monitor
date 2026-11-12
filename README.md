# Twitch Monitor

PowerShell 5.1, scoop, yt-dlp und FFmpeg. Keine weiteren Abhängigkeiten.

## Einrichtung
1. **Twitch-API-Zugang** (kostenlos): auf https://dev.twitch.tv/console eine Anwendung registrieren
   (OAuth Redirect URL: `http://localhost`, Kategorie z. B. "Application Integration") und
   `twitchClientId` / `twitchClientSecret` in `config.json` eintragen.
2. `config.json` prüfen: `channels`, `pollInterval` (min. 15 Sekunden), `twitchConfigPath`, `outputDirectory`.
3. `yt-dlp` und `ffmpeg` müssen im PATH liegen (`scoop install yt-dlp ffmpeg`).

## Start
1. `start.vbs` ausführen. Bei Bedarf einfach einen Shortcut erstellen.
2. Per powershell Befehl:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1
```

## Autostart (Task Scheduler)
Autostart hinzufügen:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1 -InstallAutoStart
```
Autostart entfernen:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1 -RemoveAutoStart
```

## Verhalten
- GUI: Per Doppelklick aufs Tray-Icon oder dessen Kontextmenu öffnen
- Tray-Icon: grau = überwacht, rot = Aufnahme läuft, orange = pausiert. Rechtsklick zeigt Status je Kanal.
- Optionen: erweiterte Optionen in GUI verfügbar.
- Logs in `logs\`: `monitor.log`, `<kanal>.log`, sowie die yt-dlp-Ausgabe `<kanal>.ytdlp.out.log` / `.err.log`

## Bekannte Grenzen
- Nur unter Windows 11 auf Lauffähigkeit getestet.
- Mit `--hls-use-mpegts` (twitch.conf) bleibt nach einem Stopp per Ctrl+C eine `.part`-Datei (MPEG-TS) übrig.
  Das Monitor-Skript remuxt sie danach per `ffmpeg -c copy` zu `.mp4` (optional `ffmpegPath` in `config.json`).
  Eingebettete Metadaten/Thumbnail fehlen bei solchen Dateien; endet der Stream normal, erledigt yt-dlp alles selbst.
