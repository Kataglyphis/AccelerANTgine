#requires -Version 7.0
# This runs the shared build-step helpers against stubs; it builds nothing and runs no GPU check.

Describe 'Windows build step helpers' {
    Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop
    . (Get-BuildFunctionBlock 'Assert-GpuCandidatePackage')
    . (Get-BuildFunctionBlock 'Invoke-BuildTreeStep')

    It 'checks only a GPU candidate and forwards an MSIX only when the step names one (mutation)' {
        $checks = [Collections.Generic.List[string]]::new()
        function Invoke-GpuCandidateCheck { param($Name, $Arguments) $checks.Add("$Name $(@($Arguments.Keys | Sort-Object) -join ',')") }
        Set-Variable -Name OrtVariant -Value 'cpu'
        Assert-GpuCandidatePackage -Bundle 'bundle' -PackageDir 'packages' -MsixPath 'app.msix'
        Set-Variable -Name OrtVariant -Value 'nvidia'
        Assert-GpuCandidatePackage -Bundle 'bundle' -PackageDir 'packages'
        Assert-GpuCandidatePackage -Bundle 'bundle' -PackageDir 'packages' -MsixPath 'app.msix'
        ($checks -join ';') | Should Be 'Test-WindowsGpuPackages.ps1 Bundle,PackageDir;Test-WindowsGpuPackages.ps1 Bundle,MsixPath,PackageDir'
    }

    It 'runs a build-tree step inside its tree and returns the caller to its directory, also after a failure (mutation)' {
        # Unnamed arguments: a stub parameter named Script would shadow the helper's own inside the step block.
        function Invoke-BuildStep { & $args[-1] }
        $tree = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'tree')).FullName
        $before = (Get-Location).ProviderPath
        (Invoke-BuildTreeStep -StepName 'tree' -BuildRoot $tree -Script { (Get-Location).ProviderPath }) | Should Be $tree
        (Get-Location).ProviderPath | Should Be $before
        { Invoke-BuildTreeStep -StepName 'tree' -BuildRoot $tree -Script { throw 'step failed' } } | Should Throw 'step failed'
        (Get-Location).ProviderPath | Should Be $before
    }
}
