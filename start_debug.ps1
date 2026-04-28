$ErrorActionPreference = "Stop"
$ProjectRoot = "D:\GitHub\Kataglyphis-Cpp-Inference"
Set-Location $ProjectRoot

$buildDir = "$ProjectRoot\build-clangcl-debug"
$configName = "Debug"

Write-Host "=== Running KataglyphisCppInference $configName ===" -ForegroundColor Cyan
Write-Host "Build directory: $buildDir"
Write-Host ""

$cliPath = "$buildDir\bin\KataglyphisCppInference.exe"
if (Test-Path $cliPath) {
    Write-Host "--- Running CLI with test pattern (5 seconds) ---" -ForegroundColor Yellow
    Write-Host "Note: WebRTC requires a signalling server to actually stream" -ForegroundColor Gray
    $proc = Start-Process -FilePath $cliPath -ArgumentList "--webrtc","--source","test","--server","ws://localhost:8443" -NoNewWindow -PassThru
    Start-Sleep 5
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Write-Host ""
} else {
    Write-Host "CLI not found at: $cliPath" -ForegroundColor Red
}

$fuzzerPath = "$buildDir\kataglyphis_libfuzzer.exe"
if (Test-Path $fuzzerPath) {
    Write-Host "--- Fuzzer available at: $fuzzerPath ---" -ForegroundColor Yellow
    Write-Host "Run manually with corpus files:" -ForegroundColor Gray
    Write-Host "  $fuzzerPath corpus_dir/" -ForegroundColor Gray
    Write-Host ""
} else {
    Write-Host "Fuzzer not found at: $fuzzerPath" -ForegroundColor Red
}

Write-Host "=== Running Tests ===" -ForegroundColor Cyan

$commitTestPath = "$buildDir\commitTestSuite.exe"
if (Test-Path $commitTestPath) {
    Write-Host "--- Running Commit Tests ---" -ForegroundColor Yellow
    & $commitTestPath
    Write-Host ""
} else {
    Write-Host "Commit test not found" -ForegroundColor Red
}

$compileTestPath = "$buildDir\compileTestSuite.exe"
if (Test-Path $compileTestPath) {
    Write-Host "--- Running Compile Tests ---" -ForegroundColor Yellow
    & $compileTestPath
    Write-Host ""
} else {
    Write-Host "Compile test not found" -ForegroundColor Red
}

Write-Host "=== Debug run complete ===" -ForegroundColor Green
