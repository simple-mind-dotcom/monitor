Describe 'Test-Config (Config)' -Tag 'Config' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Config.psm1') -Force -DisableNameChecking
    }

    It 'akzeptiert eine gueltige Konfiguration' {
        $config = @{
            Channels = @('kanal1'); PollInterval = 30
            OutputDirectory = 'C:\x'; YtDlpPath = 'yt-dlp'
        }
        { $null = Test-Config -Config $config } | Should -Not -Throw
    }

    It 'wirft ohne Kanaele' {
        $config = @{ Channels = @(); PollInterval = 30; OutputDirectory = 'C:\x'; YtDlpPath = 'yt-dlp' }
        { $null = Test-Config -Config $config } | Should -Throw
    }

    It 'wirft bei pollInterval unter 15' {
        $config = @{ Channels = @('a'); PollInterval = 5; OutputDirectory = 'C:\x'; YtDlpPath = 'yt-dlp' }
        { $null = Test-Config -Config $config } | Should -Throw
    }

    It 'wirft bei pollInterval ueber 3600' {
        $config = @{ Channels = @('a'); PollInterval = 4000; OutputDirectory = 'C:\x'; YtDlpPath = 'yt-dlp' }
        { $null = Test-Config -Config $config } | Should -Throw
    }
}

Describe 'Write-Log Loglevel (Logging)' -Tag 'Logging' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Logging.psm1') -Force -DisableNameChecking
        $script:logDir = Join-Path $TestDrive 'logs'
        Initialize-Logging -LogDirectory $script:logDir
    }

    It 'schreibt WARN immer' {
        Write-Log -Level WARN -Message 'warnung'
        (Get-Content -LiteralPath (Join-Path $script:logDir 'monitor.log')) -join "`n" | Should -Match 'warnung'
    }

    It 'schreibt DEBUG im Standard-Level INFO nicht' {
        $file = Join-Path $script:logDir 'monitor.log'
        $before = (Get-Item -LiteralPath $file).Length
        Write-Log -Level DEBUG -Message 'unsichtbar'
        (Get-Item -LiteralPath $file).Length | Should -Be $before
    }

    It 'schreibt DEBUG, wenn logLevel DEBUG ist' {
        Set-LogLevel -Level DEBUG
        Write-Log -Level DEBUG -Message 'sichtbar'
        (Get-Content -LiteralPath (Join-Path $script:logDir 'monitor.log')) -join "`n" | Should -Match 'sichtbar'
        Set-LogLevel -Level INFO
    }
}
