# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0-beta] - 2026-09-09

First public beta. Reboot control for Windows Update.

### Added
- Three noise levels chosen at install: `mute`, `quiet`, `stfu` (default).
- `status` - a safe, read-only report and the default command.
- A SYSTEM watchdog that re-applies the policy at boot and every 10 minutes and
  recreates its own task if deleted.
- `window` - a maintenance window to install updates on purpose, while reboot
  control stays on; it closes itself.
- A weekly toast summary (`report`), a control-panel window (`dashboard`, EN/RU),
  and `trust` / `untrust` for the Defender exclusion.
- Reboot-history report, including days since Windows rebooted the PC unasked.

### Known limits
- Windows Home is unsupported (it ignores these policies).
- Some reboot tasks are ACL-protected and refuse even an elevated admin; the
  registry policy carries the load.
- Active hours are capped at 18 hours by Windows; the reboot policies cover the rest.
- Level 3 pauses security updates until you open a window.

See the README for details and honest limits.
