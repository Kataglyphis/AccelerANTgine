#requires -Version 7.0

<#
.SYNOPSIS
  Container-side build script for the Python bindings (nanobind).

.DESCRIPTION
  Configures and builds the project with KATAGLYPHIS_BUILD_PYTHON_BINDINGS=ON
  outside the mounted workspace for performance, then syncs the staged Python
  package (<build>/python/kataglyphis_inference) back into the workspace.
#>

param(
    # Same default as Build-Windows.ps1: the caller's tree. The old image-baked
    # C:\workspace default was the mount-over footgun the wrappers moved off.
    [string]$WorkspaceDir = $PWD.Path,
    [string]$BuildDir = "C:\pybuild",
    [string]$Preset = "x64-ClangCL-Windows-RelWithDebInfo",
    [string]$OutDir = "build-python"
)

$ErrorActionPreference = "Stop"

# The chain ONNX Runtime staging and its G6 proof come from ANTfrastructure through the
# repo's resolver: WindowsOrtPayload.Common, which an older hub pin lacks.
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

# Bundle third-party runtime DLLs (GStreamer, ONNX Runtime) into the package so
# it imports on hosts that don't have them installed — mirrors the
# Stage-RuntimeDependencies step of Build-Windows.ps1. __init__.py registers
# the _libs dir via os.add_dll_directory.
$libsDir = Join-Path $dest "kataglyphis_inference\_libs"
New-Item -ItemType Directory -Force $libsDir | Out-Null

# GStreamer bin dir: derive from pkg-config (image layout, e.g. C:\runtime\bin),
# falling back to conventional install locations.
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

# ONNX Runtime: the chain install's layout only (owner rule 2026-09-23). Get-OnnxChainLayout
# refuses a NuGet tree or a release zip, and the package is not staged until G6 proves that
# every ORT binary in it is the image's chain build and _libs (which __init__ registers) holds it.
$null = Copy-ChainOrtBeside -OnnxRoot "$env:ONNX_ROOT" -Destination $libsDir -All
$null = Assert-ChainOrtTree -Root $dest -OrtDirectory $libsDir -WaiveUnresolved

Write-Host "Python package staged to $dest"
exit 0
