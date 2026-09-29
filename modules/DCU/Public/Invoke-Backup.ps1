<#
    Step 3 - write down what these devices were, before they stop existing.

    Once the Intune, Autopilot and Entra records are deleted, the device ids
    cannot be looked up again, and the BitLocker recovery keys Entra was
    holding go with the device object. This step is the one that is genuinely
    hard to undo by skipping it.
#>

function Invoke-DCUBackup {
    <#
        .SYNOPSIS
            Export the resolved device list (and optionally the BitLocker
            recovery keys) to the working folder.
        .DESCRIPTION
            Writes <exports>\devices-<timestamp>.csv and .json. With
            -IncludeBitLocker it also reads the recovery keys Entra ID holds
            for these devices; without -IncludeKeyValues only the key ids and
            creation dates are written, which is enough to prove a key exists
            without the file itself becoming the key.

            Reading is not a change, so this step runs for real even in dry
            run - a dry run that skipped the backup would be worse than
            useless.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Session,
        [Parameter(Mandatory)][object[]]$Devices,
        [string[]]$Selection
    )

    Initialize-DCUContext -Session $Session
    Assert-DCUSignedIn | Out-Null

    $devices  = @($Devices | ConvertTo-DCUDeviceRecord)
    $targets  = @(Select-DCUDevices -Devices $devices -Selection $Selection)

    $exportCsv   = [bool](Get-DCUStepOption -Step 'Backup' -Name 'ExportCsv' -Default $true)
    $doBitLocker = [bool](Get-DCUStepOption -Step 'Backup' -Name 'IncludeBitLocker' -Default $false)
    $withValues  = [bool](Get-DCUStepOption -Step 'Backup' -Name 'IncludeKeyValues' -Default $false)
    $folder      = [string](Get-DCUStepOption -Step 'Backup' -Name 'ExportFolder' -Default '')
    if (-not $folder) { $folder = Get-DCUExportFolder }
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    $stamp = New-DCUTimestamp
    $csvPath = ''; $jsonPath = ''; $blPath = ''
    $keyCount = 0; $withKeys = 0; $blErrors = 0

    if ($exportCsv) {
        $csvPath  = Join-Path $folder "devices-$stamp.csv"
        $jsonPath = Join-Path $folder "devices-$stamp.json"
        # Out-Null: it returns the path, and a second object on the output
        # turns this step's summary into an array
        Export-DCUDeviceCsv -Devices $targets -Path $csvPath | Out-Null
        $targets | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
        Write-DCULog -Level Success -Category 'Backup' -Message "Device list exported: $csvPath"
        Write-DCULog -Category 'Backup' -Message "Same data as JSON: $jsonPath"
    }

    if ($doBitLocker) {
        $withEntra = @($targets | Where-Object { $_.AzureAdDeviceId })
        Write-DCULog -Category 'Backup' -Message "Reading BitLocker recovery keys for $($withEntra.Count) device(s) with an Entra ID device id..."
        if ($withValues) {
            Write-DCULog -Level Warn -Category 'Backup' -Message 'The recovery passwords themselves will be written to the file. Treat that file as a password list and delete it once the handover is done.'
        }

        $rows = [System.Collections.Generic.List[object]]::new()
        $i = 0
        foreach ($d in $withEntra) {
            Test-DCUCancelled
            $i++
            Write-DCUProgress -Id 0 -Activity 'BitLocker recovery keys' -Status (Get-DCUDeviceLabel $d) `
                -PercentComplete ([int](100 * $i / [math]::Max($withEntra.Count, 1)))
            try {
                $keys = @(Get-DCUBitLockerKeys -AzureAdDeviceId $d.AzureAdDeviceId -IncludeValues:$withValues)
                if (-not $keys.Count) {
                    $d.BitLockerState = 'No key in Entra ID'
                    Write-DCULog -Level Warn -Category 'Backup' -Message "No BitLocker recovery key stored for $(Get-DCUDeviceLabel $d)."
                    continue
                }
                foreach ($k in $keys) {
                    [void]$rows.Add([pscustomobject]@{
                        DeviceName      = $d.Name
                        SerialNumber    = $d.Serial
                        AzureAdDeviceId = $d.AzureAdDeviceId
                        KeyId           = $k.id
                        VolumeType      = $k.volumeType
                        CreatedDateTime = $k.createdDateTime
                        RecoveryKey     = $(if ($withValues) { $k.key } else { '(not exported)' })
                    })
                }
                $keyCount += $keys.Count
                $withKeys++
                $d.BitLockerState = "$($keys.Count) key(s)"
            }
            catch {
                $blErrors++
                $d.BitLockerState = 'Read failed'
                Write-DCULog -Level Error -Category 'Backup' -Message "BitLocker keys for $(Get-DCUDeviceLabel $d): $($_.Exception.Message)"
            }
        }
        Write-DCUProgress -Id 0 -Activity 'BitLocker recovery keys' -Completed

        if ($rows.Count) {
            $blPath = Join-Path $folder "bitlocker-keys-$stamp.csv"
            $rows | Export-Csv -LiteralPath $blPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
            Write-DCULog -Level Success -Category 'Backup' -Message "$($rows.Count) BitLocker key record(s) exported: $blPath"
        }
        else {
            Write-DCULog -Level Warn -Category 'Backup' -Message 'No BitLocker recovery keys were found for these devices.'
        }
    }

    # ExportedAt is what the rest of the tool reads ("was this written down
    # before it was deleted?"), so it is only set when the device file was
    # really written - not for a run with every export switched off
    if ($exportCsv) {
        $when = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        foreach ($d in $targets) {
            $d.ExportedAt = $when
            Set-DCUDeviceResult $d Done "Exported to $([IO.Path]::GetFileName($csvPath))"
        }
    }
    elseif (-not $doBitLocker) {
        Write-DCULog -Level Warn -Category 'Backup' -Message 'Nothing was exported - both the device list and the BitLocker keys are switched off.'
    }

    [pscustomobject]@{
        Step            = 'Backup'
        Exported        = $targets.Count
        DeviceCsv       = $csvPath
        DeviceJson      = $jsonPath
        BitLockerCsv    = $blPath
        BitLockerKeys   = $keyCount
        DevicesWithKeys = $withKeys
        BitLockerErrors = $blErrors
        Rows            = $devices
    }
}

function Get-DCUBitLockerKeys {
    <#
        The recovery keys Entra ID holds for one device. Listing them needs
        BitLockerKey.ReadBasic.All; reading the key value itself needs
        BitLockerKey.Read.All and is a separate call per key, which Microsoft
        also records in the audit log as a key retrieval.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AzureAdDeviceId,
        [switch]$IncludeValues
    )
    $uri = "v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '$AzureAdDeviceId'"
    $r = Invoke-DCUGraph -Uri $uri -Context 'BitLocker key list' -Tolerate 404
    $keys = @($r.value)
    if (-not $IncludeValues) { return $keys }

    foreach ($k in $keys) {
        Test-DCUCancelled
        $full = Invoke-DCUGraph -Uri "v1.0/informationProtection/bitlocker/recoveryKeys/$($k.id)?`$select=key,volumeType,createdDateTime" `
            -Context 'BitLocker key value' -Tolerate 404
        if ($full) { $k | Add-Member -NotePropertyName key -NotePropertyValue ([string]$full.key) -Force }
    }
    $keys
}

function Export-DCUDeviceCsv {
    <#
        .SYNOPSIS
            Write the device list to a semicolon-separated CSV.
        .DESCRIPTION
            Semicolon separated and UTF-8, so it opens straight into Excel on a
            Dutch Windows install without an import wizard.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Devices,
        [Parameter(Mandatory)][string]$Path
    )
    $rows = foreach ($d in @($Devices | ConvertTo-DCUDeviceRecord)) {
        [pscustomobject][ordered]@{
            DeviceName        = $d.Name
            SerialNumber      = $d.Serial
            Note              = $d.Note
            Match             = $d.Match
            IntuneDeviceId    = $d.IntuneId
            IntuneName        = $d.IntuneName
            IntuneUser        = $d.IntuneUser
            IntuneOwnerType   = $d.IntuneOwner
            IntuneCompliance  = $d.IntuneCompliance
            IntuneLastSync    = $d.IntuneLastSync
            IntuneEnrolled    = $d.IntuneEnrolled
            OperatingSystem   = $d.IntuneOs
            Model             = $d.IntuneModel
            EntraDeviceId     = $d.AzureAdDeviceId
            EntraObjectId     = $d.EntraObjectId
            EntraTrustType    = $d.EntraTrust
            EntraLastSignIn   = $d.EntraLastSignIn
            AutopilotId       = $d.AutopilotId
            AutopilotGroupTag = $d.AutopilotGroupTag
            AutopilotEnrolled = $d.AutopilotEnrollment
            AutopilotUser     = $d.AutopilotUser
            LastActivity      = $d.LastActivity
            DaysSinceActivity = $(if ($d.DaysSinceActivity -ge 0) { $d.DaysSinceActivity } else { '' })
            Warning           = $d.Flag
            IntuneState       = $d.IntuneState
            AutopilotState    = $d.AutopilotState
            EntraState        = $d.EntraState
            BitLockerState    = $d.BitLockerState
            Result            = $d.Result
        }
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -Delimiter ';'
    $Path
}
