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
    'shared/python/verify_locked_files.py', 'linux/scripts/lib/fetch-data-lock.py',
    'windows/scripts/diagnostics/verify-dxgi-adapter.py') {
    if (-not (Test-Path -LiteralPath (Join-Path $hub $path) -PathType Leaf)) {
        throw "Windows GPU candidates need ANTfrastructure's $path."
    }
}
$fetcher = Get-Content -LiteralPath (Join-Path $hub 'linux/scripts/lib/fetch-data-lock.py') -Raw
if ($fetcher -cnotmatch '(?m)^def read_lock\(' -or $fetcher -cnotmatch '(?m)^def matches\(') {
    throw 'Windows GPU candidates need the locked-model fetcher verification APIs.'
}
try { Import-BuildModule @('WindowsOrtLicense.Common', 'WindowsMsiLicense.Common', 'WindowsPackageBinary.Common', 'WindowsOrtPayload.Common', 'WindowsGpuCandidate.Common') }
catch { throw "Windows GPU candidates need ANTfrastructure's finished-package and wheel verification APIs. $($_.Exception.Message)" }
Assert-OrtWheelVerifierParameter -Name 'ProviderDll' -Message 'Windows GPU candidates need provider-aware ORT wheel verification.'
Assert-OrtWheelVerifierParameter -Name 'DirectMlDll' -Message 'Windows GPU candidates need same-wheel DirectML verification.'
foreach ($command in 'Assert-PackageBinary', 'Get-PackageOrtProviderNames', 'Assert-PackageOrtFamily', 'Get-MsiInstalledFileId', 'Assert-PackageLicense', 'Get-ChainOrtRuntimeFile') {
    $null = Get-Command -Name $command -ErrorAction Stop
}
if (-not (Get-Command Get-MsiInstalledFileId).Parameters.ContainsKey('RootDirectoryId') -or
    -not (Get-Command Get-MsiInstalledFileId).Parameters.ContainsKey('RootDirectoryName')) {
    throw 'Windows GPU candidates require MSI install-root-aware verification.'
}
Write-Host 'Pinned ANTfrastructure provides the Windows GPU package verification APIs.'
