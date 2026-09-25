<#
    The step catalogue - the single source of truth for the wizard rail, the
    CLI -Step values and Get-DCUStatus.

    The order is the order in the handover procedure, and it matters:
    Intune first, then Autopilot, then (only if it applies) Entra ID. Removing
    the Entra device object first is what causes stuck enrollments and leftover
    records on the next tenant.

    Each entry:
      Key         stable id (also the CLI -Step value and the StepOptions key)
      Number      display order label
      Name        short title
      Destructive $true when the step changes something in the tenant
      Options     ordered hashtable of option specs for the GUI + CLI:
                  Type (string|bool|int|choice|file|folder), Default, Label,
                  Help, Group / GroupOpen / Sub (page layout)
#>

$script:DCUStepCatalog = @(
    [ordered]@{
        Key = 'DeviceInput'; Number = '1a'; Name = 'Devices to release'; Destructive = $false
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
        Key = 'Lookup'; Number = '1b'; Name = 'Look up in the tenant'; Destructive = $false
        # "Windows devices only" is a session setting (Setup page / -WindowsOnly),
        # not a step option - the final check reads the inventory too, and two
        # places to set the same thing is one too many.
        Options = [ordered]@{
            RefreshInventory = @{ Type = 'bool'; Default = $true; Label = 'Re-read the tenant inventory'
                Help = 'The full Intune / Autopilot / Entra device lists are cached for this session. Leave this on after you have deleted something, so the numbers are current.' }
        }
    }
    [ordered]@{
        Key = 'Backup'; Number = '2'; Name = 'Export the list and BitLocker keys'; Destructive = $false
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
        Key = 'Wipe'; Number = '3'; Name = 'Wipe or retire (optional)'; Destructive = $true
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
        Key = 'IntuneDelete'; Number = '4'; Name = 'Remove from Intune'; Destructive = $true
        Options = [ordered]@{
            RetireFirst = @{ Type = 'bool'; Default = $false; Label = 'Retire before deleting'
                Help = 'Sends a retire first, so a device that is still online drops its company data and policies before the record goes. Slower, and pointless for hardware that is already switched off and boxed up.' }
        }
    }
    [ordered]@{
        Key = 'AutopilotDelete'; Number = '5'; Name = 'Remove the Autopilot registration'; Destructive = $true
        Options = [ordered]@{
            UnassignUserFirst = @{ Type = 'bool'; Default = $true; Label = 'Unassign the assigned user first'
                Help = 'Autopilot records can have a user assigned to them. Removing that first is the documented order and avoids a delete failing on a device that is still assigned.' }
        }
    }
    [ordered]@{
        # its own step, not an option on the delete: Intune accepts a manual
        # sync only every so often, so one sync after all the delete runs beats
        # one per run. Not destructive, but still held back in a dry run.
        Key = 'AutopilotSync'; Number = '6'; Name = 'Sync Autopilot and confirm'; Destructive = $false
        Options = [ordered]@{
            WaitMinutes = @{ Type = 'int'; Default = 10; Label = 'Wait up to this many minutes for the removals to show'
                Help = 'Only used when a registration is still there at the first look (otherwise no sync is sent and nothing is waited for). After the sync, the remaining registrations are re-read until they are really gone, or until this many minutes have passed. 0 = check once, do not wait. Cancel stops the waiting, not the deletes - you can run this step again at any time.' }
        }
    }
    [ordered]@{
        Key = 'EntraDelete'; Number = '7'; Name = 'Entra ID device object'; Destructive = $true
        Options = [ordered]@{
            OnlyWithoutAutopilot = @{ Type = 'bool'; Default = $true; Label = 'Skip devices that were Autopilot registered'
                Help = 'For a normal Autopilot + Entra joined device the Entra object does not have to be removed by hand once Intune and Autopilot are clean - so this is on by default and those rows are skipped. Turn it off only when you deliberately want the object gone as well.' }
            SkipHybrid = @{ Type = 'bool'; Default = $true; Label = 'Skip hybrid joined devices'
                Help = 'A hybrid joined device (trust type ServerAd) comes back at the next Entra Connect sync unless the on-prem AD computer object is deleted first. Those rows are listed in the final report instead so you can clean them up in Active Directory.' }
        }
    }
    [ordered]@{
        Key = 'FinalCheck'; Number = '8'; Name = 'Final check and handover report'; Destructive = $false
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
