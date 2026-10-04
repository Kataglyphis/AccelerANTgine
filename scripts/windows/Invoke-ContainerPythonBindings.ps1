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

# The container plumbing has one owner: the hub's Invoke-RepoContainerBuild.ps1.
$runner = Join-Path $ProjectRoot 'third_party\ANTfrastructure\windows\scripts\build\Invoke-RepoContainerBuild.ps1'
if (-not (Test-Path -LiteralPath $runner)) { throw "Required script not found: $runner (run: git submodule update --init --recursive third_party/ANTfrastructure)" }

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

# Root build outputs stay out of the transfer: bsdtar --exclude matches at every depth,
# and a './build_*' pattern stripped third_party/FUZZTEST/build_defs before.
# Raw enumeration: Get-ChildItem would answer with WhatIf records under -WhatIf.
$inboundItems = @([System.IO.Directory]::GetFileSystemEntries($ProjectRoot) |
    ForEach-Object { [System.IO.Path]::GetFileName($_) } |
    Where-Object { $_ -notin @("logs", "dist") -and $_ -notlike "build" -and $_ -notlike "build-*" -and $_ -notlike "build_*" })

# Not Invoke-ContainerBuild.ps1's container: the two lanes must never race for one.
# No VerifyDirs: the package ships no executables for the delivery check.
& $runner -RepoRoot $ProjectRoot -ContainerName "accelerantgine-python-persistent" `
    -BuildCommand $buildCommand -Image $Image -DockerExe $DockerExe -Isolation $Isolation -CpuCount $CpuCount -MemoryGb $MemoryGb `
    -InboundItems $inboundItems -InboundExclude @(".git") `
    -OutputDirs @("build-python") `
    -UseBindMount:$UseBindMount -FreshContainer:$FreshContainer -WhatIf:$WhatIfPreference

if (-not $WhatIfPreference) { Write-Host "Python bindings build finished successfully." }
