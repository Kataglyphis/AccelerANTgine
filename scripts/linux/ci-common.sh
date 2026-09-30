#!/usr/bin/env bash
# ci-common.sh - source after set -euo pipefail for ANTfrastructure's core library (info/die, arch_oci, compute_jobs, apt_install).

[ -n "${_CI_COMMON_SH_LOADED:-}" ] && return 0
_CI_COMMON_SH_LOADED=1

_CI_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ANTFRASTRUCTURE_DIR comes from lib/antfrastructure.sh, a verbatim copy of the upstream template.
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
  # Minimal fallbacks for a checkout without initialised submodules.
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
