#!/usr/bin/env bash
# ci-common.sh - bootstrap shim for CI scripts
#
# Sources the ANTfrastructure core library, providing:
#   Logging    : info, warn, err/die, log
#   Platform   : arch_oci, is_amd64_arch, detect_system, deb_multiarch_triplet
#   Parallelism: detect_available_cores, compute_jobs, compute_jobs_with_mem_cap
#   Apt helpers: apt_install, apt_update_once, require_sudo
#   Module load: source_module
#
# Usage (at the top of every CI script, after set -euo pipefail):
#   _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck disable=SC1091
#   source "${_SCRIPT_DIR}/ci-common.sh"

[ -n "${_CI_COMMON_SH_LOADED:-}" ] && return 0
_CI_COMMON_SH_LOADED=1

_CI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the ANTfrastructure core library.
# Works from both the repo root and an arbitrary working directory.
#
# ANTFRASTRUCTURE_DIR comes from the canonical bootstrap — a verbatim copy of
# upstream's shared/linux/templates/antfrastructure.sh — rather than a ../.. literal
# spelled out here. Six repos each had their own version of that line and they
# had drifted; see ANTfrastructure shared/linux/templates/README.md.
# shellcheck disable=SC1091
source "${_CI_COMMON_DIR}/lib/antfrastructure.sh"

_ANTFRASTRUCTURE_CORE="${ANTFRASTRUCTURE_DIR}/linux/scripts/01-core"

if [ -f "${_ANTFRASTRUCTURE_CORE}/common.sh" ]; then
  # shellcheck disable=SC1091
  source "${_ANTFRASTRUCTURE_CORE}/common.sh"
  # Also load modules.sh so callers can use source_module if needed.
  if [ -f "${_ANTFRASTRUCTURE_CORE}/modules.sh" ]; then
    # shellcheck disable=SC1091
    source "${_ANTFRASTRUCTURE_CORE}/modules.sh"
  fi
  info "ANTfrastructure core library loaded from ${_ANTFRASTRUCTURE_CORE}"
else
  # Minimal fallbacks so scripts still work outside the submodule tree
  # (e.g. when running on a bare checkout without submodule init).
  info()  { printf '[INFO]  %s\n' "$*"; }
  warn()  { printf '[WARN]  %s\n' "$*" >&2; }
  err()   { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
  log()   { info "$@"; }
  die()   { err "$@"; }

  detect_available_cores() { nproc 2>/dev/null || echo 1; }
  compute_jobs()                 { detect_available_cores; }
  compute_jobs_with_mem_cap()    { detect_available_cores; }

  arch_oci() {
    case "$(uname -m)" in
      x86_64|amd64)   printf 'amd64'   ;;
      aarch64|arm64)   printf 'arm64'   ;;
      i386|i686)       printf '386'     ;;
      riscv64)         printf 'riscv64' ;;
      *)               uname -m         ;;
    esac
  }

  require_sudo() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
      command -v sudo >/dev/null 2>&1 || { echo "This script requires sudo or root." >&2; exit 1; }
      SUDO="sudo"
    else
      SUDO=""
    fi
  }

  apt_update_once() {
    if [ -z "${_APT_UPDATED:-}" ]; then
      ${SUDO:-} apt-get update -y
      _APT_UPDATED=1
    fi
  }

  apt_install() {
    apt_update_once
    ${SUDO:-} apt-get install -yq --no-install-recommends "$@"
  }

  warn "ANTfrastructure core library not found at ${_ANTFRASTRUCTURE_CORE} - using minimal fallbacks"
fi

# compiler_llvm_tool <build-dir> <tool> - prints the absolute path of <tool> from
# the LLVM install of the C++ compiler that configured <build-dir> (its
# CMakeCache.txt CMAKE_CXX_COMPILER, else clang++), or fails printing nothing.
# The CI image puts a source-built clang 23 (/usr/local/llvm-target) behind
# clang/clang++, but bare clang-tidy, llvm-profdata and llvm-cov on PATH are
# Ubuntu's LLVM 21, which cannot read what clang 23 writes: raw profile format 11
# ("no profile can be merged") and C++ module PCMs ("uses a newer format that
# cannot be read"). -print-prog-name answers with the compiler's sibling binary.
compiler_llvm_tool() {
  local build_dir="$1" tool="$2" cxx="" path=""
  if [[ -f "${build_dir}/CMakeCache.txt" ]]; then
    cxx="$(sed -n 's/^CMAKE_CXX_COMPILER:[A-Z]*=//p' "${build_dir}/CMakeCache.txt" | head -n 1)"
  fi
  path="$("${cxx:-clang++}" -print-prog-name="${tool}" 2>/dev/null)" || return 1
  [[ "${path}" == /* && -x "${path}" ]] || return 1
  printf '%s\n' "${path}"
}

# use_compiler_llvm_tools <build-dir> <tool>... - puts the directory holding the
# compiler's own copy of EVERY named tool first on PATH, for hub functions that
# call them by bare name (coverage.sh, code-quality.sh). Warns and leaves PATH
# alone when the compiler has no such set; the caller's require_tools decides.
# Callers scope it (a subshell) when the directory holds tools they must not
# swap - clang-format's version is a format verdict of its own.
use_compiler_llvm_tools() {
  local build_dir="$1" path dir tool
  shift
  if ! path="$(compiler_llvm_tool "${build_dir}" "$1")"; then
    warn "The compiler of '${build_dir}' names no $1 of its own; using PATH's $*, which must read what that compiler wrote."
    return 0
  fi
  dir="$(dirname "${path}")"
  for tool in "$@"; do
    if [[ ! -x "${dir}/${tool}" ]]; then
      warn "${dir} has no ${tool} beside $1; using PATH's $*, which must read what that compiler wrote."
      return 0
    fi
  done
  PATH="${dir}:${PATH}"
  export PATH
  hash -r
  info "LLVM tools matching the compiler of '${build_dir}': ${dir} ($*)"
}
