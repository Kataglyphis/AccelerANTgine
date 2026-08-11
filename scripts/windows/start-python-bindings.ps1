param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Image = "ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64",
    [string]$CpuCount = "$env:NUMBER_OF_PROCESSORS",
    [string]$Memory = "24g",
    [string]$Preset = "x64-ClangCL-Windows-RelWithDebInfo"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
Set-Location $ProjectRoot

# Stevedore's bundled docker.exe is required on this host (nerdctl has broken
# DNS/NAT on Windows) — see ExternalLib/Kataglyphis-ContainerHub/docs/windows-builds.md.
$docker = Join-Path $env:ProgramFiles "Stevedore\bin\docker.exe"
if (-not (Test-Path $docker)) { $docker = "D:\Stevedore\bin\docker.exe" }
if (-not (Test-Path $docker)) { $docker = "docker" }

$buildLogPath = Join-Path $ProjectRoot "build_python.log"
$buildErrorLogPath = Join-Path $ProjectRoot "build_python_err.log"

Write-Host "Starting Python bindings build at $(Get-Date) using $docker"

# Mount to a fresh target (not the image's baked C:\workspace) — on hosts with
# kernel/base-image skew, mounting over an existing image dir fails at
# CreateComputeSystem. NOTE: if ProjectRoot is on a Dev Drive, bind mounts need
# `fsutil devdrv setfiltersallowed bindFlt, wcifs` (elevated) + remount first,
# or stage the tree to a non-Dev-Drive path and pass it as -ProjectRoot.
# See ExternalLib/Kataglyphis-ContainerHub/docs/windows-builds.md.
$dockerArgs = @(
    "run",
    "--rm",
    "--isolation", "process",
    "--cpus", $CpuCount,
    "--memory", $Memory,
    "--mount", "type=bind,source=${ProjectRoot},target=C:\ws-mnt",
    "-w", "C:\ws-mnt"
)

$psArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "C:\ws-mnt\scripts\windows\Build-PythonBindings.ps1",
    "-WorkspaceDir", "C:\ws-mnt",
    "-Preset", $Preset
)

$process = Start-Process -FilePath $docker -ArgumentList ($dockerArgs + @($Image, "powershell") + $psArgs) -Wait -NoNewWindow -PassThru -RedirectStandardOutput $buildLogPath -RedirectStandardError $buildErrorLogPath

Write-Host "Build exit code: $($process.ExitCode)"
Write-Host "Finished at $(Get-Date)"

if ($process.ExitCode -ne 0) {
    throw "Container build failed with exit code $($process.ExitCode). See $buildLogPath and $buildErrorLogPath."
}
