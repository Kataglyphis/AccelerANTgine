#requires -Version 7.0
# Centralizes AST selections so absent or ambiguous build wiring fails each suite.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') `
  -Function Get-TestAstCommands, Get-TestScriptAst, Get-TestCommandArguments -ErrorAction Stop

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

# Unbound, so the caller's dot-source defines the build function in the caller's scope.
function Get-BuildFunctionBlock([string]$Name) {
  return [scriptblock]::Create((Get-BuildFunctionSource -Ast (Get-BuildScriptAst) -Name $Name))
}

function Get-BuildScriptAst {
  param([string]$Path = (Join-Path $PSScriptRoot '..\Build-Windows.ps1'))
  return Get-TestScriptAst -ScriptPath $Path
}

function Get-BuildScriptParameter($Ast, [string]$Name) {
  $parameters = @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
  if ($parameters.Count -ne 1) { throw "Expected one script parameter '$Name', found $($parameters.Count)" }
  return $parameters[0]
}

function Get-SingleCommandArguments {
  param([object[]]$Commands = @(), [Parameter(Mandatory)][string]$Failure)
  if ($Commands.Count -ne 1) { throw $Failure }
  return Get-TestCommandArguments -Command $Commands[0]
}

# Usage: one call among Commands whose named arguments equal Expected, or the matching failure.
function Assert-SingleCommandArguments {
  param([object[]]$Commands = @(), [Parameter(Mandatory)][hashtable]$Expected, [Parameter(Mandatory)][string]$CountFailure, [Parameter(Mandatory)][string]$ValueFailure)
  $arguments = Get-SingleCommandArguments -Commands $Commands -Failure $CountFailure
  foreach ($name in $Expected.Keys) {
    if ($arguments.$name -ne $Expected[$name]) { throw $ValueFailure }
  }
}

# Throws unless every marker occurs in Text, in the given order.
function Assert-TextOrder {
  param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string[]]$Marker)
  $last = -1
  foreach ($item in $Marker) {
    $at = $Text.IndexOf($item)
    if ($at -le $last) { throw "Expected '$item' after position $last, found $at" }
    $last = $at
  }
}

Export-ModuleMember -Function Get-UniqueBuildAstNode, Get-BuildFunctionSource, Get-BuildFunctionBlock, Get-BuildScriptAst,
  Get-BuildScriptParameter, Get-SingleCommandArguments, Assert-SingleCommandArguments, Assert-TextOrder, Get-TestAstCommands
