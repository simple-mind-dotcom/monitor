# Twitch Monitor

[![Lint](https://github.com/simple-mind-dotcom/monitor/actions/workflows/lint.yml/badge.svg)](https://github.com/simple-mind-dotcom/monitor/actions/workflows/lint.yml)

Windows-Tray-Anwendung, die konfigurierte Twitch-Kanäle überwacht und deren Livestreams automatisch mit
[yt-dlp](https://github.com/yt-dlp/yt-dlp) aufnimmt. Außerdem möglich: Einzeldownloads als Video (mp4) oder
Musik (mp3) per URL. Geschrieben in Windows PowerShell 5.1 — als Laufzeitabhängigkeiten braucht es nur
yt-dlp und FFmpeg.

**English:** [README.md](README.md)

## Funktionen
- **Automatische Aufnahmen** der konfigurierten Kanäle: Die Aufnahme startet kurz nachdem der Stream live
  geht und wird beim Ende gestoppt und zu `.mp4` remuxt.
- **Tray-Icon** mit Live-Status je Kanal (grau = überwacht, rot = Aufnahme läuft, orange = pausiert) und
  Kontextmenü mit allen Steuerungen — der Live-Status wird auch für deaktivierte Kanäle angezeigt. Jeder
  Kanal-Eintrag klappt direkt seine Steuerungen auf: "Überwachten"-Schalter (Monitoring an/aus) und
  "Anschauen" (Live-Stream im Player öffnen).
- **Moderne GUI** (WinForms, folgt Hell-/Dunkelmodus): Kanäle mit Live-Status, Downloads, Einstellungs-Editor
  (schreibt `configs/config.json`), yt-dlp-Configs und Log-Ansicht.
- **Einzeldownloads**: Video (mp4) oder Musik (mp3) von beliebigen URLs über Tray-Menü oder GUI; laufende
  Downloads lassen sich abbrechen.
- **Stream-Wiedergabe** per [streamlink](https://streamlink.github.io/) ohne Aufnahme: Rechtsklick auf einen
  Kanal in der GUI-Liste oder einen Kanal im Tray-Menü aufklappen und "Anschauen" wählen — der Live-Stream
  öffnet sich im Player, mit Qualitätsauswahl (best, 1080p60, …, worst, nur Audio).
- **Robuste Twitch-API-Anbindung**: Token-Caching, exponentieller Backoff bei Rate-Limits (HTTP 429),
  Serverfehlern und Netzwerkproblemen (`Retry-After` wird beachtet) — erholt sich selbständig, kein Neustart nötig.
- **Speicherplatzschutz**: Keine neuen Aufnahmen, wenn auf dem Ziel-Laufwerk weniger als
  `minFreeDiskSpaceGB` frei sind; die GUI zeigt den freien Speicher farbcodiert an.
- **Schlankes Logging** (`logs/monitor.log`, Kanal-Logs): Standardmäßig nur relevante Ereignisse, Routine-Details
  mit `"logLevel": "DEBUG"`; leere yt-dlp-Logs sauber gelaufener Aufnahmen werden automatisch gelöscht.
- **yt-dlp-Alterprüfung**: Warnt beim Start, wenn die installierte yt-dlp-Version älter als 30 Tage ist.
- **Wiedergabe-Details**: Sie blockiert nicht; eine fehlgeschlagene Wiedergabe (z. B. Kanal offline) wird
  per Benachrichtigung gemeldet. Nach „Beenden (App)" läuft sie wie Aufnahmen weiter und lässt sich jederzeit
  über dasselbe Menü stoppen.
- **Einzelinstanz** pro Sitzung und Autostart über Windows Task Scheduler.

## Voraussetzungen
- Windows 10/11 (getestet nur unter Windows 11)
- Windows PowerShell 5.1 (bestandteil von Windows)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) und FFmpeg im `PATH`, z. B. per
  [scoop](https://scoop.sh): `scoop install yt-dlp ffmpeg`
- Optional für die Wiedergabe: [streamlink](https://streamlink.github.io/) im `PATH`
  (`scoop install streamlink`). Es öffnet den Stream im von streamlink vorgegebenen/konfigurierten Player
  (z. B. VLC) — oder `playback.playerPath` in `configs/config.json` auf den bevorzugten Player setzen.

## Einrichtung
1. Repository klonen oder herunterladen.
2. `configs/config.example.json` nach `configs/config.json` kopieren (die echte Datei ist absichtlich
   nicht im Repo).
3. Kostenlos eine Twitch-API-Anwendung unter https://dev.twitch.tv/console registrieren
   (OAuth-Redirect-URL: `http://localhost`, Kategorie z. B. "Application Integration") und
   `twitchClientId` / `twitchClientSecret` in `configs/config.json` eintragen.
4. `channels`, `pollInterval` (mindestens 15 Sekunden), `twitchConfigPath` und `outputDirectory` in
   `configs/config.json` prüfen. Die yt-dlp-Configs für Aufnahmen und Downloads liegen als Beispiele unter `configs/`.

## Start
`TwitchMonitor_starten.vbs` ausführen (Shortcut erstellen bei Bedarf), oder manuell:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1
```

Die App läuft im System-Tray; Doppelklick aufs Icon (oder Start mit `-ShowWindow`) öffnet das Hauptfenster.

## Autostart (Task Scheduler)
Autostart für die Benutzeranmeldung registrieren:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1 -InstallAutoStart
```
Autostart entfernen:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1 -RemoveAutoStart
```

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
| `logLevel` | `INFO` (nur relevante Ereignisse) oder `DEBUG` (zusätzlich Routine-Details) | `INFO` |
| `downloads.videoConfigPath` / `musicConfigPath` | yt-dlp-Configs für Einzeldownloads | `configs/download_*.conf` |
| `downloads.videoDirectory` / `musicDirectory` | Zielordner für Einzeldownloads | `~/Videos/downloads` bzw. `~/Music/downloads` |
| `playback.streamlinkPath` | Pfad oder Befehlsname von streamlink (Wiedergabe) | `streamlink` |
| `playback.playerPath` | Player für die Wiedergabe; leer = streamlink-eigener Standard bzw. streamlink-Config | – |
| `playback.quality` | Standard-Qualität für die Wiedergabe (z. B. `best`, `1080p60`, `worst`, `audio_only`) | `best` |

Relative Pfade gelten ab dem Projektordner, `~` wird zum Benutzerprofil aufgelöst.

## Bekannte Grenzen
- Mit `--hls-use-mpegts` (twitch.conf) bleibt nach einem Stopp per Ctrl+C eine `.part`-Datei (MPEG-TS) übrig.
  Das Monitor-Skript remuxt sie danach per `ffmpeg -c copy` zu `.mp4` (siehe `ffmpegPath` in `configs/config.json`).
  Eingebettete Metadaten/Thumbnails fehlen bei solchen Dateien; endet der Stream normal, erledigt yt-dlp alles selbst.
- `--cookies-from-browser firefox` (twitch.conf) kann scheitern, während Firefox läuft oder das Profil gesperrt ist.
  In dem Fall die yt-dlp-Fehlermeldung in `<kanal>.ytdlp.err.log` prüfen.

## Entwicklung & Tests
- Pester-Tests (reine Hilfsfunktionen): `Invoke-Pester -Path ./tests`
- CI (GitHub Actions): PSScriptAnalyzer + Pester bei jedem Push/PR

## Lizenz
[MIT](LICENSE) — © 2026 simple-mind-dotcom
