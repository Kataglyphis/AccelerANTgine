#requires -Version 7.0

Describe 'Windows GPU clean-host startup' {
    It 'isolates inherited paths and registry and restores the caller environment' {
        $script = Join-Path $PSScriptRoot '..\Test-WindowsGpuCleanHost.ps1'
        $probe = Join-Path $TestDrive 'environment.txt'
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
        $names = @('PATH', 'GST_PLUGIN_PATH_1_0', 'GST_PLUGIN_SYSTEM_PATH_1_0', 'GST_REGISTRY_1_0', 'ACCELERANT_HOST_PROBE')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
        try {
            $env:PATH = 'C:\contaminated-path'
            $env:GST_PLUGIN_PATH_1_0 = 'C:\contaminated-plugin'
            $env:GST_PLUGIN_SYSTEM_PATH_1_0 = 'C:\contaminated-system'
            $env:GST_REGISTRY_1_0 = 'C:\contaminated-registry'
            $env:ACCELERANT_HOST_PROBE = $probe
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
        } finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
    }

    It 'fails when the candidate exits unsuccessfully' {
        $script = Join-Path $PSScriptRoot '..\Test-WindowsGpuCleanHost.ps1'
        $previous = [Environment]::GetEnvironmentVariable('GST_PLUGIN_PATH_1_0', 'Process')
        try {
            $env:GST_PLUGIN_PATH_1_0 = 'C:\contaminated-plugin'
            $message = try {
                & $script -Executable (Join-Path $env:SystemRoot 'System32\cmd.exe') -Arguments @('/d', '/c', 'exit 17') -PreserveGpuRuntimePath
                ''
            } catch { $_.Exception.Message }
            $message | Should Match 'Candidate startup failed: 17'
            $env:GST_PLUGIN_PATH_1_0 | Should Be 'C:\contaminated-plugin'
        } finally { [Environment]::SetEnvironmentVariable('GST_PLUGIN_PATH_1_0', $previous, 'Process') }
    }
}
