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
- GUI: Per Doppelklick aufs Tray-Icon oder dessen Kontextmenu öffnen. Seiten: Übersicht (Kanäle/Aufnahmen),
  Downloads, Einstellungen (speichert `configs/config.json`, Sicherung: `.bak`), yt-dlp-Configs, Log.
- Einzeldownloads: Per Tray-Menü („Download (Link)…") oder GUI-Seite Downloads — Video (mp4) oder Musik (mp3).
  Die yt-dlp-Configs dafür liegen in `configs/download_video.conf` / `configs/download_music.conf`;
  laufende Downloads lassen sich in der GUI abbrechen.
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
  (Standard 5) frei sind, und warnt per Benachrichtigung. Die GUI zeigt den freien Speicher des
  Aufnahme-Laufwerks farbcodiert in der Übersicht an (gelb = unter dem doppelten Minimum, rot = unter dem Minimum).
- yt-dlp: Ist die installierte Version älter als 30 Tage, gibt es beim Start eine Warnung
  (Twitch-Extraktion bricht bei Änderungen regelmäßig; `scoop update yt-dlp`).
- yt-dlp: Ist die installierte Version älter als 30 Tage, gibt es beim Start eine Warnung
  (Twitch-Extraktion bricht bei Änderungen regelmäßig; `scoop update yt-dlp`).

## Konfiguration (`configs/config.json`)

| Schlüssel | Bedeutung | Standard |
|---|---|---|
| `channels` | Twitch-Kanalnamen (a–z, 0–9, `_`), ein Eintrag pro Kanal | – |
| `pollInterval` | Abfrageintervall in Sekunden (15–3600) | 60 |
| `twitchConfigPath` | yt-dlp-Config für Aufnahmen | `~/scoop/apps/yt-dlp/twitch.conf` |
| `outputDirectory` | Ordner für Aufnahmen (je Kanal ein Unterordner) | `~/Videos/twitch` |
| `ytDlpPath` | Pfad oder Befehlsname von yt-dlp | `yt-dlp` |
| `ffmpegPath` | Pfad oder Befehlsname von ffmpeg (Remux, mp3-Konvertierung) | `ffmpeg` |
| `twitchClientId` / `twitchClientSecret` | Twitch-API-Zugang (https://dev.twitch.tv/console) | – |
| `minFreeDiskSpaceGB` | Freier Speicherplatz, unter dem keine neuen Aufnahmen starten (0 = Check aus) | 5 |
| `logLevel` | `INFO` (relevante Ereignisse) oder `DEBUG` (zusätzlich Routine-Details) | `INFO` |
| `downloads.videoConfigPath` / `musicConfigPath` | yt-dlp-Configs für Einzeldownloads | `configs/download_*.conf` |
| `downloads.videoDirectory` / `musicDirectory` | Zielordner für Einzeldownloads | `~/Videos/downloads` bzw. `~/Music/downloads` |

Relative Pfade gelten ab dem Projektordner, `~` wird zum Benutzerprofil aufgelöst.

## Optionale Module
Die Features der App hängen daran, welche Moduldateien in `modules/` liegen. Fehlt eine Datei,
fällt das zugehörige Feature einfach weg (beim Start wird protokolliert, was deaktiviert ist) -
kein Umbau am Code nötig. Nur `Logging.psm1` und `Config.psm1` sind Pflicht.

| Moduldatei | Feature (unterschlagen wenn Datei fehlt) |
|---|---|
| `Recorder.psm1` | Aufnahmen starten/stoppen, Remux, Speicherplatzprüfung; ohne es zeigen Monitor/Tray/GUI nur den Live-Status |
| `Monitor.psm1` | Twitch-Abfrage (Live-Status), Kanalverwaltung, Pausieren/Fortsetzen, "Monitoring beenden" |
| `Downloader.psm1` | Einzeldownloads (Video/Musik): Tray-Eintrag "Download (Link)...", GUI-Seite Downloads |
| `Tray.psm1` | Tray-Icon und -Menü (ohne es läuft der Monitor unsichtbar bzw. im NoTray-Modus weiter) |
| `Startup.psm1` | Autostart (`-InstallAutoStart` / `-RemoveAutoStart`) |
| `Gui.psm1` | Hauptfenster (Tray-Doppelklick, `-ShowWindow`) |

Beispiele: `Recorder.psm1` löschen -> die App zeigt nur den Live-Status an, startet aber keine Aufnahmen.
`Tray.psm1` und `Gui.psm1` löschen -> reiner Kopflos-Betrieb (Konsole schließen beendet - Aufnahmen laufen weiter).

## Bekannte Grenzen
- Nur unter Windows 11 auf Lauffähigkeit getestet.
- Mit `--hls-use-mpegts` (twitch.conf) bleibt nach einem Stopp per Ctrl+C eine `.part`-Datei (MPEG-TS) übrig.
  Das Monitor-Skript remuxt sie danach per `ffmpeg -c copy` zu `.mp4` (optional `ffmpegPath` in `configs/config.json`).
  Eingebettete Metadaten/Thumbnail fehlen bei solchen Dateien; endet der Stream normal, erledigt yt-dlp alles selbst.
- `--cookies-from-browser firefox` (twitch.conf) kann scheitern, während Firefox läuft oder das Profil gesperrt ist.
  In dem Fall yt-dlp-Fehlermeldung in `<kanal>.ytdlp.err.log` prüfen.

## Entwicklung & Tests
- Pester-Tests (reine Hilfsfunktionen): `Invoke-Pester -Path ./tests`
- CI (GitHub Actions): PSScriptAnalyzer + Pester bei jedem Push/PR
