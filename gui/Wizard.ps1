<#
    WPF wizard for the Device CleanUpper.

    Loaded from Start-Gui.ps1 on a dedicated STA thread. A left rail lists the
    setup page + the eight steps of the handover procedure; each step is its own
    page with inline status, options, the device grid, an activity feed and a
    result panel.

    Two design choices worth knowing:

      * ONE background runspace is created at start-up and reused for every
        operation. The Graph sign-in lives in that runspace, so re-using it is
        what keeps the administrator signed in between steps.
      * the device list is owned by the UI thread. Rows are handed to the worker
        as plain copies and merged back when it finishes - the worker never
        touches an object that is bound to the grid.
#>
param([Parameter(Mandatory)][string]$RootPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

if (-not ('WizStep' -as [type])) {
    Add-Type -Language CSharp @'
using System.ComponentModel;

public class WizStep : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void PC(string n){ var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    public string Key { get; set; }
    public string Number { get; set; }
    string _name; public string Name { get { return _name; } set { _name = value; PC("Name"); } }
    string _d = ""; public string Detail { get { return _d; } set { _d = value; PC("Detail"); } }
    string _s = ""; public string Status { get { return _s; } set { _s = value; PC("Status"); PC("StatusColor"); } }
    public string StatusColor {
        get {
            switch (_s) {
                case "Done": return "#3FB950";
                case "Partial": return "#D29922";
                case "Blocked": return "#3E4756";
                case "Error": return "#F85149";
                case "Running": return "#58A6FF";
                default: return "#8B949E";
            }
        }
    }
}

// One row of the device grid. Only Apply notifies: every other change arrives
// as a fresh set of rows from the worker, and the collection is rebuilt.
public class DcuDevice : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void PC(string n){ var h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }

    public string Key { get; set; }
    public string Raw { get; set; }
    public string Name { get; set; }
    public string Serial { get; set; }
    public string Note { get; set; }
    public string Source { get; set; }
    public string Match { get; set; }
    public string MatchDetail { get; set; }
    public string IntuneId { get; set; }
    public string IntuneName { get; set; }
    public string IntuneUser { get; set; }
    public string IntuneLastSync { get; set; }
    public string IntuneEnrolled { get; set; }
    public string IntuneOs { get; set; }
    public string IntuneModel { get; set; }
    public string IntuneOwner { get; set; }
    public string IntuneCompliance { get; set; }
    public string AzureAdDeviceId { get; set; }
    public string EntraObjectId { get; set; }
    public string EntraName { get; set; }
    public string EntraTrust { get; set; }
    public string EntraLastSignIn { get; set; }
    public string EntraEnabled { get; set; }
    public string AutopilotId { get; set; }
    public string AutopilotGroupTag { get; set; }
    public string AutopilotEnrollment { get; set; }
    public string AutopilotUser { get; set; }
    public string LastActivity { get; set; }
    public int DaysSinceActivity { get; set; }
    public bool Warn { get; set; }
    public string Flag { get; set; }
    public string IntuneState { get; set; }
    public string AutopilotState { get; set; }
    public string EntraState { get; set; }
    public string BitLockerState { get; set; }
    public string Result { get; set; }

    bool _apply; public bool Apply { get { return _apply; } set { _apply = value; PC("Apply"); } }

    public string Display {
        get {
            if (!string.IsNullOrEmpty(Name)) return Name;
            if (!string.IsNullOrEmpty(IntuneName)) return IntuneName;
            if (!string.IsNullOrEmpty(EntraName)) return EntraName;
            if (!string.IsNullOrEmpty(Raw)) return Raw;
            return Serial;
        }
    }
    public string LastSeen {
        get {
            if (string.IsNullOrEmpty(LastActivity)) return "unknown";
            if (DaysSinceActivity < 0) return LastActivity;
            if (DaysSinceActivity == 0) return "today";
            if (DaysSinceActivity == 1) return "yesterday";
            return DaysSinceActivity.ToString() + " days ago";
        }
    }
    public string FlagColor { get { return Warn ? "#C0281F" : "#6E7681"; } }
    public string ResultColor {
        get {
            if (string.IsNullOrEmpty(Result)) return "#6E7681";
            if (Result.StartsWith("FAILED") || Result.StartsWith("NOT ready")) return "#C0281F";
            if (Result.StartsWith("DRY RUN")) return "#1A56C4";
            if (Result.StartsWith("Skipped")) return "#6E7681";
            if (Result.StartsWith("PENDING")) return "#A25A00";
            return "#1B7F35";
        }
    }
}

// A row the administrator types into the "Type them in" grid.
public class ManualRow {
    public string Serial { get; set; }
    public string Name { get; set; }
    public string Note { get; set; }
}
'@
}

$ModulePath = Join-Path $RootPath 'modules\DCU\DCU.psd1'
$ModuleRoot = Join-Path $RootPath 'modules'
$env:PSModulePath = "$ModuleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module $ModulePath -Force

$xamlPath = Join-Path $RootPath 'gui\MainWindow.xaml'
$xamlText = Get-Content -Path $xamlPath -Raw
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new(([xml]$xamlText)))
$c = @{}
foreach ($m in [regex]::Matches($xamlText, 'x:Name="([^"]+)"')) { $c[$m.Groups[1].Value] = $window.FindName($m.Groups[1].Value) }

$ConfigDir  = Join-Path $env:APPDATA 'DeviceCleanUpper'
$ConfigPath = Join-Path $ConfigDir 'config.json'

# Page 1 is the two catalogue steps DeviceInput and Lookup on one page: building
# the list and looking it up are two halves of the same job, and a device list
# you have not looked up yet is of no use to anything. The page shows them as
# numbered halves - the rail carries one entry, and the Run button drives Lookup.
$MergedPageKey = 'DeviceInput'
$MergedRunKey  = 'Lookup'

# steps that always work on the whole list instead of the ticked rows: ticking
# rows for a lookup, a sync or a final check would only hide devices from it
$WholeListSteps = 'Lookup', 'AutopilotSync', 'FinalCheck'

function Get-RunStepKey {
    <# which catalogue step the Run button on a page actually invokes #>
    param([string]$PageKey)
    if ($PageKey -eq $MergedPageKey) { return $MergedRunKey }
    $PageKey
}

# short per-step descriptions for the page header
$StepDesc = @{
    DeviceInput     = 'Put the devices that are leaving this tenant on the list, then look them up. Read the list from a CSV or Excel file, paste it in, type it in, or pick up a list you saved earlier - and then have Intune, Windows Autopilot and Entra ID checked for every one of them.'
    Lookup          = 'Find every device on the list in Intune, Windows Autopilot and Entra ID, and flag the ones that look like they are still in use. Read-only.'
    Backup          = 'Write down what these devices were before they stop existing: device names, serial numbers and the Intune / Entra / Autopilot ids - and, if you need them, the BitLocker recovery keys. Read-only.'
    Wipe            = 'Optional. Send a wipe or a retire to devices you still have and that can still come online. The command is queued in Intune and runs the next time the device checks in.'
    IntuneDelete    = 'Delete the Intune device objects, so this tenant no longer manages the devices. Step 1 of the two that actually release the hardware.'
    AutopilotDelete = 'Delete the Windows Autopilot registrations. This is the step that releases the serial numbers - until it is done, the devices keep landing back in this tenant at OOBE and the other tenant cannot register them.'
    AutopilotSync   = 'Check whether the registrations deleted in step 5 are gone yet; only if one is still there, ask Intune to sync the Autopilot list and wait until it is. Run it after ALL your Autopilot deletes - Intune only accepts a manual sync every so often.'
    EntraDelete     = 'Delete the Entra ID device objects. Usually NOT needed: for an Autopilot + Entra joined device the object is cleaned up once Intune and Autopilot are gone. It matters for devices that were never in Autopilot.'
    FinalCheck      = 'Re-read all three systems and prove the devices really are released. Writes the handover report and lists whatever still has to be done by hand.'
}

# the "How this step works" card under the banner
$StepInfo = @{
    Lookup = @'
Every device on the list is looked up in three places at once: the Intune managed-device list, the Windows Autopilot device list and the Entra ID device list. Matching is on serial number first and device name second - a value that could be either is tried both ways, so a single pasted column does not have to be labelled.

Nothing is changed. This step exists to tell you what you are about to delete: which of the three systems each device is in, who used it, when it last checked in, and whether anything looks wrong.

Devices that checked in recently are flagged in red and left unticked. So are devices that matched nothing, devices that matched more than one record, and hybrid joined devices.
'@
    Backup = @'
Once the Intune, Autopilot and Entra records are deleted, their ids cannot be looked up again - and deleting an Entra device object also throws away the BitLocker recovery keys Entra was holding for it. This is the step that is genuinely hard to undo by skipping.

The export is a semicolon-separated CSV (opens straight into Excel) plus the same data as JSON.

BitLocker keys are off by default and need their own consent. Exporting the key VALUES makes that file as good as the disks themselves - keep it somewhere safe and delete it when the handover is done.
'@
    Wipe = @'
Optional, and only for hardware you still physically have. Intune queues the command and it runs the next time the device comes online - a laptop that is already boxed up will never receive it, which is fine: deleting the records still releases it.

Wipe resets Windows to a clean state, which is what you want before handing hardware to somebody else. Retire only removes company data, apps and policies and leaves the user profile alone.

This does not delete anything from Intune. That is the next step.
'@
    IntuneDelete = @'
Removes the Intune device object, so this tenant stops managing the device.

On its own this does NOT release the hardware: while the serial number is still registered in Windows Autopilot, the device keeps coming back to this tenant at OOBE. Do steps 5 and 6 as well.

The order matters. Intune first, then Autopilot, and only then (if at all) the Entra ID object - removing the Entra object first is what leaves stuck enrollments and orphaned records behind.
'@
    AutopilotDelete = @'
This is the step that actually releases the serial numbers. The assigned user is removed first, then the device identity is deleted.

Deletion is asynchronous: Intune accepts it straight away, but the registration can stay in the list for minutes. A device is therefore marked "Deletion pending" here, not Deleted - step 6 syncs Autopilot and confirms it is really gone.

This step does NOT sync. If you remove devices in several batches, run this step for each batch first and step 6 once at the end: Intune only accepts a manual sync every so often.

If a device was never registered in Autopilot, its row is skipped here - that is normal, not a failure. A device whose delete was already sent is skipped too.
'@
    AutopilotSync = @'
First looks up every registration that step 5 deleted. If they are all gone already, that is it - no sync is sent. Only when at least one is still in Autopilot does it send one "sync" (the same as the Sync button in the Intune portal) and then re-read the remaining ones until they are really gone, or until the waiting time runs out, with a countdown in the activity list. Only then is a device marked Deleted.

Intune accepts a manual sync only every so often. If it refuses because a sync ran recently (from here or from the portal), that sync counts: the removals are still checked, and the log shows when the last sync was.

Still pending when the time runs out? Nothing is wrong - run this step again in a few minutes. Cancel stops the waiting, never the deletes. The Entra ID step skips every device that is still in Autopilot.
'@
    EntraDelete = @'
For a normal Autopilot + Entra joined device you do NOT have to delete the Entra object by hand to release the device, so those rows are skipped by default.

It matters for devices that were never in Autopilot and have to be fully detached from this tenant.

A device that the list still shows in Autopilot - or whose Autopilot removal is not confirmed yet - is looked up in Autopilot first. If the registration is gone (also when someone removed it outside this tool), the device is handled like any other. If it is really still there, it is always skipped, whatever the options say: run step 5 (remove the registration) and step 6 (sync and confirm) first.

Hybrid joined devices (trust type ServerAd) are skipped too: the cloud object comes straight back at the next Entra Connect sync unless the computer object is deleted from the on-prem Active Directory first. Those devices are listed in the final report so you can clean them up there.

Deleting a device object also deletes the BitLocker recovery keys Entra held for it. Export them in step 2 first if there is any chance a disk still has to be unlocked.
'@
    FinalCheck = @'
Re-reads Intune, Windows Autopilot and Entra ID and answers, per device: is it gone from Intune, is the serial number gone from the Autopilot list, what is left in Entra ID, and is there anything still to do on-premises.

A device counts as ready for handover when it is out of Intune and out of Autopilot and needs nothing done in the on-prem Active Directory. An Entra ID object that is still there is normal for an Autopilot device.

The report is written as a CSV plus a readable checklist you can hand to whoever takes the devices over.
'@
}

# ----------------------------------------------------------------------------
$wiz = [ordered]@{
    Steps        = [System.Collections.ObjectModel.ObservableCollection[WizStep]]::new()
    Devices      = [System.Collections.ObjectModel.ObservableCollection[DcuDevice]]::new()
    Manual       = [System.Collections.ObjectModel.ObservableCollection[ManualRow]]::new()
    Catalog      = @(Get-DCUStepList)
    Index        = 0
    Navigating   = $false
    Running      = $false
    CancelRef    = [ref]$false
    Queue        = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    Runspace     = $null
    Ps           = $null
    Handle       = $null
    Timer        = $null
    OptControls  = @{}
    CurrentKey   = $null
    LastResults  = @{}
    SignIn       = $null
    Dirty        = $false      # device list changed since the last save
    LiveLine     = $null       # the in-place countdown line in the activity feed
}

# ----------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------
function New-Line { param([string]$Text, [string]$Color = '#1B1B1B') [pscustomobject]@{ Text = $Text; Color = $Color } }

function Level-Color {
    param([string]$Level)
    switch ($Level) {
        'Verbose' { '#7A7A7A' } 'Info' { '#1B1B1B' } 'Success' { '#1B7F35' }
        'Warn' { '#A25A00' } 'Error' { '#C0281F' } default { '#1B1B1B' }
    }
}

function Add-LogLine {
    param($Entry)
    if ($Entry.Level -eq 'Verbose' -and -not $c.VerboseCheck.IsChecked) { return }
    $cat = if ($Entry.Category) { " [$($Entry.Category)]" } else { '' }
    $item = New-Line ('{0:HH:mm:ss}{1}  {2}' -f $Entry.Timestamp, $cat, $Entry.Message) (Level-Color $Entry.Level)
    [void]$c.LogList.Items.Add($item)
    while ($c.LogList.Items.Count -gt 8000) { $c.LogList.Items.RemoveAt(0) }
    $c.LogList.ScrollIntoView($item)
}

function Add-StepActivity {
    param($Entry)
    if ($Entry.Level -eq 'Verbose' -and -not $c.VerboseCheck.IsChecked) { return }
    $item = New-Line ('{0:HH:mm:ss}  {1}' -f $Entry.Timestamp, $Entry.Message) (Level-Color $Entry.Level)
    # a running countdown stays the last line - new lines go in above it
    $live = if ($wiz.LiveLine) { $c.StepActivityList.Items.IndexOf($wiz.LiveLine) } else { -1 }
    if ($live -ge 0) { $c.StepActivityList.Items.Insert($live, $item) } else { [void]$c.StepActivityList.Items.Add($item) }
    while ($c.StepActivityList.Items.Count -gt 4000) { $c.StepActivityList.Items.RemoveAt(0) }
    $c.StepActivityList.ScrollIntoView($item)
}

function Set-Status { param([string]$Text) $c.StatusText.Text = $Text }

function Update-LiveActivity {
    <#
        A countdown ("next check in 14s") as ONE activity line that is rewritten
        in place and always sits at the bottom - a line per second would bury
        everything else. It goes away when the wait is over; the log lines that
        follow say how it ended.
    #>
    param($P)
    $list = $c.StepActivityList
    if ($wiz.LiveLine) { [void]$list.Items.Remove($wiz.LiveLine); $wiz.LiveLine = $null }
    if ($P.Completed) { return }
    $text = if ($P.Status) { "$($P.Activity) - $($P.Status)" } else { $P.Activity }
    $wiz.LiveLine = New-Line ('{0:HH:mm:ss}  {1}' -f (Get-Date), $text) '#1A56C4'
    [void]$list.Items.Add($wiz.LiveLine)
    $list.ScrollIntoView($wiz.LiveLine)
}

function Update-Progress {
    param($P)
    if ($P.Live) { Update-LiveActivity $P }
    $c.ProgressActivity.Text = ("$($P.Activity)  -  $($P.Status)").Trim(' -')
    $bar = if ($P.Id -eq 0) { $c.OverallBar } else { $c.DetailBar }
    if ($P.Completed) { $bar.Value = 0; $bar.IsIndeterminate = $false; if ($P.Id -eq 0) { $c.ProgressActivity.Text = '' }; return }
    if ($P.PercentComplete -ge 0) { $bar.IsIndeterminate = $false; $bar.Value = [math]::Min($P.PercentComplete, 100) }
    else { $bar.IsIndeterminate = $true }
}

function Set-Banner {
    param([string]$Status, [string]$Text)
    $bg, $fg = switch ($Status) {
        'Done'    { '#E3F4E7', '#1B5E20' }
        'Partial' { '#FFF3DC', '#8A5A00' }
        'Warn'    { '#FDE8E6', '#A01A12' }
        'Error'   { '#FBE3E1', '#B0241B' }
        'Running' { '#E4EEFB', '#1A56C4' }
        'Blocked' { '#EDEEF0', '#5B6067' }
        default   { '#EDEEF0', '#3A3F45' }
    }
    $c.StepBanner.Background = $bg
    $c.StepBannerText.Foreground = $fg
    $c.StepBannerText.Text = $Text
}

function Get-DryRun { [bool]$c.DryRunCheck.IsChecked }

function Set-Busy {
    param([bool]$Busy)
    $wiz.Running = $Busy
    $c.CancelBtn.IsEnabled = $Busy
    foreach ($n in 'BrowseWorkBtn', 'WorkFolderBox', 'SignInBtn', 'SignOutBtn', 'DeviceCodeCheck', 'TenantBox',
        'ScopeWipeCheck', 'ScopeBitLockerCheck', 'DryRunCheck', 'NavDryRunCheck', 'RecentDaysBox', 'WindowsOnlyCheck',
        'StepRunBtn', 'StepRefreshBtn', 'BackBtn', 'NextBtn', 'RailList',
        'GridAllBtn', 'GridNoneBtn', 'GridSafeBtn', 'GridRemoveBtn',
        'InFileBrowse', 'InFileLoadBtn', 'InPasteLoadBtn', 'InPasteClipBtn', 'InPasteClearBtn',
        'InManualLoadBtn', 'InManualClearBtn', 'InWorkBrowse', 'InWorkLoadBtn', 'InWorkSaveBtn', 'InClearBtn') {
        if ($c[$n]) { $c[$n].IsEnabled = -not $Busy }
    }
    if (-not $Busy) { Update-RunButton; Update-NavButtons }
}

# ----------------------------------------------------------------------------
# dry run / execute chrome
# ----------------------------------------------------------------------------
function Update-ModeChrome {
    <#
        The dry-run switch is the single most important control in this window,
        so it is visible in three places at once: the rail, the nav bar and the
        Setup card. They are all the same setting.
    #>
    param([switch]$FromNav)
    $dry = if ($FromNav) { [bool]$c.NavDryRunCheck.IsChecked } else { [bool]$c.DryRunCheck.IsChecked }

    # keep the two checkboxes in step without bouncing events between them
    if ([bool]$c.DryRunCheck.IsChecked -ne $dry) { $c.DryRunCheck.IsChecked = $dry }
    if ([bool]$c.NavDryRunCheck.IsChecked -ne $dry) { $c.NavDryRunCheck.IsChecked = $dry }

    if ($dry) {
        $c.RailModeBox.Background   = '#16341E'
        $c.RailModeTitle.Text       = 'DRY RUN'
        $c.RailModeTitle.Foreground = '#7EE787'
        $c.RailModeText.Text        = 'Nothing is changed in the tenant.'
        $c.RailModeText.Foreground  = '#B9CBB9'
        $c.NavModeBox.Background    = '#EAF7EE'
        $c.NavModeBox.BorderBrush   = '#A7D7B0'
        $c.NavModeText.Text         = 'Dry run - nothing is changed'
        $c.NavModeText.Foreground   = '#1B5E20'
        $c.DryRunCard.Background    = '#EAF7EE'
        $c.DryRunCard.BorderBrush   = '#A7D7B0'
        $c.DryRunTitle.Text         = 'Dry run is ON'
        $c.DryRunTitle.Foreground   = '#1B5E20'
        $c.DryRunText.Foreground    = '#33513A'
        $c.DryRunText.Text          = 'Every step still runs end to end and every device is still checked - only the delete, wipe and unassign calls are held back. Turn this off when the dry run looks right.'
    }
    else {
        $c.RailModeBox.Background   = '#3B1B1B'
        $c.RailModeTitle.Text       = 'RUNNING FOR REAL'
        $c.RailModeTitle.Foreground = '#FF9C94'
        $c.RailModeText.Text        = 'Deletes are permanent and cannot be undone.'
        $c.RailModeText.Foreground  = '#E0BDBA'
        $c.NavModeBox.Background    = '#FBE3E1'
        $c.NavModeBox.BorderBrush   = '#E29A93'
        $c.NavModeText.Text         = 'RUNNING FOR REAL - deletes are permanent'
        $c.NavModeText.Foreground   = '#A01A12'
        $c.DryRunCard.Background    = '#FBE3E1'
        $c.DryRunCard.BorderBrush   = '#E29A93'
        $c.DryRunTitle.Text         = 'Dry run is OFF - this session changes the tenant'
        $c.DryRunTitle.Foreground   = '#A01A12'
        $c.DryRunText.Foreground    = '#7A2A24'
        $c.DryRunText.Text          = 'Steps 3 to 7 will delete Intune devices, Autopilot registrations and Entra ID device objects for real. Deleted registrations cannot be restored - the devices have to be re-registered from a hardware hash.'
    }
    Update-StepModeCard
    Update-RunButton
}

function Update-StepModeCard {
    if ($wiz.Index -lt 1 -or -not $wiz.CurrentKey) { $c.StepModeCard.Visibility = 'Collapsed'; return }
    $meta = $wiz.Catalog | Where-Object Key -eq (Get-RunStepKey $wiz.CurrentKey) | Select-Object -First 1
    if (-not $meta -or -not $meta.Destructive) { $c.StepModeCard.Visibility = 'Collapsed'; return }

    $c.StepModeCard.Visibility = 'Visible'
    $n = @($wiz.Devices | Where-Object Apply).Count
    if (Get-DryRun) {
        $c.StepModeCard.Background  = '#EAF7EE'
        $c.StepModeCard.BorderBrush = '#A7D7B0'
        $c.StepModeTitle.Text       = 'Dry run - this changes nothing'
        $c.StepModeTitle.Foreground = '#1B5E20'
        $c.StepModeText.Foreground  = '#33513A'
        $c.StepModeText.Text = "Running this step now checks all $n ticked device(s) and reports what it would do to each of them, without sending a single delete to the tenant. Untick 'Dry run' in the bar below when the result looks right."
    }
    else {
        $c.StepModeCard.Background  = '#FBE3E1'
        $c.StepModeCard.BorderBrush = '#E29A93'
        $c.StepModeTitle.Text       = 'This runs for real'
        $c.StepModeTitle.Foreground = '#A01A12'
        $c.StepModeText.Foreground  = '#7A2A24'
        $c.StepModeText.Text = "Running this step changes $n device(s) in the tenant, permanently. You will be asked to confirm once more."
    }
}

# ----------------------------------------------------------------------------
# config persistence
# ----------------------------------------------------------------------------
function Save-Config {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        [pscustomobject]@{
            WorkFolder     = $c.WorkFolderBox.Text
            RecentDays     = $c.RecentDaysBox.Text
            WindowsOnly    = [bool]$c.WindowsOnlyCheck.IsChecked
            TenantId       = $c.TenantBox.Text
            UseDeviceCode  = [bool]$c.DeviceCodeCheck.IsChecked
            ScopeWipe      = [bool]$c.ScopeWipeCheck.IsChecked
            ScopeBitLocker = [bool]$c.ScopeBitLockerCheck.IsChecked
        } | ConvertTo-Json | Set-Content -Path $ConfigPath
    }
    catch { }
}

function Load-Config {
    # NB: the dry-run switch is deliberately NOT restored. Every session starts
    # safe, whatever the last one was set to.
    if (-not (Test-Path $ConfigPath)) { return }
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.WorkFolder) { $c.WorkFolderBox.Text = $cfg.WorkFolder }
        if ($cfg.RecentDays) { $c.RecentDaysBox.Text = $cfg.RecentDays }
        if ($cfg.TenantId)   { $c.TenantBox.Text = $cfg.TenantId }
        if ($null -ne $cfg.WindowsOnly)    { $c.WindowsOnlyCheck.IsChecked = [bool]$cfg.WindowsOnly }
        if ($null -ne $cfg.UseDeviceCode)  { $c.DeviceCodeCheck.IsChecked = [bool]$cfg.UseDeviceCode }
        if ($null -ne $cfg.ScopeWipe)      { $c.ScopeWipeCheck.IsChecked = [bool]$cfg.ScopeWipe }
        if ($null -ne $cfg.ScopeBitLocker) { $c.ScopeBitLockerCheck.IsChecked = [bool]$cfg.ScopeBitLocker }
    }
    catch { }
}

# ----------------------------------------------------------------------------
# setup page
# ----------------------------------------------------------------------------
function Get-WorkFolder {
    $t = [string]$c.WorkFolderBox.Text
    if ($t) { return $t.Trim() }
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'DeviceCleanUpper'
}

function Get-RecentDays {
    $v = 30
    if (-not [int]::TryParse([string]$c.RecentDaysBox.Text, [ref]$v)) { $v = 30 }
    if ($v -lt 0) { $v = 0 }
    $v
}

function Refresh-Setup {
    $folder = Get-WorkFolder
    if (Test-Path -LiteralPath $folder) {
        $c.WorkFolderStatus.Text = "OK - $folder"
        $c.WorkFolderStatus.Foreground = '#1B7F35'
    }
    else {
        $c.WorkFolderStatus.Text = "Will be created on the first run: $folder"
        $c.WorkFolderStatus.Foreground = '#A25A00'
    }
    $c.ScopeList.Text = 'Graph scopes: ' + ((Get-RequestedScopes) -join ', ')
    Update-SignInChrome
}

function Get-RequestedScopes {
    $a = @{}
    if ($c.ScopeWipeCheck.IsChecked)      { $a.IncludeWipe = $true }
    if ($c.ScopeBitLockerCheck.IsChecked) { $a.IncludeBitLocker = $true }
    @(Get-DCURequiredScopes @a)
}

function Update-SignInChrome {
    $s = $wiz.SignIn
    if ($s -and $s.SignedIn) {
        $c.SignInStatus.Text = "Signed in as $($s.Account)" +
            $(if ($s.TenantDomain) { "  -  tenant $($s.TenantDomain)" } else { '' }) +
            $(if ($s.TenantId) { "  ($($s.TenantId))" } else { '' })
        $c.SignInStatus.Foreground = '#1B7F35'
        $c.SignInBtn.Content = 'Sign in again'
        $missing = @($s.MissingScopes)
        if ($missing.Count) {
            $c.SignInStatus.Text += "`r`nConsent is missing for: $($missing -join ', '). Tick the extra permissions above and sign in again."
            $c.SignInStatus.Foreground = '#A25A00'
        }
    }
    else {
        $msg = if ($s -and $s.Message) { $s.Message } else { 'Not signed in. Nothing can be looked up or deleted until you do.' }
        $c.SignInStatus.Text = $msg
        $c.SignInStatus.Foreground = '#A25A00'
        $c.SignInBtn.Content = 'Sign in'
    }
    $c.SignOutBtn.IsEnabled = [bool]($s -and $s.SignedIn) -and -not $wiz.Running
    Update-NavButtons
}

function Test-SignedIn { [bool]($wiz.SignIn -and $wiz.SignIn.SignedIn) }

# ----------------------------------------------------------------------------
# device list <-> module records
# ----------------------------------------------------------------------------
$DeviceFields = @(
    'Key', 'Raw', 'Name', 'Serial', 'Note', 'Source', 'Match', 'MatchDetail'
    'IntuneId', 'IntuneName', 'IntuneUser', 'IntuneLastSync', 'IntuneEnrolled', 'IntuneOs'
    'IntuneModel', 'IntuneOwner', 'IntuneCompliance'
    'AzureAdDeviceId', 'EntraObjectId', 'EntraName', 'EntraTrust', 'EntraLastSignIn', 'EntraEnabled'
    'AutopilotId', 'AutopilotGroupTag', 'AutopilotEnrollment', 'AutopilotUser'
    'LastActivity', 'DaysSinceActivity', 'Warn', 'Flag'
    'IntuneState', 'AutopilotState', 'EntraState', 'BitLockerState', 'Result', 'Apply'
)

function ConvertTo-WorkerRows {
    <# plain copies for the worker - it must never touch an object bound to the grid #>
    $out = foreach ($d in $wiz.Devices) {
        $h = [ordered]@{}
        foreach ($f in $DeviceFields) { $h[$f] = $d.$f }
        [pscustomobject]$h
    }
    @($out)
}

function Sync-DeviceRows {
    <# rebuild the bound collection from what the worker returned #>
    param($Rows)
    $wiz.Devices.Clear()
    foreach ($r in @($Rows)) {
        $d = [DcuDevice]::new()
        foreach ($f in $DeviceFields) {
            $v = $r.PSObject.Properties[$f]
            if (-not $v) { continue }
            if ($f -eq 'DaysSinceActivity') { $d.$f = if ($null -eq $v.Value -or "$($v.Value)" -eq '') { -1 } else { [int]$v.Value } }
            elseif ($f -in 'Warn', 'Apply')  { $d.$f = [bool]$v.Value }
            else { $d.$f = [string]$v.Value }
        }
        $d.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'Apply') { Update-GridSummary } })
        $wiz.Devices.Add($d)
    }
    $wiz.Dirty = $true
    Update-GridSummary
}

function Update-GridSummary {
    $total   = $wiz.Devices.Count
    $ticked  = @($wiz.Devices | Where-Object Apply).Count
    $warned  = @($wiz.Devices | Where-Object Warn).Count
    $tickedW = @($wiz.Devices | Where-Object { $_.Apply -and $_.Warn }).Count

    $t = "$total device(s) on the list, $ticked ticked."
    if ($warned) { $t += "  $warned flagged" + $(if ($tickedW) { ", $tickedW of them ticked" } else { ' (none ticked)' }) + '.' }
    if ($tickedW) { $t += "  A ticked flagged device is still acted on - check the Warning column before you run a destructive step." }
    $c.GridSummary.Text = $t
    $c.GridSummary.Foreground = if ($tickedW) { '#A25A00' } else { '#555' }

    Update-SectionChrome   # half 2 of page 1 unlocks as soon as the list is not empty
    Update-RunButton
    Update-StepModeCard
    Update-NavButtons      # the pages after 1 unlock once the whole list is looked up
}

function Update-RunButton {
    if ($wiz.Index -lt 1) { return }
    if (-not $wiz.CurrentKey) { return }
    $key = Get-RunStepKey $wiz.CurrentKey
    $meta = $wiz.Catalog | Where-Object Key -eq $key | Select-Object -First 1
    $c.StepRunBtn.Visibility = 'Visible'

    $n = if ($key -in $WholeListSteps) { $wiz.Devices.Count }
         else { @($wiz.Devices | Where-Object Apply).Count }

    $label = switch ($key) {
        'Lookup'          { "Look up $n device(s)" }
        'Backup'          { "Export $n device(s)" }
        'Wipe'            { $m = Get-OptionValue 'Mode' 'Wipe'; "$m $n device(s)" }
        'IntuneDelete'    { "Delete $n device(s) from Intune" }
        'AutopilotDelete' { "Remove $n Autopilot registration(s)" }
        'AutopilotSync'   { $p = @($wiz.Devices | Where-Object AutopilotState -eq 'Deletion pending').Count
                            # it only syncs when a registration is still there, so the label promises no sync
                            if ($p) { "Confirm $p Autopilot removal(s)" } else { 'Check for Autopilot removals' } }
        'EntraDelete'     { "Delete $n Entra ID object(s)" }
        'FinalCheck'      { "Check $n device(s)" }
        default           { 'Run this step' }
    }
    # the sync is not destructive, but a dry run holds it back all the same
    if (($meta -and $meta.Destructive -or $key -eq 'AutopilotSync') -and (Get-DryRun)) { $label = "Simulate: $label" }
    # blue for read-only and dry-run steps, red when this click changes the tenant
    $c.StepRunBtn.Background = if ($meta -and $meta.Destructive -and -not (Get-DryRun)) { '#C0281F' } else { '#1A56C4' }
    $c.StepRunBtn.Content = $label
    $c.StepRunBtn.IsEnabled = (-not $wiz.Running) -and ($n -gt 0) -and (Test-SignedIn)
    if (-not (Test-SignedIn)) { $c.StepRunBtn.Content = 'Sign in on the Setup page first' }
    elseif ($n -eq 0) {
        # a whole-list step has nothing to tick - it is the list itself that is missing
        $c.StepRunBtn.Content = if ($key -in $WholeListSteps) { 'Add devices to the list first' } else { 'Tick at least one device' }
    }
}

function Get-OptionValue {
    param([string]$Name, $Default)
    if ($wiz.OptControls.ContainsKey($Name)) {
        $e = $wiz.OptControls[$Name]
        switch ($e.Type) {
            'bool'   { return [bool]$e.Control.IsChecked }
            'int'    { $v = 0; [void][int]::TryParse($e.Control.Text, [ref]$v); return $v }
            'choice' { return [string]$e.Control.SelectedItem }
            default  { return [string]$e.Control.Text }
        }
    }
    $Default
}

# ----------------------------------------------------------------------------
# step status (rail + banner)
# ----------------------------------------------------------------------------
function Refresh-Steps {
    $rows = @(ConvertTo-WorkerRows)
    $map = @{}
    try {
        foreach ($s in Get-DCUStatus -Devices $rows -SignedIn (Test-SignedIn)) { $map[$s.Key] = $s }
    }
    catch { Add-LogLine ([pscustomobject]@{ Timestamp = Get-Date; Level = 'Warn'; Message = "Status: $($_.Exception.Message)" }) }

    foreach ($row in $wiz.Steps) {
        if ($row.Key -eq '__setup') {
            $row.Status = if (Test-SignedIn) { 'Done' } else { 'Ready' }
            $row.Detail = if (Test-SignedIn) { [string]$wiz.SignIn.TenantDomain } else { 'sign in first' }
            continue
        }
        # page 1 covers two catalogue steps: it is only really done once the
        # lookup has run, so that is the status it wears
        $statusKey = if ($row.Key -eq $MergedPageKey -and $wiz.Devices.Count) { $MergedRunKey } else { $row.Key }
        if ($map.ContainsKey($statusKey)) { $row.Status = $map[$statusKey].Status; $row.Detail = $map[$statusKey].Detail }
    }
    if ($wiz.Index -ge 1 -and -not $wiz.Running) {
        $cur = $wiz.Steps[$wiz.Index]
        Set-Banner $cur.Status (Format-BannerText $cur)
    }
    Update-SectionChrome
}

function Format-BannerText {
    param($Row)
    switch ($Row.Status) {
        'Done'    { "Done. $($Row.Detail)" }
        'Partial' { "Partly done. $($Row.Detail)" }
        'Blocked' { "Not available yet - $($Row.Detail)." }
        'Error'   { "Last run ended with an error. $($Row.Detail)" }
        default   { if ($Row.Detail) { "Ready. $($Row.Detail)." } else { 'Ready to run.' } }
    }
}

# ----------------------------------------------------------------------------
# option controls + result rendering
# ----------------------------------------------------------------------------
function New-CopyText {
    <# a borderless read-only TextBox that reads like a TextBlock but is selectable / Ctrl+C copyable #>
    param([string]$Text, [string]$Color = '#1B1B1B', [double]$FontSize = 0, [string]$FontWeight = 'Normal')
    $t = [System.Windows.Controls.TextBox]::new()
    $t.Text = [string]$Text
    $t.Foreground = $Color
    $t.IsReadOnly = $true; $t.IsReadOnlyCaretVisible = $false; $t.AcceptsReturn = $true; $t.IsTabStop = $false
    $t.BorderThickness = '0'; $t.Background = 'Transparent'; $t.Padding = '0'
    $t.TextWrapping = 'Wrap'; $t.Cursor = 'IBeam'
    $t.HorizontalScrollBarVisibility = 'Disabled'
    if ($FontSize -gt 0) { $t.FontSize = $FontSize }
    if ($FontWeight -ne 'Normal') { $t.FontWeight = $FontWeight }
    $t
}

function Add-KV {
    param([System.Windows.Controls.Panel]$Panel, [string]$Key, [string]$Value, [string]$Color = '#1B1B1B')
    $g = [System.Windows.Controls.Grid]::new()
    $g.Margin = '0,2,0,2'
    $g.ColumnDefinitions.Add(([System.Windows.Controls.ColumnDefinition]@{ Width = '180' }))
    $g.ColumnDefinitions.Add(([System.Windows.Controls.ColumnDefinition]@{ Width = '*' }))
    $k = [System.Windows.Controls.TextBlock]::new(); $k.Text = $Key; $k.Foreground = '#666'
    $v = New-CopyText -Text $Value -Color $Color
    [System.Windows.Controls.Grid]::SetColumn($v, 1)
    [void]$g.Children.Add($k); [void]$g.Children.Add($v)
    [void]$Panel.Children.Add($g)
}

function Add-InfoCard {
    param([System.Windows.Controls.Panel]$Panel, [string]$Title, [string]$Body, [string]$Bg = '#E8F0FE', [string]$Fg = '#174EA6')
    $b = [System.Windows.Controls.Border]::new()
    $b.Background = $Bg; $b.Padding = '10,8'; $b.CornerRadius = 3; $b.Margin = '0,0,0,10'
    $sp = [System.Windows.Controls.StackPanel]::new()
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Title; $t.FontWeight = 'SemiBold'; $t.Foreground = $Fg; $t.Margin = '0,0,0,4'
    [void]$sp.Children.Add($t)
    [void]$sp.Children.Add((New-CopyText -Color '#33373D' -FontSize 12 -Text $Body))
    $b.Child = $sp
    [void]$Panel.Children.Add($b)
}

function New-OptControl {
    <# label + help + input for one option spec, added to $Panel and registered in $wiz.OptControls #>
    param($Panel, [string]$OptName, $Spec, $Init)
    $lbl = [System.Windows.Controls.TextBlock]::new()
    $lbl.Text = $Spec.Label; $lbl.Margin = '0,8,0,2'; $lbl.Foreground = '#333'; $lbl.FontWeight = 'SemiBold'
    [void]$Panel.Children.Add($lbl)
    if ($Spec.Help) {
        $hlp = New-CopyText -Text ([string]$Spec.Help) -Color '#5B6067' -FontSize 11
        $hlp.Margin = '0,0,0,3'
        [void]$Panel.Children.Add($hlp)
    }
    if ($Spec.Type -eq 'bool') {
        $ctl = [System.Windows.Controls.CheckBox]::new(); $ctl.IsChecked = [bool]$Init; $ctl.Content = 'enabled'
    }
    elseif ($Spec.Type -eq 'choice') {
        $ctl = [System.Windows.Controls.ComboBox]::new()
        foreach ($ch in $Spec.Choices) { [void]$ctl.Items.Add($ch) }
        $ctl.SelectedItem = $Init
        $ctl.MaxWidth = 220; $ctl.HorizontalAlignment = 'Left'
    }
    else {
        $ctl = [System.Windows.Controls.TextBox]::new(); $ctl.Text = [string]$Init; $ctl.Padding = '3'
    }
    [void]$Panel.Children.Add($ctl)
    $wiz.OptControls[$OptName] = @{ Control = $ctl; Type = $Spec.Type }

    # options that change what the Run button says / does
    if ($Spec.Type -eq 'bool')   { $ctl.Add_Checked({ Update-RunButton }); $ctl.Add_Unchecked({ Update-RunButton }) }
    if ($Spec.Type -eq 'choice') { $ctl.Add_SelectionChanged({ Update-RunButton }) }

    if ($Spec.Type -eq 'folder') {
        $box = $ctl
        $btn = [System.Windows.Controls.Button]::new()
        $btn.Content = 'Browse...'; $btn.Margin = '0,3,0,0'; $btn.HorizontalAlignment = 'Left'
        $btn.Add_Click({
            $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
            if ($box.Text -and (Test-Path $box.Text)) { $dlg.SelectedPath = $box.Text }
            if ($dlg.ShowDialog() -eq 'OK') { $box.Text = $dlg.SelectedPath }
        }.GetNewClosure())
        [void]$Panel.Children.Add($btn)
    }
}

function Add-OptGroup {
    <# a collapsible titled section; consecutive items sharing a Pair go side by side #>
    param([string]$GroupName, [object[]]$Items, [switch]$Expanded)
    $border = [System.Windows.Controls.Border]::new()
    $border.BorderBrush = '#DADDE1'; $border.BorderThickness = '1'; $border.CornerRadius = 3
    $border.Padding = '12,4,12,10'; $border.Margin = '0,16,0,2'

    $exp = [System.Windows.Controls.Expander]::new()
    $exp.IsExpanded = [bool]$Expanded
    $hdr = [System.Windows.Controls.TextBlock]::new()
    $hdr.Text = $GroupName; $hdr.FontWeight = 'SemiBold'; $hdr.FontSize = 13; $hdr.Foreground = '#333'
    $exp.Header = $hdr

    $gsp = [System.Windows.Controls.StackPanel]::new()
    $gsp.Margin = '0,4,0,0'
    $exp.Content = $gsp
    $border.Child = $exp

    $lastSub = $null
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $it = $Items[$i]
        if ($it.Spec.Sub -and $it.Spec.Sub -ne $lastSub) {
            $sh = [System.Windows.Controls.TextBlock]::new()
            $sh.Text = $it.Spec.Sub; $sh.Foreground = '#5B6067'; $sh.FontSize = 11
            $sh.TextWrapping = 'Wrap'; $sh.Margin = '0,12,0,0'
            [void]$gsp.Children.Add($sh)
            $lastSub = $it.Spec.Sub
        }
        $next = if ($i + 1 -lt $Items.Count) { $Items[$i + 1] } else { $null }
        if ($it.Spec.Pair -and $next -and $next.Spec.Pair -eq $it.Spec.Pair) {
            $grid = [System.Windows.Controls.Grid]::new(); $grid.Margin = '0,2,0,0'
            foreach ($w in 1, 2) { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = '*'; $grid.ColumnDefinitions.Add($cd) }
            $left = [System.Windows.Controls.StackPanel]::new();  $left.Margin = '0,0,6,0'
            $right = [System.Windows.Controls.StackPanel]::new(); $right.Margin = '6,0,0,0'
            [System.Windows.Controls.Grid]::SetColumn($right, 1)
            New-OptControl $left  $it.Name   $it.Spec   $it.Init
            New-OptControl $right $next.Name $next.Spec $next.Init
            [void]$grid.Children.Add($left); [void]$grid.Children.Add($right)
            [void]$gsp.Children.Add($grid)
            $i++
        }
        else {
            New-OptControl $gsp $it.Name $it.Spec $it.Init
        }
    }
    [void]$c.StepOptionsPanel.Children.Add($border)
}

function Build-OptionControls {
    param([string]$Key)
    $wiz.OptControls = @{}
    $c.StepOptionsPanel.Children.Clear()
    $c.StepInfoPanel.Children.Clear()

    if ($StepInfo.ContainsKey($Key)) {
        Add-InfoCard $c.StepInfoPanel 'How this step works' $StepInfo[$Key]
    }

    # the device-input step has its own panel of tabs instead of generic fields
    if ($Key -eq 'DeviceInput') { return }

    $meta = $wiz.Catalog | Where-Object Key -eq $Key | Select-Object -First 1
    if (-not $meta) { return }

    # the working folder is the default for both export folders
    $prefill = @{ ExportFolder = ''; ReportFolder = '' }

    $doneGroups = @{}
    foreach ($optName in $meta.Options.Keys) {
        $spec = $meta.Options[$optName]
        if ($spec.Group) {
            if ($doneGroups.ContainsKey($spec.Group)) { continue }
            $doneGroups[$spec.Group] = $true
            $members = foreach ($k in $meta.Options.Keys) {
                if ($meta.Options[$k].Group -ne $spec.Group) { continue }
                @{ Name = $k; Spec = $meta.Options[$k]
                   Init = $(if ($prefill.ContainsKey($k)) { $prefill[$k] } else { $meta.Options[$k].Default }) }
            }
            $open = [bool](@($members | Where-Object { $_.Spec.GroupOpen }).Count)
            Add-OptGroup -GroupName $spec.Group -Items @($members) -Expanded:$open
            continue
        }
        $init = if ($prefill.ContainsKey($optName)) { $prefill[$optName] } else { $spec.Default }
        New-OptControl $c.StepOptionsPanel $optName $spec $init
    }
    if ($meta.Options.Keys.Count -eq 0) {
        $t = [System.Windows.Controls.TextBlock]::new(); $t.Text = 'No options for this step.'; $t.Foreground = '#999'
        [void]$c.StepOptionsPanel.Children.Add($t)
    }
}

function Get-OptionValues {
    $r = @{}
    foreach ($name in $wiz.OptControls.Keys) {
        $e = $wiz.OptControls[$name]; $ctl = $e.Control
        switch ($e.Type) {
            'bool'   { $r[$name] = [bool]$ctl.IsChecked }
            'int'    { $v = 0; [void][int]::TryParse($ctl.Text, [ref]$v); $r[$name] = $v }
            'choice' { $r[$name] = [string]$ctl.SelectedItem }
            default  { if ($ctl.Text) { $r[$name] = $ctl.Text } }
        }
    }
    $r
}

function Show-Result {
    param($Summary, [string]$Key)
    $c.StepResultPanel.Children.Clear()
    if (-not $Summary) { return }
    $wiz.LastResults[$Key] = $Summary

    $hdr = [System.Windows.Controls.TextBlock]::new()
    $hdr.Text = 'Result'; $hdr.FontWeight = 'SemiBold'; $hdr.FontSize = 14; $hdr.Margin = '0,0,0,6'
    [void]$c.StepResultPanel.Children.Add($hdr)

    $card = [System.Windows.Controls.Border]::new()
    $card.Background = '#F6F8FA'; $card.Padding = '12,10'; $card.CornerRadius = 3
    $sp = [System.Windows.Controls.StackPanel]::new()

    foreach ($p in $Summary.PSObject.Properties) {
        if ($p.Name -in 'Step', 'Rows', 'Checklist', 'Columns') { continue }
        $val = $p.Value
        if ($null -eq $val -or "$val" -eq '') { continue }
        $col = '#1B1B1B'
        if ($p.Name -in 'Failed', 'NotFound', 'NotReady', 'BitLockerErrors' -and "$val" -match '^\d+$' -and [int]"$val" -gt 0) { $col = '#C0281F' }
        if ($p.Name -in 'RecentlyActive', 'HybridJoined', 'Warned', 'NeedsOnPremAd', 'StillPending' -and "$val" -match '^\d+$' -and [int]"$val" -gt 0) { $col = '#A25A00' }
        if ($p.Name -eq 'DryRun') { $col = if ([bool]$val) { '#1A56C4' } else { '#A01A12' } }
        Add-KV $sp $p.Name "$val" $col
    }

    if ($Summary.PSObject.Properties.Name -contains 'Checklist' -and $Summary.Checklist) {
        $t = [System.Windows.Controls.TextBlock]::new()
        $t.Text = 'Handover checklist'; $t.FontWeight = 'SemiBold'; $t.Margin = '0,10,0,4'
        [void]$sp.Children.Add($t)
        $tb = [System.Windows.Controls.TextBox]::new()
        $tb.Text = [string]$Summary.Checklist; $tb.IsReadOnly = $true; $tb.FontFamily = 'Consolas'; $tb.FontSize = 12
        $tb.MaxHeight = 260; $tb.VerticalScrollBarVisibility = 'Auto'; $tb.TextWrapping = 'NoWrap'
        $tb.HorizontalScrollBarVisibility = 'Auto'
        [void]$sp.Children.Add($tb)
    }

    $card.Child = $sp
    [void]$c.StepResultPanel.Children.Add($card)
}

# ----------------------------------------------------------------------------
# navigation
# ----------------------------------------------------------------------------
function Update-SectionChrome {
    <#
        Page 1 shows its two halves as numbered cards with an arrow between them,
        and half 2 stays greyed out until half 1 has produced a list. Every other
        page strips the wrapper back to a plain panel - same trick the Tenant
        Migrator uses for its app-registration pages.
    #>
    if ($wiz.CurrentKey -ne $MergedPageKey) {
        $c.InputPanel.Visibility    = 'Collapsed'
        $c.SectionArrow.Visibility  = 'Collapsed'
        $c.SectionBHead.Visibility  = 'Collapsed'
        $c.SectionBHint.Visibility  = 'Collapsed'
        $c.SectionB.BorderThickness = '0'
        $c.SectionB.Background      = 'Transparent'
        $c.SectionB.Padding         = '0'
        $c.SectionB.Margin          = '0'
        return
    }

    $have = $wiz.Devices.Count

    $c.InputPanel.Visibility   = 'Visible'
    $c.SectionArrow.Visibility = 'Visible'
    $c.SectionBHead.Visibility = 'Visible'
    $c.SectionBHint.Visibility = 'Visible'
    $c.SectionB.BorderThickness = '1'
    $c.SectionB.CornerRadius    = 3
    $c.SectionB.Padding         = '12,10'
    $c.SectionB.Margin          = '0,0,0,4'

    $c.SectionADone.Text = if ($have) { "$have device(s) on the list" } else { '' }

    if ($have) {
        # half 1 done, half 2 is the live one
        $c.SectionB.BorderBrush     = '#9DBEEA'
        $c.SectionB.Background      = '#F3F7FD'
        $c.SectionBBadge.Background = '#1F2A3A'
        $c.SectionBHeader.Foreground = '#1B1B1B'
        $c.SectionArrow.Foreground   = '#1A56C4'
        $c.SectionBHint.Text = 'Every device above is looked up in Intune, Windows Autopilot and Entra ID. Nothing is changed - this is what tells you what you are about to delete, and flags the devices that still look like they are in use.'
    }
    else {
        # nothing to look up yet - half 2 is visibly not your turn
        $c.SectionB.BorderBrush     = '#E3E5E8'
        $c.SectionB.Background      = '#FAFBFC'
        $c.SectionBBadge.Background = '#B4BCC6'
        $c.SectionBHeader.Foreground = '#8A9099'
        $c.SectionArrow.Foreground   = '#C6CCD3'
        $c.SectionBHint.Text = 'Not yet - put some devices on the list above first.'
    }
}

function Build-StepPage {
    param([int]$Index)
    $row = $wiz.Steps[$Index]
    $wiz.CurrentKey = $row.Key
    $c.StepTitle.Text = "$($row.Number)   $($row.Name)"
    $c.StepDesc.Text  = [string]$StepDesc[$row.Key]
    $c.StepActivityList.Items.Clear()
    $c.StepResultPanel.Children.Clear()

    # on the merged page the options and the info card belong to the step the
    # Run button drives, not to the page key
    Build-OptionControls -Key (Get-RunStepKey $row.Key)
    Update-SectionChrome
    $c.GridHeader.Text = if ($row.Key -eq $MergedPageKey) { 'The list' } else { 'Devices - tick the ones this step should touch' }

    Set-Banner $row.Status (Format-BannerText $row)
    if ($row.Key -eq 'AutopilotDelete') {
        $c.StepBannerText.Text += '  This is the step that releases the serial numbers.'
    }
    if (-not (Test-SignedIn) -and $row.Key -ne 'DeviceInput') {
        Set-Banner 'Blocked' 'Not signed in. Go back to Setup and sign in to the tenant these devices are leaving.'
    }

    if ($wiz.LastResults.ContainsKey($row.Key)) { Show-Result $wiz.LastResults[$row.Key] $row.Key }
    Update-ModeChrome
    Update-GridSummary
}

function Navigate {
    param([int]$Index)
    if ($wiz.Navigating) { return }
    if ($Index -lt 0 -or $Index -ge $wiz.Steps.Count) { return }
    if ($wiz.Running) { Set-Status 'Wait for the running step to finish.'; return }

    $lim = Get-NavLimit
    if ($Index -gt $lim.Max -and $Index -ne $wiz.Index) {
        Set-Status $lim.Reason
        # put the rail highlight back on the page we are staying on
        $wiz.Navigating = $true
        try { $c.RailList.SelectedIndex = $wiz.Index } finally { $wiz.Navigating = $false }
        return
    }

    $wiz.Navigating = $true
    try {
        $wiz.Index = $Index
        $c.RailList.SelectedIndex = $Index
        if ($Index -eq 0) {
            $c.PageSetup.Visibility = 'Visible'; $c.PageStep.Visibility = 'Collapsed'
            $wiz.CurrentKey = '__setup'
            Refresh-Setup
        }
        else {
            $c.PageSetup.Visibility = 'Collapsed'; $c.PageStep.Visibility = 'Visible'
            Build-StepPage $Index
        }
        Update-NavButtons
    }
    finally { $wiz.Navigating = $false }
}

function Get-NavLimit {
    <#
        How far forward the wizard may go right now, and why not further:
        Setup until signed in, page 1 until every device on the list has been
        looked up. Every later step works on the lookup results - a delete run
        against a list nobody has checked is the mistake this tool exists to
        prevent.
    #>
    if (-not (Test-SignedIn)) {
        return @{ Max = 0; Reason = 'Sign in first - nothing can be looked up or deleted until you do.' }
    }
    $pageOne = 0
    for ($i = 0; $i -lt $wiz.Steps.Count; $i++) { if ($wiz.Steps[$i].Key -eq $MergedPageKey) { $pageOne = $i } }
    $total   = $wiz.Devices.Count
    # same test Get-DCUStatus uses for "looked up"
    $pending = @($wiz.Devices | Where-Object { $_.Match -eq 'Not looked up' }).Count
    if (-not $total) { return @{ Max = $pageOne; Reason = 'Put the devices on the list and look them up first.' } }
    if ($pending)    { return @{ Max = $pageOne; Reason = "Look up the devices first - $pending of $total not looked up yet." } }
    @{ Max = $wiz.Steps.Count - 1; Reason = '' }
}

function Update-NavButtons {
    <# Back / Next, the hint next to them, and the rail entries you cannot reach yet #>
    $lim = Get-NavLimit
    $idle = -not $wiz.Running
    $c.BackBtn.IsEnabled = $idle -and ($wiz.Index -gt 0)
    $c.NextBtn.IsEnabled = $idle -and ($wiz.Index -lt $lim.Max)

    $gated = $idle -and ($wiz.Index -ge $lim.Max) -and ($wiz.Index -lt $wiz.Steps.Count - 1)
    $c.NavHintText.Text       = if ($gated) { $lim.Reason } else { '' }
    $c.NavHintText.Visibility = if ($gated) { 'Visible' } else { 'Collapsed' }

    # containers only exist once the rail has rendered; ContentRendered calls this again
    for ($i = 0; $i -lt $wiz.Steps.Count; $i++) {
        $item = $c.RailList.ItemContainerGenerator.ContainerFromIndex($i)
        if ($item) { $item.IsEnabled = ($i -le $lim.Max) -or ($i -eq $wiz.Index) }
    }
}

# ----------------------------------------------------------------------------
# background runner
#
# ONE runspace for the whole session: Connect-MgGraph keeps its token in the
# runspace that signed in, so a fresh runspace per operation would mean a fresh
# sign-in per operation.
# ----------------------------------------------------------------------------
$worker = {
    param($ModulePath, $ModuleRoot, $Queue, $CancelRef, $Operation, $SessionArgs, $StepKey, $Verbose, $Devices, $Selection, $Extra)

    $env:PSModulePath = "$ModuleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    if (-not (Get-Module -Name DCU)) { Import-Module $ModulePath -Force }

    Register-DCULogSink      { param($e) $Queue.Enqueue([pscustomobject]@{ Kind = 'log';      Payload = $e }) }
    Register-DCUProgressSink { param($p) $Queue.Enqueue([pscustomobject]@{ Kind = 'progress'; Payload = $p }) }
    Set-DCUCancelToken $CancelRef
    Set-DCUVerboseLogging ([bool]$Verbose)

    try {
        $session = New-DCUSession @SessionArgs

        switch ($Operation) {
            'signin' {
                $connect = @{ Scopes = @($Extra.Scopes) }
                if ($Extra.TenantId)      { $connect.TenantId = $Extra.TenantId }
                if ($Extra.UseDeviceCode) { $connect.UseDeviceCode = $true }
                if ($Extra.Force)         { $connect.Force = $true }
                Connect-DCUGraph @connect | Out-Null
                $Queue.Enqueue([pscustomobject]@{ Kind = 'signin'; Payload = (Get-DCUSignInState -Scopes @($Extra.Scopes)) })
            }
            'signout' {
                Disconnect-DCUGraph
                $Queue.Enqueue([pscustomobject]@{ Kind = 'signin'; Payload = (Get-DCUSignInState) })
            }
            'state' {
                $Queue.Enqueue([pscustomobject]@{ Kind = 'signin'; Payload = (Get-DCUSignInState -Scopes @($Extra.Scopes)) })
            }
            'input-file' {
                $r = Import-DCUDeviceList -Path $Extra.Path -Sheet $Extra.Sheet -Existing @($Devices) -Session $session `
                    -SerialColumn $Extra.SerialColumn -NameColumn $Extra.NameColumn -NoteColumn $Extra.NoteColumn
                $Queue.Enqueue([pscustomobject]@{ Kind = 'done'; Payload = $r })
            }
            'input-text' {
                $r = Import-DCUDeviceList -Text $Extra.Text -Existing @($Devices) -Session $session
                $Queue.Enqueue([pscustomobject]@{ Kind = 'done'; Payload = $r })
            }
            'input-rows' {
                $r = Import-DCUDeviceList -Rows @($Extra.Rows) -Existing @($Devices) -Session $session
                $Queue.Enqueue([pscustomobject]@{ Kind = 'done'; Payload = $r })
            }
            'input-load' {
                $rows = @(Import-DCUWorkingSet -Path $Extra.Path)
                $Queue.Enqueue([pscustomobject]@{ Kind = 'done'
                        Payload = [pscustomobject]@{ Step = 'DeviceInput'; Source = $Extra.Path; Added = $rows.Count
                                                     Duplicates = 0; Unclassified = 0; Total = $rows.Count; Rows = $rows } })
            }
            'input-save' {
                $path = Save-DCUWorkingSet -Devices @($Devices) -Path $Extra.Path -Session $session
                $Queue.Enqueue([pscustomobject]@{ Kind = 'saved'; Payload = $path })
            }
            'step' {
                $fn = "Invoke-DCU$StepKey"
                $callArgs = @{ Session = $session; Devices = @($Devices) }
                if (@($Selection).Count) { $callArgs.Selection = @($Selection) }
                $summary = & $fn @callArgs
                # keep the on-disk list in step with what just happened
                try { Save-DCUWorkingSet -Devices @($summary.Rows) -Session $session | Out-Null } catch { }
                $Queue.Enqueue([pscustomobject]@{ Kind = 'done'; Payload = $summary })
            }
        }
    }
    catch [System.OperationCanceledException] { $Queue.Enqueue([pscustomobject]@{ Kind = 'cancelled' }) }
    catch { $Queue.Enqueue([pscustomobject]@{ Kind = 'error'; Payload = $_.Exception.Message }) }
    finally {
        Clear-DCUSinks
        $Queue.Enqueue([pscustomobject]@{ Kind = 'complete' })
    }
}

function Build-SessionArgs {
    param([string]$StepKey)
    $sa = @{
        WorkFolder  = Get-WorkFolder
        DryRun      = Get-DryRun
        RecentDays  = Get-RecentDays
        WindowsOnly = [bool]$c.WindowsOnlyCheck.IsChecked
    }
    if ($c.TenantBox.Text) { $sa.TenantId = $c.TenantBox.Text.Trim() }
    if ($StepKey) { $sa.StepOptions = @{ $StepKey = (Get-OptionValues) } }
    $sa
}

function Start-Run {
    param(
        [string]$Operation,
        [string]$StepKey,
        [string[]]$Selection,
        [hashtable]$Extra = @{},
        [string]$Status = 'Working...'
    )
    if ($wiz.Running) { return }

    $sa = Build-SessionArgs -StepKey $StepKey
    $wiz.CancelRef.Value = $false
    Save-Config
    Set-Busy $true
    if ($Operation -eq 'step') { $c.StepActivityList.Items.Clear() }
    Set-Status $Status
    if ($Operation -eq 'step') {
        $wiz.Steps[$wiz.Index].Status = 'Running'
        Set-Banner 'Running' $Status
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $wiz.Runspace
    [void]$ps.AddScript($worker).
        AddArgument($ModulePath).AddArgument($ModuleRoot).AddArgument($wiz.Queue).
        AddArgument($wiz.CancelRef).AddArgument($Operation).AddArgument($sa).AddArgument($StepKey).
        AddArgument([bool]$c.VerboseCheck.IsChecked).AddArgument(@(ConvertTo-WorkerRows)).
        AddArgument(@($Selection)).AddArgument($Extra)
    $wiz.Ps = $ps
    $wiz.Handle = $ps.BeginInvoke()
}

function Start-StepRun {
    <#
        The Run button. A destructive step outside a dry run asks once more,
        and says out loud how many of the ticked devices are flagged.
    #>
    if ($wiz.Index -lt 1) { return }
    $key = Get-RunStepKey $wiz.Steps[$wiz.Index].Key

    $wholeList = $key -in $WholeListSteps
    $ticked = if ($wholeList) { @($wiz.Devices) } else { @($wiz.Devices | Where-Object Apply) }
    if (-not $ticked.Count) {
        Set-Status $(if ($wholeList) { 'The device list is empty - add devices on step 1 first.' } else { 'Tick at least one device first.' })
        return
    }

    $meta = $wiz.Catalog | Where-Object Key -eq $key | Select-Object -First 1
    if ($meta -and $meta.Destructive -and -not (Get-DryRun) -and $env:DCU_WIZARD_SELFTEST -ne '1') {
        $warned = @($ticked | Where-Object Warn)
        $what = switch ($key) {
            'Wipe'            { "send a $(Get-OptionValue 'Mode' 'Wipe') to" }
            'IntuneDelete'    { 'delete from Intune' }
            'AutopilotDelete' { 'remove the Autopilot registration of' }
            'EntraDelete'     { 'delete the Entra ID device object of' }
            default           { 'change' }
        }
        $msg = "About to $what $($ticked.Count) device(s) in $($wiz.SignIn.TenantDomain).`n`nThis runs for real and cannot be undone."
        if ($warned.Count) {
            $msg += "`n`n$($warned.Count) of them are FLAGGED:"
            foreach ($w in ($warned | Select-Object -First 12)) { $msg += "`n  - $($w.Display)  ($($w.Flag))" }
            if ($warned.Count -gt 12) { $msg += "`n  ... and $($warned.Count - 12) more" }
        }
        $msg += "`n`nContinue?"
        $icon = if ($warned.Count) { [System.Windows.MessageBoxImage]::Warning } else { [System.Windows.MessageBoxImage]::Question }
        $ans = [System.Windows.MessageBox]::Show($msg, 'Device CleanUpper - this cannot be undone',
            [System.Windows.MessageBoxButton]::YesNo, $icon, [System.Windows.MessageBoxResult]::No)
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { Set-Status 'Cancelled - nothing was changed.'; return }
    }

    $verb = if ($meta -and $meta.Destructive -and (Get-DryRun)) { 'Simulating' } else { 'Running' }
    $selection = if ($wholeList) { @() } else { @($ticked | ForEach-Object Key) }
    Start-Run -Operation 'step' -StepKey $key -Selection $selection `
        -Status "$verb $($wiz.Steps[$wiz.Index].Name) on $($ticked.Count) device(s)..."
}

# ----------------------------------------------------------------------------
# queue drain
# ----------------------------------------------------------------------------
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(110)
$timer.Add_Tick({
    $item = $null
    while ($wiz.Queue.TryDequeue([ref]$item)) {
        switch ($item.Kind) {
            'log'      { Add-LogLine $item.Payload; Add-StepActivity $item.Payload }
            'progress' { Update-Progress $item.Payload }
            'signin'   {
                $wiz.SignIn = $item.Payload
                Update-SignInChrome
                Set-Status $(if (Test-SignedIn) { "Signed in as $($wiz.SignIn.Account)." } else { 'Signed out.' })
            }
            'saved'    { Set-Status "Saved: $($item.Payload)"; $wiz.Dirty = $false }
            'done'     {
                $p = $item.Payload
                if ($p.PSObject.Properties.Name -contains 'Rows') { Sync-DeviceRows $p.Rows }
                if ($p.Step -eq 'DeviceInput') {
                    Show-Result $p 'DeviceInput'
                    Set-Status ("{0} device(s) added{1}. The list holds {2}." -f $p.Added,
                        $(if ($p.Duplicates) { ", $($p.Duplicates) duplicate(s) skipped" } else { '' }), $p.Total)
                }
                else {
                    Show-Result $p $wiz.CurrentKey
                    # the worker writes workingset.json after every step, so the
                    # list on disk is current again
                    $wiz.Dirty = $false
                    Set-Status 'Done.'
                }
            }
            'cancelled' { Set-Status 'Cancelled.'; Add-StepActivity ([pscustomobject]@{ Timestamp = Get-Date; Level = 'Warn'; Message = 'Cancelled by user.' }) }
            'error'     {
                Set-Status 'Error.'
                Add-StepActivity ([pscustomobject]@{ Timestamp = Get-Date; Level = 'Error'; Message = $item.Payload })
                Add-LogLine ([pscustomobject]@{ Timestamp = Get-Date; Level = 'Error'; Message = $item.Payload })
                if ($wiz.Index -ge 1) { $wiz.Steps[$wiz.Index].Status = 'Error'; Set-Banner 'Error' "Error: $($item.Payload)" }
            }
            'complete'  {
                if ($wiz.Ps) { try { $wiz.Ps.EndInvoke($wiz.Handle) } catch { }; $wiz.Ps.Dispose(); $wiz.Ps = $null }
                # a run that died mid-countdown never sent its Completed
                Update-LiveActivity ([pscustomobject]@{ Completed = $true })
                Set-Busy $false
                Refresh-Steps
                if ($wiz.Index -eq 0) { Refresh-Setup }
                Update-GridSummary
            }
        }
    }
})
$timer.Start()
$wiz.Timer = $timer

# ----------------------------------------------------------------------------
# events
# ----------------------------------------------------------------------------
function Copy-ListText {
    param($ListBox, [switch]$All)
    $items = if ($All -or -not @($ListBox.SelectedItems).Count) { @($ListBox.Items) } else { @($ListBox.SelectedItems) }
    $text = ($items | ForEach-Object { [string]$_.Text }) -join "`r`n"
    if ($text) {
        try { [System.Windows.Clipboard]::SetText($text); Set-Status "Copied $($items.Count) line(s)." } catch { }
    }
}
foreach ($lbName in 'LogList', 'StepActivityList') {
    $lb = $c[$lbName]
    if (-not $lb) { continue }
    $lb.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'C' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            Copy-ListText $s; $e.Handled = $true
        }
    })
    # the menu finds its list box through PlacementTarget, not a closure: a
    # .GetNewClosure() block runs in a dynamic module and cannot see this
    # script's functions, so Copy-ListText was "not recognized" and the
    # unhandled error closed the window
    $cm = [System.Windows.Controls.ContextMenu]::new()
    $miSel = [System.Windows.Controls.MenuItem]::new(); $miSel.Header = 'Copy selected'
    $miSel.Add_Click({ param($s, $e) Copy-ListText $s.Parent.PlacementTarget })
    $miAll = [System.Windows.Controls.MenuItem]::new(); $miAll.Header = 'Copy all'
    $miAll.Add_Click({ param($s, $e) Copy-ListText $s.Parent.PlacementTarget -All })
    [void]$cm.Items.Add($miSel); [void]$cm.Items.Add($miAll)
    $lb.ContextMenu = $cm
}

# ---- setup page ----
$c.BrowseWorkBtn.Add_Click({
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    if ($c.WorkFolderBox.Text -and (Test-Path $c.WorkFolderBox.Text)) { $dlg.SelectedPath = $c.WorkFolderBox.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $c.WorkFolderBox.Text = $dlg.SelectedPath; Refresh-Setup; Save-Config }
})
$c.WorkFolderBox.Add_LostFocus({ Refresh-Setup; Save-Config })
$c.RecentDaysBox.Add_LostFocus({ Save-Config })
$c.ScopeWipeCheck.Add_Click({ Refresh-Setup; Save-Config })
$c.ScopeBitLockerCheck.Add_Click({ Refresh-Setup; Save-Config })

$c.SignInBtn.Add_Click({
    Start-Run -Operation 'signin' -Status 'Waiting for the sign-in window...' -Extra @{
        Scopes        = @(Get-RequestedScopes)
        TenantId      = [string]$c.TenantBox.Text
        UseDeviceCode = [bool]$c.DeviceCodeCheck.IsChecked
        Force         = $true
    }
})
$c.SignOutBtn.Add_Click({ Start-Run -Operation 'signout' -Status 'Signing out...' })

$c.DryRunCheck.Add_Click({ Update-ModeChrome })
$c.NavDryRunCheck.Add_Click({ Update-ModeChrome -FromNav })

# ---- device input tabs ----
$c.InFileBrowse.Add_Click({
    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Filter = 'Device lists (*.csv;*.xlsx;*.txt)|*.csv;*.xlsx;*.xlsm;*.txt|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { $c.InFilePath.Text = $dlg.FileName }
})
$c.InFileLoadBtn.Add_Click({
    if (-not $c.InFilePath.Text) { Set-Status 'Pick a file first.'; return }
    if (-not (Test-Path -LiteralPath $c.InFilePath.Text)) { Set-Status "File not found: $($c.InFilePath.Text)"; return }
    Start-DeviceInput -Operation 'input-file' -Extra @{
        Path = $c.InFilePath.Text; Sheet = $c.InFileSheet.Text
        SerialColumn = $c.InFileSerialCol.Text; NameColumn = $c.InFileNameCol.Text; NoteColumn = $c.InFileNoteCol.Text
    } -Status 'Reading the file...'
})
$c.InPasteLoadBtn.Add_Click({
    if (-not $c.InPasteBox.Text.Trim()) { Set-Status 'Paste something first.'; return }
    Start-DeviceInput -Operation 'input-text' -Extra @{ Text = $c.InPasteBox.Text } -Status 'Reading the pasted text...'
})
$c.InPasteClipBtn.Add_Click({
    try {
        $t = [System.Windows.Clipboard]::GetText()
        if ($t) { $c.InPasteBox.Text = $t; Set-Status 'Pasted from the clipboard - now click "Read this text".' }
        else { Set-Status 'The clipboard holds no text.' }
    }
    catch { Set-Status 'Could not read the clipboard.' }
})
$c.InPasteClearBtn.Add_Click({ $c.InPasteBox.Text = '' })
$c.InManualLoadBtn.Add_Click({
    $rows = @($wiz.Manual | Where-Object { $_.Serial -or $_.Name } | ForEach-Object {
        [pscustomobject]@{ Serial = [string]$_.Serial; Name = [string]$_.Name; Note = [string]$_.Note }
    })
    if (-not $rows.Count) { Set-Status 'Type at least one serial number or device name in the grid.'; return }
    Start-DeviceInput -Operation 'input-rows' -Extra @{ Rows = $rows } -Status 'Adding the typed rows...'
})
$c.InManualClearBtn.Add_Click({ $wiz.Manual.Clear() })
$c.InWorkBrowse.Add_Click({
    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Filter = 'Saved lists (*.json;*.csv)|*.json;*.csv|All files (*.*)|*.*'
    $wf = Get-WorkFolder
    if (Test-Path -LiteralPath $wf) { $dlg.InitialDirectory = $wf }
    if ($dlg.ShowDialog() -eq 'OK') { $c.InWorkPath.Text = $dlg.FileName }
})
$c.InWorkLoadBtn.Add_Click({
    if (-not $c.InWorkPath.Text) { Set-Status 'Pick a file first.'; return }
    Start-Run -Operation 'input-load' -Extra @{ Path = $c.InWorkPath.Text } -Status 'Loading the saved list...'
})
$c.InWorkSaveBtn.Add_Click({
    if (-not $wiz.Devices.Count) { Set-Status 'The list is empty.'; return }
    $path = Join-Path (Get-WorkFolder) 'workingset.json'
    Start-Run -Operation 'input-save' -Extra @{ Path = $path } -Status 'Saving the list...'
})
$c.InClearBtn.Add_Click({
    if (-not $wiz.Devices.Count) { return }
    $ans = [System.Windows.MessageBox]::Show(
        "Empty the list of $($wiz.Devices.Count) device(s)?`n`nNothing in the tenant is touched - this only clears the list in this window.",
        'Empty the list', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
        $wiz.Devices.Clear(); Update-GridSummary; Refresh-Steps; Set-Status 'List emptied.'
    }
})

function Start-DeviceInput {
    <# the three "read this" buttons; honours the append/replace checkbox #>
    param([string]$Operation, [hashtable]$Extra, [string]$Status)
    if (-not $c.InAppendCheck.IsChecked -and $wiz.Devices.Count) {
        $wiz.Devices.Clear()
    }
    Start-Run -Operation $Operation -Extra $Extra -Status $Status
}

# ---- grid ----
$c.GridAllBtn.Add_Click({ foreach ($d in $wiz.Devices) { $d.Apply = $true }; Update-GridSummary })
$c.GridNoneBtn.Add_Click({ foreach ($d in $wiz.Devices) { $d.Apply = $false }; Update-GridSummary })
$c.GridSafeBtn.Add_Click({
    foreach ($d in $wiz.Devices) { $d.Apply = (-not $d.Warn) -and ($d.Match -ne 'Not found') }
    Update-GridSummary
    Set-Status 'Ticked every device that was found and is not flagged.'
})
$c.GridRemoveBtn.Add_Click({
    $gone = @($wiz.Devices | Where-Object Apply)
    if (-not $gone.Count) { Set-Status 'Nothing ticked.'; return }
    foreach ($d in $gone) { [void]$wiz.Devices.Remove($d) }
    Update-GridSummary; Refresh-Steps
    Set-Status "Removed $($gone.Count) device(s) from the list. Nothing in the tenant was touched."
})

# ---- navigation ----
$c.RailList.Add_SelectionChanged({ if (-not $wiz.Navigating) { Navigate $c.RailList.SelectedIndex } })
$c.BackBtn.Add_Click({ Navigate ($wiz.Index - 1) })
$c.NextBtn.Add_Click({ Navigate ($wiz.Index + 1) })
$c.StepRunBtn.Add_Click({ Start-StepRun })
$c.StepRefreshBtn.Add_Click({
    Refresh-Steps
    if ($wiz.Index -ge 1) { Build-StepPage $wiz.Index }
    Set-Status 'Status refreshed.'
})
$c.CancelBtn.Add_Click({ $wiz.CancelRef.Value = $true; Set-Status 'Cancelling...' })
$c.LogsBtn.Add_Click({
    $f = Get-WorkFolder
    if (Test-Path -LiteralPath $f) { Start-Process explorer.exe $f } else { Set-Status "Not created yet: $f" }
})
$c.CloseBtn.Add_Click({ $window.Close() })
$window.Add_ContentRendered({ Update-NavButtons })   # the rail items exist from here on

$window.Add_Closing({
    if ($wiz.Running) {
        $r = [System.Windows.MessageBox]::Show('A step is running. Cancel and close?', 'Device CleanUpper', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $_.Cancel = $true; return }
        $wiz.CancelRef.Value = $true
    }
    elseif ($wiz.Dirty -and $wiz.Devices.Count) {
        $r = [System.Windows.MessageBox]::Show(
            "The device list has changed since it was last saved.`n`nSave it to $(Join-Path (Get-WorkFolder) 'workingset.json') before closing?",
            'Save the list?', [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Question)
        if ($r -eq [System.Windows.MessageBoxResult]::Cancel) { $_.Cancel = $true; return }
        if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
            try {
                $sa = Build-SessionArgs
                Save-DCUWorkingSet -Devices (ConvertTo-WorkerRows) -Path (Join-Path (Get-WorkFolder) 'workingset.json') -Session (New-DCUSession @sa) | Out-Null
            }
            catch { }
        }
    }
    $wiz.Timer.Stop()
    Save-Config
    if ($wiz.Runspace) { try { $wiz.Runspace.Close(); $wiz.Runspace.Dispose() } catch { } }
})

# ----------------------------------------------------------------------------
# boot
# ----------------------------------------------------------------------------
# One rail entry per PAGE, not per catalogue step: DeviceInput and Lookup share
# page 1, so Lookup gets no entry of its own and page 1 is numbered plainly "1".
[void]$wiz.Steps.Add(([WizStep]@{ Key = '__setup'; Number = '0'; Name = 'Setup and sign in' }))
foreach ($s in $wiz.Catalog) {
    if ($s.Key -eq $MergedRunKey) { continue }
    $number = if ($s.Key -eq $MergedPageKey) { '1' } else { $s.Number }
    $name   = if ($s.Key -eq $MergedPageKey) { 'Devices to release and look up' } else { $s.Name }
    [void]$wiz.Steps.Add(([WizStep]@{ Key = $s.Key; Number = $number; Name = $name }))
}
$c.RailList.ItemsSource   = $wiz.Steps
$c.DeviceGrid.ItemsSource = $wiz.Devices
$c.InManualGrid.ItemsSource = $wiz.Manual

$wiz.Runspace = [runspacefactory]::CreateRunspace()
$wiz.Runspace.ApartmentState = 'STA'
$wiz.Runspace.ThreadOptions  = 'ReuseThread'
$wiz.Runspace.Open()

Load-Config
if (-not $c.WorkFolderBox.Text) { $c.WorkFolderBox.Text = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'DeviceCleanUpper' }

Update-ModeChrome
Refresh-Setup
Refresh-Steps
Navigate 0
Set-Status 'Ready. Sign in to the tenant the devices are leaving.'

if ($env:DCU_WIZARD_SELFTEST -eq '1') {
    Write-Output "SELF-TEST: window built, $($wiz.Steps.Count) rail entries"
    Write-Output ("  work folder = '{0}'  dry run = {1}  recent days = {2}" -f (Get-WorkFolder), (Get-DryRun), (Get-RecentDays))
    Write-Output ("  scopes = {0}" -f ((Get-RequestedScopes) -join ', '))
    $wiz.Steps | ForEach-Object { "  {0,-3} {1,-38} {2,-8} {3}" -f $_.Number, $_.Name, $_.Status, $_.Detail }

    # the gates: signed out you stay on Setup; signed in with a list that is
    # not looked up yet you stay on page 1
    Navigate 3
    Write-Output ("  gate signed out    : index={0}  next={1}  hint='{2}'" -f $wiz.Index, $c.NextBtn.IsEnabled, $c.NavHintText.Text)

    # fake a signed-in state + a couple of devices so every page can be built
    $wiz.SignIn = [pscustomobject]@{ SignedIn = $true; Account = 'admin@contoso.com'; TenantId = 'tid'
                                     TenantDomain = 'contoso.onmicrosoft.com'; Scopes = @(); MissingScopes = @(); Message = 'test' }
    Update-SignInChrome
    Sync-DeviceRows @([pscustomobject]@{ Key = 'S:ZZZ999'; Serial = 'ZZZ999'; Match = 'Not looked up'; Apply = $true })
    Navigate 1; Navigate 3
    Write-Output ("  gate not looked up : index={0}  next={1}  hint='{2}'" -f $wiz.Index, $c.NextBtn.IsEnabled, $c.NavHintText.Text)

    Sync-DeviceRows @(
        [pscustomobject]@{ Key = 'S:AAA111'; Serial = 'AAA111'; Name = 'LT-0001'; Match = 'Matched'; IntuneId = 'i-1'
                           AutopilotId = 'ap-1'; EntraObjectId = 'e-1'; IntuneState = 'Present'; AutopilotState = 'Registered'
                           EntraState = 'Present'; LastActivity = '2025-01-01 09:00'; DaysSinceActivity = 400; Warn = $false; Apply = $true }
        [pscustomobject]@{ Key = 'S:BBB222'; Serial = 'BBB222'; Name = 'LT-0002'; Match = 'Matched'; IntuneId = 'i-2'
                           IntuneState = 'Present'; AutopilotState = 'Not in Autopilot'; EntraState = 'Present'
                           LastActivity = '2026-09-06 08:00'; DaysSinceActivity = 2; Warn = $true
                           Flag = 'STILL IN USE - last seen 2 d ago'; Apply = $false }
    )
    Refresh-Steps
    for ($i = 1; $i -lt $wiz.Steps.Count; $i++) {
        Navigate $i
        Write-Output ("  [{0}] {1,-42} run='{2}'  input={3}  sectionB={4}  mode={5}" -f $i, $c.StepTitle.Text.Trim(),
            $c.StepRunBtn.Content, $c.InputPanel.Visibility, $c.SectionBHead.Visibility, $c.StepModeCard.Visibility)
    }
    # page 1 with an empty list: half 2 must read as "not your turn yet"
    $wiz.Devices.Clear(); Navigate 1
    Write-Output ("  page 1 empty : A-done='{0}'  B-header='{1}'  B-hint='{2}'  run='{3}' enabled={4}" -f `
        $c.SectionADone.Text, $c.SectionBHeader.Text, $c.SectionBHint.Text, $c.StepRunBtn.Content, $c.StepRunBtn.IsEnabled)
    # put the devices back and check the execute-mode chrome on a destructive page
    Sync-DeviceRows @(
        [pscustomobject]@{ Key = 'S:AAA111'; Serial = 'AAA111'; Name = 'LT-0001'; Match = 'Matched'; IntuneId = 'i-1'
                           IntuneState = 'Present'; AutopilotState = 'Registered'; EntraState = 'Present'; Apply = $true }
    )
    Write-Output "  grid summary: $($c.GridSummary.Text)"
    $c.DryRunCheck.IsChecked = $false; Update-ModeChrome
    $idx = 0; for ($i = 0; $i -lt $wiz.Steps.Count; $i++) { if ($wiz.Steps[$i].Key -eq 'IntuneDelete') { $idx = $i } }
    Navigate $idx
    Write-Output ("  execute mode: rail='{0}'  nav='{1}'  run='{2}'" -f $c.RailModeTitle.Text, $c.NavModeText.Text, $c.StepRunBtn.Content)

    # the countdown: one line, rewritten in place, always last, gone when done
    $c.StepActivityList.Items.Clear()
    foreach ($s in 3, 2, 1) {
        Update-Progress ([pscustomobject]@{ Id = 0; Live = $true; Completed = $false; PercentComplete = 50
                                            Activity = 'Waiting for Autopilot'; Status = "next check in ${s}s" })
        if ($s -eq 2) { Add-StepActivity ([pscustomobject]@{ Timestamp = Get-Date; Level = 'Success'; Message = 'LT-0001 confirmed gone' }) }
    }
    $lines = @($c.StepActivityList.Items | ForEach-Object Text)
    Write-Output ("  countdown     : {0} line(s), last='{1}'" -f $lines.Count, ($lines[-1] -replace '^\S+\s+', ''))
    Update-Progress ([pscustomobject]@{ Id = 0; Live = $true; Completed = $true; Activity = 'Waiting for Autopilot' })
    Write-Output ("  countdown done: {0} line(s) left: '{1}'" -f $c.StepActivityList.Items.Count,
        (@($c.StepActivityList.Items | ForEach-Object Text) -join ' | ') -replace '\d\d:\d\d:\d\d\s+', '')
    $wiz.Timer.Stop()
    if ($wiz.Runspace) { $wiz.Runspace.Close(); $wiz.Runspace.Dispose() }
    return
}

# safety net: an error thrown in any UI event handler is reported in the log
# instead of tearing down the whole window
$window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    try {
        Add-LogLine ([pscustomobject]@{ Timestamp = Get-Date; Level = 'Error'; Message = "UI error: $($e.Exception.Message)" })
        Set-Status "UI error: $($e.Exception.Message)"
    } catch { }
})

[void]$window.ShowDialog()
