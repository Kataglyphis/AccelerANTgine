#requires -Version 7.0

<#
.SYNOPSIS
  Configurable Windows container build script for the Kataglyphis project using the ANTfrastructure build framework.

.DESCRIPTION
  Run with defaults or pass parameters to override workspace path and other options.
  Accepts a -BuildTargets array to selectively build specific targets (e.g. clangcl-debug, clangcl-profile, clangcl-release).
  Builds are executed outside the mounted workspace for performance, and artifacts are synced back upon completion.
#>

param(
    [string]$WorkspaceDir = $PWD.Path,
    [string[]]$BuildTargets = @("clangcl-debug", "clangcl-profile", "clangcl-release"),
    # Build directories, presets and their `cmake --build --config` values are
    # NOT parameters any more: they are rows in Build-Windows.config.psd1, read
    # through ANTfrastructure's WindowsConfig.Common. Retarget one row with its
    # BuildDirEnv/PresetEnv environment variable, or point -ConfigPath at a
    # different table. FastBuildDir and LogDir keep their parameters but take
    # their defaults from that same file, so there is one place to look.
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
    [switch]$StopOnError
)

$ErrorActionPreference = if ($ContinueOnError) { "Continue" } else { "Stop" }

# ANTfrastructure build framework, resolved through the shared bootstrap (a
# verbatim copy of ANTfrastructure's shared/windows/templates/Resolve-BuildModule.ps1)
# rather than a hard-coded submodule path: a module that moves upstream is
# picked up without editing this script, and a missing submodule reports the
# exact `git submodule update` command instead of a bare path.
#
# WindowsLogging.Common is deliberately NOT listed any more: upstream folded it
# into WindowsBuild.Common (b391a1d), which exports the Write-BuildLog*
# wrappers this script actually uses. Importing it by name has been a hard
# failure against any recent ANTfrastructure.
. (Join-Path $PSScriptRoot 'Resolve-BuildModule.ps1')

# Dependency order: Shared, then Build, then what builds on them.
#
# Nested imports inside a .psm1 are MODULE-PRIVATE, so every module this script
# calls into must be named here explicitly - WindowsCMake.Common importing
# WindowsBuild.Common does not put Write-BuildLog in this scope.
#
# WindowsToolchain.Common, WindowsTesting.Common, WindowsClang.Common and
# WindowsConfig.Common are the four whose jobs this script used to hand-roll:
# toolchain probing, ctest/manual-test execution with the ASan runtime
# reachable, clang-tidy over a compile-commands database, and the build table
# reader. BeschleunigerBallett has imported the same set for months.
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
)

# ---------------------------------------------------------------------------
# The build table. Import-PowerShellDataFile plus Get-ConfigValue/Get-OrDefault
# (WindowsConfig.Common) rather than five script parameters with literal
# defaults: a preset rename becomes a data edit, and every row carries its own
# environment override, so a CI lane retargets one configuration without anyone
# adding a parameter for it.
# ---------------------------------------------------------------------------
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

try {
    Write-BuildLog -Context $Context -Message "=== Kataglyphis Container Build Script ==="
    Write-BuildLog -Context $Context -Message "Workspace:          $Workspace"
    Write-BuildLog -Context $Context -Message "FastBuildDir:       $FastBuildDir"
    Write-BuildLog -Context $Context -Message "BuildTargets:       $($BuildTargets -join ', ')"
    Write-BuildLog -Context $Context -Message "BuildConfig:        $configPathResolved"
    Write-BuildLog -Context $Context -Message "LLVMBinPath:        $LLVMBinPath"
    Write-BuildLog -Context $Context -Message ("=" * 60)

    Set-Location -Path $Workspace

    # Fast Local Cache Initialization (Outside mounted dir)
    $fastLocalCache = Initialize-BuildCacheEnvironment -Context $Context -FastBuildDir $FastBuildDir
    
    # One row per lane: build directory, preset and the --config value that also
    # decides whether Invoke-CmakeConfigureAndBuild stages the sanitizer runtime.
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
    $fastBuildReleaseDirFull = Join-Path $fastLocalCache $cfgRelease.BuildDir

    $BuildTargets = $BuildTargets -join ',' -split ',' | ForEach-Object { $_.Trim() }

    # Define targets
    $doMsvc    = -not $SkipMSVC -and ($BuildTargets -contains "msvc-debug")
    $doClang   = $BuildTargets -contains "clangcl-debug"
    $doProfile = $BuildTargets -contains "clangcl-profile"
    $doRelease = $BuildTargets -contains "clangcl-release"

    # Get-LLVMRuntimePaths used to live here. It is gone, and nothing replaced it
    # locally: the ASan runtime is found by WindowsTesting.Common
    # (Get-AsanRuntimeDirs, which knows about Microsoft's runtime as well as
    # LLVM's) and staged by WindowsCMake.Common's Invoke-CmakeConfigureAndBuild
    # for any -Configuration Debug. Both its callers - the hand DLL copy after the
    # ClangCL debug build and the PATH juggling around ctest - are gone with it.

    # Add-ExistingDirectory, Get-RuntimeDependencyDirectories and
    # Copy-RuntimeDependencies used to live here, under a comment saying the pair
    # stayed "under the two-consumer rule". The rule is met, so they are
    # WindowsMediaRuntime.Common's Get-MediaRuntimeDirectory and
    # Copy-MediaRuntimeBundle now (ANTfrastructure f92f10ef) - a module whose
    # signature was taken from the three call sites below, which is why they
    # collapse to one exported call each.
    #
    # ONE BEHAVIOUR DIFFERENCE, and it is the one this lane wants: the recursive
    # NuGet probe is pinned to the TARGET runtime identifier rather than the
    # literal 'win-x64' the local copy hard-coded, so a foreign-rid payload
    # cannot be staged next to the exe. Nothing moves today - every preset in
    # Build-Windows.config.psd1 is x64-*, and Get-WindowsRuntimeIdentifier
    # resolves amd64 -> win-x64 unless WINDOWS_TARGET_ARCH says otherwise - so
    # the probe matches exactly what it matched before on this lane, and starts
    # being correct rather than lucky if the lane is ever pointed at arm64.
    #
    # The empty-payload guard the local comment was written for is upstream too,
    # and pinned by its suite: the resolver returns an empty ARRAY, not $null.
    # --- Step 1: Environment Setup ---
    Invoke-BuildStep -Context $Context -StepName "Environment Setup" -Critical -Script {
        $finalPath = $LLVMBinPath
        if (-not (Test-Path $finalPath)) {
            $clangCl = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
            if ($clangCl) { $finalPath = Split-Path -Parent $clangCl.Source }
        }
        # Add-DirectoriesToPath (WindowsScripts.Shared) prepends, de-duplicates and
        # skips a directory that does not exist - the three things the two
        # hand-written blocks here did between them. Add-DirectoryToPath, which the
        # audit item named, is its unexported internal helper; the plural is the
        # exported surface.
        Add-DirectoriesToPath @(
            $finalPath
            (Join-Path $env:USERPROFILE 'scoop\shims')
        )
        Write-BuildLog -Context $Context -Message "PATH front: $finalPath and the Scoop shims (when present)"
    }

    # --- Step 2: Environment Check ---
    # Invoke-ToolchainChecks (WindowsToolchain.Common) runs each probe, warns on
    # the ones that fail and collects the names - the same "report, do not abort"
    # behaviour the two -IgnoreExitCode calls had, minus the hand-rolling. Pass
    # -RequiredTools/-FailOnMissingRequiredTools here the day a missing tool
    # should stop the run.
    Invoke-BuildStep -Context $Context -StepName "Environment Check" -Script {
        Invoke-ToolchainChecks -Context $Context -ToolArguments @{
            clang = @('--version')
            cmake = @('--version')
        }
    }

    # --- Step 3: cmake-format ---
    # Mirrors the Linux lane's cmake-format gate. Upstream Invoke-CmakeFormatStep
    # creates/heals the uv venv itself and installs the requirements it is
    # pointed at, so no separate venv step is needed; it throws when uv or
    # cmake-format is missing.
    #
    # BOTH PARAMETERS BELOW ARE NEW IN 19286e9f, and each closes a gap against
    # the Linux lane rather than adding a preference:
    #
    #   -RequirementsPath  without it the step installs this repo's WHOLE
    #                      requirements.txt - sphinx, sphinx-book-theme,
    #                      myst-parser, breathe, exhale, pre-commit - to obtain
    #                      one formatter, and takes cmake-format unpinned, so a
    #                      floating release could move a verdict with no commit
    #                      to blame. The hub's cmake-format.requirements.txt is
    #                      the pinned pair (cmake-format==0.6.13, pyyaml==6.0.3)
    #                      that run-static-analysis-format.sh installs since the
    #                      library gained its venv default, so the two lanes now
    #                      format with the SAME cmake-format.
    #
    #   -ExcludePattern    the module's built-in excludes cover build*/,
    #                      third_party/, _deps/ and vcpkg_installed/ but not
    #                      .venv/, which the Linux side has always listed
    #                      (CODE_QUALITY_CMAKE_EXCLUDE_PATHS). It bites only on
    #                      the filesystem fallback - git ls-files never lists an
    #                      untracked venv - which is exactly the dev box, where
    #                      the venv the step itself just created holds cmake
    #                      files it would then reformat.
    #
    # -Check is deliberately NOT passed. This repo's Linux gate also formats in
    # place (run_gate cmake-format -> code_quality_run_cmake_format with no
    # --check), and turning a build driver into a gate that fails on unformatted
    # input is a policy change, not an adoption.
    if (-not $SkipFormat) {
        $cmakeFormatRequirements = Join-Path $Workspace 'third_party\ANTfrastructure\linux\scripts\cmake-format.requirements.txt'
        Invoke-BuildStep -Context $Context -StepName "Python tooling + cmake-format" -Critical -Script {
            Invoke-CmakeFormatStep -Context $Context -WorkspacePath $Workspace `
                -RequirementsPath $cmakeFormatRequirements `
                -ExcludePattern @('\\\.venv\\')
        }

        # The other half of the Linux lane's format gate, which this script had
        # never run: Invoke-ClangFormatStep formats every source
        # Get-ProjectCppFiles finds against .clang-format, in place. It throws when
        # clang-format is missing, and -SkipFormat opts out of both steps.
        Invoke-BuildStep -Context $Context -StepName "clang-format" -Critical -Script {
            Invoke-ClangFormatStep -Context $Context -WorkspacePath $Workspace
        }
    }

    # --- MSVC Debug Build ---
    if ($doMsvc) {
        Invoke-BuildStep -Context $Context -StepName "MSVC Debug Build" -Script {
            # Invoke-CmakeConfigureAndBuild builds `-B <path> --preset <name>` with
            # NO -S, so the preset's own sourceDir applies and cwd has to be the
            # workspace - hence Push-Location. It also picks the job count, wires
            # sccache and streams the build output line by line.
            Push-Location $Workspace
            try {
                Invoke-CmakeConfigureAndBuild -Context $Context `
                    -BuildPath $fastBuildMsvcFull `
                    -Preset $cfgMsvc.Preset `
                    -Configuration $cfgMsvc.Configuration
            } finally { Pop-Location }

            # --test-dir, so no Push-Location; -RuntimeFlavor Msvc because this lane
            # links Microsoft's ASan runtime, not LLVM's, and the two are not
            # interchangeable.
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
            # -Configuration Debug is load-bearing, not cosmetic: it is the switch
            # Invoke-CmakeConfigureAndBuild reads to stage the sanitizer runtime DLLs
            # into the build root and its bin\ before and after the build. That is
            # what the hand-written clang_rt.asan_dynamic-x86_64.dll copy that used to
            # sit here did, only it looked in LLVM's tree alone.
            Push-Location $Workspace
            try {
                Invoke-CmakeConfigureAndBuild -Context $Context `
                    -BuildPath $fastBuildClangFull `
                    -Preset $cfgClang.Preset `
                    -Configuration $cfgClang.Configuration `
                    -ConfigureExtraArgs @('-Dmyproject_ENABLE_CPPCHECK=OFF', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON')
            } finally { Pop-Location }

            # $null = : the hub function RETURNS the staged DLL count so a caller
            # can gate on it. This lane does not, and an unassigned int inside an
            # Invoke-BuildStep script block lands in that step's output stream.
            $null = Copy-MediaRuntimeBundle -Context $Context -TargetDir (Join-Path $fastBuildClangFull "bin")
        }

        # Invoke-CtestDiscoveredTests puts the ASan runtime directories on PATH for
        # the duration of the run and restores it afterwards, which is the
        # save/override/restore block this step used to spell out by hand.
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
            # Invoke-ClangTidyFixStep (WindowsClang.Common) owns the file discovery,
            # the --header-filter, and - the part that matters here - the skip for
            # any translation unit that imports a C++20 named module, which
            # clang-tidy cannot analyse without the BMIs the compile-commands
            # database does not carry.
            #
            # -Extension carries this project's module extensions on TOP of the
            # module default (.cpp/.cc/.cxx). Leave the check disables on -Checks
            # and NOT in .clang-tidy: that file is a SHARED config whose drift the
            # lint gate checks against ANTfrastructure's copy (AGENTS.md section 2,
            # "clang-format / clang-tidy / cmake-format and the canonical
            # configs"), so a project-local disable belongs on the command line.
            Invoke-BuildStep -Context $Context -StepName "clang-tidy Analysis" -Script {
                Invoke-ClangTidyFixStep -Context $Context `
                    -WorkspacePath $Workspace `
                    -BuildRoot $fastBuildClangFull `
                    -SourceSubdirectory 'Src' `
                    -Extension @('.cpp', '.cc', '.cxx', '.ixx', '.cppm', '.mxx') `
                    -Checks @('-checks=-readability-convert-member-functions-to-static,-readability-redundant-declaration,-misc-const-correctness,-google-explicit-constructor,-hicpp-explicit-conversions') `
                    -Fix
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

            # $null = : the hub function RETURNS the staged DLL count so a caller
            # can gate on it. This lane does not, and an unassigned int inside an
            # Invoke-BuildStep script block lands in that step's output stream.
            $null = Copy-MediaRuntimeBundle -Context $Context -TargetDir (Join-Path $fastBuildProfileFull "bin")
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
            # -CleanBuildRoot replaces the explicit Remove-BuildRoot that used to
            # stand here, and it is passed on THIS lane only. The debug and profile
            # lanes deliberately keep their trees: they live in the reusable
            # container's C:\kataglyphis_fast_build, which is the only thing making
            # a rerun incremental, and wiping them would turn every run into a
            # from-scratch build. The release lane has always started clean, because
            # a packaged artifact must not inherit anything.
            Push-Location $Workspace
            try {
                Invoke-CmakeConfigureAndBuild -Context $Context `
                    -BuildPath $fastBuildReleaseDirFull `
                    -Preset $cfgRelease.Preset `
                    -Configuration $cfgRelease.Configuration `
                    -CleanBuildRoot `
                    -ConfigureExtraArgs @('-Dmyproject_ENABLE_CPPCHECK=OFF', '-DENABLE_WIX_PACKAGING=ON')
            } finally { Pop-Location }

            # $null = : the hub function RETURNS the staged DLL count so a caller
            # can gate on it. This lane does not, and an unassigned int inside an
            # Invoke-BuildStep script block lands in that step's output stream.
            $null = Copy-MediaRuntimeBundle -Context $Context -TargetDir (Join-Path $fastBuildReleaseDirFull "bin")
            Invoke-BuildExternal -Context $Context -File "cmake" -Parameters @("--build", $fastBuildReleaseDirFull, "--target", "package")
        }
        
        # Sync Release Artifacts
        Invoke-BuildStep -Context $Context -StepName "Sync ClangCL Release Artifacts" -Script {
            Sync-BuildArtifacts -Context $Context -Source $fastBuildReleaseDirFull -Destination (Join-Path $Workspace $cfgRelease.BuildDir) -ExcludeCommonRustAndCppCache
        }

        # MSIX Packaging
        #
        # STAGING IS THE CALLER'S; EVERYTHING AFTER IT IS THE HUB'S.
        # Invoke-MsixPackage (WindowsMsix.Common, new in 19286e9f) is the
        # orchestration three consumers had each written out - lay the assets
        # out, expand the manifest template, pack, assert, optionally sign -
        # and the only part that genuinely differs between them is WHAT GOES
        # INTO the staging directory. Here that is the ClangCL release exe, its
        # dll, and the three extra assets this project's AppxManifest names
        # beyond the four the hub always writes: SmallTile, LargeTile and
        # SplashScreen, referenced from uap:DefaultTile and uap:SplashScreen.
        #
        # Two things the 65 hand-rolled lines this replaces did NOT do:
        #   * XML-ESCAPE the token values. Expand-XmlTemplateTokens runs each
        #     one through SecurityElement::Escape; the .Replace chain put
        #     __DESCRIPTION__ into an XML attribute raw, so a single ampersand
        #     in it produces a manifest makeappx rejects with a parser error.
        #   * ASSERT the output. makeappx has been seen to report success and
        #     produce no file; the step then went green and the artifact upload
        #     found nothing.
        #
        # The version literal goes with them. Get-PackageVersion reads
        # VERSION.txt / version.txt and pads to the four components an
        # AppxManifest requires (makeappx rejects three). This repo ships
        # neither file today, so it returns the same 0.0.1.0 that was typed
        # twice here - but from one place, and correctly the day a version file
        # lands.
        #
        # The three warn-and-skip preconditions stay HERE rather than becoming
        # the hub's throws. This step is not -Critical, a Windows box without
        # the SDK is a dev box rather than a broken lane, and making that red is
        # a policy change, not an adoption. -MakeAppxPath hands the tool this
        # already resolved to the hub so it is not probed a second time.
        #
        # Invoke-MsixSign is called here rather than through -Sign: the hub's
        # -Sign passes the staging directory's PARENT as the workspace, and
        # Invoke-MsixSign looks for the signing *.pfx in the workspace ROOT.
        if (-not $SkipMSIX) {
            Invoke-BuildStep -Context $Context -StepName "MSIX Packaging" -Script {
                $msixWorkspace = Join-Path $Workspace "packaging\msix"
                $msixTemplate = Join-Path $msixWorkspace "AppxManifest.template.xml"
                $msixOutput = Join-Path $Workspace "dist\msix"
                $stagingRoot = Join-Path $msixOutput "staging"

                $exePath = Join-Path $fastBuildReleaseDirFull "bin\AccelerANTgine.exe"
                $dllPath = Join-Path $fastBuildReleaseDirFull "bin\AccelerANTgine.dll"
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

                # A fresh staging tree, then the three assets the hub does not
                # know about. Invoke-MsixPackage creates both directories with
                # -Force and never clears them, so what is put here survives.
                if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force }
                $stagingAssets = Join-Path $stagingRoot "Assets"
                New-Item -ItemType Directory -Path $stagingAssets -Force | Out-Null
                foreach ($extraAsset in @("SmallTile.png", "LargeTile.png", "SplashScreen.png")) {
                    Copy-Item $logoSource -Destination (Join-Path $stagingAssets $extraAsset) -Force
                }

                $packageVersion = Get-PackageVersion -WorkspacePath $Workspace
                New-Item -ItemType Directory -Path $msixOutput -Force | Out-Null
                $msixFile = Join-Path $msixOutput "AccelerANTgine_${packageVersion}_x64.msix"

                Write-BuildLog -Context $Context -Message "Creating MSIX package (version $packageVersion)..."
                Invoke-MsixPackage -Context $Context `
                    -StagingDir $stagingRoot `
                    -ManifestTemplatePath $msixTemplate `
                    -TokenMap @{
                        '__PACKAGE_NAME__'           = 'AccelerANTgine'
                        '__PUBLISHER__'              = 'CN=Kataglyphis'
                        '__VERSION__'                = $packageVersion
                        '__DISPLAY_NAME__'           = 'Kataglyphis C++ Inference'
                        '__PUBLISHER_DISPLAY_NAME__' = 'Kataglyphis'
                        '__DESCRIPTION__'            = 'High-performance C++ inference engine with ONNXRuntime and WebRTC streaming'
                        '__EXECUTABLE__'             = 'AccelerANTgine.exe'
                    } `
                    -OutputPath $msixFile `
                    -ExePath $exePath `
                    -ExtraFiles @($dllPath) `
                    -LogoPath $logoSource `
                    -MakeAppxPath $makeappx | Out-Null

                Write-BuildLog -Context $Context -Message "MSIX package created: $msixFile"

                Invoke-MsixSign -Context $Context -WorkspacePath $Workspace -MsixOutPath $msixFile
            }
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
