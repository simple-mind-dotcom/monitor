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
# Gui ist optional: fehlt modules\Gui.psm1, läuft alles wie vorher (ohne Fenster).
$moduleNames = @('Logging', 'Config', 'Recorder', 'Downloader', 'Monitor', 'Tray', 'Startup')
if (Test-Path -LiteralPath (Join-Path $script:ProjectRoot 'modules\Gui.psm1')) { $moduleNames += 'Gui' }
foreach ($name in $moduleNames) {
    Import-Module (Join-Path $script:ProjectRoot "modules\$name.psm1") -Force -Global -DisableNameChecking -ErrorAction Stop
}

if ($InstallAutoStart) {
    Register-AutoStart -ScriptPath $PSCommandPath
    Write-Host "Autostart-Task 'TwitchMonitor' wurde für die Anmeldung registriert."
    return
}
if ($RemoveAutoStart) {
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
    $script:GuiAvailable = [bool](Get-Command Show-MainWindow -ErrorAction SilentlyContinue)
    Write-Log -Level DEBUG -Message ("GUI-Modul: " + $(if ($script:GuiAvailable) { 'geladen (Fenster: Tray-Doppelklick oder Start mit -ShowWindow)' } else { 'nicht vorhanden' }))
    $script:AppState.Config = Initialize-Config -Path (Join-Path $script:ProjectRoot 'configs/config.json')
    Set-LogLevel -Level $script:AppState.Config.LogLevel
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

    if (-not $NoTray) {
        Initialize-Tray -State $script:AppState
    }

    # Einzeldownloads (unabhängig vom Monitoring, funktioniert auch bei Konfigurationsfehlern).
    Initialize-Downloader -State $script:AppState

    Start-Monitor -State $script:AppState

    # Optionales Fenster beim Start. Fehler hier dürfen den Start nicht verhindern.
    if ($ShowWindow) {
        if ($script:GuiAvailable) {
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

    if (-not $NoTray) {
        [System.Windows.Forms.Application]::Run()
    }
    else {
        Write-Log -Level INFO -Message 'NoTray-Modus: Monitor läuft bis zum Abbruch.'
        while ($script:AppState.IsRunning) {
            [System.Windows.Forms.Application]::DoEvents()   # damit die Timer auch ohne Tray feuern
            Start-Sleep -Milliseconds 200
        }
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
        if ($script:AppState.IsRunning) {
            Stop-Monitor -State $script:AppState -StopRecordings $true
        }
    }
    catch { Write-Log -Level ERROR -Message "Cleanup (Stop-Monitor): $($_.Exception.Message)" }

    try { Stop-Downloader -State $script:AppState }
    catch { Write-Log -Level ERROR -Message "Cleanup (Downloader): $($_.Exception.Message)" }

    try { if (Get-Command Dispose-Gui -ErrorAction SilentlyContinue) { Dispose-Gui } }
    catch { Write-Log -Level ERROR -Message "Cleanup (GUI): $($_.Exception.Message)" }

    try { Dispose-Tray -State $script:AppState }
    catch { Write-Log -Level ERROR -Message "Cleanup (Tray): $($_.Exception.Message)" }

    Write-Log -Level INFO -Message 'Twitch Monitor beendet.'
    if ($script:OwnsMutex) { try { $script:Mutex.ReleaseMutex() } catch { } }
}
