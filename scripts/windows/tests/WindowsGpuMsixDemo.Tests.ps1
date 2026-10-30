#requires -Version 7.0
# Exercise the actual MSIX staging helper with the build script's selected demo.
Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') `
    -Function ConvertTo-TestScriptAst -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop
$module = Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\modules\WindowsMsix.Common.psm1') -PassThru -DisableNameChecking
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Build-Windows.ps1') -Raw
$step = Get-UniqueBuildAstNode -Ast (ConvertTo-TestScriptAst -Text $source) -StepName 'MSIX Packaging'
$selection = @($step.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$demo' -and $node.Right.Extent.Text.Contains('AccelerANTgine_demo.exe') }, $true))
$guard = @($step.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.Contains('Missing packaged inference demo') }, $true))
$addition = @($step.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$payloadExtra' -and $node.Right.Extent.Text -eq '$demo' }, $true))
if ($selection.Count -ne 1 -or $guard.Count -ne 1 -or $addition.Count -ne 1) { throw 'MSIX demo wiring is missing or ambiguous.' }

Describe 'Windows GPU MSIX demo staging' {
    It 'stages the selected demo and rejects a missing source' {
        $payloadDir = Join-Path $TestDrive 'payload'; $stage = Join-Path $TestDrive 'stage'
        $null = New-Item -ItemType Directory -Path $payloadDir
        Set-Content -LiteralPath (Join-Path $payloadDir 'AccelerANTgine_demo.exe') -Value 'demo bytes'
        $payloadExtra = @()
        . ([scriptblock]::Create($selection[0].Extent.Text))
        . ([scriptblock]::Create($guard[0].Extent.Text))
        . ([scriptblock]::Create($addition[0].Extent.Text))
        & $module { param($dir, $files) Copy-MsixStageFiles -StagingDir $dir -ExtraFiles $files } $stage $payloadExtra
        (Get-Content -LiteralPath (Join-Path $stage 'AccelerANTgine_demo.exe') -Raw).Trim() | Should Be 'demo bytes'
        Remove-Item -LiteralPath $demo
        { . ([scriptblock]::Create($guard[0].Extent.Text)) } | Should Throw 'Missing packaged inference demo.'
    }
}
