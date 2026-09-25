# Contributing

Thanks for looking under the hood. Issues and pull requests are welcome; for a
larger change, open an issue first so we can agree on the approach before you
spend time on it.

**Never put real tenant data in the repository** - not in code, tests,
screenshots or commit messages. Sample data uses `contoso.com` and made-up
serial numbers.

## How it's built

One engine, two front ends:

* **`modules\DCU`** - the engine. Every step is a function that takes a
  session object (`New-DCUSession`) instead of `param()` + `Read-Host`, and
  reports through pluggable log / progress / cancel sinks, so it runs the same
  under the wizard, the command line or your own script.
* **The wizard** (`Launch.cmd` → `Start-Gui.ps1` → `gui\Wizard.ps1`) - a WPF
  window on an STA runspace. The work runs in **one persistent background
  runspace**: the Graph token lives in the runspace that signed in, so a fresh
  runspace per step would mean a fresh sign-in per step. The UI thread owns the
  device list; the worker gets plain copies and hands results back.
* **The command line** (`Invoke-DeviceCleanup.ps1`) - one step per run, with
  the device list carried between runs in `workingset.json`.

Rules the code depends on:

* **Every destructive step goes through `Invoke-DCUDeviceLoop`**
  (`Public\Invoke-Actions.ps1`). It makes no Graph write call at all in a dry
  run. Do not send a write from anywhere else.
* **The dry run is never persisted.** `New-DCUSession` defaults to it, the CLI
  needs `-Execute`, and the wizard does not restore the switch from its saved
  settings.
* **Only `Microsoft.Graph.Authentication`.** Every call goes through
  `Invoke-MgGraphRequest` (`Private\Graph.ps1`); do not add the
  `Microsoft.Graph.*` command modules.
* **Never `.GetNewClosure()` a scriptblock that calls module or script
  functions.** It rebinds the block to a new dynamic module, and the module's
  private functions become "not recognized". Step blocks get their options as
  a second parameter (`Invoke-DCUDeviceLoop -Options`); WPF handlers reach
  their control through the event sender.
* **Matching is pure.** `Resolve-DCUDeviceMatches` (`Private\Devices.ps1`)
  makes no Graph calls, which is what keeps it testable.
* Messages refer to steps through `Get-DCUStepRef`, never a hard-coded number.

## Layout

```
Launch.cmd                    starts the wizard (finds pwsh)
Start-Gui.ps1                 STA runspace host for the wizard
Invoke-DeviceCleanup.ps1      CLI, one step per run
Build-TestPackage.ps1         builds the release / test zip
GETTING-STARTED.md            install, admin consent and a guided first run (in the zip)
gui\MainWindow.xaml           the window
gui\Wizard.ps1                the wizard: pages, device grid, background runner
modules\DCU\
  Private\Logging.ps1         Write-DCULog / Write-DCUProgress / cancel token
  Private\Context.ps1         per-run context (dry run, recent days, folders)
  Private\Auth.ps1            delegated sign-in + the scope sets
  Private\Graph.ps1           Invoke-MgGraphRequest wrappers, paging, errors
  Private\Retry.ps1           retry with back-off for throttled calls
  Private\Devices.ps1         the device record and the matching logic
  Private\Spreadsheet.ps1     CSV + a dependency-free .xlsx reader
  Private\Steps.ps1           the step catalogue (options, help, defaults)
  Public\...                  New-DCUSession, the steps, exports
  tests\Run-SmokeTests.ps1    the smoke tests
  tests\New-TestWorkbook.ps1  builds the .xlsx test fixture
```

## Tests

```powershell
pwsh -File .\modules\DCU\tests\Run-SmokeTests.ps1
```

No tenant, no sign-in, no Graph module needed. The smoke tests cover input
parsing (CSV, Excel, paste, typed), device matching, the recent-activity flag,
the step catalogue, the export and working-set round trip, the action loop's
dry-run and failure behaviour, and the destructive steps run for real against
a fake Graph (the Autopilot delete / sync / confirm flow and the Entra step's
Autopilot check). They run on GitHub Actions for every push and pull request.

The wizard has its own self-test that builds the window, walks every page and
prints what it found. It needs a desktop session, so it runs locally only:

```powershell
$env:DCU_WIZARD_SELFTEST = '1'; .\Start-Gui.ps1; $env:DCU_WIZARD_SELFTEST = $null
```

Run both before you open a pull request.

## Building a zip

`Build-TestPackage.ps1` builds the zip from a **commit**, not the working
folder: uncommitted edits are left out and listed. It runs the smoke tests and
the wizard self-test on that export first, drops the tests and the build
script, and writes `VERSION.txt` (the commit it came from).

A **release download** leaves the Graph module out - it is Microsoft's, not
this project's to redistribute:

```powershell
.\Build-TestPackage.ps1 -Tag v1.0.0 -NoGraphModule
```

A **package for a tester** bundles `Microsoft.Graph.Authentication`, so the
tester only needs PowerShell 7:

```powershell
.\Build-TestPackage.ps1 -Tag test-1
```

`-Tag` also puts an annotated tag on the commit, so a report maps back to the
exact code. The tag is local; push it yourself.

## Commits and pull requests

* One logical change per commit, with an imperative subject ("Fix ...",
  "Add ...") and a body that says what was wrong and what changed.
* Keep the style of the surrounding code; comments explain *why*.
* Add a smoke test for new matching, parsing or step behaviour where you can.
* Note user-visible changes in [CHANGELOG.md](CHANGELOG.md).
