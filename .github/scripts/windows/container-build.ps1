$ErrorActionPreference = 'Stop'

function Invoke-Soft([string]$Name, [scriptblock]$Block) {
  try { & $Block }
  catch {
    Write-Warning ("{0} failed: {1}" -f $Name, $_.Exception.Message)
  }
}

# Match the native job setup
if (Test-Path './scripts/windows/setup-dependencies.ps1') {
  ./scripts/windows/setup-dependencies.ps1 -ClangVersion $Env:CLANG_VERSION
}

$llvmBin = 'C:\Program Files\LLVM\bin'
if (Test-Path $llvmBin) { $env:PATH = "$llvmBin;$env:PATH" }

$scoopShims = Join-Path $env:USERPROFILE 'scoop\shims'
if (Test-Path $scoopShims) { $env:PATH = "$scoopShims;$env:PATH" }

$buildDir = Join-Path $Env:GITHUB_WORKSPACE $Env:BUILD_DIR
$buildReleaseDir = Join-Path $Env:GITHUB_WORKSPACE $Env:BUILD_DIR_RELEASE

# MSVC debug
cmake -B $buildDir --preset x64-MSVC-Windows-Debug
cmake --build $buildDir --preset x64-MSVC-Windows-Debug
Push-Location $buildDir
ctest
Pop-Location

# Prepare for Clang
Remove-Item -Path $buildDir -Recurse -Force -ErrorAction SilentlyContinue
clang --version

# ClangCL debug
cmake -B $buildDir --preset x64-ClangCL-Windows-Debug -Dmyproject_ENABLE_CPPCHECK=OFF
cmake --build $buildDir --preset x64-ClangCL-Windows-Debug
Push-Location $buildDir
ctest
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
  scan-build --use-analyzer='C:\Program Files\LLVM\bin\clang-cl.exe' -o scan-build-reports cmake --build $buildDir --preset x64-ClangCL-Windows-Debug
}

# Prepare for Profiling
clang --version

# Configure/build for Profiling
$PRESET = $Env:CLANG_PROFILE_PRESET
Write-Output ("Using preset: {0}" -f $PRESET)
cmake -B $buildReleaseDir --preset $PRESET -Dmyproject_ENABLE_CPPCHECK=OFF
cmake --build $buildReleaseDir --preset $PRESET

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
