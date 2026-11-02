#requires -Version 7.0
# The Windows image lane behind Invoke-ContainerBuild.ps1 and Invoke-ContainerPythonBindings.ps1; see third_party/ANTfrastructure/docs/windows-container-build-performance.md.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectRoot,
    [string]$Image,
    # Build: comma-separated Build-Windows.ps1 targets (it splits the string itself). PythonBindings: the CMake preset.
    [Alias('BuildTargets', 'Preset')][string]$LaneValue,
    # Build only: a GPU variant needs its own -Image (the family's -nvidia or -rocm Windows tag).
    [ValidateSet('cpu', 'nvidia', 'amd')][string]$OrtVariant = 'cpu',
    # Falls back to $env:DOCKER_EXE, the Stevedore install locations, then 'docker' on PATH.
    [string]$DockerExe,
    # Process isolation exposes all host CPUs; Hyper-V isolation defaults to 2.
    [ValidateSet("process", "hyperv")]
    [string]$Isolation = "process",
    # Only applied under Hyper-V isolation (process isolation shares the host).
    [int]$CpuCount = 0,
    [int]$MemoryGb,
    # Opt into the bind-mount transport, measured slower on a Dev Drive host.
    [switch]$UseBindMount,
    # Discard the reusable build container and start from a clean one.
    [switch]$FreshContainer,
    # Selects the Python bindings lane instead of the CMake one.
    [switch]$PythonBindings
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $ProjectRoot) { $ProjectRoot = Join-Path $PSScriptRoot "..\.." }
$ProjectRoot = (Resolve-Path $ProjectRoot).Path

# The container plumbing has one owner: the hub's Invoke-RepoContainerBuild.ps1.
$runner = Join-Path $ProjectRoot 'third_party\ANTfrastructure\windows\scripts\build\Invoke-RepoContainerBuild.ps1'
if (-not (Test-Path -LiteralPath $runner)) { throw "Required script not found: $runner (run: git submodule update --init --recursive third_party/ANTfrastructure)" }

$isBuild = -not $PythonBindings
if (-not $PSBoundParameters.ContainsKey('LaneValue')) { $LaneValue = if ($isBuild) { "clangcl-debug,clangcl-profile,clangcl-release" } else { "x64-ClangCL-Windows-RelWithDebInfo" } }
if (-not $PSBoundParameters.ContainsKey('MemoryGb')) { $MemoryGb = if ($isBuild) { 48 } else { 24 } }

if ($isBuild) {
    Write-Host "BuildTargets: $LaneValue"
    # Build-Windows.ps1 syncs each target's artifacts to build-<target>, which the host needs back.
    $targetList = @($LaneValue -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $buildDirs = @($targetList | ForEach-Object { "build-$_" })
    $entry = "Build-Windows.ps1"
    $entryArgs = @("-BuildTargets", ($targetList -join ","))
    $laneArgs = @{
        ContainerName = "accelerantgine-build-persistent"
        OutputDirs = @("logs", "dist") + $buildDirs
        OutboundExclude = @("*/CMakeFiles", "*/_deps", "*/_CPack_Packages", "*.obj", "*.lib", "*.ilk")
        VerifyDirs = @($buildDirs | Where-Object { $_ -like "build-clangcl-*" })
    }
    if ($OrtVariant -ne 'cpu') {
        if (-not $Image) { throw "-OrtVariant $OrtVariant needs -Image, the GPU image the variant's ONNX Runtime comes from." }
        $entryArgs += @('-OrtVariant', $OrtVariant, '-SkipFormat')
        # A GPU build delivers only its dist tree, and keeps its own container so CPU reuse stays intact.
        $laneArgs.ContainerName = "accelerantgine-build-$OrtVariant"
        $laneArgs.OutputDirs = @('logs', 'dist')
        $laneArgs.VerifyDirs = @("dist\windows-x64-gpu-$OrtVariant")
    }
} else {
    Write-Host "Preset: $LaneValue"
    $entry = "Build-PythonBindings.ps1"
    $entryArgs = @("-Preset", $LaneValue)
    # Not the build lane's container (the two lanes must never race); no VerifyDirs, nothing to deliver-check.
    $laneArgs = @{ ContainerName = "accelerantgine-python-persistent"; OutputDirs = @("build-python") }
}

# Every token must stay space-free: it travels docker CLI -> cmd /S /C -> %*.
$buildCommand = {
    param([string]$WorkspacePath)
    return @(
        "pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $WorkspacePath "scripts\windows\$entry"),
        "-WorkspaceDir", $WorkspacePath
    ) + $entryArgs
}.GetNewClosure()

& $runner -RepoRoot $ProjectRoot @laneArgs `
    -BuildCommand $buildCommand -Image $Image -DockerExe $DockerExe -Isolation $Isolation -CpuCount $CpuCount -MemoryGb $MemoryGb `
    -ExcludeRootEntries @("logs", "dist") -ExcludeRootPatterns @("build", "build-*", "build_*") -InboundExclude @(".git") `
    -UseBindMount:$UseBindMount -FreshContainer:$FreshContainer -WhatIf:$WhatIfPreference

if (-not $WhatIfPreference) { Write-Host "$(if ($isBuild) { 'Container' } else { 'Python bindings' }) build finished successfully." }
