#requires -Version 7.0

# This guards the shared runtime call and fixture bytes; it does not run a container build or load the staged DLLs.
Describe 'Windows media runtime reuse' {
    . (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1')
    Import-BuildModule 'WindowsMediaRuntime.Common'
    Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop

    It 'stages the shared runtime through one helper for all three build roots' {
        $ast = Get-BuildScriptAst
        $calls = @(Get-TestAstCommands -Ast $ast -Name 'Copy-MediaRuntimeBundle')
        $calls.Count | Should Be 1
        ($calls[0].Extent.Text -match "-GStreamerRoot 'C:\\runtime\\bin'") | Should Be $true
        $buildCalls = @(Get-TestAstCommands -Ast $ast -Name 'Copy-BuildMediaRuntime')
        $buildCalls.Count | Should Be 2
        @($buildCalls | Where-Object { $_.Extent.Text -match '-StageTestPlugins\s+-CopyOrtBeside' }).Count | Should Be 1
        @(Get-TestAstCommands -Ast $ast -Name 'Invoke-ConfiguredBuildStep').Count | Should Be 2
        @($buildCalls | Where-Object { $_.Extent.Text -match '\$fastBuildReleaseDirFull' -and $_.Extent.Text -notmatch '-StageTestPlugins|-CopyOrtBeside' }).Count | Should Be 1
        @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-ImageGStreamerRuntime' }, $true)).Count | Should Be 0
        @(Get-TestAstCommands -Ast $ast -Name 'Write-MissingGStreamerBinWarning').Count | Should Be 1
    }

    It 'keeps debug-only plugin and ORT staging out of Release while preserving call order' {
        . (Get-BuildFunctionBlock 'Copy-BuildMediaRuntime')
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

    It 'stages required and present optional package plugins and rejects an incomplete image' {
        . (Get-BuildFunctionBlock 'Get-ImageGStreamerPluginDir')
        . (Get-BuildFunctionBlock 'Get-ImageGStreamerPluginFile')
        . (Get-BuildFunctionBlock 'Get-ImageGStreamerPackagePlugins')
        . (Get-BuildFunctionBlock 'Copy-ImageGStreamerPackagePlugins')
        function Assert-PeTargetMachine { param($Path, $Arch, $Context) }
        $bin = Join-Path $TestDrive 'package-image\bin'
        $plugins = Join-Path $TestDrive 'package-image\lib\gstreamer-1.0'
        $null = New-Item -ItemType Directory -Force -Path $bin, $plugins
        $required = @('coreelements', 'app', 'videotestsrc', 'videoconvertscale', 'playback', 'webrtc', 'nice', 'dtls', 'srtp', 'sctp', 'rtpmanager', 'rtp')
        foreach ($name in ($required + 'vpx')) { [IO.File]::WriteAllText((Join-Path $plugins "gst$name.dll"), $name) }
        Invoke-WithProcessEnvironment -Environment @{ GSTREAMER_BIN = $bin } -ScriptBlock {
            $destination = Join-Path $TestDrive 'staged-plugins'
            $selected = @(Get-ImageGStreamerPackagePlugins -Arch amd64)
            $files = @(Copy-ImageGStreamerPackagePlugins -Destination $destination -Plugins $selected)
            $files.Count | Should Be 13
            (Get-Content -LiteralPath (Join-Path $destination 'gstvpx.dll') -Raw) | Should Be 'vpx'
            Remove-Item -LiteralPath (Join-Path $plugins 'gstvpx.dll')
            $withoutVpx = @(Get-ImageGStreamerPackagePlugins -Arch amd64)
            $withoutVpx.Count | Should Be 12
            $null = @(Copy-ImageGStreamerPackagePlugins -Destination $destination -Plugins $withoutVpx)
            (Test-Path -LiteralPath (Join-Path $destination 'gstvpx.dll')) | Should Be $false
            Remove-Item -LiteralPath (Join-Path $plugins 'gstwebrtc.dll')
            $message = try { Get-ImageGStreamerPackagePlugins -Arch amd64; '' } catch { $_.Exception.Message }
            ($message -match 'gstwebrtc.dll is missing') | Should Be $true
        }
    }

    It 'takes the package scanner from the image and rejects an image without one' {
        . (Get-BuildFunctionBlock 'Get-ImageGStreamerPluginDir')
        . (Get-BuildFunctionBlock 'Get-ImageGStreamerPackageScanner')
        function Assert-PeTargetMachine { param($Path, $Arch, $Context) }
        $bin = Join-Path $TestDrive 'scanner-image\bin'
        $scanner = Join-Path $TestDrive 'scanner-image\libexec\gstreamer-1.0\gst-plugin-scanner.exe'
        $null = New-Item -ItemType Directory -Force -Path $bin, (Split-Path -Parent $scanner)
        [IO.File]::WriteAllText($scanner, 'scanner')
        Invoke-WithProcessEnvironment -Environment @{ GSTREAMER_BIN = $bin } -ScriptBlock {
            (Get-ImageGStreamerPackageScanner -Arch amd64) | Should Be $scanner
            Remove-Item -LiteralPath $scanner
            $message = try { Get-ImageGStreamerPackageScanner -Arch amd64; '' } catch { $_.Exception.Message }
            ($message -match 'gst-plugin-scanner.exe is missing') | Should Be $true
        }
    }

    It 'seeds the closure with plugins and installs them into each package layout' {
        $ast = Get-BuildScriptAst
        @((Get-TestAstCommands -Ast $ast -Name 'Copy-PeImportClosure') | Where-Object { $_.Extent.Text -match '\$engine \+ \$plugins \+ \$imageScanner' }).Count | Should Be 1
        $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Build-Windows.ps1') -Raw
        $script.Contains('Copy-Item -LiteralPath $bundlePlugins -Destination $stagingLib -Recurse -Force') | Should Be $true
        $script.Contains("`$imagePlugins = @(if (`$OrtVariant -ne 'cpu')") | Should Be $true
        $script.Contains('-RuntimeBin $gstBin') | Should Be $true
        $script.Contains("`$payloadExtra += Join-Path `$payloadDir 'gst-plugin-scanner.exe'") | Should Be $true
        $script.Contains('$search += $ffmpegBin') | Should Be $true
        $cmake = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\cmake\CPackOptions.cmake') -Raw
        $cmake.Contains('install(DIRECTORY "${KATAGLYPHIS_GST_PLUGIN_DIR}/" DESTINATION "${CMAKE_INSTALL_LIBDIR}/gstreamer-1.0")') | Should Be $true
        $cmake.Contains('install(PROGRAMS "${KATAGLYPHIS_GST_PLUGIN_SCANNER}" DESTINATION "${CMAKE_INSTALL_BINDIR}")') | Should Be $true
    }

    It 'warns when the selected GStreamer bin is missing' {
        . (Get-BuildFunctionBlock 'Write-MissingGStreamerBinWarning')
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

        function Copy-FixtureBundle($GstBin, [string]$TargetName) {
            $target = Join-Path $TestDrive $TargetName
            Invoke-WithProcessEnvironment -Environment @{ GSTREAMER_BIN = $GstBin } -ScriptBlock {
                $null = Copy-MediaRuntimeBundle -Context $context -TargetDir $target -GStreamerRoot $image -OnnxRoot '' -OnnxGenAiRoot ''
            }
            return (Get-Content -LiteralPath (Join-Path $target 'gstreamer-fixture-only.dll') -Raw).Trim()
        }
        Copy-FixtureBundle $null 'without-env' | Should Be 'image'
        Copy-FixtureBundle $override 'with-env' | Should Be 'override'

        foreach ($case in @(@{ Dll = 'onnxruntime.dll'; Pattern = 'outside the chain install' }, @{ Dll = 'DirectML.dll'; Pattern = 'outside the chain install.*DirectML\.dll' })) {
            $foreign = Join-Path $image $case.Dll
            [IO.File]::WriteAllText($foreign, 'foreign')
            $message = try { $null = Copy-FixtureBundle $null "foreign-$($case.Dll)"; '' } catch { $_.Exception.Message }
            $message | Should Match $case.Pattern
            Remove-Item -LiteralPath $foreign
        }
    }
}
