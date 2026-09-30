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

# Standard import shim: upstream ANTfrastructure modules win over any vendored copy.
. (Join-Path $PSScriptRoot "Resolve-BuildModule.ps1")
Import-BuildModule @("WindowsContainerBuild.Reuse", "WindowsContainerImage.Common")

# The image ref comes from ANTfrastructure's versions.env, never from here.
if (-not $Image) { $Image = Get-CiImageReference -Windows }

$docker = Resolve-DockerExe -Override $DockerExe
Write-Host "Using docker: $docker"
Write-Host "Image: $Image"
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

$build = @{
    DockerExe     = $docker
    Image         = $Image
    ContainerName = "accelerantgine-build-persistent"
    RepoRoot      = $ProjectRoot
    BuildCommand  = $buildCommand
    # Not the image-baked C:\workspace: mounting over an image directory fails on host/image OS-build skew.
    WorkspacePath = "C:\ws"
    IsolationArgs = (Get-ContainerIsolationArgs -Isolation $Isolation -CpuCount $CpuCount -MemoryGb $MemoryGb)
    # Build-Windows.ps1 re-points SCCACHE_DIR; the log and size entries still apply.
    CacheEnv      = (Get-SccacheContainerEnv)

    # Anchored: unanchored bsdtar patterns match at every depth and would strip nested third_party files.
    InboundExclude = @(".git", "./logs", "./build", "./build-*", "./build_*", "./dist")

    # No IncrementalDirs: incrementality comes from reusing the container, not from the synced build-* dirs.
    OutputDirs      = (@("logs", "dist") + $buildDirs)
    OutboundExclude = @("*/CMakeFiles", "*/_deps", "*/_CPack_Packages", "*.obj", "*.lib", "*.ilk")

    # clangcl-* only: the msvc lanes' multi-config generator puts exes in a per-config subdirectory.
    VerifyDirs = @($buildDirs | Where-Object { $_ -like "build-clangcl-*" })

    UseBindMount   = $UseBindMount
    FreshContainer = $FreshContainer
}

if ($PSCmdlet.ShouldProcess("$Image (container '$($build.ContainerName)')", "Invoke-ContainerBuild")) {
    # The imported function, not this script: the working directory is not on PATH.
    $null = Invoke-ContainerBuild @build
    Write-Host "Container build finished successfully."
} else {
    # -WhatIf: show the exact in-container command the config assembles to.
    $argv = Resolve-ContainerBuildCommand -BuildCommand $buildCommand -WorkspacePath $build.WorkspacePath
    Write-Host ("Would run in {0}: {1}" -f $build.WorkspacePath, ($argv -join " "))
    Write-Host ("OutputDirs: {0} | VerifyDirs: {1}" -f ($build.OutputDirs -join ", "), ($build.VerifyDirs -join ", "))
}
