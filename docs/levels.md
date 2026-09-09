# Noise levels: what each one actually does

Three levels, chosen when you run `shutup`, stored in
`C:\ProgramData\WSTFU\config.json`. Each level is a strict superset of the one
below it, so level 3 contains everything in levels 1 and 2.

**Reboot control is never switched off.** Level 1 is always in force - including
inside a maintenance window, and including while the pause is lifted. Everything
above level 1 is about *when updates are allowed to arrive*, not about who is
allowed to restart your machine. Nobody but you is, ever.

Every value below is written to one of three keys and removed again by
`wstfu.ps1 speak`:

```
WU  = HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
AU  = HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
UX  = HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings
```

The **confidence** column is not decoration:

| Confidence | Meaning |
|---|---|
| `high` | A documented Windows Update for Business or Group Policy setting that modern Windows 10/11 honours. The guarantees rest on these. |
| `medium` | Works in practice but is undocumented, version-dependent, or only affects the UI. Useful, not load-bearing. |
| `legacy` | Windows 10 1803+ and Windows 11 largely ignore it, because updates are delivered by the Update Session Orchestrator rather than the old Automatic Updates client. Written anyway - it costs nothing and still applies on LTSC. Nothing depends on it. |

---

## Level 1 - `mute`

**Reboot control only.** Updates download and install exactly as they do today.
The single thing that changes is that the machine stops restarting itself.

| Id | Key | Value | What Windows does with it | Confidence |
|----|-----|-------|---------------------------|------------|
| M01 | `AU\NoAutoRebootWithLoggedOnUsers` | `1` | No automatic restart while a user is signed in. The core setting. | high |
| M02 | `AU\AlwaysAutoRebootAtScheduledTime` | `0` | Kills the forced restart countdown that appears after an install. | medium |
| M03 | `WU\SetAutoRestartNotificationDisable` | `1` | Turns off auto-restart notifications, so nothing nags a restart into happening. | high |
| M04 | `WU\SetAutoRestartNotificationDisable2` | `1` | Same thing on builds where Microsoft renamed the value. | medium |
| M05 | `UX\RestartNotificationsAllowed2` | `0` | Removes the "restart now" push inside the update UX. | medium |
| M06 | `UX\SmartActiveHoursState` | `0` | Stops Windows choosing active hours for you, so the range below sticks. | high |
| M07 | `WU\SetActiveHours` | `1` | Enables the active-hours policy. | high |
| M08 | `WU\ActiveHoursStart` | `5` | Start of active hours. | high |
| M09 | `WU\ActiveHoursEnd` | `23` | End of active hours. Windows caps the span at **18 hours**, so 05:00-23:00 is the widest window it will accept. 24/7 through active hours is not possible - M01 to M05 are what cover the rest of the day. | high |

Plus the Update Orchestrator reboot tasks, disabled where Windows permits it
(see [below](#orchestrator-reboot-tasks)).

**What you will see:** updates install as usual, and the machine sits there with
a pending restart until you restart it. No countdown, no "we'll restart outside
active hours", no morning surprise.

**What this level does not do:** updates still download and install on
Microsoft's schedule, so a feature update can still be installed - it will wait
for you to restart, but it *is* installed. If you want a say in what gets
installed at all, you want level 2.

---

## Level 2 - `quiet`

Everything in `mute`, plus control over *when* updates arrive. This is the level
that addresses the actual cause of surprise reboots: the monthly quality update.

| Id | Key | Value | What Windows does with it | Confidence |
|----|-----|-------|---------------------------|------------|
| Q01 | `WU\TargetReleaseVersion` | `1` | Enables the feature-update version pin. | high |
| Q02 | `WU\TargetReleaseVersionInfo` | current release (e.g. `25H2`) | Pins the machine to the release it is on now. Feature updates are the ones that reboot you hardest. | high |
| Q03 | `WU\ProductVersion` | `Windows 11` / `Windows 10` | Tells the pin which product line to stay on. Read from the build number, not from `ProductName` - that value still says "Windows 10 Pro" on Windows 11. | high |
| Q04 | `WU\DeferFeatureUpdates` | `1` | Enables feature-update deferral alongside the pin. | high |
| Q05 | `WU\DeferFeatureUpdatesPeriodInDays` | `365` | Maximum deferral Microsoft allows. | high |
| Q06 | `WU\DeferQualityUpdates` | `1` | Enables quality-update deferral. | high |
| Q07 | `WU\DeferQualityUpdatesPeriodInDays` | `30` | Monthly patches land 30 days late. 30 is the documented maximum. **This is the setting that stops the fortnightly reboot.** | high |
| Q08 | `UX\IsContinuousInnovationOptedIn` | `0` | Turns off "get the latest updates as soon as they're available". | high |
| Q09 | `AU\NoAutoUpdate` | `0` | Explicitly *not* disabled - we control timing, we do not amputate the service. | legacy |
| Q10 | `AU\AUOptions` | `2` | Classic "notify, don't install". | legacy |
| Q11 | `AU\AutoInstallMinorUpdates` | `0` | Legacy companion to Q10. | legacy |

**What you will see:** Windows Update goes quiet for a month at a time. When a
patch does arrive, it installs - and then waits for you, because level 1 is still
in force.

**The catch worth knowing:** a version pin holds only while your release is still
serviced. When the release reaches end of service, Microsoft will push the
upgrade regardless of the pin. Check the lifecycle date for the release in Q02
once a year; upgrading on purpose beats being upgraded.

---

## Level 3 - `stfu` (default)

Everything in `quiet`, plus a rolling pause. Nothing arrives at all until you
open a maintenance window.

### The mechanism

Windows has a built-in pause. You give it a *start* timestamp and it stops
delivering updates for 35 days from that moment. The Settings app exposes it as a
slider capped at 35 days; the policy keys accept any timestamp.

WSTFU sets the start timestamp and the watchdog re-stamps it whenever it is more
than **7 days** old. The pause is therefore always somewhere between 28 and 35
days from expiring, and it never actually runs out. Re-stamping weekly rather
than every 10 minutes keeps registry writes down and avoids poking the update
stack more than necessary.

This is Microsoft's own mechanism, used the way it was built, which is why it is
completely reversible and does not break anything. It is a *pause*, not a block.

| Id | Key | Value | What Windows does with it | Confidence |
|----|-----|-------|---------------------------|------------|
| S01 | `WU\PauseQualityUpdatesStartTime` | now (UTC, ISO 8601) | Policy-level quality pause, 35 days from this stamp. Re-stamped weekly. | high |
| S02 | `WU\PauseFeatureUpdatesStartTime` | now | Same for feature updates. | high |
| S03 | `UX\PauseQualityUpdatesStartTime` | now | Mirrors the pause into the Settings UI so it reports the truth. | medium |
| S04 | `UX\PauseQualityUpdatesEndTime` | now + 35d | End of the mirrored quality pause. | medium |
| S05 | `UX\PauseFeatureUpdatesStartTime` | now | Mirror for feature updates. | medium |
| S06 | `UX\PauseFeatureUpdatesEndTime` | now + 35d | End of the mirrored feature pause. | medium |
| S07 | `UX\PauseUpdatesExpiryTime` | now + 35d | The date the Settings app shows as "paused until". | medium |
| S08 | `UX\FlightSettingsMaxPauseDays` | `3650` | Lets the UI accept a pause longer than its built-in 35-day slider. | medium |

**What you will see:** Settings shows updates paused. Nothing downloads, nothing
installs, nothing asks. `status` shows the pause date moving forward once a week.

**The honest caveat:** a rolling pause is not a documented Microsoft feature - the
documented behaviour is that after a pause period ends you must install available
updates before pausing again. Re-stamping the start time is what sidesteps that,
and how long Microsoft keeps letting it work is a question only time answers.
That is exactly what the `Days since Windows rebooted this PC without asking`
counter in `status` is for. If the pause ever stops holding, level 2 is still
underneath it, and level 1 is still underneath that.

**The trade you are making:** the machine stops receiving security fixes until you
open a window. That is a reasonable trade for a workstation on a private network,
which is what this level was built for. It is not a reasonable trade for a laptop
that connects to networks you do not own.

---

## What no level does

These are deliberate omissions, not gaps. Tools that reach for them turn "managed
silence" into "broken Windows Update", and you find out at the worst moment.

- **Never disables a service.** `wuauserv`, `UsoSvc`, `WaaSMedicSvc`, `BITS` and
  `DoSvc` are left exactly as Windows configured them. `status` reports their
  state so you can see whether something *else* disabled them.
- **Never touches a service `ImagePath`.** Corrupting one is repaired by
  `sfc /scannow` and breaks installs when you eventually want them.
- **Never uses Image File Execution Options** to block `UsoClient.exe`,
  `MusNotification.exe` and friends from launching.
- **Never kills processes.**
- **Never disables `Schedule Scan`.** Disabling it would break your own manual
  update checks - the opposite of the goal.
- **Never locks out an administrator.** You can undo all of it with `speak`, or
  by hand, at any time.

---

## Orchestrator reboot tasks

Disabled at every level, on a best-effort basis:

| Task | Why it is on the list |
|------|----------------------|
| `UpdateOrchestrator\Reboot` | Direct reboot trigger. |
| `UpdateOrchestrator\Reboot_AC` | Reboot trigger while on mains power. |
| `UpdateOrchestrator\Reboot_Battery` | Reboot trigger while on battery. |
| `UpdateOrchestrator\USO_UxBroker_ReadyToReboot` | Fires the "ready to restart" flow. |
| `UpdateOrchestrator\USO_UxBroker_Display` | Displays the restart prompts that lead there. |

`status` reports one of four states per task, and never pretends:

| State | Meaning |
|-------|---------|
| `disabled` | Done. |
| `denied` | The task exists but is ACL'd to SYSTEM/TrustedInstaller and refuses even an elevated administrator. Expected on Windows 11. The registry policy carries the load. |
| `absent` | The task does not exist on this build. |
| `unreadable` | You are not running elevated, so the folder cannot be read at all. Not the same as "absent" - re-run elevated. |

---

## The maintenance window

`wstfu.ps1 window 4h` temporarily drops to level 1 behaviour:

- pause and deferral values are removed, so updates can actually arrive;
- the orchestrator tasks are re-enabled, so an install can complete cleanly;
- **level 1 stays in force** - Windows still cannot restart the machine;
- when the window expires, the next watchdog pass restores your full level.

Install what you want, restart when it suits you, and either run
`wstfu.ps1 close` or just let the window run out.

---

## Verifying each level

```powershell
# everything at once, per setting, with its current value
.\wstfu.ps1 status

# level 1: no automatic restart
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' NoAutoRebootWithLoggedOnUsers

# level 2: deferral and pin
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' |
  Select-Object TargetReleaseVersionInfo, DeferQualityUpdatesPeriodInDays

# level 3: how far the rolling pause currently reaches
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' PauseUpdatesExpiryTime

# the only measurement that really counts
Get-WinEvent -FilterHashtable @{ LogName='System'; Id=1074,6008 } -MaxEvents 20 |
  Select-Object TimeCreated, Id, @{n='Msg';e={ $_.Message -replace "`r`n",' ' }} | Format-Table -Wrap
```
