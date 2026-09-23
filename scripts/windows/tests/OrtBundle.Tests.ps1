#requires -Version 7.0

# WindowsOrtBundle.Common: a staged bin\ and the Python package carry the image's chain-built ONNX
# Runtime and nothing else (owner rule 2026-09-23), proved by the hub's G6 census. The DLLs are byte
# fixtures with a PE header; the chain is a TestDrive ONNX_ROOT, which G6 takes as its reference.
# NOTE: written for Pester 3.4.0 (what the Windows lane pins) - no BeforeAll
# outside Describe, dash-less Should, and no `Should Throw` under pwsh 7.

Describe 'WindowsOrtBundle.Common' {

    . (Join-Path $PSScriptRoot '..\Resolve-BuildModule.ps1')
    Import-BuildModule @('WindowsOnnx.Common', 'WindowsOrtBundle.Common', 'WindowsOrtProvenance.Common')

    $chainSrc = 'C:\temp\onnx-src\onnxruntime\core\session\inference_session.cc'
    $foreignSrc = 'C:\__w\1\s\onnxruntime\core\session\inference_session.cc'

    # MZ, e_lfanew = 0x40, 'PE\0\0', machine amd64: enough for Get-PeFileMachine; the text follows.
    function New-FakePe([string] $Path, [string] $Text) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
        $h = [byte[]]::new(0x80)
        $h[0] = 0x4D; $h[1] = 0x5A; $h[0x3C] = 0x40; $h[0x40] = 0x50; $h[0x41] = 0x45; $h[0x44] = 0x64; $h[0x45] = 0x86
        [System.IO.File]::WriteAllBytes($Path, [byte[]]($h + [System.Text.Encoding]::Latin1.GetBytes("`0$Text`0")))
    }

    function Get-ThrowText([scriptblock] $Block) {
        try { & $Block | Out-Null } catch { return "$($_.Exception.Message)" }
        return ''
    }

    function New-ChainRoot([string] $Name) {
        $root = Join-Path $TestDrive "$Name\onnx"
        New-FakePe (Join-Path $root 'bin\onnxruntime.dll') "$chainSrc OrtGetApiBase"
        New-FakePe (Join-Path $root 'bin\onnxruntime_providers_shared.dll') 'provider bridge'
        New-FakePe (Join-Path $root 'bin\DirectML.dll') 'directml'
        return $root
    }

    function Invoke-WithOnnxRoot([string] $Root, [scriptblock] $Block) {
        $saved = $env:ONNX_ROOT
        $env:ONNX_ROOT = $Root
        try { & $Block } finally { $env:ONNX_ROOT = $saved }
    }

    It 'stages the chain layout over a stale NuGet copy and passes G6 on the Python package' {
        $root = New-ChainRoot 'py'
        $pkg = Join-Path $TestDrive 'py\python\kataglyphis_inference'
        $libs = Join-Path $pkg '_libs'
        New-FakePe (Join-Path $pkg '_core.cp314-win_amd64.pyd') 'OrtGetApiBase'
        New-FakePe (Join-Path $pkg 'AccelerANTgine.dll') 'OrtGetApiBase'
        New-FakePe (Join-Path $libs 'onnxruntime.dll') $foreignSrc
        Invoke-WithOnnxRoot $root {
            Copy-ChainOrtLib -OnnxRoot $root -Destination $libs
            (Get-Item (Join-Path $libs 'DirectML.dll')).Length | Should Be (Get-Item (Join-Path $root 'bin\DirectML.dll')).Length
            Get-ThrowText { Assert-BundleChainOrt -Root (Split-Path $pkg -Parent) -DllDirectory $libs } | Should Be ''
        }
    }

    It 'keeps every G6 byte verdict for the Python package, and needs onnxruntime.dll in _libs (mutation)' {
        $root = New-ChainRoot 'pyred'
        $pkg = Join-Path $TestDrive 'pyred\python\kataglyphis_inference'
        $libs = Join-Path $pkg '_libs'
        New-FakePe (Join-Path $pkg 'AccelerANTgine.dll') 'OrtGetApiBase'
        Invoke-WithOnnxRoot $root {
            Copy-ChainOrtLib -OnnxRoot $root -Destination $libs
            $tree = Split-Path $pkg -Parent
            # G6 alone cannot model os.add_dll_directory: without -DllDirectory it reports the fall-through.
            Get-ThrowText { Assert-BundleChainOrt -Root $tree } | Should Match 'UNRESOLVED'
            New-FakePe (Join-Path $pkg 'onnxruntime.dll') $foreignSrc
            Get-ThrowText { Assert-BundleChainOrt -Root $tree -DllDirectory $libs } | Should Match 'FOREIGN'
            Remove-Item -LiteralPath (Join-Path $pkg 'onnxruntime.dll')
            New-FakePe (Join-Path $libs 'onnxruntime.dll') "$chainSrc FileVersion 1.27.0"
            Get-ThrowText { Assert-BundleChainOrt -Root $tree -DllDirectory $libs } | Should Match 'STALE'
            Remove-Item -LiteralPath (Join-Path $libs 'onnxruntime.dll')
            Get-ThrowText { Assert-BundleChainOrt -Root $tree -DllDirectory $libs } | Should Match 'MISSING'
        }
    }

    It 'refuses an ONNX_ROOT laid out as a NuGet package or a release zip' {
        $nuget = Join-Path $TestDrive 'nuget\onnx'
        New-FakePe (Join-Path $nuget 'runtimes\win-x64\native\onnxruntime.dll') $foreignSrc
        Get-ThrowText { Copy-ChainOrtLib -OnnxRoot $nuget -Destination (Join-Path $TestDrive 'nuget\libs') } | Should Match 'not the chain install'
        Get-ThrowText { Copy-ChainOrtLib -OnnxRoot '' -Destination (Join-Path $TestDrive 'nuget\libs') } | Should Match 'ONNX_ROOT is not set'
    }

    It 'passes a bin\ holding the chain ORT; fails one the pre-G6 hub left without it, or with other bytes (mutation)' {
        $root = New-ChainRoot 'bin'
        $bin = Join-Path $TestDrive 'bin\build\bin'
        New-FakePe (Join-Path $bin 'AccelerANTgine.exe') 'main'
        New-FakePe (Join-Path $bin 'AccelerANTgine.dll') 'OrtGetApiBase'
        Invoke-WithOnnxRoot $root {
            $missing = Get-ThrowText { Assert-BundleChainOrt -Root $bin }
            $missing | Should Match 'MISSING'
            $missing | Should Match "Windows ML"
            Copy-Item -LiteralPath (Join-Path $root 'bin\onnxruntime.dll'), (Join-Path $root 'bin\onnxruntime_providers_shared.dll') -Destination $bin
            Get-ThrowText { Assert-BundleChainOrt -Root $bin } | Should Be ''
            New-FakePe (Join-Path $bin 'onnxruntime.dll') $foreignSrc
            Get-ThrowText { Assert-BundleChainOrt -Root $bin } | Should Match 'FOREIGN'
        }
    }

    It 'proves a whole install tree: the chain ORT in bin\, any ORT elsewhere graded, UNRESOLVED fatal (mutation)' {
        $root = New-ChainRoot 'inst'
        $prefix = Join-Path $TestDrive 'inst\prefix'
        $bin = Join-Path $prefix 'bin'
        New-FakePe (Join-Path $bin 'AccelerANTgine_cli.exe') 'main'
        New-FakePe (Join-Path $bin 'AccelerANTgine.dll') 'OrtGetApiBase'
        Invoke-WithOnnxRoot $root {
            Get-ThrowText { Assert-BundleChainOrt -Root $prefix -ExeDirectory $bin } | Should Match 'MISSING'
            Copy-Item -LiteralPath (Join-Path $root 'bin\onnxruntime.dll') -Destination $bin
            Get-ThrowText { Assert-BundleChainOrt -Root $prefix -ExeDirectory $bin } | Should Be ''
            New-FakePe (Join-Path $prefix 'share\extra\onnxruntime.dll') $foreignSrc
            Get-ThrowText { Assert-BundleChainOrt -Root $prefix -ExeDirectory $bin } | Should Match 'FOREIGN .*share'
            Remove-Item -LiteralPath (Join-Path $prefix 'share') -Recurse
            # An installed exe outside bin\ has no ORT beside it: an exe's loader, so no os.add_dll_directory waiver.
            New-FakePe (Join-Path $prefix 'tools\probe.exe') 'OrtGetApiBase'
            Get-ThrowText { Assert-BundleChainOrt -Root $prefix -ExeDirectory $bin } | Should Match 'UNRESOLVED .*probe.exe'
        }
    }

    It 'wires G6 into the release: the install tree CPack packs is proved before --target package (mutation)' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Build-Windows.ps1'), [ref] $tokens, [ref] $errors)
        $step = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Invoke-BuildStep' -and $n.Extent.Text -match '-StepName "ClangCL Release Build"' }, $true))
        $step.Count | Should Be 1
        $text = $step[0].Extent.Text
        $install = $text.IndexOf('"--install", $fastBuildReleaseDirFull')
        $proof = $text.IndexOf('Assert-BundleChainOrt -Root $installProof -ExeDirectory')
        ($install -ge 0 -and $install -lt $proof -and $proof -lt $text.IndexOf('"--target", "package"')) | Should Be $true
    }

    It 'names the hub commit when the pinned hub lacks G6' {
        (Get-OrtCensusRequirement -Cause 'not found') | Should Match 'ORT single-source commit of 2026-09-23'
    }
}
