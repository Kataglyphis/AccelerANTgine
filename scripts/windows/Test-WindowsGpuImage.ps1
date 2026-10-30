#requires -Version 7.0
<#
.SYNOPSIS
  Checks the chain ONNX Runtime inputs for a future Windows x64 GPU package.
.DESCRIPTION
  This is an image preflight, not a build, installer proof or GPU execution test.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('nvidia', 'amd')][string]$Variant,
    [Parameter(Mandatory)][string]$OnnxRoot,
    [Parameter(Mandatory)][string]$WheelDir,
    [ValidateSet('amd64', 'x64', 'arm64')][string]$TargetArch = 'amd64',
    [string]$ScratchRoot = [IO.Path]::GetTempPath()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($TargetArch -eq 'arm64') { throw 'Windows ARM GPU packages are excluded from the build matrix.' }

. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')
Import-BuildModule @('WindowsTargetArch.Common', 'WindowsOrtLicense.Common', 'WindowsOrtPayload.Common')
$names = @('onnxruntime.dll')
if (-not (Get-Command Copy-OrtWheelLicenses).Parameters.ContainsKey('ProviderDll')) {
    throw "GPU preflight requires ANTfrastructure's provider-aware ORT wheel verifier."
}
if (-not (Get-Command Copy-OrtWheelLicenses).Parameters.ContainsKey('DirectMlDll')) {
    throw "GPU preflight requires ANTfrastructure's same-wheel DirectML verifier."
}
if (-not (Get-Command Get-ChainOrtRuntimeFile -ErrorAction SilentlyContinue)) {
    throw "GPU preflight requires ANTfrastructure's chain runtime file resolver."
}
if ($Variant -eq 'nvidia') {
    $names += @('onnxruntime_providers_shared.dll', 'onnxruntime_providers_cuda.dll')
    if (Get-ChainOrtRuntimeFile -OnnxRoot $OnnxRoot -Name 'DirectML.dll' -AllowMissing) { $names += 'DirectML.dll' }
} else {
    $names += 'onnxruntime_providers_shared.dll', 'DirectML.dll'
}
$files = @($names | ForEach-Object {
        $path = Get-ChainOrtRuntimeFile -OnnxRoot $OnnxRoot -Name $_
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -eq 0) { throw "Required ORT input is empty or not a file: $path" }
        $item.FullName
    })
$null = Assert-PeTargetMachine -Path $files -Arch 'amd64' -Context 'Windows GPU packages require x64 inputs'

# The shared verifier needs a destination for the wheel's notices; keep it out of the source image.
$scratchParent = (Resolve-Path -LiteralPath $ScratchRoot -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $scratchParent -PathType Container)) { throw "Scratch root is not a directory: $scratchParent" }
$scratch = Join-Path $scratchParent "accelerantgine-gpu-preflight-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $scratch -ErrorAction Stop
try {
    $licenseParams = @{ OrtDll = $files[0]; WheelDir = $WheelDir; Destination = $scratch }
    $licenseParams.ProviderDll = [string[]]@(if ($Variant -eq 'nvidia') { $files[1], $files[2] } else { $files[1] })
    $directMlIndex = [array]::IndexOf($names, 'DirectML.dll')
    if ($directMlIndex -ge 0) { $licenseParams.DirectMlDll = $files[$directMlIndex] }
    $null = Copy-OrtWheelLicenses @licenseParams
} finally {
    $resolvedScratch = (Resolve-Path -LiteralPath $scratch -ErrorAction Stop).ProviderPath
    $scratchPrefix = $scratchParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedScratch.StartsWith($scratchPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a GPU preflight directory outside $scratchParent`: $resolvedScratch"
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force -ErrorAction Stop
}
Write-Host "Windows x64 $Variant ORT input preflight passed. Provider execution and finished packages remain unverified."
