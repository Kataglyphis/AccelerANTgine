#requires -Version 7.0

# How Build-Windows.ps1 wires the hub's G6 proof in; Pester 3.4.0 syntax (dash-less Should, no `Should Throw` under pwsh 7).

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
