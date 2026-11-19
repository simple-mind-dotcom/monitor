# Hilfsskript, das in einem eigenen, versteckten PowerShell-Prozess läuft:
# Es hängt sich an die (unsichtbare) Konsole des yt-dlp-Prozesses und sendet dort Ctrl+C.
# Das ist der einzige zuverlässige Weg, einen Konsolenprozess ohne Fenster "sauber" zu beenden
# (CloseMainWindow wirkt bei versteckten Konsolenprozessen nicht).
$script:CtrlCHelperTemplate = @'
$ErrorActionPreference = 'Stop'
try {
    Add-Type -Namespace TmNative -Name Con -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
"@
    [void][TmNative.Con]::FreeConsole()
    if (-not [TmNative.Con]::AttachConsole([uint32]__PID__)) { exit 2 }
    [void][TmNative.Con]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
    if (-not [TmNative.Con]::GenerateConsoleCtrlEvent(0, 0)) { exit 4 }
    Start-Sleep -Milliseconds 1000
    [void][TmNative.Con]::FreeConsole()
    exit 0
}
catch { exit 3 }
'@

function ConvertTo-ArgumentString {
    # Start-Process -ArgumentList quotet Array-Elemente nicht. Pfade/Titel mit Leerzeichen
    # würden sonst in mehrere Argumente zerfallen.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Items)
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

function Get-SafeFileName {
    # Entspricht der Wirkung von --restrict-filenames in der twitch.conf: nur ASCII, keine Leerzeichen.
    param([string]$Text, [int]$MaxLength = 80)
    $clean = $Text
    try {
        $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $decomposed.ToCharArray()) {
            if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
        }
        $clean = $sb.ToString()
    }
    catch { }
    $clean = $clean -replace '[^A-Za-z0-9._-]', '_'
    $clean = ($clean -replace '_+', '_').Trim('_', '.')
    if ($clean.Length -gt $MaxLength) { $clean = $clean.Substring(0, $MaxLength).Trim('_', '.') }
    if (-not $clean) { $clean = 'stream' }
    return $clean
}

function Send-CtrlC {
    # Exit-Codes des Helfers: 0 = OK, 2 = AttachConsole fehlgeschlagen, 3 = Ausnahme,
    # 4 = GenerateConsoleCtrlEvent fehlgeschlagen.
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $code = $script:CtrlCHelperTemplate.Replace('__PID__', [string]$ProcessId)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $helper = Start-Process -FilePath 'powershell.exe' -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded)
        return ($helper.ExitCode -eq 0)
    }
    catch {
        return $false
    }
}

function Clear-RecordingState {
    param([Parameter(Mandatory)][hashtable]$ChannelState)
    $ChannelState.Process = $null
    $ChannelState.ProcessId = $null
    $ChannelState.StartedAt = $null
}

function Get-OrphanRecorder {
    # Sucht yt-dlp-Prozesse für diesen Kanal, die NICHT von dieser App-Instanz gehalten werden
    # (z. B. nach "Beenden (App)" oder einem Absturz). Gibt ein Array zurück (leer = keiner).
    # Der Aufruf kostet ein paar hundert Millisekunden; er passiert nur direkt vor einem Aufnahmestart.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Channel)

    $pattern = 'twitch\.tv/' + [regex]::Escape($Channel) + '(?=[\s"/?]|$)'
    try {
        return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.Name -match '^(yt-dlp|python|pythonw)(\.exe)?$' -and
                $_.CommandLine -match $pattern
            })
    }
    catch {
        return @()
    }
}

function Test-FreeDiskSpace {
    # Verhindert Aufnahmen, wenn der Datenträger voll läuft (yt-dlp würde sonst mittendrin abbrechen).
    # UNC-Pfade machen DriveInfo mit: der Check wird dann einfach übersprungen.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Channel, [Parameter(Mandatory)][string]$Folder)

    $minGB = 5.0
    if ($State.Config.MinFreeDiskSpaceGB) { $minGB = [double]$State.Config.MinFreeDiskSpaceGB }
    if ($minGB -le 0) { return $true }
    try {
        $drive = New-Object IO.DriveInfo($Folder)
        $freeGB = $drive.AvailableFreeSpace / 1GB
        if ($freeGB -ge $minGB) { return $true }
        $cs = $State.Channels[$Channel]
        $cs.LastError = "Zu wenig Speicherplatz auf $($drive.Name): $([Math]::Round($freeGB, 1)) GB frei (Minimum $minGB GB)."
        $cs.FailCount = [int]$cs.FailCount + 1
        $cs.NextStartAt = (Get-Date).AddSeconds(300)
        Write-Log -Channel $Channel -Level ERROR -Message "Keine Aufnahme gestartet: $($cs.LastError) (nächster Versuch in 300 s)"
        # Tray-Modul ist optional - ohne es nur loggen.
        if (Get-Command Show-TrayBalloon -ErrorAction SilentlyContinue) {
            Show-TrayBalloon -State $State -Title 'Speicherplatz niedrig' -Text "$($Channel): nur noch $([Math]::Round($freeGB, 1)) GB frei - Aufnahme verzögert." -IsError $true
        }
    }
    catch { return $true }
}

function Start-ChannelRecording {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Title
    )

    $cs = $State.Channels[$Channel]
    if ($cs.Process -and -not $cs.Process.HasExited) { return $false }

    $ytDlp = $State.Config.YtDlpPath
    $configPath = $State.Config.TwitchConfigPath
    $folder = Join-Path $State.Config.OutputDirectory $Channel

    if (-not (Test-FreeDiskSpace -State $State -Channel $Channel -Folder $folder)) { return $false }

    try {
        New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null

        # yt-dlp-Templates kennen kein %Y%m%d (das wäre ein falscher Platzhalter) - das Datum
        # wird deshalb hier eingesetzt. Existiert die Datei schon (z. B. Neustart nach Absturz),
        # wird eine Uhrzeit angehängt, sonst würde yt-dlp "already downloaded" melden und sofort enden.
        $baseName = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd'), (Get-SafeFileName -Text $Title)
        $taken = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith("$baseName.", [StringComparison]::OrdinalIgnoreCase) })
        if ($taken.Count -gt 0) { $baseName = '{0}_{1}' -f $baseName, (Get-Date -Format 'HHmmss') }

        # '%' im Pfad muss für yt-dlp als '%%' maskiert werden.
        $outputTemplate = ((Join-Path $folder $baseName) -replace '%', '%%') + '.%(ext)s'

        $ytArgs = @()
        if ($configPath -and (Test-Path -LiteralPath $configPath)) {
            $ytArgs += @('--config-locations', $configPath)
        }
        elseif ($configPath) {
            Write-Log -Channel $Channel -Level ERROR -Message "yt-dlp-Config fehlt: $configPath - starte ohne Config."
        }
        # --no-progress / -nostats: verhindern, dass die umgeleiteten Logs mit Fortschrittszeilen volllaufen
        # (ffmpeg schrieb sonst ca. 90 MB pro Tag in <kanal>.ytdlp.err.log).
        # -loglevel warning: ffmpeg meldet sonst JEDES HLS-Segment ("Opening '...' for reading") - reine
        # Info-Meldungen, die über viele Stunden Aufzeichnung die err.log aufblähen. Fehler/Warnungen bleiben sichtbar.
        $ytArgs += @('--no-progress', '--downloader-args', 'ffmpeg:-nostats -loglevel warning', '-o', $outputTemplate, "https://www.twitch.tv/$Channel")

        $logBase = Join-Path $State.LogPath "$Channel.ytdlp"

        # Start-Process überschreibt die umgeleiteten Logs. Die Logs des vorherigen Laufs werden deshalb
        # als *.prev.log gesichert - sonst verschwindet bei Neustart-Schleifen genau die Fehlermeldung.
        foreach ($suffix in 'out', 'err') {
            $logFile = "$logBase.$suffix.log"
            try {
                if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 0) {
                    Move-Item -LiteralPath $logFile -Destination "$logBase.$suffix.prev.log" -Force -ErrorAction Stop
                }
            }
            catch { }
        }

        $process = Start-Process -FilePath $ytDlp -ArgumentList (ConvertTo-ArgumentString -Items $ytArgs) `
            -PassThru -WindowStyle Hidden -ErrorAction Stop `
            -RedirectStandardOutput "$logBase.out.log" -RedirectStandardError "$logBase.err.log"
        $null = $process.Handle   # Handle cachen, sonst ist ExitCode bei Windows PowerShell 5.1 später leer.

        $cs.Process = $process
        $cs.ProcessId = $process.Id
        $cs.OutputFolder = $folder
        $cs.OutputPrefix = $baseName
        $cs.StartedAt = Get-Date
        Write-Log -Channel $Channel -Level INFO -Message "Aufnahme gestartet (PID $($process.Id)): $baseName"
        return $true
    }
    catch {
        $cs.LastError = $_.Exception.Message
        # Auch ein nicht startbares yt-dlp bekommt den Backoff (sonst Startversuch bei jeder Abfrage).
        $cs.FailCount = [int]$cs.FailCount + 1
        $delay = [Math]::Min(1800, 30 * [Math]::Pow(2, [Math]::Min($cs.FailCount, 10) - 1))
        $cs.NextStartAt = (Get-Date).AddSeconds($delay)
        Write-Log -Channel $Channel -Level ERROR -Message "yt-dlp konnte nicht gestartet werden: $($_.Exception.Message) (nächster Versuch in $([int]$delay) s)"
        return $false
    }
}

function Complete-PartialRecording {
    # Nach Ctrl+C (oder einem Absturz) bleibt bei --hls-use-mpegts eine abspielbare *.part-Datei (MPEG-TS)
    # liegen; yt-dlp führt Merge/Rename/Thumbnail dann nicht mehr aus. Hier wird der ffmpeg-Remux zu .mp4
    # nur GESTARTET (nicht blockierend) und als Job in $State.RemuxJobs vorgemerkt. Abgeschlossen wird er
    # von Update-RemuxJobs (Timer, alle 5 s) bzw. beim Beenden von Wait-RemuxJobs.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Channel, [Parameter(Mandatory)][hashtable]$State)

    $cs = $State.Channels[$Channel]
    $folder = $cs.OutputFolder
    $prefix = $cs.OutputPrefix
    if (-not $folder -or -not $prefix -or -not (Test-Path -LiteralPath $folder)) { return }
    if ($null -eq $State.RemuxJobs) { $State.RemuxJobs = New-Object System.Collections.ArrayList }

    $parts = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith("$prefix.", [StringComparison]::OrdinalIgnoreCase) -and $_.Extension -eq '.part' })
    foreach ($part in $parts) {
        try {
            # Läuft für diese Datei schon ein Remux, nichts doppelt starten.
            if (@($State.RemuxJobs | Where-Object { $_.Part -eq $part.FullName }).Count -gt 0) { continue }

            $target = $part.FullName.Substring(0, $part.FullName.Length - 5)          # ohne ".part"
            if ([IO.Path]::GetExtension($target) -ne '.mp4') { $target = [IO.Path]::ChangeExtension($target, '.mp4') }
            $claimed = @($State.RemuxJobs | Where-Object { $_.Target -eq $target }).Count -gt 0
            if ((Test-Path -LiteralPath $target) -or $claimed) { $target = [IO.Path]::ChangeExtension($target, $null) + '_recovered.mp4' }
            $tmp = [IO.Path]::ChangeExtension($target, '.remux.mp4')

            Write-Log -Channel $Channel -Level INFO -Message "Remuxe unvollständige Aufnahme (im Hintergrund): $($part.Name) -> $([IO.Path]::GetFileName($target))"
            $ffArgs = @('-hide_banner', '-loglevel', 'error', '-y', '-i', $part.FullName, '-c', 'copy', '-movflags', '+faststart', $tmp)
            $ff = Start-Process -FilePath $State.Config.FfmpegPath -ArgumentList (ConvertTo-ArgumentString -Items $ffArgs) `
                -PassThru -WindowStyle Hidden -ErrorAction Stop
            $null = $ff.Handle   # Handle cachen, sonst ist ExitCode bei Windows PowerShell 5.1 später leer.
            [void]$State.RemuxJobs.Add(@{
                Channel = $Channel; Process = $ff; Part = $part.FullName
                Target = $target; Tmp = $tmp; StartedAt = Get-Date
            })
        }
        catch {
            Write-Log -Channel $Channel -Level ERROR -Message "Remux nicht möglich (ffmpeg im PATH?): $($_.Exception.Message)"
        }
    }
}

function Update-RemuxJobs {
    # Prüft laufende Remux-Jobs (billig, ohne Blockieren) und schließt fertige ab.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    if ($null -eq $State.RemuxJobs -or $State.RemuxJobs.Count -eq 0) { return }
    foreach ($job in @($State.RemuxJobs)) {
        try {
            $exited = $true
            try { $exited = $job.Process.HasExited } catch { }

            $exitCode = $null
            if (-not $exited) {
                if (((Get-Date) - $job.StartedAt).TotalHours -le 6) { continue }
                try { $job.Process.Kill() } catch { }
                $exitCode = -1
                Write-Log -Channel $job.Channel -Level ERROR -Message "ffmpeg-Remux nach 6 h abgebrochen: $([IO.Path]::GetFileName($job.Part))"
            }
            else {
                try { $exitCode = $job.Process.ExitCode } catch { }
            }

            $partName = [IO.Path]::GetFileName($job.Part)
            if ($exitCode -eq 0 -and (Test-Path -LiteralPath $job.Tmp)) {
                Move-Item -LiteralPath $job.Tmp -Destination $job.Target -Force
                Remove-Item -LiteralPath $job.Part -Force
                $ytdl = $job.Part -replace '\.part$', '.ytdl'
                if (Test-Path -LiteralPath $ytdl) { Remove-Item -LiteralPath $ytdl -Force -ErrorAction SilentlyContinue }
                Write-Log -Channel $job.Channel -Level INFO -Message "Remux abgeschlossen: $([IO.Path]::GetFileName($job.Target))"
            }
            else {
                if (Test-Path -LiteralPath $job.Tmp) { Remove-Item -LiteralPath $job.Tmp -Force -ErrorAction SilentlyContinue }
                Write-Log -Channel $job.Channel -Level ERROR -Message "ffmpeg-Remux fehlgeschlagen (Exit-Code $exitCode); .part-Datei bleibt erhalten: $partName"
            }
            $State.RemuxJobs.Remove($job)
        }
        catch {
            Write-Log -Channel $job.Channel -Level ERROR -Message "Remux-Abschluss fehlgeschlagen: $($_.Exception.Message)"
            $State.RemuxJobs.Remove($job)   # sonst würde derselbe Fehler alle 5 s wiederkehren
        }
    }
}

function Wait-RemuxJobs {
    # Nur beim Beenden: wartet, bis alle laufenden Remux-Jobs fertig sind (parallel laufend, daher meist kurz).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [int]$TimeoutSeconds = 120)

    if ($null -eq $State.RemuxJobs) { return }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Update-RemuxJobs -State $State
    while ($State.RemuxJobs.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        Update-RemuxJobs -State $State
    }
    if ($State.RemuxJobs.Count -gt 0) {
        Write-Log -Level WARN -Message "$($State.RemuxJobs.Count) Remux-Job(s) laufen beim Beenden noch (Wartezeit $TimeoutSeconds s überschritten); die .remux.mp4-Dateien werden fertig geschrieben, bleiben aber als solche liegen."
    }
}

function Stop-ChannelRecording {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][hashtable]$State,
        [int]$FinalizeTimeoutSeconds = 30
    )

    $cs = $State.Channels[$Channel]
    $process = $cs.Process
    if (-not $process) { return $true }

    try {
        if (-not $process.HasExited) {
            Write-Log -Channel $Channel -Level INFO -Message 'Sende Ctrl+C an yt-dlp, warte auf Finalisierung.'
            if (-not (Send-CtrlC -ProcessId $process.Id)) {
                Write-Log -Channel $Channel -Level WARN -Message 'Ctrl+C konnte nicht gesendet werden.'
            }
            if (-not $process.WaitForExit($FinalizeTimeoutSeconds * 1000)) {
                Write-Log -Channel $Channel -Level WARN -Message 'Prozess läuft noch; sende Ctrl+C ein zweites Mal.'
                $null = Send-CtrlC -ProcessId $process.Id
                if (-not $process.WaitForExit(15000)) {
                    Write-Log -Channel $Channel -Level WARN -Message 'Finalisierung dauert zu lange; Prozess bleibt zur Sicherheit aktiv.'
                    return $false
                }
            }
        }
        Write-Log -Channel $Channel -Level DEBUG -Message 'Aufnahmeprozess beendet.'
        Clear-RecordingState -ChannelState $cs
        Complete-PartialRecording -Channel $Channel -State $State
        return $true
    }
    catch {
        Write-Log -Channel $Channel -Level ERROR -Message "Fehler beim Stoppen: $($_.Exception.Message)"
        return $false
    }
}

function Test-ChannelRecording {
    # Reine Abfrage ohne Nebenwirkungen (für das Tray).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Channel, [Parameter(Mandatory)][hashtable]$State)
    $p = $State.Channels[$Channel].Process
    if (-not $p) { return $false }
    try { return (-not $p.HasExited) } catch { return $false }
}

function Get-RecordingStatus {
    # Wie Test-ChannelRecording, räumt aber einen beendeten Prozess auf, loggt ihn, setzt bei einem
    # Fehlstart den Neustart-Backoff und repariert eine verwaiste .part-Datei.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Channel, [Parameter(Mandatory)][hashtable]$State)
    $cs = $State.Channels[$Channel]
    $p = $cs.Process
    if (-not $p) { return $false }
    try { if (-not $p.HasExited) { return $true } } catch { }

    $code = $null
    try { $code = $p.ExitCode } catch { }
    $runtime = if ($cs.StartedAt) { (Get-Date) - $cs.StartedAt } else { [TimeSpan]::Zero }
    $isShort = ($runtime.TotalSeconds -lt 60)
    $failed = ($code -ne 0) -or $isShort

    if ($code -eq 0) {
        Write-Log -Channel $Channel -Level DEBUG -Message "yt-dlp hat sich beendet (Exit-Code 0, Laufzeit $([int]$runtime.TotalSeconds) s)."
    }
    else {
        Write-Log -Channel $Channel -Level WARN -Message "yt-dlp hat sich beendet (Exit-Code $code, Laufzeit $([int]$runtime.TotalSeconds) s). Details: logs\$Channel.ytdlp.err.log (voriger Lauf: .prev.log)"
    }

    if ($failed) {
        # Lief die Aufnahme lange, war es ein einzelner Abbruch und kein Fehlstart-Muster.
        if (-not $isShort) { $cs.FailCount = 0 }
        $cs.FailCount = [int]$cs.FailCount + 1
        $delay = [Math]::Min(1800, 30 * [Math]::Pow(2, [Math]::Min($cs.FailCount, 10) - 1))
        $cs.NextStartAt = (Get-Date).AddSeconds($delay)
        Write-Log -Channel $Channel -Level WARN -Message "Fehlstart Nr. $($cs.FailCount) - nächster Aufnahmeversuch frühestens in $([int]$delay) s."
    }
    else {
        $cs.FailCount = 0
        $cs.NextStartAt = $null
    }

    Clear-RecordingState -ChannelState $cs
    # Sauber beendete Läufe erzeugen keine Fehler; leere Logdateien werden dann gleich mit entfernt.
    if (-not $failed) { Remove-EmptyYtdlpLogs -State $State -Channel $Channel }
    # Von selbst beendetes yt-dlp (Absturz, Netzwerkabbruch) hinterlässt evtl. eine unfertige .part-Datei.
    try { Complete-PartialRecording -Channel $Channel -State $State }
    catch { Write-Log -Channel $Channel -Level ERROR -Message "Nachbearbeitung fehlgeschlagen: $($_.Exception.Message)" }
    return $false
}

function Remove-EmptyYtdlpLogs {
    # Nur bei Fehlern soll etwas im Log-Ordner liegen: Leere yt-dlp-Logs eines sauberen Laufs entfernen.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Channel)
    $errLog = Join-Path $State.LogPath "$Channel.ytdlp.err.log"
    try {
        if ((Test-Path -LiteralPath $errLog) -and (Get-Item -LiteralPath $errLog).Length -gt 0) { return }
        foreach ($suffix in 'out', 'err') {
            $logFile = Join-Path $State.LogPath "$Channel.ytdlp.$suffix.log"
            if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -eq 0) {
                Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }
}

function Get-RecordingSize {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Channel, [Parameter(Mandatory)][hashtable]$State)
    # Nur Dateien der aktuellen Aufnahme (inkl. .part/.ytdl/Teilformate) zählen, nicht den ganzen Künstlerordner.
    # Ergebnis 5 s cachen: das Tray fragt jede Sekunde ab, ein Verzeichnis-Scan pro Tick ist unnötig.
    $cs = $State.Channels[$Channel]
    $folder = $cs.OutputFolder
    $prefix = $cs.OutputPrefix
    if (-not $folder -or -not $prefix -or -not (Test-Path -LiteralPath $folder)) { return [int64]0 }
    if ($cs.SizeCache -and ((Get-Date) - $cs.SizeCache.At).TotalSeconds -lt 5) { return [int64]$cs.SizeCache.Value }
    $sum = [int64]0
    foreach ($f in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) {
        if ($f.Name.StartsWith("$prefix.", [StringComparison]::OrdinalIgnoreCase)) { $sum += $f.Length }
    }
    $cs.SizeCache = @{ Value = $sum; At = Get-Date }
    return $sum
}

Export-ModuleMember -Function Start-ChannelRecording, Stop-ChannelRecording, Complete-PartialRecording, Test-ChannelRecording, Get-RecordingStatus, Get-RecordingSize, Get-OrphanRecorder, Update-RemuxJobs, Wait-RemuxJobs, ConvertTo-ArgumentString, Get-SafeFileName, Test-FreeDiskSpace
