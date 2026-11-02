#requires -Version 7.0

Describe 'Windows build parallelism' {
    Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop

    It 'keeps the default unlimited and forwards an explicit limit to every CMake build, Debug and Profile through one step' {
        $ast = Get-BuildScriptAst
        (Get-BuildScriptParameter -Ast $ast -Name 'ParallelJobs').DefaultValue.Extent.Text | Should Be '0'
        $calls = @(Get-TestAstCommands -Ast $ast -Name 'Invoke-CmakeConfigureAndBuild')
        if ($calls.Count -ne 3 -or @($calls | Where-Object { $_.Extent.Text -match '-ParallelJobs\s+\$ParallelJobs' }).Count -ne 3) {
            throw 'Each Windows CMake build must receive ParallelJobs.'
        }
    }
}
