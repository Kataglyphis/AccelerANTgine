#requires -Version 7.0
<#
.SYNOPSIS
  Verifies a Windows x64 GPU candidate against its chain runtime and finished installers.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('nvidia', 'amd')][string]$Variant,
    [Parameter(Mandatory)][string]$OnnxRoot,
    [Parameter(Mandatory)][string]$WheelDir,
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$PackageDir,
    [string]$MsixPath = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')
Import-BuildModule @('WindowsMsiLicense.Common', 'WindowsPackageBinary.Common', 'WindowsOrtPayload.Common')

# Re-prove the source immediately before comparing the bytes shipped to users.
& (Join-Path $PSScriptRoot 'Test-WindowsGpuImage.ps1') -Variant $Variant -OnnxRoot $OnnxRoot -WheelDir $WheelDir
$names = @('onnxruntime.dll')
if ($Variant -eq 'nvidia') {
    $names += 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_cuda.dll'
    if (Get-ChainOrtRuntimeFile -OnnxRoot $OnnxRoot -Name 'DirectML.dll' -AllowMissing) { $names += 'DirectML.dll' }
} else {
    $names += 'onnxruntime_providers_shared.dll', 'DirectML.dll'
}
$sources = [string[]]@($names | ForEach-Object { Get-ChainOrtRuntimeFile -OnnxRoot $OnnxRoot -Name $_ })
for ($i = 0; $i -lt $names.Count; $i++) {
    $staged = Join-Path $Bundle "bin\$($names[$i])"
    if (-not (Test-Path -LiteralPath $staged -PathType Leaf) -or
        (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $sources[$i] -Algorithm SHA256).Hash) {
        throw "GPU bundle does not contain the proven $($names[$i]) bytes"
    }
}
$zips = @(Get-ChildItem -LiteralPath $PackageDir -Filter '*.zip' -File)
$msis = @(Get-ChildItem -LiteralPath $PackageDir -Filter '*.msi' -File)
if ($zips.Count -ne 1 -or $msis.Count -ne 1 -or @(Get-ChildItem -LiteralPath $PackageDir -Filter '*.exe' -File).Count) {
    throw 'GPU candidates require exactly one ZIP and MSI and no unverified NSIS installer.'
}
$appNames = @('AccelerANTgine.exe', 'AccelerANTgine_demo.exe', 'AccelerANTgine.dll')
$appSources = [string[]]@($appNames | ForEach-Object { Join-Path $Bundle "bin\$_" })
$packageNames = [string[]]@($names + $appNames)
$pluginDir = Join-Path $Bundle 'lib\gstreamer-1.0'
$plugins = @(Get-ChildItem -LiteralPath $pluginDir -File -ErrorAction Stop | Sort-Object Name)
if ($plugins.Count -eq 0) { throw "GPU bundle has no GStreamer plugins: $pluginDir" }
$pluginMembers = [string[]]@($plugins | ForEach-Object { "lib/gstreamer-1.0/$($_.Name)" })
$bundleMembers = [string[]]@(@($packageNames | ForEach-Object { "bin/$_" }) + $pluginMembers)
$msixMembers = [string[]]@($packageNames + $pluginMembers)
$packageSources = [string[]]@($sources + $appSources + @($plugins | ForEach-Object FullName))
$providers = @($names | Where-Object { $_ -clike 'onnxruntime_providers_*.dll' } | Sort-Object)
$prefix = [IO.Path]::GetFileNameWithoutExtension($zips[0].Name)
Assert-PackageBinary -Path $zips[0].FullName -Member @($bundleMembers | ForEach-Object { "$prefix/$_" }) -SourcePath $packageSources
$zipProviders = @(Get-PackageOrtProviderNames -Path $zips[0].FullName -Directory "$prefix/bin")
if (($providers -join ',') -cne ($zipProviders -join ',')) { throw 'ZIP ORT provider set differs from the proven inputs.' }
$ids = [string[]]@($bundleMembers | ForEach-Object { Get-MsiInstalledFileId -Path $msis[0].FullName -RelativePath $_ -RootDirectoryId 'INSTALL_ROOT' -RootDirectoryName 'AccelerANTgine' })
Assert-PackageBinary -Path $msis[0].FullName -Member $ids -SourcePath $packageSources
$msiProviders = @(Get-PackageOrtProviderNames -Path $msis[0].FullName -Directory 'bin' -RootDirectoryId 'INSTALL_ROOT' -RootDirectoryName 'AccelerANTgine')
if (($providers -join ',') -cne ($msiProviders -join ',')) { throw 'MSI ORT provider set differs from the proven inputs.' }
$licenses = Join-Path $Bundle 'licenses\onnxruntime'
foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
    $id = Get-MsiInstalledFileId -Path $msis[0].FullName -RelativePath "licenses/onnxruntime/$name" -RootDirectoryId 'INSTALL_ROOT' -RootDirectoryName 'AccelerANTgine'
    Assert-PackageLicense -Path $msis[0].FullName -Pattern $id -LicensePath (Join-Path $licenses $name)
}
if ($MsixPath) {
    Assert-PackageBinary -Path $MsixPath -Member $msixMembers -SourcePath $packageSources
    $msixProviders = @(Get-PackageOrtProviderNames -Path $MsixPath -Directory '')
    if (($providers -join ',') -cne ($msixProviders -join ',')) { throw 'MSIX ORT provider set differs from the proven inputs.' }
}
# The source wheel might have changed while packages were being checked.
& (Join-Path $PSScriptRoot 'Test-WindowsGpuImage.ps1') -Variant $Variant -OnnxRoot $OnnxRoot -WheelDir $WheelDir
Write-Host "Windows x64 $Variant GPU package bytes verified; GPU execution remains unverified."
