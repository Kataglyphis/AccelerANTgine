#requires -Version 7.0
# This checks the MSIX license call sites, not a completed Windows package.
Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') `
  -Function ConvertTo-TestScriptAst, Get-TestAstCommands, Get-TestAstAncestor, Get-TestCommandArguments, Assert-Throws -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop

function Get-MsixScriptModel([string]$Source) {
  $ast = ConvertTo-TestScriptAst -Text $Source
  return [pscustomobject]@{
    Step = Get-UniqueBuildAstNode -Ast $ast -StepName 'MSIX Packaging'
    Copies = @(Get-TestAstCommands -Ast $ast -Name 'Copy-PackageLicense')
    Checks = @(Get-TestAstCommands -Ast $ast -Name 'Invoke-BuildExternal' | Where-Object { $_.Extent.Text.Contains('$licenseVerifier') })
    OrtCopies = @(Get-TestAstCommands -Ast $ast -Name 'Copy-OrtWheelLicenses')
    OrtChecks = @(Get-TestAstCommands -Ast $ast -Name 'Assert-OrtWheelLicensesInPackage')
  }
}

function Assert-MsixLicenseWiring([string]$Source) {
  $model = Get-MsixScriptModel $Source
  $copies = $model.Copies
  if ($copies.Count -ne 1) { throw 'Expected one MSIX project license staging call' }
  $copyArgs = Get-TestCommandArguments -Command $copies[0]
  if ($copyArgs.Path -ne '$licenseSource' -or $copyArgs.Destination -ne '$payloadDir') { throw 'Wrong MSIX license source or destination' }
  $checks = $model.Checks
  if ($checks.Count -ne 1 -or -not $checks[0].Extent.Text.Contains('$msixFile')) { throw 'Expected the completed MSIX license check' }
  $ortCopies = $model.OrtCopies
  $ortChecks = $model.OrtChecks
  if ($ortCopies.Count -ne 2 -or $ortChecks.Count -ne 3 -or @($ortChecks | Where-Object { $_.Extent.Text.Contains('$msixFile') }).Count -ne 1) { throw 'Expected ONNX license staging and checks for the install tree, ZIP and MSIX' }
}

function Assert-OrtInstallLicenseWiring([string]$Source) {
  foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
    if (-not $Source.Contains(('${KATAGLYPHIS_PACKAGE_DLL_DIR}/licenses/onnxruntime/' + $name))) { throw "Missing ONNX install text: $name" }
  }
}

function Invoke-MsixInputGuard([string]$Source, [hashtable]$Scenario) {
  $Name = $Scenario.Name
  $Root = $Scenario.Root
  $step = (Get-MsixScriptModel $Source).Step
  $predicate = {
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
      $node.Clauses[0].Item1.Extent.Text.Contains('$' + $Name)
  }.GetNewClosure()
  $guard = Get-UniqueBuildAstNode -Ast $step -Predicate $predicate -Label "MSIX guard for $Name"
  $inputs = @{
    makeappx = 'makeappx.exe'
    msixTemplate = Join-Path $Root 'AppxManifest.xml'
    logoSource = Join-Path $Root 'logo.png'
    Context = $null
  }
  function Write-BuildLogWarning { param($Context, $Message) }
  if ($Scenario.Missing) {
    switch ($Name) {
      'makeappx' { $inputs.makeappx = '' }
      'msixTemplate' { $inputs.msixTemplate = Join-Path $Root 'missing.xml' }
      'logoSource' { $inputs.logoSource = Join-Path $Root 'missing.png' }
    }
  }
  foreach ($inputBinding in $inputs.GetEnumerator()) { Set-Variable -Name $inputBinding.Key -Value $inputBinding.Value }
  & ([scriptblock]::Create($guard.Extent.Text))
}

function Invoke-MsixStepSelection([string]$Source, [bool]$Skip) {
  $gate = Get-TestAstAncestor -Node (Get-MsixScriptModel $Source).Step -Type ([System.Management.Automation.Language.IfStatementAst]) -First
  if ($null -eq $gate -or -not $gate.Clauses[0].Item1.Extent.Text.Contains('$SkipMSIX')) { throw 'Expected the explicit MSIX skip gate' }
  Set-Variable -Name SkipMSIX -Value $Skip
  $Context = $null
  $script:MsixStepCalls = 0
  function Invoke-BuildStep {
    param($Context, $StepName, [switch]$Critical, [scriptblock]$Script)
    if (-not $Critical) { throw 'Selected MSIX must be a critical build step' }
    $script:MsixStepCalls++
  }
  & ([scriptblock]::Create($gate.Extent.Text))
  return $script:MsixStepCalls
}

function Assert-MsixStepSelection([string]$Source) {
  if ((Invoke-MsixStepSelection -Source $Source -Skip $true) -ne 0 -or
      (Invoke-MsixStepSelection -Source $Source -Skip $false) -ne 1) {
    throw 'MSIX skip selection did not preserve the requested behavior'
  }
}

function Assert-MsixGuardMutation([string]$Source, [string]$Find, [string]$Replace, [hashtable]$Scenario) {
  $mutant = $Source.Replace($Find, $Replace)
  if ($mutant -eq $Source) { throw "Mutation anchor missing for $($Scenario.Name)" }
  Assert-Throws -Body {
    Assert-Throws -Body { Invoke-MsixInputGuard -Source $mutant -Scenario $Scenario } -MessagePattern 'required|not found'
  } -MessagePattern 'expected an exception'
}

function Assert-MsixInputCases([string]$Source, [string[]]$Names, [string]$Root, [bool]$Missing, [switch]$MutatePath) {
  foreach ($name in $Names) {
    $scenario = @{ Name = $name; Root = $Root; Missing = $Missing }
    Assert-Throws -Body { Invoke-MsixInputGuard -Source $Source -Scenario $scenario } -MessagePattern 'required|not found'
    if ($MutatePath) {
      $check = 'Test-Path -LiteralPath $' + $name
      Assert-MsixGuardMutation -Source $Source -Find ($check + ' -PathType Leaf') -Replace $check -Scenario $scenario
    }
  }
}

Describe 'MSIX project license wiring' {
  $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Build-Windows.ps1') -Raw

  It 'stages and checks the project license' { Assert-MsixLicenseWiring $source }

  It 'rejects removing either the staging call or the artifact check' {
    $model = Get-MsixScriptModel $source
    $copy = $model.Copies[0]
    $check = $model.Checks[0]
    $ortCopies = $model.OrtCopies
    $ortChecks = $model.OrtChecks
    foreach ($call in @($copy, $check) + $ortCopies + $ortChecks) {
      $mutant = $source.Replace($call.Extent.Text, "Write-Output 'removed'")
      $mutant | Should Not Be $source
      Assert-Throws -Body { Assert-MsixLicenseWiring $mutant } -MessagePattern 'license'
    }
  }

  It 'installs both ONNX texts from the matched package build' {
    $cmake = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\cmake\SystemLibDependencies.cmake') -Raw
    Assert-OrtInstallLicenseWiring $cmake
    foreach ($name in 'LICENSE', 'ThirdPartyNotices.txt') {
      $path = '${KATAGLYPHIS_PACKAGE_DLL_DIR}/licenses/onnxruntime/' + $name
      $mutant = $cmake.Replace($path, 'removed')
      Assert-Throws -Body { Assert-OrtInstallLicenseWiring $mutant } -MessagePattern 'Missing ONNX install text'
    }
  }

  It 'fails for each missing selected MSIX input and accepts present inputs' {
    Set-Content -LiteralPath (Join-Path $TestDrive 'AppxManifest.xml') -Value '<Package/>'
    Set-Content -LiteralPath (Join-Path $TestDrive 'logo.png') -Value 'fixture'
    foreach ($name in 'makeappx', 'msixTemplate', 'logoSource') {
      $scenario = @{ Name = $name; Root = $TestDrive; Missing = $false }
      Invoke-MsixInputGuard -Source $source -Scenario $scenario
    }
    Assert-MsixInputCases -Source $source -Names @('makeappx', 'msixTemplate', 'logoSource') -Root $TestDrive -Missing $true
  }

  It 'detects each missing-input guard being changed to a non-fatal return' {
    $throwLines = @(
      "throw 'makeappx.exe is required for MSIX packaging'",
      'throw "MSIX manifest template not found: $msixTemplate"',
      'throw "MSIX project logo not found: $logoSource"'
    )
    $names = @('makeappx', 'msixTemplate', 'logoSource')
    for ($index = 0; $index -lt $names.Count; $index++) {
      $scenario = @{ Name = $names[$index]; Root = $TestDrive; Missing = $true }
      Assert-MsixGuardMutation -Source $source -Find $throwLines[$index] -Replace 'return' -Scenario $scenario
    }
  }

  It 'rejects directories standing in for the manifest or logo' {
    $directoryRoot = Join-Path $TestDrive 'directories'
    $null = New-Item -ItemType Directory -Path (Join-Path $directoryRoot 'AppxManifest.xml') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $directoryRoot 'logo.png') -Force
    Assert-MsixInputCases -Source $source -Names @('msixTemplate', 'logoSource') -Root $directoryRoot -Missing $false -MutatePath
  }

  It 'keeps selected MSIX as a critical step and leaves explicit skipping available' {
    Assert-MsixStepSelection $source
    $noncritical = $source.Replace('-StepName "MSIX Packaging" -Critical -Script', '-StepName "MSIX Packaging" -Script')
    $noncritical | Should Not Be $source
    Assert-Throws -Body { Invoke-MsixStepSelection -Source $noncritical -Skip $false } -MessagePattern 'critical'
    $inverted = $source.Replace('if (-not $SkipMSIX) {', 'if ($SkipMSIX) {')
    $inverted | Should Not Be $source
    Assert-Throws -Body { Assert-MsixStepSelection $inverted } -MessagePattern 'skip selection'
  }

  It 'rejects missing and duplicate AST selections, including a weakened selector mutant' {
    $empty = ConvertTo-TestScriptAst -Text 'Write-Output "no step"'
    $duplicate = ConvertTo-TestScriptAst -Text 'Invoke-BuildStep -StepName "MSIX Packaging"; Invoke-BuildStep -StepName "MSIX Packaging"'
    Assert-Throws -Body { Get-UniqueBuildAstNode -Ast $empty -StepName 'MSIX Packaging' } -MessagePattern 'found 0'
    Assert-Throws -Body { Get-UniqueBuildAstNode -Ast $duplicate -StepName 'MSIX Packaging' } -MessagePattern 'found 2'
    $fixtureText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -Raw
    $fixtureAst = ConvertTo-TestScriptAst -Text $fixtureText
    $definition = Get-BuildFunctionSource -Ast $fixtureAst -Name 'Get-UniqueBuildAstNode'
    $mutant = $definition.Replace('if ($nodes.Count -ne 1)', 'if ($nodes.Count -eq 0)')
    $mutant | Should Not Be $definition
    & {
      param($mutantText, $duplicateAst)
      . ([scriptblock]::Create($mutantText))
      Assert-Throws -Body {
        Assert-Throws -Body { Get-UniqueBuildAstNode -Ast $duplicateAst -StepName 'MSIX Packaging' } -MessagePattern 'found 2'
      } -MessagePattern 'expected an exception'
    } $mutant $duplicate
  }
}
