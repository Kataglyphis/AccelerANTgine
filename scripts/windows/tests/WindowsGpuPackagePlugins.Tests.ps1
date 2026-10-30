#requires -Version 7.0
# The GPU package verifier requires a newer hub than the CPU build's pinned baseline.
$hub = Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure'
$canRun = (Test-Path (Join-Path $hub 'windows\scripts\modules\WindowsPackageBinary.Common.psm1')) -and
    (Test-Path (Join-Path $hub 'linux\scripts\verify_package_binary.py'))

Describe 'Windows GPU GStreamer finished packages' {
    It 'accepts matching plugins and rejects missing or altered ZIP, MSI and MSIX members' -Skip:(-not $canRun) {
        $null = Get-Command 7z, makecab -ErrorAction Stop
        & (Join-Path $PSScriptRoot 'WindowsGpuPackageFixture.ps1') -Scratch $TestDrive
    }
}
