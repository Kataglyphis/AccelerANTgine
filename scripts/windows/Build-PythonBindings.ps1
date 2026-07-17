<#
.SYNOPSIS
  Container-side build script for the Python bindings (nanobind).

.DESCRIPTION
  Configures and builds the project with KATAGLYPHIS_BUILD_PYTHON_BINDINGS=ON
  outside the mounted workspace for performance, then syncs the staged Python
  package (<build>/python/kataglyphis_inference) back into the workspace.
#>

param(
    [string]$WorkspaceDir = "C:\workspace",
    [string]$BuildDir = "C:\pybuild",
    [string]$Preset = "x64-ClangCL-Windows-RelWithDebInfo",
    [string]$OutDir = "build-python"
)

$ErrorActionPreference = "Stop"

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

# ONNX Runtime: source layouts (bin\onnxruntime.dll) and NuGet layouts
# (runtimes\win-x64\native) both appear across images — search recursively.
if ($env:ONNX_ROOT -and (Test-Path $env:ONNX_ROOT)) {
    Get-ChildItem -Path $env:ONNX_ROOT -Recurse -Filter 'onnxruntime*.dll' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName -Destination (Join-Path $libsDir $_.Name) -Force }
}

Write-Host "Python package staged to $dest"
exit 0
