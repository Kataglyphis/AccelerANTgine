#requires -Version 7.0
# Centralizes AST selections so absent or ambiguous build wiring fails each suite.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') `
  -Function Get-TestAstCommands -ErrorAction Stop

function Get-UniqueBuildAstNode {
  [CmdletBinding(DefaultParameterSetName = 'Filter')]
  param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory, ParameterSetName = 'Filter')][scriptblock]$Predicate,
        [Parameter(Mandatory, ParameterSetName = 'Filter')][string]$Label,
        [Parameter(Mandatory, ParameterSetName = 'Step')][string]$StepName)
  $nodes = @(if ($PSCmdlet.ParameterSetName -eq 'Step') {
    $Label = "build step '$StepName'"
    @(Get-TestAstCommands -Ast $Ast -Name 'Invoke-BuildStep' | Where-Object { $_.Extent.Text.Contains("-StepName `"$StepName") })
  } else { @($Ast.FindAll($Predicate, $true)) })
  if ($nodes.Count -ne 1) { throw "Expected one $Label, found $($nodes.Count)" }
  return $nodes[0]
}

function Get-BuildFunctionSource {
  param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory)][string]$Name)
  $predicate = { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }.GetNewClosure()
  return (Get-UniqueBuildAstNode -Ast $Ast -Predicate $predicate -Label "function '$Name'").Extent.Text
}

Export-ModuleMember -Function Get-UniqueBuildAstNode, Get-BuildFunctionSource
