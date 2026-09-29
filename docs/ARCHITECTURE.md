# Architecture: engine, front ends, and the browser version

This is for whoever maintains Device CleanUpper or decides how it grows. It
says where the code started, what was changed to separate the rules from the
front ends, how the local browser version is built, and what is still open.

## Where it started

The engine (`modules\DCU`) was already in better shape than most tools of this
kind: steps take a session object instead of prompting, output goes through
pluggable sinks, device matching is pure, and every destructive call goes
through one loop (`Invoke-DCUDeviceLoop`) that makes no write in a dry run.
That is the part worth keeping.

The weaknesses were around it:

1. **Safety rules lived in the WPF event handlers.** How far you may navigate
   (not past the device list until everything is looked up), which rows a
   step acts on (ticked rows, or the whole list for lookup, sync and final
   check), what a "safe" device is, when to ask for confirmation, and what
   the Run button says were all in `gui\Wizard.ps1`. The CLI did not have
   them, or had its own version: for example, it treated "not looked up" as
   safe to act on, and the wizard did not.
2. **Workflow state was read back out of display text.** Step 2 counted as
   done when a row's `Result` started with `Exported`, but every later step
   overwrites `Result`. After any later step - even a dry run - step 2 went
   back to "nothing exported yet". The grid colours parsed the same text
   (`FAILED`, `DRY RUN`, `PENDING`, ...).
3. **The same definitions were kept in several places.** The device field list
   existed three times (module, wizard, wizard's C# row type), the step
   descriptions lived in the wizard while the step names lived in the
   catalogue, and the CLI's `-Step` list and "destructive" list were typed
   out by hand.
4. **Failures disappeared.** An audit log that could not be written, a
   settings file that could not be read or saved, and a working set that
   could not be saved after a destructive step were all `catch { }`. The last
   one also cleared the wizard's "unsaved changes" flag, so closing the window
   lost the state without a question.
5. **"No selection" meant "every device".** Every step function treats an
   empty `-Selection` as the whole list. The wizard guarded against that in
   the button handler; nothing guarded it at the engine.
6. **Module-wide mutable state.** `Initialize-DCUContext` copies the session
   into `$script:` variables (dry run, options, inventory cache, sinks), so a
   module instance can run one thing at a time. That is fine for one
   administrator in one runspace, and a blocker for serving several users from
   one process.

Two smaller bugs turned up along the way: `Invoke-DCUBackup` returned the CSV
path as well as its summary, so the wizard's step 2 result panel showed the
array's `Length` and `Rank`; and a Backup with every export switched off still
marked the rows as exported.

## What changed

The rule of thumb: **a decision that a web front end would also have to make
belongs in the module, pure and tested; the host only renders it.**

| Layer | Where | What it holds now |
|---|---|---|
| Catalogue | `Private\Steps.ps1` | Per step: `Effect` (ReadOnly / Write / Destructive), `Scope` (Input / Selection / WholeList), `Summary`, `Explainer`, run label and confirmation wording, options. The only copy. |
| Domain | `Private\Devices.ps1` | The device record, now with `Outcome` (Done / Simulated / Skipped / Pending / Failed / NotReady) and `ExportedAt`. `Set-DCUDeviceResult` is the one writer of `Result` + `Outcome`; `Test-DCUSafeDevice` the one definition of "safe". Old working sets are migrated on load. |
| Workflow policy (pure) | `Public\Workflow.ps1` | `Get-DCUNavigationGate` (how far you may go, and why), `Get-DCUSafeSelection`, `Resolve-DCURunPlan` (targets, label, blocked reason, flagged devices, devices never exported, whether a confirmation is needed, and a `ConfirmationKey`). |
| Application | `Public\Invoke-Step.ps1` | `Invoke-DCUStep`: re-plans the run, refuses a blocked one, refuses a live destructive one without the matching `ConfirmationKey`, passes exactly the planned keys to the step, saves the working set and reports a failed save on the result. |
| Settings | `Public\Settings.ps1` | `Read-` / `Save-` / `ConvertTo-DCUSettings`: whitelisted, typed, clamped - and the dry-run switch can never be stored or restored. |
| Infrastructure | `Private\Graph.ps1`, `Auth.ps1`, `Retry.ps1`, `Spreadsheet.ps1`, `Logging.ps1` | Unchanged, except the audit log now reports once if it cannot be written. |
| Hosts | `gui\Wizard.ps1`, `Invoke-DeviceCleanup.ps1` | Render the plan and gate; no business rules of their own. The CLI works out what it will do before it signs in. |

**The confirmation contract** is the piece that matters most for a web front
end. A plan's `ConfirmationKey` is a fingerprint of the step, dry-run mode,
the step's options and the exact target keys. A host shows the plan, asks the
administrator, and sends the key with the run. `Invoke-DCUStep` computes the
plan again from what the run request carries, and does nothing unless the keys
match. The effect: what was confirmed is what runs - not a list that changed
in between, not a Wipe that was confirmed as a Retire. It is not an
authentication mechanism (see the concerns below).

The wizard's self-test output is identical before and after the change, page
by page. The tests grew from 47 to 114 checks; the new ones are in
`modules\DCU\tests\WorkflowChecks.ps1` and `WebChecks.ps1`.

## The browser version (built: a local web host)

The decision was a **local** web app, not a hosted service. `Launch-Web.cmd`
starts `Start-Web.ps1`, which serves the page and a JSON API on `127.0.0.1`
and opens the browser. It keeps what the README promises: delegated sign-in as
the administrator, no app registration, the tenant's own MFA and Conditional
Access, every delete in the tenant's audit log under their name.

```
 browser page (web\static)          renders plans, gates, outcomes; holds no rules
   │  JSON over http://127.0.0.1:<random port>, token in a header, polling for events
 web host (web\DcuWeb.psm1)         request checks, routes, owns the device list,
   │                                one worker runspace (the Graph sign-in lives there)
 DCU module ─ application           Invoke-DCUStep, Import-DCUDeviceList, settings
            ─ workflow policy       Get-DCUNavigationGate, Resolve-DCURunPlan  (pure)
            ─ domain                device record, matching, flags, outcomes  (pure)
            ─ infrastructure        Graph client, retry, spreadsheet, audit log, working set
```

| Request | What it does |
|---|---|
| `GET /api/state` | mode, sign-in, settings, saved list, `Get-DCUNavigationGate`, `Get-DCUStatus`, last results |
| `GET /api/steps`, `GET /api/devices` | the catalogue; the host's list plus `Get-DCUSafeSelection` |
| `GET /api/events?after=N` | numbered log / progress / result events from the worker |
| `POST /api/settings`, `/api/mode` | `Save-DCUSettings`; dry run on/off (in memory only, starts on) |
| `POST /api/signin`, `/api/signout` | `Connect-` / `Disconnect-DCUGraph` in the worker |
| `POST /api/devices/import` / `remove` / `clear` | paste, typed rows, an uploaded file, or the saved list |
| `POST /api/plan` `{ step, selection, options }` | `Resolve-DCURunPlan` against the host's list |
| `POST /api/run` `{ step, selection, options, confirmationKey, tenantConfirmation }` | `Invoke-DCUStep` in the worker |
| `POST /api/cancel`, `/api/open-folder`, `/api/shutdown` | |

Decisions in the host, and why:

- **The host owns the device list.** The page sends keys, options, the
  confirmation key and the typed tenant - never device rows. A client that
  could send rows could send any Intune or Autopilot id to delete. (A test
  sends a smuggled row and checks that nothing starts.)
- **Every request is checked** (`Test-DCUWebRequest`): the `Host` header must be
  `127.0.0.1:<port>` against DNS rebinding, an `Origin` must be the page itself,
  and `/api/*` needs the per-launch token. The token travels in the URL
  *fragment*, which browsers never send to a server or put in a `Referer`; the
  page moves it to `sessionStorage` and out of the address bar. The listener
  binds to loopback only, and a strict content security policy allows no
  inline script and nothing from elsewhere.
- **One worker runspace, one operation at a time.** Same model as the wizard:
  the Graph token lives in the runspace that signed in. While it runs, the
  list, the mode and a second run are refused with 409.
- **Polling instead of server-sent events.** It keeps the HTTP loop single
  threaded, and a missed poll loses nothing because events are numbered.
- **The list is saved after every change**, and a change that replaces or
  shortens it keeps the previous `workingset.json` as
  `workingset-before-<stamp>.json` first. A browser tab can be closed at any
  moment, so there is no "save before closing?" question to rely on.
- **No build step and no packages.** Plain HTML, CSS and JavaScript modules.
  Every element is built with `textContent`, never `innerHTML` - device names
  and notes come from spreadsheets.

**Large batches need the tenant typed in.** From 10 devices on
(`$script:DCUTypedConfirmMinDevices` in `Public\Workflow.ps1`), a real
destructive run needs the tenant's domain typed as well as the confirmation.
The plan says so (`RequiresTypedConfirmation`); the page asks for it in the
confirmation dialog, the wizard in a second prompt, the CLI through
`-ConfirmTenant`. `Invoke-DCUStep` checks the typed text against the tenant the
session is really signed in to, so it also catches "signed in to the wrong
tenant".

The wizard and the CLI stay. The wizard can be retired once the browser
version has had real use.

### The page

- **One mode switch, always visible,** in the top bar: "Dry run - nothing is
  changed" or "LIVE - deletes are permanent", in text and icon, never colour
  alone; in live mode the whole page gets a red top edge. Going live asks
  first.
- **A stepper driven by `Get-DCUStatus`.** Each step shows done, partly done,
  ready, not yet (lock icon) or running, with the detail as text. A step that
  is not `Reachable` cannot be opened, and the gate's reason is shown under
  the list.
- **Each step page in reading order:** summary; "How this step works" folded
  away; options; the device table; a sticky action bar that says what the
  button will do in the plan's words, with chips for flagged devices, devices
  never exported, and dry run / runs for real.
- **Device table filters:** All / Safe / Flagged / Not found / Autopilot pending
  / Selected, plus a search box. "Select the safe ones" uses the host's safe
  selection.
- **Five tones with fixed meanings:** info for read-only and dry runs; success
  for done; warning for things to check; danger only for live destructive
  actions and failures; blocked for what is not available yet. Tones come from
  the plan's `Effect` / `DryRun`, a row's `Outcome` and a step's `Status` - no
  text is parsed to choose a colour.
- **The confirmation dialog** lists what, how many and in which tenant, names
  the flagged devices, counts those never exported, has Cancel focused, and
  for a large batch keeps the confirm button disabled until the tenant is
  typed.
- **Accessibility:** real buttons and labels, keyboard tabs, focus moved to the
  heading on each page, native modal dialogs, `aria-live` for the activity log
  and announcements, light and dark themes, reduced motion respected, no
  horizontal scroll at phone width.

## Trade-offs and known concerns

- **The confirmation key is a consistency check, not a proof of a human.** The
  page and the wizard hand it over after their own dialog; the CLI treats
  `-Execute` as the confirmation. It guarantees that what was confirmed is what
  runs. It does not stop a program that calls the plan and the run back to
  back - nothing in a local tool could.
- **An open browser tab is an open door.** Anyone at the unlocked computer can
  use the tab, as with the wizard's window. The token only keeps other
  websites and other users' processes out. Lock the screen, or press Quit.
- **The page has no automated UI test.** The host's API has tests, including a
  real HTTP round trip; the page was checked by hand and with headless-browser
  screenshots, not by a test in CI.
- **Sign-in from the browser version has not been exercised against a real
  tenant yet.** It is the same call, in the same kind of STA worker runspace,
  as the wizard's. With a device code, the code still appears in the console
  window, not in the page.
- **Module-wide state stays for now.** `Initialize-DCUContext` copies the
  session into `$script:` variables, so one module instance runs one thing at
  a time. Harmless for a local host with one worker; a blocker for any shared
  server.
- **Most state values are still display text.** `IntuneState = 'Deletion
  pending'`, `Match = 'Not looked up'` and the rest are both the value and the
  label, and they are stored in `workingset.json`. `Outcome` and `ExportedAt`
  were the ones workflow logic depended on through `Result`; the rest should
  become codes plus labels, with a migration behind `SchemaVersion`.
- **The final check overwrites `Warn` / `Flag`** with its own verdict, so after
  step 8 a row no longer shows that it was, say, recently active. The lookup's
  risk flags and the final verdict should be separate fields.
- **The audit log falls back, and a real run needs one of the two.** When the working folder's log cannot be written, lines go to `%LOCALAPPDATA%DeviceCleanUpperogs` and the host is told once. When neither can be written, `Invoke-DCUStep` refuses any run that would change the tenant (the "starting for real" line it writes first is the test); dry runs always run. The fallback file is local to this computer and user - it has to be moved to the working folder by hand.
- **The wizard's grid row type is still a hand-written copy** of the device
  record, guarded by a check at start-up and a test in CI.
- **The explainer texts mention step numbers literally** ("do steps 5 and 6").
  Renumbering the steps means editing them.
- **The home-grown test runner is kept.** Pester 5 does not ship with
  PowerShell 7; worth switching when the checks outgrow the runner.

## Open questions

None at the moment. Decided so far: a local web host rather than a hosted
service; a typed tenant from 10 devices on; an audit log that falls back to
`%LOCALAPPDATA%` and blocks only real runs when neither location works.
