<#
    Get-DCUStepList  - the catalogue as plain objects (wizard rail + CLI help)
    Get-DCUStatus    - per-step Done / Ready / Blocked state for the rail

    Unlike the migration tool next door there are no config files to inspect:
    the state of a cleanup run lives in the device list the host is holding, so
    Get-DCUStatus takes that list and reads counts off it.
#>

function Get-DCUStepList {
    [CmdletBinding()]
    param()
    $script:DCUStepCatalog | ForEach-Object {
        [pscustomobject]@{
            Key         = $_.Key
            Number      = $_.Number
            Name        = $_.Name
            Effect      = $_.Effect
            Scope       = $_.Scope
            # kept for callers that only need the yes/no: deletes or wipes
            Destructive = ($_.Effect -eq 'Destructive')
            Summary     = [string]$_.Summary
            Explainer   = [string]$_.Explainer
            Options     = $_.Options
        }
    }
}

function Get-DCUStatus {
    <#
        .SYNOPSIS
            Done / Partial / Ready / Blocked per step, from the device list.
        .PARAMETER Devices
            The working set the host is holding. Empty is fine - everything
            after step 1 is then Blocked.
        .PARAMETER SignedIn
            Whether there is a Graph sign-in. Without one nothing but the
            device input step can run.
    #>
    [CmdletBinding()]
    param(
        [object[]]$Devices = @(),
        [bool]$SignedIn = $false
    )

    $devices    = @($Devices)
    $total      = $devices.Count
    $lookedUp   = @($devices | Where-Object { $_.Match -ne 'Not looked up' }).Count
    $inIntune   = @($devices | Where-Object { $_.IntuneId }).Count
    $inAp       = @($devices | Where-Object { $_.AutopilotId }).Count
    $inEntra    = @($devices | Where-Object { $_.EntraObjectId }).Count
    # an explicit field, not the Result text: every later step overwrites
    # Result, and step 2 must not look undone again after step 4 ran
    $exported   = @($devices | Where-Object { $_.ExportedAt -or $_.BitLockerState }).Count
    $intuneGone = @($devices | Where-Object { $_.IntuneState -eq 'Deleted' -or $_.IntuneState -eq 'Not in Intune' }).Count
    # a sent-but-unconfirmed Autopilot delete keeps its id: step 5 is done for
    # that row, step 6 (sync and confirm) is not
    $apPending  = @($devices | Where-Object { $_.AutopilotState -eq 'Deletion pending' }).Count
    $apToDelete = @($devices | Where-Object { $_.AutopilotId -and $_.AutopilotState -ne 'Deletion pending' }).Count
    $apRemoved  = @($devices | Where-Object { $_.AutopilotState -in 'Deleted', 'Gone from Autopilot' }).Count
    $apSteps    = "steps $((Get-DCUStepMeta 'AutopilotDelete').Number) and $((Get-DCUStepMeta 'AutopilotSync').Number)"

    $gate = Get-DCUNavigationGate -Devices $devices -SignedIn $SignedIn
    $lastReachable = if ($gate.LastReachable) { Get-DCUStepIndex $gate.LastReachable } else { -1 }
    $index = 0

    $rows = foreach ($meta in $script:DCUStepCatalog) {
        $status = 'Ready'
        $detail = ''
        switch ($meta.Key) {
            'DeviceInput' {
                if ($total) { $status = 'Done'; $detail = "$total device(s) on the list" }
                else { $status = 'Ready'; $detail = 'no devices yet' }
            }
            'Lookup' {
                if (-not $total) { $status = 'Blocked'; $detail = 'add devices first' }
                elseif (-not $SignedIn) { $status = 'Blocked'; $detail = 'sign in on the Setup page' }
                elseif ($lookedUp -eq $total) { $status = 'Done'; $detail = "$inIntune in Intune, $inAp in Autopilot, $inEntra in Entra ID" }
                elseif ($lookedUp) { $status = 'Partial'; $detail = "$lookedUp of $total looked up" }
                else { $status = 'Ready'; $detail = "$total device(s) to look up" }
            }
            'Backup' {
                if (-not $lookedUp) { $status = 'Blocked'; $detail = 'run the lookup first' }
                elseif ($exported) { $status = 'Done'; $detail = 'exported' }
                else { $status = 'Ready'; $detail = 'nothing exported yet' }
            }
            'Wipe' {
                if (-not $inIntune) { $status = 'Blocked'; $detail = 'no devices in Intune' }
                else { $status = 'Ready'; $detail = 'optional - only for devices you still have' }
            }
            'IntuneDelete' {
                if (-not $lookedUp) { $status = 'Blocked'; $detail = 'run the lookup first' }
                elseif (-not $inIntune) { $status = 'Done'; $detail = 'nothing left in Intune' }
                elseif ($intuneGone -eq $total) { $status = 'Done'; $detail = 'all devices are out of Intune' }
                elseif ($intuneGone) { $status = 'Partial'; $detail = "$intuneGone of $total out of Intune" }
                else { $status = 'Ready'; $detail = "$inIntune device(s) in Intune" }
            }
            'AutopilotDelete' {
                if (-not $lookedUp) { $status = 'Blocked'; $detail = 'run the lookup first' }
                elseif ($apToDelete -and ($apPending -or $apRemoved)) { $status = 'Partial'; $detail = "$apToDelete registration(s) still to remove" }
                elseif ($apToDelete) { $status = 'Ready'; $detail = "$apToDelete registration(s) to remove" }
                elseif ($apPending) { $status = 'Done'; $detail = "deletes sent - confirm them in step $((Get-DCUStepMeta 'AutopilotSync').Number)" }
                elseif ($apRemoved) { $status = 'Done'; $detail = 'all Autopilot registrations removed' }
                else { $status = 'Done'; $detail = 'no Autopilot registrations' }
            }
            'AutopilotSync' {
                if (-not $lookedUp) { $status = 'Blocked'; $detail = 'run the lookup first' }
                elseif ($apPending) { $status = 'Ready'; $detail = "$apPending removal(s) to confirm" }
                elseif ($apRemoved) { $status = 'Done'; $detail = 'removals confirmed' }
                else { $status = 'Ready'; $detail = 'nothing to confirm yet' }
            }
            'EntraDelete' {
                if (-not $lookedUp) { $status = 'Blocked'; $detail = 'run the lookup first' }
                elseif (-not $inEntra) { $status = 'Done'; $detail = 'no Entra device objects' }
                elseif ($apToDelete -or $apPending) { $status = 'Ready'; $detail = "$($apToDelete + $apPending) still in Autopilot - $apSteps first" }
                else { $status = 'Ready'; $detail = "$inEntra object(s) - usually only needed without Autopilot" }
            }
            'FinalCheck' {
                if (-not $lookedUp) { $status = 'Blocked'; $detail = 'run the lookup first' }
                else { $status = 'Ready'; $detail = 're-checks all three systems' }
            }
        }
        [pscustomobject]@{
            Key       = $meta.Key
            Number    = $meta.Number
            Name      = $meta.Name
            Status    = $status
            Detail    = $detail
            # Status says whether the step has work to do; Reachable says
            # whether the workflow lets you get to it yet (Get-DCUNavigationGate)
            Reachable = ($index -le $lastReachable)
        }
        $index++
    }

    $rows
}
