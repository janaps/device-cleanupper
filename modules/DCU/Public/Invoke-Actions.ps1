<#
    Steps 3 to 7 - the parts that change the tenant.

    Every one of them goes through Invoke-DCUDeviceLoop, so they all behave the
    same way:

      * DRY RUN (the default) makes no Graph write calls at all. Each device is
        still checked for eligibility and logged as "DRY RUN - would ...", so a
        dry run is a real rehearsal, not a guess.
      * a device that is not eligible is skipped with the reason, never
        silently.
      * a device that is flagged (still in use, hybrid, multiple matches) is
        logged loudly on the way past, even when the caller ticked it.
      * one failure does not stop the batch; it is counted and reported.

    The order the steps appear in is the order they must run in: Intune, then
    Autopilot, then Entra ID.
#>

function Invoke-DCUDeviceLoop {
    <#
        Shared driver for the destructive steps. $Plan decides whether a row is
        eligible and describes what would happen; $Act performs it and is only
        ever called outside a dry run.

        NOTE for callers: both blocks are called as `& $Plan $d $Options`, so
        pass the step options they need in -Options and read them from the
        second parameter ($o). Do NOT use .GetNewClosure() on them: that
        rebinds the block to a new dynamic module, where the module's private
        functions (Invoke-DCUGraph, ...) are no longer found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Targets,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][scriptblock]$Plan,
        [Parameter(Mandatory)][scriptblock]$Act,
        [hashtable]$Options = @{}
    )

    $counts = [ordered]@{ Total = @($Targets).Count; Done = 0; Simulated = 0; Skipped = 0; Failed = 0; Flagged = 0 }
    $i = 0

    foreach ($d in $Targets) {
        Test-DCUCancelled
        $i++
        $label = Get-DCUDeviceLabel $d
        Write-DCUProgress -Id 0 -Activity $Activity -Status $label -PercentComplete ([int](100 * $i / [math]::Max($counts.Total, 1)))

        # NB: not $plan - PowerShell variable names are case-insensitive, so that
        # would assign over the [scriptblock]$Plan parameter itself
        $decision = & $Plan $d $Options
        if (-not $decision.Eligible) {
            $counts.Skipped++
            $d.Result = "Skipped - $($decision.Reason)"
            Write-DCULog -Level Info -Category $Category -Message "SKIP $label - $($decision.Reason)"
            continue
        }

        if ($d.Warn -and $d.Flag) {
            $counts.Flagged++
            Write-DCULog -Level Warn -Category $Category -Message "WARNING on $label - $($d.Flag)"
        }

        if ($script:DryRun) {
            $counts.Simulated++
            $d.Result = "DRY RUN - would $($decision.What)"
            Write-DCULog -Level Info -Category 'DryRun' -Message "DRY RUN - would $($decision.What) for $label"
            continue
        }

        try {
            $r = & $Act $d $Options
            $counts.Done++
            $msg = if ($r -and $r.Message) { $r.Message } else { $decision.What }
            $d.Result = $msg
            Write-DCULog -Level Success -Category $Category -Message "$label - $msg"
        }
        catch [System.OperationCanceledException] { throw }
        catch {
            $counts.Failed++
            $d.Result = "FAILED - $($_.Exception.Message)"
            Write-DCULog -Level Error -Category $Category -Message "$label - $($_.Exception.Message)"
        }
    }

    Write-DCUProgress -Id 0 -Activity $Activity -Completed
    $counts
}

function Write-DCUModeBanner {
    param([string]$Step, [int]$Count)
    if ($script:DryRun) {
        Write-DCULog -Level Info -Category 'DryRun' -Message "DRY RUN is ON - $Step will only report what it would do to $Count device(s). Nothing is changed."
    }
    else {
        Write-DCULog -Level Warn -Category $Step -Message "RUNNING FOR REAL - $Step will change $Count device(s) in this tenant. This cannot be undone."
    }
}

# ---------------------------------------------------------------------------
# Step 3 - wipe / retire (optional)
# ---------------------------------------------------------------------------
function Invoke-DCUWipe {
    <#
        .SYNOPSIS
            Send a wipe (or retire) to the selected Intune devices.
        .DESCRIPTION
            Optional, and only useful for hardware you still physically have
            and that can still come online: the command is queued in Intune and
            runs the next time the device checks in. Wipe resets Windows to a
            clean state; retire only removes company data and policies.

            This does not delete anything from Intune - that is the next step.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection
    )

    Initialize-DCUContext -Session $Session
    Assert-DCUSignedIn | Out-Null

    $devices = @($Devices | ConvertTo-DCUDeviceRecord)
    $targets = @(Select-DCUDevices -Devices $devices -Selection $Selection)

    $mode       = [string](Get-DCUStepOption -Step 'Wipe' -Name 'Mode' -Default 'Wipe')
    $keepUser   = [bool](Get-DCUStepOption -Step 'Wipe' -Name 'KeepUserData' -Default $false)
    $keepEnroll = [bool](Get-DCUStepOption -Step 'Wipe' -Name 'KeepEnrollmentState' -Default $false)
    $verb       = if ($mode -eq 'Retire') { 'retire' } else { 'wipe' }

    Write-DCUModeBanner -Step "$verb" -Count $targets.Count

    $plan = {
        param($d, $o)
        if (-not $d.IntuneId) { return [pscustomobject]@{ Eligible = $false; Reason = 'not an Intune managed device' } }
        $n = @($d.IntuneId -split ';').Count
        [pscustomobject]@{ Eligible = $true; Reason = ''; What = "send a $($o.Verb) to $n Intune record(s)" }
    }

    $act = {
        param($d, $o)
        $sent = 0
        foreach ($id in ($d.IntuneId -split ';' | Where-Object { $_ })) {
            if ($o.Mode -eq 'Retire') {
                Invoke-DCUGraph -Method POST -Uri "v1.0/deviceManagement/managedDevices/$id/retire" -Context 'retire' | Out-Null
            }
            else {
                $body = @{
                    keepEnrollmentData = $o.KeepEnroll
                    keepUserData       = $o.KeepUser
                    useProtectedWipe   = $false
                }
                Invoke-DCUGraph -Method POST -Uri "v1.0/deviceManagement/managedDevices/$id/wipe" -Body $body -Context 'wipe' | Out-Null
            }
            $sent++
        }
        $d.IntuneState = if ($o.Mode -eq 'Retire') { 'Retire sent' } else { 'Wipe sent' }
        [pscustomobject]@{ Message = "$($o.Verb) queued for $sent record(s) - it runs when the device next checks in" }
    }

    $counts = Invoke-DCUDeviceLoop -Targets $targets -Activity "Sending a $verb" -Category 'Wipe' -Plan $plan -Act $act `
        -Options @{ Mode = $mode; Verb = $verb; KeepUser = $keepUser; KeepEnroll = $keepEnroll }

    Write-DCULog -Level Success -Category 'Wipe' -Message "${verb}: $($counts.Done) sent, $($counts.Simulated) simulated, $($counts.Skipped) skipped, $($counts.Failed) failed."

    [pscustomobject]@{
        Step = 'Wipe'; Mode = $mode; DryRun = $script:DryRun
        Selected = $counts.Total; Sent = $counts.Done; Simulated = $counts.Simulated
        Skipped = $counts.Skipped; Failed = $counts.Failed; Warned = $counts.Flagged
        Rows = $devices
    }
}

# ---------------------------------------------------------------------------
# Step 4 - remove from Intune
# ---------------------------------------------------------------------------
function Invoke-DCUIntuneDelete {
    <#
        .SYNOPSIS
            Delete the selected devices from Intune.
        .DESCRIPTION
            Removes the Intune device object, so the device is no longer
            managed by this tenant. It does not touch the Autopilot
            registration - that is the next step, and doing it in this order is
            what keeps the handover clean.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection
    )

    Initialize-DCUContext -Session $Session
    Assert-DCUSignedIn | Out-Null

    $devices = @($Devices | ConvertTo-DCUDeviceRecord)
    $targets = @(Select-DCUDevices -Devices $devices -Selection $Selection)
    $retireFirst = [bool](Get-DCUStepOption -Step 'IntuneDelete' -Name 'RetireFirst' -Default $false)

    Write-DCUModeBanner -Step 'Intune delete' -Count $targets.Count

    $plan = {
        param($d, $o)
        if (-not $d.IntuneId) { return [pscustomobject]@{ Eligible = $false; Reason = 'not in Intune' } }
        $n = @($d.IntuneId -split ';').Count
        $what = if ($o.RetireFirst) { "retire and delete $n Intune record(s)" } else { "delete $n Intune record(s)" }
        [pscustomobject]@{ Eligible = $true; Reason = ''; What = $what }
    }

    $act = {
        param($d, $o)
        $gone = 0
        foreach ($id in ($d.IntuneId -split ';' | Where-Object { $_ })) {
            if ($o.RetireFirst) {
                try { Invoke-DCUGraph -Method POST -Uri "v1.0/deviceManagement/managedDevices/$id/retire" -Context 'retire' | Out-Null }
                catch { Write-DCULog -Level Warn -Category 'Intune' -Message "Retire failed for $id, deleting anyway: $($_.Exception.Message)" }
            }
            Invoke-DCUGraph -Method DELETE -Uri "v1.0/deviceManagement/managedDevices/$id" -Context 'delete Intune device' -Tolerate 404 | Out-Null
            $gone++
        }
        $d.IntuneState = 'Deleted'
        $d.IntuneId = ''
        [pscustomobject]@{ Message = "removed from Intune ($gone record(s))" }
    }

    $counts = Invoke-DCUDeviceLoop -Targets $targets -Activity 'Removing from Intune' -Category 'Intune' -Plan $plan -Act $act `
        -Options @{ RetireFirst = $retireFirst }

    Write-DCULog -Level Success -Category 'Intune' -Message "Intune: $($counts.Done) deleted, $($counts.Simulated) simulated, $($counts.Skipped) skipped, $($counts.Failed) failed."
    if (-not $script:DryRun -and $counts.Done) {
        Write-DCULog -Category 'Intune' -Message "Next: $(Get-DCUStepRef 'AutopilotDelete'). Deleting the Intune record alone does not release the serial number to another tenant."
    }

    [pscustomobject]@{
        Step = 'IntuneDelete'; DryRun = $script:DryRun
        Selected = $counts.Total; Deleted = $counts.Done; Simulated = $counts.Simulated
        Skipped = $counts.Skipped; Failed = $counts.Failed; Warned = $counts.Flagged
        Rows = $devices
    }
}

# ---------------------------------------------------------------------------
# Step 5 - remove the Autopilot registration
# ---------------------------------------------------------------------------
function Invoke-DCUAutopilotDelete {
    <#
        .SYNOPSIS
            Remove the Windows Autopilot registration for the selected devices.
        .DESCRIPTION
            This is the step that actually releases the hardware: while the
            serial number is still registered to this tenant's Autopilot, the
            device keeps landing back here at OOBE and the other tenant cannot
            register it.

            The assigned user is removed first (the documented order), then the
            device identity is deleted. Deletion is asynchronous: Graph accepts
            the DELETE straight away, but the registration can stay in the list
            for minutes. So a row is only marked Deleted once a re-read shows
            it gone; until then it stays 'Deletion pending' and keeps its
            Autopilot id, and the Entra step will not touch it.

            This step checks once, right after the deletes. The sync and the
            waiting are the next step (AutopilotSync), so several delete runs
            share one sync instead of each burning the sync limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection
    )

    Initialize-DCUContext -Session $Session
    Assert-DCUSignedIn | Out-Null

    $devices = @($Devices | ConvertTo-DCUDeviceRecord)
    $targets = @(Select-DCUDevices -Devices $devices -Selection $Selection)
    $unassign = [bool](Get-DCUStepOption -Step 'AutopilotDelete' -Name 'UnassignUserFirst' -Default $true)
    $syncRef  = Get-DCUStepRef 'AutopilotSync'

    Write-DCUModeBanner -Step 'Autopilot delete' -Count $targets.Count

    $plan = {
        param($d, $o)
        if (-not $d.AutopilotId) { return [pscustomobject]@{ Eligible = $false; Reason = 'no Autopilot registration' } }
        if ($d.AutopilotState -eq 'Deletion pending') {
            return [pscustomobject]@{ Eligible = $false; Reason = "delete already sent - $($o.SyncRef) confirms it" }
        }
        $n = @($d.AutopilotId -split ';').Count
        [pscustomobject]@{ Eligible = $true; Reason = ''; What = "delete $n Autopilot registration(s)" }
    }

    $act = {
        param($d, $o)
        $ids = @($d.AutopilotId -split ';' | Where-Object { $_ })
        foreach ($id in $ids) {
            if ($o.Unassign -and $d.AutopilotUser) {
                try {
                    Invoke-DCUGraph -Method POST -Uri "v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$id/unassignUserFromDevice" `
                        -Context 'unassign Autopilot user' -Tolerate 400, 404 | Out-Null
                }
                catch { Write-DCULog -Level Warn -Category 'Autopilot' -Message "Unassign user failed for $id, deleting anyway: $($_.Exception.Message)" }
            }
            Invoke-DCUGraph -Method DELETE -Uri "v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$id" `
                -Context 'delete Autopilot registration' -Tolerate 404 | Out-Null
        }
        $d.AutopilotState = 'Deletion pending'
        [pscustomobject]@{ Message = "PENDING - Autopilot delete accepted for $($ids.Count) record(s), not confirmed yet" }
    }

    $counts = Invoke-DCUDeviceLoop -Targets $targets -Activity 'Removing Autopilot registrations' -Category 'Autopilot' -Plan $plan -Act $act `
        -Options @{ Unassign = $unassign; SyncRef = $syncRef }

    # one look straight away - some deletes go through within seconds
    $sent = @($targets | Where-Object { $_.AutopilotState -eq 'Deletion pending' -and $_.Result -like 'PENDING*' })
    $confirmed = 0
    if (-not $script:DryRun -and $sent.Count) {
        $confirmed = Wait-DCUAutopilotRemoval -Devices $sent -Minutes 0 -PendingHint "$syncRef confirms it"
    }
    $stillPending = $sent.Count - $confirmed

    Write-DCULog -Level Success -Category 'Autopilot' -Message ("Autopilot: $($counts.Done) delete(s) sent ($confirmed already confirmed gone, $stillPending pending), " +
        "$($counts.Simulated) simulated, $($counts.Skipped) skipped, $($counts.Failed) failed.")
    if ($stillPending) {
        Write-DCULog -Level Warn -Category 'Autopilot' -Message ("Next: $syncRef. $stillPending registration(s) are accepted for deletion but still in the Autopilot list - " +
            'that step syncs Autopilot and waits until they are really gone. Remove the other devices first if there are more to do, so one sync covers them all.')
    }

    [pscustomobject]@{
        Step = 'AutopilotDelete'; DryRun = $script:DryRun
        Selected = $counts.Total; Sent = $counts.Done; Confirmed = $confirmed; StillPending = $stillPending
        Simulated = $counts.Simulated; Skipped = $counts.Skipped; Failed = $counts.Failed; Warned = $counts.Flagged
        Rows = $devices
    }
}

# ---------------------------------------------------------------------------
# Step 6 - sync Autopilot and confirm the removals
# ---------------------------------------------------------------------------
function Invoke-DCUAutopilotSync {
    <#
        .SYNOPSIS
            Ask Intune to sync the Autopilot device list, then confirm that the
            registrations deleted in the previous step are really gone.
        .DESCRIPTION
            A step of its own on purpose: Intune accepts a manual sync only
            every so often, so one sync after all the delete runs beats one per
            run. It is also the step that turns a 'Deletion pending' row into
            Deleted - and only once a re-read shows the registration gone.

            It LOOKS FIRST: every pending registration is re-read, and a sync
            is only sent when at least one is still there. No pending rows, or
            all of them already gone, means no sync at all.

            If Intune refuses the sync because one ran recently (from here or
            from the portal), that earlier sync counts: the waiting still runs.
            In a dry run the first look still happens (it is read-only), but
            no sync is sent and there is no waiting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection
    )

    Initialize-DCUContext -Session $Session
    Assert-DCUSignedIn | Out-Null

    $devices = @($Devices | ConvertTo-DCUDeviceRecord)
    $targets = @(Select-DCUDevices -Devices $devices -Selection $Selection)
    $waitMin = [int](Get-DCUStepOption -Step 'AutopilotSync' -Name 'WaitMinutes' -Default 10)

    $pending = @($targets | Where-Object { $_.AutopilotState -eq 'Deletion pending' })
    $hint    = 'run this step again in a few minutes'
    $synced  = $false
    $confirmed = 0

    if (-not $pending.Count) {
        Write-DCULog -Category 'Autopilot' -Message ("No Autopilot removals on this list are waiting to be confirmed, so no sync is sent. " +
            "Delete registrations with $(Get-DCUStepRef 'AutopilotDelete') first.")
    }
    else {
        # look first, sync only if a registration is really still there: a
        # sync that is not needed only uses up the next one
        $confirmed = Wait-DCUAutopilotRemoval -Devices $pending -Minutes 0 -PendingHint $hint
        $still = @($pending | Where-Object { $_.AutopilotState -eq 'Deletion pending' })

        if (-not $still.Count) {
            Write-DCULog -Category 'Autopilot' -Message 'Every registration is already gone - no sync needed.'
        }
        else {
            if ($script:DryRun) {
                Write-DCULog -Level Info -Category 'DryRun' -Message ("DRY RUN - $($still.Count) registration(s) still in Autopilot: would request a sync " +
                    "and wait up to $waitMin minute(s) for them to go. Nothing is sent.")
            }
            else {
                Write-DCULog -Category 'Autopilot' -Message "$($still.Count) registration(s) still in Autopilot - requesting a sync."
                try {
                    # beta only: windowsAutopilotSettings does not exist in v1.0, where
                    # this call is a plain 400 Bad Request
                    Invoke-DCUGraph -Method POST -Uri 'beta/deviceManagement/windowsAutopilotSettings/sync' -Context 'Autopilot sync' | Out-Null
                    $synced = $true
                    Write-DCULog -Level Success -Category 'Autopilot' -Message 'Autopilot sync requested.'
                }
                catch {
                    Write-DCULog -Level Warn -Category 'Autopilot' -Message ("Autopilot sync was not accepted: $($_.Exception.Message)$(Get-DCUAutopilotSyncInfo) " +
                        'Intune accepts a manual sync only every so often; a recent one (from here or the portal) counts. Waiting for the removals anyway.')
                }
                $confirmed += Wait-DCUAutopilotRemoval -Devices $still -Minutes $waitMin -PendingHint $hint
            }
        }
    }
    $stillPending = $pending.Count - $confirmed

    if ($pending.Count) {
        Write-DCULog -Level Success -Category 'Autopilot' -Message "Autopilot: $confirmed of $($pending.Count) removal(s) confirmed, $stillPending still pending."
    }
    if ($stillPending) {
        Write-DCULog -Level Warn -Category 'Autopilot' -Message ("$stillPending registration(s) are still in the Autopilot list. Run this step again in a few minutes - " +
            "the Entra ID step and the final check will show them as not released until then.")
    }
    elseif ($confirmed) {
        Write-DCULog -Category 'Autopilot' -Message "All removals confirmed. Next: $(Get-DCUStepRef 'EntraDelete') only if it applies, then $(Get-DCUStepRef 'FinalCheck')."
    }

    [pscustomobject]@{
        Step = 'AutopilotSync'; DryRun = $script:DryRun
        SyncRequested = $synced; Pending = $pending.Count; Confirmed = $confirmed; StillPending = $stillPending
        Rows = $devices
    }
}

function Get-DCUAutopilotSyncInfo {
    <# " Last manual sync requested 14:02, last completed sync 14:05." - or '' when unreadable #>
    try {
        $s = Invoke-DCUGraph -Uri 'beta/deviceManagement/windowsAutopilotSettings' -Context 'read Autopilot sync status'
        $trig = ConvertTo-DCUDate $s.lastManualSyncTriggerDateTime
        $done = ConvertTo-DCUDate $s.lastSyncDateTime
        $parts = @()
        if ($trig) { $parts += "last manual sync requested $($trig.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" }
        if ($done) { $parts += "last completed sync $($done.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" }
        if ($parts) { return " ($($parts -join ', '))." }
    }
    catch { }
    ''
}

function Get-DCUAutopilotLeft {
    <# the Autopilot ids on a row that Graph still returns - a read, so fine in a dry run #>
    param([Parameter(Mandatory)]$Device)
    @($Device.AutopilotId -split ';' | Where-Object { $_ } | Where-Object {
        $null -ne (Invoke-DCUGraph -Uri "v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$_" `
            -Context 'check Autopilot registration' -Tolerate 404)
    })
}

function Wait-DCUAutopilotRemoval {
    <#
        Re-read each pending registration by id until Graph says 404 or the
        time is up. A confirmed row becomes Deleted and loses its Autopilot
        id; the rest stay 'Deletion pending' with the ids still on them.
        Cancel stops the waiting, not the step - the deletes were already
        sent, and the rows have to come back to the caller either way.
        -PendingHint is what a still-pending row is told to do next.
        Returns how many rows were confirmed.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Devices,
        [int]$Minutes = 10,
        [int]$PollSeconds = 20,
        [string]$PendingHint = 'check again later'
    )

    $left = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Devices) { $left.Add($d) }
    $total    = $left.Count
    $deadline = (Get-Date).AddMinutes([math]::Max($Minutes, 0))
    Write-DCULog -Category 'Autopilot' -Message ("Checking that the $total registration(s) are really gone" +
        $(if ($Minutes -gt 0) { " (waiting up to $Minutes minute(s))..." } else { ' (one check, no waiting)...' }))

    try {
        while ($true) {
            Write-DCUProgress -Id 0 -Live -Activity 'Waiting for Autopilot' -Status "checking $($left.Count) of $total registration(s) now..."
            foreach ($d in @($left)) {
                $still = @(Get-DCUAutopilotLeft $d)
                if ($still.Count) { $d.AutopilotId = $still -join ';'; continue }

                $d.AutopilotState = 'Deleted'
                $d.AutopilotId    = ''
                $d.Result         = 'Autopilot registration removed (confirmed gone)'
                Write-DCULog -Level Success -Category 'Autopilot' -Message "$(Get-DCUDeviceLabel $d) - Autopilot registration confirmed gone"
                [void]$left.Remove($d)
            }
            if (-not $left.Count -or (Get-Date) -ge $deadline) { break }

            # a countdown once a second, so a ten-minute wait never looks like a hang
            $next = (Get-Date).AddSeconds($PollSeconds)
            if ($next -gt $deadline) { $next = $deadline }
            $lastTick = -1
            while ((Get-Date) -lt $next) {
                Test-DCUCancelled
                $toNext = [int][math]::Ceiling(($next - (Get-Date)).TotalSeconds)
                if ($toNext -ne $lastTick) {
                    $lastTick = $toNext
                    $toEnd = $deadline - (Get-Date)
                    if ($toEnd -lt [TimeSpan]::Zero) { $toEnd = [TimeSpan]::Zero }
                    Write-DCUProgress -Id 0 -Live -Activity 'Waiting for Autopilot' `
                        -Status ("{0} of {1} still in the list - next check in {2}s - stops waiting in {3:m\:ss} (Cancel only stops the waiting)" -f
                            $left.Count, $total, $toNext, $toEnd) `
                        -PercentComplete ([int](100 * (1 - $toEnd.TotalSeconds / [math]::Max($Minutes * 60, 1))))
                }
                Start-Sleep -Milliseconds 250
            }
        }
    }
    catch [System.OperationCanceledException] {
        Write-DCULog -Level Warn -Category 'Autopilot' -Message "Stopped waiting (cancelled). The deletes were sent - $PendingHint."
    }
    finally { Write-DCUProgress -Id 0 -Live -Activity 'Waiting for Autopilot' -Completed }

    foreach ($d in $left) {
        $d.Result = "PENDING - Autopilot delete accepted, but the registration is still in the list - $PendingHint"
    }
    $total - $left.Count
}

# ---------------------------------------------------------------------------
# Step 7 - the Entra ID device object
# ---------------------------------------------------------------------------
function Invoke-DCUEntraDelete {
    <#
        .SYNOPSIS
            Delete the Entra ID device object for the selected devices.
        .DESCRIPTION
            Usually NOT needed: for an Autopilot + Entra joined device the
            object is cleaned up once Intune and Autopilot are gone, so those
            rows are skipped by default. It matters for devices that were never
            in Autopilot and have to be fully detached.

            Hybrid joined devices (trust type ServerAd) are skipped as well:
            deleting the cloud object is pointless while the on-prem computer
            object still exists, because Entra Connect syncs it straight back.
            Those rows are listed in the final report instead.

            Autopilot first, then Entra: a row that still carries an Autopilot
            registration (or a removal that is not confirmed yet) is looked up
            live first. If the registration is gone - also when it was removed
            outside this tool - the row is updated and handled like any other.
            If it is really still there, the device is ALWAYS skipped, whatever
            the options say, and told which steps to run first.

            Deleting the device object also removes the BitLocker recovery keys
            Entra held for it - export them first (step 2).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection
    )

    Initialize-DCUContext -Session $Session
    Assert-DCUSignedIn | Out-Null

    $devices = @($Devices | ConvertTo-DCUDeviceRecord)
    $targets = @(Select-DCUDevices -Devices $devices -Selection $Selection)
    $skipAutopilot = [bool](Get-DCUStepOption -Step 'EntraDelete' -Name 'OnlyWithoutAutopilot' -Default $true)
    $skipHybrid    = [bool](Get-DCUStepOption -Step 'EntraDelete' -Name 'SkipHybrid' -Default $true)

    $apDeleteRef = Get-DCUStepRef 'AutopilotDelete'
    $apSyncRef   = Get-DCUStepRef 'AutopilotSync'

    Write-DCUModeBanner -Step 'Entra delete' -Count $targets.Count

    $plan = {
        param($d, $o)
        if (-not $d.EntraObjectId) { return [pscustomobject]@{ Eligible = $false; Reason = 'no Entra ID device object' } }

        # Autopilot has to be gone before Entra - but the list can be behind:
        # the registration may have been removed outside this tool, or its
        # removal gone through since step 6. So look it up live before
        # holding the device back (a read, so a dry run does it too).
        if ($d.AutopilotId -or $d.AutopilotState -eq 'Deletion pending') {
            $left = @(Get-DCUAutopilotLeft $d)
            if ($left.Count) {
                $d.AutopilotId = $left -join ';'
                $why = if ($d.AutopilotState -eq 'Deletion pending') { "Autopilot removal not confirmed yet (still there just now) - run $($o.ApSyncRef) first" }
                       else { "still registered in Windows Autopilot (checked just now) - run $($o.ApDeleteRef) and then $($o.ApSyncRef) first" }
                return [pscustomobject]@{ Eligible = $false; Reason = $why }
            }
            $was = $d.AutopilotState
            $d.AutopilotState = if ($was -eq 'Deletion pending') { 'Deleted' } else { 'Gone from Autopilot' }
            $d.AutopilotId    = ''
            Write-DCULog -Category 'Entra' -Message ("$(Get-DCUDeviceLabel $d) - the Autopilot registration is gone" +
                $(if ($was -eq 'Deletion pending') { ' (removal confirmed)' } else { ' (removed outside this tool)' }) + '.')
        }

        if ($o.SkipHybrid -and $d.EntraTrust -eq 'ServerAd') {
            return [pscustomobject]@{ Eligible = $false; Reason = 'hybrid joined - delete the on-prem AD computer object first' }
        }
        if ($o.SkipAutopilot -and $d.AutopilotState -in 'Deleted', 'Gone from Autopilot') {
            return [pscustomobject]@{ Eligible = $false; Reason = 'was Autopilot registered - the Entra object does not need deleting by hand' }
        }
        [pscustomobject]@{ Eligible = $true; Reason = ''; What = 'delete the Entra ID device object' }
    }

    $act = {
        param($d, $o)
        Invoke-DCUGraph -Method DELETE -Uri "v1.0/devices/$($d.EntraObjectId)" -Context 'delete Entra device' -Tolerate 404 | Out-Null
        $d.EntraState = 'Deleted'
        $d.EntraObjectId = ''
        [pscustomobject]@{ Message = 'Entra ID device object deleted' }
    }

    $counts = Invoke-DCUDeviceLoop -Targets $targets -Activity 'Removing Entra ID device objects' -Category 'Entra' -Plan $plan -Act $act `
        -Options @{ SkipHybrid = $skipHybrid; SkipAutopilot = $skipAutopilot; ApDeleteRef = $apDeleteRef; ApSyncRef = $apSyncRef }

    # the reminder, once, after the per-device SKIP lines
    $apLeft = @($targets | Where-Object { $_.EntraObjectId -and ($_.AutopilotId -or $_.AutopilotState -eq 'Deletion pending') })
    if ($apLeft.Count) {
        $notSent = @($apLeft | Where-Object { $_.AutopilotState -ne 'Deletion pending' }).Count
        $todo = if ($notSent) { "run $apDeleteRef and then $apSyncRef" } else { "run $apSyncRef" }
        Write-DCULog -Level Warn -Category 'Entra' -Message ("$($apLeft.Count) device(s) were skipped because they are still in Windows Autopilot" +
            $(if ($notSent -lt $apLeft.Count) { " ($($apLeft.Count - $notSent) with the removal not confirmed yet)" } else { '' }) +
            ". First $todo, then come back to this step.")
    }

    $hybrid = @($targets | Where-Object { $_.EntraTrust -eq 'ServerAd' })
    if ($hybrid.Count) {
        Write-DCULog -Level Warn -Category 'Entra' -Message "$($hybrid.Count) hybrid joined device(s) still need their computer object removed from the on-prem Active Directory:"
        foreach ($h in $hybrid) { Write-DCULog -Level Warn -Category 'Entra' -Message "  on-prem AD: $(Get-DCUDeviceLabel $h)" }
    }
    Write-DCULog -Level Success -Category 'Entra' -Message "Entra ID: $($counts.Done) deleted, $($counts.Simulated) simulated, $($counts.Skipped) skipped, $($counts.Failed) failed."

    [pscustomobject]@{
        Step = 'EntraDelete'; DryRun = $script:DryRun
        Selected = $counts.Total; Deleted = $counts.Done; Simulated = $counts.Simulated
        Skipped = $counts.Skipped; Failed = $counts.Failed; Warned = $counts.Flagged
        HybridNeedingOnPrem = $hybrid.Count
        Rows = $devices
    }
}
