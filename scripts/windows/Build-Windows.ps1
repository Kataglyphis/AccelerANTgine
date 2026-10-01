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
    # Release also builds the commit/compile suites and stages them in dist\windows-<arch>-tests for the arm64 run job.
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
# Cross arguments, package arch and the DLL closure; an older hub pin lacks Get-ProductDllSearchPath.
try {
    Import-BuildModule @('WindowsCrossBundle.Common')
    $null = Get-Command -Name 'Get-ProductDllSearchPath' -ErrorAction Stop
} catch {
    throw "This build needs ANTfrastructure's WindowsCrossBundle.Common with Get-ProductDllSearchPath (hub commit of 2026-09-25, third_party/ANTfrastructure/docs/windows-cross-builds.md); move third_party/ANTfrastructure to it or later. ($($_.Exception.Message))"
}
$TargetArch = Get-WindowsTargetArch -Arch $TargetArch
$isCross = Test-WindowsCrossTarget -Arch $TargetArch
$packageArch = Get-WindowsPackageArch -Arch $TargetArch
# Before the log opens, so a refusal exits non-zero; Debug needs an aarch64 ASan runtime, Profile runs on the host, MSVC pins x64.
$requestedTargets = @($BuildTargets -join ',' -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$notCross = @($requestedTargets | Where-Object { $_ -ne 'clangcl-release' })
if ($isCross -and $notCross.Count -gt 0) {
    throw "-TargetArch $TargetArch builds clangcl-release only, not $($notCross -join ', ') (third_party/ANTfrastructure/docs/windows-cross-builds.md)."
}
# The G6 proof of every staged bin\, install tree and payload; an older hub pin lacks it.
try { Import-BuildModule @('WindowsOrtPayload.Common') } catch {
    throw "This build needs ANTfrastructure's WindowsOrtPayload.Common (hub commit ad08bc30 of 2026-09-25, third_party/ANTfrastructure/docs/onnxruntime-single-source.md § The shared Windows glue); move third_party/ANTfrastructure to it or later. ($($_.Exception.Message))"
}

# The build table: a preset rename is a data edit, and every row carries its own environment override.
$configPathResolved = Get-OrDefault $ConfigPath (Join-Path $PSScriptRoot 'Build-Windows.config.psd1')
if (-not (Test-Path $configPathResolved)) {
    throw "Build config not found: $configPathResolved"
}
$BuildConfig = Import-PowerShellDataFile -Path $configPathResolved

function Get-EnvironmentVariableValue {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $item = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    if ($null -ne $item) { return $item.Value }
    return $null
}

function Get-BuildConfiguration {
    param([Parameter(Mandatory)][string]$Name)

    $row = Get-ConfigValue -Config $BuildConfig -Path "Build.Configurations.$Name"
    if ($null -eq $row) {
        throw "Unknown build configuration '$Name' in $configPathResolved."
    }

    return [pscustomobject]@{
        Name          = $Name
        BuildDir      = (Get-OrDefault (Get-EnvironmentVariableValue -Name $row['BuildDirEnv']) $row['BuildDir'])
        Preset        = (Get-OrDefault (Get-EnvironmentVariableValue -Name $row['PresetEnv']) $row['Preset'])
        Configuration = $row['Configuration']
    }
}

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

# Copy-MediaRuntimeBundle misses the image's C:\runtime\bin; ORT-family DLLs stay the chain staging's alone.
function Copy-ImageGStreamerRuntime {
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$Destination
    )
    $gstBin = if ($env:GSTREAMER_BIN) { $env:GSTREAMER_BIN } else { 'C:\runtime\bin' }
    if (-not (Test-Path -LiteralPath $gstBin -PathType Container)) {
        Write-BuildLogWarning -Context $Context -Message "GStreamer bin not found ($gstBin); host runs of this tree lack GStreamer."
        return
    }
    $dlls = @(Get-ChildItem -LiteralPath $gstBin -Filter '*.dll' -File |
        Where-Object { $_.Name -notlike 'onnxruntime*' -and $_.Name -ne 'DirectML.dll' })
    foreach ($dll in $dlls) { Copy-Item -LiteralPath $dll.FullName -Destination $Destination -Force }
    Write-BuildLog -Context $Context -Message "Image GStreamer runtime: $($dlls.Count) DLL(s) from $gstBin (ORT family excluded) -> $Destination"
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

    # Fast Local Cache Initialization (Outside mounted dir)
    $fastLocalCache = Initialize-BuildCacheEnvironment -Context $Context -FastBuildDir $FastBuildDir
    
    # The --config value also decides whether Invoke-CmakeConfigureAndBuild stages the sanitizer runtime.
    $cfgMsvc = Get-BuildConfiguration -Name 'msvc-debug'
    $cfgClang = Get-BuildConfiguration -Name 'clangcl-debug'
    $cfgProfile = Get-BuildConfiguration -Name 'clangcl-profile'
    $cfgRelease = Get-BuildConfiguration -Name 'clangcl-release'

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
        $cmakeFormatRequirements = Join-Path $Workspace 'third_party\ANTfrastructure\linux\scripts\cmake-format.requirements.txt'
        Invoke-BuildStep -Context $Context -StepName "Python tooling + cmake-format" -Critical -Script {
            Invoke-CmakeFormatStep -Context $Context -WorkspacePath $Workspace `
                -RequirementsPath $cmakeFormatRequirements `
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
                    -ConfigureExtraArgs @('-Dmyproject_ENABLE_CPPCHECK=OFF', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON')
            } finally { Pop-Location }

            # $null =: the returned DLL count would otherwise land in the step's output stream.
            $null = Copy-MediaRuntimeBundle -Context $Context -TargetDir (Join-Path $fastBuildClangFull "bin")
            Copy-ImageGStreamerRuntime -Context $Context -Destination (Join-Path $fastBuildClangFull "bin")
            $null = Assert-ChainOrtTree -Root (Join-Path $fastBuildClangFull "bin")
            Copy-AppLocalVcRuntime -Context $Context -Destination @((Join-Path $fastBuildClangFull "bin"), $fastBuildClangFull)
        }

        Invoke-BuildStep -Context $Context -StepName "ClangCL Debug Tests" -Script {
            Invoke-CtestDiscoveredTests -Context $Context `
                -BuildRoot $fastBuildClangFull `
                -Configuration $cfgClang.Configuration `
                -RuntimeFlavor Clang
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
                        Write-BuildLog -Context $Context -Message "clang-tidy: the compiler's own, $ownTidy"
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
            Sync-BuildArtifacts -Context $Context -Source $fastBuildClangFull -Destination (Join-Path $Workspace $cfgClang.BuildDir) -ExcludeCommonRustAndCppCache
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

            # $null =: the returned DLL count would otherwise land in the step's output stream.
            $null = Copy-MediaRuntimeBundle -Context $Context -TargetDir (Join-Path $fastBuildProfileFull "bin")
            Copy-ImageGStreamerRuntime -Context $Context -Destination (Join-Path $fastBuildProfileFull "bin")
            $null = Assert-ChainOrtTree -Root (Join-Path $fastBuildProfileFull "bin")
            Copy-AppLocalVcRuntime -Context $Context -Destination @((Join-Path $fastBuildProfileFull "bin"), $fastBuildProfileFull)
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

            # $null =: the returned DLL count would otherwise land in the step's output stream.
            $null = Copy-MediaRuntimeBundle -Context $Context -TargetDir (Join-Path $fastBuildReleaseDirFull "bin")
            Copy-ImageGStreamerRuntime -Context $Context -Destination (Join-Path $fastBuildReleaseDirFull "bin")
            $null = Assert-ChainOrtTree -Root (Join-Path $fastBuildReleaseDirFull "bin")
            Copy-AppLocalVcRuntime -Context $Context -Destination @((Join-Path $fastBuildReleaseDirFull "bin"), $fastBuildReleaseDirFull)
            # Everything the engine imports transitively that a clean machine lacks.
            New-Item -ItemType Directory -Force -Path $packageDlls | Out-Null
            $engine = @('AccelerANTgine.exe', 'AccelerANTgine.dll') | ForEach-Object { Join-Path $fastBuildReleaseDirFull "bin\$_" }
            $closure = @(Copy-PeImportClosure -Path $engine -SearchDirectory @(Get-ProductDllSearchPath -Arch $TargetArch) -Destination $packageDlls -Arch $TargetArch)
            Write-BuildLog -Context $Context -Message "Package DLL closure ($TargetArch): $(@($closure | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
            # The NSIS/WiX/ZIP installers pack the install tree, not bin\: G6 proves that tree first.
            $installProof = Join-Path ([System.IO.Path]::GetTempPath()) "accelerantgine-install-$([guid]::NewGuid().ToString('N'))"
            try {
                Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--install", $fastBuildReleaseDirFull, "--prefix", $installProof, "--config", $cfgRelease.Configuration)
                $null = Assert-ChainOrtTree -Root $installProof -OrtDirectory (Join-Path $installProof "bin")
            } finally { Remove-Item -LiteralPath $installProof -Recurse -Force -ErrorAction SilentlyContinue }
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--build", $fastBuildReleaseDirFull, "--target", "package")
        }

        # The uploaded install tree plus installers; NSIS's stub is x86, which the arm64 arch gate refuses.
        Invoke-BuildStep -Context $Context -StepName "Portable Bundle ($TargetArch)" -Critical -Script {
            $distArch = Join-Path $Workspace "dist\windows-$packageArch"
            $bundle = Join-Path $distArch 'bundle'
            if (Test-Path $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--install", $fastBuildReleaseDirFull, "--prefix", $bundle, "--config", $cfgRelease.Configuration)
            $bundleBin = Join-Path $bundle 'bin'
            $installed = @(Get-ChildItem -LiteralPath $bundleBin -File | ForEach-Object Name)
            $seeds = @(Get-ChildItem -LiteralPath $bundleBin -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object FullName)
            # The installers pack this tree, so a DLL this has to add is one they would all lack.
            $added = @(Copy-PeImportClosure -Path $seeds -SearchDirectory @(Get-ProductDllSearchPath -Arch $TargetArch) -Destination $bundleBin -Arch $TargetArch |
                ForEach-Object { Split-Path $_ -Leaf } | Where-Object { $_ -notin $installed })
            if ($added.Count) {
                throw "The install tree lacks $($added -join ', '), which its binaries import, so every installer would ship without it: seed the package DLL closure with the binary that imports it."
            }
            $null = Assert-ChainOrtTree -Root $bundle -OrtDirectory $bundleBin
            $packages = Join-Path $distArch 'packages'
            if (Test-Path $packages) { Remove-Item -LiteralPath $packages -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $packages | Out-Null
            $installers = @(Get-ChildItem -LiteralPath $fastBuildReleaseDirFull -File | Where-Object { $_.Extension -in '.msi', '.zip' })
            if (-not $isCross) {
                # NSIS names its installer like the MSI; the build root's other .exe files are tests.
                $installers += @($installers | ForEach-Object { Join-Path $fastBuildReleaseDirFull "$($_.BaseName).exe" } |
                        Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Get-Item)
            }
            $installers | Copy-Item -Destination $packages
            Write-BuildLog -Context $Context -Message "Portable bundle $bundle; the install tree carries its whole DLL closure ($($installed.Count) file(s) in bin)"
        }

        # Beside the product, not in it: the run job downloads both, and the hub grades this tree with the same arch gate.
        if ($StageTests) {
            Invoke-BuildStep -Context $Context -StepName "Stage Tests ($TargetArch)" -Critical -Script {
                $tests = Join-Path $Workspace "dist\windows-$packageArch-tests"
                if (Test-Path $tests) { Remove-Item -LiteralPath $tests -Recurse -Force }
                New-Item -ItemType Directory -Force -Path $tests | Out-Null
                $suites = @('commitTestSuite.exe', 'compileTestSuite.exe') | ForEach-Object { Join-Path $fastBuildReleaseDirFull $_ }
                $missing = @($suites | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
                if ($missing.Count) { throw "The Release build made no $($missing -join ', '); KATAGLYPHIS_RELEASE_TESTS did not take" }
                Copy-Item -LiteralPath $suites -Destination $tests
                # The build's own bin first, so a suite that imports the engine gets this build's AccelerANTgine.dll.
                $search = @(Join-Path $fastBuildReleaseDirFull 'bin') + @(Get-ProductDllSearchPath -Arch $TargetArch)
                $closure = @(Copy-PeImportClosure -Path $suites -SearchDirectory $search -Destination $tests -Arch $TargetArch)
                Copy-Item -LiteralPath (Join-Path $Workspace 'third_party\ANTfrastructure\windows\scripts\build\Invoke-StagedTests.ps1') -Destination $tests
                ConvertTo-Json -InputObject @($suites | ForEach-Object { @{ exe = (Split-Path $_ -Leaf); kind = 'gtest' } }) |
                    Set-Content -LiteralPath (Join-Path $tests 'tests.json') -Encoding utf8
                Write-BuildLog -Context $Context -Message "Staged $($suites.Count) suite(s) in $tests with $($closure.Count) closure DLL(s): $(@($closure | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')"
            }
        }

        # Sync Release Artifacts
        Invoke-BuildStep -Context $Context -StepName "Sync ClangCL Release Artifacts" -Script {
            Sync-BuildArtifacts -Context $Context -Source $fastBuildReleaseDirFull -Destination (Join-Path $Workspace $releaseBuildDir) -ExcludeCommonRustAndCppCache
        }

        # MSIX: staging is this repo's, the rest the hub's; a box without the SDK only warns (dev box, not a broken lane).
        if (-not $SkipMSIX) {
            Invoke-BuildStep -Context $Context -StepName "MSIX Packaging" -Script {
                $msixWorkspace = Join-Path $Workspace "packaging\msix"
                $msixTemplate = Join-Path $msixWorkspace "AppxManifest.template.xml"
                $msixOutput = Join-Path $Workspace "dist\windows-$packageArch\msix"
                # Intermediates stay in the build tree: dist\windows-<arch> is uploaded whole, so it holds products only.
                $msixWork = Join-Path $fastBuildReleaseDirFull "msix"
                $stagingRoot = Join-Path $msixWork "staging"

                $logoSource = Join-Path $Workspace "images\logo.png"

                $makeappx = Resolve-WindowsSdkToolPath -ToolName "makeappx.exe"
                if (-not $makeappx) {
                    Write-BuildLogWarning -Context $Context -Message "makeappx.exe not found. Skipping MSIX packaging."
                    return
                }

                if (-not (Test-Path $msixTemplate)) {
                    Write-BuildLogWarning -Context $Context -Message "MSIX manifest template not found: $msixTemplate. Skipping."
                    return
                }

                if (-not (Test-Path $logoSource)) {
                    Write-BuildLogWarning -Context $Context -Message "Logo not found: $logoSource. Skipping MSIX."
                    return
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
