#requires -Version 7.0

<#
.SYNOPSIS
  Runs what a Windows build produced on the host: the CLI plus that configuration's test suites.

.DESCRIPTION
  The build directory comes from Build-Windows.config.psd1, so producer and consumer cannot disagree.

.PARAMETER Config
  Debug (CLI, fuzz-target report, commit and compile suites), Profile (CLI, benchmarks) or Release (CLI only).

.PARAMETER RunWebRtcSmoke
  Debug only: run the CLI against a signalling server for five seconds; fail if it exits non-zero sooner.
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
    'WindowsTargetArch.Common'
)

# The row names are the tokens Build-Windows.ps1 takes in -BuildTargets.
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

# The build side's environment override, so a retargeted build directory is found here too.
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

# The runtime DLLs sit in <buildDir>\bin, but the test suites live at the build root, out of the loader's reach.
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
        $exe = Resolve-TestExecutable -BuildRoot $buildDir -ExecutableName $ExecutableName -AdditionalRelativeDirectory $RelativeDirectory
        if ($exe) { Write-ImportClosureReport -Executable $exe -SearchDirs @((Join-Path $buildDir 'bin'), $buildDir) }
    }
}

# Names the missing or stale DLL behind the hub's one "loader/runtime mismatch" message, searching as the loader does.
function Write-ImportClosureReport {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$SearchDirs = @()
    )
    $system = [Environment]::SystemDirectory
    $dirs = @((Split-Path -Parent $Executable), $system) + $SearchDirs + @($env:PATH -split ';' | Where-Object { $_ })
    $resolved = @{}
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Executable)
    while ($queue.Count -gt 0) {
        $file = $queue.Dequeue()
        foreach ($name in @(Get-PeImportNames -Path $file)) {
            $key = $name.ToLowerInvariant()
            if ($resolved.ContainsKey($key) -or $key -like 'api-ms-win-*' -or $key -like 'ext-ms-*') { continue }
            $hit = $dirs | ForEach-Object { Join-Path $_ $name } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
            $resolved[$key] = $hit
            if (-not $hit) {
                Write-BuildLogWarning -Context $ctx -Message "  import closure: $name (imported by $(Split-Path -Leaf $file)) -- NOT FOUND"
            } elseif (-not $hit.StartsWith($system, [StringComparison]::OrdinalIgnoreCase)) {
                $queue.Enqueue($hit)
            }
        }
    }
    foreach ($runtime in 'vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'clang_rt.asan_dynamic-x86_64.dll') {
        if ($resolved[$runtime]) {
            $version = (Get-Item -LiteralPath $resolved[$runtime]).VersionInfo.FileVersion
            Write-BuildLog -Context $ctx -Message "  import closure: $runtime -> $($resolved[$runtime]) ($version)"
        }
    }
}

try {
    Write-BuildLog -Context $ctx -Message "=== Running AccelerANTgine $Config ==="
    Write-BuildLog -Context $ctx -Message "Build table:     $configPathResolved"
    Write-BuildLog -Context $ctx -Message "Build directory: $buildDir"

    Write-BuildLog -Context $ctx -Message "--- CLI version check ---"
    Invoke-BuiltArtifact -ExecutableName 'AccelerANTgine.exe'

    if ($Config -eq 'Debug') {
        # Reported, never run: the fuzz tests are long-running and started by hand.
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
            # Start-Process: this run is killed after five seconds, not waited on; the test-binary ASan defaults only add noise.
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
