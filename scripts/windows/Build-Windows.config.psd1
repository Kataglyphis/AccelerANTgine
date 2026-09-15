# Build-Windows.config.psd1 - the build-directory / preset / configuration table
# Build-Windows.ps1 used to carry as five parameters with literal defaults.
#
# It lives here, and is read through ANTfrastructure's WindowsConfig.Common
# (Import-PowerShellDataFile + Get-ConfigValue / Get-OrDefault), for the reason
# BeschleunigerBallett moved its own table out: a preset rename is a data edit,
# not a script edit, and the environment-variable override per row lets a CI lane
# retarget one configuration without a new script parameter.
#
# Precedence per row: the named environment variable, then the literal here.
#
# Configuration is what reaches `cmake --build --config`. It is also the switch
# the hub's Invoke-CmakeConfigureAndBuild reads to decide whether to stage the
# sanitizer runtime DLLs next to the binaries, so 'Debug' here is load-bearing
# rather than cosmetic - the ClangCL debug lane links ASan.
@{
  Build = @{
    LogDir       = 'logs'
    FastBuildDir = 'C:\kataglyphis_fast_build'

    Configurations = @{
      'msvc-debug' = @{
        BuildDir      = 'build-msvc-debug'
        BuildDirEnv   = 'BUILD_DIR_MSVC'
        Preset        = 'x64-MSVC-Windows-Debug'
        PresetEnv     = 'PRESET_MSVC_DEBUG'
        Configuration = 'Debug'
      }
      'clangcl-debug' = @{
        BuildDir      = 'build-clangcl-debug'
        BuildDirEnv   = 'BUILD_DIR_CLANGCL'
        Preset        = 'x64-ClangCL-Windows-Debug'
        PresetEnv     = 'PRESET_CLANGCL_DEBUG'
        Configuration = 'Debug'
      }
      'clangcl-profile' = @{
        BuildDir      = 'build-clangcl-profile'
        BuildDirEnv   = 'BUILD_DIR_PROFILE'
        Preset        = 'x64-ClangCL-Windows-Profile'
        PresetEnv     = 'CLANG_PROFILE_PRESET'
        Configuration = 'RelWithDebInfo'
      }
      'clangcl-release' = @{
        BuildDir      = 'build-clangcl-release'
        BuildDirEnv   = 'BUILD_DIR_RELEASE'
        Preset        = 'x64-ClangCL-Windows-Release'
        PresetEnv     = 'PRESET_CLANGCL_RELEASE'
        Configuration = 'Release'
      }
    }
  }
}
