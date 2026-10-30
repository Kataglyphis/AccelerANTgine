#requires -Version 7.0

<#
.SYNOPSIS
  Windows container build of the -BuildTargets configurations, on the ANTfrastructure build framework.

.DESCRIPTION
  Builds outside the mounted workspace and syncs back; clangcl-release packages to dist\windows-<x64|arm64>.
  -TargetArch arm64 cross-builds clangcl-release only (windows-arm64-cross.yml).
#>

param(
    [string]$WorkspaceDir = $PWD.Path,
    [string[]]$BuildTargets = @("clangcl-debug", "clangcl-profile", "clangcl-release"),
    # Build dirs and presets are rows in Build-Windows.config.psd1, which also defaults FastBuildDir and LogDir.
    [string]$ConfigPath,
    [string]$FastBuildDir,
    [string]$LLVMBinPath = "C:\Program Files\LLVM\bin",
    [string]$LogDir,
    [switch]$SkipFormat,
    [switch]$SkipMSVC,
    [switch]$SkipClangTidy,
    [switch]$SkipStaticAnalysis,
    [switch]$SkipScanBuild,
    [switch]$SkipPGO,
    [switch]$SkipMSIX,
    [switch]$ContinueOnError,
    [switch]$StopOnError,
    # amd64 (alias x64) or arm64; empty means the image's WINDOWS_TARGET_ARCH, else amd64.
    [string]$TargetArch = '',
    # Release also builds the four suites and stages them in dist\windows-<arch>-tests (arm64 run job, x64 host run).
    [switch]$StageTests
)

$ErrorActionPreference = if ($ContinueOnError) { "Continue" } else { "Stop" }

# The shared bootstrap names the exact `git submodule update` fix when the submodule is missing.
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')

# Dependency order; nested .psm1 imports are module-private, so every module called here is listed.
Import-BuildModule @(
    'WindowsScripts.Shared'
    'WindowsBuild.Common'
    'WindowsConfig.Common'
    'WindowsToolchain.Common'
    'WindowsUv.Common'
    'WindowsFormatting.Common'
    'WindowsCMake.Common'
    'WindowsClang.Common'
    'WindowsTesting.Common'
    'WindowsMsix.Common'
    'WindowsMsix.Signing'
    'WindowsOnnx.Common'
    'WindowsMediaRuntime.Common'
    'WindowsTargetArch.Common'  # the target: accepted spellings, cross or not, the MSVC lib dir
)
# Cross arguments, package arch, the DLL closure and the portable bundle; an older hub pin lacks New-PortableBundle.
try {
    Import-BuildModule @('WindowsCrossBundle.Common')
    $null = Get-Command -Name 'New-PortableBundle' -ErrorAction Stop
} catch {
    throw "This build needs ANTfrastructure's WindowsCrossBundle.Common with New-PortableBundle (hub 3d26fac7 of 2026-10-19, third_party/ANTfrastructure/docs/windows-cross-builds.md); move third_party/ANTfrastructure to it or later. ($($_.Exception.Message))"
}
$TargetArch = Get-WindowsTargetArch -Arch $TargetArch
$isCross = Test-WindowsCrossTarget -Arch $TargetArch
$packageArch = Get-WindowsPackageArch -Arch $TargetArch
# Before the log opens, so a refusal exits non-zero; Debug's aarch64 ASan runtime exists since 2026-10-03, Profile runs on the host, MSVC pins x64.
$requestedTargets = @($BuildTargets -join ',' -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$notCross = @($requestedTargets | Where-Object { $_ -notin 'clangcl-release', 'clangcl-debug' })
if ($isCross -and $notCross.Count -gt 0) {
    throw "-TargetArch $TargetArch builds clangcl-release and clangcl-debug, not $($notCross -join ', ') (third_party/ANTfrastructure/docs/windows-cross-builds.md)."
}
# The G6 proof of every staged bin\, install tree and payload; an older hub pin lacks it.
try { Import-BuildModule @('WindowsOrtProvenance.Common', 'WindowsOrtPayload.Common', 'WindowsMsiLicense.Common', 'WindowsOrtLicense.Common') } catch {
    throw "This build needs ANTfrastructure's WindowsOrtPayload.Common (hub commit 73a8dd74 of 2026-09-25, third_party/ANTfrastructure/docs/onnxruntime-single-source.md § The shared Windows glue); move third_party/ANTfrastructure to it or later. ($($_.Exception.Message))"
}

# The build table: a preset rename is a data edit, and every row carries its own environment override.
$configPathResolved = Get-OrDefault $ConfigPath (Join-Path $PSScriptRoot 'Build-Windows.config.psd1')
if (-not (Test-Path $configPathResolved)) {
    throw "Build config not found: $configPathResolved"
}
$BuildConfig = Import-PowerShellDataFile -Path $configPathResolved

# For host runs only: a VS 2022 runner's redistributable is older than the toolset the binaries import from.
function Copy-AppLocalVcRuntime {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string[]]$Destination
    )
    $crt = @()
    if ($env:VCToolsRedistDir) {
        $crt = @(Get-ChildItem -Path (Join-Path $env:VCToolsRedistDir "$packageArch\Microsoft.VC*.CRT\*.dll") -File -ErrorAction SilentlyContinue)
    }
    if ($crt.Count -eq 0) {
        Write-BuildLogWarning -Context $Context -Message "No VC++ runtime under VCToolsRedistDir ('$env:VCToolsRedistDir'); host runs of this tree use the host's redistributable."
        return
    }
    foreach ($dir in $Destination) {
        foreach ($dll in $crt) { Copy-Item -LiteralPath $dll.FullName -Destination $dir -Force }
    }
    Write-BuildLog -Context $Context -Message "App-local VC++ runtime: $($crt.Count) DLL(s) from $($crt[0].DirectoryName) -> $($Destination -join ', ')"
}

# The shared bundler permits ORT-only builds, so this consumer keeps its missing-GStreamer hint.
function Write-MissingGStreamerBinWarning {
    param([Parameter(Mandatory)][pscustomobject]$Context)
    $gstBin = if ($env:GSTREAMER_BIN) { $env:GSTREAMER_BIN } else { 'C:\runtime\bin' }
    if (-not (Test-Path -LiteralPath $gstBin -PathType Container)) {
        Write-BuildLogWarning -Context $Context -Message "GStreamer bin not found ($gstBin); host runs of this tree lack GStreamer."
    }
}

# GStreamer looks for plugins in <dir of gstreamer-1.0-0.dll, minus a trailing bin>\lib\gstreamer-1.0; build\bin holds that DLL.
function Copy-ImageGStreamerTestPlugins {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$BuildRoot
    )
    $gstBin = if ($env:GSTREAMER_BIN) { $env:GSTREAMER_BIN } else { 'C:\runtime\bin' }
    $pluginDir = Join-Path (Split-Path -Parent $gstBin) 'lib\gstreamer-1.0'
    $destination = Join-Path $BuildRoot 'lib\gstreamer-1.0'
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    # The elements the GStreamer tests and benchmarks build pipelines from; their DLL closure is already in bin\.
    $wanted = @('gstcoreelements', 'gstapp', 'gstvideotestsrc', 'gstvideoconvertscale')
    $copied = @(foreach ($name in $wanted) {
            $dll = Join-Path $pluginDir "$name.dll"
            if (Test-Path -LiteralPath $dll -PathType Leaf) {
                Copy-Item -LiteralPath $dll -Destination $destination -Force
                $name
            }
        })
    $missing = @($wanted | Where-Object { $_ -notin $copied })
    if ($missing.Count) {
        Write-BuildLogWarning -Context $Context -Message "GStreamer test plugins missing from ${pluginDir}: $($missing -join ', '); the tests that need them skip."
    }
    Write-BuildLog -Context $Context -Message "GStreamer test plugins: $($copied -join ', ') -> $destination"
}

function Copy-BuildMediaRuntime {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$BuildRoot,
        [switch]$StageTestPlugins,
        [switch]$CopyOrtBeside
    )
    $bin = Join-Path $BuildRoot 'bin'
    Write-MissingGStreamerBinWarning -Context $Context
    $null = Copy-MediaRuntimeBundle -Context $Context -TargetDir $bin -GStreamerRoot 'C:\runtime\bin'
    if ($StageTestPlugins) { Copy-ImageGStreamerTestPlugins -Context $Context -BuildRoot $BuildRoot }
    $null = Assert-ChainOrtTree -Root $bin
    Copy-AppLocalVcRuntime -Context $Context -Destination @($bin, $BuildRoot)
    # Suites at the build root must load the chain ORT before Windows ML's System32 copy.
    if ($CopyOrtBeside) { $null = Copy-ChainOrtBeside -OnnxRoot $env:ONNX_ROOT -Destination $BuildRoot }
}

# GenAI loads at run time, so no import closure finds it; a staged suite needs the chain DLL beside it.
function Copy-ChainGenaiBeside {
    param([Parameter(Mandatory)][string]$Destination)
    if (-not $env:ONNX_GENAI_ROOT) { throw 'ONNX_GENAI_ROOT is not set; the staged suites cannot load ONNX Runtime GenAI' }
    $dll = @('bin', 'lib') | ForEach-Object { Join-Path (Join-Path $env:ONNX_GENAI_ROOT $_) 'onnxruntime-genai.dll' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $dll) { throw "ONNX_GENAI_ROOT ($env:ONNX_GENAI_ROOT) holds no onnxruntime-genai.dll in bin\ or lib\" }
    Copy-Item -LiteralPath $dll -Destination $Destination -Force
    return (Join-Path $Destination 'onnxruntime-genai.dll')
}

# The install-time notices list every DLL the closure added; each ZIP and MSI must carry that exact list.
function Assert-InstallerNotice {
    param(
        [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)][string]$PackageDir,
        [string[]]$Installer = @()
    )
    $notices = Join-Path $Bundle 'licenses\THIRD-PARTY-NOTICES.txt'
    if (-not (Test-Path -LiteralPath $notices -PathType Leaf)) { throw "The install tree lacks $notices" }
    $zips = @($Installer | Where-Object { $_ -like '*.zip' })
    $msis = @($Installer | Where-Object { $_ -like '*.msi' })
    if ($zips.Count -eq 0 -or $msis.Count -eq 0) { throw 'CPack produced no ZIP or no MSI for third-party notice verification' }
    foreach ($zip in $zips) {
        Assert-PackageLicense -Path (Join-Path $PackageDir $zip) -Pattern '*/licenses/THIRD-PARTY-NOTICES.txt' -LicensePath $notices
    }
    foreach ($msi in $msis) {
        Assert-MsiPackageLicense -Path (Join-Path $PackageDir $msi) -FileName 'THIRD-PARTY-NOTICES.txt' -LicensePath $notices
    }
}

$FastBuildDir = Get-OrDefault $FastBuildDir (Get-ConfigValue -Config $BuildConfig -Path 'Build.FastBuildDir')
$LogDir = Get-OrDefault $LogDir (Get-ConfigValue -Config $BuildConfig -Path 'Build.LogDir')

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
$unhandledError = $false

try {
    Write-BuildLog -Context $Context -Message "=== Kataglyphis Container Build Script ==="
    Write-BuildLog -Context $Context -Message "Workspace:          $Workspace"
    Write-BuildLog -Context $Context -Message "FastBuildDir:       $FastBuildDir"
    Write-BuildLog -Context $Context -Message "BuildTargets:       $($BuildTargets -join ', ')"
    Write-BuildLog -Context $Context -Message "BuildConfig:        $configPathResolved"
    Write-BuildLog -Context $Context -Message "LLVMBinPath:        $LLVMBinPath"
    Write-BuildLog -Context $Context -Message "TargetArch:         $TargetArch$(if ($isCross) { ' (cross)' })"
    Write-BuildLog -Context $Context -Message ("=" * 60)

    Set-Location -Path $Workspace

    # ctest exits 0 on a tree that registered no test at all; every ctest run below must fail that instead.
    $env:CTEST_NO_TESTS_ACTION = 'error'

    # Fast Local Cache Initialization (Outside mounted dir)
    $fastLocalCache = Initialize-BuildCacheEnvironment -Context $Context -FastBuildDir $FastBuildDir
    
    # The --config value also decides whether Invoke-CmakeConfigureAndBuild stages the sanitizer runtime.
    $cfgMsvc = Get-BuildConfigurationRow -Config $BuildConfig -Name 'msvc-debug' -ConfigPath $configPathResolved
    $cfgClang = Get-BuildConfigurationRow -Config $BuildConfig -Name 'clangcl-debug' -ConfigPath $configPathResolved
    $cfgProfile = Get-BuildConfigurationRow -Config $BuildConfig -Name 'clangcl-profile' -ConfigPath $configPathResolved
    $cfgRelease = Get-BuildConfigurationRow -Config $BuildConfig -Name 'clangcl-release' -ConfigPath $configPathResolved

    foreach ($cfg in @($cfgMsvc, $cfgClang, $cfgProfile, $cfgRelease)) {
        Write-BuildLog -Context $Context -Message ("Configuration {0,-16} -> {1} / {2} / {3}" -f $cfg.Name, $cfg.BuildDir, $cfg.Preset, $cfg.Configuration)
    }

    $fastBuildMsvcFull = Join-Path $fastLocalCache $cfgMsvc.BuildDir
    $fastBuildClangFull = Join-Path $fastLocalCache $cfgClang.BuildDir
    $fastBuildProfileFull = Join-Path $fastLocalCache $cfgProfile.BuildDir
    # A cross build keeps its own tree beside the host's, so neither clobbers the other.
    $releaseBuildDir = if ($isCross) { "$($cfgRelease.BuildDir)-$TargetArch" } else { $cfgRelease.BuildDir }
    $fastBuildReleaseDirFull = Join-Path $fastLocalCache $releaseBuildDir

    $BuildTargets = $BuildTargets -join ',' -split ',' | ForEach-Object { $_.Trim() }

    # Define targets
    $doMsvc    = -not $SkipMSVC -and ($BuildTargets -contains "msvc-debug")
    $doClang   = $BuildTargets -contains "clangcl-debug"
    $doProfile = $BuildTargets -contains "clangcl-profile"
    $doRelease = $BuildTargets -contains "clangcl-release"

    # --- Step 1: Environment Setup ---
    Invoke-BuildStep -Context $Context -StepName "Environment Setup" -Critical -Script {
        $finalPath = $LLVMBinPath
        if (-not (Test-Path $finalPath)) {
            $clangCl = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
            if ($clangCl) { $finalPath = Split-Path -Parent $clangCl.Source }
        }
        Add-DirectoriesToPath @(
            $finalPath
            (Join-Path $env:USERPROFILE 'scoop\shims')
        )
        Write-BuildLog -Context $Context -Message "PATH front: $finalPath and the Scoop shims (when present)"
    }

    # --- Step 2: Environment Check (reports, never aborts) ---
    Invoke-BuildStep -Context $Context -StepName "Environment Check" -Script {
        Invoke-ToolchainChecks -Context $Context -ToolArguments @{
            clang = @('--version')
            cmake = @('--version')
        }
    }

    # --- Step 3: cmake-format, in place like the Linux gate (no -Check) ---
    if (-not $SkipFormat) {
        # The Linux lane's pinned cmake-format; .venv is excluded because the step's own venv holds CMake files.
        $cmakeFormatProject = Join-Path $Workspace 'third_party\ANTfrastructure\quality\cmake-format'
        Invoke-BuildStep -Context $Context -StepName "Python tooling + cmake-format" -Critical -Script {
            Invoke-CmakeFormatStep -Context $Context -WorkspacePath $Workspace `
                -UvProjectPath $cmakeFormatProject `
                -ExcludePattern @('\\\.venv\\')
        }

        # The other half of the Linux format gate; -SkipFormat opts out of both.
        Invoke-BuildStep -Context $Context -StepName "clang-format" -Critical -Script {
            Invoke-ClangFormatStep -Context $Context -WorkspacePath $Workspace
        }
    }

    # --- MSVC Debug Build ---
    if ($doMsvc) {
        Invoke-BuildStep -Context $Context -StepName "MSVC Debug Build" -Script {
            # No -S is passed, so the preset's sourceDir applies and cwd must be the workspace.
            Push-Location $Workspace
            try {
                Invoke-CmakeConfigureAndBuild -Context $Context `
                    -BuildPath $fastBuildMsvcFull `
                    -Preset $cfgMsvc.Preset `
                    -Configuration $cfgMsvc.Configuration
            } finally { Pop-Location }

            # This lane links Microsoft's ASan runtime, which is not interchangeable with LLVM's.
            Invoke-CtestDiscoveredTests -Context $Context `
                -BuildRoot $fastBuildMsvcFull `
                -Configuration $cfgMsvc.Configuration `
                -RuntimeFlavor Msvc

            Sync-BuildArtifacts -Context $Context -Source $fastBuildMsvcFull -Destination (Join-Path $Workspace $cfgMsvc.BuildDir) -ExcludeCommonRustAndCppCache
        }
    }

    # --- ClangCL Debug Build ---
    if ($doClang) {
        Invoke-BuildStep -Context $Context -StepName "ClangCL Debug Build" -Critical -Script {
            # -Configuration Debug is what makes Invoke-CmakeConfigureAndBuild stage the sanitizer runtime DLLs.
            Push-Location $Workspace
            try {
                Invoke-CmakeConfigureAndBuild -Context $Context `
                    -BuildPath $fastBuildClangFull `
                    -Preset $cfgClang.Preset `
                    -Configuration $cfgClang.Configuration `
                    -ConfigureExtraArgs (@('-Dmyproject_ENABLE_CPPCHECK=OFF', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON') +
                        @(Get-CrossConfigureArgs -Arch $TargetArch -Corrosion))
            } finally { Pop-Location }

            Copy-BuildMediaRuntime -Context $Context -BuildRoot $fastBuildClangFull -StageTestPlugins -CopyOrtBeside
        }

        # A cross build stages the instrumented suite for the arm64 runner instead: the container cannot execute it.
        if (-not $isCross) {
            Invoke-BuildStep -Context $Context -StepName "ClangCL Debug Tests" -Script {
                # The hub logs sanitizer reports to files beside the tests; a later log_path wins, so they reach ctest's output.
                $savedAsanOptions = $env:ASAN_OPTIONS
                $env:ASAN_OPTIONS = 'log_path=stderr'
                try {
                    Invoke-CtestDiscoveredTests -Context $Context `
                        -BuildRoot $fastBuildClangFull `
                        -Configuration $cfgClang.Configuration `
                        -RuntimeFlavor Clang
                } finally {
                    $env:ASAN_OPTIONS = $savedAsanOptions
                }
            }
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
            # Disables go on -Checks, not the shared .clang-tidy; only the compiler's own clang-tidy reads its BMIs (AGENTS.md section 4).
            Invoke-BuildStep -Context $Context -StepName "clang-tidy Analysis" -Script {
                $tidyArgs = @{
                    Context            = $Context
                    WorkspacePath      = $Workspace
                    BuildRoot          = $fastBuildClangFull
                    SourceSubdirectory = 'Src'
                    Extension          = @('.cpp', '.cc', '.cxx', '.ixx', '.cppm', '.mxx')
                    Checks             = @('-checks=-readability-convert-member-functions-to-static,-readability-redundant-declaration,-misc-const-correctness,-google-explicit-constructor,-hicpp-explicit-conversions')
                    Fix                = $true
                }
                $cache = Join-Path $fastBuildClangFull 'CMakeCache.txt'
                $compilerLine = Select-String -Path $cache -Pattern '^CMAKE_CXX_COMPILER:[A-Z]+=(.+)$' -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                $ownTidy = if ($compilerLine) { Join-Path (Split-Path -Parent $compilerLine.Matches[0].Groups[1].Value) 'clang-tidy.exe' }
                $savedPath = $env:PATH
                try {
                    if ($ownTidy -and (Test-Path $ownTidy)) {
                        $env:PATH = "$(Split-Path -Parent $ownTidy);$env:PATH"
                        # The compiler's own tidy reads the BMIs it built (hub CON10), so no TU needs the BMI skip.
                        $tidyArgs.ModuleImportPattern = '(?!)'
                        Write-BuildLog -Context $Context -Message "clang-tidy: the compiler's own, $ownTidy; every Src/ TU analysed"
                    } else {
                        $tidyArgs.ModuleImportPattern = '(?m)^\s*((export\s+)?import\s+[\w.:<>"/]+|module\s+[\w.:]+)\s*;'
                        Write-BuildLog -Context $Context -Message "clang-tidy: none beside the compiler ($(if ($compilerLine) { $compilerLine.Matches[0].Groups[1].Value } else { "no CMAKE_CXX_COMPILER in $cache" })); every TU that needs a BMI is skipped"
                    }
                    Invoke-ClangTidyFixStep @tidyArgs
                } finally {
                    $env:PATH = $savedPath
                }
            }
        }
        
        # Sync Debug Artifacts
        Invoke-BuildStep -Context $Context -StepName "Sync ClangCL Debug Artifacts" -Script {
            # A cross build keeps its own tree beside the host's, so neither clobbers the other.
            $debugBuildDir = if ($isCross) { "$($cfgClang.BuildDir)-$TargetArch" } else { $cfgClang.BuildDir }
            Sync-BuildArtifacts -Context $Context -Source $fastBuildClangFull -Destination (Join-Path $Workspace $debugBuildDir) -ExcludeCommonRustAndCppCache
        }
    }

    # --- Profile Build ---
    if ($doProfile) {
        Invoke-BuildStep -Context $Context -StepName "Profile Build Configure" -Script {
            Push-Location $Workspace
            try {
                Invoke-CmakeConfigureAndBuild -Context $Context `
                    -BuildPath $fastBuildProfileFull `
                    -Preset $cfgProfile.Preset `
                    -Configuration $cfgProfile.Configuration `
                    -ConfigureExtraArgs @('-Dmyproject_ENABLE_CPPCHECK=OFF', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON')
            } finally { Pop-Location }

            Copy-BuildMediaRuntime -Context $Context -BuildRoot $fastBuildProfileFull -StageTestPlugins -CopyOrtBeside
        }

        Invoke-BuildStep -Context $Context -StepName "Performance Benchmarks" -Script {
            Push-Location $fastBuildProfileFull
            try {
                $perfExe = Join-Path $fastBuildProfileFull "perfTestSuite.exe"
                $benchmarkOutPath = Join-Path $logDirPath "results.json"
                if (Test-Path $perfExe) {
                    # The suite imports AccelerANTgine.dll and its closure, which sit in bin\, not beside the exe.
                    Invoke-WithRuntimePath -RuntimeDirs @((Join-Path $fastBuildProfileFull 'bin')) -AsanOptions '' -Script {
                        Invoke-BuildExternal -Context $Context -File $perfExe -Parameters @("--benchmark_out=$benchmarkOutPath", "--benchmark_out_format=json")
                    }
                }
            } finally { Pop-Location }
        }

        if (-not $SkipPGO) {
            Invoke-BuildStep -Context $Context -StepName "PGO (Profile-Guided Optimization)" -Script {
                Push-Location $fastBuildProfileFull
                try {
                    $mainExe = Join-Path $fastBuildProfileFull "bin\AccelerANTgine.exe"
                    $dummyProfrawPath = Join-Path $logDirPath "dummy.profraw"
                    if (Test-Path $mainExe) {
                        $env:LLVM_PROFILE_FILE = $dummyProfrawPath
                        Invoke-BuildExternal -Context $Context -File $mainExe -Parameters @() -IgnoreExitCode
                    }
                } finally { Pop-Location }
            }
        }
        
        # Sync Profile Artifacts
        Invoke-BuildStep -Context $Context -StepName "Sync ClangCL Profile Artifacts" -Script {
            Sync-BuildArtifacts -Context $Context -Source $fastBuildProfileFull -Destination (Join-Path $Workspace $cfgProfile.BuildDir) -ExcludeCommonRustAndCppCache
        }
    }

    # --- Release Build ---
    if ($doRelease) {
        Invoke-BuildStep -Context $Context -StepName "ClangCL Release Build" -Critical -Script {
            # Only this lane cleans, since a package must inherit nothing; CPack installs package-dlls beside the executables.
            $packageDlls = Join-Path $fastBuildReleaseDirFull 'package-dlls'
            Push-Location $Workspace
            try {
                Invoke-CmakeConfigureAndBuild -Context $Context `
                    -BuildPath $fastBuildReleaseDirFull `
                    -Preset $cfgRelease.Preset `
                    -Configuration $cfgRelease.Configuration `
                    -CleanBuildRoot `
                    -ConfigureExtraArgs (@('-Dmyproject_ENABLE_CPPCHECK=OFF', '-DENABLE_WIX_PACKAGING=ON',
                            "-DKATAGLYPHIS_PACKAGE_DLL_DIR=$($packageDlls -replace '\\', '/')") +
                        @(if ($StageTests) { '-DBUILD_TESTING=ON', '-DKATAGLYPHIS_RELEASE_TESTS=ON' }) +
                        @(Get-CrossConfigureArgs -Arch $TargetArch -Corrosion))
            } finally { Pop-Location }

            Copy-BuildMediaRuntime -Context $Context -BuildRoot $fastBuildReleaseDirFull
            # Everything the engine imports transitively that a clean machine lacks.
            New-Item -ItemType Directory -Force -Path $packageDlls | Out-Null
            $engine = @('AccelerANTgine.exe', 'AccelerANTgine.dll') | ForEach-Object { Join-Path $fastBuildReleaseDirFull "bin\$_" }
            $closure = @(Copy-PeImportClosure -Path $engine -SearchDirectory @(Get-ProductDllSearchPath -Arch $TargetArch) -Destination $packageDlls -Arch $TargetArch)
            $null = Copy-OrtWheelLicenses -OrtDll (Join-Path $env:ONNX_ROOT 'bin\onnxruntime.dll') -WheelDir (Get-OrtChainWheelStore) -Destination $packageDlls
            Write-BuildLog -Context $Context -Message "Package DLL closure ($TargetArch): $(@($closure | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
            # The NSIS/WiX/ZIP installers pack the install tree, not bin\: G6 proves that tree first.
            $installProof = Join-Path ([System.IO.Path]::GetTempPath()) "accelerantgine-install-$([guid]::NewGuid().ToString('N'))"
            try {
                Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--install", $fastBuildReleaseDirFull, "--prefix", $installProof, "--config", $cfgRelease.Configuration)
                $null = Assert-ChainOrtTree -Root $installProof -OrtDirectory (Join-Path $installProof "bin")
            } finally { Remove-Item -LiteralPath $installProof -Recurse -Force -ErrorAction SilentlyContinue }
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--build", $fastBuildReleaseDirFull, "--target", "package")
        }

        # The uploaded install tree plus installers; arm64's setup .exe is NSIS's x86 stub too, which the device job installs.
        Invoke-BuildStep -Context $Context -StepName "Portable Bundle ($TargetArch)" -Critical -Script {
            # -RequireCompleteInstall: the installers pack the install tree, so a DLL the closure has to add is one they would all lack.
            $portable = New-PortableBundle -BuildDir $fastBuildReleaseDirFull -DistDir (Join-Path $Workspace "dist\windows-$packageArch") `
                -Configuration $cfgRelease.Configuration -Arch $TargetArch -RequireCompleteInstall `
                -Runner { param($File, [string[]]$Arguments) $null = Invoke-BuildExternal -Context $Context -File $File -Parameters $Arguments }
            $null = Assert-ChainOrtTree -Root $portable.Bundle -OrtDirectory (Join-Path $portable.Bundle 'bin')
            $ortLicenses = Join-Path $fastBuildReleaseDirFull 'package-dlls\licenses\onnxruntime'
            Assert-OrtWheelLicensesInPackage -Path $portable.Bundle -LicenseDirectory $ortLicenses -Format archive
            $zipFiles = @($portable.Installers | Where-Object { $_ -like '*.zip' })
            if ($zipFiles.Count -eq 0) { throw 'CPack produced no ZIP for ONNX license verification' }
            foreach ($zip in $zipFiles) {
                Assert-OrtWheelLicensesInPackage -Path (Join-Path $portable.Packages $zip) -LicenseDirectory $ortLicenses `
                    -Format archive -ArchivePrefix ([IO.Path]::GetFileNameWithoutExtension($zip))
            }
            Assert-InstallerNotice -Bundle $portable.Bundle -PackageDir $portable.Packages -Installer $portable.Installers
            Write-BuildLog -Context $Context -Message "Portable bundle $($portable.Bundle), complete as installed; packages: $($portable.Installers -join ', ')"
        }

        # Beside the product, not in it: the run job downloads both, and the hub grades this tree with the same arch gate.
        if ($StageTests) {
            Invoke-BuildStep -Context $Context -StepName "Stage Tests ($TargetArch)" -Critical -Script {
                $tests = Join-Path $Workspace "dist\windows-$packageArch-tests"
                Initialize-BuildDirectory -Path $tests -Empty
                # The fuzz suite runs in FuzzTest's unit mode (a gtest binary); the benchmarks count by exit code, kept short.
                $manifest = @(
                    @{ exe = 'commitTestSuite.exe'; kind = 'gtest' }
                    @{ exe = 'compileTestSuite.exe'; kind = 'gtest' }
                    @{ exe = 'fuzzTestSuite.exe'; kind = 'gtest' }
                    @{ exe = 'perfTestSuite.exe'; kind = 'exitcode'; args = @('--benchmark_min_time=0.05s') }
                )
                $suites = $manifest | ForEach-Object { Join-Path $fastBuildReleaseDirFull $_.exe }
                $missing = @($suites | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
                if ($missing.Count) { throw "The Release build made no $($missing -join ', '); KATAGLYPHIS_RELEASE_TESTS did not take" }
                Copy-Item -LiteralPath $suites -Destination $tests
                # The build's own bin first, so a suite that imports the engine gets this build's AccelerANTgine.dll.
                $search = @(Join-Path $fastBuildReleaseDirFull 'bin') + @(Get-ProductDllSearchPath -Arch $TargetArch)
                $closure = @(Copy-PeImportClosure -Path $suites -SearchDirectory $search -Destination $tests -Arch $TargetArch)
                $closure += @(Copy-ChainGenaiBeside -Destination $tests)
                # The suites look for the configure-time GenAI test model beside themselves once its build path is gone.
                Copy-Item -LiteralPath (Join-Path $fastBuildReleaseDirFull 'test-models') -Destination $tests -Recurse -Force
                # GStreamer looks for plugins in <flat dir>\lib\gstreamer-1.0; their own imports join the closure beside the suites.
                Copy-ImageGStreamerTestPlugins -Context $Context -BuildRoot $tests
                $plugins = @(Get-ChildItem -LiteralPath (Join-Path $tests 'lib\gstreamer-1.0') -Filter '*.dll' -File | ForEach-Object FullName)
                if ($plugins.Count) {
                    $closure += @(Copy-PeImportClosure -Path $plugins -SearchDirectory $search -Destination $tests -Arch $TargetArch)
                }
                # The Debug (ASan) suite cannot run in the container on a cross build; it rides along, runtime DLLs beside it.
                if ($isCross -and $doClang) {
                    $debugSuite = Join-Path $fastBuildClangFull 'commitTestSuite.exe'
                    if (-not (Test-Path -LiteralPath $debugSuite -PathType Leaf)) { throw "The Debug build made no $debugSuite" }
                    Copy-Item -LiteralPath $debugSuite -Destination (Join-Path $tests 'commitTestSuite-debug.exe')
                    $manifest += @{ exe = 'commitTestSuite-debug.exe'; kind = 'gtest' }
                    & (Join-Path $Workspace 'third_party\ANTfrastructure\windows\scripts\build\Copy-Arm64VsRuntime.ps1') -InstallDir $tests -Flat
                }
                Copy-Item -LiteralPath (Join-Path $Workspace 'third_party\ANTfrastructure\windows\scripts\build\Invoke-StagedTests.ps1') -Destination $tests
                ConvertTo-Json -InputObject $manifest -Depth 3 |
                    Set-Content -LiteralPath (Join-Path $tests 'tests.json') -Encoding utf8
                Write-BuildLog -Context $Context -Message "Staged $($suites.Count) suite(s) in $tests with $($closure.Count) closure DLL(s): $(@($closure | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
            }
        }

        # Sync Release Artifacts
        Invoke-BuildStep -Context $Context -StepName "Sync ClangCL Release Artifacts" -Script {
            Sync-BuildArtifacts -Context $Context -Source $fastBuildReleaseDirFull -Destination (Join-Path $Workspace $releaseBuildDir) -ExcludeCommonRustAndCppCache
        }

        # A selected MSIX must fail when its inputs are unavailable.
        if (-not $SkipMSIX) {
            Invoke-BuildStep -Context $Context -StepName "MSIX Packaging" -Critical -Script {
                $msixWorkspace = Join-Path $Workspace "packaging\msix"
                $msixTemplate = Join-Path $msixWorkspace "AppxManifest.template.xml"
                $msixOutput = Join-Path $Workspace "dist\windows-$packageArch\msix"
                # Intermediates stay in the build tree: dist\windows-<arch> is uploaded whole, so it holds products only.
                $msixWork = Join-Path $fastBuildReleaseDirFull "msix"
                $stagingRoot = Join-Path $msixWork "staging"

                $logoSource = Join-Path $Workspace "images\logo.png"

                $makeappx = Resolve-WindowsSdkToolPath -ToolName "makeappx.exe"
                if (-not $makeappx) {
                    throw 'makeappx.exe is required for MSIX packaging'
                }

                if (-not (Test-Path -LiteralPath $msixTemplate -PathType Leaf)) {
                    throw "MSIX manifest template not found: $msixTemplate"
                }

                if (-not (Test-Path -LiteralPath $logoSource -PathType Leaf)) {
                    throw "MSIX project logo not found: $logoSource"
                }

                # Invoke-MsixPackage never clears the staging tree, so the extra assets placed here survive.
                if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force }
                $stagingAssets = Join-Path $stagingRoot "Assets"
                New-Item -ItemType Directory -Path $stagingAssets -Force | Out-Null
                foreach ($extraAsset in @("SmallTile.png", "LargeTile.png", "SplashScreen.png")) {
                    Copy-Item $logoSource -Destination (Join-Path $stagingAssets $extraAsset) -Force
                }

                $packageVersion = Get-PackageVersion -WorkspacePath $Workspace
                New-Item -ItemType Directory -Path $msixOutput -Force | Out-Null
                $msixFile = Join-Path $msixOutput "AccelerANTgine_${packageVersion}_${packageArch}.msix"

                # The bundle's bin\ whole: without the chain ORT a client loads System32's Windows ML copy.
                $payloadDir = Join-Path $msixWork "payload"
                if (Test-Path $payloadDir) { Remove-Item $payloadDir -Recurse -Force }
                New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
                $bundleBin = Join-Path $Workspace "dist\windows-$packageArch\bundle\bin"
                Copy-Item -LiteralPath @(Get-ChildItem -LiteralPath $bundleBin -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object FullName) -Destination $payloadDir
                $null = Assert-ChainOrtTree -Root $payloadDir
                $payloadExtra = @(Get-ChildItem -LiteralPath $payloadDir -Filter '*.dll' -File | ForEach-Object FullName)
                $licenseSource = Join-Path $Workspace 'LICENSE'
                $payloadExtra += Copy-PackageLicense -Path $licenseSource -Destination $payloadDir
                $ortLicenses = Copy-OrtWheelLicenses -OrtDll (Join-Path $payloadDir 'onnxruntime.dll') -WheelDir (Get-OrtChainWheelStore) -Destination $payloadDir
                # The payload is the bundle's bin\, so the bundle's notices describe it.
                $bundleLicenses = Join-Path $Workspace "dist\windows-$packageArch\bundle\licenses"
                $bundleNotices = Join-Path $bundleLicenses 'THIRD-PARTY-NOTICES.txt'
                Copy-Item -LiteralPath @('THIRD-PARTY-NOTICES.txt', 'third-party-inventory.json', 'third-party' | ForEach-Object { Join-Path $bundleLicenses $_ }) `
                    -Destination (Join-Path $payloadDir 'licenses') -Recurse -Force -ErrorAction Stop
                $payloadExtra += Join-Path $payloadDir 'licenses'

                Write-BuildLog -Context $Context -Message "Creating MSIX package (version $packageVersion)..."
                Invoke-MsixPackage -Context $Context `
                    -StagingDir $stagingRoot `
                    -ManifestTemplatePath $msixTemplate `
                    -TokenMap @{
                        '__PACKAGE_NAME__'           = 'AccelerANTgine'
                        '__PUBLISHER__'              = 'CN=Kataglyphis'
                        '__VERSION__'                = $packageVersion
                        '__ARCH__'                   = $packageArch
                        '__DISPLAY_NAME__'           = 'Kataglyphis C++ Inference'
                        '__PUBLISHER_DISPLAY_NAME__' = 'Kataglyphis'
                        '__DESCRIPTION__'            = 'High-performance C++ inference engine with ONNXRuntime and WebRTC streaming'
                        '__EXECUTABLE__'             = 'AccelerANTgine.exe'
                    } `
                    -OutputPath $msixFile `
                    -ExePath (Join-Path $payloadDir 'AccelerANTgine.exe') `
                    -ExtraFiles $payloadExtra `
                    -LogoPath $logoSource `
                    -MakeAppxPath $makeappx `
                    -Sign -SigningRoot $Workspace | Out-Null

                $licenseVerifier = Join-Path $Workspace 'third_party\ANTfrastructure\linux\scripts\verify_package_license.py'
                Invoke-BuildExternal -Context $Context -File 'python' -Parameters @($licenseVerifier, $msixFile, '--require', "LICENSE=$licenseSource") | Out-Null
                Assert-OrtWheelLicensesInPackage -Path $msixFile -LicenseDirectory $ortLicenses -Format archive
                Assert-PackageLicense -Path $msixFile -Pattern 'licenses/THIRD-PARTY-NOTICES.txt' -LicensePath $bundleNotices

                Write-BuildLog -Context $Context -Message "MSIX package created: $msixFile"
            }
        }
    }

} catch {
    # An error outside every step is in no step's failure list, so record it for the exit code.
    $unhandledError = $true
    Write-BuildLogError -Context $Context -Message "Unhandled critical error: $($_.Exception.Message)"
} finally {
    Write-BuildSummary -Context $Context
    Close-BuildLog -Context $Context
    
    if ($unhandledError -or $Context.Results.Failed.Count -gt 0) {
        exit 1
    }
}
