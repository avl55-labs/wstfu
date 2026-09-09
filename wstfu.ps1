<#
.SYNOPSIS
    WSTFU - Windows, Shut The F**k Up.
    Takes reboot control away from Windows Update and keeps it that way.

.DESCRIPTION
    One file, a handful of commands:

      status            (default) read-only report. Changes nothing.
      shutup [-Level N] apply the chosen noise level and install the watchdog.
      window <duration> open a maintenance window: updates allowed, reboots still yours.
      close             close the maintenance window early.
      speak             full revert to Microsoft defaults, watchdog removed.
      enforce           single silent pass (this is what the watchdog runs).

    Noise levels:
      1  mute   - reboot control only. Updates install as usual, only you reboot.
      2  quiet  - mute + version pin + 30-day quality deferral + no restart nags.
      3  stfu   - quiet + rolling pause. Nothing arrives until you open a window.

.NOTES
    Honest limits: a local administrator, SYSTEM and TrustedInstaller sit above
    every service in Windows by design. Nothing here is un-killable, and it must
    not be. WSTFU defends against *automatic* reversion - an update, sfc, a
    cleanup tool - by putting the settings back within 10 minutes and recreating
    its own task if that gets deleted.

    Repository: https://github.com/<owner>/wstfu
    License: MIT
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Yes',
    Justification = 'Passed through as -NoPrompt:$Yes; the analyzer does not follow switch splatting.')]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'shutup', 'window', 'close', 'speak', 'enforce', 'help')]
    [string]$Command = 'status',

    # 0 means "not supplied" - shutup then asks, or defaults to 3 with -Yes.
    [int]$Level = 0,

    [string]$For = '4h',

    [switch]$Yes,

    # Dot-source the script without running anything (used by the test suite).
    [switch]$NoExecute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ------------------------------------------------------------- constants

$script:Version    = '1.0.0-beta'
# ProgramData is absent when the file is dot-sourced by the test suite on a
# non-Windows CI leg; the fallback keeps the pure logic loadable anywhere.
$script:ProgramData = if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }
$script:SystemRoot  = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
$script:HomeDir    = Join-Path $script:ProgramData 'WSTFU'
$script:InstalledPs = Join-Path $script:HomeDir 'wstfu.ps1'
$script:LogPath    = Join-Path $script:HomeDir 'wstfu.log'
$script:ConfigPath = Join-Path $script:HomeDir 'config.json'
$script:StatePath  = Join-Path $script:HomeDir 'state.json'
$script:TaskName   = 'WSTFU'
$script:MaxLogBytes = 1MB

$script:RegWU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:RegAU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:RegUX = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

# Windows caps the active-hours span at 18 hours. 05:00-23:00 is the widest
# legal window; anything larger is silently rejected, so we do not pretend.
$script:ActiveHoursStart = 5
$script:ActiveHoursEnd   = 23

# Microsoft's pause mechanism runs 35 days from the recorded start time.
$script:PauseDays = 35

# Reboot triggers owned by the Update Orchestrator. Note that 'Schedule Scan'
# is deliberately NOT here: disabling it breaks manual update checks too.
$script:RebootTasks = @(
    '\Microsoft\Windows\UpdateOrchestrator\Reboot'
    '\Microsoft\Windows\UpdateOrchestrator\Reboot_AC'
    '\Microsoft\Windows\UpdateOrchestrator\Reboot_Battery'
    '\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_ReadyToReboot'
    '\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_Display'
)

$script:LevelNames = @{ 1 = 'mute'; 2 = 'quiet'; 3 = 'stfu' }

# Services WSTFU never touches. They are reported because a blunt-instrument
# blocker (Windows Update Blocker and friends) leaves its fingerprints here: a
# Disabled wuauserv or UsoSvc means updates are broken rather than managed, and
# nothing in this tool would have done that.
$script:WatchedServices = @(
    @{ Name = 'wuauserv';     Expect = @('Manual', 'Automatic'); Note = 'Windows Update service' }
    @{ Name = 'UsoSvc';       Expect = @('Manual', 'Automatic'); Note = 'Update Session Orchestrator' }
    @{ Name = 'WaaSMedicSvc'; Expect = @('Manual', 'Automatic'); Note = 'Update Medic - undoes tampering' }
    @{ Name = 'BITS';         Expect = @('Manual', 'Automatic'); Note = 'transfer service' }
    @{ Name = 'DoSvc';        Expect = @('Manual', 'Automatic'); Note = 'delivery optimization' }
)

#endregion

#region ----------------------------------------------------------------- output

function Write-Out {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

function Invoke-Native {
    <#
    .SYNOPSIS
        Runs a console executable and returns its output plus exit code.
    .NOTES
        Windows PowerShell 5.1 turns anything a native program writes to stderr
        into an error record, and with $ErrorActionPreference = 'Stop' that
        terminates the whole script. schtasks writes to stderr for the entirely
        normal "this task does not exist" case, so without this wrapper a fresh
        machine cannot even run 'status'. Found the hard way on a real box.
    #>
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $File @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    } catch {
        return [pscustomobject]@{ Output = $_.Exception.Message; ExitCode = -1 }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Write-GuardLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not (Test-Path $script:HomeDir)) {
            New-Item -ItemType Directory -Path $script:HomeDir -Force | Out-Null
        }
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
        $item = Get-Item $script:LogPath -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt $script:MaxLogBytes) {
            $tail = Get-Content $script:LogPath -Tail 1500
            Set-Content -Path $script:LogPath -Value $tail -Encoding UTF8
        }
    } catch {
        $script:LastLogError = $_.Exception.Message   # logging must never break enforcement
    }
}

#endregion

#region ------------------------------------------------------- the settings plan

function New-Setting {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int]$Level,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('DWord', 'String')][string]$Type = 'DWord',
        $Value = $null,
        [scriptblock]$Desired = $null,
        [scriptblock]$IsOk = $null,
        [Parameter(Mandatory)][string]$Why,
        [ValidateSet('high', 'medium', 'legacy')][string]$Confidence = 'high'
    )
    [pscustomobject]@{
        Id         = $Id
        Level      = $Level
        Path       = $Path
        Name       = $Name
        Type       = $Type
        Value      = $Value
        Desired    = $Desired
        IsOk       = $IsOk
        Why        = $Why
        Confidence = $Confidence
    }
}

function Get-ProductNameFromBuild {
    <# HKLM ProductName lies on Windows 11; the build number does not. #>
    param([Parameter(Mandatory)]$Build)
    $n = 0
    [void][int]::TryParse([string]$Build, [ref]$n)
    if ($n -ge 22000) { return 'Windows 11' }
    if ($n -ge 10240) { return 'Windows 10' }
    return 'Windows'
}

function Get-WindowsRelease {
    <# Current Windows release, used for the version pin. #>
    $cv = $null
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    } catch {
        Write-GuardLog "Could not read the current Windows release: $($_.Exception.Message)" 'WARN'
    }
    $display = '22H2'
    $product = 'Windows 11'
    if ($cv) {
        if ($cv.PSObject.Properties.Name -contains 'DisplayVersion' -and $cv.DisplayVersion) {
            $display = $cv.DisplayVersion
        } elseif ($cv.PSObject.Properties.Name -contains 'ReleaseId' -and $cv.ReleaseId) {
            $display = $cv.ReleaseId
        }
        if ($cv.PSObject.Properties.Name -contains 'CurrentBuild') {
            $product = Get-ProductNameFromBuild -Build $cv.CurrentBuild
        }
    }
    [pscustomobject]@{ DisplayVersion = $display; ProductVersion = $product }
}

function ConvertTo-PauseStamp {
    param([datetime]$Moment)
    $Moment.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertFrom-PauseStamp {
    param([string]$Stamp)
    if ([string]::IsNullOrWhiteSpace($Stamp)) { return $null }
    try {
        return [datetime]::Parse(
            $Stamp,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    } catch { return $null }
}

function Get-WstfuPlan {
    <#
    .SYNOPSIS
        The whole policy of this tool as data. Apply, verify, report and revert
        are four passes over this one list - there is no second copy to drift.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([ValidateRange(1, 3)][int]$Level = 3)

    $rel = Get-WindowsRelease
    $p = @()

    # --- level 1: mute -- nobody but the human reboots this machine ------------

    $p += New-Setting -Id 'M01' -Level 1 -Path $script:RegAU -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1 `
        -Why 'No automatic restart while a user is signed in.'
    $p += New-Setting -Id 'M02' -Level 1 -Path $script:RegAU -Name 'AlwaysAutoRebootAtScheduledTime' -Value 0 `
        -Why 'Kills the forced restart countdown after an install.' -Confidence 'medium'
    $p += New-Setting -Id 'M03' -Level 1 -Path $script:RegWU -Name 'SetAutoRestartNotificationDisable' -Value 1 `
        -Why 'No auto-restart notifications, so nothing nags a restart into happening.'
    $p += New-Setting -Id 'M04' -Level 1 -Path $script:RegWU -Name 'SetAutoRestartNotificationDisable2' -Value 1 `
        -Why 'Same as M03 on newer builds where the key was renamed.' -Confidence 'medium'
    $p += New-Setting -Id 'M05' -Level 1 -Path $script:RegUX -Name 'RestartNotificationsAllowed2' -Value 0 `
        -Why 'Removes the "restart now" push in the update UX.'
    $p += New-Setting -Id 'M06' -Level 1 -Path $script:RegUX -Name 'SmartActiveHoursState' -Value 0 `
        -Why 'Stops Windows from picking active hours for you, so ours stick.'
    $p += New-Setting -Id 'M07' -Level 1 -Path $script:RegWU -Name 'SetActiveHours' -Value 1 `
        -Why 'Enables the active-hours policy below.'
    $p += New-Setting -Id 'M08' -Level 1 -Path $script:RegWU -Name 'ActiveHoursStart' -Value $script:ActiveHoursStart `
        -Why "Active hours start. Windows caps the span at 18 hours, so $($script:ActiveHoursStart):00-$($script:ActiveHoursEnd):00 is the widest legal window."
    $p += New-Setting -Id 'M09' -Level 1 -Path $script:RegWU -Name 'ActiveHoursEnd' -Value $script:ActiveHoursEnd `
        -Why 'Active hours end. Outside this span the other settings are what protect you.'

    # --- level 2: quiet -- updates arrive on your schedule, not theirs ---------

    $p += New-Setting -Id 'Q01' -Level 2 -Path $script:RegWU -Name 'TargetReleaseVersion' -Value 1 `
        -Why 'Enables the feature-update version pin.'
    $p += New-Setting -Id 'Q02' -Level 2 -Path $script:RegWU -Name 'TargetReleaseVersionInfo' -Type 'String' -Value $rel.DisplayVersion `
        -Why "Pins the machine to $($rel.DisplayVersion). Feature updates are the ones that reboot you without asking."
    $p += New-Setting -Id 'Q03' -Level 2 -Path $script:RegWU -Name 'ProductVersion' -Type 'String' -Value $rel.ProductVersion `
        -Why "Tells the pin which product line to stay on ($($rel.ProductVersion))."
    $p += New-Setting -Id 'Q04' -Level 2 -Path $script:RegWU -Name 'DeferFeatureUpdates' -Value 1 `
        -Why 'Belt and braces with the pin above.'
    $p += New-Setting -Id 'Q05' -Level 2 -Path $script:RegWU -Name 'DeferFeatureUpdatesPeriodInDays' -Value 365 `
        -Why 'Maximum feature-update deferral.'
    $p += New-Setting -Id 'Q06' -Level 2 -Path $script:RegWU -Name 'DeferQualityUpdates' -Value 1 `
        -Why 'Enables the quality-update deferral - the monthly patch is what actually reboots you.'
    $p += New-Setting -Id 'Q07' -Level 2 -Path $script:RegWU -Name 'DeferQualityUpdatesPeriodInDays' -Value 30 `
        -Why 'Monthly patches land 30 days late, on a day you choose. 30 is the documented maximum.'
    $p += New-Setting -Id 'Q08' -Level 2 -Path $script:RegUX -Name 'IsContinuousInnovationOptedIn' -Value 0 `
        -Why 'Turns off "get the latest updates as soon as they are available".'
    $p += New-Setting -Id 'Q09' -Level 2 -Path $script:RegAU -Name 'NoAutoUpdate' -Value 0 `
        -Why 'Updates stay reachable - we control timing, we do not amputate the service.'
    $p += New-Setting -Id 'Q10' -Level 2 -Path $script:RegAU -Name 'AUOptions' -Value 2 `
        -Why 'Legacy "notify only". Largely ignored on Windows 10 1803+ and 11; kept because it costs nothing and still applies on LTSC.' `
        -Confidence 'legacy'
    $p += New-Setting -Id 'Q11' -Level 2 -Path $script:RegAU -Name 'AutoInstallMinorUpdates' -Value 0 `
        -Why 'Legacy companion to Q10.' -Confidence 'legacy'

    # --- level 3: stfu -- rolling pause, nothing arrives at all ----------------

    $stampNow  = { ConvertTo-PauseStamp -Moment (Get-Date) }
    $stampEnd  = { ConvertTo-PauseStamp -Moment (Get-Date).AddDays($script:PauseDays) }
    # Re-stamped once a week rather than every tick: less registry churn, and the
    # pause never gets closer than four weeks from expiring.
    $startOk   = {
        param($Current)
        $d = ConvertFrom-PauseStamp $Current
        if (-not $d) { return $false }
        $age = ((Get-Date).ToUniversalTime() - $d).TotalDays
        return ($age -ge 0 -and $age -lt 7)
    }
    $endOk     = {
        param($Current)
        $d = ConvertFrom-PauseStamp $Current
        if (-not $d) { return $false }
        $left = ($d - (Get-Date).ToUniversalTime()).TotalDays
        return ($left -gt ($script:PauseDays - 7))
    }

    $p += New-Setting -Id 'S01' -Level 3 -Path $script:RegWU -Name 'PauseQualityUpdatesStartTime' -Type 'String' `
        -Desired $stampNow -IsOk $startOk `
        -Why "Rolling quality-update pause. The watchdog re-stamps it weekly, so it is always ~$($script:PauseDays) days from expiring."
    $p += New-Setting -Id 'S02' -Level 3 -Path $script:RegWU -Name 'PauseFeatureUpdatesStartTime' -Type 'String' `
        -Desired $stampNow -IsOk $startOk `
        -Why 'Rolling feature-update pause, same mechanism.'
    $p += New-Setting -Id 'S03' -Level 3 -Path $script:RegUX -Name 'PauseQualityUpdatesStartTime' -Type 'String' `
        -Desired $stampNow -IsOk $startOk `
        -Why 'Mirrors the pause into the Settings UI so it reports the truth.' -Confidence 'medium'
    $p += New-Setting -Id 'S04' -Level 3 -Path $script:RegUX -Name 'PauseQualityUpdatesEndTime' -Type 'String' `
        -Desired $stampEnd -IsOk $endOk `
        -Why 'End of the mirrored quality pause.' -Confidence 'medium'
    $p += New-Setting -Id 'S05' -Level 3 -Path $script:RegUX -Name 'PauseFeatureUpdatesStartTime' -Type 'String' `
        -Desired $stampNow -IsOk $startOk `
        -Why 'Mirrors the feature pause into the Settings UI.' -Confidence 'medium'
    $p += New-Setting -Id 'S06' -Level 3 -Path $script:RegUX -Name 'PauseFeatureUpdatesEndTime' -Type 'String' `
        -Desired $stampEnd -IsOk $endOk `
        -Why 'End of the mirrored feature pause.' -Confidence 'medium'
    $p += New-Setting -Id 'S07' -Level 3 -Path $script:RegUX -Name 'PauseUpdatesExpiryTime' -Type 'String' `
        -Desired $stampEnd -IsOk $endOk `
        -Why 'The date the Settings app shows as "paused until".' -Confidence 'medium'
    $p += New-Setting -Id 'S08' -Level 3 -Path $script:RegUX -Name 'FlightSettingsMaxPauseDays' -Value 3650 `
        -Why 'Lets the UI accept a pause longer than its built-in 35-day slider.' -Confidence 'medium'

    return @($p | Where-Object { $_.Level -le $Level })
}

function Get-DesiredValue {
    param([Parameter(Mandatory)]$Setting)
    if ($Setting.Desired) { return (& $Setting.Desired) }
    return $Setting.Value
}

function Test-SettingSatisfied {
    <# Pure check: does this current value satisfy the setting? #>
    param([Parameter(Mandatory)]$Setting, $Current)
    if ($Setting.IsOk) { return [bool](& $Setting.IsOk $Current) }
    if ($null -eq $Current) { return $false }
    return ([string]$Current -eq [string](Get-DesiredValue $Setting))
}

#endregion

#region ------------------------------------------------------------- registry io

function Get-CurrentValue {
    param([Parameter(Mandatory)]$Setting)
    try {
        $item = Get-ItemProperty -Path $Setting.Path -Name $Setting.Name -ErrorAction Stop
        return $item.$($Setting.Name)
    } catch { return $null }
}

function Invoke-SettingApply {
    <# Returns 'ok' (already correct), 'fixed' (was wrong, corrected) or 'failed'. #>
    param([Parameter(Mandatory)]$Setting)
    $current = Get-CurrentValue $Setting
    if (Test-SettingSatisfied -Setting $Setting -Current $current) { return 'ok' }
    try {
        if (-not (Test-Path $Setting.Path)) { New-Item -Path $Setting.Path -Force | Out-Null }
        New-ItemProperty -Path $Setting.Path -Name $Setting.Name `
            -Value (Get-DesiredValue $Setting) -PropertyType $Setting.Type -Force | Out-Null
        return 'fixed'
    } catch {
        Write-GuardLog "Could not write $($Setting.Id) ($($Setting.Name)): $($_.Exception.Message)" 'ERROR'
        return 'failed'
    }
}

function Remove-SettingValue {
    param([Parameter(Mandatory)]$Setting)
    try {
        if (Test-Path $Setting.Path) {
            $existing = Get-CurrentValue $Setting
            if ($null -ne $existing) {
                Remove-ItemProperty -Path $Setting.Path -Name $Setting.Name -Force -ErrorAction Stop
                return $true
            }
        }
    } catch {
        Write-GuardLog "Could not remove $($Setting.Name): $($_.Exception.Message)" 'WARN'
    }
    return $false
}

#endregion

#region ------------------------------------------------------- orchestrator tasks

function Get-SchedTaskState {
    <#
    .SYNOPSIS
        State of a scheduled task as 'enabled', 'disabled' or 'absent'.
    .NOTES
        Deliberately never parses schtasks console output: the status word is
        localised (Ready / Bereit / and so on). Get-ScheduledTask returns a real
        enum, and the /XML fallback gives an <Enabled> element - both are the
        same in every language.
    #>
    param([Parameter(Mandatory)][string]$TaskPath)

    $leaf = Split-Path $TaskPath -Leaf
    $dir  = (Split-Path $TaskPath -Parent).TrimEnd('\') + '\'
    try {
        $task = Get-ScheduledTask -TaskName $leaf -TaskPath $dir -ErrorAction Stop
        if ($task.State -eq 'Disabled') { return 'disabled' }
        return 'enabled'
    } catch {
        Write-GuardLog "Get-ScheduledTask unavailable for $leaf, falling back to schtasks." 'INFO'
    }

    $query = Invoke-Native -File 'schtasks.exe' -Arguments @('/Query', '/TN', $TaskPath, '/XML', 'ONE')
    if ($query.ExitCode -ne 0) { return 'absent' }
    try {
        $doc = [xml]$query.Output
        if ($doc.Task.Settings.Enabled -eq 'false') { return 'disabled' }
        return 'enabled'
    } catch {
        return 'unknown'
    }
}

function Set-SchedTaskEnabled {
    <#
    .SYNOPSIS
        Best-effort enable/disable of one orchestrator task.
    .NOTES
        Several UpdateOrchestrator tasks are ACL'd to SYSTEM/TrustedInstaller and
        refuse even an elevated administrator. That returns 'denied' and is shown
        in the report rather than being swallowed - a status screen that lies is
        worse than one that admits a gap.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][ValidateSet('enable', 'disable')][string]$Action
    )

    $state = Get-SchedTaskState -TaskPath $TaskPath
    if ($state -eq 'absent') { return 'absent' }
    $want = if ($Action -eq 'disable') { 'disabled' } else { 'enabled' }
    if ($state -eq $want) { return 'ok' }

    $leaf = Split-Path $TaskPath -Leaf
    $dir  = (Split-Path $TaskPath -Parent).TrimEnd('\') + '\'
    try {
        if ($Action -eq 'disable') {
            Disable-ScheduledTask -TaskName $leaf -TaskPath $dir -ErrorAction Stop | Out-Null
        } else {
            Enable-ScheduledTask -TaskName $leaf -TaskPath $dir -ErrorAction Stop | Out-Null
        }
        return 'fixed'
    } catch {
        $flag = if ($Action -eq 'disable') { '/DISABLE' } else { '/ENABLE' }
        $change = Invoke-Native -File 'schtasks.exe' -Arguments @('/Change', '/TN', $TaskPath, $flag)
        if ($change.ExitCode -eq 0) { return 'fixed' }
        Write-GuardLog "Task $leaf refused to be $($Action)d (ACL protected)." 'WARN'
        return 'denied'
    }
}

#endregion

#region ---------------------------------------------------------- the watchdog

function Get-WatchdogXml {
    param([Parameter(Mandatory)][string]$ScriptPath)
    $ps  = "$($script:SystemRoot)\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arg = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" enforce"
    @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>WSTFU</Author>
    <Description>Re-applies the WSTFU update policy and heals its own task.</Description>
    <URI>\$($script:TaskName)</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT1M</Delay>
    </BootTrigger>
    <TimeTrigger>
      <StartBoundary>2020-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT10M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$ps</Command>
      <Arguments>$arg</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

function Test-WatchdogPresent {
    $query = Invoke-Native -File 'schtasks.exe' -Arguments @('/Query', '/TN', $script:TaskName)
    return ($query.ExitCode -eq 0)
}

function Install-Watchdog {
    $xmlPath = Join-Path $env:TEMP "wstfu-task-$PID.xml"
    try {
        Get-WatchdogXml -ScriptPath $script:InstalledPs | Set-Content -Path $xmlPath -Encoding Unicode
        $create = Invoke-Native -File 'schtasks.exe' -Arguments @('/Create', '/TN', $script:TaskName, '/XML', $xmlPath, '/F')
        if ($create.ExitCode -ne 0) { throw $create.Output }
        return $true
    } catch {
        Write-GuardLog "Watchdog registration failed: $($_.Exception.Message)" 'ERROR'
        return $false
    } finally {
        Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-Watchdog {
    $delete = Invoke-Native -File 'schtasks.exe' -Arguments @('/Delete', '/TN', $script:TaskName, '/F')
    return ($delete.ExitCode -eq 0)
}

#endregion

#region --------------------------------------------------------- config & state

function Get-Config {
    $default = [pscustomobject]@{
        level       = 3
        version     = $script:Version
        installedAt = $null
        windowUntil = $null
    }
    if (-not (Test-Path $script:ConfigPath)) { return $default }
    try {
        $raw = Get-Content $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($k in 'level', 'version', 'installedAt', 'windowUntil') {
            if ($raw.PSObject.Properties.Name -contains $k) { $default.$k = $raw.$k }
        }
        if ($default.level -lt 1 -or $default.level -gt 3) { $default.level = 3 }
    } catch {
        Write-GuardLog 'config.json unreadable, falling back to level 3.' 'WARN'
    }
    return $default
}

function Save-Config {
    param([Parameter(Mandatory)]$Config)
    if (-not (Test-Path $script:HomeDir)) {
        New-Item -ItemType Directory -Path $script:HomeDir -Force | Out-Null
    }
    $Config | ConvertTo-Json -Depth 4 | Set-Content -Path $script:ConfigPath -Encoding UTF8
}

function Get-GuardState {
    $default = [pscustomobject]@{
        lastEnforce      = $null
        lastCorrection   = $null
        totalCorrections = 0
        lastFixedIds     = @()
    }
    if (-not (Test-Path $script:StatePath)) { return $default }
    try {
        $raw = Get-Content $script:StatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($k in 'lastEnforce', 'lastCorrection', 'totalCorrections', 'lastFixedIds') {
            if ($raw.PSObject.Properties.Name -contains $k) { $default.$k = $raw.$k }
        }
    } catch {
        Write-GuardLog 'state.json unreadable, starting a fresh one.' 'WARN'
    }
    return $default
}

function Save-GuardState {
    param([Parameter(Mandatory)]$State)
    try {
        if (-not (Test-Path $script:HomeDir)) {
            New-Item -ItemType Directory -Path $script:HomeDir -Force | Out-Null
        }
        $State | ConvertTo-Json -Depth 4 | Set-Content -Path $script:StatePath -Encoding UTF8
    } catch {
        Write-GuardLog "Could not save state.json: $($_.Exception.Message)" 'WARN'
    }
}

function ConvertFrom-Duration {
    <# '4h', '90m', '2d' -> TimeSpan. Bare number means hours. #>
    param([Parameter(Mandatory)][string]$Text)
    $t = $Text.Trim().ToLowerInvariant()
    if ($t -match '^(\d+(?:\.\d+)?)\s*([mhd]?)$') {
        $n = [double]$Matches[1]
        switch ($Matches[2]) {
            'm'     { return [timespan]::FromMinutes($n) }
            'd'     { return [timespan]::FromDays($n) }
            default { return [timespan]::FromHours($n) }
        }
    }
    throw "Cannot read duration '$Text'. Use forms like 30m, 4h, 2d."
}

function Test-WindowOpen {
    param($Config)
    if (-not $Config.windowUntil) { return $false }
    $until = $null
    try {
        $until = [datetime]::Parse($Config.windowUntil, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        Write-GuardLog "Unreadable window timestamp '$($Config.windowUntil)', treating the window as closed." 'WARN'
        return $false
    }
    return ((Get-Date) -lt $until)
}

#endregion

#region ------------------------------------------------------------ environment

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsEdition {
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $edition = if ($cv.PSObject.Properties.Name -contains 'EditionID') { $cv.EditionID } else { 'Unknown' }
        $build   = if ($cv.PSObject.Properties.Name -contains 'CurrentBuild') { $cv.CurrentBuild } else { '0' }
        # ProductName still says "Windows 10 Pro" on Windows 11 - Microsoft never
        # updated that value. The build number is the only honest source.
        $name    = Get-ProductNameFromBuild -Build $build
        return [pscustomobject]@{
            EditionId  = $edition
            Name       = $name
            Build      = $build
            IsHome     = ($edition -match '^Core')
        }
    } catch {
        return [pscustomobject]@{ EditionId = 'Unknown'; Name = 'Windows'; Build = '0'; IsHome = $false }
    }
}

function Test-ServiceHealthy {
    <# Pure classifier: does this start type look untouched by a blocker tool? #>
    param([Parameter(Mandatory)][string]$StartType, [Parameter(Mandatory)][string[]]$Expected)
    return ($Expected -contains $StartType)
}

function Get-UpdateServiceState {
    $rows = @()
    foreach ($svc in $script:WatchedServices) {
        try {
            $s = Get-Service -Name $svc.Name -ErrorAction Stop
            $rows += [pscustomobject]@{
                Name      = $svc.Name
                Status    = [string]$s.Status
                StartType = [string]$s.StartType
                Healthy   = (Test-ServiceHealthy -StartType ([string]$s.StartType) -Expected $svc.Expect)
                Note      = $svc.Note
            }
        } catch {
            $rows += [pscustomobject]@{
                Name = $svc.Name; Status = 'missing'; StartType = 'missing'
                Healthy = $false; Note = $svc.Note
            }
        }
    }
    return $rows
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    return $false
}

function Test-UninvitedReboot {
    <# Pure heuristic, kept separate so it can be unit-tested. #>
    param([Parameter(Mandatory)][int]$EventId, [string]$Message = '')
    if ($EventId -eq 6008) { return $true }
    if ($EventId -ne 1074) { return $false }
    return ($Message -match 'TrustedInstaller|UpdateOrchestrator|MoUsoCoreWorker|USOClient|wuauclt|svchost')
}

function Get-RebootHistory {
    param([int]$Max = 25)
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074, 6008 } -MaxEvents $Max -ErrorAction Stop
    } catch {
        return @()
    }
    $result = @()
    foreach ($e in $events) {
        $msg = ($e.Message -replace '\s+', ' ').Trim()
        $result += [pscustomobject]@{
            Time      = $e.TimeCreated
            Id        = $e.Id
            Uninvited = (Test-UninvitedReboot -EventId $e.Id -Message $msg)
            Message   = $msg
        }
    }
    return $result
}

#endregion

#region ------------------------------------------------------------- enforcement

function Invoke-Enforce {
    <#
    .SYNOPSIS
        One idempotent pass. Writes only what is actually wrong.
    #>
    $config    = Get-Config
    $inWindow  = Test-WindowOpen $config
    $effective = if ($inWindow) { 1 } else { $config.level }

    # A window that has run out closes itself on the next tick.
    if (-not $inWindow -and $config.windowUntil) {
        $config.windowUntil = $null
        Save-Config $config
        Write-GuardLog 'Maintenance window expired - full policy back in force.'
    }

    # While a window is open, anything above level 1 is lifted so updates can
    # actually install; reboot control stays on the whole time.
    if ($inWindow) {
        foreach ($s in (Get-WstfuPlan -Level 3 | Where-Object { $_.Level -gt 1 })) {
            $null = Remove-SettingValue $s
        }
    }

    $plan   = Get-WstfuPlan -Level $effective
    $fixed  = @()
    $failed = @()
    foreach ($s in $plan) {
        switch (Invoke-SettingApply $s) {
            'fixed'  { $fixed  += $s.Id }
            'failed' { $failed += $s.Id }
            default  { }
        }
    }

    $tasksFixed  = @()
    $tasksDenied = @()
    foreach ($t in $script:RebootTasks) {
        $action = if ($inWindow) { 'enable' } else { 'disable' }
        switch (Set-SchedTaskEnabled -TaskPath $t -Action $action) {
            'fixed'  { $tasksFixed  += $t }
            'denied' { $tasksDenied += $t }
            default  { }
        }
    }

    # Self-healing: if the watchdog task went missing, put it back.
    $healed = $false
    if ((Test-Path $script:InstalledPs) -and -not (Test-WatchdogPresent)) {
        $healed = Install-Watchdog
        if ($healed) { Write-GuardLog 'Watchdog task was missing - recreated.' 'WARN' }
    }

    $state = Get-GuardState
    $state.lastEnforce = (Get-Date).ToString('s')
    if ($fixed.Count -or $tasksFixed.Count -or $healed) {
        $state.lastCorrection   = $state.lastEnforce
        $state.totalCorrections = [int]$state.totalCorrections + $fixed.Count + $tasksFixed.Count
        $state.lastFixedIds     = $fixed
        Write-GuardLog ("Corrected {0} setting(s) [{1}]{2}{3}." -f `
            $fixed.Count, ($fixed -join ','), `
            $(if ($tasksFixed.Count) { ", $($tasksFixed.Count) task(s)" } else { '' }), `
            $(if ($healed) { ', watchdog recreated' } else { '' }))
    }
    if ($failed.Count) { Write-GuardLog "Could not apply: $($failed -join ',')" 'WARN' }
    Save-GuardState $state

    return [pscustomobject]@{
        Level       = $effective
        InWindow    = $inWindow
        Fixed       = $fixed
        Failed      = $failed
        TasksFixed  = $tasksFixed
        TasksDenied = $tasksDenied
        Healed      = $healed
    }
}

#endregion

#region ----------------------------------------------------------- the commands

function Show-Banner {
    Write-Out ''
    Write-Out '  WSTFU  -  Windows, Shut The F**k Up' 'Cyan'
    Write-Out "  v$($script:Version)  |  your machine reboots when you say so" 'DarkGray'
    Write-Out ''
}

function Show-LevelGuide {
    Write-Out '  1  mute   - reboot control only' 'White'
    Write-Out '             Updates download and install exactly as they do now, but nothing'
    Write-Out '             restarts the machine except you.'
    Write-Out '             + machine stays fully patched, smallest possible change'
    Write-Out '             - a pending restart nags forever and installs land whenever they land' 'DarkGray'
    Write-Out ''
    Write-Out '  2  quiet  - mute + version pin + 30-day quality deferral' 'White'
    Write-Out '             Monthly patches arrive 30 days late, feature updates never arrive'
    Write-Out '             on their own. You install them on a day that suits you.'
    Write-Out '             + patched within a month, no surprise feature upgrades'
    Write-Out '             - a fix for an actively exploited hole also waits 30 days' 'DarkGray'
    Write-Out ''
    Write-Out '  3  stfu   - quiet + rolling pause  [default]' 'White'
    Write-Out '             The watchdog keeps re-stamping the pause mechanism Microsoft ships, so'
    Write-Out '             nothing arrives at all until you run: wstfu window 4h'
    Write-Out '             + total silence, fully reversible, uses a supported mechanism'
    Write-Out '             - the machine stops receiving security fixes until you open a window;' 'DarkGray'
    Write-Out '               sane for a local workstation off the public network, not for a laptop' 'DarkGray'
    Write-Out '               that lives in cafes' 'DarkGray'
    Write-Out ''
}

function Read-LevelChoice {
    Write-Out 'Pick a noise level:' 'Yellow'
    Write-Out ''
    Show-LevelGuide
    $answer = Read-Host 'Level [3]'
    if ([string]::IsNullOrWhiteSpace($answer)) { return 3 }
    if ($answer -match '^[123]$') { return [int]$answer }
    Write-Out 'Not a level. Using 3.' 'DarkYellow'
    return 3
}

function Show-Status {
    Show-Banner

    $edition = Get-WindowsEdition
    Write-Out "  System    : $($edition.Name) $($edition.EditionId), build $($edition.Build)"
    if ($edition.IsHome) {
        Write-Out '  WARNING   : Home edition. Windows ignores these Group Policy keys here.' 'Red'
        Write-Out '              Pro, Enterprise, Education or IoT LTSC required.' 'Red'
    }

    $config   = Get-Config
    $inWindow = Test-WindowOpen $config
    $installed = Test-Path $script:InstalledPs
    Write-Out ("  Installed : {0}" -f $(if ($installed) { "yes  ($($script:HomeDir))" } else { 'no' }))
    Write-Out ("  Level     : {0}  ({1})" -f $config.level, $script:LevelNames[[int]$config.level])
    if ($inWindow) {
        Write-Out "  Window    : OPEN until $($config.windowUntil) - updates allowed, reboots still yours" 'Yellow'
    }

    $wd = Test-WatchdogPresent
    Write-Out ("  Watchdog  : {0}" -f $(if ($wd) { 'registered (SYSTEM, boot + every 10 min)' } else { 'NOT REGISTERED' })) `
        $(if ($wd) { 'Gray' } else { 'Red' })

    $state = Get-GuardState
    if ($state.lastEnforce) {
        Write-Out "  Last pass : $($state.lastEnforce)   corrections so far: $($state.totalCorrections)"
    }
    Write-Out ("  Pending   : {0}" -f $(if (Test-PendingReboot) { 'a restart is pending - install and reboot on your terms' } else { 'nothing pending' }))
    Write-Out ''

    # --- settings table
    $effective = if ($inWindow) { 1 } else { [int]$config.level }
    $plan = Get-WstfuPlan -Level $effective
    Write-Out '  SETTINGS' 'White'
    $bad = 0
    foreach ($s in $plan) {
        $current = Get-CurrentValue $s
        $ok = Test-SettingSatisfied -Setting $s -Current $current
        if (-not $ok) { $bad++ }
        $mark  = if ($ok) { 'OK   ' } else { 'DRIFT' }
        $color = if ($ok) { 'Green' } else { 'Yellow' }
        $shown = if ($null -eq $current) { '<unset>' } else { [string]$current }
        if ($shown.Length -gt 22) { $shown = $shown.Substring(0, 22) }
        Write-Out ("    [{0}] {1}  {2,-34} = {3}" -f $mark, $s.Id, $s.Name, $shown) $color
    }
    Write-Out ''

    # --- update services (never written to, only reported)
    Write-Out '  UPDATE SERVICES (not touched by WSTFU - shown so you can see if they are)' 'White'
    foreach ($svc in (Get-UpdateServiceState)) {
        $flag  = if ($svc.Healthy) { 'ok      ' } else { 'ALTERED ' }
        $color = if ($svc.Healthy) { 'Green' } else { 'Red' }
        Write-Out ("    [{0}] {1,-13} {2,-9} start={3,-9} {4}" -f `
            $flag, $svc.Name, $svc.Status, $svc.StartType, $svc.Note) $color
    }
    if (@(Get-UpdateServiceState | Where-Object { -not $_.Healthy }).Count) {
        Write-Out '    Something disabled an update service - WSTFU never does that. Usually a' 'Red'
        Write-Out '    blocker tool. Updates there are broken, not managed; expect manual installs' 'Red'
        Write-Out '    to fail until the service is set back to Manual.' 'Red'
    }
    Write-Out ''

    # --- orchestrator tasks
    $elevated = Test-Admin
    Write-Out '  ORCHESTRATOR REBOOT TASKS' 'White'
    foreach ($t in $script:RebootTasks) {
        $st = Get-SchedTaskState -TaskPath $t
        # Without elevation the UpdateOrchestrator folder is not even readable,
        # so 'absent' would be a lie. Say what we actually know.
        if (-not $elevated -and $st -eq 'absent') { $st = 'unreadable' }
        $color = switch ($st) {
            'disabled'   { 'Green' }
            'absent'     { 'DarkGray' }
            'unreadable' { 'DarkGray' }
            default      { 'Yellow' }
        }
        Write-Out ("    [{0,-10}] {1}" -f $st, $t.Split('\')[-1]) $color
    }
    if (-not $elevated) {
        Write-Out '    Not elevated: this folder is ACL protected, so these readings are blind.' 'DarkYellow'
        Write-Out '    Run from an elevated PowerShell for the real state.' 'DarkYellow'
    } else {
        Write-Out '    (some of these refuse even an elevated admin - expected on Windows 11;' 'DarkGray'
        Write-Out '     the registry policy is what carries the load)' 'DarkGray'
    }
    Write-Out ''

    # --- the number that actually matters
    $history = Get-RebootHistory
    $lastUninvited = $history | Where-Object { $_.Uninvited } | Select-Object -First 1
    Write-Out '  REBOOT HISTORY' 'White'
    if ($lastUninvited) {
        $days = [int]((Get-Date) - $lastUninvited.Time).TotalDays
        Write-Out "    Days since Windows rebooted this PC without asking: $days" 'Cyan'
        Write-Out "    (last one: $($lastUninvited.Time))" 'DarkGray'
    } elseif ($history.Count) {
        Write-Out '    No uninvited reboot found in the recent System log. Good.' 'Cyan'
    } else {
        Write-Out '    System log unreadable from this session (run elevated for full history).' 'DarkGray'
    }
    foreach ($h in ($history | Select-Object -First 5)) {
        $tag = if ($h.Uninvited) { 'THEM' } else { 'you ' }
        $msg = if ($h.Message.Length -gt 90) { $h.Message.Substring(0, 90) } else { $h.Message }
        Write-Out ("    [{0}] {1:yyyy-MM-dd HH:mm}  {2}" -f $tag, $h.Time, $msg) `
            $(if ($h.Uninvited) { 'Yellow' } else { 'DarkGray' })
    }
    Write-Out ''

    if ($bad -gt 0 -and $installed) {
        Write-Out "  $bad setting(s) drifted. The watchdog fixes that within 10 minutes," 'Yellow'
        Write-Out '  or run:  wstfu enforce' 'Yellow'
    }
    if (-not $installed) {
        Write-Out '  Nothing is installed yet. To apply:  .\wstfu.ps1 shutup' 'White'
    }
    Write-Out ''
}

function Invoke-Shutup {
    param([int]$ChosenLevel, [switch]$NoPrompt)

    Show-Banner
    if (-not (Test-Admin)) {
        Write-Out '  Run this from an elevated PowerShell (Run as administrator).' 'Red'
        Write-Out ''
        exit 1
    }

    $edition = Get-WindowsEdition
    if ($edition.IsHome) {
        Write-Out '  WARNING: Windows Home detected.' 'Red'
        Write-Out '  Home ignores the Group Policy keys this tool writes. It will install and' 'Red'
        Write-Out '  look fine, but Windows will keep doing whatever it wants. Pro / Enterprise /' 'Red'
        Write-Out '  Education / IoT LTSC are the supported editions.' 'Red'
        Write-Out ''
        if (-not $NoPrompt) {
            $go = Read-Host 'Continue anyway? [y/N]'
            if ($go -notmatch '^(y|yes)$') { Write-Out 'Nothing changed.' ; exit 0 }
        }
    }

    if ($ChosenLevel -lt 1) {
        $ChosenLevel = if ($NoPrompt) { 3 } else { Read-LevelChoice }
    }

    Write-Out ''
    Write-Out "  Applying level $ChosenLevel ($($script:LevelNames[$ChosenLevel]))..." 'White'

    if (-not (Test-Path $script:HomeDir)) {
        New-Item -ItemType Directory -Path $script:HomeDir -Force | Out-Null
    }
    $me = $PSCommandPath
    if ($me -and ((Resolve-Path $me).Path -ne $script:InstalledPs)) {
        Copy-Item -Path $me -Destination $script:InstalledPs -Force
    }
    # SYSTEM and administrators own it; users may read but not rewrite the script
    # the watchdog executes.
    $acl = Invoke-Native -File 'icacls.exe' -Arguments @(
        $script:HomeDir, '/inheritance:r', '/grant:r',
        'SYSTEM:(OI)(CI)F', 'Administrators:(OI)(CI)F', 'Users:(OI)(CI)RX')
    if ($acl.ExitCode -ne 0) { Write-GuardLog "icacls hardening failed: $($acl.Output)" 'WARN' }

    $config = Get-Config
    $config.level       = $ChosenLevel
    $config.version     = $script:Version
    $config.installedAt = (Get-Date).ToString('s')
    $config.windowUntil = $null
    Save-Config $config

    $result = Invoke-Enforce
    $ok = Install-Watchdog
    $null = Invoke-Native -File 'gpupdate.exe' -Arguments @('/force')

    Write-Out ''
    Write-Out "  Applied   : $($result.Fixed.Count) setting(s) written, $($result.Failed.Count) refused" 'Green'
    Write-Out ("  Watchdog  : {0}" -f $(if ($ok) { 'registered - SYSTEM, at boot and every 10 minutes' } else { 'FAILED to register, see the log' })) `
        $(if ($ok) { 'Green' } else { 'Red' })
    if ($result.TasksDenied.Count) {
        Write-Out "  Note      : $($result.TasksDenied.Count) orchestrator task(s) refused to be disabled (ACL protected)." 'DarkYellow'
        Write-Out '              Expected on Windows 11. The registry policy still applies.' 'DarkGray'
    }
    Write-Out ''
    Write-Out '  Check it        :  .\wstfu.ps1 status' 'White'
    Write-Out '  Update on your terms:  .\wstfu.ps1 window 4h' 'White'
    Write-Out '  Undo everything :  .\wstfu.ps1 speak' 'DarkGray'
    Write-Out ''
    Write-GuardLog "Installed at level $ChosenLevel."
}

function Invoke-Window {
    param([string]$Duration)

    Show-Banner
    if (-not (Test-Admin)) { Write-Out '  Needs an elevated PowerShell.' 'Red'; exit 1 }

    $span = ConvertFrom-Duration $Duration
    $config = Get-Config
    $config.windowUntil = ((Get-Date) + $span).ToString('s')
    Save-Config $config

    $null = Invoke-Enforce

    Write-Out "  Maintenance window open until $($config.windowUntil)." 'Yellow'
    Write-Out '  Pause and deferrals are lifted. Reboot control stays on - Windows still' 'Gray'
    Write-Out '  cannot restart this machine on its own.' 'Gray'
    Write-Out ''
    Write-Out '  Install now:  Settings > Windows Update > Check for updates' 'White'
    Write-Out '           or:  UsoClient StartScan ; UsoClient StartInstall' 'White'
    Write-Out '  Then reboot yourself, whenever suits you.' 'White'
    Write-Out ''
    Write-Out '  The window closes on its own; close it early with:  .\wstfu.ps1 close' 'DarkGray'
    Write-Out ''
    Write-GuardLog "Maintenance window opened until $($config.windowUntil)."
}

function Invoke-CloseWindow {
    Show-Banner
    if (-not (Test-Admin)) { Write-Out '  Needs an elevated PowerShell.' 'Red'; exit 1 }
    $config = Get-Config
    $config.windowUntil = $null
    Save-Config $config
    $result = Invoke-Enforce
    Write-Out "  Window closed. Level $($result.Level) back in force, $($result.Fixed.Count) setting(s) re-applied." 'Green'
    Write-Out ''
    Write-GuardLog 'Maintenance window closed manually.'
}

function Invoke-Speak {
    Show-Banner
    if (-not (Test-Admin)) { Write-Out '  Needs an elevated PowerShell.' 'Red'; exit 1 }

    Write-Out '  Reverting everything to Microsoft defaults...' 'White'
    Write-GuardLog '=== speak: full revert ==='

    $null = Uninstall-Watchdog

    $removed = 0
    foreach ($s in (Get-WstfuPlan -Level 3)) {
        if (Remove-SettingValue $s) { $removed++ }
    }
    foreach ($t in $script:RebootTasks) {
        $null = Set-SchedTaskEnabled -TaskPath $t -Action 'enable'
    }

    $config = Get-Config
    $config.windowUntil = $null
    Save-Config $config

    $null = Invoke-Native -File 'gpupdate.exe' -Arguments @('/force')

    Write-Out ''
    Write-Out "  Removed $removed registry value(s), re-enabled the orchestrator tasks," 'Green'
    Write-Out '  and deleted the watchdog. Windows is back in charge of your reboots.' 'Green'
    Write-Out ''
    Write-Out "  Logs and config are left in $($script:HomeDir) - delete the folder by hand" 'DarkGray'
    Write-Out '  if you want no trace at all.' 'DarkGray'
    Write-Out ''
    Write-GuardLog "Revert complete, $removed value(s) removed."
}

function Show-Help {
    Show-Banner
    Write-Out '  USAGE' 'White'
    Write-Out '    .\wstfu.ps1 status              read-only report (default, safe)'
    Write-Out '    .\wstfu.ps1 shutup              pick a level, apply it, install the watchdog'
    Write-Out '    .\wstfu.ps1 shutup -Level 3     same, no prompt'
    Write-Out '    .\wstfu.ps1 window 4h           let updates in for a while; reboots stay yours'
    Write-Out '    .\wstfu.ps1 close               close that window now'
    Write-Out '    .\wstfu.ps1 speak               undo everything, Microsoft defaults'
    Write-Out '    .\wstfu.ps1 enforce             one silent pass (what the watchdog runs)'
    Write-Out ''
    Write-Out '  LEVELS' 'White'
    Write-Out ''
    Show-LevelGuide
}

#endregion

#region ------------------------------------------------------------ entry point

function Invoke-Main {
    switch ($Command) {
        'status'  { Show-Status }
        'help'    { Show-Help }
        'shutup'  { Invoke-Shutup -ChosenLevel $Level -NoPrompt:$Yes }
        'window'  { Invoke-Window -Duration $For }
        'close'   { Invoke-CloseWindow }
        'speak'   { Invoke-Speak }
        'enforce' { $null = Invoke-Enforce }
    }
}

if (-not $NoExecute) {
    if ($Level -lt 0 -or $Level -gt 3) { throw 'Level must be 1, 2 or 3.' }
    # 'wstfu.ps1 window 4h' should work as well as 'wstfu.ps1 window -For 4h'
    if ($Command -eq 'window' -and $args.Count -ge 1 -and $For -eq '4h') { $For = [string]$args[0] }
    Invoke-Main
}

#endregion
