#requires -Version 7.0

# Synthetic PE files and wheels test image inputs; they do not establish GPU execution.
Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') -Function New-TestPeFile -ErrorAction Stop

function Invoke-GpuPreflight([hashtable]$Fixture, [string]$Variant, [string]$Script = $scriptPath, [hashtable]$Extra = @{}) {
    & $Script -Variant $Variant -OnnxRoot $Fixture.Ort -WheelDir $Fixture.Wheels -ScratchRoot $Fixture.Scratch @Extra
}

function Assert-FixtureScratchEmpty([hashtable]$Fixture) {
    @(Get-ChildItem -LiteralPath $Fixture.Scratch -Force).Count | Should Be 0
}

function Write-FixtureAlteredInput([hashtable]$Fixture, [string]$Name, [string]$Tag = 'different bytes') {
    New-TestPeFile -Path (Join-Path $Fixture.Bin $Name) -Tag $Tag
}

function Assert-FixtureRejected {
    param([hashtable]$Fixture, [string]$Variant, [string]$Pattern, [string]$Script = $scriptPath, [string]$TargetArch = 'amd64')
    $message = ''
    try { Invoke-GpuPreflight $Fixture $Variant $Script @{ TargetArch = $TargetArch } } catch { $message = $_.Exception.Message }
    if ($message -notmatch $Pattern) { throw "Expected '$Pattern', got '$message'" }
}

function New-GpuImageFixture {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $bin = Join-Path $root 'ort\bin'
    $lib = Join-Path $root 'ort\lib'
    $wheels = Join-Path $root 'wheels'
    $scratch = Join-Path $root 'scratch'
    $null = New-Item -ItemType Directory -Path $bin, $lib, $wheels, $scratch -Force
    foreach ($name in 'onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_cuda.dll', 'DirectML.dll') {
        New-TestPeFile -Path (Join-Path $bin $name) -Tag $name
    }
    $wheel = Join-Path $wheels 'onnxruntime_gpu-1.0.0-cp315-cp315-win_amd64.whl'
    $zip = [IO.Compression.ZipFile]::Open($wheel, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in 'onnxruntime.dll', 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_cuda.dll', 'DirectML.dll') {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $bin $name), "onnxruntime/capi/$name") | Out-Null
        }
        foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
            $entry = $zip.CreateEntry("onnxruntime/$name")
            $writer = [IO.StreamWriter]::new($entry.Open())
            try { $writer.Write('fixture text') } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    return @{ Ort = (Join-Path $root 'ort'); Bin = $bin; Lib = $lib; Wheels = $wheels; Scratch = $scratch }
}

Describe 'Windows GPU image preflight' {
    $scriptPath = Join-Path $PSScriptRoot '..\Test-WindowsGpuImage.ps1'
    Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\modules\WindowsOrtLicense.Common.psm1') -DisableNameChecking -ErrorAction Stop
    $providerAware = (Get-Command Copy-OrtWheelLicenses).Parameters.ContainsKey('ProviderDll') -and
        (Get-Command Copy-OrtWheelLicenses).Parameters.ContainsKey('DirectMlDll')

    It 'rejects ARM targets' {
        $f = New-GpuImageFixture
        Assert-FixtureRejected $f nvidia -TargetArch arm64 'ARM GPU packages'
    }

    if ($providerAware) {
        It 'accepts matching x64 AMD inputs and rejects a bad shared bridge or ARM DirectML' {
            $f = New-GpuImageFixture
            Invoke-GpuPreflight $f amd
            Write-FixtureAlteredInput $f 'onnxruntime_providers_shared.dll' 'different bytes'
            Assert-FixtureRejected $f amd 'differs from the matching wheel'
            Write-FixtureAlteredInput $f 'onnxruntime_providers_shared.dll' 'onnxruntime_providers_shared.dll'
            Write-FixtureAlteredInput $f 'DirectML.dll' 'different bytes'
            Assert-FixtureRejected $f amd 'differs from the matching wheel'
            New-TestPeFile -Path (Join-Path $f.Bin 'DirectML.dll') -Machine 0xAA64
            Assert-FixtureRejected $f amd 'PE machine'
            Assert-FixtureScratchEmpty $f
        }
        It 'accepts matching x64 NVIDIA inputs and rejects missing, mismatched or ARM providers' {
            $f = New-GpuImageFixture
            Invoke-GpuPreflight $f nvidia
            $provider = Join-Path $f.Bin 'onnxruntime_providers_cuda.dll'
            $libProvider = Join-Path $f.Lib 'onnxruntime_providers_cuda.dll'
            Move-Item -LiteralPath $provider -Destination $libProvider
            Invoke-GpuPreflight $f nvidia
            Move-Item -LiteralPath $libProvider -Destination $provider
            Remove-Item -LiteralPath $provider
            Assert-FixtureRejected $f nvidia 'onnxruntime_providers_cuda'
            New-TestPeFile -Path $provider -Machine 0xAA64
            Assert-FixtureRejected $f nvidia 'PE machine'
            New-TestPeFile -Path $provider -Tag 'different bytes'
            Assert-FixtureRejected $f nvidia 'differs from the matching wheel'
            Assert-FixtureScratchEmpty $f
        }
    } else {
        It 'rejects NVIDIA when the recorded hub lacks provider-aware verification' {
            $f = New-GpuImageFixture
            Assert-FixtureRejected $f nvidia 'provider-aware ORT wheel verifier|same-wheel DirectML verifier'
        }
        It 'rejects AMD when the recorded hub lacks provider-aware verification' {
            $f = New-GpuImageFixture
            Assert-FixtureRejected $f amd 'provider-aware ORT wheel verifier|same-wheel DirectML verifier'
        }
    }

    if ($providerAware) { It 'rejects a missing DirectML redistributable and a wheel mismatch' {
        $f = New-GpuImageFixture
        Remove-Item -LiteralPath (Join-Path $f.Bin 'DirectML.dll')
        Assert-FixtureRejected $f amd 'DirectML'
        New-TestPeFile -Path (Join-Path $f.Bin 'DirectML.dll')
        Write-FixtureAlteredInput $f 'onnxruntime.dll' 'different core'
        Assert-FixtureRejected $f amd 'matched 0 wheels'
        Assert-FixtureScratchEmpty $f
    } }

    It 'refuses an older hub that cannot match provider bytes to the wheel' {
        $f = New-GpuImageFixture
        $repo = Join-Path $f.Scratch 'old-hub'
        $scripts = Join-Path $repo 'scripts\windows'
        $modules = Join-Path $repo 'third_party\ANTfrastructure\windows\scripts\modules'
        $null = New-Item -ItemType Directory -Force -Path $scripts, $modules
        Copy-Item -LiteralPath $scriptPath, (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1') -Destination $scripts
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\modules\WindowsGpuCandidate.Common.psm1') -Destination $modules
        $stubs = @{
            'WindowsOrtLicense.Common' = 'function Copy-OrtWheelLicenses { param($OrtDll, $WheelDir, $Destination) }; Export-ModuleMember -Function Copy-OrtWheelLicenses'
            'WindowsOrtPayload.Common' = 'function Get-ChainOrtRuntimeFile { }; Export-ModuleMember -Function Get-ChainOrtRuntimeFile'
            'WindowsTargetArch.Common' = 'function Assert-PeTargetMachine { }; Export-ModuleMember -Function Assert-PeTargetMachine'
            'WindowsScripts.Shared' = '# fixture'
        }
        foreach ($stub in $stubs.GetEnumerator()) { Set-Content -LiteralPath (Join-Path $modules "$($stub.Key).psm1") -Value $stub.Value }
        $oldScript = Join-Path $scripts 'Test-WindowsGpuImage.ps1'
        try {
            Assert-FixtureRejected $f nvidia -Script $oldScript 'provider-aware ORT wheel verifier'
        } finally {
            $realModules = Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\modules'
            foreach ($name in 'WindowsTargetArch.Common', 'WindowsOrtLicense.Common', 'WindowsScripts.Shared', 'WindowsOrtPayload.Common') {
                Import-Module (Join-Path $realModules "$name.psm1") -Force -Global -DisableNameChecking
            }
        }
    }
}
