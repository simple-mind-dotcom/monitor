# Twitch Monitor

[![Lint](https://github.com/simple-mind-dotcom/monitor/actions/workflows/lint.yml/badge.svg)](https://github.com/simple-mind-dotcom/monitor/actions/workflows/lint.yml)

Windows-Tray-Anwendung, die konfigurierte Twitch-Kan\u00e4le \u00fcberwacht und deren Livestreams automatisch mit
[yt-dlp](https://github.com/yt-dlp/yt-dlp) aufnimmt. Au\u00dferdem m\u00f6glich: Einzeldownloads als Video (mp4) oder
Musik (mp3) per URL. Geschrieben in Windows PowerShell 5.1 \u2014 als Laufzeitabh\u00e4ngigkeiten braucht es nur
yt-dlp und FFmpeg.

**English:** [README.md](README.md)

## Funktionen
- **Automatische Aufnahmen** der konfigurierten Kan\u00e4le: Die Aufnahme startet kurz nachdem der Stream live
  geht und wird beim Ende gestoppt und zu `.mp4` remuxt.
- **Tray-Icon** mit Live-Status je Kanal (grau = \u00fcberwacht, rot = Aufnahme l\u00e4uft, orange = pausiert) und
  Kontextmen\u00fc mit allen Steuerungen \u2014 der Live-Status wird auch f\u00fcr deaktivierte Kan\u00e4le angezeigt.
- **Moderne GUI** (WinForms, folgt Hell-/Dunkelmodus): Kan\u00e4le mit Live-Status, Downloads, Einstellungs-Editor
  (schreibt `configs/config.json`), yt-dlp-Configs und Log-Ansicht.
- **Einzeldownloads**: Video (mp4) oder Musik (mp3) von beliebigen URLs \u00fcber Tray-Men\u00fc oder GUI; laufende
  Downloads lassen sich abbrechen.
- **Robuste Twitch-API-Anbindung**: Token-Caching, exponentieller Backoff bei Rate-Limits (HTTP 429),
  Serverfehlern und Netzwerkproblemen (`Retry-After` wird beachtet) \u2014 erholt sich selbst\u00e4ndig, kein Neustart n\u00f6tig.
- **Speicherplatzschutz**: Keine neuen Aufnahmen, wenn auf dem Ziel-Laufwerk weniger als
  `minFreeDiskSpaceGB` frei sind; die GUI zeigt den freien Speicher farbcodiert an.
- **Schlankes Logging** (`logs/monitor.log`, Kanal-Logs): Standardm\u00e4\u00dfig nur relevante Ereignisse, Routine-Details
  mit `"logLevel": "DEBUG"`; leere yt-dlp-Logs sauber gelaufener Aufnahmen werden automatisch gel\u00f6scht.
- **yt-dlp-Alterpr\u00fcfung**: Warnt beim Start, wenn die installierte yt-dlp-Version \u00e4lter als 30 Tage ist.
- **Einzelinstanz** pro Sitzung und Autostart \u00fcber Windows Task Scheduler.

## Voraussetzungen
- Windows 10/11 (getestet nur unter Windows 11)
- Windows PowerShell 5.1 (bestandteil von Windows)
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) und FFmpeg im `PATH`, z. B. per
  [scoop](https://scoop.sh): `scoop install yt-dlp ffmpeg`

## Einrichtung
1. Repository klonen oder herunterladen.
2. `configs/config.example.json` nach `configs/config.json` kopieren (die echte Datei ist absichtlich
   nicht im Repo).
3. Kostenlos eine Twitch-API-Anwendung unter https://dev.twitch.tv/console registrieren
   (OAuth-Redirect-URL: `http://localhost`, Kategorie z. B. "Application Integration") und
   `twitchClientId` / `twitchClientSecret` in `configs/config.json` eintragen.
4. `channels`, `pollInterval` (mindestens 15 Sekunden), `twitchConfigPath` und `outputDirectory` in
   `configs/config.json` pr\u00fcfen. Die yt-dlp-Configs f\u00fcr Aufnahmen und Downloads liegen als Beispiele unter `configs/`.

## Start
`TwitchMonitor_starten.vbs` ausf\u00fchren (Shortcut erstellen bei Bedarf), oder manuell:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1
```

Die App l\u00e4uft im System-Tray; Doppelklick aufs Icon (oder Start mit `-ShowWindow`) \u00f6ffnet das Hauptfenster.

## Autostart (Task Scheduler)
Autostart f\u00fcr die Benutzeranmeldung registrieren:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1 -InstallAutoStart
```
Autostart entfernen:
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\twitch_monitor.ps1 -RemoveAutoStart
```

## Konfiguration (`configs/config.json`)

| Schl\u00fcssel | Bedeutung | Standard |
|---|---|---|
| `channels` | Twitch-Kanalnamen (a\u2013z, 0\u20139, `_`), ein Eintrag pro Kanal | \u2013 |
| `pollInterval` | Abfrageintervall in Sekunden (15\u20133600) | 60 |
| `twitchConfigPath` | yt-dlp-Config f\u00fcr Aufnahmen | `~/scoop/apps/yt-dlp/twitch.conf` |
| `outputDirectory` | Ordner f\u00fcr Aufnahmen (je Kanal ein Unterordner) | `~/Videos/twitch` |
| `ytDlpPath` | Pfad oder Befehlsname von yt-dlp | `yt-dlp` |
| `ffmpegPath` | Pfad oder Befehlsname von ffmpeg (Remux, mp3-Konvertierung) | `ffmpeg` |
| `twitchClientId` / `twitchClientSecret` | Twitch-API-Zugang (https://dev.twitch.tv/console) | \u2013 |
| `minFreeDiskSpaceGB` | Freier Speicherplatz, unter dem keine neuen Aufnahmen starten (0 = Check aus) | 5 |
| `logLevel` | `INFO` (nur relevante Ereignisse) oder `DEBUG` (zus\u00e4tzlich Routine-Details) | `INFO` |
| `downloads.videoConfigPath` / `musicConfigPath` | yt-dlp-Configs f\u00fcr Einzeldownloads | `configs/download_*.conf` |
| `downloads.videoDirectory` / `musicDirectory` | Zielordner f\u00fcr Einzeldownloads | `~/Videos/downloads` bzw. `~/Music/downloads` |

Relative Pfade gelten ab dem Projektordner, `~` wird zum Benutzerprofil aufgel\u00f6st.

## Bekannte Grenzen
- Mit `--hls-use-mpegts` (twitch.conf) bleibt nach einem Stopp per Ctrl+C eine `.part`-Datei (MPEG-TS) \u00fcbrig.
  Das Monitor-Skript remuxt sie danach per `ffmpeg -c copy` zu `.mp4` (siehe `ffmpegPath` in `configs/config.json`).
  Eingebettete Metadaten/Thumbnails fehlen bei solchen Dateien; endet der Stream normal, erledigt yt-dlp alles selbst.
- `--cookies-from-browser firefox` (twitch.conf) kann scheitern, w\u00e4hrend Firefox l\u00e4uft oder das Profil gesperrt ist.
  In dem Fall die yt-dlp-Fehlermeldung in `<kanal>.ytdlp.err.log` pr\u00fcfen.

## Entwicklung & Tests
- Pester-Tests (reine Hilfsfunktionen): `Invoke-Pester -Path ./tests`
- CI (GitHub Actions): PSScriptAnalyzer + Pester bei jedem Push/PR

## Lizenz
[MIT](LICENSE) \u2014 \u00a9 2026 simple-mind-dotcom
