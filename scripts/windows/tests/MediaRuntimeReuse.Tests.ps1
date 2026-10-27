#requires -Version 7.0

# This guards the shared runtime call and fixture bytes; it does not run a container build or load the staged DLLs.
Describe 'Windows media runtime reuse' {
    . (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1')
    Import-BuildModule 'WindowsMediaRuntime.Common'
    Import-Module (Join-Path $PSScriptRoot '..\..\..\third_party\ANTfrastructure\windows\scripts\tests\TestHarness.psm1') -Function Get-TestScriptAst, Get-TestAstCommands -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop

    It 'stages the shared runtime through one helper for all three build roots' {
        $ast = Get-TestScriptAst -ScriptPath (Join-Path $PSScriptRoot '..\Build-Windows.ps1')
        $calls = @(Get-TestAstCommands -Ast $ast -Name 'Copy-MediaRuntimeBundle')
        $calls.Count | Should Be 1
        ($calls[0].Extent.Text -match "-GStreamerRoot 'C:\\runtime\\bin'") | Should Be $true
        $buildCalls = @(Get-TestAstCommands -Ast $ast -Name 'Copy-BuildMediaRuntime')
        $buildCalls.Count | Should Be 3
        @($buildCalls | Where-Object { $_.Extent.Text -match '-StageTestPlugins\s+-CopyOrtBeside' }).Count | Should Be 2
        @($buildCalls | Where-Object { $_.Extent.Text -match '\$fastBuildReleaseDirFull' -and $_.Extent.Text -notmatch '-StageTestPlugins|-CopyOrtBeside' }).Count | Should Be 1
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-ImageGStreamerRuntime' }, $true)).Count | Should Be 0
        @(Get-TestAstCommands -Ast $ast -Name 'Write-MissingGStreamerBinWarning').Count | Should Be 1
    }

    It 'keeps debug-only plugin and ORT staging out of Release while preserving call order' {
        $ast = Get-TestScriptAst -ScriptPath (Join-Path $PSScriptRoot '..\Build-Windows.ps1')
        $definition = Get-BuildFunctionSource -Ast $ast -Name 'Copy-BuildMediaRuntime'
        . ([scriptblock]::Create($definition))
        $calls = [Collections.Generic.List[string]]::new()
        function Write-MissingGStreamerBinWarning { param($Context) $calls.Add('warning') }
        function Copy-MediaRuntimeBundle { param($Context, $TargetDir, $GStreamerRoot) $calls.Add('bundle'); return 7 }
        function Copy-ImageGStreamerTestPlugins { param($Context, $BuildRoot) $calls.Add('plugins') }
        function Assert-ChainOrtTree { param($Root) $calls.Add('ort-proof'); return 9 }
        function Copy-AppLocalVcRuntime { param($Context, $Destination) $calls.Add('crt') }
        function Copy-ChainOrtBeside { param($OnnxRoot, $Destination) $calls.Add('ort-beside'); return 11 }
        $context = [pscustomobject]@{}
        $root = Join-Path $TestDrive 'runtime'
        $output = @(Copy-BuildMediaRuntime -Context $context -BuildRoot $root -StageTestPlugins -CopyOrtBeside)
        $output.Count | Should Be 0
        ($calls -join ',') | Should Be 'warning,bundle,plugins,ort-proof,crt,ort-beside'
        $calls.Clear()
        $output = @(Copy-BuildMediaRuntime -Context $context -BuildRoot $root)
        $output.Count | Should Be 0
        ($calls -join ',') | Should Be 'warning,bundle,ort-proof,crt'
    }

    It 'warns when the selected GStreamer bin is missing' {
        $ast = Get-TestScriptAst -ScriptPath (Join-Path $PSScriptRoot '..\Build-Windows.ps1')
        $definition = Get-BuildFunctionSource -Ast $ast -Name 'Write-MissingGStreamerBinWarning'
        . ([scriptblock]::Create($definition))
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
