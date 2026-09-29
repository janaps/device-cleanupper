<#
    Web host checks - dot-sourced by Run-SmokeTests.ps1 (Check, NewRec,
    MatchRec, Get-ThrownMessage, $tmp, the fixture inventories).

    Most of these call the host's routing and request checks directly, with no
    listener and no worker: they check what the host refuses before anything
    is started. The last one starts the real host in a separate process and
    talks to it over HTTP, as the browser does - it never signs in.
#>

$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
Import-Module (Join-Path $repoRoot 'web\DcuWeb.psm1') -Force

function WebState {
    <# a host state with a fake sign-in and a looked-up list (LT-0001 safe, LT-0002 flagged, one not found) #>
    param([switch]$SignedOut, [object[]]$Devices)
    $s = New-DCUWebState -RootPath $repoRoot -Port 5555 -Token ('ab' * 32) -ConfigPath (Join-Path $tmp 'web-config.json')
    if (-not $SignedOut) {
        $s.SignIn = [pscustomobject]@{ SignedIn = $true; Account = 'admin@contoso.com'; TenantId = 'tid-contoso'
            TenantDomain = 'contoso.onmicrosoft.com'; Scopes = @(); MissingScopes = @(); Message = '' }
    }
    $s.Devices = if ($Devices) { $Devices } else { @(MatchRec -Devices @(NewRec -Serial '5CD1111AAA'; NewRec -Serial '5CD2222BBB'; NewRec -Serial 'NOPE12345')) }
    $s.Settings = ConvertTo-DCUSettings @{ WorkFolder = (Join-Path $tmp 'web-work') }
    $s
}
function Route { param($State, [string]$Method, [string]$Path, [hashtable]$Body = @{}) Invoke-DCUWebRoute $State $Method $Path @{} $Body }
$okHeaders = @{ host = '127.0.0.1:5555'; 'x-dcu-token' = ('ab' * 32) }

# --- request checks ------------------------------------------------------------
Check 'web: an API call without the token, or with the wrong one, is refused' {
    $s = WebState
    ((Test-DCUWebRequest $s '/api/state' @{ host = '127.0.0.1:5555' }).Status -eq 401) -and
    ((Test-DCUWebRequest $s '/api/state' @{ host = '127.0.0.1:5555'; 'x-dcu-token' = ('ac' * 32) }).Status -eq 401) -and
    ($null -eq (Test-DCUWebRequest $s '/api/state' $okHeaders))
}

function With { param([hashtable]$Extra) $h = $okHeaders.Clone(); foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }; $h }

Check 'web: another Host name is refused (DNS rebinding), another Origin too' {
    $s = WebState
    ((Test-DCUWebRequest $s '/api/state' (With @{ host = 'evil.example:5555' })).Status -eq 421) -and
    ((Test-DCUWebRequest $s '/api/state' (With @{ origin = 'http://evil.example' })).Status -eq 403) -and
    ((Test-DCUWebRequest $s '/api/state' (With @{ 'sec-fetch-site' = 'cross-site' })).Status -eq 403) -and
    ($null -eq (Test-DCUWebRequest $s '/api/state' (With @{ origin = 'http://127.0.0.1:5555' })))
}

Check 'web: only named files in web\static are served' {
    $s = WebState
    ((Route $s GET '/static/app.js').File -like '*web\static\app.js') -and
    ((Route $s GET '/static/../Start-Web.ps1').Status -eq 404) -and ((Route $s GET '/static/nope.js').Status -eq 404) -and
    ((Route $s GET '/Start-Web.ps1').Status -eq 404)
}

# --- what the host refuses before it starts anything ---------------------------------
Check 'web: every session starts as a dry run, and the mode only takes a real true/false' {
    $s = WebState
    $s.DryRun -and ((Route $s POST '/api/mode' @{ dryRun = 'false' }).Status -eq 400) -and $s.DryRun -and
    ((Route $s POST '/api/mode' @{ dryRun = $false }).Status -eq 200) -and -not $s.DryRun
}

Check 'web: a plan for a large live batch asks for the signed-in tenant to be typed' {
    $s = WebState -Devices (BatchRows 12); $s.DryRun = $false
    $p = (Route $s POST '/api/plan' @{ step = 'IntuneDelete'; selection = @($s.Devices.Key) }).Body
    $p.RequiresTypedConfirmation -and ($p.TypedConfirmationText -eq 'contoso.onmicrosoft.com')
}

Check 'web: a live destructive run without the matching confirmation starts nothing' {
    $s = WebState; $s.DryRun = $false
    $r = Route $s POST '/api/run' @{ step = 'IntuneDelete'; selection = @('S:5CD1111AAA'); confirmationKey = 'wrong' }
    ($r.Status -eq 409) -and ($null -eq $s.Busy) -and ($null -eq $s.Runspace)
}

Check 'web: a large live batch without the right tenant typed starts nothing' {
    $s = WebState -Devices (BatchRows 12); $s.DryRun = $false
    $sel = @($s.Devices.Key)
    $key = (Route $s POST '/api/plan' @{ step = 'IntuneDelete'; selection = $sel }).Body.ConfirmationKey
    $none  = Route $s POST '/api/run' @{ step = 'IntuneDelete'; selection = $sel; confirmationKey = $key }
    $wrong = Route $s POST '/api/run' @{ step = 'IntuneDelete'; selection = $sel; confirmationKey = $key; tenantConfirmation = 'fabrikam.onmicrosoft.com' }
    ($none.Status -eq 400) -and ($wrong.Status -eq 400) -and ($null -eq $s.Busy) -and ($null -eq $s.Runspace)
}

Check 'web: a run request cannot bring its own device rows' {
    # the host plans against its own list; a smuggled row with someone else's Intune id is not in it
    $s = WebState -Devices @(); $s.DryRun = $false
    $r = Route $s POST '/api/run' @{ step = 'IntuneDelete'; selection = @('S:EVIL1'); confirmationKey = 'x'
                                     devices = @(@{ Key = 'S:EVIL1'; Serial = 'EVIL1'; IntuneId = 'someone-elses-device'; Match = 'Matched' }) }
    ($r.Status -eq 409) -and ($r.Body.error -like '*No devices are selected*') -and ($null -eq $s.Runspace)
}

Check 'web: signed out, a run is refused' {
    $s = WebState -SignedOut
    $r = Route $s POST '/api/run' @{ step = 'Lookup' }
    ($r.Status -eq 409) -and ($r.Body.error -eq 'Not signed in.') -and ($null -eq $s.Runspace)
}

Check 'web: while something runs, the list, the mode and a second run are refused' {
    $s = WebState; $s.Busy = [pscustomobject]@{ operation = 'step'; runId = 'x' }
    $codes = @(
        (Route $s POST '/api/run' @{ step = 'Lookup' }).Status
        (Route $s POST '/api/mode' @{ dryRun = $false }).Status
        (Route $s POST '/api/devices/remove' @{ keys = @('S:5CD1111AAA') }).Status
        (Route $s POST '/api/devices/clear').Status
        (Route $s POST '/api/devices/import' @{ source = 'text'; text = 'X1' }).Status
        (Route $s POST '/api/shutdown').Status
    )
    (($codes | Select-Object -Unique) -join ',') -eq '409'
}

Check 'web: an upload of another file type, or an empty paste, is refused before the worker starts' {
    $s = WebState
    $csv = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('Serial;Name'))
    ((Route $s POST '/api/devices/import' @{ source = 'file'; fileName = 'list.exe'; fileBase64 = $csv }).Status -eq 400) -and
    ((Route $s POST '/api/devices/import' @{ source = 'text'; text = '   ' }).Status -eq 400) -and
    ((Route $s POST '/api/devices/import' @{ source = 'somewhere' }).Status -eq 400) -and ($null -eq $s.Runspace)
}

Check 'web: removing devices keeps the previous saved list as a copy' {
    $s = WebState
    $work = Join-Path $tmp 'web-work'
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory $work | Out-Null
    '{ "Devices": [] }' | Set-Content (Join-Path $work 'workingset.json')
    $r = Route $s POST '/api/devices/remove' @{ keys = @('S:5CD2222BBB') }
    $saved = @(Import-DCUWorkingSet -Path (Join-Path $work 'workingset.json'))
    ($r.Status -eq 200) -and (@($s.Devices).Count -eq 2) -and ($saved.Count -eq 2) -and
    (@(Get-ChildItem $work -Filter 'workingset-before-*.json').Count -eq 1)
}

Check 'web: the state the page gets carries the gate, the status and the saved list' {
    $s = WebState
    $b = (Route $s GET '/api/state').Body
    ($b.gate.Level -eq 'Open') -and (@($b.status).Count -eq 9) -and $b.dryRun -and ($b.tenantName -eq 'contoso.onmicrosoft.com')
}

# --- the real host, over HTTP ------------------------------------------------------
Check 'web: the host serves the page, reads a pasted list in its worker, saves it and quits' {
    $dir = Join-Path $tmp 'web-live'; New-Item -ItemType Directory $dir -Force | Out-Null
    @{ WorkFolder = (Join-Path $dir 'work') } | ConvertTo-Json | Set-Content (Join-Path $dir 'config.json')
    $urlFile = Join-Path $dir 'url.txt'
    $proc = Start-Process pwsh -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $dir 'out.txt') -RedirectStandardError (Join-Path $dir 'err.txt') `
        -ArgumentList '-NoProfile', '-File', (Join-Path $repoRoot 'Start-Web.ps1'), '-NoBrowser', '-UrlFile', $urlFile, '-ConfigPath', (Join-Path $dir 'config.json')
    try {
        for ($i = 0; $i -lt 80 -and -not (Test-Path $urlFile); $i++) { Start-Sleep -Milliseconds 250 }
        $url = (Get-Content $urlFile -Raw).Trim()
        $base = $url.Substring(0, $url.IndexOf('/#')); $H = @{ 'X-DCU-Token' = $url.Substring($url.IndexOf('token=') + 6) }
        $page = Invoke-WebRequest "$base/"
        $csp = [string]$page.Headers['Content-Security-Policy']
        $denied = (Invoke-WebRequest "$base/api/state" -SkipHttpErrorCheck).StatusCode
        Invoke-RestMethod -Method POST "$base/api/devices/import" -Headers $H -ContentType 'application/json' `
            -Body (@{ source = 'text'; text = "5CD1111AAA`n5CD2222BBB"; append = $true } | ConvertTo-Json) | Out-Null
        for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Milliseconds 250; if (-not (Invoke-RestMethod "$base/api/events?after=0" -Headers $H).busy) { break } }
        $count = @((Invoke-RestMethod "$base/api/devices" -Headers $H).devices).Count
        $saved = Test-Path (Join-Path $dir 'work\workingset.json')
        Invoke-RestMethod -Method POST "$base/api/shutdown" -Headers $H -ContentType 'application/json' -Body '{}' | Out-Null
        $stopped = $proc.WaitForExit(10000)
        ($csp -like "*script-src 'self'*") -and ($denied -eq 401) -and ($count -eq 2) -and $saved -and $stopped
    }
    finally { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force } }
}
