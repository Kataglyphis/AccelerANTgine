#requires -Version 7.0

<#
.SYNOPSIS
  Container-side build script for the Python bindings (nanobind).

.DESCRIPTION
  Builds outside the mounted workspace for speed, then syncs the staged package back into it.
#>

param(
    # The caller's tree, as in Build-Windows.ps1; an image-baked default can be hidden by the mount.
    [string]$WorkspaceDir = $PWD.Path,
    [string]$BuildDir = "C:\pybuild",
    [string]$Preset = "x64-ClangCL-Windows-RelWithDebInfo",
    [string]$OutDir = "build-python"
)

$ErrorActionPreference = "Stop"

# Chain ORT staging and its G6 proof come from WindowsOrtPayload.Common, which an older hub pin lacks.
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')
try { Import-BuildModule @('WindowsOrtPayload.Common') } catch {
    throw "This build needs ANTfrastructure's WindowsOrtPayload.Common (hub commit ad08bc30 of 2026-09-25, third_party/ANTfrastructure/docs/onnxruntime-single-source.md § The shared Windows glue); move third_party/ANTfrastructure to it or later. ($($_.Exception.Message))"
}

Write-Host "=== Python bindings build ($Preset) ==="
cmake --preset $Preset -S $WorkspaceDir -B $BuildDir `
    -DKATAGLYPHIS_BUILD_PYTHON_BINDINGS=ON `
    -Dmyproject_ENABLE_CPPCHECK=OFF `
    -Dmyproject_ENABLE_IPO=OFF
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }

cmake --build $BuildDir
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

$dest = Join-Path (Join-Path $WorkspaceDir $OutDir) "python"
robocopy (Join-Path $BuildDir "python") $dest /E /NFL /NDL /NJH
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }

# Bundled runtime DLLs let the package import on hosts without them; __init__.py registers _libs.
$libsDir = Join-Path $dest "kataglyphis_inference\_libs"
New-Item -ItemType Directory -Force $libsDir | Out-Null

# GStreamer bin from pkg-config (the image's layout), else the conventional install locations.
$gstCandidates = @()
$gstLibDir = (& pkg-config --variable=libdir gstreamer-1.0) 2>$null
if ($gstLibDir) {
    $gstCandidates += (Join-Path (Split-Path -Parent ($gstLibDir -replace '/', '\')) "bin")
}
$gstCandidates += @('C:\gstreamer\bin', 'C:\gstreamer\1.0\msvc_x86_64\bin')
foreach ($candidate in $gstCandidates) {
    if ($candidate -and (Test-Path $candidate)) {
        robocopy $candidate $libsDir *.dll /NFL /NDL /NJH /NJS
        if ($LASTEXITCODE -ge 8) { throw "robocopy of GStreamer DLLs failed" }
        break
    }
}

# Chain ORT only: nothing is staged until G6 proves every ORT binary in the package is the chain build.
$null = Copy-ChainOrtBeside -OnnxRoot "$env:ONNX_ROOT" -Destination $libsDir -All
$null = Assert-ChainOrtTree -Root $dest -OrtDirectory $libsDir -WaiveUnresolved

Write-Host "Python package staged to $dest"
exit 0
