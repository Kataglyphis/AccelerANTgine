#requires -Version 7.0

# Synthetic PE files and wheels test image inputs; they do not establish GPU execution.
Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') -Function New-TestPeFile -ErrorAction Stop

function Assert-GpuPreflightRejected([scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action } catch { $message = $_.Exception.Message }
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
        Assert-GpuPreflightRejected { & $scriptPath -Variant nvidia -OnnxRoot $f.Ort -WheelDir $f.Wheels -TargetArch arm64 -ScratchRoot $f.Scratch } 'ARM GPU packages'
    }

    if ($providerAware) {
        It 'accepts matching x64 AMD inputs and rejects a bad shared bridge or ARM DirectML' {
            $f = New-GpuImageFixture
            & $scriptPath -Variant amd -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch
            New-TestPeFile -Path (Join-Path $f.Bin 'onnxruntime_providers_shared.dll') -Tag 'different bytes'
            Assert-GpuPreflightRejected { & $scriptPath -Variant amd -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'differs from the matching wheel'
            New-TestPeFile -Path (Join-Path $f.Bin 'onnxruntime_providers_shared.dll') -Tag 'onnxruntime_providers_shared.dll'
            New-TestPeFile -Path (Join-Path $f.Bin 'DirectML.dll') -Tag 'different bytes'
            Assert-GpuPreflightRejected { & $scriptPath -Variant amd -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'differs from the matching wheel'
            New-TestPeFile -Path (Join-Path $f.Bin 'DirectML.dll') -Machine 0xAA64
            Assert-GpuPreflightRejected { & $scriptPath -Variant amd -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'PE machine'
            @(Get-ChildItem -LiteralPath $f.Scratch -Force).Count | Should Be 0
        }
        It 'accepts matching x64 NVIDIA inputs and rejects missing, mismatched or ARM providers' {
            $f = New-GpuImageFixture
            & $scriptPath -Variant nvidia -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch
            $provider = Join-Path $f.Bin 'onnxruntime_providers_cuda.dll'
            $libProvider = Join-Path $f.Lib 'onnxruntime_providers_cuda.dll'
            Move-Item -LiteralPath $provider -Destination $libProvider
            & $scriptPath -Variant nvidia -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch
            Move-Item -LiteralPath $libProvider -Destination $provider
            Remove-Item -LiteralPath $provider
            Assert-GpuPreflightRejected { & $scriptPath -Variant nvidia -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'onnxruntime_providers_cuda'
            New-TestPeFile -Path $provider -Machine 0xAA64
            Assert-GpuPreflightRejected { & $scriptPath -Variant nvidia -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'PE machine'
            New-TestPeFile -Path $provider -Tag 'different bytes'
            Assert-GpuPreflightRejected { & $scriptPath -Variant nvidia -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'differs from the matching wheel'
            @(Get-ChildItem -LiteralPath $f.Scratch -Force).Count | Should Be 0
        }
    } else {
        It 'rejects NVIDIA when the recorded hub lacks provider-aware verification' {
            $f = New-GpuImageFixture
            Assert-GpuPreflightRejected { & $scriptPath -Variant nvidia -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'provider-aware ORT wheel verifier|same-wheel DirectML verifier'
        }
        It 'rejects AMD when the recorded hub lacks provider-aware verification' {
            $f = New-GpuImageFixture
            Assert-GpuPreflightRejected { & $scriptPath -Variant amd -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'provider-aware ORT wheel verifier|same-wheel DirectML verifier'
        }
    }

    if ($providerAware) { It 'rejects a missing DirectML redistributable and a wheel mismatch' {
        $f = New-GpuImageFixture
        Remove-Item -LiteralPath (Join-Path $f.Bin 'DirectML.dll')
        Assert-GpuPreflightRejected { & $scriptPath -Variant amd -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'DirectML'
        New-TestPeFile -Path (Join-Path $f.Bin 'DirectML.dll')
        New-TestPeFile -Path (Join-Path $f.Bin 'onnxruntime.dll') -Tag 'different core'
        Assert-GpuPreflightRejected { & $scriptPath -Variant amd -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'matched 0 wheels'
        @(Get-ChildItem -LiteralPath $f.Scratch -Force).Count | Should Be 0
    } }

    It 'refuses an older hub that cannot match provider bytes to the wheel' {
        $f = New-GpuImageFixture
        $repo = Join-Path $f.Scratch 'old-hub'
        $scripts = Join-Path $repo 'scripts\windows'
        $modules = Join-Path $repo 'third_party\ANTfrastructure\windows\scripts\modules'
        $null = New-Item -ItemType Directory -Force -Path $scripts, $modules
        Copy-Item -LiteralPath $scriptPath, (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1') -Destination $scripts
        Set-Content -LiteralPath (Join-Path $modules 'WindowsOrtLicense.Common.psm1') -Value 'function Copy-OrtWheelLicenses { param($OrtDll, $WheelDir, $Destination) }; Export-ModuleMember -Function Copy-OrtWheelLicenses'
        Set-Content -LiteralPath (Join-Path $modules 'WindowsOrtPayload.Common.psm1') -Value 'function Get-ChainOrtRuntimeFile { }; Export-ModuleMember -Function Get-ChainOrtRuntimeFile'
        Set-Content -LiteralPath (Join-Path $modules 'WindowsTargetArch.Common.psm1') -Value 'function Assert-PeTargetMachine { }; Export-ModuleMember -Function Assert-PeTargetMachine'
        Set-Content -LiteralPath (Join-Path $modules 'WindowsScripts.Shared.psm1') -Value '# fixture'
        $oldScript = Join-Path $scripts 'Test-WindowsGpuImage.ps1'
        try {
            Assert-GpuPreflightRejected { & $oldScript -Variant nvidia -OnnxRoot $f.Ort -WheelDir $f.Wheels -ScratchRoot $f.Scratch } 'provider-aware ORT wheel verifier'
        } finally {
            $realModules = Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\modules'
            foreach ($name in 'WindowsTargetArch.Common', 'WindowsOrtLicense.Common', 'WindowsScripts.Shared', 'WindowsOrtPayload.Common') {
                Import-Module (Join-Path $realModules "$name.psm1") -Force -Global -DisableNameChecking
            }
        }
    }
}
