<#
    The step catalogue - the single source of truth for the wizard rail, the
    CLI -Step values and Get-DCUStatus.

    The order is the order in the handover procedure, and it matters:
    Intune first, then Autopilot, then (only if it applies) Entra ID. Removing
    the Entra device object first is what causes stuck enrollments and leftover
    records on the next tenant.

    Each entry:
      Key           stable id (also the CLI -Step value and the StepOptions key)
      Number        display order label
      Name          short title
      Effect        what the step does to the tenant:
                      ReadOnly     reads only (local files may be written)
                      Write        sends a write that is not destructive (the
                                   Autopilot sync) - held back in a dry run
                      Destructive  deletes or wipes; held back in a dry run and
                                   needs a confirmation when it runs for real
      Scope         which devices a run acts on:
                      Input        none - the step builds the list itself
                      Selection    the devices the administrator picked
                      WholeList    every device on the list; picking rows
                                   would only hide devices from it
      Summary       one or two sentences for a page header or CLI help
      Explainer     "how this step works", for whoever wants the detail
      RunLabel      the action as a button would say it; {n} is the number of
                    target devices, {mode} the Mode option, {pending} the
                    number of Autopilot removals waiting to be confirmed
      RunLabelIdle  AutopilotSync only: the label when nothing is pending
      ConfirmAction Destructive only: "About to <ConfirmAction> 3 device(s)"
      Options       ordered hashtable of option specs for the GUI + CLI:
                    Type (string|bool|int|choice|file|folder), Default, Label,
                    Help, Group / GroupOpen / Sub (page layout)

    Every host (CLI, wizard, a future web front end) reads this through
    Get-DCUStepList and Resolve-DCURunPlan instead of keeping its own copy.
#>

$script:DCUStepCatalog = @(
    [ordered]@{
        Key = 'DeviceInput'; Number = '1a'; Name = 'Devices to release'; Effect = 'ReadOnly'; Scope = 'Input'
        Summary = 'Put the devices that are leaving this tenant on the list, then look them up. Read the list from a CSV or Excel file, paste it in, type it in, or pick up a list you saved earlier - and then have Intune, Windows Autopilot and Entra ID checked for every one of them.'
        Options = [ordered]@{
            Path = @{ Type = 'file'; Default = ''; Label = 'CSV or Excel file'
                Help = 'A .csv (comma, semicolon or tab separated) or .xlsx file with one device per row. Excel files are read directly - Excel does not have to be installed.' }
            Sheet = @{ Type = 'string'; Default = ''; Label = 'Excel sheet name'
                Group = 'Column mapping (optional)'
                Help = 'Which worksheet to read. Empty = the first sheet in the workbook.' }
            SerialColumn = @{ Type = 'string'; Default = ''; Label = 'Serial number column'
                Group = 'Column mapping (optional)'; Pair = 'cols'
                Sub = 'Leave empty to auto-detect. Recognised headers: serial, serienummer, serial number, sn, s/n - and devicename, apparaatnaam, computernaam, hostname, naam, name.'
                Help = 'Header of the column holding the serial number.' }
            NameColumn = @{ Type = 'string'; Default = ''; Label = 'Device name column'
                Group = 'Column mapping (optional)'; Pair = 'cols'
                Help = 'Header of the column holding the device name.' }
            NoteColumn = @{ Type = 'string'; Default = ''; Label = 'Note column'
                Group = 'Column mapping (optional)'
                Help = 'Optional free text carried along into the exports - a school name, a purchase order, whatever helps you recognise the batch later.' }
        }
    }
    [ordered]@{
        Key = 'Lookup'; Number = '1b'; Name = 'Look up in the tenant'; Effect = 'ReadOnly'; Scope = 'WholeList'
        RunLabel = 'Look up {n} device(s)'
        Summary = 'Find every device on the list in Intune, Windows Autopilot and Entra ID, and flag the ones that look like they are still in use. Read-only.'
        Explainer = @'
Every device on the list is looked up in three places at once: the Intune managed-device list, the Windows Autopilot device list and the Entra ID device list. Matching is on serial number first and device name second - a value that could be either is tried both ways, so a single pasted column does not have to be labelled.

Nothing is changed. This step exists to tell you what you are about to delete: which of the three systems each device is in, who used it, when it last checked in, and whether anything looks wrong.

Devices that checked in recently are flagged in red and left unticked. So are devices that matched nothing, devices that matched more than one record, and hybrid joined devices.
'@
        # "Windows devices only" is a session setting (Setup page / -WindowsOnly),
        # not a step option - the final check reads the inventory too, and two
        # places to set the same thing is one too many.
        Options = [ordered]@{
            RefreshInventory = @{ Type = 'bool'; Default = $true; Label = 'Re-read the tenant inventory'
                Help = 'The full Intune / Autopilot / Entra device lists are cached for this session. Leave this on after you have deleted something, so the numbers are current.' }
        }
    }
    [ordered]@{
        Key = 'Backup'; Number = '2'; Name = 'Export the list and BitLocker keys'; Effect = 'ReadOnly'; Scope = 'Selection'
        RunLabel = 'Export {n} device(s)'
        Summary = 'Write down what these devices were before they stop existing: device names, serial numbers and the Intune / Entra / Autopilot ids - and, if you need them, the BitLocker recovery keys. Read-only.'
        Explainer = @'
Once the Intune, Autopilot and Entra records are deleted, their ids cannot be looked up again - and deleting an Entra device object also throws away the BitLocker recovery keys Entra was holding for it. This is the step that is genuinely hard to undo by skipping.

The export is a semicolon-separated CSV (opens straight into Excel) plus the same data as JSON.

BitLocker keys are off by default and need their own consent. Exporting the key VALUES makes that file as good as the disks themselves - keep it somewhere safe and delete it when the handover is done.
'@
        Options = [ordered]@{
            ExportCsv = @{ Type = 'bool'; Default = $true; Label = 'Write the device list to CSV and JSON'
                Help = 'Everything that was found: device name, serial number, Intune device id, Entra device id, Autopilot id, owner, last check-in. This is the record of what the devices were BEFORE they were deleted - once they are gone, these ids cannot be looked up again.' }
            IncludeBitLocker = @{ Type = 'bool'; Default = $false; Label = 'Also export BitLocker recovery keys'
                Help = 'Reads the BitLocker recovery keys that Entra ID holds for these devices. Deleting the Entra device object also removes its recovery keys, so export them first if there is any chance a disk still has to be unlocked. Needs the BitLockerKey.Read.All consent - sign in again after ticking this.' }
            IncludeKeyValues = @{ Type = 'bool'; Default = $false; Label = 'Include the actual key values in the file'
                Help = 'OFF: only the key ids and dates are exported (proof that a key exists). ON: the recovery passwords themselves are written to the file. That file then unlocks the disks - store it like a password list, and delete it once the handover is done.' }
            ExportFolder = @{ Type = 'folder'; Default = ''; Label = 'Export folder'
                Group = 'Advanced'
                Help = 'Empty = the exports folder inside the working folder from the Setup page.' }
        }
    }
    [ordered]@{
        Key = 'Wipe'; Number = '3'; Name = 'Wipe or retire (optional)'; Effect = 'Destructive'; Scope = 'Selection'
        RunLabel = '{mode} {n} device(s)'
        ConfirmAction = 'send a {mode} to'
        Summary = 'Optional. Send a wipe or a retire to devices you still have and that can still come online. The command is queued in Intune and runs the next time the device checks in.'
        Explainer = @'
Optional, and only for hardware you still physically have. Intune queues the command and it runs the next time the device comes online - a laptop that is already boxed up will never receive it, which is fine: deleting the records still releases it.

Wipe resets Windows to a clean state, which is what you want before handing hardware to somebody else. Retire only removes company data, apps and policies and leaves the user profile alone.

This does not delete anything from Intune. That is the next step.
'@
        Options = [ordered]@{
            Mode = @{ Type = 'choice'; Default = 'Wipe'; Choices = @('Wipe', 'Retire'); Label = 'What to send'
                Help = 'Wipe resets Windows to a clean state and is what you want before handing hardware over. Retire only removes company data, apps and policies and leaves the user profile alone. Both need the device to be online to actually happen.' }
            KeepUserData = @{ Type = 'bool'; Default = $false; Label = 'Wipe: keep user data'
                Help = 'Only applies to Wipe. Off (default) = full reset. On = a "reset while keeping my files" wipe, which is not what a device leaving the organisation normally wants.' }
            KeepEnrollmentState = @{ Type = 'bool'; Default = $false; Label = 'Wipe: keep enrollment state'
                Help = 'Only applies to Wipe. Leave off - keeping the enrollment state is for reprovisioning inside the same tenant, not for handing the device to another one.' }
        }
    }
    [ordered]@{
        Key = 'IntuneDelete'; Number = '4'; Name = 'Remove from Intune'; Effect = 'Destructive'; Scope = 'Selection'
        RunLabel = 'Delete {n} device(s) from Intune'
        ConfirmAction = 'delete from Intune'
        Summary = 'Delete the Intune device objects, so this tenant no longer manages the devices. Step 1 of the two that actually release the hardware.'
        Explainer = @'
Removes the Intune device object, so this tenant stops managing the device.

On its own this does NOT release the hardware: while the serial number is still registered in Windows Autopilot, the device keeps coming back to this tenant at OOBE. Do steps 5 and 6 as well.

The order matters. Intune first, then Autopilot, and only then (if at all) the Entra ID object - removing the Entra object first is what leaves stuck enrollments and orphaned records behind.
'@
        Options = [ordered]@{
            RetireFirst = @{ Type = 'bool'; Default = $false; Label = 'Retire before deleting'
                Help = 'Sends a retire first, so a device that is still online drops its company data and policies before the record goes. Slower, and pointless for hardware that is already switched off and boxed up.' }
        }
    }
    [ordered]@{
        Key = 'AutopilotDelete'; Number = '5'; Name = 'Remove the Autopilot registration'; Effect = 'Destructive'; Scope = 'Selection'
        RunLabel = 'Remove {n} Autopilot registration(s)'
        ConfirmAction = 'remove the Autopilot registration of'
        Summary = 'Delete the Windows Autopilot registrations. This is the step that releases the serial numbers - until it is done, the devices keep landing back in this tenant at OOBE and the other tenant cannot register them.'
        Explainer = @'
This is the step that actually releases the serial numbers. The assigned user is removed first, then the device identity is deleted.

Deletion is asynchronous: Intune accepts it straight away, but the registration can stay in the list for minutes. A device is therefore marked "Deletion pending" here, not Deleted - step 6 syncs Autopilot and confirms it is really gone.

This step does NOT sync. If you remove devices in several batches, run this step for each batch first and step 6 once at the end: Intune only accepts a manual sync every so often.

If a device was never registered in Autopilot, its row is skipped here - that is normal, not a failure. A device whose delete was already sent is skipped too.
'@
        Options = [ordered]@{
            UnassignUserFirst = @{ Type = 'bool'; Default = $true; Label = 'Unassign the assigned user first'
                Help = 'Autopilot records can have a user assigned to them. Removing that first is the documented order and avoids a delete failing on a device that is still assigned.' }
        }
    }
    [ordered]@{
        # its own step, not an option on the delete: Intune accepts a manual
        # sync only every so often, so one sync after all the delete runs beats
        # one per run. Not destructive, but still held back in a dry run.
        Key = 'AutopilotSync'; Number = '6'; Name = 'Sync Autopilot and confirm'; Effect = 'Write'; Scope = 'WholeList'
        # it only syncs when a registration is still there, so neither label promises a sync
        RunLabel = 'Confirm {pending} Autopilot removal(s)'
        RunLabelIdle = 'Check for Autopilot removals'
        Summary = 'Check whether the registrations deleted in step 5 are gone yet; only if one is still there, ask Intune to sync the Autopilot list and wait until it is. Run it after ALL your Autopilot deletes - Intune only accepts a manual sync every so often.'
        Explainer = @'
First looks up every registration that step 5 deleted. If they are all gone already, that is it - no sync is sent. Only when at least one is still in Autopilot does it send one "sync" (the same as the Sync button in the Intune portal) and then re-read the remaining ones until they are really gone, or until the waiting time runs out, with a countdown in the activity list. Only then is a device marked Deleted.

Intune accepts a manual sync only every so often. If it refuses because a sync ran recently (from here or from the portal), that sync counts: the removals are still checked, and the log shows when the last sync was.

Still pending when the time runs out? Nothing is wrong - run this step again in a few minutes. Cancel stops the waiting, never the deletes. The Entra ID step skips every device that is still in Autopilot.
'@
        Options = [ordered]@{
            WaitMinutes = @{ Type = 'int'; Default = 10; Label = 'Wait up to this many minutes for the removals to show'
                Help = 'Only used when a registration is still there at the first look (otherwise no sync is sent and nothing is waited for). After the sync, the remaining registrations are re-read until they are really gone, or until this many minutes have passed. 0 = check once, do not wait. Cancel stops the waiting, not the deletes - you can run this step again at any time.' }
        }
    }
    [ordered]@{
        Key = 'EntraDelete'; Number = '7'; Name = 'Entra ID device object'; Effect = 'Destructive'; Scope = 'Selection'
        RunLabel = 'Delete {n} Entra ID object(s)'
        ConfirmAction = 'delete the Entra ID device object of'
        Summary = 'Delete the Entra ID device objects. Usually NOT needed: for an Autopilot + Entra joined device the object is cleaned up once Intune and Autopilot are gone. It matters for devices that were never in Autopilot.'
        Explainer = @'
For a normal Autopilot + Entra joined device you do NOT have to delete the Entra object by hand to release the device, so those rows are skipped by default.

It matters for devices that were never in Autopilot and have to be fully detached from this tenant.

A device that the list still shows in Autopilot - or whose Autopilot removal is not confirmed yet - is looked up in Autopilot first. If the registration is gone (also when someone removed it outside this tool), the device is handled like any other. If it is really still there, it is always skipped, whatever the options say: run step 5 (remove the registration) and step 6 (sync and confirm) first.

Hybrid joined devices (trust type ServerAd) are skipped too: the cloud object comes straight back at the next Entra Connect sync unless the computer object is deleted from the on-prem Active Directory first. Those devices are listed in the final report so you can clean them up there.

Deleting a device object also deletes the BitLocker recovery keys Entra held for it. Export them in step 2 first if there is any chance a disk still has to be unlocked.
'@
        Options = [ordered]@{
            OnlyWithoutAutopilot = @{ Type = 'bool'; Default = $true; Label = 'Skip devices that were Autopilot registered'
                Help = 'For a normal Autopilot + Entra joined device the Entra object does not have to be removed by hand once Intune and Autopilot are clean - so this is on by default and those rows are skipped. Turn it off only when you deliberately want the object gone as well.' }
            SkipHybrid = @{ Type = 'bool'; Default = $true; Label = 'Skip hybrid joined devices'
                Help = 'A hybrid joined device (trust type ServerAd) comes back at the next Entra Connect sync unless the on-prem AD computer object is deleted first. Those rows are listed in the final report instead so you can clean them up in Active Directory.' }
        }
    }
    [ordered]@{
        Key = 'FinalCheck'; Number = '8'; Name = 'Final check and handover report'; Effect = 'ReadOnly'; Scope = 'WholeList'
        RunLabel = 'Check {n} device(s)'
        Summary = 'Re-read all three systems and prove the devices really are released. Writes the handover report and lists whatever still has to be done by hand.'
        Explainer = @'
Re-reads Intune, Windows Autopilot and Entra ID and answers, per device: is it gone from Intune, is the serial number gone from the Autopilot list, what is left in Entra ID, and is there anything still to do on-premises.

A device counts as ready for handover when it is out of Intune and out of Autopilot and needs nothing done in the on-prem Active Directory. An Entra ID object that is still there is normal for an Autopilot device.

The report is written as a CSV plus a readable checklist you can hand to whoever takes the devices over.
'@
        Options = [ordered]@{
            ExportReport = @{ Type = 'bool'; Default = $true; Label = 'Write the handover report'
                Help = 'A CSV plus a readable text checklist per device: gone from Intune, gone from Autopilot, Entra object state, and whatever still needs doing by hand (on-prem AD).' }
            ReportFolder = @{ Type = 'folder'; Default = ''; Label = 'Report folder'
                Group = 'Advanced'
                Help = 'Empty = the exports folder inside the working folder from the Setup page.' }
        }
    }
)

function Get-DCUStepMeta {
    param([Parameter(Mandatory)][string]$Key)
    $script:DCUStepCatalog | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
}

function Get-DCUStepIndex {
    <# position in the handover order, -1 for an unknown key #>
    param([Parameter(Mandatory)][string]$Key)
    for ($i = 0; $i -lt $script:DCUStepCatalog.Count; $i++) {
        if ($script:DCUStepCatalog[$i].Key -eq $Key) { return $i }
    }
    -1
}

function Get-DCUStepRef {
    <# "step 6 (Sync Autopilot and confirm)" - messages use this so they follow the catalogue numbering #>
    param([Parameter(Mandatory)][string]$Key)
    $m = Get-DCUStepMeta -Key $Key
    "step $($m.Number) ($($m.Name))"
}

function Resolve-DCUStepOptions {
    <#
        Merge the catalogue defaults for one step with caller-supplied
        overrides. Booleans are taken as given - an explicit $false is a real
        value, not "unset" - while empty strings fall back to the default.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Override = @{}
    )
    $meta = Get-DCUStepMeta -Key $Key
    if (-not $meta) { throw "Unknown step: $Key" }
    $result = @{}
    foreach ($name in $meta.Options.Keys) {
        $result[$name] = $meta.Options[$name].Default
    }
    foreach ($k in $Override.Keys) {
        $v = $Override[$k]
        if ($v -is [bool] -or $v -is [int]) { $result[$k] = $v; continue }
        if ($null -ne $v -and "$v" -ne '') { $result[$k] = $v }
    }
    $result
}
