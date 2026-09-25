# Device CleanUpper

Releases Windows devices from a Microsoft 365 tenant so that another tenant can
take them over - for example when laptops move to another school, company or
department with its own tenant. It removes the devices from **Intune**, from
**Windows Autopilot** and, where needed, from **Entra ID**, in the order that
avoids stuck enrollments, and proves at the end that the serial numbers are
really released.

One engine (`modules\DCU`), two front ends: a **wizard** (`Launch.cmd`) and a
**command line** (`Invoke-DeviceCleanup.ps1`). A core module with pluggable log /
progress / cancel sinks, a session object instead of `param()` + `Read-Host`,
and a WPF window on an STA runspace with the work running in a background
runspace.

> **Deleting a Windows Autopilot registration cannot be undone** - the device
> has to be re-registered from its hardware hash. Every run is a dry run until
> you switch that off, and you use this tool at your own risk (see
> [LICENSE](LICENSE)).

## The two things to know before you start

**Every run is a dry run until you say otherwise.** `New-DCUSession` defaults to
`DryRun = $true`, the CLI needs `-Execute`, and the wizard starts with the switch
on every time - it is deliberately not remembered between sessions, however you
left it. A dry run is a real rehearsal: it signs in,
reads the tenant, resolves every device and reports what it *would* do - it just
never sends a delete.

**Devices that were used recently are flagged and never ticked for you.** The
threshold is yours to set (Setup page, or `-RecentDays`, default 30). A laptop
that checked in yesterday is almost certainly still in somebody's hands, and
deleting it from Intune silently unmanages a live device. Acting on a flagged
device is possible - it takes a tick and a confirmation.

## The steps

| # | Step (CLI `-Step`) | Changes the tenant | What it does |
|---|--------------------|--------------------|--------------|
| 1a | `DeviceInput` | no | Build the device list: CSV, Excel, paste, typed in, or a saved list |
| 1b | `Lookup` | no | Find each device in Intune, Windows Autopilot and Entra ID; flag the risky ones |
| 2 | `Backup` | no | Export the list + ids to CSV/JSON, optionally the BitLocker recovery keys |
| 3 | `Wipe` | **yes** | Optional wipe or retire for devices you still have |
| 4 | `IntuneDelete` | **yes** | Delete the Intune device objects |
| 5 | `AutopilotDelete` | **yes** | Delete the Autopilot registrations - this is what releases the serials. Marks them "Deletion pending"; no sync |
| 6 | `AutopilotSync` | no (a sync) | Check the deleted registrations first; only if one is still there, sync Autopilot once and wait (with a countdown) until it is gone |
| 7 | `EntraDelete` | **yes** | Delete the Entra ID device objects (usually not needed). Checks Autopilot live first and never touches a device that is really still there |
| 8 | `FinalCheck` | no | Re-read all three systems, write the handover report |

1a and 1b are two halves of one job - a device list nobody has looked up yet is
of no use to anything - so the wizard puts them on **one page, numbered 1**, with
"first this, then that" halves. The CLI keeps them as two `-Step` values, since
there they are two separate commands.

The rest of the order is not a suggestion. Intune first, then Autopilot, then -
only if it applies - Entra ID. Removing the Entra device object first is what
leaves stuck enrollments and orphaned records behind.

## Getting the devices in

Four ways, all producing the same list:

* **CSV or Excel** - `.csv` (comma, semicolon or tab separated) or `.xlsx`.
  Excel files are read straight out of the package, so Excel does not have to be
  installed and no `ImportExcel` module is needed. Headers are auto-detected in
  Dutch and English (`Serienummer`, `Apparaatnaam`, `Serial Number`,
  `Device Name`, ...); you can name the columns yourself if that goes wrong.
* **Copy / paste** - one device per line, fields separated by a tab, semicolon,
  comma or a couple of spaces. A header line is recognised.
* **Typed in** - an editable grid; type serial, name and a note.
* **A saved list** - `workingset.json` from a previous session, with everything
  that was already looked up and deleted.

A value that could be either a serial number or a device name is tried as both,
so a single unlabelled column works fine. Duplicates are dropped.

## Requirements

* PowerShell 7.2+ (`winget install --id Microsoft.PowerShell -e`)
* `Microsoft.Graph.Authentication`
  (`Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`).
  That module only - every call goes through `Invoke-MgGraphRequest`, so the
  large `Microsoft.Graph.*` command modules are not needed. A copy can also be
  vendored into `modules\Microsoft.Graph.Authentication\`.
* An administrator account that may read and delete devices: **Intune
  Administrator** plus **Cloud Device Administrator** covers it (Global
  Administrator obviously does too).

## Authentication

Delegated, interactive, no app registration and no certificate. You sign in as
yourself, so the tenant's Conditional Access and MFA rules apply and every
delete lands in the tenant audit log under your own name.

Scopes are requested per feature:

| Always | `DeviceManagementManagedDevices.ReadWrite.All`, `DeviceManagementServiceConfig.ReadWrite.All`, `Device.ReadWrite.All`, `Directory.Read.All` |
|---|---|
| Only when you tick "wiping devices" | `DeviceManagementManagedDevices.PrivilegedOperations.All` |
| Only when you tick "BitLocker keys" | `BitLockerKey.Read.All` |

The two sensitive ones are opt-in so the everyday sign-in asks for less. Change
a tick after signing in and you have to sign in again.

## The wizard

```
Launch.cmd
```

A left rail with the setup page and eight step pages, each with a status dot. The
dry-run switch is shown in three places at once (rail, nav bar, Setup card) -
they are the same setting. Every step page has:

* a "How this step works" card,
* the step's options with a line of help each,
* the device grid: tick which devices this step should touch, with the Intune /
  Autopilot / Entra state, when the device was last seen, and the warning,
* the live activity feed and the result panel.

Page 1 is the one exception: it carries both halves of getting started, as two
numbered sections with an arrow between them. Half ➊ (put the devices on the
list) is where you work first; half ➋ (look them up in the tenant) is greyed out,
badge and all, until the list is not empty.

Running a destructive step outside a dry run asks for confirmation once, and
names the flagged devices in the prompt.

The working folder (default `Documents\DeviceCleanUpper`) holds:

```
workingset.json                     the device list + how far it got
exports\devices-<stamp>.csv|.json   what the devices were, before deleting
exports\bitlocker-keys-<stamp>.csv  only if you asked for it
exports\handover-<stamp>.csv|.txt   the final report and checklist
logs\devicecleanupper-<date>.log    every line this tool logged, appended live
```

## The command line

The device list is carried between runs in `workingset.json`, so the steps can be
run one at a time, hours apart.

```powershell
# 1a. read the list
.\Invoke-DeviceCleanup.ps1 -Step DeviceInput -Path C:\lijsten\uitdienst.xlsx

# 1b. look them up (also signs you in)
.\Invoke-DeviceCleanup.ps1 -Step Lookup

# 2. keep a record - and the BitLocker keys, values included
.\Invoke-DeviceCleanup.ps1 -Step Backup -Option @{ IncludeBitLocker = $true; IncludeKeyValues = $true }

# 4. dry run first...
.\Invoke-DeviceCleanup.ps1 -Step IntuneDelete
# ...then for real
.\Invoke-DeviceCleanup.ps1 -Step IntuneDelete -Execute

# 5. the step that actually releases the hardware (run it for every batch first...)
.\Invoke-DeviceCleanup.ps1 -Step AutopilotDelete -Execute

# 6. ...then confirm: syncs Autopilot only if a registration is still there, and waits until it is gone
.\Invoke-DeviceCleanup.ps1 -Step AutopilotSync -Execute

# 8. prove it
.\Invoke-DeviceCleanup.ps1 -Step FinalCheck
```

Useful switches:

| Switch | Meaning |
|---|---|
| `-Execute` | run for real; without it everything is simulated |
| `-RecentDays 7` | change the "still in use" threshold; `0` turns the warning off |
| `-Selection S:5CD1234ABC,...` | act on these device keys only |
| `-IncludeWarned` | act on the flagged devices too (they are left out by default) |
| `-Option @{ ... }` | per-step options, see `Get-DCUStepList \| ForEach-Object Options` |
| `-UseDeviceCode` | sign in with a device code instead of the browser |
| `-WorkFolder` | somewhere other than `Documents\DeviceCleanUpper` |

## What it does not do

* **On-prem Active Directory.** A hybrid joined device (trust type `ServerAd`)
  needs its computer object deleted from the local AD, or Entra Connect syncs it
  straight back. Those devices are skipped, flagged, and listed in the handover
  report - deleting them is a job for `Remove-ADComputer` on a domain-joined
  machine.
* **Undo.** A deleted Autopilot registration cannot be restored; re-registering
  the device needs its hardware hash. That is what step 2 and the dry run are
  for.

## Tests

```powershell
pwsh -File .\modules\DCU\tests\Run-SmokeTests.ps1
```

54 checks - input parsing (CSV, Excel, paste, typed), device matching, the
recent-activity flag, the step catalogue, the export and working-set round trip,
the action loop's dry-run and failure behaviour, and the destructive steps run
for real against a fake Graph (the Autopilot delete / sync / confirm flow and
the Entra step's Autopilot check). No tenant, no sign-in.

The wizard has its own self-test that builds the window, walks every page and
prints what it found:

```powershell
$env:DCU_WIZARD_SELFTEST = '1'; .\Start-Gui.ps1; $env:DCU_WIZARD_SELFTEST = $null
```

## Handing it to a tester

```powershell
.\Build-TestPackage.ps1 -Tag dcu-test-1
```

Builds `dist\DeviceCleanUpper-dcu-test-1.zip` from the committed code, not the
working folder: uncommitted edits are left out and listed. The smoke tests and
the wizard self-test run on that export first. The zip bundles
`Microsoft.Graph.Authentication`, so the tester only needs PowerShell 7, and
holds `VERSION.txt` (the commit it came from) and `TESTING.md` - the tester's
instructions: prerequisites, the admin consent, a dry-run round and a real
round, and what to send back. `-Tag` also tags the commit, so a report maps
back to the exact code.

For a **public release** download, leave the Graph module out - it is
Microsoft's, not this project's to redistribute:

```powershell
.\Build-TestPackage.ps1 -Tag v1.0.0 -NoGraphModule
```

## Layout

```
Launch.cmd                    starts the wizard (finds pwsh)
Start-Gui.ps1                 STA runspace host for the wizard
Invoke-DeviceCleanup.ps1      CLI, one step per run
Build-TestPackage.ps1         builds the zip for a test user
TESTING.md                    the test user's instructions (goes in that zip)
gui\MainWindow.xaml           the window
gui\Wizard.ps1                the wizard: pages, device grid, background runner
modules\DCU\
  Private\Logging.ps1         Write-DCULog / Write-DCUProgress / cancel token
  Private\Context.ps1         per-run context (dry run, recent days, folders)
  Private\Auth.ps1            delegated sign-in + the scope sets
  Private\Graph.ps1           Invoke-MgGraphRequest wrappers, paging, retry
  Private\Devices.ps1         the device record and the matching logic
  Private\Spreadsheet.ps1     CSV + a dependency-free .xlsx reader
  Private\Steps.ps1           the step catalogue (options, help, defaults)
  Public\...                  New-DCUSession, the nine steps, exports
  tests\Run-SmokeTests.ps1
```
