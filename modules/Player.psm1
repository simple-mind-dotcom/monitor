# Wiedergabe von Twitch-Streams per streamlink (ohne Aufnahme). streamlink liefert den Stream und
# startet den Player: Standard ist der Player, den streamlink selbst vorsieht (z. B. VLC bzw. die
# streamlink-Config); mit `playback.playerPath` in config.json laesst sich der Player ueberschreiben.
# Start/Stopp ist ueber das Kontextmenue im Tray und in der GUI moeglich (mit Qualitaetsauswahl).

$script:PlSeq = 0

function Show-PlaybackBalloon {
    param([Parameter(Mandatory)][hashtable]$State, [string]$Title, [string]$Text, [bool]$IsError = $false)
    # Tray-Modul ist optional - ohne es nur loggen.
    if (Get-Command Show-TrayBalloon -ErrorAction SilentlyContinue) {
        Show-TrayBalloon -State $State -Title $Title -Text $Text -IsError $IsError
    }
}

function Test-PlaybackUrl {
    # Nur http(s), keine Leerzeichen/Anfuehrungszeichen: verhindert zugleich, dass ein Eintrag
    # wie "--exec ..." als streamlink-Option durchrutscht.
    param([string]$Url)
    return ($Url -match '^https?://[^\s"]+$')
}

function Get-PlaybackQualities {
    # Auswahl im Kontextmenue (Tray/GUI): streamlink-Qualitaetstaenden fuer Twitch.
    return @(
        @{ Value = 'best';       Label = 'Beste Qualitaet' },
        @{ Value = '1080p60';    Label = '1080p60 (60 fps)' },
        @{ Value = '1080p';      Label = '1080p' },
        @{ Value = '720p60';     Label = '720p60 (60 fps)' },
        @{ Value = '720p';       Label = '720p' },
        @{ Value = 'worst';      Label = 'Niedrigste Qualitaet' },
        @{ Value = 'audio_only'; Label = 'Nur Audio' }
    )
}

function ConvertTo-PlaybackArgs {
    # Reine Argumentliste fuer streamlink (einfach testbar). playerPath leer = streamlink-Standardplayer.
    # Optionen zuerst, dann URL, dann Qualitaet (streamlink-Syntax: streamlink [OPTIONEN] URL [QUALITAET]).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url, [string]$PlayerPath, [string]$Quality = '')
    $q = if ($Quality) { [string]$Quality } else { 'best' }
    $result = @()
    if ($PlayerPath) { $result += @('--player', $PlayerPath) }
    $result += @($Url, $q)
    return , $result
}

function ConvertTo-PlaybackArgumentString {
    # Start-Process -ArgumentList quotet Array-Elemente nicht (siehe Recorder.psm1 / Downloader.psm1).
    param([Parameter(Mandatory)][string[]]$Items)
    $quoted = foreach ($item in $Items) {
        if ($item -match '[\s"]' -or $item -eq '') {
            $escaped = $item -replace '(\\*)"', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            '"' + $escaped + '"'
        }
        else { $item }
    }
    return ($quoted -join ' ')
}

function Initialize-Player {
    # Legt den Job-Speicher an und startet den Timer, der beendete Wiedergaben abholen.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    if ($null -eq $State.PlaybackJobs) { $State.PlaybackJobs = New-Object System.Collections.ArrayList }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.add_Tick({
        try { Update-PlaybackJobs -State $State }
        catch { Write-Log -Channel 'playback' -Level ERROR -Message "Playback-Timer: $($_.Exception.Message)" }
    }.GetNewClosure())
    $State.Timers.Playback = $timer
    $timer.Start()
}

function Get-PlaybackForChannel {
    # Laeuft fuer diesen Kanal bereits eine Wiedergabe? (ein Stream pro Kanal/-URL)
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Channel)
    if ($null -eq $State.PlaybackJobs) { return $null }
    foreach ($job in @($State.PlaybackJobs)) {
        if ([string]$job.Channel -eq $Channel) {
            $running = $true
            try { $running = -not $job.Process.HasExited } catch { }
            if ($running) { return $job }
        }
    }
    return $null
}

function Get-ActivePlaybackCount {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    if ($null -eq $State.PlaybackJobs -or $State.PlaybackJobs.Count -eq 0) { return 0 }
    $count = 0
    foreach ($job in @($State.PlaybackJobs)) {
        try { if (-not $job.Process.HasExited) { $count++ } } catch { }
    }
    return $count
}

function Request-StreamPlayback {
    # Startet die Wiedergabe. Blockiert nicht: streamlink + Player laufen als eigener Prozess.
    # Ein Kanal laeuft nur einmal gleichzeitig - fuer mehr Aufloesung erst stoppen oder aufnehmen.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Channel,
        [string]$Quality = ''
    )

    $cfg = $State.Config
    $url = 'https://twitch.tv/' + $Channel
    if (-not (Test-PlaybackUrl -Url $url)) {
        Write-Log -Channel 'playback' -Level ERROR -Message "Ungueltige URL abgelehnt: $url"
        return $false
    }
    $existing = Get-PlaybackForChannel -State $State -Channel $Channel
    if ($existing) {
        Write-Log -Channel 'playback' -Level INFO -Message "Wiedergabe laeuft bereits ($Channel)."
        Show-PlaybackBalloon -State $State -Title 'Wiedergabe läuft bereits' -Text "$Channel - zuerst stoppen, um neu zu starten."
        return $false
    }
    if (-not (Get-Command $cfg.PlaybackStreamlinkPath -ErrorAction SilentlyContinue)) {
        Write-Log -Channel 'playback' -Level ERROR -Message "streamlink nicht gefunden ($($cfg.PlaybackStreamlinkPath)) - Wiedergabe nicht moeglich."
        Show-PlaybackBalloon -State $State -Title 'Wiedergabe fehlgeschlagen' -Text "streamlink nicht gefunden: $($cfg.PlaybackStreamlinkPath) (scoop install streamlink)" -IsError $true
        return $false
    }
    if ($cfg.PlaybackPlayerPath -and -not (Get-Command $cfg.PlaybackPlayerPath -ErrorAction SilentlyContinue)) {
        Write-Log -Channel 'playback' -Level ERROR -Message "Player nicht gefunden ($($cfg.PlaybackPlayerPath)) - Wiedergabe nicht moeglich."
        Show-PlaybackBalloon -State $State -Title 'Wiedergabe fehlgeschlagen' -Text "Player nicht gefunden: $($cfg.PlaybackPlayerPath)" -IsError $true
        return $false
    }

    try {
        $script:PlSeq++
        $id = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $script:PlSeq
        $logBase = Join-Path $State.LogPath "playback_$id"

        $plArgs = ConvertTo-PlaybackArgs -Url $url -PlayerPath $cfg.PlaybackPlayerPath -Quality ($(if ($Quality) { $Quality } else { $cfg.PlaybackQuality }))
        $process = Start-Process -FilePath $cfg.PlaybackStreamlinkPath -ArgumentList (ConvertTo-PlaybackArgumentString -Items $plArgs) `
            -PassThru -WindowStyle Hidden -ErrorAction Stop `
            -RedirectStandardOutput "$logBase.out.log" -RedirectStandardError "$logBase.err.log"
        $null = $process.Handle   # Handle cachen, sonst ist ExitCode bei Windows PowerShell 5.1 spaeter leer.

        if ($null -eq $State.PlaybackJobs) { $State.PlaybackJobs = New-Object System.Collections.ArrayList }
        [void]$State.PlaybackJobs.Add(@{
            Id = $id; Channel = $Channel; Url = $url; Process = $process
            LogBase = $logBase; Quality = $plArgs[-1]; StartedAt = Get-Date
        })
        Write-Log -Channel 'playback' -Level INFO -Message "Wiedergabe gestartet ($Channel, $($plArgs[-1]), PID $($process.Id)): $url"
        Show-PlaybackBalloon -State $State -Title 'Wiedergabe gestartet' -Text "$Channel (streamlink)"
        return $true
    }
    catch {
        Write-Log -Channel 'playback' -Level ERROR -Message "Wiedergabe konnte nicht gestartet werden ($Channel): $($_.Exception.Message)"
        Show-PlaybackBalloon -State $State -Title 'Wiedergabe fehlgeschlagen' -Text $_.Exception.Message -IsError $true
        return $false
    }
}

function Stop-StreamPlayback {
    # Beendet streamlink inkl. Player (Kindprozesse) sauber per taskkill.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Id)

    $job = @($State.PlaybackJobs | Where-Object { [string]$_.Id -eq $Id }) | Select-Object -First 1
    if (-not $job) { return $false }
    try {
        & taskkill.exe /PID $job.Process.Id /T /F *> $null   # inkl. Player-Kindprozesse
        Write-Log -Channel 'playback' -Level INFO -Message "Wiedergabe gestoppt: $($job.Channel)"
    }
    catch { Write-Log -Channel 'playback' -Level ERROR -Message "Wiedergabe stoppen fehlgeschlagen ($($job.Channel)): $($_.Exception.Message)" }
    if ($null -ne $State.PlaybackJobs) { $State.PlaybackJobs.Remove($job) | Out-Null }
    return $true
}

function Get-LastPlaybackError {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $line = Get-Content -LiteralPath $Path -Tail 30 -ErrorAction Stop |
            Where-Object { $_ -match 'error|ERROR|warnung|WARNING' } | Select-Object -Last 1
        if ($line) { return [string]$line }
    }
    catch { }
    return ''
}

function Update-PlaybackJobs {
    # Prueft laufende Wiedergaben (billig, ohne Blockieren) und raeumt beendete ab.
    # Beendet sich streamlink selbst (Stream vorbei / Player geschlossen), ist Exit-Code 0 normal.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    if ($null -eq $State.PlaybackJobs -or $State.PlaybackJobs.Count -eq 0) { return }
    foreach ($job in @($State.PlaybackJobs)) {
        try {
            $exited = $true
            try { $exited = $job.Process.HasExited } catch { }
            if (-not $exited) { continue }

            $code = $null
            try { $code = $job.Process.ExitCode } catch { }
            $State.PlaybackJobs.Remove($job)   # zuerst entfernen: sonst Wiederholung bei Folgefehlern

            $secs = [int]((Get-Date) - $job.StartedAt).TotalSeconds
            if ($code -eq 0) {
                Write-Log -Channel 'playback' -Level INFO -Message "Wiedergabe beendet ($($job.Channel), $secs s): $($job.Url)"
                # Erfolgreiche/ruhige Laeufe brauchen keine Einzel-Logs.
                Remove-Item -LiteralPath "$($job.LogBase).out.log", "$($job.LogBase).err.log" -Force -ErrorAction SilentlyContinue
            }
            else {
                $detail = Get-LastPlaybackError -Path "$($job.LogBase).err.log"
                Write-Log -Channel 'playback' -Level ERROR -Message "Wiedergabe fehlgeschlagen ($($job.Channel), Exit-Code $code): $($job.Url) $detail"
                $text = if ($detail) { $detail } else { "Exit-Code $code - Kanal vermutlich offline." }
                if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
                Show-PlaybackBalloon -State $State -Title "Wiedergabe ($($job.Channel)) beendet" -Text $text -IsError $true
                if ($secs -lt 5) {
                    # Kurz nach dem Start gescheitert (z. B. offline): Log behalten fuer Details ist nicht
                    # noetig, die Meldung steht im monitor.log. Logs trotzdem aufraeumen.
                    Remove-Item -LiteralPath "$($job.LogBase).out.log", "$($job.LogBase).err.log" -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
            Write-Log -Channel 'playback' -Level ERROR -Message "Playback-Abschluss fehlgeschlagen: $($_.Exception.Message)"
            $State.PlaybackJobs.Remove($job)
        }
    }
}

Export-ModuleMember -Function Initialize-Player, Update-PlaybackJobs, Request-StreamPlayback, Stop-StreamPlayback, Get-ActivePlaybackCount, Get-PlaybackForChannel, Get-PlaybackQualities, Test-PlaybackUrl, ConvertTo-PlaybackArgs, Get-LastPlaybackError
