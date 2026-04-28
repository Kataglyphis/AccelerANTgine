$ErrorActionPreference = "Stop"
$ProjectRoot = "D:\GitHub\Kataglyphis-Cpp-Inference"
Set-Location $ProjectRoot

$buildDir = "$ProjectRoot\build-clangcl-release"
$configName = "Release"

Write-Host "=== Running KataglyphisCppInference $configName ===" -ForegroundColor Cyan
Write-Host "Build directory: $buildDir"
Write-Host ""

$cliPath = "$buildDir\bin\KataglyphisCppInference.exe"
if (Test-Path $cliPath) {
    Write-Host "--- CLI version check ---" -ForegroundColor Yellow
    & $cliPath
    Write-Host ""
} else {
    Write-Host "CLI not found at: $cliPath" -ForegroundColor Red
}

Write-Host "=== Release run complete ===" -ForegroundColor Green
