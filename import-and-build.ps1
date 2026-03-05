#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Import Clarion apps from version control and build without generating source.

.DESCRIPTION
    For teams that commit CLW source to their repository.
    Imports APV changes into .app files (via ClaInterface + ClarionCL /ai),
    then compiles with MSBuild using the CLW files already on disk.
    Does NOT run ClarionCL /ag - no source generation.

    Requires:
      - Clarion 10 installed with a working IDE configuration
      - UpperPark ClaInterface (only if using vcDevelopment APV import)
      - MSBuild (ships with .NET Framework 4)

.PARAMETER ClarionPath
    Path to your Clarion 10 installation folder (e.g. C:\Clarion10).
    Must contain bin\ClarionCL.exe and bin\Clarion.exe.

.PARAMETER SolutionPath
    Path to your .sln file. Default: accura.sln in the current directory.

.PARAMETER Configuration
    Build configuration: Debug or Release. Default: Release.

.PARAMETER ConfigDir
    Path to the Clarion config directory containing ClarionProperties.xml.
    Default: %AppData%\SoftVelocity\Clarion\10.0 (your IDE's own config).

.PARAMETER SkipImport
    Skip the vcDevelopment import step and go straight to MSBuild.

.PARAMETER StopOnError
    Stop the build on the first project failure. Default: true.

.EXAMPLE
    # Import from vcDevelopment APV folders then build
    .\import-and-build.ps1 -ClarionPath "C:\Clarion10"

.EXAMPLE
    # Build only (CLWs already up to date)
    .\import-and-build.ps1 -ClarionPath "C:\Clarion10" -SkipImport

.EXAMPLE
    # Debug build with explicit solution path
    .\import-and-build.ps1 -ClarionPath "C:\Clarion10" -SolutionPath "C:\Dev\MyApp\MyApp.sln" -Configuration Debug
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ClarionPath,

    [Parameter()]
    [string]$SolutionPath = "accura.sln",

    [Parameter()]
    [ValidateSet('Debug','Release')]
    [string]$Configuration = 'Release',

    [Parameter()]
    [string]$ConfigDir,

    [Parameter()]
    [switch]$SkipImport,

    [Parameter()]
    [bool]$StopOnError = $true
)

$ErrorActionPreference = "Stop"

function Write-Info    { param($m) Write-Host "i  $m" -ForegroundColor Cyan }
function Write-OK      { param($m) Write-Host "+  $m" -ForegroundColor Green }
function Write-Warn    { param($m) Write-Host "!  $m" -ForegroundColor Yellow }
function Write-Fail    { param($m) Write-Host "X  $m" -ForegroundColor Red }

function Get-VcOutputFolder {
    param([string]$SolutionDir)
    $ini = Join-Path $SolutionDir "up_vcSettings.ini"
    if (-not (Test-Path $ini)) {
        throw "up_vcSettings.ini not found in '$SolutionDir'. Cannot determine VC output folder."
    }
    $line = Get-Content $ini | Where-Object { $_ -match '^OutputFolder\s*=' } | Select-Object -First 1
    if (-not $line) {
        throw "OutputFolder not found in '$ini'. Cannot determine VC output folder."
    }
    $folder = ($line -split '=', 2)[1].Trim()
    if (-not $folder) {
        throw "OutputFolder is empty in '$ini'. Cannot determine VC output folder."
    }
    return $folder
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

$ClarionPath   = [System.IO.Path]::GetFullPath($ClarionPath)
$clarionBin    = Join-Path $ClarionPath "bin"
$clarionCL     = Join-Path $clarionBin  "ClarionCL.exe"
$msBuild       = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\msbuild.exe"
$claInterface  = "C:\Program Files (x86)\UpperParkSolutions\claInterface\ClaInterface.exe"

# Default ConfigDir to the user's own Clarion IDE config so no manual setup needed
if (-not $ConfigDir) {
    $ConfigDir = Join-Path $env:APPDATA "SoftVelocity\Clarion\10.0"
}

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------

Write-Host "`n=== Clarion Import & Build ===" -ForegroundColor Magenta
Write-Host ("Started: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "`n") -ForegroundColor Gray

if (-not (Test-Path $clarionCL)) {
    Write-Fail "ClarionCL.exe not found at: $clarionCL"
    exit 1
}
if (-not (Test-Path $msBuild)) {
    Write-Fail "MSBuild not found at: $msBuild"
    exit 1
}
if (-not (Test-Path $ConfigDir)) {
    Write-Fail "Clarion ConfigDir not found: $ConfigDir"
    Write-Host "  Set -ConfigDir to the folder containing your ClarionProperties.xml" -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path $SolutionPath)) {
    Write-Fail "Solution file not found: $SolutionPath"
    exit 1
}

$solutionDir = Split-Path (Resolve-Path $SolutionPath) -Parent

Write-Info "Clarion  : $ClarionPath"
Write-Info "ConfigDir: $ConfigDir"
Write-Info "Solution : $SolutionPath"
Write-Info "Config   : $Configuration"

# ---------------------------------------------------------------------------
# Project helpers
# ---------------------------------------------------------------------------

function Get-ProjectsFromSolution {
    param([string]$SolutionFile)
    $dir = Split-Path $SolutionFile -Parent
    $projects = @()
    Get-Content $SolutionFile | ForEach-Object {
        if ($_ -match 'Project\(".*?"\)\s*=\s*"(.*?)",\s*"(.*?\.cwproj)"') {
            $name = $Matches[1]
            $file = Join-Path $dir $Matches[2]
            if (Test-Path $file) {
                $projects += @{ Name = $name; File = $file; Dir = Split-Path $file -Parent }
            }
        }
    }
    return $projects
}

function Get-ProjectData {
    param([string]$File)
    try {
        [xml]$xml = Get-Content $File
        $guid = ($xml.Project.PropertyGroup.ProjectGuid | Where-Object { $_ } | Select-Object -First 1) -replace '[{}]',''
        $type = $xml.Project.PropertyGroup.OutputType | Where-Object { $_ } | Select-Object -First 1
        $refs = @()
        $xml.Project.ItemGroup.ProjectReference | ForEach-Object {
            if ($_) { $refs += ($_.Project -replace '[{}]','') }
        }
        return @{ Guid = $guid; OutputType = $type; RefGuids = $refs }
    } catch { return $null }
}

function Get-BuildOrder {
    param([array]$Projects)

    $nodes     = @{}
    $guidToName = @{}

    foreach ($p in $Projects) {
        $d = Get-ProjectData $p.File
        if ($d -and $d.Guid) {
            $nodes[$p.Name]       = @{ Project = $p; Guid = $d.Guid; OutputType = $d.OutputType; RefGuids = $d.RefGuids; Deps = @() }
            $guidToName[$d.Guid]  = $p.Name
        }
    }

    foreach ($name in $nodes.Keys) {
        $nodes[$name].Deps = $nodes[$name].RefGuids | Where-Object { $guidToName.ContainsKey($_) } | ForEach-Object { $guidToName[$_] }
    }

    $sorted   = [System.Collections.ArrayList]::new()
    $visited  = @{}
    $visiting = @{}

    function Visit($n) {
        if ($visiting[$n]) { return }
        if ($visited[$n])  { return }
        $visiting[$n] = $true
        if ($nodes.ContainsKey($n)) {
            foreach ($dep in $nodes[$n].Deps) { Visit $dep }
        }
        $visiting[$n] = $false
        $visited[$n]  = $true
        [void]$sorted.Add($n)
    }

    foreach ($n in ($nodes.Keys | Sort-Object)) { Visit $n }

    return $sorted.ToArray(), $nodes
}

# ---------------------------------------------------------------------------
# STEP 1 – Import apps from vcDevelopment
# ---------------------------------------------------------------------------

if (-not $SkipImport) {
    Write-Host "`n--- Step 1: Importing Apps from vcDevelopment ---" -ForegroundColor Magenta

    if (-not (Test-Path $claInterface)) {
        Write-Warn "ClaInterface.exe not found at: $claInterface"
        Write-Warn "Skipping import. Use -SkipImport to suppress this warning."
    } else {
        $vcBase = Get-VcOutputFolder $solutionDir
        $apps = @()
        Get-Content $SolutionPath | ForEach-Object {
            if ($_ -match 'Project\(".*?"\)\s*=\s*"(.*?)",\s*"(.*?\.cwproj)"') {
                $name    = $Matches[1]
                $appFile = Join-Path $solutionDir "$name.app"
                $vcDir   = Join-Path $vcBase $name
                if (Test-Path $vcDir) {
                    $apps += @{ Name = $name; AppFile = $appFile; VCDir = $vcDir }
                }
            }
        }

        if ($apps.Count -eq 0) {
            Write-Warn "No VC output folders found under '$vcBase' - skipping import"
        } else {
            Write-Info "Found $($apps.Count) app(s) with VC output folders"
            $ok = 0; $fail = 0

            foreach ($app in $apps) {
                Write-Host "  $($app.Name)..." -NoNewline -ForegroundColor Gray
                $txa = Join-Path $solutionDir "$($app.Name).upstxa"

                # Build TXA from APV files
                $proc = Start-Process -FilePath $claInterface `
                    -ArgumentList "/quiet /ConfigDir `"$ConfigDir`" COMMAND=BUILDTXA INPUT=`"$($app.VCDir)`" OUTPUT=`"$txa`" APPNAME=`"$($app.Name)`"" `
                    -Wait -NoNewWindow -PassThru
                if ($proc.ExitCode -ne 0 -or -not (Test-Path $txa)) {
                    Write-Host " FAILED (BuildTXA exit $($proc.ExitCode))" -ForegroundColor Red
                    $fail++; continue
                }

                # Import TXA into .app
                $proc2 = Start-Process -FilePath $clarionCL `
                    -ArgumentList "/ConfigDir `"$ConfigDir`" /ai `"$($app.AppFile)`" `"$txa`"" `
                    -Wait -NoNewWindow -PassThru
                if (Test-Path $txa) { Remove-Item $txa -Force }

                if ($proc2.ExitCode -eq 0) {
                    Write-Host " OK" -ForegroundColor Green
                    $ok++
                } else {
                    Write-Host " FAILED (import exit $($proc2.ExitCode))" -ForegroundColor Red
                    $fail++
                }
            }

            Write-OK "Import complete: $ok OK, $fail failed"
            if ($fail -gt 0 -and $StopOnError) { Write-Fail "Import errors. Stopping."; exit 1 }
        }
    }
} else {
    Write-Info "Step 1: Import skipped (-SkipImport)"
}

# ---------------------------------------------------------------------------
# STEP 2 – Build with MSBuild (no generate)
# ---------------------------------------------------------------------------

Write-Host "`n--- Step 2: Building Projects (no generate) ---" -ForegroundColor Magenta

$projects = Get-ProjectsFromSolution (Resolve-Path $SolutionPath)
if ($projects.Count -eq 0) {
    Write-Fail "No .cwproj files found in solution"
    exit 1
}
Write-Info "Found $($projects.Count) project(s)"

$buildOrder, $nodes = Get-BuildOrder $projects

# Show build order
Write-Host ""
for ($i = 0; $i -lt $buildOrder.Count; $i++) {
    $n    = $buildOrder[$i]
    $node = $nodes[$n]
    $tag  = if ($node.OutputType -eq 'Library') { '[LIB]' } else { '[EXE]' }
    $deps = if ($node.Deps.Count -gt 0) { "-> $($node.Deps -join ', ')" } else { '' }
    Write-Host ("  {0,2}. {1} {2} {3}" -f ($i+1), $tag, $n, $deps) -ForegroundColor Gray
}
Write-Host ""

# Build output dir
$buildOutputDir = Join-Path $solutionDir "build-output"
$failedLogsDir  = Join-Path $buildOutputDir "failed"
foreach ($d in @($buildOutputDir, $failedLogsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    else { Get-ChildItem $d -Filter "*.log" | Remove-Item -Force }
}

$successCount = 0
$failCount    = 0
$failedList   = @()

for ($i = 0; $i -lt $buildOrder.Count; $i++) {
    $name    = $buildOrder[$i]
    $node    = $nodes[$name]
    $project = $node.Project
    $log     = Join-Path $buildOutputDir "build_${name}.log"

    Write-Host "[$($i+1)/$($buildOrder.Count)] Building $name..." -NoNewline -ForegroundColor Gray

    $buildArgs = @(
        "/property:GenerateFullPaths=true"
        "/t:Rebuild"
        "/property:Configuration=$Configuration"
        "/property:clarion_Sections=$Configuration"
        "/property:ClarionBinPath=`"$clarionBin`""
        "/property:ConfigDir=`"$ConfigDir`""
        "/property:NoDependency=true"
        "/verbosity:normal"
        "/nologo"
        "/fileLogger"
        "/fileLoggerParameters:LogFile=`"$log`""
        "`"$($project.File)`""
    )

    try {
        $proc = Start-Process -FilePath $msBuild -ArgumentList $buildArgs `
            -WorkingDirectory $solutionDir -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput "$env:TEMP\msbuild_stdout_${name}.txt"

        if ($proc.ExitCode -eq 0) {
            Write-Host " OK" -ForegroundColor Green
            $successCount++
        } else {
            Write-Host " FAILED" -ForegroundColor Red
            $failCount++
            $failedList += $name
            Copy-Item $log (Join-Path $failedLogsDir "build_${name}.log") -Force -ErrorAction SilentlyContinue

            # Show first 5 error lines from log
            if (Test-Path $log) {
                Get-Content $log | Where-Object { $_ -match '\): error ' } | Select-Object -First 5 |
                    ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            }
            Write-Host "    Full log: build-output\build_${name}.log" -ForegroundColor DarkGray

            if ($name -in @('classes','data')) {
                Write-Fail "Critical project '$name' failed - aborting"
                exit 1
            }
            if ($StopOnError) { Write-Fail "Stopping on first error."; exit 1 }
        }
    } finally {
        Remove-Item "$env:TEMP\msbuild_stdout_${name}.txt" -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host "`n--- Summary ---" -ForegroundColor Magenta
Write-Host "  Configuration : $Configuration" -ForegroundColor Gray
Write-Host "  Projects      : $($buildOrder.Count)" -ForegroundColor Gray
Write-OK   "  Succeeded     : $successCount"
if ($failCount -gt 0) {
    Write-Warn "  Failed        : $failCount ($($failedList -join ', '))"
    Write-Host "  Failed logs   : $failedLogsDir" -ForegroundColor Gray
    exit 1
}

Write-Host "`n=== Build Complete ===" -ForegroundColor Magenta
Write-Host ("Finished: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
exit 0
