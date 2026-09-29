<#
    Workflow checks - dot-sourced by Run-SmokeTests.ps1, which provides Check,
    NewRec, MatchRec, FakeStep, Get-ThrownMessage, $mod, $tmp and the fixture
    inventories.

    What is checked here is what a host relies on: where the workflow stops
    you, which devices a run touches, what has to be confirmed, and that
    nothing reaches the tenant when it should not. The fake Graph only stands
    in for the tenant; the assertions are about the tool's own decisions.
#>

function WfRows {
    <# a fresh looked-up list: LT-0001 is safe, LT-0002 was seen 2 days ago, NOPE12345 is not in the tenant #>
    @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'; NewRec -Serial '5CD2222BBB'; NewRec -Serial 'NOPE12345'))
}
function FakeCalls { <# the Graph calls the last FakeStep made, also when it threw #> & $mod { @($script:fakeCalls) } }
$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

# --- navigation gate ---------------------------------------------------------
Check 'gate: signed out, no step is reachable' {
    $g = Get-DCUNavigationGate -Devices (WfRows) -SignedIn $false
    $open = @(Get-DCUStatus -Devices (WfRows) -SignedIn $false | Where-Object Reachable)
    ($g.Level -eq 'SignIn') -and ($null -eq $g.LastReachable) -and ($open.Count -eq 0)
}

Check 'gate: signed in with an empty list, only the list and the lookup are reachable' {
    $open = @(Get-DCUStatus -Devices @() -SignedIn $true | Where-Object Reachable | ForEach-Object Key)
    ($open -join ',') -eq 'DeviceInput,Lookup'
}

Check 'gate: one device not looked up keeps every later step closed, and says how many' {
    $rows = @(WfRows) + @(NewRec -Serial 'NEW0001')
    $g = Get-DCUNavigationGate -Devices $rows -SignedIn $true
    $delete = Get-DCUStatus -Devices $rows -SignedIn $true | Where-Object Key -eq 'IntuneDelete'
    ($g.Level -eq 'Lookup') -and ($g.Reason -like '*1 of 4 not looked up*') -and -not $delete.Reachable
}

Check 'gate: a fully looked-up list opens every step' {
    $g = Get-DCUNavigationGate -Devices (WfRows) -SignedIn $true
    $closed = @(Get-DCUStatus -Devices (WfRows) -SignedIn $true | Where-Object { -not $_.Reachable })
    ($g.Level -eq 'Open') -and ($g.LastReachable -eq 'FinalCheck') -and ($closed.Count -eq 0)
}

# --- device selection ----------------------------------------------------------
Check 'safe selection: only looked up, found and unflagged devices' {
    $safe = @(Get-DCUSafeSelection -Devices (@(WfRows) + @(NewRec -Serial 'NEW0001')))
    ($safe.Count -eq 1) -and ($safe[0] -eq 'S:5CD1111AAA')
}

# --- run plans -------------------------------------------------------------------
Check 'plan: a Selection step acts on exactly the picked devices and reports unknown keys' {
    $p = Resolve-DCURunPlan -Step IntuneDelete -Devices (WfRows) -Selection 'S:5CD1111AAA', 'S:TYPO' -DryRun $true
    $p.CanRun -and ($p.TargetCount -eq 1) -and ($p.Targets[0] -eq 'S:5CD1111AAA') -and ($p.UnknownKeys -contains 'S:TYPO')
}

Check 'plan: an empty selection is nothing, never the whole list' {
    $p = Resolve-DCURunPlan -Step IntuneDelete -Devices (WfRows) -Selection @() -DryRun $false
    (-not $p.CanRun) -and ($p.Blocked -eq 'NothingSelected') -and ($p.TargetCount -eq 0)
}

Check 'plan: a WholeList step ignores the selection' {
    $p = Resolve-DCURunPlan -Step FinalCheck -Devices (WfRows) -Selection 'S:5CD1111AAA'
    ($p.TargetCount -eq 3) -and ($p.Label -eq 'Check 3 device(s)')
}

Check 'plan: a WholeList step on an empty list is blocked as an empty list' {
    $p = Resolve-DCURunPlan -Step Lookup -Devices @()
    (-not $p.CanRun) -and ($p.Blocked -eq 'EmptyList')
}

Check 'plan: signed out, nothing can run' {
    $p = Resolve-DCURunPlan -Step Lookup -Devices (WfRows) -SignedIn $false
    (-not $p.CanRun) -and ($p.Blocked -eq 'NotSignedIn')
}

Check 'plan: a dry run of a destructive step changes nothing and needs no confirmation' {
    $p = Resolve-DCURunPlan -Step AutopilotDelete -Devices (WfRows) -Selection 'S:5CD1111AAA' -DryRun $true
    ($p.Label -eq 'Simulate: Remove 1 Autopilot registration(s)') -and -not $p.ChangesTenant -and -not $p.RequiresConfirmation
}

Check 'plan: for real, a destructive step needs a confirmation and says what it will do' {
    $p = Resolve-DCURunPlan -Step EntraDelete -Devices (WfRows) -Selection 'S:5CD1111AAA' -DryRun $false
    $p.RequiresConfirmation -and $p.ChangesTenant -and
    ($p.ConfirmAction -eq 'delete the Entra ID device object of') -and ($p.Label -eq 'Delete 1 Entra ID object(s)')
}

Check 'plan: the Wipe label and confirmation follow the chosen mode' {
    $p = Resolve-DCURunPlan -Step Wipe -Devices (WfRows) -Selection 'S:5CD1111AAA' -DryRun $false -Options @{ Mode = 'Retire' }
    ($p.Label -eq 'Retire 1 device(s)') -and ($p.ConfirmAction -eq 'send a Retire to')
}

Check 'plan: the Autopilot sync is held back in a dry run but never needs a confirmation' {
    $live = Resolve-DCURunPlan -Step AutopilotSync -Devices (WfRows) -DryRun $false
    $dry  = Resolve-DCURunPlan -Step AutopilotSync -Devices (WfRows) -DryRun $true
    $live.ChangesTenant -and -not $live.RequiresConfirmation -and ($dry.Label -like 'Simulate:*') -and
    ($live.Label -eq 'Check for Autopilot removals')
}

Check 'plan: the sync label counts the removals waiting to be confirmed' {
    $rows = @(WfRows); $rows[0].AutopilotState = 'Deletion pending'
    (Resolve-DCURunPlan -Step AutopilotSync -Devices $rows -DryRun $false).Label -eq 'Confirm 1 Autopilot removal(s)'
}

Check 'plan: the confirmation key changes with the devices, the mode and dry run - and only then' {
    $key = { param($sel, $opt, $dry) (Resolve-DCURunPlan -Step Wipe -Devices (WfRows) -Selection $sel -DryRun $dry -Options $opt).ConfirmationKey }
    $base = & $key @('S:5CD1111AAA') @{} $false
    ($base -eq (& $key @('S:5CD1111AAA') @{} $false)) -and
    ($base -eq (& $key @('S:5CD1111AAA') @{ Mode = 'Wipe' } $false)) -and          # the default, spelled out, is the same run
    ($base -ne (& $key @('S:5CD1111AAA', 'S:5CD2222BBB') @{} $false)) -and
    ($base -ne (& $key @('S:5CD1111AAA') @{ Mode = 'Retire' } $false)) -and
    ($base -ne (& $key @('S:5CD1111AAA') @{} $true))
}

Check 'plan: flagged targets are named with their warning' {
    $p = Resolve-DCURunPlan -Step IntuneDelete -Devices (WfRows) -Selection 'S:5CD1111AAA', 'S:5CD2222BBB' -DryRun $false
    $f = @($p.Flagged)
    ($f.Count -eq 1) -and ($f[0].Key -eq 'S:5CD2222BBB') -and ($f[0].Flag -like '*STILL IN USE*') -and ($f[0].Label -eq 'LT-0002 (5CD2222BBB)')
}

Check 'plan: destructive steps count the devices that were never exported' {
    $rows = @(WfRows); $rows[0].ExportedAt = '2026-09-29 10:00'
    $delete = Resolve-DCURunPlan -Step IntuneDelete -Devices $rows -Selection 'S:5CD1111AAA', 'S:5CD2222BBB' -DryRun $false
    $export = Resolve-DCURunPlan -Step Backup -Devices $rows -Selection 'S:5CD1111AAA', 'S:5CD2222BBB'
    ($delete.NotBackedUp -eq 1) -and ($export.NotBackedUp -eq 0)
}

Check 'plan: building the list is not a step that runs against it' {
    (Get-ThrownMessage { Resolve-DCURunPlan -Step DeviceInput }) -like '*builds the device list*'
}

# --- Invoke-DCUStep: the confirmation is enforced where the writes are ---------
Check 'run: a real destructive run without a confirmation is refused, and nothing is sent' {
    $err = Get-ThrownMessage { FakeStep IntuneDelete (WfRows) -ViaInvokeStep -Selection 'S:5CD1111AAA' }
    ($err -like '*not confirmed*') -and (@(FakeCalls).Count -eq 0)
}

Check 'run: a confirmation given for other devices is refused, and nothing is sent' {
    $key = (Resolve-DCURunPlan -Step IntuneDelete -Devices (WfRows) -Selection 'S:5CD1111AAA' -DryRun $false).ConfirmationKey
    $err = Get-ThrownMessage { FakeStep IntuneDelete (WfRows) -ViaInvokeStep -Selection 'S:5CD1111AAA', 'S:5CD2222BBB' -ConfirmationKey $key }
    ($err -like '*different set*') -and (@(FakeCalls).Count -eq 0)
}

Check 'run: a Retire confirmation does not let a Wipe through' {
    $key = (Resolve-DCURunPlan -Step Wipe -Devices (WfRows) -Selection 'S:5CD1111AAA' -DryRun $false -Options @{ Mode = 'Retire' }).ConfirmationKey
    # the session runs the catalogue default, Mode = Wipe
    $err = Get-ThrownMessage { FakeStep Wipe (WfRows) -ViaInvokeStep -Selection 'S:5CD1111AAA' -ConfirmationKey $key }
    ($err -like '*different set*') -and (@(FakeCalls).Count -eq 0)
}

Check 'run: the confirmed plan runs on the confirmed device only, and the list is saved' {
    $key = (Resolve-DCURunPlan -Step IntuneDelete -Devices (WfRows) -Selection 'S:5CD1111AAA' -DryRun $false).ConfirmationKey
    $r = FakeStep IntuneDelete (WfRows) -ViaInvokeStep -Selection 'S:5CD1111AAA' -ConfirmationKey $key
    $writes = @($r.Calls | Where-Object { $_ -notlike 'GET*' })
    $saved = @(Import-DCUWorkingSet -Path $r.Res.WorkingSet) | Where-Object Key -eq 'S:5CD1111AAA'
    (($writes -join '|') -eq 'DELETE v1.0/deviceManagement/managedDevices/i-1') -and
    ($saved.IntuneState -eq 'Deleted') -and ($saved.Outcome -eq 'Done')
}

Check 'run: a dry run needs no confirmation and sends no write' {
    $r = FakeStep AutopilotDelete (WfRows) -ViaInvokeStep -Selection 'S:5CD1111AAA' -DryRun $true
    $row = @($r.Res.Rows | Where-Object Key -eq 'S:5CD1111AAA')[0]
    (@($r.Calls | Where-Object { $_ -notlike 'GET*' }).Count -eq 0) -and ($row.Outcome -eq 'Simulated')
}

Check 'run: an empty selection is refused before the step starts (it used to mean every device)' {
    $err = Get-ThrownMessage { FakeStep Backup (WfRows) -ViaInvokeStep -Selection @() }
    ($err -like '*No devices are selected*') -and (@(FakeCalls).Count -eq 0)
}

Check 'run: a working set that cannot be saved is reported on the result, not swallowed' {
    $res = & $mod {
        param($rows, $work)
        $saved = @{ Save = ${function:Save-DCUWorkingSet}; Auth = ${function:Assert-DCUSignedIn} }
        try {
            ${function:script:Save-DCUWorkingSet} = { throw 'the disk is full' }
            ${function:script:Assert-DCUSignedIn} = { [pscustomobject]@{ SignedIn = $true } }
            Invoke-DCUStep -Step Backup -Session (New-DCUSession -WorkFolder $work) -Devices $rows -Selection 'S:5CD1111AAA'
        }
        finally {
            ${function:script:Save-DCUWorkingSet} = $saved.Save
            ${function:script:Assert-DCUSignedIn} = $saved.Auth
        }
    } (WfRows) $tmp
    ($res.WorkingSetError -like '*the disk is full*') -and -not $res.PSObject.Properties['WorkingSet']
}

# --- large batches: the tenant has to be typed in ------------------------------------
function BatchRows {
    <# $Count devices, all found in Intune and none flagged #>
    param([int]$Count)
    $old = (Get-Date).AddDays(-300).ToString('o')
    $inv = @(1..$Count | ForEach-Object { [pscustomobject]@{ id = "b-$_"; deviceName = "LT-B$_"; serialNumber = "BATCH$_"; lastSyncDateTime = $old } })
    @(MatchRec -Devices @(1..$Count | ForEach-Object { NewRec -Serial "BATCH$_" }) -Intune $inv -Autopilot @() -Entra @())
}
function BatchPlan { param($Rows, [bool]$DryRun = $false) Resolve-DCURunPlan -Step IntuneDelete -Devices $Rows -Selection @($Rows.Key) -DryRun $DryRun -TenantDomain 'contoso.onmicrosoft.com' }

Check 'plan: from 10 devices on, a real destructive run needs the tenant typed in' {
    $nine = BatchPlan (BatchRows 9); $ten = BatchPlan (BatchRows 10); $dry = BatchPlan (BatchRows 10) -DryRun $true
    -not $nine.RequiresTypedConfirmation -and $ten.RequiresTypedConfirmation -and -not $dry.RequiresTypedConfirmation -and
    ($ten.TypedConfirmationText -eq 'contoso.onmicrosoft.com')
}

Check 'run: a large batch without the typed tenant is refused, and nothing is sent' {
    $rows = BatchRows 10; $key = (BatchPlan $rows).ConfirmationKey
    $err = Get-ThrownMessage { FakeStep IntuneDelete $rows -ViaInvokeStep -Selection @($rows.Key) -ConfirmationKey $key }
    ($err -like '*typed in*') -and (@(FakeCalls).Count -eq 0)
}

Check 'run: a large batch confirmed for another tenant is refused, and nothing is sent' {
    $rows = BatchRows 10; $key = (BatchPlan $rows).ConfirmationKey
    $err = Get-ThrownMessage { FakeStep IntuneDelete $rows -ViaInvokeStep -Selection @($rows.Key) -ConfirmationKey $key -TenantConfirmation 'fabrikam.onmicrosoft.com' }
    ($err -like "*'fabrikam.onmicrosoft.com' is not this tenant*") -and (@(FakeCalls).Count -eq 0)
}

Check 'run: a large batch runs with the tenant typed in, in any case' {
    $rows = BatchRows 10; $key = (BatchPlan $rows).ConfirmationKey
    $r = FakeStep IntuneDelete $rows -ViaInvokeStep -Selection @($rows.Key) -ConfirmationKey $key -TenantConfirmation ' Contoso.OnMicrosoft.com '
    @($r.Calls | Where-Object { $_ -like 'DELETE*' }).Count -eq 10
}

# --- outcomes and status -----------------------------------------------------------
Check 'the action loop records a machine-readable outcome for every row' {
    $d = @(NewRec -Serial 'A1'; NewRec -Serial 'B2'; NewRec -Serial 'C3')
    & $mod {
        param($rows, $work)
        Initialize-DCUContext -Session (New-DCUSession -WorkFolder $work -DryRun:$false)
        $plan = { param($x) [pscustomobject]@{ Eligible = ($x.Serial -ne 'C3'); Reason = 'not eligible'; What = 'do it' } }
        $act  = { param($x) if ($x.Serial -eq 'A1') { throw 'boom' } }
        Invoke-DCUDeviceLoop -Targets $rows -Activity 't' -Category 't' -Plan $plan -Act $act | Out-Null
    } $d $tmp
    ($d.Outcome -join ',') -eq 'Failed,Done,Skipped'
}

Check 'an accepted Autopilot delete is Pending until it is confirmed gone' {
    $r = FakeStep AutopilotDelete @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))
    @($r.Res.Rows)[0].Outcome -eq 'Pending'
}

Check 'step 2 stays done after a later step overwrites the Result text' {
    $rows = @((FakeStep Backup (WfRows)).Res.Rows)
    $rows = @((FakeStep IntuneDelete $rows -DryRun $true).Res.Rows)
    $backup = Get-DCUStatus -Devices $rows -SignedIn $true | Where-Object Key -eq 'Backup'
    ($backup.Status -eq 'Done') -and ($rows[0].Result -like 'DRY RUN*') -and $rows[0].ExportedAt
}

Check 'Backup returns one summary, not the export path as well' {
    # it used to return @(<csv path>, <summary>): the wizard's result panel then
    # listed the array's Length and Rank, and the working set was not saved
    $r = FakeStep Backup (WfRows)
    (@($r.Res).Count -eq 1) -and ($r.Res.Step -eq 'Backup')
}

Check 'Backup with every export switched off marks nothing as exported' {
    $r = FakeStep Backup (WfRows) -StepOptions @{ Backup = @{ ExportCsv = $false } }
    @($r.Res.Rows | Where-Object ExportedAt).Count -eq 0
}

Check 'a working set saved before Outcome existed is migrated when it is loaded' {
    $p = Join-Path $tmp 'legacy.json'
    @{ Devices = @(
        @{ Key = 'S:A1'; Serial = 'A1'; Match = 'Matched'; Result = 'Exported' }
        @{ Key = 'S:B2'; Serial = 'B2'; Match = 'Matched'; Result = 'PENDING - Autopilot delete accepted' }
        @{ Key = 'S:C3'; Serial = 'C3'; Match = 'Matched'; Result = 'FAILED - boom' }
    ) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $p
    $back = @(Import-DCUWorkingSet -Path $p)
    (($back.Outcome -join ',') -eq 'Done,Pending,Failed') -and $back[0].ExportedAt -and -not $back[1].ExportedAt
}

# --- settings ------------------------------------------------------------------------
Check 'settings: a DryRun key in the settings file is never restored' {
    $p = Join-Path $tmp 'config.json'
    '{ "DryRun": false, "RecentDays": 14 }' | Set-Content -LiteralPath $p
    $s = Read-DCUSettings -Path $p
    ($s.PSObject.Properties.Name -notcontains 'DryRun') -and ($s.RecentDays -eq 14)
}

Check 'settings: saving never writes a dry-run switch, even when handed one' {
    $p = Join-Path $tmp 'config2.json'
    Save-DCUSettings -Path $p -Settings @{ DryRun = $false; ScopeWipe = $true }
    $raw = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    ($raw.PSObject.Properties.Name -notcontains 'DryRun') -and ((Read-DCUSettings -Path $p).ScopeWipe -eq $true)
}

Check 'settings: RecentDays is parsed and kept within what a session accepts' {
    $f = { param($v) (ConvertTo-DCUSettings @{ RecentDays = $v }).RecentDays }
    ((& $f 'abc') -eq 30) -and ((& $f '-5') -eq 0) -and ((& $f '99999') -eq 3650) -and ((& $f ' 7 ') -eq 7)
}

Check 'settings: the text "false" is false' {
    -not (ConvertTo-DCUSettings @{ WindowsOnly = 'false' }).WindowsOnly
}

Check 'settings: a missing file gives the defaults, an unreadable one says so' {
    $default = Read-DCUSettings -Path (Join-Path $tmp 'no-such-config.json')
    $bad = Join-Path $tmp 'bad.json'; '{ not json' | Set-Content -LiteralPath $bad
    ($default.RecentDays -eq 30) -and $default.WindowsOnly -and ((Get-ThrownMessage { Read-DCUSettings -Path $bad }) -like '*could not be read*')
}

# --- audit trail -------------------------------------------------------------------
Check 'an audit log that cannot be written is reported once, not swallowed' {
    $got = & $mod {
        param($work)
        $lines = [System.Collections.Generic.List[object]]::new()
        $savedFile = $script:AuditFile
        try {
            $script:AuditFile = Join-Path $work 'no-such-folder\audit.log'
            $script:AuditFailedFor = $null
            Register-DCULogSink { param($e) $lines.Add($e) }
            Write-DCULog 'first'
            Write-DCULog 'second'
            @($lines)
        }
        finally { $script:AuditFile = $savedFile; Clear-DCUSinks }
    } $tmp
    $audit = @($got | Where-Object Category -eq 'Audit')
    ($audit.Count -eq 1) -and ($audit[0].Level -eq 'Warn') -and (@($got).Count -eq 3)
}

# --- copies that must not drift apart ------------------------------------------------
Check 'every catalogue step declares its effect, scope and wording' {
    $bad = @(& $mod {
        $script:DCUStepCatalog | Where-Object {
            ($_.Effect -notin 'ReadOnly', 'Write', 'Destructive') -or ($_.Scope -notin 'Input', 'Selection', 'WholeList') -or
            -not $_.Summary -or ($_.Scope -ne 'Input' -and -not $_.RunLabel) -or ($_.Effect -eq 'Destructive' -and -not $_.ConfirmAction)
        } | ForEach-Object Key
    })
    $bad.Count -eq 0
}

Check 'the CLI -Step values are exactly the catalogue steps' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Invoke-DeviceCleanup.ps1'), [ref]$null, [ref]$null)
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Step' }
    $set = $param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
    $cli = (@($set.PositionalArguments.Value) | Sort-Object) -join ','
    $catalogue = (@((Get-DCUStepList).Key) | Sort-Object) -join ','
    $cli -eq $catalogue
}

Check 'the wizard grid row type carries every device field' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'gui\Wizard.ps1'), [ref]$null, [ref]$null)
    $cs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                   $n.Value -like '*public class DcuDevice*' }, $true) | Select-Object -First 1
    if (-not ('DcuDriftCheck.DcuDevice' -as [type])) { Add-Type -Language CSharp -TypeDefinition "namespace DcuDriftCheck { $($cs.Value) }" }
    @(Get-DCUDeviceFields | Where-Object { -not [DcuDriftCheck.DcuDevice].GetProperty($_) }).Count -eq 0
}

Check 'the manifest and the module export the same functions' {
    $manifest = @((Import-PowerShellDataFile (Join-Path $PSScriptRoot '..\DCU.psd1')).FunctionsToExport | Sort-Object)
    $exported = @((Get-Command -Module DCU).Name | Sort-Object)
    ($manifest -join ',') -eq ($exported -join ',')
}
