<#
    Step 8 - prove it worked.

    Re-reads all three systems and answers, per device, the checklist from the
    handover procedure: gone from Intune, gone from Autopilot, serial no longer
    in the Autopilot list, on-prem AD still to do. Read-only, so it runs the
    same in dry run and for real - in a dry run it simply reports that nothing
    has moved yet.
#>

function Invoke-DCUFinalCheck {
    <#
        .SYNOPSIS
            Re-check every device against Intune, Autopilot and Entra ID and
            write the handover report.
        .DESCRIPTION
            Returns { Ready; NotReady; Rows; ReportCsv; ReportTxt } where Ready
            counts the devices that no longer exist in Intune or Autopilot and
            need nothing done on-premises.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection
    )

    Initialize-DCUContext -Session $Session
    $state = Assert-DCUSignedIn

    $devices = @($Devices | ConvertTo-DCUDeviceRecord)
    if (-not $devices.Count) { throw 'The device list is empty.' }

    $exportReport = [bool](Get-DCUStepOption -Step 'FinalCheck' -Name 'ExportReport' -Default $true)
    $folder       = [string](Get-DCUStepOption -Step 'FinalCheck' -Name 'ReportFolder' -Default '')
    if (-not $folder) { $folder = Get-DCUExportFolder }
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    Write-DCULog -Category 'Check' -Message 'Re-reading Intune, Windows Autopilot and Entra ID...'
    Get-DCUInventory -Refresh -WindowsOnly:$script:WindowsOnly

    # Match against the fresh inventory on the identifiers only - the ids that
    # were resolved earlier are exactly what should be gone now.
    $probe = foreach ($d in $devices) {
        [pscustomobject]@{ Key = $d.Key; Raw = $d.Raw; Name = $d.Name; Serial = $d.Serial; Note = $d.Note; Source = $d.Source }
    }
    $fresh = Resolve-DCUDeviceMatches -Devices @($probe) -Intune $script:IntuneDevices `
        -Autopilot $script:AutopilotDevices -Entra $script:EntraDevices -RecentDays $script:RecentDays

    $byKey = @{}
    foreach ($f in $fresh) { $byKey[$f.Key] = $f }

    $ready = 0; $notReady = 0; $onPrem = @()
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("Device handover check - $($state.TenantDomain) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$lines.Add(('=' * 78))
    if ($script:DryRun) {
        [void]$lines.Add('DRY RUN was on for this session - nothing has actually been removed yet.')
        [void]$lines.Add('')
    }

    foreach ($d in $devices) {
        $f = $byKey[$d.Key]
        $label = Get-DCUDeviceLabel $d

        $inIntune = [bool]($f -and $f.IntuneId)
        $inAp     = [bool]($f -and $f.AutopilotId)
        $inEntra  = [bool]($f -and $f.EntraObjectId)
        $hybrid   = ($d.EntraTrust -eq 'ServerAd' -or ($f -and $f.EntraTrust -eq 'ServerAd'))

        $d.IntuneState    = if ($inIntune) { 'Still in Intune' } else { 'Gone from Intune' }
        $d.AutopilotState = if ($inAp) { 'Still in Autopilot' } else { 'Gone from Autopilot' }
        $d.EntraState     = if ($inEntra) { 'Present' } else { 'Gone from Entra ID' }
        if ($inEntra -and $f.EntraTrust) { $d.EntraTrust = $f.EntraTrust }

        $todo = @()
        if ($inIntune) { $todo += 'still a managed device in Intune' }
        if ($inAp)     { $todo += 'serial number is still in the Autopilot list' }
        if ($hybrid)   { $todo += 'hybrid joined - delete the computer object in the on-prem Active Directory'; $onPrem += $label }

        if ($todo.Count) {
            $notReady++
            Set-DCUDeviceResult $d NotReady ('NOT ready: ' + ($todo -join '; '))
            $d.Warn = $true
            $d.Flag = ($todo -join ' | ')
            Write-DCULog -Level Warn -Category 'Check' -Message "$label - $($d.Result)"
        }
        else {
            $ready++
            Set-DCUDeviceResult $d Done 'Ready for handover'
            $d.Warn = $false
            $d.Flag = if ($inEntra) { 'Entra ID object still present (normal for an Autopilot device)' } else { '' }
            Write-DCULog -Level Success -Category 'Check' -Message "$label - ready for handover."
        }

        [void]$lines.Add(("[{0}] {1}" -f $(if ($todo.Count) { ' ' } else { 'x' }), $label))
        [void]$lines.Add("       Intune    : $($d.IntuneState)")
        [void]$lines.Add("       Autopilot : $($d.AutopilotState)")
        [void]$lines.Add("       Entra ID  : $($d.EntraState)$(if ($d.EntraTrust) { " (trust type $($d.EntraTrust))" })")
        if ($todo.Count) { [void]$lines.Add("       TO DO     : " + ($todo -join '; ')) }
        [void]$lines.Add('')
    }

    [void]$lines.Add(('-' * 78))
    [void]$lines.Add("Ready for handover : $ready of $($devices.Count)")
    [void]$lines.Add("Still to do        : $notReady")
    if ($onPrem.Count) {
        [void]$lines.Add('')
        [void]$lines.Add('Delete these computer objects from the on-prem Active Directory, or Entra Connect')
        [void]$lines.Add('will sync them back:')
        foreach ($o in $onPrem) { [void]$lines.Add("  - $o") }
    }
    [void]$lines.Add('')
    [void]$lines.Add('Also confirm by hand, on a test device:')
    [void]$lines.Add('  - the device no longer shows this tenant''s branding during Windows OOBE')
    [void]$lines.Add('  - the BitLocker and user data you needed were secured beforehand')

    $csvPath = ''; $txtPath = ''
    if ($exportReport) {
        $stamp = New-DCUTimestamp
        $csvPath = Join-Path $folder "handover-$stamp.csv"
        $txtPath = Join-Path $folder "handover-$stamp.txt"
        Export-DCUDeviceCsv -Devices $devices -Path $csvPath | Out-Null
        $lines -join "`r`n" | Set-Content -LiteralPath $txtPath -Encoding UTF8
        Write-DCULog -Level Success -Category 'Check' -Message "Handover report: $txtPath"
        Write-DCULog -Category 'Check' -Message "Handover data: $csvPath"
    }

    if ($notReady -eq 0) {
        Write-DCULog -Level Success -Category 'Check' -Message "All $($devices.Count) device(s) are released. Tenant A is done - the other tenant can register them."
    }
    else {
        Write-DCULog -Level Warn -Category 'Check' -Message "$notReady device(s) are not released yet - see the report."
    }

    [pscustomobject]@{
        Step          = 'FinalCheck'
        Tenant        = $state.TenantDomain
        DryRun        = $script:DryRun
        Total         = $devices.Count
        Ready         = $ready
        NotReady      = $notReady
        NeedsOnPremAd = $onPrem.Count
        ReportCsv     = $csvPath
        ReportTxt     = $txtPath
        Checklist     = ($lines -join "`r`n")
        Rows          = $devices
    }
}
