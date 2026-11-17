Describe 'Get-GuiDiskStatus (Gui)' -Tag 'Gui' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\modules\Gui.psm1') -Force -DisableNameChecking
    }

    It "liefert 'ok', wenn das Minimum 0 ist" {
        $state = @{ Config = @{ OutputDirectory = $TestDrive; MinFreeDiskSpaceGB = 0 } }
        $status = Get-GuiDiskStatus -State $state
        $status | Should -Not -BeNullOrEmpty
        $status.Level | Should -Be 'ok'
    }

    It "liefert 'critical', wenn der freie Platz unter dem Minimum liegt" {
        $state = @{ Config = @{ OutputDirectory = $TestDrive; MinFreeDiskSpaceGB = 1000000 } }
        $status = Get-GuiDiskStatus -State $state
        $status | Should -Not -BeNullOrEmpty
        $status.Level | Should -Be 'critical'
    }

    It "liefert Drive und freien Speicher fuer einen gueltigen Pfad" {
        $state = @{ Config = @{ OutputDirectory = $TestDrive; MinFreeDiskSpaceGB = 5 } }
        $status = Get-GuiDiskStatus -State $state
        $status | Should -Not -BeNullOrEmpty
        $status.Drive | Should -Match '^[A-Za-z]:\\$'
        $status.FreeGB | Should -BeGreaterThan 0
    }

    It "liefert keinen Status fuer einen ungueltigen Pfad" {
        $state = @{ Config = @{ OutputDirectory = 'Q:\gibt-es-nicht\xyz'; MinFreeDiskSpaceGB = 5 } }
        Get-GuiDiskStatus -State $state | Should -BeNullOrEmpty
    }
}
