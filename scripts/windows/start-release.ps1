param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
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

$buildDir = "$ProjectRoot\build-clangcl-release"
$configName = "Release"
$missingArtifacts = @()

Write-Host "=== Running KataglyphisCppInference $configName ===" -ForegroundColor Cyan
Write-Host "Build directory: $buildDir"
Write-Host ""

$cliPath = "$buildDir\bin\KataglyphisCppInference.exe"
if (Test-Path $cliPath) {
    Write-Host "--- CLI version check ---" -ForegroundColor Yellow
    Invoke-WithBuildRuntimePath -BuildDir $buildDir -Script {
        Invoke-NativeOrThrow -FilePath $cliPath
    }
    Write-Host ""
} else {
    Write-Host "CLI not found at: $cliPath" -ForegroundColor Red
    $missingArtifacts += $cliPath
}

if ($missingArtifacts.Count -gt 0) {
    throw "Required release artifacts not found: $($missingArtifacts -join ', ')"
}

Write-Host "=== Release run complete ===" -ForegroundColor Green
