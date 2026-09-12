#requires -Version 7.0
# Build the engine inside the ANTfrastructure Windows developer image using
# Stevedore's docker.exe (see third_party/ANTfrastructure/docs/windows-builds.md
# for why nerdctl is not an option on Windows).
#
# Thin project wrapper: the transport decision (tar pipe vs bind mount), the
# reusable container, the artifact streaming and the delivery verification all
# live upstream in ANTfrastructure's WindowsContainerBuild.Reuse module
# (Invoke-ContainerBuild). Rationale + measurements:
# ANTfrastructure docs/windows-container-build-performance.md.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Image = "ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64",
    # Comma-separated Build-Windows.ps1 targets (it splits the string itself).
    [string]$BuildTargets = "clangcl-debug,clangcl-profile,clangcl-release",
    # Explicit docker.exe path; falls back to $env:DOCKER_EXE, the Stevedore
    # install locations, then 'docker' on PATH (Resolve-DockerExe).
    [string]$DockerExe,
    # Process isolation exposes all host CPUs; Hyper-V isolation defaults to 2.
    [ValidateSet("process", "hyperv")]
    [string]$Isolation = "process",
    # Only applied under Hyper-V isolation (process isolation shares the host).
    [int]$CpuCount = 0,
    [int]$MemoryGb = 48,
    # Opt into the bind-mount transport - measured slower on a Dev Drive host,
    # see Invoke-ContainerBuild.
    [switch]$UseBindMount,
    # Discard the reusable build container and start from a clean one.
    [switch]$FreshContainer
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectRoot = (Resolve-Path $ProjectRoot).Path

# Standard import shim: upstream ANTfrastructure modules win over any vendored copy.
. (Join-Path $PSScriptRoot "Resolve-BuildModule.ps1")
Import-BuildModule @("WindowsContainerBuild.Reuse")

$docker = Resolve-DockerExe -Override $DockerExe
Write-Host "Using docker: $docker"
Write-Host "Image: $Image"
Write-Host "BuildTargets: $BuildTargets"

# Build-Windows.ps1 syncs each target's artifacts to build-<target> in the
# workspace; those (plus logs and the MSIX output) are what the host needs back.
$targetList = @($BuildTargets -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$buildDirs = @($targetList | ForEach-Object { "build-$_" })

# Arguments handed to the image entrypoint (VsDevCmd, then %*). Every token
# must stay space-free: it travels docker CLI -> cmd /S /C -> %*.
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
    # The family workspace path. NOT the image-baked C:\workspace: mounting
    # over a directory that exists in the image fails at CreateComputeSystem
    # on host/image OS-build skew (see Invoke-ContainerBuild).
    WorkspacePath = "C:\ws"
    IsolationArgs = (Get-ContainerIsolationArgs -Isolation $Isolation -CpuCount $CpuCount -MemoryGb $MemoryGb)
    # Build-Windows.ps1 re-points SCCACHE_DIR under its fast-build dir
    # (Initialize-BuildCacheEnvironment); the log/size entries still apply.
    CacheEnv      = (Get-SccacheContainerEnv)

    # Anchored (./...) so nested third_party files are not stripped -
    # unanchored patterns match at every path depth in bsdtar.
    InboundExclude = @(".git", "./logs", "./build", "./build-*", "./build_*", "./dist")

    # No IncrementalDirs: the ninja tree lives in the reusable container at
    # C:\kataglyphis_fast_build, so incrementality comes from container reuse;
    # the host's build-* dirs hold synced artifacts, not a usable seed.
    OutputDirs      = (@("logs", "dist") + $buildDirs)
    OutboundExclude = @("*/CMakeFiles", "*/_deps", "*/_CPack_Packages", "*.obj", "*.lib", "*.ilk")

    # Each lane leaves at least one top-level exe in its build dir (test
    # suites; the CPack installer for release), which is what the check reads.
    # clangcl-* only: the msvc-* lanes use the Visual Studio multi-config
    # generator, whose exes land in a per-config SUBdirectory, so the top-level
    # probe would fail a green build there.
    VerifyDirs = @($buildDirs | Where-Object { $_ -like "build-clangcl-*" })

    UseBindMount   = $UseBindMount
    FreshContainer = $FreshContainer
}

if ($PSCmdlet.ShouldProcess("$Image (container '$($build.ContainerName)')", "Invoke-ContainerBuild")) {
    $null = Invoke-ContainerBuild @build
    Write-Host "Container build finished successfully."
} else {
    # -WhatIf: show the exact in-container command the config assembles to.
    $argv = Resolve-ContainerBuildCommand -BuildCommand $buildCommand -WorkspacePath $build.WorkspacePath
    Write-Host ("Would run in {0}: {1}" -f $build.WorkspacePath, ($argv -join " "))
    Write-Host ("OutputDirs: {0} | VerifyDirs: {1}" -f ($build.OutputDirs -join ", "), ($build.VerifyDirs -join ", "))
}
