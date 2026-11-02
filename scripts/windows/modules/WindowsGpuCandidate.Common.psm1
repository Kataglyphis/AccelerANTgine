#requires -Version 7.0
# Shared steps of the Windows GPU candidate checks; each caller keeps its own verdicts and messages.
Set-StrictMode -Version Latest

# The chain ORT files a GPU variant ships, with the core first.
function Get-WindowsGpuOrtName([string]$Variant, [string]$OnnxRoot) {
    $names = @('onnxruntime.dll', 'onnxruntime_providers_shared.dll')
    if ($Variant -eq 'nvidia') {
        $names += 'onnxruntime_providers_cuda.dll'
        if (Get-ChainOrtRuntimeFile -OnnxRoot $OnnxRoot -Name 'DirectML.dll' -AllowMissing) { $names += 'DirectML.dll' }
    } else {
        $names += 'DirectML.dll'
    }
    return $names
}

# The provider path of an input that must exist with this type; Failure precedes the path in the refusal.
function Resolve-GpuCandidatePath([string]$Path, [string]$PathType, [string]$Failure) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $resolved -PathType $PathType)) { throw "$Failure$resolved" }
    return $resolved
}

function Assert-OrtWheelVerifierParameter {
    <#
    .SYNOPSIS
        Throws Message when the pinned hub's wheel verifier lacks a parameter.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not (Get-Command Copy-OrtWheelLicenses).Parameters.ContainsKey($Name)) { throw $Message }
}

function Invoke-WithGpuScratchDirectory {
    <#
    .SYNOPSIS
        Runs ScriptBlock with a new directory under Parent and removes it afterwards, refusing a path that left Parent.
    .PARAMETER UnsafeMessage
        Text before the resolved path in the refusal.
    #>
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$UnsafeMessage,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    $Parent = (Resolve-Path -LiteralPath $Parent -ErrorAction Stop).ProviderPath
    $scratch = Join-Path $Parent "$Prefix-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $scratch -ErrorAction Stop
    try {
        & $ScriptBlock $scratch
    } finally {
        $resolved = (Resolve-Path -LiteralPath $scratch -ErrorAction Stop).ProviderPath
        $parentPrefix = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "$UnsafeMessage$resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}

function Get-ProcessEnvironmentSnapshot {
    <#
    .SYNOPSIS
        The current process values of the named variables, null when unset.
    #>
    param([Parameter(Mandatory)][string[]]$Name)
    $saved = @{}
    foreach ($variable in $Name) { $saved[$variable] = [Environment]::GetEnvironmentVariable($variable, 'Process') }
    return $saved
}

function Restore-ProcessEnvironmentSnapshot {
    <#
    .SYNOPSIS
        Puts back what Get-ProcessEnvironmentSnapshot recorded, removing the variables that were unset.
    #>
    param([Parameter(Mandatory)][hashtable]$Snapshot)
    foreach ($variable in $Snapshot.Keys) {
        if ($null -eq $Snapshot[$variable]) { Remove-Item -LiteralPath "Env:$variable" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($variable, $Snapshot[$variable], 'Process') }
    }
}

Export-ModuleMember -Function Get-WindowsGpuOrtName, Resolve-GpuCandidatePath, Assert-OrtWheelVerifierParameter, Invoke-WithGpuScratchDirectory,
    Get-ProcessEnvironmentSnapshot, Restore-ProcessEnvironmentSnapshot
