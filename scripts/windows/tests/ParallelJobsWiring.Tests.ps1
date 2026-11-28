#requires -Version 7.0

Describe 'Windows build parallelism' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop
    }

    It 'keeps the default unlimited and forwards an explicit limit to every CMake build through one helper, Debug and Profile through one step' {
        $ast = Get-BuildScriptAst
        (Get-BuildScriptParameter -Ast $ast -Name 'ParallelJobs').DefaultValue.Extent.Text | Should -Be '0'
        $calls = @(Get-TestAstCommands -Ast $ast -Name 'Invoke-CmakeConfigureAndBuild')
        $helper = Get-BuildFunctionSource -Ast $ast -Name 'Invoke-WorkspaceCmakeBuild'
        if ($calls.Count -ne 1 -or -not $helper.Contains($calls[0].Extent.Text) -or $calls[0].Extent.Text -notmatch '-ParallelJobs\s+\$ParallelJobs') {
            throw 'Each Windows CMake build must go through Invoke-WorkspaceCmakeBuild, which forwards ParallelJobs.'
        }
        @(Get-TestAstCommands -Ast $ast -Name 'Invoke-WorkspaceCmakeBuild').Count | Should -Be 3
    }
}
