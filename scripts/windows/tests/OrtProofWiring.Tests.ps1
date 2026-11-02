#requires -Version 7.0

# This checks G6 build wiring and parse failures, not a running Windows build.

Describe 'ONNX Runtime proof wiring' {
    Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop

    # The one Invoke-BuildStep whose -StepName starts with $StepName, as an AST; a step that is gone or doubled throws.
    function Get-BuildStep([string]$StepName, [hashtable]$Source = @{}) {
        return Get-UniqueBuildAstNode -Ast (Get-BuildScriptAst @Source) -StepName $StepName
    }

    It 'rejects a malformed build script before accepting its step (mutation)' {
        $broken = Join-Path $TestDrive 'Build-Windows.ps1'
        Set-Content -LiteralPath $broken -Value @('Invoke-BuildStep -StepName "ClangCL Release Build" -Script {}', 'if (')
        $message = ''
        try { $null = Get-BuildStep -StepName 'ClangCL Release Build' -Source @{ Path = $broken } } catch { $message = $_.Exception.Message }
        $message | Should Match 'parse errors'
    }

    It 'proves the install tree CPack packs, after --install and before --target package (mutation)' {
        $text = (Get-BuildStep 'ClangCL Release Build').Extent.Text
        Assert-TextOrder -Text $text -Marker '"--install", $fastBuildReleaseDirFull', 'Assert-ChainOrtTree -Root $installProof -OrtDirectory', '"--target", "package"'
    }

    It 'proves the portable bundle after New-PortableBundle made it, which refuses an incomplete install tree (mutation)' {
        $step = Get-BuildStep 'Portable Bundle ('
        Assert-TextOrder -Text $step.Extent.Text -Marker 'New-PortableBundle ', 'Assert-ChainOrtTree -Root $portable.Bundle'
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
