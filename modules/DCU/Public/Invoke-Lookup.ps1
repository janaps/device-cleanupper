<#
    Step 2 - look the devices up in Intune, Windows Autopilot and Entra ID.

    The three inventories are read once, in full, and matched locally. That is
    both faster and more reliable than a query per device: Intune's
    managedDevices endpoint does not support filtering on serialNumber, and a
    per-device query would be several hundred round trips for a school batch.
    The lists are cached on the module for the session, so re-opening a page
    does not re-read the tenant.
#>

function Invoke-DCULookup {
    <#
        .SYNOPSIS
            Find every device on the list in Intune, Autopilot and Entra ID.
        .DESCRIPTION
            Fills in the Intune device id, Entra device/object id, Autopilot id,
            owner, last check-in and the warning flags, and returns the updated
            rows. Read-only: nothing in the tenant is changed, whatever the dry
            run setting is.
        .PARAMETER Devices
            The working set (from Import-DCUDeviceList or a previous step).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection,
        [switch]$Refresh
    )

    Initialize-DCUContext -Session $Session
    $state = Assert-DCUSignedIn

    $devices = @($Devices | ConvertTo-DCUDeviceRecord)
    if (-not $devices.Count) { throw 'The device list is empty - add devices on step 1 first.' }

    $windowsOnly = [bool]$script:WindowsOnly
    $wantRefresh = $Refresh -or [bool](Get-DCUStepOption -Step 'Lookup' -Name 'RefreshInventory' -Default $true)

    Write-DCULog -Category 'Lookup' -Message "Looking up $($devices.Count) device(s) in $($state.TenantDomain)."
    Write-DCUProgress -Id 0 -Activity 'Looking devices up' -Status 'reading the tenant inventory' -PercentComplete 5

    Get-DCUInventory -Refresh:$wantRefresh -WindowsOnly:$windowsOnly

    Write-DCUProgress -Id 0 -Activity 'Looking devices up' -Status 'matching' -PercentComplete 80
    $matched = Resolve-DCUDeviceMatches -Devices $devices -Intune $script:IntuneDevices `
        -Autopilot $script:AutopilotDevices -Entra $script:EntraDevices -RecentDays $script:RecentDays

    # a fresh lookup pre-ticks the safe rows: found, and not flagged
    foreach ($r in $matched) {
        if ($Selection) { $r.Apply = ($Selection -contains $r.Key) }
        else { $r.Apply = Test-DCUSafeDevice $r }
    }

    $found   = @($matched | Where-Object { $_.Match -ne 'Not found' }).Count
    $missing = @($matched | Where-Object { $_.Match -eq 'Not found' })
    $recent  = @($matched | Where-Object { $_.DaysSinceActivity -ge 0 -and $script:RecentDays -gt 0 -and $_.DaysSinceActivity -lt $script:RecentDays })
    $hybrid  = @($matched | Where-Object { $_.EntraTrust -eq 'ServerAd' })
    $inIntune = @($matched | Where-Object { $_.IntuneId }).Count
    $inAp     = @($matched | Where-Object { $_.AutopilotId }).Count
    $inEntra  = @($matched | Where-Object { $_.EntraObjectId }).Count

    Write-DCULog -Level Success -Category 'Lookup' -Message "$found of $($matched.Count) device(s) found: $inIntune in Intune, $inAp in Windows Autopilot, $inEntra in Entra ID."
    foreach ($m in $missing) {
        Write-DCULog -Level Warn -Category 'Lookup' -Message "Not found in this tenant: $(Get-DCUDeviceLabel $m)"
    }
    if ($recent.Count) {
        Write-DCULog -Level Warn -Category 'Lookup' -Message "$($recent.Count) device(s) checked in less than $($script:RecentDays) day(s) ago - they look like they are still in use. They are NOT ticked."
        foreach ($m in $recent) {
            Write-DCULog -Level Warn -Category 'Lookup' -Message "  still in use: $(Get-DCUDeviceLabel $m) - last seen $($m.LastActivity) ($($m.DaysSinceActivity) d ago)"
        }
    }
    if ($hybrid.Count) {
        Write-DCULog -Level Warn -Category 'Lookup' -Message "$($hybrid.Count) device(s) are hybrid joined (trust type ServerAd). Their computer object also has to be deleted from the on-prem Active Directory, or Entra Connect syncs them back."
    }
    Write-DCUProgress -Id 0 -Activity 'Looking devices up' -Completed

    [pscustomobject]@{
        Step            = 'Lookup'
        Tenant          = $state.TenantDomain
        Total           = $matched.Count
        Found           = $found
        NotFound        = $missing.Count
        InIntune        = $inIntune
        InAutopilot     = $inAp
        InEntra         = $inEntra
        RecentlyActive  = $recent.Count
        HybridJoined    = $hybrid.Count
        InventoryRead   = "$($script:IntuneDevices.Count) Intune / $($script:AutopilotDevices.Count) Autopilot / $($script:EntraDevices.Count) Entra objects"
        Rows            = $matched
    }
}

function Get-DCUInventory {
    <#
        Read (or reuse) the three tenant device lists. Cached on the module for
        the session; -Refresh forces a re-read, which is what you want after a
        round of deletes.
    #>
    [CmdletBinding()]
    param([switch]$Refresh, [bool]$WindowsOnly = $true)

    $haveAll = $script:IntuneDevices -and $script:AutopilotDevices -and $script:EntraDevices
    if ($haveAll -and -not $Refresh) {
        Write-DCULog -Level Verbose -Category 'Lookup' -Message "Using the inventory read at $script:InventoryStamp."
        return
    }

    # --- Intune managed devices --------------------------------------------
    $select = 'id,deviceName,serialNumber,azureADDeviceId,managedDeviceOwnerType,operatingSystem,osVersion,' +
              'lastSyncDateTime,enrolledDateTime,complianceState,userPrincipalName,model,manufacturer,managementAgent'
    $uri = "v1.0/deviceManagement/managedDevices?`$select=$select&`$top=999"
    if ($WindowsOnly) { $uri += "&`$filter=operatingSystem eq 'Windows'" }
    Write-DCULog -Category 'Lookup' -Message 'Reading the Intune device list...'
    $script:IntuneDevices = @(Get-DCUGraphPages -Uri $uri -Activity 'Intune devices' -ProgressId 1)
    Write-DCULog -Category 'Lookup' -Message "  $($script:IntuneDevices.Count) Intune device(s)."

    # --- Windows Autopilot device identities --------------------------------
    Write-DCULog -Category 'Lookup' -Message 'Reading the Windows Autopilot device list...'
    $script:AutopilotDevices = @(Get-DCUGraphPages -Uri 'v1.0/deviceManagement/windowsAutopilotDeviceIdentities?$top=999' `
        -Activity 'Autopilot devices' -ProgressId 1)
    Write-DCULog -Category 'Lookup' -Message "  $($script:AutopilotDevices.Count) Autopilot registration(s)."

    # --- Entra ID device objects --------------------------------------------
    # approximateLastSignInDateTime is only returned when it is selected explicitly.
    $dsel = 'id,deviceId,displayName,operatingSystem,operatingSystemVersion,trustType,accountEnabled,' +
            'isCompliant,isManaged,profileType,physicalIds,registrationDateTime,approximateLastSignInDateTime'
    $duri = "v1.0/devices?`$select=$dsel&`$top=999"
    if ($WindowsOnly) { $duri += "&`$filter=operatingSystem eq 'Windows'" }
    Write-DCULog -Category 'Lookup' -Message 'Reading the Entra ID device list...'
    try {
        $script:EntraDevices = @(Get-DCUGraphPages -Uri $duri -Activity 'Entra ID devices' -ProgressId 1)
    }
    catch {
        # the OS filter is the usual culprit on older tenants - retry unfiltered
        Write-DCULog -Level Warn -Category 'Lookup' -Message "Filtered Entra device read failed ($($_.Exception.Message)). Retrying without the Windows filter."
        $script:EntraDevices = @(Get-DCUGraphPages -Uri "v1.0/devices?`$select=$dsel&`$top=999" -Activity 'Entra ID devices' -ProgressId 1)
    }
    Write-DCULog -Category 'Lookup' -Message "  $($script:EntraDevices.Count) Entra ID device object(s)."

    $script:InventoryStamp = (Get-Date).ToString('HH:mm:ss')
}

function Get-DCUDeviceLabel {
    <# "LT-0421 (5CD1234ABC)" - whatever identifies the row best in a log line. #>
    param($Record)
    $name = @($Record.Name, $Record.IntuneName, $Record.EntraName) | Where-Object { $_ } | Select-Object -First 1
    $serial = @($Record.Serial) | Where-Object { $_ } | Select-Object -First 1
    if ($name -and $serial) { return "$name ($serial)" }
    if ($name) { return [string]$name }
    if ($serial) { return [string]$serial }
    [string]$Record.Raw
}
