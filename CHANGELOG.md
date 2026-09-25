# Changelog

## 1.0.0 - 2026-09-25

First public release.

- **Wizard** (`Launch.cmd`) and **command line** (`Invoke-DeviceCleanup.ps1`)
  on one shared PowerShell module.
- **Device list** from CSV, Excel (no Excel needed), copy / paste, typed in, or
  a saved list. Serial numbers and device names are matched against Intune,
  Windows Autopilot and Entra ID; recently used, unmatched, duplicate and hybrid
  joined devices are flagged.
- **Steps**, in the order that avoids stuck enrollments: export the list (and
  optionally the BitLocker recovery keys), wipe or retire (optional), remove
  from Intune, remove the Autopilot registration, sync Autopilot and confirm
  the removals, remove the Entra ID object (only where needed), final check
  with a handover report.
- **Dry run by default**, every session. A real run asks for confirmation.
- **Autopilot removals are confirmed, not assumed**: a deleted registration
  stays "Deletion pending" until Autopilot no longer returns it. The sync step
  only sends a sync when a registration is still there, and shows a countdown
  while it waits.
- **Delegated sign-in** only - no app registration, no certificate; every
  change is made as, and logged under, the signed-in administrator.
