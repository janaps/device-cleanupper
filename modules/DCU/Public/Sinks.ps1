<#
    Host integration points: where log lines, progress updates and the cancel
    signal go. The CLI registers console sinks; the wizard registers sinks that
    push onto a thread-safe queue drained by the UI thread.
#>

function Register-DCULogSink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Sink)
    # $Sink receives one argument: [pscustomobject]@{ Timestamp; Level; Message; Category }
    $script:LogSink = $Sink
}

function Register-DCUProgressSink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Sink)
    # $Sink receives: [pscustomobject]@{ Activity; Status; PercentComplete; Id; Completed }
    $script:ProgressSink = $Sink
}

function Set-DCUCancelToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ref]$Token)
    $script:CancelToken = $Token
}

function Clear-DCUSinks {
    $script:LogSink = $null
    $script:ProgressSink = $null
    $script:CancelToken = $null
}

function Set-DCUVerboseLogging {
    param([bool]$Enabled)
    $script:VerboseLog = $Enabled
}
