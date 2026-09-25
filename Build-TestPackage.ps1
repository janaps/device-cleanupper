#requires -Version 7.2
<#
.SYNOPSIS
    Build a zip of the Device CleanUpper: a release download, or a package
    for a test user.

.DESCRIPTION
    The package is built from a COMMIT, not from the working folder, so it
    holds exactly the code that was committed. Uncommitted edits are left out
    and reported. Steps:

      1. export the project folder at -Ref with git archive
      2. run the smoke tests and the wizard self-test on that export
      3. drop what a user does not need (the tests, this script, .github)
      4. bundle Microsoft.Graph.Authentication into modules\ - the DCU module
         prefers that copy, so a tester does not have to install it - and
      5. check that the packaged module really loads the bundled copy
         (4 and 5 are skipped with -NoGraphModule: use that for a PUBLIC
         download - the Graph module is Microsoft's, not ours to redistribute)
      6. write VERSION.txt and zip it all as dist\DeviceCleanUpper-<name>.zip

    With -Tag the commit also gets an annotated git tag, so a bug report can
    be traced back to the exact code. The tag is local; push it yourself if
    the repository is shared.

.EXAMPLE
    .\Build-TestPackage.ps1 -Tag dcu-test-1

.EXAMPLE
    .\Build-TestPackage.ps1 -Tag v1.0.0 -NoGraphModule
    # the public release download: users install the Graph module themselves

.EXAMPLE
    .\Build-TestPackage.ps1 -Ref dcu-autopilot-sync-fixes
    # no tag: the zip is named after the short commit id
#>
[CmdletBinding()]
param(
    # The commit, branch or tag to package.
    [string]$Ref = 'HEAD',

    # Annotated tag to put on that commit; the zip is named after it.
    [string]$Tag,

    # Which Microsoft.Graph.Authentication to bundle. Default: the newest one
    # installed on this machine, or the newest on the PowerShell Gallery.
    [version]$GraphModuleVersion,

    # Leave Microsoft.Graph.Authentication out - for a public download.
    [switch]$NoGraphModule,

    [string]$OutputFolder = (Join-Path $PSScriptRoot 'dist'),

    # Skip the smoke tests and the wizard self-test on the export.
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Git {
    # git from this folder, so a path argument is relative to the project folder
    $out = & git -C $PSScriptRoot @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE) { throw "git $($args -join ' ') failed: $($out -join ' ')" }
    $out
}

function Write-Step { param([string]$Text) Write-Host "--> $Text" -ForegroundColor Cyan }

# --- what to package --------------------------------------------------------
$repo    = [string](Invoke-Git rev-parse --show-toplevel)
$sha     = [string](Invoke-Git rev-parse --verify "$Ref^{commit}")
$short   = [string](Invoke-Git rev-parse --short $sha)
$prefix  = ([string](Invoke-Git rev-parse --show-prefix)).TrimEnd('/')    # '' at a repo root, 'deviceCleanUpper' inside a bigger repo
$date    = [string](Invoke-Git show -s --format=%ci $sha)
$subject = [string](Invoke-Git show -s --format=%s $sha)
$name    = if ($Tag) { "DeviceCleanUpper-$Tag" } else { "DeviceCleanUpper-$short" }

Write-Step "Packaging $(if ($prefix) { $prefix } else { 'Device CleanUpper' }) at $short - $subject"

$headSha = [string](Invoke-Git rev-parse HEAD)
if ($sha -eq $headSha) {
    $dirty = @(Invoke-Git status --porcelain -- . | Where-Object { $_ })
    if ($dirty.Count) {
        Write-Warning "$($dirty.Count) uncommitted change(s) in $prefix are NOT in this package - commit them first if they should be:"
        $dirty | ForEach-Object { Write-Warning "  $_" }
    }
}

if ($Tag) {
    $existing = & git -C $PSScriptRoot rev-parse -q --verify "refs/tags/$Tag^{commit}" 2>$null
    if ($existing) {
        if ("$existing" -ne $sha) { throw "Tag $Tag already exists on another commit ($("$existing".Substring(0, 7))). Pick a new tag name." }
        Write-Step "Tag $Tag is already on this commit"
    }
    else {
        Invoke-Git tag -a $Tag -m "Device CleanUpper $Tag" $sha | Out-Null
        Write-Step "Tagged $short as $Tag"
    }
}

# --- export -----------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) "dcu-package-$short-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
$pkg  = Join-Path $work 'DeviceCleanUpper'
New-Item -ItemType Directory -Path $pkg -Force | Out-Null

try {
    Write-Step 'Exporting the committed files'
    $archive = Join-Path $work 'export.zip'
    # from the repository root: run from a subfolder, git archive keeps only the
    # paths under that subfolder - inside the subtree it was already given,
    # which leaves nothing at all
    & git -C $repo archive --format=zip -o $archive "${sha}:$prefix" 2>&1 | Out-Null
    if ($LASTEXITCODE) { throw "git archive failed for ${sha}:$prefix" }
    Expand-Archive -LiteralPath $archive -DestinationPath $pkg
    Remove-Item -LiteralPath $archive
    if (-not (Test-Path -LiteralPath (Join-Path $pkg 'modules\DCU\DCU.psd1'))) {
        throw "The export of ${short}:$prefix is empty or incomplete - no package built."
    }

    # --- test the export, not the working folder ----------------------------
    if (-not $SkipTests) {
        Write-Step 'Running the smoke tests on the export'
        $smoke = pwsh -NoProfile -File (Join-Path $pkg 'modules\DCU\tests\Run-SmokeTests.ps1') 2>&1
        if ($LASTEXITCODE) {
            $failed = @($smoke | Select-String 'FAIL')
            $show = if ($failed.Count) { $failed } else { $smoke | Select-Object -Last 15 }
            $show | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            throw 'The smoke tests failed on the export - no package built.'
        }

        Write-Step 'Running the wizard self-test on the export'
        $wizard = Join-Path $pkg 'gui\Wizard.ps1'
        $self = pwsh -NoProfile -Command "& {
            `$rs = [runspacefactory]::CreateRunspace(); `$rs.ApartmentState = 'STA'; `$rs.Open()
            `$ps = [powershell]::Create(); `$ps.Runspace = `$rs
            [void]`$ps.AddScript('`$env:DCU_WIZARD_SELFTEST = ''1''; & ''$wizard'' -RootPath ''$pkg''')
            `$ps.Invoke()
            `$ps.Streams.Error | ForEach-Object { 'ERROR: ' + `$_.Exception.Message }
        }" 2>&1
        $bad = @($self | Where-Object { "$_" -like 'ERROR:*' })
        if ($bad.Count -or -not ($self -match 'SELF-TEST: window built')) {
            $bad | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            throw 'The wizard self-test failed on the export - no package built.'
        }
    }

    # --- what a tester does not need ----------------------------------------
    foreach ($p in 'modules\DCU\tests', 'Build-TestPackage.ps1', '.gitignore', '.github') {
        $full = Join-Path $pkg $p
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    }

    # --- bundle Microsoft.Graph.Authentication ------------------------------
    $graphVersion = $null
    if ($NoGraphModule) {
        Write-Step 'Leaving Microsoft.Graph.Authentication out (-NoGraphModule)'
    }
    else {
        $graphRoot = Join-Path $pkg 'modules\Microsoft.Graph.Authentication'
        $installed = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication | Sort-Object Version -Descending)
        $graph = if ($GraphModuleVersion) { $installed | Where-Object Version -eq $GraphModuleVersion | Select-Object -First 1 }
                 else { $installed | Select-Object -First 1 }
        if ($graph) {
            Write-Step "Bundling Microsoft.Graph.Authentication $($graph.Version) (installed copy)"
            Copy-Item -LiteralPath $graph.ModuleBase -Destination (Join-Path $graphRoot $graph.Version) -Recurse
            $graphVersion = $graph.Version
        }
        else {
            Write-Step "Bundling Microsoft.Graph.Authentication $(if ($GraphModuleVersion) { $GraphModuleVersion } else { '(newest)' }) from the PowerShell Gallery"
            $save = @{ Name = 'Microsoft.Graph.Authentication'; Path = (Join-Path $pkg 'modules'); Repository = 'PSGallery' }
            if ($GraphModuleVersion) { $save.RequiredVersion = $GraphModuleVersion }
            Save-Module @save
            $graphVersion = (Get-ChildItem -LiteralPath $graphRoot -Directory | Select-Object -First 1).Name
        }

        # the packaged module must pick up the bundled copy, not one on this machine.
        # Asked from inside the DCU module: it imports Graph into its own scope,
        # where a Get-Module from outside does not see it.
        $loaded = pwsh -NoProfile -Command "Import-Module '$pkg\modules\DCU\DCU.psd1'; & (Get-Module DCU) { Assert-DCUGraphModule; (Get-Module Microsoft.Graph.Authentication).ModuleBase }" 2>&1 |
            Select-Object -Last 1
        if (-not "$loaded".StartsWith($graphRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The packaged module did not load the bundled Graph module (it loaded: $loaded)."
        }
    }

    # --- VERSION.txt + zip --------------------------------------------------
    $graphLine = if ($graphVersion) { "Microsoft.Graph.Authentication $graphVersion (bundled in modules\)" }
                 else { 'not included - Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' }
    @(
        'Device CleanUpper'
        ''
        "Package   : $name"
        "Tag       : $(if ($Tag) { $Tag } else { '(none)' })"
        "Commit    : $sha"
        "Committed : $date  $subject"
        "Built     : $(Get-Date -Format 'yyyy-MM-dd HH:mm') by $env:USERNAME"
        "Graph     : $graphLine"
        ''
        'Start with GETTING-STARTED.md. When you report a problem, include this file.'
    ) | Set-Content -LiteralPath (Join-Path $pkg 'VERSION.txt') -Encoding utf8

    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    $zip = Join-Path $OutputFolder "$name.zip"
    Write-Step "Zipping to $zip"
    Compress-Archive -Path $pkg -DestinationPath $zip -CompressionLevel Optimal -Force
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
Write-Host ''
Write-Host "Done: $zip ($size MB)" -ForegroundColor Green
Write-Host 'Before anyone signs in, a Global Administrator of their tenant has to consent once - see GETTING-STARTED.md, "Before you start".'

[pscustomobject]@{
    Zip         = $zip
    SizeMB      = $size
    Commit      = $sha
    Tag         = $Tag
    GraphModule = "$graphVersion"
}
