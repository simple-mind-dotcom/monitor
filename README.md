# Twitch Monitor

PowerShell 5.1, scoop, yt-dlp und FFmpeg. Keine weiteren Abhängigkeiten.

## Einrichtung
1. `configs/config.example.json` nach `configs/config.json` kopieren (die Datei ist absichtlich nicht im Repo).
2. **Twitch-API-Zugang** (kostenlos): auf https://dev.twitch.tv/console eine Anwendung registrieren
   (OAuth Redirect URL: `http://localhost`, Kategorie z. B. "Application Integration") und
   `twitchClientId` / `twitchClientSecret` in `configs/config.json` eintragen.
3. `configs/config.json` prüfen: `channels`, `pollInterval` (min. 15 Sekunden), `twitchConfigPath`, `outputDirectory`.
4. `yt-dlp` und `ffmpeg` müssen im PATH liegen (`scoop install yt-dlp ffmpeg`).

## Start
1. `TwitchMonitor_starten.vbs` ausführen. Bei Bedarf einfach einen Shortcut erstellen.
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
- Tray-Icon: grau = überwacht, rot = Aufnahme läuft, orange = pausiert. Rechtsklick zeigt Status je Kanal
  (live/Aufnahme zuerst; auch deaktivierte Kanäle werden mit abgefragt und zeigen ihren Live-Status).
- Optionen: erweiterte Optionen in GUI verfügbar.
- Logs in `logs\`: `monitor.log`, `<kanal>.log`, sowie die yt-dlp-Ausgabe `<kanal>.ytdlp.out.log` / `.err.log`
  (ffmpeg-Logausgabe ist auf Warnungen/Fehler reduziert, damit die err.log klein bleibt).
  Der Log umfasst nur relevante Ereignisse (Start/Stop der Aufnahme, WARN/ERROR); Routine-Details stehen
  mit `"logLevel": "DEBUG"` in `configs/config.json` zusätzlich zur Verfügung. Leere yt-dlp-Logs sauber gelaufener
  Aufnahmen werden automatisch gelöscht.
- Twitch-API: Bei Rate-Limit (HTTP 429), Serverfehlern oder Netzwerkproblemen (z. B. DNS) wartet der Monitor
  mit exponentiellem Backoff (max. 30 min, `Retry-After` wird beachtet), bevor er erneut abfragt.
  Sobald die Verbindung wieder steht, wird normal weitergemacht - ein Eingriff ist nicht nötig.
- Speicherplatz: Startet keine neue Aufnahme, wenn auf dem Ziel-Laufwerk weniger als `minFreeDiskSpaceGB`
  (Standard 5) frei sind, und warnt per Benachrichtigung.
- yt-dlp: Ist die installierte Version älter als 30 Tage, gibt es beim Start eine Warnung
  (Twitch-Extraktion bricht bei Änderungen regelmäßig; `scoop update yt-dlp`).

## Bekannte Grenzen
- Nur unter Windows 11 auf Lauffähigkeit getestet.
- Mit `--hls-use-mpegts` (twitch.conf) bleibt nach einem Stopp per Ctrl+C eine `.part`-Datei (MPEG-TS) übrig.
  Das Monitor-Skript remuxt sie danach per `ffmpeg -c copy` zu `.mp4` (optional `ffmpegPath` in `configs/config.json`).
  Eingebettete Metadaten/Thumbnail fehlen bei solchen Dateien; endet der Stream normal, erledigt yt-dlp alles selbst.
- `--cookies-from-browser firefox` (twitch.conf) kann scheitern, während Firefox läuft oder das Profil gesperrt ist.
  In dem Fall yt-dlp-Fehlermeldung in `<kanal>.ytdlp.err.log` prüfen.
