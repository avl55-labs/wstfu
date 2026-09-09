# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0-beta] - 2026-09-09

### Added after first beta
- **Control-panel dashboard** (`dashboard`): a native WPF window - live status
  tiles, one-click level switch, maintenance window, trust and revert, EN/RU.
  No exe, no dependencies.
- **Defender trust** (`trust` / `untrust`): a path exclusion for the WSTFU
  folder, removed again by `speak`. Honest about what it does and does not do.
- **Weekly self-report** (`report`): a scheduled task, in the signed-in user's
  session, pops a dismissable Windows toast once a week - days since an
  uninvited reboot, whether the watchdog is alive and settings held, and any
  drift it corrected. Runs entirely on the machine, no cloud, no account.
- `status` now lists the update services WSTFU never touches (so a blunt blocker
  tool's fingerprints show), and the Defender-trust state.

### Fixed on real hardware
- A native-stderr crash that killed `status` on a clean machine (PowerShell 5.1
  turns schtasks' stderr into a terminating error).
- Windows 11 detection: `ProductName` still says "Windows 10 Pro", so the build
  number is used instead.
- `status` no longer reports the watchdog as NOT REGISTERED when a non-elevated
  run simply cannot read the SYSTEM-owned task - it says so, and offers to
  re-run elevated.
- Path resolution no longer trusts `$env:ProgramData` (it can be empty in some
  spawned contexts, which sent the tool at a Temp folder); the OS API is used.
- Config and state are written atomically, so a reader never catches a
  half-written file.

First public beta. Reboot control only; everything else is backlog.

### Added
- A `dashboard` command: a native WPF control panel (no exe, no dependencies -
  WPF ships with .NET) with live status tiles, one-click level switching, the
  maintenance window, Defender trust and revert, plus an EN/RU language switch
  that is remembered in `config.json`.
- `trust` / `untrust`: add or remove a Windows Defender path exclusion for the
  WSTFU folder, so Defender stops flagging the installed script. `speak` removes
  it too. Honest about what it does and does not cover (file scans yes, behaviour
  monitoring no).
- `status` now reports the update services (`wuauserv`, `UsoSvc`, `WaaSMedicSvc`,
  `BITS`, `DoSvc`) it never touches, so a blocker tool's damage is visible, and
  the AV-trust state.
- Three noise levels chosen at install time: `mute`, `quiet`, `stfu` (default).
- `status` as the default command - read-only, changes nothing, safe to run first.
- Declarative settings table: apply, verify, report and revert are four passes
  over one list, so the revert path cannot drift from the apply path.
- Quality-update deferral and a rolling pause, on top of the feature-update pin.
- `window <duration>` - a maintenance window that lifts pause and deferrals so
  you can install on purpose, while reboot control stays on. Closes itself.
- SYSTEM watchdog registered from task XML (boot + every 10 minutes, indefinite
  repetition), with self-healing if the task is deleted.
- Reboot history report, including "days since Windows rebooted this PC without
  asking".
- Pester unit tests over the pure logic and PSScriptAnalyzer in CI.

### Fixed on real hardware
- `status` no longer dies on a clean machine: schtasks writes "task not found"
  to stderr, which Windows PowerShell 5.1 turns into a terminating error under
  `$ErrorActionPreference = 'Stop'`. All native calls now go through a wrapper.
- Windows version is read from the build number, not `ProductName` - the latter
  still says "Windows 10 Pro" on Windows 11.
- Orchestrator task state reads `unreadable` (not a false `absent`) when not
  elevated.
- The file is saved UTF-8 with BOM so PowerShell 5.1 reads the Russian UI
  strings correctly.

### Known limits
- `AUOptions` / `AutoInstallMinorUpdates` are kept but flagged `legacy`: Windows
  10 1803+ and Windows 11 largely ignore them. They still apply on LTSC.
- Some `UpdateOrchestrator` tasks are ACL protected and refuse to be disabled
  even by an elevated administrator. Reported, not hidden.
- Active hours are capped by Windows at an 18-hour span. 24/7 is not possible
  through that mechanism, so 05:00-23:00 is used and the rest is carried by the
  reboot policies.
- Windows Home ignores these Group Policy keys entirely. Warned about, not
  supported.
