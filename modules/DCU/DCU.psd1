@{
    RootModule        = 'DCU.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '5c9a3f61-2d84-4b17-9e0c-7a6b4f2d81c3'
    Author            = 'Jan Aps'
    Copyright         = '(c) 2026 Jan Aps. MIT License.'
    Description       = 'Device CleanUpper - shared core for releasing Windows devices from a Microsoft 365 tenant (Intune, Windows Autopilot, Entra ID) so another tenant can take them over. Drives both the CLI and the WPF wizard.'
    PowerShellVersion = '7.2'

    # Microsoft.Graph.Authentication is a runtime dependency loaded on demand
    # (Assert-DCUGraphModule) so the module still imports for the pure-function
    # tests without it. Everything talks to Graph through Invoke-MgGraphRequest -
    # the big Microsoft.Graph.* SDK sub-modules are deliberately NOT used.

    FunctionsToExport = @(
        # session + host integration
        'New-DCUSession'
        'Register-DCULogSink'
        'Register-DCUProgressSink'
        'Set-DCUCancelToken'
        'Set-DCUVerboseLogging'
        'Clear-DCUSinks'
        # authentication (delegated / user based)
        'Connect-DCUGraph'
        'Disconnect-DCUGraph'
        'Get-DCUSignInState'
        'Get-DCURequiredScopes'
        # discovery / catalogue / status
        'Get-DCUStepList'
        'Get-DCUStatus'
        # device list input
        'Import-DCUDeviceList'
        'ConvertFrom-DCUPastedText'
        'Import-DCUSpreadsheet'
        # steps
        'Invoke-DCULookup'
        'Invoke-DCUBackup'
        'Invoke-DCUWipe'
        'Invoke-DCUIntuneDelete'
        'Invoke-DCUAutopilotDelete'
        'Invoke-DCUAutopilotSync'
        'Invoke-DCUEntraDelete'
        'Invoke-DCUFinalCheck'
        # working set + reporting
        'Save-DCUWorkingSet'
        'Import-DCUWorkingSet'
        'Export-DCUDeviceCsv'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Microsoft365', 'Intune', 'Autopilot', 'EntraID', 'Graph', 'DeviceManagement')
            ProjectUri = 'https://github.com/janaps/device-cleanupper'
            LicenseUri = 'https://github.com/janaps/device-cleanupper/blob/main/LICENSE'
        }
    }
}
