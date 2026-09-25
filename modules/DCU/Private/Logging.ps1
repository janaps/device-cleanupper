<#
    Logging + progress + cancellation plumbing for the DCU module.

    Every DCU function writes through Write-DCULog / Write-DCUProgress instead
    of Write-Host / Write-Progress. A host (CLI or wizard GUI) registers a sink
    with Register-DCULogSink / Register-DCUProgressSink. With no sink registered
    the default is coloured console output, so the module is usable bare.

    -Category carries the kind of line (Lookup / Delete / Wipe / DryRun / Audit)
    so the GUI can colour it and the audit-file sink can keep a CSV shape.
#>

$script:LogSink      = $null   # scriptblock param($entry)
$script:ProgressSink = $null   # scriptblock param($progress)
$script:CancelToken  = $null   # [ref] to a [bool]; $true means "cancel requested"
$script:VerboseLog   = $false  # include Verbose-level entries in the default sink

function Write-DCULog {
    [CmdletBinding()]
    param(
        [ValidateSet('Verbose', 'Info', 'Success', 'Warn', 'Error')]
        [string]$Level = 'Info',

        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        # Free-form category kept for the audit file (Lookup/Delete/Wipe/DryRun/...).
        [string]$Category
    )

    $entry = [PSCustomObject]@{
        Timestamp = Get-Date
        Level     = $Level
        Message   = $Message
        Category  = $Category
    }

    # every line also goes to the run's audit file, if one is open
    Write-DCUAuditLine $entry

    if ($script:LogSink) {
        try { & $script:LogSink $entry } catch { }
        return
    }

    if ($Level -eq 'Verbose' -and -not $script:VerboseLog) { return }

    $color = switch ($Level) {
        'Verbose' { 'DarkGray' }
        'Info'    { 'Gray' }
        'Success' { 'Green' }
        'Warn'    { 'Yellow' }
        'Error'   { 'Red' }
    }
    $tag = switch ($Level) {
        'Verbose' { '[..]' }
        'Info'    { '[i]' }
        'Success' { '[ok]' }
        'Warn'    { '[!]' }
        'Error'   { '[x]' }
    }
    Microsoft.PowerShell.Utility\Write-Host ("{0:HH:mm:ss} {1} {2}" -f $entry.Timestamp, $tag, $Message) -ForegroundColor $color
}

function Write-DCUProgress {
    [CmdletBinding()]
    param(
        [string]$Activity = 'Working',
        [string]$Status = ' ',
        [int]$PercentComplete = -1,
        [int]$Id = 0,
        [switch]$Completed,
        # a status worth showing in the activity feed as one line that updates
        # in place (a countdown), not just on the progress bar
        [switch]$Live
    )

    $progress = [PSCustomObject]@{
        Activity        = $Activity
        Status          = $Status
        PercentComplete = $PercentComplete
        Id              = $Id
        Completed       = [bool]$Completed
        Live            = [bool]$Live
    }

    if ($script:ProgressSink) {
        try { & $script:ProgressSink $progress } catch { }
        return
    }

    $wp = @{ Activity = $Activity; Id = $Id }
    if ($Completed) {
        $wp.Completed = $true
    }
    else {
        $wp.Status = $Status
        if ($PercentComplete -ge 0) { $wp.PercentComplete = [math]::Min($PercentComplete, 100) }
    }
    Microsoft.PowerShell.Utility\Write-Progress @wp
}

function Test-DCUCancelled {
    if ($script:CancelToken -and $script:CancelToken.Value) {
        throw [System.OperationCanceledException]::new('Cancelled by the user.')
    }
}

function Write-DCUAuditLine {
    <#
        Append one log line to <WorkFolder>\logs\devicecleanupper-<date>.log.
        This tool deletes things: the audit trail is written even when the GUI
        is closed mid-run, so it is a plain append with no buffering.
    #>
    param($Entry)
    if (-not $script:AuditFile) { return }
    try {
        $line = "{0:yyyy-MM-dd HH:mm:ss}`t{1}`t{2}`t{3}" -f $Entry.Timestamp, $Entry.Level, $Entry.Category, ($Entry.Message -replace "`r?`n", ' ')
        Add-Content -LiteralPath $script:AuditFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}
