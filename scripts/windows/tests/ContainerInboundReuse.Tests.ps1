#requires -Version 7.0
# This checks root selection wiring; it does not run a container build.

Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\WindowsContainerInbound.Fixture.psm1') -ErrorAction Stop

Describe 'Windows container inbound reuse' {
    It 'lets the shared runner omit root build output in the CMake lane' {
        Assert-ContainerRootSelection -ScriptPath (Join-Path $PSScriptRoot '..\Invoke-ContainerBuild.ps1') `
            -ExcludeEntries @('logs', 'dist') -ExcludePatterns @('build', 'build-*', 'build_*')
    }

    It 'uses the same root policy in the Python bindings lane' {
        Assert-ContainerRootSelection -ScriptPath (Join-Path $PSScriptRoot '..\Invoke-ContainerPythonBindings.ps1') `
            -ExcludeEntries @('logs', 'dist') -ExcludePatterns @('build', 'build-*', 'build_*')
    }
}
