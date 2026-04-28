$ErrorActionPreference = "Stop"
$ProjectRoot = "D:\GitHub\Kataglyphis-Cpp-Inference"
Set-Location $ProjectRoot

$buildDir = "$ProjectRoot\build-clangcl-profile"
$configName = "RelWithDebInfo (Profile)"

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

Write-Host "=== Running Perf Tests ===" -ForegroundColor Cyan

$perfTestPath = "$buildDir\perfTestSuite.exe"
if (Test-Path $perfTestPath) {
    Write-Host "--- Running Performance Tests (Benchmark) ---" -ForegroundColor Yellow
    Write-Host "Note: Perf tests measure execution time of key operations" -ForegroundColor Gray
    Write-Host ""
    & $perfTestPath
    Write-Host ""
} else {
    Write-Host "Perf test not found at: $perfTestPath" -ForegroundColor Red
}

Write-Host "=== Profile run complete ===" -ForegroundColor Green
