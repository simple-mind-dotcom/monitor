Describe 'ConvertTo-ArgumentString (Recorder)' -Tag 'Recorder' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Recorder.psm1') -Force -DisableNameChecking
    }

    It 'verbindet einfache Argumente ohne Anfuehrungszeichen' {
        ConvertTo-ArgumentString -Items @('--no-progress', 'https://www.twitch.tv/x') |
            Should -Be '--no-progress https://www.twitch.tv/x'
    }

    It 'zitiert Argumente mit Leerzeichen' {
        ConvertTo-ArgumentString -Items @('-o', 'C:\out dir\file name.mp4') |
            Should -Be '-o "C:\out dir\file name.mp4"'
    }

    It 'maskiert Anfuehrungszeichen im Argument' {
        ConvertTo-ArgumentString -Items @('say "hi"') |
            Should -Be '"say \"hi\""'
    }

    It 'verdoppelt abschliessende Backslashes innerhalb von Anfuehrungszeichen' {
        ConvertTo-ArgumentString -Items @('C:\path with space\') |
            Should -Be '"C:\path with space\\"'
    }

    It 'zitiert leere Argumente' {
        ConvertTo-ArgumentString -Items @('') | Should -Be '""'
    }
}

Describe 'Get-SafeFileName (Recorder)' -Tag 'Recorder' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Recorder.psm1') -Force -DisableNameChecking
    }

    It 'ersetzt Leerzeichen und Sonderzeichen' {
        Get-SafeFileName -Text 'Hello World: Test?' | Should -Be 'Hello_World_Test'
    }

    It 'wandelt Umlaute in ASCII um' {
        Get-SafeFileName -Text 'Héllo Wörld' | Should -Be 'Hello_World'
    }

    It 'kuerzt lange Titel' {
        $name = Get-SafeFileName -Text ('a' * 200) -MaxLength 80
        $name.Length | Should -BeLessOrEqual 80
    }

    It 'liefert einen Fallback fuer leere Eingabe' {
        Get-SafeFileName -Text '   ' | Should -Be 'stream'
    }
}

Describe 'Get-RecordingSize Caching (Recorder)' -Tag 'Recorder' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Recorder.psm1') -Force -DisableNameChecking
        $tmp = Join-Path $TestDrive 'rec'
        New-Item -ItemType Directory -Path $tmp | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $tmp 'p1.part'), [byte[]](1, 2, 3))
        $script:state = @{ Channels = @{ chan = @{ OutputFolder = $tmp; OutputPrefix = 'p'; SizeCache = $null } } }
    }

    It 'summiert die Dateien des Praefix' {
        $size = Get-RecordingSize -Channel 'chan' -State $script:state
        $size | Should -BeGreaterThan 0
        $script:state.Channels['chan'].SizeCache | Should -Not -BeNullOrEmpty
    }

    It 'liefert den Cache innerhalb von 5 Sekunden ohne neuen Scan' {
        $script:state.Channels['chan'].SizeCache = @{ Value = [int64]12345; At = (Get-Date) }
        Get-RecordingSize -Channel 'chan' -State $script:state | Should -Be 12345
    }
}
