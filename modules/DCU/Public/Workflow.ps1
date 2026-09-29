<#
    The workflow rules: how far an administrator may get, which devices a run
    acts on, and what has to be confirmed before it goes ahead.

    These used to live in the wizard's event handlers, where the CLI could not
    use them and no test could reach them. They are pure - no Graph, no files,
    no UI - so every host asks the same questions and gets the same answers:

      Get-DCUNavigationGate  how far the workflow is unlocked, and why not further
      Get-DCUSafeSelection   the devices that may be picked without looking
      Resolve-DCURunPlan     what running one step right now would do

    Resolve-DCURunPlan is also what Invoke-DCUStep checks a run against, so a
    host that skips its own checks still cannot start a run the plan refuses.

    They read device properties directly instead of normalising every row, so
    the wizard can call them on each checkbox click; anything with the device
    record's property names will do.
#>

function Get-DCUNavigationGate {
    <#
        .SYNOPSIS
            How far forward the workflow may go right now, and why not further.
        .DESCRIPTION
            Signed out, nothing is reachable. Signed in, the device list and the
            lookup are, and every later step only once every device on the list
            has been looked up: they all work on the lookup results, and a
            delete run against a list nobody has checked is the mistake this
            tool exists to prevent.

            Returns { Level; LastReachable; Reason }:
              Level          SignIn | Lookup | Open
              LastReachable  the last step key that may be opened, $null for none
              Reason         why the next one may not ('' when Open)
    #>
    [CmdletBinding()]
    param(
        [object[]]$Devices = @(),
        [bool]$SignedIn = $false
    )

    if (-not $SignedIn) {
        return [pscustomobject]@{ Level = 'SignIn'; LastReachable = $null
            Reason = 'Sign in first - nothing can be looked up or deleted until you do.' }
    }

    $total = 0; $pending = 0
    foreach ($d in $Devices) {
        if ($null -eq $d) { continue }
        $total++
        if ($d.Match -in 'Not looked up', '') { $pending++ }
    }
    if (-not $total) {
        return [pscustomobject]@{ Level = 'Lookup'; LastReachable = 'Lookup'
            Reason = 'Put the devices on the list and look them up first.' }
    }
    if ($pending) {
        return [pscustomobject]@{ Level = 'Lookup'; LastReachable = 'Lookup'
            Reason = "Look up the devices first - $pending of $total not looked up yet." }
    }
    [pscustomobject]@{ Level = 'Open'; LastReachable = $script:DCUStepCatalog[-1].Key; Reason = '' }
}

function Get-DCUSafeSelection {
    <# The keys of the devices that are looked up, found and not flagged (Test-DCUSafeDevice). #>
    [CmdletBinding()]
    param([object[]]$Devices = @())
    @(foreach ($d in $Devices) { if ($null -ne $d -and (Test-DCUSafeDevice $d)) { [string]$d.Key } })
}

function Resolve-DCURunPlan {
    <#
        .SYNOPSIS
            What running one step now would do, and whether it may.
        .DESCRIPTION
            A Selection step acts on exactly the keys in -Selection - an empty
            selection is "nothing", never "everything". A WholeList step acts on
            the whole list and ignores -Selection.

            A Destructive step that runs for real needs a confirmation. The
            plan carries a ConfirmationKey: a fingerprint of the step, the mode,
            the step options and the exact target keys. Invoke-DCUStep refuses
            to run such a step unless it is handed the key of the plan it
            recomputes itself, so what was confirmed is what runs - not a list
            that changed in between, and not a Wipe that was confirmed as a
            Retire.

            Returns:
              Step, Number, Name, Effect, Scope, DryRun
              Targets / TargetCount    the keys the run acts on
              UnknownKeys              selected keys that are not on the list
              Flagged                  targets with a warning: { Key; Label; Flag }
              NotBackedUp              destructive steps: targets never exported
              PendingAutopilot         targets whose Autopilot delete is unconfirmed
              Label                    the action, "Simulate: ..." in a dry run
              ConfirmAction            "delete from Intune" (destructive only)
              CanRun / Blocked / BlockedReason
                                       Blocked is NotSignedIn | EmptyList |
                                       NothingSelected, for hosts to word their own way
              ChangesTenant            this run sends writes (never in a dry run)
              RequiresConfirmation     destructive and for real
              ConfirmationKey
              Options                  the step options the plan was made with
        .PARAMETER Options
            This step's option overrides; merged with the catalogue defaults.
        .PARAMETER SignedIn
            The host's sign-in state. Invoke-DCUStep leaves it at $true - the
            step checks the real sign-in itself before it touches anything.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [object[]]$Devices = @(),
        [string[]]$Selection = @(),
        [bool]$DryRun = $true,
        [bool]$SignedIn = $true,
        [hashtable]$Options = @{}
    )

    $meta = Get-DCUStepMeta -Key $Step
    if (-not $meta) { throw "Unknown step: $Step" }
    if ($meta.Scope -eq 'Input') { throw "$Step builds the device list - it is not a step that runs against it." }

    $opts = Resolve-DCUStepOptions -Key $Step -Override $Options
    $list = @(foreach ($d in $Devices) { if ($null -ne $d) { $d } })

    $targets = [System.Collections.Generic.List[object]]::new()
    $unknown = @()
    if ($meta.Scope -eq 'WholeList') {
        foreach ($d in $list) { $targets.Add($d) }
    }
    else {
        $want = @{}
        foreach ($k in @($Selection)) { if ($k) { $want[[string]$k] = $true } }
        $have = @{}
        foreach ($d in $list) {
            $have[[string]$d.Key] = $true
            if ($want.ContainsKey([string]$d.Key)) { $targets.Add($d) }
        }
        $unknown = @($want.Keys | Where-Object { -not $have.ContainsKey($_) } | Sort-Object)
    }
    $n = $targets.Count

    $flagged = @(); $notBackedUp = 0; $pending = 0
    foreach ($d in $targets) {
        if ($d.Warn) { $flagged += [pscustomobject]@{ Key = [string]$d.Key; Label = (Get-DCUDeviceLabel $d); Flag = [string]$d.Flag } }
        if (-not $d.ExportedAt) { $notBackedUp++ }
        if ($d.AutopilotState -eq 'Deletion pending') { $pending++ }
    }

    $writes      = $meta.Effect -ne 'ReadOnly'
    $destructive = $meta.Effect -eq 'Destructive'

    $fill = { param($t) ([string]$t).Replace('{n}', "$n").Replace('{mode}', [string]$opts.Mode).Replace('{pending}', "$pending") }
    $label = if ($meta.RunLabelIdle -and -not $pending) { [string]$meta.RunLabelIdle } else { & $fill $meta.RunLabel }
    if ($writes -and $DryRun) { $label = "Simulate: $label" }

    $blocked = ''; $reason = ''
    if (-not $SignedIn) { $blocked = 'NotSignedIn'; $reason = 'Not signed in.' }
    elseif (-not $n) {
        if ($meta.Scope -eq 'WholeList') { $blocked = 'EmptyList'; $reason = 'The device list is empty.' }
        else { $blocked = 'NothingSelected'; $reason = 'No devices are selected for this step.' }
    }

    $sorted = @($targets | ForEach-Object { [string]$_.Key } | Sort-Object)
    [pscustomobject]@{
        Step                 = $meta.Key
        Number               = $meta.Number
        Name                 = $meta.Name
        Effect               = $meta.Effect
        Scope                = $meta.Scope
        DryRun               = $DryRun
        Targets              = $sorted
        TargetCount          = $n
        UnknownKeys          = $unknown
        Flagged              = $flagged
        NotBackedUp          = $(if ($destructive) { $notBackedUp } else { 0 })
        PendingAutopilot     = $pending
        Label                = $label
        ConfirmAction        = $(if ($destructive) { & $fill $meta.ConfirmAction } else { '' })
        CanRun               = -not $blocked
        Blocked              = $blocked
        BlockedReason        = $reason
        ChangesTenant        = $writes -and -not $DryRun
        RequiresConfirmation = $destructive -and -not $DryRun
        ConfirmationKey      = Get-DCUConfirmationKey -Step $meta.Key -DryRun $DryRun -Options $opts -Targets $sorted
        Options              = $opts
    }
}

function Get-DCUConfirmationKey {
    <#
        A short fingerprint of exactly what a run would do. Not a secret and
        not a signature - it only has to change whenever the step, the mode,
        an option or the set of target devices changes.
    #>
    param(
        [Parameter(Mandatory)][string]$Step,
        [bool]$DryRun,
        [hashtable]$Options = @{},
        [string[]]$Targets = @()
    )
    # options are rendered as text, so 10 and '10' or $true and 'True' agree
    $opt = @($Options.Keys | Sort-Object | ForEach-Object { "$_=$($Options[$_])" }) -join ';'
    $text = "$Step|$DryRun|$opt|$(@($Targets | Sort-Object) -join ',')"
    $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($text))
    -join ($hash[0..7] | ForEach-Object { $_.ToString('x2') })
}
