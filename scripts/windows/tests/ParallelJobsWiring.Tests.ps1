#requires -Version 7.0

Describe 'Windows build parallelism' {
    Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') -Function Get-TestScriptAst, Get-TestAstCommands -ErrorAction Stop

    It 'keeps the default unlimited and forwards an explicit limit to every CMake build' {
        $ast = Get-TestScriptAst -ScriptPath (Join-Path $PSScriptRoot '..\Build-Windows.ps1')
        $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ParallelJobs' })
        if ($parameter.Count -ne 1 -or $parameter[0].DefaultValue.Extent.Text -ne '0') {
            throw 'ParallelJobs must default to 0.'
        }
        $calls = @(Get-TestAstCommands -Ast $ast -Name 'Invoke-CmakeConfigureAndBuild')
        if ($calls.Count -ne 4 -or @($calls | Where-Object { $_.Extent.Text -match '-ParallelJobs\s+\$ParallelJobs' }).Count -ne 4) {
            throw 'Each Windows CMake build must receive ParallelJobs.'
        }
    }
}
