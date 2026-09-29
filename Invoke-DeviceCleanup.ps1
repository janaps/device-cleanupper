#requires -Version 7.2
<#
.SYNOPSIS
    Command-line entry point for the Device CleanUpper.

.DESCRIPTION
    Releases Windows devices from this tenant so another Microsoft 365 tenant
    can take them over, using the same shared engine (modules\DCU) the wizard
    uses. One step per run, in this order:

      DeviceInput      read the device list from a CSV / Excel file or text
      Lookup           find them in Intune, Windows Autopilot and Entra ID
      Backup           export the list (and optionally BitLocker keys)
      Wipe             wipe or retire the devices (optional)
      IntuneDelete     delete the Intune device objects
      AutopilotDelete  delete the Windows Autopilot registrations (no sync)
      AutopilotSync    confirm the deletes; syncs Autopilot only if one is still there
      EntraDelete      delete the Entra ID device objects (usually not needed)
      FinalCheck       re-check everything and write the handover report

    EVERY RUN IS A DRY RUN unless you pass -Execute. A dry run makes no write
    calls at all - it reports exactly what it would do, per device.

    The device list is carried between steps in a working-set file
    (<WorkFolder>\workingset.json) which each step reads and rewrites, so the
    steps can be run one at a time, hours apart.

.EXAMPLE
    .\Invoke-DeviceCleanup.ps1 -Step DeviceInput -Path C:\lists\leavers.xlsx
    # read the list, then look it up:
    .\Invoke-DeviceCleanup.ps1 -Step Lookup

.EXAMPLE
    .\Invoke-DeviceCleanup.ps1 -Step IntuneDelete
    # dry run: reports what it would delete, changes nothing

.EXAMPLE
    .\Invoke-DeviceCleanup.ps1 -Step IntuneDelete -Execute
    # the same run, for real

.EXAMPLE
    .\Invoke-DeviceCleanup.ps1 -Step AutopilotDelete -Execute -Selection S:5CD1234ABC,S:5CD9876ZYX
    # only those two devices

.EXAMPLE
    .\Invoke-DeviceCleanup.ps1 -Step Backup -Option @{ IncludeBitLocker = $true; IncludeKeyValues = $true }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DeviceInput', 'Lookup', 'Backup', 'Wipe', 'IntuneDelete', 'AutopilotDelete', 'AutopilotSync', 'EntraDelete', 'FinalCheck')]
    [string]$Step,

    # Where the working set, exports and logs live.
    [string]$WorkFolder,

    # DeviceInput: a .csv / .xlsx file, or pasted text, or both.
    [string]$Path,
    [string]$Text,
    [string]$Sheet,
    [switch]$Append,

    # SAFETY: without this every step only reports what it would do.
    [switch]$Execute,

    # Flag devices that checked in less than this many days ago. 0 = no warning.
    [int]$RecentDays = 30,

    # Act on these device keys only (the Key column of the exports). None = all.
    [string[]]$Selection,

    # Act on every device, including the ones flagged as still in use.
    # Without it, flagged devices are left out of a destructive step.
    [switch]$IncludeWarned,

    # Per-step option overrides (see Get-DCUStepList | ForEach-Object Options).
    [hashtable]$Option = @{},

    [string]$TenantId,

    # A real destructive run on 10 or more devices also needs the tenant's
    # domain (or id) typed here - it is checked against the actual sign-in.
    [string]$ConfirmTenant,

    [switch]$UseDeviceCode,
    [switch]$ShowVerbose
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$env:PSModulePath = "$PSScriptRoot\modules$([IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module (Join-Path $PSScriptRoot 'modules\DCU\DCU.psd1') -Force

# --- console sinks ----------------------------------------------------------
$script:ShowVerbose = [bool]$ShowVerbose
Register-DCULogSink {
    param($e)
    if ($e.Level -eq 'Verbose' -and -not $script:ShowVerbose) { return }
    $color = switch ($e.Level) {
        'Verbose' { 'DarkGray' } 'Info' { 'Gray' } 'Success' { 'Green' }
        'Warn' { 'Yellow' } 'Error' { 'Red' }
    }
    $cat = if ($e.Category) { " ($($e.Category))" } else { '' }
    Write-Host ('{0:HH:mm:ss} {1,-7}{2} {3}' -f $e.Timestamp, $e.Level.ToUpper(), $cat, $e.Message) -ForegroundColor $color
}
Register-DCUProgressSink {
    param($p)
    if ($p.Completed) { Write-Progress -Id $p.Id -Activity $p.Activity -Completed; return }
    $wp = @{ Id = $p.Id; Activity = $p.Activity; Status = $p.Status }
    if ($p.PercentComplete -ge 0) { $wp.PercentComplete = [math]::Min($p.PercentComplete, 100) }
    Write-Progress @wp
}
Set-DCUVerboseLogging $script:ShowVerbose

# --- cancellation on Ctrl+C -------------------------------------------------
$cancel = [ref]$false
Set-DCUCancelToken $cancel
try { [Console]::CancelKeyPress.Add({ param($s, $e) $e.Cancel = $true; $cancel.Value = $true }) } catch { }

# --- session ----------------------------------------------------------------
$sessionArgs = @{
    DryRun      = -not $Execute
    RecentDays  = $RecentDays
    StepOptions = @{ $Step = $Option }
}
if ($WorkFolder) { $sessionArgs.WorkFolder = $WorkFolder }
if ($TenantId)   { $sessionArgs.TenantId = $TenantId }
$session = New-DCUSession @sessionArgs

$workingSet = Join-Path $session.WorkFolder 'workingset.json'

Write-Host ''
Write-Host "==== $Step ====" -ForegroundColor Cyan
Write-Host "working folder : $($session.WorkFolder)"
if ($session.DryRun) {
    Write-Host 'mode           : DRY RUN - nothing will be changed. Add -Execute to run for real.' -ForegroundColor Cyan
}
else {
    Write-Host 'mode           : EXECUTE - changes will be made in the tenant and cannot be undone.' -ForegroundColor Yellow
}
Write-Host ''

# --- device list ------------------------------------------------------------
$devices = @()
if (Test-Path -LiteralPath $workingSet) { $devices = @(Import-DCUWorkingSet -Path $workingSet) }

if ($Step -eq 'DeviceInput') {
    if (-not $Path -and -not $Text) {
        throw 'Step DeviceInput needs -Path (a .csv or .xlsx file) or -Text (pasted lines).'
    }
    # NB: not "$existing = if (...) { } else { @() }" - an if-expression whose
    # branch yields an empty pipeline assigns $null, and $null binds to an
    # [object[]] parameter as a one-element array containing $null
    $existing = @()
    if ($Append) { $existing = $devices }
    $result = if ($Path) {
        Import-DCUDeviceList -Path $Path -Sheet $Sheet -Existing $existing -Session $session `
            -SerialColumn ([string]$Option['SerialColumn']) -NameColumn ([string]$Option['NameColumn']) -NoteColumn ([string]$Option['NoteColumn'])
    }
    else {
        Import-DCUDeviceList -Text $Text -Existing $existing -Session $session
    }
    Save-DCUWorkingSet -Devices $result.Rows -Path $workingSet -Session $session | Out-Null
    Write-Host ''
    $result | Select-Object Step, Source, Added, Duplicates, Unclassified, Total | Format-List | Out-String | Write-Host
    Write-Host "Next: .\Invoke-DeviceCleanup.ps1 -Step Lookup" -ForegroundColor Cyan
    return
}

if (-not $devices.Count) {
    throw "No devices in $workingSet. Run -Step DeviceInput first."
}

# --- selection --------------------------------------------------------------
# The CLI has no ticks, so it says up front which devices a step acts on:
# -Selection if given; otherwise, for a destructive step, only the safe ones
# (looked up, found, not flagged) unless -IncludeWarned; otherwise all.
$meta = Get-DCUStepList | Where-Object Key -eq $Step
if ($Selection -and $meta.Scope -eq 'WholeList') {
    Write-Host "-Selection is ignored: $Step always works on the whole list." -ForegroundColor Yellow
}
$sel = if ($Selection) { @($Selection) } else { @($devices | ForEach-Object Key) }
if ($meta.Destructive -and -not $Selection -and -not $IncludeWarned) {
    $safe = @(Get-DCUSafeSelection -Devices $devices)
    $left = @($devices | Where-Object { $_.Key -notin $safe })
    if ($left.Count) {
        Write-Host ''
        Write-Host "$($left.Count) device(s) are flagged or not found and are being LEFT OUT of this step:" -ForegroundColor Yellow
        foreach ($w in $left) {
            $why = if ($w.Flag) { $w.Flag } else { $w.Match }
            Write-Host ("  - {0,-28} {1}" -f (@($w.Name, $w.Serial, $w.Raw) | Where-Object { $_ } | Select-Object -First 1), $why) -ForegroundColor Yellow
        }
        Write-Host 'Add -IncludeWarned to act on them anyway, or -Selection to pick devices by key.' -ForegroundColor Yellow
        Write-Host ''
        if (-not $safe.Count) { throw 'Every device on the list is flagged or not found - nothing to do without -IncludeWarned.' }
    }
    $sel = $safe
}

# decided before signing in: a run with nothing to do should not touch the tenant at all
$plan = Resolve-DCURunPlan -Step $Step -Devices $devices -Selection $sel -DryRun $session.DryRun -Options $Option
if (-not $plan.CanRun) { throw "$Step not run: $($plan.BlockedReason)" }
if ($plan.RequiresConfirmation) {
    Write-Host "$($plan.Name): about to $($plan.ConfirmAction) $($plan.TargetCount) device(s), for real." -ForegroundColor Yellow
    if ($plan.NotBackedUp) {
        Write-Host "  $($plan.NotBackedUp) of them were never exported (-Step Backup) - their ids cannot be looked up once they are gone." -ForegroundColor Yellow
    }
}
if ($plan.RequiresTypedConfirmation -and -not $ConfirmTenant) {
    throw "$Step not run: it changes $($plan.TargetCount) devices for real. Add -ConfirmTenant <tenant domain> to confirm which tenant that is."
}

# --- sign in ----------------------------------------------------------------
$scopeArgs = @{}
if ($Step -eq 'Wipe') { $scopeArgs.IncludeWipe = $true }
if ($Step -eq 'Backup' -and $Option.ContainsKey('IncludeBitLocker') -and $Option['IncludeBitLocker']) { $scopeArgs.IncludeBitLocker = $true }
$scopes = Get-DCURequiredScopes @scopeArgs

$connect = @{ Scopes = $scopes }
if ($TenantId)      { $connect.TenantId = $TenantId }
if ($UseDeviceCode) { $connect.UseDeviceCode = $true }
Connect-DCUGraph @connect | Out-Null

# --- run --------------------------------------------------------------------
# -Execute is the CLI's confirmation, so the run carries the key of the plan
# it was given for; Invoke-DCUStep also saves the working set afterwards
$summary = Invoke-DCUStep -Step $Step -Session $session -Devices $devices -Selection $plan.Targets -ConfirmationKey $plan.ConfirmationKey -TenantConfirmation $ConfirmTenant
if ($summary.PSObject.Properties['WorkingSetError']) { Write-Host $summary.WorkingSetError -ForegroundColor Red }

Write-Host ''
$summary | Select-Object -Property * -ExcludeProperty Rows, Checklist | Format-List | Out-String | Write-Host

if ($summary.PSObject.Properties.Name -contains 'Rows') {
    @($summary.Rows) |
        Select-Object @{ n = 'Key'; e = { $_.Key } },
                      @{ n = 'Device'; e = { @($_.Name, $_.Raw) | Where-Object { $_ } | Select-Object -First 1 } },
                      @{ n = 'Serial'; e = { $_.Serial } },
                      @{ n = 'Intune'; e = { $_.IntuneState } },
                      @{ n = 'Autopilot'; e = { $_.AutopilotState } },
                      @{ n = 'Entra'; e = { $_.EntraState } },
                      @{ n = 'Days'; e = { if ($_.DaysSinceActivity -ge 0) { $_.DaysSinceActivity } else { '' } } },
                      @{ n = 'Result'; e = { $_.Result } } |
        Format-Table -AutoSize | Out-String -Width 240 | Write-Host
}

if ($session.DryRun -and $plan.Effect -ne 'ReadOnly') {
    Write-Host 'This was a DRY RUN - nothing was changed. Re-run with -Execute to apply it.' -ForegroundColor Cyan
}
