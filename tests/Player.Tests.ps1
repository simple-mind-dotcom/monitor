Describe 'Wiedergabe (Player)' -Tag 'Player' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Player.psm1') -Force -DisableNameChecking
    }

    Describe 'Test-PlaybackUrl' {
        It 'akzeptiert gültige Twitch-URL' {
            Test-PlaybackUrl -Url 'https://twitch.tv/kanal1' | Should -BeTrue
        }

        It 'lehnt leere und nicht-http URLs ab' {
            Test-PlaybackUrl -Url '' | Should -BeFalse
            Test-PlaybackUrl -Url 'file:///C:/x' | Should -BeFalse
        }

        It 'lehnt URLs mit Leerzeichen oder Anführungszeichen ab' {
            Test-PlaybackUrl -Url 'https://x.de/a b' | Should -BeFalse
            Test-PlaybackUrl -Url 'https://x.de/a"b' | Should -BeFalse
        }
    }

    Describe 'ConvertTo-PlaybackArgs' {
        It 'baut URL und Qualität ohne Player' {
            $result = ConvertTo-PlaybackArgs -Url 'https://twitch.tv/kanal1' -Quality 'best'
            $result[-2] | Should -Be 'https://twitch.tv/kanal1'
            $result[-1] | Should -Be 'best'
            $result | Should -Not -Contain '--player'
        }

        It 'setzt den spezifischen Player als Option vor die URL' {
            $result = ConvertTo-PlaybackArgs -Url 'https://twitch.tv/kanal1' -PlayerPath 'C:\Program Files\mpv\mpv.exe' -Quality '720p60'
            $result[0] | Should -Be '--player'
            $result[1] | Should -Be 'C:\Program Files\mpv\mpv.exe'
            $result[2] | Should -Be 'https://twitch.tv/kanal1'
            $result[3] | Should -Be '720p60'
        }

        It 'nutzt best, wenn keine Qualität angegeben ist' {
            $result = ConvertTo-PlaybackArgs -Url 'https://twitch.tv/kanal1'
            $result[-1] | Should -Be 'best'
        }
    }

    Describe 'Get-PlaybackQualities' {
        It 'enthält best, worst und audio_only' {
            $values = (Get-PlaybackQualities) | ForEach-Object { $_.Value }
            $values | Should -Contain 'best'
            $values | Should -Contain 'worst'
            $values | Should -Contain 'audio_only'
        }
    }
}
