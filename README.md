# Device CleanUpper

[![Tests](https://github.com/janaps/device-cleanupper/actions/workflows/tests.yml/badge.svg)](https://github.com/janaps/device-cleanupper/actions/workflows/tests.yml)
[![Latest release](https://img.shields.io/github/v/release/janaps/device-cleanupper)](https://github.com/janaps/device-cleanupper/releases/latest)
[![License: MIT](https://img.shields.io/github/license/janaps/device-cleanupper)](LICENSE)

Releases Windows devices from a Microsoft 365 tenant so that another tenant can
take them over - for example when laptops move to another school, company or
department with its own tenant. It removes the devices from **Intune**, from
**Windows Autopilot** and, where needed, from **Entra ID**, in the order that
avoids stuck enrollments, and proves at the end that the serial numbers are
really released.

A **wizard** (`Launch.cmd`) for doing it by hand, the same in your **browser**
(`Launch-Web.cmd`, runs on your own computer only), and a **command line**
(`Invoke-DeviceCleanup.ps1`) for scripting it - all on one PowerShell module.

> **Deleting a Windows Autopilot registration cannot be undone** - the device
> has to be re-registered from its hardware hash. Every run is a dry run until
> you switch that off, and you use this tool at your own risk (see
> [LICENSE](LICENSE)).

## Quick start

1. Install [PowerShell 7](https://aka.ms/powershell-release?tag=stable)
   (`winget install --id Microsoft.PowerShell -e`) and the one Graph module it
   needs: `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`
2. Download `DeviceCleanUpper-<version>.zip` from the
   [latest release](https://github.com/janaps/device-cleanupper/releases/latest).
   Right-click it → **Properties** → tick **Unblock**, then extract it.
3. Once per tenant, a Global Administrator gives [admin consent](#admin-consent).
4. Start **`Launch.cmd`**, sign in, and put your devices on the list. Nothing
   changes in the tenant until you untick **Dry run**.

[GETTING-STARTED.md](GETTING-STARTED.md) walks you through a first dry run and a
first real run, step by step.

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

| When | Scopes |
|---|---|
| Always | `DeviceManagementManagedDevices.ReadWrite.All`, `DeviceManagementServiceConfig.ReadWrite.All`, `Device.ReadWrite.All`, `Directory.Read.All` |
| Only when you tick "wiping devices" | `DeviceManagementManagedDevices.PrivilegedOperations.All` |
| Only when you tick "BitLocker keys" | `BitLockerKey.Read.All` |

The two sensitive ones are opt-in so the everyday sign-in asks for less. Change
a tick after signing in and you have to sign in again.

### Admin consent

The sign-in goes through Microsoft's own **Microsoft Graph Command Line Tools**
app, and these permissions need a Global Administrator's approval once per
tenant - until then everyone gets *"Need admin approval"*. The simplest way:
the Global Administrator starts the wizard, ticks both boxes under **Extra
permissions to ask for** on the Setup page, clicks **Sign in**, and ticks
**Consent on behalf of your organization** in the Microsoft window. That covers
every scope above, so nobody has to come back for the optional ones.

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

Running a destructive step outside a dry run asks for confirmation once,
names the flagged devices in the prompt, and says how many were never
exported in step 2. From **10 devices** on, you also type the tenant's domain
(`contoso.onmicrosoft.com`) - a yes/no is easy to click through, and a typed
name also catches "signed in to the wrong tenant". The typed name is checked
against the tenant you are actually signed in to.

The working folder (default `Documents\DeviceCleanUpper`) holds:

```
workingset.json                     the device list + how far it got
exports\devices-<stamp>.csv|.json   what the devices were, before deleting
exports\bitlocker-keys-<stamp>.csv  only if you asked for it
exports\handover-<stamp>.csv|.txt   the final report and checklist
logs\devicecleanupper-<date>.log    every line this tool logged, appended live
```

If that log cannot be written (the folder moved, OneDrive in the way, no
permission, disk full), the lines go to `%LOCALAPPDATA%\DeviceCleanUpper\logs`
instead and you are told once. If neither can be written, dry runs still work
but nothing that changes the tenant runs - a real run always leaves a record.

## In your browser

```
Launch-Web.cmd
```

The same steps, rules and sign-in as the wizard, in a browser tab. It is not a
website: a PowerShell window starts a small server on `127.0.0.1` - this
computer only, nothing listens on the network - and opens the page with a
one-time key in the link. Keep that window open while you work; **Quit** in
the page (or Ctrl+C in the window) stops it.

* one mode switch in the top bar - **Dry run** or **LIVE** - instead of three;
* each step shows, above its button, what the button will do in words
  ("Delete 12 device(s) from Intune - 2 flagged - 3 not exported");
* the device table filters on Safe / Flagged / Not found / Autopilot pending;
* the list is saved to `workingset.json` after every change, and a list that
  is replaced or shortened is kept as `workingset-before-<stamp>.json` first.

Sign-in is delegated as in the wizard: the Microsoft sign-in window opens next
to the page. The CLI and the wizard stay; the browser version will replace the
wizard once it has had some real use.

## The command line

The device list is carried between runs in `workingset.json`, so the steps can be
run one at a time, hours apart.

```powershell
# 1a. read the list
.\Invoke-DeviceCleanup.ps1 -Step DeviceInput -Path C:\lists\leavers.xlsx

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
| `-ConfirmTenant contoso.onmicrosoft.com` | needed with `-Execute` when a destructive step acts on 10 or more devices; must be the tenant you sign in to |
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

## Contributing

Bug reports and ideas are welcome as
[issues](https://github.com/janaps/device-cleanupper/issues) - but read the
note in the form first: an issue is public, so tenant data has to come out of
anything you paste. Security problems go through [SECURITY.md](SECURITY.md).

How the code is organised, how to run the tests and how to build a release zip
are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) - © 2026 Jan Aps. Microsoft Graph, Intune, Windows Autopilot and
Entra ID are Microsoft products; this project is not affiliated with Microsoft.