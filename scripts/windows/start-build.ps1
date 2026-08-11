param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$Image = "ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64",
    [string]$CpuCount = "32",
    [string]$Memory = "48g",
    [string]$BuildTargets = "clangcl-debug,clangcl-profile,clangcl-release"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
Set-Location $ProjectRoot

$buildLogPath = Join-Path $ProjectRoot "build.log"
$buildErrorLogPath = Join-Path $ProjectRoot "build_err.log"

Write-Host "Starting build at $(Get-Date)"

$dockerArgs = @(
    "run",
    "--rm",
    "--cpus", $CpuCount,
    "--memory", $Memory,
    "--mount", "type=bind,source=${ProjectRoot},target=C:\workspace",
    "-w", "C:\workspace"
)

$psArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "C:\workspace\scripts\windows\Build-Windows.ps1",
    "-WorkspaceDir", "C:\workspace",
    "-BuildTargets", $BuildTargets
)

$process = Start-Process -FilePath "docker" -ArgumentList ($dockerArgs + @($Image, "powershell") + $psArgs) -Wait -NoNewWindow -PassThru -RedirectStandardOutput $buildLogPath -RedirectStandardError $buildErrorLogPath

Write-Host "Build exit code: $($process.ExitCode)"
Write-Host "Finished at $(Get-Date)"

if ($process.ExitCode -ne 0) {
    throw "Container build failed with exit code $($process.ExitCode). See $buildLogPath and $buildErrorLogPath."
}
