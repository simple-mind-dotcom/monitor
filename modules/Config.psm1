function Initialize-Config {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        $template = [ordered]@{
            channels = @('twitch')
            pollInterval = 60
            twitchConfigPath = "$env:USERPROFILE\scoop\apps\yt-dlp\twitch.conf"
            outputDirectory = "$env:USERPROFILE\Videos\twitch"
            ytDlpPath = 'yt-dlp'
            twitchClientId = ''
            twitchClientSecret = ''
        }
        $template | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
        Write-Log -Level WARN -Message "config.json fehlte und wurde mit einer Vorlage erstellt: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "config.json ist kein gültiges JSON: $($_.Exception.Message)"
    }

    # Kanalnamen normalisieren: Twitch-Logins sind klein geschrieben und bestehen nur aus [a-z0-9_].
    $channels = @()
    foreach ($entry in @($raw.channels)) {
        $name = ([string]$entry).Trim().ToLowerInvariant()
        if (-not $name) { continue }
        if ($name -notmatch '^[a-z0-9_]{1,25}$') {
            Write-Log -Level WARN -Message "Ungültiger Kanalname in config.json wird ignoriert: '$entry'"
            continue
        }
        if ($channels -notcontains $name) { $channels += $name }
    }

    $config = @{
        Channels = $channels
        PollInterval = if ($raw.pollInterval) { [int]$raw.pollInterval } else { 60 }
        TwitchConfigPath = [string]$raw.twitchConfigPath
        OutputDirectory = [string]$raw.outputDirectory
        YtDlpPath = [string]$raw.ytDlpPath
        FfmpegPath = if ($raw.ffmpegPath) { [string]$raw.ffmpegPath } else { 'ffmpeg' }
        TwitchClientId = [string]$raw.twitchClientId
        TwitchClientSecret = [string]$raw.twitchClientSecret
    }
	$projectRoot = Split-Path -Parent $PSScriptRoot
$resolve = {
    param($value, $default)
    $p = if ($value) { [string]$value } else { $default }
    if (-not [IO.Path]::IsPathRooted($p) -and $p -notmatch '^~') { $p = Join-Path $projectRoot $p }
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
}
$config.DownloadVideoConfigPath = & $resolve $raw.downloads.videoConfigPath 'configs\download_video.conf'
$config.DownloadMusicConfigPath = & $resolve $raw.downloads.musicConfigPath 'configs\download_music.conf'
$config.DownloadVideoDirectory  = & $resolve $raw.downloads.videoDirectory  "$env:USERPROFILE\Videos\downloads"
$config.DownloadMusicDirectory  = & $resolve $raw.downloads.musicDirectory  "$env:USERPROFILE\Music\downloads"

    # Relative Pfade (z. B. configs\twitch.conf) gelten ab dem Projektordner, nicht ab dem Arbeitsverzeichnis.
	$cfgRoot = Split-Path -Parent $PSScriptRoot
		if ($config.TwitchConfigPath -and -not [IO.Path]::IsPathRooted($config.TwitchConfigPath) -and $config.TwitchConfigPath -notmatch '^~') {
		$config.TwitchConfigPath = Join-Path $cfgRoot $config.TwitchConfigPath
	}
	# WICHTIG: Test-Config gibt $true in die Pipeline. Ohne $null = würde diese Funktion
    # @($true, $config) statt der Hashtable zurückgeben (Ursache des Fehlers im alten monitor.log).
    $null = Test-Config -Config $config

    # Umgebungsprobleme (fehlendes yt-dlp, fehlende Zugangsdaten ...) beenden die App nicht, sondern werden
    # im Tray angezeigt und verhindern den Start des Monitorings. @(): auch 0 oder 1 Eintrag bleibt ein Array.
    $config.EnvironmentErrors = @(Test-ConfigEnvironment -Config $config)
    return $config
}

function Test-Config {
    # Strukturelle Prüfung: Fehler hier sind nicht behebbar, ohne config.json zu ändern -> Ausnahme.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    if ($Config.Channels.Count -lt 1) { throw 'Mindestens ein gültiger Twitch-Kanal muss in channels stehen.' }
    if ($Config.PollInterval -lt 15) { throw 'pollInterval muss mindestens 15 Sekunden betragen.' }
    if ($Config.PollInterval -gt 3600) { throw 'pollInterval darf höchstens 3600 Sekunden betragen.' }
    if ([string]::IsNullOrWhiteSpace($Config.OutputDirectory)) { throw 'outputDirectory fehlt.' }
    if ([string]::IsNullOrWhiteSpace($Config.YtDlpPath)) { throw 'ytDlpPath fehlt.' }
    return $true
}

function Test-ConfigEnvironment {
    # Prüft, ob die Umgebung zur Konfiguration passt. Gibt die blockierenden Probleme als Textliste zurück
    # (leer = alles gut). Nicht blockierende Auffälligkeiten werden nur als WARN geloggt.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $problems = @()

    $id = $Config.TwitchClientId
    $secret = $Config.TwitchClientSecret
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($secret) -or $id -match '^x+$' -or $secret -match '^x+$') {
        $problems += 'twitchClientId/twitchClientSecret in config.json fehlen oder sind Platzhalter (https://dev.twitch.tv/console)'
    }

    if (-not (Get-Command $Config.YtDlpPath -ErrorAction SilentlyContinue)) {
        $problems += "yt-dlp nicht gefunden: $($Config.YtDlpPath)"
    }

    try { New-Item -ItemType Directory -Path $Config.OutputDirectory -Force -ErrorAction Stop | Out-Null }
    catch { $problems += "outputDirectory nicht nutzbar: $($Config.OutputDirectory)" }

    if (-not (Get-Command $Config.FfmpegPath -ErrorAction SilentlyContinue)) {
        Write-Log -Level WARN -Message "ffmpeg nicht gefunden ($($Config.FfmpegPath)) - Remux unvollständiger Aufnahmen ist nicht möglich."
    }
    if ($Config.TwitchConfigPath -and -not (Test-Path -LiteralPath $Config.TwitchConfigPath)) {
        Write-Log -Level WARN -Message "twitchConfigPath existiert nicht: $($Config.TwitchConfigPath) - yt-dlp startet ohne Config."
    }

    return , $problems
}

function Get-DisabledChannels {
    # Liest die per Tray-Menü deaktivierten Kanäle aus state.json (fehlt die Datei: alle aktiv).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return @(@($raw.disabledChannels) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    catch {
        Write-Log -Level WARN -Message "state.json konnte nicht gelesen werden (alle Kanäle aktiv): $($_.Exception.Message)"
        return @()
    }
}

function Save-DisabledChannels {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$Channels = @())

    try {
        [ordered]@{ disabledChannels = @($Channels) } | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log -Level ERROR -Message "state.json konnte nicht gespeichert werden: $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function Initialize-Config, Test-Config, Test-ConfigEnvironment, Get-DisabledChannels, Save-DisabledChannels
