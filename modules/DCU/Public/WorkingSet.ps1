<#
    The working set: the device list plus where it has got to.

    A batch is rarely finished in one sitting - the wipe has to reach the
    devices, Autopilot takes a few minutes to catch up, and the final check
    happens the next morning. Saving the list means picking it up again without
    re-importing the spreadsheet and re-doing the lookup.
#>

function Save-DCUWorkingSet {
    <#
        .SYNOPSIS
            Write the device list to a JSON file that Import-DCUWorkingSet reads back.
        .PARAMETER Path
            Empty = <WorkFolder>\workingset.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Devices,
        [string]$Path,
        [pscustomobject]$Session
    )
    if ($Session) { Initialize-DCUContext -Session $Session }
    if (-not $Path) {
        if (-not $script:WorkFolder) { throw 'No path given and no working folder on the session.' }
        $Path = Join-Path $script:WorkFolder 'workingset.json'
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $payload = [pscustomobject]@{
        Saved      = (Get-Date).ToString('s')
        Tenant     = $script:TenantDomainCache
        DryRun     = $script:DryRun
        RecentDays = $script:RecentDays
        Devices    = @($Devices | ConvertTo-DCUDeviceRecord)
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-DCULog -Category 'WorkingSet' -Message "Working set saved ($(@($payload.Devices).Count) device(s)): $Path"
    $Path
}

function Import-DCUWorkingSet {
    <#
        .SYNOPSIS
            Read a working set back in.
        .DESCRIPTION
            Also accepts a plain device JSON export (an array of records) or a
            devices-*.csv, so a list that was exported for a colleague can be
            picked straight back up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }

    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.csv') {
        $rows = @(Import-DCUSpreadsheet -Path $Path)
        $devices = foreach ($r in $rows) {
            New-DCUDeviceRecord -Serial ([string]$r['SerialNumber']) -Name ([string]$r['DeviceName']) -Note ([string]$r['Note']) -Source 'csv'
        }
        Write-DCULog -Category 'WorkingSet' -Message "Read $(@($devices).Count) device(s) from $Path (identifiers only - run the lookup again)."
        return @($devices)
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    $parsed = $raw | ConvertFrom-Json
    $list = if ($parsed.PSObject.Properties.Name -contains 'Devices') { @($parsed.Devices) } else { @($parsed) }
    $devices = @($list | ConvertTo-DCUDeviceRecord)
    Write-DCULog -Category 'WorkingSet' -Message "Working set loaded ($($devices.Count) device(s)): $Path"
    @($devices)
}
