<#
    Invoke-DCUStep - the one way a host runs a step.

    The step functions (Invoke-DCUIntuneDelete, ...) stay callable on their
    own, but hosts go through here, so the rules are the same whoever asks -
    the CLI, the wizard, or a web front end that only ever sends a request:

      * the plan is worked out again here (Resolve-DCURunPlan), from the
        devices and the selection the request carries. A run the plan
        refuses does not start.
      * a destructive step that runs for real needs the ConfirmationKey of
        that same plan. The host showed the administrator the plan and got a
        yes; the key proves the yes was for these devices, this step and these
        options. No key, or a key for anything else, and nothing is sent.
      * a large one (RequiresTypedConfirmation) also needs the tenant typed
        in, and that is checked against the tenant this session is really
        signed in to - not against anything the host says.
      * a Selection step gets exactly the planned keys. An empty selection is
        refused by the plan, so it can never fall through to "all devices".
      * afterwards the working set is saved, and a save that fails is
        reported on the result instead of being swallowed.
#>

function Invoke-DCUStep {
    <#
        .SYNOPSIS
            Run one step against the device list, under the workflow rules.
        .PARAMETER ConfirmationKey
            The ConfirmationKey of the plan the administrator confirmed. Only
            needed for a destructive step outside a dry run.
        .PARAMETER TenantConfirmation
            What the administrator typed as the tenant. Only needed when the
            plan says RequiresTypedConfirmation; must be the signed-in
            tenant's domain or id (case does not matter).
        .PARAMETER NoSave
            Do not write <WorkFolder>\workingset.json afterwards.
        .OUTPUTS
            The step's own summary, plus WorkingSet (the saved path) or
            WorkingSetError (why it could not be saved).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection = @(),
        [string]$ConfirmationKey,
        [string]$TenantConfirmation,
        [switch]$NoSave
    )

    $options = @{}
    if ($Session.StepOptions -and $Session.StepOptions.ContainsKey($Step) -and $Session.StepOptions[$Step]) {
        $options = $Session.StepOptions[$Step]
    }
    $plan = Resolve-DCURunPlan -Step $Step -Devices $Devices -Selection $Selection -DryRun ([bool]$Session.DryRun) -Options $options

    if (-not $plan.CanRun) {
        throw "$(Get-DCUStepRef $Step) was not run: $($plan.BlockedReason)"
    }
    if ($plan.RequiresConfirmation -and $ConfirmationKey -ne $plan.ConfirmationKey) {
        $why = if ($ConfirmationKey) { 'the confirmation was given for a different set of devices or options' }
               else { 'it runs for real and was not confirmed' }
        throw "$(Get-DCUStepRef $Step) was not run: $why. Nothing was changed - review the $($plan.TargetCount) device(s) and confirm again."
    }
    if ($plan.RequiresTypedConfirmation) {
        $state = Assert-DCUSignedIn
        $typed = ([string]$TenantConfirmation).Trim()
        $known = @($state.TenantDomain, $state.TenantId) | Where-Object { $_ }
        if (-not $typed -or -not @($known | Where-Object { $_ -eq $typed }).Count) {
            $name = @($known)[0]
            throw ("$(Get-DCUStepRef $Step) was not run: it changes $($plan.TargetCount) devices, so the tenant has to be typed in to confirm " +
                "(signed in to $name)$(if ($typed) { " - '$typed' is not this tenant" }). Nothing was changed.")
        }
    }
    if ($plan.UnknownKeys.Count) {
        Write-DCULog -Level Warn -Message "These selected keys are not in the device list and were skipped: $($plan.UnknownKeys -join ', ')"
    }

    $call = @{ Session = $Session; Devices = $Devices }
    if ($plan.Scope -eq 'Selection') { $call.Selection = $plan.Targets }
    $summary = & "Invoke-DCU$($plan.Step)" @call

    if (-not $NoSave -and $Session.WorkFolder -and $summary.PSObject.Properties['Rows']) {
        try {
            $path = Save-DCUWorkingSet -Devices @($summary.Rows) -Session $Session
            $summary | Add-Member -NotePropertyName WorkingSet -NotePropertyValue $path -Force
        }
        catch {
            # the step itself went through - losing track of it on disk must
            # not look like success, or the next session starts from old state
            $msg = "The device list could not be saved after this step: $($_.Exception.Message). Save it by hand before you close."
            Write-DCULog -Level Error -Category 'WorkingSet' -Message $msg
            $summary | Add-Member -NotePropertyName WorkingSetError -NotePropertyValue $msg -Force
        }
    }
    $summary
}
