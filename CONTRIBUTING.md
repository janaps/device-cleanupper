# Contributing

Thanks for looking under the hood. Issues and pull requests are welcome; for a
larger change, open an issue first so we can agree on the approach before you
spend time on it.

**Never put real tenant data in the repository** - not in code, tests,
screenshots or commit messages. Sample data uses `contoso.com` and made-up
serial numbers.

## How it's built

One engine, three front ends:

* **`modules\DCU`** - the engine. Every step is a function that takes a
  session object (`New-DCUSession`) instead of `param()` + `Read-Host`, and
  reports through pluggable log / progress / cancel sinks, so it runs the same
  under the wizard, the command line or your own script.
* **The wizard** (`Launch.cmd` → `Start-Gui.ps1` → `gui\Wizard.ps1`) - a WPF
  window on an STA runspace. The work runs in **one persistent background
  runspace**: the Graph token lives in the runspace that signed in, so a fresh
  runspace per step would mean a fresh sign-in per step. The UI thread owns the
  device list; the worker gets plain copies and hands results back.
* **The browser version** (`Launch-Web.cmd` → `Start-Web.ps1` →
  `web\DcuWeb.psm1` + `web\static\`) - a local host on 127.0.0.1 with the
  same one-worker-runspace model as the wizard. The **host** owns the device
  list; the page sends keys, options and confirmations, never device rows.
  The page is plain HTML/CSS/JS modules - no build step, no packages, nothing
  inline (the content security policy forbids it) - and builds every element
  with `textContent`, never `innerHTML`: device names come from spreadsheets.
* **The command line** (`Invoke-DeviceCleanup.ps1`) - one step per run, with
  the device list carried between runs in `workingset.json`.

All front ends only render decisions the module makes. Why it is shaped this
way, and what is still open, is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Rules the code depends on:

* **Hosts run steps through `Invoke-DCUStep`**, not by calling
  `Invoke-DCU<Step>` themselves. It re-plans the run, refuses a live
  destructive one without the `ConfirmationKey` of the plan the administrator
  confirmed, and saves the working set.
* **Workflow rules live in the module, not in a front end.** How far you may
  navigate (`Get-DCUNavigationGate`), which devices a run acts on and what
  needs confirming (`Resolve-DCURunPlan`), and what counts as safe
  (`Test-DCUSafeDevice`) are pure functions with tests. A front end that needs
  a new rule adds it there.
* **Step metadata lives in the catalogue** (`Private\Steps.ps1`): effect,
  scope, texts, labels. No front end keeps its own list of steps.
* **Write a row's result with `Set-DCUDeviceResult`**, never `$d.Result = ...`.
  Code reads `Outcome` and `ExportedAt`; nothing parses `Result` text.
* **A run that changes the tenant needs a writable audit log.** Audit lines go
  to the working folder's log, or to the fallback in `%LOCALAPPDATA%` when that
  fails (`Write-DCUAuditLine`); `Invoke-DCUStep` refuses a real run when
  neither can be written. Dry runs are never refused.
* **No silent `catch { }` around anything that loses state or audit lines** -
  report it (log, result property or dialog).

* **Every destructive step goes through `Invoke-DCUDeviceLoop`**
  (`Public\Invoke-Actions.ps1`). It makes no Graph write call at all in a dry
  run. Do not send a write from anywhere else.
* **The dry run is never persisted.** `New-DCUSession` defaults to it, the CLI
  needs `-Execute`, and the settings functions (`Public\Settings.ps1`) can
  neither store nor restore the switch.
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
Launch-Web.cmd                starts the browser version (finds pwsh)
Start-Gui.ps1                 STA runspace host for the wizard
Start-Web.ps1                 starts the local web host and opens the page
web\DcuWeb.psm1               the web host: request checks, routes, worker, HTTP loop
web\static\                   the page: index.html, app.css, app.js, api.js, dom.js
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
  Private\Devices.ps1         the device record, outcomes, "safe", the matching logic
  Private\Spreadsheet.ps1     CSV + a dependency-free .xlsx reader
  Private\Steps.ps1           the step catalogue (effect, scope, texts, options)
  Public\Workflow.ps1         navigation gate, safe selection, run plans (pure)
  Public\Invoke-Step.ps1      Invoke-DCUStep - the one way hosts run a step
  Public\Settings.ps1         the host settings file (never the dry run)
  Public\...                  New-DCUSession, the steps, status, exports
  tests\Run-SmokeTests.ps1    the test runner, fixtures and the engine checks
  tests\WorkflowChecks.ps1    gating, plans, confirmation, settings, drift checks
  tests\WebChecks.ps1         the web host: request checks, refusals, one HTTP round trip
  tests\New-TestWorkbook.ps1  builds the .xlsx test fixture
docs\ARCHITECTURE.md          current shape, web target, trade-offs, open questions
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
Autopilot check). `WorkflowChecks.ps1` adds the navigation gate, run plans,
the confirmation rule (a live destructive run without the matching key sends
nothing), settings, outcomes, and checks that the CLI's `-Step` list, the
wizard's row type and the manifest have not drifted from the module.
`WebChecks.ps1` covers the web host: token, Host and Origin checks, what it
refuses before a worker starts (a live run without the matching confirmation,
a large batch without the typed tenant, a request that brings its own device
rows), and one real round trip - start the host, read a pasted list in its
worker, save it, quit. They run on GitHub Actions for every push and pull
request, after a parse check of every script and of the page's JavaScript.

The page itself has no automated UI test yet. Before a pull request that
touches `web\static`, start `Launch-Web.cmd` and click through a dry run.

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
