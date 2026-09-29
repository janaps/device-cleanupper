<#
    Module-scoped run context.

    Populated from a session object (New-DCUSession) by Initialize-DCUContext,
    which every public Invoke-DCU* function calls first. One run at a time.

    The two settings that matter most live here:
      $script:DryRun      nothing is changed in the tenant; every action logs
                          what it WOULD do. On by default (New-DCUSession).
      $script:RecentDays  a device that checked in more recently than this many
                          days is flagged as "still in use" everywhere.
#>

# --- configuration (set per run from the session) ----------------------------
$script:Session       = $null
$script:WorkFolder    = $null      # where exports, the working set and logs land
$script:DryRun        = $true
$script:RecentDays    = 30
$script:WindowsOnly   = $true
$script:StepOptions   = @{}
$script:AuditFile     = $null
$script:RunFolder     = $null      # <WorkFolder>\runs\<timestamp>

# --- cached tenant inventory (filled by Invoke-DCULookup) --------------------
$script:IntuneDevices    = $null
$script:AutopilotDevices = $null
$script:EntraDevices     = $null
$script:InventoryStamp   = $null

function Initialize-DCUContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session
    )

    $script:Session     = $Session
    $script:WorkFolder  = $Session.WorkFolder
    $script:DryRun      = [bool]$Session.DryRun
    $script:RecentDays  = [int]$Session.RecentDays
    $script:WindowsOnly = [bool]$Session.WindowsOnly
    $script:StepOptions = if ($Session.StepOptions) { $Session.StepOptions } else { @{} }

    if ($script:WorkFolder) {
        if (-not (Test-Path -LiteralPath $script:WorkFolder)) { New-Item -ItemType Directory -Path $script:WorkFolder -Force | Out-Null }
        # not fatal here: a logs folder that cannot be made sends the audit
        # lines to the fallback (Write-DCUAuditLine), and an exports folder is
        # made - loudly - when something is exported (Get-DCUExportFolder)
        foreach ($sub in 'logs', 'exports') {
            $p = Join-Path $script:WorkFolder $sub
            if (-not (Test-Path -LiteralPath $p)) { try { New-Item -ItemType Directory -Path $p -Force -ErrorAction Stop | Out-Null } catch { } }
        }
        # every run tries the working folder's log first again, so a fixed
        # folder is picked up without a restart
        $script:AuditFile = Join-Path $script:WorkFolder ('logs\devicecleanupper-{0:yyyy-MM-dd}.log' -f (Get-Date))
    }
    else {
        $script:AuditFile = $null
    }
}

function Get-DCUStepOption {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($script:StepOptions.ContainsKey($Step) -and
        $null -ne $script:StepOptions[$Step] -and
        $script:StepOptions[$Step].ContainsKey($Name)) {
        return $script:StepOptions[$Step][$Name]
    }
    return $Default
}

function Get-DCUExportFolder {
    <# <WorkFolder>\exports, created on demand. #>
    if (-not $script:WorkFolder) { throw 'No working folder is set on the session.' }
    $p = Join-Path $script:WorkFolder 'exports'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    $p
}

function New-DCUTimestamp { (Get-Date).ToString('yyyyMMdd-HHmmss') }
