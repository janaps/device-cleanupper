#requires -Version 7.2
<#
    Plain-PowerShell smoke tests for the pure functions in the DCU module.
    No tenant, no Graph, no sign-in needed.

        pwsh -File .\modules\DCU\tests\Run-SmokeTests.ps1
#>
$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module (Join-Path $PSScriptRoot '..' 'DCU.psd1') -Force

$fails = 0
function Check($name, [scriptblock]$test) {
    try {
        $r = & $test
        if ($r) { Write-Host "  PASS  $name" -ForegroundColor Green }
        else { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:fails++ }
    }
    catch {
        Write-Host "  FAIL  $name  ($($_.Exception.Message))" -ForegroundColor Red
        $script:fails++
    }
}

Write-Host 'DCU smoke tests' -ForegroundColor Cyan

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('dcu_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# The record + matching helpers are module-internal on purpose (a host never
# needs to build a device record by hand), so the tests reach into the module
# scope for them instead of the module exporting more than it should.
$mod = Get-Module DCU
function NewRec {
    param([string]$Serial, [string]$Name, [string]$Raw, [string]$Note)
    & $mod { param($s, $n, $r, $o) New-DCUDeviceRecord -Serial $s -Name $n -Raw $r -Note $o } $Serial $Name $Raw $Note
}
function MatchRec {
    <# match against the fixture inventories below, or against ones passed in #>
    param([object[]]$Devices, [int]$RecentDays = 30, $Intune, $Autopilot, $Entra)
    if ($null -eq $Intune)    { $Intune = $script:intune }
    if ($null -eq $Autopilot) { $Autopilot = $script:autopilot }
    if ($null -eq $Entra)     { $Entra = $script:entra }
    & $mod {
        param($d, $rd, $i, $a, $e) Resolve-DCUDeviceMatches -Devices $d -Intune $i -Autopilot $a -Entra $e -RecentDays $rd
    } $Devices $RecentDays @($Intune) @($Autopilot) @($Entra)
}
function FakeStep {
    <#
        Run one step for real (not a dry run) inside the module, with Graph and
        the sign-in check replaced. Every call is recorded as "METHOD uri"; a
        GET for an id in -Gone answers like a 404 (the helper returns $null),
        every other call succeeds.

        -ViaInvokeStep goes through Invoke-DCUStep (the plan, the confirmation
        check and the working-set save) instead of calling the step directly;
        -Selection, -ConfirmationKey and -DryRun are passed on to it.
    #>
    param([string]$Step, [object[]]$Rows, [hashtable]$StepOptions = @{}, [string[]]$Gone = @(),
          [switch]$ViaInvokeStep, [string[]]$Selection = @(), [string]$ConfirmationKey, [bool]$DryRun = $false)
    & $mod {
        param($step, $rows, $work, $opts, $gone, $via, $sel, $key, $dry)
        $saved = @{ Graph = ${function:Invoke-DCUGraph}; Auth = ${function:Assert-DCUSignedIn} }
        $script:fakeCalls = [System.Collections.Generic.List[string]]::new()
        $script:fakeGone  = @($gone)
        try {
            ${function:script:Invoke-DCUGraph} = {
                param([string]$Uri, [string]$Method = 'GET', $Body, [int[]]$Tolerate = @(), [string]$Context)
                $script:fakeCalls.Add("$Method $Uri")
                if ($Method -eq 'GET' -and @($script:fakeGone | Where-Object { $Uri -like "*/$_" }).Count) { return $null }
                [pscustomobject]@{ id = 'fake' }
            }
            ${function:script:Assert-DCUSignedIn} = { [pscustomobject]@{ SignedIn = $true } }
            $session = New-DCUSession -WorkFolder $work -DryRun:$dry -StepOptions $opts
            $res = if ($via) { Invoke-DCUStep -Step $step -Session $session -Devices $rows -Selection $sel -ConfirmationKey $key }
                   else { & "Invoke-DCU$step" -Session $session -Devices $rows }
            [pscustomobject]@{ Res = $res; Calls = @($script:fakeCalls) }
        }
        finally {
            ${function:script:Invoke-DCUGraph}    = $saved.Graph
            ${function:script:Assert-DCUSignedIn} = $saved.Auth
        }
    } $Step $Rows $tmp $StepOptions $Gone ([bool]$ViaInvokeStep) $Selection $ConfirmationKey $DryRun
}

function Get-ThrownMessage {
    <# run a block, return the error message it threw ('' when it did not) #>
    param([scriptblock]$Block)
    try { & $Block | Out-Null; '' } catch { $_.Exception.Message }
}

# --- fixture inventories ----------------------------------------------------
$now = Get-Date
$intune = @(
    [pscustomobject]@{ id = 'i-1'; deviceName = 'LT-0001'; serialNumber = '5CD1111AAA'; azureADDeviceId = 'aad-1'
        userPrincipalName = 'adele@contoso.com'; operatingSystem = 'Windows'; osVersion = '10.0.22631'
        lastSyncDateTime = $now.AddDays(-200).ToString('o'); enrolledDateTime = $now.AddDays(-900).ToString('o')
        complianceState = 'compliant'; manufacturer = 'HP'; model = 'ProBook'; managedDeviceOwnerType = 'company' }
    [pscustomobject]@{ id = 'i-2'; deviceName = 'LT-0002'; serialNumber = '5CD2222BBB'; azureADDeviceId = 'aad-2'
        userPrincipalName = 'megan@contoso.com'; operatingSystem = 'Windows'; osVersion = '10.0.22631'
        lastSyncDateTime = $now.AddDays(-2).ToString('o'); enrolledDateTime = $now.AddDays(-400).ToString('o')
        complianceState = 'compliant'; manufacturer = 'HP'; model = 'ProBook'; managedDeviceOwnerType = 'company' }
    [pscustomobject]@{ id = 'i-3a'; deviceName = 'LT-0003'; serialNumber = '5CD3333CCC'; azureADDeviceId = 'aad-3'
        operatingSystem = 'Windows'; lastSyncDateTime = $now.AddDays(-300).ToString('o') }
    [pscustomobject]@{ id = 'i-3b'; deviceName = 'LT-0003'; serialNumber = '5CD3333CCC'; azureADDeviceId = 'aad-3'
        operatingSystem = 'Windows'; lastSyncDateTime = $now.AddDays(-500).ToString('o') }
)
$autopilot = @(
    [pscustomobject]@{ id = 'ap-1'; serialNumber = '5CD1111AAA'; displayName = 'LT-0001'; groupTag = 'school-a'
        enrollmentState = 'enrolled'; userPrincipalName = 'adele@contoso.com'; azureActiveDirectoryDeviceId = 'aad-1' }
    [pscustomobject]@{ id = 'ap-4'; serialNumber = '5CD4444DDD'; displayName = ''; groupTag = 'school-a'
        enrollmentState = 'notContacted' }
)
$entra = @(
    [pscustomobject]@{ id = 'e-1'; deviceId = 'aad-1'; displayName = 'LT-0001'; trustType = 'AzureAd'
        operatingSystem = 'Windows'; accountEnabled = $true; physicalIds = @('[ZTDID]:11111111-1111-1111-1111-111111111111')
        approximateLastSignInDateTime = $now.AddDays(-210).ToString('o') }
    [pscustomobject]@{ id = 'e-2'; deviceId = 'aad-2'; displayName = 'LT-0002'; trustType = 'AzureAd'
        operatingSystem = 'Windows'; accountEnabled = $true
        approximateLastSignInDateTime = $now.AddDays(-1).ToString('o') }
    [pscustomobject]@{ id = 'e-5'; deviceId = 'aad-5'; displayName = 'PC-HYBRID'; trustType = 'ServerAd'
        operatingSystem = 'Windows'; accountEnabled = $true
        approximateLastSignInDateTime = $now.AddDays(-400).ToString('o') }
)

try {
    Check 'module exports the step functions' {
        $names = (Get-Command -Module DCU).Name
        ($names -contains 'Invoke-DCULookup') -and ($names -contains 'Invoke-DCUIntuneDelete') -and
        ($names -contains 'Invoke-DCUAutopilotDelete') -and ($names -contains 'Invoke-DCUAutopilotSync') -and ($names -contains 'Invoke-DCUEntraDelete') -and
        ($names -contains 'Import-DCUDeviceList')
    }

    Check 'step catalogue has the 9 steps in handover order' {
        $keys = (Get-DCUStepList).Key
        ($keys.Count -eq 9) -and
        ($keys[0] -eq 'DeviceInput') -and
        ([array]::IndexOf($keys, 'IntuneDelete') -lt [array]::IndexOf($keys, 'AutopilotDelete')) -and
        ([array]::IndexOf($keys, 'AutopilotDelete') -lt [array]::IndexOf($keys, 'AutopilotSync')) -and
        ([array]::IndexOf($keys, 'AutopilotSync') -lt [array]::IndexOf($keys, 'EntraDelete'))
    }

    Check 'a new session is a DRY RUN by default' {
        $s = New-DCUSession -WorkFolder $tmp
        $s.DryRun -eq $true -and $s.RecentDays -eq 30
    }

    Check 'dry run has to be turned off explicitly' {
        $s = New-DCUSession -WorkFolder $tmp -DryRun:$false
        $s.DryRun -eq $false
    }

    Check 'the recent-activity threshold is configurable' {
        (New-DCUSession -WorkFolder $tmp -RecentDays 7).RecentDays -eq 7
    }

    # --- input parsing ------------------------------------------------------
    Check 'pasted text: one serial per line' {
        # a single column says nothing about what it is, so the value lands in
        # Raw and the key is the unclassified R: form
        $r = @(ConvertFrom-DCUPastedText -Text "5CD1111AAA`n5CD2222BBB`n`n5CD3333CCC")
        ($r.Count -eq 3) -and ($r[0].Raw -eq '5CD1111AAA') -and ($r[0].Key -eq 'R:5CD1111AAA')
    }

    Check 'pasted text: header line is recognised, columns mapped' {
        $r = @(ConvertFrom-DCUPastedText -Text "Serienummer;Apparaatnaam`n5CD1111AAA;LT-0001`n5CD2222BBB;LT-0002")
        ($r.Count -eq 2) -and ($r[0].Serial -eq '5CD1111AAA') -and ($r[0].Name -eq 'LT-0001')
    }

    Check 'pasted text: tab separated Excel copy without a header' {
        $r = @(ConvertFrom-DCUPastedText -Text "5CD1111AAA`tLT-0001`n5CD2222BBB`tLT-0002")
        ($r.Count -eq 2) -and ($r[0].Serial -eq '5CD1111AAA') -and ($r[0].Name -eq 'LT-0001')
    }

    Check 'pasted text: name-first order is detected and swapped' {
        $r = @(ConvertFrom-DCUPastedText -Text "LT-0001`t5CD1111AAA")
        ($r[0].Serial -eq '5CD1111AAA') -and ($r[0].Name -eq 'LT-0001')
    }

    Check 'CSV import maps Dutch headers and skips duplicates' {
        $csv = Join-Path $tmp 'devices.csv'
        "Serienummer;Apparaatnaam;Opmerking`n5CD1111AAA;LT-0001;school A`n5CD2222BBB;LT-0002;school A`n5CD1111AAA;LT-0001;dubbel" |
            Set-Content -LiteralPath $csv -Encoding UTF8
        $r = Import-DCUDeviceList -Path $csv
        ($r.Total -eq 2) -and ($r.Duplicates -eq 1) -and (@($r.Rows)[0].Note -eq 'school A')
    }

    Check 'CSV import accepts comma separated English headers' {
        $csv = Join-Path $tmp 'devices2.csv'
        "Device Name,Serial Number`nLT-0009,5CD9999ZZZ" | Set-Content -LiteralPath $csv -Encoding UTF8
        $r = Import-DCUDeviceList -Path $csv
        (@($r.Rows)[0].Serial -eq '5CD9999ZZZ') -and (@($r.Rows)[0].Name -eq 'LT-0009')
    }

    Check 'a single unnamed column becomes an unclassified identifier' {
        $csv = Join-Path $tmp 'devices3.csv'
        "Kolom1`n5CD1111AAA`nLT-0002" | Set-Content -LiteralPath $csv -Encoding UTF8
        $r = Import-DCUDeviceList -Path $csv
        ($r.Total -eq 2) -and ($r.Unclassified -eq 2) -and (@($r.Rows)[1].Raw -eq 'LT-0002')
    }

    Check 'typed grid rows import' {
        $r = Import-DCUDeviceList -Rows @(
            [pscustomobject]@{ Serial = '5CD1111AAA'; Name = 'LT-0001'; Note = '' }
            [pscustomobject]@{ Serial = ''; Name = ''; Note = 'leeg' }
        )
        $r.Total -eq 1
    }

    Check 'an existing list is extended, not replaced' {
        $first = Import-DCUDeviceList -Rows @([pscustomobject]@{ Serial = '5CD1111AAA' })
        $second = Import-DCUDeviceList -Rows @([pscustomobject]@{ Serial = '5CD2222BBB' }) -Existing $first.Rows
        $second.Total -eq 2
    }

    Check 'a device pasted as a bare serial is not added twice' {
        # the spreadsheet row has an S: key, the pasted line an R: key - dedupe
        # has to compare the values, or the laptop gets deleted twice
        $first = Import-DCUDeviceList -Rows @([pscustomobject]@{ Serial = '5CD1111AAA'; Name = 'LT-0001' })
        $second = Import-DCUDeviceList -Text "5CD1111AAA`nLT-0001`n5CD9999ZZZ" -Existing $first.Rows
        ($second.Total -eq 2) -and ($second.Duplicates -eq 2)
    }

    Check 'a null Existing (an if-expression that yielded nothing) is tolerated' {
        (Import-DCUDeviceList -Rows @([pscustomobject]@{ Serial = 'X1' }) -Existing $null).Total -eq 1
    }

    # --- matching -----------------------------------------------------------
    Check 'matching resolves Intune, Autopilot and Entra ids from a serial' {
        $d = @(NewRec -Serial '5CD1111AAA')
        $r = @(MatchRec -Devices $d -RecentDays 30)
        ($r[0].IntuneId -eq 'i-1') -and ($r[0].AutopilotId -eq 'ap-1') -and ($r[0].EntraObjectId -eq 'e-1') -and
        ($r[0].Match -eq 'Matched') -and ($r[0].Name -eq 'LT-0001')
    }

    Check 'matching falls back to the device name' {
        $d = @(NewRec -Name 'LT-0002')
        $r = @(MatchRec -Devices $d)
        ($r[0].IntuneId -eq 'i-2') -and ($r[0].Serial -eq '5CD2222BBB') -and ($r[0].EntraObjectId -eq 'e-2')
    }

    Check 'an unclassified value is tried as a serial and as a name' {
        $bySerial = @(MatchRec -Devices @(NewRec -Raw '5CD1111AAA'))
        $byName   = @(MatchRec -Devices @(NewRec -Raw 'LT-0002')   )
        ($bySerial[0].IntuneId -eq 'i-1') -and ($byName[0].IntuneId -eq 'i-2')
    }

    Check 'a device seen 2 days ago is flagged as still in use and not pre-ticked' {
        $r = @(MatchRec -Devices @(NewRec -Serial '5CD2222BBB') -RecentDays 30)
        $r[0].Warn -and ($r[0].Flag -like '*STILL IN USE*') -and ($r[0].DaysSinceActivity -le 2)
    }

    Check 'the same device is NOT flagged with a 1-day threshold' {
        $r = @(MatchRec -Devices @(NewRec -Serial '5CD2222BBB') -RecentDays 1)
        -not $r[0].Warn
    }

    Check 'RecentDays 0 turns the activity warning off' {
        $r = @(MatchRec -Devices @(NewRec -Serial '5CD2222BBB') -RecentDays 0)
        -not $r[0].Warn
    }

    Check 'two Intune records for one serial are both kept and flagged' {
        $r = @(MatchRec -Devices @(NewRec -Serial '5CD3333CCC'))
        ($r[0].Match -eq 'Multiple') -and (@($r[0].IntuneId -split ';').Count -eq 2) -and $r[0].Warn
    }

    Check 'a serial that is only in Autopilot still resolves' {
        $r = @(MatchRec -Devices @(NewRec -Serial '5CD4444DDD'))
        ($r[0].AutopilotId -eq 'ap-4') -and ($r[0].IntuneState -eq 'Not in Intune') -and ($r[0].Match -eq 'Matched')
    }

    Check 'an unknown device is reported as not found and flagged' {
        $r = @(MatchRec -Devices @(NewRec -Serial 'NOPE12345'))
        ($r[0].Match -eq 'Not found') -and $r[0].Warn
    }

    Check 'a hybrid joined device is flagged for the on-prem AD' {
        $r = @(MatchRec -Devices @(NewRec -Name 'PC-HYBRID'))
        ($r[0].EntraTrust -eq 'ServerAd') -and ($r[0].Flag -like '*on-prem*') -and $r[0].Warn
    }

    Check 'the Entra object is found through the Autopilot ZTDID when nothing else matches' {
        $ap = @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; serialNumber = 'ZTD0001'; displayName = 'zzz' })
        $r = @(MatchRec -Devices @(NewRec -Serial 'ZTD0001') -Intune @() -Autopilot $ap)
        $r[0].EntraObjectId -eq 'e-1'
    }

    # --- selection + status -------------------------------------------------
    Check 'Select-DCUDevices returns everything without a selection' {
        $d = @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'; NewRec -Serial '5CD2222BBB'))
        (& (Get-Module DCU) { param($x) @(Select-DCUDevices -Devices $x).Count } $d) -eq 2
    }

    Check 'Select-DCUDevices honours a selection of keys' {
        $d = @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'; NewRec -Serial '5CD2222BBB'))
        $sel = & (Get-Module DCU) { param($x) @(Select-DCUDevices -Devices $x -Selection @('S:5CD2222BBB')) } $d
        (@($sel).Count -eq 1) -and (@($sel)[0].Serial -eq '5CD2222BBB')
    }

    Check 'status: everything after step 1 is blocked without a sign-in' {
        $s = Get-DCUStatus -Devices @() -SignedIn $false
        (($s | Where-Object Key -eq 'DeviceInput').Status -eq 'Ready') -and
        (($s | Where-Object Key -eq 'Lookup').Status -eq 'Blocked')
    }

    Check 'status: a looked-up list makes the delete steps ready' {
        $d = @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))
        $s = Get-DCUStatus -Devices $d -SignedIn $true
        (($s | Where-Object Key -eq 'Lookup').Status -eq 'Done') -and
        (($s | Where-Object Key -eq 'IntuneDelete').Status -eq 'Ready') -and
        (($s | Where-Object Key -eq 'AutopilotDelete').Status -eq 'Ready')
    }

    # --- options ------------------------------------------------------------
    Check 'step options merge with the catalogue defaults' {
        $o = & (Get-Module DCU) { Resolve-DCUStepOptions -Key 'AutopilotSync' -Override @{ WaitMinutes = 3 } }
        ($o.WaitMinutes -eq 3) -and ((Get-DCUStepList | Where-Object Key -eq 'AutopilotSync').Options.WaitMinutes.Default -eq 10)
    }

    Check 'an explicit $false override is kept, not treated as unset' {
        $o = & (Get-Module DCU) { Resolve-DCUStepOptions -Key 'EntraDelete' -Override @{ OnlyWithoutAutopilot = $false } }
        $o.OnlyWithoutAutopilot -eq $false
    }

    Check 'the Entra step skips Autopilot and hybrid devices by default' {
        $o = (Get-DCUStepList | Where-Object Key -eq 'EntraDelete').Options
        ($o.OnlyWithoutAutopilot.Default -eq $true) -and ($o.SkipHybrid.Default -eq $true)
    }

    Check 'BitLocker key values are not exported unless asked for' {
        $o = (Get-DCUStepList | Where-Object Key -eq 'Backup').Options
        ($o.IncludeBitLocker.Default -eq $false) -and ($o.IncludeKeyValues.Default -eq $false)
    }

    # --- dry run through the real action loop --------------------------------
    Check 'the action loop simulates in dry run and never calls Graph' {
        $d = @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))
        $r = & (Get-Module DCU) {
            param($rows, $work)
            Initialize-DCUContext -Session (New-DCUSession -WorkFolder $work)   # DryRun defaults to $true
            function Invoke-DCUGraph { throw 'Graph must not be called in a dry run' }
            $plan = { param($x) [pscustomobject]@{ Eligible = $true; Reason = ''; What = 'delete something' } }
            $act  = { param($x) Invoke-DCUGraph }
            Invoke-DCUDeviceLoop -Targets $rows -Activity 'test' -Category 'test' -Plan $plan -Act $act
        } $d $tmp
        ($r.Simulated -eq 1) -and ($r.Done -eq 0) -and ($r.Failed -eq 0) -and ($d[0].Result -like 'DRY RUN*')
    }

    Check 'the action loop skips ineligible rows with a reason' {
        $d = @(NewRec -Serial 'X1')
        $r = & (Get-Module DCU) {
            param($rows, $work)
            Initialize-DCUContext -Session (New-DCUSession -WorkFolder $work)
            $plan = { param($x) [pscustomobject]@{ Eligible = $false; Reason = 'not in Intune' } }
            $act  = { param($x) throw 'must not run' }
            Invoke-DCUDeviceLoop -Targets $rows -Activity 'test' -Category 'test' -Plan $plan -Act $act
        } $d $tmp
        ($r.Skipped -eq 1) -and ($d[0].Result -eq 'Skipped - not in Intune')
    }

    Check 'one failing device does not stop the batch' {
        $d = @(NewRec -Serial 'A1'; NewRec -Serial 'B2')
        $r = & (Get-Module DCU) {
            param($rows, $work)
            Initialize-DCUContext -Session (New-DCUSession -WorkFolder $work -DryRun:$false)
            $plan = { param($x) [pscustomobject]@{ Eligible = $true; Reason = ''; What = 'do it' } }
            $act  = { param($x) if ($x.Serial -eq 'A1') { throw 'boom' }; [pscustomobject]@{ Message = 'done' } }
            Invoke-DCUDeviceLoop -Targets $rows -Activity 'test' -Category 'test' -Plan $plan -Act $act
        } $d $tmp
        ($r.Failed -eq 1) -and ($r.Done -eq 1) -and ($d[0].Result -like 'FAILED*') -and ($d[1].Result -eq 'done')
    }

    # regression: the step blocks used .GetNewClosure(), which made the
    # module's private Invoke-DCUGraph "not recognized" - only outside a dry run
    Check 'a real (non dry run) step can reach the private Graph helper' {
        $r = FakeStep 'IntuneDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))
        ($r.Res.Deleted -eq 1) -and ($r.Res.Failed -eq 0) -and ($r.Calls -contains 'DELETE v1.0/deviceManagement/managedDevices/i-1')
    }

    # --- Autopilot: delete, then a separate sync-and-confirm step ------------
    Check 'Autopilot delete sends no sync and keeps the row pending until it is gone' {
        $r = FakeStep 'AutopilotDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))
        $row = @($r.Res.Rows)[0]
        ($r.Calls -contains 'DELETE v1.0/deviceManagement/windowsAutopilotDeviceIdentities/ap-1') -and
        -not ($r.Calls -like '*windowsAutopilotSettings*') -and
        ($row.AutopilotState -eq 'Deletion pending') -and ($row.AutopilotId -eq 'ap-1') -and ($r.Res.StillPending -eq 1)
    }

    Check 'Autopilot delete does not send a second delete for a pending row' {
        $rows = @((FakeStep 'AutopilotDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))).Res.Rows)
        $r = FakeStep 'AutopilotDelete' $rows
        -not ($r.Calls -like 'DELETE*') -and (@($r.Res.Rows)[0].Result -like 'Skipped*step 6*')
    }

    Check 'the sync step sends no sync when the registration is already gone' {
        $rows = @((FakeStep 'AutopilotDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))).Res.Rows)
        $r = FakeStep 'AutopilotSync' $rows -Gone 'ap-1'
        $row = @($r.Res.Rows)[0]
        -not ($r.Calls -like '*windowsAutopilotSettings*') -and ($r.Res.SyncRequested -eq $false) -and
        ($row.AutopilotState -eq 'Deleted') -and (-not $row.AutopilotId) -and ($r.Res.Confirmed -eq 1)
    }

    Check 'the sync step sends no sync when nothing is pending' {
        $r = FakeStep 'AutopilotSync' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))
        -not ($r.Calls -like '*windowsAutopilotSettings*') -and ($r.Res.Pending -eq 0)
    }

    Check 'the sync step looks first, then syncs on beta while a registration is still there' {
        $rows = @((FakeStep 'AutopilotDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))).Res.Rows)
        $r = FakeStep 'AutopilotSync' $rows -StepOptions @{ AutopilotSync = @{ WaitMinutes = 0 } }
        $row  = @($r.Res.Rows)[0]
        $look = [array]::IndexOf($r.Calls, 'GET v1.0/deviceManagement/windowsAutopilotDeviceIdentities/ap-1')
        $sync = [array]::IndexOf($r.Calls, 'POST beta/deviceManagement/windowsAutopilotSettings/sync')
        ($look -ge 0) -and ($sync -gt $look) -and
        ($row.AutopilotState -eq 'Deletion pending') -and ($row.AutopilotId -eq 'ap-1') -and
        ($row.Result -like 'PENDING*') -and ($r.Res.StillPending -eq 1)
    }

    Check 'the Autopilot wait counts down in live progress and stops once the registration is gone' {
        $rows = @((FakeStep 'AutopilotDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))).Res.Rows)
        $r = & $mod {
            param($rows)
            $saved = ${function:Invoke-DCUGraph}
            $script:fakeReads = 0
            $script:fakeTicks = [System.Collections.Generic.List[object]]::new()
            try {
                # still there on the first read, gone on the second
                ${function:script:Invoke-DCUGraph} = {
                    param([string]$Uri, [string]$Method = 'GET')
                    $script:fakeReads++
                    if ($script:fakeReads -ge 2) { return $null }
                    [pscustomobject]@{ id = 'ap-1' }
                }
                Register-DCUProgressSink { param($p) $script:fakeTicks.Add($p) }
                $n = Wait-DCUAutopilotRemoval -Devices $rows -Minutes 1 -PollSeconds 2
                [pscustomobject]@{ Confirmed = $n; Ticks = @($script:fakeTicks) }
            }
            finally {
                ${function:script:Invoke-DCUGraph} = $saved
                Clear-DCUSinks
            }
        } $rows
        $countdown = @($r.Ticks | Where-Object { $_.Live -and $_.Status -like '*next check in*' })
        ($r.Confirmed -eq 1) -and ($countdown.Count -ge 2) -and ($r.Ticks[-1].Completed -and $r.Ticks[-1].Live)
    }

    Check 'the Entra step never deletes a device still in Autopilot, and says which steps come first' {
        $r = FakeStep 'EntraDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA')) `
            -StepOptions @{ EntraDelete = @{ OnlyWithoutAutopilot = $false } }
        -not ($r.Calls -like 'DELETE*') -and (@($r.Res.Rows)[0].Result -like 'Skipped*step 5*step 6*')
    }

    Check 'the Entra step deletes a device whose Autopilot registration was removed outside the tool' {
        $r = FakeStep 'EntraDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA')) -Gone 'ap-1' `
            -StepOptions @{ EntraDelete = @{ OnlyWithoutAutopilot = $false } }
        $row = @($r.Res.Rows)[0]
        ($r.Calls -contains 'DELETE v1.0/devices/e-1') -and ($row.EntraState -eq 'Deleted') -and
        ($row.AutopilotState -eq 'Gone from Autopilot') -and (-not $row.AutopilotId)
    }

    Check 'the Entra step goes ahead once an unconfirmed Autopilot removal turns out to be done' {
        $rows = @((FakeStep 'AutopilotDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))).Res.Rows)
        $r = FakeStep 'EntraDelete' $rows -Gone 'ap-1' -StepOptions @{ EntraDelete = @{ OnlyWithoutAutopilot = $false } }
        $row = @($r.Res.Rows)[0]
        ($r.Calls -contains 'DELETE v1.0/devices/e-1') -and ($row.AutopilotState -eq 'Deleted')
    }

    Check 'status: a sent Autopilot delete finishes step 5 but leaves step 6 to do' {
        $rows = @((FakeStep 'AutopilotDelete' @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))).Res.Rows)
        $s = Get-DCUStatus -Devices $rows -SignedIn $true
        (($s | Where-Object Key -eq 'AutopilotDelete').Status -eq 'Done') -and
        (($s | Where-Object Key -eq 'AutopilotSync').Status -eq 'Ready')
    }

    # --- export + working set -----------------------------------------------
    Check 'the device CSV export holds the ids you cannot look up afterwards' {
        $d = @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))
        $p = Join-Path $tmp 'export.csv'
        Export-DCUDeviceCsv -Devices $d -Path $p | Out-Null
        $row = @(Import-Csv -LiteralPath $p -Delimiter ';')[0]
        ($row.IntuneDeviceId -eq 'i-1') -and ($row.AutopilotId -eq 'ap-1') -and ($row.EntraObjectId -eq 'e-1') -and ($row.SerialNumber -eq '5CD1111AAA')
    }

    Check 'the working set round-trips through JSON' {
        $d = @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'))
        $p = Save-DCUWorkingSet -Devices $d -Path (Join-Path $tmp 'ws.json') -Session (New-DCUSession -WorkFolder $tmp)
        $back = @(Import-DCUWorkingSet -Path $p)
        ($back.Count -eq 1) -and ($back[0].IntuneId -eq 'i-1') -and ($back[0].Key -eq $d[0].Key)
    }

    # --- xlsx reader ---------------------------------------------------------
    Check 'the built-in xlsx reader reads a workbook without Excel' {
        $xlsx = Join-Path $tmp 'devices.xlsx'
        & $PSScriptRoot\New-TestWorkbook.ps1 -Path $xlsx
        $r = Import-DCUDeviceList -Path $xlsx
        ($r.Total -eq 2) -and (@($r.Rows)[0].Serial -eq '5CD1111AAA') -and (@($r.Rows)[1].Name -eq 'LT-0002')
    }

    Check 'the xlsx reader can pick a sheet by name' {
        $xlsx = Join-Path $tmp 'devices.xlsx'
        $rows = @(Import-DCUSpreadsheet -Path $xlsx -Sheet 'Laptops')
        ($rows.Count -eq 2) -and ($rows[0]['Serienummer'] -eq '5CD1111AAA')
    }

    Check 'the xlsx reader reports a sheet name that is not there' {
        try { Import-DCUSpreadsheet -Path (Join-Path $tmp 'devices.xlsx') -Sheet 'Nope' | Out-Null; $false }
        catch { $_.Exception.Message -like '*not found*' }
    }

    # navigation gating, run plans, confirmation, settings, drift between copies
    . (Join-Path $PSScriptRoot 'WorkflowChecks.ps1')
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) { Write-Host "$fails test(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed.' -ForegroundColor Green
