<p align="center">
  <img src="assets/logo.svg" alt="WSTFU" width="180">
</p>

<h1 align="center">WSTFU</h1>
<p align="center"><b>Windows, Shut The F**k Up.</b><br>
Your machine reboots when <i>you</i> say so.</p>

<p align="center">
  <a href="../../actions/workflows/ci.yml"><img alt="CI" src="../../actions/workflows/ci.yml/badge.svg"></a>
  <img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE">
  <img alt="Windows 10 / 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-green">
</p>

---

## The problem

Windows is a good OS with one habit that makes it unusable as a workstation: every
week or two it decides, on its own, that now is a fine moment to restart. Editors
with unsaved work, long builds, a training run, a remote session - gone, because
Patch Tuesday landed and the Update Orchestrator got impatient.

Nothing is wrong with the machine. Nothing is wrong with the updates. The problem
is that **the reboot decision does not belong to the person using the computer**.

WSTFU takes that decision back, and keeps it - because a setting you flip by hand
gets quietly restored by the next update, and you find out the hard way.

## What it does

You pick a noise level. WSTFU applies it, then installs a **SYSTEM watchdog** that
re-checks everything at boot and every 10 minutes, writing back anything that
drifted and recreating its own scheduled task if that gets deleted.

| Level | Name | What it does | You get | You give up |
|:-----:|------|--------------|---------|-------------|
| 1 | `mute` | Reboot control only. Updates download and install as usual. | Machine stays fully patched. Smallest possible change to the system. | A pending restart follows you around; installs still land whenever they land. |
| 2 | `quiet` | `mute` + version pin + 30-day quality deferral + no restart nags. | Monthly patches arrive a month late, on a day you choose. No surprise feature upgrades. | A fix for something actively exploited also waits 30 days. |
| 3 | `stfu` **(default)** | `quiet` + a rolling pause the watchdog keeps re-stamping. | Total silence. Nothing arrives until you open a window. Fully reversible, and it uses Microsoft's own pause mechanism rather than breaking anything. | The machine stops receiving security fixes until you open a window. Sane for a workstation on a private network. Not for a laptop that lives in cafes. |

Whatever the level, **reboot control is always on**. That is the point of the tool;
the rest is about *when* updates are allowed to show up.

[docs/levels.md](docs/levels.md) breaks each level down setting by setting - what
is written, what Windows does with it, how much confidence it deserves, and what
no level does on purpose.

## Install

Requires **Windows 10 or 11, Pro / Enterprise / Education / IoT LTSC**, and an
elevated PowerShell. (Home ignores these Group Policy keys - see
[Honest limits](#honest-limits).)

```powershell
# look first - this changes nothing at all
.\wstfu.ps1 status

# then apply; it asks which level you want, level 3 is preselected
.\wstfu.ps1 shutup

# or skip the prompt
.\wstfu.ps1 shutup -Level 3 -Yes
```

Prefer double-clicking? `status.cmd`, `shutup.cmd` and `speak.cmd` do the same
three things and ask for elevation themselves.

## Commands

| Command | What happens |
|---------|--------------|
| `wstfu.ps1 status` | Read-only report: every setting, the orchestrator tasks, the watchdog, and your reboot history. Default command. Changes nothing. |
| `wstfu.ps1 shutup [-Level 1\|2\|3] [-Yes]` | Applies a level and installs the watchdog. |
| `wstfu.ps1 window 4h` | Opens a maintenance window: pause and deferrals lifted so you can install on purpose. Reboot control stays on. Closes itself when the time is up. |
| `wstfu.ps1 close` | Closes that window right now. |
| `wstfu.ps1 dashboard` | Open the control panel: a native window with live status, one-click level switching, the window, trust and revert, and an EN/RU switch. Needs elevation (it self-elevates). |
| `wstfu.ps1 trust` / `untrust` | Add / remove a Defender exclusion for the WSTFU folder. |
| `wstfu.ps1 speak` | Full revert to Microsoft defaults, watchdog removed. Also removes the Defender exclusion. |
| `wstfu.ps1 trust` | Add the WSTFU folder to Microsoft Defender's exclusions (stops file-based flags). Removed by `speak`. |
| `wstfu.ps1 report` | Show the weekly health summary as a toast right now. |
| `wstfu.ps1 dashboard` | Open the control panel window (native, no dependencies). |
| `wstfu.ps1 enforce` | One silent pass. This is what the watchdog runs. |

Durations are `30m`, `4h`, `2d`, or a bare number meaning hours.

## Updating on purpose

The whole point is that you still patch the machine - deliberately, at a moment
that suits you.

```powershell
.\wstfu.ps1 window 4h        # let updates in for four hours
# Settings > Windows Update > Check for updates
# or: UsoClient StartScan ; UsoClient StartInstall
# install what you want, then reboot yourself
.\wstfu.ps1 close            # or just let the window expire
```

During a window, Windows still cannot restart the machine on its own. It never can.

## What gets written

Everything lives in two policy trees and the update UX tree, and it is all
removed again by `speak`:

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings
```

Plus these Update Orchestrator tasks, disabled where Windows allows it:
`Reboot`, `Reboot_AC`, `Reboot_Battery`, `USO_UxBroker_ReadyToReboot`,
`USO_UxBroker_Display`.

`Schedule Scan` is deliberately left alone - disabling it would break your own
manual update checks too, which is the opposite of the goal.

`wstfu.ps1 status` prints every single value with its current state, so there is
nothing hidden. Each setting in the source carries a one-line `Why`.

## Verify it is working

```powershell
.\wstfu.ps1 status

# the watchdog task
schtasks /Query /TN WSTFU /V /FO LIST

# who has been rebooting this PC, and why
Get-WinEvent -FilterHashtable @{ LogName='System'; Id=1074,6008 } -MaxEvents 20 |
  Select-Object TimeCreated, Id, @{n='Msg';e={ $_.Message -replace "`r`n",' ' }} | Format-Table -Wrap

# the guard log
Get-Content C:\ProgramData\WSTFU\wstfu.log -Tail 40
```

`status` also prints the number this whole project exists for:

```
Days since Windows rebooted this PC without asking: 47
```

## Honest limits

Read this part. A tool in this space that promises more than it can deliver is
worse than no tool.

- **Nothing here is un-killable, and nothing should be.** A local administrator,
  `SYSTEM` and `TrustedInstaller` sit above every service in Windows by design.
  WSTFU defends against *automatic* reversion - an update, a servicing operation,
  a cleanup tool - by putting settings back within 10 minutes and recreating its
  own task. It does not lock you out of your own machine.
- **Windows Home is not supported.** Home ignores these Group Policy keys
  entirely. WSTFU warns and refuses to pretend otherwise.
- **Some orchestrator tasks refuse to be disabled.** They are ACL'd to
  SYSTEM/TrustedInstaller and will deny even an elevated administrator. This is
  expected on Windows 11; `status` reports it as `denied` instead of hiding it.
  The registry policy is what carries the load.
- **The Windows Update Medic Service (`WaaSMedicSvc`) exists to undo exactly this
  kind of change.** It is itself protected, and WSTFU does not fight it head-on -
  it simply re-applies faster than the medic can matter. If you see recurring
  corrections in the log, that is usually what you are looking at.
- **`AUOptions` and friends are legacy.** Windows 10 1803+ and Windows 11 mostly
  ignore the old `AU` keys, because updates come through the Update Session
  Orchestrator now. They are still written (they cost nothing and do apply on
  LTSC), but they are flagged `legacy` in the source and none of the guarantees
  rest on them.
- **Active hours cannot cover 24 hours.** Windows caps the span at 18 hours, so
  WSTFU uses 05:00-23:00 and lets the reboot policies do the real work.
- **Domain Group Policy wins.** On a domain-joined machine, policy from the domain
  can overwrite local values on every refresh. Out of scope.
- **Defender Tamper Protection is a different mechanism.** It does not affect
  these settings; do not go looking for a connection.
- **Level 3 means an unpatched machine.** That is a deliberate, reversible trade
  for a workstation off the public network. If that is not your situation, use
  level 1 or 2.

## Uninstall

```powershell
.\wstfu.ps1 speak
```

Removes every value it wrote, re-enables the orchestrator tasks, deletes the
watchdog task, and runs `gpupdate /force`. The log and config in
`C:\ProgramData\WSTFU` are left behind on purpose - delete the folder by hand if
you want no trace at all.

## Files it creates

```
C:\ProgramData\WSTFU\wstfu.ps1     the copy the watchdog runs
C:\ProgramData\WSTFU\config.json   chosen level, maintenance window
C:\ProgramData\WSTFU\state.json    last pass, correction counters
C:\ProgramData\WSTFU\wstfu.log     rolling log, trimmed at ~1 MB
Scheduled Task \WSTFU              SYSTEM, at boot + every 10 minutes
```

The folder is ACL'd on install: full control for SYSTEM and Administrators,
read-only for everyone else.

## Development

The policy is data, not code: one table in `Get-WstfuPlan`, and apply, verify,
report and revert are four passes over it. Adding a setting means adding one row.

```powershell
Invoke-Pester ./tests                                                  # unit tests, no system changes
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

CI runs both on `windows-latest` plus a parse check on Linux. Before installing on
a machine you care about, walk through [docs/vm-checklist.md](docs/vm-checklist.md)
on a throwaway VM.

## Roadmap

Version 1 is about reboots, and only reboots. Candidates for later:

- `-Status -Json` for monitoring, and a tray icon that says "updates are waiting"
  once a week so you actually install them.
- Signed releases through GitHub Releases.
- A real Windows service instead of a scheduled task.
- An opt-in "install and reboot at 03:00 next Sunday" mode for people who want a
  schedule rather than silence.

## License

MIT. See [LICENSE](LICENSE).
