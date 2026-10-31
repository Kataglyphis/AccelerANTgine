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
$executablePath = (Resolve-Path -LiteralPath $Executable -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw "Executable is not a file: $executablePath" }
$scratchParent = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath()) -ErrorAction Stop).ProviderPath
$scratch = Join-Path $scratchParent "accelerantgine-clean-host-$([guid]::NewGuid().ToString('N'))"
$variables = @('PATH', 'GST_PLUGIN_PATH', 'GST_PLUGIN_PATH_1_0', 'GST_PLUGIN_SYSTEM_PATH',
    'GST_PLUGIN_SYSTEM_PATH_1_0', 'GST_PLUGIN_SCANNER', 'GST_PLUGIN_SCANNER_1_0', 'GST_REGISTRY',
    'GST_REGISTRY_1_0', 'GST_REGISTRY_FORK')
$previous = @{}
foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null
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
    foreach ($name in $variables) {
        if ($null -eq $previous[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    }
    $resolved = (Resolve-Path -LiteralPath $scratch -ErrorAction Stop).ProviderPath
    $prefix = $scratchParent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe clean-host scratch path: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}
