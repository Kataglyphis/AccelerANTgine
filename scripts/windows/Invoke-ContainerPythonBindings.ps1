#requires -Version 7.0
# Builds the Python bindings in the ANTfrastructure Windows image; see third_party/ANTfrastructure/docs/windows-container-build-performance.md.

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Image,
    [string]$Preset = "x64-ClangCL-Windows-RelWithDebInfo",
    # Falls back to $env:DOCKER_EXE, the Stevedore install locations, then 'docker' on PATH.
    [string]$DockerExe,
    # Process isolation exposes all host CPUs; Hyper-V isolation defaults to 2.
    [ValidateSet("process", "hyperv")]
    [string]$Isolation = "process",
    # Only applied under Hyper-V isolation (process isolation shares the host).
    [int]$CpuCount = 0,
    [int]$MemoryGb = 24,
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
Write-Host "Preset: $Preset"

# Every token must stay space-free: it travels docker CLI -> cmd /S /C -> %*.
$buildCommand = {
    param([string]$WorkspacePath)
    return @(
        "pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $WorkspacePath "scripts\windows\Build-PythonBindings.ps1"),
        "-WorkspaceDir", $WorkspacePath,
        "-Preset", $Preset
    )
}.GetNewClosure()

$build = @{
    DockerExe     = $docker
    Image         = $Image
    # Not Invoke-ContainerBuild.ps1's container: the two lanes must never race for one.
    ContainerName = "accelerantgine-python-persistent"
    RepoRoot      = $ProjectRoot
    BuildCommand  = $buildCommand
    # Not the image-baked C:\workspace: mounting over an image directory fails on host/image OS-build skew.
    WorkspacePath = "C:\ws"
    IsolationArgs = (Get-ContainerIsolationArgs -Isolation $Isolation -CpuCount $CpuCount -MemoryGb $MemoryGb)
    # The preset compiles through sccache (COMPILER_CACHE in CMakePresets.json).
    CacheEnv      = (Get-SccacheContainerEnv)

    # Anchored: unanchored bsdtar patterns match at every depth and would strip nested third_party files.
    InboundExclude = @(".git", "./logs", "./build", "./build-*", "./build_*", "./dist")

    # No VerifyDirs: the package ships no executables for the delivery check.
    OutputDirs = @("build-python")

    UseBindMount   = $UseBindMount
    FreshContainer = $FreshContainer
}

if ($PSCmdlet.ShouldProcess("$Image (container '$($build.ContainerName)')", "Invoke-ContainerBuild")) {
    $null = Invoke-ContainerBuild @build
    Write-Host "Python bindings build finished successfully."
} else {
    # -WhatIf: show the exact in-container command the config assembles to.
    $argv = Resolve-ContainerBuildCommand -BuildCommand $buildCommand -WorkspacePath $build.WorkspacePath
    Write-Host ("Would run in {0}: {1}" -f $build.WorkspacePath, ($argv -join " "))
    Write-Host ("OutputDirs: {0}" -f ($build.OutputDirs -join ", "))
}
