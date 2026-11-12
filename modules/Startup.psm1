function Register-AutoStart {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath, [string]$TaskName = 'TwitchMonitor')

    $user = "$env:USERDOMAIN\$env:USERNAME"
    $workDir = Split-Path -Parent $ScriptPath
    $psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
    # Unter Windows 11 mit Windows Terminal als Standard-Terminal bleibt bei "powershell.exe -WindowStyle Hidden"
    # ein sichtbares Terminalfenster stehen. "conhost.exe --headless" startet PowerShell ganz ohne Konsolenfenster.
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    if (Test-Path -LiteralPath $conhost) {
        $action = New-ScheduledTaskAction -Execute $conhost -Argument "--headless powershell.exe $psArgs" -WorkingDirectory $workDir
    }
    else {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs -WorkingDirectory $workDir
    }
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    # Standardmäßig beendet der Taskplaner Tasks nach 72 h - für einen Dauerläufer abschalten.
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    # Interaktiv: nur dann ist das Tray-Icon sichtbar.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

function Unregister-AutoStart {
    [CmdletBinding()]
    param([string]$TaskName = 'TwitchMonitor')
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-AutoStartStatus {
    [CmdletBinding()]
    param([string]$TaskName = 'TwitchMonitor')
    return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

Export-ModuleMember -Function Register-AutoStart, Unregister-AutoStart, Get-AutoStartStatus
