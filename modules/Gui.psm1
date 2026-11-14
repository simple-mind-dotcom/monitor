# Optionale grafische Oberfläche (Hauptfenster) im modernen Look.
# Seiten (Seitenleiste links): Übersicht (Kanäle/Aufnahmen), Downloads, Einstellungen (config.json),
#   yt-dlp-Configs (twitch.conf / Video / Musik) und Log.
# Das Design folgt automatisch dem Hell-/Dunkelmodus von Windows (Apps).
# Das Fenster ist nicht modal; das Schließen versteckt es nur (die App läuft im Tray weiter).
#
# Hinweis: Event-Handler (GetNewClosure) sehen keine $script:-Variablen und keine nicht exportierten
# Funktionen dieses Moduls. Deshalb werden alle Funktionen, die aus Handlern gerufen werden, exportiert,
# und Handler arbeiten nur mit lokalen Kopien ($gui, $State, Controls, Farben, Pinsel).
# Performance: Der Aufbau der Listen ist billig; teure Dinge (Verzeichnisgrößen, Log lesen) sind gecacht.
# Die Twitch-Abfrage selbst läuft im Hintergrund (Monitor.psm1) und blockiert das Fenster nicht.

$script:Gui = @{
    Form = $null; Timer = $null; Refreshing = $false
    Fields = @{}; Controls = @{}; Pages = @{}; Nav = @{}
    Theme = $null; Fonts = $null; CurrentPage = 'Overview'; LogStamp = ''
}

# ---------------------------------------------------------------- Theme

function Get-GuiTheme {
    $dark = $false
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        $dark = ([int]$v -eq 0)
    }
    catch { }
    $c = { param([string]$hex) [System.Drawing.ColorTranslator]::FromHtml($hex) }
    $t = @{
        Dark = $dark
        Sidebar = (& $c '#18181b'); SidebarHover = (& $c '#26262c'); SidebarText = (& $c '#e4e4e7'); SidebarMuted = (& $c '#9a9aa6')
        Accent = (& $c '#9146ff'); AccentHover = (& $c '#a970ff'); AccentText = (& $c '#ffffff')
        Danger = (& $c $(if ($dark) { '#ff6b6b' } else { '#d93a3a' }))
        Success = (& $c $(if ($dark) { '#3fb950' } else { '#1a9a3c' }))
        Warn = (& $c $(if ($dark) { '#e3b341' } else { '#c98500' }))
    }
    if ($dark) {
        $t.Bg = (& $c '#1e1f24'); $t.Surface = (& $c '#272a31'); $t.SurfaceAlt = (& $c '#2e323b'); $t.RowAlt = (& $c '#2b2e36')
        $t.Text = (& $c '#e8eaed'); $t.Muted = (& $c '#9aa0aa'); $t.Border = (& $c '#3a3f4a'); $t.AccentSoft = (& $c '#3a3566')
    }
    else {
        $t.Bg = (& $c '#f2f3f7'); $t.Surface = (& $c '#ffffff'); $t.SurfaceAlt = (& $c '#eceef4'); $t.RowAlt = (& $c '#f8f9fc')
        $t.Text = (& $c '#1f2330'); $t.Muted = (& $c '#6b7280'); $t.Border = (& $c '#dcdfe8'); $t.AccentSoft = (& $c '#ece4ff')
    }
    return $t
}

function New-GuiFonts {
    return @{
        Base = (New-Object System.Drawing.Font('Segoe UI', 9.5))
        Semi = (New-Object System.Drawing.Font('Segoe UI Semibold', 9.5))
        Title = (New-Object System.Drawing.Font('Segoe UI Semibold', 17))
        Brand = (New-Object System.Drawing.Font('Segoe UI Semibold', 13))
        Small = (New-Object System.Drawing.Font('Segoe UI', 8.5))
        Mono = (New-Object System.Drawing.Font('Consolas', 10))
    }
}

function Set-GuiTitleBarTheme {
    # Dunkle Titelleiste unter Windows 10/11 (Fehler sind unkritisch).
    param([Parameter(Mandatory)]$Form, [bool]$Dark)
    try {
        if (-not ('TmGui.Dwm' -as [type])) {
            Add-Type -Namespace TmGui -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
        }
        $v = if ($Dark) { 1 } else { 0 }
        [void][TmGui.Dwm]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$v, 4)
    }
    catch { }
}

# ---------------------------------------------------------------- Hilfsfunktionen

function Format-GuiSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Format-GuiSpan {
    param([TimeSpan]$Span)
    return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

function Resolve-GuiPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Set-GuiProp {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Read-GuiRawConfig {
    param([Parameter(Mandatory)][hashtable]$State)
    $path = Join-Path $State.ProjectRoot 'config.json'
    if (Test-Path -LiteralPath $path) {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return [pscustomobject]@{}
}

function Sync-GuiListView {
    # Aktualisiert eine ListView ohne Flackern: gleiche Zeilenfolge -> nur geänderte Zellen setzen,
    # sonst neu aufbauen (Auswahl bleibt erhalten).
    # Rows: @{ Key; Cells = @(...); Tag (optional, hier: Kanal aktiv ja/nein) }
    param([Parameter(Mandatory)][System.Windows.Forms.ListView]$ListView, [object[]]$Rows = @())

    $existing = (@($ListView.Items | ForEach-Object { $_.Name }) -join "`n")
    $wanted = (@($Rows | ForEach-Object { $_.Key }) -join "`n")
    $ListView.BeginUpdate()
    try {
        if ($existing -ne $wanted) {
            $selected = @($ListView.SelectedItems | ForEach-Object { $_.Name })
            $ListView.Items.Clear()
            foreach ($r in $Rows) {
                $item = $ListView.Items.Add([string]$r.Key, [string]$r.Cells[0], -1)
                for ($i = 1; $i -lt $r.Cells.Count; $i++) { [void]$item.SubItems.Add([string]$r.Cells[$i]) }
                if ($r.ContainsKey('Tag')) { $item.Tag = [bool]$r.Tag }
                if ($selected -contains $r.Key) { $item.Selected = $true }
            }
        }
        else {
            for ($n = 0; $n -lt $Rows.Count; $n++) {
                $item = $ListView.Items[$n]
                $cells = $Rows[$n].Cells
                $changed = $false
                for ($i = 0; $i -lt $cells.Count; $i++) {
                    $text = [string]$cells[$i]
                    if ($item.SubItems[$i].Text -ne $text) { $item.SubItems[$i].Text = $text; $changed = $true }
                }
                if ($Rows[$n].ContainsKey('Tag') -and ([bool]$item.Tag -ne [bool]$Rows[$n].Tag)) {
                    $item.Tag = [bool]$Rows[$n].Tag
                    $changed = $true
                }
                if ($changed) { $ListView.RedrawItems($n, $n, $false) }
            }
        }
    }
    finally { $ListView.EndUpdate() }
}

# ---------------------------------------------------------------- Datenzeilen

function Get-GuiChannelRows {
    param([Parameter(Mandatory)][hashtable]$State)
    $limit = 3 * [Math]::Max(15, [int]$State.Config.PollInterval)
    $now = Get-Date
    $rows = @()
    foreach ($name in @($State.Channels.Keys | Sort-Object)) {
        $cs = $State.Channels[$name]
        $rec = Test-ChannelRecording -Channel $name -State $State
        $unknown = $false
        if (-not $State.IsPaused -and $cs.Enabled) {
            if ($cs.ApiError) { $unknown = $true }
            elseif ($cs.LastCheck -and (($now - $cs.LastCheck).TotalSeconds -gt $limit)) { $unknown = $true }
        }
        $status =
            if ($rec -and -not $cs.Enabled) { 'Aufnahme läuft (inaktiv)' }
            elseif ($rec) { 'Aufnahme läuft' }
            elseif (-not $cs.Enabled) { 'inaktiv' }
            elseif ($cs.IsLive) { 'live (keine Aufnahme)' }
            elseif ($unknown) { 'Status unbekannt' }
            else { 'offline' }

        $duration = ''; $size = ''
        if ($rec -and $cs.StartedAt) {
            $duration = Format-GuiSpan -Span ($now - $cs.StartedAt)
            # Verzeichnisgröße höchstens alle 5 s neu berechnen (Dateisystemzugriff vermeiden).
            if ($null -eq $cs.GuiSizeAt -or (($now - $cs.GuiSizeAt).TotalSeconds -ge 5)) {
                $cs.GuiSize = Get-RecordingSize -Channel $name -State $State
                $cs.GuiSizeAt = $now
            }
            $size = Format-GuiSize -Bytes ([int64]$cs.GuiSize)
        }
        $title = if ($cs.IsLive) { [string]$cs.Title } else { '' }
        $last = if ($cs.LastCheck) { $cs.LastCheck.ToString('HH:mm:ss') } else { '' }
        $hint = if ($cs.ApiError) { [string]$cs.ApiError } elseif ($cs.LastError) { [string]$cs.LastError } else { '' }
        $rows += @{ Key = $name; Tag = [bool]$cs.Enabled; Cells = @('', $name, $status, $title, $duration, $size, $last, $hint) }
    }
    return , $rows
}

function Get-GuiDownloadRows {
    param([Parameter(Mandatory)][hashtable]$State)
    $rows = @()
    foreach ($job in @($State.DownloadJobs)) {
        if ($null -eq $job) { continue }
        $span = Format-GuiSpan -Span ((Get-Date) - $job.StartedAt)
        $rows += @{ Key = [string]$job.Id; Cells = @($job.StartedAt.ToString('dd.MM. HH:mm:ss'), [string]$job.Label, 'läuft', $span, [string]$job.Url, '') }
    }
    foreach ($h in @($State.DownloadHistory)) {
        if ($null -eq $h) { continue }
        $span = Format-GuiSpan -Span ($h.Ended - $h.Started)
        $rows += @{ Key = [string]$h.Id; Cells = @($h.Started.ToString('dd.MM. HH:mm:ss'), [string]$h.Label, [string]$h.Status, $span, [string]$h.Url, [string]$h.Detail) }
    }
    return , $rows
}

# ---------------------------------------------------------------- Aktualisierung

function Update-MainWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $gui = $script:Gui
    if ($null -eq $gui.Form -or $gui.Form.IsDisposed) { return }
    $c = $gui.Controls
    $t = $gui.Theme

    # In der Konfiguration entfernte Kanäle verschwinden, sobald keine Aufnahme mehr zu ihnen gehört
    # (Process ist erst nach dem Aufräumen durch den Monitor $null, damit der Remux nicht verloren geht).
    foreach ($n in @($State.Channels.Keys)) {
        if (($State.Config.Channels -notcontains $n) -and $null -eq $State.Channels[$n].Process) { $State.Channels.Remove($n) }
    }

    $gui.Refreshing = $true
    try {
        # Nur die sichtbare Seite aktualisieren.
        if ($gui.CurrentPage -eq 'Overview') { Sync-GuiListView -ListView $c.ChannelList -Rows (Get-GuiChannelRows -State $State) }
        if ($gui.CurrentPage -eq 'Downloads') { Sync-GuiListView -ListView $c.DownloadList -Rows (Get-GuiDownloadRows -State $State) }

        $polling = [bool]$State.PollJob
        $c.PauseButton.Text = if ($State.IsPaused) { 'Fortsetzen' } else { 'Pausieren' }
        $c.PauseButton.Enabled = -not $State.ConfigError
        $c.CheckButton.Enabled = (-not $State.ConfigError) -and (-not $State.IsPaused) -and (-not $polling)

        $rec = 0
        foreach ($n in @($State.Channels.Keys)) { if (Test-ChannelRecording -Channel $n -State $State) { $rec++ } }
        $dl = Get-ActiveDownloadCount -State $State
        $head = if ($State.ConfigError) { 'Konfigurationsfehler' }
                elseif ($State.IsPaused) { 'Pausiert' }
                else { 'Überwacht: ' + @($State.Channels.Values | Where-Object { $_.Enabled }).Count + ' Kanäle' }
        $c.StatusLabel.Text = "$head`r`nAufnahmen: $rec`r`nDownloads: $dl" + $(if ($polling) { "`r`nAbfrage läuft ..." } else { '' })
        $c.StatusLabel.ForeColor = if ($State.ConfigError) { $t.Danger } else { $t.SidebarMuted }

        if ($State.ConfigError) {
            $c.OverviewSub.Text = [string]$State.ConfigError
            $c.OverviewSub.ForeColor = $t.Danger
        }
        else {
            $c.OverviewSub.Text = 'Live-Status deiner Kanäle und laufende Aufnahmen. Der Schalter aktiviert oder deaktiviert einen Kanal.'
            $c.OverviewSub.ForeColor = $t.Muted
        }

        if ($gui.CurrentPage -eq 'Log') { Update-GuiLog -State $State }
    }
    finally { $gui.Refreshing = $false }
}

# ---------------------------------------------------------------- Einstellungen (config.json)

function Add-GuiSection {
    param([Parameter(Mandatory)]$Parent, [Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][int]$Y)
    $g = $script:Gui
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Font = $g.Fonts.Semi
    $lbl.ForeColor = $g.Theme.Accent
    $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point(20, $Y)
    $Parent.Controls.Add($lbl)
    return ($Y + 32)
}

function Add-GuiField {
    param(
        [Parameter(Mandatory)]$Parent, [Parameter(Mandatory)][hashtable]$Fields,
        [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]$Y, [string]$Kind = 'text'
    )
    $g = $script:Gui
    $t = $g.Theme
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Label
    $lbl.ForeColor = $t.Text
    $lbl.SetBounds(20, $Y + 4, 190, 20)
    $Parent.Controls.Add($lbl)

    $height = 26
    $browse = ($Kind -eq 'folder' -or $Kind -eq 'file')
    $anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'

    if ($Kind -eq 'number') {
        $ctl = New-Object System.Windows.Forms.NumericUpDown
        $ctl.Minimum = 15; $ctl.Maximum = 3600
        $ctl.BorderStyle = 'FixedSingle'
        $ctl.SetBounds(220, $Y, 110, 26)
    }
    elseif ($Kind -eq 'channels') {
        $ctl = New-Object System.Windows.Forms.TextBox
        $ctl.Multiline = $true; $ctl.AcceptsReturn = $true; $ctl.ScrollBars = 'Vertical'
        $ctl.BorderStyle = 'FixedSingle'
        $ctl.SetBounds(220, $Y, 320, 120)
        $height = 120
    }
    else {
        $ctl = New-Object System.Windows.Forms.TextBox
        $ctl.BorderStyle = 'FixedSingle'
        if ($Kind -eq 'password') { $ctl.UseSystemPasswordChar = $true }
        $ctl.SetBounds(220, $Y, $(if ($browse) { 460 } else { 560 }), 26)
        $ctl.Anchor = $anchor
    }
    $ctl.Font = $g.Fonts.Base
    $ctl.BackColor = $t.Bg
    $ctl.ForeColor = $t.Text
    $Parent.Controls.Add($ctl)
    $Fields[$Key] = $ctl

    if ($browse) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Wählen ...'
        $btn.Font = $g.Fonts.Base
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderColor = $t.Border
        $btn.FlatAppearance.MouseOverBackColor = $t.SurfaceAlt
        $btn.BackColor = $t.Surface
        $btn.ForeColor = $t.Text
        $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
        $btn.UseVisualStyleBackColor = $false
        $btn.SetBounds(688, $Y - 1, 90, 28)
        $btn.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
        $btn.add_Click({
            if ($Kind -eq 'folder') {
                $d = New-Object System.Windows.Forms.FolderBrowserDialog
                try {
                    if ($ctl.Text -and [IO.Path]::IsPathRooted($ctl.Text) -and (Test-Path -LiteralPath $ctl.Text)) { $d.SelectedPath = $ctl.Text }
                    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ctl.Text = $d.SelectedPath }
                }
                finally { $d.Dispose() }
            }
            else {
                $d = New-Object System.Windows.Forms.OpenFileDialog
                $d.CheckFileExists = $false
                try { if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ctl.Text = $d.FileName } }
                finally { $d.Dispose() }
            }
        }.GetNewClosure())
        $Parent.Controls.Add($btn)
    }
    return ($Y + $height + 10)
}

function Import-GuiFields {
    # Füllt die Felder mit den ROHEN Werten aus config.json (so wie sie dort stehen, z. B. mit "~").
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $f = $script:Gui.Fields
    if ($f.Count -eq 0) { return }
    $raw = Read-GuiRawConfig -State $State
    $dl = $raw.downloads

    $f.channels.Text = (@($raw.channels) -join [Environment]::NewLine)
    $poll = if ($raw.pollInterval) { [int]$raw.pollInterval } else { 60 }
    $f.pollInterval.Value = [Math]::Min(3600, [Math]::Max(15, $poll))
    $f.outputDirectory.Text = [string]$raw.outputDirectory
    $f.ytDlpPath.Text = [string]$raw.ytDlpPath
    $f.ffmpegPath.Text = if ($raw.ffmpegPath) { [string]$raw.ffmpegPath } else { 'ffmpeg' }
    $f.twitchConfigPath.Text = [string]$raw.twitchConfigPath
    $f.twitchClientId.Text = [string]$raw.twitchClientId
    $f.twitchClientSecret.Text = [string]$raw.twitchClientSecret
    $f.videoDirectory.Text = if ($dl -and $dl.videoDirectory) { [string]$dl.videoDirectory } else { [string]$State.Config.DownloadVideoDirectory }
    $f.musicDirectory.Text = if ($dl -and $dl.musicDirectory) { [string]$dl.musicDirectory } else { [string]$State.Config.DownloadMusicDirectory }
    $f.videoConfigPath.Text = if ($dl -and $dl.videoConfigPath) { [string]$dl.videoConfigPath } else { [string]$State.Config.DownloadVideoConfigPath }
    $f.musicConfigPath.Text = if ($dl -and $dl.musicConfigPath) { [string]$dl.musicConfigPath } else { [string]$State.Config.DownloadMusicConfigPath }
}

function Update-RuntimeConfig {
    # Übernimmt eine neu geladene Konfiguration in die laufende App (ohne Neustart).
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][hashtable]$NewConfig)

    $State.Config = $NewConfig
    Set-LogLevel -Level $NewConfig.LogLevel
    $State.TwitchAccessToken = $null     # neue Zugangsdaten -> Token neu holen
    $State.TokenExpiresAt = $null

    $disabled = @(Get-DisabledChannels -Path $State.StatePath)
    foreach ($name in $NewConfig.Channels) {
        if (-not $State.Channels.ContainsKey($name)) {
            $cs = New-ChannelState -Name $name
            if ($disabled -contains $name) { $cs.Enabled = $false }
            $State.Channels[$name] = $cs
            Write-Log -Channel $name -Level INFO -Message 'Kanal über die Oberfläche hinzugefügt.'
        }
    }
    foreach ($name in @($State.Channels.Keys)) {
        if ($NewConfig.Channels -contains $name) { continue }
        $cs = $State.Channels[$name]
        if ($null -ne $cs.Process) {
            # Aufnahme läuft noch: nicht abwürgen, aber nichts Neues mehr starten. Entfernt wird der Kanal später.
            $cs.Enabled = $false
            Write-Log -Channel $name -Level WARN -Message 'Kanal aus der Konfiguration entfernt; laufende Aufnahme wird noch beendet.'
        }
        else {
            $State.Channels.Remove($name)
            Write-Log -Level INFO -Message "Kanal entfernt: $name"
        }
    }

    if ($State.Timers.Monitor) { $State.Timers.Monitor.Interval = [Math]::Max(15, [int]$NewConfig.PollInterval) * 1000 }

    $problems = @($NewConfig.EnvironmentErrors | Where-Object { $_ })
    if ($problems.Count -eq 0) {
        $State.ConfigError = $null
        # War das Monitoring wegen eines Konfigurationsfehlers nie gestartet, startet es jetzt.
        if (-not $State.Timers.Monitor -and $State.IsRunning) { Start-Monitor -State $State }
    }
    else {
        $State.ConfigError = $problems -join '; '
    }
    Write-Log -Level INFO -Message 'Konfiguration über die Oberfläche geändert und übernommen.'
}

function Save-GuiSettings {
    # Prüft die Felder, schreibt config.json (Sicherung: config.json.bak) und übernimmt die Werte live.
    # Unbekannte Schlüssel in config.json bleiben erhalten. Wirft bei Fehlern (config.json wird dann zurückgesetzt).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $f = $script:Gui.Fields

    $channels = @()
    foreach ($piece in ($f.channels.Text -split '[\s,;]+')) {
        $n = $piece.Trim().ToLowerInvariant()
        if (-not $n) { continue }
        if ($n -notmatch '^[a-z0-9_]{1,25}$') { throw "Ungültiger Kanalname: '$n' (erlaubt: a-z, 0-9, _ ; höchstens 25 Zeichen)." }
        if ($channels -notcontains $n) { $channels += $n }
    }
    if ($channels.Count -lt 1) { throw 'Mindestens ein Kanal ist erforderlich.' }
    if ([string]::IsNullOrWhiteSpace($f.outputDirectory.Text)) { throw 'Der Aufnahme-Ordner darf nicht leer sein.' }
    if ([string]::IsNullOrWhiteSpace($f.ytDlpPath.Text)) { throw 'Der Pfad zu yt-dlp darf nicht leer sein.' }

    $path = Join-Path $State.ProjectRoot 'config.json'
    $raw = Read-GuiRawConfig -State $State

    Set-GuiProp $raw 'channels' @($channels)
    Set-GuiProp $raw 'pollInterval' ([int]$f.pollInterval.Value)
    Set-GuiProp $raw 'twitchConfigPath' $f.twitchConfigPath.Text.Trim()
    Set-GuiProp $raw 'outputDirectory' $f.outputDirectory.Text.Trim()
    Set-GuiProp $raw 'ytDlpPath' $f.ytDlpPath.Text.Trim()
    if (-not [string]::IsNullOrWhiteSpace($f.ffmpegPath.Text)) { Set-GuiProp $raw 'ffmpegPath' $f.ffmpegPath.Text.Trim() }
    Set-GuiProp $raw 'twitchClientId' $f.twitchClientId.Text.Trim()
    Set-GuiProp $raw 'twitchClientSecret' $f.twitchClientSecret.Text.Trim()

    $dl = $raw.downloads
    if (-not $dl) { $dl = [pscustomobject]@{} }
    Set-GuiProp $dl 'videoConfigPath' $f.videoConfigPath.Text.Trim()
    Set-GuiProp $dl 'musicConfigPath' $f.musicConfigPath.Text.Trim()
    Set-GuiProp $dl 'videoDirectory' $f.videoDirectory.Text.Trim()
    Set-GuiProp $dl 'musicDirectory' $f.musicDirectory.Text.Trim()
    Set-GuiProp $raw 'downloads' $dl

    $backup = "$path.bak"
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup -Force }
    $raw | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    try { $new = Initialize-Config -Path $path }
    catch {
        if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $path -Force }
        throw
    }
    $null = Update-RuntimeConfig -State $State -NewConfig $new
    return $new
}

# ---------------------------------------------------------------- yt-dlp-Configs

function Get-GuiConfPath {
    param([Parameter(Mandatory)][hashtable]$State, [int]$Index)
    switch ($Index) {
        0 { return (Resolve-GuiPath $State.Config.TwitchConfigPath) }
        1 { return (Resolve-GuiPath $State.Config.DownloadVideoConfigPath) }
        2 { return (Resolve-GuiPath $State.Config.DownloadMusicConfigPath) }
    }
    return ''
}

function Import-GuiConf {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $c = $script:Gui.Controls
    $path = Get-GuiConfPath -State $State -Index $c.ConfCombo.SelectedIndex
    $c.ConfPath.Text = if ($path) { $path } else { '(kein Pfad in config.json gesetzt)' }
    $c.ConfBox.Text = ''
    if ($path -and (Test-Path -LiteralPath $path)) {
        $c.ConfBox.Text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) -replace "(?<!`r)`n", "`r`n"
        $c.ConfStatus.Text = ''
    }
    else {
        $c.ConfStatus.Text = 'Datei existiert noch nicht - sie wird beim Speichern angelegt.'
    }
}

function Save-GuiConf {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $c = $script:Gui.Controls
    $path = Get-GuiConfPath -State $State -Index $c.ConfCombo.SelectedIndex
    if (-not $path) { throw 'In config.json ist für diese Config kein Pfad gesetzt (Seite Einstellungen).' }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # UTF-8 ohne BOM: yt-dlp-Configs sollen kein BOM am Dateianfang haben.
    [IO.File]::WriteAllText($path, $c.ConfBox.Text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log -Level INFO -Message "yt-dlp-Config gespeichert: $path"
    $c.ConfStatus.Text = 'Gespeichert (' + (Get-Date -Format 'HH:mm:ss') + ') - gilt ab dem nächsten Start eines Downloads/einer Aufnahme.'
}

# ---------------------------------------------------------------- Log

function Update-GuiLogList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $c = $script:Gui.Controls
    $files = @(Get-ChildItem -LiteralPath $State.LogPath -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.Name })
    $current = [string]$c.LogCombo.SelectedItem
    if ((@($c.LogCombo.Items) -join '|') -ne ($files -join '|')) {
        $c.LogCombo.Items.Clear()
        foreach ($n in $files) { [void]$c.LogCombo.Items.Add($n) }
        if ($current -and $files -contains $current) { $c.LogCombo.SelectedItem = $current }
        elseif ($files -contains 'monitor.log') { $c.LogCombo.SelectedItem = 'monitor.log' }
        elseif ($files.Count -gt 0) { $c.LogCombo.SelectedIndex = 0 }
    }
}

function Update-GuiLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $gui = $script:Gui
    $c = $gui.Controls
    $name = [string]$c.LogCombo.SelectedItem
    if (-not $name) { Update-GuiLogList -State $State; return }
    try {
        $file = Get-Item -LiteralPath (Join-Path $State.LogPath $name) -ErrorAction Stop
        # Nur neu lesen, wenn sich die Datei geändert hat.
        $stamp = '{0}|{1}|{2}' -f $name, $file.Length, $file.LastWriteTimeUtc.Ticks
        if ($stamp -eq $gui.LogStamp) { return }
        $lines = Get-Content -LiteralPath $file.FullName -Tail 300 -Encoding UTF8 -ErrorAction Stop
        $c.LogBox.Text = (@($lines) -join [Environment]::NewLine)
        $c.LogBox.SelectionStart = $c.LogBox.TextLength
        $c.LogBox.ScrollToCaret()
        $gui.LogStamp = $stamp
    }
    catch { }   # Datei gerade vom Logger gesperrt: beim nächsten Tick erneut
}

# ---------------------------------------------------------------- Bausteine

function New-GuiButton {
    param([string]$Text, [int]$Width = 120, [ValidateSet('primary', 'secondary', 'danger')][string]$Style = 'secondary')
    $g = $script:Gui
    $t = $g.Theme
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size($Width, 32)
    $b.Font = $g.Fonts.Base
    $b.FlatStyle = 'Flat'
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.UseVisualStyleBackColor = $false
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
    switch ($Style) {
        'primary' {
            $b.BackColor = $t.Accent; $b.ForeColor = $t.AccentText
            $b.FlatAppearance.BorderSize = 0
            $b.FlatAppearance.MouseOverBackColor = $t.AccentHover; $b.FlatAppearance.MouseDownBackColor = $t.AccentHover
        }
        'danger' {
            $b.BackColor = $t.Surface; $b.ForeColor = $t.Danger
            $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $t.Danger
            $b.FlatAppearance.MouseOverBackColor = $t.SurfaceAlt; $b.FlatAppearance.MouseDownBackColor = $t.SurfaceAlt
        }
        default {
            $b.BackColor = $t.Surface; $b.ForeColor = $t.Text
            $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $t.Border
            $b.FlatAppearance.MouseOverBackColor = $t.SurfaceAlt; $b.FlatAppearance.MouseDownBackColor = $t.SurfaceAlt
        }
    }
    return $b
}

function New-GuiBar {
    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Top'
    $bar.AutoSize = $true
    $bar.AutoSizeMode = 'GrowAndShrink'
    $bar.BackColor = $script:Gui.Theme.Bg
    $bar.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    return $bar
}

function New-GuiCard {
    # Rahmen mit 1 px Linie um ein Steuerelement (wirkt wie eine Karte).
    param([Parameter(Mandatory)]$Child)
    $card = New-Object System.Windows.Forms.Panel
    $card.Dock = 'Fill'
    $card.BackColor = $script:Gui.Theme.Border
    $card.Padding = New-Object System.Windows.Forms.Padding(1)
    $Child.Dock = 'Fill'
    $card.Controls.Add($Child)
    return $card
}

function New-GuiPage {
    param([Parameter(Mandatory)][string]$Title, [string]$Subtitle = '')
    $g = $script:Gui
    $t = $g.Theme
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = 'Fill'
    $page.BackColor = $t.Bg
    $page.Padding = New-Object System.Windows.Forms.Padding(28, 22, 28, 18)
    $page.Visible = $false

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 66
    $header.BackColor = $t.Bg
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.Font = $g.Fonts.Title
    $titleLabel.ForeColor = $t.Text
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(0, 0)
    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = $Subtitle
    $sub.Font = $g.Fonts.Base
    $sub.ForeColor = $t.Muted
    $sub.AutoSize = $false
    $sub.Size = New-Object System.Drawing.Size(900, 20)
    $sub.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
    $sub.AutoEllipsis = $true
    $sub.Location = New-Object System.Drawing.Point(2, 38)
    $header.Controls.AddRange(@($titleLabel, $sub))
    return @{ Page = $page; Header = $header; Sub = $sub }
}

function New-GuiListView {
    # Owner-drawn ListView: eigene Kopfzeile, Zebra-Streifen, Statuspunkt, Schalter (Aktiv-Spalte).
    param(
        [Parameter(Mandatory)][object[]]$Columns,
        [int]$SwitchColumn = -1, [int]$StatusColumn = -1, [int[]]$MutedColumns = @()
    )
    $g = $script:Gui
    $t = $g.Theme
    $fonts = $g.Fonts

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Dock = 'Fill'
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.HideSelection = $false
    $lv.MultiSelect = $true
    $lv.BorderStyle = 'None'
    $lv.OwnerDraw = $true
    $lv.BackColor = $t.Surface
    $lv.ForeColor = $t.Text
    $lv.Font = $fonts.Base
    foreach ($col in $Columns) { [void]$lv.Columns.Add([string]$col[0], [int]$col[1]) }

    # Zeilenhöhe über eine 1x32-ImageList; DoubleBuffered gegen Flackern.
    $il = New-Object System.Windows.Forms.ImageList
    $il.ImageSize = New-Object System.Drawing.Size(1, 34)
    $lv.SmallImageList = $il
    try {
        $prop = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
        $prop.SetValue($lv, $true, $null)
    }
    catch { }

    $headBrush = New-Object System.Drawing.SolidBrush $t.SurfaceAlt
    $rowBrush = New-Object System.Drawing.SolidBrush $t.Surface
    $altBrush = New-Object System.Drawing.SolidBrush $t.RowAlt
    $selBrush = New-Object System.Drawing.SolidBrush $t.AccentSoft
    $accentBrush = New-Object System.Drawing.SolidBrush $t.Accent
    $offBrush = New-Object System.Drawing.SolidBrush $t.Border
    $knobBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $borderPen = New-Object System.Drawing.Pen $t.Border
    $textColor = $t.Text
    $mutedColor = $t.Muted
    $cDanger = $t.Danger; $cWarn = $t.Warn; $cSuccess = $t.Success; $cAccent = $t.Accent
    $baseFont = $fonts.Base
    $headFont = $fonts.Semi
    $flags = [System.Windows.Forms.TextFormatFlags]'VerticalCenter, EndEllipsis, NoPrefix, Left, SingleLine'

    $lv.add_DrawColumnHeader({
        param($s, $e)
        $e.Graphics.FillRectangle($headBrush, $e.Bounds)
        $rect = New-Object System.Drawing.Rectangle(($e.Bounds.X + 8), $e.Bounds.Y, [Math]::Max(1, $e.Bounds.Width - 12), $e.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $headFont, $rect, $mutedColor, $flags)
        $e.Graphics.DrawLine($borderPen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1)
    }.GetNewClosure())

    $lv.add_DrawItem({ param($s, $e) }.GetNewClosure())   # gezeichnet wird pro Zelle (DrawSubItem)

    $lv.add_DrawSubItem({
        param($s, $e)
        $g2 = $e.Graphics
        $r = $e.Bounds
        if ($e.ColumnIndex -eq 0) { $r = New-Object System.Drawing.Rectangle($r.X, $r.Y, $s.Columns[0].Width, $r.Height) }
        $bg = $rowBrush
        if ($e.Item.Selected) { $bg = $selBrush } elseif (($e.ItemIndex % 2) -eq 1) { $bg = $altBrush }
        $g2.FillRectangle($bg, $r)
        $g2.DrawLine($borderPen, $r.Left, $r.Bottom - 1, $r.Right, $r.Bottom - 1)

        if ($e.ColumnIndex -eq $SwitchColumn) {
            $on = [bool]$e.Item.Tag
            $g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $w = 34; $h = 18
            $x = [int]($r.X + 14); $y = [int]($r.Y + (($r.Height - $h) / 2))
            $track = if ($on) { $accentBrush } else { $offBrush }
            $g2.FillEllipse($track, $x, $y, $h, $h)
            $g2.FillEllipse($track, [int]($x + $w - $h), $y, $h, $h)
            $g2.FillRectangle($track, [int]($x + ($h / 2)), $y, [int]($w - $h), $h)
            $knobX = if ($on) { [int]($x + $w - $h + 2) } else { [int]($x + 2) }
            $g2.FillEllipse($knobBrush, $knobX, [int]($y + 2), [int]($h - 4), [int]($h - 4))
            return
        }

        $text = [string]$e.SubItem.Text
        $x0 = [int]($r.X + 8)
        if ($e.ColumnIndex -eq $StatusColumn) {
            $dot = switch -Wildcard ($text) {
                'Aufnahme*' { $cDanger }
                'live*' { $cWarn }
                'Status unbekannt' { $cWarn }
                'läuft' { $cAccent }
                'fertig' { $cSuccess }
                'fehlgeschlagen' { $cDanger }
                'abgebrochen' { $cWarn }
                default { $mutedColor }
            }
            $br = New-Object System.Drawing.SolidBrush $dot
            $g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g2.FillEllipse($br, [int]($r.X + 10), [int]($r.Y + (($r.Height - 8) / 2)), 8, 8)
            $br.Dispose()
            $x0 = [int]($r.X + 26)
        }
        $color = $textColor
        if ($MutedColumns -contains $e.ColumnIndex) { $color = $mutedColor }
        if ($SwitchColumn -ge 0 -and -not [bool]$e.Item.Tag) { $color = $mutedColor }   # inaktive Kanäle gedimmt
        $rect = New-Object System.Drawing.Rectangle($x0, $r.Y, [Math]::Max(1, $r.Right - $x0 - 4), $r.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($g2, $text, $baseFont, $rect, $color, $flags)
    }.GetNewClosure())

    # Letzte Spalte füllt den Rest der Breite.
    $lv.add_Resize({
        param($s, $e)
        if ($s.Columns.Count -lt 2) { return }
        $sum = 0
        for ($i = 0; $i -lt $s.Columns.Count - 1; $i++) { $sum += $s.Columns[$i].Width }
        $w = $s.ClientSize.Width - $sum
        if ($w -gt 140) { $s.Columns[$s.Columns.Count - 1].Width = $w }
    }.GetNewClosure())

    return $lv
}

# ---------------------------------------------------------------- Seiten

function New-GuiOverviewPage {
    param([hashtable]$State, [hashtable]$gui)
    $p = New-GuiPage -Title 'Übersicht' -Subtitle 'Live-Status deiner Kanäle und laufende Aufnahmen.'
    $gui.Controls.OverviewSub = $p.Sub

    $lv = New-GuiListView -SwitchColumn 0 -StatusColumn 2 -MutedColumns @(6, 7) -Columns @(
        @('Aktiv', 70), @('Kanal', 150), @('Status', 170), @('Titel', 250), @('Dauer', 80), @('Größe', 90), @('Letzte Prüfung', 110), @('Hinweis', 240))
    $gui.Controls.ChannelList = $lv

    # Klick auf den Schalter (erste Spalte) aktiviert/deaktiviert den Kanal.
    $lv.add_MouseDown({
        param($s, $e)
        if ($gui.Refreshing) { return }
        $hit = $s.HitTest($e.Location)
        if ($hit.Item -and $e.X -lt $s.Columns[0].Width) {
            try {
                Set-ChannelEnabled -State $State -Channel $hit.Item.Name -Enabled (-not [bool]$hit.Item.Tag)
                Update-MainWindow -State $State
            }
            catch { Write-Log -Level ERROR -Message "GUI (Kanal umschalten): $($_.Exception.Message)" }
        }
    }.GetNewClosure())

    $bar = New-GuiBar
    $pause = New-GuiButton -Text 'Pausieren' -Width 110
    $check = New-GuiButton -Text 'Jetzt prüfen' -Width 110
    $folder = New-GuiButton -Text 'Aufnahme-Ordner' -Width 140
    $newDl = New-GuiButton -Text 'Neuer Download ...' -Width 150 -Style primary
    $stopMon = New-GuiButton -Text 'Monitoring beenden' -Width 160 -Style danger
    $exitApp = New-GuiButton -Text 'App beenden' -Width 110 -Style danger
    $gui.Controls.PauseButton = $pause
    $gui.Controls.CheckButton = $check

    $pause.add_Click({
        try {
            if ($State.IsPaused) { Resume-Monitor -State $State } else { Pause-Monitor -State $State }
            Update-MainWindow -State $State
        }
        catch { Write-Log -Level ERROR -Message "GUI (Pause/Fortsetzen): $($_.Exception.Message)" }
    }.GetNewClosure())
    $check.add_Click({
        try { Invoke-MonitorCycle -State $State; Update-MainWindow -State $State }   # startet nur die Hintergrundabfrage
        catch { Write-Log -Level ERROR -Message "GUI (Jetzt prüfen): $($_.Exception.Message)" }
    }.GetNewClosure())
    $folder.add_Click({
        try {
            $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$State.Config.OutputDirectory)
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            Invoke-Item -LiteralPath $dir
        }
        catch { Write-Log -Level ERROR -Message "GUI (Ordner öffnen): $($_.Exception.Message)" }
    }.GetNewClosure())
    $newDl.add_Click({
        try { Request-SingleDownload -State $State }
        catch { Write-Log -Level ERROR -Message "GUI (Download): $($_.Exception.Message)" }
    }.GetNewClosure())
    $stopMon.add_Click({
        $q = 'Monitoring beenden? Laufende Aufnahmen werden sauber beendet und die App schließt sich.'
        if ([System.Windows.Forms.MessageBox]::Show($q, 'Twitch Monitor', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try { Stop-Monitor -State $State -StopRecordings $true }
        catch { Write-Log -Level ERROR -Message "GUI (Monitoring beenden): $($_.Exception.Message)" }
    }.GetNewClosure())
    $exitApp.add_Click({
        $q = 'App beenden? Laufende Aufnahmen laufen im Hintergrund weiter (ohne Nachbearbeitung durch die App).'
        if ([System.Windows.Forms.MessageBox]::Show($q, 'Twitch Monitor', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question) -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try { Stop-Monitor -State $State -StopRecordings $false }
        catch { Write-Log -Level ERROR -Message "GUI (Beenden): $($_.Exception.Message)" }
    }.GetNewClosure())

    $bar.Controls.AddRange(@($pause, $check, $folder, $newDl, $stopMon, $exitApp))
    $p.Page.Controls.Add((New-GuiCard -Child $lv))   # Fill zuerst, dann Leiste, dann Kopf (Dock-Reihenfolge)
    $p.Page.Controls.Add($bar)
    $p.Page.Controls.Add($p.Header)
    $gui.Pages.Overview = $p.Page
    return $p.Page
}

function New-GuiDownloadsPage {
    param([hashtable]$State, [hashtable]$gui)
    $p = New-GuiPage -Title 'Downloads' -Subtitle 'Einzeldownloads (Video/Musik) per Link - laufende und abgeschlossene.'

    $lv = New-GuiListView -StatusColumn 2 -MutedColumns @(5) -Columns @(
        @('Start', 120), @('Typ', 80), @('Status', 140), @('Dauer', 80), @('Link', 380), @('Hinweis', 260))
    $gui.Controls.DownloadList = $lv

    $bar = New-GuiBar
    $new = New-GuiButton -Text 'Neuer Download ...' -Width 150 -Style primary
    $cancel = New-GuiButton -Text 'Abbrechen' -Width 100
    $vid = New-GuiButton -Text 'Video-Ordner' -Width 120
    $mus = New-GuiButton -Text 'Musik-Ordner' -Width 120
    $clear = New-GuiButton -Text 'Verlauf leeren' -Width 120

    $new.add_Click({
        try { Request-SingleDownload -State $State }
        catch { Write-Log -Channel 'download' -Level ERROR -Message "GUI (Download): $($_.Exception.Message)" }
    }.GetNewClosure())
    $cancel.add_Click({
        try {
            foreach ($sel in @($lv.SelectedItems)) {
                $job = @($State.DownloadJobs | Where-Object { $_.Id -eq $sel.Name }) | Select-Object -First 1
                if ($job) {
                    $job.Cancelled = $true
                    & taskkill.exe /PID $job.Process.Id /T /F *> $null   # inkl. ffmpeg-Kindprozesse
                    Write-Log -Channel 'download' -Level INFO -Message "Download abgebrochen: $($job.Url)"
                }
            }
        }
        catch { Write-Log -Channel 'download' -Level ERROR -Message "GUI (Abbrechen): $($_.Exception.Message)" }
    }.GetNewClosure())
    $vid.add_Click({
        try {
            $dir = [string]$State.Config.DownloadVideoDirectory
            if (Test-Path -LiteralPath $dir) { Invoke-Item -LiteralPath $dir }
            else { [void][System.Windows.Forms.MessageBox]::Show("Der Ordner existiert noch nicht:`r`n$dir", 'Downloads') }
        }
        catch { Write-Log -Channel 'download' -Level ERROR -Message "GUI (Video-Ordner): $($_.Exception.Message)" }
    }.GetNewClosure())
    $mus.add_Click({
        try {
            $dir = [string]$State.Config.DownloadMusicDirectory
            if (Test-Path -LiteralPath $dir) { Invoke-Item -LiteralPath $dir }
            else { [void][System.Windows.Forms.MessageBox]::Show("Der Ordner existiert noch nicht:`r`n$dir", 'Downloads') }
        }
        catch { Write-Log -Channel 'download' -Level ERROR -Message "GUI (Musik-Ordner): $($_.Exception.Message)" }
    }.GetNewClosure())
    $clear.add_Click({
        if ($State.DownloadHistory) { $State.DownloadHistory.Clear() }
        Update-MainWindow -State $State
    }.GetNewClosure())

    $bar.Controls.AddRange(@($new, $cancel, $vid, $mus, $clear))
    $p.Page.Controls.Add((New-GuiCard -Child $lv))
    $p.Page.Controls.Add($bar)
    $p.Page.Controls.Add($p.Header)
    $gui.Pages.Downloads = $p.Page
    return $p.Page
}

function New-GuiSettingsPage {
    param([hashtable]$State, [hashtable]$gui)
    $t = $gui.Theme
    $p = New-GuiPage -Title 'Einstellungen' -Subtitle 'Änderungen werden in config.json gespeichert und sofort übernommen (Sicherung: config.json.bak).'

    $panel = New-Object System.Windows.Forms.Panel
    $panel.AutoScroll = $true
    $panel.BackColor = $t.Surface
    $f = $gui.Fields

    $y = 16
    $y = Add-GuiSection -Parent $panel -Text 'ÜBERWACHUNG' -Y $y
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'channels' -Label 'Kanäle (einer pro Zeile)' -Y $y -Kind 'channels'
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'pollInterval' -Label 'Abfrageintervall (s)' -Y $y -Kind 'number'
    $y += 10
    $y = Add-GuiSection -Parent $panel -Text 'ORDNER && PROGRAMME' -Y $y
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'outputDirectory' -Label 'Aufnahme-Ordner' -Y $y -Kind 'folder'
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'ytDlpPath' -Label 'yt-dlp' -Y $y -Kind 'file'
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'ffmpegPath' -Label 'ffmpeg' -Y $y -Kind 'file'
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'twitchConfigPath' -Label 'Config für Aufnahmen' -Y $y -Kind 'file'
    $y += 10
    $y = Add-GuiSection -Parent $panel -Text 'TWITCH-API' -Y $y
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'twitchClientId' -Label 'Client-ID' -Y $y -Kind 'text'
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'twitchClientSecret' -Label 'Client-Secret' -Y $y -Kind 'password'
    $y += 10
    $y = Add-GuiSection -Parent $panel -Text 'EINZELDOWNLOADS' -Y $y
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'videoDirectory' -Label 'Video-Ordner' -Y $y -Kind 'folder'
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'musicDirectory' -Label 'Musik-Ordner' -Y $y -Kind 'folder'
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'videoConfigPath' -Label 'Video-Config' -Y $y -Kind 'file'
    $y = Add-GuiField -Parent $panel -Fields $f -Key 'musicConfigPath' -Label 'Musik-Config' -Y $y -Kind 'file'

    $bar = New-GuiBar
    $save = New-GuiButton -Text 'Speichern && übernehmen' -Width 190 -Style primary
    $reset = New-GuiButton -Text 'Zurücksetzen' -Width 120
    $status = New-Object System.Windows.Forms.Label
    $status.AutoSize = $true
    $status.Font = $gui.Fonts.Base
    $status.ForeColor = $t.Muted
    $status.Margin = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
    $bar.Controls.AddRange(@($save, $reset, $status))

    $save.add_Click({
        try {
            $new = Save-GuiSettings -State $State
            Import-GuiFields -State $State
            $msg = 'Gespeichert und übernommen (' + (Get-Date -Format 'HH:mm:ss') + ').'
            $problems = @($new.EnvironmentErrors | Where-Object { $_ })
            if ($problems.Count -gt 0) {
                $status.ForeColor = $gui.Theme.Danger
                $msg += ' Achtung: ' + ($problems -join '; ')
            }
            else { $status.ForeColor = $gui.Theme.Success }
            $status.Text = $msg
            Update-MainWindow -State $State
        }
        catch {
            Write-Log -Level ERROR -Message "GUI (Einstellungen): $($_.Exception.Message)"
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Einstellungen', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }.GetNewClosure())
    $reset.add_Click({
        try { Import-GuiFields -State $State; $status.Text = '' }
        catch { Write-Log -Level ERROR -Message "GUI (Zurücksetzen): $($_.Exception.Message)" }
    }.GetNewClosure())

    $p.Page.Controls.Add((New-GuiCard -Child $panel))
    $p.Page.Controls.Add($bar)
    $p.Page.Controls.Add($p.Header)
    $gui.Pages.Settings = $p.Page
    return $p.Page
}

function New-GuiConfPage {
    param([hashtable]$State, [hashtable]$gui)
    $t = $gui.Theme
    $p = New-GuiPage -Title 'yt-dlp-Configs' -Subtitle 'Die Konfigurationsdateien für Aufnahmen und Einzeldownloads direkt bearbeiten.'

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.AcceptsReturn = $true
    $box.WordWrap = $false
    $box.ScrollBars = 'Both'
    $box.BorderStyle = 'None'
    $box.BackColor = $t.Surface
    $box.ForeColor = $t.Text
    $box.Font = $gui.Fonts.Mono

    $bar = New-GuiBar
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.FlatStyle = 'Flat'
    $combo.Font = $gui.Fonts.Base
    $combo.BackColor = $t.Surface
    $combo.ForeColor = $t.Text
    $combo.Width = 230
    $combo.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 8)
    [void]$combo.Items.AddRange(@('Aufnahmen (twitch.conf)', 'Video-Download', 'Musik-Download'))
    $combo.SelectedIndex = 0
    $save = New-GuiButton -Text 'Speichern' -Width 100 -Style primary
    $reload = New-GuiButton -Text 'Neu laden' -Width 100
    $path = New-Object System.Windows.Forms.Label
    $path.AutoSize = $true
    $path.Font = $gui.Fonts.Small
    $path.ForeColor = $t.Muted
    $path.Margin = New-Object System.Windows.Forms.Padding(8, 9, 0, 0)
    $status = New-Object System.Windows.Forms.Label
    $status.AutoSize = $true
    $status.Font = $gui.Fonts.Small
    $status.ForeColor = $t.Success
    $status.Margin = New-Object System.Windows.Forms.Padding(8, 9, 0, 0)
    $bar.Controls.AddRange(@($combo, $save, $reload, $path, $status))

    $gui.Controls.ConfCombo = $combo
    $gui.Controls.ConfBox = $box
    $gui.Controls.ConfPath = $path
    $gui.Controls.ConfStatus = $status

    $combo.add_SelectedIndexChanged({
        try { Import-GuiConf -State $State }
        catch { Write-Log -Level ERROR -Message "GUI (Config laden): $($_.Exception.Message)" }
    }.GetNewClosure())
    $reload.add_Click({
        try { Import-GuiConf -State $State }
        catch { Write-Log -Level ERROR -Message "GUI (Config laden): $($_.Exception.Message)" }
    }.GetNewClosure())
    $save.add_Click({
        try { Save-GuiConf -State $State }
        catch {
            Write-Log -Level ERROR -Message "GUI (Config speichern): $($_.Exception.Message)"
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'yt-dlp-Configs', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }.GetNewClosure())

    $p.Page.Controls.Add((New-GuiCard -Child $box))
    $p.Page.Controls.Add($bar)
    $p.Page.Controls.Add($p.Header)
    $gui.Pages.Configs = $p.Page
    return $p.Page
}

function New-GuiLogPage {
    param([hashtable]$State, [hashtable]$gui)
    $t = $gui.Theme
    $p = New-GuiPage -Title 'Log' -Subtitle 'Die letzten 300 Zeilen der gewählten Logdatei (aktualisiert sich automatisch).'

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.WordWrap = $false
    $box.ScrollBars = 'Both'
    $box.BorderStyle = 'None'
    $box.BackColor = $t.Surface
    $box.ForeColor = $t.Text
    $box.Font = $gui.Fonts.Mono

    $bar = New-GuiBar
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.FlatStyle = 'Flat'
    $combo.Font = $gui.Fonts.Base
    $combo.BackColor = $t.Surface
    $combo.ForeColor = $t.Text
    $combo.Width = 270
    $combo.Margin = New-Object System.Windows.Forms.Padding(0, 3, 8, 8)
    $logs = New-GuiButton -Text 'Log-Ordner' -Width 110
    $bar.Controls.AddRange(@($combo, $logs))

    $gui.Controls.LogCombo = $combo
    $gui.Controls.LogBox = $box

    $combo.add_SelectedIndexChanged({
        try { $gui.LogStamp = ''; Update-GuiLog -State $State }
        catch { }
    }.GetNewClosure())
    $logs.add_Click({
        try { if (Test-Path -LiteralPath $State.LogPath) { Invoke-Item -LiteralPath $State.LogPath } }
        catch { Write-Log -Level ERROR -Message "GUI (Log-Ordner): $($_.Exception.Message)" }
    }.GetNewClosure())

    $p.Page.Controls.Add((New-GuiCard -Child $box))
    $p.Page.Controls.Add($bar)
    $p.Page.Controls.Add($p.Header)
    $gui.Pages.Log = $p.Page
    return $p.Page
}

# ---------------------------------------------------------------- Fenster

function Set-GuiPage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Name)
    $gui = $script:Gui
    $t = $gui.Theme
    if (-not $gui.Pages.ContainsKey($Name)) { return }
    $gui.Pages[$Name].Visible = $true
    foreach ($k in @($gui.Pages.Keys)) {
        if ($k -ne $Name) { $gui.Pages[$k].Visible = $false }
        $btn = $gui.Nav[$k]
        if ($k -eq $Name) { $btn.BackColor = $t.Accent; $btn.ForeColor = $t.AccentText }
        else { $btn.BackColor = $t.Sidebar; $btn.ForeColor = $t.SidebarText }
    }
    $gui.CurrentPage = $Name
    if ($Name -eq 'Log') { Update-GuiLogList -State $State; Update-GuiLog -State $State }
    Update-MainWindow -State $State
}

function New-MainWindow {
    param([Parameter(Mandatory)][hashtable]$State)

    $gui = $script:Gui
    if ($gui.Timer) { try { $gui.Timer.Stop(); $gui.Timer.Dispose() } catch { } ; $gui.Timer = $null }
    $gui.Controls = @{}; $gui.Fields = @{}; $gui.Pages = @{}; $gui.Nav = @{}
    $gui.LogStamp = ''; $gui.CurrentPage = 'Overview'
    $gui.Theme = Get-GuiTheme
    $gui.Fonts = New-GuiFonts
    $t = $gui.Theme

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Twitch Monitor'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(1080, 680)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 560)
    $form.Font = $gui.Fonts.Base
    $form.BackColor = $t.Bg
    try { if ($State.Tray.Icons) { $form.Icon = $State.Tray.Icons.Idle } } catch { }

    # Inhaltsbereich: alle Seiten übereinander, immer nur eine sichtbar.
    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = 'Fill'
    $content.BackColor = $t.Bg
    foreach ($page in @(
            (New-GuiOverviewPage -State $State -gui $gui),
            (New-GuiDownloadsPage -State $State -gui $gui),
            (New-GuiSettingsPage -State $State -gui $gui),
            (New-GuiConfPage -State $State -gui $gui),
            (New-GuiLogPage -State $State -gui $gui))) {
        $content.Controls.Add($page)
    }

    # Seitenleiste (Controls in umgekehrter Reihenfolge hinzufügen: das zuletzt hinzugefügte Dock=Top-Element steht oben).
    $sidebar = New-Object System.Windows.Forms.Panel
    $sidebar.Dock = 'Left'
    $sidebar.Width = 210
    $sidebar.BackColor = $t.Sidebar

    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Bottom'
    $status.Height = 92
    $status.Font = $gui.Fonts.Small
    $status.ForeColor = $t.SidebarMuted
    $status.Padding = New-Object System.Windows.Forms.Padding(20, 8, 8, 8)
    $gui.Controls.StatusLabel = $status
    $sidebar.Controls.Add($status)

    $navItems = @(
        @('Overview', 'Übersicht'), @('Downloads', 'Downloads'), @('Settings', 'Einstellungen'),
        @('Configs', 'yt-dlp-Configs'), @('Log', 'Log'))
    for ($i = $navItems.Count - 1; $i -ge 0; $i--) {
        $pageName = [string]$navItems[$i][0]
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = [string]$navItems[$i][1]
        $btn.Dock = 'Top'
        $btn.Height = 44
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderSize = 0
        $btn.FlatAppearance.MouseOverBackColor = $t.SidebarHover
        $btn.FlatAppearance.MouseDownBackColor = $t.SidebarHover
        $btn.TextAlign = 'MiddleLeft'
        $btn.Padding = New-Object System.Windows.Forms.Padding(22, 0, 0, 0)
        $btn.Font = $gui.Fonts.Semi
        $btn.BackColor = $t.Sidebar
        $btn.ForeColor = $t.SidebarText
        $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
        $btn.UseVisualStyleBackColor = $false
        $btn.add_Click({ Set-GuiPage -State $State -Name $pageName }.GetNewClosure())
        $gui.Nav[$pageName] = $btn
        $sidebar.Controls.Add($btn)
    }

    $brand = New-Object System.Windows.Forms.Label
    $brand.Dock = 'Top'
    $brand.Height = 76
    $brand.Text = 'Twitch Monitor'
    $brand.Font = $gui.Fonts.Brand
    $brand.ForeColor = $t.AccentText
    $brand.TextAlign = 'MiddleLeft'
    $brand.Padding = New-Object System.Windows.Forms.Padding(20, 0, 0, 0)
    $sidebar.Controls.Add($brand)

    $form.Controls.Add($content)   # Fill zuerst, dann die Seitenleiste
    $form.Controls.Add($sidebar)

    $form.add_Shown({ Set-GuiTitleBarTheme -Form $form -Dark $gui.Theme.Dark }.GetNewClosure())

    # Schließen versteckt nur das Fenster, solange die App läuft.
    $form.add_FormClosing({
        param($sender, $e)
        if ($State.IsRunning -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $sender.Hide()
        }
    }.GetNewClosure())

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.add_Tick({
        try { if ($gui.Form -and $gui.Form.Visible) { Update-MainWindow -State $State } }
        catch { Write-Log -Level ERROR -Message "GUI-Timer: $($_.Exception.Message)" }
    }.GetNewClosure())

    $gui.Form = $form
    $gui.Timer = $timer

    Import-GuiFields -State $State
    Import-GuiConf -State $State
    Update-GuiLogList -State $State
    Set-GuiPage -State $State -Name 'Overview'
    $timer.Start()
}

function Show-MainWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    $gui = $script:Gui
    if ($null -eq $gui.Form -or $gui.Form.IsDisposed) { New-MainWindow -State $State }
    $form = $gui.Form
    if (-not $form.Visible) { $form.Show() }
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal }
    [void]$form.Activate()
    Update-MainWindow -State $State
}

function Dispose-Gui {
    [CmdletBinding()]
    param()
    $gui = $script:Gui
    try { if ($gui.Timer) { $gui.Timer.Stop(); $gui.Timer.Dispose(); $gui.Timer = $null } } catch { }
    try { if ($gui.Form -and -not $gui.Form.IsDisposed) { $gui.Form.Dispose() }; $gui.Form = $null } catch { }
}

Export-ModuleMember -Function Show-MainWindow, Update-MainWindow, Dispose-Gui, Set-GuiPage, Save-GuiSettings, Import-GuiFields, Import-GuiConf, Save-GuiConf, Update-GuiLogList, Update-GuiLog, Set-GuiTitleBarTheme
