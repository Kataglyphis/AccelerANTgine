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
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')
Import-BuildModule @('WindowsGpuCandidate.Common')
$executablePath = Resolve-GpuCandidatePath -Path $Executable -PathType Leaf -Failure 'Executable is not a file: '
$variables = @('PATH', 'GST_PLUGIN_PATH', 'GST_PLUGIN_PATH_1_0', 'GST_PLUGIN_SYSTEM_PATH',
    'GST_PLUGIN_SYSTEM_PATH_1_0', 'GST_PLUGIN_SCANNER', 'GST_PLUGIN_SCANNER_1_0', 'GST_REGISTRY',
    'GST_REGISTRY_1_0', 'GST_REGISTRY_FORK')
Invoke-WithGpuScratchDirectory -Parent ([IO.Path]::GetTempPath()) -Prefix 'accelerantgine-clean-host' -UnsafeMessage 'Unsafe clean-host scratch path: ' -ScriptBlock {
    param($scratch)
    $isolated = @{}
    foreach ($name in $variables) { $isolated[$name] = $null }
    $isolated['PATH'] = if ($PreserveGpuRuntimePath) { $env:PATH } else { "$env:SystemRoot\System32;$env:SystemRoot" }
    # A real empty directory avoids PowerShell/.NET versions that remove empty environment values.
    $isolated['GST_PLUGIN_SYSTEM_PATH_1_0'] = $scratch
    $isolated['GST_REGISTRY_1_0'] = Join-Path $scratch 'registry.bin'
    if ($PoisonPluginPath) { $isolated['GST_PLUGIN_PATH_1_0'] = $scratch }
    Invoke-WithProcessEnvironment -Environment $isolated -ScriptBlock {
        Push-Location -LiteralPath $scratch
        try {
            & $executablePath @Arguments
            if ($LASTEXITCODE -ne 0) { throw "Candidate startup failed: $LASTEXITCODE" }
        } finally { Pop-Location }
    }
}
