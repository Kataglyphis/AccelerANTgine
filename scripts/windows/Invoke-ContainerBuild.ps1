#requires -Version 7.0
# Builds in the ANTfrastructure Windows image; see third_party/ANTfrastructure/docs/windows-container-build-performance.md.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Image,
    # Comma-separated Build-Windows.ps1 targets (it splits the string itself).
    [string]$BuildTargets = "clangcl-debug,clangcl-profile,clangcl-release",
    # Falls back to $env:DOCKER_EXE, the Stevedore install locations, then 'docker' on PATH.
    [string]$DockerExe,
    # Process isolation exposes all host CPUs; Hyper-V isolation defaults to 2.
    [ValidateSet("process", "hyperv")]
    [string]$Isolation = "process",
    # Only applied under Hyper-V isolation (process isolation shares the host).
    [int]$CpuCount = 0,
    [int]$MemoryGb = 48,
    # Opt into the bind-mount transport, measured slower on a Dev Drive host.
    [switch]$UseBindMount,
    # Discard the reusable build container and start from a clean one.
    [switch]$FreshContainer
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectRoot = (Resolve-Path $ProjectRoot).Path

# The container plumbing has one owner: the hub's Invoke-RepoContainerBuild.ps1.
$runner = Join-Path $ProjectRoot 'third_party\ANTfrastructure\windows\scripts\build\Invoke-RepoContainerBuild.ps1'
if (-not (Test-Path -LiteralPath $runner)) { throw "Required script not found: $runner (run: git submodule update --init --recursive third_party/ANTfrastructure)" }

Write-Host "BuildTargets: $BuildTargets"

# Build-Windows.ps1 syncs each target's artifacts to build-<target>, which the host needs back.
$targetList = @($BuildTargets -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$buildDirs = @($targetList | ForEach-Object { "build-$_" })

# Every token must stay space-free: it travels docker CLI -> cmd /S /C -> %*.
$buildCommand = {
    param([string]$WorkspacePath)
    return @(
        "pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $WorkspacePath "scripts\windows\Build-Windows.ps1"),
        "-WorkspaceDir", $WorkspacePath,
        "-BuildTargets", ($targetList -join ",")
    )
}.GetNewClosure()

# Root build dirs leave the list, not a pattern (bsdtar matches everywhere); raw enumeration dodges WhatIf records.
$inboundItems = @([System.IO.Directory]::GetFileSystemEntries($ProjectRoot) |
    ForEach-Object { [System.IO.Path]::GetFileName($_) } |
    Where-Object { $_ -notin @("logs", "dist") -and $_ -notlike "build" -and $_ -notlike "build-*" -and $_ -notlike "build_*" })

& $runner -RepoRoot $ProjectRoot -ContainerName "accelerantgine-build-persistent" `
    -BuildCommand $buildCommand -Image $Image -DockerExe $DockerExe -Isolation $Isolation -CpuCount $CpuCount -MemoryGb $MemoryGb `
    -InboundItems $inboundItems -InboundExclude @(".git") `
    -OutputDirs (@("logs", "dist") + $buildDirs) `
    -OutboundExclude @("*/CMakeFiles", "*/_deps", "*/_CPack_Packages", "*.obj", "*.lib", "*.ilk") `
    -VerifyDirs @($buildDirs | Where-Object { $_ -like "build-clangcl-*" }) `
    -UseBindMount:$UseBindMount -FreshContainer:$FreshContainer -WhatIf:$WhatIfPreference

if (-not $WhatIfPreference) { Write-Host "Container build finished successfully." }
