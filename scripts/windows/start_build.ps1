$ErrorActionPreference = "Stop"
$ProjectRoot = "D:\GitHub\Kataglyphis-Cpp-Inference"
Set-Location $ProjectRoot

Write-Host "Starting build at $(Get-Date)"

$dockerArgs = @(
    "run",
    "--rm",
    "--cpus", "32",
    "--memory", "48g",
    "-v", "$ProjectRoot`:/workspace",
    "-w", "C:\workspace"
)

$image = "ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64"

$psArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", "C:\workspace\scripts\windows\Build-Windows.ps1",
    "-Configurations", "clangcl-debug,clangcl-profile,clangcl-release",
    "-SkipFormat"
)

$process = Start-Process -FilePath "docker" -ArgumentList ($dockerArgs + @($image, "powershell") + $psArgs) -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$ProjectRoot\build.log" -RedirectStandardError "$ProjectRoot\build_err.log"

Write-Host "Build exit code: $($process.ExitCode)"
Write-Host "Finished at $(Get-Date)"