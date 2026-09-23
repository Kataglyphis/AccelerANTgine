#requires -Version 7.0

# PROJECT-LOCAL glue: prove a staged bundle (the exe's bin\, or the Python package) carries the image's
# chain ONNX Runtime with ANTfrastructure's G6 census (WindowsOrtProvenance.Common), which the caller
# imports. Owner rule 2026-09-23 (third_party/ANTfrastructure/docs/onnxruntime-single-source.md). Every
# byte verdict is G6's. NOT covered: which copy a process loads beyond G6's modelled loader order.

Set-StrictMode -Version Latest

$script:OrtFamily = @('onnxruntime*.dll', 'DirectML.dll')

function Get-OrtCensusRequirement {
    <#
    .SYNOPSIS
        The error for a hub pin that lacks G6: which hub commit is needed, and where the pin is.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object] $Cause = $null)

    $hub = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure'))
    $at = try { "$(& git -C $hub rev-parse --short HEAD 2>$null)".Trim() } catch { '' }
    return ("ONNX Runtime proof needs ANTfrastructure's G6 census (windows/scripts/modules/" +
        "WindowsOrtProvenance.Common.psm1, Test-OrtProvenanceTree), added by the hub's ORT single-source " +
        "commit of 2026-09-23 (third_party/ANTfrastructure/docs/onnxruntime-single-source.md). third_party/ANTfrastructure is at " +
        "$(if ($at) { $at } else { 'an unknown commit' }): move the gitlink to that commit or later." +
        $(if ($Cause) { " ($Cause)" } else { '' }))
}

function Assert-OrtCensusCommand {
    param([string[]] $Command = @('Test-OrtProvenanceTree'))
    foreach ($cmd in $Command) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) { throw (Get-OrtCensusRequirement -Cause "$cmd is not loaded") }
    }
}

function Copy-ChainOrtLib {
    <#
    .SYNOPSIS
        Replaces every ORT-family DLL in Destination with the DLLs of the chain install's layout
        (Get-OnnxChainLayout: ONNX_ROOT\lib and \bin, no GenAI), which throws for a NuGet tree or a
        release zip. Provenance is judged by Assert-BundleChainOrt (G6) afterwards.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $OnnxRoot,
        [Parameter(Mandatory)][string] $Destination
    )

    Assert-OrtCensusCommand -Command 'Get-OnnxChainLayout'
    $layout = Get-OnnxChainLayout -OnnxRoot $OnnxRoot -OnnxGenAiRoot ''
    if (-not $PSCmdlet.ShouldProcess($Destination, 'stage chain ONNX Runtime')) { return }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $stale = @(Get-ChildItem -LiteralPath $Destination -File | Where-Object { $n = $_.Name; @($script:OrtFamily | Where-Object { $n -like $_ }).Count -gt 0 })
    $stale | Remove-Item -Force
    foreach ($dir in @($layout.RuntimeDirectories)) {
        Get-ChildItem -LiteralPath $dir -Filter '*.dll' -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination -Force }
    }
}

function Assert-BundleChainOrt {
    <#
    .SYNOPSIS
        G6 over Root against the image's chain ORT: every ORT binary is the chain's, byte for byte, and
        onnxruntime.dll sits in DllDirectory (default Root). Throws on any fatal finding.
    .PARAMETER DllDirectory
        For a Python package whose __init__ registers this directory with os.add_dll_directory, which Windows
        searches before System32. G6 models an exe's loader, not that call, so its UNRESOLVED verdicts are
        replaced by the onnxruntime.dll-in-DllDirectory check; every byte verdict still applies.
    .PARAMETER ExeDirectory
        For an install tree (what CPack packs): onnxruntime.dll must sit here, beside the exe (bin\), while
        G6 still grades all of Root and every verdict, UNRESOLVED included, stays fatal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Root,
        [string] $DllDirectory = '',
        [string] $ExeDirectory = ''
    )

    Assert-OrtCensusCommand
    $findings = [System.Collections.Generic.List[string]]::new()
    $ortDir = if ($DllDirectory) { $DllDirectory } elseif ($ExeDirectory) { $ExeDirectory } else { $Root }
    if (-not (Test-Path -LiteralPath (Join-Path $ortDir 'onnxruntime.dll') -PathType Leaf)) {
        $findings.Add("MISSING $ortDir\onnxruntime.dll: without it a client host loads System32's Windows ML copy")
    }
    $census = Test-OrtProvenanceTree -Root $Root -PassThru
    foreach ($f in @($census.Findings | Where-Object { $_.Fatal -and -not ($DllDirectory -and $_.Verdict -eq 'UNRESOLVED') })) {
        $findings.Add("$($f.Verdict) $($f.Path) -- $($f.Detail)")
    }
    $waived = @($census.Findings | Where-Object { $DllDirectory -and $_.Verdict -eq 'UNRESOLVED' })
    if ($waived.Count -gt 0 -and $findings.Count -eq 0) {
        Write-Host "  UNRESOLVED above ($($waived.Count)) is not fatal here: the package's __init__ registers $DllDirectory with os.add_dll_directory, searched before System32, and it holds the chain onnxruntime.dll."
    }
    if ($findings.Count -gt 0) {
        throw ("ONNX Runtime in $Root is not the image's chain build (G6):" + [Environment]::NewLine + '  ' +
            ($findings -join ([Environment]::NewLine + '  ')))
    }
    return $census
}

Export-ModuleMember -Function Get-OrtCensusRequirement, Copy-ChainOrtLib, Assert-BundleChainOrt
