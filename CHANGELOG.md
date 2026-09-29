# Changelog

## 1.1.0 - 2026-09-29

### New

- **The browser version** (`Launch-Web.cmd`): the same steps, rules and
  sign-in as the wizard, in a browser tab, served from this computer only
  (127.0.0.1, with a one-time key in the link). One Dry run / LIVE switch, a
  plain-words summary of what each button will do, device filters, and the
  list saved after every change - a list that is replaced or shortened is kept
  as a copy first. The wizard and the command line stay.
- **Large batches need the tenant typed in**: a real run of a destructive step
  on 10 or more devices also asks for the tenant's domain (browser and wizard),
  or `-ConfirmTenant` (command line). It is checked against the tenant you are
  actually signed in to, so it also catches "signed in to the wrong tenant".
- **The confirmation for a real run says more**: how many of the devices were
  never exported in step 2, as well as which ones are flagged. What was
  confirmed is what runs - the confirmation is for exactly those devices, that
  step and those options.
- **The audit log falls back**: when `logs\` in the working folder cannot be
  written, the lines go to `%LOCALAPPDATA%\DeviceCleanUpper\logs` and you are
  told once. When neither can be written, runs that change the tenant are
  refused; dry runs still work.

### Changed - may affect scripts that use the command line

- `-Execute` on 10 or more devices in a destructive step now also needs
  `-ConfirmTenant <tenant domain>`. Without it the run stops before signing in,
  and says so.
- A destructive step without `-Selection` now also leaves out devices that were
  never looked up (as well as the flagged ones), unless `-IncludeWarned` is
  given.
- `-Selection` is ignored, with a notice, for the steps that always use the
  whole list: Lookup, AutopilotSync and FinalCheck.
- The command line works out which devices a step acts on before it signs in,
  and stops without signing in when there is nothing to do.

### Changed

- The workflow rules moved out of the wizard into the module, so the wizard,
  the command line and the browser version follow the same ones. See
  `docs/ARCHITECTURE.md`.
- Working sets are saved with a `SchemaVersion`; lists saved by 1.0.0 still
  load.
- Faster ticking of all / none / the safe devices on long lists.
- README: a quick start and an admin consent section. New: `CONTRIBUTING.md`,
  `SECURITY.md` (private vulnerability reporting), issue forms, and the tests
  on GitHub Actions. The zip's `TESTING.md` is now `GETTING-STARTED.md`,
  written for anyone who downloads a release, with how to report a problem
  without posting tenant data.

### Fixed

- Step 2 showed "nothing exported yet" again after any later step ran.
- The step 2 result panel in the wizard showed the wrong fields (Length,
  Rank, ...).
- A Backup with every export switched off still marked the devices exported.
- A working set that could not be saved after a step, or when closing the
  wizard, was lost without a word. An unwritable audit log, and settings that
  could not be read or saved, are now reported too.
- A `logs` folder that could not be created stopped every run, dry runs
  included.

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
