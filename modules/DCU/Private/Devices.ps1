<#
    The device record and the matching logic.

    One record per line the administrator supplied. Every step reads and writes
    the same shape, the GUI binds a grid to it and it round-trips through JSON
    (the working set) and across runspace boundaries, so it stays a flat
    PSCustomObject of simple types - no nested objects, no [datetime] where a
    string will do.

    Resolve-DCUDeviceMatches is deliberately pure: it takes the three
    inventories as plain arrays and does no Graph calls at all, which is what
    makes the matching testable without a tenant.
#>

$script:DCUDeviceFields = @(
    'Key', 'Raw', 'Name', 'Serial', 'Note', 'Source'
    'Match', 'MatchDetail'
    'IntuneId', 'IntuneName', 'IntuneUser', 'IntuneLastSync', 'IntuneEnrolled', 'IntuneOs'
    'IntuneModel', 'IntuneOwner', 'IntuneCompliance'
    'AzureAdDeviceId', 'EntraObjectId', 'EntraName', 'EntraTrust', 'EntraLastSignIn', 'EntraEnabled'
    'AutopilotId', 'AutopilotGroupTag', 'AutopilotEnrollment', 'AutopilotUser'
    'LastActivity', 'DaysSinceActivity'
    'Warn', 'Flag'
    'IntuneState', 'AutopilotState', 'EntraState', 'BitLockerState', 'Result', 'Outcome', 'ExportedAt'
    'Apply'
)

# What the last step did to a row, as a value a program can test - Result is
# the sentence for people. Set both through Set-DCUDeviceResult, never by hand.
$script:DCUOutcomes = @(
    'Done'        # the step did what it set out to do
    'Simulated'   # dry run: it would have
    'Skipped'     # not eligible for this step; Result says why
    'Pending'     # accepted by the tenant, not confirmed yet (Autopilot delete)
    'Failed'      # the call failed; Result carries the error
    'NotReady'    # final check: something is still left to do
)

function Get-DCUDeviceFields {
    <# The field list of a device record, for hosts that keep their own row type (the wizard grid). #>
    @($script:DCUDeviceFields)
}

function Set-DCUDeviceResult {
    <# The one place a row's Outcome and Result are written, so they cannot drift apart. #>
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][ValidateScript({ $_ -in $script:DCUOutcomes })][string]$Outcome,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $Record.Outcome = $Outcome
    $Record.Result  = $Text
}

function Test-DCUSafeDevice {
    <#
        Whether a row may be picked without the administrator looking at it:
        looked up, found, and not flagged. The lookup pre-ticks exactly these,
        the wizard's "tick the safe ones" button ticks exactly these, and the
        CLI acts on exactly these unless told otherwise.
    #>
    param([Parameter(Mandatory)]$Device)
    ($Device.Match -notin 'Not looked up', 'Not found', '') -and -not $Device.Warn
}

function ConvertFrom-DCULegacyResult {
    <#
        Working sets saved before Outcome existed carry only the Result text.
        Read the outcome back out of it once, when the row is loaded, so no
        other code has to parse Result again.
    #>
    param([string]$Result)
    switch -Wildcard ($Result) {
        ''          { return '' }
        'FAILED*'   { return 'Failed' }
        'NOT ready*' { return 'NotReady' }
        'DRY RUN*'  { return 'Simulated' }
        'Skipped*'  { return 'Skipped' }
        'PENDING*'  { return 'Pending' }
        default     { return 'Done' }
    }
}

function New-DCUDeviceRecord {
    <# An empty record with every field present, so nothing is $null-by-absence. #>
    param(
        [string]$Raw, [string]$Name, [string]$Serial, [string]$Note, [string]$Source = 'manual'
    )
    $r = [ordered]@{}
    foreach ($f in $script:DCUDeviceFields) { $r[$f] = '' }
    $r.Raw    = $Raw
    $r.Name   = $Name
    $r.Serial = $Serial
    $r.Note   = $Note
    $r.Source = $Source
    $r.Match  = 'Not looked up'
    $r.DaysSinceActivity = -1
    $r.Warn   = $false
    $r.Apply  = $false
    $r.Key    = Get-DCUDeviceKey -Serial $Serial -Name $Name -Raw $Raw
    [pscustomobject]$r
}

function ConvertTo-DCUDeviceRecord {
    <#
        Normalise whatever the host handed over (hashtables from a runspace
        boundary, PSCustomObjects from JSON, or records this module made) into
        the canonical record. Unknown fields are dropped, missing ones filled.
    #>
    param([Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -eq $InputObject) { return }
        $get = {
            param($n)
            if ($InputObject -is [hashtable] -or $InputObject -is [System.Collections.IDictionary]) {
                if ($InputObject.Contains($n)) { return $InputObject[$n] }
                return $null
            }
            $p = $InputObject.PSObject.Properties[$n]
            if ($p) { return $p.Value }
            $null
        }
        $r = [ordered]@{}
        foreach ($f in $script:DCUDeviceFields) {
            $v = & $get $f
            $r[$f] = switch ($f) {
                'Warn'              { [bool]$v }
                'Apply'             { [bool]$v }
                'DaysSinceActivity' { if ($null -eq $v -or "$v" -eq '') { -1 } else { [int]$v } }
                default             { if ($null -eq $v) { '' } else { [string]$v } }
            }
        }
        if (-not $r.Key) { $r.Key = Get-DCUDeviceKey -Serial $r.Serial -Name $r.Name -Raw $r.Raw }
        if (-not $r.Match) { $r.Match = 'Not looked up' }
        if ($r.Result -and -not $r.Outcome) {
            $r.Outcome = ConvertFrom-DCULegacyResult $r.Result
            if ($r.Result -like 'Exported*' -and -not $r.ExportedAt) { $r.ExportedAt = 'before this version' }
        }
        [pscustomobject]$r
    }
}

function Get-DCUNormalSerial {
    <# Serials arrive with stray spaces, dashes and mixed case. #>
    param([string]$Value)
    if (-not $Value) { return '' }
    ($Value -replace '[\s]', '').Trim().ToUpperInvariant()
}

function Get-DCUNormalName {
    param([string]$Value)
    if (-not $Value) { return '' }
    $Value.Trim().ToUpperInvariant()
}

function Get-DCUDeviceKey {
    <#
        A stable id for one input line, used everywhere a selection is passed
        around. Serial wins because that is what Autopilot works with.
    #>
    param([string]$Serial, [string]$Name, [string]$Raw)
    $s = Get-DCUNormalSerial $Serial
    if ($s) { return "S:$s" }
    $n = Get-DCUNormalName $Name
    if ($n) { return "N:$n" }
    $r = Get-DCUNormalName $Raw
    if ($r) { return "R:$r" }
    "X:$([guid]::NewGuid().ToString('N').Substring(0,8))"
}

function Get-DCUZtdId {
    <#
        Entra device objects carry the Autopilot id as "[ZTDID]:<guid>" in
        physicalIds - the only reliable link between an Entra object and its
        Autopilot registration.
    #>
    param($PhysicalIds)
    foreach ($p in @($PhysicalIds)) {
        $m = [regex]::Match([string]$p, '\[ZTDID\]:(?<id>[0-9a-fA-F-]{36})')
        if ($m.Success) { return $m.Groups['id'].Value }
    }
    ''
}

function Resolve-DCUDeviceMatches {
    <#
        .SYNOPSIS
            Match every input record against the three inventories. Pure - no
            Graph calls, so it is unit-testable.
        .PARAMETER RecentDays
            A device whose last check-in / sign-in is newer than this many days
            is flagged as still in use.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Devices,
        [object[]]$Intune = @(),
        [object[]]$Autopilot = @(),
        [object[]]$Entra = @(),
        [int]$RecentDays = 30
    )

    # --- indexes ------------------------------------------------------------
    $intBySerial = @{}; $intByName = @{}; $intById = @{}
    foreach ($d in $Intune) {
        $s = Get-DCUNormalSerial ([string]$d.serialNumber)
        if ($s) { if (-not $intBySerial.ContainsKey($s)) { $intBySerial[$s] = @() }; $intBySerial[$s] += $d }
        $n = Get-DCUNormalName ([string]$d.deviceName)
        if ($n) { if (-not $intByName.ContainsKey($n)) { $intByName[$n] = @() }; $intByName[$n] += $d }
        if ($d.id) { $intById[[string]$d.id] = $d }
    }

    $apBySerial = @{}; $apByName = @{}; $apById = @{}
    foreach ($d in $Autopilot) {
        $s = Get-DCUNormalSerial ([string]$d.serialNumber)
        if ($s) { if (-not $apBySerial.ContainsKey($s)) { $apBySerial[$s] = @() }; $apBySerial[$s] += $d }
        $n = Get-DCUNormalName ([string]$d.displayName)
        if ($n) { if (-not $apByName.ContainsKey($n)) { $apByName[$n] = @() }; $apByName[$n] += $d }
        if ($d.id) { $apById[[string]$d.id] = $d }
    }

    $enByDeviceId = @{}; $enByName = @{}; $enByZtd = @{}
    foreach ($d in $Entra) {
        if ($d.deviceId) { $enByDeviceId[([string]$d.deviceId).ToLowerInvariant()] = $d }
        $n = Get-DCUNormalName ([string]$d.displayName)
        if ($n) { if (-not $enByName.ContainsKey($n)) { $enByName[$n] = @() }; $enByName[$n] += $d }
        $z = Get-DCUZtdId $d.physicalIds
        if ($z) { $enByZtd[$z.ToLowerInvariant()] = $d }
    }

    $now = Get-Date
    $out = foreach ($dev in $Devices) {
        $r = $dev | ConvertTo-DCUDeviceRecord

        # Every value the row carries is tried against BOTH the serial index and
        # the device-name index, serial first. A single-column paste has no idea
        # which it is, and a two-column file can have them the wrong way round -
        # this way neither has to be guessed correctly.
        $tokens = @(@($r.Serial, $r.Name, $r.Raw) | Where-Object { $_ })
        $serialCandidates = @($tokens | ForEach-Object { Get-DCUNormalSerial $_ } | Where-Object { $_ } | Select-Object -Unique)
        $nameCandidates   = @($tokens | ForEach-Object { Get-DCUNormalName $_ }   | Where-Object { $_ } | Select-Object -Unique)

        # --- Intune ---------------------------------------------------------
        $intHits = @()
        foreach ($s in $serialCandidates) { if ($intBySerial.ContainsKey($s)) { $intHits += $intBySerial[$s] } }
        if (-not $intHits.Count) {
            foreach ($n in $nameCandidates) { if ($intByName.ContainsKey($n)) { $intHits += $intByName[$n] } }
        }
        $intHits = @($intHits | Sort-Object -Property id -Unique)

        if ($intHits.Count) {
            $primary = @($intHits | Sort-Object { ConvertTo-DCUDate $_.lastSyncDateTime } -Descending)[0]
            $r.IntuneId         = ($intHits | ForEach-Object { [string]$_.id }) -join ';'
            $r.IntuneName       = [string]$primary.deviceName
            $r.IntuneUser       = [string]$primary.userPrincipalName
            $r.IntuneOs         = (@([string]$primary.operatingSystem, [string]$primary.osVersion) | Where-Object { $_ }) -join ' '
            $r.IntuneModel      = (@([string]$primary.manufacturer, [string]$primary.model) | Where-Object { $_ }) -join ' '
            $r.IntuneOwner      = [string]$primary.managedDeviceOwnerType
            $r.IntuneCompliance = [string]$primary.complianceState
            $sync = ConvertTo-DCUDate $primary.lastSyncDateTime
            $r.IntuneLastSync   = if ($sync) { $sync.ToString('yyyy-MM-dd HH:mm') } else { '' }
            $enr = ConvertTo-DCUDate $primary.enrolledDateTime
            $r.IntuneEnrolled   = if ($enr) { $enr.ToString('yyyy-MM-dd') } else { '' }
            if (-not $r.Serial) { $r.Serial = [string]$primary.serialNumber }
            if (-not $r.Name)   { $r.Name   = [string]$primary.deviceName }
            if ($primary.azureADDeviceId) { $r.AzureAdDeviceId = [string]$primary.azureADDeviceId }
            $r.IntuneState = if ($intHits.Count -gt 1) { "Present ($($intHits.Count) records)" } else { 'Present' }
        }
        else { $r.IntuneState = 'Not in Intune' }

        # --- Autopilot ------------------------------------------------------
        # the Intune hit may have filled in a serial the input did not have
        $serialCandidates = @(@($serialCandidates) + (Get-DCUNormalSerial $r.Serial) | Where-Object { $_ } | Select-Object -Unique)
        $apHits = @()
        foreach ($s in $serialCandidates) { if ($apBySerial.ContainsKey($s)) { $apHits += $apBySerial[$s] } }
        if (-not $apHits.Count) {
            foreach ($n in $nameCandidates) { if ($apByName.ContainsKey($n)) { $apHits += $apByName[$n] } }
        }
        $apHits = @($apHits | Sort-Object -Property id -Unique)

        if ($apHits.Count) {
            $ap = $apHits[0]
            $r.AutopilotId         = ($apHits | ForEach-Object { [string]$_.id }) -join ';'
            $r.AutopilotGroupTag   = [string]$ap.groupTag
            $r.AutopilotEnrollment = [string]$ap.enrollmentState
            $r.AutopilotUser       = (@([string]$ap.userPrincipalName, [string]$ap.addressableUserName) | Where-Object { $_ } | Select-Object -First 1)
            if (-not $r.Serial) { $r.Serial = [string]$ap.serialNumber }
            if (-not $r.AzureAdDeviceId -and $ap.azureActiveDirectoryDeviceId) {
                $r.AzureAdDeviceId = [string]$ap.azureActiveDirectoryDeviceId
            }
            $r.AutopilotState = if ($apHits.Count -gt 1) { "Registered ($($apHits.Count) records)" } else { 'Registered' }
        }
        else { $r.AutopilotState = 'Not in Autopilot' }

        # --- Entra ID -------------------------------------------------------
        $en = $null
        if ($r.AzureAdDeviceId) {
            $key = ([string]$r.AzureAdDeviceId).ToLowerInvariant()
            if ($enByDeviceId.ContainsKey($key)) { $en = $enByDeviceId[$key] }
        }
        if (-not $en -and $r.AutopilotId) {
            foreach ($apid in ($r.AutopilotId -split ';')) {
                $k = $apid.ToLowerInvariant()
                if ($enByZtd.ContainsKey($k)) { $en = $enByZtd[$k]; break }
            }
        }
        if (-not $en) {
            $names = @(Get-DCUNormalName $r.IntuneName) + $nameCandidates | Where-Object { $_ } | Select-Object -Unique
            foreach ($n in $names) {
                if ($enByName.ContainsKey($n) -and @($enByName[$n]).Count -eq 1) { $en = @($enByName[$n])[0]; break }
            }
        }

        if ($en) {
            $r.EntraObjectId = [string]$en.id
            $r.EntraName     = [string]$en.displayName
            $r.EntraTrust    = [string]$en.trustType
            $r.EntraEnabled  = if ($null -ne $en.accountEnabled) { [string][bool]$en.accountEnabled } else { '' }
            $signIn = ConvertTo-DCUDate $en.approximateLastSignInDateTime
            $r.EntraLastSignIn = if ($signIn) { $signIn.ToString('yyyy-MM-dd HH:mm') } else { '' }
            if (-not $r.AzureAdDeviceId) { $r.AzureAdDeviceId = [string]$en.deviceId }
            $r.EntraState = 'Present'
        }
        else { $r.EntraState = 'Not in Entra ID' }

        # --- match verdict --------------------------------------------------
        $found = @(@($intHits.Count, $apHits.Count, $(if ($en) { 1 } else { 0 })) | Where-Object { $_ -gt 0 })
        if (-not $found.Count) {
            $r.Match = 'Not found'
            $r.MatchDetail = 'No Intune, Autopilot or Entra ID object matched this serial number or device name.'
        }
        elseif ($intHits.Count -gt 1 -or $apHits.Count -gt 1) {
            $r.Match = 'Multiple'
            $r.MatchDetail = 'More than one record matched - check before acting; all matched records will be removed.'
        }
        else {
            $r.Match = 'Matched'
            $r.MatchDetail = ''
        }

        # --- activity + flags -----------------------------------------------
        $dates = @()
        foreach ($d in @($r.IntuneLastSync, $r.EntraLastSignIn)) {
            $p = ConvertTo-DCUDate $d
            if ($p) { $dates += $p }
        }
        if ($dates.Count) {
            $last = ($dates | Sort-Object -Descending)[0]
            $r.LastActivity      = $last.ToString('yyyy-MM-dd HH:mm')
            $r.DaysSinceActivity = [int][math]::Floor(($now - $last).TotalDays)
        }
        else {
            $r.LastActivity = ''
            $r.DaysSinceActivity = -1
        }

        Set-DCUDeviceFlag -Record $r -RecentDays $RecentDays
        $r
    }

    @($out)
}

function Set-DCUDeviceFlag {
    <#
        Fills .Warn / .Flag. The recent-activity warning is the important one:
        a laptop that phoned home yesterday is almost certainly still in use by
        somebody, and deleting it from Intune silently unmanages a live device.

        Mutates the record in place and returns NOTHING - it is called from
        inside a foreach that emits the record itself, and an extra copy down
        the pipeline would duplicate every row.
    #>
    param(
        [Parameter(Mandatory)]$Record,
        [int]$RecentDays = 30
    )
    $flags = @()
    $warn = $false

    if ($Record.DaysSinceActivity -ge 0 -and $RecentDays -gt 0 -and $Record.DaysSinceActivity -lt $RecentDays) {
        $ago = if ($Record.DaysSinceActivity -eq 0) { 'today' } else { "$($Record.DaysSinceActivity) d ago" }
        $flags += "STILL IN USE - last seen $ago"
        $warn = $true
    }
    if ($Record.Match -eq 'Not found') {
        $flags += 'Not found in this tenant'
        $warn = $true
    }
    if ($Record.Match -eq 'Multiple') {
        $flags += 'Multiple records matched'
        $warn = $true
    }
    if ($Record.EntraTrust -eq 'ServerAd') {
        $flags += 'Hybrid joined - also delete the on-prem AD computer object'
        $warn = $true
    }
    if ($Record.IntuneUser) {
        # not a warning on its own, but worth seeing next to the row
        $flags += "user $($Record.IntuneUser)"
    }

    $Record.Warn = $warn
    $Record.Flag = ($flags -join ' | ')
}

function Select-DCUDevices {
    <#
        The rows an action should touch: everything when -Selection is empty,
        otherwise only those keys. Unknown keys are reported, never silently
        skipped - a typo in a CLI -Selection should not look like success.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection
    )
    if (-not $Selection -or $Selection.Count -eq 0) { return @($Devices) }
    $want = @{}
    foreach ($s in $Selection) { $want[$s] = $true }
    $have = @{}
    foreach ($d in $Devices) { $have[[string]$d.Key] = $true }
    $hit = @($Devices | Where-Object { $want.ContainsKey([string]$_.Key) })
    $missing = @($Selection | Where-Object { -not $have.ContainsKey([string]$_) })
    if ($missing.Count) {
        Write-DCULog -Level Warn -Message "These selected keys are not in the device list and were skipped: $($missing -join ', ')"
    }
    $hit
}
