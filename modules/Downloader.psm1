# Einzeldownloads (Video oder Musik) per Link, unabhängig vom Stream-Monitoring.
# Jeder Typ hat eine eigene yt-dlp-Config (configs\download_video.conf / download_music.conf).
# Der Link wird im Tray-Menü ("Download (Link)...") in einem kleinen Dialog eingefügt.
# Die Downloads laufen als versteckte yt-dlp-Prozesse; ein Timer räumt fertige Jobs auf.

$script:DlSeq = 0

function ConvertTo-DlArgumentString {
    # Start-Process -ArgumentList quotet Array-Elemente nicht (siehe Recorder.psm1).
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

function Test-DownloadUrl {
    param([string]$Url)
    # Nur http(s): verhindert zugleich, dass ein Eintrag wie "--exec ..." als yt-dlp-Option durchrutscht.
    return ($Url -match '^https?://[^\s"]+$')
}

function Initialize-Downloader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    if ($null -eq $State.DownloadJobs) { $State.DownloadJobs = New-Object System.Collections.ArrayList }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.add_Tick({
        try { Update-DownloadJobs -State $State }
        catch { Write-Log -Channel 'download' -Level ERROR -Message "Download-Timer: $($_.Exception.Message)" }
    }.GetNewClosure())
    $State.Timers.Download = $timer
    $timer.Start()
}

function Stop-Downloader {
    # Stoppt nur den Überwachungs-Timer. Laufende Downloads bleiben bewusst aktiv
    # (wie "Beenden (App)" bei Aufnahmen); yt-dlp kann .part-Dateien beim nächsten Mal fortsetzen.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    try {
        if ($State.Timers.Download) { $State.Timers.Download.Stop(); $State.Timers.Download.Dispose(); $State.Timers.Download = $null }
    }
    catch { Write-Log -Channel 'download' -Level ERROR -Message "Stop-Downloader: $($_.Exception.Message)" }
}

function Get-ActiveDownloadCount {
    param([Parameter(Mandatory)][hashtable]$State)
    if ($null -eq $State.DownloadJobs) { return 0 }
    return @($State.DownloadJobs).Count
}

function Show-DownloadDialog {
    # Kleiner modaler Dialog: Link einfügen, Typ wählen. Gibt $null (Abbruch) oder @{ Url; Kind } zurück.
    [CmdletBinding()]
    param([string]$InitialUrl = '')

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Download per Link'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(520, 150)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Link (Video-, Musik- oder Playlist-Seite - es wird nur das einzelne Element geladen):'
    $label.AutoSize = $false
    $label.SetBounds(12, 12, 496, 32)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.SetBounds(12, 48, 496, 24)
    $tb.Text = $InitialUrl

    $rbVideo = New-Object System.Windows.Forms.RadioButton
    $rbVideo.Text = 'Video (mp4)'
    $rbVideo.Checked = $true
    $rbVideo.SetBounds(12, 82, 120, 24)

    $rbMusic = New-Object System.Windows.Forms.RadioButton
    $rbMusic.Text = 'Musik (mp3)'
    $rbMusic.SetBounds(140, 82, 120, 24)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Starten'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.SetBounds(332, 112, 84, 28)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Abbrechen'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancel.SetBounds(424, 112, 84, 28)

    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    # Ungültige Eingabe: Dialog offen lassen (DialogResult zurück auf None).
    $ok.add_Click({
        if (-not (Test-DownloadUrl -Url $tb.Text.Trim())) {
            [void][System.Windows.Forms.MessageBox]::Show('Bitte einen gültigen Link (http:// oder https://) eingeben.', 'Download per Link')
            $form.DialogResult = [System.Windows.Forms.DialogResult]::None
        }
    }.GetNewClosure())

    $form.Controls.AddRange(@($label, $tb, $rbVideo, $rbMusic, $ok, $cancel))
    try {
        $form.Add_Shown({ $tb.Focus(); $tb.SelectAll() }.GetNewClosure())
        if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return [pscustomobject]@{
            Url  = $tb.Text.Trim()
            Kind = $(if ($rbMusic.Checked) { 'music' } else { 'video' })
        }
    }
    finally { $form.Dispose() }
}

function Request-SingleDownload {
    # Öffnet den Dialog über einen einmaligen Timer, damit der Menü-Klick nicht blockiert
    # (und das Menü vorher sauber schließt).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $once = New-Object System.Windows.Forms.Timer
    $once.Interval = 150
    $once.add_Tick({
        param($sender, $e)
        $sender.Stop(); $sender.Dispose()
        try {
            $initial = ''
            try {
                $clip = [System.Windows.Forms.Clipboard]::GetText().Trim()
                if (Test-DownloadUrl -Url $clip) { $initial = $clip }
            }
            catch { }
            $result = Show-DownloadDialog -InitialUrl $initial
            if ($result) { [void](Start-SingleDownload -State $State -Url $result.Url -Kind $result.Kind) }
        }
        catch { Write-Log -Channel 'download' -Level ERROR -Message "Download-Dialog: $($_.Exception.Message)" }
    }.GetNewClosure())
    $once.Start()
}

function Show-DownloadBalloon {
    param([Parameter(Mandatory)][hashtable]$State, [string]$Title, [string]$Text, [bool]$IsError = $false)
    # Tray-Modul ist optional - ohne es nur keine Balloon-Meldung.
    if (Get-Command Show-TrayBalloon -ErrorAction SilentlyContinue) {
        Show-TrayBalloon -State $State -Title $Title -Text $Text -IsError $IsError
    }
}

function Start-SingleDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidateSet('video', 'music')][string]$Kind
    )

    $cfg = $State.Config
    if (-not (Test-DownloadUrl -Url $Url)) {
        Write-Log -Channel 'download' -Level ERROR -Message "Ungültiger Link abgelehnt: $Url"
        return $false
    }

    $isMusic = ($Kind -eq 'music')
    $confPath = if ($isMusic) { $cfg.DownloadMusicConfigPath } else { $cfg.DownloadVideoConfigPath }
    $dir = if ($isMusic) { $cfg.DownloadMusicDirectory } else { $cfg.DownloadVideoDirectory }
    $label = if ($isMusic) { 'Musik' } else { 'Video' }

    try {
        if (-not (Test-Path -LiteralPath $confPath)) {
            throw "Config fehlt: $confPath"
        }
        if ($isMusic -and -not (Get-Command $cfg.FfmpegPath -ErrorAction SilentlyContinue)) {
            throw "ffmpeg nicht gefunden ($($cfg.FfmpegPath)) - für die mp3-Konvertierung nötig."
        }
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null

        # '%' im Verzeichnis muss für yt-dlp als '%%' maskiert werden; der Dateiname kommt aus dem Template.
        $template = (Join-Path ($dir -replace '%', '%%') '%(title).150B [%(id)s].%(ext)s')

        $script:DlSeq++
        $id = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $script:DlSeq
        $logBase = Join-Path $State.LogPath "download_$id"

        $ytArgs = @('--config-locations', $confPath, '--no-progress', '-o', $template, $Url)
        $process = Start-Process -FilePath $cfg.YtDlpPath -ArgumentList (ConvertTo-DlArgumentString -Items $ytArgs) `
            -PassThru -WindowStyle Hidden -ErrorAction Stop `
            -RedirectStandardOutput "$logBase.out.log" -RedirectStandardError "$logBase.err.log"
        $null = $process.Handle   # Handle cachen, sonst ist ExitCode bei Windows PowerShell 5.1 später leer.

        if ($null -eq $State.DownloadJobs) { $State.DownloadJobs = New-Object System.Collections.ArrayList }
        [void]$State.DownloadJobs.Add(@{
            Id = $id; Url = $Url; Kind = $Kind; Label = $label; Process = $process
            LogBase = $logBase; Directory = $dir; StartedAt = Get-Date
        })
        Write-Log -Channel 'download' -Level INFO -Message "Download gestartet ($label, PID $($process.Id)): $Url"
        Show-DownloadBalloon -State $State -Title "$label-Download gestartet" -Text $Url
        return $true
    }
    catch {
        Write-Log -Channel 'download' -Level ERROR -Message "Download konnte nicht gestartet werden ($label): $($_.Exception.Message)"
        Show-DownloadBalloon -State $State -Title "$label-Download fehlgeschlagen" -Text $_.Exception.Message -IsError $true
        return $false
    }
}

function Get-LastDownloadError {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $line = Get-Content -LiteralPath $Path -Tail 30 -ErrorAction Stop |
            Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1
        if ($line) { return [string]$line }
    }
    catch { }
    return ''
}

function Add-DownloadHistory {
    # Merkt abgeschlossene Downloads für die Oberfläche (neueste zuerst, höchstens 100 Einträge).
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Job, [string]$Status, [string]$Detail = '')
    if ($null -eq $State.DownloadHistory) { $State.DownloadHistory = New-Object System.Collections.ArrayList }
    $State.DownloadHistory.Insert(0, @{
        Id = $Job.Id; Label = $Job.Label; Url = $Job.Url; Directory = $Job.Directory
        Started = $Job.StartedAt; Ended = Get-Date; Status = $Status; Detail = $Detail
    })
    while ($State.DownloadHistory.Count -gt 100) { $State.DownloadHistory.RemoveAt($State.DownloadHistory.Count - 1) }
}

function Update-DownloadJobs {
    # Prüft laufende Downloads (billig, ohne Blockieren) und schließt fertige ab.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    if ($null -eq $State.DownloadJobs -or $State.DownloadJobs.Count -eq 0) { return }
    foreach ($job in @($State.DownloadJobs)) {
        try {
            $exited = $true
            try { $exited = $job.Process.HasExited } catch { }
            if (-not $exited) { continue }

            $code = $null
            try { $code = $job.Process.ExitCode } catch { }
            $State.DownloadJobs.Remove($job)   # zuerst entfernen: sonst Wiederholung bei Folgefehlern

            $secs = [int]((Get-Date) - $job.StartedAt).TotalSeconds
            if ($code -eq 0) {
                Write-Log -Channel 'download' -Level INFO -Message "Download abgeschlossen ($($job.Label), $secs s): $($job.Url)"
                Add-DownloadHistory -State $State -Job $job -Status 'fertig'
                Show-DownloadBalloon -State $State -Title "$($job.Label)-Download fertig" -Text $job.Directory
                # Erfolgreiche Läufe brauchen keine Einzel-Logs.
                Remove-Item -LiteralPath "$($job.LogBase).out.log", "$($job.LogBase).err.log" -Force -ErrorAction SilentlyContinue
            }
            else {
                $detail = Get-LastDownloadError -Path "$($job.LogBase).err.log"
                $histStatus = if ($job.Cancelled) { 'abgebrochen' } else { 'fehlgeschlagen' }
                Add-DownloadHistory -State $State -Job $job -Status $histStatus -Detail $detail
                Write-Log -Channel 'download' -Level ERROR -Message "Download fehlgeschlagen ($($job.Label), Exit-Code $code): $($job.Url) $detail | Details: logs\download_$($job.Id).err.log"
                $text = if ($detail) { $detail } else { "Exit-Code $code" }
                if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
                Show-DownloadBalloon -State $State -Title "$($job.Label)-Download fehlgeschlagen" -Text $text -IsError $true
            }
        }
        catch {
            Write-Log -Channel 'download' -Level ERROR -Message "Download-Abschluss fehlgeschlagen: $($_.Exception.Message)"
            $State.DownloadJobs.Remove($job)
        }
    }
}

Export-ModuleMember -Function Initialize-Downloader, Stop-Downloader, Request-SingleDownload, Start-SingleDownload, Update-DownloadJobs, Get-ActiveDownloadCount, Show-DownloadDialog, Test-DownloadUrl, Get-LastDownloadError
