#!/usr/bin/env bash
# ci_common.sh - bootstrap shim for CI scripts
#
# Sources the Kataglyphis-ContainerHub core library, providing:
#   Logging    : info, warn, err/die, log
#   Platform   : arch_oci, is_amd64_arch, detect_system, deb_multiarch_triplet
#   Parallelism: detect_available_cores, compute_jobs, compute_jobs_with_mem_cap
#   Apt helpers: apt_install, apt_update_once, require_sudo
#   Module load: source_module
#
# Usage (at the top of every CI script, after set -euo pipefail):
#   _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck disable=SC1091
#   source "${_SCRIPT_DIR}/ci_common.sh"

[ -n "${_CI_COMMON_SH_LOADED:-}" ] && return 0
_CI_COMMON_SH_LOADED=1

_CI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the ContainerHub core library.
# Works from both the repo root and an arbitrary working directory.
_CONTAINER_HUB_CORE="${_CI_COMMON_DIR}/../../ExternalLib/Kataglyphis-ContainerHub/linux/scripts/01-core"

if [ -f "${_CONTAINER_HUB_CORE}/common.sh" ]; then
  # shellcheck disable=SC1091
  source "${_CONTAINER_HUB_CORE}/common.sh"
  # Also load modules.sh so callers can use source_module if needed.
  if [ -f "${_CONTAINER_HUB_CORE}/modules.sh" ]; then
    # shellcheck disable=SC1091
    source "${_CONTAINER_HUB_CORE}/modules.sh"
  fi
  info "ContainerHub core library loaded from ${_CONTAINER_HUB_CORE}"
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

  warn "ContainerHub core library not found at ${_CONTAINER_HUB_CORE} - using minimal fallbacks"
fi
