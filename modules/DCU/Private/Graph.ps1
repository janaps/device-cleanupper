<#
    Thin Microsoft Graph helpers on top of Invoke-MgGraphRequest.

    Only Microsoft.Graph.Authentication is used - the big Microsoft.Graph.*
    command modules are slow to import and add nothing over the raw REST calls
    this tool makes.

    Invoke-DCUGraph      one call, with retry and a readable error
    Get-DCUGraphPages    follow @odata.nextLink and return every item
#>

function Invoke-DCUGraph {
    <#
        .PARAMETER Uri
            Either a full https://graph.microsoft.com/... URL (as returned in
            @odata.nextLink) or a relative one like 'v1.0/deviceManagement/...'.
        .PARAMETER Tolerate
            HTTP status codes that are an expected outcome rather than a
            failure - e.g. 404 when checking that something is really gone.
            Returns $null for those instead of throwing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        $Body,
        [int[]]$Tolerate = @(),
        [string]$Context
    )

    Assert-DCUGraphModule
    Test-DCUCancelled

    $full = if ($Uri -match '^https?://') { $Uri } else { "https://graph.microsoft.com/$($Uri.TrimStart('/'))" }
    if (-not $Context) { $Context = "$Method $($Uri -replace '\?.*$', '')" }

    $call = {
        # NB: not $args - that is an automatic variable inside a scriptblock
        $req = @{ Method = $Method; Uri = $full; OutputType = 'PSObject'; ErrorAction = 'Stop' }
        if ($null -ne $Body) {
            $req.Body        = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
            $req.ContentType = 'application/json'
        }
        Invoke-MgGraphRequest @req
    }

    try {
        return Invoke-DCUWithRetry -ScriptBlock $call -Context $Context
    }
    catch [System.OperationCanceledException] { throw }
    catch {
        $status = Get-DCUGraphStatusCode $_
        if ($status -and $Tolerate -contains $status) {
            Write-DCULog -Level Verbose -Message "$Context returned $status (expected)."
            return $null
        }
        throw [System.Exception]::new((Get-DCUGraphErrorText $_ $Context), $_.Exception)
    }
}

function Get-DCUGraphPages {
    <#
        Follow @odata.nextLink and return every item in the collection.
        Reports progress on -ProgressId so a long inventory read does not look
        like a hang, and checks the cancel token between pages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Activity = 'Reading from Microsoft Graph',
        [int]$ProgressId = 1,
        [int]$MaxPages = 500
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $next  = $Uri
    $page  = 0

    while ($next -and $page -lt $MaxPages) {
        Test-DCUCancelled
        $page++
        $r = Invoke-DCUGraph -Uri $next -Context $Activity
        if ($null -eq $r) { break }
        foreach ($v in @($r.value)) { [void]$items.Add($v) }
        Write-DCUProgress -Id $ProgressId -Activity $Activity -Status "$($items.Count) object(s), page $page" -PercentComplete -1
        $next = [string]$r.'@odata.nextLink'
    }
    if ($page -ge $MaxPages -and $next) {
        Write-DCULog -Level Warn -Message "$Activity stopped after $MaxPages pages ($($items.Count) objects). Narrow the filter if this is not everything."
    }
    Write-DCUProgress -Id $ProgressId -Activity $Activity -Completed
    $items.ToArray()
}

function Get-DCUGraphStatusCode {
    param($ErrorRecord)
    try {
        $r = $ErrorRecord.Exception.Response
        if ($r -and $r.StatusCode) { return [int]$r.StatusCode }
    }
    catch { }
    if ($ErrorRecord.Exception.Message -match '\b(400|401|403|404|409|429|500|503|504)\b') { return [int]$Matches[1] }
    $null
}

function Get-DCUGraphErrorText {
    <#
        Graph errors arrive as a JSON blob inside the exception message. Pull
        out code + message so the activity feed reads like a sentence rather
        than a wall of JSON, and translate the two that admins hit most.
    #>
    param($ErrorRecord, [string]$Context)

    $raw = [string]$ErrorRecord.Exception.Message
    # Invoke-MgGraphRequest leaves the exception at "BadRequest (Bad Request)"
    # and puts Graph's own error JSON in ErrorDetails - that is the useful part
    $details = if ($ErrorRecord.ErrorDetails) { [string]$ErrorRecord.ErrorDetails.Message } else { '' }
    $code = ''; $msg = ''
    foreach ($text in $details, $raw) {
        try {
            $m = [regex]::Match($text, '\{.*\}', 'Singleline')
            if ($m.Success) {
                $j = $m.Value | ConvertFrom-Json -ErrorAction Stop
                $code = [string]$j.error.code
                $msg  = [string]$j.error.message
            }
        }
        catch { }
        if ($msg) { break }
    }
    if (-not $msg) { $msg = $raw }

    $status = Get-DCUGraphStatusCode $ErrorRecord
    $hint = switch ($status) {
        403 { ' - the signed-in account is not allowed to do this (needs Intune Administrator / Cloud Device Administrator, or the scope was not consented).' }
        401 { ' - the sign-in expired. Sign in again on the Setup page.' }
        404 { ' - the object no longer exists.' }
        default { '' }
    }
    $prefix = if ($Context) { "$Context failed" } else { 'Graph call failed' }
    $codeText = if ($code) { " [$code]" } else { '' }
    "${prefix}${codeText}: ${msg}${hint}"
}

function ConvertTo-DCUDate {
    <# Graph hands back ISO strings (and sometimes DateTime already). #>
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [ref]$d)) {
        # Intune writes 0001-01-01 for "never"
        if ($d.Year -le 1601) { return $null }
        return $d
    }
    $null
}
