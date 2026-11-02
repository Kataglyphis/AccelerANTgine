#requires -Version 7.0
# This checks where the notices are installed and verified, not a completed Windows package.
Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') `
  -Function ConvertTo-TestScriptAst, Get-TestAstCommands, Get-TestCommandArguments, Assert-Throws -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop

function Get-StepCommand([System.Management.Automation.Language.Ast]$Ast, [string]$StepName, [string]$Name) {
  $step = Get-UniqueBuildAstNode -Ast $Ast -StepName $StepName
  return @(Get-TestAstCommands -Ast $step -Name $Name)
}

function Get-InstallerNoticeCommands([System.Management.Automation.Language.Ast]$Ast) {
  $function = ConvertTo-TestScriptAst -Text (Get-BuildFunctionSource -Ast $Ast -Name 'Assert-InstallerNotice')
  return [pscustomobject]@{
    Zip = @(Get-TestAstCommands -Ast $function -Name 'Assert-PackageLicense')
    Msi = @(Get-TestAstCommands -Ast $function -Name 'Assert-MsiPackageLicense')
  }
}

function Assert-WindowsNoticeWiring([string]$Source) {
  $ast = ConvertTo-TestScriptAst -Text $Source
  $bundleFailure = 'Expected one installer notice check over the bundle'
  Assert-SingleCommandArguments -Commands @(Get-StepCommand $ast 'Portable Bundle ($TargetArch)' 'Assert-InstallerNotice') -Expected @{ Bundle = '$portable.Bundle' } `
    -CountFailure $bundleFailure -ValueFailure $bundleFailure
  $installer = Get-InstallerNoticeCommands $ast
  Assert-SingleCommandArguments -Commands $installer.Zip -Expected @{ Pattern = "'*/licenses/THIRD-PARTY-NOTICES.txt'"; LicensePath = '$notices' } `
    -CountFailure 'Expected one notice check over the ZIP packages' -ValueFailure 'The ZIP notice check reads the wrong member or reference'
  $msiFailure = 'Expected one notice check over the MSI packages'
  Assert-SingleCommandArguments -Commands $installer.Msi -Expected @{ FileName = "'THIRD-PARTY-NOTICES.txt'" } -CountFailure $msiFailure -ValueFailure $msiFailure
  if (-not $Source.Contains("throw 'CPack produced no ZIP or no MSI for third-party notice verification'")) {
    throw 'A run without a ZIP or an MSI must fail the notice check'
  }
  Assert-SingleCommandArguments -Commands @(Get-StepCommand $ast 'MSIX Packaging' 'Assert-PackageLicense') -Expected @{ Path = '$msixFile'; Pattern = "'licenses/THIRD-PARTY-NOTICES.txt'" } `
    -CountFailure 'Expected one notice check over the MSIX' -ValueFailure 'The MSIX notice check reads the wrong package or member'
  $copies = @(Get-StepCommand $ast 'MSIX Packaging' 'Copy-Item' | Where-Object { $_.Extent.Text.Contains('$bundleLicenses') })
  if ($copies.Count -ne 1 -or -not $copies[0].Extent.Text.Contains("'third-party'")) {
    throw 'The MSIX payload must carry the bundle notices and their texts'
  }
}

function Assert-CmakeNoticeWiring([string]$CPack, [string]$Wheel) {
  $closure = $CPack.IndexOf('kataglyphis_install_linux_closure(')
  $linux = $CPack.IndexOf('accelerantgine_install_linux_notices(SEARCH ${_closure_search})')
  $windows = $CPack.IndexOf('accelerantgine_install_windows_notices()')
  $cpack = $CPack.IndexOf('include(CPack)')
  if ($closure -lt 0 -or $linux -le $closure -or $windows -lt 0 -or $cpack -le [Math]::Max($linux, $windows)) {
    throw 'Notices must install after the closure and before CPack'
  }
  if (-not $Wheel.Contains('accelerantgine_install_wheel_notices(python_bindings)')) { throw 'The wheel lacks its notices' }
}

Describe 'Third-party notice wiring' {
  $buildPath = Join-Path $PSScriptRoot '..\Build-Windows.ps1'
  $source = Get-Content -LiteralPath $buildPath -Raw
  $cpack = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\cmake\CPackOptions.cmake') -Raw
  $wheel = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\Bindings\python\CMakeLists.txt') -Raw

  It 'verifies the notices in every ZIP, MSI and MSIX' { Assert-WindowsNoticeWiring $source }

  It 'rejects removing any notice check or the MSIX copy' {
    $ast = ConvertTo-TestScriptAst -Text $source
    $installer = Get-InstallerNoticeCommands $ast
    $calls = @(Get-StepCommand $ast 'Portable Bundle ($TargetArch)' 'Assert-InstallerNotice') + $installer.Zip + $installer.Msi +
      @(Get-StepCommand $ast 'MSIX Packaging' 'Assert-PackageLicense') +
      @(Get-StepCommand $ast 'MSIX Packaging' 'Copy-Item' | Where-Object { $_.Extent.Text.Contains('$bundleLicenses') })
    $calls.Count | Should Be 5
    foreach ($call in $calls) {
      $mutant = $source.Replace($call.Extent.Text, "Write-Output 'removed'")
      $mutant | Should Not Be $source
      Assert-Throws -Body { Assert-WindowsNoticeWiring $mutant } -MessagePattern 'notice'
    }
    $lenient = $source.Replace("throw 'CPack produced no ZIP or no MSI for third-party notice verification'", "Write-Output 'no MSI'")
    $lenient | Should Not Be $source
    Assert-Throws -Body { Assert-WindowsNoticeWiring $lenient } -MessagePattern 'MSI'
  }

  It 'installs the notices after the closure, before CPack, and into the wheel' {
    Assert-CmakeNoticeWiring -CPack $cpack -Wheel $wheel
    $early = $cpack.Replace('accelerantgine_install_linux_notices(SEARCH ${_closure_search})', '')
    $early = $early.Replace('include(ThirdPartyNotices)', "include(ThirdPartyNotices)`naccelerantgine_install_linux_notices(SEARCH `${_closure_search})")
    Assert-Throws -Body { Assert-CmakeNoticeWiring -CPack $early -Wheel $wheel } -MessagePattern 'after the closure'
    Assert-Throws -Body { Assert-CmakeNoticeWiring -CPack $cpack -Wheel '' } -MessagePattern 'wheel'
  }
}
