# Each *Env variable overrides its row; Configuration 'Debug' is load-bearing, it makes the hub stage the ASan runtime DLLs.
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
