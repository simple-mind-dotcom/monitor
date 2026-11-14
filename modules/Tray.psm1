# Symbole per Codepoint, damit die Datei auch ohne UTF-8-BOM korrekt funktioniert.
$script:Sym = @{
    Pause = [char]0x23F8                       # ⏸
    Play  = [char]0x25B6                       # ▶
    Stop  = [char]0x23F9                       # ⏹
    Live  = [char]0x25CF                       # ●
    Off   = [char]0x25CB                       # ○
    Warn  = [char]0x26A0                       # ⚠
    Timer = [char]0x23F1                       # ⏱
    Disk  = [char]::ConvertFromUtf32(0x1F4BE)  # 💾
    Dash  = [char]0x2013                       # –
    Folder = [char]::ConvertFromUtf32(0x1F4C1) # 📁
	Down = [char]0x2B07
}

function New-StatusIcon {
    param([Parameter(Mandatory)][System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(170, 0, 0, 0)), 2
    $g.FillEllipse($brush, 3, 3, 26, 26)
    $g.DrawEllipse($pen, 3, 3, 26, 26)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    # Das HICON-Handle bleibt bewusst für die Prozesslaufzeit offen (nur 3 Icons, einmal erzeugt).
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $icon
}

function Initialize-Tray {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $State.Tray.Icons = @{
        Idle      = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(128, 128, 128))
        Recording = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(220, 40, 40))
        Paused    = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(240, 160, 20))
    }
    $notify.Icon = $State.Tray.Icons.Idle
    $notify.Text = 'Twitch Monitor'
    $notify.ContextMenuStrip = $menu
    $notify.Visible = $true
	$notify.add_DoubleClick({
		try { if (Get-Command Show-MainWindow -ErrorAction SilentlyContinue) { Show-MainWindow -State $State } }
		catch { Write-Log -Level ERROR -Message "Tray (Fenster): $($_.Exception.Message)" }
    }.GetNewClosure())
    $State.Tray.NotifyIcon = $notify
    $State.Tray.ContextMenu = $menu

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    # GetNewClosure: Event-Handler sehen sonst die lokale Variable $State nicht mehr.
    $timer.add_Tick({ Update-Tray -State $State }.GetNewClosure())
    $State.Timers.Tray = $timer
    $timer.Start()
    Update-Tray -State $State
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Test-ChannelStatusUnknown {
    # Der Live-Status ist "unbekannt", wenn die letzte Abfrage fehlschlug oder zu lange zurückliegt
    # (3 Abfrageintervalle). Im pausierten Zustand wird nicht abgefragt, das ist also kein Fehler.
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$ChannelState)
    if ($State.IsPaused) { return $false }
    if ($ChannelState.ApiError) { return $true }
    if ($ChannelState.LastCheck) {
        $limit = 3 * [Math]::Max(15, [int]$State.Config.PollInterval)
        return (((Get-Date) - $ChannelState.LastCheck).TotalSeconds -gt $limit)
    }
    return $false
}

function Update-Tray {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    try {
        $menu = $State.Tray.ContextMenu
        $notify = $State.Tray.NotifyIcon
        if (-not $menu -or -not $notify) { return }

        $recCount = 0
        foreach ($name in @($State.Channels.Keys)) {
            if (Test-ChannelRecording -Channel $name -State $State) { $recCount++ }
        }

        # Icon + Tooltip bei jedem Tick aktualisieren.
        if ($State.ConfigError) { $notify.Icon = $State.Tray.Icons.Paused; $notify.Text = "Twitch Monitor $($script:Sym.Dash) Konfigurationsfehler" }
        elseif ($State.IsPaused) { $notify.Icon = $State.Tray.Icons.Paused; $notify.Text = "Twitch Monitor $($script:Sym.Dash) pausiert" }
        elseif ($recCount -gt 0) { $notify.Icon = $State.Tray.Icons.Recording; $notify.Text = "Twitch Monitor $($script:Sym.Dash) $recCount Aufnahme(n)" }
        else { $notify.Icon = $State.Tray.Icons.Idle; $notify.Text = "Twitch Monitor $($script:Sym.Dash) überwacht" }

        # Ein geöffnetes Menü nicht neu aufbauen (würde schließen/flackern und Klicks verschlucken).
        if ($menu.Visible) { return }

        $old = @($menu.Items)
        $menu.Items.Clear()
        foreach ($o in $old) { $o.Dispose() }
		if (Get-Command Show-MainWindow -ErrorAction SilentlyContinue) {
			$win = $menu.Items.Add('Fenster öffnen')
			$win.Font = New-Object System.Drawing.Font($win.Font, [System.Drawing.FontStyle]::Bold)
			$win.add_Click({
				try { Show-MainWindow -State $State }
				catch { Write-Log -Level ERROR -Message "Tray (Fenster): $($_.Exception.Message)" }
			}.GetNewClosure())
			[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
		}

        if ($State.ConfigError) {
            $msg = [string]$State.ConfigError
            if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 90) + '...' }
            $item = $menu.Items.Add("$($script:Sym.Warn) Konfigurationsfehler")
            $item.Enabled = $false
            $detail = $menu.Items.Add(("   " + ($msg -replace '&', '&&')))
            $detail.Enabled = $false
            $hint = $menu.Items.Add('   Details: logs\monitor.log')
            $hint.Enabled = $false
        }
        else {
            if ($State.IsPaused) {
                $item = $menu.Items.Add("$($script:Sym.Pause) Pausiert")
                $item.Enabled = $false
            }

            # Live/Aufnahme zuerst, dann Status unbekannt, offline, inaktiv - innerhalb der Gruppen alphabetisch.
            # Inaktive Kanäle werden mit abgefragt und zeigen ihren Live-Status ebenfalls an.
            $sorted = @($State.Channels.Keys | ForEach-Object {
                $c = $State.Channels[$_]
                $p = 2
                if ($c.IsLive -or (Test-ChannelRecording -Channel $_ -State $State)) { $p = 0 }
                elseif (-not $c.Enabled) { $p = 3 }
                elseif (Test-ChannelStatusUnknown -State $State -ChannelState $c) { $p = 1 }
                [pscustomobject]@{ Priority = $p; Name = [string]$_ }
            } | Sort-Object Priority, Name | ForEach-Object { $_.Name })
            foreach ($channel in $sorted) {
                $cs = $State.Channels[$channel]
                $unknown = Test-ChannelStatusUnknown -State $State -ChannelState $cs
                $suffix = if ($unknown) { " ($($script:Sym.Warn) Status unbekannt)" } else { '' }

                if (-not $cs.Enabled) {
                    if (Test-ChannelRecording -Channel $channel -State $State) {
                        $item = $menu.Items.Add("$($script:Sym.Live) $channel (inaktiv $($script:Sym.Dash) Aufnahme läuft)")
                        $item.Enabled = $false
                        if ($cs.StartedAt) {
                            $span = (Get-Date) - $cs.StartedAt
                            $duration = '{0:00}:{1:mm\:ss}' -f [int][Math]::Floor($span.TotalHours), $span
                        }
                        else { $duration = '--:--:--' }
                        $size = Format-Size -Bytes (Get-RecordingSize -Channel $channel -State $State)
                        $detail = $menu.Items.Add("   $($script:Sym.Timer) $duration  $($script:Sym.Disk) $size")
                        $detail.Enabled = $false
                    }
                    elseif ($cs.IsLive) {
                        $title = [string]$cs.Title
                        if ($title.Length -gt 30) { $title = $title.Substring(0, 30) }
                        $title = $title -replace '&', '&&'
                        $label = if ($title) { "$($script:Sym.Live) $channel $($script:Sym.Dash) $title (inaktiv $($script:Sym.Dash) live)" }
                        else { "$($script:Sym.Live) $channel (inaktiv $($script:Sym.Dash) live)" }
                        $item = $menu.Items.Add($label)
                        $item.Enabled = $false
                    }
                    elseif ($unknown) {
                        $item = $menu.Items.Add("$($script:Sym.Warn) $channel (inaktiv - Status unbekannt)")
                        $item.Enabled = $false
                    }
                    else {
                        $item = $menu.Items.Add("$($script:Sym.Pause) $channel (inaktiv)")
                        $item.Enabled = $false
                    }
                }
                elseif ($cs.IsLive) {
                    $title = [string]$cs.Title
                    if ($title.Length -gt 30) { $title = $title.Substring(0, 30) }
                    $title = $title -replace '&', '&&'
                    $item = $menu.Items.Add("$($script:Sym.Live) $channel $($script:Sym.Dash) $title$suffix")
                    $item.Enabled = $false

                    if ($cs.StartedAt) {
                        $span = (Get-Date) - $cs.StartedAt
                        $duration = '{0:00}:{1:mm\:ss}' -f [int][Math]::Floor($span.TotalHours), $span
                    }
                    else { $duration = '--:--:--' }
                    $size = Format-Size -Bytes (Get-RecordingSize -Channel $channel -State $State)
                    $detail = $menu.Items.Add("   $($script:Sym.Timer) $duration  $($script:Sym.Disk) $size")
                    $detail.Enabled = $false
                }
                elseif ($unknown) {
                    $item = $menu.Items.Add("$($script:Sym.Warn) $channel (Status unbekannt)")
                    $item.Enabled = $false
                }
                else {
                    $item = $menu.Items.Add("$($script:Sym.Off) $channel (offline)")
                    $item.Enabled = $false
                }
            }

            # Untermenü: einzelne Kanäle aktiv (Haken) oder inaktiv schalten.
            $sub = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Aktive Kanäle:'
            foreach ($channel in @($State.Channels.Keys | Sort-Object)) {
                $label = $channel -replace '&', '&&'
                if ($State.Channels[$channel].IsLive) { $label = "$label  $($script:Sym.Live)" }
                $entry = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList $label
                $entry.Checked = [bool]$State.Channels[$channel].Enabled
                # GetNewClosure: $channel und $State müssen im Handler pro Eintrag erhalten bleiben.
                $entry.add_Click({
                    try {
                        Set-ChannelEnabled -State $State -Channel $channel -Enabled (-not [bool]$State.Channels[$channel].Enabled)
                        Update-Tray -State $State
                    }
                    catch { Write-Log -Level ERROR -Message "Tray (Kanal umschalten): $($_.Exception.Message)" }
                }.GetNewClosure())
                [void]$sub.DropDownItems.Add($entry)
            }
            [void]$menu.Items.Add($sub)
        }

        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        if (-not $State.ConfigError) {
            $toggleText = if ($State.IsPaused) { "$($script:Sym.Play) Fortsetzen" } else { "$($script:Sym.Pause) Pausieren" }
            $toggle = $menu.Items.Add($toggleText)
            $toggle.add_Click({
                try {
                    if ($State.IsPaused) { Resume-Monitor -State $State } else { Pause-Monitor -State $State }
                    Update-Tray -State $State
                }
                catch { Write-Log -Level ERROR -Message "Tray (Pause/Fortsetzen): $($_.Exception.Message)" }
            }.GetNewClosure())
        }

        $openFolder = $menu.Items.Add("$($script:Sym.Folder) Download-Ordner öffnen")
        $openFolder.add_Click({
            try {
                $dir = [string]$State.Config.OutputDirectory
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
                Invoke-Item -LiteralPath $dir
            }
            catch { Write-Log -Level ERROR -Message "Tray (Ordner öffnen): $($_.Exception.Message)" }
        }.GetNewClosure())
		$dl = $menu.Items.Add("$($script:Sym.Down) Download (Link)...")
		$dl.add_Click({
			try { Request-SingleDownload -State $State }
			catch { Write-Log -Level ERROR -Message "Tray (Download): $($_.Exception.Message)" }
		}.GetNewClosure())
		$dlCount = Get-ActiveDownloadCount -State $State
		if ($dlCount -gt 0) {
			$dlInfo = $menu.Items.Add("   $($script:Sym.Disk) $dlCount Download(s) laufen")
			$dlInfo.Enabled = $false
		}
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $stop = $menu.Items.Add("$($script:Sym.Stop) Monitoring beenden")
        $stop.add_Click({
            try { Stop-Monitor -State $State -StopRecordings $true }
            catch { Write-Log -Level ERROR -Message "Tray (Monitoring beenden): $($_.Exception.Message)" }
        }.GetNewClosure())

        $exit = $menu.Items.Add('Beenden (App)')
        $exit.add_Click({
            try { Stop-Monitor -State $State -StopRecordings $false }
            catch { Write-Log -Level ERROR -Message "Tray (Beenden): $($_.Exception.Message)" }
        }.GetNewClosure())
    }
    catch {
        Write-Log -Level ERROR -Message "Tray-Update fehlgeschlagen: $($_.Exception.Message)"
    }
}

function Set-TrayStatus {
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Status)
    if ($State.Tray.NotifyIcon) { $State.Tray.NotifyIcon.Text = $Status.Substring(0, [Math]::Min(63, $Status.Length)) }
}

function Show-TrayBalloon {
    # Zentrale Balloon-Meldungen (Aufnahme, Download, Warnungen). Ohne Tray-Icon (NoTray) ein No-Op.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Title, [string]$Text = '', [bool]$IsError = $false)
    try {
        $n = $State.Tray.NotifyIcon
        if (-not $n) { return }
        $icon = if ($IsError) { [System.Windows.Forms.ToolTipIcon]::Error } else { [System.Windows.Forms.ToolTipIcon]::Info }
        $n.ShowBalloonTip(6000, $Title, $Text, $icon)
    }
    catch { }
}

function Dispose-Tray {
    param([Parameter(Mandatory)][hashtable]$State)
    if ($State.Timers.Tray) { $State.Timers.Tray.Stop(); $State.Timers.Tray.Dispose(); $State.Timers.Tray = $null }
    if ($State.Tray.NotifyIcon) { $State.Tray.NotifyIcon.Visible = $false; $State.Tray.NotifyIcon.Dispose(); $State.Tray.NotifyIcon = $null }
    if ($State.Tray.ContextMenu) { $State.Tray.ContextMenu.Dispose(); $State.Tray.ContextMenu = $null }
}

Export-ModuleMember -Function Initialize-Tray, Update-Tray, Set-TrayStatus, Dispose-Tray, Show-TrayBalloon, Format-Size
