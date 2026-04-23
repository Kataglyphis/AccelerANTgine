<#
.SYNOPSIS
  Configurable Windows container build script for the Kataglyphis project using the Kataglyphis-ContainerHub build framework.

.DESCRIPTION
  Run with defaults or pass parameters to override workspace path and other options.
  Accepts a -BuildTargets array to selectively build specific targets (e.g. clangcl-debug, clangcl-profile, clangcl-release).
  Builds are executed outside the mounted workspace for performance, and artifacts are synced back upon completion.
#>

param(
    [string]$WorkspaceDir = $PWD.Path,
    [string[]]$BuildTargets = @("clangcl-debug", "clangcl-profile", "clangcl-release"),
    [string]$FastBuildDir = "C:\kataglyphis_fast_build",
    [string]$BuildDirMsvc = "build-msvc-debug",
    [string]$BuildDirClang = "build-clangcl-debug",
    [string]$BuildDirProfile = "build-clangcl-profile",
    [string]$BuildDirClangRelease = "build-clangcl-release",
    [string]$ClangProfilePreset = "x64-ClangCL-Windows-Profile",
    [string]$LLVMBinPath = "C:\Program Files\LLVM\bin",
    [string]$LogDir = "logs",
    [switch]$SkipMSVC,
    [switch]$SkipClangTidy,
    [switch]$SkipStaticAnalysis,
    [switch]$SkipScanBuild,
    [switch]$SkipPGO,
    [switch]$ContinueOnError,
    [switch]$StopOnError
)

$ErrorActionPreference = if ($ContinueOnError) { "Continue" } else { "Stop" }

# Import ContainerHub build framework
$modulesPath = Join-Path $WorkspaceDir "ExternalLib\Kataglyphis-ContainerHub\windows\scripts\modules"
$buildModule = Join-Path $modulesPath "WindowsBuild.Common.psm1"

if (-not (Test-Path $buildModule)) {
    Write-Error "Required module not found: $buildModule. Please ensure ExternalLib is populated."
    exit 1
}

Import-Module $buildModule -Force
Import-Module (Join-Path $modulesPath "WindowsCMake.Common.psm1") -Force
Import-Module (Join-Path $modulesPath "WindowsLogging.Common.psm1") -Force

# Resolve workspace
try {
    $Workspace = (Resolve-Path -Path $WorkspaceDir -ErrorAction Stop).Path
} catch {
    Write-Host "Workspace path doesn't exist, using current directory: $PWD"
    $Workspace = $PWD.Path
}

# Initialize Build Context
$logDirPath = Join-Path $Workspace $LogDir
if (-not (Test-Path $logDirPath)) {
    New-Item -ItemType Directory -Force $logDirPath | Out-Null
}

$Context = New-BuildContext -Workspace $Workspace -LogDir $logDirPath -StopOnError:(-not $ContinueOnError)
Open-BuildLog -Context $Context

try {
    Write-BuildLog -Context $Context -Message "=== Kataglyphis Container Build Script ==="
    Write-BuildLog -Context $Context -Message "Workspace:          $Workspace"
    Write-BuildLog -Context $Context -Message "FastBuildDir:       $FastBuildDir"
    Write-BuildLog -Context $Context -Message "BuildTargets:       $($BuildTargets -join ', ')"
    Write-BuildLog -Context $Context -Message "ClangProfilePreset: $ClangProfilePreset"
    Write-BuildLog -Context $Context -Message "LLVMBinPath:        $LLVMBinPath"
    Write-BuildLog -Context $Context -Message ("=" * 60)

    Set-Location -Path $Workspace

    # Fast Local Cache Initialization (Outside mounted dir)
    $fastLocalCache = Initialize-BuildCacheEnvironment -Context $Context -FastBuildDir $FastBuildDir
    
    $fastBuildMsvcFull = Join-Path $fastLocalCache $BuildDirMsvc
    $fastBuildClangFull = Join-Path $fastLocalCache $BuildDirClang
    $fastBuildProfileFull = Join-Path $fastLocalCache $BuildDirProfile
    $fastBuildReleaseDirFull = Join-Path $fastLocalCache $BuildDirClangRelease

    $srcDir = Join-Path $Workspace "Src"

    $BuildTargets = $BuildTargets -join ',' -split ',' | ForEach-Object { $_.Trim() }

    # Define targets
    $doMsvc    = -not $SkipMSVC -and ($BuildTargets -contains "msvc-debug")
    $doClang   = $BuildTargets -contains "clangcl-debug"
    $doProfile = $BuildTargets -contains "clangcl-profile"
    $doRelease = $BuildTargets -contains "clangcl-release"

    # Helper function for LLVM Paths
    function Get-LLVMRuntimePaths {
        param([string]$LLVMBin)
        if (-not $LLVMBin -or -not (Test-Path $LLVMBin)) { return @() }
        $llvmRoot = Split-Path -Parent $LLVMBin
        $clangRoot = Join-Path $llvmRoot "lib\clang"
        if (-not (Test-Path $clangRoot)) { return @() }
        return Get-ChildItem -Path $clangRoot -Directory -ErrorAction SilentlyContinue |
               ForEach-Object { Join-Path $_.FullName "lib\windows" } |
               Where-Object { Test-Path $_ }
    }

    # --- Step 1: Environment Setup ---
    Invoke-BuildStep -Context $Context -StepName "Environment Setup" -Critical -Script {
        $finalPath = $LLVMBinPath
        if (-not (Test-Path $finalPath)) {
            $clangCl = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
            if ($clangCl) { $finalPath = Split-Path -Parent $clangCl.Source }
        }
        if (Test-Path $finalPath) {
            $env:PATH = "$finalPath;$env:PATH"
            $script:llvmBin = $finalPath
            Write-BuildLog -Context $Context -Message "Added LLVM bin to PATH: $finalPath"
        }

        $scoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
        if (Test-Path $scoopShims) {
            $env:PATH = "$scoopShims;$env:PATH"
            Write-BuildLog -Context $Context -Message "Added Scoop shims to PATH: $scoopShims"
        }
    }

    # --- Step 2: Environment Check ---
    Invoke-BuildStep -Context $Context -StepName "Environment Check" -Script {
        Invoke-BuildExternal -Context $Context -File "clang" -Parameters @("--version") -IgnoreExitCode
        Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--version") -IgnoreExitCode
    }

    # --- MSVC Debug Build ---
    if ($doMsvc) {
        Invoke-BuildStep -Context $Context -StepName "MSVC Debug Build" -Script {
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("-B", $fastBuildMsvcFull, "--preset", "x64-MSVC-Windows-Debug", "-S", $Workspace)
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--build", $fastBuildMsvcFull, "--config", "Debug")
            
            Push-Location $fastBuildMsvcFull
            try { Invoke-BuildExternal -Context $Context -File "ctest" -Parameters @("-C", "Debug", "--output-on-failure") } finally { Pop-Location }

            Sync-BuildArtifacts -Context $Context -Source $fastBuildMsvcFull -Destination (Join-Path $Workspace $BuildDirMsvc) -ExcludeCommonRustAndCppCache
        }
    }

    # --- ClangCL Debug Build ---
    if ($doClang) {
        Invoke-BuildStep -Context $Context -StepName "ClangCL Debug Build" -Critical -Script {
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("-B", $fastBuildClangFull, "--preset", "x64-ClangCL-Windows-Debug", "-S", $Workspace, "-Dmyproject_ENABLE_CPPCHECK=OFF", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--build", $fastBuildClangFull)

            $runtimeDirs = Get-LLVMRuntimePaths -LLVMBin $script:llvmBin
            $asanRuntime = $null
            foreach ($dir in $runtimeDirs) {
                $candidate = Join-Path $dir "clang_rt.asan_dynamic-x86_64.dll"
                if (Test-Path $candidate) { $asanRuntime = $candidate; break }
            }

            if ($asanRuntime) {
                Copy-Item -Path $asanRuntime -Destination (Join-Path $fastBuildClangFull "clang_rt.asan_dynamic-x86_64.dll") -Force
                $clangBinOutput = Join-Path $fastBuildClangFull "bin"
                if (Test-Path $clangBinOutput) {
                    Copy-Item -Path $asanRuntime -Destination (Join-Path $clangBinOutput "clang_rt.asan_dynamic-x86_64.dll") -Force
                }
            }
        }

        Invoke-BuildStep -Context $Context -StepName "ClangCL Debug Tests" -Script {
            $runtimePaths = @((Join-Path $fastBuildClangFull "bin"), (Join-Path $fastBuildClangFull "lib")) + (Get-LLVMRuntimePaths -LLVMBin $script:llvmBin)
            $previousPath = $env:PATH
            $env:PATH = (($runtimePaths + @($env:PATH)) -join ';')

            Push-Location $fastBuildClangFull
            try { Invoke-BuildExternal -Context $Context -File "ctest" -Parameters @("-C", "Debug", "--output-on-failure") } finally { Pop-Location; $env:PATH = $previousPath }
        }

        # Code Coverage
        Invoke-BuildStep -Context $Context -StepName "Code Coverage (llvm-cov)" -Script {
            Push-Location $fastBuildClangFull
            try {
                $profrawPath = Join-Path $fastBuildClangFull "Test\compile\default.profraw"
                if (Test-Path $profrawPath) {
                    $profrawCopyPath = Join-Path $logDirPath "default.profraw"
                    $profdataPath = Join-Path $logDirPath "compileTestSuite.profdata"
                    $coverageJsonPath = Join-Path $logDirPath "coverage.json"
                    
                    Copy-Item -Path $profrawPath -Destination $profrawCopyPath -Force
                    Invoke-BuildExternal -Context $Context -File "llvm-profdata.exe" -Parameters @("merge", "-sparse", $profrawPath, "-o", $profdataPath)
                    Invoke-BuildExternal -Context $Context -File "llvm-cov.exe" -Parameters @("report", "compileTestSuite.exe", "-instr-profile=$profdataPath")
                    
                    $coverageOutput = & llvm-cov.exe export "compileTestSuite.exe" -format=text "-instr-profile=$profdataPath" 2>&1
                    $coverageOutput | Out-File -FilePath $coverageJsonPath -Encoding UTF8
                }
            } finally { Pop-Location }
        }

        # Clang Tidy & Scan Build
        if (-not $SkipClangTidy) {
            Invoke-BuildStep -Context $Context -StepName "clang-tidy Analysis" -Script {
                $sourceFiles = Get-ChildItem -Path $srcDir -Recurse -Include @('*.cpp', '*.cc') | ForEach-Object { $_.FullName }
                $compileCommands = Join-Path $fastBuildClangFull "compile_commands.json"
                if ((Test-Path $compileCommands) -and $sourceFiles.Count -gt 0) {
                    Invoke-BuildExternal -Context $Context -File "clang-tidy" -Parameters (@("--fix", "-checks=-readability-convert-member-functions-to-static,-readability-redundant-declaration,-misc-const-correctness,-google-explicit-constructor,-hicpp-explicit-conversions", "-p=$compileCommands") + $sourceFiles) -IgnoreExitCode
                }
            }
        }
        
        # Sync Debug Artifacts
        Invoke-BuildStep -Context $Context -StepName "Sync ClangCL Debug Artifacts" -Script {
            Sync-BuildArtifacts -Context $Context -Source $fastBuildClangFull -Destination (Join-Path $Workspace $BuildDirClang) -ExcludeCommonRustAndCppCache
        }
    }

    # --- Profile Build ---
    if ($doProfile) {
        Invoke-BuildStep -Context $Context -StepName "Profile Build Configure" -Script {
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("-B", $fastBuildProfileFull, "--preset", $ClangProfilePreset, "-S", $Workspace, "-Dmyproject_ENABLE_CPPCHECK=OFF", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--build", $fastBuildProfileFull)
        }

        Invoke-BuildStep -Context $Context -StepName "Performance Benchmarks" -Script {
            Push-Location $fastBuildProfileFull
            try {
                $perfExe = Join-Path $fastBuildProfileFull "perfTestSuite.exe"
                $benchmarkOutPath = Join-Path $logDirPath "results.json"
                if (Test-Path $perfExe) {
                    Invoke-BuildExternal -Context $Context -File $perfExe -Parameters @("--benchmark_out=$benchmarkOutPath", "--benchmark_out_format=json")
                }
            } finally { Pop-Location }
        }

        if (-not $SkipPGO) {
            Invoke-BuildStep -Context $Context -StepName "PGO (Profile-Guided Optimization)" -Script {
                Push-Location $fastBuildProfileFull
                try {
                    $mainExe = Join-Path $fastBuildProfileFull "KataglyphisCppProject.exe"
                    $dummyProfrawPath = Join-Path $logDirPath "dummy.profraw"
                    if (Test-Path $mainExe) {
                        $env:LLVM_PROFILE_FILE = $dummyProfrawPath
                        Invoke-BuildExternal -Context $Context -File $mainExe -IgnoreExitCode
                    }
                } finally { Pop-Location }
            }
        }
        
        # Sync Profile Artifacts
        Invoke-BuildStep -Context $Context -StepName "Sync ClangCL Profile Artifacts" -Script {
            Sync-BuildArtifacts -Context $Context -Source $fastBuildProfileFull -Destination (Join-Path $Workspace $BuildDirProfile) -ExcludeCommonRustAndCppCache
        }
    }

    # --- Release Build ---
    if ($doRelease) {
        Invoke-BuildStep -Context $Context -StepName "ClangCL Release Build" -Critical -Script {
            Remove-BuildRoot -Context $Context -Path $fastBuildReleaseDirFull | Out-Null
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("-B", $fastBuildReleaseDirFull, "--preset", "x64-ClangCL-Windows-Release", "-S", $Workspace, "-Dmyproject_ENABLE_CPPCHECK=OFF")
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--build", $fastBuildReleaseDirFull)
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--build", $fastBuildReleaseDirFull, "--target", "package")
        }
        
        # Sync Release Artifacts
        Invoke-BuildStep -Context $Context -StepName "Sync ClangCL Release Artifacts" -Script {
            Sync-BuildArtifacts -Context $Context -Source $fastBuildReleaseDirFull -Destination (Join-Path $Workspace $BuildDirClangRelease) -ExcludeCommonRustAndCppCache
        }
    }

} catch {
    Write-BuildLogError -Context $Context -Message "Unhandled critical error: $($_.Exception.Message)"
} finally {
    Write-BuildSummary -Context $Context
    Close-BuildLog -Context $Context
    
    if ($Context.Results.Failed.Count -gt 0) {
        exit 1
    }
}
