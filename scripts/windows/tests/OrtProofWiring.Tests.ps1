#requires -Version 7.0

# The chain ONNX Runtime staging and the G6 proof of every staged bin\, install tree, MSIX payload and
# the Python package are the hub's WindowsOrtPayload.Common since 2026-09-25; its suite,
# OrtPayload.Common.Tests.ps1, holds the cases this repo's WindowsOrtBundle.Common carried. What stays
# here is how Build-Windows.ps1 wires the proof into the release.
# NOTE: written for Pester 3.4.0 (what the Windows lane pins) - no BeforeAll
# outside Describe, dash-less Should, and no `Should Throw` under pwsh 7.

Describe 'ONNX Runtime proof wiring' {

    It 'proves the install tree CPack packs, after --install and before --target package (mutation)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Build-Windows.ps1'), [ref] $tokens, [ref] $errors)
        $step = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Invoke-BuildStep' -and $n.Extent.Text -match '-StepName "ClangCL Release Build"' }, $true))
        $step.Count | Should Be 1
        $text = $step[0].Extent.Text
        $install = $text.IndexOf('"--install", $fastBuildReleaseDirFull')
        $proof = $text.IndexOf('Assert-ChainOrtTree -Root $installProof -OrtDirectory')
        ($install -ge 0 -and $install -lt $proof -and $proof -lt $text.IndexOf('"--target", "package"')) | Should Be $true
    }

    It 'takes the proof from the hub, which this repo no longer carries a copy of' {
        . (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1')
        (Resolve-BuildModule -Name 'WindowsOrtPayload.Common') | Should Match 'third_party[\\/]ANTfrastructure[\\/]'
        Test-Path (Join-Path $PSScriptRoot '..\modules\WindowsOrtBundle.Common.psm1') | Should Be $false
    }
}
