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
    [string] $BuildDir = "build",
    [string] $BuildDirRelease = "build-release",
    [string] $ClangProfilePreset = "x64-ClangCL-Windows-RelWithDebInfo",
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

$buildDirFull = Join-Path $Workspace $BuildDir
$buildReleaseDirFull = Join-Path $Workspace $BuildDirRelease
$srcDir = Join-Path $Workspace "Src"

# Initialize logging

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDirPath = Join-Path $Workspace $LogDir
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
    Write-Log "BuildDir:             $buildDirFull"
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
            Invoke-External -File "cmake" -Args @("-B", $buildDirFull, "--preset", "x64-MSVC-Windows-Debug")
            Invoke-External -File "cmake" -Args @("--build", $buildDirFull, "--preset", "x64-MSVC-Windows-Debug")
            
            Push-Location $buildDirFull
            try {
                Invoke-External -File "ctest"
            } finally {
                Pop-Location
            }
        }
    } else {
        Skip-Step -StepName "MSVC Debug Build" -Reason "SkipMSVC flag set"
    }

    # --- Step 4: Clean for Clang Build ---
    Invoke-Step -StepName "Clean Build Directory (Prepare for Clang)" -Script {
        Remove-BuildDirectory -Path $buildDirFull | Out-Null
    }

    # --- Step 5: ClangCL Debug Build ---
    Invoke-Step -StepName "ClangCL Debug Build" -Critical -Script {
        Invoke-External -File "cmake" -Args @(
            "-B", $buildDirFull,
            "--preset", "x64-ClangCL-Windows-Debug",
            "-Dmyproject_ENABLE_CPPCHECK=OFF",
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
        )
        Invoke-External -File "cmake" -Args @("--build", $buildDirFull, "--preset", "x64-ClangCL-Windows-Debug")
    }

    # --- Step 6: ClangCL Debug Tests ---
    Invoke-Step -StepName "ClangCL Debug Tests" -Script {
        Push-Location $buildDirFull
        try {
            Invoke-External -File "ctest"
        } finally {
            Pop-Location
        }
    }

    # --- Step 7: Code Coverage ---
    Invoke-SoftStep -StepName "Code Coverage (llvm-cov)" -Script {
        Push-Location $buildDirFull
        try {
            $profrawPath = Join-Path $buildDirFull "Test\compile\default.profraw"
            $profdataPath = Join-Path $buildDirFull "compileTestSuite.profdata"
            $coverageJsonPath = Join-Path $buildDirFull "coverage.json"

            if (Test-Path $profrawPath) {
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
        }
    }

    # --- Step 8: clang-tidy ---
    if (-not $SkipClangTidy) {
        Invoke-SoftStep -StepName "clang-tidy Analysis" -Script {
            $sourceFiles = Get-SourceFiles -BasePath $srcDir
            if ($sourceFiles.Count -eq 0) {
                Write-LogWarning "No source files found for clang-tidy"
                return
            }
            $compileCommands = Join-Path $buildDirFull "compile_commands.json"
            if (-not (Test-Path $compileCommands)) {
                throw "compile_commands.json not found: $compileCommands"
            }
            Invoke-External -File "clang-tidy" -Args (@("-p=$compileCommands") + $sourceFiles) -IgnoreExitCode
        }
    } else {
        Skip-Step -StepName "clang-tidy Analysis" -Reason "SkipClangTidy flag set"
    }

    # --- Step 9: Clang Static Analysis (HTML) ---
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

    # --- Step 10: scan-build ---
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
                    "cmake", "--build", $buildDirFull, "--preset", "x64-ClangCL-Windows-Debug"
                ) -IgnoreExitCode
            } else {
                Write-LogWarning "scan-build skipped: clang-cl.exe not found"
            }
        }
    } else {
        Skip-Step -StepName "scan-build Analysis" -Reason "SkipScanBuild flag set"
    }

    # --- Step 11: Profile Build Configure ---
    Invoke-Step -StepName "Profile Build Configure" -Script {
        Write-Log "Using profile preset: $ClangProfilePreset"
        Invoke-External -File "cmake" -Args @(
            "-B", $buildReleaseDirFull,
            "--preset", $ClangProfilePreset,
            "-Dmyproject_ENABLE_CPPCHECK=OFF",
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
        )
    }

    # --- Step 12: Profile Build ---
    Invoke-Step -StepName "Profile Build" -Script {
        Invoke-External -File "cmake" -Args @("--build", $buildReleaseDirFull, "--preset", $ClangProfilePreset)
    }

    # --- Step 13: Performance Benchmarks ---
    Invoke-SoftStep -StepName "Performance Benchmarks" -Script {
        Push-Location $buildReleaseDirFull
        try {
            $perfExe = Join-Path $buildReleaseDirFull "perfTestSuite.exe"
            if (Test-Path $perfExe) {
                Invoke-External -File $perfExe -Args @("--benchmark_out=results.json", "--benchmark_out_format=json")
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
            Push-Location $buildReleaseDirFull
            try {
                $mainExe = Join-Path $buildReleaseDirFull "KataglyphisCppProject.exe"
                if (Test-Path $mainExe) {
                    $env:LLVM_PROFILE_FILE = "dummy.profraw"
                    Invoke-External -File $mainExe -IgnoreExitCode
                    Invoke-External -File "llvm-profdata.exe" -Args @("merge", "-sparse", "dummy.profraw", "-o", "dummy.profdata")
                    Invoke-External -File "llvm-cov.exe" -Args @("show", $mainExe, "-instr-profile=dummy.profdata", "-format=text") -IgnoreExitCode
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
        Invoke-External -File "cmake" -Args @(
            "-B", $buildReleaseDirFull,
            "--preset", "x64-ClangCL-Windows-Release",
            "-Dmyproject_ENABLE_CPPCHECK=OFF"
        )
        Invoke-External -File "cmake" -Args @("--build", $buildReleaseDirFull, "--preset", "x64-ClangCL-Windows-Release")
    }

    # --- Step 17: Package ---
    Invoke-Step -StepName "Create Package" -Script {
        Invoke-External -File "cmake" -Args @(
            "--build", $buildReleaseDirFull,
            "--preset", "x64-ClangCL-Windows-Release",
            "--target", "package"
        )
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