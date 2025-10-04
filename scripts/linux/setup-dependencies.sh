#!/bin/bash
set -e

# Update package lists and install packages based on available package manager

if command -v apt-get >/dev/null; then
    echo "Detected apt-get. Installing via apt-get..."
    sudo apt-get update
    sudo apt-get install -y sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm valgrind

    # for debian packaging
    sudo apt-get install -y dpkg-dev fakeroot binutils

    # Ensure pip is available
    sudo apt-get install -y python3-pip

    # Install latest CMake from Kitware APT repository
    # Determine codename (e.g. focal, jammy). Fall back to 'noble' if lsb_release isn't available.
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "noble")
    echo "Installing latest CMake via Kitware repo for codename: ${CODENAME}"

    # Purge older distro cmake if present (ignore errors)
    sudo apt-get purge --auto-remove -y cmake || true

    # Ensure required tools for adding the repo are present
    sudo apt-get update
    sudo apt-get install -y wget gpg lsb-release ca-certificates

    # Add Kitware GPG key (dearmored) and repository
    wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc \
      | gpg --dearmor \
      | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null

    echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${CODENAME} main" \
      | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null

    sudo apt-get update
    sudo apt-get install -y cmake

    cmake --version

    # desired tool versions
    LLVM_WANTED=21        # for the apt.llvm.org helper (llvm.sh)
    CLANG_WANTED=21       # for update-alternatives clang/clang++=21
    export DEBIAN_FRONTEND=noninteractive
    APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    
    # minimal prerequisites
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends wget gnupg lsb-release ca-certificates

    # Add the LLVM apt repo using the official helper (non-interactive)
    wget -qO- https://apt.llvm.org/llvm.sh | sudo bash -s -- "${LLVM_WANTED}" all

    sudo apt-get update

    # clang
    if [ -x "/usr/bin/clang-${CLANG_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/clang clang /usr/bin/clang-"${CLANG_WANTED}" 100
      sudo update-alternatives --set clang /usr/bin/clang-"${CLANG_WANTED}"
    fi

    # clang++
    if [ -x "/usr/bin/clang++-${CLANG_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-"${CLANG_WANTED}" 100
      sudo update-alternatives --set clang++ /usr/bin/clang++-"${CLANG_WANTED}"
    fi

    # clang-tidy
    if [ -x "/usr/bin/clang-tidy-${CLANG_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/clang-tidy clang-tidy /usr/bin/clang-tidy-"${CLANG_WANTED}" 100
    fi

    # clang-format
    if [ -x "/usr/bin/clang-format-${CLANG_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/clang-format clang-format /usr/bin/clang-format-"${CLANG_WANTED}" 100
    fi

    # llvm-profdata
    if [ -x "/usr/bin/llvm-profdata-${CLANG_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/llvm-profdata llvm-profdata /usr/bin/llvm-profdata-"${CLANG_WANTED}" 100
      sudo update-alternatives --set llvm-profdata /usr/bin/llvm-profdata-"${CLANG_WANTED}"
    fi

    # llvm-cov
    if [ -x "/usr/bin/llvm-cov-${CLANG_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/llvm-cov llvm-cov /usr/bin/llvm-cov-"${CLANG_WANTED}" 100
      sudo update-alternatives --set llvm-cov /usr/bin/llvm-cov-"${CLANG_WANTED}"
    fi
    
    # Verify
    clang --version
    clang++ --version

   # Install latest GCC
    GCC_WANTED=14  # or 13, adjust as needed
    sudo apt-get install -y --no-install-recommends \
      gcc-"${GCC_WANTED}" \
      g++-"${GCC_WANTED}" \
      gfortran-"${GCC_WANTED}"

    # Set GCC as default using update-alternatives
    if [ -x "/usr/bin/gcc-${GCC_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-"${GCC_WANTED}" 100
      sudo update-alternatives --set gcc /usr/bin/gcc-"${GCC_WANTED}"
    fi

    if [ -x "/usr/bin/g++-${GCC_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-"${GCC_WANTED}" 100
      sudo update-alternatives --set g++ /usr/bin/g++-"${GCC_WANTED}"
    fi

    if [ -x "/usr/bin/gcov-${GCC_WANTED}" ]; then
      sudo update-alternatives --install /usr/bin/gcov gcov /usr/bin/gcov-"${GCC_WANTED}" 100
      sudo update-alternatives --set gcov /usr/bin/gcov-"${GCC_WANTED}"
    fi

    # Verify
    gcc --version
    g++ --version
    
elif command -v yum >/dev/null; then
    echo "Detected yum. Installing via yum..."
    sudo yum install -y sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm cmake
    # ensure pip exists
    sudo yum install -y python3-pip

elif command -v dnf >/dev/null; then
    echo "Detected dnf. Installing via dnf..."
    sudo dnf install -y sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm cmake
    # ensure pip exists
    sudo dnf install -y python3-pip

elif command -v pacman >/dev/null; then
    echo "Detected pacman. Installing via pacman..."
    sudo pacman -Sy --noconfirm sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm cmake
    # ensure pip exists
    sudo pacman -Sy --noconfirm python-pip

else
    echo "No supported package manager found. Please install ccache, cppcheck, cmake and python3-pip/pip manually."
    exit 1
fi

# Show gcov presence/version (non-fatal)
echo "Checking for gcov..."
gcov --version || true
which gcov || true

# Install gcovr via pip (try pip3, fall back to pip). Use --user to avoid permission issues.
echo "Installing gcovr (Python tool for coverage reports)..."
if command -v pip3 >/dev/null; then
    pip3 install --upgrade --user gcovr
elif command -v pip >/dev/null; then
    pip install --upgrade --user gcovr
else
    echo "pip not found. You may need to install python3-pip / pip before installing gcovr."
fi

echo "Installation complete."
