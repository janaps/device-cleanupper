<#
    DCU - Device CleanUpper core module.

    Releases Windows devices from a Microsoft 365 tenant so another tenant can
    take them over: look the devices up, keep a record of what they were, then
    remove them from Intune, from Windows Autopilot and - when it applies - from
    Entra ID, in that order.

    Nothing here talks to the console directly: output goes through
    Write-DCULog / Write-DCUProgress, which a host redirects with
    Register-DCULogSink / Register-DCUProgressSink, so the CLI
    (Invoke-DeviceCleanup.ps1) and the WPF wizard (gui\Wizard.ps1) share one
    code path.

    Authentication is DELEGATED (user based): Connect-MgGraph with an
    interactive sign-in, so every change is made as the signed-in admin and
    lands in the tenant audit log under their name. There is no app
    registration and no certificate.
#>

$ErrorActionPreference = 'Stop'

# Load order: plumbing first, then the catalogue, then Public.
$private = @(
    'Logging.ps1'
    'Context.ps1'
    'Retry.ps1'
    'Auth.ps1'
    'Graph.ps1'
    'Spreadsheet.ps1'
    'Devices.ps1'
    'Steps.ps1'
)

foreach ($file in $private) {
    $path = Join-Path $PSScriptRoot 'Private' $file
    if (Test-Path $path) { . $path }
}

$publicFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue
foreach ($file in $publicFiles) {
    . $file.FullName
}

function Assert-DCUGraphModule {
    <#
        Ensure Microsoft.Graph.Authentication is importable. Prefers a copy
        vendored next to this module (modules\Microsoft.Graph.Authentication) so
        the distributable needs no install. Called on demand, not at module
        load, so the pure-function tests run without it.

        Only the Authentication module is needed - every call goes through
        Invoke-MgGraphRequest. The big Microsoft.Graph.* command modules are
        slow to load and add nothing here.
    #>
    if (Get-Module -Name Microsoft.Graph.Authentication) { return }

    $vendored = Join-Path (Split-Path $PSScriptRoot -Parent) 'Microsoft.Graph.Authentication'
    if (Test-Path $vendored) {
        $manifest = Get-ChildItem -Path $vendored -Recurse -Filter 'Microsoft.Graph.Authentication.psd1' | Select-Object -First 1
        if ($manifest) { Import-Module $manifest.FullName -ErrorAction Stop; return }
    }
    if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication) {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        return
    }
    throw "Microsoft.Graph.Authentication was not found. Install it (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser) or place a copy in modules\Microsoft.Graph.Authentication."
}

Export-ModuleMember -Function @(
    'New-DCUSession'
    'Register-DCULogSink'
    'Register-DCUProgressSink'
    'Set-DCUCancelToken'
    'Set-DCUVerboseLogging'
    'Clear-DCUSinks'
    'Connect-DCUGraph'
    'Disconnect-DCUGraph'
    'Get-DCUSignInState'
    'Get-DCURequiredScopes'
    'Get-DCUStepList'
    'Get-DCUStatus'
    'Import-DCUDeviceList'
    'ConvertFrom-DCUPastedText'
    'Import-DCUSpreadsheet'
    'Invoke-DCULookup'
    'Invoke-DCUBackup'
    'Invoke-DCUWipe'
    'Invoke-DCUIntuneDelete'
    'Invoke-DCUAutopilotDelete'
    'Invoke-DCUAutopilotSync'
    'Invoke-DCUEntraDelete'
    'Invoke-DCUFinalCheck'
    'Save-DCUWorkingSet'
    'Import-DCUWorkingSet'
    'Export-DCUDeviceCsv'
)
