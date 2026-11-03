#requires -Version 7.0

Describe 'Windows GPU clean-host startup' {
    . (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1')
    Import-BuildModule @('WindowsGpuCandidate.Common')
    $script = Join-Path $PSScriptRoot '..\Test-WindowsGpuCleanHost.ps1'
    $probe = Join-Path $TestDrive 'environment.txt'
    function Get-StartupFailure([string]$Executable, [string[]]$CandidateArguments) {
        try {
            & $script -Executable $Executable -Arguments $CandidateArguments -PreserveGpuRuntimePath
            ''
        } catch { $_.Exception.Message }
    }
    It 'isolates inherited paths and registry and restores the caller environment' {
        $command = Join-Path $TestDrive 'probe.cmd'
        @'
@echo off
echo %PATH%>"%ACCELERANT_HOST_PROBE%"
echo %CD%>>"%ACCELERANT_HOST_PROBE%"
if defined GST_PLUGIN_PATH_1_0 (echo %GST_PLUGIN_PATH_1_0%>>"%ACCELERANT_HOST_PROBE%") else (echo UNSET>>"%ACCELERANT_HOST_PROBE%")
echo %GST_PLUGIN_SYSTEM_PATH_1_0%>>"%ACCELERANT_HOST_PROBE%"
echo %GST_REGISTRY_1_0%>>"%ACCELERANT_HOST_PROBE%"
exit /b 0
'@ | Set-Content -LiteralPath $command -Encoding ascii
        $inherited = @{
            PATH = 'C:\contaminated-path'; GST_PLUGIN_PATH_1_0 = 'C:\contaminated-plugin'; GST_PLUGIN_SYSTEM_PATH_1_0 = 'C:\contaminated-system'
            GST_REGISTRY_1_0 = 'C:\contaminated-registry'; ACCELERANT_HOST_PROBE = $probe
        }
        Invoke-WithProcessEnvironment -Environment $inherited -ScriptBlock {
            & $script -Executable (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments @('/d', '/c', $command)
            $lines = @(Get-Content -LiteralPath $probe)
            $lines[0] | Should Be "$env:SystemRoot\System32;$env:SystemRoot"
            $lines[1] | Should Match 'accelerantgine-clean-host-'
            $lines[2] | Should Be 'UNSET'
            $lines[3] | Should Be $lines[1]
            $lines[4] | Should Be (Join-Path $lines[1] 'registry.bin')
            (Test-Path -LiteralPath $lines[1]) | Should Be $false
            $env:PATH | Should Be 'C:\contaminated-path'
            $env:GST_PLUGIN_PATH_1_0 | Should Be 'C:\contaminated-plugin'
            & $script -Executable (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments @('/d', '/c', $command) -PoisonPluginPath
            $lines = @(Get-Content -LiteralPath $probe)
            $lines[2] | Should Be $lines[1]
            (Test-Path -LiteralPath $lines[1]) | Should Be $false
            $env:GST_PLUGIN_PATH_1_0 | Should Be 'C:\contaminated-plugin'
            $env:GST_REGISTRY_1_0 | Should Be 'C:\contaminated-registry'
            & $script -Executable (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments @('/d', '/c', $command) -PreserveGpuRuntimePath
            $lines = @(Get-Content -LiteralPath $probe)
            $lines[0] | Should Be 'C:\contaminated-path'
            $lines[2] | Should Be 'UNSET'
            $lines[3] | Should Be $lines[1]
            $lines[4] | Should Be (Join-Path $lines[1] 'registry.bin')
            (Test-Path -LiteralPath $lines[1]) | Should Be $false
            $env:PATH | Should Be 'C:\contaminated-path'
            $env:GST_PLUGIN_PATH_1_0 | Should Be 'C:\contaminated-plugin'
        }
    }

    It 'fails when the candidate exits unsuccessfully' {
        Invoke-WithProcessEnvironment -Environment @{ GST_PLUGIN_PATH_1_0 = 'C:\contaminated-plugin' } -ScriptBlock {
            Get-StartupFailure (Join-Path $env:SystemRoot 'System32\cmd.exe') @('/d', '/c', 'exit 17') | Should Match 'Candidate startup failed: 17'
            $env:GST_PLUGIN_PATH_1_0 | Should Be 'C:\contaminated-plugin'
        }
    }

    It 'removes inherited plugin variables in the child and restores them after a failure' {
        $child = "Set-Content -LiteralPath '$probe' -Value `"`$(Test-Path Env:GST_PLUGIN_PATH)|`$(Test-Path Env:GST_REGISTRY_FORK)|`$env:GST_REGISTRY_1_0`"; exit 9"
        Invoke-WithProcessEnvironment -Environment @{ GST_PLUGIN_PATH = 'inherited'; GST_REGISTRY_FORK = 'inherited'; GST_REGISTRY_1_0 = 'inherited' } -ScriptBlock {
            Get-StartupFailure (Get-Process -Id $PID).Path @('-NoProfile', '-NonInteractive', '-Command', $child) | Should Match 'Candidate startup failed: 9'
            Get-Content -LiteralPath $probe | Should Match '^False\|False\|.*accelerantgine-clean-host-.*registry\.bin$'
            "$env:GST_PLUGIN_PATH|$env:GST_REGISTRY_FORK|$env:GST_REGISTRY_1_0" | Should Be 'inherited|inherited|inherited'
        }
    }
}
