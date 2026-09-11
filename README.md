<p align="center">
  <img src="assets/logo.svg" alt="WSTFU" width="320">
</p>

<p align="center"><b>Windows, Shut The F**k Up.</b><br>
Your machine reboots when <i>you</i> say so.</p>

<p align="center">
  <a href="../../actions/workflows/ci.yml"><img alt="CI" src="../../actions/workflows/ci.yml/badge.svg"></a>
  <img alt="PowerShell 5.1+" src="https://img.shields.io/badge/PowerShell-5.1%2B-5391FE">
  <img alt="Windows 10 / 11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4">
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-green">
</p>

<p align="center"><b>English</b> · <a href="README.ru.md">Русский</a></p>

---

## The problem

Every week or two, Windows decides on its own that now is a good time to restart -
after an update, mid-work, or overnight. Nothing is broken; the reboot decision
simply does not belong to the person using the machine. WSTFU takes it back and
**keeps** it, because a setting you flip by hand gets quietly restored by the next
update.

<p align="center">
  <img src="assets/dashboard.png" alt="WSTFU control panel" width="778">
</p>

## What it does

You pick a noise level. WSTFU applies it and installs a background **watchdog**
that re-checks everything at boot and every 10 minutes, undoing anything that
drifted and recreating its own task if it gets deleted.

| Level | Name | What it does | You give up |
|:-----:|------|--------------|-------------|
| 1 | `mute` **(default)** | Reboot control only. Updates still download and install. | A pending restart follows you around until you do it. |
| 2 | `quiet` | `mute` + pin the version + hold monthly updates 30 days + no restart nags. | A fix for something actively exploited also waits 30 days. |
| 3 | `stfu` | `quiet` + a rolling pause, so nothing arrives until you open a window. | No security updates until you open a window - fine for a private workstation, not for a travelling laptop. |

Whatever the level, **reboot control is always on** - the rest is only about *when*
updates may show up. [What each level changes, setting by setting →](docs/levels.md)

## Install

Needs **Windows 10 / 11 Pro, Enterprise, Education or IoT LTSC**. (Home ignores
the policies this uses.) Nothing to install - it runs on the PowerShell that
ships with Windows.

### Easiest way: double-click `Run WSTFU.cmd`

It opens a small control panel. You see the current state, pick a level with one
click, open an update window, or revert - all with buttons. Approve the admin
prompt when it asks. That's the whole thing.

> **Unsigned software.** WSTFU has no code-signing certificate yet, so Microsoft
> Defender and SmartScreen may warn about it or flag it - not as a virus, but
> because a signature is what tells Windows who to trust, and there isn't one. If
> it gets blocked, add two folders to Defender's exclusions - **`C:\ProgramData\WSTFU`**
> (where it installs and runs from) and **the folder you unzipped it into** - then
> run it again. See [Defender](#defender) for the exact steps.

### Prefer the console?

Same thing, without the window:

```powershell
.\wstfu.ps1 status      # read-only, changes nothing - run this first
.\wstfu.ps1 shutup      # asks which level, applies it, installs the watchdog
```

`status.cmd`, `shutup.cmd` and `speak.cmd` double-click straight to those actions.

## Commands

| Command | What it does |
|---------|--------------|
| `wstfu.ps1 status` | Read-only report: settings, watchdog, and your reboot history. Default. Changes nothing. |
| `wstfu.ps1 shutup [-Level 1\|2\|3]` | Apply a level and install the watchdog. |
| `wstfu.ps1 window 4h` | Open a maintenance window so you can install updates on purpose. Reboot control stays on; closes itself. |
| `wstfu.ps1 close` | Close that window now. |
| `wstfu.ps1 report` | Show the weekly health summary as a toast now. |
| `wstfu.ps1 trust` / `untrust` | Add / remove the Defender exclusion for the WSTFU folder. |
| `wstfu.ps1 dashboard` | A small control-panel window (live status, level switch, window, revert, EN/RU). |
| `wstfu.ps1 speak` | Undo everything - back to Microsoft defaults. |

Durations are `30m`, `4h`, `2d`, or a bare number (hours). WSTFU also drops a
weekly toast with the number that matters: **days since Windows rebooted your PC
without asking.**

## Updating on your terms

The point is that you still patch the machine - when it suits you:

```powershell
.\wstfu.ps1 window 4h    # updates allowed for 4 hours; reboot control still on
# Settings > Windows Update > Check for updates, install, then reboot yourself
.\wstfu.ps1 close        # or just let the window expire
```

Inside a window Windows still cannot restart the machine on its own. It never can.

## Honest limits

- **Nothing here is un-killable, and shouldn't be.** A local admin, `SYSTEM` and
  `TrustedInstaller` sit above every service by design. WSTFU defends against
  *automatic* reversion (an update, a cleanup tool) by putting settings back
  within 10 minutes - it does not lock you out of your own machine.
- **Windows Home is not supported** - it ignores these policies entirely.
- **Some reboot tasks are protected** and refuse even an elevated admin; `status`
  shows this honestly. The registry policy carries the load.
- **Active hours can't cover 24h** (Windows caps them at 18), so the reboot
  policies do the real work outside 05:00-23:00.
- **Domain Group Policy wins.** On a domain-joined machine this is out of scope.
- **Level 3 means an unpatched machine** until you open a window - a deliberate,
  reversible trade for a workstation off the public network.

## Defender

Defender may flag WSTFU as a *potentially unwanted app* - because disabling
reboot tasks is behaviour its heuristics distrust, not because it is malware.
Reputable tools in this space get the same label.

- `shutup` tries to exclude its own folder automatically. That works only while
  Defender is running **and** Tamper Protection is off.
- If it's refused, add it once by hand: **Windows Security → Virus & threat
  protection → Manage settings → Exclusions → Add a folder → `C:\ProgramData\WSTFU`**
  (and the folder you run the script from).
- If Defender already quarantined the file: **Protection history → Restore**,
  then add the exclusion, then install.
- With that folder excluded, the installed copy is left alone - now and after
  future definition updates. A copy outside the excluded folder is not; behaviour
  monitoring is mostly, but not 100%, suppressed - the watchdog is the backstop.

**WSTFU never disables Defender, and never will.** Turning your antivirus off is
what malware does; it's blocked by Tamper Protection anyway, and it would leave
the machine exposed. An exclusion is the most it touches, and `speak` / `untrust`
put it back.

## Uninstall

```powershell
.\wstfu.ps1 speak
```

Removes every value it wrote, re-enables the reboot tasks, deletes the watchdog,
and removes the Defender exclusion.

## Development

```powershell
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

CI runs both on `windows-latest`. The policy is data, not code - one table in
`Get-WstfuPlan`, and apply / verify / report / revert are four passes over it, so
adding a setting is adding a row.

## License

MIT - see [LICENSE](LICENSE).
