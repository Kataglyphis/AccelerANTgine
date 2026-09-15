#requires -Version 7.0

<#
.SYNOPSIS
  Runs what a Windows build produced, on the host: the CLI plus that
  configuration's test suites.

.DESCRIPTION
  One script for the three configurations that used to have one each -
  Start-Debug.ps1, Start-Profile.ps1 and Start-Release.ps1. The three were 90%
  the same file: identical local copies of Invoke-NativeOrThrow and
  Invoke-WithBuildRuntimePath, identical "is the exe there / run it / collect
  what was missing" shape, and only the build directory and the list of suites
  differed. Both helpers now come from ANTfrastructure's WindowsTesting.Common
  (Invoke-ManualTestExecutable, Invoke-WithRuntimePath), which also puts the
  ASan runtime on PATH - Microsoft's as well as LLVM's - for the duration of
  each run.

  The build directory is NOT spelled out here either: it is read from
  Build-Windows.config.psd1, the same table Build-Windows.ps1 builds into, so
  the producer and the consumer of an artifact cannot disagree about where it is.

  This script LAUNCHES THE APPLICATION. That is the distinction the Start-
  prefix carries in this repo, which is why the container wrappers that merely
  drive a build are named Invoke-*/Show-* instead.

.PARAMETER Config
  Debug (CLI + fuzz-target report + commit and compile suites), Profile
  (CLI + benchmarks) or Release (CLI only).

.PARAMETER RunWebRtcSmoke
  Debug only: start the CLI against a signalling server for five seconds and
  fail if it exits non-zero before then.
#>

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Profile', 'Release')]
    [string]$Config = 'Debug',
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    # Another build table, if this tree was built with one.
    [string]$ConfigPath,
    [string]$LogDir,
    [switch]$RunWebRtcSmoke,
    [string]$ServerUri = "ws://localhost:8443"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
Set-Location $ProjectRoot

# Standard import shim: upstream ANTfrastructure modules win over any vendored copy.
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')
Import-BuildModule @(
    'WindowsScripts.Shared'
    'WindowsBuild.Common'
    'WindowsConfig.Common'
    'WindowsTesting.Common'
)

# -Config -> a row of the build table. The row names are the same tokens
# Build-Windows.ps1 takes in -BuildTargets.
$rowName = switch ($Config) {
    'Debug' { 'clangcl-debug' }
    'Profile' { 'clangcl-profile' }
    'Release' { 'clangcl-release' }
}

$configPathResolved = Get-OrDefault $ConfigPath (Join-Path $PSScriptRoot 'Build-Windows.config.psd1')
if (-not (Test-Path $configPathResolved)) {
    throw "Build config not found: $configPathResolved"
}
$buildConfig = Import-PowerShellDataFile -Path $configPathResolved

$row = Get-ConfigValue -Config $buildConfig -Path "Build.Configurations.$rowName"
if ($null -eq $row) {
    throw "Unknown build configuration '$rowName' in $configPathResolved."
}

# Same environment override the build side honours, so a lane that retargeted a
# build directory does not have to tell this script about it twice.
$buildDirEnvItem = Get-Item -Path "Env:$($row['BuildDirEnv'])" -ErrorAction SilentlyContinue
$buildDirName = Get-OrDefault $(if ($null -ne $buildDirEnvItem) { $buildDirEnvItem.Value } else { $null }) $row['BuildDir']
$buildDir = Join-Path $ProjectRoot $buildDirName

$logDirPath = Join-Path $ProjectRoot (Get-OrDefault $LogDir (Get-ConfigValue -Config $buildConfig -Path 'Build.LogDir'))
if (-not (Test-Path $logDirPath)) {
    New-Item -ItemType Directory -Force $logDirPath | Out-Null
}

$ctx = New-BuildContext -Workspace $ProjectRoot -LogDir $logDirPath -StopOnError
Open-BuildLog -Context $ctx

$script:missingArtifacts = @()

# The staged runtime DLLs (ONNX Runtime, GStreamer) sit in <buildDir>\bin next to
# the CLI, but the test suites are emitted at the build root, where the loader
# would not find them - which is exactly what the deleted Invoke-WithBuildRuntimePath
# existed to fix. Invoke-WithRuntimePath is the hub's version of that
# save/override/restore; Invoke-ManualTestExecutable adds the ASan runtime
# directories on top and returns $false (rather than throwing) for a missing
# binary or a Windows loader mismatch.
function Invoke-BuiltArtifact {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutableName,
        [string[]]$RelativeDirectory = @('bin'),
        [string[]]$Arguments = @()
    )

    $ran = [bool](Invoke-WithRuntimePath -RuntimeDirs @((Join-Path $buildDir 'bin'), $buildDir) -AsanOptions '' -Script {
            Invoke-ManualTestExecutable -Context $ctx `
                -BuildRoot $buildDir `
                -ExecutableName $ExecutableName `
                -Arguments $Arguments `
                -AdditionalRelativeDirectory $RelativeDirectory `
                -RuntimeFlavor Clang
        })

    if (-not $ran) {
        $script:missingArtifacts += $ExecutableName
    }
}

try {
    Write-BuildLog -Context $ctx -Message "=== Running AccelerANTgine $Config ==="
    Write-BuildLog -Context $ctx -Message "Build table:     $configPathResolved"
    Write-BuildLog -Context $ctx -Message "Build directory: $buildDir"

    Write-BuildLog -Context $ctx -Message "--- CLI version check ---"
    Invoke-BuiltArtifact -ExecutableName 'AccelerANTgine.exe'

    if ($Config -eq 'Debug') {
        # Reported, never run: the registered fuzz tests are long-running and are
        # started by hand. Its absence is not a missing artifact.
        $fuzzTest = Resolve-TestExecutable -BuildRoot $buildDir -ExecutableName 'first_fuzz_test.exe'
        if ($fuzzTest) {
            Write-BuildLog -Context $ctx -Message "FUZZTEST target available at: $fuzzTest (run it by hand)"
        } else {
            Write-BuildLogWarning -Context $ctx -Message "FUZZTEST target not found under $buildDir"
        }

        Write-BuildLog -Context $ctx -Message "--- Commit tests ---"
        Invoke-BuiltArtifact -ExecutableName 'commitTestSuite.exe' -RelativeDirectory @('', 'bin')

        Write-BuildLog -Context $ctx -Message "--- Compile tests ---"
        Invoke-BuiltArtifact -ExecutableName 'compileTestSuite.exe' -RelativeDirectory @('', 'bin')

        if ($RunWebRtcSmoke) {
            # Not Invoke-ManualTestExecutable: this one must be killed after five
            # seconds rather than waited on, so it keeps Start-Process. -AsanOptions ''
            # because the CLI is a full application - the test-binary defaults
            # (report_globals=1) produce noise it never has to answer for.
            Write-BuildLog -Context $ctx -Message "--- WebRTC test-pattern smoke (5s) against $ServerUri ---"
            $cliPath = Resolve-TestExecutable -BuildRoot $buildDir -ExecutableName 'AccelerANTgine.exe' -AdditionalRelativeDirectory 'bin'
            if (-not $cliPath) {
                throw "WebRTC smoke requested but no AccelerANTgine.exe under $buildDir"
            }

            Invoke-WithRuntimePath -RuntimeDirs @((Join-Path $buildDir 'bin'), $buildDir) -AsanOptions '' -Script {
                $proc = Start-Process -FilePath $cliPath -ArgumentList "--webrtc", "--source", "test", "--server", $ServerUri -NoNewWindow -PassThru
                if ($proc.WaitForExit(5000)) {
                    if ($proc.ExitCode -ne 0) {
                        throw "CLI exited early with exit code $($proc.ExitCode): $cliPath"
                    }
                } else {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } elseif ($Config -eq 'Profile') {
        Write-BuildLog -Context $ctx -Message "--- Performance tests (Google Benchmark) ---"
        Invoke-BuiltArtifact -ExecutableName 'perfTestSuite.exe' -RelativeDirectory @('', 'bin')
    }

    if ($script:missingArtifacts.Count -gt 0) {
        throw "Required $Config artifacts not found or not startable: $($script:missingArtifacts -join ', ')"
    }

    Write-BuildLog -Context $ctx -Message "=== $Config run complete ==="
} catch {
    Write-BuildLogError -Context $ctx -Message "$Config run failed: $($_.Exception.Message)"
    Close-BuildLog -Context $ctx
    throw
}

Close-BuildLog -Context $ctx
