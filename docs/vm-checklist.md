# Manual checklist: prove it on a VM first

The unit tests cover the pure logic. They cannot tell you whether Windows really
stopped rebooting - only a real machine can, and you do not want to learn that on
the machine you work on.

Use a throwaway Windows 11 Pro VM with a snapshot taken **before** step 1.

## 1. Baseline

```powershell
.\wstfu.ps1 status
```

- [ ] Runs without elevation and changes nothing.
- [ ] Every setting reports `DRIFT` / `<unset>` (nothing applied yet).
- [ ] Edition line shows Pro (or your test edition), no Home warning.
- [ ] Reboot history section prints something, or says the log is unreadable.

## 2. Install

```powershell
.\wstfu.ps1 shutup          # choose 3 at the prompt
```

- [ ] The level menu appears and 3 is the default on an empty answer.
- [ ] `C:\ProgramData\WSTFU\` exists and contains `wstfu.ps1`, `config.json`, `wstfu.log`.
- [ ] `schtasks /Query /TN WSTFU /V /FO LIST` shows SYSTEM, highest privileges,
      a boot trigger, and a 10-minute repetition with no end.
- [ ] `.\wstfu.ps1 status` now shows every setting `OK`.
- [ ] Orchestrator tasks show `disabled` or `denied` - never a silent `enabled`.
- [ ] Settings > Windows Update shows updates paused.

## 3. Idempotency

```powershell
.\wstfu.ps1 enforce
Get-Content C:\ProgramData\WSTFU\wstfu.log -Tail 5
```

- [ ] A second pass writes nothing and logs no corrections.

## 4. Drift healing

```powershell
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' NoAutoRebootWithLoggedOnUsers 0
.\wstfu.ps1 status     # should show DRIFT on M01
.\wstfu.ps1 enforce
.\wstfu.ps1 status     # OK again
```

- [ ] The log records the correction and names the setting id.
- [ ] Left alone instead, the watchdog fixes it within 10 minutes.

## 5. Self-healing

```powershell
schtasks /Delete /TN WSTFU /F
.\wstfu.ps1 enforce
schtasks /Query /TN WSTFU
```

- [ ] The task is back, and the log says so.

## 6. Maintenance window

```powershell
.\wstfu.ps1 window 1h
```

- [ ] Settings > Windows Update no longer shows a pause; "Check for updates" works.
- [ ] `status` shows `Window: OPEN until ...` and the level 1 settings still `OK`.
- [ ] Install an update, then confirm Windows still does not restart on its own.
- [ ] `.\wstfu.ps1 close` puts the pause back in one pass.
- [ ] Left alone, the window expires by itself and the next watchdog pass restores
      the full level (check the log line "Maintenance window expired").

## 7. Reboot behaviour (the real test)

- [ ] With a restart pending, leave the VM signed in overnight. It must still be
      up in the morning.
- [ ] `Get-WinEvent -FilterHashtable @{LogName='System';Id=1074,6008}` shows no
      new uninvited entry.

## 8. Revert

```powershell
.\wstfu.ps1 speak
```

- [ ] Every value from `status` is gone (`<unset>` across the board).
- [ ] Orchestrator tasks are enabled again.
- [ ] The WSTFU task is deleted.
- [ ] Settings > Windows Update behaves like a fresh install of Windows.

## 9. Home edition

If you have a Home VM handy:

- [ ] `shutup` warns clearly that Home ignores these keys and asks before going on.

## 10. Reboot the VM

- [ ] After a restart, `status` still shows everything `OK` - the boot trigger works.
