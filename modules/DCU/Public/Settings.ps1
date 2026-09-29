<#
    The administrator's remembered preferences (%APPDATA%\DeviceCleanUpper\
    config.json for the wizard; a web host would keep the same shape).

    Only the keys below are read or written, each normalised to its type and
    range. The dry-run switch is NOT one of them, on purpose: every session
    starts as a dry run, however the last one ended - and a hand-edited or
    old file with a DryRun key in it is simply ignored.
#>

$script:DCUSettingDefaults = [ordered]@{
    WorkFolder     = ''       # empty = Documents\DeviceCleanUpper
    RecentDays     = 30
    WindowsOnly    = $true
    TenantId       = ''
    UseDeviceCode  = $false
    ScopeWipe      = $false
    ScopeBitLocker = $false
}

function ConvertTo-DCUSettings {
    <#
        .SYNOPSIS
            Normalise settings from any source (a form, a JSON file, a request).
        .DESCRIPTION
            Unknown keys are dropped, missing ones take the default, and
            RecentDays is parsed and kept within what New-DCUSession accepts
            (0-3650) - a typo in a text box should not fail the next run.
    #>
    [CmdletBinding()]
    param($InputObject)

    $get = {
        param($n)
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) { if ($InputObject.Contains($n)) { return $InputObject[$n] }; return $null }
        $p = $InputObject.PSObject.Properties[$n]
        if ($p) { $p.Value } else { $null }
    }

    $out = [ordered]@{}
    foreach ($k in $script:DCUSettingDefaults.Keys) {
        $v = & $get $k
        $def = $script:DCUSettingDefaults[$k]
        $out[$k] = if ($null -eq $v) { $def }
                   elseif ($def -is [bool]) {
                       # [bool]'false' is $true in PowerShell - text has to be parsed
                       if ($v -is [string]) { $b = $def; [void][bool]::TryParse($v.Trim(), [ref]$b); $b } else { [bool]$v }
                   }
                   elseif ($def -is [int]) {
                       $n = 0
                       if (-not [int]::TryParse(([string]$v).Trim(), [ref]$n)) { $n = $def }
                       [math]::Max(0, [math]::Min(3650, $n))
                   }
                   else { ([string]$v).Trim() }
    }
    [pscustomobject]$out
}

function Read-DCUSettings {
    <#
        .SYNOPSIS
            Read the settings file. A missing file gives the defaults; a file
            that cannot be read throws, so the host can say so instead of
            silently starting from defaults.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return ConvertTo-DCUSettings $null }
    try { $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "The settings file $Path could not be read ($($_.Exception.Message)). The defaults are used; saving the settings again replaces the file." }
    ConvertTo-DCUSettings $raw
}

function Save-DCUSettings {
    <# Write the settings file, normalised. Throws when it cannot be written. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Settings
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ConvertTo-DCUSettings $Settings | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
}
