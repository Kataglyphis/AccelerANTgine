# update current positions
set(PROJECT_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(PROJECT_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(EXTERNAL_LIB_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}../ExternalLib/)

include(cmake/filters/SetProjectFilters.cmake)
include(cmake/SetSourceGroups.cmake)

file(GLOB_RECURSE KataglyphisCppProject_SOURCES "*.cpp")
file(GLOB_RECURSE KataglyphisCppProject_HEADERS "*.hpp")

if(RUST_FEATURES)

  corrosion_import_crate(
    MANIFEST_PATH rusty_code/Cargo.toml
  )
  if(WIN32)
    corrosion_set_env_vars(
              rusty_code
              CXXFLAGS=/EHsc
    )
  else()
    
Du:
e/KataglyphisCppInference $ cat Src/CMakeLists.txt   # update current positions
set(PROJECT_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(PROJECT_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(EXTERNAL_LIB_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}../ExternalLib/)

include(cmake/filters/SetProjectFilters.cmake)
include(cmake/SetSourceGroups.cmake)

file(GLOB_RECURSE KataglyphisCppProject_SOURCES "*.cpp")
file(GLOB_RECURSE KataglyphisCppProject_HEADERS "*.hpp")

if(RUST_FEATURES)

  corrosion_import_crate(
    MANIFEST_PATH rusty_code/Cargo.toml
  )
  if(WIN32)
    corrosion_set_env_vars(
              rusty_code
              CXXFLAGS=/EHsc
    )
  else()
    # Set the GCC 15.2.0 toolchain for Rust CXX bridge
    set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0")
    set(GCC_INCLUDE_PATH "${GCC_TOOLCHAIN_PATH}/include/c++/15.2.0")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")

    corrosion_set_env_vars(
              rusty_code
              CC=${GCC_TOOLCHAIN_PATH}/bin/gcc
              CXX=${GCC_TOOLCHAIN_PATH}/bin/g++
              CXXFLAGS=-fexceptions -I${GCC_INCLUDE_PATH} -I${GCC_INCLUDE_PATH}/aarch64-unknown-linux-gnu
              LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
    )
  endif()

  corrosion_add_cxxbridge(
    rusty_bridge
    CRATE
    rusty_code
    FILES
    lib.rs
    )

endif()

# add the executable
add_library(${PROJECT_NAME} SHARED)
set_target_properties(${PROJECT_NAME} PROPERTIES
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
# add_executable(${PROJECT_NAME})

# Define export macro for building the DLL
target_compile_definitions(${PROJECT_NAME} PRIVATE KATAGLYPHIS_EXPORTS)

# Set symbol visibility
set_target_properties(${PROJECT_NAME} PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

if(RUST_FEATURES)
  message("RUST features defined")
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=1)
else()
  message("RUST features not defined")
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=0)
endif()

# Treat MSVC and clang-cl on Windows differently in a sense of deployment
# https://clang.llvm.org/docs/UsersManual.html
if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC))
  target_compile_definitions(
    ${PROJECT_NAME}
    PRIVATE
      RELATIVE_RESOURCE_PATH="/../../Resources/"
      RELATIVE_INCLUDE_PATH="/../../Src/"
  )
else()
  target_compile_definitions(
    ${PROJECT_NAME}
    PRIVATE
      RELATIVE_RESOURCE_PATH="/../Resources/"
      RELATIVE_INCLUDE_PATH="/../Src/"
  )
endif()


configure_file(KataglyphisCppProjectConfig.hpp.in "${CMAKE_CURRENT_SOURCE_DIR}/KataglyphisCppProjectConfig.hpp")

target_sources(
  ${PROJECT_NAME}
  PUBLIC ${KataglyphisCppProject_SOURCES}
  PUBLIC FILE_SET
         HEADERS
         BASE_DIRS
         ${PROJECT_INCLUDE_DIR}
         FILES
         ${KataglyphisCppProject_HEADERS})

target_link_libraries(
  ${PROJECT_NAME}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         # enable compiler warnings
         myproject_warnings
         # enable sanitizers
         myproject_options
  PRIVATE GSL spdlog::spdlog nlohmann_json::nlohmann_json)

if(RUST_FEATURES)
  target_link_libraries(${PROJECT_NAME} PUBLIC rusty_code)
endif()

if(TARGET ${PROJECT_NAME} AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  message(STATUS "GCC detected — adding -MMD -MP to target ${PROJECT_NAME}")
  target_compile_options(${PROJECT_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-MMD -MP>
  )
endif()

I updated the rusty code flags to now point to GCC 15.2.0. but now the build breaks. 
Now can I find out why?
ChatGPT:

Nachgedacht für 9s
Nice — thanks for the CMake snippet. I’ll walk through the most likely causes and give a short checklist + concrete commands and a small CMake patch you can try right away. This should let you find why the build breaks after switching the Rust C++-bridge environment to /opt/gcc-15.2.0.

Quick summary of likely problems
Wrong / missing paths (/opt/gcc-15.2.0/include/c++/15.2.0 or /opt/gcc-15.2.0/lib64 might not exist or have different names).

Cross/arch mismatch — you add -I${GCC_INCLUDE_PATH}/aarch64-unknown-linux-gnu while building for a different host (x86_64 vs aarch64).

You are adding -I include dirs for libstdc++ directly — this can confuse rustc/clang/gcc selection and cause header mismatches.

Runtime linker issues — libstdc++ not found or wrong version at link/run time (need LDFLAGS / rpath / LD_LIBRARY_PATH).

ABI or compiler mismatch — rustc/cxxbridge might expect the system libstdc++/libgcc, not your custom toolchain, leading to link errors.

Typo/relative-path bug in CMake (e.g. ${CMAKE_CURRENT_SOURCE_DIR}../ExternalLib/ missing a slash).

Immediate checks (run these in shell)
These will quickly detect the common path/arch problems.

# 1) confirm the toolchain dir exists
ls -la /opt/gcc-15.2.0

# 2) inspect c++ include layout
ls -la /opt/gcc-15.2.0/include/c++

# 3) inspect libdir & libstdc++
ls -la /opt/gcc-15.2.0/lib64
file /opt/gcc-15.2.0/lib64/libstdc++.so* || true

# 4) try building the Rust crate directly (verbose)
cd rusty_code
env CC=/opt/gcc-15.2.0/bin/gcc CXX=/opt/gcc-15.2.0/bin/g++ \
    cargo build -v --manifest-path Cargo.toml
cd -
If any ls shows “No such file or directory” then adapt your GCC_INCLUDE_PATH / GCC_LIB_PATH or install the toolchain properly.

Build with maximum verbosity (capture exact error)
Run CMake with verbosity and build so you see the exact compiler / linker errors:

cmake -S . -B build -DRUST_FEATURES=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build --parallel 8 --verbose   # or `ninja -v` if using ninja
If the break happens inside the Rust crate, the cargo build -v output above will show the failing rustc/linker invocation and the error text — paste that if you want me to parse it.

Common error messages and what they mean (and fixes)
No such file or directory: /opt/gcc-15.2.0/include/c++/15.2.0/...
→ include path wrong. Fix by pointing GCC_INCLUDE_PATH to the actual directory (or use /opt/gcc-15.2.0/include/c++ without the version).

undefined reference or linker errors when linking C++ symbols
→ libstdc++.so from toolchain not found or incompatible. Make sure LDFLAGS includes -L${GCC_LIB_PATH} and add an rpath -Wl,-rpath,${GCC_LIB_PATH} (you already do that, verify the path exists).

file not recognized: file format not recognized or architecture mismatch
→ compiling/linking for different architecture (aarch64 vs x86_64). Remove the aarch64 include unless you're cross-compiling and ensure the toolchain matches host architecture.

Strange compiler header conflicts / errors from libstdc++ headers
→ avoid forcing -I into CXXFLAGS for toolchain C++ headers. Let the C/C++ compiler find its own headers, or use -isystem instead of -I to avoid macro/header pollution.

Suggested CMake adjustments (safe conservative change)
Two small fixes: fix the relative path and stop injecting the c++ include paths into CXXFLAGS (which often causes trouble). Use the toolchain compilers only via CC/CXX and let them find their own headers.

Replace your current block:

set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0")
set(GCC_INCLUDE_PATH "${GCC_TOOLCHAIN_PATH}/include/c++/15.2.0")
set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")

corrosion_set_env_vars(
          rusty_code
          CC=${GCC_TOOLCHAIN_PATH}/bin/gcc
          CXX=${GCC_TOOLCHAIN_PATH}/bin/g++
          CXXFLAGS=-fexceptions -I${GCC_INCLUDE_PATH} -I${GCC_INCLUDE_PATH}/aarch64-unknown-linux-gnu
          LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
)
with this more conservative variant:

# safer paths (and fix missing slash in EXTERNAL_LIB_SRC_DIR above)
set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0")
set(GCC_INCLUDE_PATH "${GCC_TOOLCHAIN_PATH}/include/c++")   # avoid hardcoding version
set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")

# Only set compilers and linker search path. Avoid forcing C++ include dirs into CXXFLAGS.
corrosion_set_env_vars(
  rusty_code
  CC=${GCC_TOOLCHAIN_PATH}/bin/gcc
  CXX=${GCC_TOOLCHAIN_PATH}/bin/g++
  CXXFLAGS=-fexceptions
  LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
)
Also fix the earlier path line:

# before:
set(EXTERNAL_LIB_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}../ExternalLib/)
# change to:
set(EXTERNAL_LIB_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../ExternalLib/")
If the crate still fails: collect these and paste them here
The full error output from cmake --build build --verbose (or ninja -v) — copy the failing compile/link commands and error text.

The output of cargo build -v run inside rusty_code with those env vars (paste the rustc invocation & error).

Output of ls -la /opt/gcc-15.2.0 and ls -la /opt/gcc-15.2.0/include/c++ and file /opt/gcc-15.2.0/lib64/libstdc++.so*.

With those I can say precisely whether it's a path/arch/ABI/linker problem and give the exact minimal fix (e.g. change an include path, set LD_LIBRARY_PATH for test, or change how corrosion sets env).

Extra tips
If you only need Rust to use that compiler for system calls, prefer setting CC & CXX only. Avoid manual include injection.

If you actually need cross-compilation to aarch64, set the correct target triple and use a matching cross-toolchain (not mixing host includes).

You can also try using the toolchain by setting CMake variables instead of env-vars: set(CMAKE_C_COMPILER /opt/gcc-15.2.0/bin/gcc) etc., but for Rust/corrosion the CC/CXX env is what cargo will consume.

If you paste the exact failing log (the rustc/link error or CMake verbose failure) I’ll parse it and give the exact change to make.

Du:
rchive  images  output.log  windows
docs     linux   README.md
bigjuicyjones@backpropberserker:~/GitHub/Kataglyphis-DockerHub$ sudo nerdctl run -it --rm ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest
[sudo] Passwort für bigjuicyjones:
root@6afbc965a80e:/workspace# ls /opt/gcc-15.2.0
bin  include  lib  lib64  libexec  share
root@6afbc965a80e:/workspace# ls /opt/gcc-15.2.0/bin
c++         gfortran
cpp         lto-dump
g++         x86_64-pc-linux-gnu-c++
gcc         x86_64-pc-linux-gnu-g++
gcc-ar      x86_64-pc-linux-gnu-gcc
gcc-nm      x86_64-pc-linux-gnu-gcc-15.2.0
gcc-ranlib  x86_64-pc-linux-gnu-gcc-ar
gcov        x86_64-pc-linux-gnu-gcc-nm
gcov-dump   x86_64-pc-linux-gnu-gcc-ranlib
gcov-tool   x86_64-pc-linux-gnu-gfortran
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/
share  libexec  lib64  lib  include  bin
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/include
c++
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/ share  libexec  lib64  lib  include  bin
root@6afbc965a80e:/workspace#
ChatGPT:

Nachgedacht für 6s
Nice — thanks, that ls output was the missing piece. The toolchain is present at /opt/gcc-15.2.0 — but your original CMake used a versioned include path that doesn't exist and also injected an aarch64 include. That's very likely why the build broke after you switched the Rust flags.

What I see (diagnosis)
/opt/gcc-15.2.0 exists and contains bin, include, lib64, etc. (good).

/opt/gcc-15.2.0/include contains c++ but not c++/15.2.0.
→ Your CMake used include/c++/15.2.0 which does not exist — that will lead to header-not-found or wrong-header-versions errors.

You were adding -I${GCC_INCLUDE_PATH}/aarch64-unknown-linux-gnu — but the toolchain in bin is x86_64-pc-linux-gnu-*, so you are not building for aarch64 here. That mismatch can produce weird compile/link errors.

Concrete immediate fixes (apply in CMake)
Replace your current toolchain block with this conservative, safe version:

# safer, non-versioned include path and no aarch64 hack
set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0")
set(GCC_INCLUDE_PATH "${GCC_TOOLCHAIN_PATH}/include/c++")   # do NOT hardcode version
set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")

# Only set CC/CXX and LDFLAGS. Avoid forcing C++ include dirs into CXXFLAGS.
corrosion_set_env_vars(
  rusty_code
  CC=${GCC_TOOLCHAIN_PATH}/bin/gcc
  CXX=${GCC_TOOLCHAIN_PATH}/bin/g++
  CXXFLAGS=-fexceptions
  LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
)
Also fix your earlier relative-path typo:

set(EXTERNAL_LIB_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../ExternalLib/")
Quick tests to run (in the container) — these will confirm the problem & solution
Check the include search paths used by that g++:

/opt/gcc-15.2.0/bin/g++ -E -x c++ - -v < /dev/null
This prints the include-search order — confirm /opt/gcc-15.2.0/include/c++ appears.

Compile a tiny test with that compiler:

echo '#include <iostream>\nint main(){ std::cout << "ok\\n"; }' > test.cpp
/opt/gcc-15.2.0/bin/g++ test.cpp -o test && ./test
Build the Rust crate directly (verbose) using the toolchain:

cd rusty_code
env CC=/opt/gcc-15.2.0/bin/gcc CXX=/opt/gcc-15.2.0/bin/g++ \
    cargo build -v --manifest-path Cargo.toml
Watch the rustc/linker invocation printed by cargo build -v. If it fails, copy/paste that exact error and the rustc command line.

If the produced binary fails at runtime due to missing libstdc++, test by running (before running the binary):

export LD_LIBRARY_PATH=/opt/gcc-15.2.0/lib64:$LD_LIBRARY_PATH
Why this change helps
Avoids pointing to a non-existent include/c++/15.2.0 directory. Using the non-versioned include/c++ lets the compiler select the correct headers it expects.

Stops trying to mix aarch64 headers into an x86_64 compile — that mismatch causes header/ABI problems.

Keeps the toolchain library path in LDFLAGS and sets runtime rpath, so the correct libstdc++ can be found at link/run time.

Next step I can do for you
If you run the cargo build -v or cmake --build ... --verbose after applying the CMake patch and paste the failing compiler/linker lines (the full error text plus the rustc/g++ command that failed), I’ll parse it and give the exact one-line change you need (or a minimal patch).

But from what you showed, the primary culprit is the wrong include path (.../c++/15.2.0) and the stray aarch64 include — fix those first and the break will most likely disappear.

Du:
root@6afbc965a80e:/workspace# ls /opt/gcc-15.2.0/bin
c++         gfortran
cpp         lto-dump
g++         x86_64-pc-linux-gnu-c++
gcc         x86_64-pc-linux-gnu-g++
gcc-ar      x86_64-pc-linux-gnu-gcc
gcc-nm      x86_64-pc-linux-gnu-gcc-15.2.0
gcc-ranlib  x86_64-pc-linux-gnu-gcc-ar
gcov        x86_64-pc-linux-gnu-gcc-nm
gcov-dump   x86_64-pc-linux-gnu-gcc-ranlib
gcov-tool   x86_64-pc-linux-gnu-gfortran
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/
share  libexec  lib64  lib  include  bin
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/include
c++
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/ share  libexec  lib64  lib  include  bin
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/lib
gcc
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/lib/gcc
x86_64-pc-linux-gnu
root@6afbc965a80e:/workspace# ls -r /opt/gcc-15.2.0/lib64
libubsan.so.1.0.0           liblsan.a
libubsan.so.1               libitm.spec
libubsan.so                 libitm.so.1.0.0
libubsan.la                 libitm.so.1
libubsan.a                  libitm.so
libtsan_preinit.o           libitm.la
libtsan.so.2.0.0            libitm.a
libtsan.so.2                libhwasan_preinit.o
libtsan.so                  libhwasan.so.0.0.0
libtsan.la                  libhwasan.so.0
libtsan.a                   libhwasan.so
libsupc++.la                libhwasan.la
libsupc++.a                 libhwasan.a
libstdc++fs.la              libgomp.spec
libstdc++fs.a               libgomp.so.1.0.0
libstdc++exp.la             libgomp.so.1
libstdc++exp.a              libgomp.so
libstdc++.so.6.0.34-gdb.py  libgomp.la
libstdc++.so.6.0.34         libgomp.a
libstdc++.so.6              libgfortran.spec
libstdc++.so                libgfortran.so.5.0.0
libstdc++.modules.json      libgfortran.so.5
libstdc++.la                libgfortran.so
libstdc++.a                 libgfortran.la
libssp_nonshared.la         libgfortran.a
libssp_nonshared.a          libgcc_s.so.1
libssp.so.0.0.0             libgcc_s.so
libssp.so.0                 libcc1.so.0.0.0
libssp.so                   libcc1.so.0
libssp.la                   libcc1.so
libssp.a                    libcc1.la
libsanitizer.spec           libatomic.so.1.2.0
libquadmath.so.0.0.0        libatomic.so.1
libquadmath.so.0            libatomic.so
libquadmath.so              libatomic.la
libquadmath.la              libatomic.a
libquadmath.a               libasan_preinit.o
liblsan_preinit.o           libasan.so.8.0.0
liblsan.so.0.0.0            libasan.so.8
liblsan.so.0                libasan.so
liblsan.so                  libasan.la
liblsan.la                  libasan.a
root@6afbc965a80e:/workspace#

This is.exemplary for an amd64 container. But my cmake should work in every architecture
ChatGPT:

Nachgedacht für 4 Sekunden
Nice — thanks for the extra ls output. You’re right: the container is amd64 and your toolchain is x86_64, so the previous hard-coded include path and the stray aarch64 include are the root causes. If your CMake must work across architectures, the safest approach is:

don’t hardcode versioned include paths (e.g. include/c++/15.2.0),

don’t inject architecture-specific include dirs (aarch64-...) unless you’re really cross-compiling, and

detect the toolchain layout at configure time and pick lib64 vs lib automatically.

Below is a drop-in CMake snippet you can use to replace your current toolchain block. It is defensive, works on amd64 and aarch64 systems, prefers lib64 but falls back to lib, avoids forcing C++ include dirs, and only sets CC/CXX and linker paths for corrosion. Paste it into your CMakeLists.txt (or into the cmake file that sets up rusty_code):

# --- toolchain/corrosion conservative setup (multi-arch friendly) ---
# Optionally override this when calling cmake: -DGCC_TOOLCHAIN_PATH=/path/to/gcc
set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0" CACHE PATH "Optional GCC toolchain root")

if(EXISTS "${GCC_TOOLCHAIN_PATH}")
  # find compiler binaries inside toolchain
  find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/gcc" "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-gcc")
  find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/g++" "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-g++")

  if(NOT GCC_TOOLCHAIN_GCC OR NOT GCC_TOOLCHAIN_GXX)
    message(WARNING "GCC toolchain binaries not found in ${GCC_TOOLCHAIN_PATH}; falling back to system compilers")
  endif()

  # prefer lib64, fallback to lib (works for different distributions/archs)
  if(EXISTS "${GCC_TOOLCHAIN_PATH}/lib64")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")
  elseif(EXISTS "${GCC_TOOLCHAIN_PATH}/lib")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib")
  else()
    message(FATAL_ERROR "No lib directory found under ${GCC_TOOLCHAIN_PATH}")
  endif()

  # Do NOT force C++ include directories into CXXFLAGS (this causes header/ABI conflicts).
  # Only set CC/CXX and make sure cargo/ld find the toolchain libs at link & runtime.
  corrosion_set_env_vars(
    rusty_code
    CC=${GCC_TOOLCHAIN_GCC}
    CXX=${GCC_TOOLCHAIN_GXX}
    CXXFLAGS=-fexceptions
    LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
  )

  message(STATUS "Configured corrosion to use ${GCC_TOOLCHAIN_GCC} / ${GCC_TOOLCHAIN_GXX} (lib: ${GCC_LIB_PATH})")
else()
  message(STATUS "No GCC_TOOLCHAIN_PATH (${GCC_TOOLCHAIN_PATH}) found — using system compilers")
endif()
# --- end toolchain block ---
Additional items & rationale

find_program ensures CMake uses the actual compiler binary if present; if not present it falls back to system compilers.

We do not add -I${GCC_TOOLCHAIN_PATH}/include/c++ or aarch64 include folders — letting the compiler choose its own headers avoids mixing header sets from different toolchains.

-Wl,-rpath,${GCC_LIB_PATH} ensures the produced binaries can find the toolchain libstdc++ at runtime without forcing users to set LD_LIBRARY_PATH.

If you are cross-compiling (i.e., building on x86_64 for aarch64), you must use a proper cross toolchain and also tell Cargo the target triple (for example --target aarch64-unknown-linux-gnu) and ensure the toolchain provides matching headers/libs. Mixing x86_64 headers into an aarch64 build will always fail.

If you want to be extra cautious about the architecture, you can detect the host arch in CMake:

message(STATUS "CMAKE_HOST_SYSTEM_PROCESSOR = ${CMAKE_HOST_SYSTEM_PROCESSOR}")
Use that to decide whether to enable cross-compile behavior. But in the majority of cases the snippet above is enough and portable.

If you still run into a break after applying that snippet, paste the exact failing compiler/linker command and its error output (from cmake --build ... --verbose or cargo build -v inside rusty_code) and I’ll parse it and give the exact one-line fix.

Du:
The answer u gave me will only work in amd64
ChatGPT:

Nachgedacht für 6s
You’re right — my earlier snippet assumed an x86_64-ish toolchain layout and didn’t fully cover cross-compile or aarch64 cases. Below is a multi-arch, defensive CMake snippet that:

detects host arch (and lets you override TARGET_ARCH for intentional cross builds),

looks up the correct compiler names for x86_64 and aarch64 toolchains,

prefers lib64 but falls back to lib,

avoids forcing C++ include dirs for native builds (still uses -isystem only when a cross sysroot include is actually required), and

sets sensible environment variables for corrosion/Cargo including the Rust target triple and the Cargo linker env var (generated programmatically).

Drop this into the part of your CMake that configures rusty_code:

# Multi-arch corrosion toolchain setup (works native & cross)
# Usage: optionally pass -DTARGET_ARCH=aarch64 (or x86_64) to cmake to force a target.

# 1) detect host arch, allow override for explicit cross
if(NOT DEFINED TARGET_ARCH)
  string(TOLOWER "${CMAKE_HOST_SYSTEM_PROCESSOR}" _hostproc)
  if(_hostproc MATCHES "^(x86_64|amd64)$")
    set(HOST_ARCH "x86_64")
  elseif(_hostproc MATCHES "^(aarch64|arm64|armv8)$")
    set(HOST_ARCH "aarch64")
  else()
    set(HOST_ARCH "${_hostproc}")
  endif()
  set(TARGET_ARCH "${HOST_ARCH}" CACHE STRING "Target architecture (x86_64 or aarch64)")
endif()

message(STATUS "HOST_ARCH=${HOST_ARCH}, TARGET_ARCH=${TARGET_ARCH}")

# 2) optional toolchain root; user may override
set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0" CACHE PATH "Optional GCC toolchain root")

if(EXISTS "${GCC_TOOLCHAIN_PATH}")
  # Find plausible compiler names for both arches
  if(TARGET_ARCH STREQUAL "x86_64")
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc" "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-gcc-15.2.0")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
    set(RUST_TARGET_TRIPLE "x86_64-unknown-linux-gnu")
  elseif(TARGET_ARCH STREQUAL "aarch64")
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/aarch64-pc-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/aarch64-pc-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
    set(RUST_TARGET_TRIPLE "aarch64-unknown-linux-gnu")
  else()
    # fallback: try generic names
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/g++")
    set(RUST_TARGET_TRIPLE "${TARGET_ARCH}-unknown-linux-gnu")
  endif()

  if(NOT GCC_TOOLCHAIN_GCC OR NOT GCC_TOOLCHAIN_GXX)
    message(WARNING "Could not find explicit compiler binaries in ${GCC_TOOLCHAIN_PATH}; falling back to system compilers")
  endif()

  # prefer lib64 then lib
  if(EXISTS "${GCC_TOOLCHAIN_PATH}/lib64")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")
  elseif(EXISTS "${GCC_TOOLCHAIN_PATH}/lib")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib")
  else()
    message(FATAL_ERROR "No lib directory found under ${GCC_TOOLCHAIN_PATH}")
  endif()

  # If cross-compiling (TARGET_ARCH != HOST_ARCH) you may need target sysroot includes.
  # Only add include paths if they actually exist, and use -isystem to avoid polluting macros.
  set(GCC_SYS_INCLUDE "")
  if(NOT TARGET_ARCH STREQUAL HOST_ARCH)
    # typical possible include layouts
    foreach(pfx "include/c++" "lib/gcc/${TARGET_ARCH}" "lib/gcc/${TARGET_ARCH}/15.2.0/include")
      if(EXISTS "${GCC_TOOLCHAIN_PATH}/${pfx}")
        list(APPEND GCC_SYS_INCLUDE "${GCC_TOOLCHAIN_PATH}/${pfx}")
      endif()
    endforeach()
  endif()

  # Build Cargo linker env var name: CARGO_TARGET_<TRIPLE_WITH_-_TO_>_LINKER
  string(REPLACE "-" "_" _rust_env "${RUST_TARGET_TRIPLE}")
  string(TOUPPER "${_rust_env}" _rust_env)
  set(CARGO_LINKER_VAR "CARGO_TARGET_${_rust_env}_LINKER")

  # Now set corrosion env vars. We set CC/CXX and LDFLAGS; add CARGO_BUILD_TARGET
  # and the generated cargo linker env var if cross-compiling.
  set(_corrosion_env
    CC=${GCC_TOOLCHAIN_GCC}
    CXX=${GCC_TOOLCHAIN_GXX}
    CXXFLAGS=-fexceptions
    LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
    CARGO_BUILD_TARGET=${RUST_TARGET_TRIPLE}
  )

  if(NOT TARGET_ARCH STREQUAL HOST_ARCH)
    list(APPEND _corrosion_env "${CARGO_LINKER_VAR}=${GCC_TOOLCHAIN_GCC}")
    # if we detected sys includes, add them as -isystem to CXXFLAGS
    if(GCC_SYS_INCLUDE)
      foreach(inc ${GCC_SYS_INCLUDE})
        list(APPEND _corrosion_env "CXXFLAGS=${CXXFLAGS} -isystem${inc}")
      endforeach()
    endif()
  endif()

  # Convert list to arguments for corrosion_set_env_vars
  message(STATUS "Configuring corrosion env: ${_corrosion_env}")
  corrosion_set_env_vars(rusty_code ${_corrosion_env})
  message(STATUS "Configured corrosion: CC=${GCC_TOOLCHAIN_GCC} CXX=${GCC_TOOLCHAIN_GXX} lib=${GCC_LIB_PATH} rust_target=${RUST_TARGET_TRIPLE}")
else()
  message(STATUS "No GCC_TOOLCHAIN_PATH (${GCC_TOOLCHAIN_PATH}) found — using system compilers")
endif()
How this handles different scenarios
Native build on amd64 — TARGET_ARCH defaults to x86_64. It will select x86_64 compiler names found in the toolchain and not add cross includes. It will not force include/c++/15.2.0.

Native build on aarch64 — TARGET_ARCH will be aarch64 and detection will pick aarch64 compiler names if present.

Cross-compile (build on amd64, target aarch64) — pass -DTARGET_ARCH=aarch64 to cmake. The script will try to locate aarch64 toolchain binaries under GCC_TOOLCHAIN_PATH, set CARGO_BUILD_TARGET and the Cargo linker env var (e.g. CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER) so cargo uses the right linker, and will add target sysroot -isystem includes only if those folders are present.

Quick checks & commands (run in container)
Force a native configure (amd64):

cmake -S . -B build -DGCC_TOOLCHAIN_PATH=/opt/gcc-15.2.0
cmake --build build -j $(nproc) --verbose
Force cross configure to aarch64 (if you have aarch64 toolchain and Rust target installed):

cmake -S . -B build -DGCC_TOOLCHAIN_PATH=/opt/gcc-15.2.0 -DTARGET_ARCH=aarch64
cmake --build build -j $(nproc) --verbose
Test the rust crate build directly with the selected env:

cd rusty_code
env CC=/opt/gcc-15.2.0/bin/gcc CXX=/opt/gcc-15.2.0/bin/g++ CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu \
    cargo build -v --manifest-path Cargo.toml --target aarch64-unknown-linux-gnu
(only do the last line if you're actually cross-compiling and you have the Rust target installed with rustup target add).

Important notes / gotchas
Cross-compiling requires more than a compiler: for aarch64 target you need the matching target libraries/sysroot and the Rust target installed (rustup target add aarch64-unknown-linux-gnu). Without those, linking will fail.

Prefer -isystem not -I if you must inject target includes to avoid macro/header pollution.

If you’re building multi-arch images in CI, prefer per-arch toolchain images (or pass -DGCC_TOOLCHAIN_PATH to CMake) rather than one codepath that assumes the same layout everywhere.

If you want, I can:

produce a tiny test CMake project that exercises both native and cross branches so you can validate in CI, or

parse any specific failing cargo build -v or cmake --build --verbose output you paste here and give the exact one-line fix.

Pick one and I’ll give it right away.

Du:
OK cool. Add riscv64
ChatGPT:

Nachgedacht für einige wenige Sekunden
Nice — done. Below is an updated, multi-arch CMake snippet that adds riscv64 support (native or cross). It follows the same pattern as before: detects host/target, finds plausible compiler names, prefers lib64/lib, only injects sysroot includes when cross-compiling, and sets the Cargo linker env var and CARGO_BUILD_TARGET. I default the Rust triple for RISC-V to riscv64gc-unknown-linux-gnu (common for Linux targets) but you can change it if you prefer a different triple.

Multi-arch (x86_64, aarch64, riscv64) corrosion setup
# Multi-arch corrosion toolchain setup (native & cross)
# Usage: optionally pass -DTARGET_ARCH=aarch64 (or x86_64 or riscv64) to cmake to force a target.
# Optionally pass -DGCC_TOOLCHAIN_PATH=/path/to/toolchain

if(NOT DEFINED TARGET_ARCH)
  string(TOLOWER "${CMAKE_HOST_SYSTEM_PROCESSOR}" _hostproc)
  if(_hostproc MATCHES "^(x86_64|amd64)$")
    set(HOST_ARCH "x86_64")
  elseif(_hostproc MATCHES "^(aarch64|arm64|armv8)$")
    set(HOST_ARCH "aarch64")
  elseif(_hostproc MATCHES "^(riscv64)$")
    set(HOST_ARCH "riscv64")
  else()
    set(HOST_ARCH "${_hostproc}")
  endif()
  set(TARGET_ARCH "${HOST_ARCH}" CACHE STRING "Target architecture (x86_64, aarch64, riscv64, ...)")
endif()

message(STATUS "HOST_ARCH=${HOST_ARCH}, TARGET_ARCH=${TARGET_ARCH}")

set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0" CACHE PATH "Optional GCC toolchain root")

if(EXISTS "${GCC_TOOLCHAIN_PATH}")
  if(TARGET_ARCH STREQUAL "x86_64")
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc" "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-gcc-15.2.0")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
    set(RUST_TARGET_TRIPLE "x86_64-unknown-linux-gnu")
  elseif(TARGET_ARCH STREQUAL "aarch64")
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/aarch64-pc-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/aarch64-pc-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
    set(RUST_TARGET_TRIPLE "aarch64-unknown-linux-gnu")
  elseif(TARGET_ARCH STREQUAL "riscv64")
    # Common names for linux-targeting RISC-V toolchains; include variations
    find_program(GCC_TOOLCHAIN_GCC NAMES
      "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-linux-gnu-gcc"
      "${GCC_TOOLCHAIN_PATH}/bin/riscv64-linux-gnu-gcc"
      "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-elf-gcc"
      "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES
      "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-linux-gnu-g++"
      "${GCC_TOOLCHAIN_PATH}/bin/riscv64-linux-gnu-g++"
      "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-elf-g++"
      "${GCC_TOOLCHAIN_PATH}/bin/g++")
    # Default Rust target triple for RISC-V Linux — change if needed
    set(RUST_TARGET_TRIPLE "riscv64gc-unknown-linux-gnu")
  else()
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/g++")
    set(RUST_TARGET_TRIPLE "${TARGET_ARCH}-unknown-linux-gnu")
  endif()

  if(NOT GCC_TOOLCHAIN_GCC OR NOT GCC_TOOLCHAIN_GXX)
    message(WARNING "Could not find explicit compiler binaries in ${GCC_TOOLCHAIN_PATH}; falling back to system compilers")
  endif()

  if(EXISTS "${GCC_TOOLCHAIN_PATH}/lib64")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")
  elseif(EXISTS "${GCC_TOOLCHAIN_PATH}/lib")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib")
  else()
    message(FATAL_ERROR "No lib directory found under ${GCC_TOOLCHAIN_PATH}")
  endif()

  # If cross-compiling, only add sysroot include dirs that actually exist and use -isystem
  set(GCC_SYS_INCLUDE "")
  if(NOT TARGET_ARCH STREQUAL HOST_ARCH)
    foreach(pfx "include/c++" "lib/gcc/${TARGET_ARCH}" "lib/gcc/${TARGET_ARCH}/*/include" "sysroot/usr/include")
      # glob-friendly check: if exists either exact or with wildcard
      file(GLOB _matches "${GCC_TOOLCHAIN_PATH}/${pfx}")
      if(_matches)
        foreach(_m IN LISTS _matches)
          if(EXISTS "${_m}")
            list(APPEND GCC_SYS_INCLUDE "${_m}")
          endif()
        endforeach()
      endif()
    endforeach()
  endif()

  # Build Cargo linker env var key, e.g. CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER
  string(REPLACE "-" "_" _rust_env "${RUST_TARGET_TRIPLE}")
  string(TOUPPER "${_rust_env}" _rust_env)
  set(CARGO_LINKER_VAR "CARGO_TARGET_${_rust_env}_LINKER")

  # Prepare corrosion env list
  set(_corrosion_env
    CC=${GCC_TOOLCHAIN_GCC}
    CXX=${GCC_TOOLCHAIN_GXX}
    CXXFLAGS=-fexceptions
    LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
    CARGO_BUILD_TARGET=${RUST_TARGET_TRIPLE}
  )

  if(NOT TARGET_ARCH STREQUAL HOST_ARCH)
    list(APPEND _corrosion_env "${CARGO_LINKER_VAR}=${GCC_TOOLCHAIN_GCC}")
    if(GCC_SYS_INCLUDE)
      # append -isystem includes to CXXFLAGS in a safe way
      set(_isys "")
      foreach(inc ${GCC_SYS_INCLUDE})
        set(_isys "${_isys} -isystem${inc}")
      endforeach()
      # Update CXXFLAGS entry: create a new CXXFLAGS with appended includes
      list(REMOVE_ITEM _corrosion_env "CXXFLAGS=-fexceptions")
      list(APPEND _corrosion_env "CXXFLAGS=-fexceptions${_isys}")
    endif()
  endif()

  message(STATUS "Configuring corrosion env: ${_corrosion_env}")
  corrosion_set_env_vars(rusty_code ${_corrosion_env})
  message(STATUS "Configured corrosion: CC=${GCC_TOOLCHAIN_GCC} CXX=${GCC_TOOLCHAIN_GXX} lib=${GCC_LIB_PATH} rust_target=${RUST_TARGET_TRIPLE}")
else()
  message(STATUS "No GCC_TOOLCHAIN_PATH (${GCC_TOOLCHAIN_PATH}) found — using system compilers")
endif()
Quick notes & commands
For RISC-V Linux Rust target you usually need:
rustup target add riscv64gc-unknown-linux-gnu
and a matching riscv64-linux-gnu toolchain that provides sysroot and libs.

Example configure/build for a cross riscv64 build (if you have the toolchain + rust target):

cmake -S . -B build -DGCC_TOOLCHAIN_PATH=/path/to/riscv/toolchain -DTARGET_ARCH=riscv64
cmake --build build -j$(nproc) --verbose
To test the Rust crate directly using the chosen compilers:

cd rusty_code
env CC=/path/to/riscv/toolchain/bin/riscv64-unknown-linux-gnu-gcc \
    CXX=/path/to/riscv/toolchain/bin/riscv64-unknown-linux-gnu-g++ \
    CARGO_BUILD_TARGET=riscv64gc-unknown-linux-gnu \
    cargo build -v --manifest-path Cargo.toml --target riscv64gc-unknown-linux-gnu
Gotchas
Cross-compiling to RISC-V for Linux requires a sysroot and correct target libraries — simply having a cross-gcc binary is not enough.

The Rust triple name varies by specific ABI choices (e.g. riscv64gc-unknown-linux-gnu, riscv64imac-unknown-none-elf) — set RUST_TARGET_TRIPLE to your desired triple if you need a different ABI.

If your toolchain binaries use different prefixes/names, add them to the find_program lists for riscv64.

If you want, I can:

add a short test CMake target that prints the final env used for corrosion_set_env_vars, or

produce a minimal CI matrix example (amd64/aarch64/riscv64) showing how to pass GCC_TOOLCHAIN_PATH per-job.

Which one next?

Du:
Remove cross build 
ChatGPT:

Nachgedacht für ein paar Sekunden
Got it — removing cross-build support. Below is a simplified, native-only CMake snippet: it detects the host architecture, optionally uses a provided toolchain root (GCC_TOOLCHAIN_PATH) if present, sets CC/CXX for corrosion, and adds linker search/rpath so the matching libstdc++ is used. It does not set any Rust target triple, cargo linker env var, or add any cross/sysroot include paths — so it only ever builds for the host architecture.

Drop this into the same spot where you previously set up rusty_code.

# Native-only corrosion toolchain setup (no cross-building)
# Usage: optionally pass -DGCC_TOOLCHAIN_PATH=/path/to/gcc to cmake to prefer a toolchain root.

# Detect host arch (used only for info/logging)
string(TOLOWER "${CMAKE_HOST_SYSTEM_PROCESSOR}" _hostproc)
if(_hostproc MATCHES "^(x86_64|amd64)$")
  set(HOST_ARCH "x86_64")
elseif(_hostproc MATCHES "^(aarch64|arm64|armv8)$")
  set(HOST_ARCH "aarch64")
elseif(_hostproc MATCHES "^(riscv64)$")
  set(HOST_ARCH "riscv64")
else()
  set(HOST_ARCH "${_hostproc}")
endif()

message(STATUS "Native-only build. HOST_ARCH=${HOST_ARCH}")

# Optional toolchain root (override with -DGCC_TOOLCHAIN_PATH=/path)
set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0" CACHE PATH "Optional GCC toolchain root (native use only)")

if(EXISTS "${GCC_TOOLCHAIN_PATH}")
  # Try to find reasonable native compiler binary names
  if(HOST_ARCH STREQUAL "x86_64")
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
  elseif(HOST_ARCH STREQUAL "aarch64")
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
  elseif(HOST_ARCH STREQUAL "riscv64")
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
  else()
    find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/gcc")
    find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/g++")
  endif()

  if(NOT GCC_TOOLCHAIN_GCC OR NOT GCC_TOOLCHAIN_GXX)
    message(WARNING "Toolchain compilers not found in ${GCC_TOOLCHAIN_PATH}; falling back to system compilers")
  endif()

  # prefer lib64 then lib
  if(EXISTS "${GCC_TOOLCHAIN_PATH}/lib64")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")
  elseif(EXISTS "${GCC_TOOLCHAIN_PATH}/lib")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib")
  else()
    message(FATAL_ERROR "No lib directory found under ${GCC_TOOLCHAIN_PATH}")
  endif()

  # DO NOT inject toolchain C++ includes. Only set CC/CXX and LDFLAGS/rpath for native run.
  corrosion_set_env_vars(
    rusty_code
    CC=${GCC_TOOLCHAIN_GCC}
    CXX=${GCC_TOOLCHAIN_GXX}
    CXXFLAGS=-fexceptions
    LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
  )

  message(STATUS "Configured native corrosion: CC=${GCC_TOOLCHAIN_GCC} CXX=${GCC_TOOLCHAIN_GXX} lib=${GCC_LIB_PATH}")
else()
  message(STATUS "No GCC_TOOLCHAIN_PATH (${GCC_TOOLCHAIN_PATH}) found — using system compilers (native build)")
endif()
What changed & why
removed TARGET_ARCH and all cross-compiling branches — this script only builds for the host.

no Rust/Cargo target/triple environment variables are set (so cargo builds default to the host Rust target).

no -isystem/sysroot include injection or architecture-specific include directories are added. This avoids header/ABI mismatches.

we still set LDFLAGS with -Wl,-rpath so at runtime the toolchain's libstdc++ can be found automatically if you use a custom toolchain.

Quick tests (run in container)
Configure and build (native):

cmake -S . -B build -DGCC_TOOLCHAIN_PATH=/opt/gcc-15.2.0
cmake --build build -j$(nproc) --verbose
Build the Rust crate directly (native):

cd rusty_code
env CC=/opt/gcc-15.2.0/bin/gcc CXX=/opt/gcc-15.2.0/bin/g++ cargo build -v --manifest-path Cargo.toml
If runtime complains about libstdc++, run:

export LD_LIBRARY_PATH=/opt/gcc-15.2.0/lib64:$LD_LIBRARY_PATH
If something still breaks
Paste the exact failing commands and error text you see from:

cmake --build build --verbose (copy the failing g++ invocation + errors) or

cargo build -v inside rusty_code (copy the rustc/linker command and error).

I’ll parse them and give the exact one-line tweak to fix it.

Du:
e/KataglyphisCppInference $ cat Src/CMakeLists.txt   # update current positions
set(PROJECT_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(PROJECT_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(EXTERNAL_LIB_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}../ExternalLib/)

include(cmake/filters/SetProjectFilters.cmake)
include(cmake/SetSourceGroups.cmake)

file(GLOB_RECURSE KataglyphisCppProject_SOURCES "*.cpp")
file(GLOB_RECURSE KataglyphisCppProject_HEADERS "*.hpp")

if(RUST_FEATURES)

  corrosion_import_crate(
    MANIFEST_PATH rusty_code/Cargo.toml
  )
  if(WIN32)
    corrosion_set_env_vars(
              rusty_code
              CXXFLAGS=/EHsc
    )
  else()
    # Set the GCC 15.2.0 toolchain for Rust CXX bridge
    set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0")
    set(GCC_INCLUDE_PATH "${GCC_TOOLCHAIN_PATH}/include/c++/")
    set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")

    corrosion_set_env_vars(
              rusty_code
              CC=${GCC_TOOLCHAIN_PATH}/bin/gcc
              CXX=${GCC_TOOLCHAIN_PATH}/bin/g++
              CXXFLAGS=-fexceptions -I${GCC_INCLUDE_PATH} -I${GCC_INCLUDE_PATH}/aarch64-unknown-linux-gnu
              LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
    )
  endif()

  corrosion_add_cxxbridge(
    rusty_bridge
    CRATE
    rusty_code
    FILES
    lib.rs
    )

endif()

# add the executable
add_library(${PROJECT_NAME} SHARED)
set_target_properties(${PROJECT_NAME} PROPERTIES
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
# add_executable(${PROJECT_NAME})

# Define export macro for building the DLL
target_compile_definitions(${PROJECT_NAME} PRIVATE KATAGLYPHIS_EXPORTS)

# Set symbol visibility
set_target_properties(${PROJECT_NAME} PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

if(RUST_FEATURES)
  message("RUST features defined")
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=1)
else()
  message("RUST features not defined")
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=0)
endif()

# Treat MSVC and clang-cl on Windows differently in a sense of deployment
# https://clang.llvm.org/docs/UsersManual.html
if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC))
  target_compile_definitions(
    ${PROJECT_NAME}
    PRIVATE
      RELATIVE_RESOURCE_PATH="/../../Resources/"
      RELATIVE_INCLUDE_PATH="/../../Src/"
  )
else()
  target_compile_definitions(
    ${PROJECT_NAME}
    PRIVATE
      RELATIVE_RESOURCE_PATH="/../Resources/"
      RELATIVE_INCLUDE_PATH="/../Src/"
  )
endif()


configure_file(KataglyphisCppProjectConfig.hpp.in "${CMAKE_CURRENT_SOURCE_DIR}/KataglyphisCppProjectConfig.hpp")

target_sources(
  ${PROJECT_NAME}
  PUBLIC ${KataglyphisCppProject_SOURCES}
  PUBLIC FILE_SET
         HEADERS
         BASE_DIRS
         ${PROJECT_INCLUDE_DIR}
         FILES
         ${KataglyphisCppProject_HEADERS})

target_link_libraries(
  ${PROJECT_NAME}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         # enable compiler warnings
         myproject_warnings
         # enable sanitizers
         myproject_options
  PRIVATE GSL spdlog::spdlog nlohmann_json::nlohmann_json)

if(RUST_FEATURES)
  target_link_libraries(${PROJECT_NAME} PUBLIC rusty_code)
endif()

if(TARGET ${PROJECT_NAME} AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  message(STATUS "GCC detected — adding -MMD -MP to target ${PROJECT_NAME}")
  target_compile_options(${PROJECT_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-MMD -MP>
  )
endif()

Give me full updated CMakeLists.txt
ChatGPT:

Nachgedacht für 6s
Here’s the full updated CMakeLists.txt with the native-only corrosion/toolchain setup, the fixed EXTERNAL_LIB_SRC_DIR path, and removal of any cross-build include injection. Drop this in place of your current file.

# Src/CMakeLists.txt
# update current positions
set(PROJECT_SRC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(PROJECT_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/)
set(EXTERNAL_LIB_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../ExternalLib/")

include(cmake/filters/SetProjectFilters.cmake)
include(cmake/SetSourceGroups.cmake)

file(GLOB_RECURSE KataglyphisCppProject_SOURCES "*.cpp")
file(GLOB_RECURSE KataglyphisCppProject_HEADERS "*.hpp")

if(RUST_FEATURES)

  corrosion_import_crate(
    MANIFEST_PATH rusty_code/Cargo.toml
  )

  if(WIN32)
    corrosion_set_env_vars(
      rusty_code
      CXXFLAGS=/EHsc
    )
  else()
    # Native-only corrosion/toolchain setup (no cross-building)
    # Optionally override with -DGCC_TOOLCHAIN_PATH=/path/to/gcc when configuring
    set(GCC_TOOLCHAIN_PATH "/opt/gcc-15.2.0" CACHE PATH "Optional GCC toolchain root (native use only)")

    # detect host arch for logging (no cross-compile behavior)
    string(TOLOWER "${CMAKE_HOST_SYSTEM_PROCESSOR}" _hostproc)
    if(_hostproc MATCHES "^(x86_64|amd64)$")
      set(HOST_ARCH "x86_64")
    elseif(_hostproc MATCHES "^(aarch64|arm64|armv8)$")
      set(HOST_ARCH "aarch64")
    elseif(_hostproc MATCHES "^(riscv64)$")
      set(HOST_ARCH "riscv64")
    else()
      set(HOST_ARCH "${_hostproc}")
    endif()

    message(STATUS "Native-only build. HOST_ARCH=${HOST_ARCH}")

    if(EXISTS "${GCC_TOOLCHAIN_PATH}")
      # Try to find reasonable native compiler binary names
      if(HOST_ARCH STREQUAL "x86_64")
        find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
        find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/x86_64-pc-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
      elseif(HOST_ARCH STREQUAL "aarch64")
        find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
        find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/aarch64-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
      elseif(HOST_ARCH STREQUAL "riscv64")
        find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-linux-gnu-gcc" "${GCC_TOOLCHAIN_PATH}/bin/gcc")
        find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/riscv64-unknown-linux-gnu-g++" "${GCC_TOOLCHAIN_PATH}/bin/g++")
      else()
        find_program(GCC_TOOLCHAIN_GCC NAMES "${GCC_TOOLCHAIN_PATH}/bin/gcc")
        find_program(GCC_TOOLCHAIN_GXX NAMES "${GCC_TOOLCHAIN_PATH}/bin/g++")
      endif()

      if(NOT GCC_TOOLCHAIN_GCC)
        message(WARNING "Toolchain gcc not found in ${GCC_TOOLCHAIN_PATH}; falling back to system 'gcc'")
        set(GCC_TOOLCHAIN_GCC "gcc")
      endif()
      if(NOT GCC_TOOLCHAIN_GXX)
        message(WARNING "Toolchain g++ not found in ${GCC_TOOLCHAIN_PATH}; falling back to system 'g++'")
        set(GCC_TOOLCHAIN_GXX "g++")
      endif()

      # prefer lib64 then lib; optional for setting LDFLAGS/rpath
      if(EXISTS "${GCC_TOOLCHAIN_PATH}/lib64")
        set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib64")
      elseif(EXISTS "${GCC_TOOLCHAIN_PATH}/lib")
        set(GCC_LIB_PATH "${GCC_TOOLCHAIN_PATH}/lib")
      else()
        message(WARNING "No lib or lib64 under ${GCC_TOOLCHAIN_PATH}; skipping LDFLAGS/rpath setup")
        unset(GCC_LIB_PATH)
      endif()

      # DO NOT inject toolchain C++ includes. Only set CC/CXX and LDFLAGS/rpath for native run.
      if(GCC_LIB_PATH)
        corrosion_set_env_vars(
          rusty_code
          CC=${GCC_TOOLCHAIN_GCC}
          CXX=${GCC_TOOLCHAIN_GXX}
          CXXFLAGS=-fexceptions
          LDFLAGS=-L${GCC_LIB_PATH} -Wl,-rpath,${GCC_LIB_PATH}
        )
      else()
        corrosion_set_env_vars(
          rusty_code
          CC=${GCC_TOOLCHAIN_GCC}
          CXX=${GCC_TOOLCHAIN_GXX}
          CXXFLAGS=-fexceptions
        )
      endif()

      message(STATUS "Configured native corrosion: CC=${GCC_TOOLCHAIN_GCC} CXX=${GCC_TOOLCHAIN_GXX} ${GCC_LIB_PATH}")
    else()
      message(STATUS "No GCC_TOOLCHAIN_PATH (${GCC_TOOLCHAIN_PATH}) found — using system compilers (native build)")
      # Still set minimal sensible env so corrosion has deterministic env on non-Windows hosts
      corrosion_set_env_vars(
        rusty_code
        CXXFLAGS=-fexceptions
      )
    endif()
  endif()

  corrosion_add_cxxbridge(
    rusty_bridge
    CRATE
    rusty_code
    FILES
    lib.rs
    )
  
endif()

# add the executable
add_library(${PROJECT_NAME} SHARED)
set_target_properties(${PROJECT_NAME} PROPERTIES
  ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
)
# add_executable(${PROJECT_NAME})

# Define export macro for building the DLL
target_compile_definitions(${PROJECT_NAME} PRIVATE KATAGLYPHIS_EXPORTS)

# Set symbol visibility
set_target_properties(${PROJECT_NAME} PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

if(RUST_FEATURES)
  message("RUST features defined")
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=1)
else()
  message("RUST features not defined")
  target_compile_definitions(${PROJECT_NAME} PRIVATE USE_RUST=0)
endif()

# Treat MSVC and clang-cl on Windows differently in a sense of deployment
# https://clang.llvm.org/docs/UsersManual.html
if(WIN32 AND NOT (CMAKE_CXX_COMPILER_ID STREQUAL "Clang" AND MSVC))
  target_compile_definitions(
    ${PROJECT_NAME}
    PRIVATE
      RELATIVE_RESOURCE_PATH="/../../Resources/"
      RELATIVE_INCLUDE_PATH="/../../Src/"
  )
else()
  target_compile_definitions(
    ${PROJECT_NAME}
    PRIVATE
      RELATIVE_RESOURCE_PATH="/../Resources/"
      RELATIVE_INCLUDE_PATH="/../Src/"
  )
endif()


configure_file(KataglyphisCppProjectConfig.hpp.in "${CMAKE_CURRENT_SOURCE_DIR}/KataglyphisCppProjectConfig.hpp")

target_sources(
  ${PROJECT_NAME}
  PUBLIC ${KataglyphisCppProject_SOURCES}
  PUBLIC FILE_SET
         HEADERS
         BASE_DIRS
         ${PROJECT_INCLUDE_DIR}
         FILES
         ${KataglyphisCppProject_HEADERS})

target_link_libraries(
  ${PROJECT_NAME}
  PUBLIC ${CMAKE_DL_LIBS}
         Threads::Threads
         # enable compiler warnings
         myproject_warnings
         # enable sanitizers
         myproject_options
  PRIVATE GSL spdlog::spdlog nlohmann_json::nlohmann_json)

if(RUST_FEATURES)
  target_link_libraries(${PROJECT_NAME} PUBLIC rusty_code)
endif()

if(TARGET ${PROJECT_NAME} AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  message(STATUS "GCC detected — adding -MMD -MP to target ${PROJECT_NAME}")
  target_compile_options(${PROJECT_NAME} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-MMD -MP>
  )
endif()
