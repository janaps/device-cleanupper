#requires -Version 7.2
<#
    GUI entry point. PowerShell 7's console runs MTA, but WPF needs an STA
    thread, so the wizard is invoked in a dedicated STA runspace. This script
    blocks until the window is closed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$wizard = Join-Path $root 'gui\Wizard.ps1'

if (-not (Test-Path $wizard)) {
    throw "Wizard not found: $wizard"
}

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.ThreadOptions  = 'UseNewThread'
$rs.Open()
$rs.SessionStateProxy.SetVariable('WizardRoot', $root)

$ps = [powershell]::Create()
$ps.Runspace = $rs
[void]$ps.AddScript('& (Join-Path $WizardRoot "gui\Wizard.ps1") -RootPath $WizardRoot')

try {
    $ps.Invoke()
    # print the message, not the record: a XAML parse failure carries the whole
    # file in its error record and Write-Error buries the one useful sentence
    foreach ($e in $ps.Streams.Error) {
        Write-Host "ERROR: $($e.Exception.Message)" -ForegroundColor Red
        if ($e.Exception.InnerException) { Write-Host "  inner: $($e.Exception.InnerException.Message)" -ForegroundColor Red }
        if ($e.InvocationInfo -and $e.InvocationInfo.PositionMessage) { Write-Host $e.InvocationInfo.PositionMessage -ForegroundColor DarkGray }
    }
}
finally {
    $ps.Dispose()
    $rs.Dispose()
}
