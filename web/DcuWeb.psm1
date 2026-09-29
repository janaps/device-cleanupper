<#
    DcuWeb - the local web host for Device CleanUpper.

    A browser front end for the same engine the wizard and the CLI use. It is
    a LOCAL tool, not a service: one pwsh process on the administrator's own
    machine serves the page and a small JSON API on 127.0.0.1, and the Graph
    sign-in is the administrator's own delegated sign-in, exactly as in the
    wizard. Nothing listens on the network.

    How it is put together:

      * the HTTP loop runs on the main thread. Everything slow or that needs
        Graph (sign-in, reading a file, running a step) runs in ONE persistent
        worker runspace - the Graph token lives in the runspace that signed in,
        same as the wizard. One operation at a time; a second one gets 409.
      * the SERVER owns the device list. The browser only ever sends keys,
        step options, the confirmation key and the typed tenant - never device
        rows. A client that could send rows could send any Intune or Autopilot
        id to delete.
      * the worker's log and progress lines are kept as numbered events the
        page polls (GET /api/events?after=N). Polling keeps the loop single
        threaded, and a lost poll loses nothing.
      * the rules are the module's: the page asks for a plan
        (Resolve-DCURunPlan) and runs through Invoke-DCUStep, which checks the
        confirmation key and, for large batches, the typed tenant again.

    Request checks (Test-DCUWebRequest), for every request:
      * the Host header must be 127.0.0.1:<port>   (DNS rebinding)
      * an Origin header, when present, must be this page   (cross-site calls)
      * /api/* needs the per-launch token in X-DCU-Token. The token is handed
        to the page in the URL fragment, which browsers never send to a
        server or put in a Referer.
#>

$ErrorActionPreference = 'Stop'

$script:MaxBodyBytes  = 16MB     # a 10 MB spreadsheet, base64-encoded, plus JSON
$script:MaxUploadBytes = 10MB
$script:MaxEvents     = 5000
$script:UploadTypes   = '.csv', '.txt', '.xlsx', '.xlsm', '.json'
$script:ContentTypes  = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8';  '.svg' = 'image/svg+xml'
}
# no inline script or style, nothing from anywhere else
$script:Csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; " +
              "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------
function New-DCUWebState {
    <# Everything the host keeps between requests. -Token is for tests; a real launch gets a random one. #>
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [int]$Port,
        [string]$Token,
        [string]$ConfigPath = (Join-Path $env:APPDATA 'DeviceCleanUpper\config.json')
    )
    if (-not $Token) { $Token = -join ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32) | ForEach-Object { $_.ToString('x2') }) }

    $state = [pscustomobject]@{
        RootPath       = $RootPath
        StaticRoot     = Join-Path $RootPath 'web\static'
        ModulePath     = Join-Path $RootPath 'modules\DCU\DCU.psd1'
        ModuleRoot     = Join-Path $RootPath 'modules'
        ConfigPath     = $ConfigPath
        Port           = $Port
        Token          = $Token
        Settings       = ConvertTo-DCUSettings $null
        DryRun         = $true            # every launch starts safe; never read from anywhere
        Devices        = @()
        DevicesVersion = 0
        SignIn         = [pscustomobject]@{ SignedIn = $false; Account = ''; TenantId = ''; TenantDomain = ''; Scopes = @(); MissingScopes = @(); Message = 'Not signed in.' }
        Events         = [System.Collections.Generic.List[object]]::new()
        Seq            = 0
        Busy           = $null            # @{ Operation; RunId; Step; Label; Started }
        LastResults    = @{}
        Queue          = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        CancelRef      = [ref]$false
        Runspace       = $null
        Ps             = $null
        Handle         = $null
        Stop           = $false
    }
    try { $state.Settings = Read-DCUSettings -Path $ConfigPath }
    catch { Add-DCUWebEvent $state 'log' @{ Level = 'Warn'; Category = 'Settings'; Message = $_.Exception.Message } }
    $state
}

function Add-DCUWebEvent {
    param($State, [string]$Kind, [hashtable]$Data = @{})
    $State.Seq++
    $e = [ordered]@{ seq = $State.Seq; kind = $Kind; time = (Get-Date).ToString('o') }
    foreach ($k in $Data.Keys) { $e[$k] = $Data[$k] }
    $State.Events.Add([pscustomobject]$e)
    if ($State.Events.Count -gt $script:MaxEvents) { $State.Events.RemoveRange(0, $State.Events.Count - $script:MaxEvents) }
}

function Get-DCUWebWorkFolder {
    param($State)
    if ($State.Settings.WorkFolder) { return $State.Settings.WorkFolder }
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'DeviceCleanUpper'
}

function Get-DCUWebTenantName {
    <# what the administrator types to confirm a large batch: the domain, or the id if it could not be read #>
    param($State)
    if ($State.SignIn.TenantDomain) { [string]$State.SignIn.TenantDomain } else { [string]$State.SignIn.TenantId }
}

function Get-DCUWebSessionArgs {
    param($State, [string]$Step, [hashtable]$Options = @{})
    $sa = @{
        WorkFolder  = Get-DCUWebWorkFolder $State
        DryRun      = [bool]$State.DryRun
        RecentDays  = [int]$State.Settings.RecentDays
        WindowsOnly = [bool]$State.Settings.WindowsOnly
    }
    if ($State.Settings.TenantId) { $sa.TenantId = $State.Settings.TenantId }
    if ($Step) { $sa.StepOptions = @{ $Step = $Options } }
    $sa
}

function Get-DCUWebScopes {
    param($State)
    $a = @{}
    if ($State.Settings.ScopeWipe)      { $a.IncludeWipe = $true }
    if ($State.Settings.ScopeBitLocker) { $a.IncludeBitLocker = $true }
    @(Get-DCURequiredScopes @a)
}

function Save-DCUWebList {
    <#
        Persist the server's list to <WorkFolder>\workingset.json. When the
        change drops devices (a new list, remove, clear), the file it replaces
        is kept next to it first - a batch in progress must not disappear
        because someone pasted a new list.
    #>
    param($State, [switch]$KeepPrevious)
    $folder = Get-DCUWebWorkFolder $State
    $path = Join-Path $folder 'workingset.json'
    try {
        if ($KeepPrevious -and (Test-Path -LiteralPath $path)) {
            $copy = Join-Path $folder ('workingset-before-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
            Copy-Item -LiteralPath $path -Destination $copy
            Add-DCUWebEvent $State 'log' @{ Level = 'Info'; Category = 'WorkingSet'; Message = "The previous list was kept as $copy." }
        }
        $sa = Get-DCUWebSessionArgs $State
        $session = New-DCUSession @sa
        Save-DCUWorkingSet -Devices @($State.Devices) -Path $path -Session $session | Out-Null
    }
    catch {
        Add-DCUWebEvent $State 'log' @{ Level = 'Error'; Category = 'WorkingSet'; Message = "The device list could not be saved to ${path}: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# request checks
# ---------------------------------------------------------------------------
function Test-DCUWebRequest {
    <#
        $null when the request may be served, otherwise { Status; Error }.
        -Headers is a hashtable with lower-case names.
    #>
    param($State, [string]$Path, [hashtable]$Headers)
    $self = "127.0.0.1:$($State.Port)"
    if ([string]$Headers['host'] -ne $self) { return @{ Status = 421; Error = 'Wrong host.' } }
    $origin = [string]$Headers['origin']
    if ($origin -and $origin -ne "http://$self") { return @{ Status = 403; Error = 'Cross-origin requests are not accepted.' } }
    if ([string]$Headers['sec-fetch-site'] -eq 'cross-site') { return @{ Status = 403; Error = 'Cross-site requests are not accepted.' } }
    if ($Path -like '/api/*') {
        $given = [System.Text.Encoding]::UTF8.GetBytes([string]$Headers['x-dcu-token'])
        $want  = [System.Text.Encoding]::UTF8.GetBytes([string]$State.Token)
        if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($given, $want)) {
            return @{ Status = 401; Error = 'Missing or wrong token. Open the link shown in the Device CleanUpper console window.' }
        }
    }
    $null
}

# ---------------------------------------------------------------------------
# routes
# ---------------------------------------------------------------------------
function Reply { param([int]$Status = 200, $Body = @{ ok = $true }) [pscustomobject]@{ Status = $Status; Body = $Body; File = $null } }
function Refuse { param([int]$Status, [string]$Message) Reply $Status @{ error = $Message } }

function Get-DCUWebStateBody {
    param($State)
    $saved = Join-Path (Get-DCUWebWorkFolder $State) 'workingset.json'
    $savedInfo = $null
    if (Test-Path -LiteralPath $saved) {
        try {
            $j = Get-Content -LiteralPath $saved -Raw | ConvertFrom-Json
            $savedInfo = @{ path = $saved; count = @($j.Devices).Count; saved = [string]$j.Saved }
        }
        catch { $savedInfo = @{ path = $saved; count = $null; saved = ''; error = $_.Exception.Message } }
    }
    $requested = @(Get-DCUWebScopes $State)
    [ordered]@{
        dryRun         = [bool]$State.DryRun
        signIn         = $State.SignIn
        requestedScopes = $requested
        missingScopes  = @(if ($State.SignIn.SignedIn) { $requested | Where-Object { $_ -notin @($State.SignIn.Scopes) } })
        tenantName     = Get-DCUWebTenantName $State
        settings       = $State.Settings
        workFolder     = Get-DCUWebWorkFolder $State
        savedList      = $savedInfo
        busy           = $State.Busy
        seq            = $State.Seq
        devicesVersion = $State.DevicesVersion
        deviceCount    = @($State.Devices).Count
        gate           = Get-DCUNavigationGate -Devices @($State.Devices) -SignedIn ([bool]$State.SignIn.SignedIn)
        status         = @(Get-DCUStatus -Devices @($State.Devices) -SignedIn ([bool]$State.SignIn.SignedIn))
        lastResults    = $State.LastResults
    }
}

function Get-DCUWebPlan {
    param($State, [string]$Step, $Selection, $Options)
    Resolve-DCURunPlan -Step $Step -Devices @($State.Devices) -Selection @($Selection | Where-Object { $_ }) `
        -DryRun ([bool]$State.DryRun) -SignedIn ([bool]$State.SignIn.SignedIn) -Options (ConvertTo-DCUWebHashtable $Options) `
        -TenantDomain (Get-DCUWebTenantName $State)
}

function ConvertTo-DCUWebHashtable {
    param($Value)
    if ($null -eq $Value) { return @{} }
    if ($Value -is [hashtable]) { return $Value }
    $h = @{}
    if ($Value -is [System.Collections.IDictionary]) { foreach ($k in $Value.Keys) { $h[[string]$k] = $Value[$k] }; return $h }
    foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h
}

function Invoke-DCUWebRoute {
    <#
        One request in, one reply out: { Status; Body } for JSON, or { File }
        for a static file. No HTTP objects in here, so it can be tested
        without a listener. $Body is the parsed JSON body (a hashtable).
    #>
    param($State, [string]$Method, [string]$Path, [hashtable]$Query = @{}, [hashtable]$Body = @{})

    if ($Method -eq 'GET' -and ($Path -eq '/' -or $Path -eq '/index.html')) {
        return [pscustomobject]@{ Status = 200; Body = $null; File = (Join-Path $State.StaticRoot 'index.html') }
    }
    if ($Method -eq 'GET' -and $Path -match '^/static/([A-Za-z0-9_-]+\.(js|css|svg|html))$') {
        $file = Join-Path $State.StaticRoot $Matches[1]
        if (Test-Path -LiteralPath $file -PathType Leaf) { return [pscustomobject]@{ Status = 200; Body = $null; File = $file } }
        return Refuse 404 'Not found.'
    }
    if ($Path -notlike '/api/*') { return Refuse 404 'Not found.' }

    $busy = [bool]$State.Busy
    $route = "$Method $Path"
    switch ($route) {
        'GET /api/state'   { return Reply 200 (Get-DCUWebStateBody $State) }
        'GET /api/steps'   { return Reply 200 @{ steps = @(Get-DCUStepList) } }
        'GET /api/devices' {
            return Reply 200 @{ version = $State.DevicesVersion; devices = @($State.Devices)
                                safeKeys = @(Get-DCUSafeSelection -Devices @($State.Devices)) }
        }
        'GET /api/events' {
            $after = 0; [void][int]::TryParse([string]$Query['after'], [ref]$after)
            return Reply 200 @{ seq = $State.Seq; busy = $State.Busy; events = @($State.Events | Where-Object { $_.seq -gt $after }) }
        }
    }

    if ($Method -ne 'POST') { return Refuse 405 'Method not allowed.' }

    switch ($route) {
        'POST /api/settings' {
            if ($busy) { return Refuse 409 'Wait until the running operation has finished.' }
            $State.Settings = ConvertTo-DCUSettings $Body.settings
            try { Save-DCUSettings -Path $State.ConfigPath -Settings $State.Settings }
            catch { return Refuse 500 "Your settings could not be saved to $($State.ConfigPath): $($_.Exception.Message)" }
            return Reply 200 (Get-DCUWebStateBody $State)
        }
        'POST /api/mode' {
            if ($busy) { return Refuse 409 'The mode cannot change while something is running.' }
            if ($null -eq $Body.dryRun -or $Body.dryRun -isnot [bool]) { return Refuse 400 'dryRun must be true or false.' }
            $State.DryRun = $Body.dryRun
            Add-DCUWebEvent $State 'log' @{ Level = $(if ($State.DryRun) { 'Info' } else { 'Warn' }); Category = 'Mode'
                Message = $(if ($State.DryRun) { 'Dry run is ON - nothing is changed in the tenant.' } else { 'Dry run is OFF - steps 3 to 7 now change the tenant for real.' }) }
            return Reply 200 (Get-DCUWebStateBody $State)
        }
        'POST /api/signin' {
            if ($busy) { return Refuse 409 'Wait until the running operation has finished.' }
            $extra = @{ Scopes = @(Get-DCUWebScopes $State); TenantId = [string]$State.Settings.TenantId; UseDeviceCode = [bool]$State.Settings.UseDeviceCode }
            return Reply 202 @{ runId = (Start-DCUWebOperation $State 'signin' -Label 'Signing in' -Extra $extra) }
        }
        'POST /api/signout' {
            if ($busy) { return Refuse 409 'Wait until the running operation has finished.' }
            return Reply 202 @{ runId = (Start-DCUWebOperation $State 'signout' -Label 'Signing out') }
        }
        'POST /api/devices/import' {
            if ($busy) { return Refuse 409 'Wait until the running operation has finished.' }
            return Start-DCUWebImport $State $Body
        }
        'POST /api/devices/remove' {
            if ($busy) { return Refuse 409 'The list cannot change while something is running.' }
            $gone = @{}; foreach ($k in @($Body.keys)) { if ($k) { $gone[[string]$k] = $true } }
            if (-not $gone.Count) { return Refuse 400 'No devices given.' }
            $before = @($State.Devices).Count
            $State.Devices = @($State.Devices | Where-Object { -not $gone.ContainsKey([string]$_.Key) })
            $State.DevicesVersion++
            Add-DCUWebEvent $State 'log' @{ Level = 'Info'; Category = 'List'; Message = "Removed $($before - @($State.Devices).Count) device(s) from the list. Nothing in the tenant was touched." }
            Save-DCUWebList $State -KeepPrevious
            return Reply 200 @{ version = $State.DevicesVersion; count = @($State.Devices).Count }
        }
        'POST /api/devices/clear' {
            if ($busy) { return Refuse 409 'The list cannot change while something is running.' }
            $State.Devices = @(); $State.DevicesVersion++; $State.LastResults = @{}
            Add-DCUWebEvent $State 'log' @{ Level = 'Info'; Category = 'List'; Message = 'The list was emptied. Nothing in the tenant was touched.' }
            Save-DCUWebList $State -KeepPrevious
            return Reply 200 @{ version = $State.DevicesVersion; count = 0 }
        }
        'POST /api/plan' {
            if (-not $Body.step) { return Refuse 400 'No step given.' }
            if (-not (Get-DCUStepList | Where-Object Key -eq $Body.step)) { return Refuse 400 "Unknown step: $($Body.step)" }
            try { return Reply 200 (Get-DCUWebPlan $State $Body.step $Body.selection $Body.options) }
            catch { return Refuse 400 $_.Exception.Message }
        }
        'POST /api/run' {
            if ($busy) { return Refuse 409 'Wait until the running operation has finished.' }
            return Start-DCUWebRun $State $Body
        }
        'POST /api/cancel' {
            if (-not $busy) { return Reply 200 @{ ok = $true; running = $false } }
            $State.CancelRef.Value = $true
            Add-DCUWebEvent $State 'log' @{ Level = 'Warn'; Category = 'Run'; Message = 'Cancelling... (a delete that was already sent is not undone)' }
            return Reply 200 @{ ok = $true; running = $true }
        }
        'POST /api/open-folder' {
            $folder = Get-DCUWebWorkFolder $State
            if (-not (Test-Path -LiteralPath $folder)) { return Refuse 404 "Not created yet: $folder" }
            Start-Process explorer.exe -ArgumentList "`"$folder`""
            return Reply 200 @{ ok = $true; path = $folder }
        }
        'POST /api/shutdown' {
            if ($busy) { return Refuse 409 'Something is running - cancel it or wait before you quit.' }
            $State.Stop = $true
            return Reply 200 @{ ok = $true }
        }
    }
    Refuse 404 'Not found.'
}

function Start-DCUWebImport {
    param($State, [hashtable]$Body)
    $append = [bool]$Body.append
    $extra = @{ Source = [string]$Body.source }
    switch ($Body.source) {
        'text' {
            if (-not ([string]$Body.text).Trim()) { return Refuse 400 'Paste something first.' }
            $extra.Text = [string]$Body.text
        }
        'rows' {
            $rows = @(foreach ($r in @($Body.rows)) {
                $h = ConvertTo-DCUWebHashtable $r
                if (([string]$h.Serial).Trim() -or ([string]$h.Name).Trim()) {
                    [pscustomobject]@{ Serial = [string]$h.Serial; Name = [string]$h.Name; Note = [string]$h.Note }
                }
            })
            if (-not $rows.Count) { return Refuse 400 'Type at least one serial number or device name.' }
            $extra.Rows = $rows
        }
        'file' {
            $ext = [IO.Path]::GetExtension([string]$Body.fileName).ToLowerInvariant()
            if ($ext -notin $script:UploadTypes) { return Refuse 400 "Only $($script:UploadTypes -join ', ') files can be read." }
            try { $bytes = [Convert]::FromBase64String([string]$Body.fileBase64) } catch { return Refuse 400 'The file did not arrive intact - try again.' }
            if (-not $bytes.Length) { return Refuse 400 'The file is empty.' }
            if ($bytes.Length -gt $script:MaxUploadBytes) { return Refuse 413 'The file is larger than 10 MB.' }
            # the name the browser sent is only used for its extension - never as a path
            $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dcu-upload-{0}{1}" -f [guid]::NewGuid().ToString('N'), $ext)
            [IO.File]::WriteAllBytes($tmp, $bytes)
            $extra.Path = $tmp; $extra.TempFile = $tmp; $extra.DisplayName = [IO.Path]::GetFileName([string]$Body.fileName)
            $extra.IsSavedList = ($ext -eq '.json')
            foreach ($k in 'sheet', 'serialColumn', 'nameColumn', 'noteColumn') { $extra[$k] = [string]$Body[$k] }
        }
        'saved' {
            $path = Join-Path (Get-DCUWebWorkFolder $State) 'workingset.json'
            if (-not (Test-Path -LiteralPath $path)) { return Refuse 404 'There is no saved list in the working folder.' }
            $extra.Path = $path; $extra.IsSavedList = $true
        }
        default { return Refuse 400 'Unknown source - use text, rows, file or saved.' }
    }
    # a saved list carries how far every device got, so it replaces the list
    $extra.Append = $append -and -not $extra.IsSavedList
    $existing = if ($extra.Append) { @($State.Devices) } else { @() }
    Reply 202 @{ runId = (Start-DCUWebOperation $State 'import' -Label 'Reading the device list' -Devices $existing -Extra $extra) }
}

function Start-DCUWebRun {
    <#
        Checks here are for a quick, clear answer; Invoke-DCUStep in the
        worker checks the confirmation and the typed tenant again against the
        real sign-in, and it is the one that decides.
    #>
    param($State, [hashtable]$Body)
    $step = [string]$Body.step
    if (-not (Get-DCUStepList | Where-Object Key -eq $step)) { return Refuse 400 "Unknown step: $step" }
    $options = ConvertTo-DCUWebHashtable $Body.options
    try { $plan = Get-DCUWebPlan $State $step $Body.selection $options } catch { return Refuse 400 $_.Exception.Message }
    if (-not $plan.CanRun) { return Refuse 409 $plan.BlockedReason }
    if ($plan.RequiresConfirmation -and [string]$Body.confirmationKey -ne $plan.ConfirmationKey) {
        return Refuse 409 'The list, the selection or the options changed since you confirmed. Nothing was changed - review and confirm again.'
    }
    $typed = ([string]$Body.tenantConfirmation).Trim()
    if ($plan.RequiresTypedConfirmation -and $typed -notin @($State.SignIn.TenantDomain, $State.SignIn.TenantId | Where-Object { $_ })) {
        return Refuse 400 "Type the tenant ($($plan.TypedConfirmationText)) to confirm a run on $($plan.TargetCount) devices."
    }

    # the ticks travel with the list, so a saved list and a reload keep them
    if ($plan.Scope -eq 'Selection') {
        $want = @{}; foreach ($k in $plan.Targets) { $want[$k] = $true }
        foreach ($d in $State.Devices) { $d.Apply = $want.ContainsKey([string]$d.Key) }
    }
    $extra = @{ Step = $step; Selection = @($plan.Targets); ConfirmationKey = [string]$Body.confirmationKey; TenantConfirmation = $typed
                SessionArgs = (Get-DCUWebSessionArgs $State $step $options) }
    $verb = if ($plan.Effect -ne 'ReadOnly' -and $plan.DryRun) { 'Simulating' } else { 'Running' }
    Reply 202 @{ runId = (Start-DCUWebOperation $State 'step' -Step $step -Label "$verb $($plan.Name) on $($plan.TargetCount) device(s)" `
                                -Devices @($State.Devices) -Extra $extra) }
}

# ---------------------------------------------------------------------------
# the worker
# ---------------------------------------------------------------------------
$script:WorkerScript = {
    param($ModulePath, $ModuleRoot, $Queue, $CancelRef, $Operation, $SessionArgs, $Devices, $Extra)

    $env:PSModulePath = "$ModuleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    if (-not (Get-Module -Name DCU)) { Import-Module $ModulePath -Force }
    Register-DCULogSink      { param($e) $Queue.Enqueue([pscustomobject]@{ Kind = 'log';      Payload = $e }) }
    Register-DCUProgressSink { param($p) $Queue.Enqueue([pscustomobject]@{ Kind = 'progress'; Payload = $p }) }
    Set-DCUCancelToken $CancelRef

    try {
        $session = New-DCUSession @SessionArgs
        switch ($Operation) {
            'signin' {
                $connect = @{ Scopes = @($Extra.Scopes); Force = $true }
                if ($Extra.TenantId)      { $connect.TenantId = $Extra.TenantId }
                if ($Extra.UseDeviceCode) { $connect.UseDeviceCode = $true }
                Connect-DCUGraph @connect | Out-Null
                $Queue.Enqueue([pscustomobject]@{ Kind = 'signin'; Payload = (Get-DCUSignInState -Scopes @($Extra.Scopes)) })
            }
            'signout' {
                Disconnect-DCUGraph
                $Queue.Enqueue([pscustomobject]@{ Kind = 'signin'; Payload = (Get-DCUSignInState) })
            }
            'import' {
                $r = if ($Extra.IsSavedList) {
                    $rows = @(Import-DCUWorkingSet -Path $Extra.Path)
                    [pscustomobject]@{ Step = 'DeviceInput'; Source = $(if ($Extra.DisplayName) { $Extra.DisplayName } else { 'the saved list' })
                                       Added = $rows.Count; Duplicates = 0; Unclassified = 0; Total = $rows.Count; Rows = $rows }
                }
                elseif ($Extra.Source -eq 'text') { Import-DCUDeviceList -Text $Extra.Text -Existing @($Devices) -Session $session }
                elseif ($Extra.Source -eq 'rows') { Import-DCUDeviceList -Rows @($Extra.Rows) -Existing @($Devices) -Session $session }
                else {
                    $r2 = Import-DCUDeviceList -Path $Extra.Path -Sheet $Extra.sheet -Existing @($Devices) -Session $session `
                        -SerialColumn $Extra.serialColumn -NameColumn $Extra.nameColumn -NoteColumn $Extra.noteColumn
                    $r2.Source = $Extra.DisplayName
                    $r2
                }
                $Queue.Enqueue([pscustomobject]@{ Kind = 'done'; Payload = $r })
            }
            'step' {
                $summary = Invoke-DCUStep -Step $Extra.Step -Session $session -Devices @($Devices) -Selection @($Extra.Selection) `
                    -ConfirmationKey $Extra.ConfirmationKey -TenantConfirmation $Extra.TenantConfirmation
                $Queue.Enqueue([pscustomobject]@{ Kind = 'done'; Payload = $summary })
            }
        }
    }
    catch [System.OperationCanceledException] { $Queue.Enqueue([pscustomobject]@{ Kind = 'cancelled' }) }
    catch { $Queue.Enqueue([pscustomobject]@{ Kind = 'error'; Payload = $_.Exception.Message }) }
    finally {
        if ($Extra.TempFile) { Remove-Item -LiteralPath $Extra.TempFile -Force -ErrorAction SilentlyContinue }
        Clear-DCUSinks
        $Queue.Enqueue([pscustomobject]@{ Kind = 'complete' })
    }
}

function Start-DCUWebOperation {
    param($State, [string]$Operation, [string]$Label, [string]$Step, [object[]]$Devices = @(), [hashtable]$Extra = @{})
    if (-not $State.Runspace) {
        # STA + ReuseThread, as in the wizard: the interactive sign-in wants an STA
        # thread, and the token stays with the runspace that signed in
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $State.Runspace = $rs
    }
    $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $sessionArgs = if ($Extra.SessionArgs) { $Extra.SessionArgs } else { Get-DCUWebSessionArgs $State }
    $State.CancelRef.Value = $false
    # the worker gets copies: it must never share a row object with the list the server serves
    # (and skip $null: an empty list from an if-expression binds as @($null))
    $copies = @($Devices | Where-Object { $null -ne $_ } | ForEach-Object { $_.PSObject.Copy() })

    $ps = [powershell]::Create()
    $ps.Runspace = $State.Runspace
    [void]$ps.AddScript($script:WorkerScript).AddArgument($State.ModulePath).AddArgument($State.ModuleRoot).
        AddArgument($State.Queue).AddArgument($State.CancelRef).AddArgument($Operation).AddArgument($sessionArgs).
        AddArgument($copies).AddArgument($Extra)
    $State.Ps = $ps
    $State.Busy = [pscustomobject]@{ operation = $Operation; runId = $runId; step = $Step; label = $Label; started = (Get-Date).ToString('o')
                                     append = [bool]$Extra.Append }
    Add-DCUWebEvent $State 'start' @{ runId = $runId; operation = $Operation; step = $Step; label = $Label }
    $State.Handle = $ps.BeginInvoke()
    $runId
}

function Sync-DCUWebWorker {
    <# Move what the worker reported into events and state. Called between requests. #>
    param($State)
    $item = $null
    while ($State.Queue.TryDequeue([ref]$item)) {
        switch ($item.Kind) {
            'log' {
                $e = $item.Payload
                Add-DCUWebEvent $State 'log' @{ Level = [string]$e.Level; Category = [string]$e.Category; Message = [string]$e.Message }
            }
            'progress' {
                $p = $item.Payload
                Add-DCUWebEvent $State 'progress' @{ Activity = [string]$p.Activity; Status = [string]$p.Status; Percent = [int]$p.PercentComplete
                                                     Id = [int]$p.Id; Completed = [bool]$p.Completed; Live = [bool]$p.Live }
            }
            'signin' {
                $s = $item.Payload
                $State.SignIn = [pscustomobject]@{ SignedIn = [bool]$s.SignedIn; Account = [string]$s.Account; TenantId = [string]$s.TenantId
                    TenantDomain = [string]$s.TenantDomain; Scopes = @($s.Scopes); MissingScopes = @($s.MissingScopes); Message = [string]$s.Message }
                Add-DCUWebEvent $State 'signin' @{ SignedIn = $State.SignIn.SignedIn }
            }
            'done' {
                $p = $item.Payload
                if ($p.PSObject.Properties['Rows']) {
                    $State.Devices = @($p.Rows)
                    $State.DevicesVersion++
                }
                $summary = [ordered]@{}
                foreach ($prop in $p.PSObject.Properties) { if ($prop.Name -ne 'Rows') { $summary[$prop.Name] = $prop.Value } }
                $step = [string]$p.Step
                $State.LastResults[$step] = [pscustomobject]$summary
                if ($State.Busy -and $State.Busy.operation -eq 'import') {
                    # an import is not a step run - the host saves the list itself,
                    # keeping the old file when the new list replaced it
                    Save-DCUWebList $State -KeepPrevious:(-not $State.Busy.append)
                }
                Add-DCUWebEvent $State 'result' @{ step = $step; summary = [pscustomobject]$summary }
            }
            'cancelled' { Add-DCUWebEvent $State 'cancelled' @{ Message = 'Cancelled.' } }
            'error'     { Add-DCUWebEvent $State 'error' @{ Message = [string]$item.Payload } }
            'complete'  {
                if ($State.Ps) {
                    try { $State.Ps.EndInvoke($State.Handle) } catch { Add-DCUWebEvent $State 'error' @{ Message = $_.Exception.Message } }
                    $State.Ps.Dispose(); $State.Ps = $null
                }
                $done = $State.Busy
                $State.Busy = $null
                Add-DCUWebEvent $State 'idle' @{ runId = $(if ($done) { $done.runId }); operation = $(if ($done) { $done.operation }) }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
function Send-DCUWebReply {
    param($Context, $Reply)
    $res = $Context.Response
    $res.Headers['Content-Security-Policy'] = $script:Csp
    $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Referrer-Policy'] = 'no-referrer'
    $res.Headers['X-Frame-Options'] = 'DENY'
    $res.Headers['Cache-Control'] = 'no-store'
    $res.StatusCode = $Reply.Status
    if ($Reply.File) {
        $ext = [IO.Path]::GetExtension($Reply.File).ToLowerInvariant()
        $res.ContentType = $script:ContentTypes[$ext]
        $bytes = [IO.File]::ReadAllBytes($Reply.File)
    }
    else {
        $res.ContentType = 'application/json; charset=utf-8'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Reply.Body | ConvertTo-Json -Depth 10 -Compress))
    }
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Invoke-DCUWebContext {
    param($State, $Context)
    $req = $Context.Request
    try {
        $headers = @{}
        foreach ($k in $req.Headers.AllKeys) { $headers[$k.ToLowerInvariant()] = $req.Headers[$k] }
        $path = $req.Url.AbsolutePath
        $denied = Test-DCUWebRequest $State $path $headers
        if ($denied) { Send-DCUWebReply $Context (Refuse $denied.Status $denied.Error); return }

        $query = @{}
        foreach ($k in $req.QueryString.AllKeys) { if ($k) { $query[$k] = $req.QueryString[$k] } }
        $body = @{}
        if ($req.HttpMethod -eq 'POST') {
            if ($req.ContentLength64 -gt $script:MaxBodyBytes) { Send-DCUWebReply $Context (Refuse 413 'The request is too large.'); return }
            if ($req.ContentType -notlike 'application/json*') { Send-DCUWebReply $Context (Refuse 415 'Send JSON.'); return }
            $reader = [IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd(); $reader.Dispose()
            if ($text.Trim()) {
                try { $body = $text | ConvertFrom-Json -AsHashtable -Depth 20 } catch { Send-DCUWebReply $Context (Refuse 400 'The request body is not valid JSON.'); return }
            }
        }
        $reply = Invoke-DCUWebRoute $State $req.HttpMethod $path $query $body
        Send-DCUWebReply $Context $reply
    }
    catch {
        try { Send-DCUWebReply $Context (Refuse 500 $_.Exception.Message) } catch { }
        Add-DCUWebEvent $State 'log' @{ Level = 'Error'; Category = 'Web'; Message = "$($req.HttpMethod) $($req.Url.AbsolutePath): $($_.Exception.Message)" }
    }
    finally { try { $Context.Response.Close() } catch { } }
}

function Start-DCUWebServer {
    <#
        .SYNOPSIS
            Serve the page on 127.0.0.1 until Quit is pressed in the page or the
            console window gets Ctrl+C. Blocks.
        .PARAMETER UrlFile
            Write the page's URL (with the token) to this file once listening -
            for tests that start the server in another process.
    #>
    param($State, [switch]$OpenBrowser, [string]$UrlFile)

    if (-not $State.Port) {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start(); $State.Port = $probe.LocalEndpoint.Port; $probe.Stop()
    }
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$($State.Port)/")
    $listener.Start()

    # the main thread's module instance logs too (saving the list); route it to the page
    Register-DCULogSink { param($e) Add-DCUWebEvent $State 'log' @{ Level = [string]$e.Level; Category = [string]$e.Category; Message = [string]$e.Message } }

    $url = "http://127.0.0.1:$($State.Port)/#token=$($State.Token)"
    Write-Host ''
    Write-Host 'Device CleanUpper is running on this computer only.' -ForegroundColor Cyan
    Write-Host "Open: $url"
    Write-Host 'Keep this window open while you work. Quit in the page, or Ctrl+C here, stops it.' -ForegroundColor DarkGray
    Write-Host ''
    if ($UrlFile) { Set-Content -LiteralPath $UrlFile -Value $url -Encoding UTF8 }
    if ($OpenBrowser) { Start-Process $url }

    try {
        while (-not $State.Stop) {
            $task = $listener.GetContextAsync()
            while (-not $task.Wait(200)) {
                Sync-DCUWebWorker $State
                if ($State.Stop) { break }
            }
            if (-not $task.IsCompleted) { break }
            Sync-DCUWebWorker $State
            Invoke-DCUWebContext $State $task.Result
        }
    }
    finally {
        if ($State.Busy) { $State.CancelRef.Value = $true }
        $listener.Stop(); $listener.Close()
        Clear-DCUSinks
        if ($State.Runspace) { try { $State.Runspace.Close(); $State.Runspace.Dispose() } catch { } }
        Write-Host 'Device CleanUpper stopped.' -ForegroundColor Cyan
    }
}

Export-ModuleMember -Function New-DCUWebState, Test-DCUWebRequest, Invoke-DCUWebRoute, Start-DCUWebServer, Sync-DCUWebWorker, Add-DCUWebEvent
