$script:LogDirectory = $null
$script:LogLevel = 'INFO'
$script:LogMaxBytes = 5MB    # ab dieser Größe wird rotiert
$script:LogKeep = 3          # wie viele alte Stände (.1 bis .3) behalten werden

function Initialize-Logging {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogDirectory)

    $script:LogDirectory = $LogDirectory
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
}

function Set-LogLevel {
    # DEBUG-Meldungen (Routine/Details) werden nur geschrieben, wenn logLevel in config.json auf 'DEBUG' steht.
    [CmdletBinding()]
    param([ValidateSet('DEBUG','INFO')][string]$Level = 'INFO')
    $script:LogLevel = $Level
}

function Invoke-LogRotation {
    # monitor.log -> monitor.log.1 -> .2 -> .3 (ältester fällt weg). Schlägt das fehl (z. B. weil ein Editor
    # die Datei offen hält), wird einfach weiter an die bestehende Datei angehängt.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $file -or $file.Length -le $script:LogMaxBytes) { return }
        $oldest = "$Path.$($script:LogKeep)"
        if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force -ErrorAction Stop }
        for ($i = $script:LogKeep - 1; $i -ge 1; $i--) {
            $from = "$Path.$i"
            if (Test-Path -LiteralPath $from) { Move-Item -LiteralPath $from -Destination "$Path.$($i + 1)" -Force -ErrorAction Stop }
        }
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction Stop
    }
    catch { }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [string]$Channel,
        [ValidateSet('DEBUG','INFO','WARN','ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )

    try {
        if (-not $script:LogDirectory) { return }
        if ($Level -eq 'DEBUG' -and $script:LogLevel -ne 'DEBUG') { return }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        $monitorLog = Join-Path $script:LogDirectory 'monitor.log'
        Invoke-LogRotation -Path $monitorLog
        Add-Content -LiteralPath $monitorLog -Value $line -Encoding UTF8
        if ($Channel) {
            $safeName = $Channel -replace '[^\w.-]', '_'
            $channelLog = Join-Path $script:LogDirectory "$safeName.log"
            Invoke-LogRotation -Path $channelLog
            Add-Content -LiteralPath $channelLog -Value $line -Encoding UTF8
        }
    }
    catch {
        # Logging darf die Anwendung nicht beenden.
    }
}

Export-ModuleMember -Function Initialize-Logging, Set-LogLevel, Write-Log
