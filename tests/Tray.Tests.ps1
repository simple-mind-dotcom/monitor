Describe 'Format-Size (Tray)' -Tag 'Tray' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Tray.psm1') -Force -DisableNameChecking
    }

    It 'formatiert Kilobyte' {
        Format-Size -Bytes 500KB | Should -Be '500 KB'
    }

    It 'formatiert Megabyte mit einer Nachkommastelle' {
        Format-Size -Bytes (1.5MB) | Should -Match '^1,5 MB$|^1\.5 MB$'
    }

    It 'formatiert Gigabyte mit zwei Nachkommastellen' {
        Format-Size -Bytes 2GB | Should -Match '^2,00 GB$|^2\.00 GB$'
    }

    It 'formatiert kleine Werte als KB' {
        Format-Size -Bytes 10 | Should -Be '0 KB'
    }
}
