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
Import-BuildModule @('WindowsTargetArch.Common', 'WindowsOrtLicense.Common', 'WindowsOrtPayload.Common', 'WindowsGpuCandidate.Common')
Assert-OrtWheelVerifierParameter -Name 'ProviderDll' -Message "GPU preflight requires ANTfrastructure's provider-aware ORT wheel verifier."
Assert-OrtWheelVerifierParameter -Name 'DirectMlDll' -Message "GPU preflight requires ANTfrastructure's same-wheel DirectML verifier."
if (-not (Get-Command Get-ChainOrtRuntimeFile -ErrorAction SilentlyContinue)) {
    throw "GPU preflight requires ANTfrastructure's chain runtime file resolver."
}
$names = @(Get-WindowsGpuOrtName -Variant $Variant -OnnxRoot $OnnxRoot)
$files = @($names | ForEach-Object {
        $path = Get-ChainOrtRuntimeFile -OnnxRoot $OnnxRoot -Name $_
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.PSIsContainer -or $item.Length -eq 0) { throw "Required ORT input is empty or not a file: $path" }
        $item.FullName
    })
$null = Assert-PeTargetMachine -Path $files -Arch 'amd64' -Context 'Windows GPU packages require x64 inputs'

# The shared verifier needs a destination for the wheel's notices; keep it out of the source image.
$scratchParent = Resolve-GpuCandidatePath -Path $ScratchRoot -PathType Container -Failure 'Scratch root is not a directory: '
$unsafe = "Refusing to clean a GPU preflight directory outside $scratchParent`: "
Invoke-WithGpuScratchDirectory -Parent $scratchParent -Prefix 'accelerantgine-gpu-preflight' -UnsafeMessage $unsafe -ScriptBlock {
    param($scratch)
    $licenseParams = @{ OrtDll = $files[0]; WheelDir = $WheelDir; Destination = $scratch }
    $licenseParams.ProviderDll = [string[]]@(if ($Variant -eq 'nvidia') { $files[1], $files[2] } else { $files[1] })
    $directMlIndex = [array]::IndexOf($names, 'DirectML.dll')
    if ($directMlIndex -ge 0) { $licenseParams.DirectMlDll = $files[$directMlIndex] }
    $null = Copy-OrtWheelLicenses @licenseParams
}
Write-Host "Windows x64 $Variant ORT input preflight passed. Provider execution and finished packages remain unverified."
