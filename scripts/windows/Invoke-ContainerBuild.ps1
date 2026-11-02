#requires -Version 7.0
# Builds in the ANTfrastructure Windows image; takes Invoke-ContainerLane.ps1's parameters with -BuildTargets.
& (Join-Path $PSScriptRoot 'Invoke-ContainerLane.ps1') @args
