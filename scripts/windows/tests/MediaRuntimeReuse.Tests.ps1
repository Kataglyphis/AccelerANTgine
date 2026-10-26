#requires -Version 7.0

# This guards the shared runtime call and fixture bytes; it does not run a container build or load the staged DLLs.
Describe 'Windows media runtime reuse' {
    . (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1')
    Import-BuildModule 'WindowsMediaRuntime.Common'

    It 'passes the image runtime root to the shared bundler in every clang build' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Build-Windows.ps1'), [ref]$tokens, [ref]$errors)
        @($errors | Where-Object { $_ }).Count | Should Be 0
        $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Copy-MediaRuntimeBundle' }, $true))
        $calls.Count | Should Be 3
        foreach ($call in $calls) {
            ($call.Extent.Text -match "-GStreamerRoot 'C:\\runtime\\bin'") | Should Be $true
        }
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-ImageGStreamerRuntime' }, $true)).Count | Should Be 0
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-MissingGStreamerBinWarning' }, $true)).Count | Should Be 3
    }

    It 'warns when the selected GStreamer bin is missing' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Build-Windows.ps1'), [ref]$tokens, [ref]$errors)
        @($errors | Where-Object { $_ }).Count | Should Be 0
        $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-MissingGStreamerBinWarning' }, $true))
        $functions.Count | Should Be 1
        . ([scriptblock]::Create($functions[0].Extent.Text))
        $warnings = [Collections.Generic.List[string]]::new()
        function Write-BuildLogWarning { param($Context, $Message) $warnings.Add($Message) }
        $missing = Join-Path $TestDrive 'missing-gstreamer'
        Invoke-WithProcessEnvironment -Environment @{ GSTREAMER_BIN = $missing } -ScriptBlock {
            Write-MissingGStreamerBinWarning -Context ([pscustomobject]@{})
            $null = New-Item -ItemType Directory -Path $missing
            Write-MissingGStreamerBinWarning -Context ([pscustomobject]@{})
        }
        $warnings.Count | Should Be 1
        ($warnings[0] -like "GStreamer bin not found ($missing)*") | Should Be $true
    }

    It 'copies image DLLs through the shared module and honors an explicit environment root' {
        $image = Join-Path $TestDrive 'image/bin'
        $override = Join-Path $TestDrive 'override/bin'
        $null = New-Item -ItemType Directory -Force -Path $image, $override
        [IO.File]::WriteAllText((Join-Path $image 'gstreamer-fixture-only.dll'), 'image')
        [IO.File]::WriteAllText((Join-Path $override 'gstreamer-fixture-only.dll'), 'override')
        $context = [pscustomobject]@{ LogWriter = $null; SuppressConsoleOutput = $true }

        $fromImage = Invoke-WithProcessEnvironment -Environment @{ GSTREAMER_BIN = $null } -ScriptBlock {
            $target = Join-Path $TestDrive 'without-env'
            $null = Copy-MediaRuntimeBundle -Context $context -TargetDir $target -GStreamerRoot $image -OnnxRoot '' -OnnxGenAiRoot ''
            Get-Content -LiteralPath (Join-Path $target 'gstreamer-fixture-only.dll') -Raw
        }
        $fromImage.Trim() | Should Be 'image'

        $fromOverride = Invoke-WithProcessEnvironment -Environment @{ GSTREAMER_BIN = $override } -ScriptBlock {
            $target = Join-Path $TestDrive 'with-env'
            $null = Copy-MediaRuntimeBundle -Context $context -TargetDir $target -GStreamerRoot $image -OnnxRoot '' -OnnxGenAiRoot ''
            Get-Content -LiteralPath (Join-Path $target 'gstreamer-fixture-only.dll') -Raw
        }
        $fromOverride.Trim() | Should Be 'override'

        [IO.File]::WriteAllText((Join-Path $image 'onnxruntime.dll'), 'foreign')
        $message = Invoke-WithProcessEnvironment -Environment @{ GSTREAMER_BIN = $null } -ScriptBlock {
            try {
                $null = Copy-MediaRuntimeBundle -Context $context -TargetDir (Join-Path $TestDrive 'foreign-ort') -GStreamerRoot $image -OnnxRoot '' -OnnxGenAiRoot ''
                ''
            } catch { $_.Exception.Message }
        }
        ($message -match 'outside the chain install') | Should Be $true

        Remove-Item -LiteralPath (Join-Path $image 'onnxruntime.dll')
        [IO.File]::WriteAllText((Join-Path $image 'DirectML.dll'), 'foreign')
        $dmlMessage = Invoke-WithProcessEnvironment -Environment @{ GSTREAMER_BIN = $null } -ScriptBlock {
            try {
                $null = Copy-MediaRuntimeBundle -Context $context -TargetDir (Join-Path $TestDrive 'foreign-dml') -GStreamerRoot $image -OnnxRoot '' -OnnxGenAiRoot ''
                ''
            } catch { $_.Exception.Message }
        }
        ($dmlMessage -match 'outside the chain install.*DirectML\.dll') | Should Be $true
    }
}
