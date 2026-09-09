#requires -Modules Pester

<#
    Unit tests for the pure logic of wstfu.ps1.

    Everything here runs without touching the registry, the task scheduler or
    the event log, so it is safe on any machine and on any CI runner. The parts
    that do touch the system are thin wrappers by design; they are covered by
    the manual VM checklist in docs/vm-checklist.md.
#>

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root 'wstfu.ps1') -NoExecute
}

Describe 'Get-WstfuPlan' {

    It 'returns a strictly growing plan as the level rises' {
        $l1 = @(Get-WstfuPlan -Level 1)
        $l2 = @(Get-WstfuPlan -Level 2)
        $l3 = @(Get-WstfuPlan -Level 3)

        $l1.Count | Should -BeGreaterThan 0
        $l2.Count | Should -BeGreaterThan $l1.Count
        $l3.Count | Should -BeGreaterThan $l2.Count
    }

    It 'keeps every lower level as a subset of every higher level' {
        $l1 = @(Get-WstfuPlan -Level 1).Id
        $l2 = @(Get-WstfuPlan -Level 2).Id
        $l3 = @(Get-WstfuPlan -Level 3).Id

        @($l1 | Where-Object { $_ -notin $l2 }) | Should -BeNullOrEmpty
        @($l2 | Where-Object { $_ -notin $l3 }) | Should -BeNullOrEmpty
    }

    It 'has a unique id for every setting' {
        $ids = @(Get-WstfuPlan -Level 3).Id
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'explains every setting, so status output is never a mystery' {
        @(Get-WstfuPlan -Level 3 | Where-Object { [string]::IsNullOrWhiteSpace($_.Why) }) |
            Should -BeNullOrEmpty
    }

    It 'writes only to the two update policy trees and the update UX tree' {
        $allowed = @(
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
            'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        )
        @(Get-WstfuPlan -Level 3 | Where-Object { $_.Path -notin $allowed }) |
            Should -BeNullOrEmpty
    }

    It 'puts no pause settings below level 3' {
        @(Get-WstfuPlan -Level 2 | Where-Object { $_.Name -like 'Pause*' }) |
            Should -BeNullOrEmpty
        @(Get-WstfuPlan -Level 3 | Where-Object { $_.Name -like 'Pause*' }).Count |
            Should -BeGreaterThan 0
    }

    It 'keeps the level 1 plan about reboots only, never about deferral' {
        @(Get-WstfuPlan -Level 1 | Where-Object { $_.Name -like 'Defer*' -or $_.Name -like 'Target*' }) |
            Should -BeNullOrEmpty
    }
}

Describe 'Active hours' {

    It 'stays inside the 18-hour span Windows actually accepts' {
        ($script:ActiveHoursEnd - $script:ActiveHoursStart) | Should -BeLessOrEqual 18
        $script:ActiveHoursStart | Should -BeGreaterOrEqual 0
        $script:ActiveHoursEnd   | Should -BeLessOrEqual 23
    }
}

Describe 'Orchestrator task list' {

    It 'never touches Schedule Scan, which manual update checks need' {
        @($script:RebootTasks | Where-Object { $_ -match 'Schedule Scan' }) | Should -BeNullOrEmpty
    }

    It 'only ever targets tasks under UpdateOrchestrator' {
        @($script:RebootTasks | Where-Object { $_ -notlike '\Microsoft\Windows\UpdateOrchestrator\*' }) |
            Should -BeNullOrEmpty
    }
}

Describe 'Rolling pause' {

    BeforeAll {
        $script:Start = Get-WstfuPlan -Level 3 | Where-Object { $_.Id -eq 'S01' }
        $script:End   = Get-WstfuPlan -Level 3 | Where-Object { $_.Id -eq 'S04' }
    }

    It 'accepts a stamp written moments ago' {
        Test-SettingSatisfied -Setting $script:Start -Current (Get-DesiredValue $script:Start) |
            Should -BeTrue
    }

    It 'wants a re-stamp once the pause start is over a week old' {
        $old = ConvertTo-PauseStamp -Moment (Get-Date).AddDays(-20)
        Test-SettingSatisfied -Setting $script:Start -Current $old | Should -BeFalse
    }

    It 'treats a missing or unparseable stamp as drift' {
        Test-SettingSatisfied -Setting $script:Start -Current $null      | Should -BeFalse
        Test-SettingSatisfied -Setting $script:Start -Current 'nonsense' | Should -BeFalse
    }

    It 'wants a fresh end date once the pause is close to expiring' {
        $soon = ConvertTo-PauseStamp -Moment (Get-Date).AddDays(3)
        Test-SettingSatisfied -Setting $script:End -Current $soon | Should -BeFalse
        Test-SettingSatisfied -Setting $script:End -Current (Get-DesiredValue $script:End) | Should -BeTrue
    }

    It 'round-trips a pause stamp' {
        $now  = Get-Date
        $back = ConvertFrom-PauseStamp (ConvertTo-PauseStamp -Moment $now)
        [math]::Abs(($back - $now.ToUniversalTime()).TotalSeconds) | Should -BeLessThan 2
    }
}

Describe 'Static settings comparison' {

    It 'reports a matching value as satisfied' {
        $s = Get-WstfuPlan -Level 1 | Where-Object { $_.Id -eq 'M01' }
        Test-SettingSatisfied -Setting $s -Current 1 | Should -BeTrue
        Test-SettingSatisfied -Setting $s -Current 0 | Should -BeFalse
        Test-SettingSatisfied -Setting $s -Current $null | Should -BeFalse
    }
}

Describe 'Get-ProductNameFromBuild' {

    It 'trusts the build number, because ProductName lies on Windows 11' {
        # A real Windows 11 25H2 box reports ProductName = "Windows 10 Pro".
        Get-ProductNameFromBuild -Build 26200 | Should -Be 'Windows 11'
        Get-ProductNameFromBuild -Build 22000 | Should -Be 'Windows 11'
        Get-ProductNameFromBuild -Build 19045 | Should -Be 'Windows 10'
        Get-ProductNameFromBuild -Build '19045' | Should -Be 'Windows 10'
    }

    It 'does not guess when the build is unreadable' {
        Get-ProductNameFromBuild -Build 'nonsense' | Should -Be 'Windows'
        Get-ProductNameFromBuild -Build 0 | Should -Be 'Windows'
    }
}

Describe 'Test-ServiceHealthy' {

    It 'accepts the start types Windows ships with' {
        Test-ServiceHealthy -StartType 'Manual'    -Expected @('Manual', 'Automatic') | Should -BeTrue
        Test-ServiceHealthy -StartType 'Automatic' -Expected @('Manual', 'Automatic') | Should -BeTrue
    }

    It 'flags a disabled update service - WSTFU never disables one' {
        Test-ServiceHealthy -StartType 'Disabled' -Expected @('Manual', 'Automatic') | Should -BeFalse
    }
}

Describe 'Watched services' {

    It 'reports on the services a blocker tool would break, and writes to none of them' {
        $names = $script:WatchedServices.Name
        $names | Should -Contain 'wuauserv'
        $names | Should -Contain 'UsoSvc'
        $names | Should -Contain 'WaaSMedicSvc'
        # No setting in the plan may touch a service key.
        @(Get-WstfuPlan -Level 3 | Where-Object { $_.Path -like '*\\Services\\*' }) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-Native' {

    It 'survives a program that writes to stderr and fails' {
        # The bug that took down 'status' on a clean machine: schtasks reports a
        # missing task on stderr, and PowerShell 5.1 turns that into a
        # terminating error under $ErrorActionPreference = 'Stop'.
        $ErrorActionPreference = 'Stop'
        $r = if ($IsWindows -or $null -eq $IsWindows) {
            Invoke-Native -File 'cmd.exe' -Arguments @('/c', 'echo boom 1>&2 & exit /b 3')
        } else {
            Invoke-Native -File '/bin/sh' -Arguments @('-c', 'echo boom 1>&2; exit 3')
        }
        $r.ExitCode | Should -Be 3
        $r.Output | Should -BeLike '*boom*'
    }

    It 'reports a missing executable instead of throwing' {
        $ErrorActionPreference = 'Stop'
        { Invoke-Native -File 'definitely-not-a-real-program-xyz' } | Should -Not -Throw
    }
}

Describe 'ConvertFrom-Duration' {

    It 'reads the forms the CLI documents' {
        (ConvertFrom-Duration '30m').TotalMinutes | Should -Be 30
        (ConvertFrom-Duration '4h').TotalHours    | Should -Be 4
        (ConvertFrom-Duration '2d').TotalDays     | Should -Be 2
        (ConvertFrom-Duration '6').TotalHours     | Should -Be 6
    }

    It 'refuses nonsense rather than silently defaulting' {
        { ConvertFrom-Duration 'soon' }  | Should -Throw
        { ConvertFrom-Duration '4 days' } | Should -Throw
    }
}

Describe 'Test-UninvitedReboot' {

    It 'counts an unexpected shutdown as uninvited' {
        Test-UninvitedReboot -EventId 6008 | Should -BeTrue
    }

    It 'counts a servicing-initiated restart as uninvited' {
        Test-UninvitedReboot -EventId 1074 `
            -Message 'The process C:\WINDOWS\servicing\TrustedInstaller.exe has initiated the restart' |
            Should -BeTrue
    }

    It 'does not blame the user for their own restart' {
        Test-UninvitedReboot -EventId 1074 `
            -Message 'The process C:\Windows\explorer.exe (HOST) has initiated the restart of computer HOST' |
            Should -BeFalse
    }

    It 'ignores unrelated event ids' {
        Test-UninvitedReboot -EventId 41 -Message 'anything' | Should -BeFalse
    }
}

Describe 'Watchdog task definition' {

    BeforeAll {
        $script:Xml = [xml](Get-WatchdogXml -ScriptPath 'C:\ProgramData\WSTFU\wstfu.ps1')
    }

    It 'is valid task XML' {
        $script:Xml.Task.version | Should -Not -BeNullOrEmpty
    }

    It 'runs as SYSTEM with the highest privileges' {
        $script:Xml.Task.Principals.Principal.UserId   | Should -Be 'S-1-5-18'
        $script:Xml.Task.Principals.Principal.RunLevel | Should -Be 'HighestAvailable'
    }

    It 'repeats every ten minutes with no end, and also fires at boot' {
        $script:Xml.Task.Triggers.TimeTrigger.Repetition.Interval | Should -Be 'PT10M'
        $script:Xml.Task.Triggers.TimeTrigger.Repetition.PSObject.Properties.Name |
            Should -Not -Contain 'Duration'
        $script:Xml.Task.Triggers.BootTrigger.Enabled | Should -Be 'true'
    }

    It 'survives battery and missed runs' {
        $script:Xml.Task.Settings.DisallowStartIfOnBatteries | Should -Be 'false'
        $script:Xml.Task.Settings.StartWhenAvailable         | Should -Be 'true'
    }

    It 'points at the installed copy, not at wherever it was run from' {
        $script:Xml.Task.Actions.Exec.Arguments | Should -BeLike '*C:\ProgramData\WSTFU\wstfu.ps1*'
        $script:Xml.Task.Actions.Exec.Arguments | Should -BeLike '*enforce*'
    }
}

Describe 'Documentation drift' {

    BeforeAll {
        $script:LevelsDoc = Get-Content (Join-Path $script:Root 'docs/levels.md') -Raw
    }

    It 'documents every setting the tool can write' {
        # If a row is added to the plan and not to docs/levels.md, the docs are
        # already lying. Fail here rather than in someone's registry.
        $undocumented = @(Get-WstfuPlan -Level 3 | Where-Object {
            $script:LevelsDoc -notmatch [regex]::Escape($_.Id)
        })
        $names = ($undocumented | ForEach-Object { $_.Id }) -join ', '
        $names | Should -BeNullOrEmpty
    }

    It 'documents every orchestrator task it disables' {
        foreach ($t in $script:RebootTasks) {
            $leaf = $t.Split('\')[-1]
            $script:LevelsDoc | Should -BeLike "*$leaf*"
        }
    }

    It 'keeps the promise that level 1 is never switched off' {
        $script:LevelsDoc | Should -BeLike '*Reboot control is never switched off*'
    }
}

Describe 'Revert coverage' {

    BeforeAll {
        $script:Source = Get-Content (Join-Path $script:Root 'wstfu.ps1') -Raw
        $errors = $null; $tokens = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $script:Source, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'derives the revert from the same plan it applies, with no hand-kept second list' {
        # The classic bug in tools like this is an uninstall routine holding its
        # own copy of the value names, which silently rots. Assert that the
        # revert path walks the plan instead.
        $fn = $script:Ast.Find({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Invoke-Speak'
        }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $fn.Extent.Text | Should -BeLike '*Get-WstfuPlan -Level 3*'
        $fn.Extent.Text | Should -BeLike '*Remove-SettingValue*'
    }

    It 'reverts at the highest level regardless of the level in use' {
        # Revert must clean up values left behind by a previously higher level.
        @(Get-WstfuPlan -Level 3).Count | Should -BeGreaterThan @(Get-WstfuPlan -Level 1).Count
    }
}
