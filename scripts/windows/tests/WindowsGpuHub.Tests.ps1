#requires -Version 7.0
# Checks the refusal wiring with a stubbed path helper; the hub's suites own that helper and no verifier runs here.

Describe 'Windows GPU hub requirements' {
    $check = Join-Path $PSScriptRoot '..\Test-WindowsGpuHub.ps1'

    It 'accepts the pinned checkout' {
        { & $check } | Should Not Throw
    }

    It 'asks for real hub leaves and names the missing ones (mutation)' {
        function Get-MissingBuildChildPaths {
            param($Root, $RelativePath, $PathType)
            if ($PathType -ne 'Leaf' -or -not (Test-Path -LiteralPath (Join-Path $Root $RelativePath[0]) -PathType Leaf)) { throw "Unexpected request: $Root $PathType" }
            $RelativePath[0], 'second'
        }
        { & $check } | Should Throw "ANTfrastructure's shared/python/verify_ort_profile.py, second."
    }
}
