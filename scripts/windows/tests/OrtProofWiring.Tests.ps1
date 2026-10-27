#requires -Version 7.0

# This checks G6 build wiring and parse failures, not a running Windows build.

Describe 'ONNX Runtime proof wiring' {
    Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') -Function Get-TestScriptAst, Get-TestAstCommands -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop

    # The one Invoke-BuildStep whose -StepName starts with $StepName, as an AST; a step that is gone or doubled throws.
    function Get-BuildStep([string]$StepName, [string]$BuildScriptPath = '') {
        $source = if ($BuildScriptPath) { $BuildScriptPath } else { Join-Path $PSScriptRoot '..\Build-Windows.ps1' }
        $ast = Get-TestScriptAst -ScriptPath $source
        return Get-UniqueBuildAstNode -Ast $ast -StepName $StepName
    }

    It 'rejects a malformed build script before accepting its step (mutation)' {
        $broken = Join-Path $TestDrive 'Build-Windows.ps1'
        Set-Content -LiteralPath $broken -Value @('Invoke-BuildStep -StepName "ClangCL Release Build" -Script {}', 'if (')
        $message = ''
        try { $null = Get-BuildStep -StepName 'ClangCL Release Build' -BuildScriptPath $broken } catch { $message = $_.Exception.Message }
        $message | Should Match 'parse errors'
    }

    It 'proves the install tree CPack packs, after --install and before --target package (mutation)' {
        $text = (Get-BuildStep 'ClangCL Release Build').Extent.Text
        $install = $text.IndexOf('"--install", $fastBuildReleaseDirFull')
        $proof = $text.IndexOf('Assert-ChainOrtTree -Root $installProof -OrtDirectory')
        ($install -ge 0 -and $install -lt $proof -and $proof -lt $text.IndexOf('"--target", "package"')) | Should Be $true
    }

    It 'proves the portable bundle after New-PortableBundle made it, which refuses an incomplete install tree (mutation)' {
        $step = Get-BuildStep 'Portable Bundle ('
        $text = $step.Extent.Text
        $bundle = $text.IndexOf('New-PortableBundle ')
        $proof = $text.IndexOf('Assert-ChainOrtTree -Root $portable.Bundle')
        ($bundle -ge 0 -and $bundle -lt $proof) | Should Be $true
        $call = @(Get-TestAstCommands -Ast $step -Name 'New-PortableBundle')
        $switches = @($call | ForEach-Object { $_.CommandElements } | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                ForEach-Object ParameterName)
        ($switches -contains 'RequireCompleteInstall') | Should Be $true
    }

    It 'takes the proof from the hub, which this repo no longer carries a copy of' {
        . (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1')
        (Resolve-BuildModule -Name 'WindowsOrtPayload.Common') | Should Match 'third_party[\\/]ANTfrastructure[\\/]'
        Test-Path (Join-Path $PSScriptRoot '..\modules\WindowsOrtBundle.Common.psm1') | Should Be $false
    }
}
