#requires -Version 7.0

# This checks the GenAI staging function and its Stage Tests wiring, not a Windows build or a loaded DLL.
Describe 'ONNX Runtime GenAI staging for the staged suites' {
    Import-Module (Join-Path $PSScriptRoot 'BuildAstFixture.psm1') -ErrorAction Stop
    $ast = Get-BuildScriptAst
    . (Get-BuildFunctionBlock 'Copy-ChainGenaiBeside')

    It 'copies the chain DLL from bin or from lib and returns its staged path' {
        $saved = $env:ONNX_GENAI_ROOT
        try {
            foreach ($dir in 'bin', 'lib') {
                $root = Join-Path $TestDrive "genai-$dir"
                $null = New-Item -ItemType Directory -Force -Path (Join-Path $root $dir)
                Set-Content -LiteralPath (Join-Path (Join-Path $root $dir) 'onnxruntime-genai.dll') -Value $dir
                $destination = Join-Path $TestDrive "staged-$dir"
                $null = New-Item -ItemType Directory -Force -Path $destination
                $env:ONNX_GENAI_ROOT = $root
                (Copy-ChainGenaiBeside -Destination $destination) | Should Be (Join-Path $destination 'onnxruntime-genai.dll')
                (Get-Content -LiteralPath (Join-Path $destination 'onnxruntime-genai.dll')) | Should Be $dir
            }
        } finally { $env:ONNX_GENAI_ROOT = $saved }
    }

    It 'refuses an unset root and a root without the DLL (mutation)' {
        $saved = $env:ONNX_GENAI_ROOT
        try {
            $env:ONNX_GENAI_ROOT = ''
            { Copy-ChainGenaiBeside -Destination $TestDrive } | Should Throw 'ONNX_GENAI_ROOT is not set'
            $env:ONNX_GENAI_ROOT = Join-Path $TestDrive 'empty-genai'
            $null = New-Item -ItemType Directory -Force -Path $env:ONNX_GENAI_ROOT
            { Copy-ChainGenaiBeside -Destination $TestDrive } | Should Throw 'holds no onnxruntime-genai.dll'
        } finally { $env:ONNX_GENAI_ROOT = $saved }
    }

    It 'stages GenAI, its own imports and the test model beside the suites in Stage Tests (mutation)' {
        $text = (Get-UniqueBuildAstNode -Ast $ast -StepName 'Stage Tests (').Extent.Text
        foreach ($pattern in 'Copy-ChainGenaiBeside -Destination \$tests', 'Copy-PeImportClosure -Path @\(\$genai\)', "Join-Path \`$fastBuildReleaseDirFull 'test-models'") {
            $text | Should Match $pattern
        }
    }
}
