[CmdletBinding()]
param(
    [switch]$NoTray,
    [switch]$InstallAutoStart,
    [switch]$RemoveAutoStart,
    [switch]$ShowWindow
)

$ErrorActionPreference = 'Stop'
$script:ProjectRoot = $PSScriptRoot

# Windows PowerShell 5.1 nutzt je nach System noch kein TLS 1.2 als Standard (Twitch verlangt es).
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# Windows Forms / Drawing sind in Windows PowerShell enthalten.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }

# -Global: Module rufen sich gegenseitig auf (z. B. Monitor -> Recorder), das braucht globale Sichtbarkeit.
# Module sind optional: fehlt die Datei unter modules\, fällt das zugehörige Feature einfach weg
# (z. B. Recorder -> keine Aufnahmen, Downloader -> keine Einzeldownloads, Tray -> kein Icon, Gui -> kein Fenster).
# Nur Logging und Config sind Pflicht: ohne Logging kein Protokoll, ohne Config keine Einstellungen/Kanäle.
$moduleDir = Join-Path $script:ProjectRoot 'modules'
foreach ($name in @('Logging', 'Config')) {
    $path = Join-Path $moduleDir "$name.psm1"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Pflichtmodul fehlt: $path - ohne Logging/Config kann die App nicht starten."
        exit 1
    }
    Import-Module $path -Force -Global -DisableNameChecking -ErrorAction Stop
}
foreach ($name in @('Recorder', 'Downloader', 'Monitor', 'Tray', 'Startup', 'Gui')) {
    $path = Join-Path $moduleDir "$name.psm1"
    if (Test-Path -LiteralPath $path) {
        Import-Module $path -Force -Global -DisableNameChecking -ErrorAction Stop
    }
}

if ($InstallAutoStart) {
    if (-not (Get-Command Register-AutoStart -ErrorAction SilentlyContinue)) {
        Write-Host "Autostart nicht möglich: modules\Startup.psm1 fehlt."
        exit 1
    }
    Register-AutoStart -ScriptPath $PSCommandPath
    Write-Host "Autostart-Task 'TwitchMonitor' wurde für die Anmeldung registriert."
    return
}
if ($RemoveAutoStart) {
    if (-not (Get-Command Unregister-AutoStart -ErrorAction SilentlyContinue)) {
        Write-Host "Autostart kann nicht entfernt werden: modules\Startup.psm1 fehlt."
        exit 1
    }
    Unregister-AutoStart
    Write-Host "Autostart-Task 'TwitchMonitor' wurde entfernt."
    return
}

# Nur eine Instanz pro Benutzer-Sitzung.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\TwitchMonitor_Singleton')
$script:OwnsMutex = $false
try { $script:OwnsMutex = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $script:OwnsMutex = $true }
if (-not $script:OwnsMutex) { return }

# Eigenes Konsolenfenster ausblenden - aber nur, wenn die Konsole uns allein gehört
# (nicht, wenn das Skript aus einem Terminal des Benutzers gestartet wurde).
if (-not $NoTray -and $Host.Name -eq 'ConsoleHost') {
    try {
        Add-Type -Namespace TmNative -Name Win -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
        $hwnd = [TmNative.Win]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            $ids = New-Object 'uint32[]' 4
            if ([TmNative.Win]::GetConsoleProcessList($ids, 4) -le 1) { [void][TmNative.Win]::ShowWindow($hwnd, 0) }
        }
    }
    catch { }
}

$script:AppState = @{
    ProjectRoot     = $script:ProjectRoot
    IsRunning       = $true
    IsPaused        = $false
    IsStopping      = $false
    Config          = $null
    Channels        = @{}
    Timers          = @{ Monitor = $null; Tray = $null; Remux = $null; Download = $null }
    RemuxJobs       = New-Object System.Collections.ArrayList
    DownloadJobs    = New-Object System.Collections.ArrayList
    DownloadHistory = New-Object System.Collections.ArrayList
    StoppingPollJobs = New-Object System.Collections.ArrayList
    Features        = @{}   # wird nach dem Start gefüllt: welches optionale Modul ist vorhanden
    ApiBackoffUntil = $null
    ApiBackoffFails = 0
    YtDlpVersionChecked = $false
    Tray            = @{ NotifyIcon = $null; ContextMenu = $null }
    LogPath         = Join-Path $script:ProjectRoot 'logs'
    StatePath       = Join-Path $script:ProjectRoot 'configs/state.json'
}

try {
    Initialize-Logging -LogDirectory $script:AppState.LogPath
    Write-Log -Level INFO -Message 'Twitch Monitor wird gestartet.'
    $script:AppState.Config = Initialize-Config -Path (Join-Path $script:ProjectRoot 'configs/config.json')
    Set-LogLevel -Level $script:AppState.Config.LogLevel

    # Verfügbare Features hängen daran, welche optionalen Moduldateien existieren.
    # Fehlt eine Datei, fällt das Feature still weg (kein Fehler, es wird nur protokolliert).
    $script:AppState.Features = @{
        Recorder   = [bool](Get-Command Start-ChannelRecording -ErrorAction SilentlyContinue)
        Downloader = [bool](Get-Command Initialize-Downloader -ErrorAction SilentlyContinue)
        Monitor    = [bool](Get-Command Start-Monitor -ErrorAction SilentlyContinue)
        Tray       = [bool](Get-Command Initialize-Tray -ErrorAction SilentlyContinue)
        Startup    = [bool](Get-Command Register-AutoStart -ErrorAction SilentlyContinue)
        Gui        = [bool](Get-Command Show-MainWindow -ErrorAction SilentlyContinue)
    }
    $missingFeatures = @($script:AppState.Features.Keys | Where-Object { -not $script:AppState.Features[$_] } | Sort-Object)
    if ($missingFeatures.Count -gt 0) {
        Write-Log -Level INFO -Message ("Optionale Module nicht gefunden - Features deaktiviert: " + ($missingFeatures -join ', '))
    }
    Write-Log -Level DEBUG -Message ("Aktive Features: " + (@($script:AppState.Features.Keys | Where-Object { $script:AppState.Features[$_] } | Sort-Object) -join ', '))

    if ($script:AppState.Features.Monitor) {
        foreach ($channel in $script:AppState.Config.Channels) {
            $script:AppState.Channels[$channel] = New-ChannelState -Name $channel
        }
        Write-Log -Level DEBUG -Message ("Überwachte Kanäle: " + ($script:AppState.Config.Channels -join ', '))

        # Per Tray-Menü deaktivierte Kanäle (state.json) wiederherstellen.
        $disabledChannels = @(Get-DisabledChannels -Path $script:AppState.StatePath)
        foreach ($disabledName in $disabledChannels) {
            if ($script:AppState.Channels.ContainsKey($disabledName)) { $script:AppState.Channels[$disabledName].Enabled = $false }
        }
        if ($disabledChannels.Count -gt 0) {
            Write-Log -Level DEBUG -Message ("Inaktive Kanäle: " + ($disabledChannels -join ', '))
        }
    }
    else {
        Write-Log -Level INFO -Message 'Monitor-Modul nicht vorhanden - es werden keine Kanäle überwacht.'
    }

    if (-not $NoTray -and $script:AppState.Features.Tray) {
        Initialize-Tray -State $script:AppState
    }
    elseif (-not $NoTray) {
        Write-Log -Level INFO -Message 'Tray-Modul nicht vorhanden - es gibt kein Tray-Icon.'
    }

    # Einzeldownloads (unabhängig vom Monitoring, funktioniert auch bei Konfigurationsfehlern).
    if ($script:AppState.Features.Downloader) {
        Initialize-Downloader -State $script:AppState
    }

    if ($script:AppState.Features.Monitor) {
        Start-Monitor -State $script:AppState
    }

    # Optionales Fenster beim Start. Fehler hier dürfen den Start nicht verhindern.
    if ($ShowWindow) {
        if ($script:AppState.Features.Gui) {
            try {
                Show-MainWindow -State $script:AppState
                Write-Log -Level INFO -Message 'Hauptfenster geöffnet.'
            }
            catch { Write-Log -Level ERROR -Message "Hauptfenster konnte nicht geöffnet werden: $($_.Exception.Message)" }
        }
        else {
            Write-Log -Level WARN -Message '-ShowWindow angegeben, aber modules\Gui.psm1 wurde nicht geladen.'
        }
    }

    if (-not $NoTray -and $script:AppState.Features.Tray) {
        [System.Windows.Forms.Application]::Run()
    }
    elseif ($script:AppState.Features.Monitor -or $script:AppState.Features.Downloader) {
        Write-Log -Level INFO -Message 'NoTray-Modus: Monitor läuft bis zum Abbruch.'
        while ($script:AppState.IsRunning) {
            [System.Windows.Forms.Application]::DoEvents()   # damit die Timer auch ohne Tray feuern
            Start-Sleep -Milliseconds 200
        }
    }
    else {
        Write-Log -Level WARN -Message 'Weder Tray noch Monitoring/Downloads vorhanden - nichts zu tun, die App beendet sich.'
        $script:AppState.IsRunning = $false
    }
}
catch {
    Write-Log -Level ERROR -Message "Startfehler: $($_.Exception.Message)"
    throw
}
finally {
    # Hier landet man mit IsRunning = $true nur bei abnormalem Ende (Fehler, Strg+C, Absturz des Message-Loops).
    # Bei "Beenden (App)" ist IsRunning schon $false - dort bleiben Aufnahmen bewusst am Laufen.
    # Bei abnormalem Ende werden Aufnahmen immer sauber beendet (Ctrl+C + Remux), statt sie zu verwaisen.
    try {
        if ($script:AppState.IsRunning -and $script:AppState.Features.Monitor) {
            Stop-Monitor -State $script:AppState -StopRecordings $true
        }
    }
    catch { Write-Log -Level ERROR -Message "Cleanup (Stop-Monitor): $($_.Exception.Message)" }

    try { if ($script:AppState.Features.Downloader) { Stop-Downloader -State $script:AppState } }
    catch { Write-Log -Level ERROR -Message "Cleanup (Downloader): $($_.Exception.Message)" }

    try { if (Get-Command Dispose-Gui -ErrorAction SilentlyContinue) { Dispose-Gui } }
    catch { Write-Log -Level ERROR -Message "Cleanup (GUI): $($_.Exception.Message)" }

    try { Dispose-Tray -State $script:AppState }
    catch { Write-Log -Level ERROR -Message "Cleanup (Tray): $($_.Exception.Message)" }

    Write-Log -Level INFO -Message 'Twitch Monitor beendet.'
    if ($script:OwnsMutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
}
