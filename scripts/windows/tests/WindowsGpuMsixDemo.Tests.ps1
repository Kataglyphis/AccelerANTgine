#requires -Version 7.0
BeforeAll {
    # Exercise the actual MSIX staging helper with the build script's selected demo.
    Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') `
        -Function ConvertTo-TestScriptAst -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop
    $script:module = Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\modules\WindowsMsix.Common.psm1') -PassThru -DisableNameChecking
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Build-Windows.ps1') -Raw
    $step = Get-UniqueBuildAstNode -Ast (ConvertTo-TestScriptAst -Text $source) -StepName 'MSIX Packaging'
    $script:selection = @($step.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$demo' -and $node.Right.Extent.Text.Contains('AccelerANTgine_demo.exe') }, $true))
    $script:guard = @($step.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.Contains('Missing packaged inference demo') }, $true))
    $script:addition = @($step.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$payloadExtra' -and $node.Right.Extent.Text -eq '$demo' }, $true))
    if ($script:selection.Count -ne 1 -or $script:guard.Count -ne 1 -or $script:addition.Count -ne 1) { throw 'MSIX demo wiring is missing or ambiguous.' }
}

Describe 'Windows GPU MSIX demo staging' {
    It 'stages the selected demo and rejects a missing source' {
        $payloadDir = Join-Path $TestDrive 'payload'; $stage = Join-Path $TestDrive 'stage'
        $null = New-Item -ItemType Directory -Path $payloadDir
        Set-Content -LiteralPath (Join-Path $payloadDir 'AccelerANTgine_demo.exe') -Value 'demo bytes'
        $payloadExtra = @()
        . ([scriptblock]::Create($script:selection[0].Extent.Text))
        . ([scriptblock]::Create($script:guard[0].Extent.Text))
        . ([scriptblock]::Create($script:addition[0].Extent.Text))
        & $script:module { param($dir, $files) Copy-MsixStageFiles -StagingDir $dir -ExtraFiles $files } $stage $payloadExtra
        (Get-Content -LiteralPath (Join-Path $stage 'AccelerANTgine_demo.exe') -Raw).Trim() | Should -Be 'demo bytes'
        Remove-Item -LiteralPath $demo
        { . ([scriptblock]::Create($script:guard[0].Extent.Text)) } | Should -Throw -ExpectedMessage '*Missing packaged inference demo.*'
    }
}
