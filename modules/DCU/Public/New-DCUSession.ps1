<#
    New-DCUSession - build and validate a run configuration.

    One validated object that both the CLI and the wizard hand to the
    Invoke-DCU* step functions. The two settings worth reading twice:

      DryRun      $true by default, on purpose. Nothing is changed in the
                  tenant; every action logs what it WOULD do and the result
                  rows come back marked as simulated. The caller has to pass
                  -DryRun:$false to actually delete anything.
      RecentDays  a device seen more recently than this is flagged as still in
                  use, everywhere it shows up.
#>

function New-DCUSession {
    [CmdletBinding()]
    param(
        # Where exports, the working set and the audit log are written.
        [string]$WorkFolder,

        # SAFETY DEFAULT: simulate everything. Pass -DryRun:$false to run for real.
        [bool]$DryRun = $true,

        # Warn about devices that checked in less than this many days ago.
        # 0 turns the recent-activity warning off entirely.
        [ValidateRange(0, 3650)]
        [int]$RecentDays = 30,

        # Limit the tenant inventory to Windows devices.
        [bool]$WindowsOnly = $true,

        # Per-step option overrides: @{ Backup = @{ IncludeBitLocker = $true }; ... }
        [hashtable]$StepOptions = @{},

        # Tenant to sign in to / that the devices are being released from.
        [string]$TenantId
    )

    if (-not $WorkFolder) {
        $WorkFolder = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'DeviceCleanUpper'
    }
    if (-not (Test-Path -LiteralPath $WorkFolder)) {
        New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null
    }
    $WorkFolder = (Resolve-Path -LiteralPath $WorkFolder).Path

    # normalise every step's options against the catalogue defaults
    $resolvedOptions = @{}
    foreach ($meta in $script:DCUStepCatalog) {
        $ov = if ($StepOptions.ContainsKey($meta.Key)) { $StepOptions[$meta.Key] } else { @{} }
        $resolvedOptions[$meta.Key] = Resolve-DCUStepOptions -Key $meta.Key -Override $ov
    }

    [pscustomobject]@{
        WorkFolder  = $WorkFolder
        DryRun      = [bool]$DryRun
        RecentDays  = [int]$RecentDays
        WindowsOnly = [bool]$WindowsOnly
        TenantId    = $TenantId
        StepOptions = $resolvedOptions
        Created     = Get-Date
    }
}
