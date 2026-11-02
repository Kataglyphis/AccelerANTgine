#requires -Version 7.0
<#
.SYNOPSIS
  Runs a GPU bundle check without inherited GStreamer plugin paths or caches.
.PARAMETER PreserveGpuRuntimePath
  Keep the host PATH for GPU SDK libraries while still isolating GStreamer plugins and registry.
.PARAMETER PoisonPluginPath
  Simulate an inherited, empty plugin path to test a finished executable's own isolation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [string[]]$Arguments = @('--gst_check'),
    [switch]$PreserveGpuRuntimePath,
    [switch]$PoisonPluginPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# A clean host needs no pinned hub modules for this check.
Import-Module (Join-Path $PSScriptRoot 'modules\WindowsGpuCandidate.Common.psm1') -Force -ErrorAction Stop
$executablePath = Resolve-GpuCandidatePath -Path $Executable -PathType Leaf -Failure 'Executable is not a file: '
$variables = @('PATH', 'GST_PLUGIN_PATH', 'GST_PLUGIN_PATH_1_0', 'GST_PLUGIN_SYSTEM_PATH',
    'GST_PLUGIN_SYSTEM_PATH_1_0', 'GST_PLUGIN_SCANNER', 'GST_PLUGIN_SCANNER_1_0', 'GST_REGISTRY',
    'GST_REGISTRY_1_0', 'GST_REGISTRY_FORK')
$previous = Get-ProcessEnvironmentSnapshot -Name $variables
Invoke-WithGpuScratchDirectory -Parent ([IO.Path]::GetTempPath()) -Prefix 'accelerantgine-clean-host' -UnsafeMessage 'Unsafe clean-host scratch path: ' -ScriptBlock {
    param($scratch)
    try {
        foreach ($name in $variables) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        if ($PreserveGpuRuntimePath) {
            [Environment]::SetEnvironmentVariable('PATH', $previous['PATH'], 'Process')
        } else {
            $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        }
        # A real empty directory avoids PowerShell/.NET versions that remove empty environment values.
        $env:GST_PLUGIN_SYSTEM_PATH_1_0 = $scratch
        $env:GST_REGISTRY_1_0 = Join-Path $scratch 'registry.bin'
        if ($PoisonPluginPath) { $env:GST_PLUGIN_PATH_1_0 = $scratch }
        Push-Location -LiteralPath $scratch
        try {
            & $executablePath @Arguments
            if ($LASTEXITCODE -ne 0) { throw "Candidate startup failed: $LASTEXITCODE" }
        } finally { Pop-Location }
    } finally {
        Restore-ProcessEnvironmentSnapshot -Snapshot $previous
    }
}
