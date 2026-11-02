#requires -Version 7.0
# Builds the Python bindings in the ANTfrastructure Windows image; takes Invoke-ContainerLane.ps1's parameters with -Preset.
& (Join-Path $PSScriptRoot 'Invoke-ContainerLane.ps1') -PythonBindings @args
