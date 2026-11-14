function New-ChannelState {
    param([Parameter(Mandatory)][string]$Name)
    return @{
        Name = $Name; Enabled = $true; IsLive = $false; Title = ''; StartedAt = $null
        Process = $null; ProcessId = $null; OutputFile = $null
        OutputFolder = $null; OutputPrefix = $null
        OfflineCount = 0; LastCheck = $null; LastError = $null; ApiError = $null
        FailCount = 0; NextStartAt = $null; OrphanLogged = $false
    }
}

function Set-ApiErrorAll {
    # Ein Fehler, der alle Kanäle betrifft (Token, Netzwerk, Rate-Limit), macht den Status aller Kanäle unbekannt.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Message)
    foreach ($k in @($State.Channels.Keys)) { $State.Channels[$k].ApiError = $Message }
}

# Läuft in einem Hintergrund-Runspace (kein Zugriff auf Module/State!): holt bei Bedarf ein Token und fragt
# ALLE Kanäle in einer einzigen Anfrage ab (die Twitch-API erlaubt bis zu 100 user_login pro Aufruf).
# Dadurch blockiert die Abfrage weder das Tray noch das Hauptfenster. Ergebnis: Hashtable.
$script:PollScript = @'
param($ClientId, $ClientSecret, $Token, $Channels, $YtDlpPath, $CheckVersion)
$ErrorActionPreference = 'Stop'
$result = @{ Token = $null; ExpiresIn = 0; Streams = @{}; Error = $null; Code = -1; RetryAfter = 0; YtDlpVersion = $null }
try {
    if (-not $Token) {
        $body = @{ client_id = $ClientId; client_secret = $ClientSecret; grant_type = 'client_credentials' }
        $r = Invoke-RestMethod -Method Post -Uri 'https://id.twitch.tv/oauth2/token' -Body $body `
            -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15 -ErrorAction Stop
        $Token = [string]$r.access_token
        $result.Token = $Token
        $result.ExpiresIn = [int]$r.expires_in
    }
    $headers = @{ 'Client-Id' = $ClientId; 'Authorization' = "Bearer $Token" }
    $live = @{}
    $list = @($Channels)
    for ($i = 0; $i -lt $list.Count; $i += 100) {
        $end = [Math]::Min($i + 99, $list.Count - 1)
        $query = (@($list[$i..$end]) | ForEach-Object { 'user_login=' + [uri]::EscapeDataString([string]$_) }) -join '&'
        $resp = Invoke-RestMethod -Method Get -Uri "https://api.twitch.tv/helix/streams?$query" `
            -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        foreach ($s in @($resp.data)) {
            if ($s) { $live[([string]$s.user_login).ToLowerInvariant()] = @{ Title = [string]$s.title } }
        }
    }
    $result.Streams = $live
}
catch {
    $result.Error = $_.Exception.Message
    try {
        $resp = $_.Exception.Response
        if ($resp -and $resp.StatusCode) { $result.Code = [int]$resp.StatusCode }
        if ($resp) {
            try { $result.RetryAfter = [int]$resp.Headers['Retry-After'] } catch { }
        }
    }
    catch { }
    if ($result.Code -lt 0 -and $_.Exception -is [System.Net.WebException]) { $result.Code = 0 }   # Netzwerkfehler/Timeout
}
if ($CheckVersion) {
    try {
        $v = @(& $YtDlpPath --version 2>$null)
        if ($v.Count -gt 0) { $result.YtDlpVersion = ([string]$v[0]).Trim() }
    }
    catch { }
}
$result
'@

function Stop-PollJob {
    # Bricht eine laufende Abfrage ab, ohne zu blockieren (BeginStop). Der Runspace wird nicht synchron
    # entsorgt, sondern in StoppingPollJobs gemerkt und vom Poll-Timer später freigegeben (kein Leak).
    param([Parameter(Mandatory)][hashtable]$State)
    $job = $State.PollJob
    $State.PollJob = $null
    if (-not $job) { return }
    $job.StoppedAt = Get-Date
    if ($null -eq $State.StoppingPollJobs) { $State.StoppingPollJobs = New-Object System.Collections.ArrayList }
    [void]$State.StoppingPollJobs.Add($job)
    try { [void]$job.PS.BeginStop($null, $null) } catch { }
}

function Update-StoppingPollJobs {
    # Gibt abgebrochene Abfrage-Runspaces frei, sobald BeginStop abgeschlossen ist (billig, ohne Blockieren).
    param([Parameter(Mandatory)][hashtable]$State)
    if ($null -eq $State.StoppingPollJobs -or $State.StoppingPollJobs.Count -eq 0) { return }
    foreach ($job in @($State.StoppingPollJobs)) {
        $elapsed = ((Get-Date) - $job.StoppedAt).TotalSeconds
        if ($elapsed -lt 2) { continue }
        $disposed = $false
        try { $job.PS.Dispose(); $disposed = $true } catch { }
        if ($disposed -or $elapsed -gt 30) { [void]$State.StoppingPollJobs.Remove($job) }
    }
}

function Invoke-MonitorCycle {
    # Startet einen Abfragezyklus. Blockiert nicht: die Twitch-Abfrage läuft im Hintergrund,
    # das Ergebnis wertet Update-MonitorPoll (Timer, alle 500 ms) aus.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    if ($State.IsPaused -or $State.IsStopping -or $State.ConfigError) { return }

    foreach ($channel in @($State.Channels.Keys)) {
        $cs = $State.Channels[$channel]
        if ($cs.Enabled) { continue }
        # Inaktiver Kanal: keine Abfrage, kein Start. Eine noch laufende Aufnahme wird nicht unterbrochen;
        # hier wird sie nur aufgeräumt (Log, Remux), sobald yt-dlp sich beendet hat.
        try { [void](Get-RecordingStatus -Channel $channel -State $State) }
        catch { Write-Log -Channel $channel -Level ERROR -Message "Aufräumen (inaktiv): $($_.Exception.Message)" }
    }

    # Backoff nach Rate-Limit/Serverfehlern: die API nicht weiter belästigen.
    if ($State.ApiBackoffUntil -and (Get-Date) -lt $State.ApiBackoffUntil) { return }

    if ($State.PollJob) { return }   # vorige Abfrage läuft noch
    $active = @($State.Channels.Keys | Where-Object { $State.Channels[$_].Enabled } | Sort-Object)
    if ($active.Count -eq 0) { return }

    # Token wiederverwenden, solange es gültig ist (5 Minuten Sicherheitsabstand sind in TokenExpiresAt enthalten).
    $token = $null
    if ($State.TwitchAccessToken -and $State.TokenExpiresAt -and (Get-Date) -lt $State.TokenExpiresAt) { $token = $State.TwitchAccessToken }

    try {
        $cfg = $State.Config
        $checkVersion = (-not $State.YtDlpVersionChecked)
        $ps = [powershell]::Create()
        [void]$ps.AddScript($script:PollScript).AddArgument($cfg.TwitchClientId).AddArgument($cfg.TwitchClientSecret).AddArgument($token).AddArgument($active).AddArgument($cfg.YtDlpPath).AddArgument($checkVersion)
        $handle = $ps.BeginInvoke()
        $State.PollJob = @{ PS = $ps; Handle = $handle; StartedAt = Get-Date; Channels = $active }
    }
    catch {
        Write-Log -Level WARN -Message "Twitch-Abfrage konnte nicht gestartet werden: $($_.Exception.Message)"
        Set-ApiErrorAll -State $State -Message $_.Exception.Message
    }
}

function Test-YtDlpAge {
    # yt-dlp bricht bei Twitch-Änderungen regelmäßig - deshalb einmal pro Start das Alter der Version prüfen.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$Result)
    if ($State.YtDlpVersionChecked) { return }
    $State.YtDlpVersionChecked = $true
    $version = [string]$Result.YtDlpVersion
    if (-not $version) { return }
    $parsed = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($version, 'yyyy.MM.dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)
    if (-not $ok) { return }
    $age = [int](((Get-Date) - $parsed).TotalDays)
    if ($age -le 30) { return }
    Write-Log -Level WARN -Message "yt-dlp $version ist $age Tage alt - bei Twitch-Problemen bitte aktualisieren (scoop update yt-dlp)."
    Show-TrayBalloon -State $State -Title 'yt-dlp veraltet' -Text "yt-dlp ist $age Tage alt. Bei Twitch-Problemen: scoop update yt-dlp" -IsError $true
}

function Update-MonitorPoll {
    # Wird vom Poll-Timer gerufen (billig: prüft nur, ob die Hintergrundabfrage fertig ist) und wertet
    # das Ergebnis aus: Live-Status setzen, Aufnahmen starten/stoppen.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    Update-StoppingPollJobs -State $State

    $job = $State.PollJob
    if (-not $job) { return }
    $done = $false
    try { $done = $job.Handle.IsCompleted } catch { $done = $true }
    $timedOut = (((Get-Date) - $job.StartedAt).TotalSeconds -gt 60)
    if (-not $done -and -not $timedOut) { return }

    $result = $null
    if (-not $done) {
        Stop-PollJob -State $State
        $result = @{ Error = 'Zeitüberschreitung der Twitch-Abfrage'; Code = 0 }
    }
    else {
        $State.PollJob = $null
        try {
            $out = @($job.PS.EndInvoke($job.Handle))
            $result = $out | Where-Object { $_ -is [hashtable] } | Select-Object -First 1
            if (-not $result) { $result = @{ Error = 'Leere Antwort der Hintergrundabfrage'; Code = -1 } }
        }
        catch { $result = @{ Error = $_.Exception.Message; Code = -1 } }
        finally { try { $job.PS.Dispose() } catch { } }
    }

    # Pausiert/beendet: Ergebnis verwerfen (es werden keine Aufnahmen mehr gestartet).
    if ($State.IsPaused -or $State.IsStopping) { return }

    if ($result.Error) {
        $msg = [string]$result.Error
        Write-Log -Level WARN -Message "Twitch-Abfrage fehlgeschlagen: $msg"
        if ([int]$result.Code -eq 401) {
            $State.TwitchAccessToken = $null   # Token ungültig -> im nächsten Zyklus neu holen
            $State.TokenExpiresAt = $null
        }
        # Rate-Limit/Serverfehler: mit exponentiellem Backoff (max. 30 min) das nächste Abfragen verzögern.
        $code = [int]$result.Code
        if ($code -eq 429 -or $code -ge 500) {
            $State.ApiBackoffFails = [int]$State.ApiBackoffFails + 1
            $delay = [Math]::Min(1800, 60 * [Math]::Pow(2, [Math]::Min([int]$State.ApiBackoffFails, 5) - 1))
            $retryAfter = [int]$result.RetryAfter
            if ($retryAfter -gt $delay) { $delay = [Math]::Min(1800, $retryAfter) }
            $State.ApiBackoffUntil = (Get-Date).AddSeconds($delay)
            Write-Log -Level WARN -Message "Twitch-API (HTTP $code) - nächste Abfrage in $([int]$delay) s."
        }
        foreach ($channel in $job.Channels) {
            $cs = $State.Channels[$channel]
            if ($cs) { $cs.LastError = $msg }
        }
        Set-ApiErrorAll -State $State -Message $msg
        return
    }

    if ($result.Token) {
        $State.TwitchAccessToken = [string]$result.Token
        $State.TokenExpiresAt = (Get-Date).AddSeconds([Math]::Max(60, [int]$result.ExpiresIn - 300))
    }
    $State.ApiBackoffFails = 0
    $State.ApiBackoffUntil = $null
    Test-YtDlpAge -State $State -Result $result
    $streams = $result.Streams
    if ($null -eq $streams) { $streams = @{} }

    foreach ($channel in $job.Channels) {
        $cs = $State.Channels[$channel]
        # Der Kanal kann zwischenzeitlich entfernt oder deaktiviert worden sein.
        if ($null -eq $cs -or -not $cs.Enabled) { continue }
        try {
            $isLive = $streams.ContainsKey($channel)
            $cs.LastCheck = Get-Date
            $cs.LastError = $null
            $cs.ApiError = $null
            $cs.IsLive = $isLive
            $cs.Title = if ($isLive) { [string]$streams[$channel].Title } else { '' }

            # Räumt außerdem einen von selbst beendeten yt-dlp-Prozess auf (und setzt ggf. den Neustart-Backoff).
            $recording = Get-RecordingStatus -Channel $channel -State $State

            if ($isLive) {
                $cs.OfflineCount = 0
                if (-not $recording) {
                    # Backoff nach Fehlstarts: nicht jede Abfrage einen neuen yt-dlp-Prozess starten.
                    if ($cs.NextStartAt -and (Get-Date) -lt $cs.NextStartAt) { continue }

                    # Läuft schon ein yt-dlp für diesen Kanal, den wir nicht kennen (z. B. nach "Beenden (App)"
                    # oder einem Absturz)? Dann keine zweite Aufnahme desselben Streams starten.
                    $orphans = @(Get-OrphanRecorder -Channel $channel)
                    if ($orphans.Count -gt 0) {
                        if (-not $cs.OrphanLogged) {
                            $ids = ($orphans | ForEach-Object { $_.ProcessId }) -join ', '
                            Write-Log -Channel $channel -Level WARN -Message "Es läuft bereits ein unbekannter Aufnahmeprozess (PID $ids) - starte keine zweite Aufnahme."
                            $cs.OrphanLogged = $true
                        }
                        continue
                    }
                    $cs.OrphanLogged = $false
                    Start-ChannelRecording -Channel $channel -State $State -Title $cs.Title | Out-Null
                }
            }
            else {
                $cs.OfflineCount++
                $cs.OrphanLogged = $false
                if ($recording) {
                    # yt-dlp beendet sich bei Stream-Ende meist selbst. Erst wenn die API zweimal
                    # hintereinander "offline" meldet und der Prozess noch läuft, wird er gestoppt.
                    if ($cs.OfflineCount -ge 2) {
                        Stop-ChannelRecording -Channel $channel -State $State | Out-Null
                    }
                }
                else {
                    # Stream vorbei: Backoff zurücksetzen, damit der nächste Stream sofort aufgenommen wird.
                    $cs.FailCount = 0
                    $cs.NextStartAt = $null
                }
            }
        }
        catch {
            $cs.LastError = $_.Exception.Message
            Write-Log -Channel $channel -Level WARN -Message "Monitor-Verarbeitung fehlgeschlagen: $($_.Exception.Message)"
        }
    }
}

function Start-Monitor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    # Blockierende Konfigurationsprobleme (fehlende Zugangsdaten, yt-dlp nicht gefunden ...) werden im Tray
    # angezeigt; das Monitoring startet dann nicht (sonst gäbe es alle paar Sekunden dieselbe Fehlermeldung).
    $problems = @($State.Config.EnvironmentErrors | Where-Object { $_ })
    if ($problems.Count -gt 0) {
        $State.ConfigError = $problems -join '; '
        Write-Log -Level ERROR -Message "Konfigurationsfehler - Monitoring wird nicht gestartet: $($State.ConfigError)"
        return
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(15, [int]$State.Config.PollInterval) * 1000
    # GetNewClosure: Event-Handler sehen sonst die lokale Variable $State nicht mehr.
    $timer.add_Tick({ Invoke-MonitorCycle -State $State }.GetNewClosure())
    $State.Timers.Monitor = $timer
    $timer.Start()

    # Ergebnis der Hintergrundabfrage regelmäßig und billig abholen.
    $pollTimer = New-Object System.Windows.Forms.Timer
    $pollTimer.Interval = 500
    $pollTimer.add_Tick({
        try { Update-MonitorPoll -State $State }
        catch { Write-Log -Level ERROR -Message "Poll-Timer: $($_.Exception.Message)" }
    }.GetNewClosure())
    $State.Timers.Poll = $pollTimer
    $pollTimer.Start()

    # Remux-Jobs (ffmpeg läuft im Hintergrund) regelmäßig und billig auf Fertigstellung prüfen.
    $remuxTimer = New-Object System.Windows.Forms.Timer
    $remuxTimer.Interval = 5000
    $remuxTimer.add_Tick({
        try { Update-RemuxJobs -State $State }
        catch { Write-Log -Level ERROR -Message "Remux-Timer: $($_.Exception.Message)" }
    }.GetNewClosure())
    $State.Timers.Remux = $remuxTimer
    $remuxTimer.Start()

    # Erster Zyklus erst, wenn der Message-Loop läuft (nicht synchron vor Application.Run()):
    # So ist das Tray sofort bedienbar, auch wenn beim Autostart das Netzwerk noch fehlt.
    Request-MonitorCycle -State $State
}

function Request-MonitorCycle {
    # Einmaliger, verzögerter Zyklus über einen Timer (blockiert den Aufrufer, z. B. einen Menü-Klick, nicht).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [int]$DelayMs = 500)

    if ($State.IsPaused -or $State.IsStopping -or $State.ConfigError) { return }
    $once = New-Object System.Windows.Forms.Timer
    $once.Interval = $DelayMs
    $once.add_Tick({
        param($sender, $e)
        $sender.Stop()
        $sender.Dispose()
        try { Invoke-MonitorCycle -State $State }
        catch { Write-Log -Level ERROR -Message "Monitor-Zyklus: $($_.Exception.Message)" }
    }.GetNewClosure())
    $once.Start()
}

function Set-ChannelEnabled {
    # Aktiviert/deaktiviert einen Kanal (Tray-Menü, Fenster) und speichert die Auswahl in state.json.
    # Beim Deaktivieren wird eine laufende Aufnahme beendet.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][bool]$Enabled
    )

    $cs = $State.Channels[$Channel]
    if ($null -eq $cs -or [bool]$cs.Enabled -eq $Enabled) { return }
    $cs.Enabled = $Enabled
    # Zustand der Abfrage zurücksetzen, damit nichts Veraltetes angezeigt wird.
    $cs.IsLive = $false; $cs.LastCheck = $null; $cs.ApiError = $null; $cs.OfflineCount = 0
    $cs.FailCount = 0; $cs.NextStartAt = $null; $cs.OrphanLogged = $false

    $disabled = @($State.Channels.Keys | Where-Object { -not $State.Channels[$_].Enabled } | Sort-Object)
    if ($State.StatePath) { [void](Save-DisabledChannels -Path $State.StatePath -Channels $disabled) }

    if ($Enabled) {
        Write-Log -Channel $Channel -Level INFO -Message 'Kanal aktiviert.'
        Request-MonitorCycle -State $State
    }
    else {
        Write-Log -Channel $Channel -Level INFO -Message 'Kanal deaktiviert.'
        # Eine laufende Aufnahme wird sauber beendet (Ctrl+C, Remux läuft danach im Hintergrund).
        # Das blockiert bis zur Finalisierung (typisch einige Sekunden, höchstens ca. 45 s).
        if (Test-ChannelRecording -Channel $Channel -State $State) {
            if (-not (Stop-ChannelRecording -Channel $Channel -State $State)) {
                Write-Log -Channel $Channel -Level WARN -Message 'Aufnahme konnte nicht vollständig beendet werden; sie läuft weiter und wird aufgeräumt, sobald sie endet.'
            }
        }
    }
}

function Pause-Monitor {
    param([Parameter(Mandatory)][hashtable]$State)
    $State.IsPaused = $true
    Write-Log -Level INFO -Message 'Monitoring pausiert (laufende Aufnahmen bleiben aktiv).'
}

function Resume-Monitor {
    param([Parameter(Mandatory)][hashtable]$State)
    $State.IsPaused = $false
    Write-Log -Level INFO -Message 'Monitoring fortgesetzt.'
    Invoke-MonitorCycle -State $State
}

function Stop-Monitor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [bool]$StopRecordings = $true
    )
    $State.IsStopping = $true
    $State.IsRunning = $false
    try {
        if ($State.Timers.Monitor) { $State.Timers.Monitor.Stop(); $State.Timers.Monitor.Dispose(); $State.Timers.Monitor = $null }
        if ($State.Timers.Poll) { $State.Timers.Poll.Stop(); $State.Timers.Poll.Dispose(); $State.Timers.Poll = $null }
        Stop-PollJob -State $State
    }
    catch { Write-Log -Level ERROR -Message "Stop-Monitor (Timer): $($_.Exception.Message)" }

    if ($StopRecordings) {
        foreach ($channel in @($State.Channels.Keys)) {
            # Ein Fehler bei einem Kanal darf das Beenden der übrigen nicht verhindern.
            try { Stop-ChannelRecording -Channel $channel -State $State | Out-Null }
            catch { Write-Log -Channel $channel -Level ERROR -Message "Stop-Monitor: $($_.Exception.Message)" }
        }
    }

    # Laufende Remux-Jobs (auch aus früheren Zyklen) abwarten, sonst bleiben .part/.remux.mp4 liegen.
    try {
        if ($State.Timers.Remux) { $State.Timers.Remux.Stop(); $State.Timers.Remux.Dispose(); $State.Timers.Remux = $null }
        Wait-RemuxJobs -State $State
    }
    catch { Write-Log -Level ERROR -Message "Stop-Monitor (Remux): $($_.Exception.Message)" }
    [System.Windows.Forms.Application]::Exit()
}

Export-ModuleMember -Function New-ChannelState, Set-ChannelEnabled, Start-Monitor, Stop-Monitor, Pause-Monitor, Resume-Monitor, Invoke-MonitorCycle, Update-MonitorPoll, Test-YtDlpAge
