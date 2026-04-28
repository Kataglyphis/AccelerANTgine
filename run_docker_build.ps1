$ErrorActionPreference = "Continue"
$ProjectRoot = "D:\GitHub\Kataglyphis-Cpp-Inference"

$dockerArgs = @(
    "run",
    "--rm",
    "--cpus", "32",
    "--memory", "48g",
    "-v", "//d/GitHub/Kataglyphis-Cpp-Inference:/workspace",
    "-w", "/workspace"
)

$image = "ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64"

$psArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-Command",
    "Set-Location C:\workspace; & {
        ./scripts/windows/Build-Windows.ps1 -Configurations 'clangcl-debug,clangcl-profile,clangcl-release' -SkipFormat 2>&1 |
        Out-File -FilePath 'C:\workspace\build.log' -Encoding utf8
    }"
)

$fullArgs = $dockerArgs + @($image, "powershell") + $psArgs

Write-Host "Starting build at $(Get-Date)"
Write-Host "Docker args: $($fullArgs -join ' ')"

$process = Start-Process -FilePath "docker" -ArgumentList $fullArgs -Wait -NoNewWindow -PassThru

Write-Host "Build exit code: $($process.ExitCode)"
Write-Host "Finished at $(Get-Date)"