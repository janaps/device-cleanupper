<#
    Delegated (user based) authentication.

    Deliberately NOT app-only: every delete in this tool is destructive and
    irreversible, so it runs as the signed-in administrator and shows up in the
    tenant audit log under their name. That also means the tenant's own
    Conditional Access / MFA / PIM rules apply, and an admin who is not allowed
    to delete devices simply gets an access-denied from Graph.

    Scope sets are built per feature: the base set is enough to look devices up
    and remove them, and the two sensitive extras (wipe, BitLocker recovery
    keys) are only requested when the wizard has those features switched on -
    asking for them always would make consent harder than it needs to be.
#>

$script:DCUScopeSets = [ordered]@{
    Base      = @(
        'DeviceManagementManagedDevices.ReadWrite.All'   # read + delete Intune devices
        'DeviceManagementServiceConfig.ReadWrite.All'    # Windows Autopilot device identities
        'Device.ReadWrite.All'                           # Entra ID device objects
        'Directory.Read.All'                             # device sign-in activity, trust type
    )
    Wipe      = @('DeviceManagementManagedDevices.PrivilegedOperations.All')
    BitLocker = @('BitLockerKey.Read.All')
}

$script:TenantDomainCache   = $null
$script:TenantDomainCacheId = $null

function Get-DCURequiredScopes {
    <#
        .SYNOPSIS
            The delegated Graph scopes this tool signs in with.
        .DESCRIPTION
            Base scopes are always included. -IncludeWipe adds the privileged
            operation scope needed for wipe/retire; -IncludeBitLocker adds the
            scope needed to read BitLocker recovery keys.
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeWipe,
        [switch]$IncludeBitLocker
    )
    $scopes = @($script:DCUScopeSets.Base)
    if ($IncludeWipe)      { $scopes += $script:DCUScopeSets.Wipe }
    if ($IncludeBitLocker) { $scopes += $script:DCUScopeSets.BitLocker }
    @($scopes | Select-Object -Unique)
}

function Connect-DCUGraph {
    <#
        .SYNOPSIS
            Interactive sign-in to Microsoft Graph as the administrator.
        .DESCRIPTION
            Opens the browser sign-in (or a device code, with -UseDeviceCode)
            and returns the resulting connection state. Safe to call again: if
            the current context already covers the requested scopes and tenant,
            nothing happens unless -Force is given.
        .PARAMETER TenantId
            Optional tenant id or domain, to make sure the sign-in lands in the
            tenant the devices are being released FROM.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Scopes,
        [string]$TenantId,
        [switch]$UseDeviceCode,
        [switch]$Force
    )

    Assert-DCUGraphModule
    if (-not $Scopes -or $Scopes.Count -eq 0) { $Scopes = Get-DCURequiredScopes }

    $state = Get-DCUSignInState -Scopes $Scopes
    if (-not $Force -and $state.SignedIn -and -not $state.MissingScopes -and
        (-not $TenantId -or $state.TenantId -eq $TenantId -or $state.TenantDomain -eq $TenantId)) {
        Write-DCULog -Level Info -Category 'Auth' -Message "Already signed in as $($state.Account) in $($state.TenantDomain)."
        return $state
    }

    $connect = @{ Scopes = $Scopes; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($TenantId)      { $connect.TenantId = $TenantId }
    if ($UseDeviceCode) { $connect.UseDeviceAuthentication = $true }

    $how = if ($UseDeviceCode) { 'device code' } else { 'browser' }
    Write-DCULog -Level Info -Category 'Auth' -Message ("Signing in to Microsoft Graph ({0}). Scopes: {1}" -f $how, ($Scopes -join ', '))
    if ($UseDeviceCode) {
        Write-DCULog -Level Warn -Category 'Auth' -Message 'Device code sign-in: the code is printed in the console window behind this one.'
    }

    Connect-MgGraph @connect | Out-Null

    $script:TenantDomainCache = $null
    $state = Get-DCUSignInState -Scopes $Scopes
    if (-not $state.SignedIn) { throw 'Sign-in did not complete.' }
    Write-DCULog -Level Success -Category 'Auth' -Message "Signed in as $($state.Account) - tenant $($state.TenantDomain) ($($state.TenantId))."
    if ($state.MissingScopes) {
        Write-DCULog -Level Warn -Category 'Auth' -Message "Consent is missing for: $($state.MissingScopes -join ', '). Steps that need those will fail with access denied."
    }
    $state
}

function Disconnect-DCUGraph {
    [CmdletBinding()]
    param()
    try {
        if (Get-Module -Name Microsoft.Graph.Authentication) {
            if (Get-MgContext -ErrorAction SilentlyContinue) {
                Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
                Write-DCULog -Level Info -Category 'Auth' -Message 'Signed out of Microsoft Graph.'
            }
        }
    }
    catch { }
    $script:IntuneDevices = $null; $script:AutopilotDevices = $null; $script:EntraDevices = $null
    $script:TenantDomainCache = $null
}

function Get-DCUSignInState {
    <#
        .SYNOPSIS
            Who is signed in, in which tenant, with which scopes.
        .DESCRIPTION
            Pure read - never triggers a sign-in, so the GUI can call it on
            every page build. Returns SignedIn=$false when the Graph module is
            not loaded or no context exists. TenantDomain costs one Graph read
            (/organization) and is cached per tenant id.
    #>
    [CmdletBinding()]
    param([string[]]$Scopes)

    $result = [pscustomobject]@{
        SignedIn      = $false
        Account       = ''
        TenantId      = ''
        TenantDomain  = ''
        Scopes        = @()
        MissingScopes = @()
        Message       = 'Not signed in.'
    }

    if (-not (Get-Module -Name Microsoft.Graph.Authentication) -and
        -not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        $result.Message = 'Microsoft.Graph.Authentication is not installed. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
        return $result
    }
    try { Assert-DCUGraphModule } catch { $result.Message = $_.Exception.Message; return $result }

    $ctx = try { Get-MgContext -ErrorAction Stop } catch { $null }
    if (-not $ctx) { return $result }

    $result.SignedIn = $true
    $result.Account  = [string]$ctx.Account
    $result.TenantId = [string]$ctx.TenantId
    $result.Scopes   = @($ctx.Scopes)

    if (-not $Scopes -or $Scopes.Count -eq 0) { $Scopes = Get-DCURequiredScopes }
    $result.MissingScopes = @($Scopes | Where-Object { $_ -notin $result.Scopes })

    if ($script:TenantDomainCache -and $script:TenantDomainCacheId -eq $result.TenantId) {
        $result.TenantDomain = $script:TenantDomainCache
    }
    else {
        try {
            $org = Invoke-DCUGraph -Uri 'v1.0/organization?$select=id,displayName,verifiedDomains'
            $o = @($org.value)[0]
            $initial = @($o.verifiedDomains | Where-Object { $_.isInitial }) | Select-Object -First 1
            $result.TenantDomain = if ($initial) { [string]$initial.name } else { [string]$o.displayName }
            $script:TenantDomainCache   = $result.TenantDomain
            $script:TenantDomainCacheId = $result.TenantId
        }
        catch { }
    }

    $result.Message = "Signed in as $($result.Account)" + $(if ($result.TenantDomain) { " - $($result.TenantDomain)" } else { '' })
    if ($result.MissingScopes) { $result.Message += " (missing consent: $($result.MissingScopes -join ', '))" }
    $result
}

function Assert-DCUSignedIn {
    <# Every step calls this first - a clear message beats a Graph 401. #>
    $state = Get-DCUSignInState
    if (-not $state.SignedIn) {
        throw 'Not signed in to Microsoft Graph. Sign in on the Setup page (or run Connect-DCUGraph) first.'
    }
    $state
}
