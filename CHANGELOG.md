# Changelog

## Unreleased

- The zip's `TESTING.md` is now `GETTING-STARTED.md`, written for anyone who
  downloads a release, with how to report a problem without posting tenant data.
- README: a quick start and an admin consent section. New: `CONTRIBUTING.md`,
  `SECURITY.md` (private vulnerability reporting), issue forms, and the smoke
  tests on GitHub Actions.
- The workflow rules moved out of the wizard into the module, so the CLI and
  any future front end follow the same ones; see `docs/ARCHITECTURE.md`. A
  real destructive run now needs a confirmation for exactly the devices,
  step and options it runs with, checked where the writes are sent.
- The confirmation for a real destructive run now also says how many of the
  devices were never exported in step 2.
- Fixed: step 2 showed "nothing exported yet" again after any later step ran.
- Fixed: the step 2 result panel showed the wrong fields (Length, Rank, ...).
- Fixed: a Backup with every export switched off still marked the devices as
  exported.
- Fixed: a working set that could not be saved after a step, or on closing
  the wizard, was lost without a word; an unwritable audit log, and settings
  that could not be read or saved, are now reported too.
- Faster ticking of all / none / the safe devices on long lists.
- CLI: it works out which devices a step acts on before signing in, and stops
  without signing in when there is nothing to do. A destructive step now also
  leaves out devices that were never looked up, unless `-IncludeWarned` is
  given. `-Selection` is ignored, with a notice, for the steps that always use
  the whole list (Lookup, AutopilotSync, FinalCheck).
- Working sets are saved with a `SchemaVersion`; older ones still load.
- **New: the browser version** (`Launch-Web.cmd`). The same steps and rules in
  a browser tab, served from this computer only (127.0.0.1, a one-time key in
  the link). One mode switch, a plain-words summary of what each button will
  do, device filters, and the list saved after every change - a replaced or
  shortened list is kept as a copy first.
- **Large batches need the tenant typed in**: a real destructive run on 10 or
  more devices asks for the tenant's domain as well (browser and wizard), or
  `-ConfirmTenant` (CLI). It is checked against the tenant you are actually
  signed in to.
- **The audit log falls back**: when `logs\` in the working folder cannot be
  written, the lines go to `%LOCALAPPDATA%\DeviceCleanUpper\logs` and you are
  told once. When neither can be written, runs that change the tenant are
  refused; dry runs still work. A missing `logs` folder no longer stops a run.
- Browser version: the buttons for reading a pasted list, a file or typed rows
  stayed greyed out when page 1 was opened while something was still running
  (for example straight after signing in).
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
