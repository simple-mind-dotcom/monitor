Describe 'Test-DownloadUrl (Downloader)' -Tag 'Downloader' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Downloader.psm1') -Force -DisableNameChecking
    }

    It 'akzeptiert http(s)-Links' {
        Test-DownloadUrl -Url 'https://example.com/watch?v=1' | Should -BeTrue
        Test-DownloadUrl -Url 'http://example.com' | Should -BeTrue
    }

    It 'lehnt andere Schemata ab' {
        Test-DownloadUrl -Url 'ftp://example.com' | Should -BeFalse
        Test-DownloadUrl -Url 'file:///C:/x' | Should -BeFalse
    }

    It 'lehnt yt-dlp-Optionen als Link ab' {
        Test-DownloadUrl -Url '--exec calc' | Should -BeFalse
    }

    It 'lehnt Links mit Leerzeichen oder Anfuehrungszeichen ab' {
        Test-DownloadUrl -Url 'https://example.com/a b' | Should -BeFalse
        Test-DownloadUrl -Url 'https://example.com/"x"' | Should -BeFalse
    }
}

Describe 'Get-LastDownloadError (Downloader)' -Tag 'Downloader' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Downloader.psm1') -Force -DisableNameChecking
    }

    It 'extrahiert die letzte ERROR-Zeile' {
        $log = Join-Path $TestDrive 'err.log'
        Set-Content -LiteralPath $log -Value @('INFO start', 'ERROR: boom', 'ERROR: boom 2') -Encoding UTF8
        Get-LastDownloadError -Path $log | Should -Match 'boom 2'
    }

    It 'liefert Leerstring ohne Treffer' {
        $log = Join-Path $TestDrive 'ok.log'
        Set-Content -LiteralPath $log -Value 'alles gut' -Encoding UTF8
        Get-LastDownloadError -Path $log | Should -Be ''
    }
}
