<#
.SYNOPSIS
  Configurable Windows container build script for the Kataglyphis project with logging.

.DESCRIPTION
  Run with defaults or pass parameters to override workspace path and other options.
    Supports local execution and CI usage via explicit parameter passing.
  Example:
    .\container-build.ps1
    .\container-build.ps1 -WorkspaceDir "D:\dev\kataglyphis" -SkipMSVC
    .\container-build.ps1 -LogDir "build_logs" -StopOnError
#>

[CmdletBinding()]
param(
    [string] $WorkspaceDir = $PWD.Path,
    [string] $BuildDir = "",
    [string] $BuildDirRelease = "",
    [string] $BuildDirMsvc = "build-msvc-debug",
    [string] $BuildDirClang = "build-clangcl-debug",
    [string] $BuildDirProfile = "build-clangcl-profile",
    [string] $BuildDirClangRelease = "build-clangcl-release",
    [string] $ClangProfilePreset = "x64-ClangCL-Windows-Profile",
    [string] $LLVMBinPath = "C:\Program Files\LLVM\bin",
    [string] $LogDir = "logs",
    [switch] $SkipMSVC,
    [switch] $SkipClangTidy,
    [switch] $SkipStaticAnalysis,
    [switch] $SkipScanBuild,
    [switch] $SkipPGO,
    [switch] $ContinueOnError,
    [switch] $StopOnError
)

#region ==================== LOGGING INFRASTRUCTURE ====================

$script:LogWriter = $null
$script:LogPath = $null

$script:Results = @{
    Succeeded = New-Object System.Collections.Generic.List[string]
    Failed    = New-Object System.Collections.Generic.List[string]
    Skipped   = New-Object System.Collections.Generic.List[string]
    Errors    = @{}
}

function Open-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parentDir = Split-Path -Parent $Path
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    }

    $fileStream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )
    $script:LogWriter = New-Object System.IO.StreamWriter($fileStream, [System.Text.Encoding]::UTF8)
    $script:LogWriter.AutoFlush = $true
    $script:LogPath = $Path
}

function Close-Log {
    if ($script:LogWriter) {
        try {
            $script:LogWriter.Flush()
            $script:LogWriter.Dispose()
        } catch {
            # ignore
        } finally {
            $script:LogWriter = $null
        }
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-Host $Message
    if ($script:LogWriter) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $script:LogWriter.WriteLine("[$timestamp] $Message")
    }
}

function Write-LogWarning {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($Message) {
        Write-Warning $Message
        if ($script:LogWriter) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:LogWriter.WriteLine("[$timestamp] WARNING: $Message")
        }
    } else {
        Write-Host ""
        if ($script:LogWriter) {
            $script:LogWriter.WriteLine("")
        }
    }
}

function Write-LogError {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($Message) {
        Write-Host $Message -ForegroundColor Red
        if ($script:LogWriter) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:LogWriter.WriteLine("[$timestamp] ERROR: $Message")
        }
    } else {
        Write-Host ""
        if ($script:LogWriter) {
            $script:LogWriter.WriteLine("")
        }
    }
}

function Write-LogSuccess {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($Message) {
        Write-Host $Message -ForegroundColor Green
        if ($script:LogWriter) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:LogWriter.WriteLine("[$timestamp] SUCCESS: $Message")
        }
    } else {
        Write-Host ""
        if ($script:LogWriter) {
            $script:LogWriter.WriteLine("")
        }
    }
}

function Write-LogInfo {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($Message) {
        Write-Host $Message -ForegroundColor Cyan
        if ($script:LogWriter) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $script:LogWriter.WriteLine("[$timestamp] INFO: $Message")
        }
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory)]
        [string]$File,
        [string[]]$Args = @(),
        [switch]$IgnoreExitCode
    )

    $cmdLine = if ($Args -and $Args.Count) { "$File $($Args -join ' ')" } else { $File }
    Write-Log "CMD: $cmdLine"

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0
    
    try {
        & $File @Args 2>&1 | ForEach-Object {
            $line = $_
            if ($null -eq $line) { return }
            Write-Log ([string]$line)
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
            throw "Command failed with exit code ${exitCode}: $cmdLine"
        }
        return $exitCode
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)]
        [string]$StepName,
        [Parameter(Mandatory)]
        [scriptblock]$Script,
        [switch]$Critical,
        [switch]$ContinueOnStepError
    )

    Write-Log ""
    Write-Log ">>> Starting: $StepName"
    Write-Log ("=" * 60)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        & $Script
        $stopwatch.Stop()
        $script:Results.Succeeded.Add($StepName) | Out-Null
        Write-LogSuccess "<<< Completed: $StepName (Duration: $($stopwatch.Elapsed.ToString('mm\:ss\.fff')))"
        return $true
    } catch {
        $stopwatch.Stop()
        $errorMessage = $_.Exception.Message
        $script:Results.Failed.Add($StepName) | Out-Null
        $script:Results.Errors[$StepName] = $errorMessage
        Write-LogError "<<< FAILED: $StepName (Duration: $($stopwatch.Elapsed.ToString('mm\:ss\.fff')))"
        Write-LogError "    Error: $errorMessage"

        if ($_.ScriptStackTrace) {
            Write-Log "    Stack: $($_.ScriptStackTrace)"
        }

        if ($StopOnError -and $Critical) {
            throw "Critical step '$StepName' failed: $errorMessage"
        }

        if (-not $ContinueOnStepError -and -not $ContinueOnError) {
            throw "Step '$StepName' failed: $errorMessage"
        }

        return $false
    }
}

function Invoke-SoftStep {
    param(
        [Parameter(Mandatory)]
        [string]$StepName,
        [Parameter(Mandatory)]
        [scriptblock]$Script
    )

    Invoke-Step -StepName $StepName -Script $Script -ContinueOnStepError
}

function Skip-Step {
    param(
        [Parameter(Mandatory)]
        [string]$StepName,
        [string]$Reason = "Skipped by user"
    )

    Write-Log ""
    Write-LogInfo ">>> Skipping: $StepName ($Reason)"
    $script:Results.Skipped.Add($StepName) | Out-Null
}

function Write-Summary {
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "=== CONTAINER BUILD PIPELINE SUMMARY ==="
    Write-Log ("=" * 60)
    Write-Log ""

    if ($script:Results.Succeeded.Count -gt 0) {
        Write-LogSuccess "SUCCEEDED ($($script:Results.Succeeded.Count)):"
        foreach ($step in $script:Results.Succeeded) {
            Write-LogSuccess "  [OK] $step"
        }
    }

    Write-Log ""

    if ($script:Results.Skipped.Count -gt 0) {
        Write-LogInfo "SKIPPED ($($script:Results.Skipped.Count)):"
        foreach ($step in $script:Results.Skipped) {
            Write-LogInfo "  [--] $step"
        }
    }

    Write-Log ""

    if ($script:Results.Failed.Count -gt 0) {
        Write-LogError "FAILED ($($script:Results.Failed.Count)):"
        foreach ($step in $script:Results.Failed) {
            Write-LogError "  [X] $step"
            Write-LogError "      Error: $($script:Results.Errors[$step])"
        }
    }

    Write-Log ""
    $total = $script:Results.Succeeded.Count + $script:Results.Failed.Count
    $successRate = if ($total -gt 0) { [math]::Round(($script:Results.Succeeded.Count / $total) * 100, 1) } else { 0 }
    Write-Log "Total: $total steps executed, $($script:Results.Succeeded.Count) succeeded, $($script:Results.Failed.Count) failed, $($script:Results.Skipped.Count) skipped ($($successRate)% success rate)"
    Write-Log ""

    if ($script:LogPath) {
        Write-Log "Full log available at: $script:LogPath"
    }

    if ($script:Results.Failed.Count -gt 0) {
        Write-LogWarning "Pipeline completed with errors!"
    } else {
        Write-LogSuccess "Pipeline completed successfully!"
    }
}

#endregion

#region ==================== HELPER FUNCTIONS ====================

function Initialize-LLVMPath {
    param([string]$LLVMBin)

    $finalPath = $LLVMBin

    if (-not (Test-Path $finalPath)) {
        $clangCl = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
        if ($clangCl) {
            $finalPath = Split-Path -Parent $clangCl.Source
            Write-Log "LLVM bin found via clang-cl.exe: $finalPath"
        }
    }

    if (Test-Path $finalPath) {
        $env:PATH = "$finalPath;$env:PATH"
        Write-Log "Added LLVM bin to PATH: $finalPath"
        return $finalPath
    }

    Write-LogWarning "LLVM bin path not found: $LLVMBin"
    return $null
}

function Initialize-ScoopPath {
    $scoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
    if (Test-Path $scoopShims) {
        $env:PATH = "$scoopShims;$env:PATH"
        Write-Log "Added Scoop shims to PATH: $scoopShims"
        return $scoopShims
    }
    return $null
}

function Get-LLVMRuntimePaths {
    param([string]$LLVMBin)

    if (-not $LLVMBin -or -not (Test-Path $LLVMBin)) {
        return @()
    }

    $llvmRoot = Split-Path -Parent $LLVMBin
    $clangRoot = Join-Path $llvmRoot "lib\clang"
    if (-not (Test-Path $clangRoot)) {
        return @()
    }

    $runtimeDirs = Get-ChildItem -Path $clangRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName "lib\windows" } |
    Where-Object { Test-Path $_ }

    return $runtimeDirs
}

function Get-LLVMAsanRuntimeDll {
    param([string]$LLVMBin)

    $runtimeDirs = Get-LLVMRuntimePaths -LLVMBin $LLVMBin
    foreach ($runtimeDir in $runtimeDirs) {
        $candidate = Join-Path $runtimeDir "clang_rt.asan_dynamic-x86_64.dll"
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-SourceFiles {
    param(
        [string]$BasePath,
        [string[]]$Extensions = @('*.cpp', '*.cc')
    )

    if (-not (Test-Path $BasePath)) {
        Write-LogWarning "Source path does not exist: $BasePath"
        return @()
    }

    $files = Get-ChildItem -Path $BasePath -Recurse -Include $Extensions | ForEach-Object { $_.FullName }
    Write-Log "Found $($files.Count) source files in $BasePath"
    return $files
}

function Remove-BuildDirectory {
    param([string]$Path)

    if (Test-Path $Path) {
        Write-Log "Removing build directory: $Path"
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $Path) {
            Write-LogWarning "Could not fully remove: $Path"
            return $false
        }
        Write-Log "Build directory removed successfully"
    } else {
        Write-Log "Build directory does not exist: $Path"
    }
    return $true
}

function Ensure-CMakeGeneratorCompatibility {
    param(
        [Parameter(Mandatory)]
        [string]$BuildDirectory,
        [Parameter(Mandatory)]
        [string]$ExpectedGenerator
    )

    $cachePath = Join-Path $BuildDirectory "CMakeCache.txt"
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        return
    }

    $generatorEntry = Select-String -Path $cachePath -Pattern '^CMAKE_GENERATOR:INTERNAL=(.+)$' | Select-Object -First 1
    if (-not $generatorEntry) {
        return
    }

    $cachedGenerator = $generatorEntry.Matches[0].Groups[1].Value.Trim()
    if ($cachedGenerator -eq $ExpectedGenerator) {
        return
    }

    Write-LogWarning "CMake generator mismatch in '$BuildDirectory'. Cached='$cachedGenerator', Expected='$ExpectedGenerator'. Cleaning build directory."
    Remove-BuildDirectory -Path $BuildDirectory | Out-Null
}

function Resolve-OptionalPath {
    param(
        [Parameter(Mandatory)]
        [string]$BasePath,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $BasePath
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path $BasePath $Path)
}

#endregion

#region ==================== MAIN SCRIPT ====================

# Error handling preference

if ($ContinueOnError) {
    $ErrorActionPreference = "Continue"
} else {
    $ErrorActionPreference = "Stop"
}

# Resolve workspace

try {
    $Workspace = (Resolve-Path -Path $WorkspaceDir -ErrorAction Stop).Path
} catch {
    Write-Host "Workspace path doesn't exist, using current directory: $PWD"
    $Workspace = $PWD.Path
}

# Derived paths
$effectiveBuildDirMsvc = if ([string]::IsNullOrWhiteSpace($BuildDir)) { $BuildDirMsvc } else { $BuildDir }
$effectiveBuildDirClang = if ([string]::IsNullOrWhiteSpace($BuildDir)) { $BuildDirClang } else { "${BuildDir}-clangcl" }
$effectiveBuildDirProfile = if ([string]::IsNullOrWhiteSpace($BuildDirRelease)) { $BuildDirProfile } else { "${BuildDirRelease}-profile" }
$effectiveBuildDirClangRelease = if ([string]::IsNullOrWhiteSpace($BuildDirRelease)) { $BuildDirClangRelease } else { $BuildDirRelease }

$buildDirMsvcFull = Resolve-OptionalPath -BasePath $Workspace -Path $effectiveBuildDirMsvc
$buildDirClangFull = Resolve-OptionalPath -BasePath $Workspace -Path $effectiveBuildDirClang
$buildDirProfileFull = Resolve-OptionalPath -BasePath $Workspace -Path $effectiveBuildDirProfile
$buildReleaseDirFull = Resolve-OptionalPath -BasePath $Workspace -Path $effectiveBuildDirClangRelease

if ($buildDirClangFull -eq $buildDirMsvcFull) {
    $buildDirClangFull = Join-Path $Workspace ("$effectiveBuildDirMsvc-clangcl")
}
if ($buildDirProfileFull -eq $buildReleaseDirFull) {
    $buildDirProfileFull = Join-Path $Workspace ("$effectiveBuildDirClangRelease-profile")
}

$srcDir = Join-Path $Workspace "Src"

# Initialize logging

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDirPath = Resolve-OptionalPath -BasePath $Workspace -Path $LogDir
New-Item -ItemType Directory -Force $logDirPath -ErrorAction SilentlyContinue | Out-Null
$logPath = Join-Path $logDirPath "container-build-$timestamp.log"

Open-Log -Path $logPath

try {
    Write-Log "=== Kataglyphis Container Build Script ==="
    Write-Log "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "Logging to: $logPath"
    Write-Log ""
    Write-Log "=== Configuration ==="
    Write-Log "Workspace:            $Workspace"
    Write-Log "BuildDirMsvc:         $buildDirMsvcFull"
    Write-Log "BuildDirClangDebug:   $buildDirClangFull"
    Write-Log "BuildDirProfile:      $buildDirProfileFull"
    Write-Log "BuildDirRelease:      $buildReleaseDirFull"
    Write-Log "ClangProfilePreset:   $ClangProfilePreset"
    Write-Log "LLVMBinPath:          $LLVMBinPath"
    Write-Log "SkipMSVC:             $SkipMSVC"
    Write-Log "SkipClangTidy:        $SkipClangTidy"
    Write-Log "SkipStaticAnalysis:   $SkipStaticAnalysis"
    Write-Log "SkipScanBuild:        $SkipScanBuild"
    Write-Log "SkipPGO:              $SkipPGO"
    Write-Log "ContinueOnError:      $ContinueOnError"
    Write-Log "StopOnError:          $StopOnError"
    Write-Log ("=" * 60)

    # --- Step 1: Environment Setup ---
    Invoke-Step -StepName "Environment Setup" -Script {
        $script:llvmBin = Initialize-LLVMPath -LLVMBin $LLVMBinPath
        Initialize-ScoopPath | Out-Null
    }

    # --- Step 2: Environment Check ---
    Invoke-Step -StepName "Environment Check" -Script {
        Invoke-External -File "clang" -Args @("--version") -IgnoreExitCode
        Invoke-External -File "cmake" -Args @("--version") -IgnoreExitCode
    }

    # --- Step 3: MSVC Debug Build (Optional) ---
    if (-not $SkipMSVC) {
        Invoke-SoftStep -StepName "MSVC Debug Build" -Script {
            Ensure-CMakeGeneratorCompatibility -BuildDirectory $buildDirMsvcFull -ExpectedGenerator "Visual Studio 18 2026"
            Invoke-External -File "cmake" -Args @("-B", $buildDirMsvcFull, "--preset", "x64-MSVC-Windows-Debug")
            Invoke-External -File "cmake" -Args @("--build", $buildDirMsvcFull, "--config", "Debug")
            
            Push-Location $buildDirMsvcFull
            try {
                Invoke-External -File "ctest" -Args @("-C", "Debug", "--output-on-failure")
            } finally {
                Pop-Location
            }
        }
    } else {
        Skip-Step -StepName "MSVC Debug Build" -Reason "SkipMSVC flag set"
    }

    # --- Step 4: ClangCL Debug Build ---
    Invoke-Step -StepName "ClangCL Debug Build" -Critical -Script {
        Ensure-CMakeGeneratorCompatibility -BuildDirectory $buildDirClangFull -ExpectedGenerator "Ninja"
        Invoke-External -File "cmake" -Args @(
            "-B", $buildDirClangFull,
            "--preset", "x64-ClangCL-Windows-Debug",
            "-Dmyproject_ENABLE_CPPCHECK=OFF",
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
        )
        Invoke-External -File "cmake" -Args @("--build", $buildDirClangFull)

        $asanRuntime = Get-LLVMAsanRuntimeDll -LLVMBin $script:llvmBin
        if ($asanRuntime) {
            Copy-Item -Path $asanRuntime -Destination (Join-Path $buildDirClangFull "clang_rt.asan_dynamic-x86_64.dll") -Force

            $clangBinOutput = Join-Path $buildDirClangFull "bin"
            if (Test-Path $clangBinOutput) {
                Copy-Item -Path $asanRuntime -Destination (Join-Path $clangBinOutput "clang_rt.asan_dynamic-x86_64.dll") -Force
            }

            Write-Log "Copied ASan runtime DLL for tests: $asanRuntime"
        } else {
            Write-LogWarning "Could not locate clang_rt.asan_dynamic-x86_64.dll in LLVM runtime directories."
        }
    }

    # --- Step 5: ClangCL Debug Tests ---
    Invoke-Step -StepName "ClangCL Debug Tests" -Script {
        $runtimePaths = @(
            (Join-Path $buildDirClangFull "bin"),
            (Join-Path $buildDirClangFull "lib")
        )
        $runtimePaths += Get-LLVMRuntimePaths -LLVMBin $script:llvmBin
        $previousPath = $env:PATH
        $env:PATH = (($runtimePaths + @($env:PATH)) -join ';')

        Push-Location $buildDirClangFull
        try {
            Invoke-External -File "ctest" -Args @("-C", "Debug", "--output-on-failure")
        } finally {
            Pop-Location
            $env:PATH = $previousPath
        }
    }

    # --- Step 6: Code Coverage ---
    Invoke-SoftStep -StepName "Code Coverage (llvm-cov)" -Script {
        $runtimePaths = @(
            (Join-Path $buildDirClangFull "bin"),
            (Join-Path $buildDirClangFull "lib")
        )
        $runtimePaths += Get-LLVMRuntimePaths -LLVMBin $script:llvmBin
        $previousPath = $env:PATH
        $env:PATH = (($runtimePaths + @($env:PATH)) -join ';')

        Push-Location $buildDirClangFull
        try {
            $profrawPath = Join-Path $buildDirClangFull "Test\compile\default.profraw"
            $profrawCopyPath = Join-Path $logDirPath "default.profraw"
            $profdataPath = Join-Path $logDirPath "compileTestSuite.profdata"
            $coverageJsonPath = Join-Path $logDirPath "coverage.json"

            if (Test-Path $profrawPath) {
                Copy-Item -Path $profrawPath -Destination $profrawCopyPath -Force
                Invoke-External -File "llvm-profdata.exe" -Args @("merge", "-sparse", $profrawPath, "-o", $profdataPath)
                Invoke-External -File "llvm-cov.exe" -Args @("report", "compileTestSuite.exe", "-instr-profile=$profdataPath")
                
                $coverageOutput = & llvm-cov.exe export "compileTestSuite.exe" -format=text "-instr-profile=$profdataPath" 2>&1
                $coverageOutput | Out-File -FilePath $coverageJsonPath -Encoding UTF8
                Write-Log "Coverage JSON written to: $coverageJsonPath"
                
                Invoke-External -File "llvm-cov.exe" -Args @("show", "compileTestSuite.exe", "-instr-profile=$profdataPath") -IgnoreExitCode
            } else {
                Write-LogWarning "Profile data not found: $profrawPath"
            }
        } finally {
            Pop-Location
            $env:PATH = $previousPath
        }
    }

    # --- Step 7: clang-tidy ---
    if (-not $SkipClangTidy) {
        Invoke-SoftStep -StepName "clang-tidy Analysis" -Script {
            $sourceFiles = Get-SourceFiles -BasePath $srcDir
            if ($sourceFiles.Count -eq 0) {
                Write-LogWarning "No source files found for clang-tidy"
                return
            }
            $compileCommands = Join-Path $buildDirClangFull "compile_commands.json"
            if (-not (Test-Path $compileCommands)) {
                throw "compile_commands.json not found: $compileCommands"
            }
            Invoke-External -File "clang-tidy" -Args (@("--fix", "-checks=-readability-convert-member-functions-to-static,-readability-redundant-declaration,-misc-const-correctness", "-p=$compileCommands") + $sourceFiles) -IgnoreExitCode
        }
    } else {
        Skip-Step -StepName "clang-tidy Analysis" -Reason "SkipClangTidy flag set"
    }

    # --- Step 8: Clang Static Analysis (HTML) ---
    if (-not $SkipStaticAnalysis) {
        Invoke-SoftStep -StepName "Clang Static Analysis (HTML)" -Script {
            $sourceFiles = Get-SourceFiles -BasePath $srcDir
            if ($sourceFiles.Count -eq 0) {
                Write-LogWarning "No source files found for static analysis"
                return
            }
            Invoke-External -File "clang++" -Args (@("--analyze", "-DUSE_RUST=1", "-Xanalyzer", "-analyzer-output=html") + $sourceFiles) -IgnoreExitCode
        }
    } else {
        Skip-Step -StepName "Clang Static Analysis (HTML)" -Reason "SkipStaticAnalysis flag set"
    }

    # --- Step 9: scan-build ---
    if (-not $SkipScanBuild) {
        Invoke-SoftStep -StepName "scan-build Analysis" -Script {
            $scanBuildReports = Join-Path $Workspace "scan-build-reports"
            New-Item -ItemType Directory -Path $scanBuildReports -Force | Out-Null

            $analyzer = if ($script:llvmBin) { Join-Path $script:llvmBin "clang-cl.exe" } else { $null }
            if (-not $analyzer -or -not (Test-Path $analyzer)) {
                $clangCl = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
                if ($clangCl) { $analyzer = $clangCl.Source }
            }

            if ($analyzer -and (Test-Path $analyzer)) {
                Invoke-External -File "scan-build" -Args @(
                    "--use-analyzer=$analyzer",
                    "-o", $scanBuildReports,
                    "cmake", "--build", $buildDirClangFull
                ) -IgnoreExitCode
            } else {
                Write-LogWarning "scan-build skipped: clang-cl.exe not found"
            }
        }
    } else {
        Skip-Step -StepName "scan-build Analysis" -Reason "SkipScanBuild flag set"
    }

    # --- Step 10: Profile Build Configure ---
    Invoke-Step -StepName "Profile Build Configure" -Script {
        Write-Log "Using profile preset: $ClangProfilePreset"
        Ensure-CMakeGeneratorCompatibility -BuildDirectory $buildDirProfileFull -ExpectedGenerator "Ninja"
        Invoke-External -File "cmake" -Args @(
            "-B", $buildDirProfileFull,
            "--preset", $ClangProfilePreset,
            "-Dmyproject_ENABLE_CPPCHECK=OFF",
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
        )
    }

    # --- Step 11: Profile Build ---
    Invoke-Step -StepName "Profile Build" -Script {
        Invoke-External -File "cmake" -Args @("--build", $buildDirProfileFull)
    }

    # --- Step 12: Performance Benchmarks ---
    Invoke-SoftStep -StepName "Performance Benchmarks" -Script {
        Push-Location $buildDirProfileFull
        try {
            $perfExe = Join-Path $buildDirProfileFull "perfTestSuite.exe"
            $benchmarkOutPath = Join-Path $logDirPath "results.json"
            if (Test-Path $perfExe) {
                Invoke-External -File $perfExe -Args @("--benchmark_out=$benchmarkOutPath", "--benchmark_out_format=json")
            } else {
                Write-LogWarning "perfTestSuite.exe not found"
            }
        } finally {
            Pop-Location
        }
    }

    # --- Step 14: PGO (Profile-Guided Optimization) ---
    if (-not $SkipPGO) {
        Invoke-SoftStep -StepName "PGO (Profile-Guided Optimization)" -Script {
            Push-Location $buildDirProfileFull
            try {
                $mainExe = Join-Path $buildDirProfileFull "KataglyphisCppProject.exe"
                $dummyProfrawPath = Join-Path $logDirPath "dummy.profraw"
                $dummyProfdataPath = Join-Path $logDirPath "dummy.profdata"
                if (Test-Path $mainExe) {
                    $env:LLVM_PROFILE_FILE = $dummyProfrawPath
                    Invoke-External -File $mainExe -IgnoreExitCode
                    Invoke-External -File "llvm-profdata.exe" -Args @("merge", "-sparse", $dummyProfrawPath, "-o", $dummyProfdataPath)
                    Invoke-External -File "llvm-cov.exe" -Args @("show", $mainExe, "-instr-profile=$dummyProfdataPath", "-format=text") -IgnoreExitCode
                } else {
                    Write-LogWarning "KataglyphisCppProject.exe not found"
                }
            } finally {
                Pop-Location
            }
        }
    } else {
        Skip-Step -StepName "PGO (Profile-Guided Optimization)" -Reason "SkipPGO flag set"
    }

    # --- Step 15: Clean for Release Build ---
    Invoke-Step -StepName "Clean Build Directory (Prepare for Release)" -Script {
        Remove-BuildDirectory -Path $buildReleaseDirFull | Out-Null
    }

    # --- Step 16: Release Build ---
    Invoke-Step -StepName "ClangCL Release Build" -Critical -Script {
        Ensure-CMakeGeneratorCompatibility -BuildDirectory $buildReleaseDirFull -ExpectedGenerator "Ninja"
        Invoke-External -File "cmake" -Args @(
            "-B", $buildReleaseDirFull,
            "--preset", "x64-ClangCL-Windows-Release",
            "-Dmyproject_ENABLE_CPPCHECK=OFF"
        )
        Invoke-External -File "cmake" -Args @("--build", $buildReleaseDirFull)
    }

    # --- Step 17: Package ---
    Invoke-Step -StepName "Create Package" -Script {
        Invoke-External -File "cmake" -Args @("--build", $buildReleaseDirFull, "--target", "package")
    }

    Write-Log ""
    Write-LogSuccess "=== Container Build Complete ==="
    Write-Log "Release artifacts located at: $buildReleaseDirFull"

} catch {
    Write-LogError "Unhandled critical error: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) {
        Write-LogError "Stack trace: $($_.ScriptStackTrace)"
    }
} finally {
    Write-Summary
    Close-Log
    
    if ($script:Results.Failed.Count -gt 0) {
        exit 1
    }
}

#endregion