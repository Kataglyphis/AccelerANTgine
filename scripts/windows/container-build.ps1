$ErrorActionPreference = 'Stop'

function Invoke-Soft([string]$Name, [scriptblock]$Block) {
  try { & $Block }
  catch {
    Write-Warning ("{0} failed: {1}" -f $Name, $_.Exception.Message)
  }
}

function Invoke-Native([string]$Name, [scriptblock]$Block) {
  & $Block
  if ($LASTEXITCODE -ne 0) {
    throw ("{0} failed with exit code {1}" -f $Name, $LASTEXITCODE)
  }
}

$llvmBin = if ($env:LLVM_BIN) { $env:LLVM_BIN } else { 'C:\Program Files\LLVM\bin' }
if (-not (Test-Path $llvmBin)) {
  $clangCl = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
  if ($clangCl) {
    $llvmBin = Split-Path -Parent $clangCl.Source
  }
}
if (Test-Path $llvmBin) { $env:PATH = "$llvmBin;$env:PATH" }

$scoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
if (Test-Path $scoopShims) { $env:PATH = "$scoopShims;$env:PATH" }

$buildDir = Join-Path $Env:GITHUB_WORKSPACE $Env:BUILD_DIR
$buildReleaseDir = Join-Path $Env:GITHUB_WORKSPACE $Env:BUILD_DIR_RELEASE

# MSVC debug (optional in the Windows container image)
Invoke-Soft 'MSVC Debug' {
  Invoke-Native 'cmake configure (MSVC Debug)' { cmake -B $buildDir --preset x64-MSVC-Windows-Debug }
  Invoke-Native 'cmake build (MSVC Debug)' { cmake --build $buildDir --preset x64-MSVC-Windows-Debug }
  Push-Location $buildDir
  Invoke-Native 'ctest (MSVC Debug)' { ctest }
  Pop-Location
}

# Prepare for Clang
Remove-Item -Path $buildDir -Recurse -Force -ErrorAction SilentlyContinue
clang --version

# ClangCL debug
Invoke-Native 'cmake configure (ClangCL Debug)' { cmake -B $buildDir --preset x64-ClangCL-Windows-Debug -Dmyproject_ENABLE_CPPCHECK=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON }
Invoke-Native 'cmake build (ClangCL Debug)' { cmake --build $buildDir --preset x64-ClangCL-Windows-Debug }
Push-Location $buildDir
Invoke-Native 'ctest (ClangCL Debug)' { ctest }
& 'llvm-profdata.exe' merge -sparse 'Test\compile\default.profraw' -o (Join-Path $buildDir 'compileTestSuite.profdata')
& 'llvm-cov.exe' report 'compileTestSuite.exe' -instr-profile=(Join-Path $buildDir 'compileTestSuite.profdata')
& 'llvm-cov.exe' export 'compileTestSuite.exe' -format=text -instr-profile=(Join-Path $buildDir 'compileTestSuite.profdata') | Out-File -FilePath 'coverage.json' -Encoding UTF8
& 'llvm-cov.exe' show 'compileTestSuite.exe' -instr-profile=(Join-Path $buildDir 'compileTestSuite.profdata')
Pop-Location

# clang-tidy (continue-on-error)
Invoke-Soft 'clang-tidy' {
  $sourceFiles = Get-ChildItem -Path 'Src' -Recurse -Include '*.cpp', '*.cc' | ForEach-Object { $_.FullName }
  $compileCommands = Join-Path $buildDir 'compile_commands.json'
  clang-tidy -p=$compileCommands $sourceFiles
}

# Clang static analysis HTML (continue-on-error)
Invoke-Soft 'clang++ --analyze (HTML)' {
  $sourceFiles = Get-ChildItem -Path 'Src' -Recurse -Include '*.cpp', '*.cc' | ForEach-Object { $_.FullName }
  clang++ --analyze -DUSE_RUST=1 -Xanalyzer -analyzer-output=html $sourceFiles
}

# scan-build (continue-on-error)
Invoke-Soft 'scan-build' {
  New-Item -ItemType Directory -Path 'scan-build-reports' -Force | Out-Null
  $analyzer = Join-Path $llvmBin 'clang-cl.exe'
  if (-not (Test-Path $analyzer)) {
    $clangCl = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
    if ($clangCl) { $analyzer = $clangCl.Source }
  }
  if (Test-Path $analyzer) {
    scan-build --use-analyzer=$analyzer -o scan-build-reports cmake --build $buildDir --preset x64-ClangCL-Windows-Debug
  } else {
    Write-Warning "scan-build skipped: clang-cl.exe not found"
  }
}

# Prepare for Profiling
clang --version

# Configure/build for Profiling
$PRESET = $Env:CLANG_PROFILE_PRESET
Write-Output ("Using preset: {0}" -f $PRESET)
Invoke-Native 'cmake configure (Profile)' { cmake -B $buildReleaseDir --preset $PRESET -Dmyproject_ENABLE_CPPCHECK=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON }
Invoke-Native 'cmake build (Profile)' { cmake --build $buildReleaseDir --preset $PRESET }

# Run performance benchmarks
Push-Location $buildReleaseDir
.\perfTestSuite.exe --benchmark_out=results.json --benchmark_out_format=json

# Instrumentation-based PGO (continue-on-error)
Invoke-Soft 'PGO' {
  $Env:LLVM_PROFILE_FILE = 'dummy.profraw'
  & '.\KataglyphisCppProject.exe'
  & 'llvm-profdata.exe' merge -sparse 'dummy.profraw' -o 'dummy.profdata'
  & 'llvm-cov.exe' show '.\KataglyphisCppProject.exe' -instr-profile='dummy.profdata' -format=text
}
Pop-Location

# Prepare for Release build
Remove-Item -Path $buildReleaseDir -Recurse -Force -ErrorAction SilentlyContinue
clang --version

# Release + package (ClangCL)
cmake -B $buildReleaseDir --preset x64-ClangCL-Windows-Release -Dmyproject_ENABLE_CPPCHECK=OFF
cmake --build $buildReleaseDir --preset x64-ClangCL-Windows-Release
cmake --build $buildReleaseDir --preset x64-ClangCL-Windows-Release --target package
