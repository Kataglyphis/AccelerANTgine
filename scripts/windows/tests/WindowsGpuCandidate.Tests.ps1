#requires -Version 7.0
# This checks the shared candidate helpers with stub commands; it runs no package or GPU check.

Describe 'Windows GPU candidate helpers' {
    Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsGpuCandidate.Common.psm1') -Force -ErrorAction Stop

    It 'removes the scratch directory after success and failure' {
        $seen = Invoke-WithGpuScratchDirectory -Parent $TestDrive -Prefix 'ok' -UnsafeMessage 'unsafe: ' -ScriptBlock { param($scratch) $scratch }
        $seen | Should Match 'ok-'
        (Test-Path -LiteralPath $seen) | Should Be $false
        { Invoke-WithGpuScratchDirectory -Parent $TestDrive -Prefix 'bad' -UnsafeMessage 'unsafe: ' -ScriptBlock { throw 'boom' } } | Should Throw 'boom'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'bad-*').Count | Should Be 0
    }

    It 'lists the variant ORT files with the core first (mutation)' {
        InModuleScope 'WindowsGpuCandidate.Common' {
            function Get-ChainOrtRuntimeFile { param($OnnxRoot, $Name, [switch]$AllowMissing) if ($OnnxRoot -eq 'with-dml') { 'present' } }
            (Get-WindowsGpuOrtName -Variant amd -OnnxRoot 'x') -join ',' | Should Be 'onnxruntime.dll,onnxruntime_providers_shared.dll,DirectML.dll'
            (Get-WindowsGpuOrtName -Variant nvidia -OnnxRoot 'x') -join ',' | Should Be 'onnxruntime.dll,onnxruntime_providers_shared.dll,onnxruntime_providers_cuda.dll'
            (Get-WindowsGpuOrtName -Variant nvidia -OnnxRoot 'with-dml') -join ',' | Should Be 'onnxruntime.dll,onnxruntime_providers_shared.dll,onnxruntime_providers_cuda.dll,DirectML.dll'
        }
    }

    It 'refuses a path of the wrong type with the caller message' {
        { Resolve-GpuCandidatePath -Path $TestDrive -PathType Leaf -Failure 'Not a file: ' } | Should Throw 'Not a file: '
        (Resolve-GpuCandidatePath -Path $TestDrive -PathType Container -Failure 'unused') | Should Be (Resolve-Path -LiteralPath $TestDrive).ProviderPath
    }

    It 'names a missing wheel verifier parameter' {
        InModuleScope 'WindowsGpuCandidate.Common' {
            function Copy-OrtWheelLicenses { param($OrtDll) }
            { Assert-OrtWheelVerifierParameter -Name 'ProviderDll' -Message 'needs provider' } | Should Throw 'needs provider'
            { Assert-OrtWheelVerifierParameter -Name 'OrtDll' -Message 'unused' } | Should Not Throw
        }
    }
}
