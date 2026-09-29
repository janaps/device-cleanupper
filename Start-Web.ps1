#requires -Version 7.2
<#
    Web front end entry point: serves Device CleanUpper to a browser on this
    computer only (127.0.0.1), and opens it. Blocks until Quit is pressed in
    the page or Ctrl+C is pressed here.

    Same engine, same rules and same delegated sign-in as the wizard - see
    web\DcuWeb.psm1 for how the host is put together.
#>
[CmdletBinding()]
param(
    # Do not open a browser (the URL is printed either way).
    [switch]$NoBrowser,

    # A fixed port instead of a free one picked at random.
    [int]$Port,

    # Write the URL, with its token, to this file once listening (tests).
    [string]$UrlFile,

    # Another settings file than %APPDATA%\DeviceCleanUpper\config.json -
    # tests use it to keep away from a real working folder.
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$env:PSModulePath = "$PSScriptRoot\modules$([IO.Path]::PathSeparator)$env:PSModulePath"
Import-Module (Join-Path $PSScriptRoot 'modules\DCU\DCU.psd1') -Force
Import-Module (Join-Path $PSScriptRoot 'web\DcuWeb.psm1') -Force

$stateArgs = @{ RootPath = $PSScriptRoot; Port = $Port }
if ($ConfigPath) { $stateArgs.ConfigPath = $ConfigPath }
$state = New-DCUWebState @stateArgs
Start-DCUWebServer -State $state -OpenBrowser:(-not $NoBrowser) -UrlFile $UrlFile
