#requires -Version 7.0
# This checks root selection and lane wiring against a stub runner; it does not run a container build.

Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\WindowsContainerInbound.Fixture.psm1') -ErrorAction Stop

Describe 'Windows container inbound reuse' {
    $lane = Join-Path $PSScriptRoot '..\Invoke-ContainerLane.ps1'
    $root = Join-Path $TestDrive 'project'
    $runnerDir = Join-Path $root 'third_party\ANTfrastructure\windows\scripts\build'
    $null = New-Item -ItemType Directory -Force -Path $runnerDir
    $record = Join-Path $TestDrive 'runner.json'
    # Records the bound values so each entry script proves its own lane.
    Set-Content -LiteralPath (Join-Path $runnerDir 'Invoke-RepoContainerBuild.ps1') -Value @'
[CmdletBinding(SupportsShouldProcess)]
param($RepoRoot, $ContainerName, $BuildCommand, $Image, $DockerExe, $Isolation, $CpuCount, $MemoryGb, $ExcludeRootEntries,
    $ExcludeRootPatterns, $InboundExclude, $OutputDirs, $OutboundExclude, $VerifyDirs, [switch]$UseBindMount, [switch]$FreshContainer)
$PSBoundParameters['BuildCommand'] = @(& $BuildCommand 'ws')
$PSBoundParameters | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $env:ACCELERANT_RUNNER_RECORD
'@

    # The documented command line; a splatted array would not bind its strings as parameter names.
    function Invoke-Entry([string]$Script, [string[]]$EntryArgs) {
        $env:ACCELERANT_RUNNER_RECORD = $record
        try { $null = & pwsh -NoProfile -File (Join-Path $PSScriptRoot "..\$Script") -ProjectRoot $root @EntryArgs }
        finally { Remove-Item Env:ACCELERANT_RUNNER_RECORD }
        if ($LASTEXITCODE -ne 0) { throw "$Script exited $LASTEXITCODE" }
        return Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    }

    function Assert-Lane($Bound, [string]$Container, [int]$Memory, [string]$Outputs, [string]$Command) {
        $Bound.ContainerName | Should Be $Container
        $Bound.MemoryGb | Should Be $Memory
        ($Bound.OutputDirs -join ',') | Should Be $Outputs
        ($Bound.BuildCommand -join ' ') | Should Match $Command
        ($Bound.ExcludeRootEntries -join ',') | Should Be 'logs,dist'
        ($Bound.ExcludeRootPatterns -join ',') | Should Be 'build,build-*,build_*'
    }

    It 'lets the shared runner omit root build output in both lanes' {
        Assert-ContainerRootSelection -ScriptPath $lane -ExcludeEntries @('logs', 'dist') -ExcludePatterns @('build', 'build-*', 'build_*')
    }

    It 'routes the CMake lane to its container, targets, outputs and verified directories' {
        $bound = Invoke-Entry 'Invoke-ContainerBuild.ps1' @('-BuildTargets', 'clangcl-debug, clangcl-release')
        Assert-Lane $bound 'accelerantgine-build-persistent' 48 'logs,dist,build-clangcl-debug,build-clangcl-release' 'Build-Windows\.ps1 -WorkspaceDir ws -BuildTargets clangcl-debug,clangcl-release$'
        ($bound.VerifyDirs -join ',') | Should Be 'build-clangcl-debug,build-clangcl-release'
    }

    It 'routes the Python lane to its own container without verified directories and forwards a memory limit' {
        $bound = Invoke-Entry 'Invoke-ContainerPythonBindings.ps1' @('-MemoryGb', '12')
        Assert-Lane $bound 'accelerantgine-python-persistent' 12 'build-python' 'Build-PythonBindings\.ps1 -WorkspaceDir ws -Preset x64-ClangCL-Windows-RelWithDebInfo$'
        @($bound.PSObject.Properties.Name) -contains 'VerifyDirs' | Should Be $false
    }

    It 'keeps each lane defaults and accepts -Preset' {
        (Invoke-Entry 'Invoke-ContainerBuild.ps1' @()).MemoryGb | Should Be 48
        $custom = Invoke-Entry 'Invoke-ContainerPythonBindings.ps1' @('-Preset', 'other')
        $custom.MemoryGb | Should Be 24
        ($custom.BuildCommand -join ' ') | Should Match '-Preset other$'
    }
}
