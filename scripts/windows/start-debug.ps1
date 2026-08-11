param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [switch]$RunWebRtcSmoke,
    [string]$ServerUri = "ws://localhost:8443"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
Set-Location $ProjectRoot

function Invoke-NativeOrThrow {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
    }
}

function Invoke-WithBuildRuntimePath {
    param(
        [string]$BuildDir,
        [scriptblock]$Script
    )

    $previousPath = $env:PATH
    try {
        $env:PATH = ((@((Join-Path $BuildDir 'bin'), $BuildDir, $env:PATH) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';')
        & $Script
    } finally {
        $env:PATH = $previousPath
    }
}

$buildDir = "$ProjectRoot\build-clangcl-debug"
$configName = "Debug"
$missingArtifacts = @()

Write-Host "=== Running KataglyphisCppInference $configName ===" -ForegroundColor Cyan
Write-Host "Build directory: $buildDir"
Write-Host ""

$cliPath = "$buildDir\bin\KataglyphisCppInference.exe"
if (Test-Path $cliPath) {
    Write-Host "--- Running CLI version check ---" -ForegroundColor Yellow
    Invoke-WithBuildRuntimePath -BuildDir $buildDir -Script {
        Invoke-NativeOrThrow -FilePath $cliPath
    }
    Write-Host ""

    if ($RunWebRtcSmoke) {
        Write-Host "--- Running optional WebRTC test pattern smoke test (5 seconds) ---" -ForegroundColor Yellow
        Write-Host "Using signalling server: $ServerUri" -ForegroundColor Gray
        Invoke-WithBuildRuntimePath -BuildDir $buildDir -Script {
            $proc = Start-Process -FilePath $cliPath -ArgumentList "--webrtc","--source","test","--server",$ServerUri -NoNewWindow -PassThru
            if ($proc.WaitForExit(5000)) {
                if ($proc.ExitCode -ne 0) {
                    throw "CLI exited early with exit code $($proc.ExitCode): $cliPath"
                }
            } else {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Host ""
    }
} else {
    Write-Host "CLI not found at: $cliPath" -ForegroundColor Red
    $missingArtifacts += $cliPath
}

$fuzzTestPath = "$buildDir\first_fuzz_test.exe"
if (Test-Path $fuzzTestPath) {
    Write-Host "--- FUZZTEST target available at: $fuzzTestPath ---" -ForegroundColor Yellow
    Write-Host "Run manually to execute the registered fuzz tests." -ForegroundColor Gray
    Write-Host ""
} else {
    Write-Host "FUZZTEST target not found at: $fuzzTestPath" -ForegroundColor Red
}

Write-Host "=== Running Tests ===" -ForegroundColor Cyan

$commitTestPath = "$buildDir\commitTestSuite.exe"
if (Test-Path $commitTestPath) {
    Write-Host "--- Running Commit Tests ---" -ForegroundColor Yellow
    Invoke-WithBuildRuntimePath -BuildDir $buildDir -Script {
        Invoke-NativeOrThrow -FilePath $commitTestPath
    }
    Write-Host ""
} else {
    Write-Host "Commit test not found" -ForegroundColor Red
    $missingArtifacts += $commitTestPath
}

$compileTestPath = "$buildDir\compileTestSuite.exe"
if (Test-Path $compileTestPath) {
    Write-Host "--- Running Compile Tests ---" -ForegroundColor Yellow
    Invoke-WithBuildRuntimePath -BuildDir $buildDir -Script {
        Invoke-NativeOrThrow -FilePath $compileTestPath
    }
    Write-Host ""
} else {
    Write-Host "Compile test not found" -ForegroundColor Red
    $missingArtifacts += $compileTestPath
}

if ($missingArtifacts.Count -gt 0) {
    throw "Required debug artifacts not found: $($missingArtifacts -join ', ')"
}

Write-Host "=== Debug run complete ===" -ForegroundColor Green
