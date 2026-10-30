#requires -Version 7.0
<#
.SYNOPSIS
  Refuses a pinned infrastructure checkout that cannot prove Windows GPU packages.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')
$hub = Join-Path $PSScriptRoot '../../third_party/ANTfrastructure'
foreach ($path in 'shared/python/verify_ort_profile.py', 'shared/python/tests/test_verify_ort_profile.py',
    'windows/scripts/diagnostics/verify-dxgi-adapter.py') {
    if (-not (Test-Path -LiteralPath (Join-Path $hub $path) -PathType Leaf)) {
        throw "Windows GPU candidates need ANTfrastructure's $path."
    }
}
try { Import-BuildModule @('WindowsOrtLicense.Common', 'WindowsMsiLicense.Common', 'WindowsPackageBinary.Common', 'WindowsOrtPayload.Common') }
catch { throw "Windows GPU candidates need ANTfrastructure's finished-package and wheel verification APIs. $($_.Exception.Message)" }
if (-not (Get-Command Copy-OrtWheelLicenses).Parameters.ContainsKey('ProviderDll')) {
    throw 'Windows GPU candidates need provider-aware ORT wheel verification.'
}
if (-not (Get-Command Copy-OrtWheelLicenses).Parameters.ContainsKey('DirectMlDll')) {
    throw 'Windows GPU candidates need same-wheel DirectML verification.'
}
foreach ($command in 'Assert-PackageBinary', 'Get-PackageOrtProviderNames', 'Get-MsiInstalledFileId', 'Assert-PackageLicense', 'Get-ChainOrtRuntimeFile') {
    $null = Get-Command -Name $command -ErrorAction Stop
}
if (-not (Get-Command Get-MsiInstalledFileId).Parameters.ContainsKey('RootDirectoryId') -or
    -not (Get-Command Get-MsiInstalledFileId).Parameters.ContainsKey('RootDirectoryName')) {
    throw 'Windows GPU candidates require MSI install-root-aware verification.'
}
Write-Host 'Pinned ANTfrastructure provides the Windows GPU package verification APIs.'
